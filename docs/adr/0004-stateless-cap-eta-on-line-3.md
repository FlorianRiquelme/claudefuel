# Stateless cap-ETA on Line 3 — predictive segment without leaving bash

We added a predictive segment to Line 3 of the bar: a `~cap HH:MM–HH:MM` range rendered next to the 5-hour `resets <time>` cell, signalling roughly when the current 5-hour window will hit 100% utilization at the user's current burn rate.

The brainstorm in `docs/design/configure-feature-brainstorm.md` explicitly flagged predictive segments as **ADR-breakers** — Codex's Cliffs taxonomy identifies a background daemon (Cliff #2) as the trigger that would force claudefuel off bash onto Go. We chose to ship the predictive segment without crossing that boundary by computing the prediction from a single API snapshot — no state across renders, no daemon, no new IPC.

## The non-obvious move

The Anthropic `/api/oauth/usage` response gives `.five_hour.utilization` and `.five_hour.resets_at` on every call. Because the window length is contractual (5 hours, encoded in the field name itself), `window_started = resets_at - 5h` is a derivable quantity. From there:

```
time_elapsed   = now - window_started
burn_rate      = pct_used / time_elapsed
reset_pace     = 100% / 5h
time_to_cap    = (100 - pct_used) / burn_rate
cap_eta        = now + time_to_cap
```

Every quantity above is a pure function of a single snapshot. **Average** burn rate is stateless; **instantaneous** burn rate (which would require persisting samples between renders) is what the brainstorm meant by ADR-breaker. We deliberately picked the weaker, snapshot-derived version.

The cost of choosing average over instantaneous: the rate is sluggish. If you idle the first hour of a window and then start burning, the rate is dragged down by the idle period and the cap-ETA lags reality. We accept this. The display is framed as a **rough estimate** (tilde prefix, range output) precisely so the lag doesn't read as a precision claim it can't honour.

## Display contract

The segment renders inside the 5-hour cell on Line 3, **next to** the existing reset time (never replacing it):

```
resets 5:30pm · ~cap 4:15–4:45pm
```

Three gates govern visibility:

1. **Threshold gate**: `burn_rate > reset_pace`. If the user is on-track or under-pace, no cap-ETA renders — the prediction is meaningless when the user will never hit the cap. Equivalently: cap-ETA only renders when `cap_eta < resets_at`.
2. **Noise-floor gate**: `pct_used >= 10%`. Below 10%, a single heavy prompt would dominate the rate and produce flickery cap-ETAs that don't reflect sustained activity. The 10% floor ensures we always have a meaningful denominator before predicting.
3. **Profile-aware**: the segment uses whatever profile's snapshot the bar already reads (no new keychain logic, no new cache file).

The range is a fixed `±15 minutes` band around the point estimate. The band is not a statistical interval — it's an honesty signal. The tilde + range + word `cap` are jointly self-documenting to a user who hasn't read the docs.

## Why this preserves ADR-0003

[ADR-0003](0003-stay-bash-conversational-customization.md) scopes customization to **minor tweaks**: color thresholds, segment ordering, segment show/hide, theme presets. The cap-ETA segment inherits the show/hide toggle from that scope — it is a segment, and `/claudefuel.configure` exposes it as one. Default: on.

What we explicitly did **not** do:

- **No persistence between renders.** No file the bar writes for the next render to read. The bar remains a pure function of `(stdin, env, API response)`.
- **No new data source.** Reuses the existing `/api/oauth/usage` call and its existing 60-second cache.
- **No new prerequisite.** Still bash + jq + curl. No `bc`, no python, no daemons.
- **No instantaneous burn rate.** The day a user opens an issue saying "the cap-ETA lags reality, I want it to track my burst activity," that is the trigger to revisit this ADR *and* [ADR-0003](0003-stay-bash-conversational-customization.md) together. Instantaneous burn rate is a real feature, but it is a feature-class change, not a tweak.

## Discoverability

The segment is dormant most of the time (only renders when burning). Two channels surface it to users:

- **Fresh installers**: `INSTALL.md` instructs the reconciling agent to mention the cap-ETA segment in its post-install summary. The Promptfile is the canonical contract; the agent reading it is the canonical UI surface for first-time explanation.
- **Upgraders**: `/claudefuel.update`'s post-upgrade summary mentions the new segment when users upgrade past the version that adds it.

Both channels are already conversational and on-rails. Neither adds bar-side state. The bar does not need to know it has "been seen."

## Consequences

- The Line 3 visual contract grows: the 5-hour cell can now contain `resets <time>` or `resets <time> · ~cap <range>`. The column-padding math in `statusline.sh` needs to accommodate the wider variant when active.
- `claudefuel.json` gains one new key under the `segments` show/hide map (default `true`).
- CONTEXT.md gains three new terms: **Burn rate**, **Reset-pace**, **Cap-ETA**.
- The brainstorm's "Single Predictive Slot" idea is now claimed by Line 3, not Line 1. The drift-arrow slot remains the drift-arrow slot. Future predictive ideas (prompts-remaining-at-rate, drift compass, ghost-burn) would need to either join the cap-ETA cell or claim a new slot — and most of them are stateful, so they would trigger an ADR-0003 revisit anyway.
- If Anthropic ever changes the 5-hour window length, the field name in the API response changes too (`.five_hour` → `.eight_hour`-style), making the breakage loud rather than silent. We rely on this contract rather than introspecting window length from the response.
