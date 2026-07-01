---
description: Reconcile claudefuel against the latest released spec
---
# claudefuel-skill: v0.4.1

This skill upgrades the user's claudefuel install to match the latest released `INSTALL.md`. It is thin orchestration — the actual install logic lives in the upstream Promptfile.

Execute the following steps in order. Stop and report on any unexpected state.

## Step 1 — Read the installed version

Read the version header from `~/.claude/statusline.sh`. If `CLAUDE_CONFIG_DIR` is set, read from there instead.

```bash
target_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
installed=$(head -20 "$target_dir/statusline.sh" 2>/dev/null \
  | grep -E '^# claudefuel:' \
  | sed -E 's/^# claudefuel: v//')
```

If `$installed` is empty, report "claudefuel is not installed — run the install paste line first" and stop.

## Step 2 — Resolve the latest release

Resolve the latest release tag via the GitHub Releases API, then fetch the **tagged** `INSTALL.md` (not `main`). Trust pins to the tag, not to `main` — a malicious push to `main` cannot propagate to existing users until a tag also moves.

```bash
latest_tag=$(curl -fsSL "https://api.github.com/repos/FlorianRiquelme/claudefuel/releases/latest" \
  | jq -r '.tag_name // empty')
[ -z "$latest_tag" ] && { echo "could not resolve latest release — GitHub API unreachable or no releases published. Try again later."; exit 1; }

spec_url="https://raw.githubusercontent.com/FlorianRiquelme/claudefuel/refs/tags/${latest_tag}/INSTALL.md"
spec_install=$(curl -fsSL "$spec_url")
spec=$(printf '%s\n' "$spec_install" | grep -E '^Version:' | head -n1 \
  | sed -E 's/^Version: *`?([^`]+)`?.*/\1/')
[ -z "$spec" ] && { echo "could not parse spec version from tagged INSTALL.md at ${latest_tag}. Try again later."; exit 1; }
```

Guarding both `$latest_tag` and `$spec` matters: with `$spec` empty, the three-state compare in Step 3 falls through to `installed-newer` (because the empty string sorts lowest under `sort -V`) and falsely tells the user they have a customized build. The early aborts keep the failure mode honest.

## Step 3 — Three-state version comparison

Compare `$installed` against `$spec` using `sort -V` semver semantics:

```bash
compare_versions() {
  local installed="$1" spec="$2"
  if [ "$installed" = "$spec" ]; then
    echo "equal"
    return 0
  fi
  local lowest
  lowest=$(printf '%s\n%s\n' "$installed" "$spec" | sort -V | head -n1)
  if [ "$lowest" = "$installed" ]; then
    echo "spec-newer"
  else
    echo "installed-newer"
  fi
}

state=$(compare_versions "$installed" "$spec")
```

Branch on `$state`:

- `equal` → report `v${spec} — current.` and stop.
- `spec-newer` → continue to Step 4.
- `installed-newer` → refuse: print `installed v${installed} is newer than spec v${spec} — you appear to have a customized or pre-release build; no action taken.` and stop. Do **not** offer a `--force` flag — silent downgrade would be dangerous, and the maintainer's workaround for dev builds is to edit the local version header to match spec.

## Step 4 — Render the diff for trust review

Read the installed `statusline.sh` from disk and fetch the spec's `statusline.sh` at the same tag (`refs/tags/${latest_tag}`); diff them. Also show the `INSTALL.md` diff between installed-tag and spec-tag if locally resolvable, plus a list of every file the Promptfile will create or modify (the bundle from the desired state — `statusline.sh`, five `commands/claudefuel.*.md`, `cache/`, the `.statusLine` key in `settings.json`).

This is the **primary trust check** — the user reads and explicitly confirms before anything writes.

## Step 5 — LLM audit (secondary check)

Read the fetched `INSTALL.md`'s "Desired state" section and flag any operation that:

- writes outside `~/.claude/` (or `$CLAUDE_CONFIG_DIR/`)
- modifies a shell rc file
- registers hooks
- fetches from a host other than `github.com/FlorianRiquelme`

This is vulnerable to prompt injection by design. The user's confirmation in Step 4 is the load-bearing check.

## Step 6 — Execute the Promptfile

On explicit user confirmation, fetch and execute the tagged `INSTALL.md` as a Promptfile — same paste-line behavior the user already knows from initial install. Report the post-reconcile verification results.

## Step 7 — Surface new user-visible behaviors

After Step 6's verification, read the **Post-install summary** section of the fetched `INSTALL.md` (the spec-tag version) and explain to the user any behaviors listed there. That section is the canonical home of feature discoverability copy — this skill defers to it rather than duplicating prose, so the description stays in one place across install and upgrade.

For dormant behaviors (segments that only render under specific conditions, like the cap-ETA), make it explicit that the user may not see the feature on the next render — they will see it the next time the trigger condition fires.

## Notes

- The bar polls `main` for drift detection (cheap, no execution); this skill pins to a tag (trust boundary). A poisoned `main` at worst yields inaccurate drift signaling — it never executes.
- Pre-release tags (`-rc1` etc.) are not supported in v1.
- The user's `~/.claude/claudefuel.json` is never touched by this skill or by `INSTALL.md`.
- The `compare_versions` snippet in Step 3 is the canonical home of the version-comparison algorithm. The test fixture at `tests/fixtures/compare_versions.sh` mirrors it verbatim — if you change one, change the other.
