#!/bin/bash
# Ralph Wiggum: Single Iteration (Human-in-the-Loop)
#
# Runs exactly ONE iteration of the Ralph loop, then stops.
# Useful for smoke-testing your prompt / spec before going AFK.
#
# Usage:
#   ./ralph-once.sh --cli claude --spec                 # one iter on newest spec
#   ./ralph-once.sh --prompt-file PROMPT.md              # one iter on a file
#   ./ralph-once.sh --cli cursor-agent -m composer-1     # one iter with model
#
# Flags mirror ralph-loop.sh (minus iterations/branch/pr/completion-promise).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/agent-adapter.sh"
source "$SCRIPT_DIR/ralph-common.sh"
source "$SCRIPT_DIR/prompt-resolver.sh"

show_help() {
  sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
}

WORKSPACE=""
PROMPT_MODE=""
PROMPT_VALUE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cli)
      RALPH_AGENT_CLI="$2"
      shift 2
      ;;
    -m | --model)
      MODEL="$2"
      shift 2
      ;;
    --prompt | --prompt-md)
      PROMPT_MODE="prompt"
      shift
      ;;
    --prompt-file)
      PROMPT_MODE="file"
      PROMPT_VALUE="$2"
      shift 2
      ;;
    --spec)
      PROMPT_MODE="spec"
      if [[ $# -gt 1 ]] && [[ "${2:0:1}" != "-" ]]; then
        PROMPT_VALUE="$2"
        shift 2
      else
        shift
      fi
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

main() {
  RALPH_AGENT_CLI="$(agent_normalize_cli_name "$RALPH_AGENT_CLI")"
  if [[ -z "${MODEL:-}" ]] || [[ "$MODEL" == "$DEFAULT_MODEL" ]]; then
    MODEL="$(agent_default_model "$RALPH_AGENT_CLI")"
  fi
  ROTATE_THRESHOLD="${ROTATE_THRESHOLD:-$(agent_default_rotate_threshold "$RALPH_AGENT_CLI" "$MODEL")}"
  WARN_THRESHOLD="${WARN_THRESHOLD:-$(agent_default_warn_threshold "$RALPH_AGENT_CLI" "$MODEL")}"
  export MODEL RALPH_AGENT_CLI ROTATE_THRESHOLD WARN_THRESHOLD

  if [[ -z "$WORKSPACE" ]] || [[ "$WORKSPACE" == "." ]]; then
    WORKSPACE="$(pwd)"
  else
    WORKSPACE="$(cd "$WORKSPACE" && pwd)"
  fi

  echo "═══════════════════════════════════════════════════════════════════"
  echo "🐛 Ralph Wiggum: Single Iteration (Human-in-the-Loop)"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  echo "  This runs ONE iteration, then stops for review."
  echo ""

  if [[ -z "$PROMPT_MODE" ]]; then
    if [[ -f "$WORKSPACE/PROMPT.md" ]]; then
      PROMPT_MODE="prompt"
    else
      echo "❌ No prompt source specified. Use --prompt, --prompt-file, or --spec." >&2
      exit 1
    fi
  fi

  init_ralph_dir "$WORKSPACE"

  echo "📝 Resolving prompt source: $PROMPT_MODE${PROMPT_VALUE:+ ($PROMPT_VALUE)}"
  out=$(resolve_prompt "$WORKSPACE" "$PROMPT_MODE" "$PROMPT_VALUE") || exit 1
  echo "✓ Effective prompt: $out"
  echo ""

  check_prerequisites "$WORKSPACE" || exit 1

  echo "Workspace: $WORKSPACE"
  echo "CLI:       $RALPH_AGENT_CLI"
  echo "Model:     $MODEL"
  echo ""

  show_task_summary "$WORKSPACE"

  local task_status
  task_status=$(check_task_complete "$WORKSPACE")
  if [[ "$task_status" == "COMPLETE" ]]; then
    echo "🎉 Task already complete."
    exit 0
  fi

  cd "$WORKSPACE"
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "📦 Committing uncommitted changes before iteration..."
    git add -A
    git commit -m "ralph: checkpoint before single iteration" || true
  fi

  echo ""
  echo "🚀 Running single iteration..."
  echo ""

  local signal
  signal=$(run_iteration "$WORKSPACE" "1" "" "$SCRIPT_DIR")

  task_status=$(check_task_complete "$WORKSPACE")

  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo "📋 Single Iteration Complete"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  case "$signal" in
    COMPLETE)
      if [[ "$task_status" == "COMPLETE" ]]; then
        echo "🎉 Task completed in a single iteration!"
      else
        echo "⚠️  Agent signaled complete but criteria remain unchecked."
      fi
      ;;
    GUTTER)
      echo "🚨 Gutter detected — agent got stuck."
      echo "   Review .ralph/errors.log"
      ;;
    ROTATE)
      echo "🔄 Context rotation triggered. Review progress and run again or switch to ralph-loop.sh."
      ;;
    *)
      if [[ "$task_status" == "COMPLETE" ]]; then
        echo "🎉 Task complete."
      else
        echo "Agent finished. Remaining: ${task_status#INCOMPLETE:}"
      fi
      ;;
  esac

  echo ""
  echo "Next:"
  echo "  git log --oneline -5         # see commits"
  echo "  cat .ralph/progress.md       # progress log"
  echo "  ralph-setup.sh               # interactive full loop"
}

main
