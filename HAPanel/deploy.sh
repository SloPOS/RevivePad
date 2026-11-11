#!/bin/bash
# Install the built app on an iPad over SSH.
# Usage: ./deploy.sh [ssh-host]   (default: ipad, as defined in ~/.ssh/config)
#
# Never overwrite the binary in place: iOS caches code signatures per file,
# so an in-place overwrite makes the kernel silently kill the app at launch.
# Always remove the old bundle and copy a fresh one.
set -e
HOST="${1:-ipad}"
APP="$(dirname "$0")/build/HAPanel.app"
[ -f "$APP/HAPanel" ] || { echo "build first: wsl-build.sh"; exit 1; }
ssh -o BatchMode=yes "$HOST" 'killall HAPanel 2>/dev/null; rm -rf /Applications/HAPanel.app'
scp -O -q -r "$APP" "$HOST":/Applications/
ssh -o BatchMode=yes "$HOST" 'chown -R root:admin /Applications/HAPanel.app && chmod 755 /Applications/HAPanel.app/HAPanel && su mobile -c uicache && echo "installed on $(uname -n)"; sleep 2; uiopen hapanel:// 2>/dev/null && echo relaunched'
