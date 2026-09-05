---
description: Ask usage questions in plain language — answered from the current snapshot with a recommendation
---
# claudefuel-skill: v0.4.6

Answer the user's usage question in prose, reasoning from the bar's snapshot and the ADR-0004 math. The display stays dumb; the recommendation is conversational reasoning performed fresh on each invocation — **never** propose encoding advice rules into `statusline.sh` or any script. Read-only: the only command this skill runs is the snapshot dump.

## Step 1 — Get the question

If the user supplied a question alongside the command, answer that. Otherwise ask what they want to know — typical questions: "can I finish X before my 5h reset?", "should I drop to a cheaper model?", "is my weekly limit going to survive this sprint?".

## Step 2 — Gather the snapshot

```bash
target_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
snapshot=$("$target_dir/statusline.sh" --snapshot)
```

Validate `.schema == {"name": "claudefuel-snapshot", "version": 2}` (version 1 from an older installed script is also fine — it just lacks the `config` block) — on a different name or a greater version, show the raw JSON and point at `/claudefuel.update` instead of guessing. If the usage cache is absent or stale (`.caches.usage`), say so and weaken every conclusion accordingly. `.caches.usage.source` is `"stdin"` or `"oauth"` (TTL 2s vs 300s) — mention which one is backing the numbers when the user asks how current they are.

## Step 3 — Reason to a recommendation

Work from these snapshot quantities (all pure functions of one API response — see `/claudefuel.why` for the full derivation):

- `.derived.five_hour.pct_used`, `.elapsed_seconds`, `.burn_rate_pct_per_hour` (average, sluggish)
- `.derived.five_hour.reset_pace_pct_per_hour` (20%/h constant), `.resets_at_epoch`, `.cap_eta_epoch`, `.cap_eta_rendered`
- `.usage.seven_day.utilization` and its `resets_at` — the slower constraint
- `.prepaid.amount` (cents) — the last-resort runway when extra usage is enabled

End with a clear recommendation, hedged honestly: the burn rate is a window **average**, so a burst of heavy prompts shortens real runway faster than the numbers suggest. Use `~` and ranges, never precise promises.

### Worked example 1 — "Can I finish this refactor before my 5h reset?"

1. Time until reset: `resets_at_epoch − now`.
2. Runway at current pace: `(100 − pct_used) / burn_rate` hours.
3. If `cap_eta_rendered` is true, runway ends **before** the reset — report roughly when (`cap_eta_epoch`, as a ±15 min range in local time), ask how big the remaining work is if unclear, and recommend: trim scope to fit the runway, slow the pace (smaller prompts, fewer retries), or accept a pause until reset.
4. If the threshold gate failed (burn rate ≤ reset-pace), the current pace survives to the reset — answer yes, with the average-burn caveat.
5. If the noise-floor gate failed (`pct_used < 10`), say there is not enough signal in this window yet to predict either way.

### Worked example 2 — "Should I drop to a cheaper model?"

1. Compute the pace ratio: `burn_rate / reset_pace`. At ≤ 1.0 the 5h window survives to reset — switching buys nothing now.
2. Check the 7-day window: a 5h reset rescues you every 5 hours, but if `.usage.seven_day.utilization` is also climbing hot, a cheaper model is one of the few levers that actually bends the weekly curve.
3. Check the prepaid balance: with extra usage enabled and credits remaining, hitting the cap degrades to spending money rather than stopping — frame the choice as cost vs. capability.
4. Recommend in prose with the tradeoff stated: a cheaper model lowers burn but also capability; it matters most when the pace ratio is well above 1 **and** the 7-day window is also under pressure. Otherwise finishing the current task on the current model and letting the reset do its job is usually the better trade.

## Boundaries

- Snapshot in, prose out. No API calls, no file writes, no edits to `statusline.sh`, `settings.json`, or `claudefuel.json`.
- Re-running `--snapshot` mid-conversation for fresher numbers is fine; anything beyond that is out of scope.
- Advice quality depends on honest inputs: always disclose stale caches and the average-burn-rate lag before the recommendation, not after.
