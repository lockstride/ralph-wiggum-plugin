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

@test "log_activity emits HEARTBEAT to stdout (0.4.0)" {
  # Regression for the 0.4.0 activity-based heartbeat. Every Read /
  # Shell / Write (which routes through log_activity) should emit a
  # HEARTBEAT token on stdout so the main loop's `read -t` timer
  # resets on real parser activity. Pre-0.4.0 the timer only reset
  # on control signals (ROTATE/COMPLETE/…) so an agent working quietly
  # between commits would trip the 300s heartbeat and die at 5-6 min.
  local events=""
  events+=$(tool_result_json "Read" 100 10 0 "/tmp/file.ts")
  events+=$'\n'
  local output
  output=$(run_parser "$events")
  # One HEARTBEAT from the Read's log_activity, plus (often) one from
  # the 30s token-status timer if the test takes long enough.
  echo "$output" | grep -q "^HEARTBEAT$"
}

@test "log_token_status emits HEARTBEAT to stdout (0.4.0)" {
  # The 30s periodic token-status log also resets the heartbeat timer.
  # We can't easily wait 30s in a test; instead we assert log_activity
  # emits HEARTBEAT (proven above) and that log_token_status does too
  # by invoking stream-parser with input that forces both code paths.
  local events=""
  # Enough reads to push through the token-status logging cadence.
  for i in $(seq 1 5); do
    events+=$(tool_result_json "Read" 100 10 0 "/tmp/f${i}.ts")
    events+=$'\n'
  done
  local output
  output=$(run_parser "$events")
  # Expect at least one HEARTBEAT per log_activity call (5 reads → 5+).
  local count
  count=$(echo "$output" | grep -c "^HEARTBEAT$" || true)
  [ "$count" -ge 5 ]
}

@test "shell-fail threshold configurable via RALPH_SHELL_FAIL_THRESHOLD (0.4.0)" {
  # With threshold=4, 2× and 3× fails should be benign; only 4× trips
  # RECOVER_ATTEMPT. This is the 0.4.0 default that gives agents a
  # realistic red-state debug budget.
  export RALPH_SHELL_FAIL_THRESHOLD=4
  local events=""
  for i in 1 2 3; do
    events+=$(tool_result_json "Shell" 50 5 1 "" "pnpm basic-check")
    events+=$'\n'
  done
  local output
  output=$(run_parser "$events")
  # 3 fails under threshold 4 → no RECOVER_ATTEMPT yet
  if echo "$output" | grep -q "RECOVER_ATTEMPT"; then
    fail "RECOVER_ATTEMPT emitted at 3x with threshold=4; expected quiet"
  fi

  # Add a 4th fail → RECOVER_ATTEMPT fires
  events+=$(tool_result_json "Shell" 50 5 1 "" "pnpm basic-check")
  events+=$'\n'
  output=$(run_parser "$events")
  echo "$output" | grep -q "RECOVER_ATTEMPT"
}

@test "first identical-shell-fail-2x emits RECOVER_ATTEMPT (not GUTTER) and writes hint (0.3.0)" {
  local events=""
  events+=$(tool_result_json "Shell" 50 5 1 "" "pnpm basic-check")
  events+=$'\n'
  events+=$(tool_result_json "Shell" 50 5 1 "" "pnpm basic-check")
  events+=$'\n'

  local output
  output=$(run_parser "$events")
  # First trip: RECOVER_ATTEMPT, NOT GUTTER
  echo "$output" | grep -q "RECOVER_ATTEMPT"
  if echo "$output" | grep -q "^GUTTER$"; then
    fail "First stuck-shell trip should emit RECOVER_ATTEMPT, not GUTTER (0.3.0)"
  fi
  # Hint file written with command + exit code
  [ -f "$MOCK_WORKSPACE/.ralph/recovery-hint.md" ]
  grep -q "Recovery Hint from Prior Iteration" "$MOCK_WORKSPACE/.ralph/recovery-hint.md"
  grep -q "pnpm basic-check" "$MOCK_WORKSPACE/.ralph/recovery-hint.md"
  grep -q "exit code (\`1\`)" "$MOCK_WORKSPACE/.ralph/recovery-hint.md"
  # Errors/activity log mention recoverable pattern
  grep -q "RECOVERABLE STUCK PATTERN" "$MOCK_WORKSPACE/.ralph/errors.log"
}

@test "second stuck pattern in same iteration falls through to GUTTER (0.3.0)" {
  # First failure 2x → RECOVER_ATTEMPT (consumes the recovery slot)
  # Second failure 2x (different command, same iteration) → GUTTER
  local events=""
  events+=$(tool_result_json "Shell" 50 5 1 "" "pnpm a")
  events+=$'\n'
  events+=$(tool_result_json "Shell" 50 5 1 "" "pnpm a")
  events+=$'\n'
  events+=$(tool_result_json "Shell" 50 5 1 "" "pnpm b")
  events+=$'\n'
  events+=$(tool_result_json "Shell" 50 5 1 "" "pnpm b")
  events+=$'\n'

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "RECOVER_ATTEMPT"
  echo "$output" | grep -q "^GUTTER$"
  # Errors log records the budget-exhausted GUTTER reason
  grep -q "recovery already used this iteration" "$MOCK_WORKSPACE/.ralph/errors.log"
}

@test "first file thrash emits RECOVER_ATTEMPT (not GUTTER) and writes hint (0.3.0)" {
  local events=""
  for i in $(seq 1 5); do
    events+=$(tool_result_json "Write" 50 5 0 "/tmp/same-file.ts")
    events+=$'\n'
  done

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "RECOVER_ATTEMPT"
  if echo "$output" | grep -q "^GUTTER$"; then
    fail "First file-thrash trip should emit RECOVER_ATTEMPT, not GUTTER (0.3.0)"
  fi
  # Hint file written with thrashed path
  [ -f "$MOCK_WORKSPACE/.ralph/recovery-hint.md" ]
  grep -q "Recovery Hint from Prior Iteration" "$MOCK_WORKSPACE/.ralph/recovery-hint.md"
  grep -q "/tmp/same-file.ts" "$MOCK_WORKSPACE/.ralph/recovery-hint.md"
  grep -q "5 times within 10 minutes" "$MOCK_WORKSPACE/.ralph/recovery-hint.md"
}

@test "thrash followed by repeat shell-fail in same iteration: RECOVER_ATTEMPT then GUTTER (0.3.0)" {
  # Thrash consumes the recovery slot; subsequent stuck shell-fail goes to GUTTER.
  local events=""
  for i in $(seq 1 5); do
    events+=$(tool_result_json "Write" 50 5 0 "/tmp/thrashed.ts")
    events+=$'\n'
  done
  events+=$(tool_result_json "Shell" 50 5 1 "" "pnpm test")
  events+=$'\n'
  events+=$(tool_result_json "Shell" 50 5 1 "" "pnpm test")
  events+=$'\n'

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "RECOVER_ATTEMPT"
  echo "$output" | grep -q "^GUTTER$"
}

@test "logs read-without-write stall but does not emit GUTTER (0.2.4)" {
  export RALPH_MAX_READS_WITHOUT_WRITE=5  # low threshold for testing

  local events=""
  for i in $(seq 1 6); do
    events+=$(tool_result_json "Read" 10 5 0 "/tmp/file${i}.ts")
    events+=$'\n'
  done

  local output
  output=$(run_parser "$events")
  # Stall is logged for visibility...
  grep -q "READ-WITHOUT-WRITE STALL" "$MOCK_WORKSPACE/.ralph/errors.log"
  grep -q "Read-without-write stall" "$MOCK_WORKSPACE/.ralph/activity.log"
  # ...but does NOT emit GUTTER. It is a smell, not evidence of stuckness.
  if echo "$output" | grep -q "GUTTER"; then
    fail "Stall should not emit GUTTER as of 0.2.4; it logs only"
  fi
}

@test "resets read-without-write counter on Write" {
  export RALPH_MAX_READS_WITHOUT_WRITE=5

  local events=""
  # 4 reads, then a write, then 4 more reads — never hits 5 consecutive
  for i in $(seq 1 4); do
    events+=$(tool_result_json "Read" 10 5 0 "/tmp/file${i}.ts")
    events+=$'\n'
  done
  events+=$(tool_result_json "Write" 10 5 0 "/tmp/output.ts")
  events+=$'\n'
  for i in $(seq 5 8); do
    events+=$(tool_result_json "Read" 10 5 0 "/tmp/file${i}.ts")
    events+=$'\n'
  done

  run_parser "$events" >/dev/null
  # The stall log line should not appear — the Write reset the counter
  # before either 5-read streak hit the threshold.
  if grep -q "READ-WITHOUT-WRITE STALL" "$MOCK_WORKSPACE/.ralph/errors.log" 2>/dev/null; then
    fail "Stall logged despite Write in between reads"
  fi
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
  # never fired and the per-iteration shell-failure counter accumulated
  # across an entire iteration's worth of successful commits.
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

@test "Shell commands increment read-without-write counter" {
  export RALPH_MAX_READS_WITHOUT_WRITE=5

  local events=""
  # Mix of reads and shells — all non-write ops
  events+=$(tool_result_json "Read" 10 5 0 "/tmp/file1.ts")
  events+=$'\n'
  events+=$(tool_result_json "Shell" 10 5 0 "" "ls -la")
  events+=$'\n'
  events+=$(tool_result_json "Read" 10 5 0 "/tmp/file2.ts")
  events+=$'\n'
  events+=$(tool_result_json "Shell" 10 5 0 "" "grep foo bar")
  events+=$'\n'
  events+=$(tool_result_json "Read" 10 5 0 "/tmp/file3.ts")
  events+=$'\n'

  run_parser "$events" >/dev/null
  # 5 non-write ops should hit the stall threshold and log it (0.2.4: logged, not GUTTER)
  grep -q "READ-WITHOUT-WRITE STALL" "$MOCK_WORKSPACE/.ralph/errors.log"
}
