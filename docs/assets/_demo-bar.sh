#!/bin/bash
# Helper for the README casts. Renders a single statusline bar for a fake
# profile by setting CLAUDE_CONFIG_DIR, pre-populating the corresponding
# usage cache, and piping a synthetic JSON payload into statusline.sh.
#
# Usage:  _demo-bar.sh <profile-name> <input_tokens> <five_hour_pct> <seven_day_pct> <extra_used_cents>
# Example: _demo-bar.sh work 40000 35 50 1200

set -e

profile="$1"
tokens="$2"
five_hour="${3:-30}"
seven_day="${4:-50}"
extra_cents="${5:-1000}"

# Match statusline.sh's hash derivation exactly:
#   config_hash=$(echo -n "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)
export CLAUDE_CONFIG_DIR="$HOME/.claude-${profile}"
config_hash=$(echo -n "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)
cache_file="/tmp/claude/statusline-usage-cache-${config_hash}.json"

mkdir -p /tmp/claude
cat > "$cache_file" <<EOF
{
  "five_hour":  {"utilization": ${five_hour}, "resets_at": "2026-05-12T20:20:00Z"},
  "seven_day":  {"utilization": ${seven_day}, "resets_at": "2026-05-15T22:00:00Z"},
  "extra_usage": {"is_enabled": true, "utilization": $((extra_cents * 100 / 17000)), "used_credits": ${extra_cents}, "monthly_limit": 17000}
}
EOF

extra_pct=$(( five_hour > 0 ? five_hour / 2 : 0 ))

printf '%s' "{\"model\":{\"display_name\":\"Claude Sonnet 4.6\"},\"workspace\":{\"current_dir\":\"/tmp\"},\"session_id\":\"demo\",\"context_window\":{\"context_window_size\":200000,\"current_usage\":{\"input_tokens\":${tokens},\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}" \
  | ./statusline.sh
echo
