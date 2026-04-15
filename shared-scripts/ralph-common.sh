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
  echo "$iteration" >"$ralph_dir/.iteration"
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
  if [[ $pct -lt 60 ]]; then
    echo "🟢"
  elif [[ $pct -lt 80 ]]; then
    echo "🟡"
  else
    echo "🔴"
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
  echo "[$timestamp] $message" >>"$ralph_dir/activity.log"
}

log_error() {
  local workspace="${1:-.}"
  local message="$2"
  local ralph_dir="$workspace/.ralph"
  local timestamp
  timestamp=$(date '+%H:%M:%S')
  mkdir -p "$ralph_dir"
  echo "[$timestamp] $message" >>"$ralph_dir/errors.log"
}

log_progress() {
  local workspace="$1"
  local message="$2"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local progress_file="$workspace/.ralph/progress.md"
  {
    echo ""
    echo "### $timestamp"
    echo "$message"
  } >>"$progress_file"
}

# =============================================================================
# INITIALIZATION
# =============================================================================

init_ralph_dir() {
  local workspace="$1"
  local ralph_dir="$workspace/.ralph"
  mkdir -p "$ralph_dir"

  if [[ ! -f "$ralph_dir/progress.md" ]]; then
    cat >"$ralph_dir/progress.md" <<'EOF'
# Progress Log

> Updated by the agent after significant work.

---

## Session History

EOF
  fi

  if [[ ! -f "$ralph_dir/guardrails.md" ]]; then
    cat >"$ralph_dir/guardrails.md" <<'EOF'
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
    cat >"$ralph_dir/errors.log" <<'EOF'
# Error Log

> Failures detected by stream-parser. Use to update guardrails.

EOF
  fi

  if [[ ! -f "$ralph_dir/activity.log" ]]; then
    cat >"$ralph_dir/activity.log" <<'EOF'
# Activity Log

> Real-time tool call logging from stream-parser.

EOF
  fi

  # Make sure .ralph is ignored. Idempotent.
  local gitignore="$workspace/.gitignore"
  if [[ -f "$gitignore" ]]; then
    if ! grep -qxF ".ralph/" "$gitignore" 2>/dev/null; then
      echo ".ralph/" >>"$gitignore"
    fi
  else
    echo ".ralph/" >"$gitignore"
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
#   2. .ralph/task-file-path breadcrumb (spec-kit mode)
#   3. $workspace/PROMPT.md
#   4. $workspace/.ralph/effective-prompt.md
_resolve_task_file() {
  local workspace="$1"
  if [[ -n "${RALPH_TASK_FILE:-}" ]] && [[ -f "${RALPH_TASK_FILE}" ]]; then
    echo "$RALPH_TASK_FILE"
    return
  fi
  local breadcrumb="$workspace/.ralph/task-file-path"
  if [[ -f "$breadcrumb" ]]; then
    local bf
    bf=$(cat "$breadcrumb")
    if [[ -f "$bf" ]]; then
      echo "$bf"
      return
    fi
  fi
  if [[ -f "$workspace/PROMPT.md" ]]; then
    echo "$workspace/PROMPT.md"
    return
  fi
  if [[ -f "$workspace/.ralph/effective-prompt.md" ]]; then
    echo "$workspace/.ralph/effective-prompt.md"
    return
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
  local total
  total=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x|X| )\]' "$task_file" 2>/dev/null) || total=0
  if [[ "$total" -eq 0 ]]; then
    echo "NO_TASKS"
    return
  fi
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
# TASK SUMMARY (for activity.log)
# =============================================================================

_write_task_summary() {
  local workspace="$1"
  local ralph_dir="$workspace/.ralph"
  local summary_file="$ralph_dir/task-summary"
  local task_file
  task_file=$(_resolve_task_file "$workspace")

  if [[ -z "$task_file" ]] || [[ ! -f "$task_file" ]]; then
    rm -f "$summary_file"
    return
  fi

  local done_count total
  total=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x| )\]' "$task_file" 2>/dev/null) || total=0
  done_count=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]' "$task_file" 2>/dev/null) || done_count=0
  local remaining=$((total - done_count))

  {
    echo "done=$done_count"
    echo "total=$total"
    echo "remaining=$remaining"
    echo "---"
    grep -E '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[ \]' "$task_file" 2>/dev/null | head -10 || true
  } >"$summary_file"
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

  # 0.3.0: Active-recovery hint. If the prior iteration tripped a
  # recoverable stuck pattern (same shell-fail 2x, file thrash 5x), the
  # stream-parser wrote a hint to .ralph/recovery-hint.md and the loop
  # killed/restarted the agent. Prepend the hint here and delete the file
  # — recovery hints are consume-once. Subsequent iterations without a
  # hint produce a normal prompt.
  local hint_file="$workspace/.ralph/recovery-hint.md"
  local hint_block=""
  if [[ -f "$hint_file" ]]; then
    hint_block=$(cat "$hint_file")
    rm -f "$hint_file"
    hint_block=$'\n'"$hint_block"$'\n'
  fi

  cat <<EOF
# Ralph Iteration $iteration
$hint_block
You are iteration $iteration of an autonomous loop. No memory of prior iterations.
Git log and tasks.md checkboxes are the authoritative record of what is done.

## State Files (read before anything else)

1. \`.ralph/handoff.md\` — if it exists and is fresher than the latest commit, read first. Trust its pointers.
2. \`.ralph/guardrails.md\` — lessons from past failures. Follow these.
3. \`.ralph/errors.log\` — recent failures to avoid repeating.

Do **not** read \`.ralph/activity.log\` (human monitoring only).

## Signals

- All tasks done + final gate passes → \`<promise>ALL_TASKS_DONE</promise>\`
- Stuck 3+ times on same issue → \`<ralph>GUTTER</ralph>\`

## Loop Hygiene

- **Never** \`git add .ralph/\` — it is gitignored; \`git add\` on it returns exit 1 and aborts the commit.
- Commit after each task — commits are your memory across rotations.
- Never \`--amend\`, \`--force\`, or \`reset --hard\`. Fix mistakes with a new commit.
- At session end, write \`.ralph/handoff.md\` (< 30 lines, navigation pointers only).
- If context is running low, finish current edit, commit, and stop cleanly.

## Task Execution

$user_body
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
# ITERATION HYGIENE HELPERS
#
# Forensic helpers that run around each iteration to catch orphan-file
# leaks (see 0.1.10 RCA on the 005-comparison-*.md incident) and to
# persist a post-mortem tarball outside of .ralph/ when the loop crashes.
# =============================================================================

# Capture the baseline state of the worktree at the start of an iteration:
# current HEAD SHA and the list of currently-untracked files. Used by
# _check_orphan_leak after the iteration to detect whether the agent
# committed any files that were untracked at start (a strong signal that
# `git add .` / `git add <dir>` swept up orphans).
_capture_iteration_baseline() {
  local workspace="$1"
  local ralph_dir="$workspace/.ralph"
  mkdir -p "$ralph_dir"
  (cd "$workspace" && git rev-parse HEAD 2>/dev/null) >"$ralph_dir/iteration-baseline-head" || true
  (cd "$workspace" && git ls-files --others --exclude-standard 2>/dev/null | LC_ALL=C sort) \
    >"$ralph_dir/iteration-baseline-untracked" || true
}

# After an iteration, compare the files touched by any new commits against
# the untracked baseline. If any committed file was untracked at iteration
# start, it's a suspected orphan leak — log a warning to activity.log and
# append a concrete finding to errors.log. Non-blocking (the commits already
# happened); this is pure telemetry so the operator can spot the problem.
_check_orphan_leak() {
  local workspace="$1"
  local ralph_dir="$workspace/.ralph"
  local baseline_head="$ralph_dir/iteration-baseline-head"
  local baseline_untracked="$ralph_dir/iteration-baseline-untracked"
  [[ -f "$baseline_head" ]] || return 0
  [[ -f "$baseline_untracked" ]] || return 0
  [[ -s "$baseline_untracked" ]] || return 0

  local before_head after_head
  before_head=$(cat "$baseline_head")
  after_head=$(cd "$workspace" && git rev-parse HEAD 2>/dev/null) || return 0
  [[ "$before_head" == "$after_head" ]] && return 0

  local changed_files
  changed_files=$(cd "$workspace" && git diff --name-only "$before_head".."$after_head" 2>/dev/null) || return 0
  [[ -z "$changed_files" ]] && return 0

  local leaked
  leaked=$(LC_ALL=C comm -12 \
    <(printf '%s\n' "$changed_files" | LC_ALL=C sort -u) \
    "$baseline_untracked" 2>/dev/null)
  [[ -z "$leaked" ]] && return 0

  local leaked_inline
  leaked_inline=$(printf '%s' "$leaked" | tr '\n' ' ')
  log_activity "$workspace" "⚠️  ORPHAN LEAK: iteration committed files that were untracked at start: $leaked_inline"
  {
    echo ""
    echo "⚠️  ORPHAN FILE LEAK DETECTED"
    echo "   iteration baseline HEAD: $before_head"
    echo "   iteration end HEAD:      $after_head"
    echo "   files committed that were untracked at iteration start:"
    while IFS= read -r _leak_path; do
      [[ -n "$_leak_path" ]] && echo "     - $_leak_path"
    done <<<"$leaked"
    echo "   likely cause: agent used 'git add .', 'git add -A', or 'git add <dir>'"
    echo "   action: review the commits and revert the orphan files if they are"
    echo "           not part of the current task"
    echo ""
  } >>"$workspace/.ralph/errors.log"
}

# Write a post-mortem bundle when a loop ends in GUTTER or STALL. The bundle
# lives at <workspace>/.ralph-postmortems/<ISO-timestamp>-<reason>.tar.gz and
# contains the most important .ralph/ state files plus a snapshot of recent
# git activity. Host projects should gitignore .ralph-postmortems/.
_write_postmortem() {
  local workspace="$1"
  local reason="${2:-unknown}"
  local ralph_dir="$workspace/.ralph"
  [[ -d "$ralph_dir" ]] || return 0

  local pm_dir="$workspace/.ralph-postmortems"
  mkdir -p "$pm_dir"

  local ts
  ts=$(date -u '+%Y%m%dT%H%M%SZ')
  local tarball="$pm_dir/${ts}-${reason}.tar.gz"

  local staging
  staging=$(mktemp -d) || return 0

  local f
  for f in errors.log activity.log progress.md guardrails.md effective-prompt.md \
    iteration-baseline-head iteration-baseline-untracked task-file-path \
    basic-check-command final-check-command test-command; do
    [[ -f "$ralph_dir/$f" ]] && cp "$ralph_dir/$f" "$staging/" 2>/dev/null || true
  done

  (cd "$workspace" && git log --oneline -30 2>/dev/null) >"$staging/git-log.txt" || true
  (cd "$workspace" && git status --porcelain 2>/dev/null) >"$staging/git-status.txt" || true
  (cd "$workspace" && git rev-parse HEAD 2>/dev/null) >"$staging/git-head.txt" || true

  {
    echo "reason: $reason"
    echo "timestamp_utc: $ts"
    echo "workspace: $workspace"
    echo "ralph_agent_cli: ${RALPH_AGENT_CLI:-unknown}"
    echo "model: ${MODEL:-unknown}"
  } >"$staging/post-mortem-meta.txt"

  (cd "$staging" && tar -czf "$tarball" ./* 2>/dev/null) || true
  rm -rf "$staging"

  [[ -f "$tarball" ]] || return 0
  echo "📦 Post-mortem saved: $tarball" >&2
  log_activity "$workspace" "📦 Post-mortem bundle written: $tarball"
}

# =============================================================================
# ITERATION RUNNER
# =============================================================================

# Classify how the heartbeat read loop exited.
#
# Emits one of the following tokens on stdout:
#   signalled    — the loop caller set a terminal signal (break/set), honour it
#   timeout      — read -t expired with no parser output (agent stalled)
#   parser_died  — FIFO hit EOF: the jq|stream-parser pipeline exited while
#                  the agent subshell is presumably still alive. Pre-0.3.1
#                  this was silently treated as a clean natural end, which
#                  let wedged agents hang indefinitely on `wait` — see the
#                  hang-investigation note in CHANGELOG.
#
# Args:
#   $1 — exit status captured immediately after `done <"$fifo"`
#   $2 — current signal string (may be empty)
_classify_heartbeat_exit() {
  local rc="$1"
  local signal="$2"
  if [[ -n "$signal" ]]; then
    echo "signalled"
    return
  fi
  # read -t returns >128 on timeout (128 + signal number).
  if [[ "$rc" -gt 128 ]]; then
    echo "timeout"
    return
  fi
  # Any other non-zero (typically 1) means EOF on the FIFO.
  echo "parser_died"
}

# Run a single agent iteration. Returns the final signal on stdout
# (ROTATE / GUTTER / COMPLETE / DEFER / empty).
run_iteration() {
  local workspace="$1"
  local iteration="$2"
  local session_id="${3:-}"
  local script_dir="${4:-$(dirname "${BASH_SOURCE[0]}")}"

  local prompt
  prompt=$(build_prompt "$workspace" "$iteration")

  # Snapshot worktree state before the agent runs so _check_orphan_leak
  # can flag any untracked files the agent commits.
  _capture_iteration_baseline "$workspace"

  local fifo="$workspace/.ralph/.parser_fifo"
  local spinner_pid="" agent_pid="" norm_filter=""

  # shellcheck disable=SC2329 # invoked indirectly via trap
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

  cd "$workspace" || return

  spinner "$workspace" &
  spinner_pid=$!

  # Write task summary so stream-parser can log it on session start
  _write_task_summary "$workspace"

  # Export thresholds so stream-parser picks them up
  export WARN_THRESHOLD ROTATE_THRESHOLD

  # Write the normalization jq filter to a temp file so it can be
  # used in a subshell pipeline without re-sourcing agent-adapter.sh.
  norm_filter=$(mktemp)
  agent_normalize_filter "$RALPH_AGENT_CLI" >"$norm_filter"

  (
    eval "$invoke_cmd" 2>&1 |
      jq -n --unbuffered -c -f "$norm_filter" 2>>"$workspace/.ralph/errors.log" |
      "$script_dir/stream-parser.sh" "$workspace" "$iteration" >"$fifo"
    rm -f "$norm_filter"
  ) &
  agent_pid=$!

  # Heartbeat timeout: if the stream-parser produces no output for
  # RALPH_HEARTBEAT_TIMEOUT seconds (default 5 min), the agent or API
  # is likely stalled. Kill the agent and emit DEFER so the loop retries
  # with exponential backoff.
  local heartbeat="${RALPH_HEARTBEAT_TIMEOUT:-300}"

  local signal=""
  while IFS= read -t "$heartbeat" -r line; do
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
      "RECOVER_ATTEMPT")
        # 0.3.0: Recoverable stuck pattern hit (first time this iteration).
        # The stream-parser has written a recovery hint to
        # .ralph/recovery-hint.md. Kill the agent so the loop can re-spawn
        # it with the hint prepended to the framing prompt. The loop's
        # per-invocation budget decides whether to honour or escalate.
        [[ -t 2 ]] && printf "\r\033[K" >&2
        echo "🔁 Recovery attempt — killing agent and re-running with hint..." >&2
        kill -- -"$agent_pid" 2>/dev/null || kill "$agent_pid" 2>/dev/null || true
        signal="RECOVER_ATTEMPT"
        break
        ;;
      "RECOVER")
        # 0.1.16: Emitted by stream-parser on a successful `git commit`
        # (task boundary). Clears any latched GUTTER so a transient
        # mid-session stuck-pattern does not poison iteration-end
        # reporting once the agent has recovered and committed. ROTATE,
        # COMPLETE, and DEFER are terminal and are NOT cleared — they
        # represent real decisions the loop must honour.
        if [[ "$signal" == "GUTTER" ]]; then
          [[ -t 2 ]] && printf "\r\033[K" >&2
          echo "✅ Task boundary reached — clearing latched GUTTER signal." >&2
          signal=""
        fi
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
  done <"$fifo"
  # shellcheck disable=SC2181
  local _read_rc=$?

  local exit_class
  exit_class=$(_classify_heartbeat_exit "$_read_rc" "$signal")
  case "$exit_class" in
    timeout)
      [[ -t 2 ]] && printf "\r\033[K" >&2
      echo "⏰ Heartbeat timeout — no output in ${heartbeat}s, killing agent..." >&2
      log_activity "$workspace" "⏰ HEARTBEAT TIMEOUT after ${heartbeat}s — no stream-parser output"
      kill -- -"$agent_pid" 2>/dev/null || kill "$agent_pid" 2>/dev/null || true
      signal="DEFER"
      ;;
    parser_died)
      # 0.3.1: jq|stream-parser pipeline exited while the agent subshell
      # is still presumed alive. The FIFO hit EOF, not a timeout, so the
      # pre-0.3.1 code treated this as a clean natural end and blocked
      # forever on `wait "$agent_pid"`. Kill the agent and defer.
      [[ -t 2 ]] && printf "\r\033[K" >&2
      echo "💥 Parser pipeline exited unexpectedly — killing agent and deferring..." >&2
      log_activity "$workspace" "💥 PARSER EXIT — pipeline died while agent still running (rc=$_read_rc)"
      kill -- -"$agent_pid" 2>/dev/null || kill "$agent_pid" 2>/dev/null || true
      signal="DEFER"
      ;;
  esac

  # Wall-clock cap on `wait`: if the agent subshell does not exit within
  # RALPH_WAIT_TIMEOUT seconds after we've either signalled or detected a
  # parser/timeout condition, force-kill with SIGKILL. Prevents the loop
  # from hanging on a wedged CLI whose pipe peer is already dead (the
  # exact failure mode that motivated the 0.3.1 fix).
  local wait_timeout="${RALPH_WAIT_TIMEOUT:-60}"
  (
    sleep "$wait_timeout"
    if kill -0 "$agent_pid" 2>/dev/null; then
      log_activity "$workspace" "⏰ WAIT TIMEOUT — force-killing agent after ${wait_timeout}s"
      kill -9 -- -"$agent_pid" 2>/dev/null || kill -9 "$agent_pid" 2>/dev/null || true
    fi
  ) &
  local _wait_killer_pid=$!
  wait "$agent_pid" 2>/dev/null || true
  kill "$_wait_killer_pid" 2>/dev/null || true
  wait "$_wait_killer_pid" 2>/dev/null || true

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

  cd "$workspace" || return
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
  local stall_count=0         # DEFER/rate-limit consecutive count (threshold 10)
  local zero_progress_count=0 # natural-end with zero task delta (threshold 3)
  local DEFER_COUNT=0
  # 0.3.0: Active-recovery budget. Each RECOVER_ATTEMPT signal from the
  # stream-parser (recoverable stuck pattern detected) consumes one slot.
  # When exhausted, subsequent RECOVER_ATTEMPT signals escalate to GUTTER.
  local RECOVERY_ATTEMPTS=0
  local MAX_RECOVERY_ATTEMPTS="${RALPH_MAX_RECOVERY_ATTEMPTS:-2}"

  while [[ $iteration -le $MAX_ITERATIONS ]]; do
    local pre_counts
    pre_counts=$(count_criteria "$workspace")
    local pre_done=${pre_counts%%:*}
    local pre_total=${pre_counts##*:}
    local pre_remaining=$((pre_total - pre_done))

    if [[ "$pre_total" -gt 0 ]]; then
      log_activity "$workspace" "ITERATION $iteration START — Tasks: $pre_done/$pre_total complete ($pre_remaining remaining)"
    else
      log_activity "$workspace" "ITERATION $iteration START"
    fi

    local signal
    signal=$(run_iteration "$workspace" "$iteration" "$session_id" "$script_dir")

    # Non-blocking check: did the agent commit any files that were
    # untracked at iteration start? (orphan sweep via broad `git add`)
    _check_orphan_leak "$workspace"

    local task_status
    task_status=$(check_task_complete "$workspace")

    # Compute post-iteration task counts for the ITERATION END line
    local post_counts post_done post_total task_delta task_suffix
    post_counts=$(count_criteria "$workspace")
    post_done=${post_counts%%:*}
    post_total=${post_counts##*:}
    task_delta=$((post_done - pre_done))
    task_suffix=""
    if [[ "$post_total" -gt 0 ]]; then
      task_suffix=" (Tasks: $post_done/$post_total complete"
      if [[ "$task_delta" -gt 0 ]]; then
        task_suffix="$task_suffix, +$task_delta this iteration"
      fi
      task_suffix="$task_suffix)"
    fi

    if [[ "$task_status" == "COMPLETE" ]]; then
      log_activity "$workspace" "ITERATION $iteration END — ✅ COMPLETE$task_suffix"
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
        if [[ "$task_status" == "COMPLETE" || "$task_status" == "NO_TASKS" || "$task_status" == "NO_TASK_FILE" ]]; then
          log_activity "$workspace" "ITERATION $iteration END — ✅ COMPLETE$task_suffix"
          log_progress "$workspace" "**Session $iteration ended** — ✅ TASK COMPLETE (agent signaled)"
          return 0
        else
          log_activity "$workspace" "ITERATION $iteration END — ⚠️ AGENT SIGNALED COMPLETE (criteria remain)$task_suffix"
          log_progress "$workspace" "**Session $iteration ended** — Agent signaled complete but criteria remain"
          echo "⚠️  Agent signaled completion but unchecked criteria remain. Continuing..."
          stall_count=0
          zero_progress_count=0
          DEFER_COUNT=0
          iteration=$((iteration + 1))
        fi
        ;;
      "ROTATE")
        log_activity "$workspace" "ITERATION $iteration END — 🔄 ROTATE$task_suffix"
        log_progress "$workspace" "**Session $iteration ended** — 🔄 Context rotation"
        echo "🔄 Rotating to fresh context..."
        stall_count=0
        zero_progress_count=0
        DEFER_COUNT=0
        iteration=$((iteration + 1))
        session_id=""
        ;;
      "GUTTER")
        log_activity "$workspace" "ITERATION $iteration END — 🚨 GUTTER$task_suffix"
        log_progress "$workspace" "**Session $iteration ended** — 🚨 GUTTER"
        echo "🚨 Gutter detected. Check .ralph/errors.log for details."
        _write_postmortem "$workspace" "gutter"
        return 1
        ;;
      "RECOVER_ATTEMPT")
        # 0.3.0: Stream-parser hit a recoverable stuck pattern and wrote
        # a hint to .ralph/recovery-hint.md. Restart the iteration with
        # the hint prepended (build_prompt consumes the file). If the
        # per-loop budget is exhausted, escalate to GUTTER instead.
        if [[ $RECOVERY_ATTEMPTS -lt $MAX_RECOVERY_ATTEMPTS ]]; then
          RECOVERY_ATTEMPTS=$((RECOVERY_ATTEMPTS + 1))
          log_activity "$workspace" "ITERATION $iteration END — 🔁 RECOVERY ATTEMPT $RECOVERY_ATTEMPTS/$MAX_RECOVERY_ATTEMPTS$task_suffix"
          log_progress "$workspace" "**Session $iteration ended** — 🔁 RECOVERY ATTEMPT $RECOVERY_ATTEMPTS/$MAX_RECOVERY_ATTEMPTS"
          echo "🔁 Recovery attempt $RECOVERY_ATTEMPTS of $MAX_RECOVERY_ATTEMPTS — restarting iteration with hint..."
          # Do NOT bump stall_count/zero_progress_count — recovery is its
          # own budget, separate from natural-end and DEFER counters.
          iteration=$((iteration + 1))
          session_id=""
        else
          log_activity "$workspace" "ITERATION $iteration END — 🚨 GUTTER (recovery budget exhausted: $MAX_RECOVERY_ATTEMPTS attempts)$task_suffix"
          log_progress "$workspace" "**Session $iteration ended** — 🚨 GUTTER (recovery budget exhausted)"
          echo "🚨 Recovery budget exhausted ($MAX_RECOVERY_ATTEMPTS attempts) — escalating to GUTTER."
          # Discard any leftover hint so the next ralph invocation starts clean.
          rm -f "$workspace/.ralph/recovery-hint.md" 2>/dev/null || true
          _write_postmortem "$workspace" "gutter"
          return 1
        fi
        ;;
      "DEFER")
        # DEFER = API/network transient error (rate limit, 429, etc.).
        # Kept lenient (threshold 10) because rate limits can take minutes to clear.
        # Does NOT increment zero_progress_count — that's reserved for the agent
        # genuinely doing nothing useful, not for API hiccups.
        log_activity "$workspace" "ITERATION $iteration END — ⏸️ DEFERRED$task_suffix"
        log_progress "$workspace" "**Session $iteration ended** — ⏸️ DEFERRED"
        DEFER_COUNT=$((DEFER_COUNT + 1))
        stall_count=$((stall_count + 1))
        if [[ $stall_count -ge 10 ]]; then
          log_activity "$workspace" "LOOP END — 🚨 STALL: $stall_count consecutive empty/deferred iterations"
          log_progress "$workspace" "**Loop ended** — 🚨 STALL: $stall_count consecutive empty/deferred iterations, likely rate limited"
          echo "🚨 Stall detected: $stall_count consecutive iterations with no progress (likely rate limited)."
          echo "   Wait for your rate limit to reset and re-run."
          _write_postmortem "$workspace" "stall-defer"
          return 1
        fi
        local defer_delay
        defer_delay=$((15 * (1 << (DEFER_COUNT > 6 ? 6 : DEFER_COUNT - 1))))
        [[ $defer_delay -gt 300 ]] && defer_delay=300
        echo "⏸️  Waiting ${defer_delay}s before retrying (attempt $DEFER_COUNT)..."
        sleep "$defer_delay"
        ;;
      *)
        # Natural end (no signal). Uses zero_progress_count (threshold 3)
        # because repeated zero-delta iterations here mean the agent is
        # silently bailing out — not an API issue.
        if [[ "$task_status" == INCOMPLETE:* ]]; then
          local remaining_count=${task_status#INCOMPLETE:}
          if [[ "$task_delta" -eq 0 ]]; then
            zero_progress_count=$((zero_progress_count + 1))
          else
            zero_progress_count=0
            stall_count=0
            DEFER_COUNT=0
          fi
          if [[ $zero_progress_count -ge 3 ]]; then
            log_activity "$workspace" "LOOP END — 🚨 STALL: $zero_progress_count consecutive natural-end iterations with zero task progress"
            log_progress "$workspace" "**Loop ended** — 🚨 STALL: $zero_progress_count consecutive natural-end iterations with zero task progress"
            echo "🚨 Stall detected: $zero_progress_count consecutive iterations completed zero tasks and exited naturally."
            echo "   The agent is silently bailing out — check .ralph/errors.log and .ralph/progress.md for why."
            _write_postmortem "$workspace" "stall-natural"
            return 1
          fi
          log_activity "$workspace" "ITERATION $iteration END — NATURAL ($remaining_count remaining)$task_suffix"
          log_progress "$workspace" "**Session $iteration ended** — Agent finished naturally ($remaining_count remaining)"
          echo "📋 Agent finished but $remaining_count criteria remaining. Starting next iteration..."
        else
          log_activity "$workspace" "ITERATION $iteration END — NATURAL (no checkbox tracking)$task_suffix"
          log_progress "$workspace" "**Session $iteration ended** — Agent finished naturally (no checkbox tracking)"
          stall_count=0
          zero_progress_count=0
          DEFER_COUNT=0
        fi
        iteration=$((iteration + 1))
        ;;
    esac

    sleep 2
  done

  local final_counts final_done final_total
  final_counts=$(count_criteria "$workspace")
  final_done=${final_counts%%:*}
  final_total=${final_counts##*:}
  if [[ "$final_total" -gt 0 ]]; then
    log_activity "$workspace" "LOOP END — ⚠️ Max iterations ($MAX_ITERATIONS) reached (Tasks: $final_done/$final_total complete)"
  else
    log_activity "$workspace" "LOOP END — ⚠️ Max iterations ($MAX_ITERATIONS) reached"
  fi
  log_progress "$workspace" "**Loop ended** — ⚠️ Max iterations ($MAX_ITERATIONS) reached"
  echo "⚠️  Max iterations ($MAX_ITERATIONS) reached. Check progress manually."
  _write_postmortem "$workspace" "max-iterations"
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
