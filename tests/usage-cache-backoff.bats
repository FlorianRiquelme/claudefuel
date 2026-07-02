#!/usr/bin/env bats

# Tests for usage-cache retry backoff and the stale-data warning.
#
# Regression: a failed usage fetch (e.g. the API rate-limiting the
# account) never aged the cache file's mtime, so `cache_age` stayed
# >= cache_max_age forever and every render retried the request with
# no backoff — able to sustain a rate limit indefinitely while silently
# showing stale numbers the user could mistake for current.
#
# Fix: a separate attempt-marker file gates retries independent of
# success, and a stale-data warning renders whenever displayed usage
# data is older than 3x the normal refresh cadence.

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

  # Mirror statusline.sh's CACHE_SUFFIX derivation to locate caches.
  config_hash=$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)
  USAGE_CACHE="/tmp/claude/statusline-usage-cache-${config_hash}.json"
  ATTEMPT_FILE="/tmp/claude/statusline-usage-attempt-${config_hash}"
  RETRYAFTER_FILE="/tmp/claude/statusline-usage-retryafter-${config_hash}"
  mkdir -p /tmp/claude

  # Fake curl: counts invocations and emits a configurable HTTP response so
  # tests can assert on retry/backoff behavior without touching the network.
  # Defaults to a 429 with a long retry-after (the rate-limit case). Tests
  # override via FAKE_HTTP_STATUS / FAKE_RETRY_AFTER / FAKE_BODY. Writes the
  # status line + retry-after header to curl's -D dump file, mirroring how
  # statusline.sh captures them.
  FAKE_BIN=$(mktemp -d)
  CURL_CALLS_FILE="$FAKE_BIN/curl-calls"
  : > "$CURL_CALLS_FILE"
  export CURL_CALLS_FILE
  cat > "$FAKE_BIN/curl" <<'EOF'
#!/bin/bash
echo x >> "$CURL_CALLS_FILE"
dfile=""; prev=""
for a in "$@"; do
  [ "$prev" = "-D" ] && dfile="$a"
  prev="$a"
done
status="${FAKE_HTTP_STATUS:-429}"
retry="${FAKE_RETRY_AFTER:-2378}"
if [ -n "$dfile" ]; then
  {
    echo "HTTP/2 $status "
    [ "$status" = "429" ] && [ -n "$retry" ] && echo "retry-after: $retry"
    echo ""
  } > "$dfile"
fi
printf '%s' "${FAKE_BODY-{\"error\":{\"type\":\"rate_limit_error\"}}}"
EOF
  chmod +x "$FAKE_BIN/curl"
  PATH="$FAKE_BIN:$PATH"
  export PATH

  # export, not a prefix: a `VAR=val cmd1 | cmd2` prefix only applies to
  # cmd1, but the script that needs these is cmd2 ("$STATUSLINE").
  export CLAUDE_CODE_OAUTH_TOKEN=bogus-token
  export CLAUDEFUEL_OFFLINE=1
}

teardown() {
  rm -f "$USAGE_CACHE" "$ATTEMPT_FILE" "$RETRYAFTER_FILE" 2>/dev/null
  unset FAKE_HTTP_STATUS FAKE_RETRY_AFTER FAKE_BODY
  [ -n "$CLAUDE_CONFIG_DIR" ] && [ -d "$CLAUDE_CONFIG_DIR" ] && rm -rf "$CLAUDE_CONFIG_DIR"
  [ -n "$FAKE_BIN" ] && [ -d "$FAKE_BIN" ] && rm -rf "$FAKE_BIN"
}

# Seed usage cache and back-date its mtime so it reads as stale.
# Args: <age_seconds>
seed_stale_usage_cache() {
  local age=$1
  cat > "$USAGE_CACHE" <<'EOF'
{
  "five_hour":   { "utilization": 0, "resets_at": "2099-01-01T00:00:00Z" },
  "seven_day":   { "utilization": 87, "resets_at": "2099-01-01T00:00:00Z" }
}
EOF
  local past=$(( $(date +%s) - age ))
  touch -t "$(date -r "$past" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$past" +%Y%m%d%H%M.%S)" "$USAGE_CACHE"
}

strip_ansi() {
  sed -E $'s/\x1b\\[[0-9;]*m//g'
}

run_bar() {
  printf '%s' "$SAMPLE_STDIN" | "$STATUSLINE" | strip_ansi
}

# Back-date a file's mtime so time-based gates read as elapsed.
# Args: <file> <age_seconds>
age_file() {
  local past=$(( $(date +%s) - $2 ))
  touch -t "$(date -r "$past" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$past" +%Y%m%d%H%M.%S)" "$1"
}

@test "failed fetch falls back to stale cache instead of blanking the bars" {
  seed_stale_usage_cache 300

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"87%"* ]]
}

@test "failed fetch touches the attempt marker so a retry isn't immediate" {
  seed_stale_usage_cache 300

  run_bar >/dev/null
  [ -f "$ATTEMPT_FILE" ]
}

@test "second render within backoff window does not retry the network fetch" {
  seed_stale_usage_cache 300

  run_bar >/dev/null
  run_bar >/dev/null

  calls=$(wc -l < "$CURL_CALLS_FILE" | tr -d ' ')
  [ "$calls" -eq 1 ]
}

@test "data older than the stale threshold warns when usage next updates" {
  seed_stale_usage_cache 300

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"updates"* ]]
}

@test "a 429 cooldown surfaces the retry time, not the data age" {
  # The warning should tell the user WHEN usage can update again (the
  # Retry-After deadline as a clock time), not how old the data is.
  export FAKE_HTTP_STATUS=429 FAKE_RETRY_AFTER=600
  seed_stale_usage_cache 300

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"updates ~"* ]]            # shows a time, e.g. "updates ~5:53pm"
  [[ "$line2" =~ (am|pm) ]]                  # clock time, not a duration
  [[ "$line2" != *"stale"* ]]                # no bare-age wording
}

@test "data within the stale threshold does not render a warning" {
  # Cache is old enough to need a refresh (>60s) but not stale enough (<180s)
  # to warrant a warning — a failed fetch here is a one-off blip, not sustained.
  seed_stale_usage_cache 90

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" != *"updates"* ]]
}

@test "fresh cache (within cache_max_age) never attempts a network fetch" {
  seed_stale_usage_cache 10

  run_bar >/dev/null

  [ ! -s "$CURL_CALLS_FILE" ]
}

@test "second render during backoff still renders the bars (no blanking)" {
  # Regression: the stale-cache fallback used to live inside the
  # should_attempt block, so once backoff kicked in the bars vanished
  # entirely on every subsequent render.
  seed_stale_usage_cache 300

  run_bar >/dev/null
  second=$(run_bar)
  line2=$(printf '%s' "$second" | sed -n '2p')

  [[ "$line2" == *"87%"* ]]
}

@test "a 429 retry-after suppresses fetches past the normal 60s cadence" {
  # The server asked for a long cooldown. Even after the 60s attempt
  # window elapses, we must not poke the endpoint again until the
  # retry-after deadline passes — otherwise we keep the rate limit alive.
  export FAKE_HTTP_STATUS=429 FAKE_RETRY_AFTER=600
  seed_stale_usage_cache 300

  run_bar >/dev/null                 # attempt 1: gets 429, records deadline
  [ -f "$RETRYAFTER_FILE" ]
  age_file "$ATTEMPT_FILE" 120       # 60s attempt gate is now open again
  run_bar >/dev/null                 # but retry-after deadline still blocks

  calls=$(wc -l < "$CURL_CALLS_FILE" | tr -d ' ')
  [ "$calls" -eq 1 ]
}

@test "a non-429 blip retries after the normal 60s cadence" {
  # A transient network failure is not a rate limit: no retry-after
  # deadline is recorded, so once the 60s attempt window elapses we retry.
  export FAKE_HTTP_STATUS=000 FAKE_BODY=
  seed_stale_usage_cache 300

  run_bar >/dev/null                 # attempt 1: empty response, no deadline
  [ ! -f "$RETRYAFTER_FILE" ]
  age_file "$ATTEMPT_FILE" 120       # 60s window elapsed
  run_bar >/dev/null                 # should retry

  calls=$(wc -l < "$CURL_CALLS_FILE" | tr -d ' ')
  [ "$calls" -eq 2 ]
}
