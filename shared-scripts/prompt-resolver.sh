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
#   3. Standalone install layout: ../ralph-templates (install.sh convention)
#   4. Same-directory fallback
_default_templates_dir() {
  if [[ -n "${RALPH_TEMPLATES_DIR:-}" ]]; then
    echo "$RALPH_TEMPLATES_DIR"
    return
  fi
  if [[ -d "$_PR_SCRIPT_DIR/../shared-references/templates" ]]; then
    echo "$_PR_SCRIPT_DIR/../shared-references/templates"
    return
  fi
  if [[ -d "$_PR_SCRIPT_DIR/../ralph-templates" ]]; then
    echo "$_PR_SCRIPT_DIR/../ralph-templates"
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
    # Escape for sed (delimiter is |)
    local esc_val
    esc_val=$(printf '%s' "$val" | sed -e 's/[\/&|]/\\&/g')
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
  rm -f "$workspace/.ralph/task-file-path"
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
  rm -f "$workspace/.ralph/task-file-path"
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

  # Resolve check commands.
  #
  # Ralph runs two tiers of gate:
  #   - BASIC_CHECK_COMMAND: fast per-task smoke gate (no e2e). Run after
  #     every individual task, must pass before marking [x].
  #   - FINAL_CHECK_COMMAND: full gate including e2e. Run at phase boundaries
  #     and before emitting ALL_TASKS_DONE.
  #
  # Breadcrumb precedence:
  #   BASIC: .ralph/basic-check-command → "pnpm basic-check"
  #   FINAL: .ralph/final-check-command → "pnpm all-check"
  local basic_check_command="pnpm basic-check"
  if [[ -f "$workspace/.ralph/basic-check-command" ]]; then
    basic_check_command=$(cat "$workspace/.ralph/basic-check-command")
  fi

  local final_check_command="pnpm all-check"
  if [[ -f "$workspace/.ralph/final-check-command" ]]; then
    final_check_command=$(cat "$workspace/.ralph/final-check-command")
  fi

  # Push policy — controls whether the agent is instructed to `git push`
  # during the loop. Breadcrumb: .ralph/push-policy containing one of:
  #   never            — never push; all commits stay local (default)
  #   per-commit       — push after every successful commit
  #   per-3-commits    — push after every ~3 commits (legacy behavior)
  #   phase-close      — push only at phase completion
  #   completion-only  — push only right before emitting ALL_TASKS_DONE
  # Unknown values fall back to `never` and a warning is emitted.
  local push_policy="never"
  if [[ -f "$workspace/.ralph/push-policy" ]]; then
    push_policy=$(tr -d '[:space:]' <"$workspace/.ralph/push-policy")
  fi
  local push_guidance
  case "$push_policy" in
    never)
      push_guidance="**Push policy: never.** Do **not** run \`git push\` at any point during the loop. Commits stay on the local branch until the operator merges them into the base branch manually. Pushing is pure cost: the pre-push hook typically re-runs lint/build/test-coverage work that the gate wrapper already ran before the commit, and a short-lived locally-merged branch has no remote consumers. If you find yourself reaching for \`git push\`, **stop and skip it.**"
      ;;
    per-commit)
      push_guidance="**Push policy: per-commit.** Run \`git push\` immediately after every successful \`git commit\`. The project's workflow depends on remote visibility of every commit (CI triggers, collaborator review, or remote backup)."
      ;;
    per-3-commits)
      push_guidance="**Push policy: per-3-commits.** Run \`git push\` after every ~3 commits. This is the legacy batching behavior for projects where pre-push hooks are cheap and some batching reduces noise."
      ;;
    phase-close)
      push_guidance="**Push policy: phase-close.** Do **not** push after individual task commits. Run \`git push\` once at phase completion, after the phase-close gate passes."
      ;;
    completion-only)
      push_guidance="**Push policy: completion-only.** Do **not** push during the loop. When you are ready to emit \`<promise>ALL_TASKS_DONE</promise>\`, run \`git push\` once, then emit the sigil."
      ;;
    *)
      echo "⚠️  Unknown push policy '$push_policy' in .ralph/push-policy; falling back to 'never'." >&2
      push_policy="never"
      push_guidance="**Push policy: never** (fallback — the value in \`.ralph/push-policy\` was not recognized). Do **not** run \`git push\` during the loop."
      ;;
  esac

  local task_file="$spec_dir/tasks.md"
  local plan_file="$spec_dir/plan.md"
  local spec_file="$spec_dir/spec.md"

  local templates_dir
  templates_dir=$(_default_templates_dir)
  local template="$templates_dir/speckit-prompt.md"

  # Resolve the gate-runner wrapper. The plugin ships gate-run.sh next to
  # this script; we substitute an absolute command the agent can invoke
  # verbatim from its shell tool. Template consumers use it as
  #   {{GATE_RUN}} final {{FINAL_CHECK_COMMAND}}
  # which renders to
  #   bash /path/to/shared-scripts/gate-run.sh final pnpm all-check
  local gate_run_path="$_PR_SCRIPT_DIR/gate-run.sh"
  local gate_run_cmd="bash $gate_run_path"
  local plugin_root
  plugin_root=$(cd "$_PR_SCRIPT_DIR/.." && pwd)

  # Ensure .ralph/gates exists before the first iteration so gate-run.sh
  # (and anything else writing there) has a home. Cheap and idempotent.
  mkdir -p "$workspace/.ralph/gates"

  local rendered
  if ! rendered=$(_render_template "$template" \
    SPEC_DIR "$spec_dir" \
    SPEC_NAME "$spec_name" \
    CONSTITUTION_PATH "$constitution_path" \
    BASIC_CHECK_COMMAND "$basic_check_command" \
    FINAL_CHECK_COMMAND "$final_check_command" \
    GATE_RUN "$gate_run_cmd" \
    RALPH_PLUGIN_ROOT "$plugin_root" \
    PUSH_GUIDANCE "$push_guidance" \
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
    prompt) resolve_prompt_promptmd "$workspace" ;;
    file) resolve_prompt_file "$workspace" "$value" ;;
    spec) resolve_prompt_spec "$workspace" "$value" ;;
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
