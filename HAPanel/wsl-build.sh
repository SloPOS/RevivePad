#!/bin/bash
# Build HAPanel with Theos inside WSL. Run from Windows:
#   wsl -d Ubuntu -e bash "/mnt/c/.../HAPanel/wsl-build.sh"
# Sources are copied to a path without spaces (Theos/make can't handle them), built there,
# and the finished HAPanel.app is copied back to ./build/ for deploy.sh.
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
export THEOS="${THEOS:-$HOME/theos}"
B="$HOME/.cache/revivepad-build"
mkdir -p "$B"
rsync -a --delete --exclude .theos --exclude build --exclude '*.bak*' "$SRC"/ "$B"/
cd "$B"
bash "$SRC/tools/patch-sdk.sh" >/dev/null
rm -rf .theos/obj/HAPanel.app
make FINALPACKAGE=1 messages=no 2>&1 | grep -vE "built for iOS Simulator" | grep -E "error|warning:|Undefined|referenced|Signing" || true
[ -f .theos/obj/HAPanel.app/HAPanel ] || { echo "BUILD FAILED"; exit 1; }
rm -rf "$SRC/build"; mkdir -p "$SRC/build"
cp -r .theos/obj/HAPanel.app "$SRC/build/"
cp -r .theos/obj/armv7/HAPanel.app/HAPanel.dSYM "$SRC/build/" 2>/dev/null || true
echo "built: $(stat -c %s "$SRC/build/HAPanel.app/HAPanel") bytes"
