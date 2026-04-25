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

  # 0.3.6: Surface gate-run.sh in the non-speckit framing. Speckit-mode
  # prompts get a dedicated gate-invocation contract from speckit-prompt.md,
  # but custom-prompt and PROMPT.md loops had no gate awareness at all —
  # agents would run bare `pnpm test` and re-run on every failure to see
  # more output. The pointer below is a minimal hook: the full protocol
  # lives in docs/gate-run.md + `gate-run.sh --help`. Only rendered when
  # the wrapper is actually installed next to this script, so projects on
  # older plugin versions or standalone setups without it are not misled.
  local _rc_script_dir
  _rc_script_dir="$(dirname "${BASH_SOURCE[0]}")"
  local gate_run_path="$_rc_script_dir/gate-run.sh"
  local gate_block=""
  if [[ -f "$gate_run_path" ]]; then
    local gate_run_cmd="bash $gate_run_path"
    gate_block=$(
      cat <<GATE_EOF

## Gate Runner (read before running any verification command)

Run every test / lint / build via the wrapper \`$gate_run_cmd <label> <cmd>\`:

- **Labels** (pick the closest fit): \`basic\` \`final\` \`e2e\` \`lint\` \`custom\`
- **Never pipe, redirect, or filter the gate command.** The wrapper already
  prints a bounded summary and persists the full log. Piping (\`| grep\`,
  \`| tail\`, \`> /tmp/…\`) hides the exit code and forces an expensive re-run.
- **On failure:** do NOT re-run the gate. Read the persisted log at
  \`.ralph/gates/<label>-latest.log\` with targeted \`Read\` offsets or \`Grep\`,
  fix the smallest thing, then re-run once. Exit code lives at
  \`.ralph/gates/<label>-latest.exit\` (breadcrumb file).
- **On success:** do NOT re-read the log. The summary you already saw is
  authoritative. Commit and move on.
- Run \`$gate_run_cmd --help\` from your shell tool if you need the full
  contract (env vars, exit codes, failure-pattern matching, timeouts).
GATE_EOF
    )
  fi

  cat <<EOF
# Ralph Iteration $iteration
$hint_block
You are iteration $iteration of an autonomous loop. No memory of prior iterations.
Git log and tasks.md checkboxes are the authoritative record of what is done.

## Completion Bar (hard — read before anything else)

- A task/phase is NOT complete until its verification gate exits 0. No exceptions.
- "Pre-existing failure" is NEVER a reason to mark a task [x], emit a completion signal, or commit. If a check fails, fix it. If you cannot fix it, emit \`<ralph>GUTTER</ralph>\` with root cause in \`.ralph/errors.log\` — NEVER mark [x] around it.
- Before flipping \`[ ]\` → \`[x]\`, self-check: did the gate for this task exit 0 in THIS iteration?

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
- **Work every remaining unchecked task across every remaining phase** in this iteration. Do not stop at phase boundaries — the loop handles rotation and rate limits for you. Only yield on \`ALL_TASKS_DONE\`, rotation WARN, \`.ralph/stop-requested\`, or genuine GUTTER (0.4.0).
- **After every commit, check whether \`.ralph/stop-requested\` exists.** If it does, the loop is asking you to yield cleanly: finish no new task, flush any dirty edits into a final commit if appropriate, and exit. Do not remove the marker — the loop clears it at next iteration start.
$gate_block

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

# Format an iteration label for human-readable logs, folding in the per-
# iteration retry count when it matters.
#
# Background (0.3.7): prior versions logged "ITERATION N" / "Session N"
# regardless of how many times the same iteration had been retried on DEFER.
# Operators watching a long DEFER loop saw "ITERATION 1 START" / "ITERATION
# 1 END — ⏸️ DEFERRED" six times in a row and assumed the loop was frozen,
# when in fact it was making real progress across retries (committing tasks,
# advancing state). The counter only bumps on a clean natural end — DEFER
# and a few other paths retry the same iteration number — which is correct
# semantics but misleading in the log stream.
#
# Emits "N" when retry==0 (the common case) and "N.R" otherwise. All
# ITERATION / Session log lines in main_loop and run_iteration now route
# through this helper so a retry is immediately visible in both activity.log
# and progress.md without requiring the reader to reconstruct it.
#
# Args:
#   $1 — iteration number
#   $2 — retry count (default 0)
_fmt_iter() {
  local iter="$1"
  local retry="${2:-0}"
  if [[ "$retry" -gt 0 ]]; then
    printf '%s.%s' "$iter" "$retry"
  else
    printf '%s' "$iter"
  fi
}

# Classify how the heartbeat read loop exited.
#
# Emits one of the following tokens on stdout:
#   signalled  — the loop caller set a terminal signal (break/set), honour it
#   timeout    — read -t expired with no parser output (agent stalled).
#                Only distinguishable on bash ≥ 4.0, where `read -t` returns
#                128+SIGALRM (142) on timeout. On bash 3.2 (macOS /bin/bash)
#                timeout and EOF both return 1, so the "timeout" label is
#                never emitted there — both paths fall through to "eof",
#                where the agent-liveness probe still dispatches correctly
#                (agent-alive = treat as heartbeat-scale stall, agent-dead
#                = natural end).
#   eof        — FIFO hit EOF; could be a clean natural end OR a wedged
#                agent whose parser/jq pipeline crashed independently.
#                Caller must probe agent-pid liveness to disambiguate
#                (see _probe_agent_liveness). Prior to 0.3.2 this was
#                unconditionally treated as a parser crash and DEFERred,
#                which mis-classified every normal iteration end.
#
# IMPORTANT (0.3.9): the caller must capture `read`'s actual exit status,
# not the while-loop's. `while read; do :; done <fifo; rc=$?` silently
# reports rc=0 because bash defines `while`'s exit as "the exit status of
# the last command executed in list-2, or zero if none was executed" —
# every case arm in the body returns 0, so the real EOF/timeout status
# was being swallowed. See run_iteration's `|| { _read_rc=$?; break; }`
# idiom for the correct capture.
#
# Args:
#   $1 — exit status of the most recent `read` call (NOT the while loop)
#   $2 — current signal string (may be empty)
_classify_heartbeat_exit() {
  local rc="$1"
  local signal="$2"
  if [[ -n "$signal" ]]; then
    echo "signalled"
    return
  fi
  # read -t returns >128 on timeout in bash ≥ 4.0 (128+SIGALRM). Bash 3.2
  # returns 1 for both EOF and timeout — see docstring note above.
  if [[ "$rc" -gt 128 ]]; then
    echo "timeout"
    return
  fi
  # Any other non-zero (typically 1) or zero means EOF on the FIFO.
  echo "eof"
}

# Probe whether the agent subshell is still alive after a grace window.
#
# Disambiguates between two EOF-on-FIFO cases:
#   - Clean natural end: claude CLI exited normally (model finished its
#     turn with no queued tool calls), so jq and stream-parser EOFed in
#     turn. The subshell is exiting or already gone.
#   - Wedged agent: the parser/jq pipeline crashed but the claude CLI is
#     still running (e.g., blocked on a pipe write with no reader).
#
# Returns "hang" if the pid is still alive after grace_sec, else "clean".
# The grace loop polls once per second so clean exits return promptly.
#
# Args:
#   $1 — agent pid to probe
#   $2 — grace window in seconds (default 5)
_probe_agent_liveness() {
  local pid="$1"
  local grace_sec="${2:-5}"
  local deadline=$((SECONDS + grace_sec))
  while [[ $SECONDS -lt $deadline ]] && kill -0 "$pid" 2>/dev/null; do
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "hang"
  else
    echo "clean"
  fi
}

# Probe liveness of each stage inside the pipeline subshell.
#
# Background (0.3.7): the prior PARSER EXIT diagnostic ("pipeline died while
# agent still running") only probed the enclosing subshell (`agent_pid`).
# When that subshell is still alive after FIFO EOF, the diagnostic
# concluded "parser pipeline exited" — but field logs showed stream-parser
# continuing to emit log_activity entries for 30-60s AFTER the PARSER EXIT
# line was written. Something further up the pipe (likely jq losing stdout
# or exiting cleanly on a transient) was the real cause; stream-parser and
# the CLI were still fine. The diagnostic blamed the wrong stage and the
# loop killed the agent mid-task on false positives — ORPHAN LEAK warnings
# at commit time confirm tasks were landing right before the kill.
#
# This helper enumerates direct children of the subshell (which are the
# three pipeline stages: agent CLI | jq | stream-parser.sh) and classifies
# each as alive or dead. The classifier uses `ps -o comm=` patterns plus
# `ps -o args=` as a fallback for shells that strip the comm name to the
# wrapper (`bash`, `node`).
#
# Emits one status token per line on stdout:
#   claude=<alive|dead|unknown>
#   jq=<alive|dead>
#   parser=<alive|dead>
# Callers should read the lines and interpret them. Unknown stages are
# treated conservatively (not counted as dead) to avoid over-aggressive
# DEFERs when the process table lookup is racey.
#
# Args:
#   $1 — subshell pid whose children form the pipeline
_probe_pipeline_stages() {
  local agent_pid="$1"
  local claude_alive=0 jq_alive=0 parser_alive=0
  local any_alive=0

  # Walk direct children; classify by short comm first, fall back to full args.
  # pgrep -P returns direct children only — perfect for `a | b | c` inside
  # a subshell where a, b, c are all direct children of the subshell.
  #
  # 0.3.10: filter out zombies (STAT=Z). The previous implementation counted
  # a process as "alive" if `pgrep -P` returned it, but `pgrep` and `kill -0`
  # both report exited-but-unreaped processes (zombies) as present. Right
  # after claude exits, stream-parser's read loop EOFs and stream-parser
  # exits — but the subshell hasn't yet called `wait` on it, so the pid
  # sits as a zombie for a few milliseconds to seconds. In field logs we
  # saw PARSER EXIT fire with rc=1 (real FIFO EOF, natural end) yet the
  # probe reported all three stages "alive" because they were zombies
  # mid-teardown. Skipping Z-state pids reports an accurate picture.
  local pids
  pids=$(pgrep -P "$agent_pid" 2>/dev/null || true)
  local pid
  for pid in $pids; do
    local stat
    stat=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')
    # Skip zombies — they're dead, just not yet reaped. Also skip empty
    # (the pid vanished between pgrep and ps).
    [[ -z "$stat" || "$stat" == Z* ]] && continue
    any_alive=1
    local comm args
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')
    args=$(ps -o args= -p "$pid" 2>/dev/null || true)
    case "$comm" in
      jq | */jq) jq_alive=1 ;;
      claude | cursor-agent | */claude | */cursor-agent) claude_alive=1 ;;
      *)
        case "$args" in
          *stream-parser.sh*) parser_alive=1 ;;
          *" claude "* | *" claude"* | */claude\ *) claude_alive=1 ;;
          *cursor-agent*) claude_alive=1 ;;
          *" jq "* | *" jq"*) jq_alive=1 ;;
        esac
        ;;
    esac
  done

  # If the subshell has no children at all, the whole pipeline has finished
  # draining — report everything dead rather than "unknown" so callers can
  # distinguish a fully-torn-down pipeline from a partial crash.
  local claude_state jq_state parser_state
  if [[ $any_alive -eq 0 ]]; then
    claude_state="dead"
    jq_state="dead"
    parser_state="dead"
  else
    [[ $claude_alive -eq 1 ]] && claude_state="alive" || claude_state="dead"
    [[ $jq_alive -eq 1 ]] && jq_state="alive" || jq_state="dead"
    [[ $parser_alive -eq 1 ]] && parser_state="alive" || parser_state="dead"
  fi

  echo "claude=$claude_state"
  echo "jq=$jq_state"
  echo "parser=$parser_state"
}

# Run a single agent iteration. Returns the final signal on stdout
# (ROTATE / GUTTER / COMPLETE / DEFER / empty).
#
# Args:
#   $1 — workspace
#   $2 — iteration number
#   $3 — session_id (optional; continues a prior agent session when set)
#   $4 — script_dir (optional; defaults to the dir containing this file)
#   $5 — retry count for this iteration (optional; default 0). Only used
#        for human-readable log framing via _fmt_iter — the iteration
#        number the agent sees in its prompt stays numeric (N) so the
#        model's "iteration N of an autonomous loop" framing isn't
#        muddied by a retry suffix.
run_iteration() {
  local workspace="$1"
  local iteration="$2"
  local session_id="${3:-}"
  local script_dir="${4:-$(dirname "${BASH_SOURCE[0]}")}"
  local retry="${5:-0}"
  local iter_label
  iter_label=$(_fmt_iter "$iteration" "$retry")

  local prompt
  prompt=$(build_prompt "$workspace" "$iteration")

  # Snapshot worktree state before the agent runs so _check_orphan_leak
  # can flag any untracked files the agent commits.
  _capture_iteration_baseline "$workspace"

  # 0.4.0: clear any leftover stop-requested marker from a prior
  # iteration. The marker is the gentle-DEFER cooperation channel
  # (see the DEFER case below) and must be absent at iteration start
  # or the agent would bail out on its first commit.
  rm -f "$workspace/.ralph/stop-requested" 2>/dev/null || true

  local fifo="$workspace/.ralph/.parser_fifo"
  local spinner_pid="" agent_pid="" norm_filter=""
  local orphan_claims="$workspace/.ralph/.orphan-claims.pid"

  # 0.4.0: at iteration start, mop up any pids left behind by a prior
  # iteration that didn't clean up properly (e.g. killed mid-DEFER, or
  # its trap fired before children were fully reaped). Each ralph
  # iteration records its pipeline-stage pids to .orphan-claims.pid;
  # on the next start we sweep that file, SIGKILL anything still
  # running, and clear it. Without this, stale claude processes
  # accumulate across DEFER cycles — seen repeatedly in field runs
  # where kill -- -$agent_pid failed to reach grandchildren under
  # certain process-group configurations.
  if [[ -r "$orphan_claims" ]]; then
    local _stale_pid
    while IFS= read -r _stale_pid; do
      [[ -z "$_stale_pid" ]] && continue
      if kill -0 "$_stale_pid" 2>/dev/null; then
        log_activity "$workspace" "🧹 ORPHAN SWEEP — SIGKILL stale pid $_stale_pid from prior iteration"
        kill -9 "$_stale_pid" 2>/dev/null || true
      fi
    done <"$orphan_claims"
    rm -f "$orphan_claims"
  fi

  # shellcheck disable=SC2329 # invoked indirectly via trap
  _iteration_cleanup() {
    # 0.4.0: strict reaping with explicit escalation ladder. The old
    # path relied on a single `kill -- -$agent_pid` which silently
    # failed to reach grandchildren under some process-group configs,
    # leaving stale `claude` processes alive across retries. We now:
    #   1. Enumerate current descendants of the subshell via pgrep -P.
    #   2. SIGTERM each, wait briefly for voluntary exit.
    #   3. SIGKILL any survivors.
    #   4. Mop up anything still rooted at agent_pid with pkill -9.
    #   5. Record all tracked pids to .orphan-claims.pid as a safety
    #      net — the NEXT iteration's start-sweep picks up anything
    #      that still survived all of this.
    local _descendants _pid
    _descendants=$(pgrep -P "$agent_pid" 2>/dev/null || true)
    # SIGTERM sweep
    for _pid in $_descendants; do
      kill "$_pid" 2>/dev/null || true
    done
    # Targeted subshell kill (original behaviour, kept for hitting pg leader)
    kill -- -"$agent_pid" 2>/dev/null || kill "$agent_pid" 2>/dev/null || true
    # Brief grace for voluntary exit
    sleep 1
    # SIGKILL survivors
    for _pid in $_descendants; do
      if kill -0 "$_pid" 2>/dev/null; then
        kill -9 "$_pid" 2>/dev/null || true
      fi
    done
    # Broad mop-up on anything still rooted at the subshell
    pkill -9 -P "$agent_pid" 2>/dev/null || true

    # Record remaining pids for the next iteration's orphan sweep.
    : >"$orphan_claims"
    for _pid in $_descendants $agent_pid; do
      if kill -0 "$_pid" 2>/dev/null; then
        echo "$_pid" >>"$orphan_claims"
      fi
    done

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
  echo "🐛 Ralph Iteration $iter_label" >&2
  echo "═══════════════════════════════════════════════════════════════════" >&2
  echo "" >&2
  echo "Workspace: $workspace" >&2
  echo "CLI:       $RALPH_AGENT_CLI" >&2
  echo "Model:     $MODEL" >&2
  echo "Monitor:   tail -f $workspace/.ralph/activity.log" >&2
  echo "" >&2

  log_progress "$workspace" "**Session $iter_label started** (cli: $RALPH_AGENT_CLI, model: $MODEL)"

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
      "$script_dir/stream-parser.sh" "$workspace" "$iter_label" >"$fifo"
    rm -f "$norm_filter"
  ) &
  agent_pid=$!

  # Heartbeat timeout: if the stream-parser produces no output for
  # RALPH_HEARTBEAT_TIMEOUT seconds (default 5 min), the agent or API
  # is likely stalled. Kill the agent and emit DEFER so the loop retries
  # with exponential backoff.
  local heartbeat="${RALPH_HEARTBEAT_TIMEOUT:-300}"

  local signal=""
  # 0.3.9: capture `read`'s ACTUAL exit status.
  #
  # The previous `while read; do ... done <"$fifo"; rc=$?` idiom looked
  # right but was silently broken. Per bash(1): "The exit status of the
  # while and until commands is the exit status of the last command
  # executed in list-2, or zero if none was executed." Every case arm in
  # the loop body ends in `;;` and returns 0, and a `case` with no match
  # also returns 0 — so `$?` after `done` was always 0, never 1 (EOF) or
  # 142 (timeout). That made the "timeout" branch in _classify_heartbeat_exit
  # completely unreachable, routed every heartbeat-timeout through the
  # "eof" branch, and caused false-positive PARSER EXIT events roughly
  # every RALPH_HEARTBEAT_TIMEOUT seconds (5–6 min cadence in the field).
  #
  # The fix here makes `read`'s exit status observable: we break out of
  # the loop explicitly when read returns non-zero, and stash the real
  # rc in _read_rc at that moment. Now 1 is EOF, 142+ is timeout, and
  # the classifier routes correctly.
  local _read_rc=0
  while :; do
    IFS= read -t "$heartbeat" -r line || {
      _read_rc=$?
      break
    }
    case "$line" in
      "HEARTBEAT")
        # 0.4.0: no-op control token. Stream-parser emits HEARTBEAT on
        # every log_activity / log_token_status so this read iterates
        # fast enough that the `read -t` timer never expires while the
        # agent is productive. The timer exists to catch truly stalled
        # agents (no stream-json from claude at all), not quiet work
        # between commits — this branch is what makes the distinction
        # observable in the read loop.
        :
        ;;
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
      "SUGGEST_SKILL")
        # 0.6.0: Soft suggestion from stream-parser. The parser detected an
        # early stuck pattern (3 same-cmd failures or 3 same-file thrashes,
        # below the 5-strike hard recovery threshold) and wrote
        # `.ralph/skill-suggestion` with a recommended skill. The agent's
        # prompt directs it to read that file and switch modes. We do NOT
        # kill the agent here — same session continues. Logged to stderr
        # for operator visibility, then the read loop continues.
        [[ -t 2 ]] && printf "\r\033[K" >&2
        echo "💡 Skill suggestion written to .ralph/skill-suggestion (agent will pick up next turn)" >&2
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
        echo "⏸️  Rate limit or transient error — requesting graceful stop..." >&2
        signal="DEFER"
        # 0.4.0: gentle DEFER. Writing .ralph/stop-requested lets the
        # agent (per its prompt) finish its current tool sequence —
        # usually a commit — and exit on its own terms. A background
        # timer force-kills after RALPH_DEFER_GRACE seconds if the agent
        # is wedged on a network call and can't check the marker. Saves
        # in-flight commits that were previously torn up by the
        # immediate kill on every rate-limit blip.
        touch "$workspace/.ralph/stop-requested" 2>/dev/null || true
        (
          sleep "${RALPH_DEFER_GRACE:-30}"
          if kill -0 "$agent_pid" 2>/dev/null; then
            log_activity "$workspace" "⏰ DEFER GRACE EXPIRED — force-killing after ${RALPH_DEFER_GRACE:-30}s"
            kill -- -"$agent_pid" 2>/dev/null || kill "$agent_pid" 2>/dev/null || true
          fi
        ) &
        ;;
    esac
  done <"$fifo"

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
    eof)
      # 0.3.2: FIFO hit EOF. Disambiguate clean natural end from wedged
      # agent. Most iterations end naturally — claude CLI exits when the
      # model finishes its turn, jq/parser EOF in turn, and we fall
      # through to the `*)` natural-end branch in the main loop. Only
      # when the agent is still alive after a short grace window does
      # this indicate the 0.3.1-investigated hang (parser/jq crashed
      # independently) — then kill and DEFER.
      #
      # 0.3.7: stage-aware diagnosis + extended grace. In the field we saw
      # PARSER EXIT fire while stream-parser was still emitting activity
      # entries for another 30-60s, which meant the old "pipeline died"
      # blame was wrong and the resulting DEFER killed agents mid-task.
      # We now enumerate children of the pipeline subshell and report
      # per-stage liveness (claude / jq / parser). If stream-parser is
      # still alive we wait a longer window (RALPH_PIPELINE_EXTENDED_GRACE,
      # default 30s) before declaring the pipeline wedged — that window
      # covers the typical parser-drain-after-jq-close pattern where no
      # intervention is actually needed.
      local grace_sec="${RALPH_EOF_GRACE:-5}"
      local liveness
      liveness=$(_probe_agent_liveness "$agent_pid" "$grace_sec")
      if [[ "$liveness" == "hang" ]]; then
        local stages_out claude_state jq_state parser_state
        stages_out=$(_probe_pipeline_stages "$agent_pid")
        claude_state=$(echo "$stages_out" | awk -F= '/^claude=/ {print $2}')
        jq_state=$(echo "$stages_out" | awk -F= '/^jq=/ {print $2}')
        parser_state=$(echo "$stages_out" | awk -F= '/^parser=/ {print $2}')

        local ext_grace="${RALPH_PIPELINE_EXTENDED_GRACE:-30}"
        if [[ "$parser_state" == "alive" ]]; then
          # Give stream-parser time to finish draining whatever jq handed
          # it. Re-probe the whole subshell and the parser after the
          # extended grace. If the parser goes away cleanly during grace,
          # the subshell almost always follows.
          log_activity "$workspace" "⏳ PIPELINE DRAIN — stream-parser still alive after EOF, extending grace to ${ext_grace}s (claude=$claude_state jq=$jq_state)"
          liveness=$(_probe_agent_liveness "$agent_pid" "$ext_grace")
          if [[ "$liveness" == "clean" ]]; then
            # Parser drained, subshell exited. Fall through to natural end.
            log_activity "$workspace" "✅ PIPELINE DRAINED — subshell exited cleanly within extended grace; treating as natural end"
            :
          else
            # Re-probe to get fresh stage state for the exit message.
            stages_out=$(_probe_pipeline_stages "$agent_pid")
            claude_state=$(echo "$stages_out" | awk -F= '/^claude=/ {print $2}')
            jq_state=$(echo "$stages_out" | awk -F= '/^jq=/ {print $2}')
            parser_state=$(echo "$stages_out" | awk -F= '/^parser=/ {print $2}')
          fi
        fi

        if [[ "$liveness" == "hang" ]]; then
          [[ -t 2 ]] && printf "\r\033[K" >&2
          echo "💥 Pipeline wedged (claude=$claude_state jq=$jq_state parser=$parser_state) — killing and deferring..." >&2
          log_activity "$workspace" "💥 PARSER EXIT — pipeline wedged (claude=$claude_state jq=$jq_state parser=$parser_state, rc=$_read_rc, grace=${grace_sec}s+${ext_grace}s)"
          # Also record a breadcrumb in errors.log so post-mortems can
          # distinguish which stage died first.
          echo "[$(date '+%H:%M:%S')] PIPELINE_STAGE_EXIT: claude=$claude_state jq=$jq_state parser=$parser_state (rc=$_read_rc)" \
            >>"$workspace/.ralph/errors.log"
          kill -- -"$agent_pid" 2>/dev/null || kill "$agent_pid" 2>/dev/null || true
          signal="DEFER"
        fi
      fi
      # else: clean natural end — leave signal="" so the main loop's
      # `*)` branch increments the iteration as it did pre-0.3.1.
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

  # 0.4.0: mop-up any reparented-to-init claude CLI that escaped the
  # process-group kill. The agent's argv contains the workspace path
  # (resolved via {{TASK_FILE}} in the prompt) — scoping on that avoids
  # killing a concurrent ralph loop in another worktree. Handles the
  # case where kill -- -$agent_pid fails to reach a grandchild;
  # previously those survived as orphans holding API auth state and
  # consuming memory across retries. If anything survives even this,
  # the next iteration's orphan-sweep (orphan_claims at run_iteration
  # start) picks up the pieces.
  pkill -9 -f "$workspace.*Ralph Iteration" 2>/dev/null || true

  # 0.5.4: also reap the gate-run.sh subtree rooted at this workspace.
  # Gate runs spawn a deep tree (bash → pnpm → nx → vitest → N node
  # workers) that the pgrep -P walk above does not fully reach when the
  # iteration is killed mid-gate (recovery, DEFER, heartbeat timeout).
  # Surviving gate trees collide with the next iteration's first gate on
  # the shared $latest-link symlink, the coverage/ output dirs, and the
  # nx daemon — producing spurious failures that look like real bugs.
  # gate-run.sh's mkdir-mutex (0.5.4) catches some of this, but reaping
  # at iteration boundaries is the cleaner fix.
  pkill -9 -f "gate-run.sh.*$workspace" 2>/dev/null || true

  # Restore previous trap
  if [[ -n "$_prev_trap" ]]; then
    eval "$_prev_trap"
  else
    trap - EXIT SIGTERM SIGHUP
  fi

  echo "$signal"
}

# =============================================================================
# COMPLETE GUARD (0.3.3)
# =============================================================================
#
# When every checkbox in tasks.md is [x], the main loop used to treat that as
# authoritative and return 0. That let an agent "complete" a feature while
# the most recent gate was still red — the exact "pre-existing failure" bunt
# behaviour we want to prevent. These helpers inspect the gate-run.sh exit
# breadcrumbs (`.ralph/gates/<label>-latest.exit`, a single decimal integer
# written by gate-run.sh as of 0.3.3) and report whether the most recently
# run gate is green.
#
# Project-agnostic: if no exit breadcrumbs exist (no gates run yet, or an
# older plugin produced the .ralph state), the guard falls back to "allow
# COMPLETE" — backward-compatible, no regression risk.

# Emit the exit code from the most-recently-modified
# `.ralph/gates/*-latest.exit` file. Empty string if no such file exists.
_most_recent_gate_exit() {
  local workspace="$1"
  local dir="$workspace/.ralph/gates"
  [[ -d "$dir" ]] || return 0
  local latest=""
  local f
  # Portable mtime comparison via bash -nt; avoids the SC2012 ls pitfall
  # and works on both GNU and BSD userspace (macOS).
  for f in "$dir"/*-latest.exit; do
    [[ -f "$f" ]] || continue
    if [[ -z "$latest" ]] || [[ "$f" -nt "$latest" ]]; then
      latest="$f"
    fi
  done
  [[ -n "$latest" ]] || return 0
  cat "$latest" 2>/dev/null
}

# Return 0 if the main loop is allowed to honour a tasks-complete /
# COMPLETE signal, non-zero if it should be blocked (most recent gate was
# red). The fallback case (no gate breadcrumbs) returns 0 so projects that
# don't yet use gate-run.sh or that ran before 0.3.3 aren't regressed.
_complete_allowed() {
  local workspace="$1"
  local exit_code
  exit_code=$(_most_recent_gate_exit "$workspace")
  [[ -z "$exit_code" ]] && return 0
  [[ "$exit_code" == "0" ]]
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
  # 0.3.7: retry counter for the current iteration. Bumps on DEFER (the
  # only signal that re-runs the same iteration number) and resets to 0
  # every time iteration advances. Folded into log headers via _fmt_iter
  # so operators can tell at a glance that "ITERATION 1.3 START" is the
  # fourth attempt at iteration 1, not a new iteration.
  local retry=0
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

    local iter_label
    iter_label=$(_fmt_iter "$iteration" "$retry")

    if [[ "$pre_total" -gt 0 ]]; then
      log_activity "$workspace" "ITERATION $iter_label START — Tasks: $pre_done/$pre_total complete ($pre_remaining remaining)"
    else
      log_activity "$workspace" "ITERATION $iter_label START"
    fi

    local signal
    signal=$(run_iteration "$workspace" "$iteration" "$session_id" "$script_dir" "$retry")

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
      # 0.3.3 Completion Bar guard: refuse to exit the loop with a red gate,
      # even if every checkbox is [x]. Forces the agent to fix verification
      # failures rather than marking around them.
      if ! _complete_allowed "$workspace"; then
        local _last_exit
        _last_exit=$(_most_recent_gate_exit "$workspace")
        log_activity "$workspace" "🛑 COMPLETE BLOCKED — all tasks checked but most recent gate exited $_last_exit. Agent must get the gate to green (or escalate via <ralph>GUTTER</ralph>) before the loop can exit.$task_suffix"
        log_progress "$workspace" "**Session $iter_label ended** — 🛑 COMPLETE BLOCKED (gate red, exit=$_last_exit)"
        echo "🛑 Checkboxes all [x] but most recent gate exited $_last_exit — not honouring COMPLETE. Continuing..."
        # Reset stall/zero-progress counters — a red-gate block is not an
        # API hiccup, and work may have progressed this iteration.
        stall_count=0
        DEFER_COUNT=0
        # zero_progress_count deliberately unchanged; repeated blocked
        # iterations with zero forward motion should still trip the
        # natural-end stall detection below.
        iteration=$((iteration + 1))
        retry=0
        sleep 2
        continue
      fi

      log_activity "$workspace" "ITERATION $iter_label END — ✅ COMPLETE$task_suffix"
      log_progress "$workspace" "**Session $iter_label ended** — ✅ TASK COMPLETE"
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
          # 0.3.3 Completion Bar guard — same check as the task-status
          # path above. An agent-emitted <promise>ALL_TASKS_DONE</promise>
          # does not override a red final gate.
          if ! _complete_allowed "$workspace"; then
            local _last_exit
            _last_exit=$(_most_recent_gate_exit "$workspace")
            log_activity "$workspace" "🛑 COMPLETE BLOCKED — agent signaled COMPLETE but most recent gate exited $_last_exit.$task_suffix"
            log_progress "$workspace" "**Session $iter_label ended** — 🛑 COMPLETE BLOCKED (agent signaled; gate red, exit=$_last_exit)"
            echo "🛑 Agent signaled COMPLETE but most recent gate exited $_last_exit — not honouring. Continuing..."
            stall_count=0
            DEFER_COUNT=0
            iteration=$((iteration + 1))
            retry=0
            session_id=""
            continue
          fi
          log_activity "$workspace" "ITERATION $iter_label END — ✅ COMPLETE$task_suffix"
          log_progress "$workspace" "**Session $iter_label ended** — ✅ TASK COMPLETE (agent signaled)"
          return 0
        else
          log_activity "$workspace" "ITERATION $iter_label END — ⚠️ AGENT SIGNALED COMPLETE (criteria remain)$task_suffix"
          log_progress "$workspace" "**Session $iter_label ended** — Agent signaled complete but criteria remain"
          echo "⚠️  Agent signaled completion but unchecked criteria remain. Continuing..."
          stall_count=0
          zero_progress_count=0
          DEFER_COUNT=0
          iteration=$((iteration + 1))
          retry=0
        fi
        ;;
      "ROTATE")
        log_activity "$workspace" "ITERATION $iter_label END — 🔄 ROTATE$task_suffix"
        log_progress "$workspace" "**Session $iter_label ended** — 🔄 Context rotation"
        echo "🔄 Rotating to fresh context..."
        stall_count=0
        zero_progress_count=0
        DEFER_COUNT=0
        iteration=$((iteration + 1))
        retry=0
        session_id=""
        ;;
      "GUTTER")
        log_activity "$workspace" "ITERATION $iter_label END — 🚨 GUTTER$task_suffix"
        log_progress "$workspace" "**Session $iter_label ended** — 🚨 GUTTER"
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
          log_activity "$workspace" "ITERATION $iter_label END — 🔁 RECOVERY ATTEMPT $RECOVERY_ATTEMPTS/$MAX_RECOVERY_ATTEMPTS$task_suffix"
          log_progress "$workspace" "**Session $iter_label ended** — 🔁 RECOVERY ATTEMPT $RECOVERY_ATTEMPTS/$MAX_RECOVERY_ATTEMPTS"
          echo "🔁 Recovery attempt $RECOVERY_ATTEMPTS of $MAX_RECOVERY_ATTEMPTS — restarting iteration with hint..."
          # Do NOT bump stall_count/zero_progress_count — recovery is its
          # own budget, separate from natural-end and DEFER counters.
          iteration=$((iteration + 1))
          retry=0
          session_id=""
        else
          log_activity "$workspace" "ITERATION $iter_label END — 🚨 GUTTER (recovery budget exhausted: $MAX_RECOVERY_ATTEMPTS attempts)$task_suffix"
          log_progress "$workspace" "**Session $iter_label ended** — 🚨 GUTTER (recovery budget exhausted)"
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
        log_activity "$workspace" "ITERATION $iter_label END — ⏸️ DEFERRED$task_suffix"
        log_progress "$workspace" "**Session $iter_label ended** — ⏸️ DEFERRED"
        DEFER_COUNT=$((DEFER_COUNT + 1))
        stall_count=$((stall_count + 1))
        # 0.3.7: bump the per-iteration retry counter. Iteration number
        # stays the same (DEFER means "retry this iteration"), but the
        # retry suffix surfaces progress in activity.log/progress.md.
        retry=$((retry + 1))
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
          log_activity "$workspace" "ITERATION $iter_label END — NATURAL ($remaining_count remaining)$task_suffix"
          log_progress "$workspace" "**Session $iter_label ended** — Agent finished naturally ($remaining_count remaining)"
          echo "📋 Agent finished but $remaining_count criteria remaining. Starting next iteration..."
        else
          log_activity "$workspace" "ITERATION $iter_label END — NATURAL (no checkbox tracking)$task_suffix"
          log_progress "$workspace" "**Session $iter_label ended** — Agent finished naturally (no checkbox tracking)"
          stall_count=0
          zero_progress_count=0
          DEFER_COUNT=0
        fi
        iteration=$((iteration + 1))
        retry=0
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
