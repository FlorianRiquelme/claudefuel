---
description: Verify claudefuel install health
---
# claudefuel-skill: v0.4.6

Run a non-destructive health check across the install. Report each item pass/fail without making changes. Use `$CLAUDE_CONFIG_DIR` when set, otherwise `~/.claude`.

Check these in order and report each result on its own line:

1. **`statusline.sh` present and executable.**
   - `[ -x "$target_dir/statusline.sh" ]`
2. **`statusline.sh` has a parseable version header.**
   - `head -20 "$target_dir/statusline.sh" | grep -E '^# claudefuel: v[0-9]+\.[0-9]+\.[0-9]+$'`
3. **`settings.json` is valid JSON with the expected `.statusLine` value.**
   - `jq -e '.statusLine.command == "~/.claude/statusline.sh"' "$target_dir/settings.json"`
4. **All seven command files present, each with a parseable `# claudefuel-skill:` header.**
   - For each of `update`, `doctor`, `rollback`, `uninstall`, `configure`, `why`, `coach`: file exists and `head -20` contains a matching header line.
5. **`jq` and `curl` are on `PATH`.**
6. **Statusline runs without error on a sample input.**
   ```bash
   echo '{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp"},"session_id":"t"}' \
     | "$target_dir/statusline.sh"
   ```
   Expected: exit 0, non-empty output.
7. **Drift cache directory `$target_dir/cache/` exists or can be created.**
8. **Native stdin path renders without network.** Claude Code ≥2.1.x passes `rate_limits` on stdin; when present it — not the OAuth cache — drives the 5h/7d bars.
   ```bash
   printf '{"model":{"display_name":"Claude"},"session_id":"t","rate_limits":{"five_hour":{"used_percentage":62,"resets_at":4070908800},"seven_day":{"used_percentage":31,"resets_at":4070995200}}}' \
     | CLAUDEFUEL_OFFLINE=1 "$target_dir/statusline.sh"
   ```
   Expected: exit 0 and a line 2 containing `62%` and `31%` — proof the bars render from stdin alone, offline, regardless of cache state.
9. **User config parses clean.** `"$target_dir/statusline.sh" --validate-config` — exit 0 with `status: "ok"` (no config file: exit 2 / `"absent"` — that is healthy too, it means pure defaults). Surface any `warnings` from the report verbatim; they name mistyped tokens and out-of-order thresholds with suggestions. Fixes belong to `/claudefuel.configure`, not this skill.

Do **not** modify any files. If something is broken, tell the user which item failed and point them at `/claudefuel.update` (for version drift), `/claudefuel.rollback` (for a recent botched upgrade), or the install paste line (for missing artifacts).

## Timing mode

Run this section only when the user asks about statusline latency (e.g. "doctor timing", "the bar feels slow") or when check 6 felt sluggish. Non-destructive: it only renders against whatever caches already exist.

1. **Warm the cache** with one render (same sample input as check 6, discard output).
2. **Render with stage timings** and capture stderr:
   ```bash
   echo '{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp"},"session_id":"t"}' \
     | CLAUDEFUEL_TIMING=1 "$target_dir/statusline.sh" >/dev/null
   ```
   Expected on stderr: one `claudefuel-timing: <stage> <N>ms` line per stage — `jq-parse`, `drift`, `usage`, `prepaid`, `render`.
3. **Compare against the published budget.** The budget assumes a warm cache (`/tmp/claude/statusline-usage-cache*.json` younger than 60s):

   | Measurement | Budget |
   |---|---|
   | Full cached render (sum of all stages) | < 250 ms |
   | Any single stage | < 100 ms |
   | `usage` / `drift` / `prepaid` stage with a **stale** cache | same budgets — staleness must never add foreground network wait (never-block contract) |

   Each timing mark spawns one `jq` for the clock, so the instrumented total runs a few tens of ms above the uninstrumented render — that overhead is inside the budget, not in addition to it.

4. **Interpret failures.** A `usage`, `prepaid`, or `drift` stage in the hundreds of ms or seconds means a network fetch ran in the foreground. That is expected only on the very first render after install (cold cache, synchronous fetch); on any later render it is a regression — report it and suggest `CLAUDEFUEL_OFFLINE=1` as a stopgap. A slow `jq-parse` or `render` stage points at process-spawn overhead on the machine itself (every render forks dozens of `jq`/`awk`/`date` processes), not at the network.

Every future feature lands inside this budget — treat a budget breach after an upgrade as a reportable regression, not as the new normal.

## Data provenance

When the user asks where a number comes from (or whether the bars are trustworthy), report per-number sources:

| Number | With stdin `rate_limits` (Claude Code ≥2.1.x, subscription auth) | Without (older Claude Code, fallback) |
|---|---|---|
| 5h / 7d bars, line-3 resets, cap-ETA/pace math | stdin — per-render fresh, zero network, agrees with Claude Code's own UI by construction; **never** carries an age marker | OAuth usage cache (`/tmp/claude/statusline-usage-cache*.json`), age markers apply |
| `extra` balance | OAuth prepaid cache — always; own `·age` marker | same |
| fleet view / `⇄` switch hint | sibling profiles' OAuth caches — always; ages shown | same |

Check 8 proves the stdin path; check 6's sample (no `rate_limits`) exercises the fallback. If check 8 shows `62%`/`31%` but the user's live bar carries `·age` markers on the 5h cell, their Claude Code is not sending `rate_limits` (too old, or non-subscription auth) — the bar is on the OAuth fallback and that is expected, not a defect.

## Failure glyphs on the bar

If the bar sent the user here via a `✚ /claudefuel.doctor` trailhead, the glyph in front of it names the failure class:

- `⊘` — credentials missing or expired. The bar is read-only on credentials and never refreshes tokens itself; Claude Code refreshes them on its own schedule, so this usually clears after the next prompt. If it persists, the user should re-authenticate with `/login`.
- `⚠` — usage API unreachable (network down or request failed). Check connectivity; the bar recovers on its own once a fetch succeeds.
- `?` — missing dependency (`jq` or `curl` not on `PATH`). Maps to check 5 above.

While a usable cache exists the bar prefers rendering it with a staleness age marker (e.g. `5h: ●●●●●●○○○○ 62% ·9m` = data is 9 minutes old) over showing a failure glyph — the trailhead only appears when there is no data to show at all.

## Bulb check (demo render)

When the user asks to see the alarm states ("bulb check", "demo the alarms"), exercise every display state — proving the alarms can light without waiting for a real emergency. The script ships this as a first-class flag: each state renders from canned built-in data, deterministic, touching neither the network nor the user's real caches.

```bash
target_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
for state in healthy warning critical stale offline; do
  echo "=== $state ==="
  "$target_dir/statusline.sh" --demo "$state"
  echo
done
```

Walk the user through what lit up, checking each off:

1. **healthy**: green bars, `extra: $25.00`, plain `↻` reset times — no alarms.
2. **warning**: yellow 5h bar (72%), orange 7d bar (55%) — hot colors, no projection alarms.
3. **critical**: red `ctx` bar (95%) on line 1; `▸⚠` prefix with inverse-video burn chip (`~18m ×1.2`) on the 5h cell; `~cap HH:MM-HH:MM · slow ≤N.N× · ⚓` on line 3.
4. **stale**: `·9m` age markers on the 5h and extra cells plus the `⚠ updates ~HH:MM` warning.
5. **offline**: `⚠ ✚ /claudefuel.doctor` trailhead in place of the usage rows.

If any expected element is missing, report which bulb failed to light. The `↗ /claudefuel.update` drift signal is deliberately absent from demo renders (they must be deterministic); its logic is covered by check 2 + the version cache.

If `--demo` errors out (installed script predates it), fall back to rendering with a throwaway profile and seeded caches as older doctors did — or better, run `/claudefuel.update` first.
