#!/usr/bin/env bats

# Tests for the "Now" layer: session identity chip, subagent context
# badge, live-activity segment (transcript tail), and the --subagent
# row renderer for subagentStatusLine.
#
# Doctrine under test: the transcript JSONL has no public format spec,
# so activity parsing is best-effort — malformed or missing input always
# renders nothing and exits 0, never garbage.

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

  TRANSCRIPT="$BATS_TEST_TMPDIR/transcript.jsonl"
  NOW=1751500000
}

teardown() {
  [ -n "$CLAUDE_CONFIG_DIR" ] && [ -d "$CLAUDE_CONFIG_DIR" ] && rm -rf "$CLAUDE_CONFIG_DIR"
}

strip_ansi() {
  sed -E $'s/\x1b\\[[0-9;]*m//g'
}

# Renders line 1 offline from a stdin fixture built out of the args.
# Usage: render_line1 '<extra stdin fields, comma-led>'
render_line1() {
  printf '{"model":{"display_name":"Claude"}%s}' "$1" \
    | CLAUDEFUEL_OFFLINE=1 CLAUDEFUEL_NOW=$NOW "$STATUSLINE" \
    | strip_ansi | sed -n '1p'
}

iso() {
  date -u -r "$1" +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null \
    || date -u -d "@$1" +"%Y-%m-%dT%H:%M:%S.000Z"
}

# Transcript with a pending Bash tool_use (no tool_result), started
# $1 seconds before NOW, preceded by resolved-call and junk lines.
write_pending_transcript() {
  local ago=${1:-12}
  cat > "$TRANSCRIPT" <<EOF
not even json
{"type":"assistant","timestamp":"$(iso $((NOW - 300)))","message":{"content":[{"type":"tool_use","id":"a1","name":"Read"}]}}
{"type":"user","timestamp":"$(iso $((NOW - 299)))","message":{"content":[{"type":"tool_result","tool_use_id":"a1"}]}}
{"type":"assistant","timestamp":"$(iso $((NOW - 200)))","message":{"content":[{"type":"text","text":"hello"}]}}
{"type":"assistant","timestamp":"$(iso $((NOW - ago)))","message":{"content":[{"type":"tool_use","id":"a2","name":"Bash"}]}}
EOF
}

@test "session chip: session_name renders with the ◈ glyph" {
  line1=$(render_line1 ',"session_id":"abc-123","session_name":"refactor-auth"')
  [[ "$line1" == *"◈ refactor-auth"* ]]
}

@test "session chip: no chip when only session_id is present (no session_name)" {
  line1=$(render_line1 ',"session_id":"97effbcf-99f3-49b4"')
  [[ "$line1" != *"◈"* ]]
}

@test "session chip: absent without session identity, hideable via 'session'" {
  line1=$(render_line1 '')
  [[ "$line1" != *"◈"* ]]

  printf '{"version":1,"segments":{"hide":["session"]}}' \
    > "$CLAUDE_CONFIG_DIR/claudefuel.json"
  line1=$(render_line1 ',"session_id":"abc-123","session_name":"refactor-auth"')
  [[ "$line1" != *"◈"* ]]
}

@test "session chip color is stable across renders of the same session" {
  a=$(printf '{"model":{"display_name":"Claude"},"session_id":"abc-123","session_name":"refactor-auth"}' \
    | CLAUDEFUEL_OFFLINE=1 CLAUDEFUEL_NOW=$NOW "$STATUSLINE" | sed -n '1p')
  b=$(printf '{"model":{"display_name":"Claude"},"session_id":"abc-123","session_name":"refactor-auth"}' \
    | CLAUDEFUEL_OFFLINE=1 CLAUDEFUEL_NOW=$NOW "$STATUSLINE" | sed -n '1p')
  [ "$a" = "$b" ]
  [[ "$a" == *$'\x1b[38;2'* ]]
}

@test "agent badge renders agent.name in subagent sessions only" {
  line1=$(render_line1 ',"agent":{"name":"security-reviewer"}')
  [[ "$line1" == *"agent: security-reviewer"* ]]

  line1=$(render_line1 '')
  [[ "$line1" != *"agent:"* ]]
}

@test "activity: pending tool_use renders '▸ <tool> <age>'" {
  write_pending_transcript 12
  line1=$(render_line1 ",\"transcript_path\":\"$TRANSCRIPT\"")
  [[ "$line1" == *"▸ Bash 12s"* ]]
}

@test "activity: a resolved tool call renders nothing (it is no longer 'now')" {
  write_pending_transcript 12
  cat >> "$TRANSCRIPT" <<EOF
{"type":"user","timestamp":"$(iso $((NOW - 10)))","message":{"content":[{"type":"tool_result","tool_use_id":"a2"}]}}
EOF
  line1=$(render_line1 ",\"transcript_path\":\"$TRANSCRIPT\"")
  [[ "$line1" != *"▸ Bash"* ]]
}

@test "activity: dormant once the pending call is older than 10 minutes" {
  write_pending_transcript 700
  line1=$(render_line1 ",\"transcript_path\":\"$TRANSCRIPT\"")
  [[ "$line1" != *"▸ Bash"* ]]
}

@test "activity: malformed or missing transcript renders nothing and exits 0" {
  printf 'total garbage\x00\x01{{{\n' > "$TRANSCRIPT"
  run bash -c "printf '{\"model\":{\"display_name\":\"Claude\"},\"transcript_path\":\"$TRANSCRIPT\"}' \
    | CLAUDEFUEL_OFFLINE=1 '$STATUSLINE'"
  [ "$status" -eq 0 ]
  [[ "$(printf '%s' "$output" | strip_ansi)" != *"▸"* ]]

  run bash -c "printf '{\"model\":{\"display_name\":\"Claude\"},\"transcript_path\":\"/nope/missing.jsonl\"}' \
    | CLAUDEFUEL_OFFLINE=1 '$STATUSLINE'"
  [ "$status" -eq 0 ]
}

@test "activity: hideable via 'activity'" {
  write_pending_transcript 12
  printf '{"version":1,"segments":{"hide":["activity"]}}' \
    > "$CLAUDE_CONFIG_DIR/claudefuel.json"
  line1=$(render_line1 ",\"transcript_path\":\"$TRANSCRIPT\"")
  [[ "$line1" != *"▸ Bash"* ]]
}

@test "new tokens are registered: validate-config accepts session/agent/activity without warnings" {
  cfg="$BATS_TEST_TMPDIR/order.json"
  printf '{"version":1,"segments":{"order":{"line1":["session","model","ctx","activity","agent"]},"hide":["activity"]}}' \
    > "$cfg"
  run "$STATUSLINE" --validate-config "$cfg"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "ok" ]
}

@test "--subagent: one JSON row per task with colored name, status, age, tokens" {
  out=$(printf '{"tasks":[{"id":"t1","name":"Explore","status":"running","startTime":%s,"tokenCount":45321},{"id":"t2","name":"reviewer","status":"completed","startTime":"%s","tokenCount":1234567}]}' \
      "$(( (NOW - 83) * 1000 ))" "$(iso $((NOW - 3700)))" \
    | CLAUDEFUEL_NOW=$NOW "$STATUSLINE" --subagent)

  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 2 ]
  printf '%s\n' "$out" | sed -n 1p | jq -e '.id == "t1" and (.content | test("Explore.*▸ 1m · 45k"))' >/dev/null
  printf '%s\n' "$out" | sed -n 2p | jq -e '.id == "t2" and (.content | test("reviewer.*✓ 1h · 1.2m"))' >/dev/null
  # ANSI color + reset present in the content strings
  printf '%s\n' "$out" | sed -n 1p | jq -e '.content | test("\\[38;2;") and test("\\[0m")' >/dev/null
}

@test "--subagent: empty or garbage stdin emits nothing and exits 0" {
  run bash -c "printf '' | '$STATUSLINE' --subagent"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash -c "printf 'garbage' | '$STATUSLINE' --subagent"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
