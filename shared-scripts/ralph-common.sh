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

# Loop ceiling (safety cap, not a target).
#
# Default 10. The unit of work is the LOOP — a healthy run completes a
# whole spec in ONE loop. This number is the upper bound on how many
# times the driver will respawn the agent process before giving up;
# it's a safety net for runaway recovery cycles, not a per-task counter.
# The driver's stall thresholds (3 consecutive natural-end zero-progress,
# 10 consecutive DEFER, 5 gate-fail TURN_END) all trip well before 10
# in any genuinely stuck scenario, so 10 is just the "you really
# shouldn't be here" backstop. Operators on smaller-context models (or
# genuinely huge specs) can override via --loops or MAX_LOOPS.
#
# 0.12.5: dropped the pre-0.6.3 deprecated aliases MAX_ITERATIONS and
# RALPH_MAX_ITERATIONS (verified zero usage in consuming projects).
MAX_LOOPS="${MAX_LOOPS:-${RALPH_MAX_LOOPS:-10}}"

# Feature flags (set by caller)
USE_BRANCH="${USE_BRANCH:-}"
OPEN_PR="${OPEN_PR:-false}"

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

get_health_emoji() {
  local tokens="$1"
  if [[ $tokens -lt $WARN_THRESHOLD ]]; then
    echo "🟢"
  elif [[ $tokens -lt $((ROTATE_THRESHOLD * 95 / 100)) ]]; then
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

  # 0.12.0: Seed handoff.md skeleton from the shared template if absent.
  # build_prompt injects this block at every loop start; gate-run.sh +
  # stream-parser maintain the "Last gate state" section automatically.
  if [[ ! -f "$ralph_dir/handoff.md" ]]; then
    local _handoff_skel
    _handoff_skel="$(dirname "${BASH_SOURCE[0]}")/../shared-references/templates/handoff-skeleton.md"
    if [[ -f "$_handoff_skel" ]]; then
      cp "$_handoff_skel" "$ralph_dir/handoff.md"
    fi
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

# Build the framing prompt sent at the start of every loop. This wraps
# the user-supplied prompt body (from prompt-resolver.sh) with the Ralph
# state-file protocol.
build_prompt() {
  local workspace="$1"
  local loop_n="$2"
  local user_prompt_file="$workspace/$RALPH_EFFECTIVE_PROMPT"

  local user_body="(no effective prompt — put instructions in .ralph/effective-prompt.md)"
  if [[ -f "$user_prompt_file" ]]; then
    user_body=$(cat "$user_prompt_file")
  fi

  # Handoff block — rolling state document injected every loop.
  # Maintained by stream-parser (`## Last gate state`), the agent
  # (`## Working set`), and the loop's auto-enricher (`## Auto-enriched
  # state` — last commit / last [x] / next unchecked).
  local handoff_block=""
  if [[ -f "$workspace/.ralph/handoff.md" ]]; then
    handoff_block=$(cat "$workspace/.ralph/handoff.md")
  fi

  # 0.14.0: Load the project's three tier-gate commands from
  # .ralph/command-policy [gates]. Startup validation (_validate_gates_section
  # in ralph-setup.sh) has already failed the loop if any are unset, so by
  # the time we get here all three are guaranteed non-empty.
  local _basic_cmd _full_cmd _final_cmd
  _load_gates_from_policy "$workspace" _basic_cmd _full_cmd _final_cmd

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

## Gate Runner

Tier-gate commands declared in .ralph/command-policy [gates]:
- basic: \`$_basic_cmd\`
- full:  \`$_full_cmd\`

The plugin hook auto-wraps these through \`$gate_run_cmd <label> <cmd>\` and
captures \`.ralph/gates/<label>-latest.log\` / \`.exit\` / \`.summary\` for you.
Do not pipe or tail the output — the wrapper already bounds it. Labels:
\`basic\` \`full\` \`final\` \`unit\` \`integration\` \`e2e\` \`lint\` \`format\`. On
failure, read the log + any Cypress/Playwright screenshots before re-running.
GATE_EOF
    )
  fi

  # 0.12.0: Inline the handoff block when present so the agent reads the last
  # gate state + working set as part of the framing prompt (not a separate
  # state-file Read it has to remember). Section markers preserved so the
  # next loop's writers (stream-parser, the agent) can find their slot.
  local handoff_section=""
  if [[ -n "$handoff_block" ]]; then
    handoff_section="
## Handoff from previous loop

$handoff_block
"
  fi

  # Gate selection guidance. Two short paragraphs covering which tier-gate
  # to run when, and where the failure summary lives. The tier-gate
  # commands are loaded from .ralph/command-policy [gates] above so this
  # framing always matches the project's actual gates and the completion
  # guard's expectations.
  local gate_selection_block
  gate_selection_block=$(
    cat <<GSEL_EOF

## Gate Selection

Run \`$_basic_cmd\` by default after each task. Only run \`$_full_cmd\`
when the current task line is marked \`[risky]\` in tasks.md. After a
\`[risky]\` task or at the end of the loop, one \`$_full_cmd\` is sufficient
— do not re-run to "double-check" green gates. The completion guard requires
a green \`$_full_cmd\` under label \`full\` before \`ALL_TASKS_DONE\`.

When a gate fails, the failure summary appears under \`## Last gate state\` in
the handoff block above. Read it before editing. To rerun just the failing
file, prefer the per-app targeted wrapper your project documents (e.g.
\`pnpm <app>:test-unit -- --testFile=<path>\`) rather than re-running the
full gate.
GSEL_EOF
  )

  cat <<EOF
# Ralph Loop $loop_n
$handoff_section
You are running inside a Ralph loop. Git log and tasks.md checkboxes
are the authoritative record of what is done. Commit after each task,
read the next one, keep going.

## Completion

- A task is NOT complete until its verification gate exits 0.
- You own every failure you see — regardless of what caused it. Fix it. If you truly cannot, emit \`<ralph>GUTTER</ralph>\` with root cause.
- Never mark \`[x]\` around a failing gate.

## State Files (read on startup)

The handoff block above is already inlined — do NOT re-read \`.ralph/handoff.md\`.
- \`.ralph/guardrails.md\` — lessons from past failures.
- \`.ralph/errors.log\` — recent failures to avoid repeating.
- \`.ralph/orphan-leak.md\` — if present, prior loop committed files that were untracked at its start; classify and proceed.

## Stop conditions (the only four)

End your turn ONLY when one of these is true. A successful commit is NOT a stop condition.

1. \`<promise>ALL_TASKS_DONE</promise>\` — every task \`[x]\` AND the final gate exits 0.
2. \`.ralph/stop-requested\` exists — operator asked the loop to wind down.
3. \`.ralph/context-warning-active\` exists — token budget is in the warning band; if you start another task you will be killed mid-work and lose progress.
4. \`<ralph>GUTTER</ralph>\` — genuinely stuck after honest investigation.

## After every commit (run these checks, in order)

1. If \`.ralph/stop-requested\` exists → write \`.ralph/handoff.md\` (see below), then yield. STOP THIS TURN.
2. If \`.ralph/context-warning-active\` exists → write \`.ralph/handoff.md\`, then yield. STOP THIS TURN. The loop will rotate to fresh context and the next agent resumes from your handoff.
3. Otherwise, your next tool call is the read of the next unchecked task. No summary, no turn-end.

## Handoff before yielding

Write \`.ralph/handoff.md\` with a \`## Working set\` section (≤ 10 lines) covering:
current task, files in flight, next planned step, ≤ 3 architectural facts you'd
want the next agent to know. Leave \`## Last gate state\` and \`## Auto-enriched state\`
alone — the plugin maintains them.

## Git hygiene

- Never \`git add .ralph/\` — it is gitignored.
- Never \`--amend\`, \`--force\`, or \`reset --hard\`. Fix mistakes with a new commit.
$gate_block
$gate_selection_block

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
# LOOP HYGIENE HELPERS
#
# Forensic helpers that run around each loop to catch orphan-file
# leaks (see 0.1.10 RCA on the 005-comparison-*.md incident) and to
# persist a post-mortem tarball outside of .ralph/ when the loop crashes.
# =============================================================================

# Capture the baseline state of the worktree at the start of a loop:
# current HEAD SHA and the list of currently-untracked files. Used by
# _check_orphan_leak after the loop to detect whether the agent
# committed any files that were untracked at start (a strong signal that
# `git add .` / `git add <dir>` swept up orphans).
_capture_loop_baseline() {
  local workspace="$1"
  local ralph_dir="$workspace/.ralph"
  mkdir -p "$ralph_dir"
  (cd "$workspace" && git rev-parse HEAD 2>/dev/null) >"$ralph_dir/loop-baseline-head" || true
  (cd "$workspace" && git ls-files --others --exclude-standard 2>/dev/null | LC_ALL=C sort) \
    >"$ralph_dir/loop-baseline-untracked" || true
  # 0.10.0: Clear hook state for this workspace so each new loop gets one
  # free gate run. The hook's gate-without-write check uses external state
  # files (not activity.log), so we clear them here.
  local _ws_real
  _ws_real=$(cd "$workspace" 2>/dev/null && pwd -P) || _ws_real="$workspace"
  local _ws_hash
  _ws_hash=$(echo -n "$_ws_real" | shasum -a 256 | cut -d' ' -f1)
  local _hook_state="${XDG_STATE_HOME:-$HOME/.local/state}/ralph/$_ws_hash"
  if [[ -d "$_hook_state" ]]; then
    # last-gate-ts.* is the per-label cache (0.13.1+); the bare 'last-gate-ts'
    # is the pre-0.13.1 form, kept here so upgrades clean it up cleanly.
    rm -f "$_hook_state/last-write-ts" "$_hook_state/last-gate-ts" "$_hook_state"/last-gate-ts.*
  fi
  # Clean up stale 0.9.x state files that are no longer written or consumed.
  rm -f "$ralph_dir/skill-suggestion" "$ralph_dir/recovery-hint.md" 2>/dev/null || true
  # 0.11.3: clear any prior loop's orphan-leak warning so the next loop sees
  # a fresh slate. _check_orphan_leak will recreate it if it fires again.
  rm -f "$ralph_dir/orphan-leak.md" 2>/dev/null || true
}

# After a loop, compare the files touched by any new commits against
# the untracked baseline. If any committed file was untracked at loop
# start, it's a suspected orphan leak — log a warning to activity.log and
# append a concrete finding to errors.log. Non-blocking (the commits already
# happened); this is pure telemetry so the operator can spot the problem.
_check_orphan_leak() {
  local workspace="$1"
  local ralph_dir="$workspace/.ralph"
  local baseline_head="$ralph_dir/loop-baseline-head"
  local baseline_untracked="$ralph_dir/loop-baseline-untracked"
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

  # 0.9.1: Filter out files explicitly named in the current task description.
  # When a task spec says "create E2E test at `apps/api/tests/e2e/foo.spec.ts`",
  # that file appearing as newly committed is expected, not a leak.
  local _task_summary="$ralph_dir/task-summary"
  if [[ -f "$_task_summary" ]]; then
    local _expected_paths=""
    # shellcheck disable=SC2016
    _expected_paths=$(sed -n '/^---$/,$p' "$_task_summary" |
      grep -oE '`[^`]+\.[a-zA-Z]{1,10}`' | tr -d '`' | LC_ALL=C sort -u 2>/dev/null) || true
    if [[ -n "$_expected_paths" ]]; then
      leaked=$(LC_ALL=C comm -23 \
        <(printf '%s\n' "$leaked" | LC_ALL=C sort -u) \
        <(printf '%s\n' "$_expected_paths" | LC_ALL=C sort -u) 2>/dev/null)
      [[ -z "$leaked" ]] && return 0
    fi
  fi

  local leaked_inline
  leaked_inline=$(printf '%s' "$leaked" | tr '\n' ' ')
  log_activity "$workspace" "⚠️  ORPHAN LEAK: loop committed files that were untracked at start: $leaked_inline"
  {
    echo ""
    echo "⚠️  ORPHAN FILE LEAK DETECTED"
    echo "   loop baseline HEAD: $before_head"
    echo "   loop end HEAD:      $after_head"
    echo "   files committed that were untracked at loop start:"
    while IFS= read -r _leak_path; do
      [[ -n "$_leak_path" ]] && echo "     - $_leak_path"
    done <<<"$leaked"
    echo "   likely cause: agent used 'git add .', 'git add -A', or 'git add <dir>'"
    echo "   action: review the commits and revert the orphan files if they are"
    echo "           not part of the current task"
    echo ""
  } >>"$workspace/.ralph/errors.log"

  # 0.11.3: Write an objective handoff stanza for the next loop. The framing
  # prompt directs the agent to read .ralph/orphan-leak.md on startup if
  # present. Strictly facts — file list and detector state, no editorial — so
  # the next turn can quickly classify (intended new module vs. real leak) and
  # proceed without inheriting confusion.
  {
    echo "# Orphan-leak warning (previous loop)"
    echo ""
    echo "The previous loop committed files that were untracked at its start."
    echo "This is informational — the warning does not block continuation. Verify"
    echo "the files below are intentional (e.g. new module per the active task);"
    echo "if any are scratch / debug / unrelated, revert them in a new commit."
    echo ""
    echo "**Loop baseline HEAD**: \`$before_head\`"
    echo "**Loop end HEAD**: \`$after_head\`"
    echo ""
    echo "**Files**:"
    while IFS= read -r _leak_path; do
      [[ -n "$_leak_path" ]] && echo "- \`$_leak_path\`"
    done <<<"$leaked"
  } >"$workspace/.ralph/orphan-leak.md"

  return 1
}

# Write a post-mortem bundle when a loop ends in GUTTER or STALL. The bundle
# lives at <workspace>/.ralph-postmortems/<ISO-timestamp>-<reason>.tar.gz and
# contains the most important .ralph/ state files plus a snapshot of recent
# git activity. Host projects should gitignore .ralph-postmortems/.
# 0.12.5: Distinguish a graceful yield from a generic natural-end.
#
# A graceful yield is a *good* loop boundary: the agent saw a breadcrumb
# (stop-requested or context-warning-active), wrote handoff.md, and ended
# its turn cleanly. A force-killed ROTATE/TURN_END or a polite "I think
# I'm done" natural-end are not graceful by this definition.
#
# Returns 0 (success) when graceful: $workspace/.ralph/handoff.md was
# modified during this loop iteration (more recent than loop-baseline-head,
# which _capture_loop_baseline rewrites at every loop start). Returns 1
# otherwise. Best-effort — false negatives are tolerable; the emoji is
# operator UX, not a correctness signal.
#
# 0.12.5: reuses the existing loop-baseline-head sentinel rather than
# maintaining a separate .loop-start-ts file. handoff-check.sh already
# uses loop-baseline-head's mtime for the same purpose.
_detect_graceful_yield() {
  local workspace="$1"
  local handoff="$workspace/.ralph/handoff.md"
  local loop_start="$workspace/.ralph/loop-baseline-head"
  [[ -f "$handoff" ]] || return 1
  [[ -f "$loop_start" ]] || return 1
  [[ "$handoff" -nt "$loop_start" ]] || return 1
  return 0
}

# 0.12.4: Auto-enrich handoff.md with mechanically-derivable state.
#
# Motivation: in practice, the agent rarely writes a "Working set" section
# before yielding — ROTATE/TURN_END force-kills don't give it a chance,
# and even on graceful yield it's easy to forget. The next session then
# boots blind, with only the bare TURN_END template (failing gate name)
# or a stale handoff from many loops ago.
#
# This appends an "## Auto-enriched state" section with three derivable
# facts: last commit, last task marked [x], next unchecked task. These
# are mechanically extracted from git + tasks.md, so the next session
# always has minimal carry-over context even with zero agent cooperation.
#
# Idempotent: if the section already exists, it's replaced (we don't
# pile up duplicate sections across loops).
_auto_enrich_handoff() {
  local workspace="$1"
  local handoff="$workspace/.ralph/handoff.md"
  [[ -f "$handoff" ]] || touch "$handoff"

  local last_commit=""
  if [[ -d "$workspace/.git" ]] || (cd "$workspace" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1); then
    last_commit=$(cd "$workspace" && git log -1 --format='%h %s' 2>/dev/null || true)
  fi

  local task_file last_done="" next_unchecked=""
  task_file=$(_resolve_task_file "$workspace")
  if [[ -n "$task_file" ]] && [[ -f "$task_file" ]]; then
    last_done=$(grep -E '^- \[x\] ' "$task_file" 2>/dev/null | tail -1 | sed -E 's/^- \[x\] //' | cut -c1-100 || true)
    next_unchecked=$(grep -E '^- \[ \] ' "$task_file" 2>/dev/null | head -1 | sed -E 's/^- \[ \] //' | cut -c1-100 || true)
  fi

  # No useful state — nothing to append.
  if [[ -z "$last_commit" ]] && [[ -z "$last_done" ]] && [[ -z "$next_unchecked" ]]; then
    return 0
  fi

  # Strip any existing "## Auto-enriched state" section so we don't pile up.
  if grep -q '^## Auto-enriched state' "$handoff" 2>/dev/null; then
    local tmp
    tmp=$(mktemp) || return 0
    awk '
      /^## Auto-enriched state[[:space:]]*$/ { in_section=1; next }
      in_section && /^## / { in_section=0 }
      !in_section { print }
    ' "$handoff" >"$tmp" && mv "$tmp" "$handoff"
  fi

  # Append the freshly-computed section. The trailing `:` ensures the block
  # returns 0 even when one or more of the conditional echoes are skipped
  # (otherwise `[[ -n "" ]] && echo` evaluates false and `set -e` aborts).
  {
    echo ""
    echo "## Auto-enriched state"
    echo ""
    [[ -n "$last_commit" ]] && echo "**Last commit**: \`$last_commit\`"
    [[ -n "$last_done" ]] && echo "**Last task done**: $last_done"
    [[ -n "$next_unchecked" ]] && echo "**Next unchecked**: $next_unchecked"
    :
  } >>"$handoff"
}

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
    loop-baseline-head loop-baseline-untracked task-file-path command-policy; do
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
# LOOP RUNNER
# =============================================================================

# Format a loop label for human-readable logs, folding in the per-loop
# retry count when it matters.
#
# Background (0.3.7): prior versions logged "LOOP N" regardless of how
# many times the same loop number had been retried on DEFER. Operators
# watching a long DEFER cycle saw "LOOP 1 START" / "LOOP 1 END —
# ⏸️ DEFERRED" six times in a row and assumed the driver was frozen,
# when in fact it was making real progress across retries (committing
# tasks, advancing state). The counter only bumps on a clean natural
# end — DEFER and a few other paths retry the same loop number — which
# is correct semantics but misleading in the log stream.
#
# Emits "N" when retry==0 (the common case) and "N.R" otherwise. All
# LOOP log lines in run_ralph_loop and run_loop route through this
# helper so a retry is immediately visible in both activity.log and
# progress.md without requiring the reader to reconstruct it.
#
# Args:
#   $1 — loop number
#   $2 — retry count (default 0)
_fmt_iter() {
  local loop_n="$1"
  local retry="${2:-0}"
  if [[ "$retry" -gt 0 ]]; then
    printf '%s.%s' "$loop_n" "$retry"
  else
    printf '%s' "$loop_n"
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
#                which mis-classified every normal natural-end loop.
#
# IMPORTANT (0.3.9): the caller must capture `read`'s actual exit status,
# not the while-loop's. `while read; do :; done <fifo; rc=$?` silently
# reports rc=0 because bash defines `while`'s exit as "the exit status of
# the last command executed in list-2, or zero if none was executed" —
# every case arm in the body returns 0, so the real EOF/timeout status
# was being swallowed. See run_loop's `|| { _read_rc=$?; break; }`
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

# Run a single agent loop. Returns the final signal on stdout
# (ROTATE / GUTTER / COMPLETE / DEFER / empty).
#
# Args:
#   $1 — workspace
#   $2 — loop number
#   $3 — session_id (optional; continues a prior agent session when set)
#   $4 — script_dir (optional; defaults to the dir containing this file)
#   $5 — retry count for this loop (optional; default 0). Only used
#        for human-readable log framing via _fmt_iter — the loop
#        number the agent sees in its prompt stays numeric (N) so the
#        model's framing isn't muddied by a retry suffix.
run_loop() {
  local workspace="$1"
  local loop_n="$2"
  local session_id="${3:-}"
  local script_dir="${4:-$(dirname "${BASH_SOURCE[0]}")}"
  local retry="${5:-0}"
  local loop_label
  loop_label=$(_fmt_iter "$loop_n" "$retry")

  local prompt
  prompt=$(build_prompt "$workspace" "$loop_n")

  # Snapshot worktree state before the agent runs so _check_orphan_leak
  # can flag any untracked files the agent commits.
  _capture_loop_baseline "$workspace"

  # 0.4.0: clear any leftover stop-requested marker from a prior loop.
  # The marker is the gentle-DEFER cooperation channel (see the DEFER
  # case below) and must be absent at loop start or the agent would
  # bail out on its first commit.
  rm -f "$workspace/.ralph/stop-requested" 2>/dev/null || true
  # 0.12.2: clear the context-warning breadcrumb so a fresh agent
  # doesn't immediately yield on its first task boundary.
  rm -f "$workspace/.ralph/context-warning-active" 2>/dev/null || true

  local fifo="$workspace/.ralph/.parser_fifo"
  local spinner_pid="" agent_pid="" norm_filter=""
  local orphan_claims="$workspace/.ralph/.orphan-claims.pid"

  # 0.4.0: at loop start, mop up any pids left behind by a prior loop
  # that didn't clean up properly (e.g. killed mid-DEFER, or its trap
  # fired before children were fully reaped). Each ralph loop records
  # its pipeline-stage pids to .orphan-claims.pid; on the next start we
  # sweep that file, SIGKILL anything still running, and clear it.
  # Without this, stale claude processes accumulate across DEFER cycles
  # — seen repeatedly in field runs where kill -- -$agent_pid failed to
  # reach grandchildren under certain process-group configurations.
  if [[ -r "$orphan_claims" ]]; then
    local _stale_pid
    while IFS= read -r _stale_pid; do
      [[ -z "$_stale_pid" ]] && continue
      if kill -0 "$_stale_pid" 2>/dev/null; then
        log_activity "$workspace" "🧹 ORPHAN SWEEP — SIGKILL stale pid $_stale_pid from prior loop"
        kill -9 "$_stale_pid" 2>/dev/null || true
      fi
    done <"$orphan_claims"
    rm -f "$orphan_claims"
  fi

  # shellcheck disable=SC2329 # invoked indirectly via trap
  _loop_cleanup() {
    # 0.4.0: strict reaping with explicit escalation ladder. The old
    # path relied on a single `kill -- -$agent_pid` which silently
    # failed to reach grandchildren under some process-group configs,
    # leaving stale `claude` processes alive across retries. We now:
    #   1. Enumerate current descendants of the subshell via pgrep -P.
    #   2. SIGTERM each, wait briefly for voluntary exit.
    #   3. SIGKILL any survivors.
    #   4. Mop up anything still rooted at agent_pid with pkill -9.
    #   5. Record all tracked pids to .orphan-claims.pid as a safety
    #      net — the NEXT loop's start-sweep picks up anything that
    #      still survived all of this.
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

    # Record remaining pids for the next loop's orphan sweep.
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
  trap '_loop_cleanup' EXIT SIGTERM SIGHUP

  echo "" >&2
  echo "═══════════════════════════════════════════════════════════════════" >&2
  echo "🐛 Ralph Loop $loop_label" >&2
  echo "═══════════════════════════════════════════════════════════════════" >&2
  echo "" >&2
  echo "Workspace: $workspace" >&2
  echo "CLI:       $RALPH_AGENT_CLI" >&2
  echo "Model:     $MODEL" >&2
  echo "Monitor:   tail -f $workspace/.ralph/activity.log" >&2
  echo "" >&2

  log_progress "$workspace" "**Session $loop_label started** (cli: $RALPH_AGENT_CLI, model: $MODEL)"

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
      "$script_dir/stream-parser.sh" "$workspace" "$loop_label" >"$fifo"
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
        # 0.13.1: auto-enrich now runs at the single loop-end chokepoint
        # in run_ralph_loop (right before `sleep 2`), so every loop boundary
        # gets fresh "Last commit / Last task / Next unchecked" carry-over,
        # not just force-kill paths.
        signal="ROTATE"
        break
        ;;
      "WARN")
        [[ -t 2 ]] && printf "\r\033[K" >&2
        echo "⚠️  Context warning — agent should wrap up soon..." >&2
        touch "$workspace/.ralph/context-warning-active" 2>/dev/null || true
        ;;
      "GUTTER")
        [[ -t 2 ]] && printf "\r\033[K" >&2
        echo "🚨 Gutter detected — agent may be stuck..." >&2
        signal="GUTTER"
        ;;
      "TURN_END")
        # 0.10.0: Mechanical turn-end signal. Emitted by stream-parser
        # when the gate-fail-streak threshold (5) is reached. Kill the
        # agent and rotate to a fresh context; the handoff-after-gate-fail
        # template + auto-enriched state carry forward the failure
        # context to the next session.
        [[ -t 2 ]] && printf "\r\033[K" >&2
        echo "🛑 Turn ended — killing agent and rotating to fresh context..." >&2
        kill -- -"$agent_pid" 2>/dev/null || kill "$agent_pid" 2>/dev/null || true
        signal="TURN_END"
        break
        ;;
      "RECOVER")
        # 0.1.16: Emitted by stream-parser on a successful `git commit`
        # (task boundary). Clears any latched GUTTER so a transient
        # mid-session stuck-pattern does not poison loop-end
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
      # agent. Most loops end naturally — claude CLI exits when the
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
      # `*)` branch increments the loop number as it did pre-0.3.1.
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
  # the next loop's orphan-sweep (orphan_claims at run_loop
  # start) picks up the pieces.
  # Pre-0.6.3 the marker said "Ralph Iteration"; post-0.6.3 it's "Ralph Loop".
  # Match either so an upgrade across a long-running session still reaps.
  pkill -9 -f "$workspace.*Ralph (Loop|Iteration)" 2>/dev/null || true

  # 0.5.4: also reap the gate-run.sh subtree rooted at this workspace.
  # Gate runs spawn a deep tree (bash → pnpm → nx → vitest → N node
  # workers) that the pgrep -P walk above does not fully reach when the
  # loop is killed mid-gate (recovery, DEFER, heartbeat timeout).
  # Surviving gate trees collide with the next loop's first gate on the
  # shared $latest-link symlink, the coverage/ output dirs, and the nx
  # daemon — producing spurious failures that look like real bugs.
  # gate-run.sh's mkdir-mutex (0.5.4) catches some of this, but reaping
  # at loop boundaries is the cleaner fix.
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
# When every checkbox in tasks.md is [x], the main loop must NOT treat that
# as authoritative on its own — that let agents "complete" a feature while
# the most recent gate was still red. The bar is the loop's own tier-gate:
# completion is honored only when that gate's -latest.cmd matches the pinned
# command from [gates] and its -latest.exit == 0.
#
# The two loops gate on DIFFERENT tiers:
#   - impl loop  → `full`  ([gates].full,  e.g. `pnpm all-check`)
#   - eval loop  → `final` ([gates].final, e.g. `pnpm all-check:no-cache`)
# ralph-evaluate.sh exports RALPH_EVAL_LOOP=1 before entering run_ralph_loop;
# _complete_allowed reads it to pick the right tier. Keying the eval loop on
# `full` (the pre-0.14.3 behavior) was unsatisfiable: the eval loop runs only
# `final` and wipes .ralph/gates at start, so full-latest.* never exists and
# completion blocked forever.

# Load the three tier-gate commands from `.ralph/command-policy` `[gates]`.
# Sets the three out-vars (passed by name) — basic, full, final. Missing
# keys yield empty strings; call _validate_gates_section first if you need
# completeness guaranteed.
#
# The [gates] section is the single source of truth for which command runs
# at each tier; no defaults, no breadcrumb-file fallbacks. Format:
#   [gates]
#   basic | <command>
#   full  | <command>
#   final | <command>
_load_gates_from_policy() {
  local workspace="$1"
  local basic_var="$2" full_var="$3" final_var="$4"
  local policy="$workspace/.ralph/command-policy"

  local basic_cmd="" full_cmd="" final_cmd=""

  if [[ -f "$policy" ]]; then
    local section="" line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      line="$(printf '%s' "$line" | sed -E 's/[[:space:]]+$//')"
      case "$line" in
        "" | \#*) continue ;;
        "[gates]")
          section="gates"
          continue
          ;;
        "["*"]")
          section=""
          continue
          ;;
      esac
      [[ "$section" == "gates" ]] || continue
      [[ "$line" == *"|"* ]] || continue

      key="${line%%|*}"
      value="${line#*|}"
      key="$(printf '%s' "$key" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
      value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
      [[ -z "$key" ]] && continue

      # shellcheck disable=SC2034  # tier locals are read indirectly via eval below
      case "$key" in
        basic) basic_cmd="$value" ;;
        full) full_cmd="$value" ;;
        final) final_cmd="$value" ;;
      esac
    done <"$policy"
  fi

  eval "$basic_var=\$basic_cmd"
  eval "$full_var=\$full_cmd"
  eval "$final_var=\$final_cmd"
}

# Validate that [gates] declares all three tier commands. Returns 0 on
# success; on failure prints a clear error to stderr naming the missing
# tier(s), appends to .ralph/errors.log if writable, and returns 1. Called
# at session entry — a misconfigured project must not reach the agent.
_validate_gates_section() {
  local workspace="$1"
  local basic full final
  _load_gates_from_policy "$workspace" basic full final

  local missing=()
  [[ -z "$basic" ]] && missing+=("basic")
  [[ -z "$full" ]] && missing+=("full")
  [[ -z "$final" ]] && missing+=("final")
  [[ ${#missing[@]} -eq 0 ]] && return 0

  local policy="$workspace/.ralph/command-policy"
  local file_state="missing"
  [[ -f "$policy" ]] && file_state="present but missing tier rows"

  {
    printf '\n❌ .ralph/command-policy [gates] is incomplete (%s).\n' "$file_state"
    printf '   Missing required tier(s): %s\n' "${missing[*]}"
    printf '   Add a [gates] section with all three of:\n'
    printf '     basic | <command>   # per-task check, after every task\n'
    printf '     full  | <command>   # impl-loop completion gate, after [risky] tasks\n'
    printf '     final | <command>   # eval-loop gate (post-completion verification)\n'
    printf '   See shared-references/templates/command-policy.md for a worked example.\n'
  } >&2

  if [[ -d "$workspace/.ralph" ]]; then
    {
      printf '\n[%s] FATAL: incomplete [gates] in .ralph/command-policy\n' "$(date '+%H:%M:%S')"
      printf '  Missing tier(s): %s\n' "${missing[*]}"
    } >>"$workspace/.ralph/errors.log" 2>/dev/null || true
  fi
  return 1
}

# Return 0 if the main loop is allowed to honour a tasks-complete /
# COMPLETE signal, non-zero if it should be blocked. Completion requires
# the loop's tier-gate to have run, its recorded command to match the
# pinned `[gates]` entry from .ralph/command-policy verbatim, and its exit
# code to be 0. Anything less blocks ALL_TASKS_DONE.
#
# The tier depends on which loop is running: the impl loop gates on `full`,
# the eval loop on `final`. ralph-evaluate.sh exports RALPH_EVAL_LOOP=1
# before entering run_ralph_loop to select the latter (see the COMPLETE
# GUARD comment block above).
#
# When this function returns non-zero, $_COMPLETE_BLOCK_REASON is set to
# a short, human-readable phrase the caller logs verbatim — single
# source of truth for the BLOCKED message in activity.log/progress.md.
_COMPLETE_BLOCK_REASON=""

_complete_allowed() {
  local workspace="$1"
  _COMPLETE_BLOCK_REASON=""

  local _basic _full _final
  _load_gates_from_policy "$workspace" _basic _full _final

  # Pick the tier this loop completes on. The eval loop runs `final` and
  # wipes .ralph/gates at start, so it must NOT be judged against `full`.
  local label pinned_gate
  if [[ "${RALPH_EVAL_LOOP:-}" == "1" ]]; then
    label="final"
    pinned_gate="$_final"
  else
    label="full"
    pinned_gate="$_full"
  fi

  local cmd_file="$workspace/.ralph/gates/${label}-latest.cmd"
  local exit_file="$workspace/.ralph/gates/${label}-latest.exit"

  if [[ -z "$pinned_gate" ]]; then
    _COMPLETE_BLOCK_REASON="no [gates].${label} in .ralph/command-policy"
    return 1
  fi

  if [[ ! -f "$cmd_file" ]]; then
    _COMPLETE_BLOCK_REASON="${label} gate \"$pinned_gate\" has not run yet"
    return 1
  fi

  local pinned_cmd actual_cmd
  pinned_cmd=$(printf '%s' "$pinned_gate" | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//')
  actual_cmd=$(tr -d '\n' <"$cmd_file")
  actual_cmd=$(printf '%s' "$actual_cmd" | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//')

  if [[ "$actual_cmd" != "$pinned_cmd" ]]; then
    _COMPLETE_BLOCK_REASON="${label} gate must run \"$pinned_cmd\" but last label=${label} ran \"$actual_cmd\""
    return 1
  fi
  local gate_exit=""
  [[ -f "$exit_file" ]] && gate_exit=$(cat "$exit_file" 2>/dev/null)
  if [[ "$gate_exit" != "0" ]]; then
    _COMPLETE_BLOCK_REASON="${label} gate \"$pinned_cmd\" exited ${gate_exit:-?}"
    return 1
  fi
  return 0
}

# Track consecutive COMPLETE-BLOCKED loops that share the SAME block reason.
# Returns 0 (escalate) once the run has been blocked for the same reason
# RALPH_COMPLETE_BLOCK_THRESHOLD times in a row, 1 (keep looping) otherwise.
# A reason that keeps repeating means the bar is unsatisfiable in this phase
# (e.g. a [gates] misconfiguration) rather than something the agent can fix
# by looping again — so failing loud beats spinning to MAX_LOOPS. State lives
# in the _COMPLETE_BLOCK_COUNT / _LAST_COMPLETE_BLOCK_REASON globals, reset at
# the loop-end chokepoint (which block paths `continue` past, so any non-block
# loop clears the streak). Default threshold 2: the first block can be benign
# (agent signaled COMPLETE before the gate ran); a second identical one is the
# tell that no amount of looping will clear it.
_COMPLETE_BLOCK_COUNT=0
_LAST_COMPLETE_BLOCK_REASON=""

_complete_block_escalates() {
  local reason="$1"
  if [[ "$reason" == "$_LAST_COMPLETE_BLOCK_REASON" ]]; then
    _COMPLETE_BLOCK_COUNT=$((_COMPLETE_BLOCK_COUNT + 1))
  else
    _COMPLETE_BLOCK_COUNT=1
    _LAST_COMPLETE_BLOCK_REASON="$reason"
  fi
  [[ $_COMPLETE_BLOCK_COUNT -ge ${RALPH_COMPLETE_BLOCK_THRESHOLD:-2} ]]
}

# Log + post-mortem for an unsatisfiable completion bar, then the caller
# returns 1 to stop the loop. Kept separate so both block sites share one
# message. $_COMPLETE_BLOCK_REASON must still hold the (repeated) reason.
_fail_unsatisfiable_completion() {
  local workspace="$1" task_suffix="${2:-}"
  log_activity "$workspace" "RALPH STOP — 🚨 UNSATISFIABLE COMPLETION BAR: blocked ${_COMPLETE_BLOCK_COUNT}× in a row with the same reason ($_COMPLETE_BLOCK_REASON). The bar cannot be met in this phase — likely a .ralph/command-policy [gates] misconfiguration, not agent error.$task_suffix"
  log_progress "$workspace" "**Ralph stopped** — 🚨 Unsatisfiable completion bar ($_COMPLETE_BLOCK_REASON)"
  echo "🚨 Completion blocked ${_COMPLETE_BLOCK_COUNT}× in a row with the same reason:"
  echo "   $_COMPLETE_BLOCK_REASON"
  echo "   This bar cannot be satisfied in the current phase. Check .ralph/command-policy"
  echo "   [gates] and the tier-gate this loop runs (impl → full, eval → final)."
  _write_postmortem "$workspace" "unsatisfiable-completion"
}

# =============================================================================
# MAIN LOOP
# =============================================================================

run_ralph_loop() {
  local workspace="$1"
  local script_dir="${2:-$(dirname "${BASH_SOURCE[0]}")}"

  export RALPH_WORKSPACE="$workspace"

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

  # 0.6.3: terminology — these used to be "iterations." Renamed to "loops"
  # so the unit of work matches the project name (the Ralph loop) and so
  # we don't reinforce the false notion that one task = one loop. A
  # well-behaved single agent process completes a whole spec in ONE loop.
  # Spawning a second loop is a recovery action, not a normal cadence.
  local loop_n=1
  # 0.3.7: retry counter for the current loop. Bumps on DEFER (the only
  # signal that re-runs the same loop number) and resets to 0 every time
  # loop_n advances. Folded into log headers via _fmt_iter so operators
  # can tell at a glance that "LOOP 1.3 START" is the fourth attempt at
  # loop 1, not a new loop.
  local retry=0
  local session_id=""
  local stall_count=0         # DEFER/rate-limit consecutive count (threshold 10)
  local zero_progress_count=0 # natural-end with zero task delta (threshold 3)
  # 0.14.3: reset the consecutive-identical-COMPLETE-BLOCKED tracker (globals
  # so the _complete_block_escalates helper can update them). See the helper
  # and the loop-end chokepoint reset below.
  _COMPLETE_BLOCK_COUNT=0
  _LAST_COMPLETE_BLOCK_REASON=""
  local natural_end_count=0 # 0.6.3: any natural-end (with or without progress) — measures "agent bailed politely instead of staying in flow"
  local DEFER_COUNT=0

  while [[ $loop_n -le $MAX_LOOPS ]]; do
    local pre_counts
    pre_counts=$(count_criteria "$workspace")
    local pre_done=${pre_counts%%:*}
    local pre_total=${pre_counts##*:}
    local pre_remaining=$((pre_total - pre_done))

    local loop_label
    loop_label=$(_fmt_iter "$loop_n" "$retry")

    if [[ "$pre_total" -gt 0 ]]; then
      log_activity "$workspace" "LOOP $loop_label START — Tasks: $pre_done/$pre_total complete ($pre_remaining remaining)"
    else
      log_activity "$workspace" "LOOP $loop_label START"
    fi

    local signal
    signal=$(run_loop "$workspace" "$loop_n" "$session_id" "$script_dir" "$retry")

    # 0.11.1: driver-side graceful-stop check. If `.ralph/stop-requested`
    # exists and the loop's exit signal is NOT "DEFER", honor it as a
    # user-initiated stop. The DEFER handler ALSO writes stop-requested
    # (as its gentle-stop cooperation channel — see line ~1273) but in
    # that case signal=="DEFER" and we let DEFER's own retry-with-backoff
    # logic run instead. So the guard is on the signal, not the file's
    # provenance.
    if [[ -f "$workspace/.ralph/stop-requested" ]] && [[ "$signal" != "DEFER" ]]; then
      # 0.12.5: distinguish "user asked, agent yielded with handoff" (graceful)
      # from "user asked, agent was mid-task and never wrote handoff" (forced).
      if _detect_graceful_yield "$workspace"; then
        log_activity "$workspace" "LOOP $loop_label END — 🤝 GRACEFUL YIELD (stop-requested honored; handoff written)"
      else
        log_activity "$workspace" "LOOP $loop_label END — 🛑 STOP REQUESTED (user; no handoff written this iteration)"
      fi
      log_progress "$workspace" "**Loop $loop_label ended** — 🛑 User requested stop"
      echo ""
      echo "🛑 Stop requested. Yielding after loop $loop_label."
      rm -f "$workspace/.ralph/stop-requested" 2>/dev/null || true
      # 0.12.5: signal to ralph-setup.sh's chain-evaluate guard that this
      # exit was user-initiated, NOT a clean "all tasks done" completion.
      # Without this breadcrumb, --evaluate would interpret rc=0 as "ready
      # for verification" and kick off the eval phase against the user's
      # explicit intent to halt.
      touch "$workspace/.ralph/.loop-stopped-by-user" 2>/dev/null || true
      return 0
    fi

    # Post-loop orphan-leak check. As of 0.11.3, this is a non-blocking
    # warning: the file list and detector facts are surfaced to the next
    # loop via .ralph/orphan-leak.md (written inside _check_orphan_leak),
    # and a post-mortem bundle is captured for forensic review. The active
    # signal is preserved — file-pattern heuristics on a clean-tree
    # end-of-loop no longer override ROTATE / NATURAL_END / etc. Prior
    # versions escalated to GUTTER, but the false-positive rate on the
    # spec-driven workflow (new module + paired spec, both committed in
    # the same loop) made that net-negative. Gutter triggers are reserved
    # for actual progress pathologies (heartbeat timeout, gate-fail streak).
    if ! _check_orphan_leak "$workspace"; then
      _write_postmortem "$workspace" "orphan-leak"
    fi

    local task_status
    task_status=$(check_task_complete "$workspace")

    # Compute post-loop task counts for the LOOP END line
    local post_counts post_done post_total task_delta task_suffix
    post_counts=$(count_criteria "$workspace")
    post_done=${post_counts%%:*}
    post_total=${post_counts##*:}
    task_delta=$((post_done - pre_done))
    task_suffix=""
    if [[ "$post_total" -gt 0 ]]; then
      task_suffix=" (Tasks: $post_done/$post_total complete"
      if [[ "$task_delta" -gt 0 ]]; then
        task_suffix="$task_suffix, +$task_delta this loop"
      fi
      task_suffix="$task_suffix)"
    fi

    if [[ "$task_status" == "COMPLETE" ]]; then
      # 0.3.3 Completion Bar guard: refuse to exit the loop with a red gate,
      # even if every checkbox is [x]. Forces the agent to fix verification
      # failures rather than marking around them. 0.6.4 extended this to
      # also reject a green-but-spoofed gate (cheaper command relabeled
      # as `final`) — see _complete_allowed.
      if ! _complete_allowed "$workspace"; then
        log_activity "$workspace" "🛑 COMPLETE BLOCKED — all tasks checked but $_COMPLETE_BLOCK_REASON. Agent must satisfy the bar (or escalate via <ralph>GUTTER</ralph>) before the loop can exit.$task_suffix"
        log_progress "$workspace" "**Loop $loop_label ended** — 🛑 COMPLETE BLOCKED ($_COMPLETE_BLOCK_REASON)"
        echo "🛑 Checkboxes all [x] but $_COMPLETE_BLOCK_REASON — not honouring COMPLETE. Continuing..."
        if _complete_block_escalates "$_COMPLETE_BLOCK_REASON"; then
          _fail_unsatisfiable_completion "$workspace" "$task_suffix"
          return 1
        fi
        # Reset stall/zero-progress counters — a red-gate block is not an
        # API hiccup, and work may have progressed this loop.
        stall_count=0
        DEFER_COUNT=0
        # zero_progress_count deliberately unchanged; repeated blocked
        # loops with zero forward motion should still trip the
        # natural-end stall detection below.
        loop_n=$((loop_n + 1))
        retry=0
        sleep 2
        continue
      fi

      log_activity "$workspace" "LOOP $loop_label END — ✅ COMPLETE$task_suffix"
      log_progress "$workspace" "**Loop $loop_label ended** — ✅ TASK COMPLETE"
      echo ""
      echo "═══════════════════════════════════════════════════════════════════"
      echo "🎉 RALPH COMPLETE! All criteria satisfied."
      echo "═══════════════════════════════════════════════════════════════════"
      echo ""
      echo "Completed in $loop_n loop(s)."

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
          # does not override a red (or spoofed) final gate.
          if ! _complete_allowed "$workspace"; then
            log_activity "$workspace" "🛑 COMPLETE BLOCKED — agent signaled COMPLETE but $_COMPLETE_BLOCK_REASON.$task_suffix"
            log_progress "$workspace" "**Loop $loop_label ended** — 🛑 COMPLETE BLOCKED (agent signaled; $_COMPLETE_BLOCK_REASON)"
            echo "🛑 Agent signaled COMPLETE but $_COMPLETE_BLOCK_REASON — not honouring. Continuing..."
            if _complete_block_escalates "$_COMPLETE_BLOCK_REASON"; then
              _fail_unsatisfiable_completion "$workspace" "$task_suffix"
              return 1
            fi
            stall_count=0
            DEFER_COUNT=0
            loop_n=$((loop_n + 1))
            retry=0
            session_id=""
            continue
          fi
          log_activity "$workspace" "LOOP $loop_label END — ✅ COMPLETE$task_suffix"
          log_progress "$workspace" "**Loop $loop_label ended** — ✅ TASK COMPLETE (agent signaled)"
          return 0
        else
          log_activity "$workspace" "LOOP $loop_label END — ⚠️ AGENT SIGNALED COMPLETE (criteria remain)$task_suffix"
          log_progress "$workspace" "**Loop $loop_label ended** — Agent signaled complete but criteria remain"
          echo "⚠️  Agent signaled completion but unchecked criteria remain. Continuing..."
          stall_count=0
          zero_progress_count=0
          DEFER_COUNT=0
          loop_n=$((loop_n + 1))
          retry=0
        fi
        ;;
      "ROTATE")
        log_activity "$workspace" "LOOP $loop_label END — 🔄 ROTATE (context-window pressure)$task_suffix"
        log_progress "$workspace" "**Loop $loop_label ended** — 🔄 Context rotation"
        echo "🔄 Rotating to fresh context..."
        stall_count=0
        zero_progress_count=0
        DEFER_COUNT=0
        loop_n=$((loop_n + 1))
        retry=0
        session_id=""
        ;;
      "TURN_END")
        # 0.10.0: Mechanical turn-end. Emitted on consecutive gate
        # failures (threshold: RALPH_GATE_FAIL_STREAK_THRESHOLD, default 5).
        local _failing_label _failing_log
        _failing_label=$(cat "$workspace/.ralph/gates/last-failed-label" 2>/dev/null) || _failing_label=""
        _failing_log=$(cat "$workspace/.ralph/gates/last-failed-log" 2>/dev/null) || _failing_log=""
        log_activity "$workspace" "LOOP $loop_label END — 🛑 TURN_END (gate-fail streak on '${_failing_label:-unknown}')$task_suffix"
        if [[ -n "$_failing_label" ]]; then
          local _handoff_template
          _handoff_template="$(dirname "${BASH_SOURCE[0]}")/../shared-references/templates/handoff-after-gate-fail.md"
          if [[ -f "$_handoff_template" ]]; then
            sed -e "s|{{FAILING_LABEL}}|$_failing_label|g" \
              -e "s|{{CONSECUTIVE_FAILURES}}|5|g" \
              "$_handoff_template" >"$workspace/.ralph/handoff.md"
          fi
          # Failure context flows via the inlined handoff block —
          # stream-parser keeps `## Last gate state` current from
          # gate-run.sh's summary file.
          # (0.13.1: _auto_enrich_handoff runs at the loop-end chokepoint
          # below — no need to call it per signal branch.)
        fi
        log_progress "$workspace" "**Loop $loop_label ended** — 🛑 TURN_END"
        echo "🛑 Turn ended — rotating to fresh context..."
        stall_count=0
        zero_progress_count=0
        DEFER_COUNT=0
        loop_n=$((loop_n + 1))
        retry=0
        session_id=""
        ;;
      "GUTTER")
        log_activity "$workspace" "LOOP $loop_label END — 🚨 GUTTER$task_suffix"
        log_progress "$workspace" "**Loop $loop_label ended** — 🚨 GUTTER"
        echo "🚨 Gutter detected. Check .ralph/errors.log for details."
        _write_postmortem "$workspace" "gutter"
        return 1
        ;;
      "DEFER")
        # DEFER = API/network transient error (rate limit, 429, etc.).
        # Kept lenient (threshold 10) because rate limits can take minutes to clear.
        # Does NOT increment zero_progress_count — that's reserved for the agent
        # genuinely doing nothing useful, not for API hiccups.
        log_activity "$workspace" "LOOP $loop_label END — ⏸️ DEFERRED$task_suffix"
        log_progress "$workspace" "**Loop $loop_label ended** — ⏸️ DEFERRED"
        DEFER_COUNT=$((DEFER_COUNT + 1))
        stall_count=$((stall_count + 1))
        # 0.3.7: bump the per-loop retry counter. Loop number stays the
        # same (DEFER means "retry this loop"), but the retry suffix
        # surfaces progress in activity.log/progress.md.
        retry=$((retry + 1))
        if [[ $stall_count -ge 10 ]]; then
          log_activity "$workspace" "RALPH STOP — 🚨 STALL: $stall_count consecutive empty/deferred loops"
          log_progress "$workspace" "**Ralph stopped** — 🚨 STALL: $stall_count consecutive empty/deferred loops, likely rate limited"
          echo "🚨 Stall detected: $stall_count consecutive loops with no progress (likely rate limited)."
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
        # Natural end (no signal). The agent ended its turn without emitting
        # a control signal — typically after a commit, sometimes after
        # exhausting a sub-task it considered "done."
        #
        # 0.6.3: this is the case the framing prompt is supposed to make
        # rare. A well-flowing ralph loop completes a whole spec in ONE
        # loop, never returning to this branch. Each occurrence here is the
        # agent "bailing politely" — costing a process-spawn cold start
        # (~10-30k tokens of re-read framing + handoff + tasks + plan)
        # without any necessary boundary. Tracked via natural_end_count
        # so operators can grep activity.log for the bail-out rate per spec
        # and see whether the framing prompt's flow framing is working.
        natural_end_count=$((natural_end_count + 1))
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
            log_activity "$workspace" "RALPH STOP — 🚨 STALL: $zero_progress_count consecutive natural-end loops with zero task progress"
            log_progress "$workspace" "**Ralph stopped** — 🚨 STALL: $zero_progress_count consecutive natural-end loops with zero task progress"
            echo "🚨 Stall detected: $zero_progress_count consecutive loops completed zero tasks and exited naturally."
            echo "   The agent is silently bailing out — check .ralph/errors.log and .ralph/progress.md for why."
            _write_postmortem "$workspace" "stall-natural"
            return 1
          fi
          # 0.12.5: a natural-end that follows a context-warning IS a
          # graceful yield — agent honored the breadcrumb instead of
          # blowing through to forced rotation. Distinguish in the log
          # so operators can grep `🤝 GRACEFUL YIELD` to count
          # well-behaved boundaries vs `🛌 NATURAL END` bailouts.
          if [[ -f "$workspace/.ralph/context-warning-active" ]] && _detect_graceful_yield "$workspace"; then
            log_activity "$workspace" "LOOP $loop_label END — 🤝 GRACEFUL YIELD (context-warning honored; handoff written; $remaining_count remaining)$task_suffix"
            log_progress "$workspace" "**Loop $loop_label ended** — 🤝 Graceful yield ($remaining_count remaining)"
            echo "🤝 Agent honored context warning and yielded with handoff. Rotating to fresh context ($remaining_count remaining)..."
          else
            log_activity "$workspace" "LOOP $loop_label END — 🛌 NATURAL END (agent ended turn; $remaining_count remaining; bail #$natural_end_count this run)$task_suffix"
            log_progress "$workspace" "**Loop $loop_label ended** — 🛌 Agent ended turn naturally ($remaining_count remaining)"
            echo "🛌 Agent ended its turn but $remaining_count criteria remaining. Starting another loop (cold start, ~10-30k tokens)..."
          fi
        else
          log_activity "$workspace" "LOOP $loop_label END — 🛌 NATURAL END (no checkbox tracking; bail #$natural_end_count this run)$task_suffix"
          log_progress "$workspace" "**Loop $loop_label ended** — 🛌 Agent ended turn naturally (no checkbox tracking)"
          stall_count=0
          zero_progress_count=0
          DEFER_COUNT=0
        fi
        loop_n=$((loop_n + 1))
        retry=0
        ;;
    esac

    # 0.13.1: single loop-end chokepoint for handoff auto-enrichment.
    # Every loop boundary that hands off to another iteration refreshes
    # "Last commit / Last task done / Next unchecked" so the next loop's
    # framing inlines accurate orientation. Skipped on DEFER (same loop
    # retries with unchanged state) and after terminal branches that
    # already `return`ed (COMPLETE, GUTTER, stop-requested).
    if [[ "$signal" != "DEFER" ]]; then
      _auto_enrich_handoff "$workspace" 2>/dev/null || true
    fi

    # 0.14.3: this iteration did NOT end in a COMPLETE BLOCKED (those paths
    # `continue` above and never reach here), so the unsatisfiable-bar streak
    # is broken — clear it so an unrelated future block starts a fresh count.
    _COMPLETE_BLOCK_COUNT=0
    _LAST_COMPLETE_BLOCK_REASON=""

    sleep 2
  done

  local final_counts final_done final_total
  final_counts=$(count_criteria "$workspace")
  final_done=${final_counts%%:*}
  final_total=${final_counts##*:}
  if [[ "$final_total" -gt 0 ]]; then
    log_activity "$workspace" "RALPH STOP — ⚠️ Max loops ($MAX_LOOPS) reached (Tasks: $final_done/$final_total complete; bails: $natural_end_count)"
  else
    log_activity "$workspace" "RALPH STOP — ⚠️ Max loops ($MAX_LOOPS) reached"
  fi
  log_progress "$workspace" "**Ralph stopped** — ⚠️ Max loops ($MAX_LOOPS) reached"
  echo "⚠️  Max loops ($MAX_LOOPS) reached. Check progress manually."
  _write_postmortem "$workspace" "max-loops"
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
