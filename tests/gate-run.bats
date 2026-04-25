#!/usr/bin/env bats
# Behavioral tests for gate-run.sh
#
# Tests verify observable behavior (exit codes, log files, activity log
# entries) — not implementation details.

load test_helper

setup() {
  create_mock_workspace
  cd "$MOCK_WORKSPACE" || fail "cannot cd to workspace"
}

teardown() {
  rm -rf "$MOCK_WORKSPACE"
}

@test "passes through exit code 0 for successful command" {
  run bash "$SCRIPTS_DIR/gate-run.sh" basic true
  [ "$status" -eq 0 ]
}

@test "passes through non-zero exit code for failing command" {
  run bash "$SCRIPTS_DIR/gate-run.sh" basic false
  [ "$status" -eq 1 ]
}

@test "creates log file and latest symlink" {
  bash "$SCRIPTS_DIR/gate-run.sh" basic echo "hello gate" || true

  # latest log should exist
  [ -e "$MOCK_WORKSPACE/.ralph/gates/basic-latest.log" ]

  # latest log should contain the command output
  grep -q "hello gate" "$MOCK_WORKSPACE/.ralph/gates/basic-latest.log"
}

@test "writes header with label and command in log file" {
  bash "$SCRIPTS_DIR/gate-run.sh" basic echo "test output" || true

  local log="$MOCK_WORKSPACE/.ralph/gates/basic-latest.log"
  grep -q "gate-run label=basic" "$log"
  grep -q "cmd:.*echo" "$log"
}

@test "rejects invalid label with exit 64" {
  run bash "$SCRIPTS_DIR/gate-run.sh" bogus true
  [ "$status" -eq 64 ]
}

@test "--help prints usage and exits 0" {
  run bash "$SCRIPTS_DIR/gate-run.sh" --help
  [ "$status" -eq 0 ]
  # Covers the label enum, env-var surface, and agent-protocol hook — these
  # are the load-bearing pieces an agent needs to discover cold.
  [[ "$output" == *"USAGE"* ]]
  [[ "$output" == *"LABELS"* ]]
  [[ "$output" == *"basic"* ]]
  [[ "$output" == *"final"* ]]
  [[ "$output" == *"RALPH_GATE_TIMEOUT"* ]]
  [[ "$output" == *"AGENT PROTOCOL"* ]]
}

@test "-h prints usage and exits 0 (short form)" {
  run bash "$SCRIPTS_DIR/gate-run.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"USAGE"* ]]
}

@test "missing args hint points at --help" {
  run bash "$SCRIPTS_DIR/gate-run.sh" basic
  [ "$status" -eq 64 ]
  [[ "$output" == *"--help"* ]]
}

@test "invalid label hint points at --help" {
  run bash "$SCRIPTS_DIR/gate-run.sh" bogus true
  [ "$status" -eq 64 ]
  [[ "$output" == *"--help"* ]]
}

@test "times out on hung command and returns exit 124" {
  RALPH_GATE_TIMEOUT=2 run bash "$SCRIPTS_DIR/gate-run.sh" basic sleep 30
  [ "$status" -eq 124 ]
}

@test "writes timeout message to log on timeout" {
  RALPH_GATE_TIMEOUT=2 bash "$SCRIPTS_DIR/gate-run.sh" basic sleep 30 || true

  local log="$MOCK_WORKSPACE/.ralph/gates/basic-latest.log"
  grep -q "timed out" "$log"
}

@test "logs gate start and end to activity log" {
  touch "$MOCK_WORKSPACE/.ralph/activity.log"
  bash "$SCRIPTS_DIR/gate-run.sh" basic echo "test" || true

  grep -q "GATE start" "$MOCK_WORKSPACE/.ralph/activity.log"
  grep -q "GATE end" "$MOCK_WORKSPACE/.ralph/activity.log"
}

# ---------------------------------------------------------------------------
# Per-label gate timeout (0.3.5)
# ---------------------------------------------------------------------------

@test "basic gate uses RALPH_BASIC_GATE_TIMEOUT default (0.3.5)" {
  # Default basic timeout is 600 s (0.3.9) — override to 2 s to trip it
  RALPH_BASIC_GATE_TIMEOUT=2 run bash "$SCRIPTS_DIR/gate-run.sh" basic sleep 30
  [ "$status" -eq 124 ]
}

@test "final gate uses RALPH_FINAL_GATE_TIMEOUT default (0.3.5)" {
  # Default final timeout is 900 s (0.3.9) — override to 2 s so it hits timeout
  RALPH_FINAL_GATE_TIMEOUT=2 run bash "$SCRIPTS_DIR/gate-run.sh" final sleep 30
  [ "$status" -eq 124 ]
}

@test "RALPH_GATE_TIMEOUT overrides per-label defaults (0.3.5)" {
  # Even though final default is 900, the blanket override takes precedence
  RALPH_GATE_TIMEOUT=2 run bash "$SCRIPTS_DIR/gate-run.sh" final sleep 30
  [ "$status" -eq 124 ]
}

@test "basic default timeout is 600s and final is 900s (0.3.9)" {
  # Regression test for the 0.3.9 default re-target (basic 360→600,
  # final 600→900 — sized for agent-mode red-state iterations where
  # failing tests slow the gate ~2× over green-path clean runs).
  # Verifies the help text, env-var docs, and live resolution all
  # agree, so a future edit to just one site can't silently diverge.
  grep -q 'Default timeout 600 s' "$SCRIPTS_DIR/gate-run.sh"
  grep -q 'Default timeout 900 s' "$SCRIPTS_DIR/gate-run.sh"
  grep -q 'RALPH_FINAL_GATE_TIMEOUT.*default 900' "$SCRIPTS_DIR/gate-run.sh"
  grep -q 'RALPH_BASIC_GATE_TIMEOUT.*default 600' "$SCRIPTS_DIR/gate-run.sh"
  grep -qE 'RALPH_FINAL_GATE_TIMEOUT:-900' "$SCRIPTS_DIR/gate-run.sh"
  grep -qE 'RALPH_BASIC_GATE_TIMEOUT:-600' "$SCRIPTS_DIR/gate-run.sh"
}

@test "custom label falls through to basic default (0.3.5)" {
  # Labels other than 'final' get the basic default
  RALPH_BASIC_GATE_TIMEOUT=2 run bash "$SCRIPTS_DIR/gate-run.sh" e2e sleep 30
  [ "$status" -eq 124 ]
}

@test "writes exit breadcrumb for final gate (0.3.3+)" {
  bash "$SCRIPTS_DIR/gate-run.sh" final echo "done" || true
  [ -f "$MOCK_WORKSPACE/.ralph/gates/final-latest.exit" ]
  [ "$(cat "$MOCK_WORKSPACE/.ralph/gates/final-latest.exit")" = "0" ]
}

@test "concurrent runs of the same label serialize via the lock (0.5.4)" {
  # Holder grabs the lock by hand, then we kick off a second invocation
  # with a tiny lock-wait timeout. The second one must give up with exit
  # 64 and a recognizable message rather than racing the holder.
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  mkdir "$MOCK_WORKSPACE/.ralph/gates/.basic.lock"

  RALPH_GATE_LOCK_WAIT=2 run bash "$SCRIPTS_DIR/gate-run.sh" basic echo "should not run"
  [ "$status" -eq 64 ]
  [[ "$output" == *"holding the basic lock"* ]]

  # Cleanup
  rmdir "$MOCK_WORKSPACE/.ralph/gates/.basic.lock"
}

@test "stale lock older than RALPH_GATE_STALE_LOCK_SEC is stolen (0.5.4)" {
  # Forge a stale lock dir with mtime in the distant past, then run with
  # a tiny stale threshold so it gets stolen and the gate proceeds.
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  mkdir "$MOCK_WORKSPACE/.ralph/gates/.basic.lock"
  # Backdate mtime to 1 hour ago — touch -t works on both macOS and GNU
  touch -t "$(date -v-1H '+%Y%m%d%H%M' 2>/dev/null || date -d '1 hour ago' '+%Y%m%d%H%M')" \
    "$MOCK_WORKSPACE/.ralph/gates/.basic.lock"

  RALPH_GATE_LOCK_WAIT=5 RALPH_GATE_STALE_LOCK_SEC=60 \
    run bash "$SCRIPTS_DIR/gate-run.sh" basic echo "ran after steal"
  [ "$status" -eq 0 ]
  grep -q "ran after steal" "$MOCK_WORKSPACE/.ralph/gates/basic-latest.log"
}

@test "retains only RALPH_GATE_KEEP logs" {
  export RALPH_GATE_KEEP=2

  # Run 4 gates
  for i in 1 2 3 4; do
    bash "$SCRIPTS_DIR/gate-run.sh" basic echo "run $i" || true
    sleep 1  # ensure distinct timestamps
  done

  # Count timestamped log files (exclude -latest.log)
  local count
  count=$(find "$MOCK_WORKSPACE/.ralph/gates" -name "basic-*.log" \
    ! -name "basic-latest.log" -type f | wc -l | tr -d ' ')
  [ "$count" -eq 2 ]
}
