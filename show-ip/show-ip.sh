#!/usr/bin/env bash
#===============================================================================
#  show-ip  —  Host NIC + Docker network / container IPv4 & port overview
#
#  1. HOST NICs        : IPv4/CIDR, MAC, MTU, state, driver, speed, and which
#                        docker ipvlan/macvlan networks use the NIC as parent.
#  2. DOCKER NETWORKS  : driver, mode (ipvlan l2/l3, macvlan bridge, bridge,
#                        overlay...), host interface / parent NIC, subnet, gw.
#  3. CONTAINERS       : one numbered row per (container x network) — a
#                        container attached to two networks gets entries 1.
#                        and 2. — with IP, MAC, gateway and PORTS.
#                        Ports = published NAT mappings (bridge) PLUS sockets
#                        actually listening inside the container's netns, which
#                        is the only way to see ports of IPVLAN/MACVLAN
#                        containers (they are never "-p" published).
#
#  Install :  sudo ./show-ip --install      ->  /usr/local/bin/show-ip
#  Usage   :  show-ip [options]             (works from any directory)
#===============================================================================
set -uo pipefail

VERSION="2.0"
PROG="${0##*/}"

#--------------------------------- options ------------------------------------
USE_COLOR="auto"          # auto | always | never
ASCII=0                   # plain ASCII borders
SHOW_ALL=0                # include stopped containers
SHOW_VETH=0               # include veth*/virtual leaf interfaces
SCAN_PORTS=1              # peek into container netns for listening sockets
DEPS_AUTO=1               # auto-install missing iproute2
ONLY=""                   # host | net | ctr
WATCH_INT=0
DO_INSTALL=0

usage() {
cat <<EOF
${PROG} v${VERSION} — host + docker IPv4 / port overview

USAGE
  ${PROG} [options]

OPTIONS
  -a, --all            include stopped containers
  -v, --veth           also list veth*/virtual leaf interfaces
  -P, --no-ports       skip the in-namespace listening-port scan (faster)
      --skip-deps      do not auto-install iproute2; run degraded instead of
                       aborting when 'ip' / 'ss' are missing
  -H, --host-only      only the host NIC table
  -N, --net-only       only the docker network table
  -C, --containers     only the container table
  -w, --watch [SEC]    refresh every SEC seconds (default 5)
  -n, --no-color       disable colour (also honours NO_COLOR=1)
  -A, --ascii          ASCII borders instead of box-drawing glyphs
      --install        copy this script to /usr/local/bin/show-ip
  -h, --help           this help
  -V, --version        print version

DEPENDENCIES
  iproute2 ('ip' and 'ss') is required and is installed automatically via
  apt-get / dnf / yum / zypper / pacman / apk when missing. If that install
  fails, ${PROG} ABORTS rather than printing an incomplete picture.
  util-linux ('nsenter') is optional: without it, listening ports of
  IPVLAN/MACVLAN containers cannot be read.

NOTES
  * Listening ports of IPVLAN / MACVLAN containers are read from the container's
    own network namespace (nsenter + ss) and require root -> run with sudo for
    the complete picture.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--all)        SHOW_ALL=1 ;;
    -v|--veth)       SHOW_VETH=1 ;;
    -P|--no-ports)   SCAN_PORTS=0 ;;
    --skip-deps)     DEPS_AUTO=0 ;;
    -H|--host-only)  ONLY="host" ;;
    -N|--net-only)   ONLY="net" ;;
    -C|--containers) ONLY="ctr" ;;
    -n|--no-color)   USE_COLOR="never" ;;
    -A|--ascii)      ASCII=1 ;;
    -w|--watch)      WATCH_INT=5; [[ "${2:-}" =~ ^[0-9]+$ ]] && { WATCH_INT="$2"; shift; } ;;
    --install)       DO_INSTALL=1 ;;
    -h|--help)       usage; exit 0 ;;
    -V|--version)    echo "${PROG} ${VERSION}"; exit 0 ;;
    *) echo "unknown option: $1  (try --help)" >&2; exit 1 ;;
  esac
  shift
done

#--------------------------- utf-8 width detection ----------------------------
# Column padding relies on ${#str} counting CHARACTERS, not bytes. Under a
# non-UTF-8 locale the box glyphs would break alignment, so try to move to a
# UTF-8 locale; if none exists, silently fall back to pure ASCII output.
_utf8_ok() { local t=$'\xe2\x86\x92'; [[ ${#t} -eq 1 ]]; }
if ! _utf8_ok; then
  for _l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8 en_GB.UTF-8; do
    export LC_ALL="$_l"; _utf8_ok && break; unset LC_ALL
  done
fi
_utf8_ok || ASCII=1

if (( ASCII )); then
  G_PUB="->"; G_LSN="=>"; G_TREE="+-"; G_BAR=">>"; G_DOT="-"; G_DASH="-"
else
  G_PUB="\u2192"; G_LSN="\u21e2"; G_TREE="\u2514\u2500"; G_BAR="\u258c"; G_DOT="\u00b7"; G_DASH="\u2014"
  G_PUB=$'\u2192'; G_LSN=$'\u21e2'; G_TREE=$'\u2514\u2500'; G_BAR=$'\u258c'; G_DOT=$'\u00b7'; G_DASH=$'\u2014'
fi

#--------------------------------- install ------------------------------------
if (( DO_INSTALL )); then
  src="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/$(basename "${BASH_SOURCE[0]}")"
  dst="/usr/local/bin/show-ip"
  if install -m 0755 "$src" "$dst" 2>/dev/null || sudo install -m 0755 "$src" "$dst"; then
    echo "installed -> $dst      (now just type:  show-ip)"
  else
    echo "install failed. try:  sudo install -m 755 '$src' '$dst'" >&2; exit 1
  fi
  exit 0
fi

#---------------------------- dependency preflight ----------------------------
have() { command -v "$1" >/dev/null 2>&1; }
SUDO=""
if [[ ${EUID:-$(id -u)} -ne 0 ]] && have sudo; then SUDO="sudo"; fi

die()  { printf '\n%s%sABORT:%s %s\n\n' "${B:-}" "${BRED:-}" "${R:-}" "$1" >&2; exit 1; }
warn() { printf '%s%sWARN:%s %s\n'        "${B:-}" "${BYEL:-}" "${R:-}" "$1" >&2; }

pkg_mgr() {
  local m
  for m in apt-get dnf yum zypper pacman apk; do have "$m" && { printf '%s' "$m"; return 0; }; done
  return 1
}

DEP_LOG=""
install_iproute2() {                       # exit status is NOT trusted; we re-verify
  local mgr=$1
  DEP_LOG=$(mktemp /tmp/show-ip-deps.XXXXXX 2>/dev/null) || DEP_LOG="/tmp/show-ip-deps.$$"
  printf '%s   installing iproute2 via %s (needs root, output -> %s) ...%s\n' \
         "${D:-}" "$mgr" "$DEP_LOG" "${R:-}" >&2
  { case "$mgr" in
    apt-get) $SUDO apt-get update -qq >/dev/null 2>&1
             $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iproute2 ;;
    dnf)     $SUDO dnf install -y -q iproute ;;
    yum)     $SUDO yum install -y -q iproute ;;
    zypper)  $SUDO zypper --non-interactive install iproute2 ;;
    pacman)  $SUDO pacman -Sy --noconfirm iproute2 ;;
    apk)     $SUDO apk add --no-cache iproute2 iproute2-ss 2>/dev/null \
             || $SUDO apk add --no-cache iproute2 ;;
    *)       return 1 ;;
  esac; } >"$DEP_LOG" 2>&1
  hash -r 2>/dev/null || true
}

ensure_deps() {
  local -a missing=()
  have ip || missing+=("ip")
  (( SCAN_PORTS )) && { have ss || missing+=("ss"); }
  (( ${#missing[@]} == 0 )) && return 0

  if (( ! DEPS_AUTO )); then
    warn "missing ${missing[*]} (package iproute2) — --skip-deps given, output will be incomplete"
    return 0
  fi

  if [[ ${EUID:-$(id -u)} -ne 0 && -z "$SUDO" ]]; then
    die "missing ${missing[*]} (package iproute2), and neither root nor sudo is available.
       install it manually and re-run, e.g.:
         apt-get install -y iproute2      # debian / ubuntu
         dnf install -y iproute           # rhel / fedora / rocky / alma
         apk add iproute2                 # alpine"
  fi

  local mgr
  if ! mgr=$(pkg_mgr); then
    die "missing ${missing[*]} (package iproute2) and no supported package manager was found
       (looked for apt-get, dnf, yum, zypper, pacman, apk).
       install iproute2 manually, then re-run ${PROG}."
  fi

  install_iproute2 "$mgr"

  local -a still=()
  have ip || still+=("ip")
  (( SCAN_PORTS )) && { have ss || still+=("ss"); }
  if (( ${#still[@]} )); then
    die "iproute2 install FAILED — still missing: ${still[*]}
       check the package manager, repository config and network access, or install by hand:
         $mgr  <install>  iproute2
       then re-run ${PROG}.   (or use '${PROG} --skip-deps' to run with reduced output)

       --- last lines of ${DEP_LOG} ---
$(tail -n 12 "$DEP_LOG" 2>/dev/null | sed 's/^/       /')"
  fi
  printf '%s   iproute2 installed OK.%s\n' "${D:-}" "${R:-}" >&2
  rm -f "$DEP_LOG" 2>/dev/null
  return 0
}

#--------------------------------- colours ------------------------------------
setup_colors() {
  local on=0
  case "$USE_COLOR" in
    always) on=1 ;;
    never)  on=0 ;;
    auto)   [[ -t 1 && -z "${NO_COLOR:-}" ]] && on=1 ;;
  esac
  if (( on )); then
    R=$'\e[0m'; B=$'\e[1m'; D=$'\e[2m'
    RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLU=$'\e[34m'
    MAG=$'\e[35m'; CYN=$'\e[36m'; WHT=$'\e[97m'
    BRED=$'\e[91m'; BGRN=$'\e[92m'; BYEL=$'\e[93m'; BBLU=$'\e[94m'
    BMAG=$'\e[95m'; BCYN=$'\e[96m'
  else
    R=""; B=""; D=""; RED=""; GRN=""; YEL=""; BLU=""; MAG=""; CYN=""; WHT=""
    BRED=""; BGRN=""; BYEL=""; BBLU=""; BMAG=""; BCYN=""
  fi
}

#------------------------------- table engine ---------------------------------
SEP=$'\x1f'
ROWSEP=$'\x1e'
ANSI_RE=$'\e\\[[0-9;]*m'
declare -a TBL=()

vislen() {                                  # printable width, ANSI-aware
  local s=$1
  while [[ $s == *$'\e['* ]]; do
    [[ $s =~ $ANSI_RE ]] || break
    s=${s/"${BASH_REMATCH[0]}"/}
  done
  printf '%s' "${#s}"
}

declare -a SPLIT=()
split_row() {                                # newline-safe field splitter
  local s=$1
  SPLIT=()
  while [[ $s == *"$SEP"* ]]; do
    SPLIT+=("${s%%"$SEP"*}")
    s=${s#*"$SEP"}
  done
  SPLIT+=("$s")
}

tbl_init() { TBL=(); }
tbl_rule() { TBL+=("$ROWSEP"); }
tbl_row() {                                  # cells may contain newlines
  local -a a=(); local x
  for x in "$@"; do [[ -z "$x" ]] && x="-"; a+=("$x"); done
  local IFS="$SEP"; TBL+=("${a[*]}")
}

tbl_render() {
  local -a widths=() cells
  local ncols=0 row i l line
  for row in "${TBL[@]}"; do
    [[ "$row" == "$ROWSEP" ]] && continue
    split_row "$row"; cells=("${SPLIT[@]}")
    (( ${#cells[@]} > ncols )) && ncols=${#cells[@]}
    for i in "${!cells[@]}"; do
      while IFS= read -r line; do
        l=$(vislen "$line")
        (( l > ${widths[i]:-0} )) && widths[i]=$l
      done <<<"${cells[i]}"
    done
  done
  (( ncols == 0 )) && return
  for ((i=0;i<ncols;i++)); do : "${widths[i]:=1}"; done

  local TL TR BL BR HZ VT TT BT LT RT XX
  if (( ASCII )); then
    TL=+ TR=+ BL=+ BR=+ HZ=- VT='|' TT=+ BT=+ LT=+ RT=+ XX=+
  else
    TL=┌ TR=┐ BL=└ BR=┘ HZ=─ VT=│ TT=┬ BT=┴ LT=├ RT=┤ XX=┼
  fi

  _hline() {                                  # $1 left $2 mid $3 right
    local out="$1" j k
    for ((j=0;j<ncols;j++)); do
      for ((k=0;k<widths[j]+2;k++)); do out+="$HZ"; done
      (( j < ncols-1 )) && out+="$2"
    done
    printf '%s%s%s\n' "$D" "${out}${3}" "$R"
  }

  _prow() {                                   # $1 row string, $2 header flag
    local rs=$1 hdr=${2:-0}
    local -a c=(); split_row "$rs"; c=("${SPLIT[@]}")
    local -A M=(); local -a H=()
    local j n h=1 line
    for ((j=0;j<ncols;j++)); do
      n=0
      while IFS= read -r line; do M["$j,$n"]="$line"; n=$((n+1)); done <<<"${c[j]:-}"
      H[j]=$n; (( n > h )) && h=$n
    done
    local li out txt pad
    for ((li=0;li<h;li++)); do
      out="${D}${VT}${R}"
      for ((j=0;j<ncols;j++)); do
        txt="${M[$j,$li]:-}"
        pad=$(( widths[j] - $(vislen "$txt") )); (( pad < 0 )) && pad=0
        if (( hdr )); then
          out+=" ${B}${WHT}${txt}${R}$(printf "%${pad}s" "") ${D}${VT}${R}"
        else
          out+=" ${txt}$(printf "%${pad}s" "") ${D}${VT}${R}"
        fi
      done
      printf '%s\n' "$out"
    done
  }

  _hline "$TL" "$TT" "$TR"
  local first=1
  for row in "${TBL[@]}"; do
    if [[ "$row" == "$ROWSEP" ]]; then _hline "$LT" "$XX" "$RT"; continue; fi
    if (( first )); then _prow "$row" 1; _hline "$LT" "$XX" "$RT"; first=0
    else _prow "$row" 0; fi
  done
  _hline "$BL" "$BT" "$BR"
}

title() {
  printf '\n%s%s%s %s%s\n' "$B" "$BCYN" "$G_BAR" "$1" "$R"
}
note() { printf '%s   %s%s\n' "$D" "$1" "$R"; }

banner() {
  local host when kern w=69
  host="$(hostname 2>/dev/null || echo unknown)"
  when="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  kern="$(uname -r 2>/dev/null)"
  local l1="IPv4 ADDRESS LIST  ${G_DASH}  HOST NICs ${G_DOT} DOCKER NETWORKS ${G_DOT} CONTAINERS"
  local l2="host: ${host}    kernel: ${kern}"
  local l3="${when}    (${PROG} v${VERSION})"
  local TLc TRc BLc BRc HZc VTc
  if (( ASCII )); then TLc=+ TRc=+ BLc=+ BRc=+ HZc== VTc='|'
  else TLc=╔ TRc=╗ BLc=╚ BRc=╝ HZc=═ VTc=║; fi
  local bar="" i
  for ((i=0;i<w;i++)); do bar+="$HZc"; done
  printf '%s%s%s%s%s%s\n' "$B" "$BBLU" "$TLc" "$bar" "$TRc" "$R"
  local ln pad
  for ln in "$l1" "$l2" "$l3"; do
    pad=$(( w - 2 - $(vislen "$ln") )); (( pad < 0 )) && pad=0
    printf '%s%s%s%s %s%s %s%s%s\n' "$B" "$BBLU" "$VTc" "$R" "$ln" "$(printf "%${pad}s" "")" "$B$BBLU" "$VTc" "$R"
  done
  printf '%s%s%s%s%s%s\n' "$B" "$BBLU" "$BLc" "$bar" "$BRc" "$R"
}

#------------------------------- docker probing -------------------------------
DOCKER=""
DOCKER_STATE="missing"                # missing | denied | ok
NSENTER=""

detect_docker() {
  command -v docker >/dev/null 2>&1 || { DOCKER_STATE="missing"; return; }
  if docker info >/dev/null 2>&1; then DOCKER="docker"; DOCKER_STATE="ok"; return; fi
  if sudo -n docker info >/dev/null 2>&1; then DOCKER="sudo docker"; DOCKER_STATE="ok"; return; fi
  DOCKER_STATE="denied"
}

detect_nsenter() {
  command -v nsenter >/dev/null 2>&1 || return 1
  command -v ss      >/dev/null 2>&1 || return 1
  if [[ $EUID -eq 0 ]]; then NSENTER="nsenter"; return 0; fi
  sudo -n true 2>/dev/null && { NSENTER="sudo nsenter"; return 0; }
  return 1
}

docker_hint() {
  case "$DOCKER_STATE" in
    missing) note "docker not installed / not in PATH." ;;
    denied)  note "cannot reach the docker daemon (permission denied) — try:  sudo $PROG" ;;
  esac
}

#------------------------------ network metadata ------------------------------
declare -A NET_DRIVER=() NET_MODE=() NET_SUBNET=() NET_GW=() NET_IFACE=()
declare -A NET_PARENT=() NET_NCTR=() NET_SCOPE=() IFACE_OWNER=() PARENT_OF=()
declare -a NET_ORDER=()

sanitize() { local s=${1:-}; s=${s//<no value>/}; printf '%s' "$s"; }

collect_networks() {
  [[ "$DOCKER_STATE" == "ok" ]] || return
  local fmt='{{.Name}}|{{.Driver}}|{{.Scope}}|{{.Internal}}|{{index .Options "ipvlan_mode"}}|{{index .Options "macvlan_mode"}}|{{index .Options "parent"}}|{{index .Options "com.docker.network.bridge.name"}}|{{range .IPAM.Config}}{{.Subnet}}~{{.Gateway}}^{{end}}|{{len .Containers}}|{{.Id}}'
  local ids; ids=$($DOCKER network ls -q 2>/dev/null); [[ -z "$ids" ]] && return
  local name drv scope internal ivm mvm parent brname ipam nctr id
  # shellcheck disable=SC2086
  while IFS='|' read -r name drv scope internal ivm mvm parent brname ipam nctr id; do
    [[ -z "$name" ]] && continue
    ivm=$(sanitize "$ivm"); mvm=$(sanitize "$mvm")
    parent=$(sanitize "$parent"); brname=$(sanitize "$brname")

    local mode iface=""
    case "$drv" in
      ipvlan)  mode="${ivm:-l2}" ;;
      macvlan) mode="${mvm:-bridge}" ;;
      bridge)  mode="bridge"
               if   [[ "$name" == "bridge" ]]; then iface="docker0"
               elif [[ -n "$brname"        ]]; then iface="$brname"
               else iface="br-${id:0:12}"; fi ;;
      overlay) mode="vxlan" ;;
      host)    mode="host-ns" ;;
      none|null) mode="null" ;;
      *)       mode="-" ;;
    esac
    [[ -n "$parent" ]] && iface="$parent"
    [[ "$internal" == "true" ]] && mode="${mode},internal"

    local subs="" gws="" e
    local -a arr=(); IFS='^' read -r -a arr <<<"$ipam"
    for e in "${arr[@]}"; do
      [[ -z "$e" ]] && continue
      subs+="${subs:+$'\n'}${e%%~*}"
      gws+="${gws:+$'\n'}${e#*~}"
    done

    NET_DRIVER["$name"]="$drv"
    NET_MODE["$name"]="$mode"
    NET_SUBNET["$name"]="${subs:--}"
    NET_GW["$name"]="${gws:--}"
    NET_IFACE["$name"]="${iface:--}"
    NET_PARENT["$name"]="$parent"
    NET_NCTR["$name"]="$nctr"
    NET_SCOPE["$name"]="$scope"
    NET_ORDER+=("$name")

    [[ -n "$iface" && -z "$parent" ]] && IFACE_OWNER["$iface"]="$name"
    [[ -n "$parent" ]] && PARENT_OF["$parent"]="${PARENT_OF[$parent]:+${PARENT_OF[$parent]}, }${name}(${drv}/${mode})"
  done < <($DOCKER network inspect --format "$fmt" $ids 2>/dev/null)
}

#--------------------------------- host NICs ----------------------------------
iface_addrs() {
  local n=$1
  if command -v ip >/dev/null 2>&1; then
    ip -o -4 addr show dev "$n" 2>/dev/null | awk '{print $4}'
  elif command -v ifconfig >/dev/null 2>&1; then
    ifconfig "$n" 2>/dev/null | awk '/inet /{for(i=1;i<=NF;i++) if($i=="inet"){print $(i+1)}}'
  fi
}
iface_mac()   { cat "/sys/class/net/$1/address"   2>/dev/null; }
iface_mtu()   { cat "/sys/class/net/$1/mtu"       2>/dev/null; }
iface_state() { cat "/sys/class/net/$1/operstate" 2>/dev/null; }
iface_speed() {
  local s; s=$(cat "/sys/class/net/$1/speed" 2>/dev/null)
  [[ -z "$s" || "$s" == "-1" ]] && { echo "-"; return; }
  if (( s >= 1000 )); then echo "$((s/1000))Gb/s"; else echo "${s}Mb/s"; fi
}
iface_driver() {
  local n=$1 d
  [[ "$n" == "lo" ]] && { echo "loopback"; return; }
  [[ -d "/sys/class/net/$n/bridge"  ]] && { echo "bridge";  return; }
  [[ -d "/sys/class/net/$n/bonding" ]] && { echo "bond";    return; }
  [[ -f "/sys/class/net/$n/tun_flags" ]] && { echo "tun/tap"; return; }
  [[ -f "/proc/net/vlan/$n" ]] && { echo "802.1q"; return; }
  if [[ -L "/sys/class/net/$n/device/driver" ]]; then
    d=$(readlink -f "/sys/class/net/$n/device/driver"); echo "${d##*/}"; return
  fi
  echo "-"
}

section_host() {
  title "HOST NICs"
  tbl_init
  tbl_row "NIC" "STATE" "IPv4 / CIDR" "MAC ADDRESS" "MTU" "DRIVER" "SPEED" "ROLE"
  local n st col addrs mac role shown=0
  while IFS= read -r n; do
    [[ -n "${IFACE_OWNER[$n]:-}" ]] && continue        # shown in docker table
    if (( ! SHOW_VETH )); then
      case "$n" in veth*|br-*|docker*|virbr*|cni*|flannel*|kube*|tunl*|nomad*|ifb*|dummy*|gre*|erspan*|ip6tnl*|sit*) continue ;; esac
    fi
    st=$(iface_state "$n"); [[ -z "$st" ]] && st="?"
    case "$st" in
      up)      col="${BGRN}up${R}" ;;
      down)    col="${BRED}down${R}" ;;
      unknown) col="${YEL}unknown${R}" ;;
      *)       col="$st" ;;
    esac
    addrs=$(iface_addrs "$n")
    [[ -z "$addrs" ]] && addrs="${D}(no ipv4)${R}" || addrs="${BGRN}${addrs}${R}"
    mac=$(iface_mac "$n"); [[ -z "$mac" || "$mac" == "00:00:00:00:00:00" ]] && mac="-"
    role="-"
    [[ -n "${PARENT_OF[$n]:-}" ]] && role="${BMAG}parent of${R} ${PARENT_OF[$n]}"
    tbl_row "${B}${n}${R}" "$col" "$addrs" "$mac" "$(iface_mtu "$n")" \
            "$(iface_driver "$n")" "$(iface_speed "$n")" "$role"
    shown=$((shown+1))
  done < <(ls -1 /sys/class/net 2>/dev/null | sort)
  (( shown == 0 )) && tbl_row "-" "-" "-" "-" "-" "-" "-" "-"
  tbl_render
  command -v ip >/dev/null 2>&1 || note "'ip' not found — install iproute2 for CIDR/prefix output."
}

#------------------------------ docker networks -------------------------------
drv_color() {
  case "$1" in
    ipvlan)    printf '%s%s%s' "$BMAG" "$1" "$R" ;;
    macvlan)   printf '%s%s%s' "$MAG"  "$1" "$R" ;;
    bridge)    printf '%s%s%s' "$BBLU" "$1" "$R" ;;
    overlay)   printf '%s%s%s' "$BYEL" "$1" "$R" ;;
    host|none) printf '%s%s%s' "$D"    "$1" "$R" ;;
    *)         printf '%s' "$1" ;;
  esac
}
mode_color() {
  case "$1" in
    l2|l3|l3s) printf '%s%s%s' "$BMAG" "$1" "$R" ;;
    bridge)    printf '%s%s%s' "$BBLU" "$1" "$R" ;;
    vxlan)     printf '%s%s%s' "$BYEL" "$1" "$R" ;;
    *)         printf '%s' "$1" ;;
  esac
}

section_networks() {
  title "DOCKER NETWORKS"
  if [[ "$DOCKER_STATE" != "ok" ]]; then docker_hint; return; fi
  if (( ${#NET_ORDER[@]} == 0 )); then note "no docker networks."; return; fi
  tbl_init
  tbl_row "DOCKER NETWORK" "DRIVER" "MODE" "HOST IFACE / PARENT" "SUBNET" "GATEWAY" "SCOPE" "CTRS"
  local name drv mode ifc nc rest
  for name in "${NET_ORDER[@]}"; do
    drv="${NET_DRIVER[$name]}"; mode="${NET_MODE[$name]}"; rest="${mode#"${mode%%,*}"}"
    if [[ -n "${NET_PARENT[$name]}" ]]; then
      ifc="${BMAG}${NET_PARENT[$name]}${R} ${D}(parent)${R}"
    else
      ifc="${NET_IFACE[$name]}"
    fi
    nc="${NET_NCTR[$name]:-0}"
    [[ "$nc" == "0" ]] && nc="${D}0${R}" || nc="${BGRN}${nc}${R}"
    tbl_row "${B}${name}${R}" "$(drv_color "$drv")" "$(mode_color "${mode%%,*}")${rest}" \
            "$ifc" "${BGRN}${NET_SUBNET[$name]}${R}" "${NET_GW[$name]}" \
            "${NET_SCOPE[$name]}" "$nc"
  done
  tbl_render
}

#-------------------------------- containers ----------------------------------
listen_ports() {                 # $1 = pid  ->  lines "tcp|80|0.0.0.0"
  local pid=$1
  [[ -z "$pid" || "$pid" == "0" ]] && return
  [[ -n "$NSENTER" ]] || return
  $NSENTER -t "$pid" -n ss -tuln 2>/dev/null | awk '
    ($1=="tcp" || $1=="udp") {
      la=$5; n=split(la,a,":"); p=a[n];
      addr=substr(la, 1, length(la)-length(p)-1);
      if (p ~ /^[0-9]+$/) print $1"|"p"|"addr
    }' | sort -u -t'|' -k2,2n
}

fmt_pub() {                      # "0.0.0.0:8080,:::8080," -> "*:8080"
  local out="" b hip hpo
  local -a bs=(); IFS=',' read -r -a bs <<<"${1:-}"
  for b in "${bs[@]}"; do
    [[ -z "$b" ]] && continue
    hip=${b%:*}; hpo=${b##*:}
    [[ "$hip" == "::" || "$hip" == *":"* ]] && continue      # skip v6 dupes
    [[ "$hip" == "0.0.0.0" || -z "$hip" ]] && hip="*"
    [[ "$out" == *"${hip}:${hpo}"* ]] && continue
    out+="${out:+, }${hip}:${hpo}"
  done
  printf '%s' "$out"
}

section_containers() {
  title "DOCKER CONTAINERS — NETWORKS, IPs & PORTS"
  if [[ "$DOCKER_STATE" != "ok" ]]; then docker_hint; return; fi

  local ids
  if (( SHOW_ALL )); then ids=$($DOCKER ps -aq 2>/dev/null); else ids=$($DOCKER ps -q 2>/dev/null); fi
  if [[ -z "$ids" ]]; then note "no containers."; return; fi

  local fmt='{{.Id}}|{{.Name}}|{{.State.Status}}|{{.State.Pid}}|{{range $k,$v := .NetworkSettings.Networks}}{{$k}}~{{$v.IPAddress}}~{{$v.IPPrefixLen}}~{{$v.MacAddress}}~{{$v.Gateway}}^{{end}}|{{range $p,$c := .NetworkSettings.Ports}}{{$p}}={{range $c}}{{.HostIp}}:{{.HostPort}},{{end}}^{{end}}'

  tbl_init
  tbl_row "#" "CONTAINER" "STATE" "DOCKER NETWORK" "DRV/MODE" "IP ADDRESS" "MAC ADDRESS" "GATEWAY" "PORTS"

  local cid cname cstate cpid nets ports
  # shellcheck disable=SC2086
  while IFS='|' read -r cid cname cstate cpid nets ports; do
    [[ -z "$cid" ]] && continue
    cname=${cname#/}

    unset PUB; declare -A PUB=()
    local -a parr=(); IFS='^' read -r -a parr <<<"$ports"
    local p
    for p in "${parr[@]}"; do
      [[ -z "$p" ]] && continue
      PUB["${p%%=*}"]="${p#*=}"
    done

    local lports=""
    (( SCAN_PORTS )) && [[ "$cstate" == "running" ]] && lports=$(listen_ports "$cpid")

    local scol
    case "$cstate" in
      running)     scol="${BGRN}running${R}" ;;
      exited|dead) scol="${BRED}${cstate}${R}" ;;
      paused)      scol="${BYEL}paused${R}" ;;
      *)           scol="${YEL}${cstate}${R}" ;;
    esac

    local -a narr=(); IFS='^' read -r -a narr <<<"$nets"
    local idx=0 e nname nip npfx nmac ngw drv mode ipcell pcell k hp proto pno baddr disp label

    for e in "${narr[@]}"; do
      [[ -z "$e" ]] && continue
      idx=$((idx+1))
      IFS='~' read -r nname nip npfx nmac ngw <<<"$e"
      drv="${NET_DRIVER[$nname]:-?}"; mode="${NET_MODE[$nname]:-?}"

      if [[ -n "$nip" ]]; then ipcell="${BGRN}${nip}${R}${D}/${npfx}${R}"
      else                     ipcell="${D}(none)${R}"; fi

      pcell=""
      if [[ "$drv" == "host" ]]; then
        pcell="${D}shares the host netns${R}"
      elif [[ "$drv" == "null" || "$drv" == "none" ]]; then
        pcell="${D}no networking${R}"
      else
        # 1) NAT-published ports (bridge / overlay only — ipvlan is never -p mapped)
        if [[ "$drv" == "bridge" || "$drv" == "overlay" || "$drv" == "?" ]]; then
          while IFS= read -r k; do
            [[ -z "$k" ]] && continue
            hp=$(fmt_pub "${PUB[$k]}")
            if [[ -n "$hp" ]]; then pcell+="${pcell:+$'\n'}${BYEL}${hp}${R} ${G_PUB} ${k}"
            else                    pcell+="${pcell:+$'\n'}${D}${k} (not published)${R}"; fi
          done < <( (( ${#PUB[@]} )) && printf '%s\n' "${!PUB[@]}" | sort -t/ -k1,1n )
        fi
        # 2) sockets really listening inside the container netns
        if [[ -n "$lports" ]]; then
          while IFS='|' read -r proto pno baddr; do
            [[ -z "$pno" ]] && continue
            [[ "$pcell" == *"${pno}/${proto}"* ]] && continue
            case "$baddr" in
              0.0.0.0|'*'|'::'|'[::]'|'')  disp="${nip:+${nip}:}${pno}" ;;
              127.0.0.1|'[::1]')           (( idx > 1 )) && continue
                                           disp="127.0.0.1:${pno}" ;;
              "$nip")                      disp="${nip}:${pno}" ;;
              *)                           continue ;;   # bound to another net's IP
            esac
            pcell+="${pcell:+$'\n'}${BCYN}${G_LSN} ${disp}${R}${D}/${proto}${R}"
          done <<<"$lports"
        fi
        if [[ -z "$pcell" ]]; then
          if   (( ! SCAN_PORTS ));                            then pcell="${D}(scan off)${R}"
          elif [[ -z "$NSENTER" && "$cstate" == "running" ]]; then pcell="${D}(need root)${R}"
          else                                                     pcell="${D}-${R}"; fi
        fi
      fi

      label="${B}${cname}${R}"; (( idx > 1 )) && label="${D}${G_TREE}${R} ${cname}"
      tbl_row "${BYEL}${idx}.${R}" "$label" "$scol" "${B}${nname}${R}" \
              "$(drv_color "$drv")${D}/${R}$(mode_color "${mode%%,*}")" \
              "$ipcell" "${nmac:--}" "${ngw:--}" "$pcell"
    done
    (( idx == 0 )) && tbl_row "1." "${B}${cname}${R}" "$scol" "${D}(no network)${R}" "-" "-" "-" "-" "-"
    tbl_rule
  done < <($DOCKER inspect --format "$fmt" $ids 2>/dev/null)

  local last=$(( ${#TBL[@]} - 1 ))
  (( last >= 0 )) && [[ "${TBL[last]}" == "$ROWSEP" ]] && unset "TBL[$last]"
  tbl_render

  printf '%s   legend:  %s%s%s published host:port to container port    %s%s%s socket listening inside the container netns    %s%s%s same container, extra network%s\n' \
    "$D" "$BYEL" "$G_PUB" "$D" "$BCYN" "$G_LSN" "$D" "$D" "$G_TREE" "$D" "$R"
  (( SCAN_PORTS )) && [[ -z "$NSENTER" ]] && \
    note "run with sudo to reveal listening ports (needed for IPVLAN/MACVLAN containers)"
  return 0
}

#---------------------------------- summary -----------------------------------
section_summary() {
  local nnic nnet nrun ntot
  nnic=$(ls -1 /sys/class/net 2>/dev/null | grep -Ecv '^(veth|br-|docker|ifb|dummy|tunl|gre|erspan|ip6tnl|sit)' )
  nnet=${#NET_ORDER[@]}
  if [[ "$DOCKER_STATE" == "ok" ]]; then
    nrun=$($DOCKER ps  -q 2>/dev/null | wc -l | tr -d ' ')
    ntot=$($DOCKER ps -aq 2>/dev/null | wc -l | tr -d ' ')
  else nrun=0; ntot=0; fi
  printf '\n%s   %s host NICs  %s  %s docker networks  %s  %s/%s containers running%s\n' \
         "$D" "$nnic" "$G_DOT" "$nnet" "$G_DOT" "$nrun" "$ntot" "$R"
}

#------------------------------------ main ------------------------------------
main() {
  setup_colors
  detect_docker
  if (( SCAN_PORTS )); then
    detect_nsenter || { NSENTER=""; have nsenter || warn "nsenter not found (package util-linux) — container listening ports unavailable"; }
  fi
  banner
  collect_networks
  case "$ONLY" in
    host) section_host ;;
    net)  section_networks ;;
    ctr)  section_containers ;;
    *)    section_host; section_networks; section_containers; section_summary ;;
  esac
  echo
}

setup_colors
ensure_deps

if (( WATCH_INT > 0 )); then
  USE_COLOR="always"; setup_colors        # colours needed in this shell too
  trap 'printf "\e[?25h\n"; exit 0' INT TERM
  printf '\e[?25l'
  while :; do
    out="$(main)"
    printf '\e[H\e[2J%s\n%s   refreshing every %ss — Ctrl-C to quit%s\n' \
           "$out" "$D" "$WATCH_INT" "$R"
    sleep "$WATCH_INT"
  done
else
  main
fi
