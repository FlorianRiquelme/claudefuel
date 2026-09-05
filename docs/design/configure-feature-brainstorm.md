# `/claudefuel.configure` — feature brainstorm

Multi-AI brainstorm exploring what features the configuration skill could offer for the status bar. Three perspectives (Codex / Gemini / Claude) ran in parallel against the v0.2.0 codebase. This document is internal design exploration, not a roadmap — its job is to seed future ADRs and reveal where the v0.2 ADR boundary (color thresholds, segment ordering, segment show/hide, theme presets) is and isn't worth crossing.

## Grounding

claudefuel renders three lines:

- **Line 1:** `[profile] Model | tokens used/total | %used | %remain | thinking on/off | effort level | ↗ drift signal`
- **Line 2:** `current: <bar> X% | weekly: <bar> X% | extra: <bar> $used/$limit`
- **Line 3:** `resets <time> | resets <datetime> | resets <date>`

Data sources already wired: Anthropic OAuth `/api/oauth/usage` (5h, 7d, extra), the stdin JSON from Claude Code (model, context_window, thinking, effort), `CLAUDE_CONFIG_DIR` profile name. Stack is bash + jq + curl, ANSI 24-bit color, runs on every render (~300ms).

[ADR-0003](../adr/0003-stay-bash-conversational-customization.md) scopes customization to **minor tweaks**: color thresholds, segment ordering, segment show/hide, theme presets. Out of scope: user-supplied data sources, custom segments with embedded scripts, plugin runtime.

## Three independent runs

### Codex — feasibility & cliffs

Codex's strongest contribution was not its features but its **Cliffs taxonomy** — seven named triggers whose addition would force the project off bash onto Go:

1. User-supplied segment logic (sandboxing, timeouts, escaping become the product)
2. Background usage daemon (lifecycle, locking, IPC)
3. Plugin runtime (versioned APIs, plugin loading, failure isolation)
4. Real TUI config editor (terminal state, resize, keyboard input)
5. Concurrent multi-profile state (file locks, atomic writes, migrations)
6. Rich rule engine ("if weekly > 80% and current reset > 2h…" — needs a parser)
7. More than one network source (fanout, timeouts, partial-failure handling)

The Cliffs document the *map of where not to go* without an ADR revisit. The recovered features from Codex's run (output was clipped at idea 7+) were: quota-strategy personas, profile-specific layouts, quiet states, live-preview configurator.

### Gemini — lateral inspirations

- **Vibe-Synced Dashboard** — `/configure` asks "what kind of morning are you having?" instead of "what color?" — translates intent (panic, flow, demo) into preset selection. In-scope; only LLM-as-UI can do it.
- **Ghost-Burn shadow bar** — dim "ghost" behind the current bar shows projected state in 20 min. **ADR-breaker** (needs velocity state).
- **Dieter Rams / Analogue Mode** — replace `[████░░]` with braille and box-drawing glyphs that mimic physical sliders (`─────┨────`). Tactile aesthetic. In-scope (pure glyph swap).
- **Drift Compass** — directional indicator (`<-- refactor | bloat -->`). **ADR-breaker** (diff content as new data source).
- **Agentic Body Language** — 1-char pulse "breathes" when effort:high. Risky on the 300ms hot path (frame state).

### Claude — patterns & paradoxes

Eleven ideas; the durable ones:

- **The Whisper Threshold** *(paradox)* — bar collapses to a single dim character below 40% burn. Health is what you don't think about.
- **Drift Tax** *(pattern)* — repurpose the only predictive slot for a projected exhaustion ETA. Every other segment looks backward; this is the one telescope.
- **The Cliff** *(naming)* — named term for the bankruptcy moment; one-time 85% warning that never repeats.
- **Profile Drift Anchor** *(contrast)* — `[work] (+18% burn vs your usual Tuesday)`. The profile segment is sitting on a behavioral mirror.
- **Reset-as-Countdown** *(paradox)* — flip Line 3 from clock time to relational ("resets in 2 prompts at current rate"). Token-time, not wall-time.
- **Segment Slot Machine** — conditional segments: effort only when thinking is on, drift only when burn > X. Bar gets denser by getting emptier.
- **The Honest Bar** — strategically round (down below 50%, up above 80%) for loss-averse nudging. **ADR-breaker** (display semantics).
- **Audience Mode** *(contrast)* — privacy preset for screen-sharing: hide $, anonymize profile, soften drift glyph. In-scope as preset. Marketing gold.
- **The Metronome** — highlight the *next* reset on Line 3, ghost the other two.
- **Burn-Rate Vocabulary** — user-named tiers (`drift / cruise / sprint / blaze / cliff`). **ADR-breaker** (segment content).

## Cross-perspective synthesis

### Three points of convergence

1. **The bar is loudest when it's healthy, quietest when it's burning.** Codex's *Quiet States* + Claude's *Whisper Threshold* + *Segment Slot Machine* all converged on the same inversion. Status bars optimize for visibility, but claudefuel's highest value comes from disappearing when you're safe and screaming when you're not. Call this the **progressive alarm**.

2. **Convert the bar from ledger to radar.** Gemini's *Ghost-Burn* + Claude's *Drift Tax* + *Reset-as-Countdown* all want predictive segments. Every existing segment looks backward; the one slot occupied by the drift arrow is the only one looking forward. All three say: use it.

3. **The profile segment is underused.** Codex's *Profile-Specific Layouts* + Claude's *Profile Drift Anchor* — `[work]` and `[personal]` shouldn't just be labels, they should be behavioral mirrors.

### Picks worth deepening

1. **The Progressive Alarm** *(in-scope)* — A meta-feature that subsumes Quiet States, Segment Slot Machine, Whisper Threshold. `/configure` asks one question: *"how loud should the bar be when you're fine?"* Three presets: `Silent`, `Compact`, `Always full`. Cheap on the hot path; fits ADR as segment show/hide driven by a preset.

2. **The Single Predictive Slot** *(ADR-breaker)* — Replace the drift arrow's slot with a single predictive readout: cap-ETA, prompts-remaining-at-rate, or one-shot Cliff warning at 85%. The interesting move is *picking one* — three predictive segments is a dashboard, one is a co-pilot. Triggers Cliff #2 (background daemon for velocity state). Worth an ADR revisit on its own.

3. **Dieter Rams glyph preset** *(in-scope, near-zero cost)* — Ship `theme = "analogue"` swapping `●○` for braille/box-drawing tactile glyphs. The screenshot-worthy idea.

4. **Audience Mode** *(in-scope as theme preset)* — `theme = "audience"` hides `$used/$limit`, replaces the profile name with a generic emoji, softens the drift signal. Zero new data sources. Every streamer becomes a billboard.

5. **Vibe-led configuration** *(meta-pattern)* — The differentiator isn't *what* `/claudefuel.configure` configures; it's *how it asks*. Don't ask "which segments to hide?" Ask "what kind of session is this?" The four picks above collapse into ~5 named modes (`Quiet / Predictive / Demo / Tactile / Audience`) mapping to combinations of configurable primitives. The config file stays simple; the conversation does the curation.

### One unresolved tension

Two of the strongest ideas (Predictive Slot, Drift Compass) are ADR-breakers because they need *state across renders*. Codex's Cliffs analysis flags this as the **Background Daemon trigger** (Cliff #2) — the moment claudefuel becomes a daemon-plus-renderer instead of a one-shot script, the maintenance ceiling shifts and the Go-rewrite path becomes the right answer.

So a real strategic question hides here: **is "predictive" the feature class worth crossing the boundary for?** If yes, [ADR-0003](../adr/0003-stay-bash-conversational-customization.md) gets revisited with predictive segments as the named trigger. If no, the predictive ideas die quietly and the project stays bash forever.

## Multi-perspective provenance

| Provider | Key contribution | Unique insight |
|----------|------------------|----------------|
| 🔴 Codex | Quiet states, profile-specific layouts, live preview | The **Cliffs taxonomy** — seven named features whose addition forces a Go rewrite. The map of where not to go. |
| 🟡 Gemini | Vibe-Synced config, Dieter Rams glyphs, body language | **Tactile/aesthetic angle** — the only purely-visual idea, and the most screenshot-worthy. |
| 🔵 Claude | Progressive alarm, predictive slot, profile drift anchor | **Audience Mode** (privacy for streamers) and **burn-rate vocabulary** (shared dialect). Both lean hard into "what only LLM-as-UI can configure." |
