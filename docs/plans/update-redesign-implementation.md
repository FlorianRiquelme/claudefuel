# Update flow redesign — implementation plan

Status: planned, not started
Drives: [[0005-update-flow-script-led]]
Supersedes the design intent of `update-redesign.md` (the design doc that resolved into ADR-0005)

## Shape

Ship in phases. Each phase is independently mergeable and leaves the repo in a working state — the existing Promptfile-driven update path stays alive until Phase 4 replaces it. Order is **docs → script → skill → INSTALL → release-notes → cleanup**.

## Phase 1 — Foundation docs

Goal: the language and contracts that the rest of the plan refers to exist in writing, in the repo.

1. **`docs/release-notes.md`** (new). The format contract.
   - Three to five bullets, 80 chars each, user-visible changes
   - Optional final `Breaking: <one line>` if applicable
   - Two worked examples (a typical release; a release with a breaking change)
   - Note that the script renders these as-is from the GH release body for the target tag and every interstitial tag
   - Acceptance: file exists, linked from `README.md` "Releases" section if one exists, otherwise from `CONTEXT.md`'s stability-contract section.

2. **`CONTEXT.md` edits.** Glossary updates driven by ADR-0005.
   - **Promptfile**: narrow scope to `/claudefuel.configure`. Add one sentence: "Install and update are no longer Promptfile-driven — see [[0005-update-flow-script-led]]."
   - **Reconcile**: keep the term and definition; add one sentence that the operator is now the `claudefuel` script (on success) and the bundle-scoped LLM (on failure).
   - **Desired state**: add one sentence that the contract now lives executably in the `claudefuel` script, with `INSTALL.md`'s desired-state section as its human-readable mirror.
   - **Drift** / **Drift signal**: unchanged.
   - **Stability contract** section: add `~/.claude/claudefuel` (the on-disk binary path) to the list of names. Removing or renaming it would strand existing users (their local `claudefuel` would not know how to fetch its replacement).

3. **`docs/plans/update-redesign.md`** — mark as superseded. One-line note at top: "Resolved into [[0005-update-flow-script-led]] and implementation plan in `update-redesign-implementation.md`." Don't delete; it's the design audit trail.

Acceptance gate for Phase 1: ADR-0005, `docs/release-notes.md`, and the updated `CONTEXT.md` all live in the repo. No code changes yet.

## Phase 2 — The `claudefuel` script

Goal: a single executable in repo root that implements forward reconcile + inspect + diagnostic-on-failure.

1. **Script skeleton.** `claudefuel` at repo root, `#!/usr/bin/env bash`, `set -euo pipefail`. Subcommands:
   - `claudefuel update` (default if no arg, or no-arg prints usage — see Q7 follow-on: prefer printing usage to avoid destructive default)
   - `claudefuel inspect` — read-only state report
   - `claudefuel --version` — header version, for tests and humans
   - Version header line `# claudefuel: vX.Y.Z` matching the existing convention.

2. **Shared `inspect_state` subroutine.** One implementation, three callers (update prelude, doctor invocation, failure diagnostic). Returns a structured snapshot of:
   - statusline.sh: presence, executability, parsed version header
   - five command files: presence, parsed `claudefuel-skill:` version each
   - claudefuel itself on disk: presence, executable, parsed version
   - settings.json: validity, current `.statusLine` value
   - cache/: presence

3. **`claudefuel update` happy path.**
   - Resolve latest tag via GitHub Releases API.
   - Fetch interstitial release bodies (current → latest) via `/releases/tags/<tag>`; on intermediate fetch failure, substitute `[notes unavailable for vX.Y.Z]` and continue.
   - Render release bodies + file manifest (`Updating: claudefuel, statusline.sh, 5 command files, settings.json (.statusLine only)`).
   - Prompt `Apply? [y/N]`. Default no on empty input.
   - On `y`: write baks with shared UTC `<TS>`, fetch and replace each bundle file atomically (mktemp → mv), patch `.statusLine` only via `jq` (preserving all other top-level keys), prune bak sets keeping the most recent three.
   - Report `Done. (rollback: /claudefuel.rollback)`.

4. **`claudefuel update` no-op + repair output shapes.**
   - All inspect checks pass + version matches latest → `v0.4.0 — current.` and exit 0.
   - Version matches latest but bundle is incomplete → `v0.4.0 — current, but bundle is incomplete: ...\n  - <list>\nRepair? [y/N]` and reconcile the deltas only on consent.

5. **`claudefuel update` failure path.**
   - Any step failure: dump `cache/claudefuel-update-diagnostic.json` per the schema in `update-redesign.md` (with embedded desired-state for offline recovery), print a one-line reason to stderr, exit non-zero.
   - **Do not** auto-revert. Leave baks on disk for `/claudefuel.rollback` to act on if the user explicitly asks.

6. **`claudefuel inspect`.** Calls `inspect_state`, renders the doctor output shape from Q6. Never touches the network. Never writes. Exit 0 always (it's a report, not a verdict).

7. **Tests.**
   - Unit-style: `inspect_state` against fixture filesystems (vanilla, partial-install, broken settings.json) using `bats` (existing convention from `tests/`).
   - Smoke: `claudefuel update` against a fixture target_dir with mocked curl returning canned spec.
   - Bak pruning: write five sets, run reconcile, assert three remain.

Acceptance gate for Phase 2: script exists, all subcommands return well-formed output, bats tests cover the three output shapes + failure dump.

## Phase 3 — Skill updates

Goal: `/claudefuel.update` and `/claudefuel.doctor` shrink to thin launchers.

1. **`commands/claudefuel.update.md`.** Replace the seven-step Promptfile with ~10 lines of prose:
   - Fetch the tagged `claudefuel` script via `curl -fsSL` from `refs/tags/${latest_tag}`.
   - Run it. Pass output through verbatim.
   - On exit 0: done.
   - On non-zero: read `$target_dir/cache/claudefuel-update-diagnostic.json`, inspect the live filesystem, drive forward to desired state. **Scope: you may modify bundle files (`statusline.sh`, the five `commands/claudefuel.*.md`, `cache/`, the local `claudefuel` binary) and the `.statusLine` key in `settings.json`. You may not modify any other key in `settings.json`, any shell rc file, or anything outside `$target_dir/`.**
   - Header `# claudefuel-skill: v0.5.0` (or whatever the next release tag is).

2. **`commands/claudefuel.doctor.md`.** Replace whatever it does today with: run `$target_dir/claudefuel inspect`; render output verbatim. If the local binary is missing, instruct the user to run `/claudefuel.update`.

3. Tests for skill prose are out of scope (the skills are prompts, not code). The script tests cover the mechanics they wrap.

Acceptance gate for Phase 3: both command files are short, point at the script, and the language matches the recovery-scope wording in the ADR verbatim.

## Phase 4 — INSTALL.md collapses

Goal: `INSTALL.md` becomes a paste-line + desired-state spec. The Reconcile section shrinks to "fetch and run `claudefuel`."

1. Replace the seven-step Reconcile section with: download `claudefuel` from `refs/tags/<latest>` to `$target_dir/claudefuel`, `chmod +x`, run it. The script handles everything else.
2. Update **Desired state** to add `claudefuel` as a bundle artifact (regular file, executable, parseable version header).
3. Update **cache/** desired-state entry: "claudefuel runtime scratch. Install creates the directory; runtime owns the contents (statusline.sh's `claudefuel-version.json`, `claudefuel`'s diagnostic dumps)."
4. Keep **Preconditions** as-is (curl/jq/claude on PATH) — the script depends on them. Consider moving precondition checking into the script itself in a follow-up; out of scope for this phase.
5. **Upgrade** section collapses to "run the same paste line."
6. **Uninstall** section: unchanged in spirit, but add `~/.claude/claudefuel` to the list of files removed.

Acceptance gate for Phase 4: paste-line is one line, the reconcile prose is gone, the desired-state contract is the only normative content left.

## Phase 5 — First release exercising the new flow

Goal: cut a v0.5.0 release using the new release-body contract. End-to-end dogfood.

1. Maintainer writes the v0.5.0 release body per `docs/release-notes.md` format before tagging.
2. Tag v0.5.0.
3. Install claudefuel into a clean `$CLAUDE_CONFIG_DIR` from v0.4.0's paste-line, then invoke `/claudefuel.update`. Verify: bar drift signal fires, release body renders, confirm prompt works, files update, bak files written, doctor reports clean.
4. Repeat from v0.4.0 with a deliberately-broken `settings.json` (`.statusLine` removed by hand) — verify the failure path dumps the diagnostic, the LLM-recovery prompt drives forward, and the recovery does not touch any settings.json key beyond `.statusLine`.

Acceptance gate for Phase 5: both scenarios pass on a real machine, not just in test fixtures.

## Phase 6 — Cleanup

1. Remove the dead three-state version-comparison snippet from `commands/claudefuel.update.md` (gone after Phase 3, but double-check `tests/fixtures/compare_versions.sh` for the mirrored fixture flagged in the current skill's notes).
2. Audit `docs/design/upgrade-experience.md` for prose that contradicts the new model; mark superseded sections.
3. Confirm `/claudefuel.rollback` still works against bak files produced by the new script — exercise once on a real machine.

## Out of scope (deferred)

- **Sigstore / keyless signing.** ADR-0005 keeps this as the named escalation path if the threat model shifts. Not now.
- **`claudefuel prune` subcommand.** Bak retention is automatic (three sets). A manual prune command can land later if needed.
- **Online doctor.** Doctor stays offline; if "am I current with upstream" is a real user need, the bar already answers it.
- **Pre-release tag support (`-rc1` etc.).** Still out of scope for v1.
- **Precondition checks inside the script.** The paste-line currently lists curl/jq/claude. Moving these checks into the script (so install is fully self-bootstrapping) is a follow-up.

## Risks and mitigations

- **Failure-path frequency is higher than expected.** Mitigation: instrument the failure path lightly (count of `cache/claudefuel-update-diagnostic.json` writes since last successful reconcile) and watch over the first few releases. If >5% drop into the LLM path, revisit the design.
- **Release-body discipline lapses.** Mitigation: add a `.github/release.yml` template (or document the template in `docs/release-notes.md` for copy-paste) so the maintainer sees the contract every time they write a body.
- **Local `claudefuel` script gets stale and doctor reports misleading state.** Mitigation: every successful `claudefuel update` rewrites the local copy as part of reconcile. Doctor output prefixes the version it parsed, so the user can see if it's behind.
