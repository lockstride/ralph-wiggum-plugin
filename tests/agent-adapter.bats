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

# ---------------------------------------------------------------------------
# Sidechain LABELLING (0.23.0).
#
# 0.18.0 suppressed a Task sub-agent's init and result. Its tool traffic still
# flowed through unlabelled, so the parser could not tell delegated work from
# the orchestrator's own and charged both to the rotation budget. The filter now
# stamps `sidechain` on assistant text and on tool_use / tool_result so
# stream-parser.sh can account them apart (see SIDECHAIN_CHARS).
# ---------------------------------------------------------------------------

# Return the `sidechain` field of the canonical event(s) for one native event.
_claude_sidechain() { # $1=native JSON event
  printf '%s\n' "$1" | jq -n -c -f "$CLAUDE_FILTER" | jq -rc '.sidechain' 2>/dev/null || true
}

@test "claude: top-level tool_use is not marked sidechain (0.23.0)" {
  run _claude_sidechain '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/a.ts"}}]}}'
  [ "$output" = "false" ]
}

@test "claude: sub-agent tool_use (parent_tool_use_id) is marked sidechain (0.23.0)" {
  run _claude_sidechain '{"type":"assistant","parent_tool_use_id":"toolu_1","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/a.ts"}}]}}'
  [ "$output" = "true" ]
}

@test "claude: sub-agent assistant text (isSidechain) is marked sidechain (0.23.0)" {
  run _claude_sidechain '{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"thinking"}]}}'
  [ "$output" = "true" ]
}

@test "claude: sub-agent tool_result is marked sidechain (0.23.0)" {
  # tool_result arrives on a `user` event; the marker rides that envelope.
  run _claude_sidechain '{"type":"user","isSidechain":true,"message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"payload"}]}}'
  [ "$output" = "true" ]
}

@test "claude: top-level tool_result is not marked sidechain (0.23.0 regression guard)" {
  run _claude_sidechain '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"payload"}]}}'
  [ "$output" = "false" ]
}

@test "claude: labelling a sub-agent event does not suppress it (0.23.0)" {
  # Delegated work must stay VISIBLE — 0.18.0 drops only init/result.
  run bash -c 'printf "%s\n" "{\"type\":\"user\",\"isSidechain\":true,\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t1\",\"content\":\"payload\"}]}}" | jq -n -c -f "'"$CLAUDE_FILTER"'" | jq -rc ".kind"'
  [ "$output" = "tool_result" ]
}

# ---------------------------------------------------------------------------
# 0.24.0: the CLI's own Bash timeout is not a command verdict. Claude's
# stream-json exposes only is_error, which flattened a cut-off command to a 1
# indistinguishable from "the command failed" — so stream-parser could not tell
# a deliberate interrupt harness from a real failure and logged both as SHELL
# FAIL (cur-71, 15:33:02 / 15:36:41). Surface 124 instead.
# ---------------------------------------------------------------------------

@test "claude: a tool timeout maps to 124, not a flattened 1 (0.24.0)" {
  run _claude_exit 'timeout -k 3 12 bash -c "BF"' true 'Command timed out after 2m 0.0s'
  [ "$output" = "124" ]
}

@test "claude: the timeout message is matched case-insensitively (0.24.0)" {
  run _claude_exit 'uv run curve backfill' true 'Error: command timed out after 120s'
  [ "$output" = "124" ]
}

@test "claude: a non-timeout is_error still maps to 1 (0.24.0 regression guard)" {
  run _claude_exit 'pnpm build' true 'error TS2345: Argument of type ...'
  [ "$output" = "1" ]
}

@test "claude: a successful command is still 0 (0.24.0 regression guard)" {
  run _claude_exit 'pnpm build' false 'Build succeeded'
  [ "$output" = "0" ]
}

# --- 0.24.1: the auto-wrapped gate carries no "gate-run" in its command ---
# ralph-guard rewrites via the PreToolUse hook's updatedInput, so the transcript
# keeps what the model typed (`pnpm all-check`). Keying the gate branch on the
# command text therefore missed the NORMAL path entirely: every waiter return
# flattened to a false SHELL FAIL and walked the GUTTER stuck-counter.

@test "claude: auto-wrapped gate still-running normalizes to 0 (0.24.1)" {
  run _claude_exit 'pnpm all-check' true '=== GATE full STILL RUNNING pid=39645 waited=570s (gate timeout 1200s) log=x ===
Re-run the exact same command to keep waiting.'
  [ "$output" = "0" ]
}

@test "claude: auto-wrapped gate recovers the real verdict from the marker (0.24.1)" {
  run _claude_exit 'pnpm all-check' true '=== GATE full exit=1 duration=180s log=x latest=y ==='
  [ "$output" = "1" ]
}

@test "claude: auto-wrapped gate timeout surfaces 124, not a flattened 1 (0.24.1)" {
  run _claude_exit 'pnpm all-check' true '=== GATE full exit=124 duration=1211s log=x latest=y ==='
  [ "$output" = "124" ]
}

@test "claude: auto-wrapped detached launch is not a failure (0.24.1)" {
  run _claude_exit 'pnpm basic-check' true 'gate-run.sh: basic gate launched detached (runner pid=1, ts=2, gate timeout 1200s)'
  [ "$output" = "0" ]
}

@test "claude: auto-wrapped runner-died is not counted as a command failure (0.24.1)" {
  run _claude_exit 'pnpm all-check' true '=== GATE full RUNNER DIED without a verdict (pid=9) log=x ==='
  [ "$output" = "0" ]
}

@test "claude: a plain failing command is still a failure (0.24.1)" {
  # The marker test must not swallow ordinary non-gate failures.
  run _claude_exit 'pnpm all-check' true 'Error: something broke'
  [ "$output" = "1" ]
}

# --- 0.26.0: API-reported context, and guard denials ------------------------
# The byte count the parser keeps never sees the system prompt, retained
# thinking, or any tool call's input, so rotation keys on the context the API
# reports for each main-chain request. A denial by ralph-guard.sh is marked so
# the parser can log it as one: the command never ran.

# Normalize one assistant event carrying $1 as message.usage, with $2 extra
# top-level fields (e.g. a sub-agent's parent_tool_use_id).
_claude_usage() { # $1=usage json, $2=extra top-level json object
  local extra="${2:-}"
  [[ -n "$extra" ]] || extra='{}'
  jq -cn --argjson u "$1" --argjson extra "$extra" \
    '{type:"assistant",message:{id:"m1",usage:$u,content:[{type:"text",text:"hi"}]}} + $extra' |
    jq -n -c -f "$CLAUDE_FILTER" | jq -rc 'select(.kind=="usage").context_tokens'
}

@test "claude: main-chain usage reports every input token as the context (0.26.0)" {
  run _claude_usage '{"input_tokens":2,"cache_creation_input_tokens":1455,"cache_read_input_tokens":816546,"output_tokens":881}'
  [ "$output" = "818003" ]
}

@test "claude: a sub-agent's usage is its own window, not this session's (0.26.0)" {
  run _claude_usage '{"input_tokens":5,"cache_read_input_tokens":90000}' '{"parent_tool_use_id":"toolu_1"}'
  [ -z "$output" ]
}

@test "claude: an assistant event without usage reports nothing (0.26.0)" {
  run bash -c "jq -cn '{type:\"assistant\",message:{content:[{type:\"text\",text:\"hi\"}]}}' |
    jq -n -c -f '$CLAUDE_FILTER' | jq -rc 'select(.kind==\"usage\")'"
  [ -z "$output" ]
}

# Normalize a Bash tool_use + its result and print the tool_result event.
_claude_result() { # $1=cmd $2=is_error $3=result text
  {
    jq -cn --arg cmd "$1" \
      '{type:"assistant",message:{content:[{type:"tool_use",id:"t1",name:"Bash",input:{command:$cmd}}]}}'
    jq -cn --argjson err "$2" --arg t "$3" \
      '{type:"user",message:{content:[{type:"tool_result",tool_use_id:"t1",is_error:$err,content:$t}]}}'
  } | jq -n -c -f "$CLAUDE_FILTER" | jq -c 'select(.kind=="tool_result")'
}

@test "claude: a guard denial is marked denied, with the reason unprefixed (0.26.0)" {
  run _claude_result "rm -rf .ralph/" true "[ralph-guard] State tampering denied: cannot delete .ralph/"
  echo "$output" | jq -e '.denied == true'
  echo "$output" | jq -e '.deny_reason == "State tampering denied: cannot delete .ralph/"'
}

@test "claude: a command that ran and failed is not a denial (0.26.0)" {
  run _claude_result "pnpm test" true "Error: 3 tests failed"
  echo "$output" | jq -e '.denied == false'
  echo "$output" | jq -e '.exit_code == 1'
}

@test "claude: the guard marker in successful output is not a denial (0.26.0)" {
  # A denial is an error result; printing the marker (e.g. grepping a log for
  # it) is not one.
  run _claude_result "grep ralph-guard notes.txt" false "[ralph-guard] seen in a note"
  echo "$output" | jq -e '.denied == false'
}

# --- 0.26.1: a write is sized by what it wrote --------------------------------
# A Write/Edit-family result is only "File created successfully at: …", so
# sizing by it logged every write as "1 lines, 0KB". The text written is in the
# call's input.

# Normalize one tool_use ($1 = name, $2 = input json) and its plain result,
# and print "<bytes> <lines>" from the tool_result event.
_claude_size() {
  {
    jq -cn --arg n "$1" --argjson in "$2" \
      '{type:"assistant",message:{content:[{type:"tool_use",id:"t1",name:$n,input:$in}]}}'
    jq -cn '{type:"user",message:{content:[{type:"tool_result",tool_use_id:"t1",content:"File created successfully at: /x"}]}}'
  } | jq -n -c -f "$CLAUDE_FILTER" | jq -r 'select(.kind=="tool_result") | "\(.bytes) \(.lines)"'
}

@test "claude: a Write is sized by the content it wrote (0.26.1)" {
  run _claude_size Write '{"file_path":"/x/install.sh","content":"#!/bin/sh\necho hi\nexit 0\n"}'
  [ "$output" = "25 3" ]
}

@test "claude: an Edit is sized by its replacement text (0.26.1)" {
  run _claude_size Edit '{"file_path":"/x/a.ts","old_string":"a","new_string":"b\nc"}'
  [ "$output" = "3 2" ]
}

@test "claude: a MultiEdit is sized by all of its replacements (0.26.1)" {
  run _claude_size MultiEdit '{"file_path":"/x/b.ts","edits":[{"old_string":"x","new_string":"y\n"},{"old_string":"z","new_string":"ww"}]}'
  [ "$output" = "4 2" ]
}

@test "claude: a NotebookEdit is sized by its new cell source (0.26.1)" {
  run _claude_size NotebookEdit '{"notebook_path":"/x/n.ipynb","new_source":"print(1)"}'
  [ "$output" = "8 1" ]
}

@test "claude: an empty Write is zero lines, zero bytes (0.26.1)" {
  run _claude_size Write '{"file_path":"/x/empty.txt","content":""}'
  [ "$output" = "0 0" ]
}

@test "claude: a Read is still sized by what came back (0.26.1 regression guard)" {
  run bash -c "{
    jq -cn '{type:\"assistant\",message:{content:[{type:\"tool_use\",id:\"t1\",name:\"Read\",input:{file_path:\"/x/r.ts\"}}]}}'
    jq -cn '{type:\"user\",message:{content:[{type:\"tool_result\",tool_use_id:\"t1\",content:\"1\\tone\\n2\\ttwo\\n3\\tthree\"}]}}'
  } | jq -n -c -f '$CLAUDE_FILTER' | jq -r 'select(.kind==\"tool_result\") | \"\\(.bytes) \\(.lines)\"'"
  [ "$output" = "19 3" ]
}

# --- 0.26.2: no event can end the stream --------------------------------------
# jq ends the whole stream on a runtime error, and the parser then reads EOF
# while the agent is still working. Content given as a plain string is a shape
# the API allows; anything the filter still cannot read is skipped and reported.

# Run the Claude filter over the given JSON lines; print the normalized events.
_claude_stream() {
  printf '%s\n' "$@" | jq -n -c -f "$CLAUDE_FILTER"
}

@test "claude: a user message with plain-string content does not end the stream (0.26.2)" {
  run _claude_stream \
    '{"type":"user","message":{"role":"user","content":"Invoke the linear-accept skill"},"parent_tool_use_id":"toolu_1"}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}' \
    '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"a"}]}}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -se 'map(select(.kind=="tool_result" and .cmd=="ls")) | length == 1'
  ! echo "$output" | grep -q adapter_error
}

@test "claude: assistant plain-string content is assistant text (0.26.2)" {
  run _claude_stream '{"type":"assistant","message":{"content":"<ralph>COMPLETE</ralph>"}}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'select(.kind=="assistant_text") | .text == "<ralph>COMPLETE</ralph>"'
}

@test "claude: a content entry that is not a block is skipped, not fatal (0.26.2)" {
  run _claude_stream \
    '{"type":"assistant","message":{"content":["stray",{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}' \
    '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"a"}]}}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -se 'map(select(.kind=="tool_result" and .cmd=="ls")) | length == 1'
}

@test "claude: an unreadable event is reported and the stream carries on (0.26.2)" {
  run _claude_stream '42' '{"type":"system","subtype":"init","model":"claude-opus-5"}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -se '.[0].kind == "adapter_error" and .[1].kind == "system"'
}

@test "cursor: an unreadable event is reported and the stream carries on (0.26.2)" {
  run bash -c "printf '%s\n' '42' '{\"type\":\"system\",\"subtype\":\"init\",\"model\":\"composer-2\"}' |
    jq -n -c -f '$CURSOR_FILTER'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -se '.[0].kind == "adapter_error" and .[1].kind == "system"'
}
