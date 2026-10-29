#!/usr/bin/env bash
# Coverage gate for the published documents: every document this repository
# ships is a document `claims.sh` actually searches.
#
#   bash tests/published_docs.sh
#
# Why this exists
# ---------------
#
# `claims.sh` checks that the figures a document quotes match what the build
# produces. Which documents it checks was, until now, decided by the file
# arguments written at each check site -- and that list had drifted: two of the
# documents it named were not published at all (so the checks were skipped and
# reported as "not published", which reads like success), while a document that
# *is* published was not named anywhere, so its numbers were never checked.
#
# Neither state is detectable by reading `claims.sh`: a check that names the
# wrong file and a check that names no file both look like a check. So the set
# is derived here, from the one place that actually decides what gets published
# (the `.gitignore` whitelist), and the two are compared.
#
# What is asserted
# ----------------
#
# 1. Every published `.md` file is named somewhere in `claims.sh`. A new
#    published document that quotes numbers and is not wired in fails here.
# 2. No document named in `claims.sh` is unpublished *and* absent -- naming a
#    file that does not exist means the check silently skips.
# 3. Every published document that carries a version string states the version
#    in `code/moon.mod`. (`cli_smoke.sh` checks a hard-coded subset; this
#    derives the set.)
#
# Exit codes: 0 all good, 1 a gap, 2 the check could not run.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 2

FAIL=0
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL %s\n' "$1" >&2
}

MOD_VERSION="$(sed -n 's/^version *= *"\(.*\)"/\1/p' code/moon.mod)"
[ -n "$MOD_VERSION" ] || { echo "could not read the version from code/moon.mod" >&2; exit 2; }

# The published set: every markdown file git would ship. `check-ignore` answers
# with the whitelist's verdict for a path, which is the same rule GitHub sees.
PUBLISHED=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if ! git check-ignore -q "$f" 2>/dev/null; then
    PUBLISHED+=("$f")
  fi
done < <(git ls-files -co --exclude-standard '*.md')

[ "${#PUBLISHED[@]}" -gt 0 ] || { echo "no published markdown found; is this a git checkout?" >&2; exit 2; }

printf 'published documents: %d\n' "${#PUBLISHED[@]}"

# --- 1. every published document is either searched or declared figure-free --
#
# A published document is one a reader will check, so the figures in it have to
# be checked too. But not every document carries gated figures: a protocol
# specification describes a wire format, and a generated report is rewritten by
# the pipeline (so `claims.sh` reads *from* it rather than comparing against it).
#
# Those are listed here explicitly. The point of the list is that adding a
# document to it is a decision someone writes down, and a *new* published
# document that quotes numbers cannot slip in unsearched without also being
# named in this file.
#
# `NOTREE.md` is on the list because its numbers are the memory ratios, and
# `memory_gate.py` -- not `claims.sh` -- is what keeps those honest.
FIGURE_FREE=".github/SECURITY.md code/docs/PROTOCOL.md code/docs/SPEC.md code/docs/INTEGRATIONS.md code/docs/NOTREE.md code/docs/MEMORY.md code/docs/EVAL.md code/docs/EVAL_AMBIGUITY.md code/docs/EVAL_INDEPENDENT.md code/docs/EVAL_PATHS.md code/docs/EVAL_REFERENCE.md code/docs/EVAL_REGISTRATION.md code/docs/READINESS.md code/docs/DIVERGENCES.md code/docs/CONFORMANCE.md code/tests/eval/third_party/jsontestsuite/PROVENANCE.md code/tests/eval/third_party/jsontestsuite/README.md code/CHANGELOG.md code/SECURITY.md code/CONTRIBUTING.md .github/ISSUE_TEMPLATE/defect.md .github/ISSUE_TEMPLATE/new-rule.md .github/PULL_REQUEST_TEMPLATE.md"

CLAIMS="code/tests/claims.sh"
for f in "${PUBLISHED[@]}"; do
  case " $FIGURE_FREE " in
    *" $f "*) continue ;;
  esac
  base="$(basename "$f")"
  if ! grep -qF "$base" "$CLAIMS"; then
    fail "$f is published and quotes figures, but claims.sh never searches it"
  fi
done

# --- 2. no check names a file that does not exist ---------------------------
#
# `require_in` skips a missing file and reports it as "not published", which is
# the right behaviour for a document that is deliberately local -- but not for a
# name that was deleted or mistyped. Every path claims.sh mentions under
# $ROOT/ must exist, unless it is a known local-only document.
LOCAL_ONLY="产品文档.md code/docs/RULES.md code/docs/ERRORS.md code/docs/BENCHMARK.md code/docs/REPRODUCE.md code/docs/TRACEABILITY.md code/docs/AI_USAGE.md code/docs/GITHUB.md code/docs/RELEASE_READINESS.md code/docs/LLM_EVENTS.md code/docs/PROVIDER_PROBE.md"
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  # `$ROOT/x`, `$CODE/x` and bare `$ROOT/...`-style names both appear; reduce to
  # the path under the repository root.
  rel="${ref#\$ROOT/}"
  rel="${rel#\$CODE/}"
  rel="${rel#code/}"
  [ -e "$rel" ] && continue
  [ -e "code/$rel" ] && continue
  case " $LOCAL_ONLY " in
    *" $rel "*) continue ;;
    *" code/$rel "*) continue ;;
  esac
  fail "claims.sh names '$rel', which does not exist -- that check skips silently"
done < <(grep -oE '\$(ROOT|CODE)/[A-Za-z0-9_./\u4e00-\u9fff-]+\.md' "$CLAIMS" | sort -u)

# --- 3. no document declares a current version that is not moon.mod's --------
#
# A document may refer to old versions freely -- a changelog does, and so does a
# sentence of the form "1.4.0 时是 217". What it may not do is *declare* a
# current version that is not the one in `code/moon.mod`, because that is the
# string a reader takes as "this is the release I am reading about".
#
# The declaration forms are enumerated rather than approximated: an optional
# prefix would match every historical mention, and a check that fails on history
# is a check someone deletes.
GENERATED="code/docs/MEMORY.md code/docs/EVAL.md code/docs/EVAL_AMBIGUITY.md code/docs/EVAL_INDEPENDENT.md code/docs/EVAL_PATHS.md code/docs/EVAL_REFERENCE.md code/docs/EVAL_REGISTRATION.md code/docs/READINESS.md code/docs/DIVERGENCES.md"
for f in "${PUBLISHED[@]}"; do
  [ -f "$f" ] || continue
  case " $GENERATED " in
    *" $f "*) continue ;;
  esac
  case "$f" in
    # The changelog declares the version of each section it documents.
    code/CHANGELOG.md) continue ;;
  esac
  declared="$(
    {
      grep -oE '\*\*版本\*\*：[`"]?1\.[0-9]+\.[0-9]+' "$f" 2>/dev/null | grep -oE '1\.[0-9]+\.[0-9]+'
      grep -oE '\| 版本 \| [`"]?1\.[0-9]+\.[0-9]+' "$f" 2>/dev/null | grep -oE '1\.[0-9]+\.[0-9]+'
      grep -oE '"version": "1\.[0-9]+\.[0-9]+"' "$f" 2>/dev/null | grep -oE '1\.[0-9]+\.[0-9]+'
      grep -oE '版本号：[`"]?1\.[0-9]+\.[0-9]+' "$f" 2>/dev/null | grep -oE '1\.[0-9]+\.[0-9]+'
      grep -oE '^1\.[0-9]+\.[0-9]+ *·' "$f" 2>/dev/null | grep -oE '^1\.[0-9]+\.[0-9]+'
    } | sort -u
  )"
  [ -n "$declared" ] || continue
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    [ "$v" = "$MOD_VERSION" ] && continue
    fail "$f declares version $v but code/moon.mod is $MOD_VERSION"
  done <<< "$declared"
done

# --- 4. the two copies of SECURITY.md are the same file ----------------------
#
# GitHub's Security tab and its "Report a vulnerability" button only read
# `.github/SECURITY.md`, so that path has to exist; `code/SECURITY.md` is the
# canonical copy, next to the code the guarantees are about. Two copies of one
# document drift, so they are compared instead of trusted.
if [ -f code/SECURITY.md ] && [ -f .github/SECURITY.md ]; then
  if ! cmp -s code/SECURITY.md .github/SECURITY.md; then
    fail ".github/SECURITY.md differs from code/SECURITY.md; they must be identical (GitHub reads the first, the second is canonical)"
  fi
elif [ -f code/SECURITY.md ] || [ -f .github/SECURITY.md ]; then
  fail "SECURITY.md exists at only one of the two paths GitHub or a reader expects"
fi

if [ "$FAIL" -gt 0 ]; then
  printf '\npublished_docs.sh: %d problem(s). A document that is published is a document a\n' "$FAIL" >&2
  printf 'reader will check, so it has to be searched by the claims gate.\n' >&2
  exit 1
fi

printf '\npublished_docs.sh: OK — every published document is searched, every named\n'
printf 'document exists, and every stated version is %s.\n' "$MOD_VERSION"
