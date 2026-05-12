#!/usr/bin/env bats

# Smoke tests for the five /claudefuel.* skill files.
# Skill prose is LLM-executed — we don't test behavior here, only the
# install-time contract: file present, version header parseable.

COMMANDS_DIR="${BATS_TEST_DIRNAME}/../commands"
SKILLS=(update doctor rollback uninstall configure)

@test "all five skills exist in commands/" {
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
