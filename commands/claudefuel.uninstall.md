---
description: Remove claudefuel from this Claude Code install
---
# claudefuel-skill: v0.4.4

Remove every install-managed claudefuel artifact and restore the user's `settings.json` to a state where `.statusLine` no longer references this script. Use `$CLAUDE_CONFIG_DIR` when set, otherwise `~/.claude`.

## Step 1 — Confirm scope

Tell the user exactly what will be removed and ask for confirmation. The default scope is the install bundle only:

- `$target_dir/statusline.sh`
- The five `$target_dir/commands/claudefuel.<name>.md` files (`<name>` ∈ `update doctor rollback uninstall configure`)
- The `.statusLine` key in `$target_dir/settings.json` (the rest of the file is preserved)
- `$target_dir/cache/claudefuel-version.json`

Ask separately whether to also delete:

- Any `*.bak-<timestamp>` backups in `$target_dir/`
- The user's `$target_dir/claudefuel.json` (user-owned config — default to keeping)

Do **not** proceed without explicit confirmation.

## Step 2 — Patch settings.json

```bash
target_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
cp "$target_dir/settings.json" "$target_dir/settings.json.bak-$(date -u +%Y%m%d%H%M%S)"
jq 'del(.statusLine)' "$target_dir/settings.json" > "$target_dir/settings.json.tmp" \
  && mv "$target_dir/settings.json.tmp" "$target_dir/settings.json"
```

Postcondition: `jq -e 'has("statusLine") | not' "$target_dir/settings.json"` exits 0.

## Step 3 — Remove install artifacts

```bash
rm -f "$target_dir/statusline.sh"
for name in update doctor rollback uninstall configure; do
  rm -f "$target_dir/commands/claudefuel.${name}.md"
done
rm -f "$target_dir/cache/claudefuel-version.json"
rmdir "$target_dir/cache" 2>/dev/null  # only succeeds if empty
```

Do not remove `$target_dir/commands/` itself — other tools share it. `rmdir` without `-p` and ignoring failure removes `cache/` only when it has no other files.

## Step 4 — Optional cleanup

If the user confirmed backup cleanup, remove `$target_dir/*.bak-*` matching the install bundle (`statusline.sh.bak-*`, `settings.json.bak-*`, and `commands/claudefuel.*.md.bak-*`).

If the user confirmed config cleanup, remove `$target_dir/claudefuel.json`.

## Step 5 — Verify

- `[ ! -e "$target_dir/statusline.sh" ]`
- `jq -e 'has("statusLine") | not' "$target_dir/settings.json"` exits 0
- None of the five `claudefuel.*.md` files remain in `$target_dir/commands/`

Tell the user to start a new Claude Code session for the bar to disappear from view.
