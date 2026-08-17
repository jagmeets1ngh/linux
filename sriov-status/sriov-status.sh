#!/usr/bin/env bash
# =============================================================================
#  sriov-status.sh — SR-IOV Virtual Function status for Linux / Proxmox VE
#
#  Nothing is statically configured. PFs, PCI addresses, bond/bridge masters
#  and guest ownership are all discovered at runtime.
#
#  VF# is the kernel index exactly:  VF0 = vf0 = virtfn0
#
#  Site MAC scheme (informational only, never parsed for truth):
#      1a:PVE#:NIC#:VLAN_ID:VM_HH:VM_LL     1a = SR-IOV VF
#      2a:PVE#:NIC#:VLAN_ID:VM_HH:VM_LL     2a = virtio
#      PVE# = 01: Host1, 02: Host2 ..... 
#
#  SPDX-License-Identifier: MIT
# =============================================================================

set -uo pipefail
shopt -s extglob

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    printf 'sriov-status: needs bash 4.3 or newer (found %s)\n' "${BASH_VERSION}" >&2
    exit 1
fi

VERSION="1.1.0"

# Path roots — overridable for testing; production defaults are the real paths.
SYS_NET="${E810_SYS_NET:-/sys/class/net}"
SYS_PCI="${E810_SYS_PCI:-/sys/bus/pci/devices}"
PVE_DIR="${E810_PVE_DIR:-/etc/pve}"
PROC_BOND="${E810_PROC_BOND:-/proc/net/bonding}"
NET_DIR="${E810_NET_DIR:-/etc/systemd/network}"
IP_BIN="${E810_IP:-ip}"
RS=$'\x1f'          # record separator: not IFS whitespace, preserves empty fields
RUN_QEMU="${E810_RUN_QEMU:-/run/qemu-server}"
CGROUP_LXC="${E810_CGROUP_LXC:-/sys/fs/cgroup}"

# ── Options ──────────────────────────────────────────────────────────────────
OPT_IFACE=""
OPT_CHARSET=""
OPT_COLOR="auto"
OPT_LAYOUT="auto"
OPT_JSON=0
OPT_BYVM=0
OPT_NOVM=0
OPT_WATCH=0
OPT_WATCH_INT=2
OPT_VERBOSE=0
OPT_WIDTH=""

# ── Discovered state ─────────────────────────────────────────────────────────
declare -a PFS=()
declare -a VF_ROWS=()          # tab-separated records, see collect_vfs()
declare -a MASTERS=()
declare -A PF_META=()
declare -A PF_MODEL=()
declare -A PCIMAP=()
declare -A PCI2VM=()           # pci -> "vmid|slot" (space-joined if >1)
declare -A MAC2VM=()           # lowercase mac -> "vmid|slot"
declare -A VMNAME=() VMSTATE=() VMTYPE=()
declare -A VMNICS=()           # vmid -> newline-joined virtio/veth nic descriptions
declare -a ISS_SEV=() ISS_SCOPE=() ISS_MSG=()
PVE_OK=0
HOSTNAME_S=""

# =============================================================================
#  Helpers
# =============================================================================
have() { command -v "$1" >/dev/null 2>&1; }
die()  { printf 'sriov-status: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
sriov-status.sh — SR-IOV VF status for Linux / Proxmox VE

Usage: sriov-status.sh [options]

  -i, --iface NAME     Only show this PF (repeatable via comma: -i ice1,ice2)
      --by-vm          Group output by guest instead of by VF
      --no-vm          Skip guest-config scanning entirely
      --json           Emit the full model as JSON and exit
      --watch [SEC]    Refresh continuously (default 2s, q or Ctrl-C to quit)
  -v, --verbose        Include informational notes in the Health section
      --wide           Keep the Driver column even on a narrow terminal
      --compact        Drop the Driver column and target a narrow layout
      --width N        Assume terminal width N instead of detecting it
      --ascii          Force ASCII box drawing
      --unicode        Force Unicode box drawing
      --no-color       Disable colour
  -h, --help           This text
  -V, --version        Version

Box style and layout are auto-detected from locale, TERM and terminal width.
Guest ownership requires read access to ${PVE_DIR} (i.e. root on Proxmox VE).
EOF
}

parse_args() {
    while (( $# )); do
        case "$1" in
            -i|--iface)  OPT_IFACE="${2:-}"; shift 2 ;;
            --by-vm)     OPT_BYVM=1; shift ;;
            --no-vm)     OPT_NOVM=1; shift ;;
            --json)      OPT_JSON=1; shift ;;
            --watch)
                OPT_WATCH=1
                if [[ "${2:-}" =~ ^[0-9]+$ ]]; then OPT_WATCH_INT="$2"; shift; fi
                shift ;;
            -v|--verbose) OPT_VERBOSE=1; shift ;;
            --wide)      OPT_LAYOUT=wide; shift ;;
            --compact)   OPT_LAYOUT=compact; shift ;;
            --width)     OPT_WIDTH="${2:-}"; shift 2 ;;
            --ascii)     OPT_CHARSET=ascii; shift ;;
            --unicode)   OPT_CHARSET=unicode; shift ;;
            --no-color)  OPT_COLOR=never; shift ;;
            -h|--help)   usage; exit 0 ;;
            -V|--version) printf 'sriov-status.sh %s\n' "$VERSION"; exit 0 ;;
            *) die "unknown option: $1 (try --help)" ;;
        esac
    done
    (( OPT_WATCH_INT < 1 )) && OPT_WATCH_INT=1
}

# ── Charset auto-detection ───────────────────────────────────────────────────
detect_charset() {
    if [[ -n "$OPT_CHARSET" ]]; then CHARSET="$OPT_CHARSET"; return; fi
    if [[ ! -t 1 ]]; then CHARSET=ascii; return; fi
    local lc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
    lc="${lc,,}"
    if [[ "$lc" != *utf-8* && "$lc" != *utf8* ]]; then CHARSET=ascii; return; fi
    case "${TERM:-dumb}" in
        dumb|vt100|vt102|vt220|ansi|linux) CHARSET=ascii; return ;;
    esac
    CHARSET=unicode
}

init_theme() {
    detect_charset
    if [[ "$CHARSET" == unicode ]]; then
        BX_TL='┌'; BX_TM='┬'; BX_TR='┐'
        BX_ML='├'; BX_MM='┼'; BX_MR='┤'
        BX_BL='└'; BX_BM='┴'; BX_BR='┘'
        BX_H='─';  BX_V='│'
        G_RUN='●'; G_STOP='○'; G_FREE='·'; G_RSVD='▪'
        F_OFF='·'; ELLIPSIS='…'
        SEV_ERR='!'; SEV_WARN='~'; SEV_INFO='i'
        D_TL='╔'; D_TR='╗'; D_BL='╚'; D_BR='╝'; D_H='═'; D_V='║'
        D_ML='╟'; D_MR='╢'; D_MH='─'
        BUL='·'
    else
        BX_TL='+'; BX_TM='+'; BX_TR='+'
        BX_ML='+'; BX_MM='+'; BX_MR='+'
        BX_BL='+'; BX_BM='+'; BX_BR='+'
        BX_H='-';  BX_V='|'
        G_RUN='*'; G_STOP='o'; G_FREE='.'; G_RSVD='-'
        F_OFF='.'; ELLIPSIS='~'
        SEV_ERR='!'; SEV_WARN='~'; SEV_INFO='i'
        D_TL='+'; D_TR='+'; D_BL='+'; D_BR='+'; D_H='='; D_V='|'
        D_ML='+'; D_MR='+'; D_MH='-'
        BUL='.'
    fi

    local use_color=0
    case "$OPT_COLOR" in
        never) use_color=0 ;;
        *) [[ -t 1 && -z "${NO_COLOR:-}" ]] && use_color=1 ;;
    esac
    if (( use_color )); then
        cR=$'\e[31m'; cY=$'\e[33m'; cG=$'\e[32m'; cB=$'\e[34m'
        cC=$'\e[36m'; cM=$'\e[35m'; cW=$'\e[1m';  cD=$'\e[2m'; cN=$'\e[0m'
    else
        cR=''; cY=''; cG=''; cB=''; cC=''; cM=''; cW=''; cD=''; cN=''
    fi
    cF="$cD"          # frame
    cHD="${cW}${cC}"  # section heading
    cLB="$cD"         # field label
    cNUM="$cW"        # emphasised number
}

term_width() {
    local w=""
    have tput && w=$(tput cols 2>/dev/null)
    [[ -z "$w" ]] && w="${COLUMNS:-}"
    [[ -z "$w" ]] && w=100
    printf '%s' "$w"
}

rep() { local s; printf -v s '%*s' "$1" ''; printf '%s' "${s// /$2}"; }

fit() {  # fit <width> <text>
    local w="$1" t="$2"
    (( ${#t} <= w )) && { printf '%s' "$t"; return; }
    printf '%s%s' "${t:0:w-1}" "$ELLIPSIS"
}

# =============================================================================
#  Discovery — PFs
# =============================================================================
discover_pfs() {
    local d name filter_ok
    local -a wanted=()
    [[ -n "$OPT_IFACE" ]] && IFS=',' read -r -a wanted <<< "$OPT_IFACE"

    for d in ${SYS_NET}/*/device/sriov_totalvfs; do
        [[ -r "$d" ]] || continue
        name="${d#"${SYS_NET}"/}"; name="${name%%/*}"
        if (( ${#wanted[@]} )); then
            filter_ok=0
            for f in "${wanted[@]}"; do [[ "$f" == "$name" ]] && filter_ok=1; done
            (( filter_ok )) || continue
        fi
        PFS+=("$name")
    done
    if (( ${#PFS[@]} > 1 )); then
        mapfile -t PFS < <(printf '%s\n' "${PFS[@]}" | sort -V)
    fi
}

sysread() {
    local v=""
    [[ -r "$1" ]] && v=$(tr -d '\n' < "$1" 2>/dev/null)
    [[ -n "$v" ]] && printf '%s' "$v" || printf '%s' "${2:-}"
}

pf_pci() {
    local l; l=$(readlink -f "${SYS_NET}/$1/device" 2>/dev/null)
    [[ -n "$l" ]] && basename "$l" || printf '%s' "-"
}

pf_driver() {
    local l; l=$(readlink -f "${SYS_NET}/$1/device/driver" 2>/dev/null)
    [[ -n "$l" ]] && basename "$l" || printf '%s' "-"
}

pf_master() {
    local l; l=$(readlink "${SYS_NET}/$1/master" 2>/dev/null)
    [[ -n "$l" ]] && basename "$l" || printf ''
}

master_kind() {
    local m="$1"
    [[ -r "${PROC_BOND}/$m" ]] && { printf 'bond'; return; }
    [[ -d "${SYS_NET}/$m/bridge" ]] && { printf 'bridge'; return; }
    if have ovs-vsctl && ovs-vsctl br-exists "$m" 2>/dev/null; then
        printf 'ovs'; return
    fi
    printf 'other'
}

pf_eswitch() {
    local pci="$1" out
    have devlink || { printf '%s' "-"; return; }
    out=$(devlink dev eswitch show "pci/$pci" 2>/dev/null)
    [[ -z "$out" ]] && out=$(devlink dev eswitch show "$pci" 2>/dev/null)
    if [[ "$out" =~ mode[[:space:]]+([a-z]+) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf '%s' "-"
    fi
}

pf_linkfile() {
    local pf="$1" mac f val line
    mac=$(sysread "${SYS_NET}/$pf/address")
    [[ -z "$mac" ]] && { printf ''; return; }
    shopt -s nullglob
    for f in ${NET_DIR}/*.link; do
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*MACAddress=(.*) ]] || continue
            val="${BASH_REMATCH[1]}"
            val="${val// /}"
            if [[ "${val,,}" == "${mac,,}" ]]; then
                shopt -u nullglob; basename "$f"; return
            fi
        done < "$f"
    done
    shopt -u nullglob
    printf ''
}

pf_speed() {
    local pf="$1" oper speed duplex
    oper=$(sysread "${SYS_NET}/$pf/operstate" "unknown")
    # speed/duplex return EINVAL while the link is down - do not even read them
    if [[ "$oper" == up ]]; then
        speed=$(sysread "${SYS_NET}/$pf/speed")
        duplex=$(sysread "${SYS_NET}/$pf/duplex")
    else
        speed=""; duplex=""
    fi
    printf "%s${RS}%s${RS}%s" "$oper" "${speed:--}" "${duplex:--}"
}

pf_firmware() {
    local pf="$1" out fw drv
    have ethtool || { printf "%s${RS}%s" "-" "-"; return; }
    out=$(ethtool -i "$pf" 2>/dev/null)
    fw=$(printf '%s' "$out"  | sed -n 's/^firmware-version:[[:space:]]*//p')
    drv=$(printf '%s' "$out" | sed -n 's/^version:[[:space:]]*//p')
    printf "%s${RS}%s" "${drv:--}" "${fw:--}"
}

pf_model() {
    local pci="$1" out
    have lspci || { printf ''; return; }
    out=$(lspci -s "$pci" 2>/dev/null | head -1)
    out="${out#*: }"
    out="${out%% (rev*}"
    printf '%s' "$out"
}

collect_pf_meta() {
    local pf pci numvfs totalvfs master kind esw link numa mtu
    local oper speed duplex drv fw model
    for pf in "${PFS[@]}"; do
        pci=$(pf_pci "$pf")
        numvfs=$(sysread "${SYS_NET}/$pf/device/sriov_numvfs" 0)
        totalvfs=$(sysread "${SYS_NET}/$pf/device/sriov_totalvfs" 0)
        master=$(pf_master "$pf")
        kind=""; [[ -n "$master" ]] && kind=$(master_kind "$master")
        esw=$(pf_eswitch "$pci")
        link=$(pf_linkfile "$pf")
        numa=$(sysread "${SYS_NET}/$pf/device/numa_node" "-")
        mtu=$(sysread "${SYS_NET}/$pf/mtu" "-")
        IFS="$RS" read -r oper speed duplex < <(pf_speed "$pf")
        IFS="$RS" read -r drv fw < <(pf_firmware "$pf")
        model=$(pf_model "$pci")
        PF_META["$pf"]=$(printf "%s${RS}%s${RS}%s${RS}%s${RS}%s${RS}%s${RS}%s${RS}%s${RS}%s${RS}%s${RS}%s${RS}%s${RS}%s${RS}%s" \
            "$pci" "$numvfs" "$totalvfs" "$master" "$kind" "$esw" "$link" \
            "$numa" "$mtu" "$oper" "$speed" "$duplex" "$drv" "$fw")
        PF_MODEL["$pf"]="$model"
        [[ -n "$master" ]] && MASTERS+=("$master|$kind")
    done
    if (( ${#MASTERS[@]} > 1 )); then
        mapfile -t MASTERS < <(printf '%s\n' "${MASTERS[@]}" | sort -u)
    fi
}
# =============================================================================
#  Discovery — VFs
# =============================================================================
vf_pci() {
    local l; l=$(readlink "${SYS_NET}/$1/device/virtfn$2" 2>/dev/null)
    [[ -n "$l" ]] && basename "$l" || printf '%s' "-"
}

vf_driver() {
    local l; l=$(readlink "${SYS_PCI}/$1/driver" 2>/dev/null)
    [[ -n "$l" ]] && basename "$l" || printf '%s' "-"
}

vf_iommu() {
    local l; l=$(readlink "${SYS_PCI}/$1/iommu_group" 2>/dev/null)
    [[ -n "$l" ]] && basename "$l" || printf '%s' "-"
}

parse_vf_line() {
    local line="$1"
    VF_IDX=""; VF_MAC=""; VF_VLAN="-"; VF_SPOOF="-"
    VF_TRUST="-"; VF_LSTATE="-"; VF_RATE="0"
    [[ $line =~ vf[[:space:]]+([0-9]+) ]]            && VF_IDX="${BASH_REMATCH[1]}"
    [[ $line =~ link/ether[[:space:]]+([0-9a-fA-F:]{17}) ]] && VF_MAC="${BASH_REMATCH[1],,}"
    [[ $line =~ vlan[[:space:]]+([0-9]+) ]]          && VF_VLAN="${BASH_REMATCH[1]}"
    [[ $line =~ spoof[[:space:]]checking[[:space:]]+([a-z]+) ]] && VF_SPOOF="${BASH_REMATCH[1]}"
    [[ $line =~ trust[[:space:]]+([a-z]+) ]]         && VF_TRUST="${BASH_REMATCH[1]}"
    [[ $line =~ link-state[[:space:]]+([a-z]+) ]]    && VF_LSTATE="${BASH_REMATCH[1]}"
    [[ $line =~ max_tx_rate[[:space:]]+([0-9]+) ]]   && VF_RATE="${BASH_REMATCH[1]}"
    [[ -z "$VF_MAC" ]] && VF_MAC="00:00:00:00:00:00"
}

collect_vfs() {
    local pf line pci drv iommu owner vmid slot vmtype conflict
    for pf in "${PFS[@]}"; do
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*vf[[:space:]] ]] || continue
            parse_vf_line "$line"
            [[ -z "$VF_IDX" ]] && continue
            pci=$(vf_pci "$pf" "$VF_IDX")
            drv=$(vf_driver "$pci")
            iommu=$(vf_iommu "$pci")

            vmid=""; slot=""; vmtype=""; conflict=0
            owner="${PCI2VM[$pci]:-}"
            [[ -z "$owner" ]] && owner="${MAC2VM[$VF_MAC]:-}"
            if [[ -n "$owner" ]]; then
                # owner may hold several "vmid|slot" entries separated by space
                if [[ "$owner" == *" "* ]]; then conflict=1; fi
                local first="${owner%% *}"
                vmid="${first%%|*}"
                slot="${first#*|}"
                vmtype="${VMTYPE[$vmid]:-qemu}"
            fi

            VF_ROWS+=("$(printf "%s${RS}%s${RS}%s${RS}%s${RS}%s${RS}%s${RS}%s${RS}%s${RS}%s${RS}%s${RS}%s${RS}%s${RS}%s${RS}%s${RS}%s" \
                "$pf" "$VF_IDX" "$pci" "$VF_MAC" "$VF_VLAN" "$VF_SPOOF" \
                "$VF_TRUST" "$VF_LSTATE" "$VF_RATE" "$drv" "$iommu" \
                "$vmid" "$slot" "$vmtype" "$conflict")")
        done < <("$IP_BIN" -d link show dev "$pf" 2>/dev/null)
    done
}

# =============================================================================
#  Discovery — guests (Proxmox VE)
# =============================================================================
normalize_pci() {
    local a="${1,,}"
    a="${a%%,*}"                       # strip trailing options
    a="${a// /}"
    [[ -z "$a" ]] && { printf ''; return; }
    # add domain if missing:  08:11.0 -> 0000:08:11.0
    if [[ "$a" =~ ^[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ ]]; then a="0000:$a"; fi
    if [[ "$a" =~ ^[0-9a-f]{2}:[0-9a-f]{2}$ ]]; then a="0000:$a.0"; fi
    # add function if missing: 0000:08:11 -> 0000:08:11.0
    if [[ "$a" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}$ ]]; then a="$a.0"; fi
    printf '%s' "$a"
}

load_pci_mappings() {
    local f="${PVE_DIR}/mapping/pci.cfg" name="" line node path
    [[ -r "$f" ]] || return 0
    while IFS= read -r line; do
        if [[ "$line" =~ ^pci:[[:space:]]*([^[:space:]]+) ]]; then
            name="${BASH_REMATCH[1]}"
            continue
        fi
        [[ "$line" =~ map[[:space:]] ]] || continue
        [[ -z "$name" ]] && continue
        node=""; path=""
        [[ "$line" =~ node=([^,[:space:]]+) ]] && node="${BASH_REMATCH[1]}"
        [[ "$line" =~ path=([^,[:space:]]+) ]] && path="${BASH_REMATCH[1]}"
        [[ "$node" == "$HOSTNAME_S" ]] || continue
        [[ -z "$path" ]] && continue
        PCIMAP["$name"]=$(normalize_pci "$path")
    done < "$f"
}
add_owner() {  # add_owner <key-array> <key> <vmid> <slot>
    local -n _arr="$1"
    local key="$2" val="$3|$4"
    if [[ -n "${_arr[$key]:-}" ]]; then
        [[ " ${_arr[$key]} " == *" $val "* ]] || _arr["$key"]+=" $val"
    else
        _arr["$key"]="$val"
    fi
}

guest_state() {
    local vmid="$1" type="$2" pidfile pid
    if [[ "$type" == lxc ]]; then
        [[ -d "${CGROUP_LXC}/lxc/$vmid" ]] && { printf 'running'; return; }
        [[ -d "${CGROUP_LXC}/lxc.payload.$vmid" ]] && { printf 'running'; return; }
        printf 'stopped'; return
    fi
    pidfile="${RUN_QEMU}/$vmid.pid"
    if [[ -r "$pidfile" ]]; then
        pid=$(tr -d '\n' < "$pidfile")
        [[ -n "$pid" && -d "/proc/$pid" ]] && { printf 'running'; return; }
    fi
    printf 'stopped'
}

scan_qemu_conf() {
    local f vmid line key val slot addr a
    shopt -s nullglob
    for f in ${PVE_DIR}/qemu-server/*.conf; do
        vmid=$(basename "$f" .conf)
        VMTYPE["$vmid"]="qemu"
        VMNAME["$vmid"]="vm$vmid"
        VMSTATE["$vmid"]=$(guest_state "$vmid" qemu)
        while IFS= read -r line; do
            # stop at snapshot / pending sections
            [[ "$line" =~ ^\[ ]] && break
            [[ "$line" =~ ^([a-z_0-9.]+):[[:space:]]*(.*)$ ]] || continue
            key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
            case "$key" in
                name) VMNAME["$vmid"]="$val" ;;
                hostpci*)
                    slot="$key"
                    if [[ "$val" =~ mapping=([^,]+) ]]; then
                        a="${PCIMAP[${BASH_REMATCH[1]}]:-}"
                        [[ -n "$a" ]] && add_owner PCI2VM "$a" "$vmid" "$slot"
                    else
                        # first field may be addr or addr;addr;addr
                        addr="${val%%,*}"
                        local -a _addrs=()
                        IFS=';' read -r -a _addrs <<< "$addr"
                        for a in "${_addrs[@]}"; do
                            a=$(normalize_pci "$a")
                            [[ -n "$a" ]] && add_owner PCI2VM "$a" "$vmid" "$slot"
                        done
                    fi ;;
                net*)
                    if [[ "$val" =~ ([0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}) ]]; then
                        local m="${BASH_REMATCH[1],,}" br="" tag="" mdl=""
                        [[ "$val" =~ ^([a-z0-9]+)= ]] && mdl="${BASH_REMATCH[1]}"
                        [[ "$val" =~ bridge=([^,]+) ]] && br="${BASH_REMATCH[1]}"
                        [[ "$val" =~ tag=([0-9]+) ]]   && tag="${BASH_REMATCH[1]}"
                        VMNICS["$vmid"]+="${key}|${mdl:-nic}|${m}|${br:--}|${tag:--}"$'\n'
                    fi ;;
            esac
        done < "$f"
        PVE_OK=1
    done
    shopt -u nullglob
}

scan_lxc_conf() {
    local f vmid line key val idx m
    declare -A physlink=() physmac=()
    shopt -s nullglob
    for f in ${PVE_DIR}/lxc/*.conf; do
        vmid=$(basename "$f" .conf)
        VMTYPE["$vmid"]="lxc"
        VMNAME["$vmid"]="ct$vmid"
        VMSTATE["$vmid"]=$(guest_state "$vmid" lxc)
        physlink=(); physmac=()
        while IFS= read -r line; do
            [[ "$line" =~ ^\[ ]] && break
            [[ "$line" =~ ^([a-zA-Z_0-9.]+):[[:space:]]*(.*)$ ]] || continue
            key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
            case "$key" in
                hostname) VMNAME["$vmid"]="$val" ;;
                net*)
                    if [[ "$val" =~ hwaddr=([0-9a-fA-F:]{17}) ]]; then
                        m="${BASH_REMATCH[1],,}"
                        local br="" tag="" nm=""
                        [[ "$val" =~ bridge=([^,]+) ]] && br="${BASH_REMATCH[1]}"
                        [[ "$val" =~ tag=([0-9]+) ]]   && tag="${BASH_REMATCH[1]}"
                        [[ "$val" =~ name=([^,]+) ]]   && nm="${BASH_REMATCH[1]}"
                        VMNICS["$vmid"]+="${key}|${nm:-veth}|${m}|${br:--}|${tag:--}"$'\n'
                    fi ;;
                lxc.net.*)
                    # raw LXC keys: lxc.net.N.type / .link / .hwaddr
                    [[ "$key" =~ ^lxc\.net\.([0-9]+)\.(type|link|hwaddr)$ ]] || continue
                    idx="${BASH_REMATCH[1]}"
                    case "${BASH_REMATCH[2]}" in
                        type)   [[ "$val" == phys ]] && physlink["$idx"]="${physlink[$idx]:-}" ;;
                        link)   physlink["$idx"]="$val" ;;
                        hwaddr) physmac["$idx"]="${val,,}" ;;
                    esac ;;
            esac
        done < "$f"

        # Resolve phys handoffs: prefer the host netdev, fall back to hwaddr.
        for idx in "${!physlink[@]}"; do
            local ln="${physlink[$idx]}" pci=""
            if [[ -n "$ln" && -e "${SYS_NET}/$ln/device" ]]; then
                pci=$(basename "$(readlink -f "${SYS_NET}/$ln/device")")
                add_owner PCI2VM "$pci" "$vmid" "lxc.net.$idx"
            elif [[ -n "${physmac[$idx]:-}" ]]; then
                add_owner MAC2VM "${physmac[$idx]}" "$vmid" "lxc.net.$idx"
            fi
        done
        PVE_OK=1
    done
    shopt -u nullglob
}

build_guest_index() {
    (( OPT_NOVM )) && return 0
    [[ -d ${PVE_DIR} ]] || return 0
    if [[ ! -r ${PVE_DIR}/qemu-server && ! -r ${PVE_DIR}/lxc ]]; then
        add_issue warn "pve" "${PVE_DIR} is not readable — run as root for guest mapping"
        return 0
    fi
    load_pci_mappings
    scan_qemu_conf
    scan_lxc_conf
}

# =============================================================================
#  Row classification
#  Decides what the "Attached to" cell says for each VF, and is the single
#  source of truth for the health checks that follow.
#
#  States:
#    running / stopped   a guest config claims this VF
#    held                a process holds the vfio group but no config claims it
#    reserved            MAC+VLAN configured, no guest claims it yet
#    free                no MAC at all
# =============================================================================
declare -A VFIO_HELD=()
declare -a R_ID=() R_NAME=() R_SLOT=() R_MARK=() R_STATE=()

# Which vfio groups are actually open by a running process? A VF bound to
# vfio-pci is NOT evidence of use: binding by device id happens at VF creation
# on most hosts. Only an open /dev/vfio/<group> proves something holds it.
scan_vfio_holders() {
    VFIO_HELD=()
    [[ -d /proc ]] || return 0
    local fd tgt grp
    shopt -s nullglob
    for fd in /proc/[0-9]*/fd/*; do
        tgt=$(readlink "$fd" 2>/dev/null) || continue
        [[ "$tgt" == /dev/vfio/* ]] || continue
        grp="${tgt##*/}"
        [[ "$grp" == vfio ]] && continue
        VFIO_HELD["$grp"]=1
    done
    shopt -u nullglob
}

classify_rows() {
    R_ID=(); R_NAME=(); R_SLOT=(); R_MARK=(); R_STATE=()
    local rec pf idx pci mac vlan spoof trust ls rate drv iommu vmid slot vtype conf
    local n=0
    for rec in "${VF_ROWS[@]}"; do
        IFS="$RS" read -r pf idx pci mac vlan spoof trust ls rate drv iommu vmid slot vtype conf <<< "$rec"
        local id name mark state
        if [[ -n "$vmid" ]]; then
            id="$vmid"; [[ "$vtype" == lxc ]] && id="c$vmid"
            name="${VMNAME[$vmid]:-$vmid}"
            state="${VMSTATE[$vmid]:-stopped}"
            mark=" "; (( conf )) && mark="!"
        elif [[ -n "${VFIO_HELD[$iommu]:-}" ]]; then
            id="-"; name="held (no config)"; slot=""; state="held"; mark="!"
        elif [[ "$mac" != "00:00:00:00:00:00" ]]; then
            id="-"; name="reserved"; slot=""; state="reserved"; mark=" "
        else
            id="-"; name="free"; slot=""; state="free"; mark=" "
        fi
        R_ID[n]="$id"; R_NAME[n]="$name"; R_SLOT[n]="$slot"
        R_MARK[n]="$mark"; R_STATE[n]="$state"
        (( n++ ))
    done
}

# =============================================================================
#  Health checks
# =============================================================================
add_issue() { ISS_SEV+=("$1"); ISS_SCOPE+=("$2"); ISS_MSG+=("$3"); }

run_health_checks() {
    local -A macseen=()
    local rec pf idx pci mac vlan spoof trust ls rate drv iommu vmid slot vtype conf
    local n=0 key

    for rec in "${VF_ROWS[@]}"; do
        IFS="$RS" read -r pf idx pci mac vlan spoof trust ls rate drv iommu vmid slot vtype conf <<< "$rec"

        if [[ "$mac" != "00:00:00:00:00:00" ]]; then
            if [[ -n "${macseen[$mac]:-}" ]]; then
                add_issue err "$pf VF$idx" "duplicate MAC $mac, also on ${macseen[$mac]}"
            else
                macseen["$mac"]="$pf VF$idx"
            fi
        fi

        if (( conf )); then
            local all="${PCI2VM[$pci]:-}" desc=""
            for key in $all; do
                local v="${key%%|*}" sl="${key#*|}"
                desc+="${v} (${VMSTATE[$v]:-?}, $sl), "
            done
            add_issue err "$pf VF$idx" "claimed by more than one guest: ${desc%, }"
        fi

        [[ "${R_STATE[$n]}" == held ]] && \
            add_issue err "$pf VF$idx" "vfio group $iommu is open by a process but no guest config claims it"

        [[ "$trust" == on && "$spoof" == off ]] && \
            add_issue err "$pf VF$idx" "trust on with spoofchk off - guest can spoof any MAC or VLAN"

        [[ "$ls" == disable ]] && \
            add_issue warn "$pf VF$idx" "link-state administratively disabled"

        if [[ "$mac" != "00:00:00:00:00:00" && "$vlan" == "-" ]]; then
            add_issue warn "$pf VF$idx" "MAC set but no VLAN, traffic will be untagged"
        fi
        [[ "$mac" == "00:00:00:00:00:00" && -n "$vmid" ]] && \
            add_issue err "$pf VF$idx" "guest $vmid claims this VF but it has no MAC configured"

        (( n++ ))
    done

    local p
    for p in "${!PCI2VM[@]}"; do
        local found=0
        for rec in "${VF_ROWS[@]}"; do
            [[ "$rec" == *"$RS$p$RS"* ]] && { found=1; break; }
        done
        if (( ! found )) && [[ ! -e "${SYS_PCI}/$p" ]]; then
            local owners="${PCI2VM[$p]}"
            add_issue err "guest ${owners%%|*}" "config references $p which is not present on this host"
        fi
    done

    local pfn numvfs totalvfs oper
    for pfn in "${PFS[@]}"; do
        IFS="$RS" read -r _ numvfs totalvfs _ _ _ _ _ _ oper _ _ _ _ <<< "${PF_META[$pfn]}"
        (( numvfs == 0 )) && add_issue info "$pfn" "SR-IOV capable ($totalvfs max) but no VFs enabled"
        [[ "$oper" != up ]] && add_issue info "$pfn" "link is $oper"
    done

    (( ! PVE_OK )) && (( ! OPT_NOVM )) && \
        add_issue warn "guests" "no guest configs found under ${PVE_DIR}, ownership unavailable"
}

# Collapse "ice2 VF6", "ice2 VF7" ... into "ice2 VF6-13"
fmt_range() { [[ "$1" == "$2" ]] && printf '%s' "$1" || printf '%s-%s' "$1" "$2"; }

compress_scopes() {
    local -a scopes=("$@") nums=()
    local prefix="" s ok=1
    for s in "${scopes[@]}"; do
        if [[ "$s" =~ ^(.*VF)([0-9]+)$ ]]; then
            [[ -z "$prefix" ]] && prefix="${BASH_REMATCH[1]}"
            [[ "$prefix" == "${BASH_REMATCH[1]}" ]] || { ok=0; break; }
            nums+=("${BASH_REMATCH[2]}")
        else ok=0; break; fi
    done
    if (( ! ok )) || (( ${#nums[@]} == 0 )); then
        local IFS=' '; printf '%s' "${scopes[*]}"; return
    fi
    mapfile -t nums < <(printf '%s\n' "${nums[@]}" | sort -n)
    local out="" start="" prev="" x
    for x in "${nums[@]}"; do
        if [[ -z "$start" ]]; then start="$x"; prev="$x"; continue; fi
        if (( 10#$x == 10#$prev + 1 )); then prev="$x"; continue; fi
        out+="$(fmt_range "$start" "$prev"),"; start="$x"; prev="$x"
    done
    out+="$(fmt_range "$start" "$prev")"
    printf '%s%s' "$prefix" "$out"
}

# =============================================================================
#  Output buffer and outer frame
# =============================================================================
declare -a BUF=()
STRIPPED=""
emit()  { BUF+=("${1-}"); }
blank() { BUF+=(""); }
rule()  { BUF+=($'\x01'); }
strip_ansi() { local s="${1-}"; STRIPPED="${s//$'\e'\[*([0-9;])m/}"; }

frame_flush() {
    local maxw=0 l pad
    for l in "${BUF[@]}"; do
        [[ "$l" == $'\x01' ]] && continue
        strip_ansi "$l"; (( ${#STRIPPED} > maxw )) && maxw=${#STRIPPED}
    done
    local inner=$(( maxw + 4 ))
    printf '%s%s%s%s%s\n' "$cF" "$D_TL" "$(rep "$inner" "$D_H")" "$D_TR" "$cN"
    for l in "${BUF[@]}"; do
        if [[ "$l" == $'\x01' ]]; then
            printf '%s%s%s%s%s\n' "$cF" "$D_ML" "$(rep "$inner" "$D_MH")" "$D_MR" "$cN"
            continue
        fi
        strip_ansi "$l"
        pad=$(( maxw - ${#STRIPPED} ))
        (( pad < 0 )) && pad=0
        printf '%s%s%s  %s%*s  %s%s%s\n' "$cF" "$D_V" "$cN" "$l" "$pad" "" "$cF" "$D_V" "$cN"
    done
    printf '%s%s%s%s%s\n' "$cF" "$D_BL" "$(rep "$inner" "$D_H")" "$D_BR" "$cN"
    BUF=()
}

# =============================================================================
#  Column sizing driven by actual content
# =============================================================================
compute_widths() {
    local rec pf idx pci mac vlan spoof trust ls rate drv iommu vmid slot vtype conf
    local n=0
    W_VF=3; W_PCI=3; W_MAC=3; W_VLAN=4; W_DRV=6; W_FLG=4
    G_ID=2; G_NAME=4; G_SLOT=0; G_MARK=0
    for rec in "${VF_ROWS[@]}"; do
        IFS="$RS" read -r pf idx pci mac vlan spoof trust ls rate drv iommu vmid slot vtype conf <<< "$rec"
        (( ${#idx} + 2 > W_VF ))  && W_VF=$(( ${#idx} + 2 ))
        (( ${#pci}  > W_PCI ))    && W_PCI=${#pci}
        (( ${#mac}  > W_MAC ))    && W_MAC=${#mac}
        (( ${#vlan} > W_VLAN ))   && W_VLAN=${#vlan}
        (( ${#drv}  > W_DRV ))    && W_DRV=${#drv}
        (( ${#R_ID[n]}   > G_ID ))   && G_ID=${#R_ID[n]}
        (( ${#R_NAME[n]} > G_NAME )) && G_NAME=${#R_NAME[n]}
        (( ${#R_SLOT[n]} > G_SLOT )) && G_SLOT=${#R_SLOT[n]}
        [[ "${R_MARK[n]}" == "!" ]] && G_MARK=1
        (( n++ ))
    done

    SHOW_DRV=1
    [[ "$OPT_LAYOUT" == compact ]] && SHOW_DRV=0
    local tw="${OPT_WIDTH:-$(term_width)}"
    local avail=$(( tw - 8 ))   # outer frame + padding
    [[ "$OPT_LAYOUT" == compact ]] && avail=$(( avail < 74 ? avail : 74 ))
    while :; do
        W_GUEST=$(( 2 + G_ID + 2 + G_NAME ))
        (( G_SLOT )) && W_GUEST=$(( W_GUEST + 2 + G_SLOT ))
        (( G_MARK )) && W_GUEST=$(( W_GUEST + 1 ))
        NCOL=6; (( SHOW_DRV )) && NCOL=7
        TABLE_W=$(( W_VF + W_PCI + W_MAC + W_VLAN + W_FLG + W_GUEST + NCOL * 2 + NCOL + 1 ))
        (( SHOW_DRV )) && TABLE_W=$(( TABLE_W + W_DRV ))
        (( TABLE_W <= avail )) && break
        if (( G_NAME > 10 )); then G_NAME=$(( G_NAME - 1 )); continue; fi
        if (( SHOW_DRV )); then SHOW_DRV=0; continue; fi
        if (( G_SLOT > 0 )); then G_SLOT=0; continue; fi
        break
    done
}

box_line() {  # left mid right
    local out="$1"
    out+=$(rep $(( W_VF + 2 )) "$BX_H")"$2"
    out+=$(rep $(( W_PCI + 2 )) "$BX_H")"$2"
    out+=$(rep $(( W_MAC + 2 )) "$BX_H")"$2"
    out+=$(rep $(( W_VLAN + 2 )) "$BX_H")"$2"
    (( SHOW_DRV )) && out+=$(rep $(( W_DRV + 2 )) "$BX_H")"$2"
    out+=$(rep $(( W_FLG + 2 )) "$BX_H")"$2"
    out+=$(rep $(( W_GUEST + 2 )) "$BX_H")
    emit "${cF}${out}${3}${cN}"
}

cellL() { printf "%-$1s" "$(fit "$1" "$2")"; }
cellR() { printf "%$1s"  "$(fit "$1" "$2")"; }

trow() {  # colour/text pairs, already width-matched
    local out="" c t w a i=0
    local -a W=("$W_VF" "$W_PCI" "$W_MAC" "$W_VLAN")
    (( SHOW_DRV )) && W+=("$W_DRV")
    W+=("$W_FLG" "$W_GUEST")
    local -a A=(l l l r l l l)
    (( SHOW_DRV )) || A=(l l l r l l)
    while (( $# )); do
        c="$1"; t="$2"; shift 2
        w="${W[$i]}"; a="${A[$i]}"
        if [[ "$a" == r ]]; then t=$(cellR "$w" "$t"); else t=$(cellL "$w" "$t"); fi
        out+="${cF}${BX_V}${cN}${c} ${t} ${cN}"
        (( i++ ))
    done
    emit "${out}${cF}${BX_V}${cN}"
}

flags_mask() {
    local m=""
    [[ "$1" == on ]] && m+="S" || m+="$F_OFF"
    [[ "$2" == on ]] && m+="T" || m+="$F_OFF"
    (( ${3:-0} > 0 )) && m+="R" || m+="$F_OFF"
    [[ "$4" == disable ]] && m+="D" || m+="$F_OFF"
    printf '%s' "$m"
}

guest_cell() {  # index
    local n="$1" out glyph
    case "${R_STATE[$n]}" in
        running)  glyph="$G_RUN" ;;
        stopped)  glyph="$G_STOP" ;;
        held)     glyph="$G_STOP" ;;
        reserved) glyph="$G_RSVD" ;;
        *)        glyph="$G_FREE" ;;
    esac
    printf -v out '%s %-*s  %-*s' "$glyph" "$G_ID" "$(fit "$G_ID" "${R_ID[$n]}")" \
        "$G_NAME" "$(fit "$G_NAME" "${R_NAME[$n]}")"
    (( G_SLOT )) && printf -v out '%s  %-*s' "$out" "$G_SLOT" "$(fit "$G_SLOT" "${R_SLOT[$n]}")"
    (( G_MARK )) && printf -v out '%s%s' "$out" "${R_MARK[$n]}"
    printf '%s' "$out"
}

guest_color() {
    case "${R_STATE[$1]}" in
        running)  printf '%s' "$cG" ;;
        stopped)  printf '%s' "$cY" ;;
        held)     printf '%s' "$cR" ;;
        reserved) printf '%s' "$cC" ;;
        *)        printf '%s' "$cD" ;;
    esac
}

vlan_color() {
    [[ "$1" == "-" ]] && { printf '%s' "$cD"; return; }
    case $(( $1 % 5 )) in
        0) printf '%s' "$cY" ;; 1) printf '%s' "$cC" ;;
        2) printf '%s' "$cM" ;; 3) printf '%s' "$cB" ;;
        *) printf '%s' "$cG" ;;
    esac
}

# =============================================================================
#  Sections
# =============================================================================
kv() {  # label value...
    local lbl="$1"; shift
    emit "$(printf '%s%-9s%s %s' "$cLB" "$lbl" "$cN" "$*")"
}

render_title() {
    local pve=""
    [[ -x /usr/bin/pveversion ]] && pve=$(pveversion 2>/dev/null | head -1 | cut -d'(' -f1)
    emit "$(printf '%sSR-IOV STATUS%s   %s%s%s   %s%s%s' \
        "${cW}${cC}" "$cN" "$cW" "$HOSTNAME_S" "$cN" "$cD" "$(date '+%Y-%m-%d %H:%M:%S')" "$cN")"
    emit "$(printf '%skernel %s%s%s' "$cD" "$(uname -r)" "${pve:+ $BUL $pve}" "$cN")"
}

render_master() {
    local entry name kind
    for entry in "${MASTERS[@]}"; do
        name="${entry%%|*}"; kind="${entry#*|}"
        rule
        emit "$(printf '%s%s%s   %s%s%s' "$cHD" "$name" "$cN" "$cD" "$kind" "$cN")"
        case "$kind" in
            bond)   render_bond "$name" ;;
            bridge) render_bridge "$name" ;;
        esac
    done
}

render_bond() {
    local b="$1" f="${PROC_BOND}/$1"
    [[ -r "$f" ]] || return
    local mode mii partner lacp xmit aggid mc
    mode=$(sed -n 's/^Bonding Mode:[[:space:]]*//p' "$f" | head -1)
    mii=$(sed -n 's/^MII Status:[[:space:]]*//p' "$f" | head -1)
    partner=$(sed -n 's/^[[:space:]]*Partner Mac Address:[[:space:]]*//p' "$f" | head -1)
    lacp=$(sed -n 's/^LACP \(active\|rate\):[[:space:]]*//p' "$f" | head -1)
    xmit=$(sed -n 's/^Transmit Hash Policy:[[:space:]]*//p' "$f" | head -1)
    aggid=$(sed -n 's/^[[:space:]]*Aggregator ID:[[:space:]]*//p' "$f" | head -1)
    [[ "$mii" == up ]] && mc="${cG}up${cN}" || mc="${cR}${mii:-?}${cN}"
    kv "status" "$mc ${cD}$BUL${cN} ${mode:-?}${xmit:+ ${cD}$BUL${cN} hash $xmit}${lacp:+ ${cD}$BUL${cN} lacp $lacp}"
    [[ -n "$partner" ]] && kv "partner" "$partner${aggid:+ ${cD}(aggregator $aggid)${cN}}"
    local slave spd smii smc
    while IFS= read -r slave; do
        slave="${slave#Slave Interface: }"
        [[ -z "$slave" ]] && continue
        spd=$(awk -v s="$slave" '$0 ~ "^Slave Interface: "s"$"{f=1;next} f&&/^Slave Interface:/{exit}
              f&&/^Speed:/{sub(/^Speed:[[:space:]]*/,"");print;exit}' "$f")
        smii=$(awk -v s="$slave" '$0 ~ "^Slave Interface: "s"$"{f=1;next} f&&/^Slave Interface:/{exit}
              f&&/^MII Status:/{sub(/^MII Status:[[:space:]]*/,"");print;exit}' "$f")
        [[ "$smii" == up ]] && smc="${cG}up${cN}" || smc="${cR}${smii:-?}${cN}"
        kv "slave" "$(printf '%s%-8s%s %-12s %b' "$cW" "$slave" "$cN" "${spd:-unknown}" "$smc")"
    done < <(grep '^Slave Interface:' "$f")
}

render_bridge() {
    local b="$1" vf stp ports="" p
    vf=$(sysread "${SYS_NET}/$b/bridge/vlan_filtering" "?")
    stp=$(sysread "${SYS_NET}/$b/bridge/stp_state" "?")
    [[ "$vf" == 1 ]] && vf="${cG}on${cN}" || vf="${cD}off${cN}"
    [[ "$stp" == 0 ]] && stp="${cD}off${cN}" || stp="${cG}on${cN}"
    shopt -s nullglob
    for p in "${SYS_NET}/$b/brif/"*; do ports+="$(basename "$p") "; done
    shopt -u nullglob
    kv "status" "vlan-aware $vf ${cD}$BUL${cN} stp $stp"
    kv "ports" "${cW}${ports:-none}${cN}"
}

render_pf_idle() {
    local pf="$1" pci totalvfs oper model
    IFS="$RS" read -r pci _ totalvfs _ _ _ _ _ _ oper _ _ _ _ <<< "${PF_META[$pf]}"
    model="${PF_MODEL[$pf]:-}"
    model="${model#Intel Corporation }"
    emit "$(printf '%s%-6s%s %s%-14s%s %s%-38s%s %slink %s %s no VFs%s' \
        "$cHD" "$pf" "$cN" "$cD" "$pci" "$cN" "$cD" "$(fit 38 "$model")" "$cN" \
        "$cD" "$oper" "$BUL" "$cN")"
}

render_pf_block() {
    local pf="$1"
    local pci numvfs totalvfs master kind esw link numa mtu oper speed duplex drv fw
    IFS="$RS" read -r pci numvfs totalvfs master kind esw link numa mtu oper speed duplex drv fw \
        <<< "${PF_META[$pf]}"
    local model="${PF_MODEL[$pf]:-}"; model="${model#Intel Corporation }"
    local mod; mod=$(pf_driver "$pf")
    local oc; [[ "$oper" == up ]] && oc="${cG}up${cN}" || oc="${cR}${oper}${cN}"
    local spd="-"; [[ "$speed" =~ ^[0-9]+$ ]] && (( speed > 0 )) && spd="$(fmt_speed "$speed")"
    [[ "$numa" == "-1" || -z "$numa" ]] && numa="n/a"

    rule
    emit "$(printf '%s%s%s   %s%s%s   %s%s%s' "$cHD" "$pf" "$cN" \
        "$cC" "$pci" "$cN" "$cD" "$model" "$cN")"
    kv "link" "$oc ${cD}$BUL${cN} ${cW}${spd}${cN}${duplex:+ ${cD}$BUL${cN} $duplex}   ${cLB}master${cN} ${master:-${cD}none${cN}}${kind:+ ${cD}($kind)${cN}}   ${cLB}eswitch${cN} $esw"
    local dev="${cD}driver${cN} ${cW}${mod}${cN}"
    [[ "$drv" != "-" && -n "$drv" ]] && dev+=" $drv"
    [[ "$fw"  != "-" && -n "$fw"  ]] && dev+=" ${cD}$BUL fw${cN} $fw"
    dev+=" ${cD}$BUL numa${cN} $numa ${cD}$BUL mtu${cN} $mtu"
    [[ -n "$link" ]] && dev+=" ${cD}$BUL link-file${cN} $link"
    kv "device" "$dev"

    local rec f_pf n=0 att=0 res=0 free=0 held=0
    for rec in "${VF_ROWS[@]}"; do
        IFS="$RS" read -r f_pf _ <<< "$rec"
        if [[ "$f_pf" == "$pf" ]]; then
            case "${R_STATE[$n]}" in
                running|stopped) (( att++ )) ;;
                held)            (( held++ )) ;;
                reserved)        (( res++ )) ;;
                free)            (( free++ )) ;;
            esac
        fi
        (( n++ ))
    done
    kv "vfs" "${cNUM}${numvfs}${cN}${cD} of ${totalvfs}${cN}   ${cG}${att} attached${cN}   ${cC}${res} reserved${cN}   ${cD}${free} free${cN}$( (( held )) && printf '   %s%d held%s' "$cR" "$held" "$cN")"
}

fmt_speed() {
    local m="$1"
    (( m >= 1000 )) && printf '%s Gb/s' "$(( m / 1000 ))" || printf '%s Mb/s' "$m"
}

render_vf_table() {
    local pf="$1" numvfs
    IFS="$RS" read -r _ numvfs _ _ _ _ _ _ _ _ _ _ _ _ <<< "${PF_META[$pf]}"
    (( numvfs == 0 )) && return

    blank
    box_line "$BX_TL" "$BX_TM" "$BX_TR"
    if (( SHOW_DRV )); then
        trow "$cW" "VF" "$cW" "PCI" "$cW" "MAC" "$cW" "VLAN" "$cW" "Driver" "$cW" "Flg" "$cW" "Attached to"
    else
        trow "$cW" "VF" "$cW" "PCI" "$cW" "MAC" "$cW" "VLAN" "$cW" "Flg" "$cW" "Attached to"
    fi
    box_line "$BX_ML" "$BX_MM" "$BX_MR"

    local rec r_pf idx pci mac vlan spoof trust ls rate drv iommu vmid slot vtype conf
    local n=0 first=1 prev="__" cur mcol vcol dcol fcol gcol flg
    for rec in "${VF_ROWS[@]}"; do
        IFS="$RS" read -r r_pf idx pci mac vlan spoof trust ls rate drv iommu vmid slot vtype conf <<< "$rec"
        if [[ "$r_pf" != "$pf" ]]; then (( n++ )); continue; fi

        cur="${vmid:-${R_STATE[$n]}}"
        (( ! first )) && [[ "$cur" != "$prev" ]] && box_line "$BX_ML" "$BX_MM" "$BX_MR"
        first=0; prev="$cur"

        [[ "$mac" == "00:00:00:00:00:00" ]] && mcol="$cD" || mcol="$cG"
        vcol=$(vlan_color "$vlan")
        [[ "$drv" == "vfio-pci" ]] && dcol="$cC" || dcol="$cD"
        flg=$(flags_mask "$spoof" "$trust" "$rate" "$ls")
        fcol="$cG"; [[ "$spoof" != on ]] && fcol="$cR"; [[ "$trust" == on ]] && fcol="$cY"
        gcol=$(guest_color "$n")

        if (( SHOW_DRV )); then
            trow "$cW" "VF$idx" "$cC" "$pci" "$mcol" "$mac" "$vcol" "$vlan" \
                 "$dcol" "$drv" "$fcol" "$flg" "$gcol" "$(guest_cell "$n")"
        else
            trow "$cW" "VF$idx" "$cC" "$pci" "$mcol" "$mac" "$vcol" "$vlan" \
                 "$fcol" "$flg" "$gcol" "$(guest_cell "$n")"
        fi
        (( n++ ))
    done
    box_line "$BX_BL" "$BX_BM" "$BX_BR"
}

render_summary() {
    local -A vlancount=() seenvm=()
    local total=0 att=0 res=0 free=0 held=0 running=0 stopped=0
    local -a freelist=()
    local rec pf idx pci mac vlan vmid n=0

    for rec in "${VF_ROWS[@]}"; do
        IFS="$RS" read -r pf idx pci mac vlan _ _ _ _ _ _ vmid _ _ _ <<< "$rec"
        (( total++ ))
        [[ "$vlan" != "-" ]] && (( vlancount[$vlan]++ ))
        case "${R_STATE[$n]}" in
            running|stopped) (( att++ )); seenvm["$vmid"]=1 ;;
            held)     (( held++ )) ;;
            reserved) (( res++ )) ;;
            free)     (( free++ )); freelist+=("$pf|VF$idx|$pci") ;;
        esac
        (( n++ ))
    done
    local v
    for v in "${!seenvm[@]}"; do
        # NOTE: must be if/else. `(( running++ )) || (( stopped++ ))` double-counts
        # the first guest, because post-increment returns the OLD value (0 = false).
        if [[ "${VMSTATE[$v]:-stopped}" == running ]]; then (( running++ )); else (( stopped++ )); fi
    done

    rule
    emit "$(printf '%sSUMMARY%s' "$cHD" "$cN")"
    kv "vfs" "${cNUM}${total}${cN} total   ${cG}${att} attached${cN}   ${cC}${res} reserved${cN}   ${cD}${free} free${cN}$( (( held )) && printf '   %s%d held%s' "$cR" "$held" "$cN")"
    kv "guests" "${cNUM}${#seenvm[@]}${cN} with VFs   ${cG}${running} running${cN}   ${cY}${stopped} stopped${cN}"

    if (( ${#vlancount[@]} )); then
        local line="" k
        for k in $(printf '%s\n' "${!vlancount[@]}" | sort -n); do
            line+="$(printf '%s%s%s%s x%-3s' "$(vlan_color "$k")" "$k" "$cN" "$cD" "${vlancount[$k]}")${cN} "
        done
        kv "vlans" "$line"
    fi

    if (( free )); then
        local names="" e nextpf="" nextvf="" nextpci=""
        for e in "${freelist[@]}"; do
            local p="${e%%|*}" rest="${e#*|}"
            names+="${rest%%|*} "
            [[ -z "$nextvf" ]] && { nextpf="$p"; nextvf="${rest%%|*}"; nextpci="${rest#*|}"; }
        done
        kv "free" "${cW}${names}${cN}${cD}(hot-add headroom)${cN}"
        local num="${nextvf#VF}"
        kv "hot-add" "${cD}ip link set${cN} $nextpf ${cD}vf${cN} $num ${cD}mac${cN} <MAC> ${cD}vlan${cN} <VLAN>"
        kv "" "${cD}qm set <VMID> -hostpci0${cN} ${nextpci}${cD},pcie=1${cN}"
    fi
}

render_health() {
    local -a keys=() outsev=() outmsg=() outscope=()
    local i k found j
    for i in "${!ISS_SEV[@]}"; do
        [[ "${ISS_SEV[$i]}" == info ]] && (( ! OPT_VERBOSE )) && continue
        k="${ISS_SEV[$i]}|${ISS_MSG[$i]}"
        found=-1
        for j in "${!keys[@]}"; do [[ "${keys[$j]}" == "$k" ]] && { found=$j; break; }; done
        if (( found >= 0 )); then
            outscope[found]+=" ${ISS_SCOPE[$i]}"
        else
            keys+=("$k"); outsev+=("${ISS_SEV[$i]}")
            outmsg+=("${ISS_MSG[$i]}"); outscope+=("${ISS_SCOPE[$i]}")
        fi
    done

    rule
    if (( ${#keys[@]} == 0 )); then
        emit "$(printf '%sHEALTH%s   %sno problems detected%s' "$cHD" "$cN" "$cG" "$cN")"
        (( OPT_VERBOSE )) || emit "$(printf '%s%s run with -v for informational notes%s' "$cD" "$BUL" "$cN")"
        return
    fi

    emit "$(printf '%sHEALTH%s' "$cHD" "$cN")"
    local w=0 sc
    local -a scopes=()
    for i in "${!keys[@]}"; do
        # shellcheck disable=SC2086
        sc=$(compress_scopes ${outscope[$i]})
        scopes+=("$sc"); (( ${#sc} > w )) && w=${#sc}
    done
    local col gl
    for i in "${!keys[@]}"; do
        case "${outsev[$i]}" in
            err)  col="$cR"; gl="$SEV_ERR" ;;
            warn) col="$cY"; gl="$SEV_WARN" ;;
            *)    col="$cD"; gl="$SEV_INFO" ;;
        esac
        emit "$(printf '%s%s%s %s%-*s%s %s' "$col" "$gl" "$cN" "$cW" "$w" "${scopes[$i]}" "$cN" "${outmsg[$i]}")"
    done
}

render_legend() {
    rule
    emit "$(printf '%sflags%s   %sS%s spoofchk  %sT%s trust  %sR%s rate-limit  %sD%s link-disabled  %s%s off%s' \
        "$cLB" "$cN" "$cG" "$cN" "$cY" "$cN" "$cW" "$cN" "$cR" "$cN" "$cD" "$F_OFF" "$cN")"
    emit "$(printf '%sstate%s   %s%s%s running  %s%s%s stopped  %s%s%s reserved  %s%s%s free  %s!%s see health' \
        "$cLB" "$cN" "$cG" "$G_RUN" "$cN" "$cY" "$G_STOP" "$cN" "$cC" "$G_RSVD" "$cN" \
        "$cD" "$G_FREE" "$cN" "$cR" "$cN")"
    emit "$(printf '%smac%s     1a:PVE#:NIC#:VLAN:VM_HH:VM_LL  %s(1a sr-iov, 2a virtio - display only)%s' \
        "$cLB" "$cN" "$cD" "$cN")"
}

render_by_vm() {
    local -A vmvfs=()
    local rec pf idx pci mac vlan drv vmid slot vtype
    for rec in "${VF_ROWS[@]}"; do
        IFS="$RS" read -r pf idx pci mac vlan _ _ _ _ drv _ vmid slot vtype _ <<< "$rec"
        [[ -z "$vmid" ]] && continue
        vmvfs["$vmid"]+="$slot|$pf|VF$idx|$pci|$mac|$vlan|$drv"$'\n'
    done
    rule
    emit "$(printf '%sBY GUEST%s' "$cHD" "$cN")"
    local v line
    for v in $(printf '%s\n' "${!vmvfs[@]}" | sort -n); do
        local glyph col
        if [[ "${VMSTATE[$v]:-stopped}" == running ]]; then glyph="$G_RUN"; col="$cG"
        else glyph="$G_STOP"; col="$cY"; fi
        blank
        emit "$(printf '%s%s%s %s%-6s%s %s%s%s  %s%s%s' "$col" "$glyph" "$cN" \
            "$cW" "$v" "$cN" "$cW" "${VMNAME[$v]:-$v}" "$cN" \
            "$cD" "${VMTYPE[$v]:-?}/${VMSTATE[$v]:-?}" "$cN")"
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            IFS='|' read -r slot pf idx pci mac vlan drv <<< "$line"
            emit "$(printf '   %s%-10s%s %-5s %-5s %s%-13s%s %s%-18s%s %svlan%s %-5s %s%s%s' \
                "$cD" "$slot" "$cN" "$pf" "$idx" "$cC" "$pci" "$cN" "$cG" "$mac" "$cN" \
                "$cD" "$cN" "$vlan" "$cD" "$drv" "$cN")"
        done <<< "${vmvfs[$v]}"
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local nk nm nmac nbr ntag
            IFS='|' read -r nk nm nmac nbr ntag <<< "$line"
            emit "$(printf '   %s%-10s %-5s %-5s %-13s %-18s vlan %-5s %s%s' \
                "$cD" "$nk" "$nm" "" "" "$nmac" "$ntag" "$nbr" "$cN")"
        done <<< "${VMNICS[$v]:-}"
    done
}

# =============================================================================
#  JSON
# =============================================================================
jesc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }

emit_json() {
    local first_pf=1 first_vf first_i=1
    printf '{\n'
    printf '  "generator": {"name":"sriov-status.sh","version":"%s"},\n' "$VERSION"
    printf '  "host": "%s",\n' "$(jesc "$HOSTNAME_S")"
    printf '  "timestamp": "%s",\n' "$(date -Is)"
    printf '  "pfs": [\n'
    local pf pci numvfs totalvfs master kind esw link numa mtu oper speed duplex drv fw
    for pf in "${PFS[@]}"; do
        (( first_pf )) || printf ',\n'; first_pf=0
        IFS="$RS" read -r pci numvfs totalvfs master kind esw link numa mtu oper speed duplex drv fw \
            <<< "${PF_META[$pf]}"
        printf '    {"name":"%s","pci":"%s","driver":"%s","firmware":"%s",' \
            "$(jesc "$pf")" "$pci" "$(jesc "$drv")" "$(jesc "$fw")"
        printf '"model":"%s","numvfs":%s,"totalvfs":%s,' \
            "$(jesc "${PF_MODEL[$pf]:-}")" "$numvfs" "$totalvfs"
        printf '"master":"%s","master_kind":"%s","eswitch":"%s","link_file":"%s",' \
            "$(jesc "$master")" "$(jesc "$kind")" "$esw" "$(jesc "$link")"
        printf '"numa":%s,"mtu":%s,"operstate":"%s","speed_mbps":%s,"duplex":"%s",\n' \
            "${numa:-0}" "${mtu:-0}" "$oper" \
            "$([[ "$speed" =~ ^[0-9]+$ ]] && echo "$speed" || echo null)" "$duplex"
        printf '     "vfs": ['
        first_vf=1
        local rec r_pf idx vpci mac vlan spoof trust ls rate vdrv iommu vmid slot vtype conf n=0
        for rec in "${VF_ROWS[@]}"; do
            IFS="$RS" read -r r_pf idx vpci mac vlan spoof trust ls rate vdrv iommu vmid slot vtype conf <<< "$rec"
            if [[ "$r_pf" != "$pf" ]]; then (( n++ )); continue; fi
            (( first_vf )) || printf ', '; first_vf=0
            printf '{"index":%s,"pci":"%s","mac":"%s","vlan":%s,' \
                "$idx" "$vpci" "$mac" "$([[ "$vlan" =~ ^[0-9]+$ ]] && echo "$vlan" || echo null)"
            printf '"spoofchk":"%s","trust":"%s","link_state":"%s","max_tx_rate":%s,' \
                "$spoof" "$trust" "$ls" "${rate:-0}"
            printf '"driver":"%s","iommu_group":"%s","state":"%s",' \
                "$vdrv" "$iommu" "${R_STATE[$n]}"
            if [[ -n "$vmid" ]]; then
                printf '"guest":{"id":%s,"name":"%s","type":"%s","state":"%s","slot":"%s","conflict":%s}}' \
                    "$vmid" "$(jesc "${VMNAME[$vmid]:-}")" "$vtype" "${VMSTATE[$vmid]:-stopped}" \
                    "$(jesc "$slot")" "$([[ "$conf" == 1 ]] && echo true || echo false)"
            else
                printf '"guest":null}'
            fi
            (( n++ ))
        done
        printf ']}'
    done
    printf '\n  ],\n  "issues": [\n'
    local i
    for i in "${!ISS_SEV[@]}"; do
        (( first_i )) || printf ',\n'; first_i=0
        printf '    {"severity":"%s","scope":"%s","message":"%s"}' \
            "${ISS_SEV[$i]}" "$(jesc "${ISS_SCOPE[$i]}")" "$(jesc "${ISS_MSG[$i]}")"
    done
    printf '\n  ]\n}\n'
}

# =============================================================================
#  Orchestration
# =============================================================================
collect_all() {
    PFS=(); VF_ROWS=(); MASTERS=(); PF_META=(); PF_MODEL=()
    PCI2VM=(); MAC2VM=(); VMNAME=(); VMSTATE=(); VMTYPE=(); VMNICS=(); PCIMAP=()
    ISS_SEV=(); ISS_SCOPE=(); ISS_MSG=(); PVE_OK=0
    HOSTNAME_S=$(hostname -s 2>/dev/null || cat /proc/sys/kernel/hostname)

    discover_pfs
    (( ${#PFS[@]} == 0 )) && return 1
    collect_pf_meta
    build_guest_index
    collect_vfs
    scan_vfio_holders
    classify_rows
    run_health_checks
    return 0
}

render_all() {
    compute_widths
    render_title
    render_master
    local pf idle=() numvfs
    for pf in "${PFS[@]}"; do
        IFS="$RS" read -r _ numvfs _ _ _ _ _ _ _ _ _ _ _ _ <<< "${PF_META[$pf]}"
        if (( numvfs == 0 )); then idle+=("$pf"); continue; fi
        render_pf_block "$pf"
        render_vf_table "$pf"
    done
    if (( ${#idle[@]} )); then
        rule
        emit "$(printf '%sIDLE INTERFACES%s' "$cHD" "$cN")"
        for pf in "${idle[@]}"; do render_pf_idle "$pf"; done
    fi
    (( OPT_BYVM )) && render_by_vm
    render_summary
    render_health
    render_legend
    frame_flush
}

watch_loop() {
    local -a prev=() cur=()
    local restore=""
    have tput && tput smcup 2>/dev/null && restore="tput rmcup"
    # shellcheck disable=SC2064
    trap "stty echo 2>/dev/null; ${restore:-true}; printf '\n'; exit 0" INT TERM
    stty -echo 2>/dev/null
    while :; do
        collect_all || die "no SR-IOV capable network interfaces found"
        mapfile -t cur < <(render_all)
        printf '\e[H\e[2J'
        local i
        for i in "${!cur[@]}"; do
            if (( ${#prev[@]} )) && [[ "${prev[$i]:-}" != "${cur[$i]}" ]]; then
                printf '\e[7m%s\e[0m\n' "${cur[$i]}"
            else
                printf '%s\n' "${cur[$i]}"
            fi
        done
        printf '%s  watch %ss - press q to quit%s\n' "$cD" "$OPT_WATCH_INT" "$cN"
        prev=("${cur[@]}")
        local key
        if read -r -N1 -t "$OPT_WATCH_INT" key 2>/dev/null; then
            [[ "$key" == q || "$key" == Q ]] && break
        fi
    done
    stty echo 2>/dev/null
    [[ -n "$restore" ]] && $restore
}

main() {
    parse_args "$@"
    init_theme
    if (( OPT_WATCH )); then watch_loop; exit 0; fi
    collect_all || die "no SR-IOV capable network interfaces found on this host"
    if (( OPT_JSON )); then emit_json; exit 0; fi
    render_all
}

main "$@"