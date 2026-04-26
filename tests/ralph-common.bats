#!/usr/bin/env bats
# Behavioral tests for ralph-common.sh build_prompt() framing.
#
# Verifies the trimmed framing prompt contains required sections
# and does NOT contain removed sections.

load test_helper

setup() {
  create_mock_workspace

  # Source ralph-common.sh (requires agent-adapter.sh first)
  source "$SCRIPTS_DIR/agent-adapter.sh"
  source "$SCRIPTS_DIR/ralph-common.sh"

  # Create minimal state files that build_prompt expects
  echo "# Guardrails" > "$MOCK_WORKSPACE/.ralph/guardrails.md"
  echo "# Errors" > "$MOCK_WORKSPACE/.ralph/errors.log"

  # Write a mock effective prompt
  mkdir -p "$MOCK_WORKSPACE/.ralph"
  echo "Mock task body" > "$MOCK_WORKSPACE/.ralph/effective-prompt.md"
}

teardown() {
  rm -rf "$MOCK_WORKSPACE"
}

@test "build_prompt framing is under 55 lines (excluding user body)" {
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  # Count lines before the user body marker "## Task Execution"
  local framing_lines
  framing_lines=$(echo "$output" | sed '/^## Task Execution$/,$d' | wc -l | tr -d ' ')

  # Framing should be concise. History:
  #   0.3.3 added Completion Bar          (cap was 35)
  #   0.3.6 added Gate Runner section     (cap bumped to 55)
  #   0.6.3 expanded the Stop conditions  (cap bumped to 70)
  #         section so the four real stop conditions are explicit and
  #         reframed gate-failure guidance away from a procedure.
  # The Gate Runner block only renders when gate-run.sh exists next to
  # ralph-common.sh (it does in-tree). If it ever needs to grow further,
  # update this cap AND AGENTS.md §Prompt Architecture in the same commit.
  [ "$framing_lines" -le 70 ]
}

@test "build_prompt includes Completion Bar (0.3.3)" {
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  echo "$output" | grep -q "Completion Bar"
  echo "$output" | grep -qi "pre-existing failure.*never"
  # Completion Bar must appear BEFORE State Files — it's the first rule.
  echo "$output" | awk '
    /## Completion Bar/ { saw_cb=1 }
    /## State Files/    { if (saw_cb) ok=1 }
    END { exit ok ? 0 : 1 }
  '
}

@test "build_prompt includes required sections" {
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  echo "$output" | grep -q "State Files"
  # 0.6.3 renamed "Signals" to "Stop conditions" — same intent, clearer name.
  echo "$output" | grep -q "Stop conditions"
  echo "$output" | grep -q "Loop Hygiene"
  echo "$output" | grep -q "Task Execution"
}

@test "build_prompt includes Gate Runner section when gate-run.sh is present (0.3.6)" {
  # gate-run.sh ships in-tree next to ralph-common.sh, so the block renders
  # under the normal test setup. This was the 0.3.6 fix for agents who ran
  # bare commands and re-ran on every failure instead of reading the log.
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  echo "$output" | grep -q "## Gate Runner"
  # 0.6.3: load-bearing pieces of the new (less prescriptive) protocol.
  # The "do NOT re-run" recipe was replaced by an "understand why, then
  # act" framing — same intent (don't reflexively retry), more latitude
  # for the agent to inspect screenshots / curl / lsof / config as the
  # situation demands.
  echo "$output" | grep -q "Never pipe"
  echo "$output" | grep -qE "\.ralph/gates/<label>-latest\.log"
  echo "$output" | grep -qE "understand why"
  # Points at --help so agents can self-discover the full surface:
  echo "$output" | grep -q -- "--help"
}

@test "build_prompt omits Gate Runner section when gate-run.sh is absent (0.3.6)" {
  # Simulate a degraded install where gate-run.sh is missing. The block
  # must not render (it would mislead the agent about a tool it can't call).
  # We copy ralph-common.sh to a temp dir without gate-run.sh, source it
  # from there, and call build_prompt.
  local tmp
  tmp=$(mktemp -d "$BATS_TMPDIR/rb-no-gate.XXXXXX")
  cp "$SCRIPTS_DIR/agent-adapter.sh" "$tmp/"
  cp "$SCRIPTS_DIR/ralph-common.sh" "$tmp/"
  # NOTE: deliberately do NOT copy gate-run.sh

  local output
  output=$(
    bash -c "
      source '$tmp/agent-adapter.sh'
      source '$tmp/ralph-common.sh'
      build_prompt '$MOCK_WORKSPACE' 1
    "
  )

  if echo "$output" | grep -q "## Gate Runner"; then
    rm -rf "$tmp"
    fail "Gate Runner section must not appear when gate-run.sh is absent"
  fi

  rm -rf "$tmp"
}

@test "build_prompt does NOT include removed verbose sections" {
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  # These were in the old 85-line framing but are now removed
  ! echo "$output" | grep -qi "naming hygiene"
  ! echo "$output" | grep -qi "gate invocation contract"
  ! echo "$output" | grep -qi "Learning from Failures"
  ! echo "$output" | grep -qi "Context Rotation Warning"
  ! echo "$output" | grep -qi "Sign:"
}

@test "build_prompt includes loop number" {
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 7)

  echo "$output" | grep -q "Loop 7"
}

@test "build_prompt includes user body from effective prompt" {
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  echo "$output" | grep -q "Mock task body"
}

@test "build_prompt prepends recovery hint when present (0.3.0)" {
  # Simulate a prior loop's stream-parser having written a hint
  cat > "$MOCK_WORKSPACE/.ralph/recovery-hint.md" <<EOF
## Recovery Hint from Prior Loop

Your prior loop ran \`pnpm test\` twice with exit code 1. Do not retry it.
EOF

  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 5)

  # Hint section appears
  echo "$output" | grep -q "Recovery Hint from Prior Loop"
  echo "$output" | grep -q "pnpm test"
  # Hint appears between the loop header and State Files (recovery is authoritative steering)
  echo "$output" | awk '
    /^# Ralph Loop 5/ { saw_header=1 }
    /Recovery Hint from Prior Loop/ { if (saw_header && !saw_state) saw_hint=1 }
    /^## State Files/ { saw_state=1 }
    END { exit (saw_hint && saw_state) ? 0 : 1 }
  '
}

@test "build_prompt deletes recovery hint after consumption (consume-once) (0.3.0)" {
  echo "## Recovery Hint from Prior Loop" > "$MOCK_WORKSPACE/.ralph/recovery-hint.md"
  echo "Some hint body" >> "$MOCK_WORKSPACE/.ralph/recovery-hint.md"

  build_prompt "$MOCK_WORKSPACE" 1 >/dev/null

  # File must be gone
  [ ! -f "$MOCK_WORKSPACE/.ralph/recovery-hint.md" ]
}

@test "build_prompt has no hint section when no hint file (0.3.0)" {
  # No recovery-hint.md exists in the mock workspace by default
  rm -f "$MOCK_WORKSPACE/.ralph/recovery-hint.md"

  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  # No recovery section in output
  if echo "$output" | grep -q "Recovery Hint from Prior Loop"; then
    fail "build_prompt should not include a Recovery Hint section when no hint file exists"
  fi
}

# ---------------------------------------------------------------------------
# _classify_heartbeat_exit — heartbeat loop exit classifier (0.3.1+)
# ---------------------------------------------------------------------------

@test "_classify_heartbeat_exit: non-empty signal always wins" {
  # Even if read returned a timeout or EOF, a caller-set signal is
  # authoritative — honour it.
  [ "$(_classify_heartbeat_exit 0 COMPLETE)" = "signalled" ]
  [ "$(_classify_heartbeat_exit 1 ROTATE)" = "signalled" ]
  [ "$(_classify_heartbeat_exit 142 DEFER)" = "signalled" ]
}

@test "_classify_heartbeat_exit: rc>128 with empty signal → timeout" {
  # read -t returns 128+signal-number on timeout; bash typically uses
  # SIGALRM-ish values in the 129..142 range.
  [ "$(_classify_heartbeat_exit 142 '')" = "timeout" ]
  [ "$(_classify_heartbeat_exit 129 '')" = "timeout" ]
}

@test "_classify_heartbeat_exit: rc=1 with empty signal → eof (0.3.2)" {
  # EOF on the FIFO. Caller must probe liveness to decide between a
  # clean natural end and a wedged-agent hang.
  [ "$(_classify_heartbeat_exit 1 '')" = "eof" ]
}

@test "_classify_heartbeat_exit: rc=0 with empty signal → eof (0.3.2)" {
  [ "$(_classify_heartbeat_exit 0 '')" = "eof" ]
}

# ---------------------------------------------------------------------------
# _probe_agent_liveness — post-EOF agent-pid probe (0.3.2)
# ---------------------------------------------------------------------------

@test "_probe_agent_liveness: dead pid → clean (0.3.2)" {
  # Spawn then reap a trivial subshell so the pid is guaranteed dead
  # by the time we probe.
  ( sleep 0 ) &
  local pid=$!
  wait "$pid" 2>/dev/null || true
  [ "$(_probe_agent_liveness "$pid" 1)" = "clean" ]
}

@test "_probe_agent_liveness: quickly-exiting pid → clean within grace (0.3.2)" {
  # Agent exits 1s into a 5s grace window — should return "clean"
  # without running the full grace duration.
  ( sleep 1 ) &
  local pid=$!
  local start=$SECONDS
  local result
  result=$(_probe_agent_liveness "$pid" 5)
  local elapsed=$((SECONDS - start))
  wait "$pid" 2>/dev/null || true
  [ "$result" = "clean" ]
  # Must not have waited the full 5s
  [ "$elapsed" -lt 4 ]
}

@test "_probe_agent_liveness: long-running pid → hang (0.3.2)" {
  # Agent still alive after the grace window — should return "hang".
  ( sleep 10 ) &
  local pid=$!
  local result
  result=$(_probe_agent_liveness "$pid" 1)
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$result" = "hang" ]
}

# ---------------------------------------------------------------------------
# Completion Bar guard — refuse COMPLETE when a gate is red (0.3.3)
# ---------------------------------------------------------------------------

@test "_most_recent_gate_exit: no gates dir → empty (0.3.3)" {
  rm -rf "$MOCK_WORKSPACE/.ralph/gates"
  [ -z "$(_most_recent_gate_exit "$MOCK_WORKSPACE")" ]
}

@test "_most_recent_gate_exit: no *-latest.exit files → empty (0.3.3)" {
  # gates dir exists but no breadcrumbs yet (older plugin, or no runs)
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  [ -z "$(_most_recent_gate_exit "$MOCK_WORKSPACE")" ]
}

@test "_most_recent_gate_exit: returns the most-recently-written breadcrumb (0.3.3)" {
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf '1'  >"$MOCK_WORKSPACE/.ralph/gates/basic-latest.exit"
  # Space them in time so mtime ordering is unambiguous
  sleep 1
  printf '0'  >"$MOCK_WORKSPACE/.ralph/gates/final-latest.exit"
  [ "$(_most_recent_gate_exit "$MOCK_WORKSPACE")" = "0" ]

  # Now the basic gate is the more recent one, and it was red
  sleep 1
  printf '42' >"$MOCK_WORKSPACE/.ralph/gates/basic-latest.exit"
  [ "$(_most_recent_gate_exit "$MOCK_WORKSPACE")" = "42" ]
}

@test "_complete_allowed: no breadcrumbs → allow (backward compat) (0.3.3)" {
  # Projects that haven't run a gate (or are on older plugin state) must
  # not regress — allow COMPLETE to proceed.
  rm -rf "$MOCK_WORKSPACE/.ralph/gates"
  _complete_allowed "$MOCK_WORKSPACE"
}

@test "_complete_allowed: green gate → allow (0.3.3)" {
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf '0' >"$MOCK_WORKSPACE/.ralph/gates/final-latest.exit"
  _complete_allowed "$MOCK_WORKSPACE"
}

@test "_complete_allowed: red gate → block (0.3.3)" {
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf '124' >"$MOCK_WORKSPACE/.ralph/gates/final-latest.exit"
  ! _complete_allowed "$MOCK_WORKSPACE"
}

@test "_complete_allowed: most recent is what matters, even if older gate was green (0.3.3)" {
  # Exactly the user's failure mode: basic-check passes, but final-check
  # (run later) fails. The agent marks all boxes [x] anyway. Guard must
  # block on the more-recent red gate.
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf '0'   >"$MOCK_WORKSPACE/.ralph/gates/basic-latest.exit"
  sleep 1
  printf '124' >"$MOCK_WORKSPACE/.ralph/gates/final-latest.exit"
  ! _complete_allowed "$MOCK_WORKSPACE"
}

# ---------------------------------------------------------------------------
# _fmt_iter — loop label with per-loop retry suffix (0.3.7)
# ---------------------------------------------------------------------------

@test "_fmt_iter: retry 0 returns bare loop number (0.3.7)" {
  [ "$(_fmt_iter 1 0)" = "1" ]
  [ "$(_fmt_iter 7 0)" = "7" ]
  # Omitted retry arg defaults to 0
  [ "$(_fmt_iter 12)" = "12" ]
}

@test "_fmt_iter: retry > 0 appends dotted suffix (0.3.7)" {
  [ "$(_fmt_iter 1 1)" = "1.1" ]
  [ "$(_fmt_iter 1 3)" = "1.3" ]
  [ "$(_fmt_iter 14 9)" = "14.9" ]
}

# ---------------------------------------------------------------------------
# _probe_pipeline_stages — per-stage classifier for FIFO EOF diagnosis (0.3.7)
# ---------------------------------------------------------------------------

@test "_probe_pipeline_stages: empty subshell reports all dead (0.3.7)" {
  # A subshell that exits immediately — its pid is dead by the time we
  # probe, so it has no children. Should report all stages dead rather
  # than emitting noise.
  ( : ) &
  local pid=$!
  wait "$pid" 2>/dev/null || true
  local out
  out=$(_probe_pipeline_stages "$pid")
  echo "$out" | grep -q "^claude=dead$"
  echo "$out" | grep -q "^jq=dead$"
  echo "$out" | grep -q "^parser=dead$"
}

@test "_probe_pipeline_stages: detects a live jq child (0.3.7)" {
  # Stand up a subshell that runs a real 3-stage pipe (mirroring the
  # production `claude | jq | stream-parser.sh` shape) so every stage is
  # a real child of the subshell. A trailing no-op (`: ;`) plus the pipe
  # structure prevents bash from exec'ing a single command in place of
  # the subshell.
  (
    sleep 2 | jq -c . >/dev/null 2>&1
    :
  ) &
  local pid=$!
  # Wait for bash to fork the pipe stages inside the subshell.
  local tries=0
  while ! pgrep -P "$pid" >/dev/null 2>&1 && [[ $tries -lt 30 ]]; do
    sleep 0.1
    tries=$((tries + 1))
  done

  local out
  out=$(_probe_pipeline_stages "$pid")

  kill -9 "$pid" 2>/dev/null || true
  # Kill any lingering jq child.
  pkill -9 -P "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  echo "$out" | grep -q "^jq=alive$"
}

@test "_probe_pipeline_stages: zombie children report as dead (0.3.10)" {
  # Regression for the 0.3.10 zombie-filter fix. When stream-parser exits
  # immediately after EOF-ing on jq's stdout, its pid enters Z state until
  # the enclosing subshell `wait`s on it. The pre-0.3.10 probe used
  # `pgrep -P` + `ps -o comm=` without checking state and reported the
  # zombie as "alive", which tripped the PARSER EXIT false-positive on
  # otherwise-clean natural ends (FIFO EOF with rc=1). Filtering STAT=Z
  # in the probe gives an accurate picture.
  #
  # We simulate this by backgrounding a subshell whose only child exits
  # immediately. The child becomes a zombie (not reaped until we wait on
  # the outer subshell). During that window the probe must treat it as
  # dead, not alive.
  (
    # Single-line command would be exec-optimized; pipe forces a real
    # child process. That child (`true`) exits instantly and becomes a
    # zombie until the outer subshell (us) reaps it.
    true | sleep 0.5
  ) &
  local pid=$!
  # Wait for the child to spawn and `true` to exit. A short sleep is
  # enough — we want to probe while sleep is still alive and `true` is
  # a zombie.
  sleep 0.1

  local out
  out=$(_probe_pipeline_stages "$pid")

  kill -9 "$pid" 2>/dev/null || true
  pkill -9 -P "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  # The probe should NOT count the zombie `true` as alive. `sleep` is
  # still alive but it isn't claude/jq/parser, so none of those flags
  # should fire — all three should be dead.
  echo "$out" | grep -q "^claude=dead$"
  echo "$out" | grep -q "^jq=dead$"
  echo "$out" | grep -q "^parser=dead$"
}

# ---------------------------------------------------------------------------
# Activity-based heartbeat (0.4.0)
# ---------------------------------------------------------------------------

@test "stream-parser emits HEARTBEAT on log_activity and log_token_status (0.4.0)" {
  # End-to-end check: feeding real tool_result events through the
  # stream-parser produces HEARTBEAT tokens on stdout. The main loop's
  # read-timer reset depends on these, so we guard the contract here.
  # Separate tests in stream-parser.bats cover per-path emission.
  local tmp
  tmp=$(mktemp -d "$BATS_TMPDIR/heartbeat.XXXXXX")
  mkdir -p "$tmp/.ralph"
  local out
  out=$(printf '{"kind":"tool_result","name":"Read","bytes":100,"lines":5,"path":"/tmp/x"}\n' \
    | bash "$SCRIPTS_DIR/stream-parser.sh" "$tmp" 1)
  echo "$out" | grep -q "^HEARTBEAT$"
  rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Read-loop rc capture (0.3.9)
# ---------------------------------------------------------------------------

@test "while-read-rc: documents the bash gotcha (0.3.9)" {
  # Regression anchor for the 0.3.9 false-positive PARSER EXIT fix.
  # Per bash(1): "The exit status of the while and until commands is the
  # exit status of the last command executed in list-2, or zero if none
  # was executed." That means `while read; do :; done < fifo; rc=$?` ALWAYS
  # reports rc=0, regardless of whether read EOF'd (1) or timed out (142).
  # The pre-0.3.9 run_loop used that broken idiom, which made the
  # timeout branch of _classify_heartbeat_exit unreachable and caused
  # every heartbeat-scale quiet period to surface as a PARSER EXIT.
  #
  # This test pins both halves of the story: the broken idiom masks the
  # status, and the new explicit-break idiom preserves it.
  local fifo
  fifo=$(mktemp -u "$BATS_TMPDIR/rc-fifo.XXXXXX")
  mkfifo "$fifo"

  # Writer opens then closes without writing (FIFO EOF, no data).
  ( exec 3>"$fifo"; exec 3>&- ) &
  local writer1=$!

  # Broken idiom — masks EOF as rc=0.
  local bad_rc
  while IFS= read -t 5 -r _line; do :; done <"$fifo"
  bad_rc=$?
  wait "$writer1" 2>/dev/null || true
  [ "$bad_rc" -eq 0 ]

  # Explicit-break idiom — preserves EOF rc=1.
  ( exec 3>"$fifo"; exec 3>&- ) &
  local writer2=$!
  local good_rc=0
  while :; do
    IFS= read -t 5 -r _line || { good_rc=$?; break; }
    :
  done <"$fifo"
  wait "$writer2" 2>/dev/null || true
  [ "$good_rc" -eq 1 ]

  rm -f "$fifo"
}

@test "while-read-rc: explicit-break captures timeout rc (0.3.9)" {
  # Same idiom, timeout path. Writer holds the FIFO open but writes no
  # data — read hits its -t timeout. The exact rc value differs by bash
  # version (bash 5.x returns 128+SIGALRM = 142; bash 3.2 returns 1),
  # so we only assert it is non-zero — the key invariant for the 0.3.9
  # fix is that read's rc is *captured* rather than swallowed to 0 by
  # the while loop's exit-status semantics.
  local fifo
  fifo=$(mktemp -u "$BATS_TMPDIR/rc-timeout-fifo.XXXXXX")
  mkfifo "$fifo"

  ( exec 3>"$fifo"; sleep 5 ) &
  local writer=$!

  local rc=0
  while :; do
    IFS= read -t 1 -r _line || { rc=$?; break; }
    :
  done <"$fifo"

  kill "$writer" 2>/dev/null || true
  wait "$writer" 2>/dev/null || true
  rm -f "$fifo"

  [ "$rc" -ne 0 ]
}

@test "check_task_complete: honors RALPH_TASK_FILE pointing at an acceptance report (0.5.0)" {
  # Simulate the eval loop's handoff: RALPH_TASK_FILE points at the
  # acceptance report; the counter must use that file, not PROMPT.md.
  mkdir -p "$MOCK_WORKSPACE/.ralph"
  cat > "$MOCK_WORKSPACE/.ralph/acceptance-report.md" <<'REPORT'
# Acceptance Report

- [ ] All acceptance criteria met and verified

**Status:** UNVERIFIED

## Gaps

- [ ] gap one
- [ ] gap two
REPORT

  # Also write a PROMPT.md with fully-checked tasks to make sure the
  # counter doesn't fall back to it.
  cat > "$MOCK_WORKSPACE/PROMPT.md" <<'PROMPT'
- [x] a
- [x] b
PROMPT

  export RALPH_TASK_FILE="$MOCK_WORKSPACE/.ralph/acceptance-report.md"
  local status
  status=$(check_task_complete "$MOCK_WORKSPACE")
  # Three unchecked boxes in the report → INCOMPLETE, not COMPLETE.
  [[ "$status" == INCOMPLETE:* ]]
  unset RALPH_TASK_FILE
}

@test "check_task_complete: flips to COMPLETE when every report checkbox is [x] (0.5.0)" {
  mkdir -p "$MOCK_WORKSPACE/.ralph"
  cat > "$MOCK_WORKSPACE/.ralph/acceptance-report.md" <<'REPORT'
# Acceptance Report

- [x] All acceptance criteria met and verified

**Status:** CLEAN

## Gaps

- [x] gap one
- [x] gap two
REPORT

  export RALPH_TASK_FILE="$MOCK_WORKSPACE/.ralph/acceptance-report.md"
  local status
  status=$(check_task_complete "$MOCK_WORKSPACE")
  [ "$status" = "COMPLETE" ]
  unset RALPH_TASK_FILE
}

@test "_resolve_task_file: breadcrumb wins over PROMPT.md (0.5.0)" {
  # This covers the eval loop's handoff AND the new PROMPT.md-mode
  # breadcrumb. If both are present, the breadcrumb is authoritative.
  mkdir -p "$MOCK_WORKSPACE/.ralph"
  echo "$MOCK_WORKSPACE/.ralph/acceptance-report.md" > "$MOCK_WORKSPACE/.ralph/task-file-path"
  echo "- [ ] placeholder" > "$MOCK_WORKSPACE/.ralph/acceptance-report.md"
  echo "- [ ] decoy" > "$MOCK_WORKSPACE/PROMPT.md"

  local got
  got=$(_resolve_task_file "$MOCK_WORKSPACE")
  [ "$got" = "$MOCK_WORKSPACE/.ralph/acceptance-report.md" ]
}

@test "_probe_pipeline_stages: detects a live stream-parser child by args (0.3.7)" {
  # A bash wrapper whose args contain "stream-parser.sh" should classify
  # as parser=alive even when comm is just "bash". Use a real pipe so the
  # bash stage is a child of the subshell, not exec'd in place.
  local fake_script
  fake_script=$(mktemp "$BATS_TMPDIR/stream-parser.sh.XXXXXX")
  cat >"$fake_script" <<'EOF'
#!/usr/bin/env bash
# Fake stream-parser that just sleeps so the probe finds it alive.
sleep 5
EOF
  chmod +x "$fake_script"

  (
    sleep 2 | bash "$fake_script" /workspace 1
    :
  ) &
  local pid=$!
  local tries=0
  while ! pgrep -P "$pid" >/dev/null 2>&1 && [[ $tries -lt 30 ]]; do
    sleep 0.1
    tries=$((tries + 1))
  done

  local out
  out=$(_probe_pipeline_stages "$pid")

  kill -9 "$pid" 2>/dev/null || true
  pkill -9 -P "$pid" 2>/dev/null || true
  pkill -9 -f "$fake_script" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$fake_script"

  echo "$out" | grep -q "^parser=alive$"
}

# -----------------------------------------------------------------------------
# 0.6.3: terminology + flow-vs-loop driver semantics
#
# The driver renamed `iteration` → `loop` in code and log messages. The
# `--iterations` flag and `MAX_ITERATIONS` / `RALPH_MAX_ITERATIONS` env vars
# are kept as deprecated aliases for one minor release. The framing prompt
# is now flow-oriented: "loop", not "iteration N of an autonomous loop";
# the agent is told ending the turn between commits costs 10–30k tokens.
# -----------------------------------------------------------------------------

@test "MAX_LOOPS env var sets the loop ceiling (0.6.3)" {
  # Re-source after setting the env to exercise the cascade in
  # ralph-common.sh. Use a subshell so the rest of the test file is
  # unaffected.
  (
    unset MAX_LOOPS RALPH_MAX_LOOPS MAX_ITERATIONS RALPH_MAX_ITERATIONS
    export MAX_LOOPS=42
    # shellcheck disable=SC1090
    source "$SCRIPTS_DIR/ralph-common.sh"
    [ "$MAX_LOOPS" = "42" ]
  )
}

@test "RALPH_MAX_LOOPS is honored as a fallback (0.6.3)" {
  (
    unset MAX_LOOPS RALPH_MAX_LOOPS MAX_ITERATIONS RALPH_MAX_ITERATIONS
    export RALPH_MAX_LOOPS=17
    # shellcheck disable=SC1090
    source "$SCRIPTS_DIR/ralph-common.sh"
    [ "$MAX_LOOPS" = "17" ]
  )
}

@test "MAX_ITERATIONS is honored as a deprecated alias for MAX_LOOPS (0.6.3 compat)" {
  (
    unset MAX_LOOPS RALPH_MAX_LOOPS MAX_ITERATIONS RALPH_MAX_ITERATIONS
    export MAX_ITERATIONS=11
    # shellcheck disable=SC1090
    source "$SCRIPTS_DIR/ralph-common.sh"
    [ "$MAX_LOOPS" = "11" ]
  )
}

@test "RALPH_MAX_ITERATIONS is honored as a deprecated alias for MAX_LOOPS (0.6.3 compat)" {
  (
    unset MAX_LOOPS RALPH_MAX_LOOPS MAX_ITERATIONS RALPH_MAX_ITERATIONS
    export RALPH_MAX_ITERATIONS=9
    # shellcheck disable=SC1090
    source "$SCRIPTS_DIR/ralph-common.sh"
    [ "$MAX_LOOPS" = "9" ]
  )
}

@test "MAX_LOOPS default is 20 when no env var is set (0.6.3)" {
  (
    unset MAX_LOOPS RALPH_MAX_LOOPS MAX_ITERATIONS RALPH_MAX_ITERATIONS
    # shellcheck disable=SC1090
    source "$SCRIPTS_DIR/ralph-common.sh"
    [ "$MAX_LOOPS" = "20" ]
  )
}

@test "build_prompt framing uses flow-not-iteration language (0.6.3)" {
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  # Header reads "Ralph Loop 1", not "Ralph Iteration 1".
  echo "$output" | grep -q "^# Ralph Loop 1"
  ! echo "$output" | grep -q "^# Ralph Iteration"

  # The framing names the four real stop conditions and explicitly tells
  # the agent that ending its turn between commits is the wrong move.
  echo "$output" | grep -q "ALL_TASKS_DONE"
  echo "$output" | grep -q "GUTTER"
  echo "$output" | grep -q "WARN"
  echo "$output" | grep -q "stop-requested"
  echo "$output" | grep -qi "cold-start tax"
}

@test "run_iteration is renamed to run_loop (0.6.3)" {
  # Both names should NOT exist; only the new name. Catches accidental
  # leftover function references after the rename.
  declare -F run_loop >/dev/null
  ! declare -F run_iteration >/dev/null
}
