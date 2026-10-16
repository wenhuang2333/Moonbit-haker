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
# Q-37 — the per-file exemption ratchet (`coverage_exemptions.txt`):
# the floors above are percentages, and a percentage hides which lines are
# missing. The exemption file records, per core file, the exact uncovered lines
# that were accepted when it was written, and the ratchet is:
#
#   * a line that is uncovered now and is NOT recorded -> FAIL, naming file:line
#     (this is the criterion: a line that used to be covered fell back out);
#   * a recorded line that is covered now -> FAIL, naming file:line and asking
#     for the entry to be deleted (an exemption may only shrink);
#   * the file may never grow: `--update-exemptions` rewrites it to the current
#     state and refuses when the result would be larger, unless
#     COVERAGE_FORCE_EXEMPTIONS=1 is set (a deliberate re-baseline, reviewable in
#     the diff).
#
# Entries are anchored on the *source text* of the uncovered line, not only on
# its number, because inserting one line above an exempted line renumbers every
# line below it; the recorded number is kept as a human hint. The ratchet covers
# the five core files (the ones with a per-file floor); every other file is held
# to the overall floor. An exemption never relaxes a floor: exempted lines still
# count as uncovered in the percentages above.
#
# Usage:
#   code/tests/coverage.sh                     measure, print, enforce
#   code/tests/coverage.sh --report            measure and print only
#   code/tests/coverage.sh --update-exemptions rewrite the exemption file
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
EXEMPTIONS_FILE="${COVERAGE_EXEMPTIONS_FILE:-$HERE/coverage_exemptions.txt}"
REPORT_WIDTH=66

ENFORCE=1
UPDATE_EXEMPTIONS=0
for arg in "$@"; do
  case "$arg" in
    --report) ENFORCE=0 ;;
    --update-exemptions) UPDATE_EXEMPTIONS=1 ;;
    -h|--help)
      sed -n '2,57p' "$0" | sed 's/^# \{0,1\}//'
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
CUR_FILE="$(mktemp -t jsonmend_uncovered)"
NEW_FILE="$(mktemp -t jsonmend_exc_new)"
OLD_FILE="$(mktemp -t jsonmend_exc_old)"
trap 'rm -f "$SUMMARY_FILE" "$ROWS_FILE" "$LOG_FILE" "$CUR_FILE" "$NEW_FILE" "$OLD_FILE"' EXIT

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

# ---------------------------------------------------------------------------
# Q-37 — the per-file exemption ratchet.
#
# One row per uncovered line: `<file>\t<line>\t<source text, trimmed>`. The text
# is what makes the record survive an insertion above it; the number is a hint.
# ---------------------------------------------------------------------------

# Every uncovered line of the core files, as file<TAB>line<TAB>text.
: >"$CUR_FILE"
for f in $CORE_FILES; do
  moon coverage report -f caret -F "$f" 2>/dev/null |
    sed -n 's/^ *--> \([^:]*\):\([0-9][0-9]*\)$/\1 \2/p' |
    while read -r file line; do
      text="$(sed -n "${line}p" "$ROOT/$file" 2>/dev/null |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      printf '%s\t%s\t%s\n' "$file" "$line" "$text"
    done >>"$CUR_FILE"
done

# The recorded exemptions, ignoring comments and blanks.
: >"$OLD_FILE"
if [ -f "$EXEMPTIONS_FILE" ]; then
  awk -F'\t' '!/^[[:space:]]*#/ && NF >= 3 { print $1 "\t" $2 "\t" $3 }' \
    "$EXEMPTIONS_FILE" >"$OLD_FILE"
fi

if [ "$UPDATE_EXEMPTIONS" -eq 1 ]; then
  cur_n="$(wc -l <"$CUR_FILE" | tr -d ' ')"
  old_n="$(wc -l <"$OLD_FILE" | tr -d ' ')"
  # Growth is a *set* property, not a count: shrinking by two and adding one is
  # still an addition, and the ratchet only turns one way.
  NEW_ONLY="$(awk -F'\t' '
    NR == FNR { exc[$1 "\t" $3]++; next }
    {
      k = $1 "\t" $3
      if (exc[k] > 0) { exc[k]-- } else { printf "  new  %s:%s  %s\n", $1, $2, $3 }
    }
  ' "$OLD_FILE" "$CUR_FILE")"
  if [ -n "$NEW_ONLY" ] && [ "${COVERAGE_FORCE_EXEMPTIONS:-0}" != "1" ]; then
    echo "coverage.sh: refusing to grow the exemption list ($old_n -> $cur_n entries):" >&2
    printf '%s\n' "$NEW_ONLY" >&2
    echo "coverage.sh: write tests instead, or re-baseline deliberately with COVERAGE_FORCE_EXEMPTIONS=1." >&2
    exit 1
  fi
  {
    echo "# Per-file coverage exemptions for code/tests/coverage.sh (Q-37)."
    echo "#"
    echo "# One line per accepted uncovered line of a core file:"
    echo "#     <file>\t<line>\t<source text of that line, trimmed>"
    echo "#"
    echo "# The ratchet: this list may only shrink. A core line that is uncovered and"
    echo "# not recorded here fails the gate (it used to be covered), a recorded line"
    echo "# that is covered now fails it too (delete the entry), and"
    echo "# \`coverage.sh --update-exemptions\` refuses to write a larger list unless"
    echo "# COVERAGE_FORCE_EXEMPTIONS=1. The line number is a hint: matching is done on"
    echo "# the source text, so inserting code above an entry does not invalidate it."
    sort "$CUR_FILE"
  } >"$EXEMPTIONS_FILE.tmp"
  if [ "$old_n" -gt "$cur_n" ]; then
    echo "coverage.sh: pruned $((old_n - cur_n)) exemption(s) that are covered now"
  fi
  mv "$EXEMPTIONS_FILE.tmp" "$EXEMPTIONS_FILE"
  echo "coverage.sh: wrote $cur_n exemption(s) to ${EXEMPTIONS_FILE#"$ROOT"/}"
  exit 0
fi

EXC_REPORT=""
if [ ! -f "$EXEMPTIONS_FILE" ]; then
  echo "coverage.sh: no $EXEMPTIONS_FILE — the per-file ratchet is skipped (floors still enforced)" >&2
else
  # Match line by line, first come first served, so that a duplicated source
  # text reports the *actual* line that has no exemption and the actual recorded
  # entry that can be deleted. Both directions use the same text key.
  EXC_REPORT="$(
    {
      awk -F'\t' '
        NR == FNR { exc[$1 "\t" $3]++; next }
        {
          k = $1 "\t" $3
          if (exc[k] > 0) { exc[k]-- } else { printf "new\t%s\t%s\t%s\n", $1, $2, $3 }
        }
      ' "$OLD_FILE" "$CUR_FILE"
      awk -F'\t' '
        NR == FNR { cur[$1 "\t" $3]++; next }
        {
          k = $1 "\t" $3
          if (cur[k] > 0) { cur[k]-- } else { printf "stale\t%s\t%s\t%s\n", $1, $2, $3 }
        }
      ' "$CUR_FILE" "$OLD_FILE"
    } | sort
  )"

  if [ -n "$EXC_REPORT" ]; then
    FAIL=1
    MISSES="$MISSES
  ratchet  see the per-line report below"
  fi
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
  if [ -n "$EXC_REPORT" ]; then
    echo >&2
    echo "coverage.sh: FAILED — the core exemption list is stale or incomplete:" >&2
    printf '%s\n' "$EXC_REPORT" |
      awk -F'\t' '
        {
          kind = $1; file = $2; line = $3; text = $4
          if (kind == "new") {
            printf "  not exempt  %s:%s  %s\n", file, line, text
          } else {
            printf "  can shrink  %s:%s  %s\n", file, line, text
          }
        }' >&2
    echo >&2
    echo "  not exempt  = uncovered now, not in ${EXEMPTIONS_FILE#"$ROOT"/} — a line fell out of coverage." >&2
    echo "  can shrink  = recorded there but covered now — delete that entry." >&2
  fi
  exit 1
fi

echo "coverage.sh: OK — library ${LC}/${LT}, core files at or above ${CORE_FLOOR}%, exemption list matches"
exit 0
