# Statusline Experience Roadmap — 2026-07-02

**Status:** implemented 2026-07-02 (R1–R8 merged to main; version bump deferred to release prep) · **Author:** ideation session 2026-07-02 · **Task ref:** task #10 ("Write roadmap plan for ranked ideas")

This plan is self-contained: a session with no prior context can pick any workstream and execute it. It sequences the ranked ideas from the 2026-07-02 research round (repo capability map + Claude Code statusline API brief + ecosystem survey of ~15 competitors) into concrete workstreams.

## Context and assumptions

- A separate session is merging the seven 2026-07-01 ideation branches into `integration/merge-ideation-branches` (`never-block-render`, `honest-instrument`, `configure-foundation`, `calm-cockpit`, `burn-radar`, `cross-profile-headroom`, `conversational-copilot`), then landing on `main`. **This plan assumes all seven are merged.** Do not re-implement anything those branches ship (never-block cache-first paint, stale-age markers + failure trailheads, `claudefuel.json` config loader + segment registry, structural alarm ladder, pace chip/steer-to, fleet view + switch hint, `/claudefuel.why` + `/claudefuel.coach` over `--snapshot` v1).
- Constraints that stand: pure Bash + `jq` + `curl`, no daemon (ADR-0003); Promptfile distribution, not a plugin (ADR-0001); config scope is minor tweaks only (thresholds, ordering, show/hide, themes). Version bumps happen **only in release-prep commits**, never inside feature branches.
- Strategic read from the ecosystem survey: the market splits into "beautiful/configurable" (ccstatusline ~11k★), "accurate/predictive quota" (claude-pace, leeguooooo usage-bar), and "live activity HUD" (claude-hud ~26k★ — the demand leader). Nobody combines p10k-grade rendering, trustworthy prediction, and now-awareness. claudefuel's lane: **the honest, instant, predictive instrument that also shows what Claude is doing right now — configured by talking to it.**

## API facts the workstreams rely on

From https://code.claude.com/docs/en/statusline (verified 2026-07-02):

- **stdin JSON now includes `rate_limits`**: `rate_limits.five_hour.{used_percentage, resets_at}` and `rate_limits.seven_day.{...}` (`resets_at` is unix epoch). Conditional field — may be absent on older Claude Code versions or non-subscription auth.
- Other stdin fields of interest: `session_id`, `session_name`, `prompt_id`, `agent.name`, `pr.{number,url,review_state}`, `worktree.{name,path,branch,original_cwd,original_branch}`, `workspace.repo.{host,owner,name}`, `context_window.current_usage.{input_tokens,output_tokens,cache_creation_input_tokens,cache_read_input_tokens}` (nullable before first API call and after `/compact`), `exceeds_200k_tokens`, `transcript_path` (session JSONL, readable), `version`.
- Since v2.1.132, `total_input_tokens`/`total_output_tokens` reflect **current context**, not cumulative session totals.
- **`refreshInterval`** statusline setting (min 1s) re-runs the command on a timer; default is event-driven only (after each assistant message, `/compact`, permission-mode change, vim toggle; 300ms debounce, in-flight runs cancelled).
- **`COLUMNS` / `LINES`** env vars are set for the script (v2.1.153+). `tput cols` does not work inside the script.
- **OSC 8 hyperlinks** are supported: `\e]8;;URL\atext\e]8;;\a` (iTerm2/Kitty/WezTerm/Ghostty; not Terminal.app).
- **`subagentStatusLine`** config renders per-subagent status rows (v2.1.x).
- Multi-line output supported; full truecolor ANSI.

## Workstreams, ranked

Execute roughly in order; R1 is the foundation and should land first. Each workstream = one `feat/` branch off `main` (post-integration), tests in `tests/*.bats`, no version bump in-branch.

### R1 — Native-first data: read `rate_limits` from stdin, demote OAuth to enrichment

**Why #1:** attacks the ecosystem's top pain (accuracy/trust) and claudefuel's own worst costs at once — the multi-endpoint OAuth fetch path (~half the script), 429 cooldowns from many concurrent sessions on one account, and stale-data warnings. stdin data is free, per-render fresh, and by construction agrees with Claude Code's own UI. Every later workstream gets faster and more trustworthy.

**Scope**
- When `rate_limits` is present on stdin, use it as the source of truth for the 5h/7d bars and line-3 reset times. Render with no network at all.
- Keep the OAuth path solely for what stdin lacks: `extra` prepaid balance, and cross-profile data for the fleet view. Fall back to the full OAuth usage fetch only when `rate_limits` is absent (older Claude Code, missing field).
- Mark data provenance in the honest-instrument sense: stdin-sourced values are always "fresh" (no age marker needed); OAuth-sourced values keep the existing age/staleness markers.
- Update `/claudefuel.doctor` to report which source each number came from.

**Acceptance:** bats tests feeding a stdin fixture with `rate_limits` render correct bars with `CLAUDEFUEL_OFFLINE=1` and no cache present; fixture without `rate_limits` falls back to the OAuth/cache path unchanged; prepaid `extra` column unaffected.

**Risks:** field is conditional — never hard-require it; verify `resets_at` epoch handling against both BSD and GNU `date` (see `feat/cap-eta-line-3` pipefail history).

### R2 — Live tick: `refreshInterval` + countdowns that move

**Why:** perceived quality. never-block-render made paint instant; a reset countdown and cap-ETA that visibly tick each second read as "alive and trustworthy". Near-zero risk once R1 makes renders network-free.

**Scope**
- INSTALL.md/update spec: set `statusLine.refreshInterval` (suggest 1–5s; measure render cost first — the script must comfortably beat the interval; post-R1 target is ≤50ms warm render).
- Offer `reset_display: "countdown"` as the natural pairing (config key already exists post-configure-foundation).
- Guard: if a render is invoked while a background OAuth refresh is in flight, the cache-first path must still return instantly (already the never-block contract — add a regression test under timer-frequency invocation).

**Acceptance:** doctor timing mode (`CLAUDEFUEL_TIMING=1`) shows warm render within budget; countdown mode changes output between two invocations 1s apart (test by injecting `CLAUDEFUEL_NOW` or equivalent seam if one exists; add one if not).

### R3 — Conversational configuration v2: talk to your statusbar *(flagship)*

**Why #3:** this is the moat. Competitors escape JSON editing with React TUIs (ccstatusline) or hosted web configurators (Powerline Studio) — claudefuel's config wizard is *the LLM the user is already talking to*. It turns the project's most unusual bet (ADR-0001/0003: the running Claude session is the UI) from an install trick into the headline experience. v1 (`configure-foundation` + `conversational-copilot`, landing now) proves the mechanism; v2 makes it *outstanding*: you describe what you want in plain language, Claude shows you the bar before/after, you say yes, it's live on the next render.

**What v1 already ships (baseline — do not rebuild):**
- Config loader in `statusline.sh`: reads `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/claudefuel.json` every render, single `jq` pass → shell assignments, malformed file silently ignored (defaults win).
- Schema v1 keys: `version`, `theme` (`default`|`mono`), `color_thresholds.{orange,yellow,red}`, `reset_display` (`clock`|`countdown`), `segments.order.{line1,columns}`, `segments.hide` (order tokens + hide-only badges `profile`, `cap_eta`).
- `commands/claudefuel.configure.md`: conversational procedure — resolve path, show *effective* config, converse, write sparse JSON (only non-default keys), preserve unknown keys, `jq .` validation before move, ADR-0003 boundary refusals, drift-hide warning.
- `--snapshot` v1 (from `conversational-copilot`): pure read-only JSON of on-disk caches + ADR-0004 derived math (no fetches, no stdin, no credential access, no cache writes) with a versioned schema (`claudefuel-snapshot v1`); consumed by `/claudefuel.why` and `/claudefuel.coach`.
- Doctor "bulb-check": demo render lighting every alarm state from a canned snapshot.
- Tests: `tests/configure.bats`, `tests/snapshot.bats`, `tests/skills.bats`.

**v2 deliverables (in implementation order):**

**D1 — `CLAUDEFUEL_CONFIG` override (the test/preview seam).** The config loader honors `CLAUDEFUEL_CONFIG=<path>` as an alternative config-file path (read-only; same malformed-file-is-ignored semantics). This single env var is what makes preview, validation testing, and golden tests possible. ~5 lines in the loader.

**D2 — `--demo <state>` flag: first-class preview renders.** Generalize the doctor bulb-check mechanism into a script flag: `statusline.sh --demo healthy|warning|critical|stale|offline` renders the full 3-line bar from a canned built-in snapshot for that state — no stdin, no network, no cache reads, deterministic output (fixed timestamps baked into the canned data so goldens are byte-stable). Combined with D1: `CLAUDEFUEL_CONFIG=/tmp/candidate.json statusline.sh --demo warning` shows exactly what a proposed config looks like under pressure. Reuse the existing bulb-check canned snapshot; inspect how `honest-instrument`/`calm-cockpit` implemented it before writing anything new.

**D3 — `--validate-config [path]` flag: machine-checkable config validation.** Validates the given path (default: the resolved user config) and prints a JSON report:
```json
{ "schema": "claudefuel-config-check v1", "status": "ok|warnings|malformed|absent",
  "errors": [], "warnings": ["unknown token \"7day\" in segments.hide — did you mean \"7d\"?"],
  "effective": { "theme": "default", "color_thresholds": {"orange":50,"yellow":70,"red":80}, "...": "..." },
  "overridden_keys": ["color_thresholds.red"] }
```
Checks: valid JSON; `version` supported; threshold sanity (numeric, 0–100, `orange < yellow < red` — warn, don't error, since the bar tolerates it); unknown tokens in `order`/`hide` (warn, with nearest-match suggestion); unknown top-level keys (info only — they're preserved by design). Exit codes: 0 ok/warnings, 1 malformed, 2 absent. `/claudefuel.doctor` runs it and surfaces the result; the configure skill runs it before *and* after every write.

**D4 — `--snapshot` v2: add a `config` block.** Extend the snapshot schema (bump to `claudefuel-snapshot v2`; additive only — existing consumers `/claudefuel.why` and `/claudefuel.coach` keep working) with: config path, parse status, effective values, and `overridden_keys`. This is how the skill shows "here's what your bar is doing and why" without re-implementing the merge logic in prose, and how `/claudefuel.why` can answer "why is my bar red at 75%?" with "your `color_thresholds.red` is set to 70".

**D5 — Rewrite `commands/claudefuel.configure.md` around the preview loop.** The new procedure (this is the heart of the feature — write it carefully, it's executed verbatim by the session LLM):
1. Resolve config path (`$CLAUDE_CONFIG_DIR` aware). Run `--validate-config` to get status + effective config; if malformed, offer to show the parse problem and fix or reset it (with the user's confirmation — the file is user-owned).
2. Understand intent via the **intent vocabulary** (below). If the ask maps to a preset, propose the preset; if it maps to keys, propose the concrete diff. If it's out of scope (custom segments, data sources, scripts, colors beyond the two themes), decline citing ADR-0003 *and offer the nearest in-scope alternative* (e.g. "custom red color" → "I can't change the palette, but `mono` removes hues entirely, or I can move when red kicks in").
3. **Preview before writing:** write the candidate config to a temp file, render `CLAUDEFUEL_CONFIG=<tmp> statusline.sh --demo healthy` and `--demo critical`, and show both next to the current config's same two demos — a literal before/after of the user's actual bar. Ask for confirmation on the *rendered output*, not the JSON.
4. On yes: back up the existing file to `claudefuel.json.bak-<timestamp>` (same convention as install backups), move the candidate into place, run `--validate-config` again, and confirm "live on your next render — no restart".
5. Support **undo**: "undo that" / "go back" restores the most recent `claudefuel.json.bak-*` (show its diff first). Mention `/claudefuel.rollback` is for the *install*, not this file.

**D6 — Intent vocabulary + presets (in the skill, not the script).** The bar stays dumb (ADR-0003): presets are expanded by the skill into concrete schema-v1 keys at write time — no `preset` key in the config file, so a preset is just a starting point the user can then tweak. Ship this table in the skill:

| User says (examples) | Maps to |
|---|---|
| "calmer", "less alarming", "stop yelling at me" | raise `color_thresholds` (e.g. 70/85/95) — show current values first |
| "warn me earlier", "more cautious" | lower `color_thresholds` (e.g. 40/60/80) |
| "minimal", "less clutter", "just the essentials" | **preset `minimal`**: `hide: ["thinking","effort","profile","extra","drift"]` — warn about drift-signal loss per v1 guardrail |
| "everything", "back to normal", "reset" | delete overrides / restore defaults (empty file or `{"version":1}`) |
| "no colors", "colorblind", "accessible", "grayscale" | `theme: "mono"` (calm-cockpit structural alarms carry severity without hue) |
| "countdown", "how long until reset" | `reset_display: "countdown"` |
| "clock times" | `reset_display: "clock"` |
| "put the weekly bar first", "reorder" | `segments.order.columns` / `segments.order.line1` |
| "hide X" / "show X" | `segments.hide` add/remove; list valid tokens if X is unrecognized |
| "focus mode", "deep work" | **preset `focus`**: minimal + `reset_display: "countdown"` |
| "cockpit", "show me everything, tight" | **preset `cockpit`**: full segments, thresholds 40/60/80 |

Unrecognized intents: ask one clarifying question with 2–3 concrete options rendered as demos — never write a config the user hasn't seen rendered.

**D7 — Cross-profile awareness.** If `CLAUDE_CONFIG_DIR` profiles exist (detect sibling `~/.claude-*` dirs with a `statusline.sh` symlink), after applying to the active profile ask once: "apply the same look to your other profiles (work, personal)?" Each profile has its own `claudefuel.json`; never write to inactive profiles without that explicit yes.

**Guardrails (carry all v1 guardrails forward, plus):**
- The skill writes **only** `claudefuel.json` (+ its `.bak-*` siblings). Never `settings.json`, never `statusline.sh` (install-managed — and note the vibe-ads wrapper caveat: some installs wrap the statusline command, so `settings.json` must stay untouched).
- Always sparse writes (non-default keys only), always preserve unknown keys, always `--validate-config` before declaring success.
- Temp candidate files go in the session scratchpad or `mktemp`, never next to the real config.
- If `--demo` or `--validate-config` don't exist (user's installed script predates v2), degrade to the v1 procedure (JSON-level confirm, manual test-render one-liner) rather than failing.

**Tests (`tests/configure.bats` extensions + new `tests/render-demo.bats`):**
- `--validate-config`: exit codes and JSON report for fixtures — valid sparse config, malformed JSON, absent file, out-of-order thresholds (warning), unknown hide token (warning + suggestion), unknown top-level key (preserved, info).
- `CLAUDEFUEL_CONFIG` override: loader reads the override path; malformed override falls back to defaults; unset behaves exactly as before (regression).
- `--demo`: each state renders 3 lines, exits 0, is byte-identical across two runs (determinism), never touches the network (assert with `CLAUDEFUEL_OFFLINE` unset but no curl calls — reuse whatever seam never-block-render's tests use), and reflects an injected `CLAUDEFUEL_CONFIG` (e.g. mono theme demo contains no color escapes).
- `--snapshot` v2: `config` block present with correct `overridden_keys`; schema string bumped; v1 fields unchanged.
- `tests/skills.bats`: configure skill file contains the preview-loop procedure markers, the intent table, and the guardrail phrases (same style as existing skill checks).

**Acceptance:** a user can say "make it calmer and hide the thinking segment", see a rendered before/after of their bar in healthy and critical states, approve, and have the change live on the next render — with a `.bak` written, validation green, and "undo" working. All without the skill ever touching `settings.json` or `statusline.sh`.

**Risks / notes for the implementer:**
- The doctor bulb-check and `--snapshot` were written by different branches — read both before adding flags; keep flag parsing in one place at the top of the script (the `--snapshot` block at ~line 22 is the pattern to follow: early-exit modes before any stdin read).
- Determinism of `--demo` requires fixed timestamps in the canned snapshot *and* bypassing the age-marker "now" — thread the existing `CLAUDEFUEL_NOW`-style seam through (add it if R2 hasn't yet).
- Keep the skill file under ~150 lines; it's read by the session LLM every invocation — dense tables beat prose.
- Coordinate with R4/R6/R7: any new segment or config key those add **must** be registered in the schema table, the intent vocabulary, and `--validate-config`'s token list. That's an acceptance criterion on *those* workstreams, listed there.

### R4 — The "Now" layer: what Claude is doing, not just what it costs

**Why:** the most-starred tool in the niche (claude-hud, ~26k★) shows almost no metrics — only live activity. claudefuel is entirely retrospective today. For a user running ~12 parallel sessions, "this pane is mid-Bash, that one is waiting on me" is the biggest single experience upgrade available.

**Scope (incremental, in this order)**
1. **Session identity chip:** `session_name` (or short `session_id` hash) with a stable per-session color — makes panes distinguishable at a glance. Cheap: pure stdin.
2. **Agent context:** show `agent.name` when present (subagent sessions); register `subagentStatusLine` in the install spec so subagent rows render too.
3. **Activity segment:** derive "current activity" from the tail of `transcript_path` (last tool_use name + elapsed since its timestamp; e.g. `▸ Bash 12s`). Read only the last N KB of the JSONL — never the whole file. Degrade to nothing on parse failure.
4. Register all three as segments in the configure registry, the R3 intent vocabulary, and `--validate-config`'s token list (hide-able, orderable).

**Acceptance:** fixtures with `agent`/`session_name` render chips; a canned transcript tail fixture yields the activity label; malformed/missing transcript renders nothing and exits 0; render budget still met (transcript tail read must be O(tail), verified in timing mode); R3 registration criterion met.

**Risks:** transcript JSONL has no public format spec — treat parsing as best-effort, feature-flag it in config (consider shipping it opt-in via `segments.hide` default). This is the most speculative workstream; keep it isolated.

### R5 — Predictive pace v2: projection on top of burn-radar

**Why:** the only question that changes behavior mid-session is "do I slow down now?". burn-radar ships the pace chip and steer-to; the upgrade is an explicit **end-of-window projection** ("→88% at reset") — the accuracy-focused competitors' current frontier.

**Scope**
- Add projected-percentage-at-reset next to the 5h bar when pace exceeds sustainable (extends the existing stateless model, ADR-0004 — stay stateless first).
- Only afterwards, and only if stateless proves too noisy: a small on-disk ring buffer of (timestamp, pct) snapshots in the cache dir for a smoothed slope. No daemon.
- Honest-instrument rules apply: projections always carry the `~`/`→` prediction glyphs, never presented as fact.

**Acceptance:** unit-style bats tests over canned snapshot pairs produce expected projections; projection hidden below the same dormancy thresholds as cap-ETA.

### R6 — Fleet awareness v2: shared-window attribution

**Why:** the documented real-world confusion — "usage stale / bar red" is usually *many sessions sharing one account window*, not a bug. cross-profile-headroom ships profile switching hints; the extension is same-account multi-session visibility. Nobody in the ecosystem does this.

**Scope**
- Per-session heartbeat file in the cache dir (`session-<id>` touched on each render, sourced from stdin `session_id`); count files fresh within ~5min → "N sessions on this window" chip when N>1.
- Optional: rough attribution (this session's context-window token delta vs. window total) — mark clearly as approximate or omit; wrong is worse than absent.
- Surface in `/claudefuel.fleet` view (exists post-merge) rather than cramming the bar. Register any new bar chip per the R3 registration criterion.

**Acceptance:** two simulated renders with different session ids yield N=2; stale heartbeats (>5min) are pruned/ignored; single-session shows nothing.

### R7 — Responsive layout: `COLUMNS`-aware rendering + degradation tiers

**Why:** three fixed lines wrap ugly in split panes; rendering glitches are a top-4 complaint category ecosystem-wide. Only ccstatusline's flex mode attempts width-awareness. Low glamour, high polish-per-effort, protects every other workstream's output.

**Scope**
- Read `COLUMNS`; define per-segment priority; drop/abbreviate lowest-priority segments below width breakpoints (e.g. <80: shorten labels, hide `extra`/effort; <60: bars shrink to 5 cells).
- Glyph degradation tiers as a config key: `glyphs: "unicode" | "ascii"` (default unicode; no Nerd Font glyphs are currently required — keep it that way). Register the key per the R3 registration criterion.
- Reuse the existing ANSI-aware padding helpers; the segment registry from configure-foundation is the natural place for priorities.

**Acceptance:** golden-output tests at COLUMNS=120/80/60 with a fixed fixture; no line ever exceeds COLUMNS.

### R8 — Clickable statusline: OSC 8 hyperlinks

**Why:** documented, supported by every modern terminal, and used by *no* surveyed competitor. Near-free ceiling raise: the bar becomes navigation.

**Scope**
- Reset-time cell → https://claude.ai/settings/usage; `↗ /claudefuel.update` → release changelog URL; `extra` balance → billing page; `pr` field → clickable `#N` chip with review-state glyph (`✓`/`◌`/`✗`/`◇`).
- Terminal capability gate: emit OSC 8 only when `TERM_PROGRAM`/`FORCE_HYPERLINK` indicates support; otherwise plain text (Terminal.app must not show garbage).
- Config: single `hyperlinks: true|false` key, registered per the R3 registration criterion.

**Acceptance:** fixture render with `FORCE_HYPERLINK=1` contains OSC 8 sequences; without it, byte-identical to pre-R8 output.

## Explicitly deferred (surveyed, ranked below the line)

- Cache-economics chips (prompt-cache expiry countdown, hit-rate), pomodoro, token-reactive pets, theme marketplace / web configurator. Revisit only as opt-in segments after R4/R7; they dilute the "honest fuel instrument" identity as defaults. (A web configurator specifically is anti-thesis: R3 *is* the configurator.)
- `starship timings`-style introspection: **already largely shipped** — `/claudefuel.doctor` has `CLAUDEFUEL_TIMING=1` per-stage latency + bulb-check. Extend only if R2/R4 budgets need finer per-segment numbers.

## Sequencing summary

```
R1 native-first stdin ──► R2 live tick ──► R4 now-layer
        │
        ├──► R5 pace v2      R6 fleet v2      (independent after R1)
        │
R3 conversational config v2: independent of R1 — only needs the integration
   merge (configure-foundation + conversational-copilot). Start immediately;
   it is priority #3 by value and has no technical blockers.
R7 responsive layout, R8 hyperlinks: independent, any time after integration lands.
```

Suggested release grouping: **0.5.0** = R1 + R2 + R3 (the "instant, native, conversational" release — R3 is the headline feature), **0.6.0** = R4 (+R8 garnish), **0.7.0** = R5 + R6 (the "predictive fleet" release), R7 folded wherever it's ready.

## Research provenance

- Repo capability map: `statusline.sh` v0.4.6, ADRs 0001–0005, `docs/ideation/2026-07-01-statusline-expansion-ideation.html`, `docs/design/configure-feature-brainstorm.md`.
- API brief: https://code.claude.com/docs/en/statusline (2026-06-30 revision) and the v2.1.x changelog (`rate_limits` payload, `refreshInterval`, `COLUMNS`/`LINES` v2.1.153+, `pr`/`workspace.repo` v2.1.145, `current_usage` semantics v2.1.132, `subagentStatusLine`).
- Ecosystem: claude-hud (~26k★), ccusage (~17k★), ccstatusline (~11k★), CCometixLine, claude-powerline, claude-pace, leeguooooo/claude-code-usage-bar, cc-statusline, rz1989s/claude-code-statusline; prompt-world lessons from powerlevel10k (instant prompt, gitstatusd), starship (`timings`), tmux-powerline (adaptive width).
