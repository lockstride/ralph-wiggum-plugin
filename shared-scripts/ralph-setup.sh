#!/bin/bash
# Ralph Wiggum: Interactive Setup & Loop (CLI-agnostic)
#
# The main entry point for Ralph. Uses gum for a nice CLI experience,
# falls back to plain prompts if gum is not installed.
#
# Usage:
#   ./ralph-setup.sh                    # Interactive setup + run loop
#   ./ralph-setup.sh /path/to/project   # Run in specific project
#
# You can also pass any ralph-loop.sh flag to skip specific prompts:
#   ./ralph-setup.sh --cli claude --spec -n 30
#
# Requirements:
#   - Either `claude` or `cursor-agent` installed and logged in
#   - Git repository
#   - jq installed
#   - gum (optional): brew install gum

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/agent-adapter.sh"
source "$SCRIPT_DIR/ralph-common.sh"
source "$SCRIPT_DIR/prompt-resolver.sh"

HAS_GUM=false
if command -v gum &>/dev/null; then
  HAS_GUM=true
fi

# =============================================================================
# FLAG PASSTHROUGH (so ralph-setup.sh --cli claude --spec works)
# =============================================================================

WORKSPACE=""
CLI_FROM_FLAG=""
MODEL_FROM_FLAG=""
ITER_FROM_FLAG=""
PROMPT_MODE=""
PROMPT_VALUE=""
BRANCH_FROM_FLAG=""
OPEN_PR_FLAG=""
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
      ITER_FROM_FLAG="$2"
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
    --branch)
      BRANCH_FROM_FLAG="$2"
      shift 2
      ;;
    --pr)
      OPEN_PR_FLAG=true
      shift
      ;;
    -h | --help)
      cat <<'EOF'
Ralph Wiggum: Interactive Setup & Loop

Usage:
  ./ralph-setup.sh [options] [workspace]

Options:
  --cli <claude|cursor-agent>  Skip CLI picker
  -m, --model <id>             Skip model picker
  -n, --iterations N           Skip iterations picker
  --prompt, --prompt-md        Use PROMPT.md
  --prompt-file <path>         Use custom prompt file
  --spec [name]                Use Spec Kit spec (default: newest)
  --branch <name>              Work on named branch
  --pr                         Open PR when complete (requires --branch)
  -h, --help                   Show this help

Any flags you pass cause the interactive prompt for that setting to be
skipped, so you can go fully unattended with:
  ./ralph-setup.sh --cli claude -m opus --spec -n 20

Inside Claude Code: the /ralph slash command prints a one-liner that
invokes this script.
EOF
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

# =============================================================================
# UI HELPERS
# =============================================================================

show_header() {
  local text="$1"
  if [[ "$HAS_GUM" == "true" ]]; then
    gum style --border double --padding "0 2" --border-foreground 212 "$text"
  else
    echo "═══════════════════════════════════════════════════════════════════"
    echo "$text"
    echo "═══════════════════════════════════════════════════════════════════"
  fi
}

CLI_OPTIONS=("claude" "cursor-agent")
select_cli() {
  if [[ -n "$CLI_FROM_FLAG" ]]; then
    echo "$CLI_FROM_FLAG"
    return
  fi
  if [[ "$HAS_GUM" == "true" ]]; then
    gum choose --header "Agent CLI:" "${CLI_OPTIONS[@]}"
  else
    echo "Select agent CLI:"
    local i=1
    for c in "${CLI_OPTIONS[@]}"; do
      echo "  $i) $c"
      ((i++))
    done
    read -rp "Choice [1]: " choice
    choice="${choice:-1}"
    echo "${CLI_OPTIONS[$((choice - 1))]}"
  fi
}

# Filter cursor-agent --list-models output: drop -fast variants and
# older versions, keeping only models at the highest version per vendor
# (claude, gpt, composer, gemini, …).  Input: raw output with ANSI
# codes already stripped.  Output: "id - description" lines, sorted
# alphabetically by vendor then model name.
filter_cursor_models() {
  awk '
  / - / {
    idx = index($0, " - ")
    id = substr($0, 1, idx - 1)
    gsub(/[[:space:]]/, "", id)
    if (id ~ /-fast$/ || id == "auto") next

    n = split(id, p, "-")
    vendor = p[1]

    ver = ""
    for (i = 2; i <= n; i++) {
      if (p[i] ~ /^[0-9]+(\.[0-9]+)?$/) {
        ver = (ver == "" ? p[i] : ver "." p[i])
      } else break
    }

    split(ver, vp, ".")
    vn = (vp[1]+0) * 1000000 + (vp[2]+0) * 1000 + (vp[3]+0)
    if (!(vendor in mx) || vn > mx[vendor]) mx[vendor] = vn

    c++
    line[c] = $0; ven[c] = vendor; vnum[c] = vn
  }
  END {
    for (i = 1; i <= c; i++)
      if (vnum[i] == mx[ven[i]]) print line[i]
  }' | sort
}

# Model list for the interactive picker.
# Claude CLI uses versionless aliases resolved by the CLI itself.
# cursor-agent models are queried at runtime via --list-models;
# if nothing comes back the user hasn't logged in yet.
models_for_cli() {
  local cli="$1"
  case "$cli" in
    claude)
      echo "opus"
      echo "sonnet"
      echo "haiku"
      echo "Custom..."
      ;;
    cursor-agent)
      local raw
      raw=$(cursor-agent --list-models 2>/dev/null |
        sed $'s/\x1b\[[0-9;]*[A-Za-z]//g')
      local filtered
      filtered=$(echo "$raw" | filter_cursor_models)
      if [[ -z "$filtered" ]]; then
        echo "ERROR: cursor-agent returned no models. Run 'cursor-agent' once to log in." >&2
        return 1
      fi
      echo "$filtered"
      echo "Custom..."
      ;;
  esac
}

select_model() {
  local cli="$1"
  if [[ -n "$MODEL_FROM_FLAG" ]]; then
    echo "$MODEL_FROM_FLAG"
    return
  fi
  local -a opts=()
  while IFS= read -r line; do opts+=("$line"); done < <(models_for_cli "$cli")
  if [[ ${#opts[@]} -eq 0 ]]; then
    return 1
  fi
  local selected
  if [[ "$HAS_GUM" == "true" ]]; then
    selected=$(gum choose --header "Model:" "${opts[@]}")
    if [[ "$selected" == "Custom..." ]]; then
      selected=$(gum input --placeholder "Model id" --value "$(agent_default_model "$cli")")
    fi
  else
    echo "Select model:"
    local i=1
    for m in "${opts[@]}"; do
      echo "  $i) $m"
      ((i++))
    done
    read -rp "Choice [1]: " choice
    choice="${choice:-1}"
    selected="${opts[$((choice - 1))]}"
    if [[ "$selected" == "Custom..." ]]; then
      read -rp "Model id: " selected
    fi
  fi
  # Strip " - description" suffix if present (cursor-agent format)
  selected="${selected%% - *}"
  echo "$selected"
}

get_max_iterations() {
  if [[ -n "$ITER_FROM_FLAG" ]]; then
    echo "$ITER_FROM_FLAG"
    return
  fi
  if [[ "$HAS_GUM" == "true" ]]; then
    gum input --header "Max iterations:" --placeholder "20" --value "20"
  else
    read -rp "Max iterations [20]: " value
    echo "${value:-20}"
  fi
}

select_prompt_source() {
  local workspace="$1"

  if [[ -n "$PROMPT_MODE" ]]; then
    echo "$PROMPT_MODE|$PROMPT_VALUE"
    return
  fi

  local -a opts=()
  if [[ -f "$workspace/PROMPT.md" ]]; then
    opts+=("PROMPT.md in repo root")
  fi
  opts+=("Custom prompt file")
  if [[ -d "$workspace/specs" ]]; then
    opts+=("Spec Kit spec dir")
  fi

  if [[ ${#opts[@]} -eq 0 ]]; then
    echo "❌ No prompt sources found. Create PROMPT.md or a specs/ dir." >&2
    exit 1
  fi

  local picked
  if [[ "$HAS_GUM" == "true" ]]; then
    picked=$(gum choose --header "Prompt source:" "${opts[@]}")
  else
    echo "Prompt source:"
    local i=1
    for o in "${opts[@]}"; do
      echo "  $i) $o"
      ((i++))
    done
    read -rp "Choice [1]: " choice
    choice="${choice:-1}"
    picked="${opts[$((choice - 1))]}"
  fi

  case "$picked" in
    "PROMPT.md in repo root")
      echo "prompt|"
      ;;
    "Custom prompt file")
      local path
      if [[ "$HAS_GUM" == "true" ]]; then
        path=$(gum input --header "Prompt file path:" --placeholder "PROMPT.md")
      else
        read -rp "Prompt file path: " path
      fi
      echo "file|$path"
      ;;
    "Spec Kit spec dir")
      local default_spec
      default_spec=$(list_specs "$workspace" | head -1)
      local chosen="$default_spec"
      if [[ "$HAS_GUM" == "true" ]]; then
        local -a specs=()
        while IFS= read -r s; do specs+=("$s"); done < <(list_specs "$workspace")
        if [[ ${#specs[@]} -gt 0 ]]; then
          chosen=$(gum choose --header "Spec dir (newest first):" "${specs[@]}")
        fi
      else
        echo "Specs (newest first, default = $default_spec):"
        list_specs "$workspace" | head -10 | nl
        read -rp "Spec name [${default_spec}]: " input
        chosen="${input:-$default_spec}"
      fi
      echo "spec|$chosen"
      ;;
  esac
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

  echo ""
  show_header "🐛 Ralph Wiggum: CLI-agnostic Autonomous Development Loop"
  echo ""
  echo "  ⚠️  This runs your agent with all tool approvals pre-granted."
  echo "      Use only in a dedicated worktree with a clean git state."
  echo ""

  if [[ "$HAS_GUM" != "true" ]]; then
    echo "  💡 Install gum for a nicer UI: https://github.com/charmbracelet/gum"
    echo ""
  fi

  # Select CLI first so defaults cascade from it
  RALPH_AGENT_CLI=$(select_cli)
  RALPH_AGENT_CLI="$(agent_normalize_cli_name "$RALPH_AGENT_CLI")"
  echo "✓ CLI: $RALPH_AGENT_CLI"

  if ! agent_check "$RALPH_AGENT_CLI"; then
    exit 1
  fi

  if ! MODEL=$(select_model "$RALPH_AGENT_CLI"); then
    exit 1
  fi
  echo "✓ Model: $MODEL"

  # Prompt source selector
  local pair
  pair=$(select_prompt_source "$WORKSPACE")
  PROMPT_MODE="${pair%%|*}"
  PROMPT_VALUE="${pair#*|}"
  echo "✓ Prompt source: $PROMPT_MODE${PROMPT_VALUE:+ ($PROMPT_VALUE)}"

  init_ralph_dir "$WORKSPACE"

  # Render effective prompt
  if ! out=$(resolve_prompt "$WORKSPACE" "$PROMPT_MODE" "$PROMPT_VALUE"); then
    exit 1
  fi
  echo "✓ Effective prompt: $out"
  echo ""

  MAX_ITERATIONS=$(get_max_iterations)
  echo "✓ Max iterations: $MAX_ITERATIONS"

  if [[ -n "$BRANCH_FROM_FLAG" ]]; then
    USE_BRANCH="$BRANCH_FROM_FLAG"
  fi
  if [[ -n "$OPEN_PR_FLAG" ]]; then
    OPEN_PR="$OPEN_PR_FLAG"
  fi
  [[ -n "$USE_BRANCH" ]] && echo "✓ Branch: $USE_BRANCH"
  [[ "${OPEN_PR:-false}" == "true" ]] && echo "✓ Will open PR when complete"

  # Re-derive thresholds for selected CLI
  ROTATE_THRESHOLD="$(agent_default_rotate_threshold "$RALPH_AGENT_CLI")"
  WARN_THRESHOLD="$(agent_default_warn_threshold "$RALPH_AGENT_CLI")"
  export RALPH_AGENT_CLI MODEL MAX_ITERATIONS USE_BRANCH OPEN_PR ROTATE_THRESHOLD WARN_THRESHOLD

  echo ""

  if ! check_prerequisites "$WORKSPACE"; then
    exit 1
  fi

  show_task_summary "$WORKSPACE"

  local task_status
  task_status=$(check_task_complete "$WORKSPACE")
  if [[ "$task_status" == "COMPLETE" ]]; then
    echo "🎉 Task already complete. Nothing to do."
    exit 0
  fi

  echo "─────────────────────────────────────────────────────────────────"
  echo "Summary:"
  echo "  • CLI:        $RALPH_AGENT_CLI"
  echo "  • Model:      $MODEL"
  echo "  • Iterations: $MAX_ITERATIONS max"
  echo "  • Prompt:     $PROMPT_MODE${PROMPT_VALUE:+ ($PROMPT_VALUE)}"
  [[ -n "$USE_BRANCH" ]] && echo "  • Branch:     $USE_BRANCH"
  [[ "${OPEN_PR:-false}" == "true" ]] && echo "  • Open PR:    Yes"
  echo "─────────────────────────────────────────────────────────────────"
  echo ""

  run_ralph_loop "$WORKSPACE" "$SCRIPT_DIR"
  exit $?
}

main
