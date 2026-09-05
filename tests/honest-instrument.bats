#!/usr/bin/env bats

# Tests for the honest-instrument display states in statusline.sh.
#
# Black-box CLI tests: isolate via CLAUDE_CONFIG_DIR, pre-seed caches,
# feed stdin, assert on stdout.
#
# Behavior under test (aviation instrument doctrine — a failed gauge must
# read FAILED, never a plausible value):
#   - Stale cache renders with an age marker (`62% ·9m`), never as fresh.
#   - Failure classes render a one-glyph diagnosis + `✚ /claudefuel.doctor`
#     trailhead when there is no data to show: ⊘ auth, ⚠ network, ? dep.
#   - The render path is read-only on credentials: an expired token is
#     never refreshed/rewritten from the bar.

SAMPLE_STDIN='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp"},"session_id":"t"}'

setup() {
  export FORCE_HYPERLINK=0  # hermetic: the host terminal must not toggle OSC 8
  CLAUDE_CONFIG_DIR=$(mktemp -d)
  export CLAUDE_CONFIG_DIR
  mkdir -p "$CLAUDE_CONFIG_DIR/cache"
  STATUSLINE="${BATS_TEST_DIRNAME}/../statusline.sh"

  # The auth-failure path must not pick up a real token from the env.
  unset CLAUDE_CODE_OAUTH_TOKEN

  # Silence drift segment regardless of network: seed cache to match installed.
  installed_version=$(grep -E '^# claudefuel:' "$STATUSLINE" | head -n1 \
    | sed -E 's/^# claudefuel: v//')
  printf '{"upstream_version":"%s"}\n' "$installed_version" \
    > "$CLAUDE_CONFIG_DIR/cache/claudefuel-version.json"

  USAGE_CACHE="$CLAUDE_CONFIG_DIR/cache/claudefuel-usage.json"
  PREPAID_CACHE="$CLAUDE_CONFIG_DIR/cache/claudefuel-prepaid.json"
  ORG_CACHE="$CLAUDE_CONFIG_DIR/cache/claudefuel-org-uuid"
}

teardown() {
  [ -n "$FAKEBIN" ] && [ -d "$FAKEBIN" ] && rm -rf "$FAKEBIN"
  [ -n "$CLAUDE_CONFIG_DIR" ] && [ -d "$CLAUDE_CONFIG_DIR" ] && rm -rf "$CLAUDE_CONFIG_DIR"
}

# Cross-platform ISO timestamp from an epoch.
iso_from_epoch() {
  local epoch=$1
  date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ"
}

# Seed usage cache with a healthy snapshot.
# Args: [extra_enabled=false] [used_credits=350]
# used_credits defaults to a live spend so the calm-cockpit extra-column
# gate (hidden until spend > $0) lets extra render when enabled.
seed_usage_cache() {
  local enabled=${1:-false} used_credits=${2:-350}
  local now fh_iso sd_iso
  now=$(date +%s)
  # 1h to reset (4h elapsed of the 5h window) keeps burn rate under
  # reset-pace at 62% (ratio ~0.78) — burn-radar's chip stays dormant so
  # the plain percent renders, which is what these tests check for.
  fh_iso=$(iso_from_epoch $(( now + 3600 )))
  sd_iso=$(iso_from_epoch $(( now + 432000 )))
  cat > "$USAGE_CACHE" <<EOF
{
  "five_hour":   { "utilization": 62, "resets_at": "$fh_iso" },
  "seven_day":   { "utilization": 12, "resets_at": "$sd_iso" },
  "extra_usage": { "is_enabled": $enabled, "used_credits": $used_credits }
}
EOF
  touch "$USAGE_CACHE"
}

# Backdate a file's mtime. Args: <minutes_ago> <file>
backdate_minutes() {
  local mins=$1 file=$2
  local ts
  ts=$(date -v-"${mins}"M +%Y%m%d%H%M.%S 2>/dev/null \
    || date -d "${mins} minutes ago" +%Y%m%d%H%M.%S)
  touch -t "$ts" "$file"
}

# Strip ANSI escape sequences so assertions can match on plain text.
strip_ansi() {
  sed -E $'s/\x1b\\[[0-9;]*m//g'
}

run_bar() {
  printf '%s' "$SAMPLE_STDIN" | "$STATUSLINE" | strip_ansi
}

@test "fresh cache: no staleness age marker on line 2" {
  seed_usage_cache

  output=$(CLAUDEFUEL_OFFLINE=1 run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"5h:"* ]]
  [[ "$line2" != *"·"* ]]
}

@test "stale cache: age marker ·9m appears on the 5h cell" {
  # Cache 9 minutes old, no credentials reachable from the temp profile —
  # the fetch can't happen, the stale snapshot still renders, but with an
  # honest age marker instead of posing as fresh.
  seed_usage_cache
  backdate_minutes 9 "$USAGE_CACHE"

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"·9m"* ]]
  [[ "$line2" == *"62%"* ]]
}

@test "stale cache: hour-scale ages render as ·<N>h" {
  seed_usage_cache
  backdate_minutes 125 "$USAGE_CACHE"

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"·2h"* ]]
}

@test "stale cache: data still renders, no doctor trailhead" {
  # Staleness is a degraded-but-usable state — the trailhead is reserved
  # for the no-data failure case.
  seed_usage_cache
  backdate_minutes 9 "$USAGE_CACHE"

  output=$(run_bar)

  [[ "$output" == *"5h:"* ]]
  [[ "$output" != *"✚ /claudefuel.doctor"* ]]
}

@test "auth failure, no cache: line 2 reads ⊘ ✚ /claudefuel.doctor" {
  # No usage cache and no credentials reachable from the temp profile.
  # A failed gauge must read FAILED — not render silence.
  rm -f "$USAGE_CACHE"

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"⊘"* ]]
  [[ "$line2" == *"✚ /claudefuel.doctor"* ]]
}

@test "failure trailhead does not grow bar height (≤2 lines, exit 0)" {
  rm -f "$USAGE_CACHE"

  run bash -c "printf '%s' '$SAMPLE_STDIN' | '$STATUSLINE'"
  [ "$status" -eq 0 ]
  line_count=$(printf '%s' "$output" | wc -l | tr -d ' ')
  # printf doesn't append final newline; 2 lines of content → 1 newline.
  [ "$line_count" -le 1 ]
}

@test "network failure, no cache: line 2 reads ⚠ ✚ /claudefuel.doctor" {
  # Token present (env) but curl fails — distinguishes network from auth.
  # No CLAUDEFUEL_OFFLINE here: on a first-ever render (no cache at all)
  # that flag now suppresses the fetch entirely (see never-block-render's
  # regression fix), which would prevent this failure from ever surfacing.
  rm -f "$USAGE_CACHE"
  FAKEBIN=$(mktemp -d)
  printf '#!/bin/sh\nexit 1\n' > "$FAKEBIN/curl"
  chmod +x "$FAKEBIN/curl"

  output=$(CLAUDE_CODE_OAUTH_TOKEN="dummy-token" \
    PATH="$FAKEBIN:$PATH" run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"⚠"* ]]
  [[ "$line2" == *"✚ /claudefuel.doctor"* ]]
}

@test "missing jq: bar reads FAILED with ? glyph and doctor trailhead" {
  # PATH stripped to a dir that has only `cat` — jq is unreachable. The
  # bar must diagnose the missing dependency instead of erroring mid-render.
  FAKEBIN=$(mktemp -d)
  ln -s "$(command -v cat)" "$FAKEBIN/cat"

  run bash -c "printf '%s' '$SAMPLE_STDIN' | PATH='$FAKEBIN' '$STATUSLINE'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"?"* ]]
  [[ "$output" == *"✚ /claudefuel.doctor"* ]]
}

@test "read-only credentials: expired creds file is never rewritten by the render path" {
  # Expired token in the Linux-style credentials file. The old behavior
  # refreshed and rewrote the store from the bar's hot path; now the bar
  # must leave credentials byte-identical and fall back to stale cache.
  cat > "$CLAUDE_CONFIG_DIR/.credentials.json" <<'EOF'
{"claudeAiOauth":{"accessToken":"expired-token","refreshToken":"refresh-token","expiresAt":1000000000000}}
EOF
  before=$(cat "$CLAUDE_CONFIG_DIR/.credentials.json")

  seed_usage_cache
  backdate_minutes 9 "$USAGE_CACHE"

  output=$(run_bar)
  after=$(cat "$CLAUDE_CONFIG_DIR/.credentials.json")

  [ "$before" = "$after" ]
  # Expired auth + stale cache → stale render with age marker, no refresh.
  [[ "$output" == *"·9m"* ]]
}

@test "prepaid stale: extra cell carries its own age marker" {
  seed_usage_cache true
  cat > "$PREPAID_CACHE" <<'EOF'
{"amount":5929,"currency":"EUR","auto_reload_settings":null,"pending_invoice_amount_cents":null,"last_paid_purchase_cents":null}
EOF
  backdate_minutes 6 "$PREPAID_CACHE"

  output=$(CLAUDEFUEL_OFFLINE=1 run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"€59.29 ·6m"* ]]
}

@test "prepaid fresh: no age marker on the extra cell" {
  seed_usage_cache true
  cat > "$PREPAID_CACHE" <<'EOF'
{"amount":5929,"currency":"EUR","auto_reload_settings":null,"pending_invoice_amount_cents":null,"last_paid_purchase_cents":null}
EOF
  touch "$PREPAID_CACHE"

  output=$(CLAUDEFUEL_OFFLINE=1 run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"€59.29"* ]]
  [[ "$line2" != *"·"* ]]
}
