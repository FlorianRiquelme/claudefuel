#!/usr/bin/env bats

# Tests for the version comparison algorithm used by /claudefuel.update
# and INSTALL.md Step 2 (see docs/design/upgrade-experience.md).
#
# The canonical home of compare_versions is the /claudefuel.update skill
# prose. This fixture mirrors that snippet verbatim so the algorithm
# is mechanically testable. If you change one, change the other.

setup() {
  source "${BATS_TEST_DIRNAME}/fixtures/compare_versions.sh"
}

@test "equal versions return 'equal'" {
  run compare_versions "0.1.1" "0.1.1"
  [ "$status" -eq 0 ]
  [ "$output" = "equal" ]
}

@test "spec newer than installed (patch bump) returns 'spec-newer'" {
  run compare_versions "0.1.0" "0.1.1"
  [ "$status" -eq 0 ]
  [ "$output" = "spec-newer" ]
}

@test "installed newer than spec returns 'installed-newer'" {
  run compare_versions "0.2.0" "0.1.5"
  [ "$status" -eq 0 ]
  [ "$output" = "installed-newer" ]
}

@test "multi-digit components compare numerically (0.10.0 > 0.2.0)" {
  run compare_versions "0.10.0" "0.2.0"
  [ "$status" -eq 0 ]
  [ "$output" = "installed-newer" ]
}

@test "fixture matches /claudefuel.update skill prose verbatim" {
  local skill="${BATS_TEST_DIRNAME}/../commands/claudefuel.update.md"
  local fixture="${BATS_TEST_DIRNAME}/fixtures/compare_versions.sh"
  local skill_fn fixture_fn
  skill_fn=$(awk '/^compare_versions\(\) {/,/^}/' "$skill")
  fixture_fn=$(awk '/^compare_versions\(\) {/,/^}/' "$fixture")
  [ -n "$skill_fn" ]
  [ "$skill_fn" = "$fixture_fn" ]
}
