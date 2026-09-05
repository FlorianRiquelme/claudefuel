---
description: Show every known profile's cached usage at a glance (fleet view)
---
# claudefuel-skill: v0.4.6

Render a compact fleet table of every Claude Code profile claudefuel has rendered recently, read from the per-profile usage caches already on disk. Strictly read-only: never fetch usage for a profile that isn't active in this terminal — only show what is already cached, and always show how old each snapshot is. Use `$CLAUDE_CONFIG_DIR` when set, otherwise `~/.claude`, as `$target_dir`.

1. **Dump the machine-readable fleet data:**
   ```bash
   "$target_dir/statusline.sh" --fleet
   ```
   Each output line is one JSON object:
   `{profile, cache_age_seconds, sessions, five_hour: {utilization, resets_at}, seven_day: {utilization, resets_at}, extra_usage, prepaid: {amount, currency}}`

   `sessions` counts the live Claude Code sessions currently drawing on that profile's account window (heartbeats fresher than 5 minutes). More than 1 means the window is shared — the usual explanation for a bar that runs hot or stale faster than one session can account for.

2. **If the output is empty**, tell the user no profile caches were found — a profile appears here only after its status bar has rendered at least once (which writes `$CLAUDE_CONFIG_DIR/cache/claudefuel-usage.json`). Do not fetch anything on their behalf.

3. **Render a markdown table**, one row per profile:

   | Profile | sessions | 5h | 7d | resets (5h) | balance | data age |
   |---|---|---|---|---|---|---|
   | work | ⧉ 3 | `●●○○○○○○○○` 18% | 32% | 4:30pm | €59.29 | 2m |

   - `sessions` from the heartbeat count; render `—` when 0 (no live session on that profile right now).
   - Build the 5h bar from `five_hour.utilization` as ten `●`/`○` cells, with the percent next to it.
   - `resets (5h)` is `five_hour.resets_at` converted to local time; omit when null.
   - `balance` is `prepaid.amount` in cents, formatted as `<currency symbol><amount/100>` (EUR → €, GBP → £, JPY → ¥, otherwise $); leave the cell empty when `prepaid` is null.
   - `data age` from `cache_age_seconds` (e.g. `45s`, `12m`, `3h`). Mark rows older than 1 hour as stale (e.g. append `⚠ stale`) — a 5h-window number older than its own window says little about the profile's current state.

4. **Close with one honesty line:** these numbers are cached snapshots from each profile's last render, not live data. Switching to a profile (its terminal tab or `CLAUDE_CONFIG_DIR`) refreshes it.
