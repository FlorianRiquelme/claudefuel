#!/usr/bin/env bats

# Smoke tests for the INSTALL.md bundle contract.
# These guard against drift in the prose between INSTALL.md and the
# files actually shipped in commands/. INSTALL.md is LLM-executed —
# what we test here is the contract surface (which files are named,
# in what order, with what postconditions), not the execution.

INSTALL_MD="${BATS_TEST_DIRNAME}/../INSTALL.md"
SKILLS=(update doctor rollback uninstall configure)

@test "INSTALL.md names every shipped /claudefuel.* command file" {
  # Accepts either an explicit per-file mention or the brace-expansion
  # form claudefuel.{update,doctor,...}.md used by the desired-state list.
  for s in "${SKILLS[@]}"; do
    run grep -E "claudefuel\.(${s}|\{[^}]*${s}[^}]*\})\.md" "$INSTALL_MD"
    [ "$status" -eq 0 ] || { echo "INSTALL.md does not mention claudefuel.${s}.md"; return 1; }
  done
}

@test "INSTALL.md desired state covers commands/ directory" {
  run grep -E "commands/" "$INSTALL_MD"
  [ "$status" -eq 0 ]
}

@test "INSTALL.md desired state covers cache/ directory" {
  run grep -E "cache/" "$INSTALL_MD"
  [ "$status" -eq 0 ]
}

@test "INSTALL.md documents the diagnostic dump on reconcile failure" {
  # ADR-0005: the script dumps cache/claudefuel-update-diagnostic.json on
  # failure and the LLM drives forward from it — no auto-revert.
  run grep -F "claudefuel-update-diagnostic.json" "$INSTALL_MD"
  [ "$status" -eq 0 ]
}

@test "INSTALL.md never instructs writing to claudefuel.json (user-owned)" {
  # Should NEVER appear as a write target. Mentioning it as 'never touched'
  # is fine; instructions like 'write claudefuel.json' are not.
  run grep -E "(write|create|patch|modify).*claudefuel\.json" "$INSTALL_MD"
  [ "$status" -ne 0 ]
}

@test "INSTALL.md declares a Post-install summary section" {
  # Canonical discoverability surface for dormant bar behaviors.
  # /claudefuel.update defers to this section on upgrade; renaming it
  # silently would break the cross-reference.
  run grep -E "^## Post-install summary" "$INSTALL_MD"
  [ "$status" -eq 0 ]
}

@test "INSTALL.md Post-install summary mentions cap-ETA" {
  # The cap-ETA segment is dormant until burning hot — users will not
  # see it on first render, so it must be surfaced in chat. This test
  # guards against the discoverability prose being silently removed.
  run grep -F "~cap" "$INSTALL_MD"
  [ "$status" -eq 0 ]
}
