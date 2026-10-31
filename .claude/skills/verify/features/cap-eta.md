# Cap-ETA

When the user is burning through the 5-hour window faster than it resets, line 3 predicts when they will hit 100%, as a ±15-minute range next to the 5h reset. It stays dormant while usage is healthy.

## Sub-features

- `cap-shown` renders `~cap <lo>-<hi>` after the 5h `↻` time when the burn rate exceeds reset pace, utilization is ≥10%, and the predicted cap is before reset.
- `cap-dormant-slow` shows nothing when the burn rate is at or below reset pace.
- `cap-dormant-low` shows nothing below 10% utilization, however fast the burn.
- `cap-weekly-only` shows nothing when `.five_hour` is `null`.

## How to get to it (user POV)

- Burn heavily early in a 5h window. Line 3 gains `· ~cap 3:10pm-3:40pm` beside `↻ <5h reset>`.

## Driving it with cf-render

Preconditions:

- `cf-doctor` exits 0.

- **Burning hot.** 60% used 2h into the window (3h left), so 100% lands about 1h20m from now. Run `R --label cap-shown --tz UTC --usage @.claude/skills/verify/fixtures/usage-burning.json`. Line 3 reads `↻ <now+3h> · ~cap <now+65m>-<now+95m>`. Check both ends against `rendered_at` in `manifest.txt`.
- **Healthy pace.** 35% used 4h in (1h left). Run `R --label cap-dormant-slow --usage @.claude/skills/verify/fixtures/usage-healthy.json`. Line 3 has no `~cap`.
- **Below threshold.** Run `R --label cap-dormant-low --usage '{"five_hour":{"utilization":9,"resets_at":"@now+17000"},"seven_day":{"utilization":5,"resets_at":"@now+400000"}}'`. That is 9% after 10 minutes, a very fast burn, yet there is no `~cap`.
- **Weekly-only.** Run `R --label cap-weekly-only --usage @.claude/skills/verify/fixtures/usage-weekly-only.json`. There is no `~cap`.
- **Proof.** Cite `usage-seed.json` (resolved ISO times), `manifest.txt` `rendered_at`, and line 3 of `run-1.txt`.

## Gotchas

- The window start is inferred as `resets_at − 5h`. A `resets_at` more than 5h out makes elapsed time ≤ 0, and the segment stays hidden.
- Times are lowercase 12-hour with no leading space (`9:05pm`). The range is cap-ETA ± 900 s, so the edges round to the minute.
- The segment is rendered dim, not red. Don't assert a color.
