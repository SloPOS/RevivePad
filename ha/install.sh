#!/bin/sh
# Copy RevivePad's Home Assistant files into /config. Run it on the Home Assistant machine
# (for example in the "Terminal & SSH" add-on) from a copy of this repository:
#
#   sh ha/install.sh            # required files only
#   sh ha/install.sh timer      # also the timer helper for the timer card
#   sh ha/install.sh timer teslamate
#
# It never overwrites a layout you already have and does not edit configuration.yaml.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${HA_CONFIG:-/config}"
[ -f "$CONFIG/configuration.yaml" ] || { echo "no configuration.yaml in $CONFIG (set HA_CONFIG=<folder>)"; exit 1; }

mkdir -p "$CONFIG/hapanel" "$CONFIG/packages" "$CONFIG/www/hapanel"
cp "$HERE"/hapanel/*.py "$CONFIG/hapanel/"
cp "$HERE/packages/hapanel.yaml" "$CONFIG/packages/"
echo "copied: hapanel/*.py, packages/hapanel.yaml"
for extra in "$@"; do
  case "$extra" in
    timer)     cp "$HERE/packages/panel_timer.yaml" "$CONFIG/packages/"; echo "copied: packages/panel_timer.yaml";;
    teslamate) cp "$HERE/packages/teslamate.yaml" "$CONFIG/packages/";  echo "copied: packages/teslamate.yaml";;
    *) echo "unknown option: $extra (timer, teslamate)";;
  esac
done
if [ ! -f "$CONFIG/www/hapanel/home.json" ]; then
  cp "$HERE/examples/home.json" "$CONFIG/www/hapanel/home.json"
  echo "copied: www/hapanel/home.json (which lights and switches the Home drawer lists)"
fi

echo
if grep -q "packages:" "$CONFIG/configuration.yaml"; then
  echo "configuration.yaml already loads packages."
else
  echo "Add this to configuration.yaml (once):"
  echo
  echo "homeassistant:"
  echo "  packages: !include_dir_named packages"
fi
echo
echo "Then restart Home Assistant. No layout file is needed to start: the app builds a first"
echo "screen by itself, and saving from its layout editor creates www/hapanel/<panel>.json."
echo "To start from the full example instead:"
echo "  cp $HERE/examples/panel.json $CONFIG/www/hapanel/<panel>.json   (then edit the entity names)"
