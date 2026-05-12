#!/usr/bin/env bats

# Tests for INSTALL.md Step 2's three-state branching.
# Step 2 is LLM-executed prose; what we test is the algorithm it must
# follow:
#   1. parse spec's `Version:` line from INSTALL.md
#   2. compare against installed via the same compare_versions algorithm
#      verified in version-compare.bats
#
# These tests guard against regression back to the `>= 0.1.0` floor bug.

setup() {
  source "${BATS_TEST_DIRNAME}/fixtures/compare_versions.sh"
  INSTALL_MD="${BATS_TEST_DIRNAME}/../INSTALL.md"
}

parse_spec_version() {
  grep -E '^Version:' "$INSTALL_MD" | head -n1 \
    | sed -E 's/^Version: *`?([^`]+)`?.*/\1/'
}

@test "INSTALL.md declares a parseable Version: line" {
  run parse_spec_version
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "INSTALL.md no longer uses the '>= 0.1.0' floor" {
  run grep -E ">= 0\.1\.0" "$INSTALL_MD"
  [ "$status" -ne 0 ]
}

@test "Step 2 references the three-state outcomes" {
  run grep -E "installed-newer|spec-newer" "$INSTALL_MD"
  [ "$status" -eq 0 ]
}

@test "older installed vs current spec triggers upgrade, not no-op (regression)" {
  # Regression guard for the original Step-2 bug: `>= 0.1.0` floor caused
  # any post-0.1.0 install to silently no-op. With the three-state compare,
  # an older installed version against a newer spec must yield spec-newer.
  spec=$(parse_spec_version)
  state=$(compare_versions "0.1.0" "$spec")
  if [ "$spec" = "0.1.0" ]; then
    skip "spec is 0.1.0; regression case requires spec > 0.1.0"
  fi
  [ "$state" = "spec-newer" ]
}

@test "installed equal to spec is a no-op (equal)" {
  spec=$(parse_spec_version)
  state=$(compare_versions "$spec" "$spec")
  [ "$state" = "equal" ]
}
