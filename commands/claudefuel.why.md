---
description: Explain the bar's current numbers — annotated snapshot with the full derivation chain
---
# claudefuel-skill: v0.4.6

Show-your-work view of the bar's current state. Annotate every number and every gate decision against the derivation chain documented in ADR-0004. Read-only: do not fetch anything, do not modify any file. The snapshot is the only input.

## Step 1 — Dump the snapshot

```bash
target_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
snapshot=$("$target_dir/statusline.sh" --snapshot)
```

If the command fails or prints nothing, the installed `statusline.sh` predates the snapshot API or is missing — point the user at `/claudefuel.update` (version drift) or `/claudefuel.doctor` (install health) and stop.

## Step 2 — Validate the schema

This skill understands `.schema == {"name": "claudefuel-snapshot", "version": 2}`, and tolerates version 1 from an older installed script (the v2 `config` block is simply absent there). If `.schema.name` differs or `.schema.version` is greater than 2, do not guess at field meanings — show the raw JSON, say the skill and script versions are out of sync, and point at `/claudefuel.update`.

## Step 3 — Annotate, in this order

1. **Profile.** `.profile.name` and `.profile.config_dir` — which account's numbers these are.
2. **Cache health.** For each entry in `.caches` (usage, prepaid, upstream_version): present/absent, age vs TTL, fresh or stale. `.caches.usage.source` is `"stdin"` or `"oauth"` — say which one is backing the bar; TTL is 300s for the OAuth cache and 2s for the stdin/native mirror, so state the source whenever explaining a number's freshness. Stale data must be labeled stale — a number from a stale cache is yesterday's fuel reading, never present it as current. If the usage cache is absent, say the bar has not rendered recently for this profile and stop after reporting versions.
3. **Versions.** `.versions.installed` vs `.versions.upstream`; whether the `↗ /claudefuel.update` drift signal is currently earned (`.versions.drift`).
4. **The 5-hour derivation chain.** Walk `.derived.five_hour` through the ADR-0004 arithmetic, plugging in the actual numbers and converting epochs to the user's local time:

   ```
   window_started = resets_at − 5h
   elapsed        = now − window_started
   burn rate      = pct_used / elapsed
   reset-pace     = 100% / 5h  (= 20%/h, constant)
   time_to_cap    = (100 − pct_used) / burn rate
   cap_eta        = now + time_to_cap   (rendered as a ±15 min range)
   ```

5. **Gate decisions.** For each gate in `.derived.five_hour.gates`, state pass/fail and explain *why* in plain language:
   - **Noise floor** (`pct_used >= 10`): below 10%, a single heavy prompt dominates the average and the prediction would flicker — the bar refuses to predict from a meaningless denominator.
   - **Threshold** (`cap_eta < resets_at`, equivalently burn rate > reset-pace): if the window resets before the projected cap, the prediction is not actionable and the bar stays quiet.

   Conclude with `.derived.five_hour.cap_eta_rendered`: whether `~cap` is on the bar right now, and if not, which gate hid it.
6. **The other windows.** `.usage.seven_day` and `.usage.extra_usage` / `.prepaid` (balance in cents, divide by 100 for display). Note that no cap-ETA exists for these by design — their burn rates are too inertial to be actionable at sub-day horizons (ADR-0004 scope).
7. **Config (v2).** When `.config` is present and the question touches appearance or visibility ("why is my bar red at 75%?", "where did the thinking segment go?"), answer from it: `.config.effective` holds the merged values driving the render, `.config.overridden_keys` names exactly what the user's `claudefuel.json` changed (e.g. "your `color_thresholds.red` is set to 70 — the default is 90"), `.config.status` says whether the file parsed (`malformed` means defaults won). Point at `/claudefuel.configure` for changes; never edit the file from this skill.

## Honesty rules

- Burn rate is the **average** over the open window, never instantaneous — the bar persists nothing between renders. If the user idled early and is bursting now, the average lags reality; say so.
- The ±15 min cap-ETA band is an honesty signal, not a statistical interval.
- If the user wants fresher numbers, tell them the bar refreshes its usage cache on the next render (300s TTL for the OAuth cache, 2s for the stdin/native mirror) — do not curl the API from this skill.
