# Stay bash; customization via a conversational skill, not a Go binary

We considered rewriting `statusline.sh` as a Go binary distributed via GoReleaser + Homebrew tap or curl-pipe-sh. That path would have given us a real release pipeline, faster execution (1–5ms vs 10ms), and a conventional config-file + TUI customization story matching the rest of the Claude Code statusbar ecosystem (CCometixLine, ccstatusline, claude-powerline).

We rejected it. claudefuel stays a bash script. Customization is scoped to **minor tweaks** (color thresholds, segment ordering, segment show/hide) stored in `~/.claude/claudefuel.json` and edited via a `/claudefuel.configure` skill that orchestrates Claude as the configuration UI.

## Reasoning

- **The Promptfile pattern is genuinely novel.** A survey of comparable projects found zero others using "paste a URL, let the LLM reconcile." Going Go means joining a crowded curl-pipe-sh aisle and abandoning the differentiator. Staying bash preserves it.
- **Performance is a non-issue.** 10ms is invisible. The case for Go was customization, not speed.
- **We're already inside an LLM session.** No other statusbar can use the running model as its config UI. A conversational `/claudefuel.configure` skill turns the platform-we-ship-on into the customization tool, requiring zero new infrastructure (no GoReleaser, no Homebrew tap, no cross-compile).
- **Maintenance ceiling.** A Go rewrite multiplies the toolchain footprint by an order of magnitude — release pipeline, multi-arch binaries, signing, package-manager registrations, a Go codebase to test alongside the markdown skills. Path A' adds one JSON file and one markdown skill.

## Scope of customization (the boundary)

In scope: color thresholds, segment ordering, segment show/hide, theme presets.
Out of scope: user-supplied data sources, custom segments with embedded scripts, plugin-like extensions, runtime hooks. These would force a richer runtime than bash + jq comfortably supports and become the trigger to revisit this ADR.

## Consequences

- `~/.claude/claudefuel.json` is **user-owned data**, not an install artifact. `INSTALL.md` never overwrites it on upgrade. The script uses built-in defaults when the file is absent or has missing keys.
- The `/claudefuel.configure` skill joins the stability contract alongside `.update`, `.doctor`, `.rollback`, `.uninstall`. Five committed names, not four.
- If customization demand outgrows "minor tweaks" — particularly user-supplied data sources or plugin segments — the migration path is Path D from this discussion: a Go binary installed *by* the existing Promptfile. The Promptfile model survives the rewrite; only the artifact format changes. This ADR is the marker for that decision point.
