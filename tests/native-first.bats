#!/usr/bin/env bats

# Tests for native-first data: stdin rate_limits as the source of truth
# for the 5h/7d bars and Line-3 reset times, with the OAuth path demoted
# to enrichment (prepaid extra, fleet sibling caches) and full fallback.
#
# Black-box CLI tests: isolate via CLAUDE_CONFIG_DIR, pre-seed caches,
# feed stdin, assert on stdout. Network calls are observed (never
# performed) through a PATH shim that replaces `curl`.
#
# Behavior under test:
#   - stdin rate_limits + no cache + offline: bars render, no trailhead.
#   - stdin values win over cached OAuth values; no staleness markers
#     attach to stdin-sourced bars (they are per-render fresh).
#   - No synchronous fetch ever happens in stdin mode; the detached
#     enrichment fetch still warms the cache for extra/fleet.
#   - Absent or malformed rate_limits falls back to the OAuth/cache
#     path unchanged.
#   - Derived math (cap-ETA gates, calm collapse, countdown display)
#     works from stdin epochs.

setup() {
  export FORCE_HYPERLINK=0  # hermetic: the host terminal must not toggle OSC 8
  CLAUDE_CONFIG_DIR=$(mktemp -d)
  export CLAUDE_CONFIG_DIR
  mkdir -p "$CLAUDE_CONFIG_DIR/cache"
  STATUSLINE="${BATS_TEST_DIRNAME}/../statusline.sh"

  # Silence drift segment regardless of network: seed cache to match installed.
  installed_version=$(grep -E '^# claudefuel:' "$STATUSLINE" | head -n1 \
    | sed -E 's/^# claudefuel: v//')
  printf '{"upstream_version":"%s"}\n' "$installed_version" \
    > "$CLAUDE_CONFIG_DIR/cache/claudefuel-version.json"

  # Credentials file with a far-future expiry so token resolution stays
  # local (no keychain entry exists for the temp dir's hashed service).
  printf '{"claudeAiOauth":{"accessToken":"test-token","refreshToken":"test-refresh","expiresAt":99999999999999}}' \
    > "$CLAUDE_CONFIG_DIR/.credentials.json"

  # Mirror statusline.sh's CACHE_SUFFIX derivation to locate caches.
  config_hash=$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)
  USAGE_CACHE="/tmp/claude/statusline-usage-cache-${config_hash}.json"
  PREPAID_CACHE="/tmp/claude/statusline-prepaid-cache-${config_hash}.json"
  ORG_CACHE="/tmp/claude/statusline-orguuid-cache-${config_hash}"
  ATTEMPT_FILE="/tmp/claude/statusline-usage-attempt-${config_hash}"
  mkdir -p /tmp/claude

  # PATH shim: every curl invocation is logged; response comes from
  # $CURL_RESPONSE_FILE (empty default = network failure).
  SHIM_DIR=$(mktemp -d)
  export CURL_LOG="$SHIM_DIR/curl.log"
  export CURL_RESPONSE_FILE="$SHIM_DIR/response"
  cat > "$SHIM_DIR/curl" <<'SHIM'
#!/bin/bash
echo "curl $*" >> "$CURL_LOG"
[ -s "$CURL_RESPONSE_FILE" ] && cat "$CURL_RESPONSE_FILE" && exit 0
exit 7
SHIM
  chmod +x "$SHIM_DIR/curl"
  SHIM_PATH="$SHIM_DIR:$PATH"

  NOW=$(date +%s)
}

teardown() {
  rm -f "$USAGE_CACHE" "$PREPAID_CACHE" "$ORG_CACHE" "$ATTEMPT_FILE" 2>/dev/null
  [ -n "$SHIM_DIR" ] && [ -d "$SHIM_DIR" ] && rm -rf "$SHIM_DIR"
  [ -n "$CLAUDE_CONFIG_DIR" ] && [ -d "$CLAUDE_CONFIG_DIR" ] && rm -rf "$CLAUDE_CONFIG_DIR"
}

strip_ansi() {
  sed -E $'s/\x1b\\[[0-9;]*m//g'
}

# stdin with rate_limits. Far-future resets (epoch 4070908800 ≈ 2099)
# keep elapsed negative, so cap-ETA and the burn chip stay dormant and
# plain percentages render deterministically.
# Args: [<5h_pct>=62] [<7d_pct>=31] [<5h_resets>=2099] [<7d_resets>=2099]
stdin_with_rl() {
  local fh_pct=${1:-62} sd_pct=${2:-31}
  local fh_resets=${3:-4070908800} sd_resets=${4:-4070995200}
  printf '{"model":{"display_name":"Claude"},"session_id":"t","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":50000}},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' \
    "$fh_pct" "$fh_resets" "$sd_pct" "$sd_resets"
}

stdin_without_rl() {
  printf '{"model":{"display_name":"Claude"},"session_id":"t","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":50000}}}'
}

# OAuth cache snapshot with values distinct from every stdin fixture, so
# which source painted the bars is unambiguous in the assertions.
seed_usage_cache() {
  cat > "$USAGE_CACHE" <<'EOF'
{"five_hour":{"utilization":42,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":13,"resets_at":"2099-01-02T00:00:00Z"},"extra_usage":{"is_enabled":true,"used_credits":350}}
EOF
}

seed_prepaid_cache() {
  printf '{"amount":5929,"currency":"EUR"}\n' > "$PREPAID_CACHE"
}

# Age a file past every cache TTL.
make_stale() {
  touch -t 202001010000 "$1"
}

@test "stdin rate_limits render bars offline with no cache at all" {
  output=$(stdin_with_rl | CLAUDEFUEL_OFFLINE=1 PATH="$SHIM_PATH" "$STATUSLINE" | strip_ansi)
  line2=$(printf '%s' "$output" | sed -n '2p')
  line3=$(printf '%s' "$output" | sed -n '3p')

  [[ "$line2" == *"5h:"*"62%"* ]]
  [[ "$line2" == *"7d:"*"31%"* ]]
  [[ "$line3" == *"↻"* ]]
  # No failure trailhead: stdin data means the gauge did not fail.
  [[ "$output" != *"/claudefuel.doctor"* ]]
  [ ! -e "$CURL_LOG" ]
}

@test "fractional used_percentage rounds to a whole rendered percent" {
  output=$(stdin_with_rl 62.4 30.6 | CLAUDEFUEL_OFFLINE=1 PATH="$SHIM_PATH" "$STATUSLINE" | strip_ansi)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"62%"* ]]
  [[ "$line2" == *"31%"* ]]
}

@test "stdin values win over a fresh OAuth cache" {
  seed_usage_cache

  output=$(stdin_with_rl | CLAUDEFUEL_OFFLINE=1 PATH="$SHIM_PATH" "$STATUSLINE" | strip_ansi)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"62%"* ]]
  [[ "$line2" == *"31%"* ]]
  [[ "$line2" != *"42%"* ]]
}

@test "no staleness age marker on stdin-sourced bars even when the cache is ancient" {
  seed_usage_cache
  make_stale "$USAGE_CACHE"
  # Attempt marker fresh: no fetch fires, isolating the marker assertion.
  touch "$ATTEMPT_FILE"

  output=$(stdin_with_rl | CLAUDEFUEL_OFFLINE=1 PATH="$SHIM_PATH" "$STATUSLINE" | strip_ansi)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"62%"* ]]
  # Neither the ·age marker nor the severe-staleness warning may attach
  # to bars that are per-render fresh from stdin.
  [[ "$line2" != *"·"* ]]
  [[ "$line2" != *"updates"* ]]
}

@test "stdin mode never fetches synchronously; detached fetch still warms the cache for enrichment" {
  # No cache at all — the OAuth path would fetch synchronously here.
  printf '{"five_hour":{"utilization":77,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":50,"resets_at":"2099-01-02T00:00:00Z"},"extra_usage":{"is_enabled":true,"used_credits":10}}' \
    > "$CURL_RESPONSE_FILE"

  output=$(stdin_with_rl | PATH="$SHIM_PATH" "$STATUSLINE" | strip_ansi)
  line2=$(printf '%s' "$output" | sed -n '2p')

  # This render painted stdin values regardless of the fetch.
  [[ "$line2" == *"62%"* ]]
  [[ "$line2" != *"77%"* ]]

  # The detached one-shot enrichment fetch lands the payload for later
  # renders (extra column, fleet sibling caches).
  for _ in $(seq 1 50); do
    grep -q '"utilization":77' "$USAGE_CACHE" 2>/dev/null && break
    sleep 0.1
  done
  grep -q '"utilization":77' "$USAGE_CACHE"
  grep -q 'api.anthropic.com/api/oauth/usage' "$CURL_LOG"
}

@test "prepaid extra column unaffected: renders from OAuth caches alongside stdin bars" {
  seed_usage_cache
  seed_prepaid_cache

  output=$(stdin_with_rl | CLAUDEFUEL_OFFLINE=1 PATH="$SHIM_PATH" "$STATUSLINE" | strip_ansi)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"62%"* ]]
  [[ "$line2" == *"extra:"*"€59.29"* ]]
}

@test "absent rate_limits falls back to the OAuth cache path unchanged" {
  seed_usage_cache
  seed_prepaid_cache

  output=$(stdin_without_rl | CLAUDEFUEL_OFFLINE=1 PATH="$SHIM_PATH" "$STATUSLINE" | strip_ansi)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"42%"* ]]
  [[ "$line2" == *"13%"* ]]
}

@test "malformed used_percentage falls back to the OAuth cache path" {
  seed_usage_cache
  seed_prepaid_cache  # extra column defeats the calm-cockpit collapse
  printf '{"model":{"display_name":"Claude"},"session_id":"t","rate_limits":{"five_hour":{"used_percentage":"not-a-number","resets_at":4070908800},"seven_day":{"used_percentage":31,"resets_at":4070995200}}}' \
    > "$SHIM_DIR/stdin.json"

  output=$(PATH="$SHIM_PATH" CLAUDEFUEL_OFFLINE=1 "$STATUSLINE" < "$SHIM_DIR/stdin.json" | strip_ansi)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"42%"* ]]
}

@test "rate_limits missing one window falls back entirely (never a half-stdin render)" {
  seed_usage_cache
  seed_prepaid_cache  # extra column defeats the calm-cockpit collapse
  printf '{"model":{"display_name":"Claude"},"session_id":"t","rate_limits":{"five_hour":{"used_percentage":62,"resets_at":4070908800}}}' \
    > "$SHIM_DIR/stdin.json"

  output=$(PATH="$SHIM_PATH" CLAUDEFUEL_OFFLINE=1 "$STATUSLINE" < "$SHIM_DIR/stdin.json" | strip_ansi)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"42%"* ]]
  [[ "$line2" != *"62%"* ]]
}

@test "countdown display works from stdin reset epochs" {
  printf '{"version":1,"reset_display":"countdown"}\n' \
    > "$CLAUDE_CONFIG_DIR/claudefuel.json"

  output=$(stdin_with_rl 62 31 $((NOW + 7100)) $((NOW + 400000)) \
    | CLAUDEFUEL_OFFLINE=1 PATH="$SHIM_PATH" "$STATUSLINE" | strip_ansi)
  line3=$(printf '%s' "$output" | sed -n '3p')

  [[ "$line3" == *"↻ in 1h"* ]]
  [[ "$line3" == *"↻ in 4d"* ]]
}

@test "cap-ETA and governing marker fire from stdin epochs when burning hot" {
  # 5h window: 50% used, started 2h ago, 3h to reset — burn rate 25%/h
  # beats reset-pace 20%/h, so cap-ETA and the ▸ marker must fire.
  output=$(stdin_with_rl 50 12 $((NOW + 10800)) $((NOW + 500000)) \
    | CLAUDEFUEL_OFFLINE=1 PATH="$SHIM_PATH" "$STATUSLINE" | strip_ansi)
  line2=$(printf '%s' "$output" | sed -n '2p')
  line3=$(printf '%s' "$output" | sed -n '3p')

  [[ "$line2" == *"▸5h:"* ]]
  [[ "$line3" == *"~cap"* ]]
}

@test "calm-cockpit collapse works from stdin values (nominal windows hide lines 2-3)" {
  output=$(stdin_with_rl 5 12 | CLAUDEFUEL_OFFLINE=1 PATH="$SHIM_PATH" "$STATUSLINE" | strip_ansi)

  [[ "$output" == *"ctx"* ]]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
}
