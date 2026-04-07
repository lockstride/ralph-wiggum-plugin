#!/bin/bash
# Ralph Wiggum: Common utilities and loop logic (CLI-agnostic)
#
# Shared functions for ralph-loop.sh, ralph-once.sh and ralph-setup.sh.
# All state lives in .ralph/ within the project.
#
# This is a port of agrimsingh/ralph-wiggum-cursor/scripts/ralph-common.sh,
# adapted to use agent-adapter.sh so the loop can drive either the
# Claude Code (`claude`) or Cursor (`cursor-agent`) CLI.

# =============================================================================
# SOURCE DEPENDENCIES
# =============================================================================

_RALPH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$_RALPH_SCRIPT_DIR/task-parser.sh" ]]; then
  source "$_RALPH_SCRIPT_DIR/task-parser.sh"
  _TASK_PARSER_AVAILABLE=1
else
  _TASK_PARSER_AVAILABLE=0
fi

if [[ -f "$_RALPH_SCRIPT_DIR/agent-adapter.sh" ]]; then
  source "$_RALPH_SCRIPT_DIR/agent-adapter.sh"
fi

if [[ -f "$_RALPH_SCRIPT_DIR/ralph-retry.sh" ]]; then
  source "$_RALPH_SCRIPT_DIR/ralph-retry.sh"
fi

# =============================================================================
# CONFIGURATION (overridable by caller before sourcing)
# =============================================================================

# Which agent CLI drives the loop: "claude" or "cursor-agent"
RALPH_AGENT_CLI="${RALPH_AGENT_CLI:-claude}"

# Model selection — resolved first so thresholds can key off [1m] suffix
if type agent_default_model >/dev/null 2>&1; then
  DEFAULT_MODEL="$(agent_default_model "$RALPH_AGENT_CLI")"
else
  DEFAULT_MODEL=""
fi
MODEL="${RALPH_MODEL:-${MODEL:-$DEFAULT_MODEL}}"

# Token thresholds — derived from CLI + model (extended [1m] vs standard)
if type agent_default_rotate_threshold >/dev/null 2>&1; then
  ROTATE_THRESHOLD="${ROTATE_THRESHOLD:-$(agent_default_rotate_threshold "$RALPH_AGENT_CLI" "$MODEL")}"
  WARN_THRESHOLD="${WARN_THRESHOLD:-$(agent_default_warn_threshold "$RALPH_AGENT_CLI" "$MODEL")}"
else
  ROTATE_THRESHOLD="${ROTATE_THRESHOLD:-80000}"
  WARN_THRESHOLD="${WARN_THRESHOLD:-70000}"
fi

# Iteration limits
MAX_ITERATIONS="${MAX_ITERATIONS:-20}"

# Feature flags (set by caller)
USE_BRANCH="${USE_BRANCH:-}"
OPEN_PR="${OPEN_PR:-false}"
# Parallel mode ceiling (Phase 5 — reserved; sequential-only in v0.1.0).
# Change this number to raise the cap. Each parallel agent is expensive
# (worktree + dependency install), so 5 is the recommended ceiling.
RALPH_MAX_PARALLEL="${RALPH_MAX_PARALLEL:-5}"

# Where the resolved prompt text lives after prompt-resolver.sh runs
RALPH_EFFECTIVE_PROMPT="${RALPH_EFFECTIVE_PROMPT:-.ralph/effective-prompt.md}"

# =============================================================================
# BASIC HELPERS
# =============================================================================

sedi() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

get_ralph_dir() {
  local workspace="${1:-.}"
  echo "$workspace/.ralph"
}

get_iteration() {
  local workspace="${1:-.}"
  local state_file="$workspace/.ralph/.iteration"
  if [[ -f "$state_file" ]]; then
    cat "$state_file"
  else
    echo "0"
  fi
}

set_iteration() {
  local workspace="${1:-.}"
  local iteration="$2"
  local ralph_dir="$workspace/.ralph"
  mkdir -p "$ralph_dir"
  echo "$iteration" > "$ralph_dir/.iteration"
}

increment_iteration() {
  local workspace="${1:-.}"
  local current
  current=$(get_iteration "$workspace")
  local next=$((current + 1))
  set_iteration "$workspace" "$next"
  echo "$next"
}

get_health_emoji() {
  local tokens="$1"
  local pct=$((tokens * 100 / ROTATE_THRESHOLD))
  if   [[ $pct -lt 60 ]]; then echo "🟢"
  elif [[ $pct -lt 80 ]]; then echo "🟡"
  else                         echo "🔴"
  fi
}

# =============================================================================
# LOGGING
# =============================================================================

log_activity() {
  local workspace="${1:-.}"
  local message="$2"
  local ralph_dir="$workspace/.ralph"
  local timestamp
  timestamp=$(date '+%H:%M:%S')
  mkdir -p "$ralph_dir"
  echo "[$timestamp] $message" >> "$ralph_dir/activity.log"
}

log_error() {
  local workspace="${1:-.}"
  local message="$2"
  local ralph_dir="$workspace/.ralph"
  local timestamp
  timestamp=$(date '+%H:%M:%S')
  mkdir -p "$ralph_dir"
  echo "[$timestamp] $message" >> "$ralph_dir/errors.log"
}

log_progress() {
  local workspace="$1"
  local message="$2"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local progress_file="$workspace/.ralph/progress.md"
  echo "" >> "$progress_file"
  echo "### $timestamp" >> "$progress_file"
  echo "$message" >> "$progress_file"
}

# =============================================================================
# INITIALIZATION
# =============================================================================

init_ralph_dir() {
  local workspace="$1"
  local ralph_dir="$workspace/.ralph"
  mkdir -p "$ralph_dir"

  if [[ ! -f "$ralph_dir/progress.md" ]]; then
    cat > "$ralph_dir/progress.md" << 'EOF'
# Progress Log

> Updated by the agent after significant work.

---

## Session History

EOF
  fi

  if [[ ! -f "$ralph_dir/guardrails.md" ]]; then
    cat > "$ralph_dir/guardrails.md" << 'EOF'
# Ralph Guardrails (Signs)

> Lessons learned from past failures. READ THESE BEFORE ACTING.

## Core Signs

### Sign: Read Before Writing
- **Trigger**: Before modifying any file
- **Instruction**: Always read the existing file first
- **Added after**: Core principle

### Sign: Test After Changes
- **Trigger**: After any code change
- **Instruction**: Run tests to verify nothing broke
- **Added after**: Core principle

### Sign: Commit Checkpoints
- **Trigger**: Before risky changes
- **Instruction**: Commit current working state first
- **Added after**: Core principle

---

## Learned Signs

EOF
  fi

  if [[ ! -f "$ralph_dir/errors.log" ]]; then
    cat > "$ralph_dir/errors.log" << 'EOF'
# Error Log

> Failures detected by stream-parser. Use to update guardrails.

EOF
  fi

  if [[ ! -f "$ralph_dir/activity.log" ]]; then
    cat > "$ralph_dir/activity.log" << 'EOF'
# Activity Log

> Real-time tool call logging from stream-parser.

EOF
  fi

  # Make sure .ralph is ignored. Idempotent.
  local gitignore="$workspace/.gitignore"
  if [[ -f "$gitignore" ]]; then
    if ! grep -qxF ".ralph/" "$gitignore" 2>/dev/null; then
      echo ".ralph/" >> "$gitignore"
    fi
  else
    echo ".ralph/" > "$gitignore"
  fi
}

# =============================================================================
# TASK MANAGEMENT
#
# Ralph's task checkbox accounting is shared with the agrimsingh port.
# For the spec-kit mode the "task file" is the rendered effective prompt
# and the underlying tasks.md is checked directly via task-parser.sh.
# =============================================================================

# Resolve which file we count checkboxes from:
#   1. $RALPH_TASK_FILE if set
#   2. $workspace/RALPH_TASK.md (upstream convention)
#   3. $workspace/PROMPT.md
#   4. $workspace/.ralph/effective-prompt.md
_resolve_task_file() {
  local workspace="$1"
  if [[ -n "${RALPH_TASK_FILE:-}" ]] && [[ -f "${RALPH_TASK_FILE}" ]]; then
    echo "$RALPH_TASK_FILE"; return
  fi
  # Spec-kit breadcrumb: resolve_prompt_spec writes the real tasks.md path here
  local breadcrumb="$workspace/.ralph/task-file-path"
  if [[ -f "$breadcrumb" ]]; then
    local bf
    bf=$(cat "$breadcrumb")
    if [[ -f "$bf" ]]; then
      echo "$bf"; return
    fi
  fi
  if [[ -f "$workspace/RALPH_TASK.md" ]]; then
    echo "$workspace/RALPH_TASK.md"; return
  fi
  if [[ -f "$workspace/PROMPT.md" ]]; then
    echo "$workspace/PROMPT.md"; return
  fi
  if [[ -f "$workspace/.ralph/effective-prompt.md" ]]; then
    echo "$workspace/.ralph/effective-prompt.md"; return
  fi
  echo ""
}

check_task_complete() {
  local workspace="$1"
  local task_file
  task_file=$(_resolve_task_file "$workspace")
  if [[ -z "$task_file" ]] || [[ ! -f "$task_file" ]]; then
    echo "NO_TASK_FILE"
    return
  fi
  _check_task_complete_direct "$task_file"
}

_check_task_complete_direct() {
  local task_file="$1"
  local unchecked
  unchecked=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[ \]' "$task_file" 2>/dev/null) || unchecked=0
  if [[ "$unchecked" -eq 0 ]]; then
    echo "COMPLETE"
  else
    echo "INCOMPLETE:$unchecked"
  fi
}

count_criteria() {
  local workspace="${1:-.}"
  local task_file
  task_file=$(_resolve_task_file "$workspace")
  if [[ -z "$task_file" ]] || [[ ! -f "$task_file" ]]; then
    echo "0:0"
    return
  fi
  local total done_count
  total=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x| )\]' "$task_file" 2>/dev/null) || total=0
  done_count=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]' "$task_file" 2>/dev/null) || done_count=0
  echo "$done_count:$total"
}

# =============================================================================
# PROMPT BUILDING
# =============================================================================

# Build the framing prompt sent on every iteration. This wraps the
# user-supplied prompt body (from prompt-resolver.sh) with the Ralph
# state-file protocol.
build_prompt() {
  local workspace="$1"
  local iteration="$2"
  local user_prompt_file="$workspace/$RALPH_EFFECTIVE_PROMPT"

  local user_body="(no effective prompt — put instructions in .ralph/effective-prompt.md)"
  if [[ -f "$user_prompt_file" ]]; then
    user_body=$(cat "$user_prompt_file")
  fi

  cat << EOF
# Ralph Iteration $iteration

You are an autonomous development agent using the Ralph methodology.

## FIRST: Read State Files

Before doing anything:
1. Read \`.ralph/guardrails.md\` — lessons from past failures (FOLLOW THESE)
2. Read \`.ralph/progress.md\` — what's been accomplished so far
3. Read \`.ralph/errors.log\` — recent failures to avoid

## Working Directory (Critical)

You are already in a git repository. Work HERE, not in a subdirectory:

- Do NOT run \`git init\` — the repo already exists
- Do NOT run scaffolding commands that create nested directories
- If you must scaffold, use flags like \`--no-git\` or target the current directory (\`.\`)

## Git Protocol (Critical)

Ralph's strength is state-in-git, not LLM memory. Commit early and often:

1. After completing each unit of work, commit with a descriptive message
2. After any significant code change (even partial): commit
3. Before any risky refactor: commit current state as a checkpoint
4. Push after every 2–3 commits

If you get rotated, the next agent picks up from your last commit.
Your commits ARE your memory.

## Task Execution (from effective prompt)

$user_body

## Completion Protocol

- When ALL criteria show \`[x]\`: output \`<ralph>COMPLETE</ralph>\` (or \`<promise>ALL_TASKS_DONE</promise>\`)
- If stuck 3+ times on the same issue: output \`<ralph>GUTTER</ralph>\`

## Learning from Failures

When something fails:
1. Check \`.ralph/errors.log\` for failure history
2. Figure out the root cause
3. Add a Sign to \`.ralph/guardrails.md\`:

\`\`\`
### Sign: [Descriptive Name]
- **Trigger**: When this situation occurs
- **Instruction**: What to do instead
- **Added after**: Iteration $iteration — what happened
\`\`\`

## Context Rotation Warning

You may receive a warning that context is running low. When you see it:
1. Finish your current file edit
2. Commit and push
3. Update .ralph/progress.md with what you accomplished and what's next
4. You will be rotated to a fresh agent that continues your work

Begin by reading the state files.
EOF
}

# =============================================================================
# SPINNER
# =============================================================================

spinner() {
  if [[ ! -t 2 ]]; then
    # No TTY on stderr (detached / redirected) — sleep quietly instead
    while true; do sleep 60; done
    return
  fi
  local workspace="$1"
  local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  while true; do
    printf "\r  🐛 Agent working... %s  (watch: tail -f %s/.ralph/activity.log)" "${spin:i++%${#spin}:1}" "$workspace" >&2
    sleep 0.1
  done
}

# =============================================================================
# ITERATION RUNNER
# =============================================================================

# Run a single agent iteration. Returns the final signal on stdout
# (ROTATE / GUTTER / COMPLETE / DEFER / empty).
run_iteration() {
  local workspace="$1"
  local iteration="$2"
  local session_id="${3:-}"
  local script_dir="${4:-$(dirname "${BASH_SOURCE[0]}")}"

  local prompt
  prompt=$(build_prompt "$workspace" "$iteration")

  local fifo="$workspace/.ralph/.parser_fifo"
  local spinner_pid="" agent_pid="" norm_filter=""

  _iteration_cleanup() {
    kill -- -"$agent_pid" 2>/dev/null || kill "$agent_pid" 2>/dev/null || true
    kill "$spinner_pid" 2>/dev/null || true
    wait "$agent_pid" 2>/dev/null || true
    wait "$spinner_pid" 2>/dev/null || true
    rm -f "$fifo" "$norm_filter"
    [[ -t 2 ]] && printf "\r\033[K" >&2
  }

  rm -f "$fifo"
  mkfifo "$fifo"

  # Save and install trap; restore on exit
  local _prev_trap
  _prev_trap=$(trap -p EXIT)
  trap '_iteration_cleanup' EXIT SIGTERM SIGHUP

  echo "" >&2
  echo "═══════════════════════════════════════════════════════════════════" >&2
  echo "🐛 Ralph Iteration $iteration" >&2
  echo "═══════════════════════════════════════════════════════════════════" >&2
  echo "" >&2
  echo "Workspace: $workspace" >&2
  echo "CLI:       $RALPH_AGENT_CLI" >&2
  echo "Model:     $MODEL" >&2
  echo "Monitor:   tail -f $workspace/.ralph/activity.log" >&2
  echo "" >&2

  log_progress "$workspace" "**Session $iteration started** (cli: $RALPH_AGENT_CLI, model: $MODEL)"

  local invoke_cmd
  invoke_cmd=$(agent_build_cmd "$RALPH_AGENT_CLI" "$MODEL" "$prompt" "$session_id")

  cd "$workspace"

  spinner "$workspace" &
  spinner_pid=$!

  # Export thresholds so stream-parser picks them up
  export WARN_THRESHOLD ROTATE_THRESHOLD

  # Write the normalization jq filter to a temp file so it can be
  # used in a subshell pipeline without re-sourcing agent-adapter.sh.
  norm_filter=$(mktemp)
  agent_normalize_filter "$RALPH_AGENT_CLI" > "$norm_filter"

  (
    eval "$invoke_cmd" 2>&1 \
      | jq --unbuffered -c -f "$norm_filter" 2>/dev/null \
      | "$script_dir/stream-parser.sh" "$workspace" > "$fifo"
    rm -f "$norm_filter"
  ) &
  agent_pid=$!

  local signal=""
  while IFS= read -r line; do
    case "$line" in
      "ROTATE")
        [[ -t 2 ]] && printf "\r\033[K" >&2
        echo "🔄 Context rotation triggered — stopping agent..." >&2
        kill -- -"$agent_pid" 2>/dev/null || kill "$agent_pid" 2>/dev/null || true
        signal="ROTATE"
        break
        ;;
      "WARN")
        [[ -t 2 ]] && printf "\r\033[K" >&2
        echo "⚠️  Context warning — agent should wrap up soon..." >&2
        ;;
      "GUTTER")
        [[ -t 2 ]] && printf "\r\033[K" >&2
        echo "🚨 Gutter detected — agent may be stuck..." >&2
        signal="GUTTER"
        ;;
      "COMPLETE")
        [[ -t 2 ]] && printf "\r\033[K" >&2
        echo "✅ Agent signaled completion!" >&2
        signal="COMPLETE"
        ;;
      "DEFER")
        [[ -t 2 ]] && printf "\r\033[K" >&2
        echo "⏸️  Rate limit or transient error — deferring for retry..." >&2
        signal="DEFER"
        kill -- -"$agent_pid" 2>/dev/null || kill "$agent_pid" 2>/dev/null || true
        ;;
    esac
  done < "$fifo"

  wait "$agent_pid" 2>/dev/null || true
  kill "$spinner_pid" 2>/dev/null || true
  wait "$spinner_pid" 2>/dev/null || true
  [[ -t 2 ]] && printf "\r\033[K" >&2
  rm -f "$fifo"

  # Restore previous trap
  if [[ -n "$_prev_trap" ]]; then
    eval "$_prev_trap"
  else
    trap - EXIT SIGTERM SIGHUP
  fi

  echo "$signal"
}

# =============================================================================
# MAIN LOOP
# =============================================================================

run_ralph_loop() {
  local workspace="$1"
  local script_dir="${2:-$(dirname "${BASH_SOURCE[0]}")}"

  cd "$workspace"
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "📦 Committing uncommitted changes..."
    git add -A
    git commit -m "ralph: initial commit before loop" || true
  fi

  if [[ -n "$USE_BRANCH" ]]; then
    echo "🌿 Creating branch: $USE_BRANCH"
    git checkout -b "$USE_BRANCH" 2>/dev/null || git checkout "$USE_BRANCH"
  fi

  echo ""
  echo "🚀 Starting Ralph loop..."
  echo ""

  local iteration=1
  local session_id=""

  while [[ $iteration -le $MAX_ITERATIONS ]]; do
    local signal
    signal=$(run_iteration "$workspace" "$iteration" "$session_id" "$script_dir")

    local task_status
    task_status=$(check_task_complete "$workspace")

    if [[ "$task_status" == "COMPLETE" ]]; then
      log_progress "$workspace" "**Session $iteration ended** — ✅ TASK COMPLETE"
      echo ""
      echo "═══════════════════════════════════════════════════════════════════"
      echo "🎉 RALPH COMPLETE! All criteria satisfied."
      echo "═══════════════════════════════════════════════════════════════════"
      echo ""
      echo "Completed in $iteration iteration(s)."

      if [[ "$OPEN_PR" == "true" ]] && [[ -n "$USE_BRANCH" ]]; then
        echo ""
        echo "📝 Opening pull request..."
        git push -u origin "$USE_BRANCH" 2>/dev/null || git push
        if command -v gh &>/dev/null; then
          gh pr create --fill || echo "⚠️  Could not create PR automatically."
        else
          echo "⚠️  gh CLI not found. Push complete, create PR manually."
        fi
      fi
      return 0
    fi

    case "$signal" in
      "COMPLETE")
        if [[ "$task_status" == "COMPLETE" ]]; then
          log_progress "$workspace" "**Session $iteration ended** — ✅ TASK COMPLETE (agent signaled)"
          return 0
        else
          log_progress "$workspace" "**Session $iteration ended** — Agent signaled complete but criteria remain"
          echo "⚠️  Agent signaled completion but unchecked criteria remain. Continuing..."
          iteration=$((iteration + 1))
        fi
        ;;
      "ROTATE")
        log_progress "$workspace" "**Session $iteration ended** — 🔄 Context rotation"
        echo "🔄 Rotating to fresh context..."
        iteration=$((iteration + 1))
        session_id=""
        ;;
      "GUTTER")
        log_progress "$workspace" "**Session $iteration ended** — 🚨 GUTTER"
        echo "🚨 Gutter detected. Check .ralph/errors.log for details."
        return 1
        ;;
      "DEFER")
        log_progress "$workspace" "**Session $iteration ended** — ⏸️ DEFERRED"
        local defer_delay=30
        if type calculate_backoff_delay &>/dev/null; then
          local defer_attempt=${DEFER_COUNT:-1}
          DEFER_COUNT=$((defer_attempt + 1))
          defer_delay=$(($(calculate_backoff_delay "$defer_attempt" 15 120 true) / 1000))
        fi
        echo "⏸️  Waiting ${defer_delay}s before retrying..."
        sleep "$defer_delay"
        ;;
      *)
        if [[ "$task_status" == INCOMPLETE:* ]]; then
          local remaining_count=${task_status#INCOMPLETE:}
          log_progress "$workspace" "**Session $iteration ended** — Agent finished naturally ($remaining_count remaining)"
          echo "📋 Agent finished but $remaining_count criteria remaining. Starting next iteration..."
          iteration=$((iteration + 1))
        fi
        ;;
    esac

    sleep 2
  done

  log_progress "$workspace" "**Loop ended** — ⚠️ Max iterations ($MAX_ITERATIONS) reached"
  echo "⚠️  Max iterations ($MAX_ITERATIONS) reached. Check progress manually."
  return 1
}

# =============================================================================
# PREREQUISITE CHECKS
# =============================================================================

check_prerequisites() {
  local workspace="$1"

  # Agent CLI present?
  if ! agent_check "$RALPH_AGENT_CLI"; then
    return 1
  fi

  # Git repo?
  if ! git -C "$workspace" rev-parse --git-dir >/dev/null 2>&1; then
    echo "❌ Not a git repository"
    echo "   Ralph requires git for state persistence."
    return 1
  fi

  # jq present? (required by the adapter's normalize filter)
  if ! command -v jq >/dev/null 2>&1; then
    cat >&2 <<'EOF'
❌ jq not found

Install jq:
  macOS:  brew install jq
  Debian: apt-get install jq
  Other:  https://jqlang.github.io/jq/
EOF
    return 1
  fi

  # Effective prompt rendered?
  if [[ ! -f "$workspace/$RALPH_EFFECTIVE_PROMPT" ]]; then
    echo "❌ No effective prompt found at $RALPH_EFFECTIVE_PROMPT"
    echo "   Run prompt-resolver.sh (via ralph-setup.sh) first, or pass --prompt-file."
    return 1
  fi

  return 0
}

# =============================================================================
# DISPLAY HELPERS
# =============================================================================

show_task_summary() {
  local workspace="$1"
  local task_file
  task_file=$(_resolve_task_file "$workspace")

  if [[ -z "$task_file" ]] || [[ ! -f "$task_file" ]]; then
    echo "(no task file detected)"
    echo ""
    return
  fi

  echo "📋 Effective prompt (first 30 lines):"
  echo "─────────────────────────────────────────────────────────────────"
  head -30 "$task_file"
  echo "─────────────────────────────────────────────────────────────────"
  echo ""

  local total done_count remaining
  total=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x| )\]' "$task_file" 2>/dev/null) || total=0
  done_count=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]' "$task_file" 2>/dev/null) || done_count=0
  remaining=$((total - done_count))

  echo "Progress: $done_count / $total criteria complete ($remaining remaining)"
  echo "CLI:      $RALPH_AGENT_CLI"
  echo "Model:    $MODEL"
  echo ""
}

show_banner() {
  echo "═══════════════════════════════════════════════════════════════════"
  echo "🐛 Ralph Wiggum: CLI-agnostic Autonomous Development Loop"
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
  echo "  \"That's the beauty of Ralph — the technique is deterministically"
  echo "   bad in an undeterministic world.\""
  echo ""
  echo "  ⚠️  This runs your chosen agent CLI with all tool approvals"
  echo "      pre-granted. Use only in a dedicated worktree with a clean"
  echo "      git state. Never run against uncommitted work you care about."
  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
  echo ""
}
