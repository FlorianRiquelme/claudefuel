#!/usr/bin/env bats

# Tests for the claudefuel script (Phase 2 of update-redesign-implementation).
# Covers:
#   - --version and no-arg usage
#   - inspect_state against vanilla / partial / broken-settings fixtures
#   - update against a fixture target_dir with mocked curl
#   - four output shapes (current, current+incomplete, upgrade, installed-newer)
#   - failure diagnostic JSON write
#   - bak set pruning (keep 3 most recent)

SCRIPT="${BATS_TEST_DIRNAME}/../claudefuel"

setup() {
  TMP=$(mktemp -d "${BATS_TMPDIR:-/tmp}/cf-XXXXXX")
  export CLAUDE_CONFIG_DIR="$TMP"
  mkdir -p "$TMP/commands" "$TMP/cache"

  # Mock curl: prepare a stub on PATH that reads canned responses.
  MOCK_BIN="$TMP/_bin"
  mkdir -p "$MOCK_BIN"
  export CLAUDEFUEL_API_BASE="mock://api"
  export CLAUDEFUEL_RAW_BASE="mock://raw"
  export MOCK_DIR="$TMP/_mock"
  mkdir -p "$MOCK_DIR"

  cat >"$MOCK_BIN/curl" <<'EOF'
#!/usr/bin/env bash
# Minimal curl mock — handles -fsSL <url> and -o <file>.
url=""
outfile=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) outfile="$2"; shift 2 ;;
    --max-time|--connect-timeout|--max-redirs|--proto|--proto-redir) shift 2 ;;
    -fsSL|-sSL|-s|-S|-L|-f) shift ;;
    --version) printf 'curl mock\n'; exit 0 ;;
    *) url="$1"; shift ;;
  esac
done
# Map url -> file under MOCK_DIR
key=$(printf '%s' "$url" | sed 's|[^A-Za-z0-9._-]|_|g')
src="$MOCK_DIR/$key"
if [ ! -f "$src" ]; then exit 22; fi
if [ -n "$outfile" ]; then cp "$src" "$outfile"; else cat "$src"; fi
EOF
  chmod +x "$MOCK_BIN/curl"
  export PATH="$MOCK_BIN:$PATH"
}

teardown() {
  rm -rf "$TMP"
}

mock_url() {
  local url="$1" file="$2"
  local key
  key=$(printf '%s' "$url" | sed 's|[^A-Za-z0-9._-]|_|g')
  cp "$file" "$MOCK_DIR/$key"
}

mock_text() {
  local url="$1"; shift
  local key
  key=$(printf '%s' "$url" | sed 's|[^A-Za-z0-9._-]|_|g')
  printf '%s' "$*" >"$MOCK_DIR/$key"
}

# Seed every curl mock needed for a successful v0.5.0 apply (latest tag, release
# list/body, and all bundle files with valid headers).
seed_apply_mocks() {
  mock_text "mock://api/repos/FlorianRiquelme/claudefuel/releases/latest" '{"tag_name":"v0.5.0"}'
  mock_text "mock://api/repos/FlorianRiquelme/claudefuel/releases?per_page=100" \
    '[{"tag_name":"v0.5.0"},{"tag_name":"v0.4.0"}]'
  mock_text "mock://api/repos/FlorianRiquelme/claudefuel/releases/tags/v0.5.0" '{"body":"bump"}'
  printf '#!/bin/sh\n# claudefuel: v0.5.0\n' >"$TMP/_sl_new"
  mock_url "mock://raw/FlorianRiquelme/claudefuel/refs/tags/v0.5.0/statusline.sh" "$TMP/_sl_new"
  printf '#!/usr/bin/env bash\n# claudefuel: v0.5.0\n' >"$TMP/_cf_new"
  mock_url "mock://raw/FlorianRiquelme/claudefuel/refs/tags/v0.5.0/claudefuel" "$TMP/_cf_new"
  for s in update doctor rollback uninstall configure; do
    printf '# claudefuel-skill: v0.5.0\n' >"$TMP/_skill_$s"
    mock_url "mock://raw/FlorianRiquelme/claudefuel/refs/tags/v0.5.0/commands/claudefuel.${s}.md" "$TMP/_skill_$s"
  done
}

# ── basics ───────────────────────────────────────────────────────────────────

@test "--version prints v0.5.0" {
  run "$SCRIPT" --version
  [ "$status" -eq 0 ]
  [ "$output" = "v0.5.0" ]
}

@test "no-arg prints usage and exits 0" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"update"* ]]
  [[ "$output" == *"inspect"* ]]
}

# ── inspect_state fixtures ───────────────────────────────────────────────────

@test "inspect --json on vanilla (empty) target shows nothing present" {
  run "$SCRIPT" inspect --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.statusline.present == false' >/dev/null
  echo "$output" | jq -e '.claudefuel_bin.present == false' >/dev/null
  echo "$output" | jq -e '.commands.update.present == false' >/dev/null
}

@test "inspect --json on partial install reports present/missing per file" {
  printf '#!/bin/sh\n# claudefuel: v0.4.0\n' >"$TMP/statusline.sh"
  chmod +x "$TMP/statusline.sh"
  printf '# claudefuel-skill: v0.4.0\n' >"$TMP/commands/claudefuel.update.md"
  run "$SCRIPT" inspect --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.statusline.present == true' >/dev/null
  echo "$output" | jq -e '.statusline.version == "0.4.0"' >/dev/null
  echo "$output" | jq -e '.commands.update.present == true' >/dev/null
  echo "$output" | jq -e '.commands.doctor.present == false' >/dev/null
}

@test "inspect --json on broken settings.json reports invalid_json" {
  printf 'not json {' >"$TMP/settings.json"
  run "$SCRIPT" inspect --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.settings_json.present == true' >/dev/null
  echo "$output" | jq -e '.settings_json.valid_json == false' >/dev/null
}

# ── update output shapes ─────────────────────────────────────────────────────

seed_complete_install() {
  local ver="$1"
  printf '#!/bin/sh\n# claudefuel: v%s\n' "$ver" >"$TMP/statusline.sh"
  chmod +x "$TMP/statusline.sh"
  printf '#!/usr/bin/env bash\n# claudefuel: v%s\n' "$ver" >"$TMP/claudefuel"
  chmod +x "$TMP/claudefuel"
  for s in update doctor rollback uninstall configure; do
    printf '# claudefuel-skill: v%s\n' "$ver" >"$TMP/commands/claudefuel.${s}.md"
  done
  printf '{"statusLine":{"type":"command","command":"%s/statusline.sh"}}\n' "$TMP" >"$TMP/settings.json"
  mkdir -p "$TMP/cache"
}

@test "update: current — emits 'vX — current.'" {
  seed_complete_install "0.5.0"
  mock_text "mock://api/repos/FlorianRiquelme/claudefuel/releases/latest" '{"tag_name":"v0.5.0"}'
  run "$SCRIPT" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"v0.5.0 — current."* ]]
}

@test "update: current but incomplete — prompts repair" {
  seed_complete_install "0.5.0"
  rm "$TMP/commands/claudefuel.doctor.md"
  mock_text "mock://api/repos/FlorianRiquelme/claudefuel/releases/latest" '{"tag_name":"v0.5.0"}'
  run bash -c "printf 'n\n' | '$SCRIPT' update"
  [ "$status" -eq 0 ]
  [[ "$output" == *"current, but bundle is incomplete"* ]]
  [[ "$output" == *"claudefuel.doctor.md missing"* ]]
  [[ "$output" == *"Repair?"* ]]
}

@test "update: upgrade case renders release bodies and arrow" {
  seed_complete_install "0.4.0"
  mock_text "mock://api/repos/FlorianRiquelme/claudefuel/releases/latest" '{"tag_name":"v0.5.0"}'
  mock_text "mock://api/repos/FlorianRiquelme/claudefuel/releases?per_page=100" \
    '[{"tag_name":"v0.5.0"},{"tag_name":"v0.4.0"},{"tag_name":"v0.3.0"}]'
  mock_text "mock://api/repos/FlorianRiquelme/claudefuel/releases/tags/v0.5.0" \
    '{"body":"- shiny new bar\n- fewer bugs"}'
  run bash -c "printf 'n\n' | '$SCRIPT' update"
  [ "$status" -eq 0 ]
  [[ "$output" == *"v0.4.0 → v0.5.0"* ]]
  [[ "$output" == *"shiny new bar"* ]]
  [[ "$output" == *"Apply?"* ]]
}

@test "update: installed newer than latest — refuses downgrade, exits 0" {
  seed_complete_install "0.6.0"
  mock_text "mock://api/repos/FlorianRiquelme/claudefuel/releases/latest" '{"tag_name":"v0.5.0"}'
  run "$SCRIPT" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"installed is newer than the latest release"* ]]
  [[ "$output" == *"Not downgrading"* ]]
  # Informational outcome: no files replaced, no diagnostic dumped.
  [ ! -f "$TMP/cache/claudefuel-update-diagnostic.json" ]
  grep -q "v0.6.0" "$TMP/statusline.sh"
}

# ── failure diagnostic ───────────────────────────────────────────────────────

@test "update: cannot resolve latest tag — writes diagnostic, exits non-zero" {
  seed_complete_install "0.4.0"
  # No mock for releases/latest → curl returns 22.
  run "$SCRIPT" update
  [ "$status" -ne 0 ]
  [ -f "$TMP/cache/claudefuel-update-diagnostic.json" ]
  jq -e '.step == "resolve_latest_tag"' "$TMP/cache/claudefuel-update-diagnostic.json" >/dev/null
  jq -e '.desired_state.scope_note | test("bundle files")' "$TMP/cache/claudefuel-update-diagnostic.json" >/dev/null
}

# ── bak pruning ──────────────────────────────────────────────────────────────

@test "update apply prunes bak sets to 3 most recent" {
  seed_complete_install "0.4.0"
  # Pre-seed 5 bak sets with synthetic timestamps.
  for ts in 20260101000000 20260102000000 20260103000000 20260104000000 20260105000000; do
    cp "$TMP/statusline.sh" "$TMP/statusline.sh.bak-$ts"
    cp "$TMP/settings.json" "$TMP/settings.json.bak-$ts"
  done

  # Mock everything needed for a successful apply.
  seed_apply_mocks

  run bash -c "printf 'y\n' | '$SCRIPT' update"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Done."* ]]

  # Count distinct timestamps in remaining bak files; must be exactly 3.
  remaining=$(find "$TMP" -maxdepth 3 -name "*.bak-*" | sed -E 's/.*\.bak-([0-9]+)$/\1/' | sort -u | wc -l | tr -d ' ')
  [ "$remaining" = "3" ]
}

# ── U3: dependency preflight + hardening ──────────────────────────────────────

@test "missing jq dependency fails fast before any network or diagnostic work" {
  seed_complete_install "0.4.0"
  # Build a PATH that has bash/env/curl but NOT jq, so require_deps trips.
  local stub="$TMP/_nojq"
  mkdir -p "$stub"
  ln -sf "$(command -v bash)" "$stub/bash"
  ln -sf "$(command -v env)" "$stub/env"
  ln -sf "$MOCK_BIN/curl" "$stub/curl"
  run env PATH="$stub" CLAUDE_CONFIG_DIR="$TMP" "$SCRIPT" update
  [ "$status" -ne 0 ]
  [[ "$output" == *"jq"* ]]
  # Fails before dump_diagnostic (which needs jq), so no diagnostic is written.
  [ ! -f "$TMP/cache/claudefuel-update-diagnostic.json" ]
}

@test "all network curl calls carry hardening opts (timeouts + https pin)" {
  # No fetch may reach a URL without the shared CURL_OPTS in between.
  run grep -nE 'curl[[:space:]]+-fsSL' "$SCRIPT"
  [ "$status" -ne 0 ]
  # The hardened form is present for every fetch function (4 call sites).
  run grep -cF 'curl "${CURL_OPTS[@]}" -fsSL' "$SCRIPT"
  [ "$output" -ge 4 ]
}

@test "apply works with TMPDIR pointed at a different directory" {
  seed_complete_install "0.4.0"
  seed_apply_mocks
  local altmp="$TMP/_alttmp"
  mkdir -p "$altmp"
  run env TMPDIR="$altmp" bash -c "printf 'y\n' | '$SCRIPT' update"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Done."* ]]
  grep -q '# claudefuel: v0.5.0' "$TMP/statusline.sh"
  # Temp files are created beside the destination, not in TMPDIR.
  [ -z "$(find "$altmp" -name '.claudefuel.*' 2>/dev/null)" ]
}

# ── U4: diagnostic + tag correctness ──────────────────────────────────────────

@test "diagnostic records the resolved tag, not a <latest> placeholder" {
  seed_complete_install "0.4.0"
  mock_text "mock://api/repos/FlorianRiquelme/claudefuel/releases/latest" '{"tag_name":"v0.5.0"}'
  mock_text "mock://api/repos/FlorianRiquelme/claudefuel/releases?per_page=100" \
    '[{"tag_name":"v0.5.0"},{"tag_name":"v0.4.0"}]'
  mock_text "mock://api/repos/FlorianRiquelme/claudefuel/releases/tags/v0.5.0" '{"body":"bump"}'
  # No statusline.sh raw mock → fetch_and_install fails at fetch_statusline.
  run bash -c "printf 'y\n' | '$SCRIPT' update"
  [ "$status" -ne 0 ]
  local dg="$TMP/cache/claudefuel-update-diagnostic.json"
  jq -e '.step == "fetch_statusline"' "$dg" >/dev/null
  jq -e '.desired_state.statusline_version == "0.5.0"' "$dg" >/dev/null
  jq -e '.desired_state.skill_version == "0.5.0"' "$dg" >/dev/null
}

@test "diagnostic bundle_files is SKILLS-derived (all 7 members present)" {
  seed_complete_install "0.4.0"
  mock_text "mock://api/repos/FlorianRiquelme/claudefuel/releases/latest" '{"tag_name":"v0.5.0"}'
  mock_text "mock://api/repos/FlorianRiquelme/claudefuel/releases?per_page=100" \
    '[{"tag_name":"v0.5.0"},{"tag_name":"v0.4.0"}]'
  mock_text "mock://api/repos/FlorianRiquelme/claudefuel/releases/tags/v0.5.0" '{"body":"bump"}'
  # No statusline.sh raw mock → fail at fetch_statusline to capture a diagnostic.
  run bash -c "printf 'y\n' | '$SCRIPT' update"
  [ "$status" -ne 0 ]
  local dg="$TMP/cache/claudefuel-update-diagnostic.json"
  jq -e '.desired_state.bundle_files | length == 7' "$dg" >/dev/null
  jq -e '.desired_state.bundle_files | index("statusline.sh") != null' "$dg" >/dev/null
  jq -e '.desired_state.bundle_files | index("claudefuel") != null' "$dg" >/dev/null
  for s in update doctor rollback uninstall configure; do
    jq -e --arg f "commands/claudefuel.$s.md" \
      '.desired_state.bundle_files | index($f) != null' "$dg" >/dev/null
  done
}

@test "malformed interstitial tag is skipped, valid tags still rendered" {
  seed_complete_install "0.4.0"
  mock_text "mock://api/repos/FlorianRiquelme/claudefuel/releases/latest" '{"tag_name":"v0.5.0"}'
  # An in-range but path/query-unsafe tag_name sits between valid releases.
  mock_text "mock://api/repos/FlorianRiquelme/claudefuel/releases?per_page=100" \
    '[{"tag_name":"v0.5.0"},{"tag_name":"v0.4.5_inject"},{"tag_name":"v0.4.0"}]'
  mock_text "mock://api/repos/FlorianRiquelme/claudefuel/releases/tags/v0.5.0" '{"body":"shiny"}'
  run bash -c "printf 'n\n' | '$SCRIPT' update"
  [ "$status" -eq 0 ]
  [[ "$output" == *"── v0.5.0 ──"* ]]
  [[ "$output" == *"shiny"* ]]
  # The malformed tag is never printed or fetched (skipped before interpolation).
  [[ "$output" != *"0.4.5_inject"* ]]
  [[ "$output" == *"Apply?"* ]]
}

# ── U5: human-readable doctor output ──────────────────────────────────────────

@test "inspect renders a human health report, not raw JSON" {
  seed_complete_install "0.5.0"
  run "$SCRIPT" inspect
  [ "$status" -eq 0 ]
  # Human report, not a bare JSON object.
  ! echo "$output" | jq -e . >/dev/null 2>&1
  [[ "$output" == *"claudefuel health"* ]]
  [[ "$output" == *"statusline.sh"* ]]
  [[ "$output" == *"v0.5.0"* ]]
  [[ "$output" == *"claudefuel binary"* ]]
  [[ "$output" == *"settings.json"* ]]
  for s in update doctor rollback uninstall configure; do
    [[ "$output" == *"commands/claudefuel.${s}.md"* ]]
  done
  [[ "$output" == *"checks passed."* ]]
}

@test "inspect marks a missing command file as failed" {
  seed_complete_install "0.5.0"
  rm "$TMP/commands/claudefuel.doctor.md"
  run "$SCRIPT" inspect
  [ "$status" -eq 0 ]
  [[ "$output" == *"✗ commands/claudefuel.doctor.md — missing"* ]]
  # Healthy files still pass.
  [[ "$output" == *"✓ commands/claudefuel.update.md"* ]]
}

@test "inspect marks broken settings.json as failed" {
  seed_complete_install "0.5.0"
  printf 'not json {' >"$TMP/settings.json"
  run "$SCRIPT" inspect
  [ "$status" -eq 0 ]
  [[ "$output" == *"✗ settings.json — invalid or missing"* ]]
}

@test "inspect --json still emits machine-parseable JSON" {
  seed_complete_install "0.5.0"
  run "$SCRIPT" inspect --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.statusline.present == true' >/dev/null
  echo "$output" | jq -e '.claudefuel_bin.present == true' >/dev/null
}

# ── U6: apply-path + invariant coverage ───────────────────────────────────────

@test "update apply lands new content and marks the bundle executable" {
  seed_complete_install "0.4.0"
  seed_apply_mocks
  run bash -c "printf 'y\n' | '$SCRIPT' update"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Done."* ]]
  # New file content landed.
  grep -q '# claudefuel: v0.5.0' "$TMP/statusline.sh"
  grep -q '# claudefuel: v0.5.0' "$TMP/claudefuel"
  for s in update doctor rollback uninstall configure; do
    grep -q '# claudefuel-skill: v0.5.0' "$TMP/commands/claudefuel.${s}.md"
  done
  # Executables stay executable.
  [ -x "$TMP/statusline.sh" ]
  [ -x "$TMP/claudefuel" ]
  # settings.json keeps a .statusLine.command.
  jq -e '.statusLine.command' "$TMP/settings.json" >/dev/null
}

@test "update apply preserves unrelated settings.json keys" {
  seed_complete_install "0.4.0"
  # Seed settings.json with keys the patch must not touch.
  printf '{"model":"opus","permissions":{"allow":["Bash"]},"statusLine":{"type":"command","command":"%s/statusline.sh"}}\n' \
    "$TMP" >"$TMP/settings.json"
  seed_apply_mocks
  run bash -c "printf 'y\n' | '$SCRIPT' update"
  [ "$status" -eq 0 ]
  jq -e '.model == "opus"' "$TMP/settings.json" >/dev/null
  jq -e '.permissions.allow[0] == "Bash"' "$TMP/settings.json" >/dev/null
  jq -e --arg c "$TMP/statusline.sh" '.statusLine.command == $c' "$TMP/settings.json" >/dev/null
}

@test "update fails when statusline.sh lacks the version header (return-2 branch)" {
  seed_complete_install "0.4.0"
  seed_apply_mocks
  # Override the statusline raw file with one missing the verification header.
  printf '#!/bin/sh\necho no header here\n' >"$TMP/_sl_bad"
  mock_url "mock://raw/FlorianRiquelme/claudefuel/refs/tags/v0.5.0/statusline.sh" "$TMP/_sl_bad"
  run bash -c "printf 'y\n' | '$SCRIPT' update"
  [ "$status" -ne 0 ]
  local dg="$TMP/cache/claudefuel-update-diagnostic.json"
  jq -e '.step == "fetch_statusline"' "$dg" >/dev/null
  # Backups were taken before the apply attempt, so a rollback is possible.
  [ -n "$(find "$TMP" -maxdepth 1 -name 'statusline.sh.bak-*')" ]
}

@test "repair apply re-fetches a missing command file" {
  seed_complete_install "0.5.0"
  rm "$TMP/commands/claudefuel.doctor.md"
  seed_apply_mocks
  run bash -c "printf 'y\n' | '$SCRIPT' update"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Done."* ]]
  [ -f "$TMP/commands/claudefuel.doctor.md" ]
  grep -q '# claudefuel-skill: v0.5.0' "$TMP/commands/claudefuel.doctor.md"
}
