# Upgrade trust boundary: tag-pinned fetch, diff review, LLM audit — no signed releases

The `/claudefuel.update` skill fetches and executes `INSTALL.md` from upstream on every invocation. Because users will run it reflexively (unlike the one-time consent at initial install), the trust window widens from "once" to "every update forever." We need a deliberate trust model for that window.

We accept the following layered model:

1. **Tag-pinned fetch (primary integrity boundary).** The skill resolves the latest release tag via the GitHub Releases API and fetches `INSTALL.md` from `refs/tags/v<X.Y.Z>`, never from `main`. A malicious push to `main` does not propagate to existing users until a tag also moves. Only the **bar** still polls raw `statusline.sh` from `main` for drift detection — it never executes content, so a poisoned `main` at worst yields inaccurate drift signaling.
2. **Full diff render at confirm-time (primary trust check).** Before executing, the skill renders to chat: the `INSTALL.md` diff, the `statusline.sh` diff, and a list of every file the Promptfile will create or modify. The user reads this and explicitly confirms. This is the load-bearing check.
3. **LLM audit against the desired-state contract (secondary check).** Before executing, the skill instructs the running Claude session to audit the fetched `INSTALL.md` against its own "Desired state" section — flagging any operation that writes outside `~/.claude/`, modifies shell rc files, registers hooks, or fetches from hosts other than `github.com/FlorianRiquelme`. Falsifiable, cheap, catches benign drift between releases.

We explicitly **reject** signed releases (Sigstore / minisign / GPG). The signing infrastructure — key management, CI integration, verification on the user's machine, revocation story — directly contradicts the **Maintenance ceiling** principle. It also buys less than it appears to: claudefuel's threat model is "the source itself is compromised," and signing infrastructure controlled by that same source provides no defense against it. Signing protects against intermediaries, not the source.

## Consequences

- The LLM audit (step 3) is **secondary**, not primary. Prompt injection can defeat it — a malicious `INSTALL.md` can instruct the auditing model to vouch for itself. We document this honestly in the skill's prompt and rely on step 2 (user diff review) as the actual trust check.
- Adding `git` as a prerequisite was considered (for `git ls-remote --tags`) and rejected — `curl` + `jq` already cover the Releases API path, and adding prerequisites raises the install floor.
- If the threat model changes — e.g., claudefuel is widely adopted and becomes a supply-chain target — this ADR should be revisited. The likely upgrade path is Sigstore-style keyless signing via OIDC, not GPG.
