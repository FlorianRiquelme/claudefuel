---
name: usage-fetch-throttle
description: TLA+ model of the usage-API fetch gate in statusline.sh — the mkdir lock (claudefuel_try_lock), the 5-minute attempt marker, the 429 retry-after cooldown — checked over every interleaving of concurrent status-bar runs. Use before changing claudefuel_try_lock, the usage cache/attempt/retry-after/lock files, cache_max_age, or the usage fetch block, and to check whether such a change lets sessions call the rate-limited usage API more often.
---

# Usage fetch throttle

Every open Claude Code session runs `statusline.sh` on each status-bar refresh, and all sessions on one account share the files under `/tmp/claude`. The usage endpoint (`GET https://api.anthropic.com/api/oauth/usage`) is rate-limited per account. The script's comments promise that these runs, together, call it at most once per `cache_max_age` (300 s), one at a time, and never during a 429 cooldown.

**Harm when the promise breaks:** extra calls keep an account-wide rate limit alive, so every session shows stale usage numbers (with the stale warning) for as long as the limit is re-armed — the failure the attempt marker and retry-after file were added to stop.

This skill holds a TLA+ model of that gate (`model/UsageFetch.tla`), a one-command checker (`bin/check`), and a replay of each finding against the real script (`bin/replay`). Paths below are relative to this skill's directory, `.claude/skills/usage-fetch-throttle/`.

## Does my change touch the verified code?

Yes, if it changes any of these in `statusline.sh`:

- `claudefuel_try_lock` (the mkdir lock and its 15 s steal rule).
- The usage fetch block, from `cache_file=` through `rm -rf "$usage_lock_dir"`: `now`, the cache/attempt/retry-after checks, `touch "$attempt_file"`, the curl call, the 200 and 429 branches, the lock release.
- `cache_max_age`, or the names of `cache_file`, `attempt_file`, `retryafter_file`, `usage_lock_dir`.

`bin/check` prints a `SYNC` line that tells you: it hashes the text from `claudefuel_try_lock() {` to `# Fall back to stale cache whenever` and compares it with the record at the bottom of this file. `CHANGED` means the model may no longer describe the code. Mirror the change first (see "Update after an intended change"), then trust the results.

Changes elsewhere in `statusline.sh` (rendering, cap-ETA, drift check, the prepaid block) do not affect these results. The prepaid block reuses `claudefuel_try_lock` and writes the same retry-after file, so a change to either one affects both.

## Run

```bash
.claude/skills/usage-fetch-throttle/bin/check           # ~20 s: concurrent + sequential configs
.claude/skills/usage-fetch-throttle/bin/check --deep    # adds the 3-run config, ~3 min in all
.claude/skills/usage-fetch-throttle/bin/check concurrent Throttle   # one rule, full trace
.claude/skills/usage-fetch-throttle/bin/replay all      # replay F1-F3 on the real statusline.sh, ~10 s
```

`bin/check` needs Java 11+ (it looks at `$JAVA`, `java` on `PATH`, then Homebrew's `openjdk`; `brew install openjdk` if none works). It downloads TLC (`tla2tools.jar` v1.7.4, sha256-checked) once into `~/.cache/claudefuel-tla/`, or uses `$TLA2TOOLS`. It runs TLC once per (config, rule), compares each result with `model/expected`, and exits 0 only if every result matches. Every line reads `ok` on the current code, including the known findings. A `FAIL` line means a result changed; it prints the counterexample as one line per step.

`bin/replay` runs the real `statusline.sh` in a fresh `CLAUDE_CONFIG_DIR`, with a bogus token and PATH shims (a fake curl that answers 429 and logs when each request starts and ends, plus mkdir/rm wrappers that pause at the lock dir to force the order the model found). Nothing leaves the machine. It cleans up its own `/tmp/claude` files.

## Rules

| Rule | In plain words | Harm if broken |
|---|---|---|
| `Mutex` | At most one run is between taking the lock and removing it. | Two requests in flight at once. |
| `Throttle` | Two usage requests come from fetch rounds at least `cache_max_age` apart. | More than one call per 5 minutes per account. |
| `HonorsCooldown` | No usage request is sent while the server's 429 cooldown (counted from its answer) is running. | Each early call can re-arm the rate limit. |
| `LateThrottle` | A run that starts after another run touched the attempt marker does not start its own round within `cache_max_age` of it. | The 5-minute backoff stops working, even without races. |
| `LateCooldown` | A run that starts after a 429 deadline was written does not send before that deadline. | The cooldown stops working, even without races. |

The first three are the full promise; today they break (see Findings). The last two are its steady-state half, and they hold. They are what catch a regression such as deleting `touch "$attempt_file"` or the retry-after check.

## Configurations and bounds

All three use `MaxAge = 3` (stands for `cache_max_age=300`), `MaxHold = 1` (the `15` passed to `claudefuel_try_lock`), `RetrySecs = 4` (a Retry-After longer than `cache_max_age`), and `CanKill = TRUE`. Only the order `MaxHold < MaxAge < RetrySecs` matters to the races. The clock starts with no files present.

| Config | Runs | Overlap | Clock bound | Distinct states | Checks |
|---|---|---|---|---|---|
| `concurrent` | 2 | yes | 8 s | ~1.06 M | all 5 rules |
| `sequential` | 2 | one run at a time | 8 s | ~72 K | `Throttle`, `HonorsCooldown`, `LateThrottle`, `LateCooldown` |
| `deep` (`--deep`) | 3 | yes | 6 s | ~17 M | `LateThrottle`, `LateCooldown` |

`sequential` exists to separate the race findings from the single-run finding F3: with no overlap, only F3 remains.

## How the model maps to the code

Each run is one execution of `statusline.sh`. Each action is one file operation or network event, so another run can act between any two of them.

| Action | Code (`statusline.sh`) |
|---|---|
| `Start` | `now=$(date +%s)`, captured once and reused for every age check and for the 429 deadline |
| `ReadCache` | `if [ -f "$cache_file" ]` … `[ "$cache_age" -lt "$cache_max_age" ]` → `needs_refresh=false` |
| `ReadAttempt` | `if [ -f "$attempt_file" ]` … `[ "$attempt_age" -lt "$cache_max_age" ]` → `should_attempt=false` |
| `ReadRetry` | `if [ -f "$retryafter_file" ]` … `[ "$now" -lt "$retry_deadline" ]`, then `$needs_refresh && $should_attempt && claudefuel_try_lock` |
| `Mkdir1` | `claudefuel_try_lock`: `mkdir "$dir"` |
| `StatLock` | `m=$(stat … "$dir")`; `[ $(( lock_now - m )) -gt "$max_hold" ]` (uses the run's `now`) |
| `RmLock`, `Mkdir2` | steal: `rm -rf "$dir"`, then `mkdir "$dir"` |
| `Touch` | `touch "$attempt_file"` |
| `Send` | `token=$(get_oauth_token)` and the `curl … /api/oauth/usage` request. Time may pass before it (token lookup). |
| `RecvOk` | 200 with `five_hour`/`seven_day`: write `$cache_file`, `rm -f "$retryafter_file"` |
| `Recv429` | `echo $(( now + retry_secs )) > "$retryafter_file"` |
| `RecvError` | timeout, other status, or bad body: nothing written |
| `Release` | `rm -rf "$usage_lock_dir"` — removes whatever lock dir is there, owned or not |
| `Kill` | the run dies between any two steps; no trap removes the lock |
| `Tick` | one second of wall clock |

Ghost variables (`serverDl`, `roundAt`, `sent`, `inCooldown`, `lastRound`, `lastDl`, `beforeDl`, `maxDl`) record what the server sees so the rules can be stated. They do not exist in the script.

## Findings (open on the code at the sync commit)

None of these is fixed. Each was replayed on the real script with `bin/replay`. The shims force the timing, so a replay proves the order is possible, not how often it happens. In normal use each needs two renders on one account to line up within a short window, so expect them rarely; each costs one extra API call, at the moment the account can least afford one.

**F1 — checks happen before the lock and are not repeated after it.** Breaks `Throttle` and `HonorsCooldown` (`concurrent`).
1. Runs A and B render together. Both read the cache (stale), the attempt marker (old), and the retry-after file (none), so both decide to fetch.
2. A wins `mkdir`, touches the attempt marker, calls the API, gets a 429 (or a 200), writes the retry-after file (or the cache), and removes the lock.
3. B now runs `mkdir`, which succeeds because the lock is gone. B does not look at the files again: it calls the API a second time, inside the cooldown A just recorded.

**F2 — the lock steal and the release remove another run's lock.** Breaks `Mutex` (`concurrent`; `bin/replay F2` shows the 3-run form).
1. A run was killed while holding the lock, so the lock dir stays, and the attempt marker it touched is now over 300 s old.
2. Runs B and C render together. Both fail `mkdir`, and both see a lock older than 15 s.
3. B runs `rm -rf`, then `mkdir`, and holds the lock. C runs `rm -rf` (removing B's lock), then `mkdir`, and holds it too. Both call the API at once.
In the 2-run form TLC prints, the first holder is frozen (for example by system sleep) for more than 15 s between `mkdir` and `touch`, and a second run steals its live lock. `Release` has the same flaw: a run that finishes removes whichever lock is there.

**F3 — the 429 deadline counts from when the run started, not from when the server answered.** Breaks `HonorsCooldown` even with one run at a time (`sequential`).
1. A run starts (`now` is set), resolves a token, and calls the API. The 429 arrives T seconds later with `retry-after: R`.
2. The script writes `now + R`. The server's cooldown ends at `now + T + R`.
3. The first render after `now + R` calls the API up to T seconds early. T includes the token lookup (a refresh is a second `--max-time 5` curl) and the usage curl itself (`--max-time 5`).

**F4 — a later 429 can move the deadline earlier.** Breaks `LateCooldown` with 3 runs (`deep` only); needs F1 and F3 together.
1. Runs A (started first) and B both pass the checks as in F1. B fetches, gets a 429, writes `B.now + R`.
2. A fetches inside that cooldown, gets a 429, and overwrites the file with `A.now + R`, which is earlier because A started earlier.
3. A run that starts after B's 429 reads the earlier deadline and calls before the one B wrote.

## Reading a result

- Read every TLC result with the pstack `/statechart` skill. Give it `model/UsageFetch.tla`, the config you ran (`model/concurrent.cfg`, etc.), and `model/view.ts` as its view module. It reports each broken rule's shortest path in plain words ("r2 mkdir on the lock dir", "r1 the API answers 429"), and when a rule holds, a chart of how the runs move between states. The full state space is above its chart budget, so for a whole-graph chart shrink `MaxTime` in a scratch copy of the config.
- For a quick look, `bin/check CONFIG RULE` prints the trace one step per line with only the variables that changed.

**Real bug or modeling error?** Replay the path on the real script, one model step per script step. `bin/replay` shows the pattern: put a pause where the trace lets another run act (the mkdir/rm shims), and log requests in the fake curl. If the real script does not do what the trace says, the model is wrong. Typical modeling errors are an action that merges steps the script does separately (or splits one it does atomically), a guard that does not match the code's comparison (`-lt` vs `-le`, the run's `now` vs the current time), or a rule stated on a ghost the code cannot see. Fix the model and say so. Do not weaken a rule until it passes.

## Update after an intended change

1. Read `git diff <sync-commit> -- statusline.sh` (sync commit below).
2. Mirror each change in `model/UsageFetch.tla` at the action from the map above: a new check, a moved `touch`, a re-check after the lock, a new file. Keep one action per file operation.
3. Run `bin/check` (and `--deep` if the change touches the retry-after file or the steal path). For each line that flips, decide: a regression (fix the code), a fixed finding (change the line in `model/expected` to `holds` and move the finding out of "Findings" here), or a new finding (record it with its path in the code's words).
4. Replay any new finding with a new `bin/replay` case.
5. Only after you confirm that the model describes the code at the new commit, update the record below: set `sync-commit` to that commit and `covered-sha256` to the value `bin/check` prints in its `SYNC CHANGED` line.

## What this does not cover

- The prepaid fetch block (`prepaid_lock_dir`, `prepaid_attempt_file`). It has the same check-before-lock shape as F1 and shares `claudefuel_try_lock` (F2) and the retry-after file (F3, F4), but it is not modeled.
- Claude Code's own polling of the same endpoint, and the server's real rate-limit algorithm. The model only assumes that the server answers 200 outside its cooldown and 429 or an error at any time.
- Token lookup and refresh (`get_oauth_token`, `refresh_oauth_token`). The model treats it as time passing before `Send`; it does not model concurrent refreshes of the credential store.
- More than 3 concurrent runs, a clock past the bounds above, and a run that renders more than once (each run is one execution).
- Filesystem assumptions: `mkdir` is atomic, `stat` mtimes have 1 s resolution, and all runs read one clock.

## Coverage record

Covered: `statusline.sh` from `claudefuel_try_lock() {` to `# Fall back to stale cache whenever` (lines 402–513 at the sync commit): `claudefuel_try_lock`, and the usage fetch block. `bin/check` reads the two lines below; keep their format.

sync-commit: ef183d8
covered-sha256: f69931bbd533b8f3b56bd5e43313097173593286825f7fb5b2187d8f834f8a39
