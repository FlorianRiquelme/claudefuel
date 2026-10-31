# Multi-account isolation

A user running several Claude Code profiles (`CLAUDE_CONFIG_DIR=~/.claude-work`, `~/.claude-personal`, …) sees each tab's own usage and profile name. Caches and keychain lookups are keyed by a hash of the config dir, so profiles never bleed into each other.

## Sub-features

- `multi-label` puts `[<name>]` on line 1 from `.claude-<name>`.
- `multi-cache-isolation` gives each profile its own `/tmp/claude/statusline-*-<first8 sha256(dir)>*` files and shows its own numbers.
- `multi-keychain-service` looks up the keychain service `Claude Code-credentials-<first8 sha256(dir)>` for each profile, under the OS username and then `Claude Code`.

## How to get to it (user POV)

- Open two terminal tabs with different `CLAUDE_CONFIG_DIR` values and the same symlinked `statusline.sh`. Each bar shows its own profile tag and usage.

## Driving it with cf-render

Preconditions:

- `cf-doctor` exits 0.

- **Two profiles, different usage.** Run `R --label multi-work --profile work --usage @.claude/skills/verify/fixtures/usage-healthy.json`, then `R --label multi-personal --profile personal --usage @.claude/skills/verify/fixtures/usage-critical.json`. The first shows `[work]` with 35%/62%. The second shows `[personal]` with 95%/91%. The two `manifest.txt` `cache_hash` values differ, and each `state-after/index.txt` lists only its own hash.
- **Keychain service derivation.** Render with no usage seed, so the script must resolve a token. Run `R --label multi-keychain-service --profile work`. Compute `printf '%s' "<claude_config_dir from manifest>" | shasum -a 256 | cut -c1-8`. It equals `cache_hash`, and `net.log` shows `security find-generic-password -s Claude Code-credentials-<that hash> -a <os user> -w` followed by `-a Claude Code -w`.
- **Proof.** Cite both manifests, both `run-1.txt` line 1–2 pairs, and `net.log`.

## Gotchas

- A fresh seeded usage cache skips token resolution entirely, so `net.log` is empty. Keychain lookups show up only when there is no cache, or the cache is stale and a fetch is due.

- cf-render's profile dirs live under `$TMPDIR`, not `$HOME`. The hash differs from a real `~/.claude-work`. To check the README's example hashes, compute `printf '%s' "$HOME/.claude-work" | shasum -a 256 | cut -c1-8` yourself. Never render against that dir.
- The default `~/.claude` profile (no `CLAUDE_CONFIG_DIR`) uses the unsuffixed service and cache names that the user's live bar uses. The harness deliberately cannot drive it.
- On Linux the GNOME-keyring fallback looks up the unsuffixed `Claude Code-credentials` service. That is a cross-profile leak path, and it shows in `net.log` as a `secret-tool lookup service Claude Code-credentials` line.
