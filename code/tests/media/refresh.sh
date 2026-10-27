#!/bin/sh
# Rebuild every piece of demo media from the current source tree.
#
#   bash code/tests/media/refresh.sh
#
# The rule this script enforces: the media in static/demo is part of the
# shipped product, so it is regenerated for the version being released rather
# than left over from an older build. The script rebuilds the browser bundle,
# refreshes the screenshots, repaints the MCP transcript GIF, records the demo
# video in a headless browser, and assembles demo.mp4 / live-demo.gif.
#
# Requirements: moon, Python with Playwright + Chromium, ffmpeg. A missing
# dependency fails loudly instead of leaving stale media behind.
set -eu

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export PATH="$HOME/.moon/bin:$PATH"
cd "$ROOT"

command -v moon >/dev/null 2>&1 || { echo "refresh.sh: moon not found" >&2; exit 1; }
command -v ffmpeg >/dev/null 2>&1 || { echo "refresh.sh: ffmpeg not found" >&2; exit 1; }
python3 -c 'import playwright' 2>/dev/null || {
  echo "refresh.sh: Python Playwright is required (pip install playwright && playwright install chromium)" >&2
  exit 1
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/interjson-media.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

echo "refresh.sh: bundle"
bash static/demo/build.sh

echo "refresh.sh: screenshots and page smoke"
python3 code/tests/media/demo_visual_smoke.py

echo "refresh.sh: console smoke"
python3 code/tests/media/index_console_smoke.py

echo "refresh.sh: MCP transcript GIF"
python3 code/tests/media/render_mcp_gif.py

echo "refresh.sh: demo video"
(cd code && moon build cmd/interjson --target native --release)
BIN="$ROOT/code/_build/native/release/build/cmd/interjson/interjson.exe"
(cd "$ROOT/code" && moon run examples/agent_loop --target native --release) >"$TMP/agent_loop.txt" 2>&1
printf '%s' '{"a":"b","a":"c"}' | "$BIN" explain --json --policy execution >"$TMP/explain.json" 2>/dev/null || true
mkdir -p "$TMP/demo"
cp "$TMP/agent_loop.txt" "$TMP/explain.json" "$TMP/demo/" 2>/dev/null || true
mkdir -p /tmp/demo
cp "$TMP/agent_loop.txt" /tmp/demo/agent_loop.txt
cp "$TMP/explain.json" /tmp/demo/explain.json
python3 code/tests/media/demo_record.py --out "$TMP/rec" --root "$ROOT"

printf "file '%s'\n" \
  "$TMP/rec/seg1.webm" "$TMP/rec/seg2.webm" "$TMP/rec/seg3.webm" "$TMP/rec/seg4.webm" \
  >"$TMP/concat.txt"
ffmpeg -y -loglevel error -f concat -safe 0 -i "$TMP/concat.txt" \
  -vf "fps=30,scale=1280:-2" -c:v libx264 -preset medium -crf 26 \
  -pix_fmt yuv420p -movflags +faststart static/demo/demo.mp4
ffmpeg -y -loglevel error -i "$TMP/rec/seg2.webm" -t 22 \
  -vf "fps=5,scale=800:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=64[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5" \
  static/demo/live-demo.gif

echo "refresh.sh: done"
ls -lh static/demo/demo.mp4 static/demo/live-demo.gif static/demo/screenshot.png \
  static/demo/mcp-screenshot.png static/demo/surfaces-poster.png \
  static/demo/mcp-demo.gif static/demo/mcp-demo.png
