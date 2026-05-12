---
description: Edit claudefuel's user config conversationally (placeholder in v0.2.0)
---
# claudefuel-skill: v0.2.0

> **Scope in v0.2.0:** this release ships the `/claudefuel.configure` slash-command name as part of the stability contract, but the bar does not yet read `~/.claude/claudefuel.json`. The skill will gain real settings to manage in a follow-up release. See `docs/design/upgrade-experience.md` and `docs/adr/0003-stay-bash-conversational-customization.md` for the intended scope (minor tweaks — color thresholds, segment ordering, segment show/hide, theme presets).

If the user invokes this skill today, do this:

1. **Read** `~/.claude/claudefuel.json` (or `$CLAUDE_CONFIG_DIR/claudefuel.json`) if it exists, and present its contents as markdown so the user sees what is already on disk. Treat a missing file as empty `{}`.
2. **Tell the user** that no config keys are wired into the bar in v0.2.0 — anything they put in `claudefuel.json` is preserved across upgrades but has no effect yet. Point them at the design doc above.
3. **Do not** modify, create, or delete the config file. It is user-owned and outside the install bundle.
4. **Do not** offer to edit `~/.claude/settings.json` or `~/.claude/statusline.sh` from this skill — those are install-managed. Direct the user to `/claudefuel.update` for version drift.

When the bar gains config-reading, this skill's body grows into a conversational editor for the keys the bar honors (`color_thresholds`, `segments.order`, `segments.hide`, `theme`). Until then, this skill exists to reserve the name and to give the user an honest answer.
