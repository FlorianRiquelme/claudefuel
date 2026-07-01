---
description: Verify claudefuel install health
---
# claudefuel-skill: v0.4.1

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
