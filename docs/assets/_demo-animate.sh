#!/bin/bash
# Drives statusline.sh through a usage progression for the README cast.
# Each frame is printed below the previous one so the viewer sees the
# color progression accumulate on screen. Updates the cache between frames
# so the rate-limit lines move too — without this the bottom two lines stay
# constant and the progression feels inert.

set -e

# Buffer so vhs's `Show` can engage before any visible output. The tape relies
# on this: it `Type`s the command inside `Hide`, sleeps past the initial buffer,
# then `Show`s — the prompt and command line never make it into the recording.
sleep 0.25

# Clear the prompt area so the cast opens on an empty terminal.
printf '\033[H\033[J'

unset CLAUDE_CONFIG_DIR
mkdir -p /tmp/claude

emit_cache() {
  local fh="$1" sd="$2" credits="$3"
  local extra_pct=$(( credits * 100 / 17000 ))
  cat > /tmp/claude/statusline-usage-cache.json <<EOF
{"five_hour":{"utilization":${fh},"resets_at":"2026-05-13T22:00:00Z"},"seven_day":{"utilization":${sd},"resets_at":"2026-05-16T22:00:00Z"},"extra_usage":{"is_enabled":true,"utilization":${extra_pct},"used_credits":${credits},"monthly_limit":17000}}
EOF
}

emit_bar() {
  local tokens="$1"
  printf '%s' "{\"model\":{\"display_name\":\"Claude Sonnet 4.6\"},\"workspace\":{\"current_dir\":\"/Users/me/repo\"},\"session_id\":\"demo\",\"context_window\":{\"context_window_size\":200000,\"current_usage\":{\"input_tokens\":${tokens},\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}" \
    | ./statusline.sh
  # statusline.sh doesn't trail a newline on the resets line — two newlines
  # gives a visible blank gap between frames.
  printf '\n\n'
}

# Each row: input_tokens | five_hour_pct | seven_day_pct | extra_used_credits
# Six frames spanning the four color states: green (<50), orange (50-69),
# yellow (70-89), red (90+). Bottom-line values progress in lockstep.
frames=(
  "8000    6   18   200"
  "55000   28  35   900"
  "105000  52  54   2100"
  "145000  72  68   3400"
  "175000  86  82   5200"
  "192000  96  94   7600"
)

for row in "${frames[@]}"; do
  # shellcheck disable=SC2086
  set -- $row
  emit_cache "$2" "$3" "$4"
  emit_bar "$1"
  sleep 1.5
done

# Hold on the final state so viewers can read all six bars before the gif loops.
sleep 3.0
