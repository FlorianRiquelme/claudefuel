---
description: Reconcile claudefuel against the latest released spec
---
# claudefuel-skill: v0.5.0

Resolve `target_dir` as `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`.

Resolve the latest release tag via the GitHub Releases API. Fetch the tagged `claudefuel` script via `curl -fsSL` from `https://raw.githubusercontent.com/FlorianRiquelme/claudefuel/refs/tags/${latest_tag}/claudefuel` into `$target_dir/claudefuel`, `chmod +x` it, then run `$target_dir/claudefuel update`. Pass its stdout and stderr through to the user verbatim — the script owns the prompts, the release-body render, and the file manifest.

On exit 0 after an applied update: briefly relay the dormant bar behaviors from the "Post-install summary" section of `INSTALL.md` (drift signal, Cap-ETA) — that section is the canonical discoverability prose, do not duplicate it elsewhere. On a no-op (`— current.`): done, do not add commentary.

On non-zero exit: read `$target_dir/cache/claudefuel-update-diagnostic.json` for the failed step and embedded desired-state snapshot, inspect the live filesystem, and drive forward to the desired state. Scope: you may modify bundle files (`statusline.sh`, the five `commands/claudefuel.*.md`, `cache/`, the local `claudefuel` binary) and the `.statusLine` key in `settings.json`. You may not modify any other key in `settings.json`, any shell rc file, or anything outside `$target_dir/`.
