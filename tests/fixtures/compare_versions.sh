# shellcheck shell=bash
# Canonical version-comparison algorithm — mirrored verbatim from the
# /claudefuel.update skill prose (commands/claudefuel.update.md).
# If you change one, change the other.

compare_versions() {
  local installed="$1" spec="$2"
  if [ "$installed" = "$spec" ]; then
    echo "equal"
    return 0
  fi
  local lowest
  lowest=$(printf '%s\n%s\n' "$installed" "$spec" | sort -V | head -n1)
  if [ "$lowest" = "$installed" ]; then
    echo "spec-newer"
  else
    echo "installed-newer"
  fi
}
