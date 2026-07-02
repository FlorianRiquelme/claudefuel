#!/usr/bin/env bats

# Tests for the calm-cockpit rendering contract in statusline.sh.
#
# Black-box CLI tests: isolate via CLAUDE_CONFIG_DIR, pre-seed the usage,
# prepaid, and version caches so the script never touches OAuth or the
# network, feed stdin, assert on stdout.
#
# Contract under test (earn-your-pixels):
#   - Lines 2-3 collapse entirely when all windows are nominal:
#     5h and 7d below 50% (first alarm threshold), no window projected
#     to cap before its own reset, no live extra spend. Line 1 always
#     renders.
#   - >=90% escalates with shape/weight (⚠ label prefix, inverse-video
#     pct), not hue alone.
#   - The governing constraint — whichever window hits 100% first at the
#     current burn rate — carries a ▸ marker (stable layout, no
#     reordering).
#   - Extra column hidden until spend is live (used_credits > 0).
#   - Drift arrow severity-gated: patch-level drift renders faint (dim),
#     minor/major drift keeps the yellow weight.

SAMPLE_STDIN='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp"},"session_id":"t"}'

setup() {
  export FORCE_HYPERLINK=0  # hermetic: the host terminal must not toggle OSC 8
  CLAUDE_CONFIG_DIR=$(mktemp -d)
  export CLAUDE_CONFIG_DIR
  mkdir -p "$CLAUDE_CONFIG_DIR/cache"
  STATUSLINE="${BATS_TEST_DIRNAME}/../statusline.sh"

  INSTALLED_VERSION=$(grep -E '^# claudefuel:' "$STATUSLINE" | head -n1 \
    | sed -E 's/^# claudefuel: v//')

  # Silence drift segment by default: seed cache to match installed.
  printf '{"upstream_version":"%s"}\n' "$INSTALLED_VERSION" \
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

# Cross-platform ISO timestamp from an epoch.
iso_from_epoch() {
  local epoch=$1
  date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ"
}

# Seed usage cache with snapshots for both windows relative to "now".
# Window starts are derived by the script from resets_at minus window
# length, so "remaining seconds" fully fixes each window's burn rate.
# Args: <5h_pct> <5h_remaining_s> <7d_pct> <7d_remaining_s>
#       [<extra_enabled>=false] [<used_credits>=0]
seed_usage_cache() {
  local fh_pct=$1 fh_remaining=$2 sd_pct=$3 sd_remaining=$4
  local extra_enabled=${5:-false} used_credits=${6:-0}
  local now fh_iso sd_iso
  now=$(date +%s)
  fh_iso=$(iso_from_epoch $(( now + fh_remaining )))
  sd_iso=$(iso_from_epoch $(( now + sd_remaining )))

  cat > "$USAGE_CACHE" <<EOF
{
  "five_hour":   { "utilization": $fh_pct, "resets_at": "$fh_iso" },
  "seven_day":   { "utilization": $sd_pct, "resets_at": "$sd_iso" },
  "extra_usage": { "is_enabled": $extra_enabled, "used_credits": $used_credits }
}
EOF
  touch "$USAGE_CACHE"
}

seed_prepaid_cache() {
  printf '{"amount":5929,"currency":"EUR"}\n' > "$PREPAID_CACHE"
  touch "$PREPAID_CACHE"
}

strip_ansi() {
  sed -E $'s/\x1b\\[[0-9;]*m//g'
}

run_bar() {
  CLAUDEFUEL_OFFLINE=1 printf '%s' "$SAMPLE_STDIN" | "$STATUSLINE"
}

# printf emits no trailing newline: N lines of content -> N-1 newlines.
line_count() {
  printf '%s' "$1" | wc -l | tr -d ' '
}

# ---- Nominal collapse ----

@test "nominal: lines 2-3 collapse, only line 1 renders" {
  # 5h: 20% with 3h left (elapsed 2h, burn 10%/h < 20%/h reset-pace).
  # 7d: 12% with 2d left (elapsed 5d, burn ~2.4%/d — far under pace).
  # Extra disabled. All gates calm -> single-line bar.
  seed_usage_cache 20 10800 12 172800

  output=$(run_bar)
  [ "$(line_count "$output")" -eq 0 ]
  line1=$(printf '%s' "$output" | head -n1)
  [ -n "$line1" ]
}

@test "non-nominal: a window at >=50% grows the bar back to 3 lines" {
  # 5h: 55% with 1h left (elapsed 4h, burn 13.75%/h — under pace, no
  # cap), but 55% crosses the first alarm threshold. Bar must grow.
  seed_usage_cache 55 3600 12 172800

  output=$(run_bar)
  [ "$(line_count "$output")" -eq 2 ]
}

@test "non-nominal calm-ish: no ▸ and no ⚠ when above 50% but under pace" {
  # Same fixture: 55% visible, but no projected cap and below 90%.
  # Escalation marks must stay dormant — the bar growing is the alarm.
  seed_usage_cache 55 3600 12 172800

  output=$(run_bar)
  plain=$(printf '%s' "$output" | strip_ansi)
  [[ "$plain" != *"▸"* ]]
  [[ "$plain" != *"⚠"* ]]
}

# ---- >=90% escalation: shape/weight, not hue alone ----

@test ">=90%: 5h column escalates with ⚠ prefix" {
  # 5h: 92% with 3h left (elapsed 2h) — way past 90%.
  seed_usage_cache 92 10800 12 172800

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p' | strip_ansi)
  [[ "$line2" == *"⚠5h:"* ]]
}

@test ">=90%: pct renders in inverse video (weight, not hue alone)" {
  # remaining=1200 (20min) at 92% keeps burn rate just under reset-pace
  # (ratio ~0.99) so burn-radar's chip stays dormant and the plain
  # percent is what gets escalated — the case this test targets.
  seed_usage_cache 92 1200 12 172800

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')
  # \x1b[7m = inverse video — survives even when hue is indistinguishable.
  [[ "$line2" == *$'\x1b[7m92%'* ]]
}

@test "below 90%: no ⚠ and no inverse video" {
  seed_usage_cache 55 3600 12 172800

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')
  [[ "$line2" != *"⚠"* ]]
  [[ "$line2" != *$'\x1b[7m'* ]]
}

@test ">=90%: 7d column escalates independently" {
  # 7d: 91% with 2d left. 5h calm at 20%.
  seed_usage_cache 20 10800 91 172800

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p' | strip_ansi)
  [[ "$line2" == *"⚠7d:"* ]]
  [[ "$line2" != *"⚠5h:"* ]]
}

# ---- Governing constraint (▸) ----

@test "governing: ▸ marks 5h when only 5h projects to cap before reset" {
  # 5h: 50% halfway in (elapsed 2h, 3h left) — caps at +2h, before reset.
  # 7d: 12% with 2d left — never caps.
  seed_usage_cache 50 10800 12 172800

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p' | strip_ansi)
  col1=$(printf '%s' "$line2" | awk -F'|' '{print $1}')
  col2=$(printf '%s' "$line2" | awk -F'|' '{print $2}')
  [[ "$col1" == *"▸5h:"* ]]
  [[ "$col2" != *"▸"* ]]
}

@test "governing: ▸ marks 7d when only 7d projects to cap before reset" {
  # 5h: 20% under pace — no cap.
  # 7d: 40% one day into the window (6d left) — burn 40%/d projects cap
  # at +1.5d, well before the 6d reset.
  seed_usage_cache 20 10800 40 518400

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p' | strip_ansi)
  col1=$(printf '%s' "$line2" | awk -F'|' '{print $1}')
  col2=$(printf '%s' "$line2" | awk -F'|' '{print $2}')
  [[ "$col2" == *"▸7d:"* ]]
  [[ "$col1" != *"▸"* ]]
}

@test "governing: both capping -> ▸ only on the earlier window (5h)" {
  # 5h caps at +2h; 7d caps at +1.5d. The 5h window governs.
  seed_usage_cache 50 10800 40 518400

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p' | strip_ansi)
  col1=$(printf '%s' "$line2" | awk -F'|' '{print $1}')
  col2=$(printf '%s' "$line2" | awk -F'|' '{print $2}')
  [[ "$col1" == *"▸5h:"* ]]
  [[ "$col2" != *"▸"* ]]
}

@test "governing: layout is stable — 5h column stays first even when 7d governs" {
  seed_usage_cache 20 10800 40 518400

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p' | strip_ansi)
  col1=$(printf '%s' "$line2" | awk -F'|' '{print $1}')
  [[ "$col1" == *"5h:"* ]]
}

@test "governing: a projected cap defeats nominal collapse even below 50%" {
  # 7d: 40% after 1 day — below the 50% hue threshold but on pace to cap
  # before reset. The bar must grow; collapse would hide a live risk.
  seed_usage_cache 20 10800 40 518400

  output=$(run_bar)
  [ "$(line_count "$output")" -eq 2 ]
}

# ---- Extra column: hidden until spend is live ----

@test "extra spend at \$0: column hidden even with prepaid balance cached" {
  seed_usage_cache 55 3600 12 172800 true 0
  seed_prepaid_cache

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p' | strip_ansi)
  [[ "$line2" != *"extra:"* ]]
}

@test "extra spend live: balance surfaces as runway" {
  seed_usage_cache 55 3600 12 172800 true 350
  seed_prepaid_cache

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p' | strip_ansi)
  [[ "$line2" == *"extra:"* ]]
  [[ "$line2" == *"€59.29"* ]]
}

@test "extra spend live defeats nominal collapse even when windows are calm" {
  seed_usage_cache 20 10800 12 172800 true 350
  seed_prepaid_cache

  output=$(run_bar)
  [ "$(line_count "$output")" -eq 2 ]
  line2=$(printf '%s' "$output" | sed -n '2p' | strip_ansi)
  [[ "$line2" == *"extra:"* ]]
}

# ---- Drift arrow: severity-gated weight ----

@test "drift severity: patch-level bump renders the arrow faint (dim)" {
  major=$(printf '%s' "$INSTALLED_VERSION" | cut -d. -f1)
  minor=$(printf '%s' "$INSTALLED_VERSION" | cut -d. -f2)
  patch=$(printf '%s' "$INSTALLED_VERSION" | cut -d. -f3)
  printf '{"upstream_version":"%s.%s.%s"}\n' "$major" "$minor" "$((patch + 1))" \
    > "$CLAUDE_CONFIG_DIR/cache/claudefuel-version.json"
  seed_usage_cache 20 10800 12 172800

  output=$(run_bar)
  line1=$(printf '%s' "$output" | head -n1)
  [[ "$line1" == *"↗ /claudefuel.update"* ]]
  # \x1b[2m = faint weight immediately before the arrow.
  [[ "$line1" == *$'\x1b[2m↗'* ]]
}

@test "drift severity: minor bump keeps the yellow weight" {
  major=$(printf '%s' "$INSTALLED_VERSION" | cut -d. -f1)
  minor=$(printf '%s' "$INSTALLED_VERSION" | cut -d. -f2)
  printf '{"upstream_version":"%s.%s.0"}\n' "$major" "$((minor + 1))" \
    > "$CLAUDE_CONFIG_DIR/cache/claudefuel-version.json"
  seed_usage_cache 20 10800 12 172800

  output=$(run_bar)
  line1=$(printf '%s' "$output" | head -n1)
  [[ "$line1" == *$'\x1b[38;2;230;200;0m↗'* ]]
  [[ "$line1" != *$'\x1b[2m↗'* ]]
}

@test "drift severity: major bump keeps the yellow weight" {
  printf '{"upstream_version":"99.0.0"}\n' \
    > "$CLAUDE_CONFIG_DIR/cache/claudefuel-version.json"
  seed_usage_cache 20 10800 12 172800

  output=$(run_bar)
  line1=$(printf '%s' "$output" | head -n1)
  [[ "$line1" == *$'\x1b[38;2;230;200;0m↗'* ]]
}
