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

@test "emits GUTTER on same shell command failing twice" {
  local events=""
  events+=$(tool_result_json "Shell" 50 5 1 "" "pnpm basic-check")
  events+=$'\n'
  events+=$(tool_result_json "Shell" 50 5 1 "" "pnpm basic-check")
  events+=$'\n'

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "GUTTER"
}

@test "emits GUTTER on file thrash (5 writes to same file in 10 min)" {
  local events=""
  for i in $(seq 1 5); do
    events+=$(tool_result_json "Write" 50 5 0 "/tmp/same-file.ts")
    events+=$'\n'
  done

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "GUTTER"
}

@test "emits GUTTER on read-without-write stall" {
  export RALPH_MAX_READS_WITHOUT_WRITE=5  # low threshold for testing

  local events=""
  for i in $(seq 1 6); do
    events+=$(tool_result_json "Read" 10 5 0 "/tmp/file${i}.ts")
    events+=$'\n'
  done

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "GUTTER"
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

  local output
  output=$(run_parser "$events")
  # Should NOT contain GUTTER from read-without-write
  # (may contain WARN/ROTATE from token accounting — that's fine)
  if echo "$output" | grep -q "GUTTER"; then
    # Check activity log to confirm it's from read-without-write (not another source)
    if grep -q "Read-without-write" "$MOCK_WORKSPACE/.ralph/activity.log"; then
      fail "GUTTER emitted for read-without-write despite Write in between"
    fi
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

@test "emits RECOVER on successful git commit" {
  local events=""
  events+=$(tool_result_json "Shell" 50 5 0 "" "git commit -m 'test'")

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "RECOVER"
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

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "GUTTER"
}
