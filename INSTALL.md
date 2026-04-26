# claudefuel — install / upgrade spec

Version: `0.1.0`
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

1. **File `~/.claude/statusline.sh`:**
   - Exists, is a regular file (not a broken symlink).
   - Is executable (`-rwx------` or stricter).
   - First 20 lines contain a header line matching the regex `^# claudefuel: v(.+)$` with captured version `>= 0.1.0`.
2. **File `~/.claude/settings.json`:**
   - Is valid JSON.
   - Contains `.statusLine == { "type": "command", "command": "~/.claude/statusline.sh" }`.
   - Every other top-level key that existed before this run **must still exist with the same value**. This is the single most important invariant.

## Reconcile

Execute the following steps in order. Verify the listed postcondition after each step before proceeding. On any postcondition failure, restore from the most recent `*.bak-<timestamp>` and report.

### Step 1 — Detect installed version

- If `~/.claude/statusline.sh` exists, run `head -20 ~/.claude/statusline.sh | grep -E '^# claudefuel:'` and capture the version.
- If absent or unparseable (e.g. a different statusline lives there), treat installed version as `none`.

### Step 2 — Compare and decide

- If installed version `>= 0.1.0` **and** Step 5's settings check already passes, report "up to date" and STOP. This is the no-op upgrade path.
- Otherwise, continue.

### Step 3 — Back up

- If `~/.claude/statusline.sh` exists, copy it to `~/.claude/statusline.sh.bak-<UTC-timestamp>` (timestamp format: `YYYYMMDDHHMMSS`).
- If `~/.claude/settings.json` exists, copy it to `~/.claude/settings.json.bak-<UTC-timestamp>`.
- Postcondition: both `*.bak-*` files exist (or were not needed because the source files did not exist).

### Step 4 — Install `statusline.sh`

- Download `https://raw.githubusercontent.com/FlorianRiquelme/claudefuel/main/statusline.sh` to a temp file (e.g. `mktemp`).
- Verify the downloaded file has a `# claudefuel: v...` header in its first 20 lines. If not, abort, delete the temp file, and report — do not move the file into place.
- `mv` the temp file to `~/.claude/statusline.sh` (atomic).
- `chmod 700 ~/.claude/statusline.sh` (executable, owner-only).
- Postcondition: `head -20 ~/.claude/statusline.sh | grep -E '^# claudefuel:'` returns the expected version, and the file is executable.

### Step 5 — Patch `~/.claude/settings.json`

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

## Upgrade

Identical to install. The user runs the same paste line again. Reconcile detects the installed version, performs the upgrade if the desired version is newer, and is a no-op otherwise. Every change writes a fresh `*.bak-<timestamp>` so previous installs are recoverable.

## Uninstall

1. Remove `~/.claude/statusline.sh`.
2. Remove the `.statusLine` key from `~/.claude/settings.json`:
   ```bash
   jq 'del(.statusLine)' ~/.claude/settings.json > ~/.claude/settings.json.tmp \
     && mv ~/.claude/settings.json.tmp ~/.claude/settings.json
   ```
3. Ask the user whether to delete `~/.claude/statusline.sh.bak-*` and `~/.claude/settings.json.bak-*` backups.

## Notes for the agent executing this Promptfile

- **Do not** modify any key in `~/.claude/settings.json` other than `.statusLine`.
- **Do not** touch `~/.zshrc`, `~/.bashrc`, or any shell rc file. This artifact requires no shell aliases.
- **Do not** download over plain HTTP. Always HTTPS.
- If `CLAUDE_CONFIG_DIR` is set in the user's environment, the same procedure applies, but to `$CLAUDE_CONFIG_DIR/statusline.sh` and `$CLAUDE_CONFIG_DIR/settings.json` instead. Ask the user whether to install there, in `~/.claude`, or both.
- If the user has `~/.claude-work` / `~/.claude-personal` (dual-account setup), the same script works for both — offer to symlink: `ln -sf ~/.claude/statusline.sh ~/.claude-<profile>/statusline.sh`. Ask before linking.
- On any postcondition failure: stop, restore the most recent `*.bak-<timestamp>` for any file you touched in this run, and report the failure to the user. Do not retry silently.
- Hard core / soft shell: the desired-state contract above is the **hard core** — do not deviate. Path locations, shell choice, and whether to also install into `$CLAUDE_CONFIG_DIR` are **soft shell** — adapt to the host and ask the user when ambiguous.
