#!/usr/bin/env bats

# Tests for the end-of-window projection: `→N%` next to the 5h value —
# where the window lands at reset if the current average pace holds
# (pct × window / elapsed). Stateless (ADR-0004), the complement of the
# burn chip: it renders exactly when the chip is dormant (ratio ≤ 1) and
# the projected landing crosses the yellow severity threshold.

setup() {
  CLAUDE_CONFIG_DIR=$(mktemp -d)
  export CLAUDE_CONFIG_DIR
  mkdir -p "$CLAUDE_CONFIG_DIR/cache"
  STATUSLINE="${BATS_TEST_DIRNAME}/../statusline.sh"

  installed_version=$(grep -E '^# claudefuel:' "$STATUSLINE" | head -n1 \
    | sed -E 's/^# claudefuel: v//')
  printf '{"upstream_version":"%s"}\n' "$installed_version" \
    > "$CLAUDE_CONFIG_DIR/cache/claudefuel-version.json"

  NOW=1751500000
}

teardown() {
  [ -n "$CLAUDE_CONFIG_DIR" ] && [ -d "$CLAUDE_CONFIG_DIR" ] && rm -rf "$CLAUDE_CONFIG_DIR"
}

strip_ansi() {
  sed -E $'s/\x1b\\[[0-9;]*m//g'
}

# Render line 2 from a stdin rate_limits snapshot with a frozen clock.
# Usage: line2_for <5h_pct> <5h_remaining_seconds>
line2_for() {
  local pct=$1 remaining=$2
  printf '{"model":{"display_name":"Claude"},"session_id":"t","rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":31,"resets_at":%s}}}' \
      "$pct" "$(( NOW + remaining ))" "$(( NOW + 400000 ))" \
    | CLAUDEFUEL_OFFLINE=1 CLAUDEFUEL_NOW=$NOW "$STATUSLINE" \
    | strip_ansi | sed -n '2p'
}

@test "projection renders where the window lands at reset (62% at 3.5h elapsed → →88%)" {
  # elapsed 12600s, 62 × 18000 / 12600 = 88.57 → →88%
  line2=$(line2_for 62 5400)
  [[ "$line2" == *"62% →88%"* ]]
}

@test "projection dormant below the yellow threshold landing" {
  # 30% at 2.5h elapsed → lands at 60, under yellow 70 → dormant.
  # (extra spend keeps lines 2-3 from calm-collapsing)
  usage_hash=$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)
  printf '{"extra_usage":{"is_enabled":true,"used_credits":10}}' \
    > "/tmp/claude/statusline-usage-cache-${usage_hash}.json"
  printf '{"amount":100,"currency":"USD"}' \
    > "/tmp/claude/statusline-prepaid-cache-${usage_hash}.json"

  line2=$(line2_for 30 9000)
  [[ "$line2" == *"30%"* ]]
  [[ "$line2" != *"→"* ]]

  rm -f "/tmp/claude/statusline-usage-cache-${usage_hash}.json" \
    "/tmp/claude/statusline-prepaid-cache-${usage_hash}.json"
}

@test "projection dormant when burning hot — the burn chip owns that story" {
  # 50% at 2h elapsed (ratio 1.25): burn chip fires, no →.
  line2=$(line2_for 50 10800)
  [[ "$line2" == *"×1.2"* ]]
  [[ "$line2" != *"→"* ]]
}

@test "projection respects the noise floor (pct < 10)" {
  # 8% at 4.9h elapsed would project ~8.2 anyway, but even a hot young
  # window must stay quiet below 10% used.
  line2=$(line2_for 8 300)
  [[ "$line2" != *"→"* ]]
}

@test "projection threshold follows the configured severity ladder" {
  # Landing 88 with a calmer ladder (yellow at 90) → dormant.
  printf '{"version":1,"color_thresholds":{"orange":70,"yellow":90,"red":95}}' \
    > "$CLAUDE_CONFIG_DIR/claudefuel.json"
  line2=$(line2_for 62 5400)
  [[ "$line2" == *"62%"* ]]
  [[ "$line2" != *"→"* ]]
}

@test "projection hide-only token works and is registered in validate-config" {
  printf '{"version":1,"segments":{"hide":["projection"]}}' \
    > "$CLAUDE_CONFIG_DIR/claudefuel.json"
  line2=$(line2_for 62 5400)
  [[ "$line2" == *"62%"* ]]
  [[ "$line2" != *"→"* ]]

  run "$STATUSLINE" --validate-config "$CLAUDE_CONFIG_DIR/claudefuel.json"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "ok" ]
}

@test "line 2/3 column pipes stay aligned when the projection widens the 5h cell" {
  out=$(printf '{"model":{"display_name":"Claude"},"session_id":"t","rate_limits":{"five_hour":{"used_percentage":62,"resets_at":%s},"seven_day":{"used_percentage":31,"resets_at":%s}}}' \
      "$(( NOW + 5400 ))" "$(( NOW + 400000 ))" \
    | CLAUDEFUEL_OFFLINE=1 CLAUDEFUEL_NOW=$NOW "$STATUSLINE" | strip_ansi)
  line2=$(printf '%s' "$out" | sed -n '2p')
  line3=$(printf '%s' "$out" | sed -n '3p')

  # Character-aware measurement (the bar glyphs are multibyte).
  pipe2=$(printf '%s' "${line2%%|*}" | wc -m | tr -d ' ')
  pipe3=$(printf '%s' "${line3%%|*}" | wc -m | tr -d ' ')
  [ "$pipe2" = "$pipe3" ]
}

@test "--snapshot derives projected_pct_at_reset" {
  config_hash=$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)
  USAGE_CACHE="/tmp/claude/statusline-usage-cache-${config_hash}.json"
  mkdir -p /tmp/claude
  reset_iso=$(date -u -r "$(( $(date +%s) + 5400 ))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "@$(( $(date +%s) + 5400 ))" +"%Y-%m-%dT%H:%M:%SZ")
  printf '{"five_hour":{"utilization":62,"resets_at":"%s"},"seven_day":{"utilization":31,"resets_at":"2099-01-01T00:00:00Z"}}' \
    "$reset_iso" > "$USAGE_CACHE"

  snap=$("$STATUSLINE" --snapshot)
  proj=$(echo "$snap" | jq -r '.derived.five_hour.projected_pct_at_reset')
  [ "$proj" -ge 87 ] && [ "$proj" -le 89 ]

  rm -f "$USAGE_CACHE"
}
