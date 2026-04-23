#!/bin/bash
# Ralph Wiggum: Acceptance Evaluation Loop
#
# Runs a second Ralph loop *after* a main implementation loop has finished,
# with an orchestrator prompt that alternates between VERIFIER and REWORK
# roles (each delegated to a sub-agent via the Task tool). The orchestrator
# maintains .ralph/acceptance-report.md; the loop exits when the report's
# top-level "All acceptance criteria met and verified" checkbox is flipped
# to [x] by the verifier, or when the iteration cap (default 5) is hit.
#
# Usage:
#   ./ralph-evaluate.sh --prompt                 # ground truth = PROMPT.md
#   ./ralph-evaluate.sh --prompt-file FOO.md     # ground truth = FOO.md
#   ./ralph-evaluate.sh --spec [name]            # ground truth = specs/<name>/tasks.md
#   ./ralph-evaluate.sh --prompt --fresh         # wipe existing report first
#   ./ralph-evaluate.sh --prompt -n 8 --cli claude -m opus
#
# Flags:
#   --cli <claude|cursor-agent>   Agent CLI (default: claude)
#   -m, --model <id>              Model (default: CLI-specific default)
#   -n, --iterations N            Eval iteration cap (default: 5)
#   --prompt | --prompt-md        Ground truth = PROMPT.md in workspace root
#   --prompt-file <path>          Ground truth = specified file
#   --spec [name]                 Ground truth = specs/<name>/tasks.md (newest if omitted)
#   --fresh                       Delete any existing acceptance-report.md first
#   -h, --help                    Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/agent-adapter.sh"
source "$SCRIPT_DIR/ralph-common.sh"
source "$SCRIPT_DIR/prompt-resolver.sh"

show_help() {
  sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'
}

WORKSPACE=""
CLI_FROM_FLAG=""
MODEL_FROM_FLAG=""
EVAL_ITER_FROM_FLAG=""
GROUND_TRUTH_MODE=""
GROUND_TRUTH_VALUE=""
FRESH=false

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cli)
        CLI_FROM_FLAG="$2"
        shift 2
        ;;
      -m | --model)
        MODEL_FROM_FLAG="$2"
        shift 2
        ;;
      -n | --iterations)
        EVAL_ITER_FROM_FLAG="$2"
        shift 2
        ;;
      --prompt | --prompt-md)
        GROUND_TRUTH_MODE="prompt"
        shift
        ;;
      --prompt-file)
        GROUND_TRUTH_MODE="file"
        GROUND_TRUTH_VALUE="$2"
        shift 2
        ;;
      --spec)
        GROUND_TRUTH_MODE="spec"
        if [[ $# -gt 1 ]] && [[ "${2:0:1}" != "-" ]]; then
          GROUND_TRUTH_VALUE="$2"
          shift 2
        else
          shift
        fi
        ;;
      --fresh)
        FRESH=true
        shift
        ;;
      -h | --help)
        show_help
        exit 0
        ;;
      -*)
        echo "Unknown option: $1" >&2
        exit 1
        ;;
      *)
        WORKSPACE="$1"
        shift
        ;;
    esac
  done
}

# =============================================================================
# GROUND TRUTH RESOLUTION
# =============================================================================

# Resolve the ground-truth file path that the orchestrator re-checks against.
# Echoes the absolute path on success, non-zero on failure.
resolve_ground_truth() {
  local workspace="$1" mode="$2" value="${3:-}"
  case "$mode" in
    prompt)
      local path="$workspace/PROMPT.md"
      if [[ ! -f "$path" ]]; then
        echo "❌ PROMPT.md not found at $path" >&2
        return 1
      fi
      echo "$path"
      ;;
    file)
      if [[ -z "$value" ]]; then
        echo "❌ --prompt-file requires a path" >&2
        return 1
      fi
      if [[ ! -f "$value" ]] && [[ -f "$workspace/$value" ]]; then
        value="$workspace/$value"
      fi
      if [[ ! -f "$value" ]]; then
        echo "❌ Prompt file not found: $value" >&2
        return 1
      fi
      echo "$value"
      ;;
    spec)
      local name="$value"
      if [[ -z "$name" ]]; then
        name=$(list_specs "$workspace" | head -1)
      fi
      if [[ -z "$name" ]]; then
        echo "❌ No specs found under $workspace/specs/" >&2
        return 1
      fi
      local tasks="$workspace/specs/$name/tasks.md"
      if [[ ! -f "$tasks" ]]; then
        echo "❌ tasks.md not found at $tasks" >&2
        return 1
      fi
      echo "$tasks"
      ;;
    *)
      echo "❌ Unknown ground-truth mode: $mode (expected prompt|file|spec)" >&2
      return 1
      ;;
  esac
}

# =============================================================================
# REPORT + PROMPT SETUP
# =============================================================================

# Seed .ralph/acceptance-report.md from template if missing.
# Honors $FRESH: delete-and-recreate when true.
seed_report() {
  local workspace="$1" ground_truth="$2"
  local report="$workspace/.ralph/acceptance-report.md"
  local template
  template="$(_default_templates_dir)/acceptance-report-template.md"

  if [[ "$FRESH" == "true" ]]; then
    rm -f "$report"
  fi

  if [[ -f "$report" ]]; then
    return 0
  fi

  if [[ ! -f "$template" ]]; then
    echo "❌ Acceptance report template not found: $template" >&2
    return 1
  fi

  mkdir -p "$(dirname "$report")"
  # Single placeholder substitution — bash param expansion handles this fine.
  local body
  body=$(cat "$template")
  body="${body//\{\{GROUND_TRUTH_PATH\}\}/$ground_truth}"
  printf '%s' "$body" >"$report"
}

# Render the orchestrator prompt into .ralph/effective-prompt.md with the
# VERIFIER and REWORK role bodies inlined. Uses bash parameter expansion
# (not sed) because role bodies are multi-line.
render_orchestrator_prompt() {
  local workspace="$1" ground_truth="$2" report="$3"
  local tpl_dir
  tpl_dir="$(_default_templates_dir)"

  local orchestrator_tpl="$tpl_dir/evaluator-orchestrator.md"
  local verifier_tpl="$tpl_dir/evaluator-verifier-role.md"
  local rework_tpl="$tpl_dir/evaluator-rework-role.md"

  local t
  for t in "$orchestrator_tpl" "$verifier_tpl" "$rework_tpl"; do
    if [[ ! -f "$t" ]]; then
      echo "❌ Template not found: $t" >&2
      return 1
    fi
  done

  local verifier_body rework_body orchestrator_body
  verifier_body=$(cat "$verifier_tpl")
  rework_body=$(cat "$rework_tpl")
  orchestrator_body=$(cat "$orchestrator_tpl")

  # First: substitute paths in the role bodies (they reference the ground
  # truth and report the same way the orchestrator does).
  verifier_body="${verifier_body//\{\{GROUND_TRUTH_PATH\}\}/$ground_truth}"
  verifier_body="${verifier_body//\{\{REPORT_PATH\}\}/$report}"
  rework_body="${rework_body//\{\{GROUND_TRUTH_PATH\}\}/$ground_truth}"
  rework_body="${rework_body//\{\{REPORT_PATH\}\}/$report}"

  # Then: substitute role bodies + paths into the orchestrator template.
  orchestrator_body="${orchestrator_body//\{\{MODE_VERIFIER_ROLE\}\}/$verifier_body}"
  orchestrator_body="${orchestrator_body//\{\{MODE_REWORK_ROLE\}\}/$rework_body}"
  orchestrator_body="${orchestrator_body//\{\{GROUND_TRUTH_PATH\}\}/$ground_truth}"
  orchestrator_body="${orchestrator_body//\{\{REPORT_PATH\}\}/$report}"

  _write_effective_prompt "$workspace" "$orchestrator_body"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
  if [[ -z "$WORKSPACE" ]] || [[ "$WORKSPACE" == "." ]]; then
    WORKSPACE="$(pwd)"
  else
    WORKSPACE="$(cd "$WORKSPACE" && pwd)"
  fi

  # CLI + model defaults — same cascade as ralph-once.sh so the eval loop
  # feels identical to launch.
  RALPH_AGENT_CLI="${CLI_FROM_FLAG:-${RALPH_AGENT_CLI:-claude}}"
  RALPH_AGENT_CLI="$(agent_normalize_cli_name "$RALPH_AGENT_CLI")"
  local MODEL="${MODEL_FROM_FLAG:-${MODEL:-}}"
  if [[ -z "$MODEL" ]]; then
    MODEL="$(agent_default_model "$RALPH_AGENT_CLI")"
  fi
  local ROTATE_THRESHOLD WARN_THRESHOLD
  ROTATE_THRESHOLD="$(agent_default_rotate_threshold "$RALPH_AGENT_CLI" "$MODEL")"
  WARN_THRESHOLD="$(agent_default_warn_threshold "$RALPH_AGENT_CLI" "$MODEL")"
  local MAX_ITERATIONS="${EVAL_ITER_FROM_FLAG:-5}"

  export RALPH_AGENT_CLI MODEL ROTATE_THRESHOLD WARN_THRESHOLD MAX_ITERATIONS

  if [[ -z "$GROUND_TRUTH_MODE" ]]; then
    # Sensible default: if PROMPT.md exists, use it. Otherwise require explicit flag.
    if [[ -f "$WORKSPACE/PROMPT.md" ]]; then
      GROUND_TRUTH_MODE="prompt"
    else
      echo "❌ No ground-truth source specified. Use --prompt, --prompt-file, or --spec." >&2
      exit 1
    fi
  fi

  echo "═══════════════════════════════════════════════════════════════════"
  echo "🔍 Ralph Wiggum: Acceptance Evaluation Loop"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""

  init_ralph_dir "$WORKSPACE"

  local ground_truth
  if ! ground_truth=$(resolve_ground_truth "$WORKSPACE" "$GROUND_TRUTH_MODE" "$GROUND_TRUTH_VALUE"); then
    exit 1
  fi
  echo "✓ Ground truth: $ground_truth"

  # Record the ground-truth path as a breadcrumb so future tooling can find it.
  echo "$ground_truth" >"$WORKSPACE/.ralph/eval-ground-truth"

  local report="$WORKSPACE/.ralph/acceptance-report.md"
  if ! seed_report "$WORKSPACE" "$ground_truth"; then
    exit 1
  fi
  echo "✓ Report: $report$([[ "$FRESH" == "true" ]] && echo ' (fresh)')"

  # Clear stale gate state so a red gate left behind by the main loop
  # doesn't block the eval-loop completion guard. Eval loop records its
  # own gates under eval-* labels if the sub-agents run any.
  rm -rf "$WORKSPACE/.ralph/gates"
  mkdir -p "$WORKSPACE/.ralph/gates"

  if ! render_orchestrator_prompt "$WORKSPACE" "$ground_truth" "$report" >/dev/null; then
    exit 1
  fi
  echo "✓ Orchestrator prompt rendered to .ralph/effective-prompt.md"

  # Point the loop's completion detector at the acceptance report. The
  # breadcrumb takes precedence over PROMPT.md-style heuristics.
  echo "$report" >"$WORKSPACE/.ralph/task-file-path"
  export RALPH_TASK_FILE="$report"

  if ! check_prerequisites "$WORKSPACE"; then
    exit 1
  fi

  echo ""
  echo "─────────────────────────────────────────────────────────────────"
  echo "Summary:"
  echo "  • CLI:          $RALPH_AGENT_CLI"
  echo "  • Model:        $MODEL"
  echo "  • Max eval iter: $MAX_ITERATIONS"
  echo "  • Ground truth: $ground_truth"
  echo "  • Report:       $report"
  echo "─────────────────────────────────────────────────────────────────"
  echo ""

  local task_status
  task_status=$(check_task_complete "$WORKSPACE")
  if [[ "$task_status" == "COMPLETE" ]]; then
    echo "🎉 Report already clean — nothing to evaluate. Use --fresh to re-run from scratch."
    exit 0
  fi

  run_ralph_loop "$WORKSPACE" "$SCRIPT_DIR"
  exit $?
}

# Standalone entrypoint: only run main() when invoked directly, so tests
# can source this script to exercise resolve_ground_truth / seed_report /
# render_orchestrator_prompt in isolation.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  parse_args "$@"
  main
fi
