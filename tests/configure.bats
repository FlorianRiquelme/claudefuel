#!/usr/bin/env bats

# Tests for the config foundation in statusline.sh.
#
# Black-box CLI tests: isolate via CLAUDE_CONFIG_DIR, pre-seed the usage
# cache so the script never touches OAuth or the network, write a
# claudefuel.json into the isolated profile, feed stdin, assert on stdout.
#
# Domain (see CONTEXT.md / ADR-0003): customization is "minor tweaks"
# only — color thresholds, segment ordering, segment show/hide, theme
# presets — read from ~/.claude/claudefuel.json (profile-aware) and
# merged over baked-in defaults. The absent-file path is the common case
# and must render pixel-identically to a file of pure defaults.

SAMPLE_STDIN='{"model":{"display_name":"Claude"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":50000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"thinking":{"enabled":true},"effort":{"level":"high"}}'

setup() {
  CLAUDE_CONFIG_DIR=$(mktemp -d)
  export CLAUDE_CONFIG_DIR
  mkdir -p "$CLAUDE_CONFIG_DIR/cache"
  STATUSLINE="${BATS_TEST_DIRNAME}/../statusline.sh"
  CONFIG_FILE="$CLAUDE_CONFIG_DIR/claudefuel.json"

  # Silence drift segment regardless of network: seed cache to match installed.
  installed_version=$(grep -E '^# claudefuel:' "$STATUSLINE" | head -n1 \
    | sed -E 's/^# claudefuel: v//')
  printf '{"upstream_version":"%s"}\n' "$installed_version" \
    > "$CLAUDE_CONFIG_DIR/cache/claudefuel-version.json"

  # Mirror statusline.sh's CACHE_SUFFIX derivation to locate caches.
  config_hash=$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)
  USAGE_CACHE="/tmp/claude/statusline-usage-cache-${config_hash}.json"
  PREPAID_CACHE="/tmp/claude/statusline-prepaid-cache-${config_hash}.json"
  mkdir -p /tmp/claude
}

teardown() {
  rm -f "$USAGE_CACHE" "$PREPAID_CACHE" 2>/dev/null
  [ -n "$CLAUDE_CONFIG_DIR" ] && [ -d "$CLAUDE_CONFIG_DIR" ] && rm -rf "$CLAUDE_CONFIG_DIR"
}

# Deterministic usage snapshot: fixed reset timestamps far in the future
# keep burn rate below reset-pace (no cap-ETA, which reads the wall
# clock), so repeated renders are byte-identical.
# Args: [<5h_pct>=20] [<7d_pct>=12] [<extra_enabled>=false] [<used_credits>=0]
seed_usage_cache() {
  local fh_pct=${1:-20} sd_pct=${2:-12} extra=${3:-false} used_credits=${4:-0}
  cat > "$USAGE_CACHE" <<EOF
{
  "five_hour":   { "utilization": $fh_pct, "resets_at": "2099-01-01T00:00:00Z" },
  "seven_day":   { "utilization": $sd_pct, "resets_at": "2099-01-02T00:00:00Z" },
  "extra_usage": { "is_enabled": $extra, "used_credits": $used_credits }
}
EOF
  touch "$USAGE_CACHE"
}

# Burning-hot 5h snapshot relative to "now" so the cap-ETA gates pass:
# 50% used, window started 2h ago, 3h until reset (burn rate 25%/h >
# reset-pace 20%/h, pct >= 10%).
seed_burning_cache() {
  local now fh_resets fh_iso
  now=$(date +%s)
  fh_resets=$(( now + 10800 ))
  fh_iso=$(date -u -r "$fh_resets" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "@$fh_resets" +"%Y-%m-%dT%H:%M:%SZ")
  cat > "$USAGE_CACHE" <<EOF
{
  "five_hour":   { "utilization": 50, "resets_at": "$fh_iso" },
  "seven_day":   { "utilization": 12, "resets_at": "2099-01-02T00:00:00Z" },
  "extra_usage": { "is_enabled": false }
}
EOF
  touch "$USAGE_CACHE"
}

seed_prepaid_cache() {
  printf '{"amount":5929,"currency":"EUR"}\n' > "$PREPAID_CACHE"
  touch "$PREPAID_CACHE"
}

write_config() {
  printf '%s' "$1" > "$CONFIG_FILE"
}

strip_ansi() {
  sed -E $'s/\x1b\\[[0-9;]*m//g'
}

run_bar() {
  CLAUDEFUEL_OFFLINE=1 printf '%s' "$SAMPLE_STDIN" | "$STATUSLINE"
}

run_bar_plain() {
  run_bar | strip_ansi
}

# ===== defaults merge =====

@test "no config file: output is byte-identical to a config of pure defaults" {
  seed_usage_cache
  baseline=$(run_bar)

  write_config '{
    "version": 1,
    "theme": "default",
    "color_thresholds": { "orange": 50, "yellow": 70, "red": 90 },
    "reset_display": "clock",
    "segments": {
      "order": {
        "line1": ["model", "ctx", "thinking", "effort", "drift"],
        "columns": ["5h", "7d", "extra"]
      },
      "hide": []
    }
  }'
  configured=$(run_bar)

  [ "$baseline" = "$configured" ]
}

@test "partial config: unspecified keys fall back to defaults" {
  seed_usage_cache
  baseline=$(run_bar)

  # A file that only pins one key must not disturb any other default.
  write_config '{"version": 1, "reset_display": "clock"}'
  configured=$(run_bar)

  [ "$baseline" = "$configured" ]
}

@test "no config file: default structure renders (regression anchor)" {
  # Golden structural assertions for the no-config render, so the
  # defaults themselves can't silently drift during config work.
  # Non-nominal pcts (>=50): a genuinely nominal snapshot now collapses
  # lines 2-3 entirely (calm cockpit) — this anchor is for the structure
  # of a render that HAS something to show, not the collapsed case.
  seed_usage_cache 55 60 false
  output=$(run_bar_plain)
  line1=$(printf '%s' "$output" | sed -n '1p')
  line2=$(printf '%s' "$output" | sed -n '2p')
  line3=$(printf '%s' "$output" | sed -n '3p')

  [[ "$line1" == *"Claude | ctx "*"50k/200k | thinking: On | effort: high"* ]]
  [[ "$line2" == "5h: "*"55%"*"| 7d: "*"60%"* ]]
  [[ "$line3" == "↻ "*"| ↻ "* ]]
}

@test "malformed config file: bar renders defaults, exit 0" {
  seed_usage_cache
  baseline=$(run_bar)

  write_config 'this is not json {'
  CLAUDEFUEL_OFFLINE=1 run bash -c "printf '%s' '$SAMPLE_STDIN' | '$STATUSLINE'"

  [ "$status" -eq 0 ]
  [ "$output" = "$baseline" ]
}

# ===== segment show/hide =====

@test "hide thinking: segment disappears from line 1" {
  seed_usage_cache
  write_config '{"version": 1, "segments": {"hide": ["thinking"]}}'
  line1=$(run_bar_plain | sed -n '1p')

  [[ "$line1" != *"thinking:"* ]]
  [[ "$line1" == *"ctx"* ]]
  [[ "$line1" == *"effort: high"* ]]
}

@test "hide profile: badge disappears while model stays" {
  # CLAUDE_CONFIG_DIR is set in these tests, so the profile badge leads
  # line 1 by default. "profile" is hide-only (attached to model).
  seed_usage_cache
  line1=$(run_bar_plain | sed -n '1p')
  [[ "$line1" == "["* ]]

  write_config '{"version": 1, "segments": {"hide": ["profile"]}}'
  line1=$(run_bar_plain | sed -n '1p')
  [[ "$line1" == "Claude |"* ]]
}

@test "hide 7d: column disappears from lines 2 and 3" {
  seed_usage_cache 55 12 false
  write_config '{"version": 1, "segments": {"hide": ["7d"]}}'
  output=$(run_bar_plain)
  line2=$(printf '%s' "$output" | sed -n '2p')
  line3=$(printf '%s' "$output" | sed -n '3p')

  [[ "$line2" == *"5h:"* ]]
  [[ "$line2" != *"7d:"* ]]
  [[ "$line2" != *"|"* ]]
  [[ "$line3" != *"|"* ]]
}

@test "hide extra: prepaid balance column disappears" {
  # 5h non-nominal (55%) so lines 2-3 keep rendering once extra is
  # hidden below — otherwise every signal would be nominal and the
  # calm-cockpit collapse would (correctly) hide the whole row.
  seed_usage_cache 55 12 true 350
  seed_prepaid_cache
  line2=$(run_bar_plain | sed -n '2p')
  [[ "$line2" == *"extra:"* ]]

  write_config '{"version": 1, "segments": {"hide": ["extra"]}}'
  line2=$(run_bar_plain | sed -n '2p')
  [[ "$line2" != *"extra:"* ]]
  [[ "$line2" == *"5h:"* ]]
}

@test "hide drift: ↗ segment suppressed even when upstream differs" {
  printf '{"upstream_version":"9.9.9"}\n' \
    > "$CLAUDE_CONFIG_DIR/cache/claudefuel-version.json"
  seed_usage_cache
  line1=$(run_bar_plain | sed -n '1p')
  [[ "$line1" == *"↗"* ]]

  write_config '{"version": 1, "segments": {"hide": ["drift"]}}'
  line1=$(run_bar_plain | sed -n '1p')
  [[ "$line1" != *"↗"* ]]
}

@test "cap-ETA toggle: hide cap_eta removes ~cap while burning hot" {
  seed_burning_cache
  line3=$(run_bar_plain | sed -n '3p')
  [[ "$line3" == *"~cap"* ]]

  write_config '{"version": 1, "segments": {"hide": ["cap_eta"]}}'
  line3=$(run_bar_plain | sed -n '3p')
  [[ "$line3" != *"~cap"* ]]
  [[ "$line3" == *"↻"* ]]
}

# ===== segment ordering =====

@test "line 1 ordering: ctx before model" {
  seed_usage_cache
  write_config '{"version": 1, "segments": {"order": {"line1": ["ctx", "model", "thinking", "effort", "drift"]}, "hide": ["profile"]}}'
  line1=$(run_bar_plain | sed -n '1p')

  [[ "$line1" == "ctx "* ]]
  [[ "$line1" == *"| Claude |"* ]]
}

@test "column ordering: 7d leads lines 2 and 3" {
  seed_usage_cache 55 12 false
  write_config '{"version": 1, "segments": {"order": {"columns": ["7d", "5h", "extra"]}}}'
  output=$(run_bar_plain)
  line2=$(printf '%s' "$output" | sed -n '2p')
  line3=$(printf '%s' "$output" | sed -n '3p')

  [[ "$line2" == "7d: "* ]]
  [[ "$line2" == *"| 5h:"* ]]
  # Line 3 mirrors the column order: the 7d reset (a datetime with a
  # comma) now leads, the 5h reset (plain time) follows.
  [[ "$line3" == "↻ "*","*"| ↻ "* ]]
}

@test "unknown tokens in order/hide are ignored, known ones still render" {
  seed_usage_cache 55 12 false
  write_config '{"version": 1, "segments": {"order": {"line1": ["bogus", "model", "ctx", "thinking", "effort", "drift"]}, "hide": ["nonsense"]}}'
  CLAUDEFUEL_OFFLINE=1 run bash -c "printf '%s' '$SAMPLE_STDIN' | '$STATUSLINE'"

  [ "$status" -eq 0 ]
  [[ "$output" == *"ctx"* ]]
  [[ "$output" == *"5h:"* ]]
}

# ===== color thresholds =====

@test "threshold override: lowering red turns a 50% bar red" {
  # Default ladder puts 50% at orange; a config with red at 40 must put
  # the same bar at red. Truecolor codes: orange 255;176;85, red 255;85;85.
  seed_usage_cache 50 12 false
  line2=$(run_bar | sed -n '2p')
  [[ "$line2" == *$'\x1b[38;2;255;176;85m'* ]]
  [[ "$line2" != *$'\x1b[38;2;255;85;85m'* ]]

  write_config '{"version": 1, "color_thresholds": {"red": 40}}'
  line2=$(run_bar | sed -n '2p')
  [[ "$line2" == *$'\x1b[38;2;255;85;85m'* ]]
}

@test "threshold override: raising orange keeps a 50% bar green" {
  seed_usage_cache 50 12 false
  write_config '{"version": 1, "color_thresholds": {"orange": 60}}'
  line2=$(run_bar | sed -n '2p')

  [[ "$line2" == *$'\x1b[38;2;0;160;0m'* ]]
  [[ "$line2" != *$'\x1b[38;2;255;176;85m'* ]]
}

@test "non-numeric threshold falls back to default" {
  seed_usage_cache 50 12 false
  baseline=$(run_bar)

  write_config '{"version": 1, "color_thresholds": {"orange": "loud"}}'
  configured=$(run_bar)

  [ "$baseline" = "$configured" ]
}

# ===== countdown vs clock =====

@test "reset_display countdown: line 3 shows relative times" {
  seed_usage_cache 55 12 false
  write_config '{"version": 1, "reset_display": "countdown"}'
  line3=$(run_bar_plain | sed -n '3p')

  [[ "$line3" == "↻ in "* ]]
  [[ "$line3" == *"| ↻ in "* ]]
}

@test "reset_display clock (default): line 3 shows wall-clock times" {
  seed_usage_cache 55 12 false
  line3=$(run_bar_plain | sed -n '3p')

  [[ "$line3" != *"in "* ]]
  [[ "$line3" == *":"* ]]
}

# ===== theme presets =====

@test "theme mono: no truecolor escapes, content intact" {
  seed_usage_cache 20 12 true 350
  seed_prepaid_cache
  write_config '{"version": 1, "theme": "mono"}'
  output=$(run_bar)

  [[ "$output" != *$'\x1b[38;2'* ]]
  plain=$(printf '%s' "$output" | strip_ansi)
  [[ "$plain" == *"ctx"* ]]
  [[ "$plain" == *"5h:"* ]]
  [[ "$plain" == *"€59.29"* ]]
}

@test "unknown theme falls back to default palette" {
  seed_usage_cache
  baseline=$(run_bar)

  write_config '{"version": 1, "theme": "vaporwave"}'
  configured=$(run_bar)

  [ "$baseline" = "$configured" ]
}

# ===== CLAUDEFUEL_CONFIG override (the preview seam) =====

@test "CLAUDEFUEL_CONFIG points the loader at an alternative config file" {
  seed_usage_cache
  write_config '{"version": 1, "segments": {"hide": ["thinking"]}}'
  alt="$BATS_TEST_TMPDIR/alt.json"
  printf '{"version": 1, "theme": "mono"}' > "$alt"

  out=$(CLAUDEFUEL_CONFIG="$alt" run_bar)

  # The override wins: mono palette, and the real file's hide is ignored.
  [[ "$out" != *$'\x1b[38;2'* ]]
  [[ "$(printf '%s' "$out" | strip_ansi)" == *"thinking"* ]]
}

@test "malformed CLAUDEFUEL_CONFIG override falls back to pure defaults" {
  seed_usage_cache
  baseline=$(run_bar)
  alt="$BATS_TEST_TMPDIR/broken.json"
  printf 'not json {' > "$alt"

  out=$(CLAUDEFUEL_CONFIG="$alt" run_bar)

  [ "$out" = "$baseline" ]
}

# ===== --validate-config =====

validate() {
  CLAUDEFUEL_CONFIG= "$STATUSLINE" --validate-config "$@"
}

@test "validate: valid sparse config reports ok with its overridden keys" {
  write_config '{"version": 1, "color_thresholds": {"red": 95}, "reset_display": "countdown"}'
  run validate "$CONFIG_FILE"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.schema')" = "claudefuel-config-check v1" ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "ok" ]
  [ "$(printf '%s' "$output" | jq -r '.effective.color_thresholds.red')" = "95" ]
  printf '%s' "$output" | jq -e '.overridden_keys == ["color_thresholds.red","reset_display"]' >/dev/null
}

@test "validate: malformed JSON exits 1 with a parse error" {
  write_config 'this is not json {'
  run validate "$CONFIG_FILE"
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "malformed" ]
  [ "$(printf '%s' "$output" | jq -r '.errors | length')" -ge 1 ]
}

@test "validate: absent file exits 2 with effective defaults" {
  run validate "$BATS_TEST_TMPDIR/does-not-exist.json"
  [ "$status" -eq 2 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "absent" ]
  [ "$(printf '%s' "$output" | jq -r '.effective.color_thresholds.red')" = "90" ]
}

@test "validate: out-of-order thresholds warn but do not error" {
  write_config '{"version": 1, "color_thresholds": {"orange": 80, "yellow": 60}}'
  run validate "$CONFIG_FILE"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "warnings" ]
  printf '%s' "$output" | jq -e '.warnings | map(select(test("out of order"))) | length == 1' >/dev/null
}

@test "validate: unknown hide token warns with a nearest-match suggestion" {
  write_config '{"version": 1, "segments": {"hide": ["7day"]}}'
  run validate "$CONFIG_FILE"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.warnings[0] | test("unknown token \"7day\"") and test("did you mean \"7d\"")' >/dev/null
}

@test "validate: unknown top-level key is info, not a warning" {
  write_config '{"version": 1, "future_key": {"a": 1}}'
  run validate "$CONFIG_FILE"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "ok" ]
  printf '%s' "$output" | jq -e '.info[0] | test("future_key")' >/dev/null
}

@test "validate: defaults agree with the render loader (single source of truth check)" {
  # A config of explicit defaults must produce zero overridden semantics:
  # the render with it is byte-identical to no config at all, and the
  # validate report's effective block equals the absent-file effective.
  seed_usage_cache
  baseline=$(run_bar)
  write_config '{"version":1,"theme":"default","color_thresholds":{"orange":50,"yellow":70,"red":90},"reset_display":"clock","segments":{"order":{"line1":["model","ctx","thinking","effort","drift"],"columns":["5h","7d","extra"]},"hide":[]}}'
  configured=$(run_bar)
  [ "$baseline" = "$configured" ]

  eff_file=$(validate "$CONFIG_FILE" | jq -S '.effective')
  eff_absent=$(validate "$BATS_TEST_TMPDIR/none.json" | jq -S '.effective' || true)
  [ "$eff_file" = "$eff_absent" ]
}
