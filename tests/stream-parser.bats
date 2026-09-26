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

# Helper: write .ralph/handoff.md with $1 as its ## Working set body
handoff_with_working_set() {
  cat >"$MOCK_WORKSPACE/.ralph/handoff.md" <<EOF
# Loop Handoff

## Working set

$1

## Last gate state

label: basic
exit: 0
EOF
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

@test "successful commit with failing trailing command is not logged as COMMIT FAILED (0.14.5)" {
  # The agent commonly chains a stop-check onto a commit:
  #   git commit -m '…' && git log --oneline -1; ls .ralph/stop-requested
  # The trailing `ls` exits 1 when the breadcrumbs are absent, so the
  # COMPOUND command's exit is 1 even though the commit succeeded. The exit
  # code must NOT be attributed to the commit.
  local events=""
  events+=$(tool_result_json "Shell" 50 5 1 "" "git commit -m 'feat: thing' && git log --oneline -1; ls .ralph/stop-requested")
  events+=$'\n'

  run_parser "$events" >/dev/null

  # No false COMMIT FAILED in the activity log…
  if grep -q "COMMIT FAILED" "$MOCK_WORKSPACE/.ralph/activity.log" 2>/dev/null; then
    fail "trailing-command exit was mis-attributed as COMMIT FAILED"
  fi
  # …the commit is still recorded…
  grep -q 'COMMIT "feat: thing"' "$MOCK_WORKSPACE/.ralph/activity.log"
  # …and no bogus gitignored hint fires from the trailing `ls .ralph/…`.
  if grep -qi "gitignored" "$MOCK_WORKSPACE/.ralph/errors.log" 2>/dev/null; then
    fail "bogus gitignored hint emitted for a trailing ls .ralph/ path"
  fi
}

@test "terminal git commit failure is still logged as COMMIT FAILED (0.14.5 regression guard)" {
  # When `git commit` IS the last command in the chain, a non-zero exit is
  # genuinely the commit's and must still surface as COMMIT FAILED.
  local events=""
  events+=$(tool_result_json "Shell" 50 5 1 "" "git add src/foo.ts && git commit -m 'feat: thing'")
  events+=$'\n'

  run_parser "$events" >/dev/null

  grep -q "COMMIT FAILED" "$MOCK_WORKSPACE/.ralph/activity.log"
}

# ---------------------------------------------------------------------------
# Expected-nonzero diagnostic filter (0.14.7)
#
# Exit 1 from a command composed purely of read-only utilities (breadcrumb
# polls, no-match greps) is informational — it must not pollute errors.log
# or the shell-fail GUTTER counter.
# ---------------------------------------------------------------------------

@test "read-only diagnostic exiting 1 is not logged as SHELL FAIL (0.14.7)" {
  # The canonical stop-check idiom plus a no-match grep — repeated past the
  # shell-fail threshold (2 under test override). Neither errors.log noise
  # nor GUTTER may result.
  local events=""
  for _ in 1 2 3; do
    events+=$(tool_result_json "Shell" 50 5 1 "" "ls .ralph/stop-requested .ralph/context-warning-active 2>&1")
    events+=$'\n'
    events+=$(tool_result_json "Shell" 50 5 1 "" "grep -n header-title apps/foo.ts | head")
    events+=$'\n'
  done

  local output
  output=$(run_parser "$events")

  if echo "$output" | grep -q "^GUTTER$"; then
    fail "GUTTER fired on repeated read-only diagnostics"
  fi
  if grep -q "SHELL FAIL" "$MOCK_WORKSPACE/.ralph/errors.log" 2>/dev/null; then
    fail "read-only diagnostic exit 1 was logged as SHELL FAIL"
  fi
}

@test "mutating command exiting 1 is still logged as SHELL FAIL (0.14.7 regression guard)" {
  local events=""
  events+=$(tool_result_json "Shell" 50 5 1 "" "pnpm basic-check 2>&1 | tail -20")
  events+=$'\n'

  run_parser "$events" >/dev/null

  grep -q "SHELL FAIL: pnpm basic-check" "$MOCK_WORKSPACE/.ralph/errors.log"
}

@test "read-only for-loop over grep -c exiting 1 is not logged as SHELL FAIL (0.18.0)" {
  # `for f in …; do echo …; grep -c … "$f"; done` exits 1 when the last
  # grep -c counts zero — a read-only diagnostic idiom that still landed in
  # errors.log pre-0.18 because the segment splitter saw the `for`/`do`
  # keywords, not the inner read-only commands. Built via jq so the inner
  # double quotes are JSON-escaped (the printf helper can't represent them).
  local cmd='for f in a.ts b.ts c.ts; do echo "--- $f"; grep -c CLOCK "$f"; done'
  local events
  events=$(jq -cn --arg c "$cmd" '{kind:"tool_result",name:"Shell",bytes:50,lines:5,exit_code:1,path:"",cmd:$c}')

  run_parser "$events" >/dev/null

  if grep -q "SHELL FAIL" "$MOCK_WORKSPACE/.ralph/errors.log" 2>/dev/null; then
    fail "read-only for/do/grep -c loop exit 1 was logged as SHELL FAIL"
  fi
}

@test "for-loop with a mutating body exiting 1 is still logged (0.18.0 regression guard)" {
  # Peeling loop keywords must not whitelist a mutating inner command.
  local cmd='for f in a b; do pnpm basic-check "$f"; done'
  local events
  events=$(jq -cn --arg c "$cmd" '{kind:"tool_result",name:"Shell",bytes:50,lines:5,exit_code:1,path:"",cmd:$c}')

  run_parser "$events" >/dev/null

  grep -q "SHELL FAIL: for f in a b" "$MOCK_WORKSPACE/.ralph/errors.log"
}

@test "read-only command with non-1 exit code is still logged as SHELL FAIL (0.14.7)" {
  # grep exits 2 on a real error (bad pattern / unreadable file) — only
  # exit 1 ("no match" semantics) qualifies as an expected diagnostic.
  local events=""
  events+=$(tool_result_json "Shell" 50 5 2 "" "grep -r pattern /nonexistent-dir")
  events+=$'\n'

  run_parser "$events" >/dev/null

  grep -q "SHELL FAIL: grep -r pattern" "$MOCK_WORKSPACE/.ralph/errors.log"
}

@test "compound chain with a mutating segment exiting 1 is still logged (0.14.7)" {
  # A read-only prefix must not whitelist the whole chain.
  local events=""
  events+=$(tool_result_json "Shell" 50 5 1 "" "cd /tmp; pnpm all-check 2>&1 | tail -40")
  events+=$'\n'

  run_parser "$events" >/dev/null

  grep -q "SHELL FAIL: cd /tmp; pnpm all-check" "$MOCK_WORKSPACE/.ralph/errors.log"
}

@test "read-only sed -n print exiting 1 is not logged as SHELL FAIL (0.14.10)" {
  # `sed -n '..p' missing-file` is a diagnostic read; exit 1 is informational.
  local events=""
  events+=$(tool_result_json "Shell" 50 5 1 "" "sed -n '1,130p' apps/api/tests/unit/missing.spec.ts")
  events+=$'\n'

  run_parser "$events" >/dev/null

  if grep -q "SHELL FAIL" "$MOCK_WORKSPACE/.ralph/errors.log" 2>/dev/null; then
    fail "read-only sed -n exit 1 was logged as SHELL FAIL"
  fi
}

@test "read-only find search exiting 1 is not logged as SHELL FAIL (0.14.10)" {
  local events=""
  events+=$(tool_result_json "Shell" 50 5 1 "" "find packages -name '*.spec.ts' -not -path '*/node_modules/*' | head")
  events+=$'\n'

  run_parser "$events" >/dev/null

  if grep -q "SHELL FAIL" "$MOCK_WORKSPACE/.ralph/errors.log" 2>/dev/null; then
    fail "read-only find search exit 1 was logged as SHELL FAIL"
  fi
}

@test "sed -i in-place edit exiting 1 is still logged as SHELL FAIL (0.14.10 regression guard)" {
  local events=""
  events+=$(tool_result_json "Shell" 50 5 1 "" "sed -i 's/a/b/' apps/foo.ts")
  events+=$'\n'

  run_parser "$events" >/dev/null

  grep -q "SHELL FAIL: sed -i" "$MOCK_WORKSPACE/.ralph/errors.log"
}

@test "find -exec exiting 1 is still logged as SHELL FAIL (0.14.10 regression guard)" {
  local events=""
  events+=$(tool_result_json "Shell" 50 5 1 "" "find . -name '*.tmp' -exec rm {} ;")
  events+=$'\n'

  run_parser "$events" >/dev/null

  grep -q "SHELL FAIL: find . -name" "$MOCK_WORKSPACE/.ralph/errors.log"
}

@test "find -delete exiting 1 is still logged as SHELL FAIL (0.14.10 regression guard)" {
  local events=""
  events+=$(tool_result_json "Shell" 50 5 1 "" "find build -type f -delete")
  events+=$'\n'

  run_parser "$events" >/dev/null

  grep -q "SHELL FAIL: find build" "$MOCK_WORKSPACE/.ralph/errors.log"
}

@test "read-only grep with a double-quoted pipe in its pattern is not logged as SHELL FAIL (0.14.12)" {
  # The diagnostic classifier replaces |/;/&&/|| with segment separators.
  # A `|` inside a quoted alternation pattern must NOT be treated as a real
  # pipe — otherwise a no-match exit 1 from a pure read-only grep lands in
  # errors.log (observed in loop 130812). `\"` in the fixture is a JSON-escaped
  # double quote, so the parser sees a real `grep -nE "test|vitest|coverage"`.
  local events=""
  events+=$(tool_result_json "Shell" 50 5 1 "" 'grep -nE \"test|vitest|coverage\" packages/data-sources/project.json')
  events+=$'\n'

  run_parser "$events" >/dev/null

  if grep -q "SHELL FAIL" "$MOCK_WORKSPACE/.ralph/errors.log" 2>/dev/null; then
    fail "read-only grep with a quoted-pipe pattern exit 1 was logged as SHELL FAIL"
  fi
}

@test "read-only compound with a quoted-pipe grep segment is not logged as SHELL FAIL (0.14.12)" {
  # Mirrors the loop-130812 explorer command: a find|head plus a quoted-pipe
  # grep, all read-only — exit 1 from a trailing no-match must stay quiet.
  local events=""
  events+=$(tool_result_json "Shell" 50 5 1 "" 'find packages -name \"*.spec.ts\" | head; grep -nE \"test|vitest|coverage\" project.json')
  events+=$'\n'

  run_parser "$events" >/dev/null

  if grep -q "SHELL FAIL" "$MOCK_WORKSPACE/.ralph/errors.log" 2>/dev/null; then
    fail "read-only quoted-pipe compound exit 1 was logged as SHELL FAIL"
  fi
}

@test "quoted pipe does not whitelist a following mutating segment (0.14.12 regression guard)" {
  # Stripping quoted content must not let a real mutating command ride along:
  # the unquoted `; pnpm build` is still a genuine, separately-classified
  # segment and keeps the whole command on the logged path.
  local events=""
  events+=$(tool_result_json "Shell" 50 5 1 "" 'echo \"a|b\"; pnpm build')
  events+=$'\n'

  run_parser "$events" >/dev/null

  grep -q "SHELL FAIL: echo" "$MOCK_WORKSPACE/.ralph/errors.log"
}

@test "file thrash at threshold emits GUTTER (0.10.0)" {
  # 0.14.7: thrash escalation now requires corroborating failure evidence
  # (at least one real shell failure since the last task boundary) — seed
  # one below the shell-fail threshold so only file-thrash can trip GUTTER.
  local events=""
  events+=$(tool_result_json "Shell" 50 5 1 "" "pnpm basic-check")
  events+=$'\n'
  for i in $(seq 1 5); do
    events+=$(tool_result_json "Write" 50 5 0 "/tmp/same-file.ts")
    events+=$'\n'
  done

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "^GUTTER$"
}

@test "file thrash with no failed command logs WRITE TEMPO, not GUTTER (0.14.7)" {
  # High write tempo with everything passing is normal incremental TDD
  # editing, not stuckness. With zero shell failures in the session, the
  # thrash threshold must downgrade to an informational activity-log line.
  local events=""
  for i in $(seq 1 5); do
    events+=$(tool_result_json "Write" 50 5 0 "/tmp/green-tempo.ts")
    events+=$'\n'
  done

  local output
  output=$(run_parser "$events")
  if echo "$output" | grep -q "^GUTTER$"; then
    fail "GUTTER fired on all-green write tempo — failure-evidence gate regressed"
  fi
  grep -q "WRITE TEMPO: /tmp/green-tempo.ts" "$MOCK_WORKSPACE/.ralph/activity.log"
  if grep -q "THRASHING" "$MOCK_WORKSPACE/.ralph/errors.log" 2>/dev/null; then
    fail "THRASHING logged to errors.log despite zero failures"
  fi
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
  # 0.14.7: seeded shell failure provides the required failure evidence.
  local events=""
  events+=$(tool_result_json "Shell" 50 5 1 "" "pnpm basic-check")
  events+=$'\n'
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
  # 0.14.7: a post-commit shell failure keeps the failure-evidence gate
  # open, so this test still proves the WRITE counter (not the absence of
  # failures) is what prevents GUTTER here.
  events+=$(tool_result_json "Shell" 50 5 1 "" "pnpm basic-check")
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
  # 0.14.7: seeded shell failure provides the required failure evidence.
  local events=""
  events+=$(tool_result_json "Shell" 50 5 1 "" "pnpm basic-check")
  events+=$'\n'
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

@test "emits GUTTER and records the structured reason (0.18.0)" {
  # `<ralph>GUTTER reason=<slug></ralph>` still emits the GUTTER signal AND
  # drops the slug at .ralph/gutter-reason so an outer supervisor can classify
  # the halt (e.g. auto-resume a concurrent-writer gutter).
  local events='{"kind":"assistant_text","text":"Two loops on one worktree. <ralph>GUTTER reason=concurrent-writer</ralph>"}'

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "^GUTTER$"
  [ "$(cat "$MOCK_WORKSPACE/.ralph/gutter-reason" 2>/dev/null)" = "concurrent-writer" ]
}

@test "bare GUTTER signal emits without a reason breadcrumb (0.18.0)" {
  # The unqualified form must still work and must NOT leave a reason file.
  local events='{"kind":"assistant_text","text":"Genuinely stuck. <ralph>GUTTER</ralph>"}'

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "^GUTTER$"
  [ ! -f "$MOCK_WORKSPACE/.ralph/gutter-reason" ]
}

@test "emits DEFER on rate limit rejection" {
  local events='{"kind":"rate_limit","status":"rejected","resets_at":0}'

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "DEFER"
}

@test "emits DEFER (not GUTTER) on dropped socket API error" {
  # Regression: the Anthropic SDK surfaces a transient drop as
  # "The socket connection was closed unexpectedly" — the "was" between
  # "connection" and "closed" dodged the `connection[[:space:]]*closed`
  # pattern, so it fell through to NON-RETRYABLE → GUTTER and halted the
  # whole runner (observed: a single drop stalled a run ~3.5h). Must DEFER.
  local events='{"kind":"error","message":"API Error: The socket connection was closed unexpectedly."}'

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "^DEFER$"
  ! echo "$output" | grep -q "^GUTTER$"
}

@test "emits DEFER on overloaded API error (529)" {
  # Companion to the socket case: confirms the existing overloaded path
  # still routes to DEFER, guarding against an over-broad edit.
  local events='{"kind":"error","message":"API Error: 529 Overloaded."}'

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "^DEFER$"
}

@test "still emits GUTTER on a genuinely non-retryable API error" {
  # The socket-drop widening must not turn every error into a DEFER —
  # an auth/validation-class error has no transient marker and stays GUTTER.
  local events='{"kind":"error","message":"API Error: 401 invalid x-api-key"}'

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "^GUTTER$"
}

@test "emits DEFER (not GUTTER) on a subscription session-limit error" {
  # Regression: a subscription quota is worded as a *named* limit — the
  # `hit your limit` pattern needs those words adjacent, and "session" sits
  # between them, so this fell through to NON-RETRYABLE → GUTTER. Observed
  # 2026-08-01: four concurrent loops all died on a session limit that reset
  # 68 minutes later, two seconds after the structured rate_limit event had
  # already said "back off and retry automatically".
  local msg="You've hit your session limit · resets 4am (America/New_York)"
  local events
  events=$(printf '{"kind":"error","message":%s}' "$(printf '%s' "$msg" | jq -R -s .)")

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "^DEFER$"
  ! echo "$output" | grep -q "^GUTTER$"
}

@test "emits DEFER on the other named-quota wordings" {
  # Same class, different nouns — all clear by themselves, none may GUTTER.
  local msg
  for msg in \
    "You've hit your weekly limit · resets Monday" \
    "You've hit your usage limit for this week" \
    "Daily limit reached — limit will reset at midnight UTC"; do
    local events output
    events=$(printf '{"kind":"error","message":%s}' "$(printf '%s' "$msg" | jq -R -s .)")
    output=$(run_parser "$events")
    echo "$output" | grep -q "^DEFER$" || {
      echo "expected DEFER for: $msg" >&2
      return 1
    }
    ! echo "$output" | grep -q "^GUTTER$" || {
      echo "unexpected GUTTER for: $msg" >&2
      return 1
    }
  done
}

@test "rate_limit event persists resets_at for the loop's quota wait" {
  # The epoch used to be printed and thrown away, leaving the DEFER handler
  # with only its 300s-capped backoff — which always expired before a
  # multi-hour reset and killed the run as a STALL. Persist it so the loop
  # can sleep exactly as long as the limit actually lasts.
  local future
  future=$(($(date +%s) + 3600))
  local events
  events=$(printf '{"kind":"rate_limit","status":"rejected","resets_at":%s}' "$future")

  run_parser "$events" >/dev/null

  [ -f "$MOCK_WORKSPACE/.ralph/rate-limit-resets-at" ]
  [ "$(cat "$MOCK_WORKSPACE/.ralph/rate-limit-resets-at")" = "$future" ]
}

@test "rate_limit event within quota writes no reset file" {
  # status != rejected is informational; it must not arm a quota wait.
  local events='{"kind":"rate_limit","status":"allowed","resets_at":0}'

  run_parser "$events" >/dev/null

  [ ! -f "$MOCK_WORKSPACE/.ralph/rate-limit-resets-at" ]
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

# ---------------------------------------------------------------------------
# 0.12.0: handoff "Last gate state" section writer.
#
# 0.24.0 moved the TRIGGER. It used to be `gate-run.sh` appearing in the
# model's command text, which ralph-guard.sh's auto-wrap never puts there —
# the rewrite happens in the PreToolUse hook's `updatedInput` and the
# transcript keeps `./scripts/gate.sh full`. So the writer never fired on the
# normal path (cur-71: 46 gate runs, `_(none yet)_` still in the handoff), and
# GATE_FAIL_STREAK never moved either. The trigger is now gate-run.sh's own
# `.ralph/gates/last-run` marker. Fixtures below therefore drive the marker
# and send the UNWRAPPED command the agent actually typed.
# ---------------------------------------------------------------------------

# Ordering barrier: the marker must land while the parser is running, exactly
# as it does in life (gate-run.sh writes it mid-stream). Waiting on a unique
# token in activity.log proves the parser is past its startup seed of
# GATE_EVENT_SEEN before we touch the file — a pre-existing marker is
# deliberately treated as already-consumed.
_wait_for_activity() {
  local pattern="$1" i=0
  while [[ $i -lt 200 ]]; do
    grep -q "$pattern" "$MOCK_WORKSPACE/.ralph/activity.log" 2>/dev/null && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

# Drive one or more gate ends through a SINGLE parser (the streak is per-agent-
# invocation, so a multi-gate fixture has to share one process).
# Usage: run_parser_gates basic:1 basic:1 full:0
#
# The sequence is per-TEST, not per-call: a test that calls this more than once
# would otherwise reuse `warmup-1`, and the barrier would clear on the previous
# call's line before the new parser had finished its startup seed.
_GATE_FIXTURE_SEQ=0
run_parser_gates() {
  local marker="$MOCK_WORKSPACE/.ralph/gates/last-run"
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  local specs=("$@") spec
  local -a seqs=()
  for spec in "${specs[@]}"; do
    _GATE_FIXTURE_SEQ=$((_GATE_FIXTURE_SEQ + 1))
    seqs+=("$_GATE_FIXTURE_SEQ")
  done
  {
    local i label code n
    for i in "${!specs[@]}"; do
      label="${specs[i]%%:*}"
      code="${specs[i]##*:}"
      n="${seqs[i]}"
      tool_result_json "Shell" 50 5 0 "" "echo warmup-$n"
      _wait_for_activity "warmup-$n"
      printf '%s %s 20260101T000000Z-%s\n' "$label" "$code" "$n" >"$marker"
      # The exit code on the wire is the agent's shell result, which is always
      # numeric; a malformed MARKER is a separate fixture (see below).
      tool_result_json "Shell" 50 5 "${code//[!0-9]/0}" "" "./scripts/gate.sh $label"
    done
  } | bash "$SCRIPTS_DIR/stream-parser.sh" "$MOCK_WORKSPACE" 1
}

# Send a raw marker line (label and exit unvalidated) followed by a shell
# result, for the malformed-input guards.
run_parser_raw_marker() {
  local raw="$1"
  local marker="$MOCK_WORKSPACE/.ralph/gates/last-run"
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  _GATE_FIXTURE_SEQ=$((_GATE_FIXTURE_SEQ + 1))
  local n="$_GATE_FIXTURE_SEQ"
  {
    tool_result_json "Shell" 50 5 0 "" "echo warmup-$n"
    _wait_for_activity "warmup-$n"
    printf '%s\n' "$raw" >"$marker"
    tool_result_json "Shell" 50 5 0 "" "./scripts/gate.sh basic"
  } | bash "$SCRIPTS_DIR/stream-parser.sh" "$MOCK_WORKSPACE" 1
}

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
  run_parser_gates basic:1 >/dev/null

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
  run_parser_gates basic:0 >/dev/null

  grep -q "Active task: T041" "$MOCK_WORKSPACE/.ralph/handoff.md"
  grep -q "exit: 0" "$MOCK_WORKSPACE/.ralph/handoff.md"
  ! grep -q "stale failure context" "$MOCK_WORKSPACE/.ralph/handoff.md"
}

@test "gate-end is a no-op when handoff.md is absent (0.12.0)" {
  rm -f "$MOCK_WORKSPACE/.ralph/handoff.md"
  # Must not error or create handoff.md.
  run_parser_gates basic:1 >/dev/null
  [ ! -f "$MOCK_WORKSPACE/.ralph/handoff.md" ]
}

# =============================================================================
# Gate-label sourcing (0.12.4 → 0.24.0)
# =============================================================================
# 0.12.4 fixed a regex that greedily captured `2` from `gate-run.sh 2>&1 |
# tail -40` and wrote `label: 2` into handoff.md. 0.24.0 removes the regex
# entirely: the label arrives as a FIELD in gate-run.sh's own marker, so there
# is no command line left to mis-parse. What survives from 0.12.4 is the
# invariant those tests were protecting — a label the parser cannot trust must
# not reach handoff.md — now enforced against the marker instead.

@test "a malformed marker never reaches handoff.md (0.24.0, ex-0.12.4)" {
  cat > "$MOCK_WORKSPACE/.ralph/handoff.md" <<'HOFF'
# Loop Handoff

## Last gate state

(unchanged sentinel)

## Working set

Active task: T099
HOFF
  # `2` where a label belongs, a non-numeric exit, and a truncated line — none
  # of them is a verdict, and the streak must not move on one either.
  run_parser_raw_marker '2 0 20260101T000000Z-a' >/dev/null
  run_parser_raw_marker 'basic notanumber 20260101T000000Z-b' >/dev/null
  run_parser_raw_marker 'basic' >/dev/null

  grep -q "unchanged sentinel" "$MOCK_WORKSPACE/.ralph/handoff.md"
  ! grep -q "label: 2" "$MOCK_WORKSPACE/.ralph/handoff.md"
  ! grep -q "label: basic" "$MOCK_WORKSPACE/.ralph/handoff.md"
}

@test "gate label is taken from the marker for every canonical label (0.24.0)" {
  for label in basic full final unit integration e2e lint format; do
    cat > "$MOCK_WORKSPACE/.ralph/handoff.md" <<HOFF
# Loop Handoff

## Last gate state

(none yet)
HOFF
    run_parser_gates "$label:0" >/dev/null
    grep -q "label: $label" "$MOCK_WORKSPACE/.ralph/handoff.md" \
      || { echo "Expected 'label: $label' in handoff but didn't find it"; return 1; }
  done
}

@test "a non-tier label now reaches the handoff too (0.24.0)" {
  # Pre-0.24 the canonical-set anchor was load-bearing against a mis-parsed
  # command line, and it silently dropped legitimate labels the eval loop
  # uses. With the label arriving as a field, `eval-final` is just a label.
  cat > "$MOCK_WORKSPACE/.ralph/handoff.md" <<'HOFF'
# Loop Handoff

## Last gate state

(none yet)
HOFF
  run_parser_gates "eval-final:0" >/dev/null
  grep -q "label: eval-final" "$MOCK_WORKSPACE/.ralph/handoff.md"
}

# ---------------------------------------------------------------------------
# 0.24.0: the gate-end trigger is the marker, not the command text.
# ---------------------------------------------------------------------------

@test "an auto-wrapped tier gate still reaches Last gate state (0.24.0)" {
  # THE regression. The agent types `./scripts/gate.sh full`; ralph-guard.sh
  # wraps it via updatedInput, which the transcript never sees. Pre-0.24 this
  # wrote nothing at all.
  cat > "$MOCK_WORKSPACE/.ralph/handoff.md" <<'HOFF'
# Loop Handoff

## Last gate state

_(none yet)_
HOFF
  run_parser_gates full:0 >/dev/null

  grep -q "label: full" "$MOCK_WORKSPACE/.ralph/handoff.md" \
    || { echo "handoff was not updated:"; cat "$MOCK_WORKSPACE/.ralph/handoff.md"; return 1; }
  ! grep -q "none yet" "$MOCK_WORKSPACE/.ralph/handoff.md"
}

@test "consecutive gate failures from the marker reach TURN_END (0.24.0)" {
  # The other half that was dead behind the command-text test: with the streak
  # never incrementing, the 5-failure TURN_END could not fire on a wrapped
  # gate. Threshold lowered to keep the fixture small.
  export RALPH_GATE_FAIL_STREAK_THRESHOLD=3
  local output
  output=$(run_parser_gates basic:1 basic:1 basic:1)
  echo "$output" | grep -q "^TURN_END$" \
    || { echo "TURN_END not emitted. Output: $output"; return 1; }
}

@test "a passing gate resets the failure streak (0.24.0)" {
  export RALPH_GATE_FAIL_STREAK_THRESHOLD=3
  local output
  output=$(run_parser_gates basic:1 basic:1 basic:0 basic:1 basic:1)
  if echo "$output" | grep -q "^TURN_END$"; then
    fail "TURN_END fired despite an intervening pass"
  fi
}

@test "a marker left by a previous loop is not replayed (0.24.0)" {
  # GATE_EVENT_SEEN is seeded at parser start. A red gate from the loop before
  # must not count as this session's first failure — the streak is per-agent-
  # invocation by design.
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf 'basic 1 20251231T235959Z-9\n' > "$MOCK_WORKSPACE/.ralph/gates/last-run"
  cat > "$MOCK_WORKSPACE/.ralph/handoff.md" <<'HOFF'
# Loop Handoff

## Last gate state

(unchanged sentinel)
HOFF
  local events=""
  events+=$(tool_result_json "Shell" 50 5 0 "" "./scripts/gate.sh basic")
  run_parser "$events" >/dev/null

  grep -q "unchanged sentinel" "$MOCK_WORKSPACE/.ralph/handoff.md"
}

@test "the same gate end is drained only once (0.24.0)" {
  export RALPH_GATE_FAIL_STREAK_THRESHOLD=2
  # One marker write, then two shell results. Only the first is a gate end;
  # re-reading an unchanged marker must not walk the streak.
  local marker="$MOCK_WORKSPACE/.ralph/gates/last-run"
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  local output
  output=$(
    {
      tool_result_json "Shell" 50 5 0 "" "echo warmup-1"
      _wait_for_activity "warmup-1"
      printf 'basic 1 20260101T000000Z-1\n' >"$marker"
      tool_result_json "Shell" 50 5 1 "" "./scripts/gate.sh basic"
      tool_result_json "Shell" 50 5 1 "" "./scripts/gate.sh basic"
    } | bash "$SCRIPTS_DIR/stream-parser.sh" "$MOCK_WORKSPACE" 1
  )
  if echo "$output" | grep -q "^TURN_END$"; then
    fail "an unchanged marker was counted twice"
  fi
}

# ---------------------------------------------------------------------------
# 0.24.0: handoff-touch stamp. handoff.md's own mtime cannot answer "when did
# the AGENT last write this" — the plugin rewrites the file too — so the
# parser records it from the tool event. _auto_enrich_handoff renders it.
# ---------------------------------------------------------------------------

@test "an agent edit that changes the working set stamps handoff-agent-ts (0.24.0)" {
  # 0.26.0: keyed on the section's content, so the edit must change it.
  handoff_with_working_set "- current task: T001"
  run_parser "" >/dev/null
  handoff_with_working_set "- current task: T002"
  local events=""
  events+=$(tool_result_json "Edit" 500 20 0 "$MOCK_WORKSPACE/.ralph/handoff.md" "")
  run_parser "$events" >/dev/null
  [ -f "$MOCK_WORKSPACE/.ralph/handoff-agent-ts" ]
  grep -qE '^[0-9]+$' "$MOCK_WORKSPACE/.ralph/handoff-agent-ts"
}

@test "editing another file does not stamp handoff-agent-ts (0.24.0)" {
  local events=""
  events+=$(tool_result_json "Edit" 500 20 0 "$MOCK_WORKSPACE/src/handoff.ts" "")
  run_parser "$events" >/dev/null
  [ ! -f "$MOCK_WORKSPACE/.ralph/handoff-agent-ts" ]
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

# ---------------------------------------------------------------------------
# Read-only vocabulary (0.20.0). The every-segment rule was already right;
# the allowlist was too small, so a long read-only diagnostic chain fell to
# the logged path on one unlisted segment. Fixtures below are verbatim shapes
# from the run that motivated this.
# ---------------------------------------------------------------------------

_expect_not_logged() {
  local events
  events=$(jq -cn --arg c "$1" \
    '{kind:"tool_result",name:"Shell",bytes:50,lines:5,exit_code:1,path:"",cmd:$c}')
  run_parser "$events" >/dev/null
  if grep -q "SHELL FAIL" "$MOCK_WORKSPACE/.ralph/errors.log" 2>/dev/null; then
    fail "read-only chain was logged as SHELL FAIL: $1"
  fi
}

_expect_logged() {
  local events
  events=$(jq -cn --arg c "$1" \
    '{kind:"tool_result",name:"Shell",bytes:50,lines:5,exit_code:1,path:"",cmd:$c}')
  run_parser "$events" >/dev/null
  grep -q "SHELL FAIL" "$MOCK_WORKSPACE/.ralph/errors.log"
}

@test "read-only git chain exiting 1 is not logged as SHELL FAIL (0.20.0)" {
  _expect_not_logged 'git rev-parse HEAD && git status --porcelain | head -20 && cat .ralph/gates/final-latest.exit 2>/dev/null'
}

@test "git check-ignore answering 1 is not logged as SHELL FAIL (0.20.0)" {
  # check-ignore exits 1 to ANSWER "not ignored" — the exit code is the
  # result, not a failure.
  _expect_not_logged 'git check-ignore -v .ralph/acceptance-report.md || echo "(not ignored)"'
}

@test "git -C global flag is skipped when reading the subcommand (0.20.0)" {
  _expect_not_logged 'git -C /some/repo status --short | head'
}

@test "git list-form group verbs are read-only (0.20.0)" {
  _expect_not_logged 'git worktree list; git stash list; git config --get user.email'
}

@test "git commit is still logged as SHELL FAIL (0.20.0 regression guard)" {
  _expect_logged 'git status && git commit -m wip'
}

@test "git worktree add is still logged as SHELL FAIL (0.20.0 regression guard)" {
  # Only the list/get shapes of a dual-purpose verb qualify.
  _expect_logged 'git worktree add ../wt feature-branch'
}

@test "docker inspection probe exiting 1 is not logged as SHELL FAIL (0.20.0)" {
  _expect_not_logged 'docker info >/dev/null 2>&1 && echo RUNNING || echo "NOT running"'
}

@test "docker ps and volume ls are read-only (0.20.0)" {
  _expect_not_logged 'docker ps -a --format "{{.Names}}" | grep -i curve; docker volume ls | grep -i curve'
}

@test "docker compose up is still logged as SHELL FAIL (0.20.0 regression guard)" {
  _expect_logged 'docker compose up -d'
}

@test "sort/awk/printf pipelines are read-only (0.20.0)" {
  _expect_not_logged 'grep -rhoE "^[A-Z_]+" .env 2>/dev/null | sort -u | awk "{print \$1}"'
}

@test "a redirect into a file is a write however read-only the command (0.20.0)" {
  # `cat > f` / `printf … > f` were judged read-only pre-0.20 because only
  # the command name was inspected.
  _expect_logged 'printf hello > /tmp/out.txt'
}

@test "sort -o writes in place and is still logged (0.20.0)" {
  _expect_logged 'sort -u in.txt -o in.txt'
}

@test "discards and fd dups are not writes (0.20.0 regression guard)" {
  # `2>/dev/null` and `2>&1` are ubiquitous in read-only diagnostics.
  _expect_not_logged 'ls .ralph/stop-requested 2>&1; grep -c CLOCK f.ts 2>/dev/null'
}

# ---------------------------------------------------------------------------
# Readiness probes (0.23.0). A bounded poll loop ends non-zero when the service
# never came up — or when the Bash tool's 120s default kills it, which is how
# the observed case arrived (cur-63-66, 2026-08-07 01:17:41). Either way that is
# the probe's answer, not a command failure. Fixtures are verbatim shapes from
# that run.
# ---------------------------------------------------------------------------

@test "readiness poll loop exiting 1 is not logged as SHELL FAIL (0.23.0)" {
  # The verbatim probe: `do` alone on its own segment, an `api=$(curl …)`
  # capture body, and a grouped `{ [ … ] || [ … ]; }` condition — three shapes
  # that each fell to the logged path before 0.23.0.
  local cmd='for i in $(seq 1 40); do
  api=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 http://127.0.0.1:16200/health 2>/dev/null)
  web=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 http://127.0.0.1:18498/ 2>/dev/null)
  echo "t=${i} api=${api} web=${web}"
  if [ "$api" = "200" ] && { [ "$web" = "200" ] || [ "$web" = "304" ]; }; then echo "READY"; break; fi
  sleep 3
done'
  _expect_not_logged "$cmd"
}

@test "repeated readiness polls do not walk the GUTTER counter (0.23.0)" {
  local cmd='for i in $(seq 1 20); do curl -s -o /dev/null --max-time 2 http://127.0.0.1:16200/health; sleep 3; done'
  local events=""
  for _ in 1 2 3; do
    events+=$(jq -cn --arg c "$cmd" \
      '{kind:"tool_result",name:"Shell",bytes:50,lines:5,exit_code:1,path:"",cmd:$c}')
    events+=$'\n'
  done

  local output
  output=$(run_parser "$events")

  if echo "$output" | grep -q "^GUTTER$"; then
    fail "GUTTER fired on repeated readiness probes"
  fi
}

@test "loop keyword on its own segment is peeled (0.23.0)" {
  # Pre-0.23 the 0.18.0 peel only handled the single-line `do grep …` form; a
  # bare `do` segment hit the default arm and rejected the whole command.
  _expect_not_logged 'for f in a b; do
  grep -c CLOCK "$f"
done'
}

@test "variable-capture body is judged on its inner command (0.23.0)" {
  _expect_not_logged 'code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:1/health); echo "$code"'
}

@test "variable capture of a MUTATING command is still logged (0.23.0 regression guard)" {
  # Peeling the assignment must not launder what it fronts.
  _expect_logged 'out=$(pnpm basic-check)'
}

@test "brace group is peeled to its inner command, not whitelisted (0.23.0 regression guard)" {
  _expect_logged '{ rm -rf /tmp/thing; }'
}

@test "readiness loop running a build is still logged (0.23.0 regression guard)" {
  _expect_logged 'for i in $(seq 1 5); do pnpm build; sleep 3; done'
}

@test "lsof and pgrep port probes are read-only (0.23.0)" {
  _expect_not_logged 'lsof -nP -iTCP:16200 -sTCP:LISTEN; pgrep -f "tsx scripts/serve.ts"'
}

@test "curl writing to a real file is still logged (0.23.0 regression guard)" {
  _expect_logged 'curl -s -o /tmp/payload.json http://127.0.0.1:16200/api/pipeline-status'
}

@test "curl -o /dev/null is a discard, not a write (0.23.0)" {
  _expect_not_logged 'curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:16200/health'
}

@test "curl with an explicit method mutates the far side and is still logged (0.23.0 regression guard)" {
  _expect_logged 'curl -s -X POST http://127.0.0.1:16200/internal/cycle-runs'
}

@test "curl uploading a body is still logged (0.23.0 regression guard)" {
  _expect_logged 'curl -s --data-binary @/tmp/plan.md https://storage.googleapis.com/bucket/key'
}

@test "nc port scan is read-only but a listener is still logged (0.23.0)" {
  _expect_not_logged 'nc -z 127.0.0.1 16200'
  _expect_logged 'nc -l 16200'
}

@test "wget only qualifies as a probe with --spider (0.23.0)" {
  _expect_not_logged 'wget --spider -q http://127.0.0.1:16200/health'
  _expect_logged 'wget http://127.0.0.1:16200/health'
}

# ---------------------------------------------------------------------------
# Sub-agent (sidechain) token accounting (0.23.0).
#
# 0.18.0 dropped a Task sub-agent's init and result events, but its tool
# traffic still flowed through and was charged to the rotation budget. A
# delegating loop therefore reported a context far larger than the
# orchestrator actually held, and could rotate early for no reason.
# ---------------------------------------------------------------------------

_sidechain_read() {
  # $1 = bytes, $2 = "true"|"false"
  jq -cn --argjson b "$1" --argjson sc "$2" \
    '{kind:"tool_result",name:"Read",path:"/tmp/big.ts",cmd:"",sidechain:$sc,bytes:$b,lines:10,exit_code:0}'
}

@test "top-level reads still drive ROTATE (0.23.0 control)" {
  export WARN_THRESHOLD=1900
  export ROTATE_THRESHOLD=2000
  local events=""
  for _ in $(seq 1 10); do
    events+=$(_sidechain_read 1000 false)
    events+=$'\n'
  done

  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "ROTATE"
}

@test "sub-agent reads do not drive ROTATE (0.23.0)" {
  # Byte-for-byte the control test's payload, marked as sidechain. That context
  # lives in the sub-agent's window, never in the orchestrator's.
  export WARN_THRESHOLD=1900
  export ROTATE_THRESHOLD=2000
  local events=""
  for _ in $(seq 1 10); do
    events+=$(_sidechain_read 1000 true)
    events+=$'\n'
  done

  local output
  output=$(run_parser "$events")
  if echo "$output" | grep -qE "ROTATE|WARN"; then
    fail "delegated sub-agent bytes drove the rotation signal"
  fi
}

@test "sub-agent bytes are reported as sub: on the TOKENS line (0.23.0)" {
  export WARN_THRESHOLD=100000
  export ROTATE_THRESHOLD=200000
  run_parser "$(_sidechain_read 8192 true)" >/dev/null
  grep -qE "TOKENS: .* sub:[0-9]+KB\]" "$MOCK_WORKSPACE/.ralph/activity.log"
}

@test "a non-delegating run's TOKENS line is unchanged (0.23.0 regression guard)" {
  export WARN_THRESHOLD=100000
  export ROTATE_THRESHOLD=200000
  run_parser "$(_sidechain_read 8192 false)" >/dev/null
  grep -q "TOKENS: " "$MOCK_WORKSPACE/.ralph/activity.log"
  if grep -q "sub:" "$MOCK_WORKSPACE/.ralph/activity.log"; then
    fail "sub: segment appeared on a run that never delegated"
  fi
}

@test "sub-agent work stays visible in the activity log (0.23.0)" {
  export WARN_THRESHOLD=100000
  export ROTATE_THRESHOLD=200000
  run_parser "$(_sidechain_read 4096 true)" >/dev/null
  grep -q "READ /tmp/big.ts" "$MOCK_WORKSPACE/.ralph/activity.log"
}

@test "a sub-agent's failing shell is still a real failure (0.23.0)" {
  # Only the byte accounting changes — a sub-agent's failures are as real as
  # the orchestrator's and must keep reaching errors.log.
  local events
  events=$(jq -cn '{kind:"tool_result",name:"Shell",bytes:50,lines:0,exit_code:1,path:"",cmd:"pnpm basic-check",sidechain:true}')
  run_parser "$events" >/dev/null
  grep -q "SHELL FAIL: pnpm basic-check" "$MOCK_WORKSPACE/.ralph/errors.log"
}

# ---------------------------------------------------------------------------
# Self-limited cutoffs (0.24.0). Sibling of the 0.23.0 readiness-probe rule,
# for the shape it does not reach: a deliberate interrupt/resume harness. Both
# fixtures are verbatim from cur-71, where they landed in errors.log as SHELL
# FAIL (15:33:02 and 15:36:41) while testing that a backfill resumes from its
# checkpoint after being cut off — being cut off was the point.
#
# Narrow on BOTH axes: the exit code must be a cutoff signature AND the command
# must carry the instrument that did the cutting. The regression guards below
# are the load-bearing half.
# ---------------------------------------------------------------------------

# Same shape as _expect_logged/_expect_not_logged but with a chosen exit code.
_cutoff_not_logged() {
  local events
  events=$(jq -cn --arg c "$1" --argjson e "$2" \
    '{kind:"tool_result",name:"Shell",bytes:50,lines:5,exit_code:$e,path:"",cmd:$c}')
  run_parser "$events" >/dev/null
  if grep -q "SHELL FAIL" "$MOCK_WORKSPACE/.ralph/errors.log" 2>/dev/null; then
    fail "self-limited cutoff was logged as SHELL FAIL: $1"
  fi
  grep -q "SHELL CUT OFF" "$MOCK_WORKSPACE/.ralph/activity.log" \
    || fail "cutoff was silently dropped instead of logged as CUT OFF: $1"
}

_cutoff_logged() {
  local events
  events=$(jq -cn --arg c "$1" --argjson e "$2" \
    '{kind:"tool_result",name:"Shell",bytes:50,lines:5,exit_code:$e,path:"",cmd:$c}')
  run_parser "$events" >/dev/null
  grep -q "SHELL FAIL" "$MOCK_WORKSPACE/.ralph/errors.log"
}

@test "a timeout harness cut off at its own budget is not a failure (0.24.0)" {
  _cutoff_not_logged 'timeout -k 3 12 bash -c "$(declare -f BF); BF" >/tmp/ff-1.log 2>&1; echo "cut off (rc=$?)"' 124
}

@test "a kill -INT harness cut off is not a failure (0.24.0)" {
  _cutoff_not_logged 'uv run curve backfill --tickers AAPL >/tmp/ff-1.log 2>&1 &
bpid=$!; sleep 14; kill -INT "$bpid" 2>/dev/null; wait "$bpid" 2>/dev/null; echo "interrupted"' 124
}

@test "SIGTERM and SIGKILL codes from a self-limited harness are cutoffs (0.24.0)" {
  _cutoff_not_logged 'timeout 30 pnpm dev' 143
  _cutoff_not_logged 'pkill -KILL -f "curve backfill"' 137
}

@test "a self-limited command failing on its OWN verdict is still logged (0.24.0 regression guard)" {
  # The budget was generous and the suite genuinely failed. Exit 1 is the
  # test runner's answer, not the cutoff's.
  _cutoff_logged 'timeout 300 pnpm test' 1
}

@test "a cutoff code with no self-cutoff instrument is still logged (0.24.0 regression guard)" {
  # The tool had to kill a plain build. That is the agent hanging the loop and
  # must stay visible.
  _cutoff_logged 'pnpm build' 124
}

@test "a kill -0 liveness probe is not a cutoff instrument (0.24.0 regression guard)" {
  # `kill -0` asks whether a pid is alive; it stops nothing. A command built
  # from it that dies must not launder itself as a deliberate cutoff.
  _cutoff_logged 'pid=60958; until ! kill -0 "$pid" 2>/dev/null; do sleep 15; done; pnpm build' 124
}

@test "curl --max-time is not the `timeout` command (0.24.0 regression guard)" {
  # Substring safety: `--max-time` must not read as the timeout instrument.
  _cutoff_logged 'curl -s --max-time 5 -X POST http://127.0.0.1:1/run' 124
}

# --- 0.24.1: per-session attribution + CLI-initiated context restarts ---
# The parser lives for a whole LOOP, but the agent CLI may open several
# sessions inside it (Claude Code auto-compaction). Pre-0.24.1 each of those
# logged a bare SESSION START with no reason, and every SESSION END reported
# the same loop-to-date token total.

@test "second init in a loop logs a CONTEXT RESTART, not a bare SESSION START (0.24.1)" {
  # Both events must go through ONE parser process — the session counter is
  # per-parser-lifetime, which is exactly the loop scope being modelled.
  printf '%s\n%s\n' \
    '{"kind":"system","model":"claude-opus-4-8"}' \
    '{"kind":"system","model":"claude-opus-4-8"}' |
    bash "$SCRIPTS_DIR/stream-parser.sh" "$MOCK_WORKSPACE" 1 > /dev/null

  grep -q "SESSION START: model=claude-opus-4-8" "$MOCK_WORKSPACE/.ralph/activity.log"
  grep -q "CONTEXT RESTART (#2)" "$MOCK_WORKSPACE/.ralph/activity.log"
  grep -q "rotated its own context" "$MOCK_WORKSPACE/.ralph/activity.log"
}

@test "a single-session loop still logs a plain SESSION START (0.24.1)" {
  run_parser '{"kind":"system","model":"claude-opus-4-8"}'
  grep -q "SESSION START: model=claude-opus-4-8" "$MOCK_WORKSPACE/.ralph/activity.log"
  ! grep -q "CONTEXT RESTART" "$MOCK_WORKSPACE/.ralph/activity.log"
}

@test "SESSION END reports this session's own tokens, not the loop total (0.24.1)" {
  # Two sessions, each doing work. The second SESSION END must NOT repeat the
  # first's cumulative figure — that identical-number bug is what this fixes.
  {
    echo '{"kind":"system","model":"m"}'
    tool_result_json "Read" 4000 10 0 "/tmp/a.ts"
    echo '{"kind":"result","duration_ms":1000}'
    echo '{"kind":"system","model":"m"}'
    tool_result_json "Read" 8000 10 0 "/tmp/b.ts"
    echo '{"kind":"result","duration_ms":2000}'
  } | bash "$SCRIPTS_DIR/stream-parser.sh" "$MOCK_WORKSPACE" 1 > /dev/null

  local first second
  first=$(grep -o "~[0-9]* tokens this session" "$MOCK_WORKSPACE/.ralph/activity.log" | head -1)
  second=$(grep -o "~[0-9]* tokens this session" "$MOCK_WORKSPACE/.ralph/activity.log" | tail -1)
  [ -n "$first" ] && [ -n "$second" ]
  [ "$first" != "$second" ] || {
    echo "both sessions reported the same figure: $first"
    return 1
  }
  # The loop total must still be reported alongside it.
  grep -q "loop total" "$MOCK_WORKSPACE/.ralph/activity.log"
}

@test "session token attribution never goes negative (0.24.1)" {
  {
    echo '{"kind":"system","model":"m"}'
    echo '{"kind":"result","duration_ms":10}'
    echo '{"kind":"result","duration_ms":10}'
  } | bash "$SCRIPTS_DIR/stream-parser.sh" "$MOCK_WORKSPACE" 1 > /dev/null
  ! grep -q -- "~-" "$MOCK_WORKSPACE/.ralph/activity.log"
}

# ---------------------------------------------------------------------------
# 0.26.0: rotation keys on the context the API reports. The byte count never
# sees the system prompt, retained thinking or any tool call's input; a usage
# report replaces it, and bytes after a report are added as an estimate until
# the next one.
# ---------------------------------------------------------------------------

usage_json() {
  printf '{"kind":"usage","context_tokens":%d}\n' "$1"
}

@test "a usage report is the token figure, however few bytes were seen (0.26.0)" {
  export WARN_THRESHOLD=5000
  export ROTATE_THRESHOLD=10000
  run_parser "$(usage_json 4000)" >/dev/null
  grep -qE 'TOKENS: 4000 / 10000 \(40%\) \[ctx:api ' "$MOCK_WORKSPACE/.ralph/activity.log"
}

@test "bytes after a usage report are added as an estimate (0.26.0)" {
  export WARN_THRESHOLD=5000
  export ROTATE_THRESHOLD=10000
  local events
  events="$(usage_json 4000)"$'\n'"$(tool_result_json "Read" 400 10 0 "/tmp/a.ts")"
  run_parser "$events" >/dev/null
  grep -q 'TOKENS: 4100 / 10000' "$MOCK_WORKSPACE/.ralph/activity.log"
}

@test "a usage report over ROTATE_THRESHOLD rotates with no tool result (0.26.0)" {
  export WARN_THRESHOLD=5000
  export ROTATE_THRESHOLD=10000
  local output
  output=$(run_parser "$(usage_json 12000)")
  echo "$output" | grep -q "^ROTATE$"
}

@test "a usage report over WARN_THRESHOLD requests the rotation (0.26.0)" {
  export WARN_THRESHOLD=5000
  export ROTATE_THRESHOLD=10000
  local output
  output=$(run_parser "$(usage_json 6000)")
  echo "$output" | grep -q "^WARN$"
  [ -f "$MOCK_WORKSPACE/.ralph/context-warning-active" ]
}

@test "a later, smaller usage report replaces the earlier one (0.26.0)" {
  # The CLI compacting its own context shrinks what the session holds.
  export WARN_THRESHOLD=50000
  export ROTATE_THRESHOLD=100000
  local events
  events="$(usage_json 60000)"$'\n''{"kind":"system","model":"claude-opus-5"}'$'\n'"$(usage_json 20000)"
  run_parser "$events" >/dev/null
  tail -n 1 "$MOCK_WORKSPACE/.ralph/activity.log" | grep -q 'TOKENS: 20000 / 100000'
}

@test "without usage reports the TOKENS line is the unmarked byte estimate (0.26.0)" {
  export WARN_THRESHOLD=5000
  export ROTATE_THRESHOLD=10000
  run_parser "$(tool_result_json "Read" 400 10 0 "/tmp/a.ts")" >/dev/null
  # PROMPT_CHARS (3000) + 400 bytes read, over 4.
  grep -q 'TOKENS: 850 / 10000 (8%) \[read:' "$MOCK_WORKSPACE/.ralph/activity.log"
  ! grep -q 'ctx:api' "$MOCK_WORKSPACE/.ralph/activity.log"
}

# ---------------------------------------------------------------------------
# 0.26.0: a guard denial is logged as one. The command never ran, so it is not
# a SHELL FAIL, a COMMIT FAILED, or a write — but re-issuing a call the guard
# keeps refusing still walks the GUTTER stuck-counter.
# ---------------------------------------------------------------------------

deny_json() { # $1=tool name $2=command (Shell) or path $3=reason
  if [[ "$1" == "Shell" ]]; then
    jq -cn --arg c "$2" --arg r "$3" \
      '{kind:"tool_result",name:"Shell",cmd:$c,path:"",bytes:80,lines:0,exit_code:1,denied:true,deny_reason:$r}'
  else
    jq -cn --arg n "$1" --arg p "$2" --arg r "$3" \
      '{kind:"tool_result",name:$n,cmd:"",path:$p,bytes:80,lines:1,exit_code:1,denied:true,deny_reason:$r}'
  fi
}

@test "a guard denial is logged as GUARD DENY, not SHELL FAIL (0.26.0)" {
  run_parser "$(deny_json Shell 'pnpm basic-check' "Gate 'basic' already ran and nothing has changed since")" >/dev/null
  grep -q "GUARD DENY: pnpm basic-check → Gate 'basic' already ran" "$MOCK_WORKSPACE/.ralph/errors.log"
  ! grep -q "SHELL FAIL" "$MOCK_WORKSPACE/.ralph/errors.log"
  grep -q "SHELL pnpm basic-check → denied by guard" "$MOCK_WORKSPACE/.ralph/activity.log"
}

@test "a denied git commit is not logged as COMMIT FAILED (0.26.0)" {
  run_parser "$(deny_json Shell 'git add -A && git commit -m "wip"' "Blanket 'git add' denied")" >/dev/null
  ! grep -q "COMMIT FAILED" "$MOCK_WORKSPACE/.ralph/activity.log"
  grep -q "GUARD DENY: git add -A" "$MOCK_WORKSPACE/.ralph/errors.log"
}

@test "re-issuing a denied call reaches GUTTER at the shell-fail threshold (0.26.0)" {
  local events
  events="$(deny_json Shell 'pnpm basic-check' 'cached')"$'\n'"$(deny_json Shell 'pnpm basic-check' 'cached')"
  local output
  output=$(run_parser "$events")
  echo "$output" | grep -q "^GUTTER$"
  grep -q "same call denied 2x" "$MOCK_WORKSPACE/.ralph/errors.log"
}

@test "a denied Write is logged as denied, not as a write (0.26.0)" {
  local target="$MOCK_WORKSPACE/.ralph/command-policy"
  run_parser "$(deny_json Write "$target" "Write to '.ralph/command-policy' denied.")" >/dev/null
  grep -qF "WRITE $target → denied by guard" "$MOCK_WORKSPACE/.ralph/activity.log"
  ! grep -qF "WRITE $target (" "$MOCK_WORKSPACE/.ralph/activity.log"
  grep -qF "GUARD DENY: WRITE $target" "$MOCK_WORKSPACE/.ralph/errors.log"
}

@test "a long failing command counts as one repeat per failure (0.26.0)" {
  # base64 wraps long input on some platforms; the repeat counter must still
  # see one line per failure.
  local long
  long="pnpm $(printf 'x%.0s' $(seq 1 200))"
  local events
  events="$(tool_result_json "Shell" 50 0 1 "" "$long")"$'\n'"$(tool_result_json "Shell" 50 0 1 "" "$long")"
  run_parser "$events" >/dev/null
  grep -q "(attempt 2)" "$MOCK_WORKSPACE/.ralph/errors.log"
  ! grep -q "(attempt 3)" "$MOCK_WORKSPACE/.ralph/errors.log"
}

# ---------------------------------------------------------------------------
# 0.26.0: the working set's age is keyed on its content. The agent rewrites the
# handoff through Bash as often as through Write/Edit, and no tool event
# reports a Bash write.
# ---------------------------------------------------------------------------

@test "the first look at the working set records a baseline, no stamp (0.26.0)" {
  handoff_with_working_set "- current task: T001"
  run_parser "$(tool_result_json "Read" 100 10 0 "/tmp/a.ts")" >/dev/null
  [ -f "$MOCK_WORKSPACE/.ralph/handoff-working-set.sum" ]
  [ ! -f "$MOCK_WORKSPACE/.ralph/handoff-agent-ts" ]
}

@test "a Bash rewrite of the working set mid-stream stamps its age (0.26.0)" {
  handoff_with_working_set "- current task: T001"
  {
    tool_result_json "Shell" 10 0 0 "" "ls"
    # Let the parser take its baseline before the rewrite lands.
    sleep 1
    handoff_with_working_set "- current task: T002"
    tool_result_json "Shell" 10 0 0 "" "python3 - rewrites .ralph/handoff.md"
  } | bash "$SCRIPTS_DIR/stream-parser.sh" "$MOCK_WORKSPACE" 1 >/dev/null
  [ -f "$MOCK_WORKSPACE/.ralph/handoff-agent-ts" ]
  grep -qE '^[0-9]+$' "$MOCK_WORKSPACE/.ralph/handoff-agent-ts"
}

@test "a working set changed after the last look is stamped at the next start (0.26.0)" {
  handoff_with_working_set "- current task: T001"
  run_parser "" >/dev/null
  handoff_with_working_set "- current task: T002"
  run_parser "" >/dev/null
  [ -f "$MOCK_WORKSPACE/.ralph/handoff-agent-ts" ]
}

@test "rewriting only the plugin's sections does not stamp the working set (0.26.0)" {
  handoff_with_working_set "- current task: T001"
  run_parser "" >/dev/null
  # What update_handoff_gate_state and _auto_enrich_handoff rewrite.
  sed -i.bak 's/^exit: 0$/exit: 1/' "$MOCK_WORKSPACE/.ralph/handoff.md"
  printf '\n## Auto-enriched state\n\n**Last commit**: `abc123 feat: x`\n' >>"$MOCK_WORKSPACE/.ralph/handoff.md"
  run_parser "$(tool_result_json "Edit" 100 10 0 "$MOCK_WORKSPACE/.ralph/handoff.md")" >/dev/null
  [ ! -f "$MOCK_WORKSPACE/.ralph/handoff-agent-ts" ]
}

@test "an identical rewrite of the working set does not stamp (0.26.0)" {
  handoff_with_working_set "- current task: T001"
  run_parser "" >/dev/null
  handoff_with_working_set "- current task: T001"
  run_parser "$(tool_result_json "Write" 100 10 0 "$MOCK_WORKSPACE/.ralph/handoff.md")" >/dev/null
  [ ! -f "$MOCK_WORKSPACE/.ralph/handoff-agent-ts" ]
}

@test "the handoff file created with a working set counts as a change (0.26.0)" {
  rm -f "$MOCK_WORKSPACE/.ralph/handoff.md"
  run_parser "" >/dev/null
  handoff_with_working_set "- current task: T001"
  run_parser "$(tool_result_json "Write" 100 10 0 "$MOCK_WORKSPACE/.ralph/handoff.md")" >/dev/null
  [ -f "$MOCK_WORKSPACE/.ralph/handoff-agent-ts" ]
}

@test "with usage reports, SESSION END gives each session its own context (0.26.0)" {
  # The second session follows the CLI compacting its own context: its figure
  # is its own context, not a negative delta from the one it inherited.
  export WARN_THRESHOLD=900000
  export ROTATE_THRESHOLD=1000000
  local events
  events='{"kind":"system","model":"claude-opus-5"}'$'\n'"$(usage_json 80000)"$'\n''{"kind":"result","duration_ms":1000}'
  events+=$'\n''{"kind":"system","model":"claude-opus-5"}'$'\n'"$(usage_json 30000)"$'\n''{"kind":"result","duration_ms":1000}'
  run_parser "$events" >/dev/null
  grep -q "SESSION END: 1000ms, ~80000 tokens this session" "$MOCK_WORKSPACE/.ralph/activity.log"
  grep -q "SESSION END: 1000ms, ~30000 tokens this session" "$MOCK_WORKSPACE/.ralph/activity.log"
}
