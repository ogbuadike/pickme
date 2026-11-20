#!/bin/bash
# Prepares real app screenshots for the stores (macOS, uses the built-in `sips`).
#
#   tools/store_screenshots.sh play  <folder-with-phone-screenshots>
#       -> store_screenshots/play/*.png  at 1080x1920 (9:16, Google Play phone)
#   tools/store_screenshots.sh ios   <folder-with-simulator-screenshots>
#       -> store_screenshots/ios/*.png   checked for 1320x2868 or 1290x2796 (6.9"/6.7")
#
# Google Play rejects screenshots whose long side is more than 2x the short side,
# which is the case for modern tall phones (e.g. Galaxy S23 Ultra 1440x3088), so
# they are scaled to 1920px high and centred on a 1080x1920 canvas.
set -euo pipefail
mode="${1:-}"; src="${2:-}"
[ -d "$src" ] || { echo "usage: $0 play|ios <folder>"; exit 1; }
command -v sips >/dev/null || { echo "This script needs macOS (sips)."; exit 1; }
out="store_screenshots/$mode"; mkdir -p "$out"
pad="${PAD_COLOR:-FFFFFF}"
shopt -s nullglob nocaseglob
n=0
for f in "$src"/*.png "$src"/*.jpg "$src"/*.jpeg; do
  name="$(basename "${f%.*}").png"
  w=$(sips -g pixelWidth "$f" | awk '/pixelWidth/{print $2}')
  h=$(sips -g pixelHeight "$f" | awk '/pixelHeight/{print $2}')
  case "$mode" in
    play)
      sips -s format png --resampleHeight 1920 "$f" --out "$out/$name" >/dev/null
      nw=$(sips -g pixelWidth "$out/$name" | awk '/pixelWidth/{print $2}')
      if [ "$nw" -gt 1080 ]; then sips --resampleWidth 1080 "$out/$name" >/dev/null; fi
      sips --padToHeightWidth 1920 1080 --padColor "$pad" "$out/$name" >/dev/null
      ;;
    ios)
      if { [ "$w" = 1320 ] && [ "$h" = 2868 ]; } || { [ "$w" = 1290 ] && [ "$h" = 2796 ]; }; then
        sips -s format png "$f" --out "$out/$name" >/dev/null
      else
        echo "skip $f: ${w}x${h} (use the iPhone 16 Pro Max / 17 Pro Max simulator: 1320x2868)"; continue
      fi
      ;;
    *) echo "mode must be play or ios"; exit 1 ;;
  esac
  n=$((n+1)); echo "ok  $out/$name"
done
echo "$n screenshot(s) written to $out"
