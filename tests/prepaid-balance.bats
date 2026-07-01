#!/usr/bin/env bats

# Tests for the prepaid credit balance display in the `extra:` column.
#
# Black-box CLI tests: isolate via CLAUDE_CONFIG_DIR, pre-seed both the
# usage cache and the prepaid cache so the script never touches OAuth or
# the network, feed stdin, assert on stdout.
#
# Behavior under test:
#   - When extra_usage.is_enabled=true AND prepaid cache is present AND
#     the balance is non-zero, render `extra: <symbol><amount>` using the
#     API `currency` field.
#   - When extra_usage.is_enabled=false, omit the column entirely.
#   - When the prepaid balance is zero, omit the column entirely (noise).
#   - Currency symbol mapping: EUR→€, GBP→£, JPY→¥, anything else→$.

SAMPLE_STDIN='{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp"},"session_id":"t"}'

setup() {
  CLAUDE_CONFIG_DIR=$(mktemp -d)
  export CLAUDE_CONFIG_DIR
  mkdir -p "$CLAUDE_CONFIG_DIR/cache"
  STATUSLINE="${BATS_TEST_DIRNAME}/../statusline.sh"

  # Silence drift segment regardless of network: seed cache to match installed.
  installed_version=$(grep -E '^# claudefuel:' "$STATUSLINE" | head -n1 \
    | sed -E 's/^# claudefuel: v//')
  printf '{"upstream_version":"%s"}\n' "$installed_version" \
    > "$CLAUDE_CONFIG_DIR/cache/claudefuel-version.json"

  # Mirror statusline.sh's CACHE_SUFFIX derivation to locate caches.
  config_hash=$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)
  USAGE_CACHE="/tmp/claude/statusline-usage-cache-${config_hash}.json"
  PREPAID_CACHE="/tmp/claude/statusline-prepaid-cache-${config_hash}.json"
  ORG_CACHE="/tmp/claude/statusline-orguuid-cache-${config_hash}"
  mkdir -p /tmp/claude
}

teardown() {
  rm -f "$USAGE_CACHE" "$PREPAID_CACHE" "$ORG_CACHE" 2>/dev/null
  [ -n "$CLAUDE_CONFIG_DIR" ] && [ -d "$CLAUDE_CONFIG_DIR" ] && rm -rf "$CLAUDE_CONFIG_DIR"
}

# Seed usage cache with extra_usage enabled or disabled.
# Args: <extra_enabled: true|false>
seed_usage_cache() {
  local enabled=$1
  cat > "$USAGE_CACHE" <<EOF
{
  "five_hour":   { "utilization": 5, "resets_at": "2099-01-01T00:00:00Z" },
  "seven_day":   { "utilization": 5, "resets_at": "2099-01-01T00:00:00Z" },
  "extra_usage": { "is_enabled": $enabled }
}
EOF
  touch "$USAGE_CACHE"
}

# Seed prepaid cache. Args: <amount_cents> <currency>
seed_prepaid_cache() {
  local amount=$1 currency=$2
  cat > "$PREPAID_CACHE" <<EOF
{"amount":$amount,"currency":"$currency","auto_reload_settings":null,"pending_invoice_amount_cents":null,"last_paid_purchase_cents":null}
EOF
  touch "$PREPAID_CACHE"
}

# Strip ANSI escape sequences so assertions can match on plain text.
strip_ansi() {
  sed -E $'s/\x1b\\[[0-9;]*m//g'
}

run_bar() {
  CLAUDEFUEL_OFFLINE=1 printf '%s' "$SAMPLE_STDIN" | "$STATUSLINE" | strip_ansi
}

@test "EUR: renders extra: €<amount> from prepaid cache" {
  seed_usage_cache true
  seed_prepaid_cache 5929 EUR

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"extra:"* ]]
  [[ "$line2" == *"€59.29"* ]]
}

@test "USD: renders extra: \$<amount> for USD currency" {
  seed_usage_cache true
  seed_prepaid_cache 12500 USD

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"\$125.00"* ]]
}

@test "GBP: renders extra: £<amount>" {
  seed_usage_cache true
  seed_prepaid_cache 1050 GBP

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"£10.50"* ]]
}

@test "JPY: renders extra: ¥<amount>" {
  seed_usage_cache true
  seed_prepaid_cache 100000 JPY

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"¥1000.00"* ]]
}

@test "Unknown currency falls back to \$" {
  seed_usage_cache true
  seed_prepaid_cache 4200 CHF

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" == *"\$42.00"* ]]
}

@test "extra_usage disabled: column is omitted entirely" {
  seed_usage_cache false
  # Even with prepaid cached, the column must not render when disabled.
  seed_prepaid_cache 5929 EUR

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" != *"extra:"* ]]
}

@test "zero balance: column is omitted entirely" {
  seed_usage_cache true
  seed_prepaid_cache 0 USD

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" != *"extra:"* ]]
}

@test "prepaid cache missing: column is omitted even when extra_usage enabled" {
  seed_usage_cache true
  # No prepaid cache seeded. Offline mode prevents the network fallback,
  # so the column should not render rather than show stale/garbage data.
  rm -f "$PREPAID_CACHE"

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" != *"extra:"* ]]
}

@test "old \$used/\$limit format is no longer rendered" {
  # Regression guard: the previous display showed `$X.XX/$Y.YY`. The
  # slash-separated form must never appear when prepaid balance is shown.
  seed_usage_cache true
  seed_prepaid_cache 5929 EUR

  output=$(run_bar)
  line2=$(printf '%s' "$output" | sed -n '2p')

  [[ "$line2" != *"/\$"* ]]
  [[ "$line2" != *"/€"* ]]
}
