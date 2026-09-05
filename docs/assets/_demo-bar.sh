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

export CLAUDE_CONFIG_DIR="$HOME/.claude-${profile}"
cache_file="$CLAUDE_CONFIG_DIR/cache/claudefuel-usage.json"

mkdir -p "$CLAUDE_CONFIG_DIR/cache"
cat > "$cache_file" <<EOF
{
  "five_hour":  {"utilization": ${five_hour}, "resets_at": "2026-05-12T20:20:00Z"},
  "seven_day":  {"utilization": ${seven_day}, "resets_at": "2026-05-15T22:00:00Z"},
  "extra_usage": {"is_enabled": true, "used_credits": ${extra_cents}}
}
EOF

printf '%s' "{\"model\":{\"display_name\":\"Claude Sonnet 4.6\"},\"workspace\":{\"current_dir\":\"/tmp\"},\"session_id\":\"demo\",\"context_window\":{\"context_window_size\":200000,\"current_usage\":{\"input_tokens\":${tokens},\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}" \
  | ./statusline.sh
echo
