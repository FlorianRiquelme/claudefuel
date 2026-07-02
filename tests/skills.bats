#!/usr/bin/env bats

# Smoke tests for the seven /claudefuel.* skill files.
# Skill prose is LLM-executed — we don't test behavior here, only the
# install-time contract: file present, version header parseable.

COMMANDS_DIR="${BATS_TEST_DIRNAME}/../commands"
SKILLS=(update doctor rollback uninstall configure why coach)

@test "all seven skills exist in commands/" {
  for s in "${SKILLS[@]}"; do
    [ -f "$COMMANDS_DIR/claudefuel.${s}.md" ] || { echo "missing: claudefuel.${s}.md"; return 1; }
  done
}

@test "every skill has a parseable '# claudefuel-skill: vX.Y.Z' header" {
  for s in "${SKILLS[@]}"; do
    local file="$COMMANDS_DIR/claudefuel.${s}.md"
    local header
    header=$(head -20 "$file" | grep -E '^# claudefuel-skill: v' | head -n1)
    if [ -z "$header" ]; then
      echo "no version header in claudefuel.${s}.md"
      return 1
    fi
    if ! [[ "$header" =~ ^\#\ claudefuel-skill:\ v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "malformed version header in claudefuel.${s}.md: $header"
      return 1
    fi
  done
}

@test "every skill has a frontmatter description" {
  for s in "${SKILLS[@]}"; do
    local file="$COMMANDS_DIR/claudefuel.${s}.md"
    run head -5 "$file"
    [[ "$output" == *"description:"* ]] || { echo "no description in claudefuel.${s}.md"; return 1; }
  done
}

# /claudefuel.fleet is new and not yet part of the five-skill stability
# contract — expanding that contract is an open ADR-level question (see
# the cross-profile headroom commit). Until settled, its file format is
# tested separately rather than folded into SKILLS above.
@test "claudefuel.fleet.md exists with parseable header and frontmatter description" {
  local file="$COMMANDS_DIR/claudefuel.fleet.md"
  [ -f "$file" ]
  local header
  header=$(head -20 "$file" | grep -E '^# claudefuel-skill: v' | head -n1)
  [[ "$header" =~ ^\#\ claudefuel-skill:\ v[0-9]+\.[0-9]+\.[0-9]+$ ]]
  run head -5 "$file"
  [[ "$output" == *"description:"* ]]
}

@test "consultation skills read the versioned snapshot API, not the rendered bar" {
  # /claudefuel.why and /claudefuel.coach consume `statusline.sh --snapshot`
  # (the versioned internal API) and must pin the schema version they
  # understand. If either reference is dropped, the skill silently decouples
  # from the script's output contract.
  for s in why coach; do
    run grep -F -- "--snapshot" "$COMMANDS_DIR/claudefuel.${s}.md"
    [ "$status" -eq 0 ] || { echo "claudefuel.${s}.md does not reference --snapshot"; return 1; }
    run grep -F "claudefuel-snapshot" "$COMMANDS_DIR/claudefuel.${s}.md"
    [ "$status" -eq 0 ] || { echo "claudefuel.${s}.md does not pin the snapshot schema"; return 1; }
  done
}

@test "claudefuel.update.md references INSTALL.md's Post-install summary" {
  # The upgrade skill defers to INSTALL.md's "Post-install summary" section
  # rather than duplicating discoverability prose. If this reference is
  # dropped, prose drift between install and upgrade becomes inevitable.
  run grep -F "Post-install summary" "$COMMANDS_DIR/claudefuel.update.md"
  [ "$status" -eq 0 ]
}
