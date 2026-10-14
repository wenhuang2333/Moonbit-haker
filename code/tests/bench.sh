#!/bin/bash
# TC-B performance measurements (D11). Prints a raw report on stdout:
#
#   bash code/tests/bench.sh            # everything
#   bash code/tests/bench.sh native     # native only
#   bash code/tests/bench.sh js         # javascript only
#   bash code/tests/bench.sh size       # wasm-gc artifact size only
#
# Numbers are observations of one machine, not a contract; the throughput
# thresholds are checked by `moon test` (TC-PERF-02) and by bench/main.mbt.
set -u

MODE="${1:-all}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="$HOME/.moon/bin:$PATH"

if [ "$MODE" = all ] || [ "$MODE" = native ]; then
  echo "== native (release) =="
  moon build bench --target native --release >/dev/null || exit 1
  ./_build/native/release/build/bench/bench.exe
  if [ "$(uname -s)" = Darwin ]; then
    TIME_FLAG=-l
  else
    TIME_FLAG=-v
  fi
  echo "-- peak memory (/usr/bin/time $TIME_FLAG) --"
  /usr/bin/time "$TIME_FLAG" ./_build/native/release/build/bench/bench.exe 2>&1 |
    grep -Ei "resident set size|^real|elapsed \(wall" || true
fi

if [ "$MODE" = all ] || [ "$MODE" = js ]; then
  echo
  echo "== javascript (release, node) =="
  moon build bench --target js --release >/dev/null || exit 1
  node ./_build/js/release/build/bench/bench.js
fi

if [ "$MODE" = all ] || [ "$MODE" = size ]; then
  echo
  echo "== wasm-gc artifact size =="
  moon build bench/probe --target wasm-gc --release >/dev/null || exit 1
  ls -l _build/wasm-gc/release/build/bench/probe/probe.wasm |
    awk '{printf "%s bytes (%.1f KiB)\n", $5, $5/1024}'
  echo "== javascript artifact size =="
  moon build examples/web --target js --release >/dev/null || exit 1
  ls -l _build/js/release/build/examples/web/web.js |
    awk '{printf "%s bytes (%.1f KiB)\n", $5, $5/1024}'
fi
