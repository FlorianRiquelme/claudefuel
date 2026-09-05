#!/usr/bin/env bats

# Tests for the burn-radar additions in statusline.sh:
#   burn chip      — `~XhYYm ×N.N` (time-at-pace + normalized burn ratio)
#                    replacing the 5h percent on Line 2 while burning hot;
#                    dormant when ratio ≤ 1.0 or pct < 10.
#   steer-to       — `slow ≤N.N×` appended to the cap-ETA segment: the pace
#                    multiple (vs reset-pace) that survives until reset.
#   stranding gap  — `⚓ XhYYm` appended to the cap-ETA segment: dead time
#                    between projected cap and reset; dormant under 5min.
#   horizon band   — cap-ETA range is ±15% of time-to-cap, floored at ±5min
#                    (replaces the fixed ±15min band).
#   countdown      — CLAUDEFUEL_RESET_COUNTDOWN=1 renders the 5h reset as
#                    `↻ in XhYYm`; default stays the wall-clock contract.
#
# Black-box CLI tests, same pattern as cap-eta.bats: isolate via
# CLAUDE_CONFIG_DIR, pre-seed the usage cache, feed stdin, assert stdout.

SAMPLE_STDIN='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp"},"session_id":"t"}'

setup() {
  export FORCE_HYPERLINK=0  # hermetic: the host terminal must not toggle OSC 8
  CLAUDE_CONFIG_DIR=$(mktemp -d)
  export CLAUDE_CONFIG_DIR
  mkdir -p "$CLAUDE_CONFIG_DIR/cache"
  STATUSLINE="${BATS_TEST_DIRNAME}/../statusline.sh"

  # Silence drift segment regardless of network: seed cache to match installed.
  installed_version=$(grep -E '^# claudefuel:' "$STATUSLINE" | head -n1 \
    | sed -E 's/^# claudefuel: v//')
  printf '{"upstream_version":"%s"}\n' "$installed_version" \
    > "$CLAUDE_CONFIG_DIR/cache/claudefuel-version.json"

  USAGE_CACHE="$CLAUDE_CONFIG_DIR/cache/claudefuel-usage.json"
}

teardown() {
  [ -n "$CLAUDE_CONFIG_DIR" ] && [ -d "$CLAUDE_CONFIG_DIR" ] && rm -rf "$CLAUDE_CONFIG_DIR"
}

# Cross-platform ISO timestamp from an epoch.
iso_from_epoch() {
  local epoch=$1
  date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ"
}

# Seed usage cache with a 5h-window snapshot relative to "now".
# Elapsed time in the window is implied: 18000s − <5h_remaining_seconds>.
# Args: <5h_pct> <5h_remaining_seconds> [<7d_pct>=12] [<7d_remaining_seconds>=432000]
seed_usage_cache() {
  local fh_pct=$1 fh_remaining=$2
  local sd_pct=${3:-12} sd_remaining=${4:-432000}
  local now fh_resets sd_resets
  now=$(date +%s)
  fh_resets=$(( now + fh_remaining ))
  sd_resets=$(( now + sd_remaining ))
  local fh_iso sd_iso
  fh_iso=$(iso_from_epoch "$fh_resets")
  sd_iso=$(iso_from_epoch "$sd_resets")

  cat > "$USAGE_CACHE" <<EOF
{
  "five_hour":   { "utilization": $fh_pct, "resets_at": "$fh_iso" },
  "seven_day":   { "utilization": $sd_pct, "resets_at": "$sd_iso" },
  "extra_usage": { "is_enabled": false }
}
EOF
  touch "$USAGE_CACHE"
}

strip_ansi() {
  sed -E $'s/\x1b\\[[0-9;]*m//g'
}

run_bar() {
  printf '%s' "$SAMPLE_STDIN" | CLAUDEFUEL_OFFLINE=1 "$STATUSLINE" | strip_ansi
}

col1_of_line() {
  # Args: <output> <line_number>
  printf '%s' "$1" | sed -n "${2}p" | awk -F'|' '{print $1}'
}

# Convert "h:mmam"/"h:mmpm" to minutes-of-day.
mins_of() {
  local t=$1
  local h=${t%%:*}
  local rest=${t#*:}
  local m=${rest:0:2}
  local ap=${rest:2}
  h=$(( 10#$h % 12 ))
  m=$(( 10#$m ))
  [ "$ap" = "pm" ] && h=$(( h + 12 ))
  echo $(( h * 60 + m ))
}

# Width in minutes of the ~cap range on line 3. Args: <output>
cap_range_width() {
  local line3 low high
  line3=$(printf '%s' "$1" | sed -n '3p')
  low=$(printf '%s' "$line3"  | sed -E 's/.*~cap ([0-9]+:[0-9]+[ap]m)-([0-9]+:[0-9]+[ap]m).*/\1/')
  high=$(printf '%s' "$line3" | sed -E 's/.*~cap ([0-9]+:[0-9]+[ap]m)-([0-9]+:[0-9]+[ap]m).*/\2/')
  echo $(( ( $(mins_of "$high") - $(mins_of "$low") + 1440 ) % 1440 ))
}

@test "burn chip: time-at-pace + ratio replace the 5h percent while burning hot" {
  # 55% used, 2h elapsed, 3h to reset. Burn rate 27.5%/h vs reset-pace
  # 20%/h → ratio ×1.4. Time-at-pace = 45% ÷ 27.5%/h ≈ 1h38m.
  seed_usage_cache 55 10800

  output=$(run_bar)
  col1=$(col1_of_line "$output" 2)

  [[ "$col1" == *"~1h38m"* ]]
  [[ "$col1" == *"×1.4"* ]]
  [[ "$col1" != *"55%"* ]]
}

@test "ratio math: 60% at 2h elapsed renders ×1.5" {
  # rate 30%/h ÷ reset-pace 20%/h = 1.5; time-at-pace 40 ÷ 30%/h = 1h20m.
  seed_usage_cache 60 10800

  output=$(run_bar)
  col1=$(col1_of_line "$output" 2)

  [[ "$col1" == *"×1.5"* ]]
  [[ "$col1" == *"~1h20m"* ]]
}

@test "dormant ≤1.0: under-pace window keeps the plain percent, no chip" {
  # 30% at 2h elapsed → ratio 0.75. Chip must be dormant; percent shows.
  # 7d bumped non-nominal (55%) so the calm-cockpit collapse (both windows
  # <50%) doesn't hide line 2 entirely — unrelated to what's under test.
  seed_usage_cache 30 10800 55

  output=$(run_bar)
  col1=$(col1_of_line "$output" 2)

  [[ "$col1" == *"30%"* ]]
  [[ "$col1" != *"×"* ]]
  [[ "$col1" != *"~"* ]]
}

@test "noise floor: chip dormant below 10% even at a huge momentary ratio" {
  # 8% used 5min into the window → ratio ~4.8, but below the noise floor
  # a single heavy prompt dominates the rate (ADR-0004). Percent shows.
  # 7d bumped non-nominal (55%) so calm-cockpit collapse doesn't hide
  # line 2 entirely — unrelated to what's under test.
  seed_usage_cache 8 17700 55

  output=$(run_bar)
  col1=$(col1_of_line "$output" 2)

  [[ "$col1" == *"8%"* ]]
  [[ "$col1" != *"×"* ]]
}

@test "5h-only scope: the 7d cell never carries a chip" {
  # 7d burning hot too (80%, 1 day to reset) — chip is 5h-only.
  seed_usage_cache 55 10800 80 86400

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')
  col2=$(printf '%s' "$line2" | awk -F'|' '{print $2}')

  [[ "$col2" == *"80%"* ]]
  [[ "$col2" != *"×"* ]]
}

@test "steer-to: cap-ETA carries the slow-down instruction" {
  # Remaining 45% over 3h ÷ reset-pace = 0.75, floored to one decimal
  # → "slow ≤0.7×" (never rounds up: the instruction must stay safe).
  seed_usage_cache 55 10800

  output=$(run_bar)
  line3=$(printf '%s' "$output" | sed -n '3p')

  [[ "$line3" == *"~cap"* ]]
  [[ "$line3" == *"slow ≤0.7×"* ]]
}

@test "stranding gap: dead time between projected cap and reset" {
  # cap-ETA ≈ now+1h38m, reset at now+3h → gap ≈ 1h21m of dead time.
  seed_usage_cache 55 10800

  output=$(run_bar)
  line3=$(printf '%s' "$output" | sed -n '3p')

  [[ "$line3" == *"⚓ 1h21m"* ]]
}

@test "stranding gap dormant under 5min: cap-ETA shows, anchor does not" {
  # 75% used, 1h17.5m to reset, 3h42.5m elapsed → cap lands ~3min before
  # reset. Sub-5min stranding isn't actionable — anchor must stay hidden.
  seed_usage_cache 75 4650

  output=$(run_bar)
  line3=$(printf '%s' "$output" | sed -n '3p')

  [[ "$line3" == *"~cap"* ]]
  [[ "$line3" != *"⚓"* ]]
}

@test "steer-to and anchor are gated on cap-ETA: absent when healthy" {
  seed_usage_cache 30 10800

  output=$(run_bar)
  line3=$(printf '%s' "$output" | sed -n '3p')

  [[ "$line3" != *"~cap"* ]]
  [[ "$line3" != *"slow"* ]]
  [[ "$line3" != *"⚓"* ]]
}

@test "horizon band: near cap the range narrows to the ±5min floor" {
  # 90% at 2h elapsed → time-to-cap ≈ 13m. 15% of that is under the
  # floor, so the band is ±5min → range exactly 10 minutes wide.
  seed_usage_cache 90 10800

  output=$(run_bar)
  width=$(cap_range_width "$output")

  [ "$width" -eq 10 ]
}

@test "horizon band: far cap widens beyond the old fixed ±15min" {
  # 45% at 2h elapsed → time-to-cap ≈ 2h27m. Band = ±15% of horizon
  # = ±22m → range exactly 44 minutes wide (old fixed band was 30).
  seed_usage_cache 45 10800

  output=$(run_bar)
  width=$(cap_range_width "$output")

  [ "$width" -eq 44 ]
}

@test "countdown opt-in: CLAUDEFUEL_RESET_COUNTDOWN=1 renders ↻ in XhYYm" {
  # 3h0m30s to reset → countdown floor lands on "in 3h00m". 7d bumped
  # non-nominal (55%) so calm-cockpit collapse doesn't hide line 3.
  seed_usage_cache 30 10830 55

  output=$(printf '%s' "$SAMPLE_STDIN" \
    | CLAUDEFUEL_OFFLINE=1 CLAUDEFUEL_RESET_COUNTDOWN=1 "$STATUSLINE" | strip_ansi)
  col1=$(col1_of_line "$output" 3)

  [[ "$col1" == *"↻ in 3h00m"* ]]
}

@test "countdown default off: 5h reset stays a wall-clock time" {
  # 7d bumped non-nominal (55%) so calm-cockpit collapse doesn't hide line 3.
  seed_usage_cache 30 10830 55

  output=$(run_bar)
  col1=$(col1_of_line "$output" 3)

  [[ "$col1" == *"↻ "* ]]
  [[ "$col1" != *"↻ in "* ]]
  [[ "$col1" =~ [0-9]:[0-9][0-9][ap]m ]]
}

@test "burning state still ≤3 lines (chip and extensions are inline)" {
  seed_usage_cache 55 10800

  output=$(run_bar)
  line_count=$(printf '%s' "$output" | wc -l | tr -d ' ')
  # printf doesn't append final newline; 3 lines of content → 2 newlines.
  [ "$line_count" -le 2 ]
}

@test "line 2/3 pipes stay aligned when the chip widens col1" {
  seed_usage_cache 55 10800

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')
  line3=$(printf '%s' "$output" | sed -n '3p')
  # bash ${#} is character-aware (awk length() counts bytes for ●/⚓/×).
  col1_2="${line2%%|*}"
  col1_3="${line3%%|*}"

  [ "${#col1_2}" -eq "${#col1_3}" ]
}
