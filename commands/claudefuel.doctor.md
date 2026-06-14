---
description: Verify claudefuel install health
---
# claudefuel-skill: v0.5.0

Resolve `target_dir` as `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`.

If `$target_dir/claudefuel` is missing or not executable, tell the user to run `/claudefuel.update` to install the local binary, then stop.

Otherwise run `$target_dir/claudefuel inspect` and render its output verbatim. Do not modify any files. Do not add commentary beyond what the script emits.
