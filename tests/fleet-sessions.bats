#!/usr/bin/env bats

# Tests for shared-window session attribution: per-session heartbeat
# files in /tmp/claude/statusline-sessions<suffix>/, the `⧉ N` Line-2
# chip when more than one live session draws on the account window, and
# the sessions count in --fleet.

setup() {
  export FORCE_HYPERLINK=0  # hermetic: the host terminal must not toggle OSC 8
  CLAUDE_CONFIG_DIR=$(mktemp -d)
  export CLAUDE_CONFIG_DIR
  mkdir -p "$CLAUDE_CONFIG_DIR/cache"
  STATUSLINE="${BATS_TEST_DIRNAME}/../statusline.sh"

  installed_version=$(grep -E '^# claudefuel:' "$STATUSLINE" | head -n1 \
    | sed -E 's/^# claudefuel: v//')
  printf '{"upstream_version":"%s"}\n' "$installed_version" \
    > "$CLAUDE_CONFIG_DIR/cache/claudefuel-version.json"

  config_hash=$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)
  SESSIONS_DIR="/tmp/claude/statusline-sessions-${config_hash}"
  USAGE_CACHE="/tmp/claude/statusline-usage-cache-${config_hash}.json"
  mkdir -p /tmp/claude

  NOW=1751500000
}

teardown() {
  rm -rf "$SESSIONS_DIR" 2>/dev/null
  rm -f "$USAGE_CACHE" 2>/dev/null
  [ -n "$CLAUDE_CONFIG_DIR" ] && [ -d "$CLAUDE_CONFIG_DIR" ] && rm -rf "$CLAUDE_CONFIG_DIR"
}

strip_ansi() {
  sed -E $'s/\x1b\\[[0-9;]*m//g'
}

# Render offline with a given session id; 62%/31% keeps lines 2-3
# visible (no calm collapse), far-future resets keep predictions quiet.
render_as() {
  local sid=$1
  printf '{"model":{"display_name":"Claude"},"session_id":"%s","rate_limits":{"five_hour":{"used_percentage":62,"resets_at":4070908800},"seven_day":{"used_percentage":31,"resets_at":4070995200}}}' "$sid" \
    | CLAUDEFUEL_OFFLINE=1 "$STATUSLINE" | strip_ansi
}

@test "two sessions on one window: second render shows ⧉ 2" {
  render_as aaaa-1111 >/dev/null
  out=$(render_as bbbb-2222)
  [[ "$out" == *"⧉ 2"* ]]
  [ -f "$SESSIONS_DIR/s-aaaa-1111" ]
  [ -f "$SESSIONS_DIR/s-bbbb-2222" ]
}

@test "a single session shows no chip" {
  out=$(render_as aaaa-1111)
  [[ "$out" != *"⧉"* ]]
}

@test "stale heartbeats are ignored and pruned" {
  mkdir -p "$SESSIONS_DIR"
  touch -t 202001010000 "$SESSIONS_DIR/s-old-session"

  out=$(render_as aaaa-1111)
  [[ "$out" != *"⧉"* ]]
  [ ! -f "$SESSIONS_DIR/s-old-session" ]
}

@test "the chip is hideable via the 'sessions' token, which validate-config accepts" {
  printf '{"version":1,"segments":{"hide":["sessions"]}}' \
    > "$CLAUDE_CONFIG_DIR/claudefuel.json"
  render_as aaaa-1111 >/dev/null
  out=$(render_as bbbb-2222)
  [[ "$out" != *"⧉"* ]]

  run "$STATUSLINE" --validate-config "$CLAUDE_CONFIG_DIR/claudefuel.json"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "ok" ]
}

@test "session ids are sanitized before touching the filesystem" {
  render_as '../../../etc/passwd' >/dev/null
  # Nothing escapes the heartbeat dir; the sanitized name stays inside.
  [ ! -e "/tmp/claude/etc/passwd" ]
  found=$(find "$SESSIONS_DIR" -type f | wc -l | tr -d ' ')
  [ "$found" -eq 1 ]
}

@test "--fleet reports the live session count per profile" {
  printf '{"five_hour":{"utilization":42,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":13,"resets_at":"2099-01-02T00:00:00Z"}}' \
    > "$USAGE_CACHE"
  render_as aaaa-1111 >/dev/null
  render_as bbbb-2222 >/dev/null

  fleet=$("$STATUSLINE" --fleet | jq -c "select(.cache_age_seconds != null) | select(.sessions == 2)" | head -n1)
  [ -n "$fleet" ]
}

@test "--fleet stays a pure read: stale heartbeats are not pruned by it" {
  printf '{"five_hour":{"utilization":42,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":13,"resets_at":"2099-01-02T00:00:00Z"}}' \
    > "$USAGE_CACHE"
  mkdir -p "$SESSIONS_DIR"
  touch -t 202001010000 "$SESSIONS_DIR/s-old-session"

  "$STATUSLINE" --fleet >/dev/null
  [ -f "$SESSIONS_DIR/s-old-session" ]
}

@test "demo renders write no heartbeats and show no chip" {
  mkdir -p "$SESSIONS_DIR"
  touch "$SESSIONS_DIR/s-one" "$SESSIONS_DIR/s-two"

  out=$("$STATUSLINE" --demo warning | strip_ansi)
  [[ "$out" != *"⧉"* ]]
  [ "$(find "$SESSIONS_DIR" -type f | wc -l | tr -d ' ')" -eq 2 ]
}
