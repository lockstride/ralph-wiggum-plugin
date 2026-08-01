#!/usr/bin/env bats
# Behavioral tests for ralph-supervise.sh
#
# The supervisor's whole job is deciding what a finished run *was*, so the
# coverage here is concentrated on _classify. Every false-positive case below
# is a bug that actually shipped: activity.log interleaves the driver's own
# terminal markers with agent-authored text (shell command source, gate `cmd=`
# strings), and a substring match cannot tell them apart.

load test_helper

SUPERVISE_SCRIPT="$PLUGIN_ROOT/shared-scripts/ralph-supervise.sh"

setup() {
  create_mock_workspace
  workspace="$MOCK_WORKSPACE"
  ralph_dir="$MOCK_WORKSPACE/.ralph"
  mkdir -p "$ralph_dir"
  # Load the helpers without entering the supervise loop.
  RALPH_SUPERVISE_LIB_ONLY=1 source "$SUPERVISE_SCRIPT" "$MOCK_WORKSPACE" test-session "$(printf 'true' | base64)"
}

teardown() {
  rm -rf "$MOCK_WORKSPACE"
}

# Helper: write activity.log lines, newest last
_log() {
  printf '%s\n' "$@" >"$ralph_dir/activity.log"
}

# ── rc=0: stopped vs complete ──────────────────────────────────────────────

@test "classify: genuine operator stop is 'stopped'" {
  _log '[02:53:24] LOOP 1.1 END — 🛑 STOP REQUESTED (user; no handoff written this iteration)'
  [ "$(_classify 0 0)" = "stopped" ]
}

@test "classify: graceful yield honoring stop-requested is 'stopped'" {
  _log '[02:53:24] LOOP 1 END — 🤝 GRACEFUL YIELD (stop-requested honored; handoff written)'
  [ "$(_classify 0 0)" = "stopped" ]
}

@test "classify: graceful yield on a context warning is NOT a stop" {
  _log '[02:53:24] LOOP 1 END — 🤝 GRACEFUL YIELD (context-warning honored; handoff written; 3 remaining)'
  [ "$(_classify 0 0)" = "complete" ]
}

@test "classify: an agent probe echoing STOP REQUESTED is not a stop" {
  # Regression: the agent runs `ls .ralph/stop-requested … && echo "STOP
  # REQUESTED"` to check for a stop file. stream-parser logs the command
  # SOURCE, so a substring match read a clean run as operator-stopped and the
  # supervisor refused to resume a run nobody stopped.
  _log \
    '[09:34:25] 🟢 SHELL ls .ralph/stop-requested 2>/dev/null && echo "STOP REQUESTED" || echo "no stop" → exit 0' \
    '[09:41:55] LOOP 2 END — ✅ COMPLETE (Tasks: 3/3 complete)'
  [ "$(_classify 0 0)" = "complete" ]
}

@test "classify: a multi-line command continuation cannot forge a marker" {
  # Continuation lines carry no timestamp, so they can never satisfy the anchor.
  _log \
    '[08:53:11] 🟢 SHELL cd /repo' \
    'echo "LOOP 1 END — 🛑 STOP REQUESTED (user)"' \
    '[09:41:55] LOOP 2 END — ✅ COMPLETE'
  [ "$(_classify 0 0)" = "complete" ]
}

@test "classify: a stop from a PREVIOUS run is fenced out by start_line" {
  # Regression: a resume whose inner command exits quickly re-read the prior
  # run's terminal line and reported 'stopped', pinning finished runs down.
  _log '[02:53:21] LOOP 1 END — 🛑 STOP REQUESTED (user)'
  local mark
  mark=$(_log_lines)
  printf '%s\n' '[08:30:00] LOOP 2 END — ✅ COMPLETE' >>"$ralph_dir/activity.log"
  [ "$(_classify 0 "$mark")" = "complete" ]
}

@test "classify: a stop within the CURRENT run is still detected past the fence" {
  _log '[02:53:21] LOOP 1 END — ✅ COMPLETE'
  local mark
  mark=$(_log_lines)
  printf '%s\n' '[08:40:00] LOOP 2 END — 🛑 STOP REQUESTED (user)' >>"$ralph_dir/activity.log"
  [ "$(_classify 0 "$mark")" = "stopped" ]
}

# ── rc!=0: stall vs gutter vs error ────────────────────────────────────────

@test "classify: genuine gutter is 'gutter'" {
  _log '[09:09:17] LOOP 4 END — 🚨 GUTTER (unsatisfiable-completion)'
  [ "$(_classify 1 0)" = "gutter" ]
}

@test "classify: a RALPH STOP halt other than STALL is 'gutter'" {
  _log '[09:09:17] RALPH STOP — 🚨 UNSATISFIABLE COMPLETION BAR: blocked 2x in a row'
  [ "$(_classify 1 0)" = "gutter" ]
}

@test "classify: genuine stall is 'stall'" {
  _log '[09:09:17] RALPH STOP — 🚨 STALL: 10 consecutive empty/deferred loops'
  [ "$(_classify 1 0)" = "stall" ]
}

@test "classify: COMPLETE BLOCKED advice text mentioning GUTTER is not a gutter" {
  # The driver's own COMPLETE-BLOCKED line tells the agent to "escalate via
  # <ralph>GUTTER</ralph>" — instruction text, not a verdict.
  _log '[09:07:52] 🛑 COMPLETE BLOCKED — all tasks checked but the final gate has not run yet. Agent must satisfy the bar (or escalate via <ralph>GUTTER</ralph>) before the loop can exit.'
  [ "$(_classify 1 0)" = "error" ]
}

@test "classify: the supervisor's own prior breadcrumb is not a verdict" {
  _log '[09:09:17] 🔔 SUPERVISOR: GUTTER (unclassified) — needs attention'
  [ "$(_classify 1 0)" = "error" ]
}

@test "classify: an unmarked non-zero exit is 'error'" {
  _log '[09:09:17] 🟢 SESSION END: 21319ms, ~4796 tokens used'
  [ "$(_classify 1 0)" = "error" ]
}

@test "classify: a missing activity.log does not crash" {
  rm -f "$ralph_dir/activity.log"
  [ "$(_classify 0 0)" = "complete" ]
  [ "$(_classify 1 0)" = "error" ]
}

# ── recoverable-reason allowlist ───────────────────────────────────────────

@test "is_recoverable: the default allowlist matches concurrent-writer only" {
  _is_recoverable "concurrent-writer"
  ! _is_recoverable "unsatisfiable-completion"
  ! _is_recoverable ""
}

@test "is_recoverable: RALPH_SUPERVISE_RECOVERABLE accepts a comma list" {
  recoverable="concurrent-writer,rotation-zombie"
  _is_recoverable "rotation-zombie"
  _is_recoverable "concurrent-writer"
  ! _is_recoverable "stall"
}

# ── end-to-end: the wrapper actually runs its command ──────────────────────

@test "supervisor runs the decoded command and reports COMPLETE" {
  local marker="$MOCK_WORKSPACE/ran.txt"
  local cmd b64
  cmd="printf '[10:00:00] LOOP 1 END — ✅ COMPLETE\n' >>'$ralph_dir/activity.log'; touch '$marker'"
  b64=$(printf '%s' "$cmd" | base64 | tr -d '\n')

  run env RALPH_SUPERVISE_NOTIFY=0 bash "$SUPERVISE_SCRIPT" "$MOCK_WORKSPACE" test-session "$b64"

  [ "$status" -eq 0 ]
  [ -f "$marker" ]
  grep -q "SUPERVISOR: run COMPLETE" "$ralph_dir/activity.log"
}

@test "supervisor surfaces a non-recoverable gutter as exit 1" {
  local cmd b64
  cmd="printf '[10:00:00] LOOP 1 END — 🚨 GUTTER\n' >>'$ralph_dir/activity.log'; exit 1"
  b64=$(printf '%s' "$cmd" | base64 | tr -d '\n')

  run env RALPH_SUPERVISE_NOTIFY=0 bash "$SUPERVISE_SCRIPT" "$MOCK_WORKSPACE" test-session "$b64"

  [ "$status" -eq 1 ]
  grep -q "SUPERVISOR: GUTTER" "$ralph_dir/activity.log"
}

@test "supervisor rejects an undecodable command with exit 64" {
  run env RALPH_SUPERVISE_NOTIFY=0 bash "$SUPERVISE_SCRIPT" "$MOCK_WORKSPACE" test-session ""
  [ "$status" -ne 0 ]
}
