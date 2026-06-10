---
description: Verify claudefuel install health
---
# claudefuel-skill: v0.4.0

Run a non-destructive health check across the install. Report each item pass/fail without making changes. Use `$CLAUDE_CONFIG_DIR` when set, otherwise `~/.claude`.

Check these in order and report each result on its own line:

1. **`statusline.sh` present and executable.**
   - `[ -x "$target_dir/statusline.sh" ]`
2. **`statusline.sh` has a parseable version header.**
   - `head -20 "$target_dir/statusline.sh" | grep -E '^# claudefuel: v[0-9]+\.[0-9]+\.[0-9]+$'`
3. **`settings.json` is valid JSON with the expected `.statusLine` value.**
   - `jq -e '.statusLine.command == "~/.claude/statusline.sh"' "$target_dir/settings.json"`
4. **All five command files present, each with a parseable `# claudefuel-skill:` header.**
   - For each of `update`, `doctor`, `rollback`, `uninstall`, `configure`: file exists and `head -20` contains a matching header line.
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
