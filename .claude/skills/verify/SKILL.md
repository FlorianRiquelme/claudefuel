---
name: verify
description: Drive claudefuel's status bar (statusline.sh) the way Claude Code does — JSON payload on stdin, 3-line ANSI bar on stdout — in a throwaway profile with the network fenced, and capture evidence. Use to prove a change to the bar (context line, 5h/7d/extra usage, reset times, cap-ETA, stale warning/backoff, drift signal, multi-account isolation) works, beyond what the bats suite asserts.
---

# Verify claudefuel

claudefuel is a single bash script, `statusline.sh`, that Claude Code executes on every status-bar refresh. Claude Code pipes a JSON payload on stdin. The script prints up to three lines of ANSI text and exits. No server runs and nothing stays alive between renders. State lives in cache files:

- `/tmp/claude/statusline-*-<hash>*` holds the usage, prepaid, attempt, retry-after, and lock files. `<hash>` is the first 8 hex chars of `sha256($CLAUDE_CONFIG_DIR)`.
- `$CLAUDE_CONFIG_DIR/cache/claudefuel-version.json` is the drift cache.

The script reaches the outside world in three places: the usage and prepaid APIs at `api.anthropic.com` (gated by the cache), the macOS keychain (`security`) or GNOME keyring (`secret-tool`) for the OAuth token, and `raw.githubusercontent.com` for the drift check.

The harness is `bin/cf-render`. For every render it does the following:

1. It creates a fresh `mktemp` profile dir named `.claude-<profile>`, which gives a fresh hash and isolated caches.
2. It seeds caches through the same files the script reads in production.
3. It puts logging shims for `curl`, `security`, and `secret-tool` first on `PATH`. The shims fail every call, so no real token is resolvable and no request leaves the machine.
4. It runs the script with `env -i`, so nothing leaks in from your shell: no inherited `CLAUDE_CODE_OAUTH_TOKEN` and no `CLAUDE_CONFIG_DIR`.
5. It files the evidence and deletes exactly the sandbox files it created.

All paths below are relative to the repo root.

## Launch

Nothing to build or start. Launch means: dependencies present, script healthy.

```bash
.claude/skills/verify/bin/cf-doctor        # must exit 0 before any drive
```

Each drive is its own short-lived, isolated render. Concurrent renders are safe because each one gets its own hash. Teardown is automatic (an `EXIT` trap). See Cleanup for crashed runs.

Never run `statusline.sh` by hand without `CLAUDE_CONFIG_DIR`, and never with your real one. The unsuffixed files (`/tmp/claude/statusline-usage-cache.json` etc.) and your real profiles' hashed files belong to the bars of your live Claude Code sessions. Writing to them corrupts what those bars show, and a real token there makes real API calls against an account-wide rate limit.

## Doctor

`.claude/skills/verify/bin/cf-doctor [--script PATH]` is read-only. It prints PASS/FAIL/WARN for these checks:

- The script exists, is executable, and has a parseable `# claudefuel: vX.Y.Z` header in its first 20 lines.
- `bash -n` passes, and the shebang is `#!/bin/bash`. On macOS that is bash 3.2, the version users run.
- `jq`, `shasum`, and `curl` are on `PATH`.
- `shellcheck -S warning` is clean. This is the CI gate; a failure here is a WARN, not a FAIL.
- `/tmp/claude` is writable.
- It reports the git revision and whether `statusline.sh` is dirty.
- It reports stranded sandboxes from crashed renders.

Run it first, and again whenever output looks wrong.

## Drive

```bash
.claude/skills/verify/bin/cf-render --help          # full option list
.claude/skills/verify/bin/cf-render --label <feature-id> [options]
```

It prints each render as plain text, then the fenced-call log, and finally the evidence directory on the last line. It exits 0 only if every render exited 0.

| Option | What it sets up |
|---|---|
| `--stdin @FILE\|JSON` | Claude Code payload. Default `fixtures/stdin-full.json`: Opus 5.5, 50k/200k ctx, thinking on, effort high. `fixtures/stdin-minimal.json` is INSTALL.md's smoke payload. |
| `--profile NAME` | Profile dir `.claude-NAME`, so line 1 shows `[NAME]`. Default `verify`. |
| `--usage @FILE\|JSON` | Seeds the usage cache in the shape of `GET /api/oauth/usage`. Strings `"@now+SECS"`/`"@now-SECS"` become ISO UTC times, so reset and cap-ETA math stays relative to the render. |
| `--usage-age SECS` | Back-dates the usage cache. ≥300 makes it due for refresh; ≥900 (3× the 300 s cadence) shows the stale warning. |
| `--prepaid @FILE\|JSON` | Seeds the prepaid cache, e.g. `{"amount":4250,"currency":"EUR"}` (amount in cents). |
| `--upstream VER` / `--no-upstream` | Seeds the drift cache. Default: the script's own version, which means no drift. `--no-upstream` is first run. |
| `--attempt-age SECS`, `--retry-after-in SECS` | Pre-existing fetch-attempt marker and 429 cooldown deadline. |
| `--api STATUS[:RETRY_AFTER]` + `--api-body @FILE` | Fakes the usage API at the HTTP boundary. A dummy token is supplied, and the `curl` shim answers `https://api.anthropic.com/api/oauth/usage`. |
| `--allow-github` | Lets the drift check really fetch `raw.githubusercontent.com/.../main/statusline.sh` (a public read). Unsets `CLAUDEFUEL_OFFLINE`. |
| `--repeat N` | N renders in one sandbox. Use it to prove backoff: render 2 must not call `curl`. |
| `--tz ZONE` | Pins `TZ` for reset-time strings. Default: inherit. |
| `--script PATH` | Script under test. Default `statusline.sh` in this checkout. Point it at `~/.claude/statusline.sh` to check an installed copy. |

Usage fixtures live in `.claude/skills/verify/fixtures/`:

| Fixture | 5h | 7d | Other |
|---|---|---|---|
| `usage-healthy.json` | 35%, resets in 1h | 62% | extra enabled |
| `usage-weekly-only.json` | `null` | 41% | extra disabled |
| `usage-burning.json` | 60% with 3h left | — | cap-ETA fires |
| `usage-critical.json` | 95% | 91% | red bars |
| `usage-api-ok.json` | — | — | 200 response body for `--api` |

Assert on the stable handles the user reads:

- Line 1: `[profile]`, the model name, `ctx`, `<used>/<total>`, `thinking: On|Off`, `effort: <level>`, `↗ /claudefuel.update`.
- Line 2: `5h:`, `7d:`, `extra:`, `⚠ updates ~<time>`, `⚠ updates soon`.
- Line 3: `↻`, `~cap <lo>-<hi>`.
- Bars use `●` (filled) and `○` (empty), 10 cells each.

Don't assert on column padding. Feature recipes live in `features/README.md`.

## Evidence

Each render writes `.verify-evidence/<YYYYmmdd-HHMMSS>-<label>/` (gitignored; override the root with `VERIFY_EVIDENCE_DIR`). The directory contains:

- `stdin.json`, `usage-seed.json`, `prepaid-seed.json`, `api-body.json`: the inputs exactly as fed.
- `run-N.ansi`: raw bytes as Claude Code would receive them.
- `run-N.txt`: the same output with ANSI stripped.
- `run-N.colors.txt`: escapes replaced by `{green}…{/}`, `{orange}`, `{yellow}`, `{red}`, `{cyan}`, `{blue}`, `{white}`, `{dim}`. Use this file to prove color thresholds.
- `run-N.exit`, `run-N.stderr`.
- `net.log`: one line per fenced call (`curl <url>`, `security find-generic-password -s <service> …`). This is the network side effect. An empty file means nothing left the machine and no keychain read happened.
- `state-after/`: copies of every cache file the script left for this profile, plus `index.txt` with their ages. This is the filesystem side effect: caches written, attempt markers touched, retry-after deadlines.
- `manifest.txt`: script path and version, git revision (`+dirty` if `statusline.sh` changed), profile, `CLAUDE_CONFIG_DIR`, cache hash, TZ, render time, network mode.

Proof standards:

- **Real path.** The bar under test is driven exactly as Claude Code drives it: exec'd directly, payload on stdin. Never source the script or call its functions.
- **Action and result.** Cite the inputs (seed and stdin) next to the rendered lines, not just the final text.
- **Side effects.** For fetch, backoff, and drift behavior, assert on `net.log` and `state-after/`, not just on what the bar shows. A bar can look right while it hammers the API.
- **Mocks only at the HTTP boundary.** Seeded caches are the production seam the script reads. `--api` fakes only the external endpoint. Never edit the script, and never stub its internals, to reach a state.
- **Offline mode is checked by observing.** `CLAUDEFUEL_OFFLINE=1` skips the drift and prepaid fetches but not the usage fetch or the token lookup. `net.log` shows the `security` lookups it still performs. Trust the log, not the flag's name.

## Cleanup

Each render removes its own sandbox (the `mktemp` profile dir plus `/tmp/claude/statusline-*-<hash>*`) on exit, and it keeps the evidence. If a render was killed, run:

```bash
.claude/skills/verify/bin/cf-cleanup                    # sweeps hashes recorded in .verify-evidence/.instances
.claude/skills/verify/bin/cf-cleanup --purge-evidence   # also deletes .verify-evidence/ (only when asked)
```

It never kills processes and never touches files outside the recorded hashes. A killed render can leave a `statusline.sh` child running for up to ~5 s (the curl `--max-time`), and that child can recreate a cache file. Wait 5 s before you run cleanup.

## Not covered by this harness

- **Claude Code itself calling the script.** The harness feeds payloads in the documented shape. To refresh a fixture from a real session, ask the user to temporarily set their own `statusLine.command` to `tee /tmp/cf-payload.json | ~/.claude/statusline.sh` and send you the file. Don't edit their settings yourself.
- **The INSTALL.md Promptfile and `/claudefuel.*` commands.** These are LLM-executed, and their contract is linted by `tests/install-bundle.bats` and `tests/skills.bats`. A real run writes to `~/.claude` and fetches from `main`, not from this checkout. Do it only with the user's OK.
- **`setup.sh`.** It writes `~/.claude-<name>` dirs and appends aliases to the shell rc. Nobody has checked yet whether `--dry-run` writes nothing. Before you trust it, run it with `HOME` pointed at a scratch dir that has a `.claude/` and an empty `.zshrc`, and diff the file tree before and after. Never run it against the real `HOME` without the user's OK.
- **Live usage numbers.** These need the user's real token. The fenced harness can't reach them, by design.
