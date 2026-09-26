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
  # 0.16.0: the cache only blocks COMPLETED runs — land a verdict for it.
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf '1' > "$MOCK_WORKSPACE/.ralph/gates/basic-latest.exit"
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
  # 0.16.0: the cache only blocks COMPLETED runs — land a verdict for it.
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf '0' > "$MOCK_WORKSPACE/.ralph/gates/final-latest.exit"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh final pnpm all-check"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  echo "$output" | jq -e ".hookSpecificOutput.permissionDecisionReason | test(\"Gate 'final'\")"
}

# --- 0.16.0: exit-75 continuation vs the per-label gate cache ---
# Gates run detached; re-running the same command is the CONTINUATION
# mechanism (join the in-flight gate / relaunch a died one), so the cache
# must only block re-runs of runs that actually landed a verdict.

@test "gate-cache: allows re-run while a live runner holds the label lock (0.16.0)" {
  echo "0" > "$STATE_DIR/last-write-ts"
  echo "$(date +%s)" > "$STATE_DIR/last-gate-ts.final"
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates/.final.lock"
  echo $$ > "$MOCK_WORKSPACE/.ralph/gates/.final.lock/pid"
  # Even with a fresh verdict on disk, a live lock means this re-run JOINS.
  printf '0' > "$MOCK_WORKSPACE/.ralph/gates/final-latest.exit"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh final pnpm all-check"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

@test "gate-cache: allows relaunch when the prior invocation never landed a verdict (0.16.0)" {
  echo "0" > "$STATE_DIR/last-write-ts"
  echo "$(date +%s)" > "$STATE_DIR/last-gate-ts.final"
  # No lock and no verdict → the recorded run died silently (hard kill).
  rm -rf "$MOCK_WORKSPACE/.ralph/gates/.final.lock"
  rm -f "$MOCK_WORKSPACE/.ralph/gates/final-latest.exit"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh final pnpm all-check"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

@test "gate-cache: stale verdict older than the invocation stamp does not block (0.16.0)" {
  # A verdict exists but predates the last invocation — that run died.
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf '124' > "$MOCK_WORKSPACE/.ralph/gates/final-latest.exit"
  touch -t "$(date -v-1H '+%Y%m%d%H%M' 2>/dev/null || date -d '1 hour ago' '+%Y%m%d%H%M')" \
    "$MOCK_WORKSPACE/.ralph/gates/final-latest.exit"
  echo "0" > "$STATE_DIR/last-write-ts"
  echo "$(date +%s)" > "$STATE_DIR/last-gate-ts.final"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh final pnpm all-check"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
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
  # 0.16.0: the cache only blocks COMPLETED runs — land a verdict for it.
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"
  printf '1' > "$MOCK_WORKSPACE/.ralph/gates/basic-latest.exit"
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

@test "[wrap] pins the gate Bash-call timeout to 600000ms (0.18.0)" {
  # A gate wrap must also raise the Bash tool timeout to its 600000ms ceiling
  # so the waiter's call is never cut at the 120s default — the kill window
  # that produced the spurious exit=130 gates in run 140038. Mechanical, not
  # advisory: enforced here, not left to the agent remembering the framing.
  setup_wrap_policy
  run _run_guard Bash "pnpm all-check"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh final pnpm all-check")'
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.timeout == 600000'
}

@test "[rewrite] non-gate rewrite does not pin a timeout (0.18.0)" {
  # The 600000ms pin is gate-only. A plain [rewrite] that does not route
  # through gate-run.sh must keep the Bash tool's own default timeout.
  cat > "$MOCK_WORKSPACE/.ralph/command-policy" <<EOF
[rewrite]
^pnpm nx run ([a-z-]+):([a-z-]+)\$ | pnpm \1:\2 | drop nx run indirection
EOF
  run _run_guard Bash "pnpm nx run api:test-unit"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command == "pnpm api:test-unit"'
  ! echo "$output" | jq -e '.hookSpecificOutput.updatedInput | has("timeout")' 2>/dev/null
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

@test "allows write to .ralph/policy-proposal (0.20.0)" {
  # The sanctioned move when command-policy ITSELF is the blocker. Without
  # it, an agent that correctly diagnosed a stale [gates] pin had no legal
  # action at all and the run deadlocked.
  run _run_guard Write "$MOCK_WORKSPACE/.ralph/policy-proposal"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

@test "still denies write to .ralph/command-policy (0.20.0)" {
  # A loop that can rewrite its own completion bar has no bar. The proposal
  # channel must not have opened this.
  run _run_guard Write "$MOCK_WORKSPACE/.ralph/command-policy"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "command-policy denial points at the proposal channel (0.20.0)" {
  run _run_guard Write "$MOCK_WORKSPACE/.ralph/command-policy"
  echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason' |
    grep -q ".ralph/policy-proposal"
}

# --- 0.24.1: the gate cache must arm on BOTH invocation paths ---
# Pre-0.24.1 the cache/tier-lock block sat after _enforce_command_policy,
# which exits via _emit_rewrite — so the auto-wrapped path (the normal one)
# never recorded last-gate-ts.<label>, leaving the cache permanently inert.
# The `$(cat .ralph/gate-runner)` indirection every eval-loop sub-agent uses
# was invisible for the same reason: its text has no "gate-run.sh" in it.

@test "gate-cache: auto-wrapped gate records the per-label timestamp (0.24.1)" {
  setup_v14_gates_policy
  rm -f "$STATE_DIR"/last-gate-ts*
  echo "$(date +%s)" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "pnpm basic-check"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh basic")'
  [ -f "$STATE_DIR/last-gate-ts.basic" ]
}

@test "gate-cache: blocks an auto-wrapped gate re-run with no intervening write (0.24.1)" {
  setup_v14_gates_policy
  echo "$(date +%s)" > "$STATE_DIR/last-gate-ts.basic"
  echo "0" > "$STATE_DIR/last-write-ts"
  printf '1' > "$MOCK_WORKSPACE/.ralph/gates/basic-latest.exit"
  run _run_guard Bash "pnpm basic-check"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("identical output")'
}

@test "gate-cache: a code write re-opens the auto-wrapped gate (0.24.1)" {
  setup_v14_gates_policy
  echo "1" > "$STATE_DIR/last-gate-ts.basic"
  echo "$(date +%s)" > "$STATE_DIR/last-write-ts"
  printf '1' > "$MOCK_WORKSPACE/.ralph/gates/basic-latest.exit"
  run _run_guard Bash "pnpm basic-check"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh basic")'
}

@test "gate-cache: gate-runner indirection records the per-label timestamp (0.24.1)" {
  setup_v14_gates_policy
  rm -f "$STATE_DIR"/last-gate-ts*
  echo "$(date +%s)" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash 'bash "$(cat .ralph/gate-runner)" final pnpm verify:final'
  [ "$status" -eq 0 ]
  [ -f "$STATE_DIR/last-gate-ts.final" ]
}

@test "gate-cache: gate-runner indirection is subject to the cache (0.24.1)" {
  setup_v14_gates_policy
  echo "$(date +%s)" > "$STATE_DIR/last-gate-ts.final"
  echo "0" > "$STATE_DIR/last-write-ts"
  printf '0' > "$MOCK_WORKSPACE/.ralph/gates/final-latest.exit"
  run _run_guard Bash 'bash "$(cat .ralph/gate-runner)" final pnpm verify:final'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  echo "$output" | jq -e ".hookSpecificOutput.permissionDecisionReason | test(\"Gate 'final'\")"
}

@test "label-lock: gate-runner indirection triggers the tier lock (0.24.1)" {
  setup_v14_gates_policy
  echo "$(date +%s)" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash 'bash "$(cat .ralph/gate-runner)" unit pnpm all-check'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("must run under label .full.")'
}

@test "label-lock: trailing '; echo' does not disarm the tier lock (0.24.1)" {
  # The shape the eval loop actually types. The trailing segment used to ride
  # along in the compared command, so no [gates] pin ever matched.
  setup_v14_gates_policy
  echo "$(date +%s)" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash 'bash "$(cat .ralph/gate-runner)" unit pnpm all-check; echo "GATE_EXIT=$?"'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("must run under label .full.")'
}

@test "label-lock: correct tier label via gate-runner indirection is allowed (0.24.1)" {
  setup_v14_gates_policy
  rm -f "$STATE_DIR"/last-gate-ts*
  echo "$(date +%s)" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash 'bash "$(cat .ralph/gate-runner)" full pnpm all-check; echo "GATE_EXIT=$?"'
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

@test "cat of .ralph/gate-runner does not trigger the gate cache (0.24.1)" {
  # Reading the breadcrumb is a diagnostic, not a gate run — must not be
  # treated as one (the 0.14.2 false-positive class).
  echo "$(date +%s)" > "$STATE_DIR/last-gate-ts.unknown"
  echo "0" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "cat .ralph/gate-runner"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

# --- 0.26.0: denials carry the guard's marker --------------------------------
# agent-adapter.sh reads the marker to tell a denial (the command never ran)
# from a command that ran and failed.

@test "a denial reason opens with the guard marker (0.26.0)" {
  run _run_guard Bash "rm -rf .ralph/"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | startswith("[ralph-guard] State tampering")'
}

# --- 0.26.0: deletions are judged one chained command at a time --------------

_assert_allowed() {
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' 2>/dev/null
  fi
}

_assert_tamper_denied() {
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("State tampering")'
}

@test "rm of another path, then a read of .ralph/ later in the chain, is allowed (0.26.0)" {
  run _run_guard Bash 'rm -rf .playwright-mcp; git status --porcelain; grep -n "Final gate" .ralph/acceptance-report.md'
  _assert_allowed
}

@test "rm naming .ralph/ is denied wherever it sits in the chain (0.26.0)" {
  run _run_guard Bash "cd sub && rm -f .ralph/gates/final-latest.exit"
  _assert_tamper_denied
}

@test "rm of .ralph/ is denied without any flag (0.26.0)" {
  run _run_guard Bash "rm .ralph/handoff.md"
  _assert_tamper_denied
}

@test "rm of .ralph as a path component is denied, whatever follows it (0.26.0)" {
  run _run_guard Bash 'rm -rf "$PWD/.ralph" other-dir'
  _assert_tamper_denied
}

@test "rm of .ralph-postmortems is not .ralph state (0.26.0)" {
  run _run_guard Bash "rm -rf .ralph-postmortems/old"
  _assert_allowed
}

@test "rm behind env assignments and sudo is still judged (0.26.0)" {
  run _run_guard Bash "FOO=1 sudo rm -rf .ralph"
  _assert_tamper_denied
}

@test "rm run by xargs is still judged (0.26.0)" {
  run _run_guard Bash "echo x | xargs -n 1 rm -rf .ralph/gates"
  _assert_tamper_denied
}

@test "find -delete elsewhere, then a read of .ralph/, is allowed (0.26.0)" {
  run _run_guard Bash "find src -name '*.tmp' -delete; cat .ralph/activity.log"
  _assert_allowed
}

# --- 0.26.0: package-local binaries canonicalize to the package manager's exec form

@test "./node_modules/.bin/vitest is a direct runner in a pnpm workspace (0.26.0)" {
  touch "$MOCK_WORKSPACE/pnpm-lock.yaml"
  run _run_guard Bash "./node_modules/.bin/vitest run src/a.spec.ts"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("Direct test runner")'
}

@test "./node_modules/.bin/jest is a direct runner in a pnpm workspace (0.26.0)" {
  touch "$MOCK_WORKSPACE/pnpm-lock.yaml"
  run _run_guard Bash "./node_modules/.bin/jest --watch=false"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("Direct test runner")'
}

@test "an absolute node_modules/.bin/vitest path in an npm workspace is a direct runner (0.26.0)" {
  touch "$MOCK_WORKSPACE/package-lock.json"
  run _run_guard Bash "$MOCK_WORKSPACE/node_modules/.bin/vitest run"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("Direct test runner")'
}

@test "../node_modules/.bin/tsc --noEmit is denied in a yarn workspace (0.26.0)" {
  touch "$MOCK_WORKSPACE/yarn.lock"
  run _run_guard Bash "../node_modules/.bin/tsc --noEmit -p apps/api"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("Direct tsc")'
}

@test "./node_modules/.bin/nx meets the project's nx rewrite and [wrap] (0.26.0)" {
  touch "$MOCK_WORKSPACE/pnpm-lock.yaml"
  echo '{"scripts":{"api:test-coverage":"nx run api:test-coverage"}}' >"$MOCK_WORKSPACE/package.json"
  printf '%s\n' '[rewrite]' '^pnpm nx (.+)$ | pnpm \1 | pnpm nx bypasses [wrap]' '' \
    '[wrap]' 'pnpm api:test-coverage | unit' >"$MOCK_WORKSPACE/.ralph/command-policy"
  run _run_guard Bash "./node_modules/.bin/nx run api:test-coverage --skip-nx-cache 2>&1 | tail -20"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh unit pnpm api:test-coverage --skip-nx-cache")'
}

@test "a script path that is not node_modules/.bin is left alone (0.26.0)" {
  touch "$MOCK_WORKSPACE/pnpm-lock.yaml"
  run _run_guard Bash "./scripts/vitest-report.sh --summary"
  _assert_allowed
}

# --- 0.26.0: a [rewrite] must not produce a pnpm script that does not exist ---

_nx_rewrite_policy() {
  printf '%s\n' '[rewrite]' \
    '^pnpm nx (.+)$ | pnpm \1 | pnpm nx bypasses [wrap]' \
    "^npx pnpm (.+)\$ | pnpm \\1 | use the project's local pnpm" \
    '^npx (eslint.*)$ | pnpm \1 | use the workspace binary' '' \
    '[deny]' 'pnpm forbidden:thing | forbidden by the project' \
    >"$MOCK_WORKSPACE/.ralph/command-policy"
  echo '{"scripts":{"test-unit":"nx run-many -t test-unit","api:test-unit":"nx run api:test-unit","lint":"eslint ."}}' \
    >"$MOCK_WORKSPACE/package.json"
}

@test "a rewrite to a script that does not exist is denied, naming real ones (0.26.0)" {
  _nx_rewrite_policy
  run _run_guard Bash "pnpm nx run canonical-prompt:test-unit"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("canonical-prompt:test-unit. is not a script")'
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("pnpm api:test-unit, pnpm test-unit")'
}

@test "a rewrite to a script that exists passes through (0.26.0)" {
  _nx_rewrite_policy
  run _run_guard Bash "pnpm nx run api:test-unit"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command == "pnpm api:test-unit"'
}

@test "a rewrite to a pnpm subcommand is not treated as a script lookup (0.26.0)" {
  _nx_rewrite_policy
  run _run_guard Bash "npx pnpm install --frozen-lockfile"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command == "pnpm install --frozen-lockfile"'
}

@test "a rewrite to a package-local binary passes through (0.26.0)" {
  _nx_rewrite_policy
  mkdir -p "$MOCK_WORKSPACE/node_modules/.bin"
  touch "$MOCK_WORKSPACE/node_modules/.bin/eslint"
  run _run_guard Bash "npx eslint src"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command == "pnpm eslint src"'
}

@test "an explicit [deny] row keeps its own reason over the missing-script check (0.26.0)" {
  _nx_rewrite_policy
  run _run_guard Bash "pnpm nx forbidden:thing"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("forbidden by the project")'
}

# --- 0.26.0: the gate cache re-opens when the working tree changed ------------
# A Bash edit (sed -i, a heredoc) produces no Write/Edit event. gate-run.sh
# records the tree each verdict ran against; any difference re-opens the gate.

# Commit a tracked file, then land a 'basic' verdict recorded against the
# current tree, with no Write/Edit since — the timestamps alone would deny.
_verdict_on_current_tree() {
  echo "one" >"$MOCK_WORKSPACE/src.ts"
  git -C "$MOCK_WORKSPACE" add src.ts
  git -C "$MOCK_WORKSPACE" commit -q -m "add src"
  echo "0" >"$STATE_DIR/last-write-ts"
  echo "$(date +%s)" >"$STATE_DIR/last-gate-ts.basic"
  printf '1' >"$MOCK_WORKSPACE/.ralph/gates/basic-latest.exit"
  bash "$SCRIPTS_DIR/tree-fingerprint.sh" "$MOCK_WORKSPACE" >"$MOCK_WORKSPACE/.ralph/gates/basic-latest.tree"
}

@test "gate-cache: an unchanged tree keeps the gate cached (0.26.0)" {
  _verdict_on_current_tree
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh basic pnpm test"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("nothing has changed since")'
}

@test "gate-cache: a Bash edit of a tracked file re-opens the gate (0.26.0)" {
  _verdict_on_current_tree
  echo "two" >>"$MOCK_WORKSPACE/src.ts"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh basic pnpm test"
  _assert_allowed
}

@test "gate-cache: a new untracked file re-opens the gate (0.26.0)" {
  _verdict_on_current_tree
  echo "new" >"$MOCK_WORKSPACE/new.spec.ts"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh basic pnpm test"
  _assert_allowed
}

@test "gate-cache: a change to an ignored path keeps the gate cached (0.26.0)" {
  # Environmental churn lands in ignored paths and is not a code change.
  _verdict_on_current_tree
  echo "scratch" >"$MOCK_WORKSPACE/.ralph/scratch"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh basic pnpm test"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
}

@test "gate-cache: an auto-wrapped gate re-opens after a Bash edit too (0.26.0)" {
  setup_v14_gates_policy
  _verdict_on_current_tree
  echo "two" >>"$MOCK_WORKSPACE/src.ts"
  run _run_guard Bash "pnpm basic-check"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh basic")'
}

# --- 0.27.0: every chained command meets [rewrite], [deny] and the direct-runner check
# Only the first command of `a; b` or `cd x && b` used to be judged, so a
# rewrite, a deny row or the direct-runner check never saw `b`. The chain is
# read the way the shell reads it: quotes, substitutions and heredoc bodies
# are never split.

_chain_policy() {
  touch "$MOCK_WORKSPACE/pnpm-lock.yaml"
  echo '{"scripts":{"test-unit":"nx run-many -t test-unit","format":"prettier --write ."}}' \
    >"$MOCK_WORKSPACE/package.json"
  printf '%s\n' '[rewrite]' \
    '^pnpm nx run ([^: ]+):test-unit( .*)?$ | pnpm test-unit \1\2 | route to the gated script' \
    '^pnpm -w run (.+)$ | pnpm \1 | no -w workspace flag' \
    '^(pnpm|npx) env-run (.* )?--env[= ]e2e-local( .*)?$ | pnpm env-run --env=e2e-local | funnel to [deny]' '' \
    '[deny]' 'pnpm env-run --env=e2e-local | the lane owns its environment' \
    'pnpm test-e2e | containerized' '' \
    '[wrap]' 'pnpm test-unit | unit' \
    >"$MOCK_WORKSPACE/.ralph/command-policy"
}

_assert_passes_unchanged() {
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a rewrite reaches a command chained after another (0.27.0)" {
  _chain_policy
  run _run_guard Bash "shellcheck -s sh x.sh; ./node_modules/.bin/nx run canonical-prompt:test-unit --skip-nx-cache 2>&1 | tail -20"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh unit pnpm test-unit canonical-prompt --skip-nx-cache$")'
}

@test "a rewrite keeps the rest of the chain as written (0.27.0)" {
  _chain_policy
  run _run_guard Bash "cd apps && pnpm -w run format && git status --short"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command == "cd apps && pnpm format && git status --short"'
}

@test "every rewritten command in a chain is rewritten (0.27.0)" {
  _chain_policy
  run _run_guard Bash $'pnpm -w run format\npnpm -w run format --check'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command == "pnpm format\npnpm format --check"'
}

@test "a [deny] row fires on a command chained after a cd (0.27.0)" {
  _chain_policy
  run _run_guard Bash "cd infra && ../node_modules/.bin/env-run --env=e2e-local -- docker compose up -d"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("the lane owns its environment")'
}

@test "a newline chains commands just as ; does (0.27.0)" {
  _chain_policy
  run _run_guard Bash $'cd infra\nnpx env-run --env e2e-local -- docker compose ps'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("the lane owns its environment")'
}

@test "a [deny] later in the chain wins over a [wrap] earlier in it (0.27.0)" {
  _chain_policy
  run _run_guard Bash "pnpm test-unit && pnpm test-e2e"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("containerized")'
}

@test "the direct-runner check reaches a chained command (0.27.0)" {
  run _run_guard Bash "cd apps/api && npx vitest run src/a.spec.ts"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("Direct test runner")'
}

@test "a runner after a gate-run.sh command is still judged (0.27.0)" {
  echo "$(date +%s)" >"$STATE_DIR/last-write-ts"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh unit pnpm test-unit && pnpm exec vitest run"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("Direct test runner")'
}

@test "separators inside a quoted commit message do not chain (0.27.0)" {
  _chain_policy
  run _run_guard Bash 'git commit -q -m "docs: note; pnpm nx run api:test-unit && npx vitest run"'
  _assert_passes_unchanged
}

@test "a gated script named in a quoted commit message is not wrapped (0.27.0)" {
  # The [wrap] chain split used to cut at the `;` inside the quotes and
  # replace the whole commit with `gate-run.sh unit pnpm test-unit passes"`.
  _chain_policy
  run _run_guard Bash 'git commit -q -m "test: cover the lane; pnpm test-unit passes"'
  _assert_passes_unchanged
}

@test "a heredoc body is not chained commands (0.27.0)" {
  _chain_policy
  run _run_guard Bash $'git commit -q -F - <<\'EOF\'\nfix: route tests\n\npnpm nx run api:test-unit; npx vitest run\ncd infra && npx env-run --env=e2e-local -- up\nEOF'
  _assert_passes_unchanged
}

@test "a heredoc inside a command substitution is not chained commands (0.27.0)" {
  _chain_policy
  run _run_guard Bash $'git commit -q -m "$(cat <<\'EOF\'\nfix: x; npx vitest run\nsecond && pnpm -w run format\nEOF\n)"'
  _assert_passes_unchanged
}

@test "a comment is not a chained command (0.27.0)" {
  _chain_policy
  run _run_guard Bash "git status # then; npx vitest run"
  _assert_passes_unchanged
}

@test "a backgrounding & chains, a 2>&1 redirect does not (0.27.0)" {
  run _run_guard Bash "nohup node server.js > /tmp/log 2>&1 & npx vitest run"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("Direct test runner")'
}

# --- 0.27.0: pnpm's -s / --silent flag is not a way around the policy ---------

@test "pnpm -s nx meets the project's nx rewrite and [wrap] (0.27.0)" {
  _chain_policy
  run _run_guard Bash "pnpm -s nx run api:test-unit"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh unit pnpm test-unit api$")'
}

@test "pnpm --silent exec nx meets the project's nx rewrite and [wrap] (0.27.0)" {
  _chain_policy
  run _run_guard Bash "pnpm --silent exec nx run api:test-unit --skip-nx-cache"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh unit pnpm test-unit api --skip-nx-cache$")'
}

@test "pnpm run -s <script> meets [wrap] (0.27.0)" {
  _chain_policy
  run _run_guard Bash "pnpm run -s test-unit"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command | test("gate-run.sh unit pnpm test-unit$")'
}

@test "pnpm -s vitest is a direct runner (0.27.0)" {
  run _run_guard Bash "pnpm -s vitest run"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("Direct test runner")'
}

# --- 0.27.0: a [rewrite] regex may use | alternation ---------------------------
# Fields split on a `|` with whitespace on both sides; a row without one
# splits on bare `|`, as compact rows always have.

@test "a [rewrite] regex may use alternation (0.27.0)" {
  printf '%s\n' '[rewrite]' \
    '^(pnpm|npx) nx run ([^: ]+):test-unit( .*)?$ | pnpm \2:test-unit\3 | either launcher' \
    >"$MOCK_WORKSPACE/.ralph/command-policy"
  run _run_guard Bash "npx nx run api:test-unit --watch=false"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command == "pnpm api:test-unit --watch=false"'
  run _run_guard Bash "pnpm nx run api:test-unit"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command == "pnpm api:test-unit"'
}

@test "a compact [rewrite] row without spaces around | still parses (0.27.0)" {
  printf '%s\n' '[rewrite]' '^pnpm -w run (.+)$|pnpm \1|no -w workspace flag' \
    >"$MOCK_WORKSPACE/.ralph/command-policy"
  run _run_guard Bash "pnpm -w run format"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command == "pnpm format"'
}

@test "a [rewrite] reason may contain | itself (0.27.0)" {
  printf '%s\n' '[rewrite]' '^npx pnpm (.+)$ | pnpm \1 | local pnpm | never npx' \
    >"$MOCK_WORKSPACE/.ralph/command-policy"
  run _run_guard Bash "npx pnpm install"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.updatedInput.command == "pnpm install"'
}
