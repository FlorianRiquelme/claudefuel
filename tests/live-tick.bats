#!/usr/bin/env bats

# Tests for the live tick: statusLine.refreshInterval re-runs the bar on
# a timer, so time-based cells (countdowns, cap-ETA) must visibly move
# and the render must stay instant under timer-frequency invocation.
#
# The determinism seam is CLAUDEFUEL_NOW=<epoch>: it freezes "now" for
# every time-derived value, so a tick can be simulated by advancing the
# injected clock instead of sleeping.

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

  printf '{"claudeAiOauth":{"accessToken":"test-token","refreshToken":"test-refresh","expiresAt":99999999999999}}' \
    > "$CLAUDE_CONFIG_DIR/.credentials.json"

  config_hash=$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)
  USAGE_CACHE="/tmp/claude/statusline-usage-cache-${config_hash}.json"
  PREPAID_CACHE="/tmp/claude/statusline-prepaid-cache-${config_hash}.json"
  ORG_CACHE="/tmp/claude/statusline-orguuid-cache-${config_hash}"
  ATTEMPT_FILE="/tmp/claude/statusline-usage-attempt-${config_hash}"
  PREPAID_ATTEMPT_FILE="/tmp/claude/statusline-prepaid-attempt-${config_hash}"
  mkdir -p /tmp/claude

  # PATH shim: logs every curl call; optional CURL_SLEEP simulates a slow
  # in-flight fetch; response comes from $CURL_RESPONSE_FILE.
  SHIM_DIR=$(mktemp -d)
  export CURL_LOG="$SHIM_DIR/curl.log"
  export CURL_RESPONSE_FILE="$SHIM_DIR/response"
  cat > "$SHIM_DIR/curl" <<'SHIM'
#!/bin/bash
echo "curl $*" >> "$CURL_LOG"
[ -n "$CURL_SLEEP" ] && sleep "$CURL_SLEEP"
[ -s "$CURL_RESPONSE_FILE" ] && cat "$CURL_RESPONSE_FILE" && exit 0
exit 7
SHIM
  chmod +x "$SHIM_DIR/curl"
  SHIM_PATH="$SHIM_DIR:$PATH"

  NOW=1751500000
}

teardown() {
  rm -f "$USAGE_CACHE" "$PREPAID_CACHE" "$ORG_CACHE" \
    "$ATTEMPT_FILE" "$PREPAID_ATTEMPT_FILE" 2>/dev/null
  [ -n "$SHIM_DIR" ] && [ -d "$SHIM_DIR" ] && rm -rf "$SHIM_DIR"
  [ -n "$CLAUDE_CONFIG_DIR" ] && [ -d "$CLAUDE_CONFIG_DIR" ] && rm -rf "$CLAUDE_CONFIG_DIR"
}

strip_ansi() {
  sed -E $'s/\x1b\\[[0-9;]*m//g'
}

# stdin with rate_limits pinned to the frozen clock: 5h resets in exactly
# 1h, 7d in ~4.6d. 62%/31% keeps lines 2-3 visible (no calm collapse);
# 62% over 4h elapsed is below reset-pace, so the burn chip stays dormant.
stdin_with_rl() {
  printf '{"model":{"display_name":"Claude"},"session_id":"t","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":50000}},"rate_limits":{"five_hour":{"used_percentage":62,"resets_at":%s},"seven_day":{"used_percentage":31,"resets_at":%s}}}' \
    "$((NOW + 3600))" "$((NOW + 400000))"
}

stdin_without_rl() {
  printf '{"model":{"display_name":"Claude"},"session_id":"t","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":50000}}}'
}

seed_usage_cache() {
  cat > "$USAGE_CACHE" <<'EOF'
{"five_hour":{"utilization":42,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":13,"resets_at":"2099-01-02T00:00:00Z"},"extra_usage":{"is_enabled":true,"used_credits":350}}
EOF
}

seed_prepaid_cache() {
  printf '{"amount":5929,"currency":"EUR"}\n' > "$PREPAID_CACHE"
}

make_stale() {
  touch -t 202001010000 "$1"
}

@test "countdown moves between two renders one tick apart" {
  printf '{"version":1,"reset_display":"countdown"}\n' \
    > "$CLAUDE_CONFIG_DIR/claudefuel.json"

  line3_t0=$(stdin_with_rl | CLAUDEFUEL_OFFLINE=1 CLAUDEFUEL_NOW=$NOW \
    PATH="$SHIM_PATH" "$STATUSLINE" | strip_ansi | sed -n '3p')
  line3_t1=$(stdin_with_rl | CLAUDEFUEL_OFFLINE=1 CLAUDEFUEL_NOW=$((NOW + 1)) \
    PATH="$SHIM_PATH" "$STATUSLINE" | strip_ansi | sed -n '3p')

  [[ "$line3_t0" == *"↻ in 1h00m"* ]]
  [[ "$line3_t1" == *"↻ in 59m"* ]]
  [ "$line3_t0" != "$line3_t1" ]
}

@test "frozen clock renders byte-identical output — the tick is clock-driven only" {
  printf '{"version":1,"reset_display":"countdown"}\n' \
    > "$CLAUDE_CONFIG_DIR/claudefuel.json"

  out1=$(stdin_with_rl | CLAUDEFUEL_OFFLINE=1 CLAUDEFUEL_NOW=$NOW \
    PATH="$SHIM_PATH" "$STATUSLINE")
  out2=$(stdin_with_rl | CLAUDEFUEL_OFFLINE=1 CLAUDEFUEL_NOW=$NOW \
    PATH="$SHIM_PATH" "$STATUSLINE")

  [ "$out1" = "$out2" ]
}

@test "render during an in-flight background refresh returns instantly from cache" {
  seed_usage_cache
  seed_prepaid_cache
  make_stale "$USAGE_CACHE"
  export CURL_SLEEP=3

  # Render 1 claims the refresh and fires the detached slow fetch.
  out1=$(stdin_without_rl | PATH="$SHIM_PATH" "$STATUSLINE" | strip_ansi)
  [[ "$out1" == *"42%"* ]]

  # Render 2 arrives at timer frequency while that fetch is still in
  # flight — it must paint the stale cache instantly, not wait.
  t_start=$(jq -n 'now*1000|floor')
  out2=$(stdin_without_rl | PATH="$SHIM_PATH" "$STATUSLINE" | strip_ansi)
  t_end=$(jq -n 'now*1000|floor')

  [[ "$out2" == *"42%"* ]]
  [ $(( t_end - t_start )) -lt 2000 ]

  # Let the detached child finish before teardown removes its files.
  sleep 3.5
}

@test "timer-frequency renders never stampede the API — one usage attempt per cadence" {
  seed_usage_cache
  seed_prepaid_cache
  make_stale "$USAGE_CACHE"

  for _ in 1 2 3 4 5; do
    out=$(stdin_without_rl | PATH="$SHIM_PATH" "$STATUSLINE" | strip_ansi)
    [[ "$out" == *"42%"* ]]
  done

  # Give the single detached fetch time to log.
  sleep 0.5
  usage_calls=$(grep -c 'api.anthropic.com/api/oauth/usage' "$CURL_LOG" 2>/dev/null || echo 0)
  [ "$usage_calls" -le 1 ]
}

@test "INSTALL.md pins statusLine.refreshInterval in desired state and patch step" {
  INSTALL="${BATS_TEST_DIRNAME}/../INSTALL.md"
  grep -q '"refreshInterval": 2' "$INSTALL"
  grep -q 'refreshInterval: 2' "$INSTALL"
  grep -q '.statusLine.refreshInterval == 2' "$INSTALL"
}
