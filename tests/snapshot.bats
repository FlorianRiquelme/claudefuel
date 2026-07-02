#!/usr/bin/env bats

# Tests for `statusline.sh --snapshot` — the versioned machine-readable
# internal API consumed by /claudefuel.why and /claudefuel.coach.
#
# Contract under test:
#   - valid JSON, no stdin required
#   - carries a schema version field (.schema.name / .schema.version)
#   - includes the ADR-0004 derivation inputs and outputs (pct, elapsed,
#     burn rate, reset-pace, cap-ETA, gate decisions)
#   - pure read: no fetches, no cache writes

SNAPSHOT_SCHEMA_VERSION=2

setup() {
  export FORCE_HYPERLINK=0  # hermetic: the host terminal must not toggle OSC 8
  CLAUDE_CONFIG_DIR=$(mktemp -d)
  export CLAUDE_CONFIG_DIR
  mkdir -p "$CLAUDE_CONFIG_DIR/cache"
  STATUSLINE="${BATS_TEST_DIRNAME}/../statusline.sh"

  # Seed the version cache so .versions is deterministic (drift = false).
  installed_version=$(grep -E '^# claudefuel:' "$STATUSLINE" | head -n1 \
    | sed -E 's/^# claudefuel: v//')
  printf '{"upstream_version":"%s"}\n' "$installed_version" \
    > "$CLAUDE_CONFIG_DIR/cache/claudefuel-version.json"

  # Mirror statusline.sh's CACHE_SUFFIX derivation to locate the caches.
  config_hash=$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)
  USAGE_CACHE="/tmp/claude/statusline-usage-cache-${config_hash}.json"
  PREPAID_CACHE="/tmp/claude/statusline-prepaid-cache-${config_hash}.json"
  mkdir -p /tmp/claude
}

teardown() {
  [ -n "$USAGE_CACHE" ] && rm -f "$USAGE_CACHE"
  [ -n "$PREPAID_CACHE" ] && rm -f "$PREPAID_CACHE"
  [ -n "$CLAUDE_CONFIG_DIR" ] && [ -d "$CLAUDE_CONFIG_DIR" ] && rm -rf "$CLAUDE_CONFIG_DIR"
}

iso_from_epoch() {
  local epoch=$1
  date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ"
}

# Seed usage cache with a 5h-window snapshot relative to "now".
# Args: <5h_pct> <5h_elapsed_seconds> <5h_remaining_seconds>
seed_usage_cache() {
  local fh_pct=$1 fh_elapsed=$2 fh_remaining=$3
  local now fh_iso sd_iso
  now=$(date +%s)
  fh_iso=$(iso_from_epoch $(( now + fh_remaining )))
  sd_iso=$(iso_from_epoch $(( now + 432000 )))

  cat > "$USAGE_CACHE" <<EOF
{
  "five_hour":   { "utilization": $fh_pct, "resets_at": "$fh_iso" },
  "seven_day":   { "utilization": 12, "resets_at": "$sd_iso" },
  "extra_usage": { "is_enabled": false }
}
EOF
  touch "$USAGE_CACHE"
}

@test "--snapshot emits valid JSON without stdin" {
  seed_usage_cache 50 7200 10800
  run "$STATUSLINE" --snapshot
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e . >/dev/null
}

@test "snapshot carries a versioned schema field" {
  run "$STATUSLINE" --snapshot
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.schema.name')" = "claudefuel-snapshot" ]
  [ "$(printf '%s' "$output" | jq -r '.schema.version')" = "$SNAPSHOT_SCHEMA_VERSION" ]
}

@test "snapshot includes the ADR-0004 derivation inputs and chain (burning hot)" {
  # 50% used, 2h elapsed, 3h to reset → burn rate 25%/h > reset-pace 20%/h.
  seed_usage_cache 50 7200 10800
  snap=$("$STATUSLINE" --snapshot)

  # Raw inputs surfaced verbatim
  [ "$(echo "$snap" | jq -r '.usage.five_hour.utilization')" = "50" ]
  [ "$(echo "$snap" | jq -r '.usage.five_hour.resets_at != null')" = "true" ]

  # Derived chain: window_started = resets_at − 5h; elapsed ≈ 7200
  echo "$snap" | jq -e '.derived.five_hour.window_length_seconds == 18000' >/dev/null
  echo "$snap" | jq -e '.derived.five_hour.elapsed_seconds >= 7195 and .derived.five_hour.elapsed_seconds <= 7210' >/dev/null
  echo "$snap" | jq -e '.derived.five_hour.window_started_epoch == .derived.five_hour.resets_at_epoch - 18000' >/dev/null

  # burn rate 25%/h beats reset-pace 20%/h
  echo "$snap" | jq -e '.derived.five_hour.burn_rate_pct_per_hour > .derived.five_hour.reset_pace_pct_per_hour' >/dev/null

  # cap-ETA lands before the reset, both gates pass, segment rendered
  echo "$snap" | jq -e '.derived.five_hour.cap_eta_epoch < .derived.five_hour.resets_at_epoch' >/dev/null
  echo "$snap" | jq -e '.derived.five_hour.gates.noise_floor.pass == true' >/dev/null
  echo "$snap" | jq -e '.derived.five_hour.gates.threshold.pass == true' >/dev/null
  echo "$snap" | jq -e '.derived.five_hour.cap_eta_rendered == true' >/dev/null
}

@test "threshold gate fails when burn rate is below reset-pace" {
  # 10% used, 2h elapsed → 5%/h, far under 20%/h. Noise floor passes (10 >= 10).
  seed_usage_cache 10 7200 10800
  snap=$("$STATUSLINE" --snapshot)

  echo "$snap" | jq -e '.derived.five_hour.gates.noise_floor.pass == true' >/dev/null
  echo "$snap" | jq -e '.derived.five_hour.gates.threshold.pass == false' >/dev/null
  echo "$snap" | jq -e '.derived.five_hour.cap_eta_rendered == false' >/dev/null
}

@test "noise-floor gate fails below 10% even when the rate projects an early cap" {
  # 8% in 5 minutes — ~96%/h would trip the threshold, but the floor hides it.
  seed_usage_cache 8 300 17700
  snap=$("$STATUSLINE" --snapshot)

  echo "$snap" | jq -e '.derived.five_hour.gates.noise_floor.pass == false' >/dev/null
  echo "$snap" | jq -e '.derived.five_hour.cap_eta_rendered == false' >/dev/null
}

@test "absent caches degrade to nulls, never to invalid JSON" {
  snap=$("$STATUSLINE" --snapshot)
  echo "$snap" | jq -e . >/dev/null
  echo "$snap" | jq -e '.usage == null' >/dev/null
  echo "$snap" | jq -e '.prepaid == null' >/dev/null
  echo "$snap" | jq -e '.caches.usage.present == false' >/dev/null
  echo "$snap" | jq -e '.derived.five_hour.pct_used == null' >/dev/null
  echo "$snap" | jq -e '.derived.five_hour.cap_eta_rendered == false' >/dev/null
}

@test "snapshot reports cache freshness against each TTL" {
  seed_usage_cache 50 7200 10800
  printf '{"amount": 1234, "currency": "USD"}\n' > "$PREPAID_CACHE"
  snap=$("$STATUSLINE" --snapshot)

  echo "$snap" | jq -e '.caches.usage.fresh == true and .caches.usage.ttl_seconds == 60' >/dev/null
  echo "$snap" | jq -e '.caches.prepaid.fresh == true and .caches.prepaid.ttl_seconds == 300' >/dev/null
  echo "$snap" | jq -e '.prepaid.amount == 1234' >/dev/null
}

@test "snapshot is a pure read: no fetches, no cache writes" {
  # No CLAUDEFUEL_OFFLINE set — purity must hold by construction, not by env.
  rm -f "$USAGE_CACHE" "$PREPAID_CACHE"
  run "$STATUSLINE" --snapshot
  [ "$status" -eq 0 ]
  [ ! -f "$USAGE_CACHE" ]
  [ ! -f "$PREPAID_CACHE" ]
}

@test "snapshot is profile-aware" {
  expected=$(basename "$CLAUDE_CONFIG_DIR" | sed 's/^\.claude-//')
  snap=$("$STATUSLINE" --snapshot)
  [ "$(echo "$snap" | jq -r '.profile.name')" = "$expected" ]
  [ "$(echo "$snap" | jq -r '.profile.config_dir')" = "$CLAUDE_CONFIG_DIR" ]
}

# ===== v2: the config block =====

@test "snapshot v2 carries the config block with overridden keys" {
  printf '{"version":1,"color_thresholds":{"red":80},"segments":{"hide":["thinking"]}}' \
    > "$CLAUDE_CONFIG_DIR/claudefuel.json"
  snap=$("$STATUSLINE" --snapshot)

  [ "$(echo "$snap" | jq -r '.config.path')" = "$CLAUDE_CONFIG_DIR/claudefuel.json" ]
  [ "$(echo "$snap" | jq -r '.config.status')" = "ok" ]
  [ "$(echo "$snap" | jq -r '.config.effective.color_thresholds.red')" = "80" ]
  echo "$snap" | jq -e '.config.overridden_keys == ["color_thresholds.red","segments.hide"]' >/dev/null
}

@test "snapshot v2 config block reports absent and malformed states" {
  snap=$("$STATUSLINE" --snapshot)
  [ "$(echo "$snap" | jq -r '.config.status')" = "absent" ]

  printf 'not json' > "$CLAUDE_CONFIG_DIR/claudefuel.json"
  snap=$("$STATUSLINE" --snapshot)
  [ "$(echo "$snap" | jq -r '.config.status')" = "malformed" ]
  # Malformed config never breaks the snapshot: still valid JSON,
  # effective shows the defaults that actually render.
  [ "$(echo "$snap" | jq -r '.config.effective.theme')" = "default" ]
}

@test "snapshot v2 keeps every v1 field (additive change only)" {
  seed_usage_cache 50 7200 10800
  snap=$("$STATUSLINE" --snapshot)
  for path in .generated_at_epoch .profile.name .versions .caches.usage.ttl_seconds \
      .usage.five_hour.utilization .derived.five_hour.cap_eta_rendered; do
    echo "$snap" | jq -e "$path != null" >/dev/null
  done
}
