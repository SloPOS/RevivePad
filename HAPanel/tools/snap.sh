#!/bin/bash
# Take a screenshot of the running app over SSH (see "Remote debug channel" in PanelViewController.m).
# Usage: tools/snap.sh out.jpg [extra commands, e.g. "drawer:Music"]
OUT="${1:-snap.jpg}"; shift
HOST="${IPAD_HOST:-ipad}"
D=/var/mobile/Library/HAPanel
CMDS="stay:900"; for c in "$@"; do CMDS="$CMDS\n$c"; done
ssh -o BatchMode=yes "$HOST" "rm -f $D/snap.jpg; printf '$CMDS\n' > $D/cmd; chown mobile $D/cmd" 2>/dev/null
sleep 3
ssh -o BatchMode=yes "$HOST" "printf 'snap\n' > $D/cmd; chown mobile $D/cmd" 2>/dev/null
n=0; until ssh -o BatchMode=yes "$HOST" "test -f $D/snap.jpg" 2>/dev/null || [ $n -ge 10 ]; do sleep 1; n=$((n+1)); done
scp -O -q "$HOST:$D/snap.jpg" "$OUT" 2>/dev/null && echo "saved $OUT"
