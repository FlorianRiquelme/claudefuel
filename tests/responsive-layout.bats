#!/usr/bin/env bats

# Tests for COLUMNS-aware rendering: degradation tiers (full / narrow
# <80 / tiny <60) and the glyphs: unicode|ascii config key. Golden
# checks pin the fixture's shape per tier; the invariant check asserts
# no line ever exceeds COLUMNS.

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
  USAGE_CACHE="/tmp/claude/statusline-usage-cache-${config_hash}.json"
  PREPAID_CACHE="/tmp/claude/statusline-prepaid-cache-${config_hash}.json"
  mkdir -p /tmp/claude

  # Extra column live so the narrow tier has something to drop.
  cat > "$USAGE_CACHE" <<'EOF'
{"five_hour":{"utilization":62,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":31,"resets_at":"2099-01-02T00:00:00Z"},"extra_usage":{"is_enabled":true,"used_credits":350}}
EOF
  printf '{"amount":5929,"currency":"EUR"}\n' > "$PREPAID_CACHE"

  NOW=1751500000
  STDIN='{"model":{"display_name":"Claude"},"session_id":"t","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":50000}},"thinking":{"enabled":true},"effort":{"level":"high"}}'
}

teardown() {
  rm -f "$USAGE_CACHE" "$PREPAID_CACHE" 2>/dev/null
  rm -rf "/tmp/claude/statusline-sessions-${config_hash}" 2>/dev/null
  [ -n "$CLAUDE_CONFIG_DIR" ] && [ -d "$CLAUDE_CONFIG_DIR" ] && rm -rf "$CLAUDE_CONFIG_DIR"
}

strip_ansi() {
  sed -E $'s/\x1b\\[[0-9;]*m//g'
}

render_at() {
  printf '%s' "$STDIN" \
    | COLUMNS=$1 CLAUDEFUEL_OFFLINE=1 CLAUDEFUEL_NOW=$NOW "$STATUSLINE" \
    | strip_ansi
}

@test "full tier (COLUMNS=120): everything renders — extra, effort, 10-cell bars" {
  out=$(render_at 120)
  [[ "$out" == *"effort: high"* ]]
  [[ "$out" == *"extra:"*"€59.29"* ]]
  [[ "$out" == *"●●●●●●○○○○"* ]]
  [[ "$out" == *"thinking: On"* ]]
}

@test "<90: line 1 slims (effort drops, thinking abbreviates) but extra survives" {
  out=$(render_at 85)
  [[ "$out" != *"effort:"* ]]
  [[ "$out" == *"think: On"* ]]
  [[ "$out" == *"extra:"* ]]
  [[ "$out" == *"●●●●●●○○○○"* ]]
}

@test "<80: the extra column drops too" {
  out=$(render_at 79)
  [[ "$out" != *"effort:"* ]]
  [[ "$out" != *"extra:"* ]]
  [[ "$out" == *"think: On"* ]]
  [[ "$out" == *"●●●●●●○○○○"* ]]
}

@test "<60: bars shrink to 5 cells, thinking drops" {
  out=$(render_at 59)
  [[ "$out" == *"●●●○○"* ]]
  [[ "$out" != *"●●●●●●○○○○"* ]]
  [[ "$out" != *"extra:"* ]]
  [[ "$out" != *"think"* ]]
}

@test "no line exceeds COLUMNS at 120 / 80 / 60" {
  for cols in 120 80 60; do
    out=$(render_at "$cols")
    while IFS= read -r line; do
      chars=$(printf '%s' "$line" | wc -m | tr -d ' ')
      [ "$chars" -le "$cols" ] || {
        echo "line exceeds $cols chars ($chars): $line"; return 1; }
    done <<< "$out"
  done
}

@test "unknown or absent COLUMNS never constrains the layout" {
  out=$(printf '%s' "$STDIN" \
    | COLUMNS= CLAUDEFUEL_OFFLINE=1 CLAUDEFUEL_NOW=$NOW "$STATUSLINE" | strip_ansi)
  [[ "$out" == *"extra:"* ]]
  out=$(printf '%s' "$STDIN" \
    | COLUMNS=weird CLAUDEFUEL_OFFLINE=1 CLAUDEFUEL_NOW=$NOW "$STATUSLINE" | strip_ansi)
  [[ "$out" == *"extra:"* ]]
}

@test "glyphs ascii: output contains no multibyte glyphs, alignment intact" {
  printf '{"version":1,"glyphs":"ascii"}' > "$CLAUDE_CONFIG_DIR/claudefuel.json"
  out=$(render_at 120)

  for glyph in ● ○ ▸ ↻ ◈ ⚠; do
    [[ "$out" != *"$glyph"* ]]
  done
  [[ "$out" == *"######...."* ]]
  [[ "$out" == *"@"* ]]

  line2=$(printf '%s' "$out" | sed -n '2p')
  line3=$(printf '%s' "$out" | sed -n '3p')
  pipe2=$(printf '%s' "${line2%%|*}" | wc -m | tr -d ' ')
  pipe3=$(printf '%s' "${line3%%|*}" | wc -m | tr -d ' ')
  [ "$pipe2" = "$pipe3" ]
}

@test "glyphs key is registered: validate-config accepts it and warns on bad values" {
  printf '{"version":1,"glyphs":"ascii"}' > "$CLAUDE_CONFIG_DIR/claudefuel.json"
  run "$STATUSLINE" --validate-config "$CLAUDE_CONFIG_DIR/claudefuel.json"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "ok" ]
  printf '%s' "$output" | jq -e '.overridden_keys == ["glyphs"]' >/dev/null

  printf '{"version":1,"glyphs":"emoji"}' > "$CLAUDE_CONFIG_DIR/claudefuel.json"
  run "$STATUSLINE" --validate-config "$CLAUDE_CONFIG_DIR/claudefuel.json"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.warnings[0] | test("unknown glyphs")' >/dev/null
}
