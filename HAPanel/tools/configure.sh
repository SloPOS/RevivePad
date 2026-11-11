#!/bin/bash
# Write the connection settings to an iPad over SSH, instead of typing them on its screen.
# Usage: tools/configure.sh [ssh-host]      (default: ipad)
# Asks for the Home Assistant address, a long-lived access token (not shown, not stored on this
# computer) and a panel name. The app picks the change up within a minute, or tap gear > Reload.
set -e
HOST="${1:-ipad}"
read -r -p "Home Assistant address [http://homeassistant.local:8123]: " URL
URL="${URL:-http://homeassistant.local:8123}"
read -r -s -p "Long-lived access token (input hidden): " TOKEN; echo
read -r -p "Panel name for this iPad [default]: " PANEL
PANEL="$(printf '%s' "${PANEL:-default}" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_-')"
[ -n "$TOKEN" ] || { echo "no token given"; exit 1; }
case "$URL$TOKEN" in *'<'*|*'&'*) echo "address and token must not contain < or &"; exit 1;; esac
D=/var/mobile/Library/HAPanel
ssh "$HOST" "mkdir -p $D && umask 077 && cat > $D/config.plist && chown -R mobile:mobile $D && chmod 600 $D/config.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>url</key><string>$URL</string>
<key>token</key><string>$TOKEN</string>
<key>panel</key><string>$PANEL</string>
</dict></plist>
EOF
echo "saved: $URL, panel \"$PANEL\" (layout file: /config/www/hapanel/$PANEL.json)"
