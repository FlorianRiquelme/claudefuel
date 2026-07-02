---
description: Edit claudefuel's user config conversationally — describe the look you want, see a rendered before/after, approve, done
---
# claudefuel-skill: v0.4.6

> **Scope:** minor tweaks only — color thresholds, segment ordering, segment show/hide, theme presets, reset display (ADR-0003). Anything richer (custom segments, data sources, scripts, colors beyond the two themes) is out of scope: decline citing ADR-0003 **and offer the nearest in-scope alternative** (e.g. "custom red color" → "I can't change the palette, but `mono` removes hues entirely, or I can move when red kicks in"). The bar reads `claudefuel.json` every render and merges it over baked-in defaults; missing file = pure defaults; malformed file = defaults win, the bar never breaks over config.

You are the configuration UI. No TUI, no wizard — the loop is: understand intent → render a before/after preview → confirm on the *rendered output*, never on raw JSON → write.

## Procedure

1. **Resolve + validate.** Path: `$CLAUDE_CONFIG_DIR/claudefuel.json` if set, else `~/.claude/claudefuel.json`. Script: `statusline.sh` next to it. Run `"$script" --validate-config` and read the JSON report (`status`, `warnings`, `effective`, `overridden_keys`). If `status` is `malformed`, show the parse problem and offer to fix or reset the file — with the user's confirmation, it is user-owned. Show the *effective* config (defaults + overrides), not the raw file.
2. **Understand intent** via the vocabulary below. Preset → propose the preset; keys → propose the concrete diff; out of scope → decline + nearest alternative. Unrecognized → ask one clarifying question with 2–3 concrete options rendered as demos. **Never write a config the user hasn't seen rendered.**
3. **Preview before writing.** Write the candidate (sparse!) to a temp file via `mktemp` or the session scratchpad — never next to the real config. Then render before/after in two states:
   ```bash
   "$script" --demo healthy; "$script" --demo critical                          # current
   CLAUDEFUEL_CONFIG="$tmp" "$script" --demo healthy
   CLAUDEFUEL_CONFIG="$tmp" "$script" --demo critical                           # candidate
   ```
   Show both pairs side by side and ask for confirmation on what they see.
4. **On yes:** back up the existing file to `claudefuel.json.bak-<UTC-timestamp>` (`YYYYMMDDHHMMSS`, same convention as install backups; skip if no file exists), `mv` the candidate into place, run `--validate-config` again and surface any warnings, then confirm: **"live on your next render — no restart needed."**
5. **Undo.** "undo that" / "go back": find the most recent `claudefuel.json.bak-*`, show its diff against the current file, and restore it on confirmation. `/claudefuel.rollback` is for the *install*, not this file — say so if the user reaches for it.
6. **Cross-profile (ask once, after applying).** If sibling profiles exist (`~/.claude-*` dirs containing a `statusline.sh`), ask: "apply the same look to your other profiles (<names>)?" Each profile has its own `claudefuel.json`; never write to an inactive profile without that explicit yes. Repeat the backup + validate steps per profile.

## Intent vocabulary

Presets are expanded by *this skill* into concrete schema-v1 keys at write time — no `preset` key exists in the file, so a preset is just a starting point the user can tweak.

| User says (examples) | Maps to |
|---|---|
| "calmer", "less alarming", "stop yelling at me" | raise `color_thresholds` (e.g. 70/85/95) — show current values first |
| "warn me earlier", "more cautious" | lower `color_thresholds` (e.g. 40/60/80) |
| "minimal", "less clutter", "just the essentials" | **preset `minimal`**: `hide: ["thinking","effort","profile","extra","drift","session","activity"]` — warn: hiding `drift` silences release notices |
| "what is Claude doing", "live activity", "hide the spinner" | show/hide `activity` (`▸ Bash 12s` from the transcript tail) |
| "which session is this", "label my panes" | show/hide `session`; suggest `/rename` to give the session a real name |
| "everything", "back to normal", "reset" | delete overrides — restore defaults (`{"version":1}` or remove the file) |
| "no colors", "colorblind", "accessible", "grayscale" | `theme: "mono"` (structural alarms carry severity without hue) |
| "countdown", "how long until reset" | `reset_display: "countdown"` |
| "clock times" | `reset_display: "clock"` |
| "put the weekly bar first", "reorder" | `segments.order.columns` / `segments.order.line1` |
| "hide X" / "show X" | `segments.hide` add/remove; if X is unrecognized, list valid tokens |
| "focus mode", "deep work" | **preset `focus`**: minimal + `reset_display: "countdown"` |
| "cockpit", "show me everything, tight" | **preset `cockpit`**: full segments (empty `hide`), thresholds 40/60/80 |

## Schema (version 1)

All keys optional; absent keys use the default. Write **sparse**: `"version": 1` plus only the keys that differ from defaults. Preserve unknown keys already in the file.

| Key | Default | Meaning |
|---|---|---|
| `version` | `1` | Schema version. Always write `1`. |
| `theme` | `"default"` | `"default"` (truecolor) or `"mono"` (no hues). |
| `color_thresholds.{orange,yellow,red}` | `50`/`70`/`90` | Utilization % where bars change color (below orange: green). One ladder shared by ctx/5h/7d. |
| `reset_display` | `"clock"` | Line 3 style: `"clock"` (`↻ 5:30pm`) or `"countdown"` (`↻ in 42m`). |
| `segments.order.line1` | `["model","session","ctx","thinking","effort","agent","activity","drift"]` | Line 1 order. `session` = identity chip (`◈ name`), `agent` = subagent badge, `activity` = live tool call (`▸ Bash 12s`). |
| `segments.order.columns` | `["5h","7d","extra"]` | Column order for Lines 2 **and** 3 (Line 3 mirrors Line 2). |
| `segments.hide` | `[]` | Any order token above, plus hide-only `"profile"` (the `[name]` badge), `"cap_eta"` (the `~cap` range, ADR-0004), `"projection"` (the `→N%` landing prediction on the 5h cell), and `"sessions"` (the `⧉ N` shared-window session count). |

Unknown tokens/keys are ignored by the bar; `--validate-config` warns about them with a nearest-match suggestion.

## Guardrails

- This skill writes **only** `claudefuel.json` (+ its `.bak-*` siblings). Never `settings.json`, never `statusline.sh` — those are install-managed, and some installs wrap the statusline command in `settings.json` (leave it alone even if it looks unusual). Version drift → `/claudefuel.update`; health → `/claudefuel.doctor`.
- Always sparse writes; always preserve unknown keys; always `--validate-config` before declaring success.
- Candidate/temp files via `mktemp` or the session scratchpad, never beside the real config.
- Hiding `"drift"` silences the `↗ /claudefuel.update` signal — honor it, but warn the user they will no longer see new releases on the bar.
- **Degrade gracefully:** if the installed script lacks `--demo` or `--validate-config` (predates v2), fall back to the v1 procedure — confirm the concrete JSON diff in chat, validate with `jq .`, and offer a manual test render: `printf '%s' '{"model":{"display_name":"Claude"}}' | bash "$script"`.
