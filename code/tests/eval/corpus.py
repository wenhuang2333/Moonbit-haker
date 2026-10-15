#!/usr/bin/env python3
"""Ground-truth corpus for the JSONMend evaluation (I-4).

Every case is produced together with the correct answer, computed from the value
tree *before* the mutation. Neither JSONMend nor any oracle is consulted, so
"the result differs from the truth" is a fact rather than an opinion.

The protocol is pre-registered in `code/docs/EVAL_REGISTRATION.md`; this file is
`eval-1` of that registration and must stay deterministic.
"""

from __future__ import annotations

import copy
import hashlib
import json
import random

VERSION = "eval-2"
SEED = 20261015
TARGET = 1200

# ---------------------------------------------------------------- documents --

KEYS = [
    "a", "b", "id", "n", "value", "type", "msg", "count", "flag", "items",
    "名字", "ключ", "emoji\U0001F600", "k1", "longer_key_name",
]
STRINGS = [
    "x", "", "hello world", "it's fine", "quote\"inside", "tab\there",
    "line\nbreak", "caf\u00e9", "\U0001F600 emoji", "\u4e2d\u6587\u6587\u672c",
    "back\\slash", "0123456789" * 4,
]
NUMBERS = [0, 1, -1, 42, -17, 1000000, 3.5, -0.25, 12.125, 1000.5]


def gen_value(rng: random.Random, depth: int, budget: list[int]):
    """A random JSON value; `budget` caps the total node count."""
    budget[0] -= 1
    if depth >= 5 or budget[0] <= 0:
        return scalar(rng)
    r = rng.random()
    if r < 0.35:
        return scalar(rng)
    if r < 0.7:
        n = rng.randint(0, min(4, max(0, budget[0])))
        return [gen_value(rng, depth + 1, budget) for _ in range(n)]
    n = rng.randint(0, min(4, max(0, budget[0])))
    keys = rng.sample(KEYS, min(n, len(KEYS)))
    return {k: gen_value(rng, depth + 1, budget) for k in keys}


def scalar(rng: random.Random):
    r = rng.random()
    if r < 0.4:
        return rng.choice(STRINGS)
    if r < 0.75:
        return rng.choice(NUMBERS)
    if r < 0.85:
        return True
    if r < 0.95:
        return False
    return None


def render(value) -> tuple[str, dict]:
    """Render compactly and return (text, spans) with spans[path] = (start, end)."""
    out: list[str] = []
    pos = 0
    spans: dict[tuple, tuple[int, int]] = {}

    def emit(s: str) -> None:
        nonlocal pos
        out.append(s)
        pos += len(s)

    def walk(v, path: tuple) -> None:
        start = pos
        if isinstance(v, dict):
            emit("{")
            for i, (k, val) in enumerate(v.items()):
                if i:
                    emit(",")
                emit(json.dumps(k, ensure_ascii=False))
                emit(":")
                walk(val, path + (k,))
            emit("}")
        elif isinstance(v, list):
            emit("[")
            for i, val in enumerate(v):
                if i:
                    emit(",")
                walk(val, path + (i,))
            emit("]")
        else:
            emit(json.dumps(v, ensure_ascii=False))
        spans[path] = (start, pos)

    walk(value, ())
    return "".join(out), spans


def children(value, path: tuple):
    """Child paths of the container at `path`."""
    node = get_at(value, path)
    if isinstance(node, dict):
        return [path + (k,) for k in node]
    if isinstance(node, list):
        return [path + (i,) for i in range(len(node))]
    return []


def containers(value, path: tuple = ()):
    """Every container path, deepest last."""
    node = get_at(value, path)
    out = []
    if isinstance(node, (dict, list)):
        out.append(path)
        for cp in children(value, path):
            out.extend(containers(value, cp))
    return out


def get_at(value, path: tuple):
    node = value
    for step in path:
        node = node[step]
    return node


def set_at(value, path: tuple, new):
    """Return `value` with the node at `path` replaced by `new`."""
    if not path:
        return new
    node = value
    for step in path[:-1]:
        node = node[step]
    node[path[-1]] = new
    return value


def drop_child(value, path: tuple, key):
    node = get_at(value, path)
    if isinstance(node, dict):
        del node[key]
    else:
        del node[key]


def prune_after(value, spans, cut: int):
    """Drop every node that starts at or after `cut` in document order.

    A cut inside a nested container removes the tail of *every* ancestor, which
    is what "the provider stopped sending here" means. Truncating only the
    innermost container would claim a value the input never contained.
    """
    def walk(node, path):
        if isinstance(node, dict):
            for k in list(node):
                p = path + (k,)
                if spans[p][0] >= cut:
                    del node[k]
                else:
                    walk(node[k], p)
        elif isinstance(node, list):
            for i in reversed(range(len(node))):
                p = path + (i,)
                if spans[p][0] >= cut:
                    del node[i]
                else:
                    walk(node[i], p)

    walk(value, ())
    return value


def path_pretty(path: tuple) -> str:
    return "/" + "/".join(str(p) for p in path) if path else "/"


# ---------------------------------------------------------------- mutations --


def tokens(text: str):
    """Positions just after a structural token, outside strings."""
    out = []
    in_str = False
    esc = False
    for i, ch in enumerate(text):
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
        else:
            if ch == '"':
                in_str = True
            elif ch in "{}[],:":
                out.append(i + 1)
    return out


def m_ws(rng, text, value, spans):
    pos = tokens(text)
    if not pos:
        return None
    i = rng.choice(pos)
    return text[:i] + rng.choice([" ", "\n", "  ", "\t"]) + text[i:], value


def m_quotes(rng, text, value, spans):
    # A backslash or an apostrophe inside a string makes the mutated text
    # ambiguous (`'it's'` can be read two ways), so those documents are not
    # valid instances of this family.
    if "\\" in text or "'" in text:
        return None
    return text.replace('"', "'"), value


def m_trailing_comma(rng, text, value, spans):
    pos = [i for i, ch in enumerate(text) if ch in "}]"]
    if not pos:
        return None
    i = rng.choice(pos)
    return text[:i] + "," + text[i:], value


def m_double_comma(rng, text, value, spans):
    pos = [i for i, ch in enumerate(text) if ch == ","]
    if not pos:
        return None
    i = rng.choice(pos)
    return text[:i] + ",," + text[i + 1 :], value


BARE = set("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ+-._")


def m_delete_comma(rng, text, value, spans):
    # Two bare neighbours would merge into one token (`[1,2]` -> `[12]`, a valid
    # document with a different meaning), so the missing comma would be
    # unobservable. Require at least one neighbour to be a container or a
    # string, which is the case the repair can detect.
    pos = [
        i
        for i, ch in enumerate(text)
        if ch == ","
        and i > 0
        and i + 1 < len(text)
        and not (text[i - 1] in BARE and text[i + 1] in BARE)
    ]
    if not pos:
        return None
    i = rng.choice(pos)
    return text[:i] + text[i + 1 :], value


def m_delete_colon(rng, text, value, spans):
    pos = [i for i, ch in enumerate(text) if ch == ":"]
    if not pos:
        return None
    i = rng.choice(pos)
    return text[:i] + text[i + 1 :], value


def m_fence(rng, text, value, spans):
    return "```json\n" + text + "\n```", value


def m_prose(rng, text, value, spans):
    # `--skip-prose` looks for the first container, so a scalar root preceded by
    # prose is not a well defined case; see EVAL_REGISTRATION.md 10.
    if not containers(value):
        return None
    return "Sure! Here is the JSON you asked for:\n" + text, value


def m_comment(rng, text, value, spans):
    return text + " // done", value


def m_bom(rng, text, value, spans):
    return "\ufeff" + text, value


def m_dup_key(rng, text, value, spans):
    cands = [p for p in spans if p and isinstance(get_at(value, p[:-1]), dict)]
    if not cands:
        return None
    p = rng.choice(cands)
    start, end = spans[p]
    key = json.dumps(p[-1], ensure_ascii=False)
    return text[:end] + "," + key + ":" + text[start:end] + text[end:], value


def m_mismatched_closer(rng, text, value, spans):
    cs = containers(value)
    if not cs:
        return None
    p = cs[-1]
    start, end = spans[p]
    close = text[end - 1]
    other = "]" if close == "}" else "}"
    return text[: end - 1] + other + text[end:], value


def m_extra_closer(rng, text, value, spans):
    if not containers(value):
        return None
    return text + ("]" if text[0] == "[" else "}"), value


LITERALS = [("true", "True"), ("false", "False"), ("null", "None")]


def m_literal_case(rng, text, value, spans):
    cands = []
    in_str = False
    esc = False
    for i, ch in enumerate(text):
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
        elif text.startswith("true", i) or text.startswith("false", i) or text.startswith("null", i):
            cands.append(i)
    if not cands:
        return None
    i = rng.choice(cands)
    for src, dst in LITERALS:
        if text.startswith(src, i):
            return text[:i] + dst + text[i + len(src) :], value
    return None


def m_control_char(rng, text, value, spans):
    cands = [p for p in spans if isinstance(get_at(value, p), str)]
    if not cands:
        return None
    p = rng.choice(cands)
    start, end = spans[p]
    ch = rng.choice(["\x01", "\x1f", "\x0b"])
    new_value = set_at(copy.deepcopy(value), p, ch + get_at(value, p))
    return text[: start + 1] + ch + text[start + 1 :], new_value


def m_missing_value(rng, text, value, spans):
    cands = [p for p in spans if p and isinstance(get_at(value, p[:-1]), dict)]
    if not cands:
        return None
    p = rng.choice(cands)
    start, end = spans[p]
    new_value = copy.deepcopy(value)
    set_at(new_value, p, None)
    return text[:start] + text[end:], new_value


def m_ellipsis(rng, text, value, spans):
    cands = [p for p in spans if p and isinstance(get_at(value, p[:-1]), (dict, list))]
    if not cands:
        return None
    p = rng.choice(cands)
    start, end = spans[p]
    new_value = copy.deepcopy(value)
    drop_child(new_value, p[:-1], p[-1])
    return text[:start] + "..." + text[end:], new_value


def m_truncate_child(rng, text, value, spans):
    cs = containers(value)
    if not cs:
        return None
    p = rng.choice(cs)
    kids = children(value, p)
    if not kids:
        return None
    k = rng.randrange(len(kids))
    cut = spans[kids[k]][1]
    new_value = copy.deepcopy(value)
    prune_after(new_value, spans, cut)
    return text[:cut], new_value


def _safe_cuts(literal: str):
    """Positions inside a JSON string literal that are not inside an escape."""
    out = []
    i = 1
    while i < len(literal) - 1:
        if literal[i] == "\\":
            i += 2
            continue
        out.append(i + 1)
        i += 1
    return out


def m_truncate_string(rng, text, value, spans):
    cs = containers(value)
    if not cs:
        return None
    p = rng.choice(cs)
    kids = [k for k in children(value, p) if isinstance(get_at(value, k), str)]
    if not kids:
        return None
    kp = rng.choice(kids)
    start, end = spans[kp]
    literal = text[start:end]
    cuts = _safe_cuts(literal)
    if not cuts:
        return None
    cut = start + rng.choice(cuts)
    partial = json.loads(text[start:cut] + '"')
    new_value = copy.deepcopy(value)
    prune_after(new_value, spans, cut)
    set_at(new_value, kp, partial)
    return text[:cut], new_value


FAMILIES = {
    "ws": m_ws,
    "quotes": m_quotes,
    "trailing_comma": m_trailing_comma,
    "double_comma": m_double_comma,
    "delete_comma": m_delete_comma,
    "delete_colon": m_delete_colon,
    "fence": m_fence,
    "prose": m_prose,
    "comment": m_comment,
    "bom": m_bom,
    "dup_key": m_dup_key,
    "mismatched_closer": m_mismatched_closer,
    "extra_closer": m_extra_closer,
    "literal_case": m_literal_case,
    "control_char": m_control_char,
    "missing_value": m_missing_value,
    "ellipsis": m_ellipsis,
    "truncate_child": m_truncate_child,
    "truncate_string": m_truncate_string,
}

# Families whose repair only touches notation: the answer must be recoverable
# and the label must not be `lossy`.
NOTATION = [
    "ws", "quotes", "trailing_comma", "double_comma", "delete_comma",
    "delete_colon", "fence", "prose", "comment", "bom", "dup_key",
    "mismatched_closer", "extra_closer", "literal_case", "control_char",
]
# Families that drop or invent information: the label must be `lossy`.
LOSSY = ["missing_value", "ellipsis", "truncate_child", "truncate_string"]


def build(target: int = TARGET, seed: int = SEED):
    """Return the corpus: a list of dicts, deterministic for (target, seed).

    Families are filled round robin up to an equal quota, so a family that
    often cannot be applied to a random document (for instance `quotes` needs a
    document without a backslash) still contributes its share.
    """
    rng = random.Random(seed)
    names = ["clean"] + list(FAMILIES)
    want = {f: target // len(names) for f in names}
    for f in names[: target % len(names)]:
        want[f] += 1
    corpus = []
    excluded = 0
    for family in names:
        made = 0
        attempts = 0
        while made < want[family] and attempts < want[family] * 500:
            attempts += 1
            budget = [rng.randint(4, 40)]
            value = gen_value(rng, 0, budget)
            text, spans = render(value)
            if len(text) > 4096:
                continue
            if family == "clean":
                mutated, truth = text, value
            else:
                result = FAMILIES[family](rng, text, copy.deepcopy(value), spans)
                if result is None or result[0] == text:
                    excluded += 1
                    continue
                mutated, truth = result
                # Except for whitespace (provably insignificant) and an
                # identical duplicate key (provably value preserving), the
                # mutated text must no longer be valid JSON: otherwise the
                # damage is invisible and the truth claim would be unjustified.
                if family not in ("ws", "dup_key"):
                    try:
                        json.loads(mutated)
                        excluded += 1
                        continue
                    except ValueError:
                        pass
            corpus.append(
                {
                    "id": "e-%04d" % len(corpus),
                    "family": family,
                    "input": mutated,
                    "truth": truth,
                    "note": "",
                }
            )
            made += 1
    return corpus, excluded


def fingerprint(corpus) -> str:
    h = hashlib.sha256()
    for case in corpus:
        h.update(
            json.dumps(
                [case["id"], case["family"], case["input"], case["truth"]],
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        )
        h.update(b"\n")
    return h.hexdigest()


if __name__ == "__main__":
    import sys

    cases, skipped = build()
    out = sys.argv[1] if len(sys.argv) > 1 else "corpus.jsonl"
    with open(out, "w", encoding="utf-8") as fh:
        for c in cases:
            fh.write(json.dumps(c, ensure_ascii=False, sort_keys=True) + "\n")
    print(
        "%d cases (%d generation attempts skipped), sha256 %s"
        % (len(cases), skipped, fingerprint(cases))
    )
