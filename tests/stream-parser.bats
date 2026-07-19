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
