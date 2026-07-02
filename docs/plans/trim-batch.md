# Status bar trim batch (WIP)

Multi-task batch of trims and simplifications to the status bar. Built up
across sessions: each session grills one task to a locked spec and appends
it here. A final session executes the whole batch as one diff.

## How to use this file (for the next session)

1. Read the locked tasks below — they're settled, do not re-grill.
2. Read **Batch-wide deferrals** so you don't re-debate them.
3. Grill the user on the next candidate trim (`/grill-with-docs`).
4. When a task locks, append it as `## Task N — <title>` with the same
   shape as Task 1 (Decision / In scope / Out of scope / Change set).
5. Do **not** execute until the user says the batch is closed.

## Batch-wide deferrals (apply to every task)

- **Demo gifs** (`docs/assets/multi-account.gif`, `usage-progression.gif`):
  regenerate once at the end, not per task.
- **Version bump** (`statusline.sh:2` header `# claudefuel: vX.Y.Z`):
  release-prep concern, lives in a separate commit, not in any task here.
- **ADRs**: only add one if the change is hard to reverse, surprising
  without context, and the result of a real trade-off. Most trims are
  none of those — skip the ADR by default.

---

## Task 1 — trim `% used` / `% remain` segments from line 1

**Decision**: drop both segments entirely. The abbreviated `used / total`
segment (e.g. `0 / 1.0m`) already answers "where am I in the window" at a
glance; the percentage and comma-formatted exact count are redundant
duplication on the same line, and `claude /status` covers the rare need
for token-precise readouts.

### In scope

- `statusline.sh:5` — header layout comment: drop
  `| % used <fullused> | % remain <fullremain>` from the Line 1 summary.
- `statusline.sh:53-55` — delete `format_commas` helper (orphan after the
  segments are removed).
- `statusline.sh:104` — delete `pct_remain=...` assignment (orphan).
- `statusline.sh:106-107` — delete `used_comma` and `remain_comma`
  assignments (orphan).
- `statusline.sh:118` — section comment: drop `% used | % remain` from
  the Line 1 layout summary.
- `statusline.sh:130-133` — delete the four `line1+=...` lines rendering
  the two doomed segments, including their two pipe separators.
- `pct_used` **stays** — still used by the cap-ETA noise-floor gate
  (`statusline.sh:518`, see ADR-0004).
- `README.md:27` — prose: drop `· % used bar · % remaining bar` so the
  line reads `model · tokens used / total · thinking on/off · effort
  level …`. (Side note: those were never bars, just text — the doc was
  already slightly wrong; the trim corrects it.)

### Out of scope (already deferred by batch rule)

- Regenerating the README gifs — covered in **Batch-wide deferrals**.
- Bumping the `# claudefuel:` version header — covered in **Batch-wide
  deferrals**.
- ADR or CONTEXT.md changes — none warranted; the dropped segments had
  no domain name to retire and the change is trivially reversible.

### Tests

No bats test asserts on the doomed segments. Only `tests/cap-eta.bats`
references `pct_used`, and that's inside the unchanged cap-ETA function.
Existing test suite covers the change with no edits needed.

---

## Task 2 — TBD

Next session: grill the user on the next trim candidate. Use the same
shape as Task 1 when locking.

## Task 3 — TBD
