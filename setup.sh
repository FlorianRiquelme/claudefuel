#!/bin/bash
# Claude Code Dual Account Setup
#
# Sets up two isolated Claude Code environments (e.g. work + personal) that can
# run simultaneously in separate terminal tabs with independent usage tracking.
#
# How it works:
#   - Creates separate config directories (~/.claude-work, ~/.claude-personal)
#   - Symlinks shared config (CLAUDE.md, settings, rules, agents, skills, etc.)
#   - Each dir gets its own keychain credentials and session data
#   - Installs a multi-account-aware statusline that shows per-account usage
#
# Usage:
#   ./setup.sh                    # Interactive setup
#   ./setup.sh --names ops dev    # Custom profile names instead of work/personal
#
# After setup, authenticate each account:
#   claude-work auth login
#   claude-personal auth login
#
# Then just use the aliases:
#   claude-work      # Uses work account
#   claude-personal  # Uses personal account

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_HOME="${HOME}/.claude"
SHELL_RC=""
PROFILE_1="work"
PROFILE_2="personal"
SKIP_PERMISSIONS=false
DRY_RUN=false

# ── Parse arguments ────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --names)
            PROFILE_1="$2"
            PROFILE_2="$3"
            shift 3
            ;;
        --skip-permissions)
            SKIP_PERMISSIONS=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# ── Helpers ────────────────────────────────────────────────────────────────────

info()  { printf '\033[38;2;0;153;255m▸\033[0m %s\n' "$*"; }
ok()    { printf '\033[38;2;0;160;0m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[38;2;255;176;85m⚠\033[0m %s\n' "$*"; }
err()   { printf '\033[38;2;255;85;85m✗\033[0m %s\n' "$*" >&2; }

run() {
    if $DRY_RUN; then
        echo "  [dry-run] $*"
    else
        "$@"
    fi
}

# ── Preflight checks ──────────────────────────────────────────────────────────

if ! command -v claude >/dev/null 2>&1; then
    err "Claude Code CLI not found. Install it first: https://docs.anthropic.com/en/docs/claude-code"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    err "jq is required but not installed. Install with: brew install jq"
    exit 1
fi

if [ ! -d "$CLAUDE_HOME" ]; then
    err "~/.claude/ not found. Run 'claude' at least once first to initialize."
    exit 1
fi

# Detect shell RC file
if [ -n "${ZSH_VERSION:-}" ] || [ "$(basename "$SHELL")" = "zsh" ]; then
    SHELL_RC="$HOME/.zshrc"
elif [ -n "${BASH_VERSION:-}" ] || [ "$(basename "$SHELL")" = "bash" ]; then
    SHELL_RC="$HOME/.bashrc"
else
    SHELL_RC="$HOME/.profile"
fi

# ── Step 1: Create config directories ─────────────────────────────────────────

DIR_1="$HOME/.claude-${PROFILE_1}"
DIR_2="$HOME/.claude-${PROFILE_2}"

info "Creating config directories..."

for dir in "$DIR_1" "$DIR_2"; do
    if [ -d "$dir" ]; then
        warn "$(basename "$dir") already exists — will update symlinks"
    else
        run mkdir -p "$dir"
        ok "Created $dir"
    fi
done

# ── Step 2: Symlink shared config ─────────────────────────────────────────────

# Files/dirs to symlink (config that should be shared across accounts)
SHARE_FILES=(
    CLAUDE.md
    settings.json
    mcp.json
    .lsp.json
)

SHARE_DIRS=(
    rules
    agents
    skills
    commands
    hooks
    plugins
)

info "Symlinking shared config..."

for dir in "$DIR_1" "$DIR_2"; do
    for f in "${SHARE_FILES[@]}"; do
        src="$CLAUDE_HOME/$f"
        [ -e "$src" ] && run ln -sf "$src" "$dir/$f"
    done
    for d in "${SHARE_DIRS[@]}"; do
        src="$CLAUDE_HOME/$d"
        [ -e "$src" ] && run ln -sf "$src" "$dir/$d"
    done
done

ok "Shared config symlinked to both profiles"

# ── Step 3: Install statusline ─────────────────────────────────────────────────

STATUSLINE_SRC="$SCRIPT_DIR/statusline.sh"
STATUSLINE_DST="$CLAUDE_HOME/statusline.sh"

if [ -f "$STATUSLINE_SRC" ]; then
    info "Installing multi-account-aware statusline..."
    if [ -f "$STATUSLINE_DST" ] && ! $DRY_RUN; then
        cp "$STATUSLINE_DST" "$STATUSLINE_DST.backup-$(date +%Y%m%d%H%M%S)"
        ok "Backed up existing statusline.sh"
    fi
    run cp "$STATUSLINE_SRC" "$STATUSLINE_DST"
    run chmod +x "$STATUSLINE_DST"
    ok "Statusline installed"

    # Symlink statusline to both config dirs
    for dir in "$DIR_1" "$DIR_2"; do
        run ln -sf "$STATUSLINE_DST" "$dir/statusline.sh"
    done
else
    warn "statusline.sh not found in repo — skipping"
fi

# ── Step 4: Add shell aliases ──────────────────────────────────────────────────

PERM_FLAG=""
if $SKIP_PERMISSIONS; then
    PERM_FLAG=" --dangerously-skip-permissions"
fi

ALIAS_1="alias claude-${PROFILE_1}='CLAUDE_CONFIG_DIR=\"\$HOME/.claude-${PROFILE_1}\" claude${PERM_FLAG}'"
ALIAS_2="alias claude-${PROFILE_2}='CLAUDE_CONFIG_DIR=\"\$HOME/.claude-${PROFILE_2}\" claude${PERM_FLAG}'"
ALIAS_BLOCK="
# Claude Code dual-account aliases
${ALIAS_1}
${ALIAS_2}"

info "Configuring shell aliases in $SHELL_RC..."

if grep -q "claude-${PROFILE_1}" "$SHELL_RC" 2>/dev/null; then
    warn "Aliases already present in $SHELL_RC — skipping (review manually if needed)"
else
    if ! $DRY_RUN; then
        echo "$ALIAS_BLOCK" >> "$SHELL_RC"
    else
        echo "  [dry-run] Would append to $SHELL_RC:"
        echo "$ALIAS_BLOCK"
    fi
    ok "Aliases added"
fi

# ── Step 5: Clear stale shared cache ──────────────────────────────────────────

if [ -f /tmp/claude/statusline-usage-cache.json ]; then
    run rm -f /tmp/claude/statusline-usage-cache.json
    ok "Cleared stale shared usage cache"
fi

# ── Summary ────────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ok "Setup complete!"
echo ""
echo "  Next steps:"
echo ""
echo "  1. Reload your shell:"
echo "     source $SHELL_RC"
echo ""
echo "  2. Authenticate each account:"
echo "     claude-${PROFILE_1} auth login"
echo "     claude-${PROFILE_2} auth login"
echo ""
echo "  3. Use them:"
echo "     claude-${PROFILE_1}      # opens with ${PROFILE_1} account"
echo "     claude-${PROFILE_2}      # opens with ${PROFILE_2} account"
echo ""
echo "  Both can run simultaneously in separate terminal tabs."
echo "  The statusline shows per-account usage automatically."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
