#!/usr/bin/env bash
#
# Q-28 — the coverage gate for 0.6.0 "Streaming Semantic Safety".
#
# Frozen policy:
#   * overall >= 85%  over the library packages;
#   * core    >= 90%  for policy.mbt, decision.mbt, schema.mbt, plan.mbt and
#                     stream_readiness.mbt, the five files a caller's safety
#                     depends on (parse, decide, plan, readiness).
#   * the earlier "every new file >= 90%" rule is withdrawn. Its denominator
#     moved with every release and it measured nothing a caller could feel.
#
# SCOPE: `moon coverage report` covers the whole module, `bench/main.mbt`
# included. That file is a benchmark driver which `moon test` never executes
# (0/453 lines), so the overall floor is measured over the library packages and
# the all-files number is printed next to it. Nothing else is excluded, and no
# file is skipped because it is inconvenient.
#
# A core file that does not appear in the summary is fully covered: the report
# only lists files that still have an uncovered line.
#
# Usage:
#   code/tests/coverage.sh            measure, print the table, enforce
#   code/tests/coverage.sh --report   measure and print the table only
#
# Exits non-zero and names every file below its floor when enforcing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

# MoonBit is not on the default PATH in this checkout.
export PATH="$HOME/.moon/bin:$PATH"

# The frozen floors. The environment overrides exist so that the failure path
# of this script can be exercised (`COVERAGE_CORE_FLOOR=99 code/tests/coverage.sh`);
# the defaults are the policy.
OVERALL_FLOOR="${COVERAGE_OVERALL_FLOOR:-85}"
CORE_FLOOR="${COVERAGE_CORE_FLOOR:-90}"
CORE_FILES="policy.mbt decision.mbt schema.mbt plan.mbt stream_readiness.mbt"

ENFORCE=1
for arg in "$@"; do
  case "$arg" in
    --report) ENFORCE=0 ;;
    -h|--help)
      sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "coverage.sh: unknown argument: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done

if ! command -v moon >/dev/null 2>&1; then
  echo "coverage.sh: moon is not on PATH (expected \$HOME/.moon/bin/moon)" >&2
  exit 2
fi

SUMMARY_FILE="$(mktemp -t jsonmend_coverage)"
ROWS_FILE="$(mktemp -t jsonmend_rows)"
LOG_FILE="$(mktemp -t jsonmend_test_log)"
trap 'rm -f "$SUMMARY_FILE" "$ROWS_FILE" "$LOG_FILE"' EXIT

echo "coverage.sh: moon coverage clean"
moon coverage clean >/dev/null 2>&1

echo "coverage.sh: moon test --enable-coverage"
if ! moon test --enable-coverage >"$LOG_FILE" 2>&1; then
  echo "coverage.sh: the instrumented test run failed:" >&2
  tail -20 "$LOG_FILE" >&2
  exit 1
fi
tail -1 "$LOG_FILE" | sed 's/^/coverage.sh: /'

moon coverage report -f summary >"$SUMMARY_FILE" 2>&1 || {
  echo "coverage.sh: moon coverage report failed:" >&2
  cat "$SUMMARY_FILE" >&2
  exit 1
}

# `path/file.mbt: covered/total`, one line per file that has an uncovered line,
# then `Total: covered/total`. The total is recomputed here so that the same
# rows drive the table and the gate.
awk '
  /^[^:]*\.mbt:[[:space:]]*[0-9]+\/[0-9]+[[:space:]]*$/ {
    split($0, parts, ":")
    file = parts[1]
    split(parts[2], nums, "/")
    gsub(/[^0-9]/, "", nums[1])
    gsub(/[^0-9]/, "", nums[2])
    printf "%s %s %s\n", file, nums[1], nums[2]
  }
' "$SUMMARY_FILE" >"$ROWS_FILE"

if [ ! -s "$ROWS_FILE" ]; then
  echo "coverage.sh: no coverage rows parsed from the summary:" >&2
  cat "$SUMMARY_FILE" >&2
  exit 1
fi

printf '\n%-26s %8s %8s %7s  %s\n' "file" "covered" "total" "pct" "floor"
printf '%-26s %8s %8s %7s  %s\n' "--------------------------" "--------" "--------" "-------" "-----"

print_row() {
  # file covered total floor-label
  local file="$1" cov="$2" tot="$3" label="$4" pct
  if [ "$cov" = "-" ]; then
    printf '%-26s %8s %8s %7s  %s\n' "$file" "-" "-" "-" "$label"
    return
  fi
  pct="$(awk -v c="$cov" -v t="$tot" 'BEGIN { if (t == 0) print "100.0"; else printf "%.1f", 100.0 * c / t }')"
  printf '%-26s %8s %8s %6s%%  %s\n' "$file" "$cov" "$tot" "$pct" "$label"
}

CORE_FOUND=0
for f in $CORE_FILES; do
  # A core file absent from the summary has no uncovered line at all.
  row="$(awk -v f="$f" '$1 == f { print $2, $3 }' "$ROWS_FILE")"
  if [ -z "$row" ]; then
    print_row "$f" "-" "-" ">= ${CORE_FLOOR}% (fully covered, not listed)"
    CORE_FOUND=$((CORE_FOUND + 1))
  else
    # shellcheck disable=SC2086
    print_row "$f" $row ">= ${CORE_FLOOR}%"
  fi
done

printf '\n'
awk -v fl="$OVERALL_FLOOR" '
  {
    if ($1 ~ /^bench\//) { bc += $2; bt += $3 } else { lc += $2; lt += $3 }
    ac += $2; at += $3
  }
  END {
    printf "%-26s %8d %8d %6.1f%%  >= %d%%\n", "library (no bench/)", lc, lt, (lt ? 100.0 * lc / lt : 100.0), fl
    printf "%-26s %8d %8d %6.1f%%  (reported, not enforced)\n", "all files incl. bench/", ac, at, (at ? 100.0 * ac / at : 100.0)
  }
' "$ROWS_FILE"

echo
if [ "$ENFORCE" -eq 0 ]; then
  echo "coverage.sh: --report, no threshold enforced"
  exit 0
fi

FAIL=0
MISSES=""

# Core files, one at a time: a missing row means 100%.
for f in $CORE_FILES; do
  row="$(awk -v f="$f" '$1 == f { print $2, $3 }' "$ROWS_FILE")"
  [ -z "$row" ] && continue
  # shellcheck disable=SC2086
  set -- $row
  cov="$1"
  tot="$2"
  if [ "$(awk -v c="$cov" -v t="$tot" -v fl="$CORE_FLOOR" 'BEGIN { print (100.0 * c / t < fl) ? 1 : 0 }')" = "1" ]; then
    FAIL=1
    MISSES="$MISSES
  core  $f $cov/$tot ($(awk -v c="$cov" -v t="$tot" 'BEGIN { printf "%.1f", 100.0 * c / t }')%) below ${CORE_FLOOR}%"
  fi
done

# Overall, over the library packages.
read -r LC LT < <(awk '$1 !~ /^bench\// { c += $2; t += $3 } END { print c + 0, t + 0 }' "$ROWS_FILE")
if [ "$(awk -v c="$LC" -v t="$LT" -v fl="$OVERALL_FLOOR" 'BEGIN { print (t == 0 || 100.0 * c / t < fl) ? 1 : 0 }')" = "1" ]; then
  FAIL=1
  MISSES="$MISSES
  overall  library $LC/$LT ($(awk -v c="$LC" -v t="$LT" 'BEGIN { printf "%.1f", 100.0 * c / t }')%) below ${OVERALL_FLOOR}%"
fi

if [ "$FAIL" -ne 0 ]; then
  echo "coverage.sh: FAILED — below the frozen floor:" >&2
  printf '%s\n' "$MISSES" >&2
  echo >&2
  echo "Uncovered lines for a failing core file:" >&2
  for f in $CORE_FILES; do
    row="$(awk -v f="$f" '$1 == f { print $2, $3 }' "$ROWS_FILE")"
    [ -z "$row" ] && continue
    # shellcheck disable=SC2086
    set -- $row
    if [ "$(awk -v c="$1" -v t="$2" -v fl="$CORE_FLOOR" 'BEGIN { print (100.0 * c / t < fl) ? 1 : 0 }')" = "1" ]; then
      lines="$(moon coverage report -f caret -F "$f" 2>/dev/null | grep -oE '\-\-> [^ ]+:[0-9]+' | sed 's/.*://' | tr '\n' ' ')"
      echo "  $f: $lines" >&2
    fi
  done
  exit 1
fi

echo "coverage.sh: OK — library ${LC}/${LT}, core files at or above ${CORE_FLOOR}%"
exit 0
