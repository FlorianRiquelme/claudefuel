# Session line

Line 1 tells the user which profile and model they are on, how full the context window is, and whether thinking and effort are active. Every value comes from the stdin payload Claude Code sends on each refresh.

## Sub-features

- `line1-profile` shows `[name]` from `CLAUDE_CONFIG_DIR` basename `.claude-<name>`.
- `line1-model` shows `.model.display_name`, or `Claude` when it is absent.
- `line1-ctx` shows a 10-cell bar plus `<used>/<total>`. Used is input + cache_creation + cache_read tokens, formatted `k`/`m`.
- `line1-thinking` shows `thinking: On` (orange) or `thinking: Off` (dim) from `.thinking.enabled`.
- `line1-effort` shows `effort: <level>` only when `.effort.level` is present.
- `line1-empty-stdin` prints just `Claude` and exits 0 on empty stdin.

## How to get to it (user POV)

- Open any Claude Code session with claudefuel installed. Line 1 updates on every refresh.
- Toggle thinking (Option+T) or run `/effort <level>`. The next payload carries the new value.

## Driving it with cf-render

Preconditions:

- `cf-doctor` exits 0.

- **Full payload.** Session on Opus 5.5 with 50k of 200k used, thinking on, effort high. Run `R --label line1-full --profile work`. `run-1.txt` line 1 is `[work] Opus 5.5 | ctx ●●○○○○○○○○ 50k/200k | thinking: On | effort: high`. `run-1.colors.txt` shows `{green}●●` and `thinking: {orange}On`.
- **Minimal payload.** Model without effort support, no context data. Run `R --label line1-minimal --stdin @.claude/skills/verify/fixtures/stdin-minimal.json`. Line 1 is `[verify] Claude | ctx ○○○○○○○○○○ 0/200k | thinking: Off`, with no `effort:` segment.
- **Context near full.** Run `R --label line1-ctx-red --stdin '{"model":{"display_name":"Opus 5.5"},"context_window":{"context_window_size":1000000,"current_usage":{"input_tokens":950000}}}'`. Line 1 shows `950k/1.0m` and `run-1.colors.txt` shows `{red}●●●●●●●●●`.
- **Empty stdin.** Run `R --label line1-empty --stdin ''`. `run-1.txt` is exactly `Claude`, `run-1.exit` is `0`, `net.log` is empty, and `state-after/` holds only the seeded drift cache.
- **Proof.** Cite `stdin.json` and `run-1.txt` for each render.

## Gotchas

- Without `CLAUDE_CONFIG_DIR` there is no `[profile]` tag. cf-render always sets it, so the default-profile look (no tag) can't be rendered through the harness without touching shared caches.
- `context_window_size: 0` falls back to 200k. Assert `0/200k`, not a division error.
- Bar color thresholds come from `build_bar`: green <50, orange 50–69, yellow 70–89, red ≥90. Confirm them in `run-N.colors.txt`, not in plain text.
