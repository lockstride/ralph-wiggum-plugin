#!/usr/bin/env bats
# Behavioral tests for ralph-evaluate.sh
#
# Sources the script (which only runs main() when invoked directly) and
# exercises the helper functions: parse_args, resolve_ground_truth,
# seed_report, render_orchestrator_prompt.

load test_helper

setup() {
  create_mock_workspace
  # The script sources ralph-common.sh and prompt-resolver.sh. Those need
  # agent-adapter.sh available too. Sourcing ralph-evaluate.sh handles
  # the chain for us.
  source "$SCRIPTS_DIR/ralph-evaluate.sh"
}

teardown() {
  rm -rf "$MOCK_WORKSPACE"
}

# -----------------------------------------------------------------------------
# parse_args
# -----------------------------------------------------------------------------

@test "parse_args: --prompt sets mode = prompt" {
  GROUND_TRUTH_MODE=""
  GROUND_TRUTH_VALUE=""
  parse_args --prompt
  [ "$GROUND_TRUTH_MODE" = "prompt" ]
  [ -z "$GROUND_TRUTH_VALUE" ]
}

@test "parse_args: --prompt-file captures path" {
  GROUND_TRUTH_MODE=""
  GROUND_TRUTH_VALUE=""
  parse_args --prompt-file some/path.md
  [ "$GROUND_TRUTH_MODE" = "file" ]
  [ "$GROUND_TRUTH_VALUE" = "some/path.md" ]
}

@test "parse_args: --spec without name sets empty value" {
  GROUND_TRUTH_MODE=""
  GROUND_TRUTH_VALUE=""
  parse_args --spec
  [ "$GROUND_TRUTH_MODE" = "spec" ]
  [ -z "$GROUND_TRUTH_VALUE" ]
}

@test "parse_args: --spec name captures name" {
  GROUND_TRUTH_MODE=""
  GROUND_TRUTH_VALUE=""
  parse_args --spec my-feature
  [ "$GROUND_TRUTH_MODE" = "spec" ]
  [ "$GROUND_TRUTH_VALUE" = "my-feature" ]
}

@test "parse_args: --fresh flips FRESH to true" {
  FRESH=false
  parse_args --prompt --fresh
  [ "$FRESH" = "true" ]
}

@test "parse_args: -n and --iterations capture eval-iter cap" {
  EVAL_ITER_FROM_FLAG=""
  parse_args -n 8
  [ "$EVAL_ITER_FROM_FLAG" = "8" ]

  EVAL_ITER_FROM_FLAG=""
  parse_args --iterations 12
  [ "$EVAL_ITER_FROM_FLAG" = "12" ]
}

# -----------------------------------------------------------------------------
# resolve_ground_truth
# -----------------------------------------------------------------------------

@test "resolve_ground_truth: prompt mode returns workspace PROMPT.md" {
  echo "# prompt" > "$MOCK_WORKSPACE/PROMPT.md"
  local got
  got=$(resolve_ground_truth "$MOCK_WORKSPACE" prompt "")
  [ "$got" = "$MOCK_WORKSPACE/PROMPT.md" ]
}

@test "resolve_ground_truth: prompt mode fails when PROMPT.md missing" {
  run resolve_ground_truth "$MOCK_WORKSPACE" prompt ""
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "PROMPT.md not found"
}

@test "resolve_ground_truth: file mode accepts workspace-relative path" {
  echo "# custom" > "$MOCK_WORKSPACE/custom.md"
  local got
  got=$(resolve_ground_truth "$MOCK_WORKSPACE" file "custom.md")
  [ "$got" = "$MOCK_WORKSPACE/custom.md" ]
}

@test "resolve_ground_truth: file mode accepts absolute path" {
  echo "# custom" > "$MOCK_WORKSPACE/abs.md"
  local got
  got=$(resolve_ground_truth "$MOCK_WORKSPACE" file "$MOCK_WORKSPACE/abs.md")
  [ "$got" = "$MOCK_WORKSPACE/abs.md" ]
}

@test "resolve_ground_truth: file mode fails for missing path" {
  run resolve_ground_truth "$MOCK_WORKSPACE" file "nonexistent.md"
  [ "$status" -ne 0 ]
}

@test "resolve_ground_truth: spec mode resolves newest spec when name omitted" {
  create_mock_spec "alpha"
  local got
  got=$(resolve_ground_truth "$MOCK_WORKSPACE" spec "")
  [ "$got" = "$MOCK_WORKSPACE/specs/alpha/tasks.md" ]
}

@test "resolve_ground_truth: spec mode resolves named spec" {
  create_mock_spec "beta"
  local got
  got=$(resolve_ground_truth "$MOCK_WORKSPACE" spec "beta")
  [ "$got" = "$MOCK_WORKSPACE/specs/beta/tasks.md" ]
}

@test "resolve_ground_truth: unknown mode fails" {
  run resolve_ground_truth "$MOCK_WORKSPACE" invalid ""
  [ "$status" -ne 0 ]
}

# -----------------------------------------------------------------------------
# seed_report
# -----------------------------------------------------------------------------

@test "seed_report: creates report when missing and substitutes ground-truth" {
  FRESH=false
  seed_report "$MOCK_WORKSPACE" "$MOCK_WORKSPACE/PROMPT.md"

  local report="$MOCK_WORKSPACE/.ralph/acceptance-report.md"
  [ -f "$report" ]
  grep -q "Acceptance Report" "$report"
  grep -q "$MOCK_WORKSPACE/PROMPT.md" "$report"
  # Top-level checkbox must exist and be unchecked so the loop has something to track.
  grep -qE '^- \[ \] All acceptance criteria met and verified' "$report"
  ! grep -q '{{GROUND_TRUTH_PATH}}' "$report"
}

@test "seed_report: is idempotent when report already exists" {
  FRESH=false
  mkdir -p "$MOCK_WORKSPACE/.ralph"
  echo "preserved contents" > "$MOCK_WORKSPACE/.ralph/acceptance-report.md"

  seed_report "$MOCK_WORKSPACE" "$MOCK_WORKSPACE/PROMPT.md"

  # Existing content is not overwritten
  grep -q "preserved contents" "$MOCK_WORKSPACE/.ralph/acceptance-report.md"
}

@test "seed_report: --fresh mode wipes and re-seeds" {
  FRESH=true
  mkdir -p "$MOCK_WORKSPACE/.ralph"
  echo "stale contents" > "$MOCK_WORKSPACE/.ralph/acceptance-report.md"

  seed_report "$MOCK_WORKSPACE" "$MOCK_WORKSPACE/PROMPT.md"

  ! grep -q "stale contents" "$MOCK_WORKSPACE/.ralph/acceptance-report.md"
  grep -q "Acceptance Report" "$MOCK_WORKSPACE/.ralph/acceptance-report.md"
}

# -----------------------------------------------------------------------------
# render_orchestrator_prompt
# -----------------------------------------------------------------------------

@test "render_orchestrator_prompt: writes thin framing pointing at running-acceptance-evaluation skill (0.6.0)" {
  local report="$MOCK_WORKSPACE/.ralph/acceptance-report.md"
  mkdir -p "$(dirname "$report")"
  touch "$report"

  render_orchestrator_prompt "$MOCK_WORKSPACE" "$MOCK_WORKSPACE/PROMPT.md" "$report" >/dev/null

  local effective="$MOCK_WORKSPACE/.ralph/effective-prompt.md"
  [ -f "$effective" ]
  # Framing must reference the orchestrator skill by name.
  grep -q "running-acceptance-evaluation" "$effective"
  # Per-run paths are substituted in the framing.
  grep -q "$MOCK_WORKSPACE/PROMPT.md" "$effective"
  grep -q "$report" "$effective"
}

@test "render_orchestrator_prompt: framing references both role skills by name (0.6.0)" {
  local report="$MOCK_WORKSPACE/.ralph/acceptance-report.md"
  mkdir -p "$(dirname "$report")"
  touch "$report"

  render_orchestrator_prompt "$MOCK_WORKSPACE" "$MOCK_WORKSPACE/PROMPT.md" "$report" >/dev/null

  local effective="$MOCK_WORKSPACE/.ralph/effective-prompt.md"
  # Both role skills are mentioned in the framing so the orchestrator
  # skill knows what sub-agents should invoke.
  grep -q "verifying-acceptance-criteria" "$effective"
  grep -q "addressing-acceptance-gaps" "$effective"
}

@test "render_orchestrator_prompt: framing is short — orchestrator content lives in the skill (0.6.0)" {
  local report="$MOCK_WORKSPACE/.ralph/acceptance-report.md"
  mkdir -p "$(dirname "$report")"
  touch "$report"

  render_orchestrator_prompt "$MOCK_WORKSPACE" "$MOCK_WORKSPACE/PROMPT.md" "$report" >/dev/null

  local effective="$MOCK_WORKSPACE/.ralph/effective-prompt.md"
  # Pre-0.6.0 the orchestrator template inlined ~150 lines including both
  # role bodies. Post-0.6.0 the framing is a thin pointer (< 50 lines)
  # because everything load-bearing moved to skills.
  local lines
  lines=$(wc -l < "$effective" | tr -d ' ')
  [ "$lines" -lt 80 ]
}
