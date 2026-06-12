#!/bin/zsh
# Convert demo/raw.mov into an optimized GIF at docs/demo.gif.
# Usage: ./demo/make-gif.sh [input.mov] [width]   (defaults: raw.mov, 880)
#
# Two-pass ffmpeg palette pipeline: small file, no dithering mud on the
# pixel-art dog. Trim first if needed:
#   ffmpeg -ss 2 -to 16 -i raw.mov -c copy trimmed.mov

set -e
cd "$(dirname "$0")"
INPUT="${1:-raw.mov}"
WIDTH="${2:-880}"
OUT="../docs/demo.gif"
FILTERS="fps=10,scale=${WIDTH}:-1:flags=lanczos"

ffmpeg -y -v warning -i "$INPUT" -vf "$FILTERS,palettegen=stats_mode=diff" -update 1 palette.png
ffmpeg -y -v warning -i "$INPUT" -i palette.png \
  -lavfi "$FILTERS [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  "$OUT"
rm -f palette.png

SIZE=$(du -h "$OUT" | cut -f1)
echo "Wrote docs/demo.gif (${SIZE})."
echo "GitHub renders README images up to ~10MB; if larger, lower width or fps."
