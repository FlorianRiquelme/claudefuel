#!/usr/bin/env bats

# Tests for OSC 8 hyperlinks: the bar as navigation. Emitted only when
# the terminal is known to render them (TERM_PROGRAM allowlist,
# FORCE_HYPERLINK override) — a non-supporting terminal gets output
# byte-identical to the pre-hyperlink bar. Plus the clickable #N PR
# chip with review-state glyphs.

setup() {
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
  cat > "$USAGE_CACHE" <<'EOF'
{"five_hour":{"utilization":62,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":31,"resets_at":"2099-01-02T00:00:00Z"},"extra_usage":{"is_enabled":true,"used_credits":350}}
EOF
  printf '{"amount":5929,"currency":"EUR"}\n' > "$PREPAID_CACHE"

  STDIN='{"model":{"display_name":"Claude"},"session_id":"t","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":50000}}}'
  OSC8=$'\x1b]8;;'
}

teardown() {
  rm -f "$USAGE_CACHE" "$PREPAID_CACHE" 2>/dev/null
  rm -rf "/tmp/claude/statusline-sessions-${config_hash}" 2>/dev/null
  [ -n "$CLAUDE_CONFIG_DIR" ] && [ -d "$CLAUDE_CONFIG_DIR" ] && rm -rf "$CLAUDE_CONFIG_DIR"
}

render() {
  printf '%s' "$STDIN" | CLAUDEFUEL_OFFLINE=1 env "$@" "$STATUSLINE"
}

@test "FORCE_HYPERLINK=1: reset and extra cells carry OSC 8 sequences" {
  out=$(printf '%s' "$STDIN" | CLAUDEFUEL_OFFLINE=1 FORCE_HYPERLINK=1 "$STATUSLINE")
  expanded=$(printf '%b' "$out")
  [[ "$expanded" == *"${OSC8}https://claude.ai/settings/usage"* ]]
  [[ "$expanded" == *"${OSC8}https://claude.ai/settings/billing"* ]]
}

@test "without hyperlink support the output is link-free (Terminal.app sees no garbage)" {
  out=$(printf '%s' "$STDIN" \
    | CLAUDEFUEL_OFFLINE=1 TERM_PROGRAM=Apple_Terminal TERM=xterm-256color "$STATUSLINE")
  [[ "$(printf '%b' "$out")" != *"${OSC8}"* ]]
}

@test "TERM_PROGRAM allowlist gates emission" {
  out=$(printf '%s' "$STDIN" | CLAUDEFUEL_OFFLINE=1 TERM_PROGRAM=iTerm.app "$STATUSLINE")
  [[ "$(printf '%b' "$out")" == *"${OSC8}"* ]]

  out=$(printf '%s' "$STDIN" | CLAUDEFUEL_OFFLINE=1 TERM=xterm-kitty "$STATUSLINE")
  [[ "$(printf '%b' "$out")" == *"${OSC8}"* ]]
}

@test "hyperlinks: false disables links even under FORCE_HYPERLINK" {
  printf '{"version":1,"hyperlinks":false}' > "$CLAUDE_CONFIG_DIR/claudefuel.json"
  out=$(printf '%s' "$STDIN" | CLAUDEFUEL_OFFLINE=1 FORCE_HYPERLINK=1 "$STATUSLINE")
  [[ "$(printf '%b' "$out")" != *"${OSC8}"* ]]
}

@test "linked and unlinked renders are visually identical (links add zero width)" {
  plain=$(printf '%s' "$STDIN" | CLAUDEFUEL_OFFLINE=1 "$STATUSLINE" \
    | sed -E $'s/\x1b\\[[0-9;]*m//g')
  linked=$(printf '%s' "$STDIN" | CLAUDEFUEL_OFFLINE=1 FORCE_HYPERLINK=1 "$STATUSLINE" \
    | perl -pe 's/\\033\]8;;.*?\\a//g' | sed -E $'s/\x1b\\[[0-9;]*m//g')
  [ "$plain" = "$linked" ]
}

@test "drift signal links to the releases page" {
  printf '{"upstream_version":"99.99.99"}\n' \
    > "$CLAUDE_CONFIG_DIR/cache/claudefuel-version.json"
  out=$(printf '%s' "$STDIN" | CLAUDEFUEL_OFFLINE=1 FORCE_HYPERLINK=1 "$STATUSLINE")
  expanded=$(printf '%b' "$out")
  [[ "$expanded" == *"${OSC8}https://github.com/FlorianRiquelme/claudefuel/releases"* ]]
}

@test "pr chip renders #N with the review-state glyph and links to the PR" {
  pr_stdin='{"model":{"display_name":"Claude"},"session_id":"t","pr":{"number":123,"url":"https://github.com/o/r/pull/123","review_state":"approved"}}'
  out=$(printf '%s' "$pr_stdin" | CLAUDEFUEL_OFFLINE=1 FORCE_HYPERLINK=1 "$STATUSLINE")
  expanded=$(printf '%b' "$out")
  plain=$(printf '%s' "$expanded" | sed -E $'s/\x1b\\[[0-9;]*m//g')

  [[ "$plain" == *"#123 ✓"* ]]
  [[ "$expanded" == *"${OSC8}https://github.com/o/r/pull/123"* ]]
}

@test "pr review-state glyph map: changes_requested ✗, draft ◇, pending ◌" {
  for pair in 'changes_requested:✗' 'draft:◇' 'pending:◌'; do
    state="${pair%%:*}" glyph="${pair##*:}"
    pr_stdin=$(printf '{"model":{"display_name":"Claude"},"pr":{"number":7,"url":"u","review_state":"%s"}}' "$state")
    out=$(printf '%s' "$pr_stdin" | CLAUDEFUEL_OFFLINE=1 "$STATUSLINE" \
      | sed -E $'s/\x1b\\[[0-9;]*m//g')
    [[ "$out" == *"#7 ${glyph}"* ]]
  done
}

@test "pr chip absent without pr data, hideable via 'pr', registered in validate-config" {
  out=$(printf '%s' "$STDIN" | CLAUDEFUEL_OFFLINE=1 "$STATUSLINE" \
    | sed -E $'s/\x1b\\[[0-9;]*m//g')
  [[ "$out" != *"#"[0-9]* ]]

  printf '{"version":1,"segments":{"hide":["pr"]},"hyperlinks":false}' \
    > "$CLAUDE_CONFIG_DIR/claudefuel.json"
  pr_stdin='{"model":{"display_name":"Claude"},"pr":{"number":123,"url":"u","review_state":"approved"}}'
  out=$(printf '%s' "$pr_stdin" | CLAUDEFUEL_OFFLINE=1 "$STATUSLINE")
  [[ "$out" != *"#123"* ]]

  run "$STATUSLINE" --validate-config "$CLAUDE_CONFIG_DIR/claudefuel.json"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "ok" ]
  printf '%s' "$output" | jq -e '.effective.hyperlinks == false' >/dev/null
}
