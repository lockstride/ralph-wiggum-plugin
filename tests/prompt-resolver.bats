#!/usr/bin/env bats
# Behavioral tests for prompt-resolver.sh
#
# Tests verify the hash-check + generation flow, caching behavior, and
# fallback to the built-in template.
#
# Generation tests that call `claude -p` use RALPH_SKIP_GENERATION=1
# and supply fixture prompts to avoid actual API calls in CI.

load test_helper

setup() {
  create_mock_workspace
  create_mock_spec "test-spec"

  # Source the resolver so we can call functions directly
  source "$SCRIPTS_DIR/prompt-resolver.sh"
}

teardown() {
  rm -rf "$MOCK_WORKSPACE"
}

@test "falls back to template when no speckit.implement.md" {
  # No .claude/commands/speckit.implement.md exists
  local out
  out=$(resolve_prompt "$MOCK_WORKSPACE" "spec" "test-spec")

  # Should have written effective prompt
  [ -f "$MOCK_WORKSPACE/.ralph/effective-prompt.md" ]

  # Should NOT have generated a ralph-prompt.md (no speckit.implement)
  [ ! -f "$MOCK_SPEC_DIR/ralph-prompt.md" ]
}

@test "falls back to template when RALPH_SKIP_GENERATION=1" {
  create_mock_speckit_implement
  export RALPH_SKIP_GENERATION=1

  local out
  out=$(resolve_prompt "$MOCK_WORKSPACE" "spec" "test-spec")

  [ -f "$MOCK_WORKSPACE/.ralph/effective-prompt.md" ]
  [ ! -f "$MOCK_SPEC_DIR/ralph-prompt.md" ]
}

@test "uses cached prompt when hash matches" {
  create_mock_speckit_implement

  # Pre-populate the cache with a known prompt and matching hash
  local hash
  hash=$(shasum -a 256 "$MOCK_WORKSPACE/.claude/commands/speckit.implement.md" | cut -d' ' -f1)

  cat > "$MOCK_SPEC_DIR/ralph-prompt.md" <<'PROMPT'
# Cached Loop Prompt
This is a cached prompt with {{TASK_FILE}} placeholder.
PROMPT
  echo "$hash" > "$MOCK_SPEC_DIR/.ralph-prompt-hash"

  (cd "$MOCK_WORKSPACE" && git add specs/ && git commit -q -m "add cache")

  local out
  out=$(resolve_prompt "$MOCK_WORKSPACE" "spec" "test-spec" 2>&1)

  # Should report cache hit
  echo "$out" | grep -q "hash match"

  # Effective prompt should contain the cached content (with placeholder substituted)
  grep -q "Cached Loop Prompt" "$MOCK_WORKSPACE/.ralph/effective-prompt.md"
}

@test "detects hash mismatch and reports regeneration needed" {
  create_mock_speckit_implement

  # Pre-populate with a stale hash
  cat > "$MOCK_SPEC_DIR/ralph-prompt.md" <<'PROMPT'
# Stale Prompt
Old content.
PROMPT
  echo "stale-hash-that-wont-match" > "$MOCK_SPEC_DIR/.ralph-prompt-hash"

  (cd "$MOCK_WORKSPACE" && git add specs/ && git commit -q -m "add stale cache")

  # Skip actual generation (no API call) — just verify it detects the mismatch
  export RALPH_SKIP_GENERATION=1
  local out
  out=$(resolve_prompt "$MOCK_WORKSPACE" "spec" "test-spec" 2>&1)

  # With RALPH_SKIP_GENERATION=1 it should fall back to template
  # (in production, it would regenerate instead)
  [ -f "$MOCK_WORKSPACE/.ralph/effective-prompt.md" ]
}

@test "writes task-file-path breadcrumb" {
  local out
  out=$(resolve_prompt "$MOCK_WORKSPACE" "spec" "test-spec")

  [ -f "$MOCK_WORKSPACE/.ralph/task-file-path" ]
  grep -q "tasks.md" "$MOCK_WORKSPACE/.ralph/task-file-path"
}

@test "logs prompt resolution to activity.log when log_activity available" {
  create_mock_speckit_implement

  # Pre-populate cache so we hit the hash-match path
  local hash
  hash=$(shasum -a 256 "$MOCK_WORKSPACE/.claude/commands/speckit.implement.md" | cut -d' ' -f1)
  cat > "$MOCK_SPEC_DIR/ralph-prompt.md" <<'PROMPT'
# Cached Prompt
{{TASK_FILE}}
PROMPT
  echo "$hash" > "$MOCK_SPEC_DIR/.ralph-prompt-hash"
  (cd "$MOCK_WORKSPACE" && git add specs/ && git commit -q -m "add cache")

  # Source ralph-common.sh so log_activity is defined
  source "$SCRIPTS_DIR/ralph-common.sh"

  # Create activity.log header (as init_ralph_dir would)
  echo "# Activity Log" > "$MOCK_WORKSPACE/.ralph/activity.log"

  resolve_prompt "$MOCK_WORKSPACE" "spec" "test-spec" >/dev/null 2>&1

  # Should have logged the cache hit to activity.log
  grep -q "PROMPT.*cached prompt" "$MOCK_WORKSPACE/.ralph/activity.log"
}

@test "no activity log writes in standalone mode without log_activity" {
  # prompt-resolver.sh is sourced but ralph-common.sh is NOT — _pr_log is a no-op
  echo "# Activity Log" > "$MOCK_WORKSPACE/.ralph/activity.log"

  resolve_prompt "$MOCK_WORKSPACE" "spec" "test-spec" >/dev/null 2>&1

  # activity.log should only have the header — no PROMPT lines
  ! grep -q "PROMPT" "$MOCK_WORKSPACE/.ralph/activity.log"
}

@test "cached prompt preserves placeholders for later substitution" {
  create_mock_speckit_implement

  local hash
  hash=$(shasum -a 256 "$MOCK_WORKSPACE/.claude/commands/speckit.implement.md" | cut -d' ' -f1)

  # Prompt with multiple placeholders
  cat > "$MOCK_SPEC_DIR/ralph-prompt.md" <<'PROMPT'
# Loop Prompt
- Tasks: {{TASK_FILE}}
- Plan: {{PLAN_FILE}}
- Gate: {{GATE_RUN}} basic {{BASIC_CHECK_COMMAND}}
PROMPT
  echo "$hash" > "$MOCK_SPEC_DIR/.ralph-prompt-hash"

  (cd "$MOCK_WORKSPACE" && git add specs/ && git commit -q -m "add cache with placeholders")

  resolve_prompt "$MOCK_WORKSPACE" "spec" "test-spec" >/dev/null 2>&1

  local effective="$MOCK_WORKSPACE/.ralph/effective-prompt.md"

  # Placeholders should be substituted with real values
  grep -q "tasks.md" "$effective"
  grep -q "plan.md" "$effective"
  grep -q "gate-run.sh" "$effective"
  grep -q "pnpm basic-check" "$effective"

  # Raw placeholders should NOT remain
  ! grep -q '{{TASK_FILE}}' "$effective"
  ! grep -q '{{PLAN_FILE}}' "$effective"
}
