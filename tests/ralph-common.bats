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
