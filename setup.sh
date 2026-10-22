#!/usr/bin/env bash
# MaskedIP - install as a background systemd service
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="/usr/local/bin/maskedip"
CONF="/etc/maskedip.conf"
UNIT="/etc/systemd/system/maskedip.service"
MIN_INTERVAL=10
DEFAULT_INTERVAL=60

# Re-run with sudo if needed
if [[ $EUID -ne 0 ]]; then
  echo "[*] Root privileges required, re-running with sudo ..."
  exec sudo bash "$0" "$@"
fi

command -v systemctl >/dev/null 2>&1 || { echo "[!] systemd is required for service mode. Use ./maskedip.sh instead."; exit 1; }
[[ -f $SCRIPT_DIR/maskedip.sh ]] || { echo "[!] maskedip.sh not found next to setup.sh"; exit 1; }

echo "[*] Installing MaskedIP ..."
install -m 755 "$SCRIPT_DIR/maskedip.sh" "$BIN"

echo "[*] Installing dependencies and configuring Tor ..."
"$BIN" --prepare

# Ask for interval
read -rp "[?] Seconds between IP changes (min ${MIN_INTERVAL}) [${DEFAULT_INTERVAL}]: " INTERVAL
INTERVAL=${INTERVAL:-$DEFAULT_INTERVAL}
if ! [[ $INTERVAL =~ ^[0-9]+$ ]] || ((INTERVAL < MIN_INTERVAL)); then
  echo "[!] Invalid value, using ${DEFAULT_INTERVAL}s."
  INTERVAL=$DEFAULT_INTERVAL
fi
printf 'MASKEDIP_INTERVAL=%s\n' "$INTERVAL" >"$CONF"

cat >"$UNIT" <<EOF
[Unit]
Description=MaskedIP - automatic Tor IP rotation
After=network-online.target tor.service
Wants=network-online.target tor.service

[Service]
Type=simple
EnvironmentFile=-${CONF}
ExecStart=${BIN} --daemon
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now maskedip.service

echo
echo "[+] MaskedIP is running (new identity every ${INTERVAL}s)."
echo "    Status : systemctl status maskedip.service"
echo "    Logs   : journalctl -u maskedip.service -f"
echo "    Change interval : sudo maskedip --set-interval 120"
echo "    Use it : route apps through SOCKS5 127.0.0.1:9050"
