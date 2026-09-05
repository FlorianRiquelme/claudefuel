#!/bin/bash
# claudefuel: v0.4.6
# Claude Code Status Line — Multi-Account Aware
#
# Line 1: [profile] Model | ◈ session | ctx <bar> <used>/<total> | thinking: on/off | effort: <level> | agent: <name> | ▸ <tool> <age> | #N ◌ | ↗ /claudefuel.update
# Line 2: 5h: <bar> % [→N%] [·age] (or ~<left> ×<ratio> when burning hot) | 7d: <bar> % | extra: <currency><balance> [·age] | ⧉ N | ⇄ <profile> <pct>% (<age>)
# Line 3: ↻ <time> · ~cap <range> · slow ≤<ratio>× · ⚓ <gap> | ↻ <datetime>
#
# Data sources, in order of preference:
#   1. stdin `rate_limits` — Claude Code passes 5h/7d used_percentage and
#      resets_at (epoch) on every render for Pro/Max subscribers. Zero
#      network, per-render fresh, always in agreement with Claude Code's own
#      UI. Absent before a session's first API response and for
#      non-subscription auth. Each render mirrors it to
#      cache/claudefuel-native.json so --snapshot, --fleet and the ⇄ switch
#      hint read the same numbers the bar shows.
#   2. The OAuth usage endpoint — fallback for the bars when stdin carries
#      no rate_limits, and enrichment for the prepaid `extra` column. Cached
#      on disk, fetched by at most one session per cadence via a detached
#      one-shot refresh (never-block: a stale cache paints this render, the
#      refresh lands for the next). 5 min cadence on the fallback path,
#      30 min when stdin already drives the bars.
#
# Honest instrument: ·age marks stale cached data (never rendered as fresh);
# when no usage data is available at all, line 2 becomes a one-glyph
# diagnosis plus trailhead: <⊘|⚠|?> ✚ /claudefuel.doctor (auth / network /
# missing dep). Lines 2-3 always render once data exists. Severity rides on
# shape and weight, not hue alone: a window at ≥90% gets a ⚠ label prefix
# and inverse-video value; the governing constraint — whichever window
# would hit 100% first at the current burn rate — carries a ▸ marker
# (stable layout, never reordered). The extra column renders only once
# spend is live (>$0).
#
# Credentials are read-only: the script never refreshes or rewrites the
# OAuth token. An expired token means "no fetch this render" — Claude Code
# refreshes it on its next API call.
#
# Supports CLAUDE_CONFIG_DIR for per-account display. All runtime files live
# in $CLAUDE_CONFIG_DIR/cache/claudefuel-* (default ~/.claude/cache/), so
# profiles are isolated by directory and nothing is shared through /tmp.
#
# User config: ~/.claude/claudefuel.json (or $CLAUDE_CONFIG_DIR/claudefuel.json),
# edited via /claudefuel.configure. Minor tweaks only — see ADR-0003.
#
# Env: CLAUDEFUEL_OFFLINE=1 skips every network call. CLAUDEFUEL_NOW=<epoch>
# freezes the clock (tests, demos). CLAUDE_CODE_OAUTH_TOKEN overrides
# credential lookup. COLUMNS (set by Claude Code) drives the narrow-width
# degradation ladder.
#
# Cross-platform: macOS (Keychain), Linux (credentials file, GNOME Keyring)
# Dependencies: jq, curl

set -f          # disable globbing
set -o pipefail # `a | b || c` must reflect a's failure, not b's success.
                # Several BSD-first / GNU-fallback date pipelines below
                # rely on this: without pipefail, the trailing `tr`/`sed`
                # masks the BSD failure on Linux and the fallback never
                # runs, yielding empty time strings.

# Injectable clock: CLAUDEFUEL_NOW=<epoch> freezes "now" for every
# time-derived value (countdowns, cap-ETA math, cache ages) — the
# determinism seam behind timer-tick tests and demo golden renders.
# Read once per render: every helper below uses $now, never date(1).
now="${CLAUDEFUEL_NOW:-$(date +%s)}"

# Runtime paths. Every file the bar writes lives under the active profile's
# cache dir, prefixed claudefuel-, so profiles never share state and a
# multi-user /tmp cannot break the bar.
config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
cache_dir="$config_dir/cache"

# date(1) flavor, detected once: BSD (macOS) takes -j -r <epoch>, GNU takes
# -d @<epoch>. One exec per formatted time instead of a failing BSD attempt
# followed by the GNU fallback on every call.
if date -j -r 0 +%s >/dev/null 2>&1; then
    date_flavor=bsd
    cf_date() { date -j -r "$1" +"$2" 2>/dev/null; }
else
    date_flavor=gnu
    cf_date() { date -d "@$1" +"$2" 2>/dev/null; }
fi

# Installed version from this file's own header (first 20 lines), read
# with builtins — no head/grep/sed. Empty when the header is missing.
installed_version=""
{
    _cf_n=0
    while IFS= read -r _cf_line && [ "$_cf_n" -lt 20 ]; do
        _cf_n=$(( _cf_n + 1 ))
        case "$_cf_line" in
            "# claudefuel: v"*) installed_version="${_cf_line#\# claudefuel: v}"; break ;;
        esac
    done < "${BASH_SOURCE[0]:-$0}"
} 2>/dev/null

# Profile label: basename of CLAUDE_CONFIG_DIR minus the .claude- prefix
# ("default" when unset). Pure parameter expansion.
profile_label_for_dir() {
    local d="${1%/}"
    if [ -z "$d" ] || [ "$d" = "$HOME/.claude" ]; then printf 'default'; return; fi
    d="${d##*/}"
    printf '%s' "${d#.claude-}"
}

# The drift cache is a one-key JSON object written by this script; read it
# with a bash regex (no jq spawn). Echoes the version or nothing.
read_upstream_version() {
    local content
    [ -f "$1" ] && content=$(<"$1") || return 0
    [[ "$content" =~ \"upstream_version\":\"([^\"]+)\" ]] && printf '%s' "${BASH_REMATCH[1]}"
}

# mtime of a file or directory in epoch seconds.
file_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# Cross-platform ISO 8601 → epoch seconds ("2025-06-15T12:30:00Z",
# "2025-06-15T12:30:00.123+00:00"). A bare digit string (an epoch, as the
# stdin rate_limits and the native mirror carry) passes through untouched.
iso_to_epoch() {
    local iso_str="$1"
    [ -n "$iso_str" ] && [ "$iso_str" != "null" ] || return 1
    case "$iso_str" in
        *[!0-9]*) ;;
        *) printf '%s' "$iso_str"; return 0 ;;
    esac

    local epoch
    if [ "$date_flavor" = gnu ]; then
        epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    else
        # BSD date needs a fixed layout: strip fractional seconds and offset.
        local stripped="${iso_str%%.*}"
        stripped="${stripped%%Z}"
        stripped="${stripped%%+*}"
        stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"
        if [[ "$iso_str" == *"Z"* ]] || [[ "$iso_str" == *"+00:00"* ]] || [[ "$iso_str" == *"-00:00"* ]]; then
            epoch=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
        else
            epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
        fi
    fi
    [ -n "$epoch" ] || return 1
    printf '%s' "$epoch"
}

# ===== Cross-profile sibling caches (read-only) =====
# Every profile that has rendered recently leaves usage data in its own
# cache dir: claudefuel-native.json (mirrored from stdin rate_limits on
# every render) and/or claudefuel-usage.json (the OAuth fetch). These
# helpers read those sibling files and nothing else — they never fetch for
# a non-active profile (multi-source fanout is an ADR-0003 rewrite cliff).
# Sibling data is always a snapshot of unknown freshness, so its cache age
# travels with it everywhere it is shown.

# Freshest usage file for a profile dir, or nothing. Both files share the
# same shape ({five_hour,seven_day}.{utilization,resets_at}); the native
# mirror is preferred whenever it is at least as new as the OAuth cache.
# Usage: claudefuel_usage_file_for_dir <profile_dir>
claudefuel_usage_file_for_dir() {
    local dir="${1:-$HOME/.claude}"
    local native="$dir/cache/claudefuel-native.json" oauth="$dir/cache/claudefuel-usage.json"
    local nm om
    [ -f "$native" ] && nm=$(file_mtime "$native")
    [ -f "$oauth" ] && om=$(file_mtime "$oauth")
    if [ -n "$nm" ] && [ "${nm:-0}" -ge "${om:-0}" ]; then
        printf '%s' "$native"
    elif [ -n "$om" ]; then
        printf '%s' "$oauth"
    fi
}

# Compact age: 45s / 12m / 3h. Sibling numbers are cached, never live —
# the age is the honesty marker that says how old the snapshot is.
claudefuel_format_age() {
    local s=$1
    if [ "$s" -lt 60 ]; then printf '%ds' "$s"
    elif [ "$s" -lt 3600 ]; then printf '%dm' $(( s / 60 ))
    else printf '%dh' $(( s / 3600 ))
    fi
}

# Enumerate known profile caches: the default profile (~/.claude), every
# ~/.claude-* sibling, and the active CLAUDE_CONFIG_DIR when it lives
# outside that convention. Profile labels derive the same way as the
# [profile] segment on Line 1 (basename minus the .claude- prefix).
# Emits one line per cache found: <label>\t<profile_dir>\t<usage_file>\t<age_seconds>
claudefuel_known_profile_caches() {
    local seen="" dir label cache mtime age
    set +f  # sibling scan needs globbing; restored immediately
    local dirs=( "$HOME/.claude" "$HOME"/.claude-* )
    set -f
    [ -n "$CLAUDE_CONFIG_DIR" ] && dirs+=( "$CLAUDE_CONFIG_DIR" )
    for dir in "${dirs[@]}"; do
        [ -d "$dir" ] || continue
        case "$seen" in *"|$dir|"*) continue ;; esac
        seen+="|$dir|"
        cache=$(claudefuel_usage_file_for_dir "$dir")
        [ -n "$cache" ] || continue
        label=$(profile_label_for_dir "$dir")
        mtime=$(file_mtime "$cache")
        age=$(( now - ${mtime:-$now} ))
        printf '%s\t%s\t%s\t%s\n' "$label" "$dir" "$cache" "$age"
    done
}

# Cross-profile switch hint — `⇄ <profile> <pct>% (<age>)` appended to
# Line 2 only when the active profile runs hot and a sibling profile's
# on-disk cache shows meaningfully more headroom. Severity-gated:
# dormant in every nominal state. Three gates:
#   1. active governing pct (max of 5h/7d) >= 80
#   2. sibling cache fresher than 6h — a 5h-window number older than
#      its own window says nothing about the sibling's current state
#   3. best sibling governing pct <= active - 20 (meaningful headroom)
# Usage: claudefuel_switch_hint <active_governing_pct> <active_profile_dir>
claudefuel_switch_hint() {
    # Demo renders never read the user's real sibling caches.
    [ -n "$demo_state" ] && return 0
    local active_pct=$1 active_dir=$2
    [ "$active_pct" -ge 80 ] 2>/dev/null || return 0

    local label dir cache age sib_pct
    local best_label="" best_pct=101 best_age=0
    while IFS=$'\t' read -r label dir cache age; do
        [ "$dir" = "$active_dir" ] && continue
        [ "$age" -lt $((6 * 3600)) ] || continue
        sib_pct=$(jq -r '[(.five_hour.utilization // 0), (.seven_day.utilization // 0)] | max | round' \
            "$cache" 2>/dev/null)
        case "$sib_pct" in ''|*[!0-9]*) continue ;; esac
        if [ "$sib_pct" -lt "$best_pct" ]; then
            best_pct=$sib_pct best_label=$label best_age=$age
        fi
    done < <(claudefuel_known_profile_caches)

    [ -n "$best_label" ] || return 0
    [ "$best_pct" -le $(( active_pct - 20 )) ] || return 0

    printf "⇄ %s %s%% (%s)" "$best_label" "$best_pct" "$(claudefuel_format_age "$best_age")"
}

# ===== Shared-window session heartbeats =====
# Every render touches <profile>/cache/claudefuel-sessions/s-<id>, so the
# sessions sharing one account window (the documented real-world confusion
# behind "usage stale / bar red") become countable. A heartbeat fresher
# than 5 minutes = a live session on this window.
# Usage: claudefuel_session_count <sessions_dir> [prune]
# Echoes the fresh count; with "prune", also removes expired heartbeats
# (the render path prunes; --fleet stays a pure read).
claudefuel_session_count() {
    local dir="$1" mode="${2:-}"
    [ -d "$dir" ] || { echo 0; return; }
    local count f m
    count=0
    set +f  # heartbeat scan needs globbing; restored immediately
    for f in "$dir"/*; do
        [ -f "$f" ] || continue
        m=$(file_mtime "$f")
        if [ -n "$m" ] && [ $(( now - m )) -lt 300 ]; then
            count=$(( count + 1 ))
        elif [ "$mode" = "prune" ]; then
            rm -f "$f" 2>/dev/null
        fi
    done
    set -f
    echo "$count"
}

# ===== Config report: shared merge/lint of claudefuel.json =====
# Emits {status, errors, warnings, info, effective, overridden_keys} for
# a config path. The single source of truth for "what does this config
# mean" outside the render loader: --validate-config wraps it for humans
# and skills; --snapshot embeds it so /claudefuel.why can answer "why is
# my bar red at 75%?" with "your color_thresholds.red is 70". The
# defaults and merge semantics here MUST mirror the render loader below
# (tests/render-demo.bats asserts the agreement).
claudefuel_config_report() {
    local path="$1"
    local defaults='{
        "version": 1, "theme": "default",
        "color_thresholds": {"orange": 50, "yellow": 70, "red": 90},
        "reset_display": "clock", "glyphs": "unicode", "hyperlinks": true,
        "segments": {
          "order": {"line1": ["model","session","ctx","thinking","effort","agent","activity","pr","drift"],
                    "columns": ["5h","7d","extra"]},
          "hide": []
        }
      }'
    if [ ! -f "$path" ]; then
        jq -n --argjson d "$defaults" \
            '{status: "absent", errors: [], warnings: [], info: [],
              effective: $d, overridden_keys: []}'
        return
    fi
    if ! jq -e . "$path" >/dev/null 2>&1; then
        local parse_err
        parse_err=$(jq . "$path" 2>&1 >/dev/null | head -n1)
        jq -n --argjson d "$defaults" --arg e "${parse_err:-invalid JSON}" \
            '{status: "malformed", errors: [$e], warnings: [], info: [],
              effective: $d, overridden_keys: []}'
        return
    fi
    jq --argjson d "$defaults" '
        def line1_tokens: ["model","session","ctx","thinking","effort","agent","activity","pr","drift"];
        def column_tokens: ["5h","7d","extra"];
        def hide_tokens: line1_tokens + column_tokens + ["profile","cap_eta","projection","sessions"];
        def known_keys: ["version","theme","color_thresholds","reset_display","glyphs","hyperlinks","segments"];

        # Nearest-match hint for a mistyped token, prefix-based ("7day" →
        # "7d", "profil" → "profile"); falls back to listing valid tokens.
        def suggest($tok; $valid):
          ([$valid[] | . as $v
            | select(($tok | startswith($v)) or ($v | startswith($tok)))] | first) as $s
          | if $s == null then "valid tokens: " + ($valid | join(", "))
            else "did you mean \"" + $s + "\"?" end;

        (if type == "object" then . else {} end) as $cfg
        | {
            version: ((($cfg.version)? | tonumber? // 1) | floor),
            theme: ((($cfg.theme)? // "default") | tostring),
            color_thresholds: {
              orange: ((($cfg.color_thresholds.orange)? | tonumber? // 50) | floor),
              yellow: ((($cfg.color_thresholds.yellow)? | tonumber? // 70) | floor),
              red:    ((($cfg.color_thresholds.red)?    | tonumber? // 90) | floor)
            },
            reset_display: ((($cfg.reset_display)? // "clock") | tostring),
            glyphs: ((($cfg.glyphs)? // "unicode") | tostring),
            hyperlinks: (if ($cfg | has("hyperlinks")) then $cfg.hyperlinks else true end),
            segments: {
              order: {
                line1: ((($cfg.segments.order.line1)? // $d.segments.order.line1)
                        | if type == "array" then map(tostring) else $d.segments.order.line1 end),
                columns: ((($cfg.segments.order.columns)? // $d.segments.order.columns)
                        | if type == "array" then map(tostring) else $d.segments.order.columns end)
              },
              hide: ((($cfg.segments.hide)? // [])
                     | if type == "array" then map(tostring) else [] end)
            }
          } as $eff
        | ([ ["theme"], ["color_thresholds","orange"], ["color_thresholds","yellow"],
             ["color_thresholds","red"], ["reset_display"], ["glyphs"], ["hyperlinks"],
             ["segments","order","line1"], ["segments","order","columns"],
             ["segments","hide"] ]
           | map(select(. as $p | (($cfg | getpath($p))? // null) != null) | join("."))
          ) as $overridden
        | (
            (if type != "object" then ["config is not a JSON object — defaults used"] else [] end)
            + (if $eff.version != 1
               then ["unsupported version \($eff.version) — this build understands version 1"] else [] end)
            + ([ "orange", "yellow", "red" ] | map(
                (($cfg.color_thresholds[.])? // null) as $v
                | if $v == null then empty
                  elif ($v | type) != "number" and (($v | tonumber?) == null)
                  then "color_thresholds.\(.) is not a number — default used"
                  elif ($v | tonumber) < 0 or ($v | tonumber) > 100
                  then "color_thresholds.\(.) is outside 0–100"
                  else empty end))
            + (if $eff.color_thresholds.orange >= $eff.color_thresholds.yellow
                  or $eff.color_thresholds.yellow >= $eff.color_thresholds.red
               then ["color_thresholds out of order — expected orange < yellow < red (the bar tolerates it, but severity colors will overlap)"]
               else [] end)
            + (if ["default","mono"] | index($eff.theme) | not
               then ["unknown theme \"\($eff.theme)\" — default palette used"] else [] end)
            + (if ["clock","countdown"] | index($eff.reset_display) | not
               then ["unknown reset_display \"\($eff.reset_display)\" — clock used"] else [] end)
            + (if ["unicode","ascii"] | index($eff.glyphs) | not
               then ["unknown glyphs \"\($eff.glyphs)\" — unicode used"] else [] end)
            + (if ($eff.hyperlinks | type) != "boolean"
               then ["hyperlinks is not true|false — anything but true disables"] else [] end)
            + (((($cfg.segments.order.line1)? // null) | if . != null and (type != "array") then ["segments.order.line1 is not an array — default used"] else [] end))
            + (((($cfg.segments.order.columns)? // null) | if . != null and (type != "array") then ["segments.order.columns is not an array — default used"] else [] end))
            + (((($cfg.segments.hide)? // null) | if . != null and (type != "array") then ["segments.hide is not an array — default used"] else [] end))
            + ($eff.segments.order.line1 | map(select(. as $t | line1_tokens | index($t) | not)
                | . as $t | "unknown token \"\($t)\" in segments.order.line1 — " + suggest($t; line1_tokens)))
            + ($eff.segments.order.columns | map(select(. as $t | column_tokens | index($t) | not)
                | . as $t | "unknown token \"\($t)\" in segments.order.columns — " + suggest($t; column_tokens)))
            + ($eff.segments.hide | map(select(. as $t | hide_tokens | index($t) | not)
                | . as $t | "unknown token \"\($t)\" in segments.hide — " + suggest($t; hide_tokens)))
          ) as $warnings
        | ((if type == "object" then keys else [] end)
           | map(select(. as $k | known_keys | index($k) | not)
             | "unknown top-level key \"\(.)\" preserved (may belong to a newer version)")
          ) as $info
        | {
            status: (if ($warnings | length) > 0 then "warnings" else "ok" end),
            errors: [], warnings: $warnings, info: $info,
            effective: $eff, overridden_keys: $overridden
          }
    ' "$path" 2>/dev/null
}

# ===== Fleet mode: machine-readable dump of every known profile cache =====
# `statusline.sh --fleet` emits one JSON object per known profile cache
# and exits — the data surface for the /claudefuel.fleet skill. Strictly
# read-only: renders only what's already on disk, never fetches, and
# always carries cache_age_seconds so the renderer can show staleness.
# resets_at is an ISO string from the OAuth cache or an epoch number from
# the native mirror; consumers must accept both.
if [ "$1" = "--fleet" ]; then
    while IFS=$'\t' read -r label dir cache age; do
        prepaid_file="$dir/cache/claudefuel-prepaid.json"
        prepaid_json="null"
        if [ -f "$prepaid_file" ]; then
            prepaid_json=$(jq -c '{amount: (.amount // null), currency: (.currency // null)}' \
                "$prepaid_file" 2>/dev/null)
            [ -n "$prepaid_json" ] || prepaid_json="null"
        fi
        sessions=$(claudefuel_session_count "$dir/cache/claudefuel-sessions")
        jq -c --arg profile "$label" --argjson age "$age" --argjson prepaid "$prepaid_json" \
            --argjson sessions "$sessions" \
            '{profile: $profile, cache_age_seconds: $age, sessions: $sessions,
              source: (.source // "oauth"),
              five_hour: (.five_hour // null), seven_day: (.seven_day // null),
              extra_usage: (.extra_usage // null), prepaid: $prepaid}' \
            "$cache" 2>/dev/null
    done < <(claudefuel_known_profile_caches)
    exit 0
fi

# ===== --snapshot: versioned machine-readable internal API =====
# Pure read of the on-disk caches plus the ADR-0004 derived math, dumped
# as JSON. No fetches, no stdin, no credential access, no cache writes.
# Consumed by the /claudefuel.why and /claudefuel.coach skills — the
# display stays dumb; the running LLM session does the explaining.
# Schema is versioned via .schema.version; breaking field changes bump it.
if [ "${1:-}" = "--snapshot" ]; then
    snapshot_now=$now

    snapshot_profile=$(profile_label_for_dir "$CLAUDE_CONFIG_DIR")

    # Provenance follows the bar: the native mirror (stdin rate_limits,
    # written every render) wins over the OAuth cache whenever it is at
    # least as fresh, so /claudefuel.why explains the numbers on screen.
    snapshot_usage_path=$(claudefuel_usage_file_for_dir "$config_dir")
    [ -n "$snapshot_usage_path" ] || snapshot_usage_path="$cache_dir/claudefuel-usage.json"
    snapshot_usage_ttl=300
    case "$snapshot_usage_path" in *claudefuel-native.json) snapshot_usage_ttl=2 ;; esac
    snapshot_prepaid_path="$cache_dir/claudefuel-prepaid.json"
    snapshot_version_path="$cache_dir/claudefuel-version.json"

    # Age of a file in seconds, or the literal string "null" when absent.
    snapshot_age() {
        [ -f "$1" ] || { echo "null"; return; }
        local m
        m=$(file_mtime "$1")
        [ -z "$m" ] && { echo "null"; return; }
        echo $(( snapshot_now - m ))
    }

    # Compact JSON contents of a file, or the literal string "null".
    snapshot_json() {
        local j
        j=$(jq -c . "$1" 2>/dev/null)
        [ -z "$j" ] && j=null
        echo "$j"
    }

    snapshot_installed=$installed_version
    snapshot_upstream=$(read_upstream_version "$snapshot_version_path")

    # v2: the config block — path, parse status, effective values,
    # overridden keys — so /claudefuel.why can explain config-driven
    # rendering without re-implementing the merge logic in prose.
    snapshot_config_path="${CLAUDEFUEL_CONFIG:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/claudefuel.json}"
    snapshot_config_report=$(claudefuel_config_report "$snapshot_config_path")
    [ -n "$snapshot_config_report" ] || snapshot_config_report="null"

    jq -n \
        --argjson now "$snapshot_now" \
        --arg profile "$snapshot_profile" \
        --arg config_path "$snapshot_config_path" \
        --argjson config_report "$snapshot_config_report" \
        --arg config_dir "${CLAUDE_CONFIG_DIR:-}" \
        --arg installed "${snapshot_installed:-}" \
        --arg upstream "${snapshot_upstream:-}" \
        --arg usage_path "$snapshot_usage_path" \
        --argjson usage_ttl "$snapshot_usage_ttl" \
        --arg prepaid_path "$snapshot_prepaid_path" \
        --arg version_path "$snapshot_version_path" \
        --argjson usage "$(snapshot_json "$snapshot_usage_path")" \
        --argjson usage_age "$(snapshot_age "$snapshot_usage_path")" \
        --argjson prepaid "$(snapshot_json "$snapshot_prepaid_path")" \
        --argjson prepaid_age "$(snapshot_age "$snapshot_prepaid_path")" \
        --argjson version_age "$(snapshot_age "$snapshot_version_path")" \
        '
        def iso2epoch:
          if . == null or . == "" then null
          elif type == "number" then floor
          else (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")
                | try (strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) catch null)
          end;

        ($usage.five_hour.utilization // null) as $util
        | (if $util == null then null else ($util | round) end) as $pct
        | ($usage.five_hour.resets_at // null) as $resets_iso
        | ($resets_iso | iso2epoch) as $resets_epoch
        | (if $resets_epoch == null then null else $resets_epoch - 18000 end) as $window_started
        | (if $window_started == null then null else ($now - $window_started) end) as $elapsed
        | (if $pct != null and $elapsed != null and $elapsed > 0
           then ($pct / $elapsed * 3600) else null end) as $burn_rate
        | (if $pct != null and $pct > 0 and $elapsed != null and $elapsed > 0
           then (($now + (100 - $pct) * $elapsed / $pct) | floor) else null end) as $cap_eta
        | (if $pct != null and $elapsed != null and $elapsed > 0
           then (($pct * 18000 / $elapsed) | floor) else null end) as $projected
        | (if $pct == null then null else $pct >= 10 end) as $noise_pass
        | (if $cap_eta == null or $resets_epoch == null then false
           else $cap_eta < $resets_epoch end) as $threshold_pass
        | {
            schema: { name: "claudefuel-snapshot", version: 2 },
            generated_at_epoch: $now,
            generated_at: ($now | todate),
            profile: {
              name: $profile,
              config_dir: (if $config_dir == "" then null else $config_dir end)
            },
            config: (if $config_report == null then null else {
              path: $config_path,
              status: $config_report.status,
              effective: $config_report.effective,
              overridden_keys: $config_report.overridden_keys
            } end),
            versions: {
              installed: (if $installed == "" then null else $installed end),
              upstream: (if $upstream == "" then null else $upstream end),
              drift: (if $upstream == "" or $installed == "" then null
                      else $upstream != $installed end)
            },
            caches: {
              usage: {
                path: $usage_path, present: ($usage != null),
                source: ($usage.source // "oauth"),
                age_seconds: $usage_age, ttl_seconds: $usage_ttl,
                fresh: ($usage_age != null and $usage_age < $usage_ttl)
              },
              prepaid: {
                path: $prepaid_path, present: ($prepaid != null),
                age_seconds: $prepaid_age, ttl_seconds: 300,
                fresh: ($prepaid_age != null and $prepaid_age < 300)
              },
              upstream_version: {
                path: $version_path, present: ($version_age != null),
                age_seconds: $version_age, ttl_seconds: 21600,
                fresh: ($version_age != null and $version_age < 21600)
              }
            },
            usage: $usage,
            prepaid: $prepaid,
            derived: {
              five_hour: {
                window_length_seconds: 18000,
                pct_used: $pct,
                resets_at: $resets_iso,
                resets_at_epoch: $resets_epoch,
                window_started_epoch: $window_started,
                elapsed_seconds: $elapsed,
                burn_rate_pct_per_hour: $burn_rate,
                reset_pace_pct_per_hour: 20,
                projected_pct_at_reset: $projected,
                cap_eta_epoch: $cap_eta,
                cap_eta: (if $cap_eta == null then null else ($cap_eta | todate) end),
                cap_eta_range_seconds: 900,
                gates: {
                  noise_floor: { rule: "pct_used >= 10", pass: $noise_pass },
                  threshold: { rule: "cap_eta < resets_at (burn rate > reset-pace)", pass: $threshold_pass }
                },
                cap_eta_rendered: (($noise_pass == true) and $threshold_pass)
              }
            }
          }
        '
    exit $?
fi

# ===== --validate-config: machine-checkable config lint =====
# `statusline.sh --validate-config [path]` prints a versioned JSON report
# (schema "claudefuel-config-check v1") for the given path — default: the
# resolved user config, CLAUDEFUEL_CONFIG-aware. Exit codes: 0 ok or
# warnings, 1 malformed, 2 absent. Run by /claudefuel.doctor and by the
# configure skill before and after every write.
if [ "${1:-}" = "--validate-config" ]; then
    vc_path="${2:-${CLAUDEFUEL_CONFIG:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/claudefuel.json}}"
    vc_report=$(claudefuel_config_report "$vc_path")
    [ -n "$vc_report" ] || { echo '{"schema":"claudefuel-config-check v1","status":"malformed","errors":["internal: report failed"]}'; exit 1; }
    jq -n --arg path "$vc_path" --argjson r "$vc_report" \
        '{schema: "claudefuel-config-check v1", path: $path} + $r'
    case "$(printf '%s' "$vc_report" | jq -r .status)" in
        malformed) exit 1 ;;
        absent)    exit 2 ;;
        *)         exit 0 ;;
    esac
fi

# ===== --subagent: row renderer for subagentStatusLine =====
# Claude Code's subagentStatusLine setting runs this once per refresh
# tick with every visible subagent row as one JSON object on stdin
# ({tasks: [{id, name, type, status, startTime, tokenCount, ...}]}).
# One JSON line out per row: {"id", "content"} — the agent name in a
# stable per-task color, a status glyph, elapsed since start, token
# count. Same doctrine as the activity segment: the payload has thin
# format guarantees, so every parse step degrades — emitting nothing
# keeps Claude Code's default row rendering.
if [ "${1:-}" = "--subagent" ]; then
    command -v jq >/dev/null 2>&1 || exit 0
    sub_input=$(cat)
    [ -n "$sub_input" ] || exit 0
    printf '%s' "$sub_input" | jq -c --argjson now "$now" '
        def tokfmt: if . >= 1000000 then "\(. / 100000 | floor / 10)m"
          elif . >= 1000 then "\(. / 1000 | round)k" else tostring end;
        def agefmt: if . < 60 then "\(.)s" elif . < 3600 then "\(. / 60 | floor)m"
          else "\(. / 3600 | floor)h" end;
        def glyph: {running: "▸", in_progress: "▸", pending: "·",
                    completed: "✓", success: "✓", failed: "✗", error: "✗"}[.] // "·";
        def hue: (explode | add) % 5
          | ["[38;2;0;153;255m", "[38;2;46;149;153m",
             "[38;2;0;160;0m", "[38;2;230;200;0m",
             "[38;2;255;176;85m"][.];
        def start2epoch:
          if type == "number" then (if . > 1000000000000 then . / 1000 | floor else floor end)
          elif type == "string" then (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")
            | try (strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) catch null)
          else null end;
        (.tasks // [])[]
        | . as $t
        | (($t.id // "") | tostring) as $id
        | select($id != "")
        | (($t.name // $t.type // "agent") | tostring) as $name
        | (($t.startTime // null) | start2epoch) as $started
        | (if $started == null then ""
           else " \((($now - $started) | if . < 0 then 0 else . end) | agefmt)" end) as $age
        | (if (($t.tokenCount // 0) | type) == "number" and ($t.tokenCount // 0) > 0
           then " · \($t.tokenCount | tokfmt)" else "" end) as $tok
        | {id: $id,
           content: "\($id | hue)\($name)[0m \((($t.status // "") | tostring) | glyph)\($age)\($tok)"}
    ' 2>/dev/null
    exit 0
fi

# ===== --demo <state>: first-class preview renders =====
# `statusline.sh --demo healthy|warning|critical|stale|offline` renders
# the full bar from canned built-in data for that state — no stdin, no
# network, no reads of the user's real caches, deterministic output
# (fixed CLAUDEFUEL_NOW + fixed timestamps make goldens byte-stable; the
# clock rendering still follows the host TZ). Honors CLAUDEFUEL_CONFIG,
# which is the whole point: the configure skill previews a candidate
# config against every alarm state before anything is written.
#   healthy  — green bars, live extra spend, all columns visible
#   warning  — yellow 5h / orange 7d, no projection alarms
#   critical — ⚠ escalation, burn chip, cap-ETA + steer-to, ▸ governing
#   stale    — OAuth-path bars with ·age marker + severe-staleness warning
#   offline  — no data at all: the failure trailhead
# The generalization of the doctor bulb-check; falls through to the
# normal render path below with `input` pre-set (never reads stdin).
demo_state=""
demo_now=1751500000  # fixed: 2025-07-02T23:46:40Z
if [ "${1:-}" = "--demo" ]; then
    case "${2:-}" in
        healthy|warning|critical|stale|offline) demo_state="$2" ;;
        *)
            echo "usage: statusline.sh --demo healthy|warning|critical|stale|offline" >&2
            exit 2
            ;;
    esac
    CLAUDEFUEL_NOW=$demo_now
    now=$demo_now
    CLAUDEFUEL_OFFLINE=1
    # Demo output is captured as text by the configure skill's preview
    # loop — OSC 8 sequences would read as garbage there, and byte-
    # stable goldens must not depend on the host terminal.
    FORCE_HYPERLINK=0
    case "$demo_state" in
        healthy)
            # 5h 30% with 2.5h elapsed (ratio 0.6 — nominal), 7d 12%.
            input='{"model":{"display_name":"Claude"},"session_id":"demo","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":40000}},"thinking":{"enabled":true},"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":1751509000},"seven_day":{"used_percentage":12,"resets_at":1751900000}}}'
            ;;
        warning)
            # 5h 72% (yellow) with ratio 0.86, 7d 55% (orange) ratio 0.64
            # — hot colors, but no window projected to cap: no alarms.
            input='{"model":{"display_name":"Claude"},"session_id":"demo","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":120000}},"thinking":{"enabled":true},"rate_limits":{"five_hour":{"used_percentage":72,"resets_at":1751503000},"seven_day":{"used_percentage":55,"resets_at":1751586400}}}'
            ;;
        critical)
            # 5h 93% burning ×1.2 with 1h to reset: ⚠ + inverse video,
            # burn chip, cap-ETA + steer-to, ▸ governing. ctx 95% red.
            input='{"model":{"display_name":"Claude"},"session_id":"demo","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":190000}},"thinking":{"enabled":true},"rate_limits":{"five_hour":{"used_percentage":93,"resets_at":1751503600},"seven_day":{"used_percentage":61,"resets_at":1751672800}}}'
            ;;
        stale|offline)
            # No rate_limits: exercises the OAuth fallback path so the
            # staleness machinery (stale) or trailhead (offline) renders.
            input='{"model":{"display_name":"Claude"},"session_id":"demo","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":120000}},"thinking":{"enabled":true}}'
            ;;
    esac
fi

[ -n "$demo_state" ] || input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# Honest instrument: a missing dependency must read FAILED, never render
# a plausible partial bar. One-glyph diagnosis + a '✚ /claudefuel.doctor'
# trailhead, mirroring the '↗ /claudefuel.update' drift pattern.
if ! command -v jq >/dev/null 2>&1; then
    printf "Claude | ? ✚ /claudefuel.doctor"
    exit 0
fi

# Timing mode (CLAUDEFUEL_TIMING=1): emit per-stage wall time to stderr so
# /claudefuel.doctor can check renders against the published latency budget.
# Uses jq as a portable millisecond clock (BSD date has no %N); each mark
# costs one extra jq spawn, so reported timings carry a few ms of
# instrumentation overhead. Stages: jq-parse, drift, usage, prepaid, render.
if [ -n "$CLAUDEFUEL_TIMING" ]; then
    _cf_t_last=$(jq -n 'now*1000|floor')
fi
cf_timing_mark() {
    [ -n "$CLAUDEFUEL_TIMING" ] || return 0
    local _cf_now
    _cf_now=$(jq -n 'now*1000|floor')
    printf 'claudefuel-timing: %s %dms\n' "$1" "$(( _cf_now - _cf_t_last ))" >&2
    _cf_t_last=$_cf_now
}

# ANSI colors
blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;160;0m'
cyan='\033[38;2;46;149;153m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
white='\033[38;2;220;220;220m'
dim='\033[2m'
inverse='\033[7m'
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
# shellcheck disable=SC2034 # read by future migration logic, not yet
cfg_version=1
cfg_theme="default"
cfg_th_orange=50
cfg_th_yellow=70
cfg_th_red=90
cfg_reset_display="clock"
cfg_glyphs="unicode"
cfg_hyperlinks="true"
cfg_line1_order="model session ctx thinking effort agent activity pr drift"
cfg_columns_order="5h 7d extra"
cfg_hide=""

# CLAUDEFUEL_CONFIG=<path> overrides the config-file location (read-only,
# same malformed-file-is-ignored semantics) — the preview seam behind the
# configure skill's before/after demos, validation testing, and goldens.
config_file="${CLAUDEFUEL_CONFIG:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/claudefuel.json}"
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
        "cfg_glyphs=" + (((.glyphs)? // "unicode") | tostring | @sh),
        "cfg_hyperlinks=" + ((try (if has("hyperlinks") then .hyperlinks else true end) catch true)
            | (if . == true then "true" else "false" end) | @sh),
        "cfg_line1_order=" + toks((.segments.order.line1)?; ["model","session","ctx","thinking","effort","agent","activity","pr","drift"]),
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

# ===== Responsive layout: COLUMNS-aware degradation ladder =====
# Claude Code sets COLUMNS for the script (v2.1.153+; tput does not work
# here). Per-segment priority, dropped from the bottom as width shrinks
# — the same hide/registry mechanics as user hides, so ordering and
# padding stay consistent. Rungs:
#   ≤90  line 1 slims: effort drops, "thinking:" abbreviates to "think:"
#        (line 1 is the longest line; it overflows first)
#   ≤80  the extra column drops (lowest-priority column)
#   ≤60  bars shrink to 5 cells, columns tighten, thinking drops
# Unknown/absent COLUMNS never constrains (wide terminals, older Claude
# Code, plain pipes).
term_cols=0
case "${COLUMNS:-}" in
    ''|*[!0-9]*) ;;
    *) term_cols=$COLUMNS ;;
esac
line1_bar_width=10
bar_width_default=10
col_width_default=19
thinking_label="thinking:"
if [ "$term_cols" -gt 0 ]; then
    if [ "$term_cols" -le 90 ]; then
        cfg_hide="$cfg_hide effort"
        thinking_label="think:"
    fi
    # ≤80: lines 2/3 are the longest once any chip fires — drop the extra
    # column, the ⧉ session count, the →N% projection and the ⇄ hint.
    [ "$term_cols" -le 80 ] && cfg_hide="$cfg_hide extra sessions projection"
    if [ "$term_cols" -le 60 ]; then
        cfg_hide="$cfg_hide thinking"
        line1_bar_width=5
        bar_width_default=5
        col_width_default=14
    fi
fi

# ===== OSC 8 hyperlinks: the bar becomes navigation =====
# Emitted only when the terminal is known to render them — Terminal.app
# must never see garbage. FORCE_HYPERLINK=1 overrides detection for
# tests and unusual setups (=0 forces off); hyperlinks: false in the
# config kills them regardless.
hyperlinks_on=false
if [ "$cfg_hyperlinks" = "true" ]; then
    if [ -n "${FORCE_HYPERLINK:-}" ]; then
        [ "$FORCE_HYPERLINK" != "0" ] && hyperlinks_on=true
    else
        case "${TERM_PROGRAM:-}" in
            iTerm.app|WezTerm|ghostty|kitty|vscode) hyperlinks_on=true ;;
        esac
        case "${TERM:-}" in
            *-kitty) hyperlinks_on=true ;;
        esac
    fi
fi

# Usage: cf_link <url> <text> — OSC 8 wrap when supported, plain text
# otherwise. Emits unexpanded \033/\a sequences like the color palette
# (printf %b at output expands them). Zero visible width, so no padding
# math changes anywhere.
cf_link() {
    if $hyperlinks_on; then
        printf '%s' "\033]8;;$1\a$2\033]8;;\a"
    else
        printf '%s' "$2"
    fi
}

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
    local num=$1 r
    if [ "$num" -ge 1000000 ]; then
        r=$(( (num + 50000) / 100000 ))        # tenths of a million, rounded
        printf '%d.%dm' $(( r / 10 )) $(( r % 10 ))
    elif [ "$num" -ge 1000 ]; then
        printf '%dk' $(( (num + 500) / 1000 ))
    else
        printf '%d' "$num"
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

# ===== Extract data from JSON — one jq pass =====
# Every stdin field the bar uses, in one process. Fields are joined with
# the ASCII unit separator so empty values survive `read` (tabs collapse).
IFS=$'\x1f' read -r model_name size input_tokens cache_create cache_read \
    thinking_val effort_level session_id session_name agent_name transcript_path \
    pr_number pr_url pr_state rl_5h_pct rl_5h_reset rl_7d_pct rl_7d_reset \
    <<<"$(printf '%s' "$input" | jq -r '[
        (.model.display_name // "Claude"),
        (.context_window.context_window_size // 200000),
        (.context_window.current_usage.input_tokens // 0),
        (.context_window.current_usage.cache_creation_input_tokens // 0),
        (.context_window.current_usage.cache_read_input_tokens // 0),
        (.thinking.enabled // false),
        (.effort.level // ""),
        (.session_id // ""),
        (.session_name // ""),
        (.agent.name // ""),
        (.transcript_path // ""),
        (.pr.number // ""),
        (.pr.url // ""),
        (.pr.review_state // ""),
        (.rate_limits.five_hour.used_percentage // "" | if type == "number" then round else . end),
        (.rate_limits.five_hour.resets_at // "" | if type == "number" then floor else . end),
        (.rate_limits.seven_day.used_percentage // "" | if type == "number" then round else . end),
        (.rate_limits.seven_day.resets_at // "" | if type == "number" then floor else . end)
    ] | map(tostring) | join("\u001f")' 2>/dev/null)"

model_name=${model_name:-Claude}
# Context window
[ "$size" -gt 0 ] 2>/dev/null || size=200000
: "${input_tokens:=0}" "${cache_create:=0}" "${cache_read:=0}"
current=$(( input_tokens + cache_create + cache_read ))
used_tokens=$(format_tokens "$current")
total_tokens=$(format_tokens "$size")
pct_used=$(( current * 100 / size ))

# Thinking (reflects Option+T) and reasoning effort (reflects /effort;
# absent when the model has no effort parameter) — live session state.
thinking_on=false
[ "$thinking_val" = "true" ] && thinking_on=true

# ===== Native-first usage source (stdin rate_limits) =====
# Conditional field (older Claude Code and non-subscription auth omit it)
# — never hard-required. Both windows' used_percentage must parse as
# numbers for stdin to take over; anything less falls back to the
# OAuth/cache path unchanged. used_percentage may be fractional;
# resets_at is a unix epoch. Values are validated here and derived in
# the window-snapshot block before the column loop.
usage_source="oauth"
case "$rl_5h_pct" in ''|*[!0-9]*) rl_5h_pct="" ;; esac
case "$rl_7d_pct" in ''|*[!0-9]*) rl_7d_pct="" ;; esac
[ -n "$rl_5h_pct" ] && [ -n "$rl_7d_pct" ] && usage_source="stdin"

cf_timing_mark jq-parse

# Fetch the upstream version header and atomically publish it to the drift
# cache (tmpfile+mv, so a concurrent render never reads a half-written
# file). Echoes the version on success. Shared by the synchronous
# first-ever-render path and the detached background refresh.
# Usage: claudefuel_fetch_upstream_version <cache_dir> <cache_file>
claudefuel_fetch_upstream_version() {
    local cache_dir="$1" cache_file="$2" fresh
    fresh=$(curl -fsSL --connect-timeout 2 --max-time 3 \
        "https://raw.githubusercontent.com/FlorianRiquelme/claudefuel/main/statusline.sh" 2>/dev/null \
        | head -20 | grep -E '^# claudefuel:' | head -n1 \
        | sed -E 's/^# claudefuel: v//')
    if [ -n "$fresh" ]; then
        [ -d "$cache_dir" ] || mkdir -p "$cache_dir"
        printf '{"upstream_version":"%s"}\n' "$fresh" > "$cache_file.tmp.$$" \
            && mv "$cache_file.tmp.$$" "$cache_file"
        echo "$fresh"
    fi
}

# Drift detection — when the cached upstream version is newer than the
# installed version, append a single '↗ /claudefuel.update' segment to
# line 1. No count, no growth in bar height, no segment when equal or
# when the install is ahead of the cache (a fresh local update can
# outrun the 6h cache TTL and a lagging raw.githubusercontent CDN copy).
# Cache lives at $CLAUDE_CONFIG_DIR/cache/claudefuel-version.json
# (or ~/.claude/cache/), TTL 6h. Never-block: a stale cached value still
# paints this render while a detached one-shot fetch refreshes the cache
# for the next render (see the no-daemon note at the usage fetch below);
# only a missing cache fetches synchronously (first-ever render).
# Set CLAUDEFUEL_OFFLINE=1 to skip any fetch.
claudefuel_drift_segment() {
    local cache_file="$cache_dir/claudefuel-version.json"
    local ttl_seconds=$((6 * 60 * 60))

    drift_installed=$installed_version
    [ -z "$drift_installed" ] && return 0

    drift_upstream=""
    local should_fetch=false
    if [ -f "$cache_file" ]; then
        drift_upstream=$(read_upstream_version "$cache_file")
        local cache_mtime
        cache_mtime=$(file_mtime "$cache_file")
        [ $(( now - ${cache_mtime:-0} )) -ge "$ttl_seconds" ] && should_fetch=true
    else
        should_fetch=true
    fi

    if $should_fetch && [ -z "$CLAUDEFUEL_OFFLINE" ]; then
        if [ -n "$drift_upstream" ]; then
            # Stale value paints below; refresh lands for the next render.
            # touch claims the refresh so overlapping renders don't re-fire.
            touch "$cache_file"
            ( claudefuel_fetch_upstream_version "$cache_dir" "$cache_file" ) \
                >/dev/null 2>&1 </dev/null &
            disown
        else
            # First-ever render: nothing cached to paint, fetch synchronously.
            drift_upstream=$(claudefuel_fetch_upstream_version "$cache_dir" "$cache_file")
        fi
    fi

    [ -z "$drift_upstream" ] && return 0
    [ "$drift_upstream" = "$drift_installed" ] && return 0

    # Same sort -V algorithm as compare_versions in /claudefuel.update:
    # prompt only when upstream is strictly newer than installed.
    local lowest
    lowest=$(printf '%s\n%s\n' "$drift_installed" "$drift_upstream" \
        | sort -V | head -n1)
    [ "$lowest" = "$drift_upstream" ] && return 0

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
        profile_name=$(profile_label_for_dir "$CLAUDE_CONFIG_DIR")
        profile_label="${yellow}[${profile_name}]${reset} "
    fi
    printf '%s' "${profile_label}${blue}${model_name}${reset}"
}

segment_ctx() {
    local ctx_bar
    ctx_bar=$(build_bar "$pct_used" "$line1_bar_width")
    printf '%s' "${white}ctx${reset} ${ctx_bar} ${orange}${used_tokens}/${total_tokens}${reset}"
}

segment_thinking() {
    if $thinking_on; then
        printf '%s' "${thinking_label} ${orange}On${reset}"
    else
        printf '%s' "${thinking_label} ${dim}Off${reset}"
    fi
}

segment_effort() {
    [ -n "$effort_level" ] || return 0
    printf '%s' "effort: ${cyan}${effort_level}${reset}"
}

# ===== The "Now" layer: what Claude is doing, not just what it costs =====

# Session identity chip — `◈ <name>` in a stable per-session color, so
# parallel panes are distinguishable at a glance. Prefers session_name
# (set via --name or /rename); falls back to a short session_id stem.
# Color = hash of session_id into a fixed 5-hue palette (red excluded:
# hue there means alarm). Pure stdin, zero cost.
segment_session() {
    # Renders only for a named session (--name or /rename): the bare
    # session_id stem was six hex characters nobody could act on. Naming
    # the session is the opt-in.
    [ -n "$session_name" ] || return 0
    local palette=("$blue" "$cyan" "$green" "$yellow" "$orange")
    local h=0 i key="${session_id:-$session_name}"
    for (( i=0; i<${#key} && i<32; i++ )); do
        printf -v c '%d' "'${key:i:1}"
        h=$(( h + c ))
    done
    printf '%s' "${palette[$(( h % 5 ))]}◈ ${session_name}${reset}"
}

# Subagent context — `agent: <name>` when this render belongs to a
# subagent session. Absent otherwise.
segment_agent() {
    [ -n "$agent_name" ] || return 0
    printf '%s' "agent: ${cyan}${agent_name}${reset}"
}

# Live activity — `▸ <tool> <age>`: the most recent tool_use in the
# transcript tail that has no matching tool_result yet (i.e. what Claude
# is doing right now), plus elapsed time since it started. Best-effort
# by doctrine: the transcript JSONL has no public format spec, so every
# parse step degrades to rendering nothing. Reads only the last 16KB —
# O(tail), never the whole file. Dormant once the pending call is older
# than 10 minutes (no longer credibly "now").
segment_activity() {
    [ -n "$transcript_path" ] && [ -f "$transcript_path" ] || return 0
    local pending
    pending=$(tail -c 16384 "$transcript_path" 2>/dev/null | jq -Rr '
        fromjson? | objects
        | .timestamp as $ts
        | ((.message.content)? // empty)
        | if type == "array" then .[] else empty end
        | objects
        | if .type == "tool_use" then "use\t\(.id // "")\t\(.name // "")\t\($ts // "")"
          elif .type == "tool_result" then "done\t\(.tool_use_id // "")\t\t"
          else empty end
    ' 2>/dev/null | awk -F'\t' '
        $1 == "use"  { name[$2] = $3; ts[$2] = $4; order[++n] = $2 }
        $1 == "done" { delete name[$2] }
        END { for (i = n; i >= 1; i--) if (order[i] in name) {
                  printf "%s\t%s\n", name[order[i]], ts[order[i]]; exit } }
    ')
    [ -n "$pending" ] || return 0

    local tool="${pending%%$'\t'*}" ts="${pending#*$'\t'}"
    [ -n "$tool" ] || return 0
    local chip="▸ ${tool}"
    if [ -n "$ts" ]; then
        local epoch elapsed
        epoch=$(iso_to_epoch "$ts")
        if [ -n "$epoch" ]; then
            elapsed=$(( now - epoch ))
            [ "$elapsed" -lt 0 ] && elapsed=0
            [ "$elapsed" -gt 600 ] && return 0
            chip+=" $(claudefuel_format_age "$elapsed")"
        fi
    fi
    printf '%s' "${orange}${chip}${reset}"
}

# PR chip — `#N <glyph>` for the current branch's PR, clickable to the
# PR page when hyperlinks are on. Review-state glyphs: ✓ approved,
# ✗ changes requested, ◇ draft, ◌ pending/unreviewed.
segment_pr() {
    [ -n "$pr_number" ] || return 0
    local g color
    case "$pr_state" in
        approved)          g="✓" color="$green" ;;
        changes_requested) g="✗" color="$red" ;;
        draft)             g="◇" color="$dim" ;;
        *)                 g="◌" color="$cyan" ;;
    esac
    local text="#${pr_number} ${g}"
    [ -n "$pr_url" ] && text=$(cf_link "$pr_url" "$text")
    printf '%s' "${color}${text}${reset}"
}

segment_drift() {
    # Demo renders are deterministic: the user's real version cache must
    # not leak a ↗ signal into a golden render.
    [ -n "$demo_state" ] && return 0
    local drift_segment
    drift_segment=$(claudefuel_drift_segment)
    [ -n "$drift_segment" ] || return 0

    # Severity gate: a patch-level bump renders faint — present but
    # de-escalated; a minor/major bump keeps the yellow weight. Derived
    # from the same two version strings the segment compared. The segment
    # ran in a subshell, so re-derive the two strings here (header read +
    # cache read, no network).
    local drift_color="$yellow" installed upstream
    installed=$installed_version
    upstream=$(read_upstream_version "$cache_dir/claudefuel-version.json")
    if [ -n "$upstream" ] && [ "${installed%.*}" = "${upstream%.*}" ]; then
        drift_color="$dim"
    fi
    printf '%s' "${drift_color}$(cf_link "https://github.com/FlorianRiquelme/claudefuel/releases" "$drift_segment")${reset}"
}

line1=""
for seg in $cfg_line1_order; do
    case "$seg" in model|session|ctx|thinking|effort|agent|activity|pr|drift) ;; *) continue ;; esac
    segment_hidden "$seg" && continue
    seg_out=$("segment_${seg}")
    [ -z "$seg_out" ] && continue
    [ -n "$line1" ] && line1+="$sep"
    line1+="$seg_out"
done

cf_timing_mark drift

# ===== Cross-platform OAuth token resolution (read-only) =====
# Sources in order: env var → macOS Keychain → credentials file → GNOME
# Keyring. The render path never mutates credentials: an expired access
# token (60s buffer) is an auth failure for this render, and Claude Code
# refreshes it on its own schedule.
# When CLAUDE_CONFIG_DIR is set, Claude Code appends the first 8 chars of
# SHA256(config_dir_path) to the credential service name — on every store.
# Resolved lazily (shasum is a fork) — only renders that reach a keychain
# or secret-tool lookup pay for it.
KEYCHAIN_SERVICE=""
keychain_service() {
    if [ -z "$KEYCHAIN_SERVICE" ]; then
        KEYCHAIN_SERVICE="Claude Code-credentials"
        if [ -n "$CLAUDE_CONFIG_DIR" ]; then
            local h
            h=$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)
            KEYCHAIN_SERVICE="Claude Code-credentials-${h}"
        fi
    fi
    printf '%s' "$KEYCHAIN_SERVICE"
}

# Echo the access token from a credential blob if present and unexpired.
# One jq for both fields. A blob without expiresAt is treated as expired.
token_from_blob() {
    local tok exp
    IFS=$'\x1f' read -r tok exp <<<"$(printf '%s' "$1" | jq -r '[
        (.claudeAiOauth.accessToken // ""),
        (.claudeAiOauth.expiresAt // "")
    ] | map(tostring) | join("\u001f")' 2>/dev/null)"
    [ -n "$tok" ] && [ "$tok" != "null" ] || return 1
    case "$exp" in ''|null|*[!0-9]*) return 1 ;; esac
    [ $(( now * 1000 )) -lt $(( exp - 60000 )) ] || return 1
    printf '%s' "$tok"
}

get_oauth_token() {
    # 1. Explicit env var override (no expiry check possible)
    if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
        printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN"
        return 0
    fi

    local blob acct
    # 2. macOS Keychain. Account name is the OS user on newer Claude Code,
    #    the literal "Claude Code" on older versions.
    if command -v security >/dev/null 2>&1; then
        for acct in "$(whoami)" "Claude Code"; do
            blob=$(security find-generic-password -s "$(keychain_service)" -a "$acct" -w 2>/dev/null) || continue
            [ -n "$blob" ] && token_from_blob "$blob" && return 0
        done
    fi

    # 3. Linux credentials file
    local creds_file="$config_dir/.credentials.json"
    if [ -f "$creds_file" ]; then
        token_from_blob "$(cat "$creds_file" 2>/dev/null)" && return 0
    fi

    # 4. GNOME Keyring via secret-tool (same profile-suffixed service name)
    if command -v secret-tool >/dev/null 2>&1; then
        blob=$(timeout 2 secret-tool lookup service "$(keychain_service)" 2>/dev/null)
        [ -n "$blob" ] && token_from_blob "$blob" && return 0
    fi

    return 1
}

# Atomic cross-process lock so only ONE statusline process — across all the
# concurrent Claude Code sessions sharing this account — hits a given API at a
# time. The per-account usage endpoint is rate-limited account-wide, so N open
# sessions all refreshing at once is itself a stampede. macOS ships no flock(1),
# so use mkdir: atomic create on every POSIX filesystem. A lock older than
# max_hold is assumed abandoned by a crashed holder and stolen.
# Usage: claudefuel_try_lock <lock_dir> <now_epoch> <max_hold_secs>  → 0 if acquired
claudefuel_try_lock() {
    local dir="$1" lock_now="$2" max_hold="$3"
    if mkdir "$dir" 2>/dev/null; then
        return 0
    fi
    local m
    m=$(file_mtime "$dir")
    if [ -n "$m" ] && [ $(( lock_now - m )) -gt "$max_hold" ]; then
        rm -rf "$dir" 2>/dev/null
        mkdir "$dir" 2>/dev/null && return 0
    fi
    return 1
}

# ===== LINE 2 & 3: Usage limits with progress bars (cached) =====
# All runtime files live in the active profile's cache dir.
cache_file="$cache_dir/claudefuel-usage.json"
# Tracks the last fetch *attempt* (success or failure) — separate from
# cache_file's mtime, which only moves on success. Without this, a failing
# fetch (e.g. rate-limited) never ages the cache_file mtime, so cache_age
# stays >= cache_max_age forever and every subsequent render retries the
# request with no backoff, which can keep an upstream rate limit alive
# indefinitely while silently showing stale numbers.
attempt_file="$cache_dir/claudefuel-usage.attempt"
# When the API rate-limits us (429) it returns a Retry-After telling us how
# long to stay quiet — often tens of minutes. This file records that deadline
# (absolute epoch seconds), shared by every endpoint on the host.
retryafter_file="$cache_dir/claudefuel-retry-after"
usage_lock_dir="$cache_dir/claudefuel-usage.lock"
# Cadence between OAuth usage calls. 5 min on the fallback path (the bars
# depend on it); 30 min when stdin rate_limits already drive the bars and
# the fetch only enriches the extra column — the endpoint is rate-limited
# per account and shared with Claude Code's own polling and every open
# session, so the enrichment footprint is kept small.
cache_max_age=300
[ "$usage_source" = "stdin" ] && cache_max_age=1800
[ -d "$cache_dir" ] || mkdir -p "$cache_dir" 2>/dev/null

# Native mirror: with stdin driving the bars, write the same numbers to
# the cache dir (usage-cache shape, resets_at as epoch) so --snapshot,
# --fleet and sibling profiles' ⇄ hint read what this bar shows rather
# than a minutes-old OAuth copy. A plain redirect — no process spawned.
if [ "$usage_source" = "stdin" ] && [ -z "$demo_state" ]; then
    printf '{"source":"stdin","five_hour":{"utilization":%s,"resets_at":%s},"seven_day":{"utilization":%s,"resets_at":%s}}\n' \
        "$rl_5h_pct" "${rl_5h_reset:-null}" "$rl_7d_pct" "${rl_7d_reset:-null}" \
        > "$cache_dir/claudefuel-native.json" 2>/dev/null
fi

# Heartbeat: mark this session live on this account window. The id is
# sanitized to a filename-safe alphabet before it touches the path.
sessions_dir="$cache_dir/claudefuel-sessions"
if [ -z "$demo_state" ] && [ -n "$session_id" ]; then
    session_hb="${session_id//[^A-Za-z0-9._-]/}"
    if [ -n "$session_hb" ]; then
        { [ -d "$sessions_dir" ] || mkdir -p "$sessions_dir" 2>/dev/null; } \
            && touch "$sessions_dir/s-${session_hb}" 2>/dev/null
    fi
fi

# Demo renders never touch the user's real caches: point every cache
# path at /dev/null (fails -f, so nothing is read) — the canned demo
# data is injected after the fetch/staleness machinery, which
# CLAUDEFUEL_OFFLINE=1 already keeps inert.
if [ -n "$demo_state" ]; then
    cache_file="/dev/null"
    attempt_file="/dev/null"
    retryafter_file="/dev/null"
fi

# Fetch /api/oauth/usage and atomically publish it to the usage cache
# (tmpfile+mv, so a concurrent render never reads a half-written file).
# Echoes the response on success. Shared by the synchronous
# first-ever-render path and the detached background refresh.
# Captures response headers so we can see the HTTP status and any
# Retry-After — a bare `curl -s` throws both away, which is how we
# ended up hammering a rate-limited endpoint blind.
claudefuel_fetch_usage() {
    local token="$1" response http_status hdr_file retry_secs
    hdr_file="$cache_dir/claudefuel-usage.hdr.$$"
    response=$(curl -s -D "$hdr_file" --max-time 5 \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-code/2.1.34" \
        "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
    http_status=$(awk 'toupper($1) ~ /^HTTP/ {print $2}' "$hdr_file" 2>/dev/null | tail -n1)
    if [ -n "$response" ] && echo "$response" | jq -e '.five_hour' >/dev/null 2>&1; then
        echo "$response" > "$cache_file.tmp.$$" && mv "$cache_file.tmp.$$" "$cache_file"
        rm -f "$retryafter_file" 2>/dev/null  # recovered — clear the cooldown
        echo "$response"
    elif [ "$http_status" = "429" ]; then
        # Record when we're allowed to try again. Retry-After is
        # delta-seconds here; fall back to a conservative 5 min if it's
        # missing or non-numeric.
        retry_secs=$(grep -i '^retry-after:' "$hdr_file" 2>/dev/null | tr -d '\r' | awk '{print $2}' | tail -n1)
        case "$retry_secs" in
            ''|*[!0-9]*) retry_secs=300 ;;
        esac
        echo $(( now + retry_secs )) > "$retryafter_file"
    fi
    rm -f "$hdr_file" 2>/dev/null
}

needs_refresh=true
usage_data=""
cache_mtime=""

# Cache-first paint: read whatever cache exists — fresh or stale — so the
# render never waits on the network once a cache file is on disk.
if [ -f "$cache_file" ]; then
    usage_data=$(<"$cache_file")
    cache_mtime=$(file_mtime "$cache_file")
    cache_age=$(( now - ${cache_mtime:-0} ))
    [ "$cache_age" -lt "$cache_max_age" ] && needs_refresh=false
fi

# Never-block fetch path. When a stale cache was painted above, refresh it
# with a DETACHED ONE-SHOT background fetch whose result benefits the next
# render. This stays on the right side of ADR-0003's no-daemon cliff: the
# background job is a single token-lookup + curl + atomic mv that exits on
# its own — no loop, no polling interval, no PID tracking or supervision,
# no IPC. Nothing outlives one fetch, and the bar itself stays a pure
# function of (stdin, env, cache files). Its stdio is detached from the
# statusline's pipes so Claude Code never waits on the child.
# CLAUDEFUEL_OFFLINE=1 skips the fetch entirely.

# Only attempt a network fetch if we haven't tried recently, regardless of
# whether that attempt succeeded. Touching the attempt marker (never the
# cache file) is what claims the refresh, so overlapping renders don't
# stampede duplicate fetches while the cache mtime stays an honest record
# of when the data last actually changed.
should_attempt=true
if [ -f "$attempt_file" ]; then
    attempt_mtime=$(file_mtime "$attempt_file")
    attempt_age=$(( now - ${attempt_mtime:-0} ))
    [ "$attempt_age" -lt "$cache_max_age" ] && should_attempt=false
fi

# Honor a server-issued Retry-After: stay quiet until the deadline passes.
# This dominates the normal cadence above — a 429 asks for a much longer
# wait, and retrying sooner just re-arms the rate limit.
if [ -f "$retryafter_file" ]; then
    retry_deadline=$(cat "$retryafter_file" 2>/dev/null)
    if [ -n "$retry_deadline" ] && [ "$now" -lt "$retry_deadline" ]; then
        should_attempt=false
    fi
fi

usage_failure=""  # one of: dep, auth, net — set when a fresh fetch was impossible
                   # (only reachable on a first-ever render with no cache at
                   # all; a stale cache always has something to paint instead)

# Fetch only when the cache is stale, the attempt cadence allows it, we're
# not offline, and we win the cross-process lock — so concurrent sessions
# don't all fire at the same deadline. A process that loses the lock simply
# paints the cache-first value from above; another process is refreshing.
if $needs_refresh && $should_attempt && [ -z "$CLAUDEFUEL_OFFLINE" ] \
    && claudefuel_try_lock "$usage_lock_dir" "$now" 15; then
    touch "$attempt_file" 2>/dev/null
    if [ -n "$usage_data" ] || [ "$usage_source" = "stdin" ]; then
        # Stale value already painted this render (or stdin carries the
        # bars and the fetch only enriches extra/fleet); the detached
        # refresh lands the fresh payload (or a 429 cooldown) for the
        # next one. Native-first contract: a render backed by stdin
        # rate_limits never waits on the network, not even first-ever.
        (
            token=$(get_oauth_token)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                claudefuel_fetch_usage "$token"
            fi
            rm -rf "$usage_lock_dir" 2>/dev/null
        ) >/dev/null 2>&1 </dev/null &
        disown
    else
        # First-ever render (no cache at all): fetch synchronously so the
        # bar doesn't paint empty on install. Honest instrument: when the
        # fetch can't happen or fails, classify why (missing dep / auth /
        # network) so a failed gauge reads FAILED instead of silence.
        if ! command -v curl >/dev/null 2>&1; then
            usage_failure="dep"
        else
            token=$(get_oauth_token)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                usage_data=$(claudefuel_fetch_usage "$token")
                [ -z "$usage_data" ] && usage_failure="net"
            else
                usage_failure="auth"
            fi
        fi
        rm -rf "$usage_lock_dir" 2>/dev/null
    fi
fi

# Honest instrument: data painted from a stale cache carries an age marker
# (`·9m`), never posing as fresh. Two tiers on the SAME data_age — mild
# staleness (past cache_max_age) always gets the subtle marker; severe
# staleness (fetches have been failing well beyond the normal cadence) ALSO
# gets the prominent "⚠ updates ~" warning telling the user WHEN it can next
# update (a retry deadline is more actionable than "how old" the data is):
#   - during a server-imposed 429 cooldown, the exact retry deadline;
#   - otherwise, the next scheduled attempt (cache_max_age after the last).
# The epoch is formatted to a clock time at render (format_clock_time).
# Provenance rule: the markers describe the DATA DRIVING THE BARS. When
# stdin rate_limits drives them the bars are per-render fresh, so no
# marker fires regardless of how old the OAuth cache is (the prepaid
# cell keeps its own age marker — separate cache, separate provenance).
usage_stale=false
usage_stale_age=""
usage_next_epoch=""
if [ "$usage_source" = "oauth" ] && [ -n "$usage_data" ] && [ -n "$cache_mtime" ]; then
    data_age=$(( now - cache_mtime ))
    if [ "$data_age" -ge "$cache_max_age" ]; then
        usage_stale_age=$data_age
    fi
    if [ "$data_age" -ge $(( cache_max_age * 3 )) ]; then
        usage_stale=true
        if [ -f "$retryafter_file" ]; then
            retry_deadline=$(cat "$retryafter_file" 2>/dev/null)
            case "$retry_deadline" in
                ''|*[!0-9]*) : ;;
                *) [ "$retry_deadline" -gt "$now" ] && usage_next_epoch="$retry_deadline" ;;
            esac
        fi
        if [ -z "$usage_next_epoch" ] && [ -f "$attempt_file" ]; then
            attempt_mtime=$(file_mtime "$attempt_file")
            next_attempt=$(( ${attempt_mtime:-0} + cache_max_age ))
            [ "$next_attempt" -gt "$now" ] && usage_next_epoch="$next_attempt"
        fi
    fi
fi

cf_timing_mark usage

# ===== Prepaid credit balance (separate cache, longer TTL) =====
# Balance changes slowly, so cache for 5 min to avoid hammering the API.
prepaid_cache_file="$cache_dir/claudefuel-prepaid.json"
prepaid_attempt_file="$cache_dir/claudefuel-prepaid.attempt"
prepaid_lock_dir="$cache_dir/claudefuel-prepaid.lock"
org_cache_file="$cache_dir/claudefuel-org-uuid"
prepaid_cache_max_age=300
prepaid_data=""
prepaid_stale=false

if [ -n "$demo_state" ]; then
    prepaid_cache_file="/dev/null"
    prepaid_attempt_file="/dev/null"
    org_cache_file="/dev/null"
fi

# Resolve org UUID (cached long-term, it never changes) and fetch the
# prepaid balance, atomically published via tmpfile+mv. Echoes the
# response on success. Shared by the synchronous first-ever-render path
# and the detached background refresh. Captures the HTTP status so a 429
# feeds the SHARED Retry-After cooldown — both endpoints live on the same
# rate-limited host, so a 429 from either pauses all account API traffic.
claudefuel_fetch_prepaid() {
    local token="$1" org_uuid account_resp prepaid_resp p_hdr p_status p_retry
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
    [ -z "$org_uuid" ] && return 0

    p_hdr="$cache_dir/claudefuel-prepaid.hdr.$$"
    prepaid_resp=$(curl -s -D "$p_hdr" --max-time 5 \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "User-Agent: claude-code/2.1.34" \
        "https://api.anthropic.com/api/oauth/organizations/$org_uuid/prepaid/credits" 2>/dev/null)
    p_status=$(awk 'toupper($1) ~ /^HTTP/ {print $2}' "$p_hdr" 2>/dev/null | tail -n1)
    if [ -n "$prepaid_resp" ] && echo "$prepaid_resp" | jq -e '.amount' >/dev/null 2>&1; then
        echo "$prepaid_resp" > "$prepaid_cache_file.tmp.$$" \
            && mv "$prepaid_cache_file.tmp.$$" "$prepaid_cache_file"
        echo "$prepaid_resp"
    elif [ "$p_status" = "429" ]; then
        # Feed the shared cooldown so the usage fetch backs off too.
        p_retry=$(grep -i '^retry-after:' "$p_hdr" 2>/dev/null | tr -d '\r' | awk '{print $2}' | tail -n1)
        case "$p_retry" in
            ''|*[!0-9]*) p_retry=300 ;;
        esac
        echo $(( now + p_retry )) > "$retryafter_file"
    fi
    rm -f "$p_hdr" 2>/dev/null
}

# Cache-first paint: stale balance still renders this turn.
if [ -f "$prepaid_cache_file" ]; then
    prepaid_data=$(<"$prepaid_cache_file")
    p_mtime=$(file_mtime "$prepaid_cache_file")
    p_age=$(( now - ${p_mtime:-0} ))
    [ "$p_age" -ge "$prepaid_cache_max_age" ] && prepaid_stale=true
fi

# Like the usage fetch, the prepaid fetch must not retry on every render when
# it fails — otherwise it stampedes api.anthropic.com and keeps the whole
# account rate-limited (which also 429s the usage endpoint, same host). Gate
# it on its own attempt marker AND the shared Retry-After cooldown that either
# fetch may set: a 429 from either endpoint pauses all account API traffic.
prepaid_should_attempt=true
if [ -f "$prepaid_attempt_file" ]; then
    pa_mtime=$(file_mtime "$prepaid_attempt_file")
    [ $(( now - ${pa_mtime:-0} )) -lt "$prepaid_cache_max_age" ] && prepaid_should_attempt=false
fi
if [ -f "$retryafter_file" ]; then
    prepaid_retry_deadline=$(cat "$retryafter_file" 2>/dev/null)
    case "$prepaid_retry_deadline" in
        ''|*[!0-9]*) : ;;
        *) [ "$now" -lt "$prepaid_retry_deadline" ] && prepaid_should_attempt=false ;;
    esac
fi

if [ -z "$CLAUDEFUEL_OFFLINE" ] && $prepaid_should_attempt \
    && { [ -z "$prepaid_data" ] || $prepaid_stale; } \
    && claudefuel_try_lock "$prepaid_lock_dir" "$now" 15; then
    touch "$prepaid_attempt_file" 2>/dev/null
    if [ -n "$prepaid_data" ]; then
        # Stale balance already painted this render; detached one-shot
        # refresh — see the no-daemon note at the usage fetch above.
        (
            token=$(get_oauth_token)
            if [ -n "$token" ] && [ "$token" != "null" ]; then
                claudefuel_fetch_prepaid "$token"
            fi
            rm -rf "$prepaid_lock_dir" 2>/dev/null
        ) >/dev/null 2>&1 </dev/null &
        disown
    else
        # First-ever render: fetch synchronously. Token may be unset if the
        # usage cache was fresh — resolve it now.
        [ -z "$token" ] || [ "$token" = "null" ] && token=$(get_oauth_token)
        if [ -n "$token" ] && [ "$token" != "null" ]; then
            prepaid_data=$(claudefuel_fetch_prepaid "$token")
        fi
        rm -rf "$prepaid_lock_dir" 2>/dev/null
    fi
fi

# Age marker for the extra cell — rendered whenever the balance shown came
# from a stale cache read, never posing as fresh (same doctrine as usage).
prepaid_stale_age=""
if [ -n "$prepaid_data" ] && $prepaid_stale; then
    prepaid_stale_age=$p_age
fi

# ===== --demo data injection =====
# With every fetch inert and every cache path pointed at /dev/null, set
# the same variables the machinery above would have produced — canned,
# fixed-timestamp values per state. healthy/warning/critical carry their
# bars on stdin rate_limits; usage_data only feeds the extra column.
if [ -n "$demo_state" ]; then
    case "$demo_state" in
        healthy|warning|critical)
            usage_data='{"extra_usage":{"is_enabled":true,"used_credits":350}}'
            prepaid_data='{"amount":2500,"currency":"USD"}'
            ;;
        stale)
            # OAuth-path snapshot, 9 minutes old: ·9m marker on the 5h
            # cell, prominent ⚠ updates warning with a fixed deadline.
            usage_data='{"five_hour":{"utilization":72,"resets_at":"2025-07-03T00:36:40Z"},"seven_day":{"utilization":55,"resets_at":"2025-07-03T23:46:40Z"},"extra_usage":{"is_enabled":true,"used_credits":350}}'
            usage_stale=true
            usage_stale_age=540
            usage_next_epoch=$(( demo_now + 240 ))
            prepaid_data='{"amount":2500,"currency":"USD"}'
            prepaid_stale_age=540
            ;;
        offline)
            usage_data=""
            prepaid_data=""
            usage_failure="net"
            ;;
    esac
fi

cf_timing_mark prepaid

# Resolve a stdin rate_limits resets_at value to epoch seconds. The
# documented shape is a unix epoch (digits pass through untouched — no
# date(1) parsing, so no BSD/GNU divergence); anything else defensively
# goes through iso_to_epoch. Failure renders no reset cell, but the bar
# itself still paints.
resolve_stdin_epoch() {
    case "$1" in
        '') return 0 ;;
        *[!0-9]*) iso_to_epoch "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

# Format an epoch to compact local time (one date exec; am/pm lowercased,
# BSD's space-padded hour trimmed).
# Usage: format_epoch_time <epoch> <style: time|datetime|date>
format_epoch_time() {
    local epoch="$1" style="$2" fmt
    [ -z "$epoch" ] && return
    case "$style" in
        time)     fmt="%l:%M%p" ;;
        datetime) fmt="%b %-d, %l:%M%p" ;;
        *)        fmt="%b %-d" ;;
    esac
    local out
    out=$(cf_date "$epoch" "$fmt")
    out="${out//  / }"; out="${out# }"
    out="${out/AM/am}"; out="${out/PM/pm}"
    printf '%s' "$out"
}

# Format an epoch (seconds) as a local clock time like "5:53pm".
format_clock_time() {
    format_epoch_time "$1" "time"
}

# Format an epoch as a compact countdown to it (e.g. "in 42m",
# "in 2h05m", "in 4d21h"). Used in place of format_epoch_time when
# reset_display=countdown is configured (or CLAUDEFUEL_RESET_COUNTDOWN=1).
format_countdown() {
    local epoch=$1
    [ -z "$epoch" ] && return
    local diff=$(( epoch - now ))
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

# Compact duration formatter: seconds → "1h50m" / "42m".
# Usage: format_duration <seconds>
format_duration() {
    local secs=$1 h m
    [ "$secs" -lt 0 ] 2>/dev/null && secs=0
    h=$(( secs / 3600 )); m=$(( (secs % 3600) / 60 ))
    if [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"
    else printf '%dm' "$m"
    fi
}

# Projected cap epoch for a usage window — the governing-constraint
# primitive behind the ▸ marker and the cap-ETA segment. Same gates as
# ADR-0004: noise floor pct >= 10%, and only meaningful when the window
# would hit 100% before its own reset. Stateless: pure snapshot math.
# Usage: claudefuel_cap_epoch <pct_used> <reset_at_epoch> <window_seconds>
# Echoes the projected 100% epoch, or nothing when the window won't cap.
claudefuel_cap_epoch() {
    local pct=$1
    local reset_epoch=$2
    local window_length=$3

    [ -z "$reset_epoch" ] && return 0
    [ "$pct" -ge 10 ] 2>/dev/null || return 0

    local window_started elapsed
    window_started=$(( reset_epoch - window_length ))
    elapsed=$(( now - window_started ))
    [ "$elapsed" -gt 0 ] || return 0

    local cap_eta
    cap_eta=$(( now + (100 - pct) * elapsed / pct ))
    [ "$cap_eta" -lt "$reset_epoch" ] || return 0

    printf "%s" "$cap_eta"
}

# Burn chip — time-at-pace + normalized burn ratio for the 5h cell on
# Line 2 (e.g. "~1h38m ×1.4"): time until projected 100% at the current
# burn rate, and that rate as a multiple of reset-pace. Stateless: pure
# function of one snapshot. Shares the cap-ETA gates (ADR-0004): dormant
# when burn rate <= reset-pace (ratio ≤1.0 — you'll never hit the cap)
# or pct_used < 10% (noise floor).
# Usage: claudefuel_burn_chip <pct_used> <reset_at_epoch>
# Echoes "~XhYYm ×N.N" or empty.
claudefuel_burn_chip() {
    local pct=$1
    local reset_epoch=$2
    local window_length=$((5 * 3600))

    [ -z "$reset_epoch" ] && return 0
    [ "$pct" -ge 10 ] 2>/dev/null || return 0

    local window_started elapsed
    window_started=$(( reset_epoch - window_length ))
    elapsed=$(( now - window_started ))
    [ "$elapsed" -gt 0 ] || return 0

    # ratio > 1.0 ⟺ pct/elapsed > 100/window — exact in integers.
    [ $(( pct * window_length )) -gt $(( 100 * elapsed )) ] || return 0

    local time_to_cap ratio
    time_to_cap=$(( (100 - pct) * elapsed / pct ))
    # ratio to one decimal, rounded: tenths = pct*window*10 / (100*elapsed)
    local r10=$(( (pct * window_length * 20 / (100 * elapsed) + 1) / 2 ))
    ratio="$(( r10 / 10 )).$(( r10 % 10 ))"

    printf "~%s ×%s" "$(format_duration "$time_to_cap")" "$ratio"
}

# End-of-window projection — `→N%`: where the 5h window lands at reset
# if the current average pace holds (pct × window / elapsed). Stateless,
# same snapshot algebra as the burn chip, and its exact complement:
#   ratio > 1  → the burn chip + cap-ETA own the story (projection would
#                just read →100%) — dormant here.
#   ratio ≤ 1  → no cap coming, but where do I land? Renders when the
#                projected landing crosses the yellow severity threshold
#                (config-driven: a calmer ladder also calms this chip).
# Same noise floor as cap-ETA (pct >= 10, ADR-0004). The → glyph marks
# it a prediction, never a measurement.
# Usage: claudefuel_projection <pct_used> <reset_at_epoch>
# Echoes "→N%" or empty.
claudefuel_projection() {
    local pct=$1
    local reset_epoch=$2
    local window_length=$((5 * 3600))

    [ -z "$reset_epoch" ] && return 0
    [ "$pct" -ge 10 ] 2>/dev/null || return 0

    local window_started elapsed
    window_started=$(( reset_epoch - window_length ))
    elapsed=$(( now - window_started ))
    [ "$elapsed" -gt 0 ] || return 0

    # Burning hot (ratio > 1): dormant — the burn chip renders instead.
    [ $(( pct * window_length )) -le $(( 100 * elapsed )) ] || return 0

    local projected
    projected=$(( pct * window_length / elapsed ))
    [ "$projected" -ge "$cfg_th_yellow" ] || return 0

    printf "→%s%%" "$projected"
}

# Cap-ETA segment — predicted wall-clock 100% time for the 5h window.
# Stateless: computed from a single snapshot (pct + reset epoch), no
# samples persisted across renders. Renders only when burn rate exceeds
# reset-pace AND pct_used >= 10%. See ADR-0004.
# When it fires, two prescriptive extensions ride along (same snapshot
# algebra, no extra gates of their own beyond the noted dormancies):
#   slow ≤N.N× — steer-to: the pace multiple (vs reset-pace) that makes
#                the remaining budget last until reset. Floored to one
#                decimal so the instruction never overstates the allowance.
#   ⚓ XhYYm    — stranding gap: dead time between projected cap and
#                reset. Dormant under 5 minutes (not actionable).
# Usage: claudefuel_cap_eta_segment <pct_used> <reset_at_epoch>
# Echoes "~cap HH:MMxm-HH:MMxm · slow ≤N.N× · ⚓ XhYYm" or empty.
claudefuel_cap_eta_segment() {
    local pct=$1
    local reset_epoch=$2
    local window_length=$((5 * 3600))

    local cap_eta
    cap_eta=$(claudefuel_cap_epoch "$pct" "$reset_epoch" "$window_length")
    [ -z "$cap_eta" ] && return 0

    # Horizon-scaled uncertainty: ±15% of the time-to-cap horizon,
    # floored at ±5min. Near caps get tight honest ranges; far caps
    # get wide ones (the fixed ±15min band claimed false precision
    # at long horizons and false vagueness at short ones).
    local time_to_cap=$(( cap_eta - now ))
    local half_band
    half_band=$(( time_to_cap * 15 / 100 ))
    [ "$half_band" -lt 300 ] && half_band=300

    local cap_low=$(( cap_eta - half_band )) cap_high=$(( cap_eta + half_band ))
    local segment
    segment="~cap $(format_clock_time "$cap_low")-$(format_clock_time "$cap_high")"

    # Steer-to: floor((100-pct)/remaining ÷ reset-pace, 1 decimal).
    # Always < 1.0 when cap-ETA fires, so it is always a slow-down.
    local remaining=$(( reset_epoch - now ))
    local steer
    local s10=$(( (100 - pct) * window_length * 10 / (100 * remaining) ))
    steer="$(( s10 / 10 )).$(( s10 % 10 ))"
    segment+=" · slow ≤${steer}×"

    # Stranding gap: dormant under 5 minutes.
    local gap=$(( reset_epoch - cap_eta ))
    if [ "$gap" -ge 300 ]; then
        segment+=" · ⚓ $(format_duration "$gap")"
    fi

    printf "%s" "$segment"
}

# Format a cache age in seconds as a compact marker value ("9m", "5h").
# Used by the staleness age marker: stale cache must never render
# indistinguishably from fresh data.
format_cache_age() {
    local age=$1
    if [ "$age" -ge 3600 ]; then
        printf "%dh" $(( age / 3600 ))
    else
        printf "%dm" $(( age / 60 ))
    fi
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
# five_hour_pct / five_hour_reset_epoch and the $governing marker are
# precomputed once before the column loop (see the window-snapshot block
# below) — the governing constraint needs both windows before either
# column renders.
column_5h() {
    local five_hour_reset five_hour_bar
    # `↻ <time>` is the default; CLAUDEFUEL_RESET_COUNTDOWN=1 (env, opt-in)
    # or reset_display: "countdown" (config) render `↻ in XhYYm` instead.
    if [ "$CLAUDEFUEL_RESET_COUNTDOWN" = "1" ] || [ "$cfg_reset_display" = "countdown" ]; then
        five_hour_reset=$(format_countdown "$five_hour_reset_epoch")
    else
        five_hour_reset=$(format_epoch_time "$five_hour_reset_epoch" "time")
    fi
    five_hour_bar=$(build_bar "$five_hour_pct" "$bar_width")

    # ≥90% escalation: shape/weight, not hue alone — ⚠ label prefix and
    # inverse-video value. ▸ marks the governing constraint. Prefix length
    # is tracked numerically (multibyte glyphs defeat ${#} under some locales).
    local col1_prefix="" col1_prefix_len=0
    [ "$governing" = "5h" ] && { col1_prefix+="▸"; col1_prefix_len=$(( col1_prefix_len + 1 )); }
    local escalate=false
    if [ "$five_hour_pct" -ge 90 ]; then
        col1_prefix+="⚠"; col1_prefix_len=$(( col1_prefix_len + 1 ))
        escalate=true
    fi

    # Burn chip: when burning hot, lead with time-at-pace + ratio and
    # demote the percent to the bar fill alone. Dormant otherwise (plain
    # percent shows). The >=90% escalation wraps whichever value is shown.
    local burn_chip_plain col1_value_plain col1_pct_str
    burn_chip_plain=$(claudefuel_burn_chip "$five_hour_pct" "$five_hour_reset_epoch")
    if [ -n "$burn_chip_plain" ]; then
        col1_value_plain="$burn_chip_plain"
    else
        col1_value_plain="${five_hour_pct}%"
    fi

    # End-of-window projection (→N% at reset) — only meaningful when the
    # burn chip is dormant (ratio ≤ 1); its own gates live in
    # claudefuel_projection. Hide-only token "projection".
    local proj_plain=""
    if [ -z "$burn_chip_plain" ] && ! segment_hidden projection; then
        proj_plain=$(claudefuel_projection "$five_hour_pct" "$five_hour_reset_epoch")
    fi
    if $escalate; then
        col1_pct_str="${red}${inverse}${col1_value_plain}${reset}"
    else
        col1_pct_str="${cyan}${col1_value_plain}${reset}"
    fi

    # Calculate visible length: prefix + "5h: " + bar + " " + value
    local col1_bar_vis_len=$(( col1_prefix_len + 4 + bar_width + 1 + ${#col1_value_plain} ))
    local col1_bar_raw="${white}${col1_prefix}5h:${reset} ${five_hour_bar} ${col1_pct_str}"

    # Prediction chip rides dim after the value. Visible length counted
    # numerically: 1 for the → glyph + the ASCII remainder (multibyte
    # glyphs defeat ${#} under some locales).
    if [ -n "$proj_plain" ]; then
        local proj_rest="${proj_plain#→}"
        col1_bar_raw+=" ${dim}${proj_plain}${reset}"
        col1_bar_vis_len=$(( col1_bar_vis_len + 2 + ${#proj_rest} ))
    fi

    # Staleness age marker — one snapshot drives lines 2–3, so one marker
    # on the leading (5h) cell: `·9m` = this data is 9 minutes old.
    if [ -n "$usage_stale_age" ]; then
        local stale_age_str
        stale_age_str=$(format_cache_age "$usage_stale_age")
        col1_bar_raw+=" ${dim}·${stale_age_str}${reset}"
        col1_bar_vis_len=$(( col1_bar_vis_len + 2 + ${#stale_age_str} ))
    fi
    # col_bar padding deferred — see col1w_actual computation below (cap-ETA may widen col1).

    local col1_reset_plain="↻ ${five_hour_reset}"
    col_reset="${white}$(cf_link "https://claude.ai/settings/usage" "↻ ${five_hour_reset}")${reset}"

    # Cap-ETA: see ADR-0004. Append to the 5h reset cell when present.
    local cap_eta_plain=""
    if ! segment_hidden cap_eta; then
        cap_eta_plain=$(claudefuel_cap_eta_segment "$five_hour_pct" "$five_hour_reset_epoch")
    fi
    if [ -n "$cap_eta_plain" ]; then
        col1_reset_plain+=" · ${cap_eta_plain}"
        col_reset+=" ${dim}· ${cap_eta_plain}${reset}"
    fi

    # Widen col1 when cap-ETA or the burn chip grows a cell — keeps Line 2/3 pipes aligned.
    local col1w_actual=$col1w
    [ "${#col1_reset_plain}" -gt "$col1w_actual" ] && col1w_actual="${#col1_reset_plain}"
    [ "$col1_bar_vis_len" -gt "$col1w_actual" ] && col1w_actual="$col1_bar_vis_len"
    col_bar=$(pad_column "$col1_bar_raw" "$col1_bar_vis_len" "$col1w_actual")
    col_reset=$(pad_column "$col_reset" "${#col1_reset_plain}" "$col1w_actual")
}

# ---- 7-day ----
column_7d() {
    local seven_day_reset seven_day_bar
    if [ "$cfg_reset_display" = "countdown" ]; then
        seven_day_reset=$(format_countdown "$seven_day_reset_epoch")
    else
        seven_day_reset=$(format_epoch_time "$seven_day_reset_epoch" "datetime")
    fi
    seven_day_bar=$(build_bar "$seven_day_pct" "$bar_width")

    local col2_prefix="" col2_prefix_len=0
    [ "$governing" = "7d" ] && { col2_prefix+="▸"; col2_prefix_len=$(( col2_prefix_len + 1 )); }
    local col2_pct_str="${cyan}${seven_day_pct}%${reset}"
    if [ "$seven_day_pct" -ge 90 ]; then
        col2_prefix+="⚠"; col2_prefix_len=$(( col2_prefix_len + 1 ))
        col2_pct_str="${red}${inverse}${seven_day_pct}%${reset}"
    fi

    local col2_bar_vis_len=$(( col2_prefix_len + 4 + bar_width + 1 + ${#seven_day_pct} + 1 ))
    col_bar="${white}${col2_prefix}7d:${reset} ${seven_day_bar} ${col2_pct_str}"
    col_bar=$(pad_column "$col_bar" "$col2_bar_vis_len" "$col2w")

    local col2_reset_plain="↻ ${seven_day_reset}"
    col_reset="${white}$(cf_link "https://claude.ai/settings/usage" "↻ ${seven_day_reset}")${reset}"
    col_reset=$(pad_column "$col_reset" "${#col2_reset_plain}" "$col2w")
}

# ---- Extra usage (prepaid credit balance) ----
# Visibility gate: the column earns its pixels only once spend is live
# (used_credits > 0) — a $0 month renders nothing. This supersedes gating
# on the balance itself: a depleted balance with live spend still renders
# (an out-of-credit alarm must never hide).
column_extra() {
    # OAuth enrichment: extra_usage lives only in the usage cache. With
    # stdin driving the bars the cache may legitimately be absent — the
    # column stays dormant until a background fetch lands one.
    [ -n "$usage_data" ] || return 0
    [ -n "$prepaid_data" ] || return 0
    local extra_live prepaid_amount prepaid_currency sym
    # One jq over both payloads: the spend gate and the formatted balance.
    IFS=$'\x1f' read -r extra_live prepaid_amount prepaid_currency <<<"$(
        jq -rn --argjson u "$usage_data" --argjson p "$prepaid_data" '[
            (($u.extra_usage.is_enabled // false) == true and (($u.extra_usage.used_credits // 0) | tonumber? // 0) > 0),
            ((($p.amount // 0) | tonumber? // 0) / 100 | . * 100 | round / 100 | tostring
                | if test("\\.[0-9]$") then . + "0" elif test("\\.") then . else . + ".00" end),
            ($p.currency // "USD")
        ] | map(tostring) | join("\u001f")' 2>/dev/null)"
    [ "$extra_live" = "true" ] || return 0
    case "$prepaid_currency" in
        EUR) sym="€" ;;
        GBP) sym="£" ;;
        JPY) sym="¥" ;;
        *)   sym="\$" ;;
    esac

    col_bar="${white}extra:${reset} ${cyan}$(cf_link "https://claude.ai/settings/billing" "${sym}${prepaid_amount}")${reset}"

    # Staleness age marker for the prepaid cell (separate cache, own age).
    if [ -n "$prepaid_stale_age" ]; then
        col_bar+=" ${dim}·$(format_cache_age "$prepaid_stale_age")${reset}"
    fi
}

line2=""
line3=""

if [ "$usage_source" = "stdin" ] \
    || { [ -n "$usage_data" ] && echo "$usage_data" | jq -e . >/dev/null 2>&1; }; then
    bar_width=$bar_width_default
    col1w=$col_width_default
    col2w=$col_width_default

    # ---- Window snapshots (extracted up front: the governing-constraint
    # marker needs both windows before either column renders). Native
    # first: stdin rate_limits when present, the OAuth cache otherwise. ----
    if [ "$usage_source" = "stdin" ]; then
        five_hour_pct=$rl_5h_pct
        five_hour_reset_epoch=$(resolve_stdin_epoch "$rl_5h_reset")
        seven_day_pct=$rl_7d_pct
        seven_day_reset_epoch=$(resolve_stdin_epoch "$rl_7d_reset")
    else
        IFS=$'\x1f' read -r five_hour_pct five_hour_reset_iso seven_day_pct seven_day_reset_iso \
            <<<"$(printf '%s' "$usage_data" | jq -r '[
                ((.five_hour.utilization // 0) | tonumber? // 0 | round),
                (.five_hour.resets_at // ""),
                ((.seven_day.utilization // 0) | tonumber? // 0 | round),
                (.seven_day.resets_at // "")
            ] | map(tostring) | join("\u001f")' 2>/dev/null)"
        : "${five_hour_pct:=0}" "${seven_day_pct:=0}"
        five_hour_reset_epoch=$(iso_to_epoch "$five_hour_reset_iso")
        seven_day_reset_epoch=$(iso_to_epoch "$seven_day_reset_iso")
    fi

    # ---- Governing constraint (▸) — whichever window would hit 100%
    # first at the current burn rate, dive-computer style. A marker, not
    # a reordering: the layout stays stable for spatial memory. Empty
    # when no window is projected to cap before its own reset.
    five_hour_cap=$(claudefuel_cap_epoch "$five_hour_pct" "$five_hour_reset_epoch" $((5 * 3600)))
    seven_day_cap=$(claudefuel_cap_epoch "$seven_day_pct" "$seven_day_reset_epoch" $((7 * 24 * 3600)))
    governing=""
    if [ -n "$five_hour_cap" ] && [ -n "$seven_day_cap" ]; then
        if [ "$five_hour_cap" -le "$seven_day_cap" ]; then governing="5h"; else governing="7d"; fi
    elif [ -n "$five_hour_cap" ]; then governing="5h"
    elif [ -n "$seven_day_cap" ]; then governing="7d"
    fi

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

    # Shared-window session count — `⧉ N` when more than one live session
    # is drawing on this account window. Explains the classic confusion
    # ("why is my bar hot / stale? — eleven other panes share this
    # window") right where it arises. Dormant at one session; hidden by
    # the ≤80-column ladder. Hide-only token "sessions". Detail view:
    # /claudefuel.fleet.
    if [ -z "$demo_state" ] && ! segment_hidden sessions; then
        session_count=$(claudefuel_session_count "$sessions_dir" prune)
        if [ "$session_count" -gt 1 ]; then
            line2+="${sep}${dim}⧉ ${session_count}${reset}"
        fi
    fi

    # Cross-profile switch hint — sibling headroom when the active profile
    # runs hot. Reads sibling on-disk caches only; see claudefuel_switch_hint.
    # Uses the raw max(5h, 7d) pct, distinct from $governing above (which
    # tracks projected-to-cap, not simply the higher of the two numbers).
    active_governing_pct=$five_hour_pct
    [ "$seven_day_pct" -gt "$active_governing_pct" ] 2>/dev/null && active_governing_pct=$seven_day_pct
    switch_hint=""
    [ "$term_cols" -eq 0 ] || [ "$term_cols" -gt 80 ] && switch_hint=$(claudefuel_switch_hint "$active_governing_pct" "$config_dir")
    [ -n "$switch_hint" ] && line2+="${sep}${yellow}${switch_hint}${reset}"

    # Severe staleness (fetches have been failing well beyond the normal
    # cadence): append a prominent warning telling the user WHEN usage can
    # next update, on top of the per-column age markers above.
    if $usage_stale; then
        next_update=$(format_clock_time "$usage_next_epoch")
        if [ -n "$next_update" ]; then
            line2+="${sep}${red}⚠ updates ~${next_update}${reset}"
        else
            line2+="${sep}${red}⚠ updates soon${reset}"
        fi
    fi

elif [ -n "$usage_failure" ]; then
    # Failed gauge reads FAILED: no data to show and a known failure class.
    # One-glyph diagnosis + trailhead, mirroring the ↗ drift segment:
    #   ⊘ auth (credentials missing/expired), ⚠ network, ? missing dependency.
    case "$usage_failure" in
        auth) fail_glyph="⊘" ;;
        net)  fail_glyph="⚠" ;;
        *)    fail_glyph="?" ;;
    esac
    line2="${dim}${fail_glyph}${reset} ${yellow}✚ /claudefuel.doctor${reset}"
fi

# Glyph degradation: glyphs "ascii" maps every multibyte glyph to a
# 1:1 ASCII stand-in just before output — one place, full coverage,
# alignment preserved (padding counts one cell per glyph either way).
# Default "unicode" costs nothing. No Nerd Font glyph is required in
# either mode.
if [ "$cfg_glyphs" = "ascii" ]; then
    cf_ascii() {
        sed -e 's/●/#/g; s/○/./g; s/▸/>/g; s/⚠/!/g; s/↻/@/g; s/⇄/=/g' \
            -e 's/◈/*/g; s/⧉/+/g; s/✚/+/g; s/→/>/g; s/⚓/\&/g; s/×/x/g' \
            -e 's/·/./g; s/≤/</g; s/↗/^/g; s/✓/v/g; s/✗/x/g; s/◌/o/g; s/◇/-/g'
    }
    line1=$(printf '%s' "$line1" | cf_ascii)
    line2=$(printf '%s' "$line2" | cf_ascii)
    line3=$(printf '%s' "$line3" | cf_ascii)
fi

# Output all lines
printf "%b" "$line1"
[ -n "$line2" ] && printf "\n%b" "$line2"
[ -n "$line3" ] && printf "\n%b" "$line3"

cf_timing_mark render

exit 0
