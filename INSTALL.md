# claudefuel — install / upgrade spec

Version: `0.4.0`
Canonical URL: `https://raw.githubusercontent.com/FlorianRiquelme/claudefuel/main/INSTALL.md`
Source: `https://github.com/FlorianRiquelme/claudefuel`

This file is a **Promptfile**: it is written for an LLM agent to read and execute on the user's machine. It is also human-readable — a person can perform the same steps by hand. **Install and upgrade are the same operation** — reconcile the current state of the user's machine with the desired state declared below.

## What this installs

`claudefuel` — a status bar for Claude Code. Shows context window usage, session/weekly/extra rate limits, and reset times. The script is dropped at `~/.claude/statusline.sh` and wired up via `~/.claude/settings.json`. It also reads `CLAUDE_CONFIG_DIR` at runtime, so it shows the right per-account usage if the user runs multiple Claude Code config dirs.

## Preconditions

Before making any changes, verify ALL of these. If any fail, stop and report which one failed; do not attempt repairs the user did not ask for.

- `claude` is on `PATH` (`command -v claude`).
- `jq` is installed (`command -v jq`). On macOS: `brew install jq`. On Debian/Ubuntu: `apt install jq`.
- `curl` is installed.
- `~/.claude/` directory exists. If it does not, instruct the user to run `claude` once to initialize it. Do **not** create it yourself.
- The user has write access to `~/.claude/settings.json` (or the file does not yet exist).

## Desired state

The install is a **bundle**: every artifact below must be present and valid after reconcile, or none of them must change. This is the atomic-bundle contract — partial installs are not a valid intermediate state.

1. **File `~/.claude/statusline.sh`:**
   - Exists, is a regular file (not a broken symlink).
   - Is executable (`-rwx------` or stricter).
   - First 20 lines contain a header line matching the regex `^# claudefuel: v(.+)$` and the captured version parses as `X.Y.Z`. Version is checked at install time against the spec's `Version:` declaration (see Step 2), not against a hardcoded floor.
2. **Files `~/.claude/commands/claudefuel.{update,doctor,rollback,uninstall,configure}.md`:**
   - All five present, each readable.
   - Each carries a header line matching `^# claudefuel-skill: v(.+)$` within the first 20 lines, captured version parses as `X.Y.Z`.
3. **Directory `~/.claude/cache/`:**
   - claudefuel runtime scratch. Install creates the directory; runtime owns the contents (statusline.sh's `claudefuel-version.json`, `claudefuel`'s diagnostic dumps).
4. **File `~/.claude/claudefuel`:**
   - Exists, is a regular file (not a broken symlink).
   - Is executable (`-rwx------` or stricter).
   - First 20 lines contain a header line matching the regex `^# claudefuel: v(.+)$` and the captured version parses as `X.Y.Z`.
5. **File `~/.claude/settings.json`:**
   - Is valid JSON.
   - Contains `.statusLine == { "type": "command", "command": "~/.claude/statusline.sh" }`.
   - Every other top-level key that existed before this run **must still exist with the same value**. This is the single most important invariant.

The user's `~/.claude/claudefuel.json` is **not part of the bundle**. It is user-owned and never touched by install, upgrade, or uninstall.

## Reconcile

Download the tagged `claudefuel` script to `$target_dir/claudefuel`, make it executable, and run it. The script owns every mechanic of forward reconcile (backups, atomic file replacement, settings patching, bundle verification, failure diagnostics) — see [[0005-update-flow-script-led]].

```bash
target_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
latest=$(curl -fsSL https://api.github.com/repos/FlorianRiquelme/claudefuel/releases/latest \
  | jq -r '.tag_name')
curl -fsSL "https://raw.githubusercontent.com/FlorianRiquelme/claudefuel/refs/tags/${latest}/claudefuel" \
  -o "$target_dir/claudefuel"
chmod 700 "$target_dir/claudefuel"
"$target_dir/claudefuel" update
```

On non-zero exit the script writes `$target_dir/cache/claudefuel-update-diagnostic.json` (carrying current state, available backups, and a self-contained desired-state snapshot). At that point — and only then — fall back to LLM-driven recovery scoped to the bundle: bundle files (`statusline.sh`, the five `commands/claudefuel.*.md`, `cache/`, the local `claudefuel` binary) and the `.statusLine` key in `settings.json`. Nothing else.

## Verify

After reconcile, run all of these and report each pass/fail:

- `[ -x ~/.claude/statusline.sh ]` — executable.
- Version header line is present and parses.
- `jq -e '.statusLine.command' ~/.claude/settings.json` exits 0.
- Statusline runs without error on a sample input:
  ```bash
  echo '{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp"},"session_id":"test"}' \
    | ~/.claude/statusline.sh
  ```
  Expected: produces output, exits 0. The output may contain ANSI escapes — that is fine.
- Optional: open a new Claude Code session and confirm the status bar renders. Tell the user to do this; do not start a new session yourself.

## Post-install summary

After Verify passes, explain to the user in chat the user-visible bar behaviors — particularly the ones that are dormant until specific conditions occur, since they will not be visible on first render. This section is the canonical discoverability surface; the `/claudefuel.update` skill defers to it on upgrade so the prose lives in one place across install and upgrade.

- **Drift signal (`↗ /claudefuel.update`).** Appears on Line 1 only when an upstream release is available. Invoking it routes to the upgrade skill.
- **Cap-ETA (`~cap HH:MM-HH:MM`).** Appears on Line 3 next to the 5-hour `↻ <time>` reset cell only when the user is on track to hit the 5-hour cap before reset. A rough estimate (tilde + range — never a precise time) derived from average burn rate over the current window. Dormant when healthy; the cell shows only `↻ <time>` until burn rate exceeds reset-pace.

## Upgrade

Run the same paste line.

## Uninstall

Prefer the `/claudefuel.uninstall` skill — it walks the user through scope and confirms before removing anything. For agents performing uninstall via this Promptfile directly:

1. Remove `~/.claude/statusline.sh`.
2. Remove `~/.claude/claudefuel`.
3. Remove each of `~/.claude/commands/claudefuel.{update,doctor,rollback,uninstall,configure}.md`.
4. Remove `~/.claude/cache/claudefuel-version.json` and `~/.claude/cache/claudefuel-update-diagnostic.json`. Remove `~/.claude/cache/` only if empty afterwards.
5. Remove the `.statusLine` key from `~/.claude/settings.json`:
   ```bash
   jq 'del(.statusLine)' ~/.claude/settings.json > ~/.claude/settings.json.tmp \
     && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
   ```
6. Ask the user whether to delete `*.bak-<timestamp>` backups across the bundle.
7. Leave `~/.claude/claudefuel.json` (user-owned) in place unless the user explicitly asks to remove it.

## Notes for the agent executing this Promptfile

- **Do not** modify any key in `~/.claude/settings.json` other than `.statusLine`.
- **Do not** touch `~/.zshrc`, `~/.bashrc`, or any shell rc file. This artifact requires no shell aliases.
- **Do not** download over plain HTTP. Always HTTPS.
- If `CLAUDE_CONFIG_DIR` is set in the user's environment, the same procedure applies, but to `$CLAUDE_CONFIG_DIR/statusline.sh` and `$CLAUDE_CONFIG_DIR/settings.json` instead. Ask the user whether to install there, in `~/.claude`, or both.
- If the user has `~/.claude-work` / `~/.claude-personal` (dual-account setup), the same script works for both — offer to symlink: `ln -sf ~/.claude/statusline.sh ~/.claude-<profile>/statusline.sh`. Ask before linking.
- On any postcondition failure: stop, restore the most recent `*.bak-<timestamp>` for any file you touched in this run, and report the failure to the user. Do not retry silently.
- Hard core / soft shell: the desired-state contract above is the **hard core** — do not deviate. Path locations, shell choice, and whether to also install into `$CLAUDE_CONFIG_DIR` are **soft shell** — adapt to the host and ask the user when ambiguous.
