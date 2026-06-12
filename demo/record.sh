#!/bin/zsh
# Record a Biscuit demo take.
# Usage: ./demo/record.sh [seconds]   (default 18)
#
# Needs Screen Recording permission for your terminal app (one prompt,
# System Settings → Privacy & Security → Screen Recording).
# Records the main display with no audio into demo/raw.mov, then run
# ./demo/make-gif.sh to produce the optimized GIF.

set -e
cd "$(dirname "$0")"
SECONDS_TO_RECORD="${1:-18}"

# screencapture refuses to overwrite an existing file in video mode
# ("Failed to save to final location") — clear the previous take first.
rm -f raw.mov

echo "Recording starts in 3s — switch to your demo screen now."
sleep 1; echo 2; sleep 1; echo 1; sleep 1
echo "REC (${SECONDS_TO_RECORD}s)…"

screencapture -v -V "$SECONDS_TO_RECORD" -x raw.mov

echo "Saved demo/raw.mov ($(du -h raw.mov | cut -f1)). Next: ./demo/make-gif.sh"
