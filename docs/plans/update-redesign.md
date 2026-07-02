# Update flow redesign

Superseded: Resolved into [[0005-update-flow-script-led]] and implementation plan in `update-redesign-implementation.md`.

Status: design, not implemented
Captured: 2026-05-15 brainstorm session
Trigger: a `/claudefuel.update` v0.3.0 → v0.4.0 run that was full of noise the user didn't care about

## Problem

The current `/claudefuel.update` skill treats every invocation as a first-touch security audit — 130-line diff dumps, per-step postcondition checkboxes, multiple bash blocks of orchestration narrated turn-by-turn. For a returning user (the dominant audience) this is theater. The audit ceremony is pitched at a stranger paste-installing for the first time from a `curl | bash` line.

Concretely observed in the trigger session:
- Three commands to detect/compare versions, each rendering process output (`installed: 0.3.0`, `spec: 0.4.0`, `spec-newer`)
- 130-line `diff -u` of `statusline.sh` rendered into the conversation
- Five separate bash blocks for the reconcile steps, each with `✓ ...` postcondition checkboxes
- Two distinct "verify" blocks at the end with overlapping checks
- LLM-introduced drift: ad-hoc substitution of `$target_dir/statusline.sh` for the literal `~/.claude/statusline.sh` in `.statusLine.command`, which the LLM then noticed and reverted

## Insights

### The bar is the discovery surface, the skill is not

The status bar's `↗ /claudefuel.update` drift signal is read-only — not clickable, and tightly constrained on real estate. It tells the user *an update exists and what to type*. Nothing more. By the time the user invokes `/claudefuel.update`, the precondition "there's an update" is already established. **Every invocation is "apply now," not "check for update."**

Implication: the skill does not need 3-state version comparison on the happy path, and "you're current" is not a case worth optimising for — it barely happens.

### The audience is the update path, not install

First-touch install happens once per user. Updates happen every release. Design for the update path; install inherits the same shape (the paste-line bootstraps the same script that updates run).

### LLM-introduced drift is a real failure mode

The path-substitution mishap in the trigger session is the load-bearing example. The Promptfile-driven model trusts the LLM to "exercise judgment" — but judgment varies session-to-session. Moving mechanics into a deterministic script eliminates this entire class.

### Resilience starts from arbitrary state

The user might have hand-edited `statusline.sh`, broken `settings.json`, deleted a command file, symlinked things weirdly across `CLAUDE_CONFIG_DIR` profiles. The update flow must succeed regardless of starting state — that is what "I want to update *out of* this state" means. Where the script can't reach desired state on its own, the LLM gets a structured diagnostic and drives forward. The user never learns they crossed a script/LLM boundary.

## Design

### Architecture

- **`claudefuel-update`** — a shell script (~30 lines core), versioned with the bundle. Single executable that owns all mechanics.
- **`/claudefuel.update`** — thin skill spec. Steps: run the script; if exit 0, done; if exit non-zero, read the diagnostic, drive the user forward to desired state.
- **`INSTALL.md`** — collapses to a paste-line that bootstraps the script. The script handles everything from then on.

### Happy path

```
Bar:    ↗ /claudefuel.update           ← signal only (read-only)
User:   /claudefuel.update
Script: v0.3.0 → v0.4.0
        • Line 1 redesign — inline ctx bar, drop %used/%remain
        • Cap-ETA (dormant until burn rate exceeds reset-pace)
        Apply? [y/N] y
        ...
        Done. (rollback: /claudefuel.rollback)
```

No LLM involvement. Release notes are the only trust surface — three bullets max, written once per release by the maintainer, fetched from the GitHub release body (`gh release view <tag> --json body` or the REST API equivalent).

### Failure path

The script **does not auto-revert**. If a step fails:

1. Stop
2. Dump a structured JSON diagnostic
3. Exit non-zero
4. Leave the filesystem as-is so the LLM can drive forward

Auto-revert would be wrong here — the starting state might be exactly the broken state the user is trying to update *out of*. Forward recovery toward desired state is the goal, not preservation of the starting state.

The skill catches the non-zero exit, reads the diagnostic, and drives the user to desired state through natural-language repair. The user never learns they crossed a script/LLM boundary.

### Diagnostic contract

The JSON bundle written on failure (path: `$target_dir/cache/claudefuel-update-diagnostic.json`):

```json
{
  "step": "patch_settings_json",
  "exit_reason": "jq exited 5: parse error at line 12",
  "target_dir": "/Users/.../.claude-fresh",
  "backup_timestamp": "20260515085416",
  "available_backups": [
    "statusline.sh.bak-20260515085416",
    "settings.json.bak-20260515085416"
  ],
  "current_state": {
    "statusline.sh": {"present": true, "version": "0.4.0", "executable": true},
    "settings.json": {"present": true, "valid_json": false, "raw": "..."},
    "commands": {
      "claudefuel.update.md": {"present": true, "version": "0.4.0"},
      "claudefuel.doctor.md": {"present": true, "version": "0.4.0"},
      "...": "..."
    }
  },
  "desired_state": {
    "statusline_version": "0.4.0",
    "skill_version": "0.4.0",
    "settings_status_line": {"type": "command", "command": "<target>/statusline.sh"},
    "...": "..."
  },
  "env": {
    "CLAUDE_CONFIG_DIR": "...",
    "jq": "1.7.1",
    "curl": "8.7.1",
    "platform": "darwin",
    "shell": "zsh"
  }
}
```

Embed the desired-state spec inline so recovery is offline-capable — survives a GitHub outage mid-recovery.

### Skill spec (sketch)

```
1. Run `claudefuel-update`. Pass output through verbatim.
2. Exit 0 → done.
3. Exit non-zero → read $target_dir/cache/claudefuel-update-diagnostic.json,
   inspect the current filesystem state, drive the user forward to desired
   state. You have the diagnostic and the disk; do whatever it takes.
```

## What this kills

- 3-state version comparison rendered in the happy path (bar already did it)
- Raw `diff -u` rendering in the skill (release notes are the trust surface; raw diff becomes `claudefuel-update --diff` for users who want it)
- Per-step postcondition `✓` checkboxes (deterministic script doesn't narrate success)
- Two separate verify blocks (one final line, not running narration)
- LLM ceremony around mechanical work
- The entire turn-by-turn orchestration pattern in `INSTALL.md`'s `## Reconcile` section

## Open questions

1. **Release notes source.** GitHub release body is the most natural — the maintainer already writes it for the GitHub UI. Alternatives: tagged `CHANGELOG.md` section, separate `notes/{version}.md` per release. Going with GitHub release body unless a reason to split.
2. **`--diff` / `--verbose` flags.** Should the script support them for users who want the old ceremony? Probably yes, opt-in.
3. **`/claudefuel.rollback`.** Operates on `*.bak-*` files, which the new flow still produces. Probably unchanged.
4. **`/claudefuel.doctor`.** Its job overlaps with the diagnostic-on-failure model. Might shrink — or stay as a "run on demand even when nothing's broken" surface.
5. **Repair mode.** If the script detects a partial-install starting state (some files at v0.3.0, some at v0.4.0, missing files), is it a separate `claudefuel-update --repair` flag or just the normal forward reconcile? Lean: forward reconcile handles it implicitly; no separate flag.
6. **Install path inheriting.** The bootstrap Promptfile becomes "download the script and run it." What's the minimum the Promptfile has to do — just `curl -fsSL .../claudefuel-update -o ~/.claude/claudefuel-update && chmod +x && ~/.claude/claudefuel-update`? Then the script handles preconditions, target detection, everything.

## Next concrete moves

1. Pin down the diagnostic JSON schema with an example for each failure mode the script knows how to dump
2. Enumerate failure modes: which ones the script detects-and-dumps vs which ones are "script crashed unexpectedly" and the LLM picks up from raw state
3. Sketch the `claudefuel-update` script
4. Rewrite `/claudefuel.update` skill spec (will be ~10 lines of prose)
5. Shrink `INSTALL.md` — desired-state contract stays as documentation, but the Reconcile section collapses into "download script, run script"
6. Decide release-notes location and format conventions (see open question 1)
