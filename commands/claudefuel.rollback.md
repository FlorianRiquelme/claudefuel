---
description: Restore the most recent claudefuel backup
---
# claudefuel-skill: v0.3.0

Restore the most recent `*.bak-<UTC-timestamp>` of each install-managed artifact, in atomic-bundle order. Use `$CLAUDE_CONFIG_DIR` when set, otherwise `~/.claude`.

## Step 1 — Identify the latest backup timestamp

List backups for the canonical artifact (`statusline.sh.bak-*`), parse the suffix, pick the lexicographically greatest (timestamp format `YYYYMMDDHHMMSS` sorts as it dates).

```bash
target_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
latest=$(ls -1 "$target_dir"/statusline.sh.bak-* 2>/dev/null \
  | sed -E 's/.*\.bak-//' \
  | sort -r | head -n1)
```

If `$latest` is empty, report "no backups found — nothing to roll back" and stop.

## Step 2 — Show the user what will be restored

Walk every bundle artifact and list any `*.bak-${latest}` that exists. The bundle covers `statusline.sh`, `settings.json`, and the five `commands/claudefuel.*.md` files:

```bash
artifacts=(
  "$target_dir/statusline.sh"
  "$target_dir/settings.json"
)
for name in update doctor rollback uninstall configure; do
  artifacts+=("$target_dir/commands/claudefuel.${name}.md")
done

for f in "${artifacts[@]}"; do
  [ -f "${f}.bak-${latest}" ] && diff -u "$f" "${f}.bak-${latest}" 2>/dev/null
done
```

Ask for explicit confirmation before proceeding.

## Step 3 — Restore atomically, in reverse install order

Restore by moving each `*.bak-${latest}` over its live counterpart. If a backup is missing for a given artifact, leave the live file alone — do not delete an artifact just because its backup is absent.

The user's `~/.claude/claudefuel.json` is never touched by rollback — it is user-owned and not part of the install bundle.

## Step 4 — Verify

After restoring, invoke the verification block from `/claudefuel.doctor`'s checklist. Report each item.

## Notes

- Backups from previous install runs (older timestamps) are left in place. The user can delete them manually or via `/claudefuel.uninstall`.
- Rollback does not undo a manual file edit — only a botched reconcile. Manual customization should be tracked outside this tool.
