---
description: Edit claudefuel's user config conversationally (color thresholds, segment ordering, show/hide, theme)
---
# claudefuel-skill: v0.4.0

> **Scope:** minor tweaks only — color thresholds, segment ordering, segment show/hide, theme presets. That boundary comes from ADR-0003; anything richer (custom segments, user data sources, scripts) is out of scope for this skill. The bar reads `~/.claude/claudefuel.json` (or `$CLAUDE_CONFIG_DIR/claudefuel.json` when a profile is active) on every render and merges it over baked-in defaults. A missing file means pure defaults. A malformed file is ignored — defaults win, the bar never breaks over config.

You are the configuration UI. There is no TUI, no wizard — walk the user through changes conversationally, then write the JSON.

## Procedure

1. **Resolve the config path.** `$CLAUDE_CONFIG_DIR/claudefuel.json` if `CLAUDE_CONFIG_DIR` is set in this session, else `~/.claude/claudefuel.json`.
2. **Read** the file. Treat a missing file as `{}`. Show the user their current *effective* config: the defaults table below with their overrides applied, so they see what the bar is actually doing.
3. **Converse.** Ask what they want to change, map it to the keys below, and confirm the concrete values before writing. Reject anything outside the schema — that is an ADR-0003 boundary, not a missing feature; say so plainly.
4. **Write sparse JSON.** Emit only `"version": 1` plus the keys that differ from defaults. Preserve any unknown keys already present in the file (the bar ignores them; they may belong to a newer version). Validate with `jq . <file>` before moving it into place.
5. **Confirm.** Changes apply on the next render — no restart needed. Offer a test render:
   ```bash
   printf '%s' '{"model":{"display_name":"Claude"}}' | bash ~/.claude/statusline.sh
   ```

## Schema (version 1)

All keys optional; absent keys use the default.

| Key | Default | Meaning |
|---|---|---|
| `version` | `1` | Schema version. Always write `1`. |
| `theme` | `"default"` | Palette preset: `"default"` (truecolor) or `"mono"` (no hues; structure via dim only). |
| `color_thresholds.orange` | `50` | Utilization % at which bars turn orange (below: green). |
| `color_thresholds.yellow` | `70` | … turn yellow. |
| `color_thresholds.red` | `90` | … turn red. One ladder, shared by the ctx, 5h, and 7d bars. |
| `reset_display` | `"clock"` | Line 3 reset style: `"clock"` (`↻ 5:30pm`) or `"countdown"` (`↻ in 42m`). |
| `segments.order.line1` | `["model","ctx","thinking","effort","drift"]` | Line 1 segment order. |
| `segments.order.columns` | `["5h","7d","extra"]` | Column order for Lines 2 **and** 3 together (Line 3 always mirrors Line 2). |
| `segments.hide` | `[]` | Tokens to hide: any of the order tokens above, plus the hide-only badges `"profile"` (the `[name]` prefix on the model segment) and `"cap_eta"` (the `~cap` range on the 5h reset cell — see ADR-0004). |

Unknown tokens in `order`/`hide` are ignored. Unknown keys are ignored. Non-numeric thresholds fall back to defaults.

Example — red alarm earlier, countdown resets, no thinking segment:

```json
{
  "version": 1,
  "color_thresholds": { "red": 80 },
  "reset_display": "countdown",
  "segments": { "hide": ["thinking"] }
}
```

## Guardrails

- `~/.claude/claudefuel.json` is **user-owned** — install, update, and uninstall never touch it. Never delete it; only edit it with the user's confirmation.
- **Do not** edit `~/.claude/settings.json` or `~/.claude/statusline.sh` from this skill — those are install-managed. Direct the user to `/claudefuel.update` for version drift and `/claudefuel.doctor` for health checks.
- Hiding `"drift"` silences the `↗ /claudefuel.update` signal. Honor the request, but warn the user they will no longer see new releases on the bar.
