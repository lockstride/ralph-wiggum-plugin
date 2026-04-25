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

@test "ralph-status: PROGRESS section is rendered above STATUS with task counts (0.5.3)" {
  # Seed a task file pointed to by .ralph/task-file-path with a mix of
  # checked and unchecked tasks. Expect a PROGRESS banner before STATUS
  # showing N/M complete and the percentage.
  cat > "$MOCK_WORKSPACE/tasks.md" <<'TASKS'
# Tasks
- [x] T001 done one
- [x] T002 done two
- [ ] T003 still open
- [ ] T004 still open
TASKS
  echo "$MOCK_WORKSPACE/tasks.md" > "$MOCK_WORKSPACE/.ralph/task-file-path"

  run bash "$STATUS_SCRIPT" "$MOCK_WORKSPACE"
  [ "$status" -eq 0 ]

  # Banner must be present with the right count + percentage.
  echo "$output" | grep -qE '📋 TASKS: 2 / 4 complete  \(2 remaining, 50%\)'

  # Banner must appear BEFORE the STATUS section header (i.e. above it).
  local progress_line status_line
  progress_line=$(echo "$output" | grep -n '📋 TASKS' | head -1 | cut -d: -f1)
  status_line=$(echo "$output" | grep -n '^STATUS' | head -1 | cut -d: -f1)
  [ "$progress_line" -lt "$status_line" ]

  # The duplicate `tasks:     N / M complete` row inside STATUS should be
  # gone — only the PROGRESS banner carries the count now.
  ! echo "$output" | grep -qE '^  tasks: '
}

@test "ralph-status: STATUS section includes a mode row with the ground-truth path in eval mode (0.5.1)" {
  local gt="$MOCK_WORKSPACE/PROMPT.md"
  echo "# ground truth" > "$gt"
  echo "$gt" > "$MOCK_WORKSPACE/.ralph/eval-ground-truth"

  run bash "$STATUS_SCRIPT" "$MOCK_WORKSPACE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "mode:      acceptance eval (ground truth: $gt)"
}
