# Stale data and backoff

When usage fetches keep failing, the bar keeps showing the last known numbers and adds a red `⚠ updates ~<time>` so the user doesn't mistake old data for current. Retries are rate-gated, and a 429's `retry-after` is honored, so a failing fetch can't sustain a rate limit.

## Sub-features

- `stale-fallback` keeps showing the bars from a stale cache after a failed fetch.
- `stale-warning-429` shows `⚠ updates ~<retry deadline>` on line 2 after a 429 with `retry-after`, once data is at least 900 s old.
- `stale-warning-cadence` shows `⚠ updates ~<last attempt + 300s>` when there is no cooldown. It shows `⚠ updates soon` when that time has passed.
- `backoff-attempt-gate` makes no new fetch within 300 s of the last attempt, success or not.
- `backoff-retry-after` makes no fetch before a recorded 429 deadline.
- `fetch-success` writes a 200 response to the cache, renders it, and clears any cooldown.

## How to get to it (user POV)

- Happens on its own when the account is rate-limited or offline. Line 2 gains a red `⚠ updates ~9:21pm`.

## Driving it with cf-render

Preconditions:

- `cf-doctor` exits 0.
- These journeys use `--api`, which fakes only the HTTP endpoint and supplies a dummy token.

- **429 then quiet.** Stale cache (1000 s old). The API answers 429 with a 2400 s `retry-after`. Two refreshes. Run `R --label stale-warning-429 --tz UTC --usage @.claude/skills/verify/fixtures/usage-healthy.json --usage-age 1000 --api 429:2400 --repeat 2`. Both renders still show `5h: … 35%` and `7d: … 62%`, plus `⚠ updates ~<now+40m>`. `net.log` has exactly one line, `run=1 curl https://api.anthropic.com/api/oauth/usage`, so render 2 made no fetch. `state-after/index.txt` lists `statusline-usage-retryafter-<hash>`, whose copy holds epoch now+2400. The usage cache age is still about 1000 s.
- **Attempt gate without 429.** Run `R --label backoff-attempt-gate --usage @.claude/skills/verify/fixtures/usage-healthy.json --usage-age 1000 --attempt-age 60 --api 200 --api-body @.claude/skills/verify/fixtures/usage-api-ok.json`. `net.log` is empty: the last attempt was only 60 s ago. Line 2 shows the stale 35%/62% with `⚠ updates ~<now+240s>`.
- **Cooldown honored.** Run `R --label backoff-retry-after --usage @.claude/skills/verify/fixtures/usage-healthy.json --usage-age 1000 --retry-after-in 600 --api 200 --api-body @.claude/skills/verify/fixtures/usage-api-ok.json`. `net.log` is empty. The warning shows `~<now+10m>`.
- **Recovery.** Run `R --label fetch-success --usage @.claude/skills/verify/fixtures/usage-healthy.json --usage-age 1000 --retry-after-in -1 --api 200 --api-body @.claude/skills/verify/fixtures/usage-api-ok.json`. `net.log` has one usage `curl`. Line 2 shows `22%` and `48%` with no `⚠`. `state-after/statusline-usage-cache.json` equals `usage-api-ok.json`, and there is no `retryafter` file in `state-after/`.
- **Proof.** Cite `net.log`, `state-after/index.txt` (with ages), and line 2 of each `run-N.txt`.

## Gotchas

- With no token (default fenced mode), no `curl` happens at all. That proves token-lookup failure, not backoff. Backoff journeys need `--api`.
- The warning appears only once data is ≥900 s old. A 400 s-old cache with a 429 shows no `⚠`, which is correct behavior and not a failure.
- `--retry-after-in -1` records a past deadline to exercise its clearing. Omitting it proves less.
