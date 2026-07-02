#!/usr/bin/env bats

# Tests for `statusline.sh --demo <state>` — first-class preview renders
# from canned built-in data. The preview seam for /claudefuel.configure:
# combined with CLAUDEFUEL_CONFIG it shows exactly what a candidate
# config looks like under pressure, before anything is written.
#
# Contract under test:
#   - five states render, exit 0, deterministic (byte-identical runs)
#   - zero network and zero reads of the user's real caches
#   - CLAUDEFUEL_CONFIG=<candidate> shapes the demo render
#   - unknown state is a usage error (exit 2)

setup() {
  CLAUDE_CONFIG_DIR=$(mktemp -d)
  export CLAUDE_CONFIG_DIR
  mkdir -p "$CLAUDE_CONFIG_DIR/cache"
  STATUSLINE="${BATS_TEST_DIRNAME}/../statusline.sh"

  # A drift-y version cache + credentials that COULD be used — the demo
  # must ignore all of it (deterministic, cache-blind).
  printf '{"upstream_version":"99.99.99"}\n' \
    > "$CLAUDE_CONFIG_DIR/cache/claudefuel-version.json"
  printf '{"claudeAiOauth":{"accessToken":"test-token","refreshToken":"r","expiresAt":99999999999999}}' \
    > "$CLAUDE_CONFIG_DIR/.credentials.json"

  config_hash=$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)
  USAGE_CACHE="/tmp/claude/statusline-usage-cache-${config_hash}.json"
  PREPAID_CACHE="/tmp/claude/statusline-prepaid-cache-${config_hash}.json"
  mkdir -p /tmp/claude

  # curl shim: any invocation is a contract violation, logged.
  SHIM_DIR=$(mktemp -d)
  export CURL_LOG="$SHIM_DIR/curl.log"
  cat > "$SHIM_DIR/curl" <<'SHIM'
#!/bin/bash
echo "curl $*" >> "$CURL_LOG"
exit 7
SHIM
  chmod +x "$SHIM_DIR/curl"
  SHIM_PATH="$SHIM_DIR:$PATH"
}

teardown() {
  rm -f "$USAGE_CACHE" "$PREPAID_CACHE" 2>/dev/null
  [ -n "$SHIM_DIR" ] && [ -d "$SHIM_DIR" ] && rm -rf "$SHIM_DIR"
  [ -n "$CLAUDE_CONFIG_DIR" ] && [ -d "$CLAUDE_CONFIG_DIR" ] && rm -rf "$CLAUDE_CONFIG_DIR"
}

strip_ansi() {
  sed -E $'s/\x1b\\[[0-9;]*m//g'
}

demo() {
  TZ=UTC PATH="$SHIM_PATH" "$STATUSLINE" --demo "$1"
}

@test "every demo state renders and exits 0" {
  for state in healthy warning critical stale offline; do
    run demo "$state"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
  done
}

@test "demo renders are byte-identical across runs" {
  for state in healthy warning critical stale offline; do
    a=$(demo "$state")
    b=$(demo "$state")
    [ "$a" = "$b" ]
  done
}

@test "demo never calls the network, even without CLAUDEFUEL_OFFLINE in the env" {
  for state in healthy warning critical stale offline; do
    demo "$state" >/dev/null
  done
  [ ! -e "$CURL_LOG" ]
}

@test "demo ignores the user's real caches and version drift" {
  # Real caches scream 99% — the demo must not read them.
  printf '{"five_hour":{"utilization":99,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":99,"resets_at":"2099-01-01T00:00:00Z"},"extra_usage":{"is_enabled":true,"used_credits":1}}' \
    > "$USAGE_CACHE"

  out=$(demo healthy | strip_ansi)
  [[ "$out" == *"30%"* ]]
  [[ "$out" != *"99%"* ]]
  # The drift-y version cache seeded in setup must not light ↗ either.
  [[ "$out" != *"claudefuel.update"* ]]
}

@test "healthy: green bars, extra column, no alarms" {
  out=$(demo healthy | strip_ansi)
  [[ "$out" == *"5h:"*"30%"* ]]
  [[ "$out" == *"7d:"*"12%"* ]]
  [[ "$out" == *"extra:"*'$25.00'* ]]
  [[ "$out" != *"~cap"* ]]
  [[ "$out" != *"⚠"* ]]
}

@test "critical: escalation, burn chip, cap-ETA, governing marker" {
  out=$(demo critical | strip_ansi)
  [[ "$out" == *"▸⚠5h:"* ]]
  [[ "$out" == *"×1.2"* ]]
  [[ "$out" == *"~cap"* ]]
  [[ "$out" == *"slow ≤"* ]]
}

@test "stale: age markers and the severe-staleness warning" {
  out=$(demo stale | strip_ansi)
  [[ "$out" == *"·9m"* ]]
  [[ "$out" == *"⚠ updates ~"* ]]
}

@test "offline: the failure trailhead" {
  out=$(demo offline | strip_ansi)
  [[ "$out" == *"✚ /claudefuel.doctor"* ]]
  [[ "$out" != *"5h:"* ]]
}

@test "demo reflects an injected CLAUDEFUEL_CONFIG (mono theme drops color escapes)" {
  candidate="$SHIM_DIR/candidate.json"
  printf '{"version":1,"theme":"mono"}\n' > "$candidate"

  colored=$(demo warning)
  mono=$(CLAUDEFUEL_CONFIG="$candidate" demo warning)

  [[ "$colored" == *$'\x1b[38;2'* ]]
  [[ "$mono" != *$'\x1b[38;2'* ]]
}

@test "demo reflects an injected candidate's hide + countdown keys" {
  candidate="$SHIM_DIR/candidate.json"
  printf '{"version":1,"reset_display":"countdown","segments":{"hide":["thinking","extra"]}}\n' \
    > "$candidate"

  # warning keeps lines 2-3 visible; healthy would calm-collapse once
  # the extra column is hidden (nothing left above the alarm floor).
  out=$(CLAUDEFUEL_CONFIG="$candidate" demo warning | strip_ansi)
  [[ "$out" == *"↻ in "* ]]
  [[ "$out" != *"thinking"* ]]
  [[ "$out" != *"extra:"* ]]
}

@test "a hidden extra column calm-collapses the healthy demo to line 1 (truthful preview)" {
  candidate="$SHIM_DIR/candidate.json"
  printf '{"version":1,"segments":{"hide":["extra"]}}\n' > "$candidate"

  out=$(CLAUDEFUEL_CONFIG="$candidate" demo healthy | strip_ansi)
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "unknown demo state is a usage error" {
  run "$STATUSLINE" --demo bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}
