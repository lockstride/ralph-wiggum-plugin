#!/usr/bin/env bats
# Behavioral tests for stream-parser.sh signal detection.
#
# Each test feeds synthetic canonical-schema JSON events via stdin and
# captures the signals emitted on stdout.

load test_helper

setup() {
  create_mock_workspace
  # Use low thresholds so tests run quickly
  export WARN_THRESHOLD=100
  export ROTATE_THRESHOLD=200
  # 0.4.0: pin the shell-fail and file-thrash stuck-pattern thresholds to
  # their pre-0.4.0 values (2 and 5) for tests that exercise the
  # RECOVER_ATTEMPT / GUTTER dispatch. The defaults moved to 4 and 5 in
  # 0.4.0 to give agents a realistic red-state debug budget; these tests
  # are about the branching logic, not the threshold value itself, so
  # keeping them at 2 shell-fails keeps the fixtures small.
  export RALPH_SHELL_FAIL_THRESHOLD=2
  export RALPH_FILE_THRASH_THRESHOLD=5
}

teardown() {
  rm -rf "$MOCK_WORKSPACE"
}

# Helper: feed JSON lines to stream-parser and capture stdout signals
run_parser() {
  echo "$1" | bash "$SCRIPTS_DIR/stream-parser.sh" "$MOCK_WORKSPACE" 1
}

# Helper: build a tool_result JSON event
tool_result_json() {
  local name="$1"
  local bytes="${2:-100}"
  local lines="${3:-10}"
  local exit_code="${4:-0}"
  local path="${5:-/tmp/test.ts}"
  local cmd="${6:-}"
  printf '{"kind":"tool_result","name":"%s","bytes":%d,"lines":%d,"exit_code":%d,"path":"%s","cmd":"%s"}\n' \
    "$name" "$bytes" "$lines" "$exit_code" "$path" "$cmd"
}

@test "emits ROTATE when token threshold reached" {
  # Each Read adds bytes to BYTES_READ; tokens = total_bytes / 4
  # With ROTATE_THRESHOLD=200, we need 800+ bytes total
  local events=""
  for i in $(seq 1 10); do
    events+=$(tool_result_json "Read" 100 10 0 "/tmp/file${i}.ts")
    events+=$'\n'
  done

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "ROTATE"
}

@test "emits WARN before ROTATE" {
  # Use wider thresholds so WARN fires without ROTATE stealing the show.
  # WARN at 500 tokens = 2000 bytes, ROTATE at 1000 tokens = 4000 bytes.
  # 6 reads of 400 bytes = 2400 bytes → 600 tokens → triggers WARN only.
  export WARN_THRESHOLD=500
  export ROTATE_THRESHOLD=1000

  local events=""
  for i in $(seq 1 6); do
    events+=$(tool_result_json "Read" 400 10 0 "/tmp/file${i}.ts")
    events+=$'\n'
  done

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "WARN"
}

@test "WARN creates context-warning-active breadcrumb (0.12.2)" {
  # Same setup as "emits WARN before ROTATE" — trigger WARN only.
  export WARN_THRESHOLD=500
  export ROTATE_THRESHOLD=1000

  local events=""
  for i in $(seq 1 6); do
    events+=$(tool_result_json "Read" 400 10 0 "/tmp/file${i}.ts")
    events+=$'\n'
  done

  run_parser "$events" >/dev/null
  [ -f "$MOCK_WORKSPACE/.ralph/context-warning-active" ]
}

@test "parser emits HEARTBEAT on every log_activity (0.4.0)" {
  # Each tool event flowing through log_activity emits a HEARTBEAT on
  # stdout. The main loop's `read -t` timer depends on this — pre-0.4.0
  # the timer only reset on control signals (ROTATE/COMPLETE) so an
  # agent working quietly between commits would die at the 300s timer.
  local events=""
  for i in $(seq 1 5); do
    events+=$(tool_result_json "Read" 100 10 0 "/tmp/f${i}.ts")
    events+=$'\n'
  done
  local output
  output=$(run_parser "$events")
  local count
  count=$(echo "$output" | grep -c "^HEARTBEAT$" || true)
  [ "$count" -ge 5 ]
}

@test "shell-fail threshold configurable via RALPH_SHELL_FAIL_THRESHOLD (0.4.0)" {
  export RALPH_SHELL_FAIL_THRESHOLD=4
  local events=""
  for i in 1 2 3; do
    events+=$(tool_result_json "Shell" 50 5 1 "" "pnpm basic-check")
    events+=$'\n'
  done
  local output
  output=$(run_parser "$events")
  if echo "$output" | grep -q "^GUTTER$"; then
    fail "GUTTER emitted at 3x with threshold=4; expected quiet"
  fi

  events+=$(tool_result_json "Shell" 50 5 1 "" "pnpm basic-check")
  events+=$'\n'
  output=$(run_parser "$events")
  echo "$output" | grep -q "^GUTTER$"
}

@test "shell-fail at threshold emits GUTTER (0.10.0)" {
  export RALPH_SHELL_FAIL_THRESHOLD=5
  local events=""
  for _ in 1 2 3 4 5; do
    events+=$(tool_result_json "Shell" 50 5 1 "" "pnpm basic-check")
    events+=$'\n'
  done

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "^GUTTER$"
}

@test "different shell failures each accumulate separately (0.3.0)" {
  export RALPH_SHELL_FAIL_THRESHOLD=5
  local events=""
  for _ in 1 2 3 4 5; do
    events+=$(tool_result_json "Shell" 50 5 1 "" "pnpm a")
    events+=$'\n'
  done
  events+=$(tool_result_json "Shell" 50 5 1 "" "pnpm b")
  events+=$'\n'

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "^GUTTER$"
}

@test "git commit failure on .ralph/ path emits gitignored hint (0.9.0)" {
  # When the agent stages a path under .ralph/ (which is gitignored),
  # `git commit` fails with a generic exit 1 because the index is empty.
  # Without a hint, the next attempt is a blind retry. The hint should
  # name the cause specifically.
  local events=""
  events+=$(tool_result_json "Shell" 50 5 1 "" "git add .ralph/acceptance-report.md && git commit -m 'wip'")
  events+=$'\n'

  run_parser "$events" >/dev/null

  grep -qi "gitignored" "$MOCK_WORKSPACE/.ralph/errors.log"
  grep -qi ".ralph/" "$MOCK_WORKSPACE/.ralph/errors.log"
}

@test "git commit failure with git add and exit 1 emits generic staging hint (0.9.0)" {
  # When `git add ... && git commit` fails with exit 1 but the path
  # doesn't obviously look gitignored, surface a generic hint pointing
  # at `git status --short` as the diagnostic.
  local events=""
  events+=$(tool_result_json "Shell" 50 5 1 "" "git add src/foo.ts && git commit -m 'feat: thing'")
  events+=$'\n'

  run_parser "$events" >/dev/null

  grep -qi "git status --short" "$MOCK_WORKSPACE/.ralph/errors.log"
}

@test "non-git-commit shell failures do not emit gitignored hint (0.9.0)" {
  # The hint is git-commit-specific. A normal pnpm/test failure should
  # not produce it.
  local events=""
  events+=$(tool_result_json "Shell" 50 5 1 "" "pnpm test")
  events+=$'\n'

  run_parser "$events" >/dev/null

  if grep -qi "gitignored" "$MOCK_WORKSPACE/.ralph/errors.log" 2>/dev/null; then
    fail "gitignored hint emitted for non-git-commit failure"
  fi
}

@test "file thrash at threshold emits GUTTER (0.10.0)" {
  local events=""
  for i in $(seq 1 5); do
    events+=$(tool_result_json "Write" 50 5 0 "/tmp/same-file.ts")
    events+=$'\n'
  done

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "^GUTTER$"
}

# ---------------------------------------------------------------------------
# Edit token distinction (0.11.4)
#
# Edit / MultiEdit / NotebookEdit are modifications, not reads. They emit a
# distinct `EDIT` token in activity.log and contribute to BYTES_WRITTEN and
# the file-thrash counter, aligned with the hook's view that these are write
# operations.
# ---------------------------------------------------------------------------

@test "Edit family emits EDIT token across all variants (0.11.4)" {
  # Edit, MultiEdit, NotebookEdit all share the EDIT classification.
  # Single test loops over the variants so the contract is one assertion.
  local name path
  for name in Edit MultiEdit NotebookEdit; do
    path="/tmp/edit-$name.ts"
    local events
    events=$(tool_result_json "$name" 100 5 0 "$path")
    : > "$MOCK_WORKSPACE/.ralph/activity.log"
    run_parser "$events" >/dev/null
    grep -q "EDIT $path" "$MOCK_WORKSPACE/.ralph/activity.log" \
      || fail "$name did not emit EDIT token"
    grep -q "READ $path" "$MOCK_WORKSPACE/.ralph/activity.log" \
      && fail "$name was misclassified as READ"
  done
  true
}

@test "Edit thrash at threshold emits GUTTER (0.11.4)" {
  # Mirrors the Write-thrash test — Edit operations on the same file
  # should accumulate toward FILE_THRASH_THRESHOLD just like Writes.
  local events=""
  for i in $(seq 1 5); do
    events+=$(tool_result_json "Edit" 50 5 0 "/tmp/thrash-edit.ts")
    events+=$'\n'
  done

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "^GUTTER$"
}

@test "Read operation still emits READ token (regression guard, 0.11.4)" {
  local events
  events=$(tool_result_json "Read" 100 5 0 "/tmp/read-only.ts")
  run_parser "$events" >/dev/null
  grep -q "READ /tmp/read-only.ts" "$MOCK_WORKSPACE/.ralph/activity.log"
  if grep -q "EDIT /tmp/read-only.ts" "$MOCK_WORKSPACE/.ralph/activity.log"; then
    fail "Read operation was logged as EDIT — token split misclassified"
  fi
}

# ---------------------------------------------------------------------------
# Thrash counter reset on successful commit (0.11.5)
# ---------------------------------------------------------------------------

@test "successful commit resets per-file thrash counter (0.11.5)" {
  # With RALPH_FILE_THRASH_THRESHOLD=5 (test override): a 4-edit burst,
  # then a successful commit, then another 4-edit burst should NOT trip
  # GUTTER. Without the reset, the combined 8 edits would exceed the
  # threshold within the rolling window.
  local events=""
  for i in $(seq 1 4); do
    events+=$(tool_result_json "Edit" 50 5 0 "/tmp/same-file.ts")
    events+=$'\n'
  done
  # Successful git commit — triggers reset_failure_counters_on_task_boundary
  events+=$(tool_result_json "Shell" 50 2 0 "" "git commit -m 'fix tests'")
  events+=$'\n'
  for i in $(seq 1 4); do
    events+=$(tool_result_json "Edit" 50 5 0 "/tmp/same-file.ts")
    events+=$'\n'
  done

  local output
  output=$(run_parser "$events")

  # GUTTER must not fire — the commit between bursts cleared the counter.
  if echo "$output" | grep -q "^GUTTER$"; then
    fail "GUTTER fired despite commit between edit bursts — counter reset regressed"
  fi
  # RECOVER must have fired (proves the commit was detected as a boundary).
  echo "$output" | grep -q "^RECOVER$"
}

@test "thrash still trips when bursts cross threshold without intervening commit (0.11.5)" {
  # Regression guard: removing the commit from the previous test's
  # sequence — 8 edits with no commit — must still trip GUTTER once the
  # threshold (5 under test override) is crossed.
  local events=""
  for i in $(seq 1 8); do
    events+=$(tool_result_json "Edit" 50 5 0 "/tmp/no-commit-thrash.ts")
    events+=$'\n'
  done

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "^GUTTER$"
}

@test "emits COMPLETE on promise signal" {
  local events='{"kind":"assistant_text","text":"All done. <promise>ALL_TASKS_DONE</promise>"}'

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "COMPLETE"
}

@test "emits DEFER on rate limit rejection" {
  local events='{"kind":"rate_limit","status":"rejected","resets_at":0}'

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "DEFER"
}

@test "emits RECOVER on chained 'git add ... && git commit' command (0.5.4)" {
  # Spec-Kit prompt encourages: `git add <paths> && git commit -m "..."`
  # The pre-0.5.4 regex `^git[[:space:]]+commit` missed this because the
  # cmd starts with `git add`, so reset_failure_counters_on_task_boundary
  # never fired and the per-loop shell-failure counter accumulated
  # across an entire loop's worth of successful commits.
  local cmd='git add foo.ts && git commit -m "feat: add foo (T001)"'
  local event
  event=$(printf '{"kind":"tool_result","name":"Shell","bytes":50,"lines":2,"exit_code":0,"path":"","cmd":%s}\n' \
    "$(printf '%s' "$cmd" | jq -R -s .)")

  local out
  out=$(run_parser "$event")

  # Should emit RECOVER (the reset signal) — proves the regex matched.
  echo "$out" | grep -q "^RECOVER$"
  # And should log the commit, with the message captured from -m "..."
  grep -q 'COMMIT "feat: add foo (T001)"' "$MOCK_WORKSPACE/.ralph/activity.log"
}

@test "emits RECOVER on successful git commit" {
  local events=""
  events+=$(tool_result_json "Shell" 50 5 0 "" "git commit -m 'test'")

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "RECOVER"
}

@test "heartbeat sidecar emits HEARTBEAT on its interval even with no input (0.5.3)" {
  # The sidecar must emit a HEARTBEAT line on a fixed schedule independent
  # of the input stream. Without input the read loop blocks forever, but
  # downstream consumers (the main loop's `read -t RALPH_HEARTBEAT_TIMEOUT`)
  # must still see liveness. We pin the interval to 1s, hold stdin open
  # with no input for 3s, then close stdin and capture stdout. Expect at
  # least one HEARTBEAT line.
  local out
  out=$(RALPH_PARSER_HEARTBEAT_INTERVAL=1 \
    bash -c 'sleep 3 | bash "$0" "$1" 1' \
    "$SCRIPTS_DIR/stream-parser.sh" "$MOCK_WORKSPACE")
  echo "$out" | grep -q "^HEARTBEAT$"
}

@test "heartbeat sidecar exits when parser exits (no leaked process) (0.5.4)" {
  # Spawn the parser with a distinctive heartbeat interval (so any leaked
  # `sleep` is unambiguously OUR leak — `sleep 60` collides with the
  # spinner() fallback in ralph-common.sh which other parallel-running
  # tests trigger), feed one event so the parser exits cleanly, and verify
  # no `sleep <interval>` lingers afterwards. Pre-0.5.4 the trap killed
  # only the subshell pid; bash didn't propagate SIGTERM to the foreground
  # `sleep` child, so it became an orphan holding the FIFO open. Odd
  # uncommon value (47s) makes the orphan visible far past test wallclock
  # without colliding with any other shared-scripts/ sleeper.
  local interval=47
  echo '{"kind":"system","model":"test"}' |
    RALPH_PARSER_HEARTBEAT_INTERVAL=$interval \
      bash "$SCRIPTS_DIR/stream-parser.sh" "$MOCK_WORKSPACE" 1 >/dev/null

  # Give the trap a moment to reap.
  sleep 0.3

  # Any orphan `sleep 60` is OURS — the parent test runner is unlikely to
  # have started one at this exact value. Hard-fail rather than soft-compare.
  ! pgrep -f "^sleep $interval$" >/dev/null
}

# ---------------------------------------------------------------------------
# 0.10.4: git -C <path> commit/push detection
# ---------------------------------------------------------------------------

@test "detects git -C <path> commit as a task boundary (0.10.4)" {
  local events=""
  events+=$(tool_result_json "Shell" 50 5 0 "" "git -C /tmp/worktree commit -m 'feat: add widget (T001)'")

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "RECOVER"
  grep -q 'COMMIT "feat: add widget (T001)"' "$MOCK_WORKSPACE/.ralph/activity.log"
}

@test "detects git -C <path> push (0.10.4)" {
  local events=""
  events+=$(tool_result_json "Shell" 50 5 0 "" "git -C /tmp/worktree push origin main")

  local output
  output=$(run_parser "$events")
  grep -q 'PUSH' "$MOCK_WORKSPACE/.ralph/activity.log"
}

@test "detects chained git -C add && git -C commit (0.10.4)" {
  local events=""
  events+=$(tool_result_json "Shell" 50 5 0 "" "git -C /tmp/worktree add foo.ts && git -C /tmp/worktree commit -m 'fix: bar (T002)'")

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "RECOVER"
  grep -q 'COMMIT "fix: bar (T002)"' "$MOCK_WORKSPACE/.ralph/activity.log"
}

# --- 0.12.0: handoff "Last gate state" section writer ---

@test "gate-end failure rewrites Last gate state section of handoff.md (0.12.0)" {
  # Seed a handoff with the expected sections and a Working set the writer
  # must preserve.
  cat > "$MOCK_WORKSPACE/.ralph/handoff.md" <<'HOFF'
# Loop Handoff

## Last gate state

(none yet)

## Working set

Active task: T031
HOFF
  # Seed a summary file that gate-run.sh would have produced on failure.
  # 0.13.1: summary is a pointer breadcrumb (no failures: extraction).
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  cat > "$MOCK_WORKSPACE/.ralph/gates/basic-latest.summary" <<'SUM'
label: basic
exit: 1
duration: 12s
log: .ralph/gates/basic-latest.log
cmd: pnpm basic-check
SUM
  local events=""
  events+=$(tool_result_json "Shell" 50 5 1 "" "bash /plugin/shared-scripts/gate-run.sh basic pnpm basic-check")
  run_parser "$events" >/dev/null

  # Working set is preserved.
  grep -q "Active task: T031" "$MOCK_WORKSPACE/.ralph/handoff.md"
  # Summary is inlined under "## Last gate state".
  grep -q "label: basic" "$MOCK_WORKSPACE/.ralph/handoff.md"
  grep -q "log: .ralph/gates/basic-latest.log" "$MOCK_WORKSPACE/.ralph/handoff.md"
}

@test "gate-end success rewrites Last gate state with a one-liner (0.12.0)" {
  cat > "$MOCK_WORKSPACE/.ralph/handoff.md" <<'HOFF'
# Loop Handoff

## Last gate state

(stale failure context)

## Working set

Active task: T041
HOFF
  local events=""
  events+=$(tool_result_json "Shell" 50 5 0 "" "bash /plugin/shared-scripts/gate-run.sh basic pnpm basic-check")
  run_parser "$events" >/dev/null

  grep -q "Active task: T041" "$MOCK_WORKSPACE/.ralph/handoff.md"
  grep -q "exit: 0" "$MOCK_WORKSPACE/.ralph/handoff.md"
  ! grep -q "stale failure context" "$MOCK_WORKSPACE/.ralph/handoff.md"
}

@test "gate-end is a no-op when handoff.md is absent (0.12.0)" {
  rm -f "$MOCK_WORKSPACE/.ralph/handoff.md"
  local events=""
  events+=$(tool_result_json "Shell" 50 5 1 "" "bash /plugin/shared-scripts/gate-run.sh basic pnpm basic-check")
  # Must not error or create handoff.md.
  run_parser "$events" >/dev/null
  [ ! -f "$MOCK_WORKSPACE/.ralph/handoff.md" ]
}

# =============================================================================
# Gate-label extraction — canonical-only regex (0.12.4)
# =============================================================================
# Bug: the prior regex `gate-run\.sh[[:space:]]+[A-Za-z0-9_-]+` greedily
# captured `2` from `gate-run.sh 2>&1 | tail -40` and wrote `label: 2`
# into handoff.md. Fix: anchor to canonical labels only.

@test "gate-label extraction ignores '2>&1' as a label (0.12.4)" {
  cat > "$MOCK_WORKSPACE/.ralph/handoff.md" <<'HOFF'
# Loop Handoff

## Last gate state

(unchanged sentinel)

## Working set

Active task: T099
HOFF
  local events=""
  # Malformed invocation: agent typed `bash gate-run.sh 2>&1 | tail` —
  # there's no real label, just an stderr redirect. The handoff section
  # MUST be left alone.
  events+=$(tool_result_json "Shell" 50 5 0 "" "bash /plugin/shared-scripts/gate-run.sh 2>&1 | tail -40")
  run_parser "$events" >/dev/null

  # The unchanged sentinel must still be there — no false rewrite.
  grep -q "unchanged sentinel" "$MOCK_WORKSPACE/.ralph/handoff.md"
  # And we must NOT have written `label: 2`.
  ! grep -q "label: 2" "$MOCK_WORKSPACE/.ralph/handoff.md"
}

@test "gate-label extraction ignores non-canonical labels (0.12.4)" {
  cat > "$MOCK_WORKSPACE/.ralph/handoff.md" <<'HOFF'
# Loop Handoff

## Last gate state

(unchanged sentinel)
HOFF
  local events=""
  # Agent typed `gate-run.sh all` (typo — `all` is not a canonical
  # label). Should be ignored, not persisted as `label: all`.
  events+=$(tool_result_json "Shell" 50 5 1 "" "bash /plugin/shared-scripts/gate-run.sh all pnpm all-check")
  run_parser "$events" >/dev/null

  grep -q "unchanged sentinel" "$MOCK_WORKSPACE/.ralph/handoff.md"
  ! grep -q "label: all" "$MOCK_WORKSPACE/.ralph/handoff.md"
}

@test "gate-label extraction accepts each canonical label (0.14.0)" {
  # 0.14.0: canonical set is 3 tier labels + 5 kind labels. Stale labels
  # (custom, eval-*) are intentionally excluded — see the non-canonical
  # ignore test above.
  for label in basic full final unit integration e2e lint format; do
    cat > "$MOCK_WORKSPACE/.ralph/handoff.md" <<HOFF
# Loop Handoff

## Last gate state

(none yet)
HOFF
    local events=""
    events+=$(tool_result_json "Shell" 50 5 0 "" "bash /plugin/shared-scripts/gate-run.sh $label pnpm test")
    run_parser "$events" >/dev/null
    grep -q "label: $label" "$MOCK_WORKSPACE/.ralph/handoff.md" \
      || { echo "Expected 'label: $label' in handoff but didn't find it"; return 1; }
  done
}


# ---------------------------------------------------------------------------
# 0.14.3: SESSION START task banner reads LIVE counts from the resolved task
# file (RALPH_TASK_FILE env > .ralph/task-file-path breadcrumb), not the
# static .ralph/task-summary snapshot. Regression: in run-to-completion mode
# the bash loop launches the agent once, so task-summary froze at the
# loop-start snapshot (0/N) for the whole run despite incremental progress.
# ---------------------------------------------------------------------------

@test "SESSION START banner reflects live counts and updates across rotations (0.14.3)" {
  local taskfile="$MOCK_WORKSPACE/tasks.md"
  printf '%s\n' '# Tasks' '- [x] T001 done thing' '- [ ] T002 pending' '- [ ] T003 pending too' > "$taskfile"
  echo "$taskfile" > "$MOCK_WORKSPACE/.ralph/task-file-path"

  run_parser '{"kind":"system","model":"claude-opus-4-8"}'
  grep -q "📋 Tasks: 1/3 complete (2 remaining)" "$MOCK_WORKSPACE/.ralph/activity.log" \
    || { echo "first banner wrong"; cat "$MOCK_WORKSPACE/.ralph/activity.log"; return 1; }

  # Progress happens, then the agent rotates context (new system event).
  printf '%s\n' '# Tasks' '- [x] T001 done thing' '- [x] T002 pending' '- [ ] T003 pending too' > "$taskfile"
  run_parser '{"kind":"system","model":"claude-opus-4-8"}'
  grep -q "📋 Tasks: 2/3 complete (1 remaining)" "$MOCK_WORKSPACE/.ralph/activity.log" \
    || { echo "banner did not refresh across rotation"; cat "$MOCK_WORKSPACE/.ralph/activity.log"; return 1; }
}

@test "SESSION START banner lists remaining tasks as ☐ from the live file (0.14.3)" {
  local taskfile="$MOCK_WORKSPACE/tasks.md"
  printf '%s\n' '- [x] T001 done' '- [ ] T002 build the widget' > "$taskfile"
  echo "$taskfile" > "$MOCK_WORKSPACE/.ralph/task-file-path"
  run_parser '{"kind":"system","model":"claude-opus-4-8"}'
  grep -q "☐ T002 build the widget" "$MOCK_WORKSPACE/.ralph/activity.log"
}

@test "SESSION START banner prefers RALPH_TASK_FILE env over breadcrumb (0.14.3)" {
  local envfile="$MOCK_WORKSPACE/from-env.md"
  printf '%s\n' '- [ ] E1' '- [ ] E2' '- [x] E3' > "$envfile"
  # A stale breadcrumb that should be ignored when the env var is set.
  echo "$MOCK_WORKSPACE/nonexistent.md" > "$MOCK_WORKSPACE/.ralph/task-file-path"
  RALPH_TASK_FILE="$envfile" run_parser '{"kind":"system","model":"claude-opus-4-8"}'
  grep -q "📋 Tasks: 1/3 complete (2 remaining)" "$MOCK_WORKSPACE/.ralph/activity.log"
}

@test "SESSION START banner falls back to task-summary when no task file resolves (0.14.3)" {
  # No RALPH_TASK_FILE, no breadcrumb → use the static snapshot for back-compat.
  cat > "$MOCK_WORKSPACE/.ralph/task-summary" <<'EOF'
done=4
total=7
remaining=3
---
- [ ] T005 leftover
EOF
  run_parser '{"kind":"system","model":"claude-opus-4-8"}'
  grep -q "📋 Tasks: 4/7 complete (3 remaining)" "$MOCK_WORKSPACE/.ralph/activity.log"
}
