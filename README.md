# claudefuel

A fuel gauge for Claude Code. A status bar that shows context window usage, session / weekly / extra rate limits, and reset times — so you always know how much Claude you have left.

![claudefuel status bar ticking through usage states](docs/assets/usage-progression.gif)

## Install (one paste, in Claude Code)

```
Read https://raw.githubusercontent.com/FlorianRiquelme/claudefuel/main/INSTALL.md and install it on my machine.
```

That's it. Claude reads the spec, verifies preconditions, backs up your settings, installs the status bar, and wires it up via `~/.claude/settings.json`.

**Upgrade:** same paste line, or `/claudefuel.update` once installed. The spec is idempotent — it detects the installed version and reconciles.

**Uninstall:**

```
Read https://raw.githubusercontent.com/FlorianRiquelme/claudefuel/main/INSTALL.md and uninstall it.
```

Or `/claudefuel.uninstall` from inside a Claude Code session.

## What you get

- **Line 1:** model · `ctx` bar with `<used>/<total>` tokens · thinking on/off · effort level (when the model supports it). A `◈ session` chip appears once the session has a name (`claude --name`, or `/rename` mid-session), an `agent: <name>` badge shows inside subagent panel rows, and a live `▸ <tool> <age>` chip tracks whatever tool call is currently running. A clickable `#N` PR chip with a review-state glyph appears when the workspace has an open PR. When a newer release is available, an `↗ /claudefuel.update` segment appears here as a one-glyph drift signal — faint for a patch-level bump, yellow for minor/major.
- **Line 2:** `5h` / `7d` / `extra` usage progress bars (matches the `.five_hour` / `.seven_day` / `.extra_usage` fields the API returns). The `extra` column shows your prepaid credit balance, and only appears once spend is live (> $0 this month). A `▸` marker flags the governing constraint — whichever window would hit 100% first at your current pace (dive-computer style: the column is marked, never reordered). At ≥ 90% a column escalates with shape and weight, not hue alone: `⚠` label prefix and inverse-video percentage. While you're burning the 5-hour window faster than reset-pace, the 5h percent gives way to a burn chip — `~1h38m ×1.4`: time left at the current pace, and that pace as a multiple of the rate that would just last until reset. Dormant at ×1.0 or below (the bar fill still carries the percent).
- **Line 3:** `↻` reset times for each window. When you're burning through the 5-hour window faster than reset-pace, a `~cap HH:MM-HH:MM` segment appears next to the 5h reset — a rough estimate of when you'll hit 100% at the current pace, with a range that scales with the horizon (±15% of the time to cap, never tighter than ±5min). Two companions ride along: `slow ≤0.6×` — the pace to drop to so the remaining budget lasts until reset — and `⚓ 1h21m` — the dead time you'd sit locked out between the projected cap and the reset (hidden when under 5 minutes). Dormant when healthy; the tilde and range signal it's a prediction, not a precise time.
- Prefer a countdown over the wall clock for the 5-hour reset? Set `CLAUDEFUEL_RESET_COUNTDOWN=1` in your environment (or `reset_display: "countdown"` in `claudefuel.json` — see [Configuration](#configuration)) and Line 3 renders `↻ in 2h59m` instead. The clock stays the default.
- Cross-platform: macOS Keychain, Linux credentials file / GNOME Keyring
- Color-coded: green → orange → yellow → red as you burn through limits — with the shape/weight escalations above so severity never rides on hue alone
- **Never-block render:** the bar always paints instantly from its cache — a stale cache still paints while a detached one-shot background fetch refreshes it for the next render. Only the very first render after install waits on the network. When Claude Code passes `rate_limits` on stdin, the 5h/7d bars need no network call at all — the OAuth usage endpoint is only polled every 30 minutes in that case, purely to enrich the `extra` column. Set `CLAUDEFUEL_OFFLINE=1` to skip all fetches entirely (the cached values keep painting).
- **Honest gauge:** stale data never poses as fresh — cached snapshots render with an age marker (`5h: ●●●●●●○○○○ 62% ·9m` = 9 minutes old). When there's no data to show at all, a one-glyph diagnosis plus a `✚ /claudefuel.doctor` trailhead replaces the usage rows (`⊘` credentials, `⚠` network, `?` missing dependency). The bar reads credentials read-only and never refreshes tokens itself — Claude Code handles that on its own schedule.

### Severity is structural, not just hue

Lines 2–3 render as soon as there's usage data, in a stable layout that's never reordered. Severity rides on shape and weight rather than color alone: a `▸` marker flags the governing constraint — whichever window would hit 100% first at your current pace — and any window at ≥90% escalates with a `⚠` label prefix plus an inverse-video value, so it reads even on a monochrome terminal. The `extra` column only appears once spend is live (>$0 this month) — it's absent otherwise, not just dim.

## Works with multiple Claude Code accounts

`claudefuel` reads `CLAUDE_CONFIG_DIR` at runtime. If you run more than one Claude Code profile — work + personal, an OSS profile on the side, anything — each terminal tab automatically shows the **correct usage** for whichever profile is active.

![three terminal panes each showing a different profile's usage](docs/assets/multi-account.gif)

It does this by:

1. Deriving the keychain service name with the same SHA256 hash Claude Code uses (`Claude Code-credentials-<first-8-of-sha256>`).
2. Using a per-profile cache directory (`$CLAUDE_CONFIG_DIR/cache/`).
3. Reading settings from the active profile directory.

```
~/.claude/          → service: "Claude Code-credentials"
~/.claude-work/     → service: "Claude Code-credentials-2cb8c227"
~/.claude-personal/ → service: "Claude Code-credentials-2ed9812b"
~/.claude-oss/      → service: "Claude Code-credentials-91ab4f30"
```

If you already have a multi-profile setup, just symlink the same script into each profile dir:

```bash
ln -sf ~/.claude/statusline.sh ~/.claude-work/statusline.sh
ln -sf ~/.claude/statusline.sh ~/.claude-personal/statusline.sh
ln -sf ~/.claude/statusline.sh ~/.claude-oss/statusline.sh
```

A bundled installer for two profiles ships in this repo if you don't yet have one — see [Optional: bundled installer for two profiles](#optional-bundled-installer-for-two-profiles) below.

### See the spare tank

When the active profile is running hot (≥80% on its governing window) and another profile's cached usage shows meaningfully more headroom, a switch hint appears at the end of line 2:

```
5h: ●●●●●●●●○○ 85% | 7d: ●●●○○○○○○○ 30% | ⇄ work 12% (2m)
```

Read it as: "the `work` profile was at 12% as of 2 minutes ago — consider switching." The hint is read-only and conservative: it only reads the per-profile caches other renders already left on disk (it never fetches usage for an inactive profile), the cache age in parentheses always travels with the number, and snapshots older than 6 hours are ignored. Dormant in every nominal state.

For the full picture across all profiles, run `/claudefuel.fleet` — it renders a table of every known profile's cached 5h/7d usage, reset time, prepaid balance, and data age. Same rule applies: cached snapshots only, each row labeled with its age.

## Daily use

Once installed, these slash commands are available in any Claude Code session:

| Command | What it does |
|---|---|
| `/claudefuel.update` | Reconcile to the latest released spec. Pinned to the tag, shows the full diff before writing anything. Run it when you see the `↗ /claudefuel.update` drift signal on line 1. |
| `/claudefuel.doctor` | Non-destructive health check across the install — file presence, version header, `settings.json` wiring, dependencies. Includes a timing mode (`CLAUDEFUEL_TIMING=1`) that checks per-stage render latency against the published budget, explains the bar's failure glyphs (`⊘` / `⚠` / `?`), and can run a bulb-check demo render that lights up every alarm state from a canned snapshot. |
| `/claudefuel.rollback` | Restore the most recent `*.bak-<timestamp>` written by a previous install. Shows the diff and asks before restoring. |
| `/claudefuel.uninstall` | Remove the install bundle cleanly. Asks separately about backups and your `claudefuel.json`. |
| `/claudefuel.configure` | Edit `~/.claude/claudefuel.json` conversationally — color thresholds, segment ordering, segment show/hide, theme presets. See [Configuration](#configuration). |
| `/claudefuel.fleet` | Fleet view for multi-profile setups: a table of every known profile's cached 5h/7d usage, reset time, balance, and data age. Read-only — shows what's already cached, never fetches for inactive profiles. |
| `/claudefuel.why` | Show-your-work view of the bar's current numbers: burn rate vs reset-pace, the cap-ETA arithmetic, which visibility gates passed or failed (and why), cache ages, active profile. |
| `/claudefuel.coach` | Ask usage questions in plain language — "can I finish this refactor before my 5h reset?", "should I drop to a cheaper model?" — answered from the same snapshot math, ending in a recommendation. |

`/claudefuel.why` and `/claudefuel.coach` read a machine-readable snapshot — `~/.claude/statusline.sh --snapshot` prints versioned JSON of the cached usage data plus the derived burn-rate / cap-ETA math, without fetching anything. The bar itself stays a dumb display; the Claude session you're already in does the explaining.

## Configuration

The bar reads `~/.claude/claudefuel.json` (or `$CLAUDE_CONFIG_DIR/claudefuel.json` for a profile) on every render and merges it over baked-in defaults. No file means pure defaults; a malformed file is ignored — the bar never breaks over config. The file is user-owned: install, upgrade, and uninstall never touch it.

Run `/claudefuel.configure` to edit it conversationally, or write it by hand. All keys are optional:

```json
{
  "version": 1,
  "theme": "default",
  "color_thresholds": { "orange": 50, "yellow": 70, "red": 90 },
  "reset_display": "clock",
  "glyphs": "unicode",
  "hyperlinks": true,
  "segments": {
    "order": {
      "line1": ["model", "session", "ctx", "thinking", "effort", "agent", "activity", "pr", "drift"],
      "columns": ["5h", "7d", "extra"]
    },
    "hide": []
  }
}
```

- **`theme`** — `"default"` (truecolor) or `"mono"` (no hues).
- **`color_thresholds`** — utilization % at which bars turn orange / yellow / red (below orange: green). One ladder, shared by the ctx, 5h, and 7d bars.
- **`reset_display`** — `"clock"` (`↻ 5:30pm`) or `"countdown"` (`↻ in 42m`) on line 3.
- **`glyphs`** — `"unicode"` (default) or `"ascii"`, which maps every glyph to an ASCII stand-in for fonts/terminals that render boxes.
- **`hyperlinks`** — `true` (default) or `false` to disable the OSC 8 clickable cells (reset → usage page, extra → billing, `↗` → releases, `#N` → the PR).
- **`segments.order`** — `line1` orders the line-1 segments (`session` is the identity chip, `agent` the subagent badge, `activity` the live tool-call chip, `pr` the clickable `#N` chip); `columns` orders the 5h/7d/extra columns on lines 2 and 3 together (line 3 always mirrors line 2).
- **`segments.hide`** — tokens to hide: any order token above, plus the hide-only badges `"profile"` (the `[name]` prefix), `"cap_eta"` (the `~cap` range on the 5h reset cell), `"projection"` (the `→N%` landing prediction), and `"sessions"` (the `⧉ N` shared-window session count).

The `◈ session` chip only renders once the session has a name (`claude --name`, or `/rename` mid-session).

Scope is deliberately minor tweaks only — color thresholds, segment ordering, segment show/hide, theme presets. Custom segments, user data sources, and embedded scripts are out of scope by design.

## Why a paste-line, not a plugin?

claudefuel is distributed as a **Promptfile** — `INSTALL.md` is written for an LLM agent to read and execute on your machine, while remaining human-readable. Same paste line installs, upgrades, and no-ops. Install and upgrade are the same idempotent operation.

We deliberately didn't ship as a Claude Code plugin, even though plugins would give us `/plugin update`, a built-in registry, and the colon-namespace syntax for free. The reason is plugin fatigue — most target users already have many plugins installed, and "don't make me install another plugin" is a real adoption blocker.

The cost is that we maintain our own reconcile loop, our own upgrade UX, and dot-syntax (`/claudefuel.update`) instead of colon-syntax for skills. The benefit is that you install by pasting one line, and the LLM session you're already in does the work.

## What gets touched (and what doesn't)

Install, upgrade, and uninstall are bundled atomically — every artifact below is present and valid after reconcile, or none of them change.

**Created / managed by the bundle:**

- `~/.claude/statusline.sh` — the script itself
- `~/.claude/commands/claudefuel.{update,doctor,rollback,uninstall,configure,why,coach,fleet}.md` — the eight slash commands
- `~/.claude/cache/` — runtime cache directory (contents owned by the script at runtime)
- The `.statusLine` and `.subagentStatusLine` keys in `~/.claude/settings.json`

**Never touched:**

- Any other key in `~/.claude/settings.json` (this is the single most important invariant)
- `~/.zshrc`, `~/.bashrc`, or any other shell rc file — no aliases, no hooks
- `~/.claude/claudefuel.json` — your config file is user-owned and survives every upgrade / reinstall / uninstall

Every write produces a `*.bak-<UTC-timestamp>` so the previous state is recoverable via `/claudefuel.rollback`.

When you run `/claudefuel.update`, the skill fetches `INSTALL.md` pinned to the **latest release tag** (not `main`) and renders the full diff in chat before executing anything. You confirm; only then does it write.

## Checking and upgrading

To check what's installed and whether it's healthy: `/claudefuel.doctor`.

To upgrade: either re-run the paste line, or `/claudefuel.update`. The skill version is the source of truth; the bar polls upstream for drift and renders an `↗ /claudefuel.update` segment on line 1 when a newer release is available.

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed
- `jq` (`brew install jq` on macOS, `apt install jq` on Debian/Ubuntu)
- `curl`
- At least one successful `claude` session (so `~/.claude/` exists)

## Manual install

If you'd rather not delegate to the LLM, the steps in `INSTALL.md` are equivalent to:

```bash
git clone https://github.com/FlorianRiquelme/claudefuel.git
cd claudefuel
cp statusline.sh ~/.claude/statusline.sh
chmod 700 ~/.claude/statusline.sh
mkdir -p ~/.claude/commands ~/.claude/cache
cp commands/claudefuel.*.md ~/.claude/commands/

jq '.statusLine = {type:"command", command:"~/.claude/statusline.sh"}' \
   ~/.claude/settings.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json
```

The Promptfile path adds backups, version comparison, postcondition verification, and rollback on failure — none of which this snippet does. Use the paste line unless you have a specific reason not to.

## Optional: bundled installer for two profiles

If you don't yet have a multi-profile setup and want one, `setup.sh` in this repo creates two side-by-side Claude Code profiles with isolated keychain credentials and shared config:

```bash
git clone https://github.com/FlorianRiquelme/claudefuel.git
cd claudefuel
chmod +x setup.sh
./setup.sh
```

This creates `~/.claude-work` and `~/.claude-personal` (configurable with `--names`), symlinks shared config (CLAUDE.md, settings.json, mcp.json, .lsp.json, rules/, agents/, skills/, commands/, hooks/, plugins/) from your existing `~/.claude/`, installs `claudefuel`, and adds shell aliases:

```bash
source ~/.zshrc
claude-work auth login
claude-personal auth login

claude-work       # work profile
claude-personal   # personal profile
```

Both run simultaneously in separate terminal tabs.

> **`setup.sh` currently creates exactly two profiles.** The runtime described above works for any number — `setup.sh` is the convenience helper, not the limit. For three or more, set the extras up by hand (same pattern: a fresh `~/.claude-<name>/` dir, symlink the shared config, alias `claude-<name>` to `CLAUDE_CONFIG_DIR=~/.claude-<name> claude`) and symlink `statusline.sh` into each one.

### What gets shared vs isolated

| Shared (symlinked) | Isolated (per profile) |
|---|---|
| CLAUDE.md | Keychain credentials |
| settings.json | sessions/ |
| mcp.json | history.jsonl |
| .lsp.json | debug/ |
| rules/ | telemetry/ |
| agents/ | todos/, tasks/ |
| skills/ | cache/ |
| commands/ | .claude.json (runtime state) |
| hooks/ | statusline usage cache |
| plugins/ | |

### `setup.sh` options

```bash
./setup.sh --names ops dev          # custom profile names (still two)
./setup.sh --skip-permissions       # include --dangerously-skip-permissions in aliases
./setup.sh --dry-run                # preview without changing anything
```

## Troubleshooting

**The bar didn't appear after install.**
Start a new Claude Code session — `~/.claude/settings.json` is read at session start. `/claudefuel.doctor` confirms the wiring is correct.

**`/claudefuel.update` says "could not resolve latest release."**
GitHub's Releases API is unreachable (network / rate limit). Re-run the paste line directly — it pins to `main` and bypasses the Releases API.

**The bar shows usage for the wrong profile.**
Check `echo $CLAUDE_CONFIG_DIR` in the terminal where the bar is wrong. claudefuel reads that env var to pick a profile. If the variable is unset, it uses `~/.claude/`.

**I edited `statusline.sh` and now `/claudefuel.update` refuses with "installed is newer than spec."**
The version-comparison guard is intentionally strict — local edits to the version header are treated as a pre-release build, not a candidate for forward upgrade. To resume tracking releases, edit the `# claudefuel: vX.Y.Z` header in your local copy to match the spec version, then re-run `/claudefuel.update`.

**I edited `claudefuel.json` and nothing changed.**
Check it parses: `jq . ~/.claude/claudefuel.json`. A malformed file is silently ignored (the bar falls back to defaults rather than breaking). Also check the terminal's `$CLAUDE_CONFIG_DIR` — when a profile is active, the bar reads `$CLAUDE_CONFIG_DIR/claudefuel.json` instead.

**The bar feels slow, or I'm working offline.**
Once a cache exists the render never waits on the network — if it still feels slow, run `/claudefuel.doctor` and ask for timing mode to check the per-stage latency against the published budget. On a flaky or absent network, set `CLAUDEFUEL_OFFLINE=1` to skip every fetch; the bar keeps painting the last cached values.

## Known limitations

- **IDE integration** may not work correctly with custom config dirs ([anthropics/claude-code#4739](https://github.com/anthropics/claude-code/issues/4739))
- **Project-level `.claude/` dirs** are still created in workspaces regardless of `CLAUDE_CONFIG_DIR` ([#3833](https://github.com/anthropics/claude-code/issues/3833))
- `--dangerously-skip-permissions` still prompts for writes to `.claude/` and `.git/` dirs ([#35718](https://github.com/anthropics/claude-code/issues/35718))

## Design docs

The decisions behind the bar are in the repo, not just in the commit log:

- [CONTEXT.md](CONTEXT.md) — the project's vocabulary and the stability contract (names that can't be renamed without stranding installed users).
- [docs/adr/](docs/adr/) — the architecture decisions the code refers to by number:
  [ADR-0001](docs/adr/0001-paste-line-not-plugin.md) (Promptfile, not a plugin),
  [ADR-0002](docs/adr/0002-upgrade-trust-boundary.md) (upgrade trust boundary),
  [ADR-0003](docs/adr/0003-stay-bash-conversational-customization.md) (stay bash; Claude is the config UI),
  [ADR-0004](docs/adr/0004-stateless-cap-eta-on-line-3.md) (stateless cap-ETA),
  [ADR-0005](docs/adr/0005-update-flow-script-led.md) (script-led update flow).
- [docs/design/](docs/design/) and [docs/plans/](docs/plans/) — design explorations and implementation plans. Audit trail rather than current behaviour — superseded documents say so at the top.
