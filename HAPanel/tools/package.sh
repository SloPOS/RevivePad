#!/bin/bash
# Pack the built app into a .deb that installs with dpkg, Filza or iFile on a jailbroken iPad.
# Usage (Linux/WSL, after wsl-build.sh): tools/package.sh [version]
# Install on the iPad:  dpkg -i revivepad_<version>_iphoneos-arm.deb
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
VER="${1:-1.0}"
APP="$HERE/build/HAPanel.app"
[ -f "$APP/HAPanel" ] || { echo "build first: wsl-build.sh"; exit 1; }
W="$(mktemp -d)"
chmod 755 "$W"
mkdir -p "$W/Applications" "$W/DEBIAN"
cp -r "$APP" "$W/Applications/"
cat > "$W/DEBIAN/control" <<EOF
Package: org.revivepad.hapanel
Name: RevivePad
Version: $VER
Architecture: iphoneos-arm
Description: Home Assistant wall panel for old iPads (iOS 8 and 9, 32-bit)
Maintainer: RevivePad contributors
Section: Utilities
Depends: firmware (>= 8.0)
EOF
# Remove the old bundle first: overwriting the binary in place makes iOS kill the app at launch.
cat > "$W/DEBIAN/preinst" <<'EOF'
#!/bin/sh
killall HAPanel 2>/dev/null
rm -rf /Applications/HAPanel.app
exit 0
EOF
cat > "$W/DEBIAN/postinst" <<'EOF'
#!/bin/sh
chown -R root:admin /Applications/HAPanel.app
chmod 755 /Applications/HAPanel.app/HAPanel
su mobile -c uicache 2>/dev/null || uicache
exit 0
EOF
chmod 755 "$W/DEBIAN/preinst" "$W/DEBIAN/postinst" "$W/Applications/HAPanel.app/HAPanel"
OUT="$HERE/build/revivepad_${VER}_iphoneos-arm.deb"
dpkg-deb -Zgzip --root-owner-group -b "$W" "$OUT" >/dev/null
rm -rf "$W"
echo "packaged: $OUT"
