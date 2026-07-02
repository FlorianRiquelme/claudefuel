# Statusline Experience Roadmap — 2026-07-02

**Status:** approved for pickup · **Author:** ideation session 2026-07-02 · **Task ref:** task #10 ("Write roadmap plan for ranked ideas")

This plan is self-contained: a session with no prior context can pick any workstream and execute it. It sequences the ranked ideas from the 2026-07-02 research round (repo capability map + Claude Code statusline API brief + ecosystem survey of ~15 competitors) into concrete workstreams.

## Context and assumptions

- A separate session is merging the seven 2026-07-01 ideation branches into `integration/merge-ideation-branches` (`never-block-render`, `honest-instrument`, `configure-foundation`, `calm-cockpit`, `burn-radar`, `cross-profile-headroom`, `conversational-copilot`), then landing on `main`. **This plan assumes all seven are merged.** Do not re-implement anything those branches ship (never-block cache-first paint, stale-age markers + failure trailheads, `claudefuel.json` config loader + segment registry, structural alarm ladder, pace chip/steer-to, fleet view + switch hint, `/claudefuel.why` + `/claudefuel.coach` over `--snapshot`).
- Constraints that stand: pure Bash + `jq` + `curl`, no daemon (ADR-0003); Promptfile distribution, not a plugin (ADR-0001); config scope is minor tweaks only (thresholds, ordering, show/hide, themes). Version bumps happen **only in release-prep commits**, never inside feature branches.
- Strategic read from the ecosystem survey: the market splits into "beautiful/configurable" (ccstatusline ~11k★), "accurate/predictive quota" (claude-pace, leeguooooo usage-bar), and "live activity HUD" (claude-hud ~26k★ — the demand leader). Nobody combines p10k-grade rendering, trustworthy prediction, and now-awareness. claudefuel's lane: **the honest, instant, predictive instrument that also shows what Claude is doing right now.**

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

### R3 — The "Now" layer: what Claude is doing, not just what it costs

**Why:** the most-starred tool in the niche (claude-hud, ~26k★) shows almost no metrics — only live activity. claudefuel is entirely retrospective today. For a user running ~12 parallel sessions, "this pane is mid-Bash, that one is waiting on me" is the biggest single experience upgrade available.

**Scope (incremental, in this order)**
1. **Session identity chip:** `session_name` (or short `session_id` hash) with a stable per-session color — makes panes distinguishable at a glance. Cheap: pure stdin.
2. **Agent context:** show `agent.name` when present (subagent sessions); register `subagentStatusLine` in the install spec so subagent rows render too.
3. **Activity segment:** derive "current activity" from the tail of `transcript_path` (last tool_use name + elapsed since its timestamp; e.g. `▸ Bash 12s`). Read only the last N KB of the JSONL — never the whole file. Degrade to nothing on parse failure.
4. Register all three as segments in the configure registry (hide-able, orderable).

**Acceptance:** fixtures with `agent`/`session_name` render chips; a canned transcript tail fixture yields the activity label; malformed/missing transcript renders nothing and exits 0; render budget still met (transcript tail read must be O(tail), verified in timing mode).

**Risks:** transcript JSONL has no public format spec — treat parsing as best-effort, feature-flag it in config (`segments.hide` default could even ship it opt-in first). This is the most speculative workstream; keep it isolated.

### R4 — Predictive pace v2: projection on top of burn-radar

**Why:** the only question that changes behavior mid-session is "do I slow down now?". burn-radar ships the pace chip and steer-to; the upgrade is an explicit **end-of-window projection** ("→88% at reset") — the accuracy-focused competitors' current frontier.

**Scope**
- Add projected-percentage-at-reset next to the 5h bar when pace exceeds sustainable (extends the existing stateless model, ADR-0004 — stay stateless first).
- Only afterwards, and only if stateless proves too noisy: a small on-disk ring buffer of (timestamp, pct) snapshots in the cache dir for a smoothed slope. No daemon.
- Honest-instrument rules apply: projections always carry the `~`/`→` prediction glyphs, never presented as fact.

**Acceptance:** unit-style bats tests over canned snapshot pairs produce expected projections; projection hidden below the same dormancy thresholds as cap-ETA.

### R5 — Fleet awareness v2: shared-window attribution

**Why:** the documented real-world confusion — "usage stale / bar red" is usually *many sessions sharing one account window*, not a bug. cross-profile-headroom ships profile switching hints; the extension is same-account multi-session visibility. Nobody in the ecosystem does this.

**Scope**
- Per-session heartbeat file in the cache dir (`session-<id>` touched on each render, sourced from stdin `session_id`); count files fresh within ~5min → "N sessions on this window" chip when N>1.
- Optional: rough attribution (this session's context-window token delta vs. window total) — mark clearly as approximate or omit; wrong is worse than absent.
- Surface in `/claudefuel.fleet` view (exists post-merge) rather than cramming the bar.

**Acceptance:** two simulated renders with different session ids yield N=2; stale heartbeats (>5min) are pruned/ignored; single-session shows nothing.

### R6 — Responsive layout: `COLUMNS`-aware rendering + degradation tiers

**Why:** three fixed lines wrap ugly in split panes; rendering glitches are a top-4 complaint category ecosystem-wide. Only ccstatusline's flex mode attempts width-awareness. Low glamour, high polish-per-effort, protects every other workstream's output.

**Scope**
- Read `COLUMNS`; define per-segment priority; drop/abbreviate lowest-priority segments below width breakpoints (e.g. <80: shorten labels, hide `extra`/effort; <60: bars shrink to 5 cells).
- Glyph degradation tiers as a config key: `glyphs: "unicode" | "ascii"` (default unicode; no Nerd Font glyphs are currently required — keep it that way).
- Reuse the existing ANSI-aware padding helpers; the segment registry from configure-foundation is the natural place for priorities.

**Acceptance:** golden-output tests at COLUMNS=120/80/60 with a fixed fixture; no line ever exceeds COLUMNS.

### R7 — Clickable statusline: OSC 8 hyperlinks

**Why:** documented, supported by every modern terminal, and used by *no* surveyed competitor. Near-free ceiling raise: the bar becomes navigation.

**Scope**
- Reset-time cell → https://claude.ai/settings/usage; `↗ /claudefuel.update` → release changelog URL; `extra` balance → billing page; `pr` field → clickable `#N` chip with review-state glyph (`✓`/`◌`/`✗`/`◇`).
- Terminal capability gate: emit OSC 8 only when `TERM_PROGRAM`/`FORCE_HYPERLINK` indicates support; otherwise plain text (Terminal.app must not show garbage).
- Config: single `hyperlinks: true|false` key.

**Acceptance:** fixture render with `FORCE_HYPERLINK=1` contains OSC 8 sequences; without it, byte-identical to pre-R7 output.

## Explicitly deferred (surveyed, ranked below the line)

- Cache-economics chips (prompt-cache expiry countdown, hit-rate), pomodoro, token-reactive pets, theme marketplace / web configurator. Revisit only as opt-in segments after R3/R6; they dilute the "honest fuel instrument" identity as defaults.
- `starship timings`-style introspection: **already largely shipped** — `/claudefuel.doctor` has `CLAUDEFUEL_TIMING=1` per-stage latency + bulb-check. Extend only if R2/R3 budgets need finer per-segment numbers.

## Sequencing summary

```
R1 native-first stdin  ──►  R2 live tick ──►  R3 now-layer
        │
        └──►  R4 pace v2      R5 fleet v2      (independent after R1)
R6 responsive layout, R7 hyperlinks: independent, any time after integration lands.
```

Suggested release grouping: **0.5.0** = R1+R2 (the "instant & native" release), **0.6.0** = R3 (+R7 garnish), **0.7.0** = R4+R5 (the "predictive fleet" release), R6 folded wherever it's ready.

## Research provenance

- Repo capability map: `statusline.sh` v0.4.6, ADRs 0001–0005, `docs/ideation/2026-07-01-statusline-expansion-ideation.html`.
- API brief: https://code.claude.com/docs/en/statusline (2026-06-30 revision) and the v2.1.x changelog (`rate_limits` payload, `refreshInterval`, `COLUMNS`/`LINES` v2.1.153+, `pr`/`workspace.repo` v2.1.145, `current_usage` semantics v2.1.132, `subagentStatusLine`).
- Ecosystem: claude-hud (~26k★), ccusage (~17k★), ccstatusline (~11k★), CCometixLine, claude-powerline, claude-pace, leeguooooo/claude-code-usage-bar, cc-statusline, rz1989s/claude-code-statusline; prompt-world lessons from powerlevel10k (instant prompt, gitstatusd), starship (`timings`), tmux-powerline (adaptive width).
