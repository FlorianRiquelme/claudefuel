# Install via Promptfile paste-line, not as a Claude Code plugin

claudefuel is distributed as a **Promptfile** (`INSTALL.md`) that the user pastes into Claude Code, not as a Claude Code plugin — even though plugins would give us `/plugin update`, a built-in registry, and the `/claudefuel:update` colon-namespace syntax for free.

We accept the cost: we maintain our own reconcile loop, our own upgrade UX, and dot-syntax (`/claudefuel.update`) instead of colon-syntax for skills. In return we preserve the project's one-paste install identity and avoid contributing to plugin fatigue — most target users already have many plugins installed and "don't make me install another plugin" is a real adoption blocker.

## Consequences

- The upgrade-experience design (`docs/design/upgrade-experience.md`) — drift indicator, polling cache, `/claudefuel.update` skill — is necessary precisely because we are not a plugin. It is the cost of this decision, not separate scope.
- Slash commands shipped by `INSTALL.md` land in `~/.claude/commands/claudefuel.<verb>.md` and invoke as `/claudefuel.<verb>` (dot, not colon). The design doc's `/claudefuel:update` references should be rewritten accordingly.
- If Claude Code's plugin system later adds a "lightweight, no-prompt-fatigue" install mode, this decision is worth revisiting.
