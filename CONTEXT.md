# claudefuel

A status bar for Claude Code that displays context window, rate-limit, and reset-time information. Self-installed via a Promptfile (`INSTALL.md`) that an LLM agent reads and reconciles against the user's machine.

## Language

**Promptfile**:
A markdown document written for an LLM agent to read and execute on the user's machine, while remaining human-readable as a fallback. `INSTALL.md` is the canonical Promptfile. Scope is now `/claudefuel.configure` only — install and update are no longer Promptfile-driven, see [ADR-0005](docs/adr/0005-update-flow-script-led.md).
_Avoid_: install script, installer, recipe.

**Reconcile**:
The single operation that brings the user's machine into the desired state described in the Promptfile. Idempotent: same paste line for install, upgrade, and no-op. The operator is now the `claudefuel` script on the success path, and the bundle-scoped LLM on the failure path — see [ADR-0005](docs/adr/0005-update-flow-script-led.md).
_Avoid_: install, upgrade, sync.

**Desired state**:
The hard-core contract in `INSTALL.md` — files, permissions, settings keys — that must hold after reconcile. Distinct from soft-shell choices (paths, profiles) that the agent may adapt per host. The contract now lives executably in the `claudefuel` script, with `INSTALL.md`'s desired-state section as its human-readable mirror — see [ADR-0005](docs/adr/0005-update-flow-script-led.md).
_Avoid_: target state, spec, requirements.

**Drift**:
Inequality between the installed `statusline.sh` version header and the upstream version header (string compare). Locally-modified scripts whose header still matches upstream are explicitly **not** drift — we accept that gap.
_Avoid_: out-of-date, stale, behind.

**Drift signal**:
The single `↗ /claudefuel.update` segment appended to status-bar line 1 when drift is detected. One glyph, no count, never wraps to a new row. Dot-syntax (not colon) — see [ADR-0001](docs/adr/0001-paste-line-not-plugin.md) for why claudefuel uses `/claudefuel.<verb>` instead of the colon-namespace plugins get for free.
_Avoid_: update notification, badge, banner.

**Trailhead**:
A surface that signals "there is more here" and points to a deeper surface that owns the content. The bar is a trailhead for the skill; the skill is a trailhead for `INSTALL.md`. Each layer points; only the deepest layer owns content.
_Avoid_: shortcut, link, pointer.

**Maintenance ceiling**:
A first-class design constraint: every code path is a path the maintainer must test, so designs that add state, fallbacks, or coupling are rejected even when they offer marginal UX gains.
_Avoid_: simplicity, tech debt, KISS.

**Configuration skill**:
The `/claudefuel.configure` slash command. Orchestrates the running Claude session to read `~/.claude/claudefuel.json`, walk the user through changes conversationally, and write the updated JSON. The configuration UI lives in the LLM session, not in a shell-side TUI.
_Avoid_: config wizard, settings menu, preferences.

**Profile**:
A `CLAUDE_CONFIG_DIR` — one isolated directory holding its own keychain credentials, sessions, and cache. The thing claudefuel actually reads from and writes to. The bar's per-account awareness is profile-awareness — it derives the keychain service name and cache file from whichever `CLAUDE_CONFIG_DIR` is active in the current terminal. **Profile is the technical term used in code and technical prose.**
_Avoid_: dir, directory, config dir (use only when the path itself is the topic, e.g. "the `CLAUDE_CONFIG_DIR` env var").

**Account**:
An Anthropic billing identity — the thing the user signs into with `claude auth login`. One account typically maps to one profile, but the user can run many profiles against the same account (e.g. separate dirs for separate workspaces). claudefuel does not introspect accounts; it only observes profiles. **Account is the user-facing term used in marketing copy and section headers** ("Works with multi-account setups") because that is how users describe their need; once inside the section, switch to "profile" for technical accuracy.
_Avoid_: login, identity (too generic).

**Minor tweaks**:
The scope of supported customization: color thresholds, segment ordering, segment show/hide, theme presets. Explicitly excludes user-supplied data sources, custom segments with embedded scripts, and plugin-like extensions — those would force a richer runtime than bash + jq supports and are the trigger to revisit [ADR-0003](docs/adr/0003-stay-bash-conversational-customization.md). The **Cap-ETA** segment is inside this scope (show/hide toggle); upgrading it to instantaneous burn rate would not be (see [ADR-0004](docs/adr/0004-stateless-cap-eta-on-line-3.md)).
_Avoid_: customization, configuration, settings (these are broader).

**Burn rate**:
A snapshot-derived rate of utilization within an open usage window: `pct_used / time_elapsed_in_window`. Always **average**, never instantaneous — claudefuel does not persist samples across renders. The day a user wants the rate to track their burst activity, that is the trigger to revisit [ADR-0003](docs/adr/0003-stay-bash-conversational-customization.md) and [ADR-0004](docs/adr/0004-stateless-cap-eta-on-line-3.md) together. **Burn rate** is the canonical term in code, ADRs, and chat; `velocity`, `pace`, and `throughput` are not synonyms.
_Avoid_: velocity, pace, throughput, usage rate.

**Reset-pace**:
The burn rate that would exactly consume a usage window at the moment it resets (= 100% / window length). The reference threshold for the **Cap-ETA** segment: when **burn rate** exceeds **reset-pace**, the user is on track to hit the cap before reset; only then is a cap-ETA actionable and rendered. Distinct from the actual burn rate — reset-pace is a constant per window, burn rate is dynamic.
_Avoid_: ideal pace, target rate, baseline (too generic).

**Cap-ETA**:
The predicted wall-clock time at which a usage window will reach 100% utilization at the current **burn rate**. Rendered on Line 3 as a `~cap HH:MM–HH:MM` range next to the reset time, only when **burn rate** exceeds **reset-pace** and pct_used has crossed a noise-floor gate. The tilde, the range, and the word `cap` together carry the "this is a rough estimate" contract — the prediction is honest about being snapshot-derived. Currently scoped to the 5-hour window only; 7-day and extra/$ caps are out of scope because their burn rates are too inertial to be actionable at sub-day horizons.
_Avoid_: cap prediction, ETA, time-to-cliff, exhaustion time.

## Display labels

The compact strings that render on the bar. They are part of the public language alongside the prose terms above — once shipped, renaming any of these is a UX-visible change, not an internal rename.

- `ctx` — context window segment on Line 1, paired with the bar and `<used>/<total>` (e.g. `ctx ●●○○○○○○○○ 50k/200k`).
- `5h` / `7d` / `extra` — column labels on Line 2 for the 5-hour, 7-day, and burstable monthly windows. Match the `.five_hour` / `.seven_day` / `.extra_usage` fields in the `/api/oauth/usage` response.
- `↻` — reset-time glyph prefix on Line 3 (replaces the word "resets"; one glyph per column).
- `↗ /claudefuel.update` — see **Drift signal** above.
- `~cap HH:MM–HH:MM` — see **Cap-ETA** above.

## Relationships

- A **Promptfile** declares **Desired state**; **Reconcile** brings the machine to it.
- The **Drift signal** is rendered when the installed version differs from upstream; invoking it routes to the `/claudefuel.update` skill, which delegates back to the **Promptfile**.
- **Trailhead** describes the pattern by which the **Drift signal**, the skill, and the **Promptfile** layer without duplicating content.
- **Burn rate** is compared against **Reset-pace** to decide whether to render a **Cap-ETA**: only when the user is on track to hit the cap before reset is the prediction actionable.

## Stability contract

These names are part of the project's public contract. Renaming any of them is a breaking change that strands existing users (the old `statusline.sh` references the old name and cannot reach the new one to upgrade itself). Removing or renaming `~/.claude/claudefuel` strands users the same way — their local copy would not know how to fetch its replacement. New names may be added as aliases; existing names are not removed.

- Slash commands: `/claudefuel.update`, `/claudefuel.doctor`, `/claudefuel.rollback`, `/claudefuel.uninstall`, `/claudefuel.configure`
- Install path: `~/.claude/statusline.sh`
- Update binary path: `~/.claude/claudefuel`
- Config path: `~/.claude/claudefuel.json` (user-owned; install never overwrites)
- Settings key: `.statusLine` in `~/.claude/settings.json`
- Promptfile URL: `https://raw.githubusercontent.com/FlorianRiquelme/claudefuel/main/INSTALL.md`

Release-body format is contracted in [ADR-0005](docs/adr/0005-update-flow-script-led.md): a bullet list, at most five lines of 80 characters, user-visible changes only, with an optional `Breaking: ...` final line. It is the trust surface `/claudefuel.update` renders before writing. (The standalone `docs/release-notes.md` the update-redesign plans call for was never written; ADR-0005 is the contract until it is.)

## Flagged ambiguities

- "Drift" was briefly considered to include locally-modified scripts (header matches, body differs). Resolved: out of scope. Detecting body drift would require a checksum on the bar's hot path — a **Maintenance ceiling** violation.
