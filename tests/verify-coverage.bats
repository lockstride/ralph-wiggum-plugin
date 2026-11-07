#!/usr/bin/env bats
# Behavioral tests for verify-coverage.sh (verify-pass coverage check)

load test_helper

COVER="$SCRIPTS_DIR/verify-coverage.sh"

setup() {
  create_mock_workspace
  create_mock_plan
  REPORT="$MOCK_WORKSPACE/report.md"
}

teardown() {
  rm -rf "$MOCK_WORKSPACE"
}

# A report whose Results section holds the lines given as arguments.
_report() {
  {
    printf '# Acceptance Report\n\n- [ ] All acceptance criteria met and verified\n\n## Gaps\n\n## Results\n\n'
    local l
    for l in "$@"; do printf -- '- %s\n' "$l"; done
    printf '\n## History\n'
  } >"$REPORT"
}

_name_surfaces() {
  sed -i.bak 's#^- AC1: works | proof: tests/one.bats::works#- AC1: works | proof: tests/one.bats::works | surface: UI, api#' "$MOCK_PLAN"
}

_all_results() {
  _report "ABC-1/AC1 | ui | pass" "ABC-1/AC1 | api | pass" "ABC-1/AC2 | - | pass" \
    "ABC-2/AC1 | - | pass" "ABC-3/AC1 | - | pass"
}

@test "covered: a result for every criterion and each surface it names" {
  _name_surfaces
  _all_results
  run bash "$COVER" "$MOCK_PLAN" "$REPORT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a criterion whose named surface has no result is not covered" {
  _name_surfaces
  _report "ABC-1/AC1 | ui | pass" "ABC-1/AC2 | - | pass" "ABC-2/AC1 | - | pass" "ABC-3/AC1 | - | pass"
  run bash "$COVER" "$MOCK_PLAN" "$REPORT"
  [ "$status" -eq 1 ]
  [ "$output" = "ABC-1/AC1 | api" ]
}

@test "a result for the criterion on another surface does not cover the named one" {
  _name_surfaces
  _report "ABC-1/AC1 | - | pass" "ABC-1/AC1 | ui | pass" "ABC-1/AC2 | - | pass" "ABC-2/AC1 | - | pass" "ABC-3/AC1 | - | pass"
  run bash "$COVER" "$MOCK_PLAN" "$REPORT"
  [ "$status" -eq 1 ]
  [ "$output" = "ABC-1/AC1 | api" ]
}

@test "a ground truth that names no surfaces is checked per criterion" {
  _report "ABC-1/AC1 | - | pass" "ABC-1/AC2 | - | pass" "ABC-2/AC1 | - | pass"
  run bash "$COVER" "$MOCK_PLAN" "$REPORT"
  [ "$status" -eq 1 ]
  [ "$output" = "ABC-3/AC1 | -" ]
}

@test "a failing result still counts as a result" {
  _report "ABC-1/AC1 | - | fail" "ABC-1/AC2 | - | fail" "ABC-2/AC1 | - | fail" "ABC-3/AC1 | - | fail"
  run bash "$COVER" "$MOCK_PLAN" "$REPORT"
  [ "$status" -eq 0 ]
}

@test "same criterion id under two tickets are told apart" {
  _report "ABC-1/AC1 | - | pass" "ABC-1/AC2 | - | pass" "ABC-3/AC1 | - | pass"
  run bash "$COVER" "$MOCK_PLAN" "$REPORT"
  [ "$status" -eq 1 ]
  [ "$output" = "ABC-2/AC1 | -" ]
}

@test "matching ignores case and spacing" {
  _name_surfaces
  _report "abc-1/ac1|UI|pass" "ABC-1/AC1 |  API  | PASS" "abc-1/ac2 | - | pass" "ABC-2/AC1 | - | pass" "ABC-3/AC1 | - | pass"
  run bash "$COVER" "$MOCK_PLAN" "$REPORT"
  [ "$status" -eq 0 ]
}

@test "a report with no Results section covers nothing" {
  printf '# Acceptance Report\n\n## Gaps\n\n## History\n' >"$REPORT"
  run bash "$COVER" "$MOCK_PLAN" "$REPORT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ABC-1/AC1 | -"* ]]
}

@test "a checkbox line is not a result" {
  _report "[ ] ABC-1/AC1 | - | pass" "ABC-1/AC2 | - | pass" "ABC-2/AC1 | - | pass" "ABC-3/AC1 | - | pass"
  run bash "$COVER" "$MOCK_PLAN" "$REPORT"
  [ "$status" -eq 1 ]
  [ "$output" = "ABC-1/AC1 | -" ]
}

@test "Spec Kit: FR bullets in the sibling spec.md are the criteria, with their surfaces" {
  create_mock_spec feature
  printf -- '- **FR-001**: Users can export | surface: ui, api\n- **FR-002**: Admins can purge\n' >>"$MOCK_SPEC_DIR/spec.md"
  _report "FR-001 | ui | pass" "FR-002 | - | pass"
  run bash "$COVER" "$MOCK_SPEC_DIR/tasks.md" "$REPORT"
  [ "$status" -eq 1 ]
  [ "$output" = "FR-001 | api" ]
  _report "FR-001 | ui | pass" "FR-001 | api | pass" "FR-002 | - | pass"
  run bash "$COVER" "$MOCK_SPEC_DIR/tasks.md" "$REPORT"
  [ "$status" -eq 0 ]
}

@test "a ground truth with no criteria it can read is not judged" {
  printf 'Make the button blue.\n' >"$MOCK_WORKSPACE/PROMPT.md"
  _report
  run bash "$COVER" "$MOCK_WORKSPACE/PROMPT.md" "$REPORT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "missing files and missing arguments are not judged" {
  run bash "$COVER" "$MOCK_WORKSPACE/absent.md" "$REPORT"
  [ "$status" -eq 0 ]
  _all_results
  run bash "$COVER" "$MOCK_PLAN" "$MOCK_WORKSPACE/absent.md"
  [ "$status" -eq 0 ]
  run bash "$COVER"
  [ "$status" -eq 0 ]
}

@test "leaves no temporary directory behind" {
  _all_results
  local before after
  before=$(ls "${TMPDIR:-/tmp}" | grep -c '^verify-coverage\.' || true)
  bash "$COVER" "$MOCK_PLAN" "$REPORT" || true
  after=$(ls "${TMPDIR:-/tmp}" | grep -c '^verify-coverage\.' || true)
  [ "$before" -eq "$after" ]
}
