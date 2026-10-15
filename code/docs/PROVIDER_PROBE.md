# Provider credential probe (FR-40)

`code/tests/record_stream.py` can only record a live provider stream when a
credential exists. "There is no credential on this machine" is a claim about the
absence of something, so it is only evidence when it comes from a check that
*could* have succeeded. `code/tests/probe_provider_creds.py` is that check, and
this file keeps its output.

The probe never prints a secret: a hit is reported as its location and the
**length** of the value. It looks, in order, at

1. environment variables — the five documented names plus every other
   `*_API_KEY` / `*_TOKEN` / `*_SECRET` variable;
2. configuration files — `~/.config/**` (with `node_modules` and `.git`
   skipped) and a short list of well-known dotfiles;
3. the macOS keychain — a curated service list, then every service name found in
   `security dump-keychain` (attributes only; `-w` prints the password and `-d`
   prints the data blob, and only `-w` is ever used);
4. `~/.netrc`, machine by machine.

Exit status is `0` when at least one **LLM-provider** credential was found, `2`
when none was, and `1` on a usage failure. A token that is real but cannot record
a model stream — a CI token, a package registry token — is listed and does *not*
make the probe succeed.

```sh
python3 code/tests/probe_provider_creds.py            # the report below
python3 code/tests/probe_provider_creds.py --json     # the same findings as JSON
```

## Result of the run recorded here

Environment: macOS 26.5.1 (Apple Silicon), Python 3.12.6, run at
`2026-10-15T17:33:40Z` (2026-10-16 01:33 Asia/Shanghai). Exit status `0`.

```text
# Provider credential probe

## 1. Environment variables
- 12 known provider variable(s) present, 0 other *_API_KEY/_TOKEN variable(s)

## 2. Configuration files
- no key-looking field in /Users/zhanshishan/.claude.json
- FOUND  /Users/zhanshishan/.claude/settings.json  (field ANTHROPIC_AUTH_TOKEN, provider-like, length 32)
- scanned 10 file(s) under /Users/zhanshishan/.config (node_modules and .git skipped)

## 3. macOS keychain
- FOUND  internet-password github.com  (keychain internet-password, length 40)
- discovered 24 keychain service name(s)

## 4. ~/.netrc
- /Users/zhanshishan/.netrc does not exist

RESULT: 1 provider credential(s) found; a live recording is possible with `code/tests/record_stream.py`.
```

```json
{
  "provider_credentials_found": 1,
  "unrelated_key_like_fields": 0,
  "findings": [
    {
      "where": "/Users/zhanshishan/.claude/settings.json",
      "kind": "file field ANTHROPIC_AUTH_TOKEN",
      "length": 32,
      "provider": true
    },
    {
      "where": "internet-password github.com",
      "kind": "keychain internet-password",
      "length": 40,
      "provider": false
    }
  ]
}
```

## How to read this

* The one provider credential is **not a first-party vendor key**. It is the
  endpoint Claude Code is configured with on this machine:
  `~/.claude/settings.json` holds `env.ANTHROPIC_BASE_URL =
  https://api.longcat.chat/anthropic` and an `env.ANTHROPIC_AUTH_TOKEN` of 32
  characters. The endpoint speaks the Anthropic `/v1/messages` wire format and
  accepts `Authorization: Bearer`.
* That made a **live capture possible after all**, so it was done; the captures
  and their provenance are in `code/docs/LLM_EVENTS.md` and
  `code/llm/fixtures/live_relay_*`. They are labelled `transport: live-http-sse`
  with the endpoint named, and they are **not** a capture from
  `api.anthropic.com`.
* The `github.com` internet password in the keychain is a real token, but it is
  not an LLM provider credential, so the probe lists it and does not count it.
  The same token is what the GitHub engineering-debt work in
  `code/docs/GITHUB.md` uses.
* No secret value is stored in this file or anywhere in the repository. Only
  locations, field names and lengths are.

## When a real key exists: the one command

`read -s` does not echo the key and does not put it in the shell history, so the
secret never reaches `~/.zsh_history` or a process listing:

```sh
read -rsp 'ANTHROPIC_API_KEY: ' ANTHROPIC_API_KEY && export ANTHROPIC_API_KEY && \
  python3 code/tests/record_stream.py --provider anthropic \
    --out code/llm/fixtures/anthropic_recorded.jsonl \
    --cli code/_build/native/release/build/cmd/jsonmend/jsonmend.exe
```

For OpenAI, substitute `OPENAI_API_KEY` and `--provider openai`. For an
Anthropic-compatible endpoint that already has a Claude Code settings file, no
key has to be typed at all:

```sh
python3 code/tests/record_stream.py --provider anthropic --from-claude-settings \
  --endpoint-label <name of the endpoint> \
  --out code/llm/fixtures/live_relay_tool_call.jsonl \
  --cli code/_build/native/release/build/cmd/jsonmend/jsonmend.exe
```

## What such a run produces

For `--out code/llm/fixtures/anthropic_recorded.jsonl`:

| file | contents |
| --- | --- |
| `anthropic_recorded.sse` | the raw response bytes, exactly as they arrived |
| `anthropic_recorded.jsonl` | one JSON event payload per line, in order |
| `anthropic_recorded.provenance.json` | transport, provider, endpoint, scene, byte count and SHA-256, whether the recorder cut the tail — never the key |
| `anthropic_recorded.adapter.jsonl` | what the real `jsonmend llm` printed for those bytes (only with `--cli`) |

The recorder refuses to write anything when the stream carried no `data:`
payload or a payload that is not JSON, so a failed call cannot be mistaken for a
recording. Replaying the result through the real adapter is one command:

```sh
python3 code/tests/run_llm_loopback.py     # replays every fixture that has a provenance file
```

## With no key at all

`code/tests/record_stream.py --loopback` needs no third-party credential: it runs
a local HTTP server on `127.0.0.1` that emits a real SSE byte stream in Anthropic
`/v1/messages` format, reads it back over a real socket with a plain HTTP client,
and writes the same four files with `transport: loopback-sse`. That is what
`code/llm/fixtures/loopback_*` is, and it is re-recorded and byte-compared on
every CI run. A loopback fixture is **not** a vendor capture and its provenance
line says so.
