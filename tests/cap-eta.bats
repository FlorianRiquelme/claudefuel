#!/usr/bin/env bats

# Tests for cap-ETA segment in statusline.sh.
#
# Black-box CLI tests: isolate via CLAUDE_CONFIG_DIR, pre-seed the usage
# cache so the script never touches OAuth or the network, feed stdin,
# assert on stdout.
#
# Domain (see CONTEXT.md):
#   burn rate   — pct_used / time_elapsed_in_window (snapshot-derived)
#   reset-pace  — 100% / window_length
#   cap-ETA     — predicted wall-clock 100% time, rendered as a range
#                 next to `↻ <time>` on Line 3, only when burn rate
#                 exceeds reset-pace AND pct_used >= 10%.

SAMPLE_STDIN='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp"},"session_id":"t"}'

setup() {
  CLAUDE_CONFIG_DIR=$(mktemp -d)
  export CLAUDE_CONFIG_DIR
  mkdir -p "$CLAUDE_CONFIG_DIR/cache"
  STATUSLINE="${BATS_TEST_DIRNAME}/../statusline.sh"

  # Silence drift segment regardless of network: seed cache to match installed.
  installed_version=$(grep -E '^# claudefuel:' "$STATUSLINE" | head -n1 \
    | sed -E 's/^# claudefuel: v//')
  printf '{"upstream_version":"%s"}\n' "$installed_version" \
    > "$CLAUDE_CONFIG_DIR/cache/claudefuel-version.json"

  # Mirror statusline.sh's CACHE_SUFFIX derivation to locate the usage cache.
  config_hash=$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)
  USAGE_CACHE="/tmp/claude/statusline-usage-cache-${config_hash}.json"
  mkdir -p /tmp/claude
}

teardown() {
  [ -n "$USAGE_CACHE" ] && [ -f "$USAGE_CACHE" ] && rm -f "$USAGE_CACHE"
  [ -n "$CLAUDE_CONFIG_DIR" ] && [ -d "$CLAUDE_CONFIG_DIR" ] && rm -rf "$CLAUDE_CONFIG_DIR"
}

# Cross-platform ISO timestamp from an epoch.
iso_from_epoch() {
  local epoch=$1
  date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ"
}

# Seed usage cache with a 5h-window snapshot relative to "now".
# Args: <5h_pct> <5h_elapsed_seconds> <5h_remaining_seconds>
#       [<7d_pct>=12] [<7d_remaining_seconds>=432000]
seed_usage_cache() {
  local fh_pct=$1 fh_elapsed=$2 fh_remaining=$3
  local sd_pct=${4:-12} sd_remaining=${5:-432000}
  local now fh_resets sd_resets
  now=$(date +%s)
  fh_resets=$(( now + fh_remaining ))
  sd_resets=$(( now + sd_remaining ))
  local fh_iso sd_iso
  fh_iso=$(iso_from_epoch "$fh_resets")
  sd_iso=$(iso_from_epoch "$sd_resets")

  cat > "$USAGE_CACHE" <<EOF
{
  "five_hour":   { "utilization": $fh_pct, "resets_at": "$fh_iso" },
  "seven_day":   { "utilization": $sd_pct, "resets_at": "$sd_iso" },
  "extra_usage": { "is_enabled": false }
}
EOF
  touch "$USAGE_CACHE"
  # Touch ensures mtime is "now" so statusline.sh treats the cache as fresh.
}

run_bar() {
  CLAUDEFUEL_OFFLINE=1 printf '%s' "$SAMPLE_STDIN" | "$STATUSLINE"
}

@test "tracer: burning hot — cap-ETA range appears on line 3" {
  # 50% used, window started 2h ago, 3h until reset.
  # Burn rate = 25%/h; reset-pace = 20%/h. Cap-ETA at ~2h from now,
  # well before the 3h reset. Gate passes (50% >= 10%).
  seed_usage_cache 50 7200 10800

  output=$(run_bar)
  line3=$(printf '%s' "$output" | sed -n '3p')

  [[ "$line3" == *"~cap"* ]]
}

@test "reset text remains when cap-ETA is appended (never replaces)" {
  # Burning hot — same as tracer scenario. The cap-ETA annotation must
  # sit alongside `↻ <time>`, never replace it. The reset is the
  # authoritative wall-clock anchor; cap-ETA is the rough overlay.
  seed_usage_cache 50 7200 10800

  output=$(run_bar)
  line3=$(printf '%s' "$output" | sed -n '3p')

  [[ "$line3" == *"↻"* ]]
  [[ "$line3" == *"~cap"* ]]
}

@test "noise gate: cap-ETA hidden when pct_used < 10% even if rate projects an early cap" {
  # 8% used after only 5min in the window. Rate = ~96%/h would project
  # a cap in ~1h, well before the ~5h reset (threshold would trip). But
  # a single heavy prompt dominates the rate this early — gate must hide.
  seed_usage_cache 8 300 17700

  output=$(run_bar)
  line3=$(printf '%s' "$output" | sed -n '3p')

  [[ "$line3" != *"~cap"* ]]
}

@test "5h-only scope: cap-ETA never attaches to the 7d cell, even when 7d burning hot" {
  # 5h: burning hot (50% halfway in) — cap-ETA expected in col1.
  # 7d: 80% used, 1 day until reset — also "burning," but the 7d
  # cell must NOT carry a ~cap. Cap-ETA is 5h-only per ADR-0004.
  seed_usage_cache 50 7200 10800 80 86400

  output=$(run_bar)
  line3=$(printf '%s' "$output" | sed -n '3p')
  plain=$(printf '%s' "$line3" | sed 's/\x1b\[[0-9;]*m//g')
  col1=$(printf '%s' "$plain" | awk -F'|' '{print $1}')
  col2=$(printf '%s' "$plain" | awk -F'|' '{print $2}')

  [[ "$col1" == *"~cap"* ]]
  [[ "$col2" != *"~cap"* ]]
}

@test "cap-ETA segment does not grow bar height (still ≤3 lines)" {
  # Same burning-hot fixture as the tracer. The cap-ETA annotation is
  # an inline append to col1_reset on Line 3 — it must not introduce
  # a fourth output line.
  seed_usage_cache 50 7200 10800

  output=$(run_bar)
  line_count=$(printf '%s' "$output" | wc -l | tr -d ' ')
  # printf doesn't append final newline; 3 lines of content → 2 newlines.
  [ "$line_count" -le 2 ]
}

@test "healthy: cap-ETA hidden when burn rate is below reset-pace" {
  # 10% used, window started 2h ago, 3h until reset.
  # Burn rate = 5%/h; reset-pace = 20%/h. Cap-ETA projects to ~18h
  # from now, far beyond the 3h reset — not actionable, must hide.
  seed_usage_cache 10 7200 10800

  output=$(run_bar)
  line3=$(printf '%s' "$output" | sed -n '3p')

  [[ "$line3" != *"~cap"* ]]
}
