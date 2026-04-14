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

@test "build_prompt framing is under 30 lines (excluding user body)" {
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  # Count lines before the user body marker "## Task Execution"
  local framing_lines
  framing_lines=$(echo "$output" | sed '/^## Task Execution$/,$d' | wc -l | tr -d ' ')

  # Framing should be concise — under 30 lines
  [ "$framing_lines" -le 30 ]
}

@test "build_prompt includes required sections" {
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  echo "$output" | grep -q "State Files"
  echo "$output" | grep -q "Signals"
  echo "$output" | grep -q "Loop Hygiene"
  echo "$output" | grep -q "Task Execution"
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

@test "build_prompt includes iteration number" {
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 7)

  echo "$output" | grep -q "Iteration 7"
}

@test "build_prompt includes user body from effective prompt" {
  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 1)

  echo "$output" | grep -q "Mock task body"
}

@test "build_prompt prepends recovery hint when present (0.3.0)" {
  # Simulate a prior iteration's stream-parser having written a hint
  cat > "$MOCK_WORKSPACE/.ralph/recovery-hint.md" <<EOF
## Recovery Hint from Prior Iteration

Your prior iteration ran \`pnpm test\` twice with exit code 1. Do not retry it.
EOF

  local output
  output=$(build_prompt "$MOCK_WORKSPACE" 5)

  # Hint section appears
  echo "$output" | grep -q "Recovery Hint from Prior Iteration"
  echo "$output" | grep -q "pnpm test"
  # Hint appears between the iteration header and State Files (recovery is authoritative steering)
  echo "$output" | awk '
    /^# Ralph Iteration 5/ { saw_header=1 }
    /Recovery Hint from Prior Iteration/ { if (saw_header && !saw_state) saw_hint=1 }
    /^## State Files/ { saw_state=1 }
    END { exit (saw_hint && saw_state) ? 0 : 1 }
  '
}

@test "build_prompt deletes recovery hint after consumption (consume-once) (0.3.0)" {
  echo "## Recovery Hint from Prior Iteration" > "$MOCK_WORKSPACE/.ralph/recovery-hint.md"
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
  if echo "$output" | grep -q "Recovery Hint from Prior Iteration"; then
    fail "build_prompt should not include a Recovery Hint section when no hint file exists"
  fi
}
