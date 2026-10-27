#!/usr/bin/env python3
"""Guard: the ambiguity suite can actually fail (evidence quality).

A suite that passes is only evidence if it *could* have failed. This script runs
the same comparison that `run_ambiguity.py` runs, twice:

  1. on the registered expectations — it must report 0 failures;
  2. on one deliberately wrong expectation — it must report at least that
     failure.

If step 1 fails, the suite is not green and the guard fails. If step 2 does not
fail, the comparison is vacuous (for example, because the rows are empty or the
expectation is not read) and the guard fails too. Exit status 0 only when both
hold.

    python3 code/tests/eval/check_amb_guard.py [--cli <path to interjson>]
"""

from __future__ import annotations

import argparse
import copy
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
sys.path.insert(0, HERE)

import run_ambiguity as ra  # noqa: E402

DEFAULT_CLI = os.path.join(
    ROOT, "_build", "native", "release", "build", "cmd", "interjson", "interjson.exe"
)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", default=DEFAULT_CLI)
    args = ap.parse_args()

    default_rows = ra.run_interjson(args.cli, ra.CASES)
    gate_rows = ra.run_interjson(args.cli, ra.CASES, extra=["--for-execution"])

    real, _ = ra.compare(ra.CASES, default_rows, gate_rows)
    print("registered expectations: %d failure(s)" % len(real))
    if real:
        for f in real:
            print("  " + f)
        print("GUARD FAIL: the registered suite is not green.")
        return 1

    # A wrong expectation must be caught. The gate of an ambiguous case is
    # flipped to OK, which the real run cannot satisfy.
    tampered = copy.deepcopy(ra.CASES)
    victim = next(c for c in tampered if c["gate"] == "E011")
    victim["gate"] = "OK"
    fake, _ = ra.compare(tampered, default_rows, gate_rows)
    print("tampered expectation (%s gate -> OK): %d failure(s)" % (victim["id"], len(fake)))
    if not fake:
        print("GUARD FAIL: a wrong expectation was accepted, so the suite is vacuous.")
        return 1
    print("GUARD PASS: the comparison is non-vacuous and the suite is green.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
