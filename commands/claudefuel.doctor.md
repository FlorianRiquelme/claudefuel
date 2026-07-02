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

## Failure glyphs on the bar

If the bar sent the user here via a `✚ /claudefuel.doctor` trailhead, the glyph in front of it names the failure class:

- `⊘` — credentials missing or expired. The bar is read-only on credentials and never refreshes tokens itself; Claude Code refreshes them on its own schedule, so this usually clears after the next prompt. If it persists, the user should re-authenticate with `/login`.
- `⚠` — usage API unreachable (network down or request failed). Check connectivity; the bar recovers on its own once a fetch succeeds.
- `?` — missing dependency (`jq` or `curl` not on `PATH`). Maps to check 5 above.

While a usable cache exists the bar prefers rendering it with a staleness age marker (e.g. `5h: ●●●●●●○○○○ 62% ·9m` = data is 9 minutes old) over showing a failure glyph — the trailhead only appears when there is no data to show at all.

## Bulb check (demo render)

When the user asks to see the alarm states ("bulb check", "demo the alarms"), exercise every display state from a canned snapshot — proving the alarms can light without waiting for a real emergency. This is non-destructive: it uses a throwaway profile directory and its own cache files.

```bash
target_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
demo_dir=$(mktemp -d)
mkdir -p "$demo_dir/cache" /tmp/claude
demo_hash=$(printf '%s' "$demo_dir" | shasum -a 256 | cut -c1-8)
usage_cache="/tmp/claude/statusline-usage-cache-${demo_hash}.json"
prepaid_cache="/tmp/claude/statusline-prepaid-cache-${demo_hash}.json"
iso() { date -u -r "$1" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "@$1" +"%Y-%m-%dT%H:%M:%SZ"; }
now=$(date +%s)

# Drift signal: cached upstream deliberately differs from installed.
printf '{"upstream_version":"99.99.99"}\n' > "$demo_dir/cache/claudefuel-version.json"

# Alarm snapshot: 5h 85% (yellow) burning hot 4h into the window with 1h
# to reset (cap-ETA fires), 7d 55% (orange), prepaid balance present.
printf '{"five_hour":{"utilization":85,"resets_at":"%s"},"seven_day":{"utilization":55,"resets_at":"%s"},"extra_usage":{"is_enabled":true}}\n' \
  "$(iso $((now + 3600)))" "$(iso $((now + 432000)))" > "$usage_cache"
printf '{"amount":2500,"currency":"USD"}\n' > "$prepaid_cache"

# Backdate the usage cache 9 minutes — the temp profile has no
# credentials, so the bar falls back to it and shows the ·9m age marker.
ts=$(date -v-9M +%Y%m%d%H%M.%S 2>/dev/null || date -d '9 minutes ago' +%Y%m%d%H%M.%S)
touch -t "$ts" "$usage_cache"

echo "=== 1. alarm states ==="
printf '{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp"},"session_id":"bulb","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":190000}}}' \
  | CLAUDE_CONFIG_DIR="$demo_dir" CLAUDEFUEL_OFFLINE=1 CLAUDE_CODE_OAUTH_TOKEN= "$target_dir/statusline.sh"
echo

echo "=== 2. nominal (all green) ==="
printf '{"five_hour":{"utilization":5,"resets_at":"%s"},"seven_day":{"utilization":12,"resets_at":"%s"},"extra_usage":{"is_enabled":false}}\n' \
  "$(iso $((now + 14400)))" "$(iso $((now + 432000)))" > "$usage_cache"
printf '{"upstream_version":"%s"}\n' "$(head -20 "$target_dir/statusline.sh" | grep -E '^# claudefuel:' | sed -E 's/^# claudefuel: v//')" \
  > "$demo_dir/cache/claudefuel-version.json"
printf '{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp"},"session_id":"bulb","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":40000}}}' \
  | CLAUDE_CONFIG_DIR="$demo_dir" CLAUDEFUEL_OFFLINE=1 CLAUDE_CODE_OAUTH_TOKEN= "$target_dir/statusline.sh"
echo

echo "=== 3. failure trailhead (no data, no credentials) ==="
rm -f "$usage_cache" "$prepaid_cache"
printf '{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp"},"session_id":"bulb"}' \
  | CLAUDE_CONFIG_DIR="$demo_dir" CLAUDE_CODE_OAUTH_TOKEN= "$target_dir/statusline.sh"
echo

rm -rf "$demo_dir" /tmp/claude/statusline-usage-cache-"${demo_hash}".json \
  /tmp/claude/statusline-prepaid-cache-"${demo_hash}".json \
  /tmp/claude/statusline-orguuid-cache-"${demo_hash}"
```

Walk the user through what lit up, checking each off:

1. **Alarm render**: red `ctx` bar (95%), `↗ /claudefuel.update` drift signal on line 1; yellow 5h bar (85%) with the `·9m` staleness age marker, orange 7d bar (55%), `extra: $25.00` on line 2; `↻` reset times plus a `~cap HH:MM-HH:MM` range in the 5h cell on line 3.
2. **Nominal render**: green bars all around, no drift signal, no cap-ETA, no markers.
3. **Failure render**: `⊘ ✚ /claudefuel.doctor` trailhead in place of the usage rows.

If any expected element is missing, report which bulb failed to light.
