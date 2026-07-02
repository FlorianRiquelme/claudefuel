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

# ===== configure v2: the preview loop is the heart of the feature =====

@test "configure skill is built around the preview loop" {
  local f="$COMMANDS_DIR/claudefuel.configure.md"
  grep -q -- '--demo healthy' "$f"
  grep -q -- '--demo critical' "$f"
  grep -q 'CLAUDEFUEL_CONFIG=' "$f"
  grep -q -- '--validate-config' "$f"
  grep -qi 'never write a config the user hasn.t seen rendered' "$f"
  grep -q 'live on your next render' "$f"
}

@test "configure skill ships the intent vocabulary and presets" {
  local f="$COMMANDS_DIR/claudefuel.configure.md"
  grep -q 'preset `minimal`' "$f"
  grep -q 'preset `focus`' "$f"
  grep -q 'preset `cockpit`' "$f"
  grep -qi 'calmer' "$f"
  grep -qi 'colorblind' "$f"
  grep -q 'no `preset` key' "$f"
}

@test "configure skill carries the write guardrails and undo" {
  local f="$COMMANDS_DIR/claudefuel.configure.md"
  grep -q 'claudefuel.json.bak-' "$f"
  grep -qi 'undo' "$f"
  grep -q 'Never `settings.json`' "$f"
  grep -qi 'sparse' "$f"
  grep -qi 'preserve unknown keys' "$f"
  grep -qi 'degrade' "$f"
}

@test "configure skill keeps the LLM-context budget (~150 lines)" {
  local lines
  lines=$(wc -l < "$COMMANDS_DIR/claudefuel.configure.md")
  [ "$lines" -le 150 ]
}
