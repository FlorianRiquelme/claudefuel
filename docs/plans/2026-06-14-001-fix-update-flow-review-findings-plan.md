# fix: Address code-review findings for the ADR-0005 update flow

Created: 2026-06-14
Type: fix
Drives: [[0005-update-flow-script-led]]
Companion to: `docs/plans/update-redesign-implementation.md` (the phased redesign plan; this plan remediates review findings against its Phase 2–4 output)

---

## Summary

A code review of the uncommitted ADR-0005 work (the new `claudefuel` script plus its skill/INSTALL/test changes) surfaced two correctness gaps the redesign plan missed and a cluster of robustness, fidelity, and coverage issues. This plan closes them. It does **not** touch the version/release reconciliation — that is release-prep work owned by Phase 5 of the companion plan — and it does not re-open the security-signing question (ADR-0005 already defers Sigstore).

The work is six bounded units: two skill-file corrections (`rollback.md`, `uninstall.md`), two `claudefuel` script hardening units (network/filesystem robustness; diagnostic + tag correctness), one UX fix (human-readable doctor output), and one test-coverage unit for the apply path and its load-bearing invariants.

---

## Problem Frame

The companion plan shipped the `claudefuel` binary as a new bundle artifact and updated `INSTALL.md` to install/uninstall it. But the **skill files** that act on the bundle were not all updated to match, and the script carries several rough edges that only surface on failure or in non-default environments:

- `/claudefuel.rollback` restores every bundle artifact **except** the new `claudefuel` binary, even though `claudefuel update` backs it up as `claudefuel.bak-<TS>`. A rollback leaves a half-reverted, version-mixed bundle.
- `/claudefuel.uninstall` removes the old artifacts but leaves the `claudefuel` binary and `claudefuel-update-diagnostic.json` on disk — inconsistent with the INSTALL.md uninstall section that *was* updated.
- All `curl` calls lack timeouts, so a stalled network hangs the update indefinitely (`set -euo pipefail` does not catch hangs).
- The failure diagnostic embeds the literal string `"<latest>"` instead of the resolved tag, and hardcodes the bundle file list independently of the `SKILLS` array — both weaken the LLM-driven recovery the diagnostic exists to enable.
- `/claudefuel.doctor` now emits raw `inspect` JSON to the user instead of a health summary.
- The new tests assert exit codes and bak counts on a successful apply but never assert that the new file **content** landed or that unrelated `settings.json` keys survived — the "single most important invariant" per INSTALL.md.

These are all reachable in the current uncommitted tree (verified during review: 50/50 tests pass, binary runs clean, `shellcheck` clean).

---

## Requirements

Each finding (F-ID) traces to the units that resolve it.

- **F1** — `/claudefuel.rollback` restores the `claudefuel` binary alongside the rest of the bundle. → U1
- **F2** — `/claudefuel.uninstall` removes the `claudefuel` binary and `cache/claudefuel-update-diagnostic.json`, and matches the INSTALL.md uninstall section. → U2
- **F3** — Every `curl` invocation has connect + total timeouts and is protocol-pinned to HTTPS. → U3
- **F4** — The script fails fast with a clear message when `jq` or `curl` is absent, so the diagnostic dump itself never silently fails. → U3
- **F5** — Bundle-file replacement is atomic on all filesystems (no cross-device `mv`); the "atomic" claim is honored or removed. → U3
- **F6** — The failure diagnostic records the resolved target tag, not `"<latest>"`. → U4
- **F7** — The diagnostic's `bundle_files` list is derived from the `SKILLS` array, not hardcoded. → U4
- **F8** — All release tags reaching a URL (interstitial + release-body) pass `validate_tag`, not just `$latest`. → U4
- **F9** — `/claudefuel.doctor` presents a human-readable pass/fail health report; machine/diagnostic callers keep structured state. → U5
- **F10** — Tests assert post-apply file content, executability, and `settings.json` key preservation; the header-verification-failure and repair-apply paths are covered. → U6

---

## Key Technical Decisions

**KTD1 — Doctor renders human-readable; `inspect_state` stays JSON.**
`cmd_inspect` (the `claudefuel inspect` entry point) will render a pass/fail report for humans. The internal `inspect_state` subroutine keeps returning JSON unchanged, because `dump_diagnostic` and the update prelude depend on its structured output. `doctor.md` then renders the human report verbatim. A `--json` flag on `inspect` preserves a machine path if one is ever needed.
*Rationale:* the redesign plan (Phase 3.2) said "render output verbatim," which the review flagged as a UX regression. Fixing it in the script keeps the skill thin (the redesign's intent) rather than pushing JSON-formatting logic into LLM prose.
*Alternative considered:* have `doctor.md` parse and format the JSON. Rejected — puts formatting burden on the LLM every invocation and makes output non-deterministic.

**KTD2 — `mktemp` in the destination directory, not `$TMPDIR`.**
`fetch_and_install` and the `settings.json` patch will create their temp file under `$(dirname "$dest")` so the final `mv` is always a same-filesystem rename (truly atomic). This restores the guarantee the inline comment already claims.
*Rationale:* on macOS default `/tmp` shares the volume with `$HOME`, but `TMPDIR` is user-overridable and `/tmp` is tmpfs on many Linux setups, making the `mv` a non-atomic copy+unlink.

**KTD3 — Single source of truth for the bundle file set.**
`dump_diagnostic` will build its `bundle_files` array at runtime from `${SKILLS[@]}` plus the fixed members (`statusline.sh`, `claudefuel`), rather than a hardcoded literal. Adding a skill then updates the diagnostic automatically.

**KTD4 — Hardening only; no behavioral redesign.**
Each change preserves the existing observable contract (output shapes, exit codes, the no-auto-revert failure model from ADR-0005). This plan does not introduce a `--yes` flag, precondition relocation, or signing — those stay deferred (see Scope Boundaries).

---

## Implementation Units

### U1. Restore the `claudefuel` binary in rollback

**Goal:** `/claudefuel.rollback` includes the local `claudefuel` binary in the artifact set it restores, so a rollback fully reverts a botched `claudefuel update`.
**Requirements:** F1
**Dependencies:** none
**Files:** `commands/claudefuel.rollback.md`
**Approach:** Add `"$target_dir/claudefuel"` to the `artifacts` array (Step 2) and to the prose listing the bundle ("covers `statusline.sh`, `settings.json`, the local `claudefuel` binary, and the five `commands/claudefuel.*.md` files"). The existing restore loop (`*.bak-${latest}` over each artifact, skip when no bak exists) then handles it with no further change. Do **not** bump the `# claudefuel-skill:` header — version bumps are release-prep (companion plan Phase 5).
**Patterns to follow:** mirror the existing `artifacts=(...)` construction and the "leave the live file alone if a backup is missing" rule already in Step 3.
**Test scenarios:** Test expectation: none — `rollback.md` is LLM-executed prose, not code. Verification is the real-machine rollback exercise already scheduled in companion plan Phase 6.3; this unit makes that exercise pass for the binary.
**Verification:** The artifacts list and prose both name the `claudefuel` binary; a manual rollback after an `update` restores the prior `claudefuel` and leaves no orphaned `claudefuel.bak-<TS>`.

### U2. Remove the binary and diagnostic in uninstall

**Goal:** `/claudefuel.uninstall` removes the `claudefuel` binary and the diagnostic file, matching the (already-updated) INSTALL.md uninstall section.
**Requirements:** F2
**Dependencies:** none
**Files:** `commands/claudefuel.uninstall.md`
**Approach:** Add `$target_dir/claudefuel` to the scope list and the `rm -f` block; add `cache/claudefuel-update-diagnostic.json` alongside the existing `cache/claudefuel-version.json` removal; extend the optional bak-cleanup pattern to include `claudefuel.bak-*`. Keep `claudefuel.json` (user-owned) untouched. Do **not** bump the header.
**Patterns to follow:** the existing `rm -f "$target_dir/commands/claudefuel.${name}.md"` loop and the bak-cleanup glob list; cross-check against INSTALL.md's uninstall steps (which already list both files) so the two stay consistent.
**Test scenarios:** Test expectation: none — LLM-executed prose. Consistency is the acceptance signal (see Verification).
**Verification:** A diff of `uninstall.md`'s removal set against INSTALL.md's uninstall section shows parity (binary + both cache files); no live executable or diagnostic remains after a described uninstall.

### U3. Network and filesystem robustness in `claudefuel`

**Goal:** The script fails fast and predictably on missing dependencies and stalled networks, and its file replacement is genuinely atomic.
**Requirements:** F3, F4, F5
**Dependencies:** none
**Files:** `claudefuel`, `tests/claudefuel-script.bats`
**Approach:**
- **Preflight (F4):** at the top of `main` (before dispatch), verify `jq` and `curl` are on `PATH`; if either is missing, `log_err` a clear one-line message and exit non-zero *before* any network or JSON work. This guards `dump_diagnostic` itself, which needs `jq` to write the diagnostic.
- **Timeouts + protocol pin (F3):** add `--max-time 30 --connect-timeout 10 --proto '=https' --proto-redir '=https' --max-redirs 5` to every `curl` call (`fetch_latest_tag`, `fetch_release_body`, `fetch_interstitial_tags`, `fetch_and_install`). Consider a shared `CURL_OPTS` array to avoid drift.
- **Atomic replace (F5):** in `fetch_and_install` and the `settings.json` patch, create the temp file under `$(dirname "$dest")` (e.g. `mktemp "$(dirname "$dest")/.claudefuel.XXXXXX"`) so `mv` is a same-filesystem rename. Keep the existing cleanup-on-failure (`rm -f "$tmp"`).
**Patterns to follow:** the existing `fetch_and_install` mktemp→verify→mv structure; `log_err` for stderr messages; the `API_BASE`/`RAW_BASE` override seam for testability.
**Test scenarios:**
- Happy path: with `jq`/`curl` present, `inspect` and a mocked `update` behave exactly as today (regression guard — existing suite must stay green).
- Error path (F4): stub `jq` as absent on `PATH`; run `claudefuel inspect` (or `update`); assert non-zero exit and a message naming the missing dependency, and that the script did not proceed to network calls.
- Edge case (F5): set `TMPDIR` to a directory and assert a mocked successful `update` still replaces files and emits `Done.` (documents same-fs behavior; serves as a regression guard for the mktemp location).
- `Test expectation:` curl timeout flags are not directly unit-testable with the mock; assert via `grep` that each `curl` line carries `--max-time`, or note as an accepted coverage gap in the test comment.
**Verification:** Existing 50 tests stay green; new dependency-preflight test passes; the temp file is created beside the destination (verifiable by inspecting `fetch_and_install`).

### U4. Diagnostic and tag correctness in `claudefuel`

**Goal:** The failure diagnostic is self-sufficient for LLM-driven recovery, and every tag that reaches a URL is validated.
**Requirements:** F6, F7, F8
**Dependencies:** none (independent of U3; both edit `claudefuel` but in separate functions)
**Files:** `claudefuel`, `tests/claudefuel-script.bats`
**Approach:**
- **Resolved tag (F6):** thread the resolved `$latest` into `dump_diagnostic` (add a parameter) and emit it as `desired_state.statusline_version` / `skill_version` instead of the literal `"<latest>"`. Update the three apply-phase `dump_diagnostic` call sites that already have the tag in scope.
- **SKILLS-derived bundle list (F7):** build `desired_state.bundle_files` at runtime from `${SKILLS[@]}` plus `statusline.sh` and `claudefuel`, replacing the hardcoded JSON array (KTD3).
- **Validate all tags (F8):** run interstitial tags (from `fetch_interstitial_tags`) and the release-body tag through `validate_tag` before interpolating into any URL; skip/`continue` on a tag that fails validation. `$latest` is already validated in `cmd_update`.
**Patterns to follow:** the existing `validate_tag` regex and its use guarding `$latest`; the `jq -n --arg/--argjson` construction in `dump_diagnostic`.
**Test scenarios:**
- Happy path (F6): trigger the `resolve_latest_tag`-succeeds-then-`fetch_statusline`-fails path; assert the written diagnostic's `desired_state.statusline_version` equals the resolved tag (e.g. `0.5.0`), not `<latest>`.
- Happy path (F7): assert `desired_state.bundle_files` in a dumped diagnostic contains all five command files plus `statusline.sh` and `claudefuel` (length and membership).
- Edge case (F8): mock a releases list containing a malformed `tag_name` (path/query metacharacters); assert the script does not interpolate it into a fetch URL and still completes the prompt for valid tags.
- Regression: the existing "cannot resolve latest tag" diagnostic test still passes (step + scope_note assertions unchanged).
**Verification:** Diagnostic JSON for a forced apply-phase failure shows a concrete version and a complete, SKILLS-derived file list; malformed-tag test passes.

### U5. Human-readable doctor output

**Goal:** `/claudefuel.doctor` shows a pass/fail health summary, not raw JSON, while internal callers keep structured state.
**Requirements:** F9
**Dependencies:** none (touches `cmd_inspect`, not `inspect_state`, so independent of U3/U4)
**Files:** `claudefuel`, `commands/claudefuel.doctor.md`, `tests/claudefuel-script.bats`
**Approach:** Per KTD1, change `cmd_inspect` to render a human pass/fail report derived from `inspect_state`'s JSON (one line per check: statusline present+executable+version, claudefuel binary, settings.json valid + `.statusLine` set, cache dir, each command file present+version). Add an `inspect --json` flag that prints the raw `inspect_state` output for machine use. Leave `inspect_state` and its diagnostic caller untouched. Update `doctor.md` so its "render its output verbatim" instruction now yields the human report (the prose can stay as-is since the script output changed; adjust only if it explicitly says "JSON").
**Patterns to follow:** parse `inspect_state` with `jq -r` to build report lines; mirror the check ordering of the pre-redesign `doctor.md` checklist (statusline → settings → command files → tooling → cache) so the surface feels familiar.
**Test scenarios:**
- Happy path: seed a complete install; `claudefuel inspect` output contains human pass markers (e.g. `statusline.sh` + version, all five commands) and is **not** a bare JSON object.
- Edge case: partial install (missing one command file); the report marks that file as missing/fail.
- Machine path: `claudefuel inspect --json` still emits valid JSON parseable by `jq -e '.statusline.present'` (preserves the existing inspect-JSON tests, repointed to `--json`).
- Broken settings: `settings.json` invalid → report shows the settings check failing.
**Verification:** `inspect` (no flag) is human-readable and `inspect --json` is the prior JSON; doctor.md renders the human report; updated bats tests pass.

### U6. Apply-path and invariant test coverage

**Goal:** The successful-apply path and its load-bearing invariants are asserted, and the two untested decision paths are covered.
**Requirements:** F10
**Dependencies:** U3, U4, U5 (new-behavior assertions reference their changes); the pure-coverage additions below are independent and may land first.
**Files:** `tests/claudefuel-script.bats`
**Approach:** Strengthen the existing full-apply test and add the missing cases. Reuse the existing `seed_complete_install`, `mock_text`, `mock_url`, and the curl mock harness.
**Patterns to follow:** the existing `update apply prunes bak sets to 3` test (full mocked apply with `printf 'y'`), and the `mock_url` raw-file seeding pattern.
**Test scenarios:**
- Apply success — content (F10): after a successful mocked `update`, assert `statusline.sh` and `claudefuel` now contain `# claudefuel: v<target>`, both are executable (`-x`), and `jq -e '.statusLine.command'` on `settings.json` exits 0.
- settings.json key preservation (F10): seed `settings.json` with an unrelated key (e.g. `{"model":"opus","permissions":{...},"statusLine":{...}}`); after apply, assert `.model` and `.permissions` survive and `.statusLine.command` is the new path. (Review confirmed the jq patch preserves keys in code — this guards against regression.)
- Header-verification failure (F10): mock `statusline.sh` to return a file *without* the `# claudefuel: v` header; assert non-zero exit, a diagnostic with `step == "fetch_statusline"`, and that bak files exist. This exercises the `fetch_and_install` return-2 branch.
- Repair-apply path: "current but incomplete" + `printf 'y'`; assert exit 0, `Done.`, and the previously-missing command file is now present.
- (If U5 landed) doctor human-output assertions live here or in U5's file section — keep them with U5 to avoid double-ownership.
**Verification:** New tests pass; the full suite count increases and stays green; the previously-unreachable return-2 branch is now covered.

---

## Scope Boundaries

### In scope
The six units above — the genuine plan gaps (U1, U2) and the review-surfaced hardening/coverage worth doing before a release (U3–U6).

### Deferred to Follow-Up Work
- **"(not installed)" mislabel** when `statusline.sh` exists with an unparseable header (cosmetic; low impact).
- **`--yes` / non-interactive flag** for unattended `update` (feature add; current safe-fail abort on closed stdin is acceptable).

### Out of scope (owned elsewhere)
- **Version / release reconciliation (review finding #1).** The v0.5.0 headers on `claudefuel`/`update.md`/`doctor.md` vs v0.4.0 on `statusline.sh`/`INSTALL.md`/`rollback.md`/`uninstall.md`/`configure.md` is **release-prep**, owned by companion plan **Phase 5** and governed by the "bumps land in a release-prep commit, not feature work" rule. This plan deliberately does not bump any header. See Open Questions.
- **CONTEXT.md glossary edits** and the **`update-redesign.md` supersede note** — companion plan Phase 1.2/1.3.
- **`docs/design/upgrade-experience.md` audit** — companion plan Phase 6.2.
- **Signing / immutable-SHA pin (review finding #9).** ADR-0005 names Sigstore as the escalation path if the threat model shifts; not now.

---

## Open Questions

- **OQ1 — Version reconciliation timing.** Should the v0.5.0/v0.4.0 split be resolved now (align all headers) or left for the Phase 5 release-prep commit? Per the stated convention this is release-prep; flagged so it is a conscious decision, not an oversight. Does not block U1–U6.
- **OQ2 — `.gitignore` intent (review finding #16).** This branch added `docs/plans/` to `.gitignore`, which would exclude these plan docs (including this one) and the companion redesign plan from the repo. Confirm that is intended before committing — it affects whether this plan is tracked.

---

## Risks & Dependencies

- **R1 — Editing files outside the original diff.** U1/U2 modify `rollback.md`/`uninstall.md`, which were unchanged on this branch. Risk: colliding with a planned later phase. Mitigation: the companion plan never assigned the skill-file updates to a phase (only INSTALL.md's uninstall section), so this is net-new, not a conflict.
- **R2 — Two units edit `claudefuel` (U3, U4, U5).** Mitigation: they touch disjoint functions (`main`/`fetch_and_install` vs `dump_diagnostic`/tag-fetch vs `cmd_inspect`); sequence U3 → U4 → U5 to keep diffs clean, or land together with care.
- **R3 — doctor output-shape change (U5) could surprise the `inspect`-JSON tests.** Mitigation: repoint existing JSON assertions to `inspect --json` in the same unit; U6 guards the human shape.
- **Dependency:** all units assume the current uncommitted tree (verified: 50/50 tests green, binary + shellcheck clean). No external dependencies.

---

## Sources & Research

- Code review run `20260614-082945-acae7826` (artifacts: `/tmp/compound-engineering/ce-code-review/20260614-082945-acae7826/`) — correctness, security, reliability, maintainability, testing, project-standards.
- `docs/adr/0005-update-flow-script-led.md` — the design this work implements.
- `docs/plans/update-redesign-implementation.md` — companion phased plan (Phases 1–6).
- `docs/release-notes.md` — release-body contract (trust surface rendered by `claudefuel update`).
- No external research: the change is confined to our own bash script and skill prose, with strong local patterns and no unsettled external option set.
