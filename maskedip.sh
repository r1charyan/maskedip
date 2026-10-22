#!/usr/bin/env bash
# =============================================================================
#  MaskedIP - automatic Tor IP rotation
#  Asks Tor for a fresh identity (new exit IP) at a user-defined interval.
#
#  Usage:  sudo ./maskedip.sh            (interactive)
#          sudo ./maskedip.sh -i 30      (rotate every 30 seconds)
#          ./maskedip.sh --help
# =============================================================================
set -uo pipefail

VERSION="1.0.0"
APP="maskedip"

CONTROL_HOST="${MASKEDIP_CONTROL_HOST:-127.0.0.1}"
CONTROL_PORT="${MASKEDIP_CONTROL_PORT:-9051}"
SOCKS_ADDR="${MASKEDIP_SOCKS:-127.0.0.1:9050}"
TORRC="${MASKEDIP_TORRC:-/etc/tor/torrc}"
CONF_FILE="/etc/maskedip.conf"
SERVICE="maskedip.service"
MARK_BEGIN="# >>> MaskedIP >>>"
MARK_END="# <<< MaskedIP <<<"
MIN_INTERVAL=10        # Tor rate-limits NEWNYM to roughly once per 10 seconds
DEFAULT_INTERVAL=60

COOKIE_PATHS=(
  /run/tor/control.authcookie
  /var/run/tor/control.authcookie
  /var/lib/tor/control_authcookie
  /var/lib/tor/control.authcookie
)
IP_URLS=(
  "https://api.ipify.org"
  "https://icanhazip.com"
  "https://ifconfig.me/ip"
)

# ---------- output helpers ---------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_CYN=$'\e[36m'; C_RST=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_RST=""
fi
ts()   { date '+%F %T'; }
info() { printf '%s %s[INFO]%s %s\n' "$(ts)" "$C_CYN" "$C_RST" "$*"; }
ok()   { printf '%s %s[ OK ]%s %s\n' "$(ts)" "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s %s[WARN]%s %s\n' "$(ts)" "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%s %s[FAIL]%s %s\n' "$(ts)" "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

banner() {
  printf '%s' "$C_CYN"
  cat <<'BANNER'
  __  __           _            _ ___ ____
 |  \/  | __ _ ___| | _____  __| |_ _|  _ \
 | |\/| |/ _` / __| |/ / _ \/ _` || || |_) |
 | |  | | (_| \__ \   <  __/ (_| || ||  __/
 |_|  |_|\__,_|___/_|\_\___|\__,_|___|_|
BANNER
  printf '%s  v%s\n Masked IP, rotated automatically through Tor\n by ARYAN PARASHAR (r1charyan)\n\n' "$C_RST" "$VERSION"
}

usage() {
  cat <<EOF
MaskedIP v${VERSION} - rotate your Tor exit IP automatically

Usage: $APP [options]

  -i, --interval SECONDS   Seconds between IP changes (min ${MIN_INTERVAL})
  -n, --count N            Stop after N rotations (default: 0 = run forever)
  -o, --once               Rotate once and exit
  -s, --status             Show Tor / service / IP status
  -d, --daemon             Non-interactive mode (used by the systemd service)
      --set-interval SEC   Change the interval of the installed service (root)
      --prepare            Install dependencies and configure Tor (root)
  -h, --help               Show this help
  -v, --version            Show version

Examples:
  sudo ./maskedip.sh                  # interactive
  sudo ./maskedip.sh -i 30            # new IP every 30 seconds
  sudo ./maskedip.sh -i 60 -n 10      # 10 rotations, 60 s apart
EOF
}

# ---------- system helpers ---------------------------------------------------
is_root() { [[ $EUID -eq 0 ]]; }
have()    { command -v "$1" >/dev/null 2>&1; }

detect_pm() {
  local pm
  for pm in apt-get pacman dnf zypper; do
    have "$pm" && { echo "$pm"; return 0; }
  done
  return 1
}

install_packages() {
  local pm
  pm=$(detect_pm) || { err "No supported package manager found. Install manually: tor curl"; return 1; }
  info "Installing packages with $pm ..."
  case $pm in
    apt-get) apt-get update -qq && apt-get install -y tor curl ;;
    pacman)  pacman -S --noconfirm --needed tor curl ;;
    dnf)     dnf install -y tor curl ;;
    zypper)  zypper --non-interactive install tor curl ;;
  esac
}

ensure_dependencies() {
  local missing=()
  have tor  || missing+=(tor)
  have curl || missing+=(curl)
  if ((${#missing[@]})); then
    warn "Missing packages: ${missing[*]}"
    is_root || { err "Re-run with sudo so the missing packages can be installed."; return 1; }
    install_packages || return 1
  fi
  return 0
}

has_torrc_line() { grep -qE "$1" "$TORRC" 2>/dev/null; }

ensure_tor_config() {
  is_root || { err "Configuring Tor needs root (use sudo)."; return 1; }
  local add=()
  mkdir -p "$(dirname "$TORRC")"
  [[ -f $TORRC ]] || : >"$TORRC"

  has_torrc_line '^[[:space:]]*ControlPort[[:space:]]' \
    || add+=("ControlPort ${CONTROL_HOST}:${CONTROL_PORT}")
  has_torrc_line '^[[:space:]]*CookieAuthentication[[:space:]]+1' \
    || add+=("CookieAuthentication 1")
  has_torrc_line '^[[:space:]]*CookieAuthFileGroupReadable[[:space:]]+1' \
    || add+=("CookieAuthFileGroupReadable 1")

  if ((${#add[@]})); then
    cp -a "$TORRC" "${TORRC}.maskedip.bak"
    {
      echo
      echo "$MARK_BEGIN"
      printf '%s\n' "${add[@]}"
      echo "$MARK_END"
    } >>"$TORRC"
    info "Updated $TORRC (backup: ${TORRC}.maskedip.bak)"
  fi

  if have systemctl; then
    systemctl enable tor >/dev/null 2>&1 || true
    if ((${#add[@]})); then systemctl restart tor; else systemctl start tor; fi
  else
    warn "systemctl not found - please (re)start Tor manually."
  fi
  wait_for_cookie
}

wait_for_cookie() {
  local i
  for i in $(seq 1 20); do
    find_cookie >/dev/null && return 0
    sleep 1
  done
  err "Tor did not create its control cookie. Check: systemctl status tor"
  return 1
}

# ---------- Tor helpers ------------------------------------------------------
find_cookie() {
  local p
  for p in "${COOKIE_PATHS[@]}"; do
    [[ -r $p ]] && { echo "$p"; return 0; }
  done
  return 1
}

control_reachable() {
  timeout 3 bash -c "exec 3<>/dev/tcp/${CONTROL_HOST}/${CONTROL_PORT}" 2>/dev/null
}

# Ask Tor for a new identity (new circuits => new exit IP).
send_newnym() {
  local cookie hex reply
  cookie=$(find_cookie) || {
    err "Tor control cookie not found or not readable (run with sudo / check torrc)."
    return 1
  }
  hex=$(od -An -v -tx1 "$cookie" | tr -d ' \n')

  reply=$(
    exec 3<>"/dev/tcp/${CONTROL_HOST}/${CONTROL_PORT}" || exit 1
    printf 'AUTHENTICATE %s\r\nSIGNAL NEWNYM\r\nQUIT\r\n' "$hex" >&3
    timeout 8 cat <&3
  ) || { err "Cannot reach Tor control port ${CONTROL_HOST}:${CONTROL_PORT}."; return 1; }

  if grep -q '^[45][0-9][0-9]' <<<"$reply"; then
    err "Tor refused the request: $(grep -m1 '^[45]' <<<"$reply" | tr -d '\r')"
    return 1
  fi
  [[ $(grep -c '^250 OK' <<<"$reply") -ge 2 ]]
}

# IP as seen by the outside world THROUGH Tor.
get_tor_ip() {
  local url ip
  for url in "${IP_URLS[@]}"; do
    ip=$(curl -s --max-time 20 --socks5-hostname "$SOCKS_ADDR" "$url" 2>/dev/null | tr -d '[:space:]')
    if [[ $ip =~ ^[0-9a-fA-F:.]+$ ]]; then echo "$ip"; return 0; fi
  done
  return 1
}

# IP as seen WITHOUT Tor (your real one).
get_real_ip() {
  local url ip
  for url in "${IP_URLS[@]}"; do
    ip=$(curl -s --max-time 15 "$url" 2>/dev/null | tr -d '[:space:]')
    if [[ $ip =~ ^[0-9a-fA-F:.]+$ ]]; then echo "$ip"; return 0; fi
  done
  return 1
}

wait_for_tor() {
  local i ip
  info "Waiting for Tor to connect ..."
  for i in $(seq 1 30); do
    if ip=$(get_tor_ip); then ok "Tor is up. Current masked IP: ${ip}"; return 0; fi
    sleep 3
  done
  err "Tor is not reachable through ${SOCKS_ADDR}. Check your connection and 'systemctl status tor'."
  return 1
}

# ---------- commands ---------------------------------------------------------
valid_interval() {
  [[ $1 =~ ^[0-9]+$ ]] && (($1 >= MIN_INTERVAL))
}

show_status() {
  local tor_state svc_state tip rip
  have systemctl && tor_state=$(systemctl is-active tor 2>/dev/null) || tor_state="unknown"
  have systemctl && svc_state=$(systemctl is-active "$SERVICE" 2>/dev/null) || svc_state="unknown"

  echo "Tor service      : ${tor_state}"
  echo "MaskedIP service   : ${svc_state}"
  if control_reachable; then echo "Control port     : reachable (${CONTROL_HOST}:${CONTROL_PORT})"
  else echo "Control port     : NOT reachable"; fi
  if find_cookie >/dev/null; then echo "Auth cookie      : readable"
  else echo "Auth cookie      : not readable (try sudo)"; fi
  [[ -f $CONF_FILE ]] && echo "Configured       : $(grep '^MASKEDIP_INTERVAL=' "$CONF_FILE" | tail -1 | cut -d= -f2)s interval"

  tip=$(get_tor_ip) || tip="unavailable"
  rip=$(get_real_ip) || rip="unavailable"
  echo "Real IP          : ${rip}"
  echo "IP through Tor   : ${tip}"
  if [[ $tip != unavailable && $rip != unavailable ]]; then
    [[ $tip != "$rip" ]] && ok "Your Tor traffic is masked." || warn "Tor IP equals your real IP - something is wrong."
  fi
}

set_interval() {
  is_root || die "Run with sudo."
  valid_interval "$1" || die "Interval must be a whole number >= ${MIN_INTERVAL}."
  printf 'MASKEDIP_INTERVAL=%s\n' "$1" >"$CONF_FILE"
  ok "Interval set to ${1}s in ${CONF_FILE}"
  if have systemctl && systemctl is-active --quiet "$SERVICE"; then
    systemctl restart "$SERVICE" && ok "Service restarted."
  fi
}

run_loop() {
  local interval=$1 count=$2 n=0 ip prev=""
  trap 'echo; info "Stopped after ${n} rotation(s)."; exit 0' INT TERM

  wait_for_tor || exit 1
  prev=$(get_tor_ip || true)
  if ((count > 0)); then
    info "Rotating every ${interval}s, ${count} time(s). Press Ctrl+C to stop."
  else
    info "Rotating every ${interval}s until stopped. Press Ctrl+C to stop."
  fi
  info "Point your apps at SOCKS5 ${SOCKS_ADDR} to use the masked IP."

  while :; do
    n=$((n + 1))
    if send_newnym; then
      sleep 4   # give Tor a moment to build fresh circuits
      if ip=$(get_tor_ip); then
        if [[ $ip == "$prev" ]]; then
          warn "#${n} new circuit, but the exit IP is unchanged: ${ip}"
        else
          ok "#${n} new masked IP: ${ip}"
        fi
        prev=$ip
      else
        warn "#${n} identity changed, but the new IP could not be read yet."
      fi
    else
      warn "#${n} rotation failed, will retry next cycle."
    fi
    ((count > 0 && n >= count)) && break
    sleep "$interval" &
    wait $!
  done
  info "Done - ${n} rotation(s)."
}

# ---------- main -------------------------------------------------------------
main() {
  local mode=run interval="" count=0 daemon=0

  while (($#)); do
    case $1 in
      -i|--interval)
        (($# >= 2)) || die "$1 needs a value."; interval=$2; shift 2 ;;
      -n|--count)
        (($# >= 2)) || die "$1 needs a value."; count=$2; shift 2 ;;
      -o|--once)     count=1; shift ;;
      -s|--status)   mode=status; shift ;;
      -d|--daemon)   daemon=1; shift ;;
      --set-interval)
        (($# >= 2)) || die "$1 needs a value."; set_interval "$2"; exit 0 ;;
      --prepare)
        ensure_dependencies && ensure_tor_config && ok "Tor is ready."; exit $? ;;
      -h|--help)     usage; exit 0 ;;
      -v|--version)  echo "$APP $VERSION"; exit 0 ;;
      *) usage; die "Unknown option: $1" ;;
    esac
  done

  [[ $count =~ ^[0-9]+$ ]] || die "--count must be a whole number."
  if [[ -n $interval ]] && ! valid_interval "$interval"; then
    die "Interval must be a whole number >= ${MIN_INTERVAL} seconds."
  fi

  if [[ $mode == status ]]; then show_status; exit 0; fi

  # Daemon mode: read interval from env or config file.
  if ((daemon)) && [[ -z $interval ]]; then
    interval=${MASKEDIP_INTERVAL:-}
    if [[ -z $interval && -f $CONF_FILE ]]; then
      interval=$(sed -n 's/^MASKEDIP_INTERVAL=//p' "$CONF_FILE" | tail -1)
    fi
    interval=${interval:-$DEFAULT_INTERVAL}
  fi

  ((daemon)) || banner

  # Make sure Tor + control port are ready (auto-setup when running as root).
  if ! have tor || ! have curl || ! control_reachable || ! find_cookie >/dev/null; then
    if is_root; then
      ensure_dependencies && ensure_tor_config || exit 1
    else
      die "Tor is not ready. Run with sudo so MaskedIP can set it up: sudo $0"
    fi
  fi

  # Interactive interval prompt.
  if [[ -z $interval ]]; then
    if [[ -t 0 ]]; then
      read -rp "Seconds between IP changes [${DEFAULT_INTERVAL}]: " interval
      interval=${interval:-$DEFAULT_INTERVAL}
    else
      interval=$DEFAULT_INTERVAL
    fi
  fi
  valid_interval "$interval" || die "Interval must be a whole number >= ${MIN_INTERVAL} seconds."

  run_loop "$interval" "$count"
}

main "$@"
