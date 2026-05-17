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

@test "allows everything when RALPH_WORKSPACE is unset" {
  unset RALPH_WORKSPACE
  run _run_guard Bash "rm -rf .ralph/"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "allows everything when .ralph/ dir does not exist" {
  rm -rf "$MOCK_WORKSPACE/.ralph"
  run _run_guard Bash "rm -rf .ralph/"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- State-tampering denial ---

@test "blocks rm -rf .ralph/" {
  run _run_guard Bash "rm -rf .ralph/"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "block"'
  echo "$output" | jq -e '.reason | test("State tampering")'
}

@test "blocks rm -r .ralph/gates" {
  run _run_guard Bash "rm -r .ralph/gates"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "block"'
}

@test "blocks find .ralph -delete" {
  run _run_guard Bash "find .ralph -name '*.log' -delete"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "block"'
}

# --- Direct test tool denial ---

@test "blocks direct vitest invocation" {
  run _run_guard Bash "vitest run"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "block"'
  echo "$output" | jq -e '.reason | test("gate-run.sh")'
}

@test "blocks npx vitest" {
  run _run_guard Bash "npx vitest run tests/"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "block"'
}

@test "blocks tsc --noEmit" {
  run _run_guard Bash "tsc --noEmit"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "block"'
}

@test "allows vitest through gate-run.sh" {
  # Seed write timestamp so gate-without-write doesn't block
  echo "$(date +%s)" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh basic vitest run"
  [ "$status" -eq 0 ]
  # Either empty (allowed) or has gate-ts update
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.result == "block"' 2>/dev/null
  fi
}

@test "allows vitest through exec" {
  run _run_guard Bash "exec vitest run"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "blocks pnpm vitest" {
  run _run_guard Bash "pnpm vitest run"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "block"'
}

@test "allows bare pnpm test (not in deny list)" {
  run _run_guard Bash "pnpm test"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- Protected scripts pipe/redirect denial ---

@test "blocks pipe on protected script" {
  export RALPH_PROTECTED_SCRIPTS="pnpm basic-check pnpm all-check"
  run _run_guard Bash "pnpm basic-check | tail -20"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "block"'
  echo "$output" | jq -e '.reason | test("pipe/redirect")'
}

@test "blocks redirect on protected script" {
  export RALPH_PROTECTED_SCRIPTS="pnpm basic-check"
  run _run_guard Bash "pnpm basic-check > /tmp/out.log"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "block"'
}

@test "allows protected script without pipe" {
  export RALPH_PROTECTED_SCRIPTS="pnpm basic-check"
  run _run_guard Bash "pnpm basic-check"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "allows protected script with arguments" {
  export RALPH_PROTECTED_SCRIPTS="pnpm basic-check"
  run _run_guard Bash "pnpm basic-check tests/foo.spec.ts"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- Gate-without-write check ---

@test "blocks gate re-run with no write since last gate" {
  echo "$(date +%s)" > "$STATE_DIR/last-gate-ts"
  echo "0" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh basic pnpm test"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "block"'
  echo "$output" | jq -e '.reason | test("identical output")'
}

@test "allows gate run after a write" {
  echo "1" > "$STATE_DIR/last-gate-ts"
  echo "$(date +%s)" > "$STATE_DIR/last-write-ts"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh basic pnpm test"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.result == "block"' 2>/dev/null
  fi
}

@test "allows first gate run (no prior gate timestamp)" {
  rm -f "$STATE_DIR/last-gate-ts"
  run _run_guard Bash "bash $SCRIPTS_DIR/gate-run.sh basic pnpm test"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.result == "block"' 2>/dev/null
  fi
}

# --- Write/Edit forbidden-path denial ---

@test "blocks write to .ralph/gates/" {
  run _run_guard Write "$MOCK_WORKSPACE/.ralph/gates/foo.log"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "block"'
}

@test "blocks write to .ralph/activity.log" {
  run _run_guard Edit "$MOCK_WORKSPACE/.ralph/activity.log"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "block"'
}

@test "allows write to .ralph/handoff.md" {
  run _run_guard Write "$MOCK_WORKSPACE/.ralph/handoff.md"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.result == "block"' 2>/dev/null
  fi
}

@test "allows write to .ralph/errors.log" {
  run _run_guard Write "$MOCK_WORKSPACE/.ralph/errors.log"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.result == "block"' 2>/dev/null
  fi
}

@test "allows write to .ralph/guardrails.md" {
  run _run_guard Write "$MOCK_WORKSPACE/.ralph/guardrails.md"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.result == "block"' 2>/dev/null
  fi
}

@test "allows write to normal project files" {
  run _run_guard Write "$MOCK_WORKSPACE/src/app.ts"
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ! echo "$output" | jq -e '.result == "block"' 2>/dev/null
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
  echo "$output" | jq -e '.result == "block"'
}

@test "blocks cypress with env prefix" {
  run _run_guard Bash "CI=true npx cypress run"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "block"'
}

# --- .ralph/protected-scripts breadcrumb ---

@test "blocks pipe on command listed in .ralph/protected-scripts" {
  printf 'pnpm all-check\npnpm basic-check\n' > "$MOCK_WORKSPACE/.ralph/protected-scripts"
  run _run_guard Bash "pnpm all-check | tail -20"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "block"'
  echo "$output" | jq -e '.reason | test("pipe/redirect")'
}

@test "allows bare command listed in .ralph/protected-scripts" {
  printf 'pnpm all-check\n' > "$MOCK_WORKSPACE/.ralph/protected-scripts"
  run _run_guard Bash "pnpm all-check"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "protected-scripts file ignores comments and blank lines" {
  printf '# gate commands\npnpm all-check\n\n# lint\npnpm lint:check\n' > "$MOCK_WORKSPACE/.ralph/protected-scripts"
  run _run_guard Bash "pnpm lint:check | grep error"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "block"'
}

@test "protected-scripts file takes precedence over env var" {
  export RALPH_PROTECTED_SCRIPTS="pnpm old-check"
  printf 'pnpm new-check\n' > "$MOCK_WORKSPACE/.ralph/protected-scripts"
  # old-check from env should NOT be protected
  run _run_guard Bash "pnpm old-check | tail"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # new-check from file SHOULD be protected
  run _run_guard Bash "pnpm new-check | tail"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "block"'
}

@test "falls back to RALPH_PROTECTED_SCRIPTS env var when no file" {
  rm -f "$MOCK_WORKSPACE/.ralph/protected-scripts"
  export RALPH_PROTECTED_SCRIPTS="pnpm env-check"
  run _run_guard Bash "pnpm env-check | tail"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "block"'
}

# --- .ralph/denied-commands breadcrumb ---

@test "blocks denied command exactly" {
  printf 'pnpm api:test-e2e|Use pnpm api:test-e2e:local instead\n' > "$MOCK_WORKSPACE/.ralph/denied-commands"
  run _run_guard Bash "pnpm api:test-e2e"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "block"'
  echo "$output" | jq -e '.reason | test("local")'
}

@test "blocks denied command with trailing args" {
  printf 'pnpm api:test-e2e|Use the local variant\n' > "$MOCK_WORKSPACE/.ralph/denied-commands"
  run _run_guard Bash "pnpm api:test-e2e --headed"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "block"'
}

@test "denied command does not block longer command names" {
  printf 'pnpm api:test-e2e|blocked\n' > "$MOCK_WORKSPACE/.ralph/denied-commands"
  run _run_guard Bash "pnpm api:test-e2e:local"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "denied-commands ignores comments and blank lines" {
  printf '# expensive commands\n\npnpm test-e2e|Use pnpm test-e2e:local\n' > "$MOCK_WORKSPACE/.ralph/denied-commands"
  run _run_guard Bash "pnpm test-e2e"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "block"'
}

@test "denied command with env prefix is still blocked" {
  printf 'pnpm test-e2e|Use the local variant\n' > "$MOCK_WORKSPACE/.ralph/denied-commands"
  run _run_guard Bash "CI=true pnpm test-e2e"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result == "block"'
}
