# Upgrade experience — design

**Status:** Shipped, then partly superseded by [ADR-0005](../adr/0005-update-flow-script-led.md)
**Date:** 2026-05-12 (rev. 2026-05-12)

> **Read this first.** The drift half of this design is what ships today: the single `↗ /claudefuel.update`
> segment on line 1, the no-count rule, the per-profile 6h version cache, the bar polling `main` while the
> skill pins a tag, dot-syntax command names, and the three-state `sort -V` comparison that
> `tests/version-compare.bats` covers.
>
> The upgrade *mechanics* below are superseded by [ADR-0005](../adr/0005-update-flow-script-led.md), which moved
> reconcile off the Promptfile and into the `claudefuel` script. Specifically obsolete: steps 4–6 of
> "What `/claudefuel.update` does" (the full diff render, the LLM audit, executing `INSTALL.md` as a Promptfile) —
> the release body is now the trust surface; and the auto-revert failure semantics under "Atomic install bundle" —
> the script bails with a diagnostic instead of restoring. The bundle has also grown past the five command files
> listed here. Kept as the design audit trail, not as current behaviour.

## Problem

Today the only way a claudefuel user learns about new versions is to remember to manually re-paste the install line. There is no in-product signal of drift, no path to discover what changed, and no operational surface for adjacent actions (rollback, health check, uninstall, configure).

The status bar is the only ambient surface the user looks at routinely. The driving question for this design: **what is the smallest, least intrusive way to surface "you have drifted" and "here is what to do about it" without making the bar nag, grow, or fail?**

## Constraints

1. **Maintenance ceiling.** See [CONTEXT.md](../../CONTEXT.md). Every code path is a path the maintainer must test. Designs that proliferate state, fallbacks, or coupling are rejected even when they offer marginal UX gains.
2. **No bullying.** The bar must not grow with the number of unread items. A multi-row drift trail that gets bigger every release would be coercive — the only way to silence it is to upgrade. We do not want that.
3. **Minimum required steps.** The user should not need to context-switch (open a URL, hunt for docs, recall a paste-line) to act on a drift signal. The action affordance must be at hand.
4. **Self-explanatory at first sight.** A user who has never seen the drift signal before should understand what it means and what to do about it without docs.
5. **Promptfile install model is preserved.** See [ADR-0001](../adr/0001-paste-line-not-plugin.md). This design lives entirely inside the bash + Promptfile world; no Go binary, no plugin-system migration. This is the constraint that makes most of the work below necessary.

## Design

### Status bar — when current

Unchanged from today's three rows.

### Status bar — when drifted

One additional segment on line 1:

```
... | thinking: On | effort: medium | ↗ /claudefuel.update
```

- A single `↗` glyph indicating drift (no count — see *Why no count* below).
- The literal text `/claudefuel.update` so the user knows the action affordance.
- The bar's height does **not** grow. The segment is appended to line 1, never wraps to a new row.
- When the user is current, the segment disappears entirely. Zero ambient nag.

### Operational surface — `/claudefuel.*` slash commands

```
/claudefuel.update      — show diff, audit, offer agentic upgrade
/claudefuel.doctor      — verify install health
/claudefuel.rollback    — restore latest .bak-<timestamp>
/claudefuel.uninstall   — remove
/claudefuel.configure   — edit ~/.claude/claudefuel.json conversationally
```

Dot-syntax (`claudefuel.<verb>`), not colon (`claudefuel:<verb>`). Colon-namespace is the Claude Code *plugin* convention; we are not a plugin (see [ADR-0001](../adr/0001-paste-line-not-plugin.md)). Dot-syntax is the user-scope slash-command convention and is already in use on the maintainer's machine (e.g., `spec-kitty.accept`).

These five names form a stability contract — see [CONTEXT.md](../../CONTEXT.md). Renaming any of them is a breaking change because old `statusline.sh` builds reference the old name in the drift signal and cannot reach a renamed update command.

### What `/claudefuel.update` does

The skill is thin orchestration. The actual install logic lives in `INSTALL.md` upstream. On invocation:

1. Read the installed version from `~/.claude/statusline.sh` header.
2. Resolve the latest release tag via the GitHub Releases API. Fetch `INSTALL.md` from `refs/tags/v<X.Y.Z>`, **not** from `main`. See [ADR-0002](../adr/0002-upgrade-trust-boundary.md) for the trust-boundary rationale.
3. Three-state comparison using `sort -V` (we accept this as a precondition; available on macOS and Linux):
   - **Equal** → output `v<X.Y.Z> — current.` and stop.
   - **Spec newer than installed** → continue.
   - **Installed newer than spec** → refuse and report ("you appear to have a customized or pre-release build; no action taken"). This serves both the maintainer running a dev build and the rare user who has hand-modified and re-versioned their script.
4. Render a full diff in chat: the `INSTALL.md` diff, the `statusline.sh` diff, and a list of every file the Promptfile will create or modify. This is the **primary trust check** — the user reads and explicitly confirms.
5. Run an LLM audit against the fetched `INSTALL.md`'s "Desired state" section, flagging any operation that writes outside `~/.claude/`, modifies shell rc files, registers hooks, or fetches from hosts other than `github.com/FlorianRiquelme`. This is a **secondary check** — vulnerable to prompt injection by design.
6. On confirm, execute `INSTALL.md` as a Promptfile. Same paste-line behavior the user already knows from initial install.

### What `/claudefuel.configure` does

The Configuration skill (see [CONTEXT.md](../../CONTEXT.md)). On invocation, the skill instructs Claude to:

1. Read `~/.claude/claudefuel.json` (or treat as empty if absent).
2. Present current settings as markdown.
3. Walk the user conversationally through changes scoped to **minor tweaks** (color thresholds, segment ordering, segment show/hide, theme presets). See [ADR-0003](../adr/0003-stay-bash-conversational-customization.md) for what is in vs out of scope.
4. Write the updated JSON back atomically (`mv` from temp file).
5. Tell the user to start a new Claude Code session for the bar to pick up changes.

The config file is **user-owned**. `INSTALL.md` never writes to it on install or upgrade.

### How the bar detects drift

- Cache at `~/.claude/cache/claudefuel-version.json` (per profile, survives `/tmp` cleanup). The maintainer's existing usage cache stays in `/tmp/claude/` — different TTL, different sensitivity, separate concern.
- TTL: 6 hours.
- Fetch: raw `statusline.sh` from `raw.githubusercontent.com/.../main/statusline.sh`. Extract the `# claudefuel: vX.Y.Z` header.
- Compare: string equality against the installed version.
- Result: render the `↗ /claudefuel.update` segment when different, hide it when equal.

The bar polls `main`, not a tag, on purpose — the bar never executes content, so a poisoned `main` at worst yields inaccurate drift signaling. Trust-pinning applies only to the **skill's execution path**.

CDN-served — no GitHub API auth, no rate-limit concerns on the bar's hot path.

### Multi-profile behavior

Each profile's `statusline.sh` reads its own header, fetches via the cache at `$CLAUDE_CONFIG_DIR/cache/claudefuel-version.json`, and renders drift independently. The cached *upstream* value is identical across profiles by definition, so two profiles on the same machine each spend one HTTP call per 6h on the same query — negligible duplication. Drift state is **per-bar**, not aggregated anywhere.

### Atomic install bundle

`INSTALL.md`'s desired-state contract grows to cover the full bundle:

- `~/.claude/statusline.sh`
- `~/.claude/commands/claudefuel.{update,doctor,rollback,uninstall,configure}.md`
- `~/.claude/settings.json` (patched, `.statusLine` key only)
- `~/.claude/cache/` directory (created if absent)

Each command file ships a `# claudefuel-skill: v<X.Y.Z>` header line, mirroring the convention used by `statusline.sh`. Detection and version comparison work uniformly across all install-managed artifacts.

Failure semantics extend the existing pattern: back up every file in the bundle that exists pre-install to `*.bak-<timestamp>`, write the new versions, run postcondition checks. On any postcondition failure, restore all `*.bak-<timestamp>` files written in this run in reverse order, then report. The user's `claudefuel.json` is never in the bundle — install does not touch user data.

## Decisions and rationale

### Why no count (`↗`, not `↗3`)

A count would require hitting the GitHub Releases API on the bar's hot path (rate-limited to 60 req/hr unauthenticated). For a bar that re-renders on every assistant message, that is a real failure mode to test. Moving the count into the skill — invoked rarely, can afford one API call per invocation — eliminates the rate-limit edge case entirely. The bar answers "are you drifted, yes or no"; the skill answers "by how much, with what changed."

Pattern: **bar shows the question, skill shows the answer.** Each surface does the minimum version of its job.

### Why dot-syntax instead of colon-namespace

The colon syntax is the plugin convention. We are not a plugin (see [ADR-0001](../adr/0001-paste-line-not-plugin.md)). Dot-syntax is the user-scope slash-command convention and works out of the box for `~/.claude/commands/<name>.md` files.

### Why delegate to upstream `INSTALL.md` instead of inlining install logic

1. **Single source of truth.** When `INSTALL.md` changes, behavior changes everywhere automatically. No syncing between the spec and the skill.
2. **Maintenance ceiling.** Inlining the spec into the skill would create coupling: every `INSTALL.md` change would require a synchronous skill release. Delegating removes that path.

Cost: the skill makes a network call at upgrade time. If GitHub is unreachable at that moment, the upgrade fails. We accept this — users retry. No clever offline fallback.

### Why one trailhead glyph instead of a multi-line drift trail

A multi-line trail showing per-version headlines grows the bar height with the number of unread releases. The only way to shrink it is to upgrade — coercive UX. The single-glyph design caps bar growth at +1 segment regardless of how far behind. Rich detail lives in the skill, invoked on demand.

### Why Claude as the customization UI

See [ADR-0003](../adr/0003-stay-bash-conversational-customization.md). We are already inside an LLM session. No other statusbar in the ecosystem can use the running model as its config UI. A conversational `/claudefuel.configure` skill turns the platform-we-ship-on into the customization tool, requiring zero new infrastructure.

### Why refuse on "installed newer than spec"

Reconcile should be predictable: either it brings the machine to the declared state, or it tells the user why it won't. Silent downgrade is dangerous; silent skip hides drift. Refusing forces a human decision and matches the existing "on any postcondition failure: stop, restore, report" stance. The maintainer's workaround when developing a dev build is trivial: don't invoke `/claudefuel.update` against it, or temporarily set the header to match spec.

## Patterns named in this design

1. **Trailhead pattern** — see [CONTEXT.md](../../CONTEXT.md). An ambient signal delegates to a richer action surface; no content is duplicated across surfaces. The status bar is a trailhead for the skill. The skill is a trailhead for `INSTALL.md`. Each layer points; only the deepest layer owns content.
2. **Bar shows the question, skill shows the answer** — each surface does the minimum version of its job.
3. **Conversational config as a platform-native customization story** — when the deploy target is an LLM session, the LLM is the configuration UI. No shell-side TUI needed.

## Open questions and future work

- **Polling cadence sweet spot.** 6h TTL is currently a guess. Worth measuring after launch — log how often the cache is stale-but-still-correct versus stale-and-out-of-date.
- **Migration cost for existing users.** Users on the version *before* the drift indicator and skill exist must perform one manual upgrade (paste the install line) before the system becomes reflexive. Worth a note in that release's announcement.
- **Skill robustness when itself broken.** The skill is software; software has bugs. The original paste-line (the `INSTALL.md` URL pasted into a fresh chat) is the always-works fallback — it must remain valid for every release. Belongs in the project's stated compatibility commitments.
- **`--force` flag for `/claudefuel.update`.** Deliberately not in v1. Add only if a real user reports the refuse-on-newer behavior blocking them. (Maintainer's dev workflow does not count.)
- **Customization scope creep.** If users start asking for custom segments with their own data fetchers, that is the trigger to revisit [ADR-0003](../adr/0003-stay-bash-conversational-customization.md) — the likely migration is a Go binary installed *by* the existing Promptfile (Path D from the strategy discussion).

## Step-2 spec bug to fix in the same release

The current `INSTALL.md` Step 2 compares the installed version against the literal floor `>= 0.1.0`, not against the spec's declared version. As a result, once a user has any version `>= 0.1.0` installed, the reconcile reports "up to date" and never upgrades.

The fix:

1. Compare the installed version against the spec's `Version:` declaration using `sort -V`.
2. Three states as described above: equal → no-op; spec newer → upgrade; installed newer → refuse and report.
3. No pre-release tag support in v1 (`X.Y.Z` only). If `-rc` builds are introduced later, revisit.

This bug must be fixed before the upgrade-experience release lands, otherwise the new drift signal points at an upgrade flow that no-ops.
