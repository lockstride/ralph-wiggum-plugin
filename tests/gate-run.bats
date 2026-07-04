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

@test "accepts every label in the 0.14.0 canonical set" {
  # Tier labels (basic|full|final) and kind labels (unit|integration|
  # e2e|lint|format) are all accepted; each writes a per-label breadcrumb.
  for label in basic full final unit integration e2e lint format; do
    run bash "$SCRIPTS_DIR/gate-run.sh" "$label" true
    [ "$status" -eq 0 ] || { echo "label '$label' rejected: $output"; return 1; }
    [[ -f "$MOCK_WORKSPACE/.ralph/gates/${label}-latest.exit" ]] || {
      echo "expected breadcrumb at gates/${label}-latest.exit"; return 1;
    }
  done
}

@test "rejects pre-0.14 labels removed from the canonical set" {
  # 0.14.0 dropped 'custom' (use a kind label) and the eval-* family
  # (eval loop now uses 'final' directly).
  for label in custom eval-final eval-rework eval-something-custom; do
    run bash "$SCRIPTS_DIR/gate-run.sh" "$label" true
    [ "$status" -eq 64 ] || { echo "stale label '$label' should be rejected: $output"; return 1; }
  done
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

@test "usage errors hint at --help" {
  # Both missing-args (exit 64) and invalid-label paths should point
  # the agent at --help. -h short form is functionally equivalent to
  # --help and covered by the previous test.
  run bash "$SCRIPTS_DIR/gate-run.sh" basic
  [ "$status" -eq 64 ]
  [[ "$output" == *"--help"* ]]
  run bash "$SCRIPTS_DIR/gate-run.sh" bogus true
  [ "$status" -eq 64 ]
  [[ "$output" == *"--help"* ]]
}

@test "times out on hung command and returns exit 124" {
  RALPH_GATE_TIMEOUT=1 run bash "$SCRIPTS_DIR/gate-run.sh" basic sleep 5
  [ "$status" -eq 124 ]
}

@test "writes timeout message to log on timeout" {
  RALPH_GATE_TIMEOUT=1 bash "$SCRIPTS_DIR/gate-run.sh" basic sleep 5 || true

  local log="$MOCK_WORKSPACE/.ralph/gates/basic-latest.log"
  grep -q "timed out" "$log"
}

@test "logs gate start and end to activity log" {
  touch "$MOCK_WORKSPACE/.ralph/activity.log"
  bash "$SCRIPTS_DIR/gate-run.sh" basic echo "test" || true

  grep -q "GATE start" "$MOCK_WORKSPACE/.ralph/activity.log"
  grep -q "GATE end" "$MOCK_WORKSPACE/.ralph/activity.log"
}

@test "runs the gate command from the workspace root even when invoked from a subdir" {
  # Regression (0.15.1): the ralph-guard.sh [rewrite] chain-splitter can
  # strip a load-bearing `cd <worktree>` prefix, leaving gate-run.sh invoked
  # from the agent's stray cwd (e.g. apps/api). The gate must still execute at
  # the workspace root so root-scoped commands (pnpm <script>) resolve the
  # right package.json — otherwise pnpm fast-fails with exit=254.
  mkdir -p "$MOCK_WORKSPACE/subdir/deep"
  cd "$MOCK_WORKSPACE/subdir/deep" || fail "cannot cd to subdir"

  # RALPH_WORKSPACE points at the root (exported by create_mock_workspace)
  # while cwd is the subdir. A root-relative side effect must land at the
  # root, not the invocation cwd. Symlink-agnostic (relative path resolved
  # against the command's cwd; both absolute locations are then checked).
  run bash "$SCRIPTS_DIR/gate-run.sh" basic touch gate-ran-here.marker
  [ "$status" -eq 0 ]

  [ -f "$MOCK_WORKSPACE/gate-ran-here.marker" ]
  [ ! -f "$MOCK_WORKSPACE/subdir/deep/gate-ran-here.marker" ]
}

# ---------------------------------------------------------------------------
# Per-tier gate timeout
# ---------------------------------------------------------------------------
# Behavioral assertion: per-tier env vars override the default, and the
# blanket RALPH_GATE_TIMEOUT overrides per-tier. Kind labels share the
# basic-tier timeout budget.

@test "RALPH_BASIC_GATE_TIMEOUT applies to basic + every kind label" {
  RALPH_BASIC_GATE_TIMEOUT=1 run bash "$SCRIPTS_DIR/gate-run.sh" basic sleep 5
  [ "$status" -eq 124 ]
  for label in unit integration e2e lint format; do
    RALPH_BASIC_GATE_TIMEOUT=1 run bash "$SCRIPTS_DIR/gate-run.sh" "$label" sleep 5
    [ "$status" -eq 124 ] || { echo "kind label '$label' did not inherit basic timeout"; return 1; }
  done
}

@test "RALPH_FULL_GATE_TIMEOUT applies to full label (0.14.0)" {
  RALPH_FULL_GATE_TIMEOUT=1 run bash "$SCRIPTS_DIR/gate-run.sh" full sleep 5
  [ "$status" -eq 124 ]
}

@test "RALPH_FINAL_GATE_TIMEOUT applies to final label" {
  RALPH_FINAL_GATE_TIMEOUT=1 run bash "$SCRIPTS_DIR/gate-run.sh" final sleep 5
  [ "$status" -eq 124 ]
}

@test "RALPH_GATE_TIMEOUT (blanket) overrides per-label defaults" {
  RALPH_GATE_TIMEOUT=1 run bash "$SCRIPTS_DIR/gate-run.sh" final sleep 5
  [ "$status" -eq 124 ]
}

@test "writes exit breadcrumb for final gate (0.3.3+)" {
  bash "$SCRIPTS_DIR/gate-run.sh" final echo "done" || true
  [ -f "$MOCK_WORKSPACE/.ralph/gates/final-latest.exit" ]
  [ "$(cat "$MOCK_WORKSPACE/.ralph/gates/final-latest.exit")" = "0" ]
}

@test "writes cmd breadcrumb alongside the exit breadcrumb (0.6.4)" {
  # The .cmd file lets the loop's COMPLETE guard verify the right command
  # was actually run, not just that *some* command labeled `final` was.
  bash "$SCRIPTS_DIR/gate-run.sh" final echo hello world || true
  [ -f "$MOCK_WORKSPACE/.ralph/gates/final-latest.cmd" ]
  # Stored space-joined raw, no newline — easy plain-string compare against
  # the user-facing .ralph/final-check-command file content.
  [ "$(cat "$MOCK_WORKSPACE/.ralph/gates/final-latest.cmd")" = "echo hello world" ]
}

@test "cmd breadcrumb is per-label (0.6.4)" {
  bash "$SCRIPTS_DIR/gate-run.sh" basic echo basic-cmd || true
  bash "$SCRIPTS_DIR/gate-run.sh" final echo final-cmd || true
  [ "$(cat "$MOCK_WORKSPACE/.ralph/gates/basic-latest.cmd")" = "echo basic-cmd" ]
  [ "$(cat "$MOCK_WORKSPACE/.ralph/gates/final-latest.cmd")" = "echo final-cmd" ]
}

@test "concurrent runs of the same label serialize via the lock (0.5.4)" {
  # Holder grabs the lock by hand, then we kick off a second invocation
  # with a tiny lock-wait timeout. The second one must give up rather than
  # racing the holder. 0.13.5: exit 75 (EX_TEMPFAIL, "gate busy") instead of
  # 64, with a message that surfaces the in-progress gate and forbids
  # tampering instead of inviting "remove manually".
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  mkdir "$MOCK_WORKSPACE/.ralph/gates/.basic.lock"

  RALPH_GATE_LOCK_WAIT=2 run bash "$SCRIPTS_DIR/gate-run.sh" basic echo "should not run"
  [ "$status" -eq 75 ]
  [[ "$output" == *"'basic' gate is already running"* ]]
  # The old "remove manually" invitation must be gone; tampering is forbidden.
  [[ "$output" == *"Do NOT delete the lock"* ]]
  [[ "$output" != *"remove manually"* ]]

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

# -----------------------------------------------------------------------------
# 0.12.5: PID-aware stale-lock steal
# -----------------------------------------------------------------------------
# Time-based stale detection waits 45 minutes by default. When tmux
# kill-session leaves a lock behind, the next gate's 60s lock-wait
# expires before time-based steal kicks in — a real friction point
# observed in production. PID-aware steal closes this gap by checking
# whether the holder PID is alive (kill -0).

@test "lock with dead holder PID is stolen immediately (0.12.5)" {
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  mkdir "$MOCK_WORKSPACE/.ralph/gates/.basic.lock"
  # Pick a PID that's almost certainly not running — bash can pick
  # something high-numbered. Use $$ * 1000 + a marker to be safe.
  echo "999999" >"$MOCK_WORKSPACE/.ralph/gates/.basic.lock/pid"

  # Lock-wait is 60s by default — if PID-aware steal works we should
  # complete in < 5s. Set a tight cap to prove that.
  RALPH_GATE_LOCK_WAIT=5 RALPH_GATE_STALE_LOCK_SEC=99999 \
    run bash "$SCRIPTS_DIR/gate-run.sh" basic echo "ran after pid steal"
  [ "$status" -eq 0 ]
  grep -q "ran after pid steal" "$MOCK_WORKSPACE/.ralph/gates/basic-latest.log"
  # Activity log should record the steal.
  grep -q "GATE LOCK STOLEN.*pid=999999" "$MOCK_WORKSPACE/.ralph/activity.log"
}

@test "lock with live holder PID is NOT stolen (0.12.5)" {
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  mkdir "$MOCK_WORKSPACE/.ralph/gates/.basic.lock"
  # Use bash's own PID — guaranteed alive for the test's duration.
  echo "$$" >"$MOCK_WORKSPACE/.ralph/gates/.basic.lock/pid"

  RALPH_GATE_LOCK_WAIT=2 RALPH_GATE_STALE_LOCK_SEC=99999 \
    run bash "$SCRIPTS_DIR/gate-run.sh" basic echo "should be blocked"
  [ "$status" -eq 75 ]  # 0.13.5: busy (lock not stolen), EX_TEMPFAIL
  # A live holder is reported as alive/still-running and names its PID.
  [[ "$output" == *"pid=$$"* ]]
  [[ "$output" == *"alive"* ]]
  ! grep -q "should be blocked" "$MOCK_WORKSPACE/.ralph/gates/basic-latest.log" 2>/dev/null

  rm -rf "$MOCK_WORKSPACE/.ralph/gates/.basic.lock"
}

# -----------------------------------------------------------------------------
# 0.14.2: PID-recycling detection via lock epoch
# -----------------------------------------------------------------------------

@test "lock with live but recycled PID is stolen via epoch check (0.14.2)" {
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  mkdir "$MOCK_WORKSPACE/.ralph/gates/.basic.lock"
  # Use our own PID (guaranteed alive) but set the lock epoch to well
  # BEFORE our process started — simulating a recycled PID.
  echo "$$" >"$MOCK_WORKSPACE/.ralph/gates/.basic.lock/pid"
  echo "1000000000" >"$MOCK_WORKSPACE/.ralph/gates/.basic.lock/epoch"

  RALPH_GATE_LOCK_WAIT=5 RALPH_GATE_STALE_LOCK_SEC=99999 \
    run bash "$SCRIPTS_DIR/gate-run.sh" basic echo "ran after recycle steal"
  [ "$status" -eq 0 ]
  grep -q "ran after recycle steal" "$MOCK_WORKSPACE/.ralph/gates/basic-latest.log"
  grep -q "PID was recycled" "$MOCK_WORKSPACE/.ralph/activity.log"
}

@test "lock with live genuine PID and valid epoch is NOT stolen (0.14.2)" {
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  mkdir "$MOCK_WORKSPACE/.ralph/gates/.basic.lock"
  # Use our own PID with epoch set to NOW — the process started before
  # or at the lock epoch, so it's the genuine holder.
  echo "$$" >"$MOCK_WORKSPACE/.ralph/gates/.basic.lock/pid"
  echo "$(date +%s)" >"$MOCK_WORKSPACE/.ralph/gates/.basic.lock/epoch"

  RALPH_GATE_LOCK_WAIT=2 RALPH_GATE_STALE_LOCK_SEC=99999 \
    run bash "$SCRIPTS_DIR/gate-run.sh" basic echo "should be blocked"
  [ "$status" -eq 75 ]
  ! grep -q "PID was recycled" "$MOCK_WORKSPACE/.ralph/activity.log" 2>/dev/null

  rm -rf "$MOCK_WORKSPACE/.ralph/gates/.basic.lock"
}

@test "lock without pid file falls back to time-based steal (0.12.5)" {
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  mkdir "$MOCK_WORKSPACE/.ralph/gates/.basic.lock"
  # No pid file — simulates a pre-0.12.5 leftover lock.
  touch -t "$(date -v-1H '+%Y%m%d%H%M' 2>/dev/null || date -d '1 hour ago' '+%Y%m%d%H%M')" \
    "$MOCK_WORKSPACE/.ralph/gates/.basic.lock"

  RALPH_GATE_LOCK_WAIT=3 RALPH_GATE_STALE_LOCK_SEC=60 \
    run bash "$SCRIPTS_DIR/gate-run.sh" basic echo "ran after time-based steal"
  [ "$status" -eq 0 ]
  grep -q "ran after time-based steal" "$MOCK_WORKSPACE/.ralph/gates/basic-latest.log"
}

@test "successful gate run writes pid file inside lock dir (0.12.5)" {
  # Use a slow command to keep the lock dir alive long enough for inspection.
  # Actually, simpler: run a quick command and verify the trap cleans up.
  RALPH_GATE_LOCK_WAIT=5 run bash "$SCRIPTS_DIR/gate-run.sh" basic echo "ok"
  [ "$status" -eq 0 ]
  # Post-run, lock dir should be removed by the trap.
  [ ! -d "$MOCK_WORKSPACE/.ralph/gates/.basic.lock" ]
}

# -----------------------------------------------------------------------------
# 0.6.3: Subtree-kill on timeout
#
# Pre-0.6.3 the gate command was wrapped in `timeout(1)`, which sends SIGTERM
# only to its immediate child. Cypress / nuxt-dev / docker-compose
# grandchildren survived, got reparented to PID 1, and squat on ports +
# locks for the next loop. A real session showed a 16-min dead zone
# where the next final gate couldn't acquire its lock or hit the 15-min
# hard timeout because of orphaned containers.
#
# 0.6.3 puts the gate in its own process group via `set -m`, runs a watchdog
# that signals the entire pgroup on timeout (SIGTERM, then SIGKILL after
# RALPH_GATE_KILL_GRACE), and a final belt-and-braces SIGKILL of the pgroup
# at the end. These tests verify the subtree-kill semantics.
# -----------------------------------------------------------------------------

@test "timeout kills orphaned grandchild processes (0.6.3)" {
  # Spawn a script that backgrounds a long-sleeping grandchild and writes
  # its PID to disk, then sleeps in the foreground past the gate timeout.
  # Pre-0.6.3 timeout(1) only signaled the foreground process, so the
  # backgrounded sleep would survive as an orphan reparented to PID 1.
  local pidfile="$MOCK_WORKSPACE/orphan.pid"
  local script="$MOCK_WORKSPACE/spawn-orphan.sh"
  cat > "$script" <<EOF
#!/bin/bash
sleep 30 &
echo \$! > "$pidfile"
sleep 30
EOF
  chmod +x "$script"

  RALPH_GATE_TIMEOUT=2 RALPH_GATE_KILL_GRACE=2 \
    run bash "$SCRIPTS_DIR/gate-run.sh" basic "$script"
  [ "$status" -eq 124 ]

  # Pidfile must exist (script ran and backgrounded the orphan).
  [ -f "$pidfile" ]
  local orphan_pid
  orphan_pid=$(cat "$pidfile")
  [ -n "$orphan_pid" ]

  # The watchdog signals the entire pgroup on timeout. The grandchild MUST
  # be dead. (We allow a brief settling window for the kernel to reap, but
  # the SIGKILL escalation should land within RALPH_GATE_KILL_GRACE+1s.)
  local i
  for i in 1 2 3 4 5; do
    kill -0 "$orphan_pid" 2>/dev/null || break
    sleep 1
  done

  if kill -0 "$orphan_pid" 2>/dev/null; then
    # Cleanup so this test doesn't leak if it fails — we still want to fail.
    kill -9 "$orphan_pid" 2>/dev/null
    fail "Orphan grandchild PID $orphan_pid survived gate timeout (subtree-kill regression)"
  fi
}

@test "watchdog escalates from SIGTERM to SIGKILL after grace period (0.6.3)" {
  # Spawn a script that ignores SIGTERM but eventually dies to SIGKILL.
  # Verifies the two-tier kill: SIGTERM first (so well-behaved children get
  # to clean up), then SIGKILL after RALPH_GATE_KILL_GRACE.
  local script="$MOCK_WORKSPACE/sigterm-resistant.sh"
  cat > "$script" <<'EOF'
#!/bin/bash
trap '' TERM
sleep 30
EOF
  chmod +x "$script"

  local start end elapsed
  start=$(date +%s)
  RALPH_GATE_TIMEOUT=1 RALPH_GATE_KILL_GRACE=2 \
    run bash "$SCRIPTS_DIR/gate-run.sh" basic "$script"
  end=$(date +%s)
  elapsed=$((end - start))

  [ "$status" -eq 124 ]
  # Should die within ~timeout + grace + small overhead. Ceiling 8s gives
  # plenty of headroom for the bats fixture overhead without being so
  # generous that a regression to "wait for full sleep 30" passes.
  [ "$elapsed" -lt 8 ]
}

@test "natural gate completion does not invoke subtree-kill (0.6.3)" {
  # The watchdog should exit cleanly when the gate finishes normally —
  # NOT escalate to SIGKILL on a successful run. Verifies that the
  # belt-and-braces final pgroup-kill doesn't break clean exits.
  run bash "$SCRIPTS_DIR/gate-run.sh" basic bash -c "echo hello; exit 0"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello"* ]]
}

@test "RALPH_GATE_KILL_GRACE default is 10s (0.6.3)" {
  # Documented default; regression test so a future edit to the default
  # doesn't silently change observable wait time on timeout.
  grep -q 'RALPH_GATE_KILL_GRACE.*:-10' "$SCRIPTS_DIR/gate-run.sh"
}


@test "word-splits single quoted command arg" {
  run bash "$SCRIPTS_DIR/gate-run.sh" basic "echo hello-split"
  [ "$status" -eq 0 ]
  grep -q "hello-split" "$MOCK_WORKSPACE/.ralph/gates/basic-latest.log"
}

# --- 0.12.0: failure summary file ---

@test "writes <label>-latest.summary on failure (0.13.1 — pointer-only)" {
  # 0.13.1: the summary file is now a pointer breadcrumb (label/exit/duration/
  # log/cmd), not a parsed failure transcript. Agents read the log file
  # directly when they need failure detail — project test runners vary too
  # much for one regex to reliably extract failures.
  bash "$SCRIPTS_DIR/gate-run.sh" basic bash -c 'echo "FAIL  src/foo.spec.ts > test name"; echo "AssertionError: expected 1 to be 2"; exit 1' || true

  local summary="$MOCK_WORKSPACE/.ralph/gates/basic-latest.summary"
  [ -f "$summary" ]
  grep -q "^label: basic" "$summary"
  grep -q "^exit: 1" "$summary"
  grep -q "^duration: " "$summary"
  grep -q "^log: " "$summary"
  grep -q "^cmd: " "$summary"
  # No failure extraction — must NOT have a failures: section
  ! grep -q "^failures:" "$summary"
}

@test "removes stale summary on success (0.12.0)" {
  # First, produce a failing run that creates the summary.
  bash "$SCRIPTS_DIR/gate-run.sh" basic bash -c 'echo "Error: nope"; exit 1' || true
  local summary="$MOCK_WORKSPACE/.ralph/gates/basic-latest.summary"
  [ -f "$summary" ]

  # Then a passing run on the same label — summary should be gone.
  bash "$SCRIPTS_DIR/gate-run.sh" basic true || true
  [ ! -f "$summary" ]
}

@test "summary surfaces coverage gaps block when present in log (0.12.0)" {
  bash "$SCRIPTS_DIR/gate-run.sh" basic bash -c 'cat <<LOG
=== coverage gaps ===
src/foo.ts
  branches  88.5%  uncovered: 12, 14-18
=== end coverage gaps ===
Error: coverage threshold not met
LOG
exit 1' || true

  local summary="$MOCK_WORKSPACE/.ralph/gates/basic-latest.summary"
  [ -f "$summary" ]
  grep -q "^coverage_gaps:" "$summary"
  grep -q "src/foo.ts" "$summary"
  grep -q "uncovered: 12, 14-18" "$summary"
}

@test "retains only RALPH_GATE_KEEP logs" {
  export RALPH_GATE_KEEP=2

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

# -----------------------------------------------------------------------------
# 0.16.0: detached-runner architecture
# -----------------------------------------------------------------------------
# The gate executes in a runner detached into its own session (reparented
# to init from birth). The invoking call is only a waiter: nothing that
# kills it — tool timeout, subagent-return reap, tmux exit — can reach the
# gate, and a verdict breadcrumb is written on every runner outcome.

@test "waiter returns 75 while the gate still runs; verdict lands on its own (0.16.0)" {
  RALPH_GATE_WAIT=1 run bash "$SCRIPTS_DIR/gate-run.sh" basic bash -c 'sleep 4; exit 0'
  [ "$status" -eq 75 ]
  [[ "$output" == *"STILL RUNNING"* ]]
  # The runner outlives this call and lands the verdict by itself.
  local i=0
  until [ -f "$MOCK_WORKSPACE/.ralph/gates/basic-latest.exit" ] || [ $i -ge 15 ]; do
    sleep 1
    i=$((i + 1))
  done
  [ "$(cat "$MOCK_WORKSPACE/.ralph/gates/basic-latest.exit")" = "0" ]
}

@test "re-running the same command joins the in-flight gate — no double-run (0.16.0)" {
  RALPH_GATE_WAIT=0 run bash "$SCRIPTS_DIR/gate-run.sh" basic bash -c 'sleep 3; exit 7'
  [ "$status" -eq 75 ]
  RALPH_GATE_WAIT=20 run bash "$SCRIPTS_DIR/gate-run.sh" basic bash -c 'sleep 3; exit 7'
  [ "$status" -eq 7 ]
  [[ "$output" == *"joining in-flight"* ]]
  # Exactly one run happened: one timestamped log.
  local count
  count=$(find "$MOCK_WORKSPACE/.ralph/gates" -name "basic-*.log" \
    ! -name "basic-latest.log" -type f | wc -l | tr -d ' ')
  [ "$count" -eq 1 ]
}

@test "a different command under a live label lock is refused with 75 (0.16.0)" {
  RALPH_GATE_WAIT=0 run bash "$SCRIPTS_DIR/gate-run.sh" basic bash -c 'sleep 5; exit 0'
  [ "$status" -eq 75 ]
  RALPH_GATE_WAIT=5 run bash "$SCRIPTS_DIR/gate-run.sh" basic echo other-command
  [ "$status" -eq 75 ]
  [[ "$output" == *"DIFFERENT command"* ]]
  # Cleanup: stop the in-flight runner.
  kill -TERM "$(cat "$MOCK_WORKSPACE/.ralph/gates/.basic.lock/pid" 2>/dev/null)" 2>/dev/null || true
  sleep 1
}

@test "runner TERM writes a 143 breadcrumb, logs GATE end, releases the lock (0.16.0)" {
  RALPH_GATE_WAIT=0 RALPH_GATE_KILL_GRACE=1 run bash "$SCRIPTS_DIR/gate-run.sh" e2e bash -c 'sleep 30'
  [ "$status" -eq 75 ]
  local rpid
  rpid=$(cat "$MOCK_WORKSPACE/.ralph/gates/.e2e.lock/pid")
  kill -TERM "$rpid"
  local i=0
  until [ -f "$MOCK_WORKSPACE/.ralph/gates/e2e-latest.exit" ] || [ $i -ge 15 ]; do
    sleep 1
    i=$((i + 1))
  done
  [ "$(cat "$MOCK_WORKSPACE/.ralph/gates/e2e-latest.exit")" = "143" ]
  [ ! -d "$MOCK_WORKSPACE/.ralph/gates/.e2e.lock" ]
  grep -q "GATE end label=e2e exit=143" "$MOCK_WORKSPACE/.ralph/activity.log"
}

@test "waiter detects a hard-killed runner: exit 70, lock cleaned (0.16.0)" {
  RALPH_GATE_WAIT=0 run bash "$SCRIPTS_DIR/gate-run.sh" e2e bash -c 'sleep 30'
  [ "$status" -eq 75 ]
  local rpid
  rpid=$(cat "$MOCK_WORKSPACE/.ralph/gates/.e2e.lock/pid")
  (
    sleep 2
    kill -9 "$rpid"
  ) &
  RALPH_GATE_WAIT=20 run bash "$SCRIPTS_DIR/gate-run.sh" e2e bash -c 'sleep 30'
  wait
  [ "$status" -eq 70 ]
  [[ "$output" == *"RUNNER DIED"* ]]
  [ ! -d "$MOCK_WORKSPACE/.ralph/gates/.e2e.lock" ]
}

@test "runner is detached from the launcher tree: ppid is init (0.16.0)" {
  RALPH_GATE_WAIT=0 run bash "$SCRIPTS_DIR/gate-run.sh" unit bash -c 'sleep 5'
  [ "$status" -eq 75 ]
  local rpid
  rpid=$(cat "$MOCK_WORKSPACE/.ralph/gates/.unit.lock/pid")
  [ "$(ps -o ppid= -p "$rpid" | tr -d ' ')" = "1" ]
  # Cleanup: stop the in-flight runner.
  kill -TERM "$rpid" 2>/dev/null || true
  sleep 1
}
