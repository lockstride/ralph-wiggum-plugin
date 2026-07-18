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
  unset RALPH_EVAL_FRAMING_TEMPLATE RALPH_EVAL_REPORT_TEMPLATE
}

# -----------------------------------------------------------------------------
# parse_args
# -----------------------------------------------------------------------------

@test "parse_args: ground-truth modes (--prompt / --prompt-file / --spec)" {
  # Single test exercising all three mode flags + the optional name on
  # --spec. Previously this was 4 separate tests.
  GROUND_TRUTH_MODE=""; GROUND_TRUTH_VALUE=""
  parse_args --prompt
  [ "$GROUND_TRUTH_MODE" = "prompt" ]
  [ -z "$GROUND_TRUTH_VALUE" ]

  GROUND_TRUTH_MODE=""; GROUND_TRUTH_VALUE=""
  parse_args --prompt-file some/path.md
  [ "$GROUND_TRUTH_MODE" = "file" ]
  [ "$GROUND_TRUTH_VALUE" = "some/path.md" ]

  GROUND_TRUTH_MODE=""; GROUND_TRUTH_VALUE=""
  parse_args --spec
  [ "$GROUND_TRUTH_MODE" = "spec" ]
  [ -z "$GROUND_TRUTH_VALUE" ]

  GROUND_TRUTH_MODE=""; GROUND_TRUTH_VALUE=""
  parse_args --spec my-feature
  [ "$GROUND_TRUTH_VALUE" = "my-feature" ]
}

@test "parse_args: --fresh flips FRESH to true" {
  FRESH=false
  parse_args --prompt --fresh
  [ "$FRESH" = "true" ]
}

@test "parse_args: -n and --loops capture the eval loop cap" {
  # 0.12.5: dropped the deprecated `--iterations` alias after verifying
  # zero usage in consuming projects.
  EVAL_ITER_FROM_FLAG=""
  parse_args -n 8
  [ "$EVAL_ITER_FROM_FLAG" = "8" ]

  EVAL_ITER_FROM_FLAG=""
  parse_args --loops 10
  [ "$EVAL_ITER_FROM_FLAG" = "10" ]
}

# -----------------------------------------------------------------------------
# RALPH_EVAL_MAX_LOOPS env var (0.11.8)
# -----------------------------------------------------------------------------

@test "eval MAX_LOOPS defaults to 10 when no flag or env var is set (0.11.8)" {
  unset RALPH_EVAL_MAX_LOOPS
  EVAL_ITER_FROM_FLAG=""
  local MAX_LOOPS="${EVAL_ITER_FROM_FLAG:-${RALPH_EVAL_MAX_LOOPS:-10}}"
  [ "$MAX_LOOPS" = "10" ]
}

@test "RALPH_EVAL_MAX_LOOPS env var overrides the default (0.11.8)" {
  export RALPH_EVAL_MAX_LOOPS=15
  EVAL_ITER_FROM_FLAG=""
  local MAX_LOOPS="${EVAL_ITER_FROM_FLAG:-${RALPH_EVAL_MAX_LOOPS:-10}}"
  [ "$MAX_LOOPS" = "15" ]
  unset RALPH_EVAL_MAX_LOOPS
}

@test "--loops flag takes precedence over RALPH_EVAL_MAX_LOOPS env var (0.11.8)" {
  export RALPH_EVAL_MAX_LOOPS=15
  EVAL_ITER_FROM_FLAG=""
  parse_args --loops 7
  local MAX_LOOPS="${EVAL_ITER_FROM_FLAG:-${RALPH_EVAL_MAX_LOOPS:-10}}"
  [ "$MAX_LOOPS" = "7" ]
  unset RALPH_EVAL_MAX_LOOPS
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

@test "render_orchestrator_prompt: framing warns against signaling COMPLETE directly (0.14.8)" {
  local report="$MOCK_WORKSPACE/.ralph/acceptance-report.md"
  mkdir -p "$(dirname "$report")"
  touch "$report"

  render_orchestrator_prompt "$MOCK_WORKSPACE" "$MOCK_WORKSPACE/PROMPT.md" "$report" >/dev/null

  local effective="$MOCK_WORKSPACE/.ralph/effective-prompt.md"
  # test/000534 eval loop 1: the agent ran a cached gate and signaled
  # COMPLETE without invoking the skill. The completion guard rejected it,
  # but each miss burns a loop — the framing now states completion keys on
  # the acceptance-report checkbox.
  grep -q "Do not signal COMPLETE directly" "$effective"
}

# -----------------------------------------------------------------------------
# Template overrides (0.17.0)
#
# RALPH_EVAL_REPORT_TEMPLATE / RALPH_EVAL_FRAMING_TEMPLATE let a consuming
# project reroute the eval loop through its own report shape and orchestrator
# skill (e.g. a Linear ticket ledger) without forking the loop.
# -----------------------------------------------------------------------------

@test "seed_report: RALPH_EVAL_REPORT_TEMPLATE override is used and substituted (0.17.0)" {
  FRESH=false
  mkdir -p "$MOCK_WORKSPACE/custom"
  cat > "$MOCK_WORKSPACE/custom/ledger.md" <<'TPL'
# Ticket Ledger
- [ ] All target tickets terminal
**Ground truth:** {{GROUND_TRUTH_PATH}}
TPL

  # Workspace-relative path resolution.
  export RALPH_EVAL_REPORT_TEMPLATE="custom/ledger.md"
  seed_report "$MOCK_WORKSPACE" "$MOCK_WORKSPACE/plan.md"

  local report="$MOCK_WORKSPACE/.ralph/acceptance-report.md"
  [ -f "$report" ]
  grep -q "Ticket Ledger" "$report"
  grep -q "$MOCK_WORKSPACE/plan.md" "$report"
  ! grep -q '{{GROUND_TRUTH_PATH}}' "$report"
  # Stock template content must NOT be present.
  ! grep -q "Acceptance Report" "$report"
}

@test "seed_report: absolute-path RALPH_EVAL_REPORT_TEMPLATE is accepted (0.17.0)" {
  FRESH=false
  cat > "$MOCK_WORKSPACE/abs-ledger.md" <<'TPL'
# Ledger (absolute)
- [ ] top
TPL

  export RALPH_EVAL_REPORT_TEMPLATE="$MOCK_WORKSPACE/abs-ledger.md"
  seed_report "$MOCK_WORKSPACE" "$MOCK_WORKSPACE/plan.md"
  grep -q "Ledger (absolute)" "$MOCK_WORKSPACE/.ralph/acceptance-report.md"
}

@test "seed_report: missing RALPH_EVAL_REPORT_TEMPLATE fails loudly, no silent fallback (0.17.0)" {
  FRESH=false
  export RALPH_EVAL_REPORT_TEMPLATE="does/not/exist.md"
  run seed_report "$MOCK_WORKSPACE" "$MOCK_WORKSPACE/plan.md"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "RALPH_EVAL_REPORT_TEMPLATE override not found"
  # The stock template must not have been seeded in its place.
  [ ! -f "$MOCK_WORKSPACE/.ralph/acceptance-report.md" ]
}

@test "render_orchestrator_prompt: RALPH_EVAL_FRAMING_TEMPLATE override is rendered with both placeholders (0.17.0)" {
  local report="$MOCK_WORKSPACE/.ralph/acceptance-report.md"
  mkdir -p "$(dirname "$report")"
  touch "$report"

  mkdir -p "$MOCK_WORKSPACE/custom"
  cat > "$MOCK_WORKSPACE/custom/framing.md" <<'TPL'
# Custom verify loop
Invoke the `my-custom-orchestrator` skill.
- Ground truth: {{GROUND_TRUTH_PATH}}
- Ledger: {{REPORT_PATH}}
TPL

  export RALPH_EVAL_FRAMING_TEMPLATE="custom/framing.md"
  render_orchestrator_prompt "$MOCK_WORKSPACE" "$MOCK_WORKSPACE/plan.md" "$report" >/dev/null

  local effective="$MOCK_WORKSPACE/.ralph/effective-prompt.md"
  [ -f "$effective" ]
  grep -q "my-custom-orchestrator" "$effective"
  grep -q "$MOCK_WORKSPACE/plan.md" "$effective"
  grep -q "$report" "$effective"
  ! grep -q '{{GROUND_TRUTH_PATH}}' "$effective"
  ! grep -q '{{REPORT_PATH}}' "$effective"
  # Stock framing content must NOT be present.
  ! grep -q "running-acceptance-evaluation" "$effective"
}

@test "render_orchestrator_prompt: missing RALPH_EVAL_FRAMING_TEMPLATE fails loudly (0.17.0)" {
  local report="$MOCK_WORKSPACE/.ralph/acceptance-report.md"
  mkdir -p "$(dirname "$report")"
  touch "$report"

  export RALPH_EVAL_FRAMING_TEMPLATE="does/not/exist.md"
  run render_orchestrator_prompt "$MOCK_WORKSPACE" "$MOCK_WORKSPACE/plan.md" "$report"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "RALPH_EVAL_FRAMING_TEMPLATE override not found"
}

@test "template overrides: unset env vars keep stock templates (0.17.0)" {
  unset RALPH_EVAL_FRAMING_TEMPLATE RALPH_EVAL_REPORT_TEMPLATE
  FRESH=false
  local report="$MOCK_WORKSPACE/.ralph/acceptance-report.md"

  seed_report "$MOCK_WORKSPACE" "$MOCK_WORKSPACE/PROMPT.md"
  grep -q "Acceptance Report" "$report"

  render_orchestrator_prompt "$MOCK_WORKSPACE" "$MOCK_WORKSPACE/PROMPT.md" "$report" >/dev/null
  grep -q "running-acceptance-evaluation" "$MOCK_WORKSPACE/.ralph/effective-prompt.md"
}

# -----------------------------------------------------------------------------
# record_gate_runner (0.14.11)
# -----------------------------------------------------------------------------

@test "record_gate_runner: writes the gate-run.sh absolute path to .ralph/gate-runner" {
  record_gate_runner "$MOCK_WORKSPACE" "/some/plugin/shared-scripts"
  local breadcrumb="$MOCK_WORKSPACE/.ralph/gate-runner"
  [ -f "$breadcrumb" ]
  [ "$(cat "$breadcrumb")" = "/some/plugin/shared-scripts/gate-run.sh" ]
}

@test "record_gate_runner: creates .ralph/ when absent" {
  rm -rf "$MOCK_WORKSPACE/.ralph"
  record_gate_runner "$MOCK_WORKSPACE" "$SCRIPTS_DIR"
  [ -f "$MOCK_WORKSPACE/.ralph/gate-runner" ]
  [ "$(cat "$MOCK_WORKSPACE/.ralph/gate-runner")" = "$SCRIPTS_DIR/gate-run.sh" ]
}
