# Release-body format

The GitHub release body is the trust surface for `/claudefuel.update`. The
`claudefuel` script renders it as-is — no transformation, no diff — for the
target tag and every interstitial tag between installed and target. Users
read it and confirm `[y/N]` before any write.

This is a maintainer contract, enforced by hand at tag time.

## Format

- Three to five bullets. No more, no fewer.
- Each bullet ≤ 80 characters, user-visible language.
- Describe behaviour the user will see, not internal refactors.
- Optional final line: `Breaking: <one-line description>`. Omit when absent.
- No headings, no code blocks, no links. Plain bullets and one optional line.

## Example: typical release

```
- Cap-ETA segment now hides below 5% pct_used to avoid noise at session start
- Drift signal renders on line 1 even when context segment is suppressed
- /claudefuel.doctor reports the active profile path in its summary
- Bak-file pruning keeps the three most recent sets instead of two
```

## Example: release with a breaking change

```
- Reset-time glyph changed from "resets" to the single character ↻
- 7-day column label shortened from "weekly" to "7d" to match API field
- /claudefuel.configure stub now exits cleanly instead of printing TODO
Breaking: ~/.claude/cache/ is now required; old installs must rerun update
```

## Why

The user reads these bullets in their terminal, between drift signal and
write. They are the only audit surface left after ADR-0005 removed the
130-line diff render. Bullets that drift from this format weaken the trust
boundary; treat the contract as load-bearing.
