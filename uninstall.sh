#!/usr/bin/env bash
# MaskedIP - clean removal
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

TORRC="${MASKEDIP_TORRC:-/etc/tor/torrc}"

echo "[*] Stopping and removing the MaskedIP service ..."
systemctl stop maskedip.service 2>/dev/null || true
systemctl disable maskedip.service 2>/dev/null || true
rm -f /etc/systemd/system/maskedip.service /etc/maskedip.conf /usr/local/bin/maskedip
systemctl daemon-reload 2>/dev/null || true

# Remove only the lines MaskedIP added to torrc
if [[ -f $TORRC ]] && grep -q '^# >>> MaskedIP >>>' "$TORRC"; then
  sed -i '/^# >>> MaskedIP >>>/,/^# <<< MaskedIP <<</d' "$TORRC"
  echo "[*] Removed MaskedIP settings from $TORRC"
  systemctl restart tor 2>/dev/null || true
fi

read -rp "[?] Also stop and disable the Tor service? [y/N]: " ans
if [[ ${ans,,} == y* ]]; then
  systemctl stop tor 2>/dev/null || true
  systemctl disable tor 2>/dev/null || true
  echo "[*] Tor stopped and disabled (the package itself is still installed)."
fi

echo "[+] MaskedIP has been removed."
