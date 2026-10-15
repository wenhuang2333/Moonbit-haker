#!/usr/bin/env python3
"""Probe this machine for LLM provider credentials, without ever printing one.

`code/tests/record_stream.py` can only record a live provider stream when a key
is present. The repository claims that no such key exists here, and a claim about
the absence of something is evidence only if it was produced by a check that can
also succeed. This script is that check, and its output is archived in
`code/docs/PROVIDER_PROBE.md`.

It looks, in order, at:

  1. environment variables: the five known provider names plus every other
     `*_API_KEY` / `*_TOKEN` variable;
  2. configuration files: `~/.config/**` and a short list of well known
     dotfiles (`~/.netrc` is handled separately);
  3. the macOS keychain: a curated service list plus the service names found in
     `security dump-keychain` (attributes only, never `-d`);
  4. `~/.netrc`, machine by machine.

Nothing secret is ever written: a hit is reported as its *location* and the
*length* of the value. The exit status is 0 when at least one LLM-provider
credential was found and 2 when none was; 1 is reserved for a usage failure.
A non-provider token (for example a CI token named `*_TOKEN`) is listed but does
not make the script succeed, because it cannot be used to record a model stream.

    python3 code/tests/probe_provider_creds.py
    python3 code/tests/probe_provider_creds.py --json      # machine readable
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

HOME = Path.home()

# The five names the repository documents, plus the spellings the official SDKs
# and CLIs use.
KNOWN_ENV = [
    "ANTHROPIC_API_KEY",
    "OPENAI_API_KEY",
    "DEEPSEEK_API_KEY",
    "MOONSHOT_API_KEY",
    "ARK_API_KEY",
    "CLAUDE_API_KEY",
    "OPENAI_API_TOKEN",
    "ANTHROPIC_AUTH_TOKEN",
    "DEEPSEEK_TOKEN",
    "MOONSHOT_TOKEN",
    "VOLC_ACCESSKEY",
    "DOUBAO_API_KEY",
]

# A variable only counts as a provider credential when its name looks like one.
PROVIDER_HINT = re.compile(
    r"anthropic|claude|openai|gpt|deepseek|moonshot|kimi|ark|volc|doubao|llm",
    re.IGNORECASE,
)
GENERIC_ENV = re.compile(r"(_API_KEY|_APIKEY|_TOKEN|_SECRET)$", re.IGNORECASE)

# Keychain services and hosts to try directly before falling back to discovery.
KEYCHAIN_SERVICES = [
    "anthropic",
    "anthropic-api-key",
    "api.anthropic.com",
    "claude",
    "openai",
    "openai-api-key",
    "api.openai.com",
    "deepseek",
    "api.deepseek.com",
    "moonshot",
    "api.moonshot.cn",
    "ark",
    "ark.cn-beijing.volces.com",
]
KEYCHAIN_HOSTS = [
    "api.anthropic.com",
    "api.openai.com",
    "api.deepseek.com",
    "api.moonshot.cn",
    "ark.cn-beijing.volces.com",
    "github.com",
]

# Dotfiles that plausibly hold a provider key and are cheap to read.
KNOWN_FILES = [
    ".netrc",
    "._netrc",
    ".env",
    ".envrc",
    ".claude.json",
    ".claude/settings.json",
    ".config/anthropic/config.json",
    ".config/openai/config.json",
    ".config/deepseek/config.json",
    ".config/moonshot/config.json",
    ".anthropic.json",
    ".openai.json",
]

ASSIGNMENT = re.compile(
    r"""(?ix)
    ["']?([A-Za-z0-9_.\-]*(?:api[_-]?key|apikey|token|secret|access[_-]?key)[A-Za-z0-9_.\-]*)["']?
    \s*[:=]\s*
    ["']?([A-Za-z0-9_\-./+]{12,})["']?
    """
)

MAX_FILE_BYTES = 1 << 20  # do not read a huge file looking for a key
MAX_CONFIG_FILES = 4000


class Report:
    """Accumulates findings; `found` drives the exit status."""

    def __init__(self) -> None:
        self.sections: list[tuple[str, list[str]]] = []
        self.rows: list[dict] = []
        self.found = 0
        # Key-looking fields that are not provider credentials; counted so the
        # report can say how much noise the scan produced without listing it.
        self.unrelated = 0

    def add(self, section: str, line: str, row: dict | None = None) -> None:
        for name, lines in self.sections:
            if name == section:
                lines.append(line)
                break
        else:
            self.sections.append((section, [line]))
        if row is not None:
            self.rows.append(row)

    def section(self, name: str) -> None:
        self.sections.append((name, []))

    def note(self, section: str, line: str) -> None:
        for name, lines in self.sections:
            if name == section:
                lines.append(line)
                return
        self.sections.append((section, [line]))


def hit(report: Report, section: str, where: str, kind: str, value: str,
        provider: bool) -> None:
    """Record one hit and, when it is a provider key, count it."""
    if value:
        report.add(
            section,
            "- FOUND  %s  (%s, length %d)" % (where, kind, len(value)),
            {"where": where, "kind": kind, "length": len(value),
             "provider": provider},
        )
        if provider:
            report.found += 1
    else:
        report.note(section, "- empty  %s  (%s, length 0)" % (where, kind))


def check_env(report: Report) -> None:
    report.section("1. Environment variables")
    seen = set()
    for name in KNOWN_ENV:
        seen.add(name)
        if name in os.environ:
            hit(report, report.sections[-1][0], name, "env", os.environ[name], True)
    extra = []
    for name, value in sorted(os.environ.items()):
        if name in seen or not GENERIC_ENV.search(name):
            continue
        extra.append((name, value))
    report.note(
        report.sections[-1][0],
        "- %d known provider variable(s) present, %d other *_API_KEY/_TOKEN variable(s)"
        % (len(KNOWN_ENV), len(extra)),
    )
    for name, value in extra:
        provider = bool(PROVIDER_HINT.search(name))
        label = "provider-like name" if provider else "unrelated token, not usable here"
        hit(report, report.sections[-1][0], name, "env, " + label, value, provider)


def looks_like_provider(path: Path, field: str) -> bool:
    """Whether a `field = value` pair is plausibly an LLM-provider credential."""
    scope = "%s %s" % (path, field)
    return bool(PROVIDER_HINT.search(scope))


def scan_file(path: Path, report: Report, section: str) -> None:
    """Report key-looking fields of one file. Values are measured, never shown."""
    try:
        if not path.is_file():
            return
        if path.stat().st_size > MAX_FILE_BYTES:
            report.note(section, "- skipped %s (larger than 1 MiB)" % path)
            return
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        report.note(section, "- unreadable %s (%s)" % (path, exc.strerror or exc))
        return
    found_any = False
    for match in ASSIGNMENT.finditer(text):
        field, value = match.group(1), match.group(2)
        found_any = True
        provider = looks_like_provider(path, field)
        if not provider:
            report.unrelated += 1
            continue
        report.add(
            section,
            "- FOUND  %s  (field %s, provider-like, length %d)"
            % (path, field, len(value)),
            {"where": str(path), "kind": "file field " + field,
             "length": len(value), "provider": True},
        )
        report.found += 1
    if not found_any:
        report.note(section, "- no key-looking field in %s" % path)


def check_config_files(report: Report) -> None:
    section = "2. Configuration files"
    report.section(section)
    for rel in KNOWN_FILES:
        if rel.startswith(".config/"):
            # covered by the ~/.config walk below
            candidate = HOME / rel
            if candidate.is_file():
                scan_file(candidate, report, section)
            continue
        candidate = HOME / rel
        if candidate.is_file():
            scan_file(candidate, report, section)
    counts = 0
    root = HOME / ".config"
    if not root.is_dir():
        report.note(section, "- %s does not exist" % root)
        return
    for path in sorted(root.rglob("*")):
        parts = set(path.parts)
        if "node_modules" in parts or ".git" in parts:
            continue
        if not path.is_file():
            continue
        if counts >= MAX_CONFIG_FILES:
            report.note(section, "- stopped after %d file(s)" % MAX_CONFIG_FILES)
            break
        counts += 1
        if path.stat().st_size > MAX_FILE_BYTES:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for match in ASSIGNMENT.finditer(text):
            field, value = match.group(1), match.group(2)
            if not looks_like_provider(path, field):
                report.unrelated += 1
                continue
            report.add(
                section,
                "- FOUND  %s  (field %s, provider-like, length %d)"
                % (path, field, len(value)),
                {"where": str(path), "kind": "file field " + field,
                 "length": len(value), "provider": True},
            )
            report.found += 1
    report.note(section, "- scanned %d file(s) under %s (node_modules and .git "
                        "skipped)" % (counts, root))


def security(args: list[str], timeout: int = 12) -> tuple[int, str]:
    if shutil.which("security") is None:
        return 127, ""
    try:
        proc = subprocess.run(
            ["security", *args],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 1, "%s" % exc
    return proc.returncode, proc.stdout


def check_keychain(report: Report) -> None:
    section = "3. macOS keychain"
    report.section(section)
    if shutil.which("security") is None:
        report.note(section, "- `security` is not installed; keychain not checked")
        return
    # Attributes only: `-w` prints the password, `-d` prints the data blob. Only
    # `-w` is used, and its output is never echoed, just measured.
    for service in KEYCHAIN_SERVICES:
        rc, out = security(["find-generic-password", "-s", service, "-w"])
        if rc == 0 and out.strip():
            hit(report, section, "generic-password service %s" % service,
                "keychain", out.strip(), provider=True)
    for host in KEYCHAIN_HOSTS:
        rc, out = security(["find-internet-password", "-s", host, "-w"])
        if rc == 0 and out.strip():
            provider = bool(PROVIDER_HINT.search(host))
            kind = "keychain internet-password"
            hit(report, section, "internet-password %s" % host, kind, out.strip(),
                provider)
    # Discovery: `security dump-keychain` without `-d` lists attributes, never
    # the secret. Only the service names are kept.
    rc, dump = security(["dump-keychain"], timeout=20)
    if rc != 0:
        report.note(section, "- `security dump-keychain` unavailable (rc=%d); "
                            "curated list used" % rc)
        return
    services = sorted(set(re.findall(r'"svce"<blob>="([^"]*)"', dump)))
    report.note(section, "- discovered %d keychain service name(s)" % len(services))
    checked = set()
    for service in services:
        if service in checked or service in KEYCHAIN_SERVICES:
            continue
        checked.add(service)
        if not re.search(r"anthropic|openai|claude|deepseek|moonshot|ark|gpt|llm|api",
                         service, re.IGNORECASE):
            continue
        rc, out = security(["find-generic-password", "-s", service, "-w"])
        if rc == 0 and out.strip():
            hit(report, section, "generic-password service %s" % service,
                "keychain (discovered)", out.strip(), provider=True)


def check_netrc(report: Report) -> None:
    section = "4. ~/.netrc"
    report.section(section)
    path = HOME / ".netrc"
    if not path.is_file():
        report.note(section, "- %s does not exist" % path)
        return
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        report.note(section, "- unreadable (%s)" % exc)
        return
    machines = re.findall(
        r"machine\s+(\S+)([^\n]*)", text, re.IGNORECASE
    )
    if not machines:
        report.note(section, "- %s has no `machine` entry" % path)
        return
    for machine, rest in machines:
        password = re.search(r"password\s+(\S+)", rest, re.IGNORECASE)
        provider = bool(PROVIDER_HINT.search(machine))
        if password:
            hit(report, section, "machine %s" % machine, "netrc",
                password.group(1), provider)
        else:
            report.note(section, "- machine %s has no password field" % machine)


def render(report: Report) -> str:
    out = ["# Provider credential probe", ""]
    for name, lines in report.sections:
        out.append("## " + name)
        out.extend(lines if lines else ["- (no findings)"])
        out.append("")
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true",
                    help="emit the findings as JSON instead of the report")
    args = ap.parse_args()

    report = Report()
    check_env(report)
    check_config_files(report)
    check_keychain(report)
    check_netrc(report)

    if args.json:
        print(json.dumps({"provider_credentials_found": report.found,
                          "unrelated_key_like_fields": report.unrelated,
                          "findings": report.rows}, indent=2))
    else:
        print(render(report))
        if report.found:
            print("RESULT: %d provider credential(s) found; a live recording is "
                  "possible with `code/tests/record_stream.py`."
                  % report.found)
        else:
            print("RESULT: no LLM-provider credential found; a live recording is "
                  "impossible here. Use `record_stream.py --loopback` instead.")
        if report.unrelated:
            print("(%d unrelated key-looking field(s) were counted and not "
                  "listed.)" % report.unrelated)
    return 0 if report.found else 2


if __name__ == "__main__":
    sys.exit(main())
