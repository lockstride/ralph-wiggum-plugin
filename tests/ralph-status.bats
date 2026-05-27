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

@test "ralph-status: shows PREVIOUS/CURRENT/NEXT sections with task ID + body (0.5.7)" {
  # Mid-stream task file: 2 done, 2 to go. Expect all three sections.
  cat > "$MOCK_WORKSPACE/tasks.md" <<'TASKS'
# Tasks
- [x] T001 done one
- [x] T002 done two
- [ ] T003 currently in progress
- [ ] T004 queued next
TASKS
  echo "$MOCK_WORKSPACE/tasks.md" > "$MOCK_WORKSPACE/.ralph/task-file-path"

  run bash "$STATUS_SCRIPT" "$MOCK_WORKSPACE"
  [ "$status" -eq 0 ]

  echo "$output" | grep -qE '^PREVIOUS \(T002\)$'
  echo "$output" | grep -qE '^T002 done two'
  echo "$output" | grep -qE '^CURRENT \(T003\)$'
  echo "$output" | grep -qE '^T003 currently in progress'
  echo "$output" | grep -qE '^NEXT \(T004\)$'
  echo "$output" | grep -qE '^T004 queued next'
}

@test "ralph-status: omits PREVIOUS section before the first commit (0.5.7)" {
  # Brand-new task file, no [x] yet — there is no previous task.
  cat > "$MOCK_WORKSPACE/tasks.md" <<'TASKS'
# Tasks
- [ ] T001 first task
- [ ] T002 second task
TASKS
  echo "$MOCK_WORKSPACE/tasks.md" > "$MOCK_WORKSPACE/.ralph/task-file-path"

  run bash "$STATUS_SCRIPT" "$MOCK_WORKSPACE"
  [ "$status" -eq 0 ]

  ! echo "$output" | grep -qE '^PREVIOUS'
  echo "$output" | grep -qE '^CURRENT \(T001\)$'
  echo "$output" | grep -qE '^NEXT \(T002\)$'
}

@test "ralph-status: omits NEXT section when current is the last task (0.5.7)" {
  # Last-task case: only one [ ] remains.
  cat > "$MOCK_WORKSPACE/tasks.md" <<'TASKS'
# Tasks
- [x] T001 done
- [x] T002 done
- [ ] T003 last one
TASKS
  echo "$MOCK_WORKSPACE/tasks.md" > "$MOCK_WORKSPACE/.ralph/task-file-path"

  run bash "$STATUS_SCRIPT" "$MOCK_WORKSPACE"
  [ "$status" -eq 0 ]

  echo "$output" | grep -qE '^PREVIOUS \(T002\)$'
  echo "$output" | grep -qE '^CURRENT \(T003\)$'
  ! echo "$output" | grep -qE '^NEXT'
}

@test "ralph-status: STATUS section includes a mode row with the ground-truth path in eval mode (0.5.1)" {
  local gt="$MOCK_WORKSPACE/PROMPT.md"
  echo "# ground truth" > "$gt"
  echo "$gt" > "$MOCK_WORKSPACE/.ralph/eval-ground-truth"

  run bash "$STATUS_SCRIPT" "$MOCK_WORKSPACE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "mode:      acceptance eval (ground truth: $gt)"
}

# --- Eval-mode ACCEPTANCE section (0.13.4) ---
#
# In eval mode the report's top-level checkbox is a verdict, not a task,
# so PROGRESS / PREVIOUS / CURRENT / NEXT all need eval-aware handling.

@test "ralph-status: eval mode with CLEAN report shows verified verdict (0.13.4)" {
  echo "$MOCK_WORKSPACE/spec.md" > "$MOCK_WORKSPACE/.ralph/eval-ground-truth"
  cat > "$MOCK_WORKSPACE/.ralph/acceptance-report.md" <<'REPORT'
# Acceptance Report

- [x] All acceptance criteria met and verified

**Status:** CLEAN
**Ground truth:** /tmp/spec.md
**Last loop:** 3
**Last mode:** VERIFIER

## Gaps

(none — all criteria verified)

## History

loop 1 - VERIFIER - 5 gaps found
loop 2 - REWORK - resolved 5 gaps
loop 3 - VERIFIER - re-verified, zero gaps, set CLEAN
REPORT

  run bash "$STATUS_SCRIPT" "$MOCK_WORKSPACE"
  [ "$status" -eq 0 ]

  echo "$output" | grep -q '📋 ACCEPTANCE: ✅ verified'
  echo "$output" | grep -qE '^ACCEPTANCE$'
  echo "$output" | grep -q 'status:    CLEAN'
  echo "$output" | grep -q 'last mode: VERIFIER  (loop 3)'
  # No misleading "1 / 1 complete, 0%" from the generic task counter.
  ! echo "$output" | grep -q '📋 TASKS'
  # No PREVIOUS/CURRENT/NEXT — they'd read the top-level checkbox.
  ! echo "$output" | grep -qE '^PREVIOUS'
  ! echo "$output" | grep -qE '^CURRENT'
}

@test "ralph-status: eval mode with open gaps shows pending verdict + counts (0.13.4)" {
  echo "$MOCK_WORKSPACE/spec.md" > "$MOCK_WORKSPACE/.ralph/eval-ground-truth"
  cat > "$MOCK_WORKSPACE/.ralph/acceptance-report.md" <<'REPORT'
# Acceptance Report

- [ ] All acceptance criteria met and verified

**Status:** UNVERIFIED
**Ground truth:** /tmp/spec.md
**Last loop:** 2
**Last mode:** REWORK

## Gaps

- [ ] T037 missing E2E test for inline panel lifecycle
- [ ] T041 only 19 off-topic prompts, requirement >= 20
- [ ] T044 final gate red (blocked: needs verifier re-check)
- [x] T038 quota notice header slot added

## History

loop 1 - VERIFIER - 4 gaps found
loop 2 - REWORK - closed 1 gap, 1 blocked
REPORT

  run bash "$STATUS_SCRIPT" "$MOCK_WORKSPACE"
  [ "$status" -eq 0 ]

  echo "$output" | grep -q '📋 ACCEPTANCE: ⏳ pending'
  # Open count excludes the blocked gap.
  echo "$output" | grep -q 'gaps:      2 open, 1 blocked, 1 resolved'
  echo "$output" | grep -q 'last mode: REWORK  (loop 2)'
  echo "$output" | grep -q 'history:   2 entries — last: loop 2 - REWORK'
}

@test "ralph-status: eval mode with un-seeded report falls back gracefully (0.13.4)" {
  # eval-ground-truth breadcrumb present but no report yet — the
  # acceptance section should still render with a graceful "not seeded"
  # placeholder rather than blanking out or crashing.
  echo "$MOCK_WORKSPACE/spec.md" > "$MOCK_WORKSPACE/.ralph/eval-ground-truth"
  # No acceptance-report.md.

  run bash "$STATUS_SCRIPT" "$MOCK_WORKSPACE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '📋 ACCEPTANCE: (report not seeded yet)'
  echo "$output" | grep -qE '^ACCEPTANCE$'
}
