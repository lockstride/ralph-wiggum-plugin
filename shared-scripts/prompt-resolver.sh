#!/bin/bash
# Ralph Wiggum: Prompt Source Resolver
#
# Selects and renders the "effective prompt" that the loop feeds the
# agent on every loop. Three modes:
#
#   1) PROMPT.md in repo root  — plain prompt file (agrimsingh convention)
#   2) Custom prompt file      — user-supplied path
#   3) Spec Kit spec dir       — most-recent `specs/*` by mtime, rendered
#                                through templates/speckit-prompt.md
#
# The rendered prompt is written to .ralph/effective-prompt.md and
# stays git-ignored. ralph-common.sh reads it from there every
# loop, so you can edit it mid-run if needed.
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

# Log to activity.log when log_activity is available (sourced via ralph-common.sh).
# No-op in standalone mode where log_activity is not defined.
_pr_log() {
  local workspace="$1" message="$2"
  if declare -f log_activity >/dev/null 2>&1; then
    log_activity "$workspace" "$message"
  fi
}

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

# Resolve the universal guardrails preamble that every effective prompt
# is prefixed with, regardless of mode (PROMPT.md, --prompt-file, spec).
#
# Lookup order mirrors _default_templates_dir. Returns empty string if
# the file is missing — callers must tolerate that (older installs, or a
# user who deliberately removed it). Honor RALPH_SKIP_GUARDRAILS=1 as an
# explicit opt-out for users with their own preamble.
_resolve_guardrails_preamble() {
  if [[ "${RALPH_SKIP_GUARDRAILS:-}" == "1" ]]; then
    return 0
  fi
  local templates_dir
  templates_dir=$(_default_templates_dir)
  local guardrails="$templates_dir/loop-guardrails.md"
  if [[ -f "$guardrails" ]]; then
    cat "$guardrails"
  fi
}

# Write the resolved prompt body to .ralph/effective-prompt.md.
# Prepends the universal guardrails preamble so PROMPT.md, --prompt-file,
# and spec modes all carry the same anti-pattern rules.
#
# 0.6.0: optional third argument $append_loop_extras. When "true", appends
# a "Recent activity" section (last 50 events from activity.log) and a
# "Skills available" pointer block to the body. Used by PROMPT.md and
# --prompt-file modes so user-supplied prompts get the same self-observation
# and skill-pointer benefits the spec-mode template gets via {{ACTIVITY_TAIL}}
# placeholder substitution. Spec mode passes "false" (the template handles
# both itself).
_write_effective_prompt() {
  local workspace="$1"
  local body="$2"
  local append_loop_extras="${3:-false}"
  local rel="${RALPH_EFFECTIVE_PROMPT:-.ralph/effective-prompt.md}"
  local out="$workspace/$rel"
  mkdir -p "$(dirname "$out")"

  if [[ "$append_loop_extras" == "true" ]]; then
    body="${body}$(_loop_extras_block "$workspace")"
  fi

  local preamble
  preamble=$(_resolve_guardrails_preamble)
  if [[ -n "$preamble" ]]; then
    printf '%s\n%s' "$preamble" "$body" >"$out"
  else
    printf '%s' "$body" >"$out"
  fi
  echo "$out"
}

# 0.6.0: build the loop-extras block that PROMPT.md / --prompt-file modes
# get appended to the user's prompt. Mirrors what spec-mode templates
# include via {{ACTIVITY_TAIL}} substitution + the inline skills section,
# so non-spec users still benefit from self-observation and skill
# discoverability without having to manually template their PROMPT.md.
_loop_extras_block() {
  local workspace="$1"
  local activity_tail=""
  local _activity_log_path="$workspace/.ralph/activity.log"
  if [[ -f "$_activity_log_path" ]]; then
    activity_tail=$(tail -n 50 "$_activity_log_path" 2>/dev/null || true)
  fi
  if [[ -z "$activity_tail" ]]; then
    activity_tail="(no prior activity — this is the first loop)"
  fi

  cat <<EOF


---

## Recent activity (last 50 events from .ralph/activity.log)

\`\`\`
$activity_tail
\`\`\`

If the snapshot above shows you've been running the same gate or editing
the same file repeatedly without progress, do NOT continue the same
approach — invoke the \`diagnosing-stuck-tasks\` skill instead.

## Specialist skills available

The plugin provides three skills you can invoke (via the Skill tool) when
the situation calls for a different cognitive posture than executing the
prompt above:

- \`running-gates\` — gate-invocation contract (how to call gate-run.sh,
  no-pipe rule, retry budget, failure-diagnosis protocol). Reference any
  time you're about to run a verification command.
- \`diagnosing-stuck-tasks\` — exploratory mode when the same gate keeps
  failing or you've been on the same task too long. The loop sometimes
  prompts you to invoke this via \`.ralph/skill-suggestion\`.
- \`reviewing-loop-progress\` — lightweight meta-reflection. "Am I still
  on the right track?" One paragraph, then act.

If \`.ralph/skill-suggestion\` exists, the loop has detected a stuck
pattern and is suggesting a specific skill — read that file and invoke
the named skill before continuing.
EOF
}

# Substitute {{VAR}} placeholders in a template using a simple key/value map.
# Args: template_path KEY1 VAL1 KEY2 VAL2 ...
#
# 0.6.0: uses bash parameter expansion instead of sed. The previous sed
# implementation broke on multi-line values (newlines in the replacement
# get interpreted as new sed commands and corrupt the output) — fine when
# all placeholders were single-line, but the new {{ACTIVITY_TAIL}}
# placeholder substitutes ~50 lines of activity log. Bash's `${var//search/replace}`
# handles multi-line values correctly because the replacement side is
# always literal (no glob/regex interpretation).
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
    local placeholder="{{${key}}}"
    # shellcheck disable=SC2295 # placeholder is literal-pattern by intent
    content="${content//$placeholder/$val}"
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
  mkdir -p "$workspace/.ralph"
  echo "$prompt_file" >"$workspace/.ralph/task-file-path"
  # 0.6.0: append loop extras (activity tail + skill pointers) so PROMPT.md
  # users get the same self-observation and skill discoverability that
  # spec-mode templates include via placeholder substitution.
  _write_effective_prompt "$workspace" "$(cat "$prompt_file")" "true"
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
  mkdir -p "$workspace/.ralph"
  echo "$path" >"$workspace/.ralph/task-file-path"
  # 0.6.0: append loop extras (activity tail + skill pointers) — see
  # resolve_prompt_promptmd for rationale.
  _write_effective_prompt "$workspace" "$(cat "$path")" "true"
}

# Generate a loop-adapted prompt from speckit.implement.md using the
# adaptation guide. Writes the result + hash to the spec directory
# and commits both files.
#
# Args:
#   $1 — workspace path
#   $2 — spec directory (e.g., $workspace/specs/my-spec)
#   $3 — path to speckit.implement.md
#   $4 — sha256 hash of speckit.implement.md
#   $5 — output path for generated prompt
#   $6 — output path for hash file
#   $7 — templates directory
_generate_ralph_prompt() {
  local workspace="$1"
  local spec_dir="$2"
  local speckit_implement="$3"
  local current_hash="$4"
  local ralph_prompt="$5"
  local ralph_hash_file="$6"
  local templates_dir="$7"

  local guide="$templates_dir/speckit-adaptation-guide.md"
  if [[ ! -f "$guide" ]]; then
    echo "  ❌ Adaptation guide not found: $guide" >&2
    return 1
  fi

  local skill_content
  skill_content=$(cat "$speckit_implement")

  local guide_content
  guide_content=$(cat "$guide")

  # Build the generation prompt: guide + skill → adapted prompt
  local gen_prompt
  gen_prompt=$(
    cat <<GENPROMPT
You are transforming a speckit.implement.md slash command into a loop-compatible
prompt for an unattended Ralph development loop.

## Adaptation Guide

$guide_content

## Current speckit.implement.md

$skill_content

## Instructions

Apply the transformation rules from the guide to the current speckit.implement.md.
Use the example output in the guide as a structural reference — match its format,
section structure, and level of detail.

Output ONLY the adapted prompt content (markdown). Do not include any preamble,
explanation, or commentary. Keep the output under 50 lines. Preserve all
{{PLACEHOLDER}} variables exactly as written — they will be substituted later.
GENPROMPT
  )

  # Determine which CLI to use for generation. Prefer claude (fast, local).
  local gen_cli="claude"
  if ! command -v "$gen_cli" >/dev/null 2>&1; then
    echo "  ❌ $gen_cli CLI not found — cannot generate prompt" >&2
    return 1
  fi

  echo "  ⚙ Generating loop prompt via $gen_cli (sonnet, low effort)..." >&2
  _pr_log "$workspace" "PROMPT generating loop prompt via $gen_cli (sonnet, low effort)..."

  local generated
  if ! generated=$(echo "$gen_prompt" | $gen_cli -p \
    --model sonnet \
    --effort low \
    --output-format text \
    --dangerously-skip-permissions 2>/dev/null); then
    echo "  ❌ Prompt generation failed (exit $?)" >&2
    _pr_log "$workspace" "PROMPT ❌ generation failed"
    return 1
  fi

  # Validate output is not empty and is reasonable length
  local line_count
  line_count=$(echo "$generated" | wc -l | tr -d ' ')
  if [[ $line_count -lt 10 ]]; then
    echo "  ❌ Generated prompt too short ($line_count lines)" >&2
    return 1
  fi
  # 0.6.0 trimmed the target from 120 → 50 lines. Specialist behavior moved to
  # plugin skills (running-gates, diagnosing-stuck-tasks, reviewing-loop-progress)
  # so the framing prompt no longer needs to inline gate-discipline / diagnosis
  # protocols. Warn if the generated prompt drifts back over 75 lines.
  if [[ $line_count -gt 75 ]]; then
    echo "  ⚠️  Generated prompt is $line_count lines (target: ≤50)" >&2
  fi

  # Write the generated prompt and hash
  printf '%s\n' "$generated" >"$ralph_prompt"
  printf '%s\n' "$current_hash" >"$ralph_hash_file"

  # Commit the generated files so they're version-controlled and reviewable
  _pr_log "$workspace" "PROMPT committing generated prompt ($line_count lines)"
  (
    cd "$workspace" || return 1
    local rel_prompt="${ralph_prompt#"$workspace/"}"
    local rel_hash="${ralph_hash_file#"$workspace/"}"
    git add "$rel_prompt" "$rel_hash" 2>/dev/null || true
    git commit -q -m "ralph: generate loop prompt from speckit.implement ${current_hash:0:8}" 2>/dev/null || true
  )

  echo "  ✓ Generated prompt ($line_count lines) → $ralph_prompt" >&2
  _pr_log "$workspace" "PROMPT ✓ generated prompt ($line_count lines)"
  return 0
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

  # Ensure .ralph/gates exists before the first loop so gate-run.sh
  # (and anything else writing there) has a home. Cheap and idempotent.
  mkdir -p "$workspace/.ralph/gates"

  # =========================================================================
  # Prompt generation from speckit.implement.md (preferred path)
  #
  # If the project has .claude/commands/speckit.implement.md, generate the
  # loop prompt from it using the adaptation guide. The generated prompt is
  # cached at <spec_dir>/ralph-prompt.md with a hash for cache invalidation.
  #
  # Falls back to the built-in speckit-prompt.md template if:
  #   - speckit.implement.md does not exist
  #   - generation is explicitly skipped (RALPH_SKIP_GENERATION=1)
  # =========================================================================

  # speckit.implement may live as a slash command or as a skill. Check both.
  local speckit_implement=""
  local speckit_candidates=(
    "$workspace/.claude/commands/speckit.implement.md"
    "$workspace/.claude/skills/speckit-implement/SKILL.md"
    "$workspace/.claude/skills/speckit.implement/SKILL.md"
  )
  for candidate in "${speckit_candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      speckit_implement="$candidate"
      break
    fi
  done

  local ralph_prompt="$spec_dir/ralph-prompt.md"
  local ralph_hash_file="$spec_dir/.ralph-prompt-hash"
  local use_generated=false

  if [[ -n "$speckit_implement" ]] && [[ "${RALPH_SKIP_GENERATION:-}" != "1" ]]; then
    # 0.6.2: Composite cache key — sha256(speckit.implement) + sha256(adaptation
    # guide). Either component changing triggers regeneration. Pre-0.6.1 the
    # key was the speckit hash alone, so plugin upgrades that rewrote the
    # guide silently kept reusing the old cached prompt. 0.6.1 added the
    # guide hash but only WARNED on guide change (no auto-regen) — that
    # warning got buried in tmux startup output and operators missed it.
    # 0.6.2 unifies both branches: any composite-hash mismatch regenerates,
    # with a per-cause log line so postmortems can tell what changed.
    #
    # Falls back gracefully when the guide can't be hashed (treats it as
    # empty, so legacy single-hash files still match cleanly when speckit
    # is unchanged AND the templates dir is unavailable — rare).
    local current_hash
    current_hash=$(shasum -a 256 "$speckit_implement" | cut -d' ' -f1)
    local guide_hash=""
    local guide_path="$templates_dir/speckit-adaptation-guide.md"
    if [[ -f "$guide_path" ]]; then
      guide_hash=$(shasum -a 256 "$guide_path" | cut -d' ' -f1)
    fi
    local composite_hash="$current_hash"
    if [[ -n "$guide_hash" ]]; then
      composite_hash="${current_hash}:${guide_hash}"
    fi

    if [[ -f "$ralph_prompt" ]] && [[ -f "$ralph_hash_file" ]]; then
      local stored_hash
      stored_hash=$(cat "$ralph_hash_file")
      if [[ "$composite_hash" == "$stored_hash" ]]; then
        echo "  ✓ Using cached prompt (hash match)" >&2
        _pr_log "$workspace" "PROMPT ✓ using cached prompt (hash match)"
        use_generated=true
      else
        # Decompose what changed for log clarity. The stored hash may be
        # either the legacy single-hash format ("<speckit_hash>") or the
        # 0.6.1+ composite format ("<speckit_hash>:<guide_hash>"). Either
        # way we always regenerate — the message just tells the operator
        # which side moved.
        local stored_speckit_hash="${stored_hash%%:*}"
        local stored_guide_hash=""
        if [[ "$stored_hash" == *:* ]]; then
          stored_guide_hash="${stored_hash#*:}"
        fi
        local speckit_changed=false guide_changed=false
        [[ "$current_hash" != "$stored_speckit_hash" ]] && speckit_changed=true
        [[ -n "$guide_hash" ]] && [[ "$guide_hash" != "$stored_guide_hash" ]] && guide_changed=true

        # Loud STALE marker first when the GUIDE changed (plugin upgrade
        # we didn't initiate) so postmortems can `grep STALE activity.log`
        # to find every loop that started under a stale-cache condition.
        # Speckit-only changes are user-initiated, not "stale" — they get
        # the regen line but no STALE marker.
        if [[ "$guide_changed" == "true" ]]; then
          echo "  ⚠️  STALE prompt cache: adaptation guide changed (plugin upgrade) — auto-regenerating" >&2
          _pr_log "$workspace" "PROMPT ⚠️ STALE: adaptation guide changed (plugin upgrade) — auto-regenerating"
        fi

        if [[ "$speckit_changed" == "true" ]] && [[ "$guide_changed" == "true" ]]; then
          echo "  ↻ speckit.implement.md AND adaptation guide changed — regenerating..." >&2
          _pr_log "$workspace" "PROMPT speckit + guide changed — regenerating..."
        elif [[ "$speckit_changed" == "true" ]]; then
          echo "  ↻ speckit.implement.md changed — regenerating prompt..." >&2
          _pr_log "$workspace" "PROMPT speckit.implement.md changed — regenerating..."
        elif [[ "$guide_changed" == "true" ]]; then
          echo "  ↻ adaptation guide changed (plugin upgrade) — regenerating prompt..." >&2
          _pr_log "$workspace" "PROMPT guide changed (plugin upgrade) — regenerating..."
        fi
        # Falls through to the generation block below in all three cases.
      fi
    else
      echo "  ⚙ No cached prompt — generating from speckit.implement.md..." >&2
      _pr_log "$workspace" "PROMPT no cached prompt — generating from speckit.implement.md..."
    fi

    if [[ "$use_generated" != "true" ]]; then
      if _generate_ralph_prompt "$workspace" "$spec_dir" "$speckit_implement" \
        "$composite_hash" "$ralph_prompt" "$ralph_hash_file" "$templates_dir"; then
        use_generated=true
      else
        echo "  ⚠️  Prompt generation failed — falling back to built-in template" >&2
      fi
    fi
  fi

  # Resolve the template to render: either generated or built-in fallback
  local template
  if [[ "$use_generated" == "true" ]]; then
    template="$ralph_prompt"
  else
    template="$templates_dir/speckit-prompt.md"
  fi

  # 0.6.0: render the {{ACTIVITY_TAIL}} placeholder with the last ~50 events
  # from .ralph/activity.log. Lets the agent see its own recent pattern (same
  # gate failing 3×, same file thrashed) which it would otherwise miss.
  # ~500 token cost on a populated log; degrades gracefully to a placeholder
  # message when activity.log doesn't exist yet (first loop).
  local activity_tail=""
  local _activity_log_path="$workspace/.ralph/activity.log"
  if [[ -f "$_activity_log_path" ]]; then
    activity_tail=$(tail -n 50 "$_activity_log_path" 2>/dev/null || true)
  fi
  if [[ -z "$activity_tail" ]]; then
    activity_tail="(no prior activity — this is the first loop)"
  fi

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
    SPEC_FILE "$spec_file" \
    ACTIVITY_TAIL "$activity_tail"); then
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
