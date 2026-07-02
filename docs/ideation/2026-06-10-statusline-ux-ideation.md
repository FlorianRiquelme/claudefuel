---
date: 2026-06-10
topic: statusline-ux
focus: Best possible end-user UX for the claudefuel statusline (context usage, 5h/7d/extra limits, reset times, cap-ETA, prepaid balance, multi-account)
mode: repo-grounded
---

# Ideation: claudefuel Statusline UX

## Grounding Context

**Codebase context.** claudefuel is a bash+jq statusline for Claude Code (`statusline.sh`, ~676 lines, v0.4.0 on `feat/prepaid-credit-balance`). Display: Line 1 `[profile] Model | ctx ●●○○ used/total | thinking | effort | ↗ update-drift`; Line 2 `5h/7d/extra` progress bars + prepaid `$` balance; Line 3 `↻` reset times + `~cap HH:MM–HH:MM` ETA when burning faster than reset-pace. Colors green→orange→yellow→red. Multi-account via `CLAUDE_CONFIG_DIR` (per-profile keychain hash + cache files). Hard boundaries: ADR-0003 (bash+jq only, no daemon, no state between renders, customization = minor tweaks via `~/.claude/claudefuel.json` through `/claudefuel.configure` — currently a stub with no keys wired); ADR-0004 (predictions are pure functions of one snapshot, visibility gates, honesty signals). "Cliffs" that force a rewrite: daemons, plugin runtimes, rule engines, TUI editors, multi-source fanout.

**Past learnings.** Prior multi-AI brainstorm (`docs/design/configure-feature-brainstorm.md`) converged on: progressive alarm (quiet when healthy, loud when burning), ledger→radar (predictive > retrospective), profile segment underused. Pre-vetted picks: analogue glyph preset, Audience Mode, vibe-led config. Trim-batch precedent: redundant readouts get cut; precision defers to `claude /status`.

**External context.** Prior art: ccstatusline (10.5k★, 40+ widgets, praised TUI onboarding), ccusage (cost-centric, burn rate first-class), claude-usage-monitor (priority collapse on narrow width), cc-statusline ("deviations stand out, normal states invisible"), Rust rewrites driven purely by per-refresh latency. Gap: nobody owns prepaid balance UX or conversational config. Cross-domain: battery three-field canon (bar + % + time-to-empty); Ford distance-to-empty beats raw level; GCP normalized burn-rate ratio (>1.0 = exhausts before reset); aviation failed-instrument doctrine; dive-computer governing-constraint promotion. Market: the March 2026 quota crisis validated demand — users want real-time remaining, will-I-make-it prediction, prominent reset countdown, threshold warnings.

## Topic Axes

1. Glanceability & alarm design
2. Prediction & decision support
3. Configuration & personalization
4. Multi-account & profile experience
5. Lifecycle UX (install, update, doctor, render latency)

## Ranked Ideas

### 1. The Honest Instrument — staleness and failure become display states
**Description:** Stale cache renders with an age marker (`5h ●●●○ 62% ·9m`); failure classes (expired auth, network down, missing jq) render a one-glyph diagnosis plus a `✚ /claudefuel.doctor` trailhead mirroring the shipped `↗` drift pattern; `/claudefuel.doctor` gains a "bulb check" demo render exercising every alarm state (all four colors, cap-ETA, drift, balance) from a canned snapshot; the render path stops rewriting credentials (read-only access; on expiry, render stale with the marker and let Claude Code refresh on its own schedule).
**Axis:** Glanceability & alarm design / Lifecycle UX
**Basis:** `direct:` silent stale-cache fallback at `statusline.sh:422-425` and `475-477` renders cached data indistinguishably from fresh; auth failure renders as absence (line ~447 gates the credit path with no failure branch); `refresh_oauth_token` (lines 209-264) deletes and re-adds the keychain item inside the per-render path. `external:` aviation instrument doctrine — a failed gauge must read FAILED, never a plausible value.
**Rationale:** A fuel gauge that shows yesterday's fuel as today's is the exact mechanism behind surprise depletion — the core fear this product exists to prevent. Silent absence is indistinguishable from "no warning = fine".
**Downsides:** Requires enumerating a failure taxonomy and deciding how loud staleness honesty should be; removing render-path token refresh degrades freshness for long-idle sessions.
**Confidence:** 90%
**Complexity:** Medium
**Status:** Unexplored

### 2. Config foundation — wire /claudefuel.configure for real
**Description:** Three primitives: (a) a single jq merge loader (`~/.claude/claudefuel.json` over baked-in defaults, exported as `cfg_*` vars); (b) a segment registry (each segment a named function in a per-line ordered array, renderer walks the array) so show/hide/order become pure data; (c) one shared severity ladder (ratio → color+glyph) used by every colored element. First keys: alarm thresholds, countdown-vs-clock, segment show/hide, cap-ETA toggle, theme preset. Downstream unlocks as data, not features: joker/bingo personal callwords, Audience Mode, per-profile accent colors ($CLAUDE_CONFIG_DIR overlay), width-aware priority collapse.
**Axis:** Configuration & personalization
**Basis:** `direct:` `/claudefuel.configure` is shipped, in the five-skill stability contract, and a dead end ("placeholder — no config keys wired yet"); rendering is inline `line1+=` concatenation so ordering/hiding is structurally impossible today; ADR-0003 pre-authorizes thresholds/ordering/show-hide/presets.
**Rationale:** A documented, contracted command that does nothing is a direct trust hit and blocks every personalization-shaped improvement. The schema shipped first sets the configuration culture forever.
**Downsides:** Structural refactor of the whole render path inside a tested 676-line script; schema is a one-way door (migration pain if wrong).
**Confidence:** 90%
**Complexity:** Medium-High
**Status:** Unexplored

### 3. From ledger to radar — burn-ratio chip and time-left framing
**Description:** A normalized pace chip next to the 5h bar (`×1.4` = burning at 1.4× the rate that survives until reset; dormant ≤1.0) gives continuous will-I-make-it feedback before cap-ETA fires. Lead the 5h readout with time-at-pace (`~2.1h left`), demoting percent to the bar fill; render the 5h reset as a countdown (`↻ in 42m`). Extensions from the same snapshot algebra: a prescriptive steer-to number (`slow to ≤0.6x` — the instruction, not the diagnosis), the stranding gap (`⚓ 1h50m to ↻` — dead time between projected cap and reset), and a horizon-scaled uncertainty range replacing the fixed ±15min.
**Axis:** Prediction & decision support
**Basis:** `external:` GCP SRE burn-rate alerting (normalized ratio as the canonical signal); Ford distance-to-empty research (time-to-empty answers the decision question, raw level doesn't); battery three-field canon. `direct:` `claudefuel_cap_eta_segment` (statusline.sh:552-578) already computes elapsed, pct, and pace — every extension is one more awk expression, stateless per ADR-0004.
**Rationale:** Cap-ETA tells you when you hit the wall; the ratio tells you how hot you're running and the steer-to number tells you what to change. Percent doesn't map to felt time — `~40min left` changes behavior, `82%` doesn't.
**Downsides:** Line 2/3 are space-constrained; risks duplicating what the ETA range implies; `↻ <time>` is a contracted display label (CONTEXT.md), so countdown-vs-clock likely needs a config key.
**Confidence:** 85%
**Complexity:** Low-Medium
**Status:** Unexplored

### 4. Never-block render — cache-first paint + published latency budget
**Description:** The render always paints from cache instantly; when a cache is stale, fire a detached one-shot `curl … > cachefile &` that benefits the next render. Honor `CLAUDEFUEL_OFFLINE` on the main usage fetch (currently only prepaid/drift respect it). `/claudefuel.doctor` gains a timing mode: per-stage wall time (jq parse, cache read, fetch path, render) against a published budget (e.g. <150ms cached path), giving every future feature a regression gate.
**Axis:** Lifecycle UX
**Basis:** `direct:` the hot path performs sequential `curl -s --max-time 5` calls (OAuth refresh, usage, account, prepaid) plus a `--max-time 3` drift fetch when caches are stale (statusline.sh:407-473, 139-172) — worst case ~20s of prompt-area jank; the usage fetch block has no offline guard. `external:` per-refresh latency complaints drove full Rust rewrites in this category (ccusage-statusline-rs exists purely for startup latency).
**Rationale:** A statusline renders on every turn; it is the one place where performance is UX. Jank is attributed to Claude Code itself — invisible cause, visible pain, uninstall risk.
**Downsides:** Detached background fetch needs an explicit ADR ruling (is fire-and-forget "stateless enough"? sits near the no-daemon cliff); stale-first paint requires idea 1's honesty markers to be safe.
**Confidence:** 85%
**Complexity:** Medium
**Status:** Unexplored

### 5. The Calm Cockpit — progressive alarm as structure, not hue
**Description:** Generalize ADR-0004's visibility gates into an "earn your pixels" convention: Lines 2–3 collapse when all windows are nominal (the bar physically growing is a pre-attentive alarm no color change matches); ≥90% escalates with shape/weight (inverse video, `⚠` prefix), not hue alone; the governing constraint — whichever window hits 100% first at current pace — is promoted to lead position or marked (`▸`), dive-computer style. Instances of the same gate: prepaid balance hidden until spend is live (then surfaced as runway), extra bar hidden at $0, drift arrow severity-gated.
**Axis:** Glanceability & alarm design
**Basis:** `direct:` hue is the only severity encoding today (`build_bar`, statusline.sh:63-75; pct text is always cyan); the three-line layout is unconditional per the header contract; ADR-0004 already names "visibility gates (dormant when meaningless)" as house pattern. `external:` cc-statusline's praised principle "deviations stand out, normal states invisible"; ESI triage and dive-computer governing-constraint promotion.
**Rationale:** A statusline is read peripherally hundreds of times a day; always-on detail trains the eye to ignore it, and ~8% of male users can't reliably distinguish the most safety-critical color transition. Matches the prior brainstorm's progressive-alarm convergence — this specifies it.
**Downsides:** Changes the product's 3-line silhouette (screenshots, tests, README); dynamic position/visibility conflicts with spatial memory — some users want stable layouts (config escape hatch via idea 2).
**Confidence:** 80%
**Complexity:** Medium
**Status:** Unexplored

### 6. Cross-profile headroom — see the spare tank
**Description:** When the active profile's binding window runs hot and a sibling profile's on-disk cache shows headroom, render a switch hint (`⇄ work 12%`). Companion fleet view (`/claudefuel.fleet` skill or `claudefuel fleet` subcommand): a compact table of every known profile's 5h/7d bars, reset, and balance, read from the per-profile caches already written to /tmp.
**Axis:** Multi-account & profile experience
**Basis:** `direct:` per-profile cache files already exist keyed by `CACHE_SUFFIX` (statusline.sh:199-204, 388, 430) — the data for every recently-rendered profile sits on disk, unread; prior brainstorm flagged the profile segment as underused. `external:` FAA/NTSB fuel-management doctrine — "fuel starvation with fuel on board" (selector on the empty tank) is the most preventable failure class; the mitigation is glanceable other-tank quantity.
**Rationale:** Multi-account is the headline differentiator, yet the decision it exists for — "is my other account worth switching to?" — currently requires opening another terminal at the worst possible moment.
**Downsides:** Crosses the per-profile isolation boundary the cache design deliberately built — needs an explicit ADR ruling (privacy/trust, and whether sibling reads count as "multi-source fanout"); sibling caches may be stale if that profile hasn't rendered recently.
**Confidence:** 75%
**Complexity:** Medium
**Status:** Unexplored

### 7. The Conversational Copilot — /claudefuel.why + /claudefuel.coach
**Description:** `why`: an on-demand show-your-work view — the current snapshot fully annotated (burn rate vs reset-pace, cap-ETA arithmetic, which visibility gates passed/failed and why, cache ages, active profile), reading the existing /tmp snapshot cache as a versioned internal API. `coach`: ask "can I finish this refactor before my 5h reset?" or "should I drop to a cheaper model?" — Claude reuses the script's endpoints and ADR-0004 math and answers in prose with a recommendation. Display stays dumb and stateless; the advice layer lives where the intelligence already is.
**Axis:** Prediction & decision support / Configuration & personalization
**Basis:** `direct:` ADR-0003's thesis — "No other statusbar can use the running model as its config UI" — extends identically from configuration to consultation; ADR-0004 documents the full derivation chain as pure functions of one snapshot; the curl incantations already exist in statusline.sh. `reasoned:` predictions users can't interrogate get distrusted and ignored; the gates are the most sophisticated part of the product and completely invisible.
**Rationale:** The one differentiator no widget-count competitor (ccstatusline's 40+) can copy. Converts the gauge from instrument to copilot at exactly the moment of the core fear.
**Downsides:** Expands the five-skill stability contract; advice quality depends on the model; risk of scope creep toward a "rule engine" cliff if over-built.
**Confidence:** 70%
**Complexity:** Medium
**Status:** Unexplored

## Rejection Summary

| # | Idea | Reason Rejected |
|---|------|-----------------|
| 1 | Reset countdown (`↻ in 42m`) | folded into idea 3 (time-left framing) |
| 2 | Shape/weight escalation at ≥90% | folded into idea 5 |
| 3 | Scarcity-sorted Line 2 / governing-constraint promotion | folded into idea 5 (competing variants of the same scanning fix) |
| 4 | Single triage acuity glyph | folded into idea 5 — competes with constraint promotion; pick one in brainstorm |
| 5 | One shared severity ladder | folded into ideas 2+5 as the implementation primitive |
| 6 | Read-only credentials from render path | folded into idea 1 |
| 7 | Bulb-check demo render | folded into idea 1 |
| 8 | Steer-to pace delta, stranding gap, horizon-scaled cone | folded into idea 3 as extensions |
| 9 | Latency self-measurement in doctor | folded into idea 4 |
| 10 | Segment registry refactor | folded into idea 2 as primitive (b) |
| 11 | Joker/Bingo personal callwords | folded into idea 2 (first behavioral config key candidate) |
| 12 | Per-profile config overlay | folded into idea 2 downstream unlocks |
| 13 | Width-aware priority collapse | folded into idea 2 downstream unlocks (zero-config beats config) |
| 14 | Verdict segment (alarm bundled with remedy) | split between ideas 3 and 6 |
| 15 | Snapshot contract for skills | folded into idea 7 (`why` reads the versioned cache) |
| 16 | Drift severity filter (silence patch releases) | rejected: real but low value vs survivors; becomes trivial once idea 2 lands |
| 17 | Prepaid runway / session-denominated balance | rejected as standalone: an instance of idea 5's earn-your-pixels gate — but timely to consider now while `feat/prepaid-credit-balance` is in flight |
| 18 | Project-keyed presets (path → preset) | rejected: stretches ADR-0003's "minor tweaks"; revisit as a late config key |
| 19 | Quiet Cockpit as standalone | folded into idea 5 |
| 20 | Cross-profile variants (bar hint vs fleet vs tank-selector) | merged into idea 6 |
| 21 | Time-to-empty as primary unit (standalone) | folded into idea 3 |
| 22 | /claudefuel.profiles skill | merged into idea 6 fleet view |
