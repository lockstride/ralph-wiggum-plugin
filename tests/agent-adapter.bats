#!/usr/bin/env bats
# Behavioral tests for agent-adapter.sh — the stream-json normalization filter
# that feeds the stream-parser.
#
# Focus (0.16.1): gate-run runs DETACHED (0.16.0), so its waiter's transport
# exit — 75 (still-running) or 70 (runner died) — is NOT the gate verdict. The
# Claude branch receives only `is_error` (a boolean), so a still-running 75
# would flatten to 1 and be miscounted as a false SHELL FAIL feeding the GUTTER
# stuck-detector. The filter must instead recover the real verdict from
# gate-run's own `=== GATE <label> exit=<N>` marker and map transport states to
# 0 (not a failure). cursor-agent already carries the real exitCode, so only its
# transport codes need neutralizing.

load test_helper

setup() {
  source "$SCRIPTS_DIR/agent-adapter.sh"
  CLAUDE_FILTER="$BATS_TEST_TMPDIR/claude.jq"
  CURSOR_FILTER="$BATS_TEST_TMPDIR/cursor.jq"
  agent_normalize_filter claude >"$CLAUDE_FILTER"
  agent_normalize_filter cursor-agent >"$CURSOR_FILTER"
}

# The literal command string an agent invokes (the $(cat …) stays unexpanded).
GATE='bash "$(cat .ralph/gate-runner)" final pnpm all-check:no-cache'

# Claude branch: emit assistant(tool_use)+user(tool_result) and return the
# normalized exit_code the filter assigns to that Shell result.
_claude_exit() { # $1=cmd $2=is_error(true|false) $3=result_text
  {
    jq -cn --arg cmd "$1" \
      '{type:"assistant",message:{content:[{type:"tool_use",id:"t1",name:"Bash",input:{command:$cmd}}]}}'
    jq -cn --argjson err "$2" --arg t "$3" \
      '{type:"user",message:{content:[{type:"tool_result",tool_use_id:"t1",is_error:$err,content:$t}]}}'
  } | jq -n -c -f "$CLAUDE_FILTER" | jq -rc 'select(.kind=="tool_result").exit_code'
}

# cursor-agent branch: one completed shellToolCall event → normalized exit_code.
_cursor_exit() { # $1=cmd $2=exitCode $3=stdout
  jq -cn --arg cmd "$1" --argjson ec "$2" --arg o "$3" \
    '{type:"tool_call",subtype:"completed",tool_call:{shellToolCall:{args:{command:$cmd},result:{exitCode:$ec,stdout:$o,stderr:""}}}}' |
    jq -n -c -f "$CURSOR_FILTER" | jq -rc 'select(.kind=="tool_result").exit_code'
}

# --- Claude branch: the core fix -------------------------------------------

@test "claude: gate still-running (75→is_error) normalizes to 0, not a failure (0.16.1)" {
  run _claude_exit "$GATE" true '=== GATE final STILL RUNNING pid=9 waited=570s log=x ===
Re-run the exact same command; verdict lands in .ralph/gates/final-T.exit'
  [ "$output" = "0" ]
}

@test "claude: gate completed pass recovers exit 0 from the marker (0.16.1)" {
  run _claude_exit "$GATE" false '=== GATE final exit=0 duration=742s log=x latest=y ===
=== END GATE ==='
  [ "$output" = "0" ]
}

@test "claude: gate completed FAIL recovers the real exit 1 from the marker (0.16.1)" {
  run _claude_exit "$GATE" true '=== GATE final exit=1 duration=300s log=x ===
FAIL some.spec.ts'
  [ "$output" = "1" ]
}

@test "claude: gate timeout recovers exit 124, not a flattened 1 (0.16.1)" {
  run _claude_exit "$GATE" true '=== GATE final exit=124 duration=1200s log=x ==='
  [ "$output" = "124" ]
}

@test "claude: gate runner-died (70) normalizes to 0, a transport state not a failure (0.16.1)" {
  run _claude_exit "$GATE" true '=== GATE final RUNNER DIED without a verdict (pid=9) ===
Re-run the same command to relaunch it fresh.'
  [ "$output" = "0" ]
}

@test "claude: gate label containing a digit (e2e) is matched by the marker (0.16.1)" {
  run _claude_exit 'bash gate-run.sh e2e nx e2e' false '=== GATE e2e exit=0 duration=100s log=x ==='
  [ "$output" = "0" ]
}

@test "claude: non-gate failing command still maps is_error→1 (0.16.1 regression guard)" {
  run _claude_exit 'pnpm exec tsc --noEmit' true 'src/x.ts(3,1): error TS2304: x'
  [ "$output" = "1" ]
}

@test "claude: non-gate success still maps to 0 (0.16.1 regression guard)" {
  run _claude_exit 'ls -la' false 'total 8'
  [ "$output" = "0" ]
}

# --- cursor-agent branch: transport neutralization only --------------------

@test "cursor: gate still-running (real 75) normalizes to 0 (0.16.1)" {
  run _cursor_exit "$GATE" 75 '=== GATE final STILL RUNNING pid=9 ==='
  [ "$output" = "0" ]
}

@test "cursor: gate runner-died (real 70) normalizes to 0 (0.16.1)" {
  run _cursor_exit "$GATE" 70 '=== GATE final RUNNER DIED ==='
  [ "$output" = "0" ]
}

@test "cursor: gate completed FAIL keeps its real exit 1 (0.16.1)" {
  run _cursor_exit "$GATE" 1 '=== GATE final exit=1 duration=300s ==='
  [ "$output" = "1" ]
}

@test "cursor: non-gate command keeps its real exit code unchanged (0.16.1 regression guard)" {
  run _cursor_exit 'some-tool --run' 75 'boom'
  [ "$output" = "75" ]
}

# --- 0.18.0: Task sub-agent (sidechain) event suppression ------------------
#
# A Task sub-agent's stream events carry parent_tool_use_id (and/or
# isSidechain). Their init/result must NOT be normalized into system/result
# kinds, or the parser logs a spurious second SESSION START/END per sub-agent
# (observed run 140038). Top-level events (both markers absent) still pass.

# Return the canonical kind(s) the claude filter emits for one native event.
_claude_kind() { # $1=native JSON event
  printf '%s\n' "$1" | jq -n -c -f "$CLAUDE_FILTER" | jq -rc '.kind' 2>/dev/null || true
}

@test "claude: top-level init normalizes to a system event (0.18.0)" {
  run _claude_kind '{"type":"system","subtype":"init","model":"claude-opus-4-8"}'
  [ "$output" = "system" ]
}

@test "claude: sub-agent init (parent_tool_use_id) is suppressed (0.18.0)" {
  run _claude_kind '{"type":"system","subtype":"init","model":"x","parent_tool_use_id":"toolu_1"}'
  [ -z "$output" ]
}

@test "claude: top-level result normalizes to a result event (0.18.0)" {
  run _claude_kind '{"type":"result","duration_ms":1234}'
  [ "$output" = "result" ]
}

@test "claude: sub-agent result (isSidechain) is suppressed (0.18.0)" {
  run _claude_kind '{"type":"result","duration_ms":50,"isSidechain":true}'
  [ -z "$output" ]
}
