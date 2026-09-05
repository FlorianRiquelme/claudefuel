#!/usr/bin/env bats

# Tests for prepaid-fetch backoff.
#
# Regression: the prepaid credit fetch wrote its cache only on success and had
# no attempt throttle or Retry-After handling, so a failing fetch (e.g. the API
# rate-limiting the account) re-fired on *every* render — stampeding
# api.anthropic.com and keeping the whole account rate-limited, which also 429s
# the usage endpoint (same host).
#
# Fix: throttle prepaid attempts with an attempt marker, honor the shared
# Retry-After cooldown that either fetch may set, and record a prepaid 429 into
# that shared cooldown so the usage fetch backs off too.

SAMPLE_STDIN='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp"},"session_id":"t"}'

setup() {
  export FORCE_HYPERLINK=0  # hermetic: the host terminal must not toggle OSC 8
  CLAUDE_CONFIG_DIR=$(mktemp -d)
  export CLAUDE_CONFIG_DIR
  mkdir -p "$CLAUDE_CONFIG_DIR/cache"
  STATUSLINE="${BATS_TEST_DIRNAME}/../statusline.sh"

  installed_version=$(grep -E '^# claudefuel:' "$STATUSLINE" | head -n1 | sed -E 's/^# claudefuel: v//')
  printf '{"upstream_version":"%s"}\n' "$installed_version" \
    > "$CLAUDE_CONFIG_DIR/cache/claudefuel-version.json"

  USAGE_CACHE="$CLAUDE_CONFIG_DIR/cache/claudefuel-usage.json"
  PREPAID_CACHE="$CLAUDE_CONFIG_DIR/cache/claudefuel-prepaid.json"
  PREPAID_ATTEMPT="$CLAUDE_CONFIG_DIR/cache/claudefuel-prepaid.attempt"
  ORG_CACHE="$CLAUDE_CONFIG_DIR/cache/claudefuel-org-uuid"
  RETRYAFTER_FILE="$CLAUDE_CONFIG_DIR/cache/claudefuel-retry-after"

  # Fresh usage cache so the usage fetch is skipped — isolates the prepaid path.
  cat > "$USAGE_CACHE" <<'EOF'
{"five_hour":{"utilization":5,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":5,"resets_at":"2099-01-01T00:00:00Z"},"extra_usage":{"is_enabled":true}}
EOF
  touch "$USAGE_CACHE"
  # Org UUID cached so only /prepaid/credits is fetched (not /account).
  printf 'org-1234\n' > "$ORG_CACHE"

  # Fake curl: logs each requested URL and emits a 429 with a retry-after.
  FAKE_BIN=$(mktemp -d)
  CURL_LOG="$FAKE_BIN/curl-log"
  : > "$CURL_LOG"
  export CURL_LOG
  cat > "$FAKE_BIN/curl" <<'EOF'
#!/bin/bash
url="${@: -1}"
echo "$url" >> "$CURL_LOG"
dfile=""; prev=""
for a in "$@"; do [ "$prev" = "-D" ] && dfile="$a"; prev="$a"; done
[ -n "$dfile" ] && printf 'HTTP/2 429 \nretry-after: 600\n\n' > "$dfile"
printf '%s' '{"error":{"type":"rate_limit_error"}}'
EOF
  chmod +x "$FAKE_BIN/curl"
  PATH="$FAKE_BIN:$PATH"; export PATH

  export CLAUDE_CODE_OAUTH_TOKEN=bogus-token
  unset CLAUDEFUEL_OFFLINE
}

teardown() {
  [ -n "$CLAUDE_CONFIG_DIR" ] && [ -d "$CLAUDE_CONFIG_DIR" ] && rm -rf "$CLAUDE_CONFIG_DIR"
  [ -n "$FAKE_BIN" ] && [ -d "$FAKE_BIN" ] && rm -rf "$FAKE_BIN"
}

run_bar() { printf '%s' "$SAMPLE_STDIN" | "$STATUSLINE" >/dev/null; }
prepaid_calls() { grep -c 'prepaid/credits' "$CURL_LOG" 2>/dev/null | tr -d ' '; }

age_file() {
  local past=$(( $(date +%s) - $2 ))
  touch -t "$(date -r "$past" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$past" +%Y%m%d%H%M.%S)" "$1"
}

@test "a failed prepaid fetch does not refetch on the next render" {
  run_bar
  run_bar
  [ "$(prepaid_calls)" -eq 1 ]
}

@test "a prepaid 429 records the shared Retry-After cooldown" {
  run_bar
  [ -f "$RETRYAFTER_FILE" ]
  deadline=$(cat "$RETRYAFTER_FILE")
  [ "$deadline" -gt "$(date +%s)" ]
}

@test "an active shared cooldown suppresses the prepaid fetch entirely" {
  echo $(( $(date +%s) + 600 )) > "$RETRYAFTER_FILE"
  run_bar
  [ "$(prepaid_calls)" -eq 0 ]
}

@test "prepaid retries once its own throttle window elapses (no active cooldown)" {
  run_bar
  rm -f "$RETRYAFTER_FILE"              # clear shared cooldown
  age_file "$PREPAID_ATTEMPT" 400       # past the 300s prepaid throttle
  run_bar
  [ "$(prepaid_calls)" -eq 2 ]
}
