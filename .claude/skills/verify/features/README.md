# claudefuel verification map

This directory is the maintained source for verifying what a user sees in the claudefuel status bar. Read this index first, then use the matching feature file as the recipe. Commands are relative to the repo root. `R` stands for `.claude/skills/verify/bin/cf-render`.

## Baseline preconditions

- `.claude/skills/verify/bin/cf-doctor` exits 0.
- Every render goes through `cf-render`. It gives each render a fresh `.claude-<profile>` sandbox, so it has its own `/tmp/claude/*-<hash>*` caches and no reachable credentials.
- Never drive the user's live profiles (`~/.claude`, `~/.claude-*`) or the unsuffixed `/tmp/claude/statusline-*` files.

## Driving conventions

- Seed state through the cache options (`--usage`, `--prepaid`, `--upstream`, `--attempt-age`, `--retry-after-in`). Never edit `statusline.sh` to reach a state.
- Use `@now±SECS` in usage seeds for every `resets_at` the assertion depends on.
- Pass `--label <sub-feature-id>` so the evidence dir names what it proves.
- Assert on visible handles (`5h:`, `↻`, `~cap`, `⚠ updates`, `↗ /claudefuel.update`, `[profile]`, `●`/`○` counts). Use `run-N.colors.txt` for colors. Don't assert on column padding.
- Pin `--tz UTC` whenever an assertion includes a clock time.

## Proof and skip reporting

- Cite for each sub-feature: the evidence dir, the seed/stdin used, the relevant `run-N.txt` (or `.colors.txt`) lines, `net.log`, and `state-after/index.txt` when fetching or backoff is involved.
- A sub-feature that requires a real token, a real Claude Code session, or the user's `HOME` is reported as **not verified (needs user)**, with the reason. Never substitute a different path and call it verified.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior. Four H2 sections follow, in this order: `Sub-features`, `How to get to it (user POV)`, `Driving it with cf-render`, and `Gotchas`. The driving section starts with `Preconditions:`. Each labeled bullet in it pairs a user-visible situation with an exact command and the observable result.

## Features

- [Session line](./session-line.md) covers line 1: profile tag, model, context bar and token counts, thinking, and effort.
- [Usage bars](./usage-bars.md) covers lines 2 and 3: 5h/7d bars, weekly-only plans, reset times, color thresholds, and the prepaid `extra:` balance.
- [Cap-ETA](./cap-eta.md) covers the `~cap` prediction that appears when the 5h window burns faster than the reset pace.
- [Stale data and backoff](./stale-backoff.md) covers the stale warning, 429 cooldown, and fetch success through the usage API.
- [Update drift signal](./drift-signal.md) covers `↗ /claudefuel.update` on line 1 from the cached or live upstream version.
- [Multi-account isolation](./multi-account.md) covers per-`CLAUDE_CONFIG_DIR` caches, keychain service names, and profile labels.

Not yet mapped: the INSTALL.md Promptfile and the five `/claudefuel.*` commands (LLM-executed, write to `~/.claude`), and `setup.sh`. See "Not covered" in `../SKILL.md`.
