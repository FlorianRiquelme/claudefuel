# shellcheck shell=bash
# Canonical three-state version-comparison algorithm.
# Since ADR-0005 the /claudefuel.update skill no longer carries this snippet —
# this fixture is the canonical home, kept for the install-step2.bats regression guards.

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
