#!/bin/zsh
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <window-id> <canvas-width>x<canvas-height> <output.png>" >&2
  exit 64
fi

window_id="$1"
canvas_size="$2"
output_path="$3"

if [[ ! "$window_id" =~ '^[0-9]+$' ]]; then
  echo "window-id must be numeric" >&2
  exit 64
fi

if [[ ! "$canvas_size" =~ '^[0-9]+x[0-9]+$' ]]; then
  echo "canvas size must look like 1080x1280" >&2
  exit 64
fi

for command_name in screencapture ffmpeg; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "missing required command: $command_name" >&2
    exit 69
  fi
done

temporary_capture="$(mktemp -t ai-pulse-window)"
trap 'rm -f "$temporary_capture"' EXIT

mkdir -p "${output_path:h}"
/usr/sbin/screencapture -x -t png -l "$window_id" "$temporary_capture"

ffmpeg -loglevel error \
  -f lavfi -i "color=c=black:s=$canvas_size" \
  -i "$temporary_capture" \
  -filter_complex '[0:v][1:v]overlay=format=auto' \
  -frames:v 1 -pix_fmt rgb24 -y "$output_path"

echo "$output_path"
