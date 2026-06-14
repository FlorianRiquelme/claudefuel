#!/usr/bin/env bats

# Tests for the three-state version comparison algorithm.
#
# Since ADR-0005 the /claudefuel.update skill no longer carries this
# snippet — the fixture in fixtures/compare_versions.sh is the canonical
# home, kept for the install-step2.bats regression guards.

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
