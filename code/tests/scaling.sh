#!/bin/bash
# Performance ratchets: NFR-PERF-01 (scaling) and NFR-PERF-05 (delta overhead).
#
#   bash tests/scaling.sh [<runs>]
#
# Both figures are *ratios* measured on the machine that runs this, never an
# absolute throughput, so the gate travels between machines. Interference can
# only make a run slower, and not proportionally, so the reported figure is the
# best of `runs` measurements: a loaded machine inflates runs, it does not
# deflate the best one.
#
# Only the native backend is gated. The JavaScript backend's scaling ratio is
# printed by `bash tests/bench.sh js` and quoted in the documents, but it is not
# a hard gate: garbage collection timing on a shared CI runner moves that ratio
# by more than the regressions the gate would exist to catch. The thresholds
# here are regression alarms, not the requirements themselves -- the requirement
# numbers live in `docs/TRACEABILITY.md`.
set -u

RUNS="${1:-3}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="$HOME/.moon/bin:$PATH"

# NFR-PERF-01: n, 2n and 4n must stay within 2.3x per doubling.
LINEARITY_MAX=2.3
# NFR-PERF-05: recording the change stream as views must stay within 160% of the
# cost of the same chunking without it. The registered requirement is 90% of
# baseline throughput; the measured value is ~125%, and this bound is set to
# catch a return to per-change path arrays without failing on a busy machine.
DELTA_MAX=160

if ! moon build bench --target native --release >/dev/null 2>&1; then
  echo "scaling: could not build the benchmark" >&2
  exit 1
fi
BENCH=./_build/native/release/build/bench/bench.exe

# Times are reduced with `min` across runs before any ratio is formed, rather
# than reducing the ratios. Interference only ever adds time, so the smallest
# observed time for a size is the best estimate of its real cost -- but a ratio
# computed from two inflated times can land anywhere, including below 1, and a
# minimum over ratios would happily keep that artifact.
t_n=""
t_2n=""
t_4n=""
t_base=""
t_delta=""

reduce() {
  # reduce <current> <candidate>: keep the smaller of two positive numbers.
  local cur="$1" cand="$2"
  if [ -z "$cur" ]; then
    printf '%s' "$cand"
    return
  fi
  awk -v a="$cur" -v b="$cand" 'BEGIN { print (b < a) ? b : a }'
}

grab() {
  # grab <output> <sed-expression>
  printf '%s' "$1" | sed -n "$2" | head -1
}

for _r in $(seq 1 "$RUNS"); do
  out="$("$BENCH" 2>&1)"
  v="$(grab "$out" 's/^linearity\tn\t\([0-9.]*\) ms$/\1/p')"
  [ -n "$v" ] && t_n="$(reduce "$t_n" "$v")"
  v="$(grab "$out" 's/^linearity\t2n\t\([0-9.]*\) ms.*$/\1/p')"
  [ -n "$v" ] && t_2n="$(reduce "$t_2n" "$v")"
  v="$(grab "$out" 's/^linearity\t4n\t\([0-9.]*\) ms.*$/\1/p')"
  [ -n "$v" ] && t_4n="$(reduce "$t_4n" "$v")"
  v="$(grab "$out" 's/^stream\tchunk 1024\t\([0-9.]*\) ms.*$/\1/p')"
  [ -n "$v" ] && t_base="$(reduce "$t_base" "$v")"
  v="$(grab "$out" 's/^deltas\tfor_each_delta chunk 1024\t\([0-9.]*\) ms.*$/\1/p')"
  [ -n "$v" ] && t_delta="$(reduce "$t_delta" "$v")"
done

ratio() {
  # ratio <numerator> <denominator> <scale>: two decimal places.
  if [ -z "$1" ] || [ -z "$2" ]; then
    printf ''
    return
  fi
  awk -v a="$1" -v b="$2" -v s="$3" 'BEGIN { printf "%.1f", (b == 0) ? 0 : s * a / b }'
}

best_linearity_2n="$(ratio "$t_2n" "$t_n" 1)"
best_linearity_4n="$(ratio "$t_4n" "$t_2n" 1)"
best_delta="$(ratio "$t_delta" "$t_base" 100)"

fail=0
report() {
  # report <name> <value> <percent-or-ratio> <max> <unit>
  local name="$1" value="$2" max="$3" unit="$4"
  if [ -z "$value" ]; then
    printf 'FAIL %-28s no measurement\n' "$name"
    fail=1
    return
  fi
  if awk -v v="$value" -v m="$max" 'BEGIN { exit !(v <= m) }'; then
    printf 'ok   %-28s %s%s (max %s%s)\n' "$name" "$value" "$unit" "$max" "$unit"
  else
    printf 'FAIL %-28s %s%s exceeds %s%s\n' "$name" "$value" "$unit" "$max" "$unit"
    fail=1
  fi
}

echo "scaling ratchets, best of $RUNS native runs:"
report "scaling 2n/n" "$best_linearity_2n" "$LINEARITY_MAX" "x"
report "scaling 4n/2n" "$best_linearity_4n" "$LINEARITY_MAX" "x"
report "deltas vs baseline" "$best_delta" "$DELTA_MAX" "%"

if [ "$fail" != 0 ]; then
  echo "scaling: a ratchet moved. Check NFR-PERF-01 / NFR-PERF-05 in docs/TRACEABILITY.md."
fi
exit "$fail"