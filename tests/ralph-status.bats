#!/usr/bin/env bats
# Behavioral tests for ralph-status.sh
#
# Narrow coverage — the full output shape is validated by operators in
# practice. These tests pin the behaviors that are easy to regress:
# eval-mode decoration (0.5.1) and the "not initialized" exit branch.

load test_helper

STATUS_SCRIPT="$PLUGIN_ROOT/shared-scripts/ralph-status.sh"

setup() {
  create_mock_workspace
}

teardown() {
  rm -rf "$MOCK_WORKSPACE"
}

@test "ralph-status: no .ralph dir prints the 'not initialized' message and exits 0" {
  local clean_ws
  clean_ws=$(mktemp -d "$BATS_TMPDIR/ralph-nop-XXXXXX")

  run bash "$STATUS_SCRIPT" "$clean_ws"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "no .ralph/ directory"

  rm -rf "$clean_ws"
}

@test "ralph-status: header has no eval badge when eval-ground-truth breadcrumb is absent (0.5.1)" {
  run bash "$STATUS_SCRIPT" "$MOCK_WORKSPACE"
  [ "$status" -eq 0 ]
  # Header line should NOT contain the ACCEPTANCE EVAL suffix.
  ! echo "$output" | grep -q 'ACCEPTANCE EVAL'
  # STATUS section should NOT contain the mode row.
  ! echo "$output" | grep -q 'mode:      acceptance eval'
}

@test "ralph-status: header shows [ACCEPTANCE EVAL] when eval-ground-truth breadcrumb is present (0.5.1)" {
  echo "$MOCK_WORKSPACE/PROMPT.md" > "$MOCK_WORKSPACE/.ralph/eval-ground-truth"

  run bash "$STATUS_SCRIPT" "$MOCK_WORKSPACE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'ACCEPTANCE EVAL'
}

@test "ralph-status: STATUS section includes a mode row with the ground-truth path in eval mode (0.5.1)" {
  local gt="$MOCK_WORKSPACE/PROMPT.md"
  echo "# ground truth" > "$gt"
  echo "$gt" > "$MOCK_WORKSPACE/.ralph/eval-ground-truth"

  run bash "$STATUS_SCRIPT" "$MOCK_WORKSPACE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "mode:      acceptance eval (ground truth: $gt)"
}
