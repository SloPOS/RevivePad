#!/usr/bin/env python3
"""Save a panel layout sent by the on-screen layout editor of an iPad.

Called by shell_command.hapanel_save with two arguments: <panel> <base64 of the layout JSON>.
Validates the panel name and the JSON, keeps the last 10 versions as backups, then replaces
/config/www/hapanel/<panel>.json atomically.
"""
import base64
import glob
import json
import os
import re
import sys
import time

DIR = os.environ.get("HAPANEL_DIR", "/config/www/hapanel")


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: save_layout.py <panel> <base64-json>")
    panel, b64 = sys.argv[1], sys.argv[2]
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,40}", panel) or panel in ("home", "forecast"):
        sys.exit("invalid panel name")
    raw = base64.b64decode(b64, validate=True)
    if len(raw) > 200_000:
        sys.exit("layout too large")
    layout = json.loads(raw.decode("utf-8"))
    if not isinstance(layout, dict) or not isinstance(layout.get("cards"), list):
        sys.exit("layout must be an object with a cards list")
    path = os.path.join(DIR, panel + ".json")
    bdir = os.path.join(DIR, "backups")
    os.makedirs(bdir, exist_ok=True)
    if os.path.exists(path):
        with open(path, "rb") as f:
            old = f.read()
        with open(os.path.join(bdir, "%s.%s.json" % (panel, time.strftime("%Y%m%d-%H%M%S"))), "wb") as f:
            f.write(old)
        for stale in sorted(glob.glob(os.path.join(bdir, panel + ".*.json")))[:-10]:
            os.remove(stale)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(layout, f, indent=2, ensure_ascii=False)
    os.replace(tmp, path)
    print("saved %s (%d cards)" % (path, len(layout["cards"])))


if __name__ == "__main__":
    main()
