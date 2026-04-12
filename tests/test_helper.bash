#!/bin/bash
# Shared test helpers for ralph-wiggum-plugin bats tests.
#
# Source this in setup() of each .bats file:
#   load test_helper
#
# Provides:
#   - PLUGIN_ROOT: absolute path to the plugin repo root
#   - SCRIPTS_DIR: absolute path to shared-scripts/
#   - TEMPLATES_DIR: absolute path to shared-references/templates/
#   - create_mock_workspace: sets up a temp workspace with .ralph/ and git init
#   - MOCK_WORKSPACE: path to the mock workspace (set by create_mock_workspace)

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$PLUGIN_ROOT/shared-scripts"
TEMPLATES_DIR="$PLUGIN_ROOT/shared-references/templates"

# Create a temporary mock workspace with the minimum structure Ralph expects.
# Sets MOCK_WORKSPACE to the created path. Cleaned up automatically by bats
# via BATS_TMPDIR.
create_mock_workspace() {
  MOCK_WORKSPACE="$(mktemp -d "$BATS_TMPDIR/ralph-test-XXXXXX")"
  mkdir -p "$MOCK_WORKSPACE/.ralph/gates"

  # Initialize a git repo so git operations work
  (
    cd "$MOCK_WORKSPACE" || exit 1
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo ".ralph/" > .gitignore
    git add .gitignore
    git commit -q -m "init"
  )

  export MOCK_WORKSPACE
  export RALPH_WORKSPACE="$MOCK_WORKSPACE"
}

# Create a mock spec directory inside the workspace
# Usage: create_mock_spec "my-spec"
# Sets MOCK_SPEC_DIR
create_mock_spec() {
  local spec_name="${1:-test-spec}"
  MOCK_SPEC_DIR="$MOCK_WORKSPACE/specs/$spec_name"
  mkdir -p "$MOCK_SPEC_DIR"

  cat > "$MOCK_SPEC_DIR/tasks.md" <<'TASKS'
# Tasks

## Phase 1: Setup
- [ ] T001 Create initial structure
- [ ] T002 Add configuration
TASKS

  cat > "$MOCK_SPEC_DIR/plan.md" <<'PLAN'
# Plan
Basic implementation plan.
PLAN

  cat > "$MOCK_SPEC_DIR/spec.md" <<'SPEC'
# Spec
Feature specification.
SPEC

  (
    cd "$MOCK_WORKSPACE" || exit 1
    git add specs/
    git commit -q -m "add spec"
  )

  export MOCK_SPEC_DIR
}

# Create a mock speckit.implement.md command file
create_mock_speckit_implement() {
  mkdir -p "$MOCK_WORKSPACE/.claude/commands"
  cat > "$MOCK_WORKSPACE/.claude/commands/speckit.implement.md" <<'SKILL'
---
description: Execute implementation tasks
---

## Outline

1. Read tasks.md
2. Execute tasks phase by phase
3. Mark completed tasks as [X]
4. Validate completion
SKILL

  (
    cd "$MOCK_WORKSPACE" || exit 1
    git add .claude/
    git commit -q -m "add speckit.implement"
  )
}
