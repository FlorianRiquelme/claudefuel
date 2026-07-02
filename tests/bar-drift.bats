#!/usr/bin/env bats

# Tests for drift detection in statusline.sh.
# We treat the script as a black-box CLI: isolate via CLAUDE_CONFIG_DIR
# (its natural seam — both cache file location and account scoping flow
# through it), pre-seed the cache so HTTP is never attempted, feed stdin,
# assert on stdout.
#
# We do NOT test the live curl path — that's exercised manually. The
# load-bearing behavior here is "drift segment appears iff cached-upstream
# is strictly newer than installed", which is fully observable through
# the cache. Equal or installed-ahead-of-cache states must stay silent —
# a fresh local update can outrun the 6h cache TTL.

SAMPLE_STDIN='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp"},"session_id":"t"}'

setup() {
  CLAUDE_CONFIG_DIR=$(mktemp -d)
  export CLAUDE_CONFIG_DIR
  mkdir -p "$CLAUDE_CONFIG_DIR/cache"
  STATUSLINE="${BATS_TEST_DIRNAME}/../statusline.sh"
  INSTALLED_VERSION=$(grep -E '^# claudefuel:' "$STATUSLINE" | head -n1 \
    | sed -E 's/^# claudefuel: v//')
}

teardown() {
  [ -n "$CLAUDE_CONFIG_DIR" ] && [ -d "$CLAUDE_CONFIG_DIR" ] && rm -rf "$CLAUDE_CONFIG_DIR"
}

seed_cache() {
  local upstream_version="$1"
  printf '{"upstream_version":"%s"}\n' "$upstream_version" \
    > "$CLAUDE_CONFIG_DIR/cache/claudefuel-version.json"
}

run_bar() {
  printf '%s' "$SAMPLE_STDIN" | "$STATUSLINE"
}

@test "no ↗ segment when cached upstream equals installed" {
  seed_cache "$INSTALLED_VERSION"
  output=$(run_bar)
  line1=$(printf '%s' "$output" | head -n1)
  [[ "$line1" != *"↗"* ]]
  [[ "$line1" != *"/claudefuel.update"* ]]
}

@test "↗ /claudefuel.update appears on line 1 when cached upstream is newer" {
  seed_cache "9.9.9"
  output=$(run_bar)
  line1=$(printf '%s' "$output" | head -n1)
  [[ "$line1" == *"↗"* ]]
  [[ "$line1" == *"/claudefuel.update"* ]]
}

@test "no ↗ segment when installed is newer than cached upstream" {
  # Post-release window: the local install was just updated but the cache
  # still holds the previous upstream version (6h TTL, or a lagging CDN).
  seed_cache "0.0.1"
  output=$(run_bar)
  line1=$(printf '%s' "$output" | head -n1)
  [[ "$line1" != *"↗"* ]]
  [[ "$line1" != *"/claudefuel.update"* ]]
}

@test "drift segment does not grow bar height (still ≤3 lines)" {
  seed_cache "9.9.9"
  output=$(run_bar)
  line_count=$(printf '%s' "$output" | wc -l | tr -d ' ')
  # printf doesn't append final newline; wc -l counts newline chars.
  # 3 lines of content → 2 newlines. Allow up to 2.
  [ "$line_count" -le 2 ]
}

@test "no cache + offline: bar renders without crashing, no ↗ segment" {
  # Genuine first-run state — cache directory exists but no version file.
  # CLAUDEFUEL_OFFLINE prevents the fetch; the bar must still emit a line 1.
  CLAUDEFUEL_OFFLINE=1 run run_bar
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  line1=$(printf '%s' "$output" | head -n1)
  [[ "$line1" != *"↗"* ]]
}

@test "stale cache + offline: cached value still drives drift decision" {
  # Seed cache with a 'drifted' upstream, then backdate mtime past TTL.
  # With CLAUDEFUEL_OFFLINE no fetch is attempted, so the stale-but-known
  # upstream value drives rendering — drift segment still appears.
  seed_cache "9.9.9"
  # touch -t YYYYMMDDhhmm.ss — well past 6h ago
  touch -t 202001010000.00 "$CLAUDE_CONFIG_DIR/cache/claudefuel-version.json"
  CLAUDEFUEL_OFFLINE=1 run run_bar
  [ "$status" -eq 0 ]
  line1=$(printf '%s' "$output" | head -n1)
  [[ "$line1" == *"↗"* ]]
  [[ "$line1" == *"/claudefuel.update"* ]]
}
