# claudefuel

A fuel gauge for Claude Code. A status bar that shows context window usage, session / weekly / extra rate limits, and reset times — so you always know how much Claude you have left.

## Install (one paste, in Claude Code)

```
Read https://raw.githubusercontent.com/FlorianRiquelme/claudefuel/main/INSTALL.md and install it on my machine.
```

That's it. Claude reads the spec, verifies preconditions, backs up your settings, installs the status bar, and wires it up via `~/.claude/settings.json`.

**Upgrade:** same paste line. The spec is idempotent — it detects the installed version and reconciles.

**Uninstall:**

```
Read https://raw.githubusercontent.com/FlorianRiquelme/claudefuel/main/INSTALL.md and uninstall it.
```

## What you get

- **Line 1:** model · tokens used / total · % used bar · % remaining bar · thinking on/off
- **Line 2:** session / weekly / extra usage progress bars
- **Line 3:** session reset time · weekly reset · extra reset
- Cross-platform: macOS Keychain, Linux credentials file / GNOME Keyring
- Color-coded: green → orange → yellow → red as you burn through limits

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed
- `jq` (`brew install jq` on macOS, `apt install jq` on Debian/Ubuntu)
- At least one successful `claude` session (so `~/.claude/` exists)

## Manual install

If you'd rather not delegate to the LLM:

```bash
git clone https://github.com/FlorianRiquelme/claudefuel.git
cd claudefuel
cp statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh

# Wire it up
jq '.statusLine = {type:"command", command:"~/.claude/statusline.sh"}' \
   ~/.claude/settings.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json
```

## Versioning

`statusline.sh` self-versions via a header line:

```bash
head -2 ~/.claude/statusline.sh
# #!/bin/bash
# # claudefuel: v0.1.0
```

The `INSTALL.md` Promptfile diffs this against its declared version and only writes if an upgrade is needed.

## Bonus: multi-account aware

`claudefuel` reads `CLAUDE_CONFIG_DIR` at runtime. If you run multiple Claude Code config dirs (e.g. work + personal), each terminal tab automatically shows the **correct usage** for whichever account is active. It does this by:

1. Deriving the keychain service name with the same SHA256 hash Claude Code uses (`Claude Code-credentials-<first-8-of-sha256>`).
2. Using a per-account cache file (`/tmp/claude/statusline-usage-cache-<hash>.json`).
3. Reading settings from the active config directory.

```
~/.claude/          → service: "Claude Code-credentials"
~/.claude-work/     → service: "Claude Code-credentials-2cb8c227"
~/.claude-personal/ → service: "Claude Code-credentials-2ed9812b"
```

If you have a dual-account setup already, just symlink the same script:

```bash
ln -sf ~/.claude/statusline.sh ~/.claude-work/statusline.sh
ln -sf ~/.claude/statusline.sh ~/.claude-personal/statusline.sh
```

## Bonus: full dual-account setup

If you don't yet have a dual-account setup and want one — two Claude Code accounts running side-by-side with isolated keychain credentials and shared config — there's a `setup.sh` in this repo that does it:

```bash
git clone https://github.com/FlorianRiquelme/claudefuel.git
cd claudefuel
chmod +x setup.sh
./setup.sh
```

This creates `~/.claude-work` and `~/.claude-personal` (configurable with `--names`), symlinks shared config (CLAUDE.md, settings.json, mcp.json, rules/, agents/, skills/, commands/, hooks/, plugins/) from your existing `~/.claude/`, installs `claudefuel`, and adds shell aliases:

```bash
source ~/.zshrc
claude-work auth login
claude-personal auth login

claude-work       # work account
claude-personal   # personal account
```

Both run simultaneously in separate terminal tabs.

### What gets shared vs isolated

| Shared (symlinked) | Isolated (per account) |
|---|---|
| CLAUDE.md | Keychain credentials |
| settings.json | sessions/ |
| mcp.json | history.jsonl |
| rules/ | debug/ |
| agents/ | telemetry/ |
| skills/ | todos/, tasks/ |
| commands/ | cache/ |
| hooks/ | .claude.json (runtime state) |
| plugins/ | statusline usage cache |

### setup.sh options

```bash
./setup.sh --names ops dev          # custom profile names
./setup.sh --skip-permissions       # include --dangerously-skip-permissions in aliases
./setup.sh --dry-run                # preview without changing anything
```

### Known limitations

- **IDE integration** may not work correctly with custom config dirs ([anthropics/claude-code#4739](https://github.com/anthropics/claude-code/issues/4739))
- **Project-level `.claude/` dirs** are still created in workspaces regardless of `CLAUDE_CONFIG_DIR` ([#3833](https://github.com/anthropics/claude-code/issues/3833))
- `--dangerously-skip-permissions` still prompts for writes to `.claude/` and `.git/` dirs ([#35718](https://github.com/anthropics/claude-code/issues/35718))
