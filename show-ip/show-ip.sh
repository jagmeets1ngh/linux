#!/usr/bin/env bash
#===============================================================================
#  show-ip  —  Host NIC + Docker network / container IPv4 & port Overview
#
#  1. HOST NICs        : IPv4/CIDR, MAC, MTU, state, driver, speed, and which
#                        docker ipvlan/macvlan networks use the NIC as parent.
#  2. DOCKER NETWORKS  : driver, mode (ipvlan l2/l3, macvlan bridge, bridge,
#                        overlay...), host interface / parent NIC, subnet, gw.
#  3. CONTAINERS       : grouped by STACK (compose project / swarm namespace).
#                        One tall table row per stack; inside it each container
#                        is numbered 1., 2., 3. ... and each container gets one
#                        sub-block per bind IP: loopback first, then one block
#                        per attached docker network with that network's IP,
#                        gateway and only the ports reachable on that IP.
#                        Ports = published NAT mappings (bridge) PLUS sockets
#                        actually listening inside the container's netns, which
#                        is the only way to see ports of IPVLAN/MACVLAN
#                        containers (they are never "-p" published).
#
#  Install :  sudo ./show-ip --install      ->  /usr/local/bin/show-ip
#  Usage   :  show-ip [options]             (works from any directory)
#===============================================================================
set -uo pipefail

VERSION="3.1"
PROG="${0##*/}"

#--------------------------------- options ------------------------------------
USE_COLOR="auto"          # auto | always | never
ASCII=0                   # plain ASCII borders
SHOW_ALL=0                # include stopped containers
SHOW_VETH=0               # include veth*/virtual leaf interfaces
SCAN_PORTS=1              # peek into container netns for listening sockets
DEPS_AUTO=1               # auto-install missing iproute2
SHOW_MAC=1                # container MAC column
SHOW_LOOPBACK=0           # 127.0.0.1-bound sockets: hidden unless -L
LB_HIDDEN=0
STACK_COUNT=0
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
  -M, --no-mac         drop the container MAC column (narrower table)
  -L, --loopback       also show 127.0.0.1-bound sockets (hidden by default:
                       they are unreachable from outside the container)
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
    -M|--no-mac)     SHOW_MAC=0 ;;
    -L|--loopback)   SHOW_LOOPBACK=1 ;;
    -l|--no-loopback) SHOW_LOOPBACK=0 ;;
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

declare -a TBL_ALIGN=()
tbl_align() { TBL_ALIGN[$1]="$2"; }      # $1 col index, $2 = l | c | r

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

tbl_init() { TBL=(); TBL_ALIGN=(); }
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
    local li out txt pad lpad rpad pre post
    for ((li=0;li<h;li++)); do
      out="${D}${VT}${R}"
      for ((j=0;j<ncols;j++)); do
        txt="${M[$j,$li]:-}"
        pad=$(( widths[j] - $(vislen "$txt") )); (( pad < 0 )) && pad=0
        lpad=0; rpad=$pad
        case "${TBL_ALIGN[j]:-l}" in
          c) lpad=$(( pad / 2 )); rpad=$(( pad - lpad )) ;;
          r) lpad=$pad; rpad=0 ;;
        esac
        pre=$(printf "%${lpad}s" ""); post=$(printf "%${rpad}s" "")
        if (( hdr )); then
          out+=" ${pre}${B}${WHT}${txt}${R}${post} ${D}${VT}${R}"
        else
          out+=" ${pre}${txt}${post} ${D}${VT}${R}"
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

#------------------------------- system facts ---------------------------------
os_pretty() {
  local v=""
  [[ -r /etc/os-release ]] && v=$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null)
  [[ -z "$v" ]] && v="$(uname -s 2>/dev/null)"
  printf '%s %s' "${v:-unknown}" "$(uname -m 2>/dev/null)"
}
uptime_str() {
  local u="" s d h m
  u=$(uptime -p 2>/dev/null); u=${u#up }
  if [[ -z "$u" && -r /proc/uptime ]]; then
    s=$(cut -d' ' -f1 /proc/uptime 2>/dev/null); s=${s%.*}
    d=$(( s/86400 )); h=$(( (s%86400)/3600 )); m=$(( (s%3600)/60 ))
    (( d )) && u="${d}d "
    u+="${h}h ${m}m"
  fi
  printf '%s' "${u:--}"
}
load_str() {
  local l n
  l=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
  n=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null)
  printf '%s  (%s cpu)' "${l:--}" "${n:-?}"
}
mem_str() {
  local t a
  t=$(awk '/^MemTotal:/{print $2}'     /proc/meminfo 2>/dev/null)
  a=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
  [[ -z "$t" ]] && { printf '%s' "-"; return; }
  [[ -z "$a" ]] && a=0
  awk -v t="$t" -v a="$a" 'BEGIN{printf "%.1fG used / %.1fG", (t-a)/1048576, t/1048576}'
}
docker_ver() {
  local v=""
  case "$DOCKER_STATE" in
    ok)      v=$($DOCKER version --format '{{.Server.Version}}' 2>/dev/null)
             [[ -z "$v" ]] && v=$(docker --version 2>/dev/null | sed -e 's/^Docker version //' -e 's/,.*$//') ;;
    denied)  printf '%s' "daemon unreachable"; return ;;
    *)       printf '%s' "not installed"; return ;;
  esac
  printf '%s' "${v:-unknown}"
}

banner() {
  local HALF=37 W=$(( 37*2 + 2 )) i
  local TLc TRc BLc BRc HZc VTc LTc RTc SHZ ell
  if (( ASCII )); then
    TLc=+ TRc=+ BLc=+ BRc=+ HZc== VTc='|' LTc=+ RTc=+ SHZ=- ell="..."
  else
    TLc=╔ TRc=╗ BLc=╚ BRc=╝ HZc=═ VTc=║ LTc=╟ RTc=╢ SHZ=─ ell="…"
  fi
  local bar="" sbar=""
  for ((i=0;i<W+2;i++)); do bar+="$HZc"; sbar+="$SHZ"; done

  _bl() {                              # one framed line, content may hold ANSI
    local c=$1 pad
    pad=$(( W - $(vislen "$c") )); (( pad < 0 )) && pad=0
    printf '%s%s%s %s%s %s%s%s\n' "$B$BBLU" "$VTc" "$R" "$c" \
           "$(printf "%${pad}s" "")" "$B$BBLU" "$VTc" "$R"
  }
  _kv() {                              # $1 label $2 value -> HALF-wide cell
    local lab=$1 val=$2 lab7 pad maxv
    printf -v lab7 '%-7s' "$lab"
    maxv=$(( HALF - 8 ))
    (( ${#val} > maxv )) && val="${val:0:$((maxv-1))}${ell}"
    pad=$(( HALF - 8 - ${#val} )); (( pad < 0 )) && pad=0
    printf '%s%s%s %s%s%s%s' "$D" "$lab7" "$R" "$BCYN" "$val" "$R" "$(printf "%${pad}s" "")"
  }

  local t="IPv4 ADDRESS LIST   ${G_DOT}   HOST NICs ${G_DOT} DOCKER NETWORKS ${G_DOT} CONTAINERS"
  local lp=$(( (W - ${#t}) / 2 )); (( lp < 0 )) && lp=0

  printf '%s%s%s%s%s\n' "$B$BBLU" "$TLc" "$bar" "$TRc" "$R"
  _bl "$(printf "%${lp}s" "")${B}${BYEL}${t}${R}"
  printf '%s%s%s%s%s\n' "$B$BBLU" "$LTc" "$sbar" "$RTc" "$R"
  _bl "$(_kv HOST   "$(hostname 2>/dev/null || echo unknown)")  $(_kv OS     "$(os_pretty)")"
  _bl "$(_kv KERNEL "$(uname -r 2>/dev/null)")  $(_kv UPTIME "$(uptime_str)")"
  _bl "$(_kv DOCKER "$(docker_ver)")  $(_kv LOAD   "$(load_str)")"
  _bl "$(_kv TIME   "$(date '+%Y-%m-%d %H:%M:%S %Z')")  $(_kv MEMORY "$(mem_str)")"
  printf '%s%s%s%s%s\n' "$B$BBLU" "$BLc" "$bar" "$BRc" "$R"
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
  tbl_row "DOCKER NETWORK" "DRIVER" "MODE" "HOST IFACE / PARENT" "SUBNET" "GATEWAY" "SCOPE" "CONTAINERS"
  tbl_align 7 c
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

is_loopback() { case "$1" in 127.0.0.1|127.*|'[::1]'|'::1') return 0 ;; *) return 1 ;; esac; }
is_wildcard() { case "$1" in 0.0.0.0|'*'|'::'|'[::]'|'') return 0 ;; *) return 1 ;; esac; }

#--- one TALL table row per stack: cells are newline-joined column blocks ------
Cstack=""; Cctr=""; Cstate=""; Cnet=""; Cmode=""; Cip=""; Cmac=""; Cgw=""; Cport=""
BLK_N=0; STACK_LABEL=""; CTR_LABEL=""; STATE_LABEL=""; CFIRST=1

_blk_reset() {
  Cstack=""; Cctr=""; Cstate=""; Cnet=""
  Cmode=""; Cip=""; Cmac=""; Cgw=""; Cport=""; BLK_N=0
}
_blk_add() {                     # 9 column values for ONE visual line
  local sep=""; (( BLK_N > 0 )) && sep=$'\n'
  Cstack+="${sep}$1"; Cctr+="${sep}$2";  Cstate+="${sep}$3"
  Cnet+="${sep}$4";   Cmode+="${sep}$5"; Cip+="${sep}$6"
  Cmac+="${sep}$7";   Cgw+="${sep}$8";   Cport+="${sep}$9"
  BLK_N=$((BLK_N+1))
}
_blk_flush() {                   # emit the accumulated stack as one table row
  (( BLK_N == 0 )) && return 0
  if (( SHOW_MAC )); then
    tbl_row "$Cstack" "$Cctr" "$Cstate" "$Cnet" "$Cmode" "$Cip" "$Cmac" "$Cgw" "$Cport"
  else
    tbl_row "$Cstack" "$Cctr" "$Cstate" "$Cnet" "$Cmode" "$Cip" "$Cgw" "$Cport"
  fi
  tbl_rule
  _blk_reset
}

emit_block() {   # $1 net $2 mode $3 ip $4 mac $5 gw $6 port-lines(\n separated)
  local net=$1 mode=$2 ip=$3 mac=$4 gw=$5 pl=$6
  local bfirst=1 line s_st s_ctr s_state s_net s_mode s_ip s_mac s_gw
  [[ -z "$pl" ]] && pl="${D}-${R}"
  while IFS= read -r line; do
    s_st=""; s_ctr=""; s_state=""
    s_net=""; s_mode=""; s_ip=""; s_mac=""; s_gw=""
    (( BLK_N == 0 )) && s_st="$STACK_LABEL"          # stack name: top-left only
    if (( bfirst )); then
      s_net="$net"; s_mode="$mode"; s_ip="$ip"; s_mac="$mac"; s_gw="$gw"
      if (( CFIRST )); then s_ctr="$CTR_LABEL"; s_state="$STATE_LABEL"; fi
    fi
    _blk_add "$s_st" "$s_ctr" "$s_state" "$s_net" "$s_mode" "$s_ip" "$s_mac" "$s_gw" "$line"
    bfirst=0
  done <<<"$pl"
  CFIRST=0
}

ports_for_net() {   # $1 driver $2 this network's IP   (uses PUB + lports)
  local drv=$1 nip=$2 out="" k hp proto pno baddr disp
  if [[ "$drv" == "bridge" || "$drv" == "overlay" || "$drv" == "?" ]]; then
    while IFS= read -r k; do
      [[ -z "$k" ]] && continue
      hp=$(fmt_pub "${PUB[$k]}")
      if [[ -n "$hp" ]]; then out+="${out:+$'\n'}${BYEL}${hp}${R} ${G_PUB} ${k}"
      else                    out+="${out:+$'\n'}${D}${k} (not published)${R}"; fi
    done < <( (( ${#PUB[@]} )) && printf '%s\n' "${!PUB[@]}" | sort -t/ -k1,1n )
  fi
  if [[ -n "$lports" ]]; then
    while IFS='|' read -r proto pno baddr; do
      [[ -z "$pno" ]] && continue
      [[ "$out" == *"${pno}/${proto}"* ]] && continue
      if   is_loopback "$baddr"; then continue                      # own block
      elif is_wildcard "$baddr"; then disp="${nip:+${nip}:}${pno}"
      elif [[ "$baddr" == "$nip" ]]; then disp="${nip}:${pno}"
      else continue; fi                                # bound to another net IP
      out+="${out:+$'\n'}${BCYN}${G_LSN} ${disp}${R}${D}/${proto}${R}"
    done <<<"$lports"
  fi
  printf '%s' "$out"
}

section_containers() {
  title "DOCKER CONTAINERS — STACKS, NETWORKS, IPs & PORTS"
  if [[ "$DOCKER_STATE" != "ok" ]]; then docker_hint; return 0; fi

  local ids
  if (( SHOW_ALL )); then ids=$($DOCKER ps -aq 2>/dev/null); else ids=$($DOCKER ps -q 2>/dev/null); fi
  if [[ -z "$ids" ]]; then note "no containers."; return 0; fi

  local fmt='{{.Id}}|{{.Name}}|{{.State.Status}}|{{.State.Pid}}|{{range $k,$v := .NetworkSettings.Networks}}{{$k}}~{{$v.IPAddress}}~{{$v.IPPrefixLen}}~{{$v.MacAddress}}~{{$v.Gateway}}^{{end}}|{{range $p,$c := .NetworkSettings.Ports}}{{$p}}={{range $c}}{{.HostIp}}:{{.HostPort}},{{end}}^{{end}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.stack.namespace"}}'

  local -a REC=()
  # shellcheck disable=SC2086
  mapfile -t REC < <($DOCKER inspect --format "$fmt" $ids 2>/dev/null)
  if (( ${#REC[@]} == 0 )); then note "no containers."; return 0; fi

  # ---- order: stack (compose project / swarm namespace), then container name
  local -a ORDER=()
  mapfile -t ORDER < <(
    for i in "${!REC[@]}"; do
      IFS='|' read -r r_id r_name r_state r_pid r_nets r_ports r_proj r_ns <<<"${REC[i]}"
      r_name=${r_name#/}
      r_proj=$(sanitize "$r_proj"); r_ns=$(sanitize "$r_ns")
      r_stack="$r_proj"; [[ -z "$r_stack" ]] && r_stack="$r_ns"
      # NB: field separator must NOT be whitespace, or empty stack names collapse
      if [[ -z "$r_stack" ]]; then printf '1%s%s%s%s%s%s\n' "$SEP" "$SEP" "$r_name" "$SEP" "$i" ""
      else                         printf '0%s%s%s%s%s%s\n' "$SEP" "$r_stack" "$SEP" "$r_name" "$SEP" "$i"; fi
    done | sort -t"$SEP" -f -k1,1 -k2,2 -k3,3
  )

  tbl_init
  if (( SHOW_MAC )); then
    tbl_row "STACK" "CONTAINER" "STATE" "DOCKER NETWORK" "DRV/MODE" "IP ADDRESS" "MAC ADDRESS" "GATEWAY" "PORTS"
  else
    tbl_row "STACK" "CONTAINER" "STATE" "DOCKER NETWORK" "DRV/MODE" "IP ADDRESS" "GATEWAY" "PORTS"
  fi

  local entry grp key nm i prev="__none__"
  local cid cname cstate cpid nets ports proj ns lports scol
  local -a narr=() parr=()
  local e nname nip npfx nmac ngw drv mode ipcell pcell p proto pno baddr lb

  _blk_reset
  for entry in "${ORDER[@]}"; do
    IFS="$SEP" read -r grp key nm i <<<"$entry"

    if [[ "${grp}:${key}" != "$prev" ]]; then          # ---- new stack group
      _blk_flush
      prev="${grp}:${key}"
      [[ "$grp" == "0" ]] && STACK_COUNT=$((STACK_COUNT+1))
      if [[ "$grp" == "1" ]]; then STACK_LABEL="${D}(standalone)${R}"
      else                         STACK_LABEL="${B}${BMAG}${key}${R}"; fi
    fi

    IFS='|' read -r cid cname cstate cpid nets ports proj ns <<<"${REC[i]}"
    cname=${cname#/}

    case "$cstate" in
      running)     scol="${BGRN}running${R}" ;;
      exited|dead) scol="${BRED}${cstate}${R}" ;;
      paused)      scol="${BYEL}paused${R}" ;;
      *)           scol="${YEL}${cstate}${R}" ;;
    esac
    CTR_LABEL="${B}${cname}${R}"; STATE_LABEL="$scol"; CFIRST=1

    unset PUB; declare -A PUB=()
    parr=(); IFS='^' read -r -a parr <<<"$ports"
    for p in "${parr[@]}"; do
      [[ -z "$p" ]] && continue
      PUB["${p%%=*}"]="${p#*=}"
    done

    lports=""
    (( SCAN_PORTS )) && [[ "$cstate" == "running" ]] && lports=$(listen_ports "$cpid")

    # ---- loopback-bound sockets: own block (only with -L), else just counted
    if (( ! SHOW_LOOPBACK )) && [[ -n "$lports" ]]; then
      while IFS='|' read -r proto pno baddr; do
        [[ -n "$pno" ]] && is_loopback "$baddr" && LB_HIDDEN=$((LB_HIDDEN+1))
      done <<<"$lports"
    fi
    if (( SHOW_LOOPBACK )) && [[ -n "$lports" ]]; then
      lb=""
      while IFS='|' read -r proto pno baddr; do
        [[ -z "$pno" ]] && continue
        is_loopback "$baddr" || continue
        lb+="${lb:+$'\n'}${D}${G_LSN} 127.0.0.1:${pno}/${proto}${R}"
      done <<<"$lports"
      [[ -n "$lb" ]] && emit_block "${D}loopback${R}" "${D}host-local${R}" \
                                   "${D}127.0.0.1/8${R}" "-" "-" "$lb"
    fi

    # ---- one block per attached docker network
    narr=(); IFS='^' read -r -a narr <<<"$nets"
    local nblocks=0
    for e in "${narr[@]}"; do
      [[ -z "$e" ]] && continue
      nblocks=$((nblocks+1))
      IFS='~' read -r nname nip npfx nmac ngw <<<"$e"
      drv="${NET_DRIVER[$nname]:-?}"; mode="${NET_MODE[$nname]:-?}"

      if [[ -n "$nip" ]]; then ipcell="${BGRN}${nip}${R}${D}/${npfx}${R}"
      else                     ipcell="${D}(none)${R}"; fi

      if [[ "$drv" == "host" ]]; then
        pcell="${D}shares the host netns${R}"
      elif [[ "$drv" == "null" || "$drv" == "none" ]]; then
        pcell="${D}no networking${R}"
      else
        pcell=$(ports_for_net "$drv" "$nip")
        if [[ -z "$pcell" ]]; then
          if   (( ! SCAN_PORTS ));                            then pcell="${D}(scan off)${R}"
          elif [[ -z "$NSENTER" && "$cstate" == "running" ]]; then pcell="${D}(need root)${R}"
          else                                                     pcell="${D}-${R}"; fi
        fi
      fi
      emit_block "${B}${nname}${R}" "$(drv_color "$drv")${D}/${R}$(mode_color "${mode%%,*}")" \
                 "$ipcell" "${nmac:--}" "${ngw:--}" "$pcell"
    done
    (( nblocks == 0 )) && emit_block "${D}(no network)${R}" "-" "${D}(none)${R}" "-" "-" "${D}-${R}"
  done
  _blk_flush

  local last=$(( ${#TBL[@]} - 1 ))
  (( last >= 0 )) && [[ "${TBL[last]}" == "$ROWSEP" ]] && unset "TBL[$last]"
  tbl_render

  printf '%s   legend:  %s%s%s published host:port to container port    %s%s%s socket listening inside the container netns    stacks = compose project / swarm namespace%s\n' \
    "$D" "$BYEL" "$G_PUB" "$D" "$BCYN" "$G_LSN" "$D" "$R"
  (( LB_HIDDEN > 0 )) && note "${LB_HIDDEN} loopback-bound socket(s) hidden — they are container-internal only (-L to show)"
  (( SCAN_PORTS )) && [[ -z "$NSENTER" ]] && \
    note "run with sudo to reveal listening ports (needed for IPVLAN/MACVLAN containers)"
  return 0
}

#---------------------------------- summary -----------------------------------
section_summary() {
  local nnic nnet nrun ntot
  plu() { if (( $1 == 1 )); then printf '%s %s' "$1" "$2"; else printf '%s %ss' "$1" "$2"; fi; }
  nnic=$(ls -1 /sys/class/net 2>/dev/null | grep -Ecv '^(veth|br-|docker|ifb|dummy|tunl|gre|erspan|ip6tnl|sit)' )
  nnet=${#NET_ORDER[@]}
  if [[ "$DOCKER_STATE" == "ok" ]]; then
    nrun=$($DOCKER ps  -q 2>/dev/null | wc -l | tr -d ' ')
    ntot=$($DOCKER ps -aq 2>/dev/null | wc -l | tr -d ' ')
  else nrun=0; ntot=0; fi
  printf '\n%s   %s  %s  %s  %s  %s  %s  %s/%s containers running%s\n' \
         "$D" "$(plu "$nnic" "host NIC")" "$G_DOT" "$(plu "$nnet" "docker network")" \
         "$G_DOT" "$(plu "$STACK_COUNT" "stack")" "$G_DOT" "$nrun" "$ntot" "$R"
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
