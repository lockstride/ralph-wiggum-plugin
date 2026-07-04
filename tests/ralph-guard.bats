#!/usr/bin/env bats
# Behavioral tests for ralph-guard.sh (PreToolUse hook)

load test_helper

GUARD="$SCRIPTS_DIR/ralph-guard.sh"

setup() {
  create_mock_workspace
  cd "$MOCK_WORKSPACE" || fail "cannot cd to workspace"
  # Compute state dir the same way the guard does
  local ws_real
  ws_real=$(cd "$MOCK_WORKSPACE" && pwd -P)
  local ws_hash
  ws_hash=$(echo -n "$ws_real" | shasum -a 256 | cut -d' ' -f1)
  STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ralph/$ws_hash"
  mkdir -p "$STATE_DIR"
}

teardown() {
  rm -rf "$MOCK_WORKSPACE"
  rm -rf "$STATE_DIR"
}

_run_guard() {
  local tool_name="$1"
  shift
  local json
  if [[ "$tool_name" == "Bash" ]]; then
    json=$(jq -n --arg tn "$tool_name" --arg cmd "$1" \
      '{tool_name: $tn, tool_input: {command: $cmd}}')
  else
    json=$(jq -n --arg tn "$tool_name" --arg fp "$1" \
      '{tool_name: $tn, tool_input: {file_path: $fp}}')
  fi
  echo "$json" | bash "$GUARD"
}

# --- Pass-through when not in Ralph context ---

@test "allows everything when RALPH_AGENT_GUARD is unset" {
  unset RALPH_AGENT_GUARD
  run _run_guard Bash "rm -rf .ralph/"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "enforces rules when RALPH_AGENT_GUARD is set" {
  export RALPH_AGENT_GUARD=1
  run _run_guard Bash "rm -rf .ralph/"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "pwd fallback records per-label gate timestamp without RALPH_WORKSPACE set" {
  unset RALPH_WORKSPACE
  echo "$(date +%s)" > "$STATE_DIR/last-write-ts"
  rm -f "$STATE_DIR"/last-gate-ts*
  _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh basic pnpm test"
  [ -f "$STATE_DIR/last-gate-ts.basic" ]
  local ts
  ts=$(cat "$STATE_DIR/last-gate-ts.basic")
  [[ "$ts" =~ ^[0-9]+$ ]]
}

# --- State-tampering denial ---

@test "blocks rm -rf .ralph/" {
  run _run_guard Bash "rm -rf .ralph/"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("State tampering")'
}

@test "blocks rm -r .ralph/gates" {
  run _run_guard Bash "rm -r .ralph/gates"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "blocks find .ralph -delete" {
  run _run_guard Bash "find .ralph -name '*.log' -delete"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

# --- Hand-forged gate breadcrumb denial (0.14.11) ---

@test "blocks redirect into .ralph/gates/ (forged exit breadcrumb)" {
  run _run_guard Bash "echo 0 > .ralph/gates/final-latest.exit"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("State tampering")'
}

@test "blocks append into .ralph/gates/ (forged cmd breadcrumb)" {
  run _run_guard Bash 'echo "pnpm all-check:no-cache" >> .ralph/gates/final-latest.cmd'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "blocks tee into .ralph/gates/ (forged log breadcrumb)" {
  run _run_guard Bash "pnpm all-check 2>&1 | tee .ralph/gates/final-latest.log"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "allows reading a gate breadcrumb (no redirect)" {
  run _run_guard Bash "cat .ralph/gates/final-latest.log"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

@test "allows gate-run.sh final with 2>&1 (not a gates/ redirect)" {
  echo "$(date +%s)" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh final pnpm test 2>&1 | tail -5"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

# --- Direct test tool denial ---

@test "blocks direct vitest invocation" {
  run _run_guard Bash "vitest run"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("gate-run.sh")'
}

@test "blocks npx vitest" {
  run _run_guard Bash "npx vitest run tests/"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "blocks tsc --noEmit" {
  run _run_guard Bash "tsc --noEmit"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "allows vitest through gate-run.sh" {
  # Seed write timestamp so gate-without-write doesn't block
  echo "$(date +%s)" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh basic vitest run"
  [ "$status" -eq 0 ]
  # Either empty (allowed) or has gate-ts update
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

@test "blocks exec vitest (0.10.3)" {
  run _run_guard Bash "exec vitest run"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "blocks pnpm vitest" {
  run _run_guard Bash "pnpm vitest run"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "blocks pnpm exec vitest (0.10.3)" {
  run _run_guard Bash "pnpm exec vitest run"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "blocks pnpm exec cypress (0.10.3)" {
  run _run_guard Bash "pnpm exec cypress run"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "blocks pnpm exec tsc --noEmit (0.10.3)" {
  run _run_guard Bash "pnpm exec tsc --noEmit"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "allows bare pnpm test (not in deny list)" {
  run _run_guard Bash "pnpm test"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- Gate-without-write check ---

@test "blocks gate re-run with no write since last same-label gate (0.13.1)" {
  echo "$(date +%s)" > "$STATE_DIR/last-gate-ts.basic"
  echo "0" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh basic pnpm test"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("identical output")'
}

@test "allows gate run after a write (same label)" {
  echo "1" > "$STATE_DIR/last-gate-ts.basic"
  echo "$(date +%s)" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh basic pnpm test"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

@test "allows first gate run (no prior same-label gate timestamp)" {
  rm -f "$STATE_DIR"/last-gate-ts*
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh basic pnpm test"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

@test "allows different-label gate after another label ran (0.13.1)" {
  # Regression: pre-0.13.1, a successful 'basic' blocked a subsequent 'final'
  # because the gate cache was global, not per-label. [risky] tasks need
  # 'final' after the standard flow, so this is the load-bearing fix.
  echo "$(date +%s)" > "$STATE_DIR/last-gate-ts.basic"
  echo "0" > "$STATE_DIR/last-write-ts"
  rm -f "$STATE_DIR/last-gate-ts.final"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh final pnpm all-check"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

@test "deny message names the specific label that was cached (0.13.1)" {
  echo "$(date +%s)" > "$STATE_DIR/last-gate-ts.final"
  echo "0" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh final pnpm all-check"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  echo "$output" | jq -e ".hookSpecificOutput.permissionDecisionReason | test(\"Gate 'final'\")"
}

# --- Diagnostic reads referencing gate-run.sh (0.14.2) ---

@test "allows ls of gate-run.sh path without triggering gate cache (0.14.2)" {
  echo "$(date +%s)" > "$STATE_DIR/last-gate-ts.unknown"
  echo "0" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "ls $SCRIPTS_DIR/gate-run.sh"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

@test "allows test -f of gate-run.sh path without triggering gate cache (0.14.2)" {
  echo "$(date +%s)" > "$STATE_DIR/last-gate-ts.unknown"
  echo "0" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "test -f $SCRIPTS_DIR/gate-run.sh && echo EXISTS"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

@test "allows grep of gate-run.sh content without triggering gate cache (0.14.2)" {
  echo "$(date +%s)" > "$STATE_DIR/last-gate-ts.unknown"
  echo "0" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "grep -n 'cache' $SCRIPTS_DIR/gate-run.sh | head -40"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

@test "allows wc -l of gate-run.sh without triggering gate cache (0.14.2)" {
  echo "$(date +%s)" > "$STATE_DIR/last-gate-ts.unknown"
  echo "0" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "wc -l $SCRIPTS_DIR/gate-run.sh"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

@test "allows find for gate-run.sh without triggering gate cache (0.14.2)" {
  echo "$(date +%s)" > "$STATE_DIR/last-gate-ts.unknown"
  echo "0" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "find /tmp -name 'gate-run.sh' 2>/dev/null | head"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

@test "still blocks actual gate invocation via bash gate-run.sh (0.14.2)" {
  echo "$(date +%s)" > "$STATE_DIR/last-gate-ts.basic"
  echo "0" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh basic pnpm test"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

# --- Write/Edit forbidden-path denial ---

@test "blocks write to .ralph/gates/" {
  run _run_guard Write "$MOCK_WORKSPACE/.ralph/gates/foo.log"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "blocks write to .ralph/activity.log" {
  run _run_guard Edit "$MOCK_WORKSPACE/.ralph/activity.log"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "allows write to .ralph/handoff.md" {
  run _run_guard Write "$MOCK_WORKSPACE/.ralph/handoff.md"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

@test "allows write to .ralph/errors.log" {
  run _run_guard Write "$MOCK_WORKSPACE/.ralph/errors.log"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

@test "allows write to .ralph/guardrails.md" {
  run _run_guard Write "$MOCK_WORKSPACE/.ralph/guardrails.md"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

@test "allows write to .ralph/acceptance-report.md (0.13.3)" {
  # The acceptance-evaluation orchestrator and verifier sub-agent write
  # to this file as their primary output (History line, Status, Gaps).
  # Prior versions denied the write, which broke every eval loop that got
  # past the seed step.
  run _run_guard Write "$MOCK_WORKSPACE/.ralph/acceptance-report.md"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

@test "still denies write to other .ralph/ files (0.13.3)" {
  # Sanity-check: the allowlist expansion didn't accidentally open .ralph/
  # writes generally. Any unlisted .ralph/ path should still be denied.
  run _run_guard Write "$MOCK_WORKSPACE/.ralph/effective-prompt.md"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "allows write to normal project files" {
  run _run_guard Write "$MOCK_WORKSPACE/src/app.ts"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

# --- Write event recording ---

@test "write to project file updates last-write-ts" {
  rm -f "$STATE_DIR/last-write-ts"
  _run_guard Write "$MOCK_WORKSPACE/src/app.ts"
  [ -f "$STATE_DIR/last-write-ts" ]
  local ts
  ts=$(cat "$STATE_DIR/last-write-ts")
  [[ "$ts" =~ ^[0-9]+$ ]]
}

# --- Env-var prefix stripping ---

@test "blocks vitest even with env prefix" {
  run _run_guard Bash "NODE_ENV=test vitest run"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "blocks cypress with env prefix" {
  run _run_guard Bash "CI=true npx cypress run"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

# --- .ralph/command-policy unified file (0.12.0) ---

@test "command-policy rewrite section passes through with updatedInput (0.12.2)" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<EOF
[rewrite]
^pnpm -w run (.+)\$ | pnpm \1 | no -w workspace flag
EOF
  run _run_guard Bash "pnpm -w run format"
  [ "$status" -eq 0 ]
  # 0.12.2: rewrite is passthrough — emits updatedInput, not a block.
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command == "pnpm format"'
}

@test "command-policy deny section blocks exact prefix" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<EOF
[deny]
pnpm test-e2e | use pnpm test-e2e:local instead
EOF
  run _run_guard Bash "pnpm test-e2e --headed"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("local")'
}

@test "command-policy deny does not block longer command names" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<EOF
[deny]
pnpm api:test-e2e | use local
EOF
  run _run_guard Bash "pnpm api:test-e2e:local"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "command-policy protect blocks pipe but allows bare" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<EOF
[protect]
pnpm all-check
EOF
  run _run_guard Bash "pnpm all-check"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run _run_guard Bash "pnpm all-check | tail -20"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("pipe/redirect")'
}

@test "command-policy applies rewrite before deny (0.12.2)" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<EOF
[rewrite]
^pnpm -w run (.+)\$ | pnpm \1 | strip -w flag

[deny]
pnpm test | denied
EOF
  # 0.12.2: rewrite is passthrough — the rewritten 'pnpm test' flows into
  # deny, which blocks it. The agent sees the deny message, not a rewrite.
  run _run_guard Bash "pnpm -w run test"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("denied")'
}

@test "command-policy ignores comments and section markers" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<EOF
# top-level comment
[deny]
# inside-section comment

pnpm test-e2e | denied
EOF
  run _run_guard Bash "pnpm test-e2e"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "command-policy takes precedence over legacy denied-commands" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<EOF
[deny]
pnpm new-cmd | new policy fires
EOF
  printf 'pnpm new-cmd|legacy policy fires\n' > "$MOCK_WORKSPACE/.ralph/denied-commands"
  run _run_guard Bash "pnpm new-cmd"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("new policy fires")'
}

# --- 0.12.3: [wrap] auto-wrap enforcement ---
#
# These tests drive the agent's known evasion patterns: bare, with args,
# with pipe/redirect, with env prefix, with `pnpm run`/`pnpm exec`, etc.
# Every one of them must be transparently rewritten via the hook's
# `updatedInput` mechanism to the gate-run.sh-wrapped form — no blocks,
# no retry puzzle. The agent sees its command "just work" and the loop
# gets its tracking artifacts because the wrapped form is what runs.
#
# Also covers backward compat: [gate-wrapped] entries (no label) are
# accepted and default to label "basic".

setup_wrap_policy() {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<EOF
[wrap]
pnpm all-check | final
pnpm basic-check | basic
EOF
}

@test "[wrap] auto-wraps bare invocation via updatedInput" {
  setup_wrap_policy
  run _run_guard Bash "pnpm all-check"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh final pnpm all-check")'
}

@test "[wrap] preserves trailing args in rewrite" {
  setup_wrap_policy
  run _run_guard Bash "pnpm all-check --silent"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh final pnpm all-check --silent")'
}

@test "[wrap] auto-wraps piped invocation (pipe is stripped)" {
  setup_wrap_policy
  run _run_guard Bash "pnpm all-check | tail -50"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh final pnpm all-check")'
  # Pipe should not appear in the rewritten command — gate-run.sh bounds output.
  ! echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("tail -50")' 2>/dev/null
}

@test "[wrap] auto-wraps redirect invocation (redirect is stripped)" {
  setup_wrap_policy
  run _run_guard Bash "pnpm all-check > /tmp/out.log"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh final pnpm all-check")'
}

@test "[wrap] auto-wraps 2>&1 pipe variant" {
  setup_wrap_policy
  run _run_guard Bash "pnpm all-check 2>&1 | grep error"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh final pnpm all-check")'
}

@test "[wrap] auto-wraps env-prefixed invocation" {
  setup_wrap_policy
  run _run_guard Bash "CI=true pnpm all-check"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh final pnpm all-check")'
}

@test "[wrap] auto-wraps VERBOSE-prefixed invocation" {
  setup_wrap_policy
  run _run_guard Bash "VERBOSE=1 pnpm all-check"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh final pnpm all-check")'
}

@test "[wrap] auto-wraps 'pnpm run' variant" {
  setup_wrap_policy
  run _run_guard Bash "pnpm run all-check"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh final pnpm all-check")'
}

@test "[wrap] auto-wraps 'pnpm exec' variant" {
  setup_wrap_policy
  run _run_guard Bash "pnpm exec basic-check"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh basic pnpm basic-check")'
}

@test "[wrap] picks correct label per entry" {
  setup_wrap_policy
  # basic-check should get label "basic", not "final"
  run _run_guard Bash "pnpm basic-check"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh basic pnpm basic-check")'
  ! echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh final")' 2>/dev/null
}

@test "[wrap] allows already-wrapped gate-run.sh invocation through" {
  setup_wrap_policy
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh basic pnpm basic-check"
  [ "$status" -eq 0 ]
  # Should not rewrite or block — agent's explicit gate-run.sh is the contract.
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
    ! echo "$output" | jq -e '.hookSpecificOutput.updatedInput' 2>/dev/null
  fi
}

@test "[wrap] does not match non-listed commands" {
  setup_wrap_policy
  run _run_guard Bash "pnpm format:write"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "[wrap] does not match on prefix-of-a-longer-name" {
  setup_wrap_policy
  # pnpm all-check-extended is a different (hypothetical) script
  run _run_guard Bash "pnpm all-check-extended"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "[wrap] row with no label is skipped (0.14.0 — no implicit default)" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<EOF
[wrap]
pnpm all-check
EOF
  # No label → row skipped. Command passes through (no wrap, no allow JSON).
  run _run_guard Bash "pnpm all-check"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || ! echo "$output" | jq -e '.hookSpecificOutput.updatedInput' 2>/dev/null
}

@test "[wrap] row with invalid label is skipped (0.14.0 — no silent fallback)" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<EOF
[wrap]
pnpm all-check | not-a-real-label
EOF
  # Unrecognized label → row skipped. Command passes through unchanged.
  run _run_guard Bash "pnpm all-check"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || ! echo "$output" | jq -e '.hookSpecificOutput.updatedInput' 2>/dev/null
}

@test "[wrap] accepts every label in the 0.14.0 canonical set" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<EOF
[wrap]
pnpm a | basic
pnpm b | full
pnpm c | final
pnpm d | unit
pnpm e | integration
pnpm f | e2e
pnpm g | lint
pnpm h | format
EOF
  local letter label
  local _i=0
  for label in basic full final unit integration e2e lint format; do
    letter=$(printf '\\x%x' $((97 + _i)))
    letter=$(printf "$letter")
    run _run_guard Bash "pnpm $letter"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e ".hookSpecificOutput.updatedInput.command | test(\"gate-run.sh $label pnpm $letter\")" \
      || { echo "label '$label' did not wrap pnpm $letter: $output"; return 1; }
    _i=$((_i + 1))
  done
}

@test "[wrap] interacts cleanly with [rewrite] for 'pnpm -w run' (0.12.3)" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<EOF
[rewrite]
^pnpm -w run (.+)\$ | pnpm \1 | strip -w flag

[wrap]
pnpm all-check | final
EOF
  # 0.12.3: rewrite normalizes to 'pnpm all-check', wrap auto-rewrites to
  # gate-run.sh-wrapped form. Single emit, agent's command "just works".
  run _run_guard Bash "pnpm -w run all-check"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh final pnpm all-check")'
}

@test "[wrap] composes with [rewrite] for 'pnpm nx X' bypass" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<EOF
[rewrite]
^pnpm nx (.+)\$ | pnpm \1 | pnpm nx bypasses gate-wrapped enforcement

[wrap]
pnpm test-unit | basic
EOF
  # The original failure mode that motivated 0.12.3: agent uses `pnpm nx
  # test-unit api` to bypass gate-wrapped. Rewrite normalizes, wrap fires.
  run _run_guard Bash "pnpm nx test-unit api"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh basic pnpm test-unit api")'
}

@test "[wrap] [deny] wins on overlap (deny still hard-blocks)" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<EOF
[deny]
pnpm all-check | hard deny

[wrap]
pnpm all-check | final
EOF
  run _run_guard Bash "pnpm all-check"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("hard deny")'
  # Wrap rewrite must not have fired.
  ! echo "$output" | jq -e '.hookSpecificOutput.updatedInput' 2>/dev/null
}

# --- 0.12.3: _block uses modern hook response format ---
#
# Catches regression to legacy {"result":"block"} output which Claude Code
# SILENTLY IGNORES — every block was a no-op before this fix.

@test "_block emits hookSpecificOutput format (0.12.3)" {
  run _run_guard Bash "rm -rf .ralph/"
  [ "$status" -eq 0 ]
  # Must use the new schema, not legacy {"result":"block"}
  echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"'
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason != null'
  # Legacy fields must be absent
  ! echo "$output" | jq -e '.result' 2>/dev/null
  ! echo "$output" | jq -e '.reason' 2>/dev/null
}

@test "_emit_rewrite emits hookSpecificOutput allow + updatedInput (0.12.3)" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<EOF
[rewrite]
^npx pnpm (.+)\$ | pnpm \1 | use local pnpm
EOF
  run _run_guard Bash "npx pnpm format"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"'
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command == "pnpm format"'
}

# --- 0.12.3: canonicalization closes evasion loopholes generically ---
#
# These exercise the canonicalize pipeline end-to-end via the [wrap]
# rewrite: every form of "pnpm basic-check" the agent might invent must
# reduce to the same canonical command and produce the same auto-wrap.

@test "canonicalize: env prefix is stripped" {
  setup_wrap_policy
  run _run_guard Bash "CI=1 NODE_ENV=test pnpm basic-check"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh basic pnpm basic-check")'
}

@test "canonicalize: && separator is stripped (only head command matched)" {
  setup_wrap_policy
  run _run_guard Bash "pnpm basic-check && echo done"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh basic pnpm basic-check")'
}

@test "canonicalize: semicolon separator is stripped" {
  setup_wrap_policy
  run _run_guard Bash "pnpm basic-check ; echo done"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh basic pnpm basic-check")'
}

@test "canonicalize: append redirect >> is stripped" {
  setup_wrap_policy
  run _run_guard Bash "pnpm basic-check >> /tmp/out.log"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh basic pnpm basic-check")'
}

# =============================================================================
# 0.12.4: compound-chain wrap matching
# =============================================================================
# Bypass closed: an && / ; / || chain where a non-wrapped warm-up command
# precedes a wrapped target. Previously the head was matched and the wrap
# target was invisible. Now we split, canonicalize each segment, and rewrap
# to gate-run.sh on the wrap-target segment alone (dropping the prefix).

@test "compound chain: pnpm format:write && pnpm test-coverage rewraps to test-coverage (0.12.4)" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<'EOF'
[wrap]
pnpm test-coverage | basic
EOF
  run _run_guard Bash "pnpm format:write && pnpm lint:check && pnpm test-coverage 2>&1 | tail -20"
  [ "$status" -eq 0 ]
  # The whole chain should be replaced by a clean gate-wrap of just the wrap-target segment.
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh basic pnpm test-coverage")'
  # The format:write/lint:check prefix should NOT appear in the rewritten command.
  ! echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("format:write")'
}

@test "compound chain: cd <dir> && pnpm all-check rewraps to all-check (0.12.4)" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<'EOF'
[wrap]
pnpm all-check | final
EOF
  run _run_guard Bash "cd /tmp/somewhere && pnpm all-check 2>&1 | tail -20"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh final pnpm all-check")'
}

@test "compound chain: semicolon-separated chain still detects wrap target (0.12.4)" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<'EOF'
[wrap]
pnpm test-unit | basic
EOF
  run _run_guard Bash "pnpm format:write ; pnpm test-unit"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh basic pnpm test-unit")'
}

@test "compound chain: chain without any wrap target falls through (0.12.4)" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<'EOF'
[wrap]
pnpm test-unit | basic
EOF
  # No segment matches [wrap] — should just allow without rewrite.
  run _run_guard Bash "pnpm format:write && pnpm lint:check"
  [ "$status" -eq 0 ]
  ! echo "$output" | jq -e '.hookSpecificOutput.updatedInput' 2>/dev/null
}

# 0.14.6: a multi-line `git commit -m "<body>"` whose body line starts with a
# gated command must NOT be mis-split into a fake gate segment. The chain
# splitter must key on shell separators only, not on literal newlines inside
# a quoted argument. Regression for the spurious COMPLETE BLOCKED where
# gates/<label>-latest.cmd got polluted with a commit-message line.
@test "compound chain: multi-line commit -m body is not mis-detected as a gate (0.14.6)" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<'EOF'
[wrap]
pnpm all-check | final
EOF
  # The commit body's first line literally starts with "pnpm all-check …".
  # Old IFS=$'\n' split would have isolated that line and wrapped it.
  run _run_guard Bash "$(printf 'git add . && git commit -q -m "chore: done\n\npnpm all-check passes end-to-end: format, lint, coverage\n(no gaps), build, e2e."')"
  [ "$status" -eq 0 ]
  # Must NOT rewrite the commit into a gate-run.sh invocation.
  ! echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh")' 2>/dev/null
}

# =============================================================================
# 0.12.4: pnpm exec nx → wrap target via post-rewrite normalization
# =============================================================================
# Bypass closed: `pnpm exec nx run api:test-coverage` previously canonicalized
# to `pnpm nx run api:test-coverage`, then [rewrite] produced
# `pnpm run api:test-coverage` — but that wasn't re-normalized to
# `pnpm api:test-coverage`, so it slipped past [wrap]. The fix adds a
# second _normalize_pnpm pass after _apply_rewrites.

@test "pnpm exec nx run X normalizes to pnpm X for wrap matching (0.12.4)" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<'EOF'
[rewrite]
^pnpm nx (.+)$ | pnpm \1 | nx bypass

[wrap]
pnpm api:test-coverage | basic
EOF
  run _run_guard Bash "pnpm exec nx run api:test-coverage 2>&1 | tail -10"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh basic pnpm api:test-coverage")'
}

@test "pnpm exec nx run X with target args still matches wrap (0.12.4)" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<'EOF'
[rewrite]
^pnpm nx (.+)$ | pnpm \1 | nx bypass

[wrap]
pnpm api:test-coverage | basic
EOF
  run _run_guard Bash "pnpm exec nx run api:test-coverage --testPathPattern='foo'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh basic pnpm api:test-coverage")'
}

# =============================================================================
# 0.12.5: activity-log emoji callouts for hook intercepts
# =============================================================================
# Operators couldn't tell when the guard fired without inspecting the
# hook stream directly. These emojis make rewrites and denies visible
# in activity.log next to the agent's other tool events.

@test "rewrite via [wrap] writes 🔀 GUARD REWRITE to activity.log (0.12.5)" {
  setup_wrap_policy
  : > "$MOCK_WORKSPACE/.ralph/activity.log"
  run _run_guard Bash "pnpm basic-check 2>&1 | tail -30"
  [ "$status" -eq 0 ]
  grep -q "🔀 GUARD REWRITE" "$MOCK_WORKSPACE/.ralph/activity.log"
  grep -qE "pnpm basic-check 2>&1.*→.*gate-run.sh basic pnpm basic-check" "$MOCK_WORKSPACE/.ralph/activity.log"
}

@test "rewrite via [rewrite] writes 🔀 GUARD REWRITE to activity.log (0.12.5)" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<'EOF'
[rewrite]
^npx pnpm (.+)$ | pnpm \1 | use local pnpm
EOF
  : > "$MOCK_WORKSPACE/.ralph/activity.log"
  run _run_guard Bash "npx pnpm format"
  [ "$status" -eq 0 ]
  grep -q "🔀 GUARD REWRITE" "$MOCK_WORKSPACE/.ralph/activity.log"
  grep -qE "npx pnpm format.*→.*pnpm format" "$MOCK_WORKSPACE/.ralph/activity.log"
}

@test "deny writes ⛔ GUARD DENY to activity.log (0.12.5)" {
  : > "$MOCK_WORKSPACE/.ralph/activity.log"
  run _run_guard Bash "rm -rf .ralph/"
  [ "$status" -eq 0 ]
  grep -q "⛔ GUARD DENY" "$MOCK_WORKSPACE/.ralph/activity.log"
  grep -q "rm -rf .ralph/" "$MOCK_WORKSPACE/.ralph/activity.log"
}

@test "no-op tool calls do NOT write GUARD lines to activity.log (0.12.5)" {
  setup_wrap_policy
  : > "$MOCK_WORKSPACE/.ralph/activity.log"
  # `ls /tmp` matches no rule and triggers no intercept.
  run _run_guard Bash "ls /tmp"
  [ "$status" -eq 0 ]
  ! grep -q "GUARD" "$MOCK_WORKSPACE/.ralph/activity.log"
}

# -----------------------------------------------------------------------------
# 0.14.0: Tier-command label lock
# -----------------------------------------------------------------------------
# Each of the three [gates] commands (basic / full / final) is "owned" by
# its tier label. Running a tier command under any other label escapes the
# tier's per-label cache AND lands the breadcrumb in a per-label namespace
# the downstream consumer (_complete_allowed reads full-latest.*; the eval
# orchestrator reads final-latest.*) does not check — the "relabel to fish
# for green" anti-pattern observed in loop 152651, generalized to all
# three tiers. No eval-* exemption — eval uses 'final' directly.

setup_v14_gates_policy() {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<EOF
[gates]
basic | pnpm basic-check
full  | pnpm all-check
final | pnpm verify:final
EOF
}

@test "label-lock: denies [gates].full command under label=basic (0.14.0)" {
  setup_v14_gates_policy
  echo "$(date +%s)" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh basic pnpm all-check"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("must run under label .full.")'
}

@test "label-lock: denies [gates].full command under label=unit (0.14.0)" {
  setup_v14_gates_policy
  echo "$(date +%s)" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh unit pnpm all-check"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "label-lock: denies [gates].basic command under label=unit (0.14.0)" {
  setup_v14_gates_policy
  echo "$(date +%s)" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh unit pnpm basic-check"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "label-lock: denies [gates].final command under label=full (0.14.0)" {
  setup_v14_gates_policy
  echo "$(date +%s)" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh full pnpm verify:final"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "label-lock: pipe form still triggers the lock (0.14.0)" {
  setup_v14_gates_policy
  echo "$(date +%s)" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh basic pnpm all-check 2>&1 | tail -40"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "label-lock: allows [gates].basic under label=basic (0.14.0)" {
  setup_v14_gates_policy
  rm -f "$STATE_DIR"/last-gate-ts*
  echo "$(date +%s)" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh basic pnpm basic-check"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

@test "label-lock: allows [gates].full under label=full (0.14.0)" {
  setup_v14_gates_policy
  rm -f "$STATE_DIR"/last-gate-ts*
  echo "$(date +%s)" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh full pnpm all-check"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

@test "label-lock: allows [gates].final under label=final (0.14.0; no eval-* exemption needed)" {
  setup_v14_gates_policy
  rm -f "$STATE_DIR"/last-gate-ts*
  echo "$(date +%s)" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh final pnpm verify:final"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

@test "label-lock: allows a non-tier command under any kind label (0.14.0)" {
  setup_v14_gates_policy
  rm -f "$STATE_DIR"/last-gate-ts*
  echo "$(date +%s)" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh unit pnpm test-unit foo"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

@test "label-lock: when full and final share the same command, either label is OK (0.14.0)" {
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<EOF
[gates]
basic | pnpm basic-check
full  | pnpm all-check
final | pnpm all-check
EOF
  echo "$(date +%s)" > "$STATE_DIR/last-write-ts"
  # both 'full' and 'final' are valid for 'pnpm all-check'
  rm -f "$STATE_DIR"/last-gate-ts*
  echo "$(date +%s)" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh full pnpm all-check"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
  rm -f "$STATE_DIR"/last-gate-ts*
  echo "$(date +%s)" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh final pnpm all-check"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
  # …but label=basic still denied since 'pnpm all-check' isn't [gates].basic.
  rm -f "$STATE_DIR"/last-gate-ts*
  echo "$(date +%s)" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh basic pnpm all-check"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

# -----------------------------------------------------------------------------
# 0.14.0: [gates] auto-wrap (tier commands wrap without a [wrap] row)
# -----------------------------------------------------------------------------

@test "[gates] auto-wraps each tier command under its tier label (0.14.0)" {
  setup_v14_gates_policy
  run _run_guard Bash "pnpm basic-check"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh basic pnpm basic-check")'
  run _run_guard Bash "pnpm all-check"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh full pnpm all-check")'
  run _run_guard Bash "pnpm verify:final"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh final pnpm verify:final")'
}

@test "[gates] auto-wrap survives env prefix on agent's invocation (0.14.0)" {
  setup_v14_gates_policy
  # Canonicalization strips the env prefix, matching is on the canonical
  # form. The wrap rewrite drops the env (a documented limitation: use a
  # shell script if you need the env preserved at execution time).
  run _run_guard Bash "CI=1 pnpm all-check"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh full pnpm all-check")'
}

# --- Blanket git-add denial (0.15.4) ---

@test "blocks blanket git add -A (0.15.4)" {
  run _run_guard Bash "git add -A"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("Blanket")'
}

@test "blocks git add . (0.15.4)" {
  run _run_guard Bash "git add ."
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "blocks git add --all (0.15.4)" {
  run _run_guard Bash "git add --all"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "blocks git add -A chained before a commit (0.15.4)" {
  run _run_guard Bash "git add -A && git commit -m 'wip'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "allows git add with explicit paths (0.15.4)" {
  run _run_guard Bash "git add src/foo.ts apps/api/main.ts"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

@test "allows git add -u (tracked modifications only) (0.15.4)" {
  run _run_guard Bash "git add -u"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

@test "allows git commit -am (tracked-only, not a blanket add) (0.15.4)" {
  run _run_guard Bash "git commit -am 'wip'"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

# --- last-write-ts records only code writes, not .ralph/ state (0.15.4) ---

@test "Write to allowlisted .ralph/ state file does not bump last-write-ts (0.15.4)" {
  rm -f "$STATE_DIR/last-write-ts"
  # acceptance-report.md is allowlisted; writing it is loop bookkeeping, not a
  # code change, so it must not invalidate the per-label gate cache.
  _run_guard Write "$MOCK_WORKSPACE/.ralph/acceptance-report.md"
  [ ! -f "$STATE_DIR/last-write-ts" ]
}

@test "Write to a code file bumps last-write-ts (0.15.4)" {
  rm -f "$STATE_DIR/last-write-ts"
  _run_guard Write "$MOCK_WORKSPACE/apps/api/src/app.ts"
  [ -f "$STATE_DIR/last-write-ts" ]
}
