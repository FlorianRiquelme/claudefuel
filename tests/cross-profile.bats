#!/usr/bin/env bats

# Tests for cross-profile headroom: the ⇄ switch hint on Line 2 and the
# --fleet machine-readable dump.
#
# Black-box CLI tests: isolate via a fake HOME (sibling discovery scans
# $HOME/.claude and $HOME/.claude-*) plus CLAUDE_CONFIG_DIR for the
# active profile. All caches are pre-seeded on disk so the script never
# touches OAuth or the network — sibling data is read-only by design.
#
# Behavior under test:
#   - Switch hint `⇄ <profile> <pct>% (<age>)` appears on Line 2 only
#     when the active governing window (max of 5h/7d) is hot (>=80%)
#     AND a sibling cache fresher than 6h shows >=20 points more
#     headroom. Dormant in every nominal state.
#   - Sibling cache age always renders alongside the sibling number.
#   - `statusline.sh --fleet` dumps one JSON object per known profile
#     cache (including the active profile), read-only, with
#     cache_age_seconds so stale rows are identifiable.

SAMPLE_STDIN='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp"},"session_id":"t"}'

setup() {
  # Fake HOME so sibling discovery sees only what this test seeds —
  # and never the real machine's ~/.claude-* profiles.
  FAKE_HOME=$(mktemp -d)
  export HOME="$FAKE_HOME"

  # Active profile lives outside the ~/.claude-* convention (mktemp).
  CLAUDE_CONFIG_DIR=$(mktemp -d)
  export CLAUDE_CONFIG_DIR
  mkdir -p "$CLAUDE_CONFIG_DIR/cache"
  STATUSLINE="${BATS_TEST_DIRNAME}/../statusline.sh"

  # Silence drift segment regardless of network: seed cache to match installed.
  installed_version=$(grep -E '^# claudefuel:' "$STATUSLINE" | head -n1 \
    | sed -E 's/^# claudefuel: v//')
  printf '{"upstream_version":"%s"}\n' "$installed_version" \
    > "$CLAUDE_CONFIG_DIR/cache/claudefuel-version.json"

  # Mirror statusline.sh's CACHE_SUFFIX derivation for the active cache.
  config_hash=$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)
  ACTIVE_CACHE="/tmp/claude/statusline-usage-cache-${config_hash}.json"
  mkdir -p /tmp/claude
}

teardown() {
  # Remove every cache this test's fake siblings produced.
  for d in "$FAKE_HOME"/.claude-*; do
    [ -d "$d" ] || continue
    local h
    h=$(printf '%s' "$d" | shasum -a 256 | cut -c1-8)
    rm -f "/tmp/claude/statusline-usage-cache-${h}.json" \
          "/tmp/claude/statusline-prepaid-cache-${h}.json"
  done
  rm -f "$ACTIVE_CACHE"
  [ -n "$CLAUDE_CONFIG_DIR" ] && [ -d "$CLAUDE_CONFIG_DIR" ] && rm -rf "$CLAUDE_CONFIG_DIR"
  [ -n "$FAKE_HOME" ] && [ -d "$FAKE_HOME" ] && rm -rf "$FAKE_HOME"
}

# Cross-platform ISO timestamp from an epoch.
iso_from_epoch() {
  local epoch=$1
  date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ"
}

# Write a usage cache snapshot. Args: <path> <5h_pct> <7d_pct>
write_usage_cache() {
  local path=$1 fh_pct=$2 sd_pct=$3
  local now fh_iso sd_iso
  now=$(date +%s)
  fh_iso=$(iso_from_epoch $(( now + 10800 )))
  sd_iso=$(iso_from_epoch $(( now + 432000 )))
  cat > "$path" <<EOF
{
  "five_hour":   { "utilization": $fh_pct, "resets_at": "$fh_iso" },
  "seven_day":   { "utilization": $sd_pct, "resets_at": "$sd_iso" },
  "extra_usage": { "is_enabled": false }
}
EOF
  touch "$path"
}

# Create a sibling profile dir under fake HOME and seed its usage cache.
# Args: <name> <5h_pct> <7d_pct>
# Sets LAST_SIBLING_CACHE to the seeded cache path.
seed_sibling() {
  local name=$1 fh_pct=$2 sd_pct=$3
  mkdir -p "$FAKE_HOME/.claude-$name"
  local h
  h=$(printf '%s' "$FAKE_HOME/.claude-$name" | shasum -a 256 | cut -c1-8)
  LAST_SIBLING_CACHE="/tmp/claude/statusline-usage-cache-${h}.json"
  write_usage_cache "$LAST_SIBLING_CACHE" "$fh_pct" "$sd_pct"
}

# Strip ANSI escape sequences so assertions can match on plain text.
strip_ansi() {
  sed -E $'s/\x1b\\[[0-9;]*m//g'
}

run_bar() {
  CLAUDEFUEL_OFFLINE=1 printf '%s' "$SAMPLE_STDIN" | "$STATUSLINE" | strip_ansi
}

# ===== Switch hint =====

@test "tracer: active hot + sibling headroom — ⇄ hint appears on line 2" {
  write_usage_cache "$ACTIVE_CACHE" 85 30
  seed_sibling work 12 8

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"⇄ work 12%"* ]]
}

@test "hint always carries the sibling cache age (honesty marker)" {
  write_usage_cache "$ACTIVE_CACHE" 85 30
  seed_sibling work 12 8

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" =~ ⇄\ work\ 12%\ \([0-9]+[smh]\) ]]
}

@test "no sibling caches: hint absent even when active is hot" {
  write_usage_cache "$ACTIVE_CACHE" 85 30

  output=$(run_bar)

  [[ "$output" != *"⇄"* ]]
}

@test "severity gate: hint absent when active is nominal, despite sibling headroom" {
  write_usage_cache "$ACTIVE_CACHE" 30 20
  seed_sibling work 12 8

  output=$(run_bar)

  [[ "$output" != *"⇄"* ]]
}

@test "stale sibling: cache older than 6h never drives a switch hint" {
  write_usage_cache "$ACTIVE_CACHE" 85 30
  seed_sibling work 12 8
  # Backdate the sibling cache well past the 6h freshness gate.
  touch -t 202001010000.00 "$LAST_SIBLING_CACHE"

  output=$(run_bar)

  [[ "$output" != *"⇄"* ]]
}

@test "headroom gate: sibling nearly as hot as active does not produce a hint" {
  write_usage_cache "$ACTIVE_CACHE" 85 30
  seed_sibling work 75 10

  output=$(run_bar)

  [[ "$output" != *"⇄"* ]]
}

@test "governing window: 7d-hot active triggers the hint even when its 5h is cool" {
  write_usage_cache "$ACTIVE_CACHE" 20 85
  seed_sibling work 12 8

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"⇄ work 12%"* ]]
}

@test "best sibling wins: hint names the profile with the most headroom" {
  write_usage_cache "$ACTIVE_CACHE" 85 30
  seed_sibling busy 60 40
  seed_sibling work 12 8

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"⇄ work 12%"* ]]
  [[ "$line2" != *"busy"* ]]
}

@test "hint does not grow bar height (still ≤3 lines)" {
  write_usage_cache "$ACTIVE_CACHE" 85 30
  seed_sibling work 12 8

  output=$(run_bar)
  line_count=$(printf '%s' "$output" | wc -l | tr -d ' ')
  # printf doesn't append final newline; 3 lines of content → 2 newlines.
  [ "$line_count" -le 2 ]
}

# ===== Fleet mode =====

@test "fleet: one JSON object per known profile cache, read from fixtures" {
  write_usage_cache "$ACTIVE_CACHE" 85 30
  seed_sibling work 12 8
  seed_sibling personal 44 22

  run "$STATUSLINE" --fleet
  [ "$status" -eq 0 ]

  # Three rows: active + two siblings, each valid JSON.
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 3 ]
  while IFS= read -r row; do
    echo "$row" | jq -e . >/dev/null
  done <<< "$output"

  [[ "$output" == *'"profile":"work"'* ]]
  [[ "$output" == *'"profile":"personal"'* ]]
  work_pct=$(printf '%s\n' "$output" | jq -r 'select(.profile=="work") | .five_hour.utilization')
  [ "$work_pct" = "12" ]
}

@test "fleet: includes the active profile even outside the ~/.claude-* convention" {
  write_usage_cache "$ACTIVE_CACHE" 85 30

  run "$STATUSLINE" --fleet
  [ "$status" -eq 0 ]

  active_pct=$(printf '%s\n' "$output" | jq -r '.five_hour.utilization')
  [ "$active_pct" = "85" ]
}

@test "fleet: every row carries cache_age_seconds; stale rows stay visible with their age" {
  seed_sibling work 12 8
  touch -t 202001010000.00 "$LAST_SIBLING_CACHE"

  run "$STATUSLINE" --fleet
  [ "$status" -eq 0 ]

  age=$(printf '%s\n' "$output" | jq -r 'select(.profile=="work") | .cache_age_seconds')
  [ "$age" -gt $((6 * 3600)) ]
}

@test "fleet: joins a sibling's prepaid cache when present" {
  seed_sibling work 12 8
  prepaid_file="${LAST_SIBLING_CACHE/statusline-usage-cache/statusline-prepaid-cache}"
  printf '{"amount":5929,"currency":"EUR"}\n' > "$prepaid_file"

  run "$STATUSLINE" --fleet
  [ "$status" -eq 0 ]

  amount=$(printf '%s\n' "$output" | jq -r 'select(.profile=="work") | .prepaid.amount')
  [ "$amount" = "5929" ]
}

@test "fleet: no known caches — exits 0 with empty output, never fetches" {
  run "$STATUSLINE" --fleet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
