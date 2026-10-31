# Usage bars

Lines 2 and 3 show how much of the 5-hour and 7-day rate limits the user has burned, when each resets, and the prepaid extra-usage balance. The data comes from the usage API response cached per profile.

## Sub-features

- `usage-5h-7d` shows `5h: <bar> N%` and `7d: <bar> N%` on line 2, with matching `↻ <time>` and `↻ <date, time>` on line 3.
- `usage-weekly-only` hides the 5h bar and its reset when `.five_hour` is `null`.
- `usage-colors` turns bars green, orange, yellow, then red as utilization rises.
- `usage-extra` shows `extra: <symbol><amount>` when `extra_usage.is_enabled` is true and the prepaid balance is non-zero. EUR→€, GBP→£, JPY→¥, anything else→$.
- `usage-extra-hidden` omits the extra column when it is disabled or the balance is 0.
- `usage-no-data` shows line 1 only when no usage data exists and no token is available.

## How to get to it (user POV)

- Any Claude Code session. The bars refresh from the API at most every 5 minutes.
- On a plan with only a weekly limit, the 5h bar is absent.

## Driving it with cf-render

Preconditions:

- `cf-doctor` exits 0.

- **Healthy usage with EUR balance.** Run `R --label usage-5h-7d --tz UTC --usage @.claude/skills/verify/fixtures/usage-healthy.json --prepaid @.claude/skills/verify/fixtures/prepaid-eur.json`. Line 2 contains `5h: ●●●○○○○○○○ 35%`, `7d: ●●●●●●○○○○ 62%`, and `extra: €42.50`. Line 3 has two `↻` times: the first is now+1h, the second is now+4d as `<mon> <d>, <time>`. `net.log` is empty.
- **Weekly-only plan.** Run `R --label usage-weekly-only --usage @.claude/skills/verify/fixtures/usage-weekly-only.json`. Line 2 starts with `7d: ●●●●○○○○○○ 41%` and has no `5h:`. Line 3 has a single `↻`. There is no `extra:`.
- **Critical usage.** Run `R --label usage-colors --usage @.claude/skills/verify/fixtures/usage-critical.json`. `run-1.colors.txt` line 2 shows `{red}●●●●●●●●●` for both bars.
- **Extra disabled.** Run `R --label usage-extra-hidden --usage @.claude/skills/verify/fixtures/usage-weekly-only.json --prepaid @.claude/skills/verify/fixtures/prepaid-eur.json`. There is no `extra:` even though a balance is cached.
- **No data.** Run `R --label usage-no-data`. Output is line 1 only. `net.log` shows `security find-generic-password -s Claude Code-credentials-<hash>` lookups, and no `curl`, because no token was found.
- **Proof.** Cite `usage-seed.json`, `prepaid-seed.json`, `run-1.txt`, `run-1.colors.txt`, and `net.log`.

## Gotchas

- Reset strings are local time. Pass `--tz UTC` before you assert exact clock text.
- Percentages are rounded with `%.0f`. A seed of `34.5` renders as `34%` or `35%` depending on awk's rounding. Seed integers.
- The prepaid `amount` is in cents (`4250` → `42.50`). `JPY` still renders two decimals.
- A 7d `resets_at` in the far future (e.g. 2099) renders a date, not an error. Use `@now+…` for realistic text.
