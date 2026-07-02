# claudefuel — install / upgrade spec

Version: `0.4.6`
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
   - Exists. Contents (including `claudefuel-version.json`) are owned by `statusline.sh` at runtime; install creates the directory but writes no files into it.
4. **File `~/.claude/settings.json`:**
   - Is valid JSON.
   - Contains `.statusLine == { "type": "command", "command": "~/.claude/statusline.sh" }`.
   - Every other top-level key that existed before this run **must still exist with the same value**. This is the single most important invariant.

The user's `~/.claude/claudefuel.json` is **not part of the bundle**. It is user-owned and never touched by install, upgrade, or uninstall.

## Reconcile

Execute the following steps in order. Verify the listed postcondition after each step before proceeding. **On any postcondition failure, restore every `*.bak-<UTC-timestamp>` file written in this run in reverse install order** (settings.json, then each command file, then statusline.sh), then report which step failed. Do not retry silently.

### Step 1 — Detect installed version

- If `~/.claude/statusline.sh` exists, run `head -20 ~/.claude/statusline.sh | grep -E '^# claudefuel:'` and capture the version.
- If absent or unparseable (e.g. a different statusline lives there), treat installed version as `none`.

### Step 2 — Compare and decide

Parse the spec version from this file's `Version:` line, then run a three-state comparison against the installed version using `sort -V` semver semantics. The same algorithm lives in the `/claudefuel.update` skill — if you change one, change the other.

```bash
spec=$(grep -E '^Version:' INSTALL.md | head -n1 \
  | sed -E 's/^Version: *`?([^`]+)`?.*/\1/')

compare_versions() {
  local installed="$1" spec="$2"
  if [ "$installed" = "$spec" ]; then
    echo "equal"
    return 0
  fi
  local lowest
  lowest=$(printf '%s\n%s\n' "$installed" "$spec" | sort -V | head -n1)
  if [ "$lowest" = "$installed" ]; then
    echo "spec-newer"
  else
    echo "installed-newer"
  fi
}

state=$(compare_versions "$installed" "$spec")
```

Branch on `$state`:

- `equal` → if Step 5's settings check also passes, report "up to date" and STOP (no-op reconcile). Otherwise continue to Step 3 to repair settings drift.
- `spec-newer` → continue to Step 3 (forward upgrade).
- `installed-newer` → refuse and report: `installed v${installed} is newer than spec v${spec} — you appear to have a customized or pre-release build; no action taken.` Do not offer a `--force` flag. The maintainer's workaround when developing a dev build is to invoke the install paste line manually or temporarily set the installed header to match the spec.

If `installed` is `none` (file absent or unparseable), treat as `spec-newer` and continue.

Pre-release tags (`-rc1` etc.) are not supported in v1.

### Step 3 — Back up the existing bundle

Use a single UTC timestamp `<TS>` (format `YYYYMMDDHHMMSS`) for every backup written in this run, so the rollback skill can match them as a set.

For each of the following files that exists pre-install, copy it to `<file>.bak-<TS>`:

- `~/.claude/statusline.sh`
- `~/.claude/commands/claudefuel.update.md`
- `~/.claude/commands/claudefuel.doctor.md`
- `~/.claude/commands/claudefuel.rollback.md`
- `~/.claude/commands/claudefuel.uninstall.md`
- `~/.claude/commands/claudefuel.configure.md`
- `~/.claude/settings.json`

Do **not** back up `~/.claude/claudefuel.json` — it is not part of the bundle.

Postcondition: every file that existed pre-install has a matching `*.bak-<TS>`.

### Step 4 — Install `statusline.sh`

- Download `https://raw.githubusercontent.com/FlorianRiquelme/claudefuel/main/statusline.sh` to a temp file (e.g. `mktemp`).
- Verify the downloaded file has a `# claudefuel: v...` header in its first 20 lines. If not, abort, delete the temp file, and report — do not move the file into place.
- `mv` the temp file to `~/.claude/statusline.sh` (atomic).
- `chmod 700 ~/.claude/statusline.sh` (executable, owner-only).
- Postcondition: `head -20 ~/.claude/statusline.sh | grep -E '^# claudefuel:'` returns the expected version, and the file is executable.

### Step 5 — Install the five `/claudefuel.*` command files

- Ensure `~/.claude/commands/` exists; `mkdir -p` it if not.
- For each of `update`, `doctor`, `rollback`, `uninstall`, `configure`:
  - Download `https://raw.githubusercontent.com/FlorianRiquelme/claudefuel/main/commands/claudefuel.<name>.md` to a temp file.
  - Verify the file has a `# claudefuel-skill: v...` header in its first 20 lines. If not, abort, delete the temp file, restore prior backups in reverse order (this step's earlier writes, then statusline.sh), and report.
  - `mv` the temp file to `~/.claude/commands/claudefuel.<name>.md` (atomic).
- Postcondition: all five files exist and each has a parseable `# claudefuel-skill:` header.

### Step 6 — Create the drift cache directory

- `mkdir -p ~/.claude/cache/`. Do not write any file inside — `statusline.sh` populates `claudefuel-version.json` at runtime.
- Postcondition: `[ -d ~/.claude/cache/ ]`.

### Step 7 — Patch `~/.claude/settings.json`

- If the file does not exist, create it as `{}`.
- Validate it is valid JSON: `jq empty ~/.claude/settings.json`. If not, abort and report — do not attempt to fix unrelated JSON.
- Capture the list of pre-existing top-level keys: `jq -r 'keys[]' ~/.claude/settings.json | sort > /tmp/keys-before`.
- Patch atomically:
  ```bash
  jq '.statusLine = {type: "command", command: "~/.claude/statusline.sh"}' \
     ~/.claude/settings.json > ~/.claude/settings.json.tmp \
     && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
  ```
- Postcondition A: `jq -e '.statusLine.command == "~/.claude/statusline.sh"' ~/.claude/settings.json` exits 0.
- Postcondition B: `jq -r 'keys[]' ~/.claude/settings.json | sort > /tmp/keys-after && diff /tmp/keys-before /tmp/keys-after` shows no removed keys (additions of `statusLine` are expected).

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

Identical to install. The user runs the same paste line again. Reconcile detects the installed version, performs the upgrade if the desired version is newer, and is a no-op otherwise. Every change writes a fresh `*.bak-<timestamp>` so previous installs are recoverable.

## Uninstall

Prefer the `/claudefuel.uninstall` skill — it walks the user through scope and confirms before removing anything. For agents performing uninstall via this Promptfile directly:

1. Remove `~/.claude/statusline.sh`.
2. Remove each of `~/.claude/commands/claudefuel.{update,doctor,rollback,uninstall,configure}.md`.
3. Remove `~/.claude/cache/claudefuel-version.json`. Remove `~/.claude/cache/` only if empty afterwards.
4. Remove the `.statusLine` key from `~/.claude/settings.json`:
   ```bash
   jq 'del(.statusLine)' ~/.claude/settings.json > ~/.claude/settings.json.tmp \
     && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
   ```
5. Ask the user whether to delete `*.bak-<timestamp>` backups across the bundle.
6. Leave `~/.claude/claudefuel.json` (user-owned) in place unless the user explicitly asks to remove it.

## Notes for the agent executing this Promptfile

- **Do not** modify any key in `~/.claude/settings.json` other than `.statusLine`.
- **Do not** touch `~/.zshrc`, `~/.bashrc`, or any shell rc file. This artifact requires no shell aliases.
- **Do not** download over plain HTTP. Always HTTPS.
- If `CLAUDE_CONFIG_DIR` is set in the user's environment, the same procedure applies, but to `$CLAUDE_CONFIG_DIR/statusline.sh` and `$CLAUDE_CONFIG_DIR/settings.json` instead. Ask the user whether to install there, in `~/.claude`, or both.
- If the user has `~/.claude-work` / `~/.claude-personal` (dual-account setup), the same script works for both — offer to symlink: `ln -sf ~/.claude/statusline.sh ~/.claude-<profile>/statusline.sh`. Ask before linking.
- On any postcondition failure: stop, restore the most recent `*.bak-<timestamp>` for any file you touched in this run, and report the failure to the user. Do not retry silently.
- Hard core / soft shell: the desired-state contract above is the **hard core** — do not deviate. Path locations, shell choice, and whether to also install into `$CLAUDE_CONFIG_DIR` are **soft shell** — adapt to the host and ask the user when ambiguous.
