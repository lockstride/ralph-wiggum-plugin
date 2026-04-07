#!/bin/bash
# Ralph Wiggum: Prompt Source Resolver
#
# Selects and renders the "effective prompt" that the loop feeds the
# agent on every iteration. Three modes:
#
#   1) PROMPT.md in repo root  — plain prompt file (agrimsingh convention)
#   2) Custom prompt file      — user-supplied path
#   3) Spec Kit spec dir       — most-recent `specs/*` by mtime, rendered
#                                through templates/speckit-prompt.md
#
# The rendered prompt is written to .ralph/effective-prompt.md and
# stays git-ignored. ralph-common.sh reads it from there every
# iteration, so you can edit it mid-run if needed.
#
# Usage (sourced by ralph-setup.sh):
#   source prompt-resolver.sh
#   resolve_prompt "$workspace" "$mode" "$value"
#
# Or standalone:
#   ./prompt-resolver.sh <workspace> <mode> [value]
#     mode = prompt | file | spec
#     value (optional) = file path or spec dir name
#
# Environment variables it honors:
#   RALPH_TEMPLATES_DIR   — override the default template lookup
#   RALPH_EFFECTIVE_PROMPT — relative path to the rendered file
#                           (default: .ralph/effective-prompt.md)

set -euo pipefail

_PR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default template lookup path:
#   1. $RALPH_TEMPLATES_DIR
#   2. Plugin layout: ../shared-references/templates
#   3. Same-directory fallback
_default_templates_dir() {
  if [[ -n "${RALPH_TEMPLATES_DIR:-}" ]]; then
    echo "$RALPH_TEMPLATES_DIR"
    return
  fi
  if [[ -d "$_PR_SCRIPT_DIR/../shared-references/templates" ]]; then
    echo "$_PR_SCRIPT_DIR/../shared-references/templates"
    return
  fi
  echo "$_PR_SCRIPT_DIR/templates"
}

# Write the resolved prompt body to .ralph/effective-prompt.md
_write_effective_prompt() {
  local workspace="$1"
  local body="$2"
  local rel="${RALPH_EFFECTIVE_PROMPT:-.ralph/effective-prompt.md}"
  local out="$workspace/$rel"
  mkdir -p "$(dirname "$out")"
  printf '%s' "$body" >"$out"
  echo "$out"
}

# Substitute {{VAR}} placeholders in a template using a simple key/value map.
# Args: template_path KEY1 VAL1 KEY2 VAL2 ...
_render_template() {
  local template="$1"
  shift
  if [[ ! -f "$template" ]]; then
    echo "❌ Template not found: $template" >&2
    return 1
  fi
  local content
  content=$(cat "$template")
  while [[ $# -gt 0 ]]; do
    local key="$1"
    local val="$2"
    shift 2
    # Escape for sed
    local esc_val
    esc_val=$(printf '%s' "$val" | sed -e 's/[\/&]/\\&/g')
    content=$(printf '%s' "$content" | sed "s|{{${key}}}|${esc_val}|g")
  done
  printf '%s' "$content"
}

# Mode 1: plain PROMPT.md at the repo root
resolve_prompt_promptmd() {
  local workspace="$1"
  local prompt_file="$workspace/PROMPT.md"
  if [[ ! -f "$prompt_file" ]]; then
    echo "❌ PROMPT.md not found at $prompt_file" >&2
    return 1
  fi
  _write_effective_prompt "$workspace" "$(cat "$prompt_file")"
}

# Mode 2: custom prompt file at a user-supplied path
resolve_prompt_file() {
  local workspace="$1"
  local path="$2"
  if [[ -z "$path" ]]; then
    echo "❌ --prompt-file requires a path" >&2
    return 1
  fi
  # Support relative paths from the workspace
  if [[ ! -f "$path" ]] && [[ -f "$workspace/$path" ]]; then
    path="$workspace/$path"
  fi
  if [[ ! -f "$path" ]]; then
    echo "❌ Prompt file not found: $path" >&2
    return 1
  fi
  _write_effective_prompt "$workspace" "$(cat "$path")"
}

# Mode 3: Spec Kit spec dir (most-recent by mtime, or user-supplied)
#
# Resolution:
#   - spec_name empty  → `ls -t specs/ | head -1`
#   - spec_name given  → validate $workspace/specs/$spec_name exists
# Then render templates/speckit-prompt.md with {{SPEC_DIR}} etc.
resolve_prompt_spec() {
  local workspace="$1"
  local spec_name="${2:-}"

  local specs_root="$workspace/specs"
  if [[ ! -d "$specs_root" ]]; then
    echo "❌ No specs/ directory at $specs_root" >&2
    return 1
  fi

  if [[ -z "$spec_name" ]]; then
    # shellcheck disable=SC2012 # ls -t is the simplest portable way to sort by mtime
    spec_name=$(ls -t "$specs_root" 2>/dev/null | head -1 || true)
    if [[ -z "$spec_name" ]]; then
      echo "❌ No spec directories found in $specs_root" >&2
      return 1
    fi
  fi

  local spec_dir="$specs_root/$spec_name"
  if [[ ! -d "$spec_dir" ]]; then
    echo "❌ Spec dir not found: $spec_dir" >&2
    return 1
  fi

  # Locate the constitution. Spec Kit convention: .specify/memory/constitution.md
  local constitution_path="$workspace/.specify/memory/constitution.md"
  if [[ ! -f "$constitution_path" ]]; then
    constitution_path="(no constitution found — proceed without one)"
  fi

  # Resolve test command: prefer .ralph/test-command, fall back to "pnpm test"
  local test_command="pnpm test"
  if [[ -f "$workspace/.ralph/test-command" ]]; then
    test_command=$(cat "$workspace/.ralph/test-command")
  fi

  local task_file="$spec_dir/tasks.md"
  local plan_file="$spec_dir/plan.md"
  local spec_file="$spec_dir/spec.md"

  local templates_dir
  templates_dir=$(_default_templates_dir)
  local template="$templates_dir/speckit-prompt.md"

  local rendered
  if ! rendered=$(_render_template "$template" \
    SPEC_DIR "$spec_dir" \
    SPEC_NAME "$spec_name" \
    CONSTITUTION_PATH "$constitution_path" \
    TEST_COMMAND "$test_command" \
    TASK_FILE "$task_file" \
    PLAN_FILE "$plan_file" \
    SPEC_FILE "$spec_file"); then
    return 1
  fi

  # Leave a breadcrumb so _resolve_task_file counts checkboxes from
  # the real tasks file, not the rendered effective prompt (which has none).
  mkdir -p "$workspace/.ralph"
  echo "$task_file" >"$workspace/.ralph/task-file-path"

  _write_effective_prompt "$workspace" "$rendered"
}

# Single entry point
resolve_prompt() {
  local workspace="$1"
  local mode="$2"
  local value="${3:-}"

  case "$mode" in
    prompt | promptmd | 1) resolve_prompt_promptmd "$workspace" ;;
    file | custom | 2) resolve_prompt_file "$workspace" "$value" ;;
    spec | speckit | 3) resolve_prompt_spec "$workspace" "$value" ;;
    *)
      echo "❌ Unknown prompt mode: $mode (expected prompt|file|spec)" >&2
      return 1
      ;;
  esac
}

# List available specs (most-recent first) for interactive display
list_specs() {
  local workspace="$1"
  local specs_root="$workspace/specs"
  [[ -d "$specs_root" ]] || return 0
  ls -t "$specs_root" 2>/dev/null || true
}

# =============================================================================
# STANDALONE ENTRYPOINT
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  workspace="${1:-$(pwd)}"
  mode="${2:-}"
  value="${3:-}"
  if [[ -z "$mode" ]]; then
    echo "Usage: prompt-resolver.sh <workspace> <prompt|file|spec> [value]" >&2
    exit 2
  fi
  out=$(resolve_prompt "$workspace" "$mode" "$value")
  echo "✓ Wrote effective prompt to: $out"
fi
