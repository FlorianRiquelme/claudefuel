#!/bin/bash
# claudefuel: v0.4.0
# Claude Code Status Line — Multi-Account Aware
#
# Line 1: [profile] Model | ctx <bar> <used>/<total> | thinking: on/off | effort: <level> | ↗ /claudefuel.update
# Line 2: 5h: <bar> % | 7d: <bar> % | extra: <currency><balance>
# Line 3: ↻ <time> · ~cap <range> | ↻ <datetime> | ↻ <date>
#
# Supports CLAUDE_CONFIG_DIR for per-account usage display.
# When CLAUDE_CONFIG_DIR is set, keychain lookups and cache files are isolated per account.
#
# User config: ~/.claude/claudefuel.json (or $CLAUDE_CONFIG_DIR/claudefuel.json),
# edited via /claudefuel.configure. Minor tweaks only — see ADR-0003.
#
# Cross-platform: macOS (Keychain), Linux (credentials file, GNOME Keyring)
# Dependencies: jq, curl

set -f          # disable globbing
set -o pipefail # `a | b || c` must reflect a's failure, not b's success.
                # Several BSD-first / GNU-fallback date pipelines below
                # rely on this: without pipefail, the trailing `tr`/`sed`
                # masks the BSD failure on Linux and the fallback never
                # runs, yielding empty time strings.

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ANSI colors
blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;160;0m'
cyan='\033[38;2;46;149;153m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
white='\033[38;2;220;220;220m'
dim='\033[2m'
reset='\033[0m'

# ===== Config: ~/.claude/claudefuel.json over baked-in defaults =====
# User-owned, never written by install/update (ADR-0003). Scope is minor
# tweaks only: color thresholds, segment ordering, segment show/hide,
# theme presets. Absent file = pure defaults (the common path: no jq
# call). Malformed file = pure defaults (the bar must never break over
# config). A single jq pass emits shell assignments; strings are
# @sh-quoted and numbers forced through tonumber, so eval never sees an
# unquoted user value; segment tokens are additionally whitelisted at
# render time. Schema carries "version": 1 for future migration.
cfg_version=1
cfg_theme="default"
cfg_th_orange=50
cfg_th_yellow=70
cfg_th_red=90
cfg_reset_display="clock"
cfg_line1_order="model ctx thinking effort drift"
cfg_columns_order="5h 7d extra"
cfg_hide=""

config_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/claudefuel.json"
if [ -f "$config_file" ]; then
    cfg_assignments=$(jq -r '
        def num(v; d): ((v | tonumber? // d) | floor | tostring);
        def toks(v; d): ((v // d) | if type == "array" then map(tostring) | join(" ") else d | join(" ") end | @sh);
        "cfg_version=" + num((.version)?; 1),
        "cfg_theme=" + (((.theme)? // "default") | tostring | @sh),
        "cfg_th_orange=" + num((.color_thresholds.orange)?; 50),
        "cfg_th_yellow=" + num((.color_thresholds.yellow)?; 70),
        "cfg_th_red=" + num((.color_thresholds.red)?; 90),
        "cfg_reset_display=" + (((.reset_display)? // "clock") | tostring | @sh),
        "cfg_line1_order=" + toks((.segments.order.line1)?; ["model","ctx","thinking","effort","drift"]),
        "cfg_columns_order=" + toks((.segments.order.columns)?; ["5h","7d","extra"]),
        "cfg_hide=" + toks((.segments.hide)?; [])
    ' "$config_file" 2>/dev/null) && eval "$cfg_assignments"
fi

# Theme presets remap the palette before anything renders.
# "default" keeps the truecolor palette; "mono" drops hue entirely
# (structure still reads via dim/reset).
case "$cfg_theme" in
    mono) blue="" orange="" green="" cyan="" red="" yellow="" white="" ;;
esac

# Usage: segment_hidden <token> — true when token is in segments.hide.
segment_hidden() {
    case " $cfg_hide " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# Shared severity ladder: utilization pct → color. Every colored bar
# resolves severity through this one function so configured thresholds
# apply uniformly.
severity_color() {
    local pct=$1
    if [ "$pct" -ge "$cfg_th_red" ]; then printf '%s' "$red"
    elif [ "$pct" -ge "$cfg_th_yellow" ]; then printf '%s' "$yellow"
    elif [ "$pct" -ge "$cfg_th_orange" ]; then printf '%s' "$orange"
    else printf '%s' "$green"
    fi
}

# Format token counts (e.g., 50k / 200k)
format_tokens() {
    local num=$1
    if [ "$num" -ge 1000000 ]; then
        awk "BEGIN {printf \"%.1fm\", $num / 1000000}"
    elif [ "$num" -ge 1000 ]; then
        awk "BEGIN {printf \"%.0fk\", $num / 1000}"
    else
        printf "%d" "$num"
    fi
}

# Build a colored progress bar
# Usage: build_bar <pct> <width>
build_bar() {
    local pct=$1
    local width=$2
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))

    # Color based on usage level (shared severity ladder, config-driven)
    local bar_color
    bar_color=$(severity_color "$pct")

    local filled_str="" empty_str=""
    for ((i=0; i<filled; i++)); do filled_str+="●"; done
    for ((i=0; i<empty; i++)); do empty_str+="○"; done

    printf "${bar_color}${filled_str}${dim}${empty_str}${reset}"
}

# ===== Extract data from JSON =====
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')

# Context window
size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
[ "$size" -eq 0 ] 2>/dev/null && size=200000

# Token usage
input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
current=$(( input_tokens + cache_create + cache_read ))

used_tokens=$(format_tokens $current)
total_tokens=$(format_tokens $size)

if [ "$size" -gt 0 ]; then
    pct_used=$(( current * 100 / size ))
else
    pct_used=0
fi

# Check thinking status (live session state from stdin — reflects Option+T toggle)
thinking_on=false
thinking_val=$(echo "$input" | jq -r '.thinking.enabled // false')
[ "$thinking_val" = "true" ] && thinking_on=true

# Reasoning effort level (live session state from stdin — reflects /effort changes).
# Absent when the current model does not support the effort parameter.
effort_level=$(echo "$input" | jq -r '.effort.level // empty')

# Drift detection — when the cached upstream version differs from the
# installed version, append a single '↗ /claudefuel.update' segment to
# line 1. No count, no growth in bar height, no segment when equal.
# Cache lives at $CLAUDE_CONFIG_DIR/cache/claudefuel-version.json
# (or ~/.claude/cache/), TTL 6h. When stale, attempt one short-timeout
# fetch of raw statusline.sh from main; on failure keep the stale value
# (offline tolerance). Set CLAUDEFUEL_OFFLINE=1 to skip the fetch.
claudefuel_drift_segment() {
    local cache_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cache"
    local cache_file="$cache_dir/claudefuel-version.json"
    local ttl_seconds=$((6 * 60 * 60))

    local installed_version
    installed_version=$(head -20 "${BASH_SOURCE[0]:-$0}" \
        | grep -E '^# claudefuel:' | head -n1 \
        | sed -E 's/^# claudefuel: v//')
    [ -z "$installed_version" ] && return 0

    local upstream_version="" should_fetch=false
    if [ -f "$cache_file" ]; then
        upstream_version=$(jq -r '.upstream_version // empty' "$cache_file" 2>/dev/null)
        local cache_mtime now cache_age
        cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)
        now=$(date +%s)
        cache_age=$(( now - ${cache_mtime:-0} ))
        [ "$cache_age" -ge "$ttl_seconds" ] && should_fetch=true
    else
        should_fetch=true
    fi

    if $should_fetch && [ -z "$CLAUDEFUEL_OFFLINE" ]; then
        local fresh
        fresh=$(curl -fsSL --connect-timeout 2 --max-time 3 \
            "https://raw.githubusercontent.com/FlorianRiquelme/claudefuel/main/statusline.sh" 2>/dev/null \
            | head -20 | grep -E '^# claudefuel:' | head -n1 \
            | sed -E 's/^# claudefuel: v//')
        if [ -n "$fresh" ]; then
            upstream_version="$fresh"
            mkdir -p "$cache_dir"
            printf '{"upstream_version":"%s"}\n' "$fresh" > "$cache_file"
        fi
    fi

    [ -z "$upstream_version" ] && return 0
    [ "$upstream_version" = "$installed_version" ] && return 0

    printf "↗ /claudefuel.update"
}

# ===== LINE 1: [profile] Model | ctx <bar> <used>/<total> | thinking | effort | drift =====
# Segment registry: each segment is a function that echoes its rendered
# content (or nothing). The renderer walks cfg_line1_order, skipping
# hidden and empty segments, joining with the shared separator — so
# show/hide and ordering are pure data (ADR-0003).
sep=" ${dim}|${reset} "

# The profile badge ("[work] " when CLAUDE_CONFIG_DIR is set) is
# attached to the model segment: hide-only via "profile", not
# independently orderable.
segment_model() {
    local profile_label=""
    if [ -n "$CLAUDE_CONFIG_DIR" ] && ! segment_hidden profile; then
        local profile_name
        profile_name=$(basename "$CLAUDE_CONFIG_DIR" | sed 's/^\.claude-//')
        profile_label="${yellow}[${profile_name}]${reset} "
    fi
    printf '%s' "${profile_label}${blue}${model_name}${reset}"
}

segment_ctx() {
    local ctx_bar
    ctx_bar=$(build_bar "$pct_used" 10)
    printf '%s' "${white}ctx${reset} ${ctx_bar} ${orange}${used_tokens}/${total_tokens}${reset}"
}

segment_thinking() {
    if $thinking_on; then
        printf '%s' "thinking: ${orange}On${reset}"
    else
        printf '%s' "thinking: ${dim}Off${reset}"
    fi
}

segment_effort() {
    [ -n "$effort_level" ] || return 0
    printf '%s' "effort: ${cyan}${effort_level}${reset}"
}

segment_drift() {
    local drift_segment
    drift_segment=$(claudefuel_drift_segment)
    [ -n "$drift_segment" ] || return 0
    printf '%s' "${yellow}${drift_segment}${reset}"
}

line1=""
for seg in $cfg_line1_order; do
    case "$seg" in model|ctx|thinking|effort|drift) ;; *) continue ;; esac
    segment_hidden "$seg" && continue
    seg_out=$("segment_${seg}")
    [ -z "$seg_out" ] && continue
    [ -n "$line1" ] && line1+="$sep"
    line1+="$seg_out"
done

# ===== Cross-platform OAuth token resolution with auto-refresh =====
# Tries credential sources in order: env var → macOS Keychain → Linux creds file → GNOME Keyring
# If the access token is expired, attempts refresh using the stored refresh token.
# Supports multiple keychain accounts (Claude Code changed the account name across versions).
# When CLAUDE_CONFIG_DIR is set, keychain service name gets a hash suffix.

OAUTH_CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
OAUTH_TOKEN_URL="https://platform.claude.com/v1/oauth/token"

# Derive the keychain service name based on CLAUDE_CONFIG_DIR
# Claude Code appends first 8 chars of SHA256(config_dir_path) to the service name
KEYCHAIN_SERVICE="Claude Code-credentials"
CACHE_SUFFIX=""
if [ -n "$CLAUDE_CONFIG_DIR" ]; then
    config_hash=$(echo -n "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)
    KEYCHAIN_SERVICE="Claude Code-credentials-${config_hash}"
    CACHE_SUFFIX="-${config_hash}"
fi

# Refresh the OAuth token and update the credential store
# Usage: refresh_oauth_token <refresh_token> <store> [keychain_account]
# Returns the new access token on success, empty string on failure
refresh_oauth_token() {
    local refresh_token="$1"
    local store="$2"
    local kc_account="$3"

    local response
    response=$(curl -s -L --max-time 5 -X POST "$OAUTH_TOKEN_URL" \
        -H "Content-Type: application/json" \
        -d "{\"grant_type\":\"refresh_token\",\"refresh_token\":\"$refresh_token\",\"client_id\":\"$OAUTH_CLIENT_ID\"}")

    local new_access new_refresh expires_in
    new_access=$(echo "$response" | jq -r '.access_token // empty' 2>/dev/null)
    [ -z "$new_access" ] && return 1

    new_refresh=$(echo "$response" | jq -r '.refresh_token // empty' 2>/dev/null)
    expires_in=$(echo "$response" | jq -r '.expires_in // 28800' 2>/dev/null)
    local expires_at_ms=$(( ($(date +%s) + expires_in) * 1000 ))

    # Update the credential store with refreshed tokens
    case "$store" in
        keychain)
            if [ -n "$kc_account" ]; then
                local blob
                blob=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$kc_account" -w 2>/dev/null)
                if [ -n "$blob" ]; then
                    local updated
                    updated=$(echo "$blob" | jq --arg at "$new_access" --arg rt "${new_refresh:-$refresh_token}" --argjson exp "$expires_at_ms" \
                        '.claudeAiOauth.accessToken = $at | .claudeAiOauth.refreshToken = $rt | .claudeAiOauth.expiresAt = $exp')
                    security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$kc_account" >/dev/null 2>&1
                    security add-generic-password -s "$KEYCHAIN_SERVICE" -a "$kc_account" -w "$updated" >/dev/null 2>&1
                fi
            fi
            ;;
        file)
            local creds_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
            if [ -f "$creds_file" ]; then
                local updated
                updated=$(jq --arg at "$new_access" --arg rt "${new_refresh:-$refresh_token}" --argjson exp "$expires_at_ms" \
                    '.claudeAiOauth.accessToken = $at | .claudeAiOauth.refreshToken = $rt | .claudeAiOauth.expiresAt = $exp' "$creds_file")
                echo "$updated" > "$creds_file"
            fi
            ;;
        gnome)
            local blob
            blob=$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
            if [ -n "$blob" ]; then
                local updated
                updated=$(echo "$blob" | jq --arg at "$new_access" --arg rt "${new_refresh:-$refresh_token}" --argjson exp "$expires_at_ms" \
                    '.claudeAiOauth.accessToken = $at | .claudeAiOauth.refreshToken = $rt | .claudeAiOauth.expiresAt = $exp')
                echo "$updated" | timeout 2 secret-tool store --label="Claude Code-credentials" service "Claude Code-credentials" 2>/dev/null
            fi
            ;;
    esac

    echo "$new_access"
}

# Check if token is expired (with 60-second buffer)
is_token_expired() {
    local expires_at_ms="$1"
    [ -z "$expires_at_ms" ] || [ "$expires_at_ms" = "null" ] && return 0  # no expiry = treat as expired
    local now_ms=$(( $(date +%s) * 1000 ))
    local buffer_ms=60000  # 60 seconds buffer
    [ "$now_ms" -ge $(( expires_at_ms - buffer_ms )) ]
}

# Try a specific macOS Keychain account, return token if valid
# Usage: try_keychain_account <account_name>
try_keychain_account() {
    local acct="$1"
    local blob token expires_at refresh

    blob=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$acct" -w 2>/dev/null) || return 1
    [ -z "$blob" ] && return 1

    token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    [ -z "$token" ] || [ "$token" = "null" ] && return 1

    expires_at=$(echo "$blob" | jq -r '.claudeAiOauth.expiresAt // empty' 2>/dev/null)

    if is_token_expired "$expires_at"; then
        # Token expired — try refresh
        refresh=$(echo "$blob" | jq -r '.claudeAiOauth.refreshToken // empty' 2>/dev/null)
        if [ -n "$refresh" ] && [ "$refresh" != "null" ]; then
            token=$(refresh_oauth_token "$refresh" "keychain" "$acct")
        else
            return 1
        fi
    fi

    if [ -n "$token" ] && [ "$token" != "null" ]; then
        echo "$token"
        return 0
    fi
    return 1
}

get_oauth_token() {
    local token=""

    # 1. Explicit env var override (no expiry check possible)
    if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
        echo "$CLAUDE_CODE_OAUTH_TOKEN"
        return 0
    fi

    # 2. macOS Keychain — try multiple account names
    #    Claude Code uses different account names across versions:
    #    - Newer: OS username (e.g. "john")
    #    - Older: "Claude Code"
    #    When CLAUDE_CONFIG_DIR is set, a hash suffix is added to the service name.
    if command -v security >/dev/null 2>&1; then
        local os_user
        os_user=$(whoami)

        # Try OS username first (newer Claude Code), then legacy "Claude Code"
        for acct in "$os_user" "Claude Code"; do
            token=$(try_keychain_account "$acct")
            if [ -n "$token" ]; then
                echo "$token"
                return 0
            fi
        done
    fi

    # 3. Linux credentials file
    local creds_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
    if [ -f "$creds_file" ]; then
        local expires_at refresh
        token=$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null)
        expires_at=$(jq -r '.claudeAiOauth.expiresAt // empty' "$creds_file" 2>/dev/null)
        refresh=$(jq -r '.claudeAiOauth.refreshToken // empty' "$creds_file" 2>/dev/null)

        if [ -n "$token" ] && [ "$token" != "null" ]; then
            if is_token_expired "$expires_at"; then
                if [ -n "$refresh" ] && [ "$refresh" != "null" ]; then
                    token=$(refresh_oauth_token "$refresh" "file")
                else
                    token=""
                fi
            fi
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                echo "$token"
                return 0
            fi
        fi
    fi

    # 4. GNOME Keyring via secret-tool
    if command -v secret-tool >/dev/null 2>&1; then
        local blob
        blob=$(timeout 2 secret-tool lookup service "Claude Code-credentials" 2>/dev/null)
        if [ -n "$blob" ]; then
            local expires_at refresh
            token=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            expires_at=$(echo "$blob" | jq -r '.claudeAiOauth.expiresAt // empty' 2>/dev/null)
            refresh=$(echo "$blob" | jq -r '.claudeAiOauth.refreshToken // empty' 2>/dev/null)

            if [ -n "$token" ] && [ "$token" != "null" ]; then
                if is_token_expired "$expires_at"; then
                    if [ -n "$refresh" ] && [ "$refresh" != "null" ]; then
                        token=$(refresh_oauth_token "$refresh" "gnome")
                    else
                        token=""
                    fi
                fi
                if [ -n "$token" ] && [ "$token" != "null" ]; then
                    echo "$token"
                    return 0
                fi
            fi
        fi
    fi

    echo ""
}

# ===== LINE 2 & 3: Usage limits with progress bars (cached) =====
# Cache is per-account when CLAUDE_CONFIG_DIR is set
cache_file="/tmp/claude/statusline-usage-cache${CACHE_SUFFIX}.json"
cache_max_age=60  # seconds between API calls
mkdir -p /tmp/claude

needs_refresh=true
usage_data=""

# Check cache
if [ -f "$cache_file" ]; then
    cache_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null)
    now=$(date +%s)
    cache_age=$(( now - cache_mtime ))
    if [ "$cache_age" -lt "$cache_max_age" ]; then
        needs_refresh=false
        usage_data=$(cat "$cache_file" 2>/dev/null)
    fi
fi

# Fetch fresh data if cache is stale
if $needs_refresh; then
    token=$(get_oauth_token)
    if [ -n "$token" ] && [ "$token" != "null" ]; then
        response=$(curl -s --max-time 5 \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $token" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "User-Agent: claude-code/2.1.34" \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
        if [ -n "$response" ] && echo "$response" | jq -e '.five_hour' >/dev/null 2>&1; then
            usage_data="$response"
            echo "$response" > "$cache_file"
        fi
    fi
    # Fall back to stale cache
    if [ -z "$usage_data" ] && [ -f "$cache_file" ]; then
        usage_data=$(cat "$cache_file" 2>/dev/null)
    fi
fi

# ===== Prepaid credit balance (separate cache, longer TTL) =====
# Balance changes slowly, so cache for 5 min to avoid hammering the API.
prepaid_cache_file="/tmp/claude/statusline-prepaid-cache${CACHE_SUFFIX}.json"
prepaid_cache_max_age=300
prepaid_data=""

if [ -f "$prepaid_cache_file" ]; then
    p_mtime=$(stat -c %Y "$prepaid_cache_file" 2>/dev/null || stat -f %m "$prepaid_cache_file" 2>/dev/null)
    p_age=$(( $(date +%s) - p_mtime ))
    if [ "$p_age" -lt "$prepaid_cache_max_age" ]; then
        prepaid_data=$(cat "$prepaid_cache_file" 2>/dev/null)
    fi
fi

if [ -z "$prepaid_data" ] && [ -z "$CLAUDEFUEL_OFFLINE" ]; then
    # Token may be unset if usage cache was fresh — fetch it now
    [ -z "$token" ] || [ "$token" = "null" ] && token=$(get_oauth_token)
fi

if [ -z "$prepaid_data" ] && [ -z "$CLAUDEFUEL_OFFLINE" ] && [ -n "$token" ] && [ "$token" != "null" ]; then
    # Resolve org UUID — cache long-term, it never changes
    org_cache_file="/tmp/claude/statusline-orguuid-cache${CACHE_SUFFIX}"
    org_uuid=""
    [ -f "$org_cache_file" ] && org_uuid=$(cat "$org_cache_file" 2>/dev/null)
    if [ -z "$org_uuid" ]; then
        account_resp=$(curl -s --max-time 5 \
            -H "Authorization: Bearer $token" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "User-Agent: claude-code/2.1.34" \
            "https://api.anthropic.com/api/oauth/account" 2>/dev/null)
        org_uuid=$(echo "$account_resp" | jq -r '.memberships[0].organization.uuid // empty' 2>/dev/null)
        [ -n "$org_uuid" ] && echo "$org_uuid" > "$org_cache_file"
    fi

    if [ -n "$org_uuid" ]; then
        prepaid_resp=$(curl -s --max-time 5 \
            -H "Authorization: Bearer $token" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "User-Agent: claude-code/2.1.34" \
            "https://api.anthropic.com/api/oauth/organizations/$org_uuid/prepaid/credits" 2>/dev/null)
        if [ -n "$prepaid_resp" ] && echo "$prepaid_resp" | jq -e '.amount' >/dev/null 2>&1; then
            prepaid_data="$prepaid_resp"
            echo "$prepaid_resp" > "$prepaid_cache_file"
        fi
    fi
fi

# Fall back to stale prepaid cache
if [ -z "$prepaid_data" ] && [ -f "$prepaid_cache_file" ]; then
    prepaid_data=$(cat "$prepaid_cache_file" 2>/dev/null)
fi

# Cross-platform ISO to epoch conversion
# Converts ISO 8601 timestamp (e.g. "2025-06-15T12:30:00Z" or "2025-06-15T12:30:00.123+00:00") to epoch seconds.
# Properly handles UTC timestamps and converts to local time.
iso_to_epoch() {
    local iso_str="$1"

    # Try GNU date first (Linux) — handles ISO 8601 format automatically
    local epoch
    epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    # BSD date (macOS) - handle various ISO 8601 formats
    local stripped="${iso_str%%.*}"          # Remove fractional seconds (.123456)
    stripped="${stripped%%Z}"                 # Remove trailing Z
    stripped="${stripped%%+*}"                # Remove timezone offset (+00:00)
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"  # Remove negative timezone offset

    # Check if timestamp is UTC (has Z or +00:00 or -00:00)
    if [[ "$iso_str" == *"Z"* ]] || [[ "$iso_str" == *"+00:00"* ]] || [[ "$iso_str" == *"-00:00"* ]]; then
        # For UTC timestamps, parse with timezone set to UTC
        epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    else
        epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    fi

    if [ -n "$epoch" ]; then
        echo "$epoch"
        return 0
    fi

    return 1
}

# Format ISO reset time to compact local time
# Usage: format_reset_time <iso_string> <style: time|datetime|date>
format_reset_time() {
    local iso_str="$1"
    local style="$2"
    [ -z "$iso_str" ] || [ "$iso_str" = "null" ] && return

    # Parse ISO datetime and convert to local time (cross-platform)
    local epoch
    epoch=$(iso_to_epoch "$iso_str")
    [ -z "$epoch" ] && return

    # Format based on style (try BSD date first, then GNU date)
    # BSD date uses %p (uppercase AM/PM), so convert to lowercase
    case "$style" in
        time)
            date -j -r "$epoch" +"%l:%M%p" 2>/dev/null | sed 's/^ //' | tr '[:upper:]' '[:lower:]' || \
            date -d "@$epoch" +"%l:%M%P" 2>/dev/null | sed 's/^ //'
            ;;
        datetime)
            date -j -r "$epoch" +"%b %-d, %l:%M%p" 2>/dev/null | sed 's/  / /g; s/^ //' | tr '[:upper:]' '[:lower:]' || \
            date -d "@$epoch" +"%b %-d, %l:%M%P" 2>/dev/null | sed 's/  / /g; s/^ //'
            ;;
        *)
            date -j -r "$epoch" +"%b %-d" 2>/dev/null | tr '[:upper:]' '[:lower:]' || \
            date -d "@$epoch" +"%b %-d" 2>/dev/null
            ;;
    esac
}

# Format an epoch as a compact countdown to it (e.g. "in 42m",
# "in 2h05m", "in 4d21h"). Used in place of format_reset_time when
# reset_display=countdown is configured.
format_countdown() {
    local epoch=$1
    [ -z "$epoch" ] && return
    local diff=$(( epoch - $(date +%s) ))
    [ "$diff" -lt 0 ] && diff=0
    local d=$(( diff / 86400 )) h=$(( diff % 86400 / 3600 )) m=$(( diff % 3600 / 60 ))
    if [ "$d" -gt 0 ]; then
        printf "in %dd%02dh" "$d" "$h"
    elif [ "$h" -gt 0 ]; then
        printf "in %dh%02dm" "$h" "$m"
    else
        printf "in %dm" "$m"
    fi
}

# Cap-ETA segment — predicted wall-clock 100% time for the 5h window.
# Stateless: computed from a single snapshot (pct + reset epoch), no
# samples persisted across renders. Renders only when burn rate exceeds
# reset-pace AND pct_used >= 10%. See ADR-0004.
# Usage: claudefuel_cap_eta_segment <pct_used> <reset_at_epoch>
# Echoes "~cap HH:MMxm-HH:MMxm" or empty.
claudefuel_cap_eta_segment() {
    local pct=$1
    local reset_epoch=$2
    local window_length=$((5 * 3600))

    [ -z "$reset_epoch" ] && return 0
    [ "$pct" -ge 10 ] 2>/dev/null || return 0

    local now window_started elapsed
    now=$(date +%s)
    window_started=$(( reset_epoch - window_length ))
    elapsed=$(( now - window_started ))
    [ "$elapsed" -gt 0 ] || return 0

    local cap_eta
    cap_eta=$(awk "BEGIN {printf \"%d\", $now + (100 - $pct) * $elapsed / $pct}")
    [ "$cap_eta" -lt "$reset_epoch" ] || return 0

    local cap_low=$(( cap_eta - 900 )) cap_high=$(( cap_eta + 900 ))
    local low_str high_str
    low_str=$(date -j -r "$cap_low" +"%l:%M%p" 2>/dev/null | sed 's/^ //' | tr '[:upper:]' '[:lower:]' \
        || date -d "@$cap_low" +"%l:%M%P" 2>/dev/null | sed 's/^ //')
    high_str=$(date -j -r "$cap_high" +"%l:%M%p" 2>/dev/null | sed 's/^ //' | tr '[:upper:]' '[:lower:]' \
        || date -d "@$cap_high" +"%l:%M%P" 2>/dev/null | sed 's/^ //')

    printf "~cap %s-%s" "$low_str" "$high_str"
}

# Pad column to fixed width (ignoring ANSI codes)
# Usage: pad_column <text_with_ansi> <visible_length> <column_width>
pad_column() {
    local text="$1"
    local visible_len=$2
    local col_width=$3
    local padding=$(( col_width - visible_len ))
    if [ "$padding" -gt 0 ]; then
        printf "%s%*s" "$text" "$padding" ""
    else
        printf "%s" "$text"
    fi
}

# ===== LINE 2/3 column registry =====
# 5h / 7d / extra are columns: each owns a Line 2 cell (bar) and a
# Line 3 cell (reset). A column function sets col_bar / col_reset for
# the renderer, which walks cfg_columns_order so show/hide and ordering
# are pure data — Line 3 always mirrors Line 2's column order.

# ---- 5-hour ----
column_5h() {
    local five_hour_pct five_hour_reset_iso five_hour_reset five_hour_bar
    five_hour_pct=$(echo "$usage_data" | jq -r '.five_hour.utilization // 0' | awk '{printf "%.0f", $1}')
    five_hour_reset_iso=$(echo "$usage_data" | jq -r '.five_hour.resets_at // empty')
    local five_hour_reset_epoch
    five_hour_reset_epoch=$(iso_to_epoch "$five_hour_reset_iso")
    if [ "$cfg_reset_display" = "countdown" ]; then
        five_hour_reset=$(format_countdown "$five_hour_reset_epoch")
    else
        five_hour_reset=$(format_reset_time "$five_hour_reset_iso" "time")
    fi
    five_hour_bar=$(build_bar "$five_hour_pct" "$bar_width")

    # Calculate visible length: "5h: " + bar + " " + "XX%"
    local col1_bar_vis_len=$(( 4 + bar_width + 1 + ${#five_hour_pct} + 1 ))
    local col1_bar_raw="${white}5h:${reset} ${five_hour_bar} ${cyan}${five_hour_pct}%${reset}"
    # col_bar padding deferred — see col1w_actual computation below (cap-ETA may widen col1).

    local col1_reset_plain="↻ ${five_hour_reset}"
    col_reset="${white}↻ ${five_hour_reset}${reset}"

    # Cap-ETA: see ADR-0004. Append to the 5h reset cell when present.
    local cap_eta_plain=""
    if ! segment_hidden cap_eta; then
        cap_eta_plain=$(claudefuel_cap_eta_segment "$five_hour_pct" "$five_hour_reset_epoch")
    fi
    if [ -n "$cap_eta_plain" ]; then
        col1_reset_plain+=" · ${cap_eta_plain}"
        col_reset+=" ${dim}· ${cap_eta_plain}${reset}"
    fi

    # Widen col1 when cap-ETA grows the reset cell — keeps Line 2/3 pipes aligned.
    local col1w_actual=$col1w
    [ "${#col1_reset_plain}" -gt "$col1w_actual" ] && col1w_actual="${#col1_reset_plain}"
    col_bar=$(pad_column "$col1_bar_raw" "$col1_bar_vis_len" "$col1w_actual")
    col_reset=$(pad_column "$col_reset" "${#col1_reset_plain}" "$col1w_actual")
}

# ---- 7-day ----
column_7d() {
    local seven_day_pct seven_day_reset_iso seven_day_reset seven_day_bar
    seven_day_pct=$(echo "$usage_data" | jq -r '.seven_day.utilization // 0' | awk '{printf "%.0f", $1}')
    seven_day_reset_iso=$(echo "$usage_data" | jq -r '.seven_day.resets_at // empty')
    if [ "$cfg_reset_display" = "countdown" ]; then
        seven_day_reset=$(format_countdown "$(iso_to_epoch "$seven_day_reset_iso")")
    else
        seven_day_reset=$(format_reset_time "$seven_day_reset_iso" "datetime")
    fi
    seven_day_bar=$(build_bar "$seven_day_pct" "$bar_width")

    local col2_bar_vis_len=$(( 4 + bar_width + 1 + ${#seven_day_pct} + 1 ))
    col_bar="${white}7d:${reset} ${seven_day_bar} ${cyan}${seven_day_pct}%${reset}"
    col_bar=$(pad_column "$col_bar" "$col2_bar_vis_len" "$col2w")

    local col2_reset_plain="↻ ${seven_day_reset}"
    col_reset="${white}↻ ${seven_day_reset}${reset}"
    col_reset=$(pad_column "$col_reset" "${#col2_reset_plain}" "$col2w")
}

# ---- Extra usage (prepaid credit balance) ----
column_extra() {
    local extra_enabled
    extra_enabled=$(echo "$usage_data" | jq -r '.extra_usage.is_enabled // false')
    [ "$extra_enabled" = "true" ] && [ -n "$prepaid_data" ] || return 0

    local prepaid_amount prepaid_currency sym
    prepaid_amount=$(echo "$prepaid_data" | jq -r '.amount // 0' | awk '{printf "%.2f", $1/100}')
    prepaid_currency=$(echo "$prepaid_data" | jq -r '.currency // "USD"')
    case "$prepaid_currency" in
        EUR) sym="€" ;;
        GBP) sym="£" ;;
        JPY) sym="¥" ;;
        *)   sym="\$" ;;
    esac

    col_bar="${white}extra:${reset} ${cyan}${sym}${prepaid_amount}${reset}"
}

line2=""
line3=""

if [ -n "$usage_data" ] && echo "$usage_data" | jq -e . >/dev/null 2>&1; then
    bar_width=10
    col1w=19
    col2w=19

    for col in $cfg_columns_order; do
        case "$col" in 5h|7d|extra) ;; *) continue ;; esac
        segment_hidden "$col" && continue
        col_bar=""
        col_reset=""
        "column_${col}"
        if [ -n "$col_bar" ]; then
            [ -n "$line2" ] && line2+="$sep"
            line2+="$col_bar"
        fi
        if [ -n "$col_reset" ]; then
            [ -n "$line3" ] && line3+="$sep"
            line3+="$col_reset"
        fi
    done
fi

# Output all lines
printf "%b" "$line1"
[ -n "$line2" ] && printf "\n%b" "$line2"
[ -n "$line3" ] && printf "\n%b" "$line3"

exit 0
