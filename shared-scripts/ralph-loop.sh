#!/bin/bash
# Ralph Wiggum: The Loop (CLI-agnostic)
#
# Drives either the Claude Code (`claude`) or Cursor (`cursor-agent`)
# headless CLI through an autonomous development loop with stream-json
# parsing, token accounting, and context rotation.
#
# This script is for power users and scripting. For interactive use,
# see ralph-setup.sh.
#
# Usage:
#   ./ralph-loop.sh                                         # Start in cwd
#   ./ralph-loop.sh /path/to/project                         # Specific workspace
#   ./ralph-loop.sh --cli claude --prompt-file PROMPT.md     # Plain prompt
#   ./ralph-loop.sh --cli cursor-agent --spec               # Most-recent spec
#   ./ralph-loop.sh --cli claude --spec 20260406-foo -n 30   # Named spec
#
# Flags:
#   --cli <claude|cursor-agent>   Agent CLI (default: claude)
#   -m, --model <id>               Model name (default: per-CLI default)
#   -n, --iterations N             Max iterations (default: 20)
#   --prompt | --prompt-md         Use PROMPT.md at workspace root
#   --prompt-file <path>           Use custom prompt file
#   --spec [name]                  Use Spec Kit spec dir (default: most recent)
#   --completion-promise <text>    Custom completion sigil (default: <ralph>COMPLETE</ralph>)
#   --branch <name>                Work on a named branch
#   --pr                           Open a PR when complete (requires --branch)
#   -h, --help                     Show this help
#
# Requirements:
#   - Selected agent CLI installed and logged in
#   - Git repository
#   - jq installed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source stack: adapter → common → prompt-resolver
source "$SCRIPT_DIR/agent-adapter.sh"
source "$SCRIPT_DIR/ralph-common.sh"
source "$SCRIPT_DIR/prompt-resolver.sh"

# =============================================================================
# FLAG PARSING
# =============================================================================

show_help() {
  sed -n '3,35p' "$0" | sed 's/^# \{0,1\}//'
}

WORKSPACE=""
PROMPT_MODE=""       # prompt | file | spec
PROMPT_VALUE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cli)
      RALPH_AGENT_CLI="$2"; shift 2 ;;
    -m|--model)
      MODEL="$2"; shift 2 ;;
    -n|--iterations)
      MAX_ITERATIONS="$2"; shift 2 ;;
    --prompt|--prompt-md)
      PROMPT_MODE="prompt"; shift ;;
    --prompt-file)
      PROMPT_MODE="file"; PROMPT_VALUE="$2"; shift 2 ;;
    --spec)
      PROMPT_MODE="spec"
      # Optional positional after --spec
      if [[ $# -gt 1 ]] && [[ "${2:0:1}" != "-" ]]; then
        PROMPT_VALUE="$2"; shift 2
      else
        shift
      fi
      ;;
    --completion-promise)
      RALPH_COMPLETION_SIGIL="$2"; shift 2 ;;
    --branch)
      USE_BRANCH="$2"; shift 2 ;;
    --pr)
      OPEN_PR=true; shift ;;
    -h|--help)
      show_help; exit 0 ;;
    -*)
      echo "Unknown option: $1" >&2
      echo "Use -h for help." >&2
      exit 1
      ;;
    *)
      WORKSPACE="$1"; shift ;;
  esac
done

# =============================================================================
# MAIN
# =============================================================================

main() {
  # Re-normalize CLI and re-read defaults now that flags are parsed
  RALPH_AGENT_CLI="$(agent_normalize_cli_name "$RALPH_AGENT_CLI")"
  if [[ -z "${MODEL:-}" ]] || [[ "$MODEL" == "$DEFAULT_MODEL" ]]; then
    MODEL="$(agent_default_model "$RALPH_AGENT_CLI")"
  fi
  ROTATE_THRESHOLD="${ROTATE_THRESHOLD:-$(agent_default_rotate_threshold "$RALPH_AGENT_CLI")}"
  WARN_THRESHOLD="${WARN_THRESHOLD:-$(agent_default_warn_threshold "$RALPH_AGENT_CLI")}"
  export MODEL RALPH_AGENT_CLI ROTATE_THRESHOLD WARN_THRESHOLD

  # Resolve workspace
  if [[ -z "$WORKSPACE" ]] || [[ "$WORKSPACE" == "." ]]; then
    WORKSPACE="$(pwd)"
  else
    WORKSPACE="$(cd "$WORKSPACE" && pwd)"
  fi

  show_banner

  # Default prompt mode: PROMPT.md if present, else error
  if [[ -z "$PROMPT_MODE" ]]; then
    if [[ -f "$WORKSPACE/PROMPT.md" ]]; then
      PROMPT_MODE="prompt"
    else
      echo "❌ No prompt source specified. Use --prompt, --prompt-file, or --spec." >&2
      exit 1
    fi
  fi

  # Initialize .ralph before resolving the prompt (effective-prompt.md lives there)
  init_ralph_dir "$WORKSPACE"

  # Resolve prompt
  echo "📝 Resolving prompt source: $PROMPT_MODE${PROMPT_VALUE:+ ($PROMPT_VALUE)}"
  if ! out=$(resolve_prompt "$WORKSPACE" "$PROMPT_MODE" "$PROMPT_VALUE"); then
    exit 1
  fi
  echo "✓ Effective prompt: $out"
  echo ""

  if ! check_prerequisites "$WORKSPACE"; then
    exit 1
  fi

  if [[ "$OPEN_PR" == "true" ]] && [[ -z "$USE_BRANCH" ]]; then
    echo "❌ --pr requires --branch" >&2
    exit 1
  fi

  echo "Workspace: $WORKSPACE"
  echo "CLI:       $RALPH_AGENT_CLI"
  echo "Model:     $MODEL"
  echo "Max iter:  $MAX_ITERATIONS"
  [[ -n "$USE_BRANCH" ]] && echo "Branch:    $USE_BRANCH"
  [[ "$OPEN_PR" == "true" ]] && echo "Open PR:   Yes"
  echo ""

  show_task_summary "$WORKSPACE"

  local task_status
  task_status=$(check_task_complete "$WORKSPACE")
  if [[ "$task_status" == "COMPLETE" ]]; then
    echo "🎉 Task already complete. Nothing to do."
    exit 0
  fi

  run_ralph_loop "$WORKSPACE" "$SCRIPT_DIR"
  exit $?
}

main
