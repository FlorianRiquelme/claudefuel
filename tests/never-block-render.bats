#!/usr/bin/env bats

# Tests for the never-block render: cache-first paint + detached one-shot
# background refresh.
#
# Black-box CLI tests: isolate via CLAUDE_CONFIG_DIR, pre-seed caches, feed
# stdin, assert on stdout. Network calls are observed (never performed)
# through a PATH shim that replaces `curl`, logs every invocation, and
# serves a canned response — so these tests also prove which renders make
# zero network calls.
#
# Behavior under test:
#   - Fresh caches: render makes NO curl call at all.
#   - Stale caches: the stale values still paint THIS render; a detached
#     one-shot background fetch refreshes the cache for the NEXT render.
#   - CLAUDEFUEL_OFFLINE=1 suppresses the main usage fetch (regression:
#     previously only prepaid/drift honored it).
#   - First-ever render (no usage cache at all) still fetches synchronously.
#   - CLAUDEFUEL_TIMING=1 emits per-stage timings on stderr, never stdout.

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

  # Credentials file with a far-future expiry so token resolution stays
  # local (no keychain entry exists for the temp dir's hashed service).
  printf '{"claudeAiOauth":{"accessToken":"test-token","refreshToken":"test-refresh","expiresAt":99999999999999}}' \
    > "$CLAUDE_CONFIG_DIR/.credentials.json"

  # Mirror statusline.sh's CACHE_SUFFIX derivation to locate caches.
  config_hash=$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)
  USAGE_CACHE="/tmp/claude/statusline-usage-cache-${config_hash}.json"
  PREPAID_CACHE="/tmp/claude/statusline-prepaid-cache-${config_hash}.json"
  ORG_CACHE="/tmp/claude/statusline-orguuid-cache-${config_hash}"
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
}

teardown() {
  rm -f "$USAGE_CACHE" "$PREPAID_CACHE" "$ORG_CACHE" 2>/dev/null
  [ -n "$SHIM_DIR" ] && [ -d "$SHIM_DIR" ] && rm -rf "$SHIM_DIR"
  [ -n "$CLAUDE_CONFIG_DIR" ] && [ -d "$CLAUDE_CONFIG_DIR" ] && rm -rf "$CLAUDE_CONFIG_DIR"
}

seed_usage_cache() {
  # used_credits>0 keeps the extra column live (calm-cockpit gate) and
  # so also defeats nominal collapse regardless of the 5h/7d pcts here.
  cat > "$USAGE_CACHE" <<'EOF'
{"five_hour":{"utilization":42,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":13,"resets_at":"2099-01-01T00:00:00Z"},"extra_usage":{"is_enabled":true,"used_credits":350}}
EOF
}

seed_prepaid_cache() {
  printf '{"amount":5929,"currency":"EUR"}\n' > "$PREPAID_CACHE"
}

# Age a file past every cache TTL.
make_stale() {
  touch -t 202001010000 "$1"
}

strip_ansi() {
  sed -E $'s/\x1b\\[[0-9;]*m//g'
}

run_bar() {
  printf '%s' "$SAMPLE_STDIN" | PATH="$SHIM_PATH" "$STATUSLINE" | strip_ansi
}

@test "fresh caches: render paints from cache with zero curl invocations" {
  seed_usage_cache
  seed_prepaid_cache

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"42%"* ]]
  [[ "$line2" == *"€59.29"* ]]
  # The shim logs every curl call — the log must not exist.
  [ ! -e "$CURL_LOG" ]
}

@test "stale usage cache still paints this render even when the network fails" {
  seed_usage_cache
  seed_prepaid_cache
  make_stale "$USAGE_CACHE"
  # CURL_RESPONSE_FILE empty: shim exits 7 (network down).

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"42%"* ]]
  [[ "$line2" == *"€59.29"* ]]
}

@test "stale usage cache fires a detached one-shot refresh for the next render" {
  seed_usage_cache
  seed_prepaid_cache
  make_stale "$USAGE_CACHE"
  printf '{"five_hour":{"utilization":77,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":50,"resets_at":"2099-01-01T00:00:00Z"},"extra_usage":{"is_enabled":true}}' \
    > "$CURL_RESPONSE_FILE"

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  # This render painted the stale value...
  [[ "$line2" == *"42%"* ]]

  # ...while the detached fetch lands the fresh payload for the next one.
  for _ in $(seq 1 50); do
    grep -q '"utilization":77' "$USAGE_CACHE" 2>/dev/null && break
    sleep 0.1
  done
  grep -q '"utilization":77' "$USAGE_CACHE"
  grep -q 'api.anthropic.com/api/oauth/usage' "$CURL_LOG"

  # Next render paints the refreshed value — again without waiting.
  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')
  [[ "$line2" == *"77%"* ]]
}

@test "CLAUDEFUEL_OFFLINE=1 suppresses the main usage fetch (stale cache)" {
  seed_usage_cache
  seed_prepaid_cache
  make_stale "$USAGE_CACHE"
  make_stale "$PREPAID_CACHE"

  output=$(printf '%s' "$SAMPLE_STDIN" \
    | CLAUDEFUEL_OFFLINE=1 PATH="$SHIM_PATH" "$STATUSLINE" | strip_ansi)
  line2=$(printf '%s' "$output" | sed -n '2p')

  # Stale values still paint; not a single curl was attempted.
  [[ "$line2" == *"42%"* ]]
  sleep 0.3  # give a (wrongly) fired background fetch time to log itself
  [ ! -e "$CURL_LOG" ]
}

@test "CLAUDEFUEL_OFFLINE=1 suppresses the main usage fetch (no cache at all)" {
  rm -f "$USAGE_CACHE" "$PREPAID_CACHE"

  output=$(printf '%s' "$SAMPLE_STDIN" \
    | CLAUDEFUEL_OFFLINE=1 PATH="$SHIM_PATH" "$STATUSLINE" | strip_ansi)
  line1=$(printf '%s' "$output" | head -n1)

  # Bar still renders line 1; the synchronous first-ever fetch is skipped.
  [[ "$line1" == *"ctx"* ]]
  [ ! -e "$CURL_LOG" ]
}

@test "first-ever render (no usage cache) fetches synchronously" {
  rm -f "$USAGE_CACHE" "$PREPAID_CACHE"
  printf '{"five_hour":{"utilization":61,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":20,"resets_at":"2099-01-01T00:00:00Z"},"extra_usage":{"is_enabled":false}}' \
    > "$CURL_RESPONSE_FILE"

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  # Fresh data renders in the SAME pass — no cache existed to paint from.
  [[ "$line2" == *"61%"* ]]
  grep -q 'api.anthropic.com/api/oauth/usage' "$CURL_LOG"
  grep -q '"utilization":61' "$USAGE_CACHE"
}

@test "CLAUDEFUEL_TIMING=1 emits stage timings on stderr, not stdout" {
  seed_usage_cache
  seed_prepaid_cache

  stderr_file="$SHIM_DIR/stderr"
  output=$(printf '%s' "$SAMPLE_STDIN" \
    | CLAUDEFUEL_TIMING=1 PATH="$SHIM_PATH" "$STATUSLINE" 2>"$stderr_file" | strip_ansi)

  for stage in jq-parse drift usage prepaid render; do
    grep -q "claudefuel-timing: $stage [0-9]*ms" "$stderr_file"
  done
  [[ "$output" != *"claudefuel-timing"* ]]
}
