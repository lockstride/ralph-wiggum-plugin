#!/bin/bash
# Ralph Wiggum: Iteration status snapshot
#
# Prints a one-screen summary of the current Ralph loop's state for an
# operator who is checking in. Designed to answer the question "what is
# the loop actually doing right now?" without scrolling .ralph/activity.log
# by hand.
#
# Usage:
#   ralph-status.sh                    # uses current working directory as workspace
#   ralph-status.sh /path/to/worktree  # explicit workspace
#
# All output is plain text on stdout. Exit code is always 0 unless the
# given workspace does not exist.

set -euo pipefail

workspace="${1:-$PWD}"
workspace="$(cd "$workspace" 2>/dev/null && pwd)" || {
  echo "ralph-status: workspace not found: $1" >&2
  exit 64
}

ralph_dir="$workspace/.ralph"
activity_log="$ralph_dir/activity.log"
gates_dir="$ralph_dir/gates"
task_file_path="$ralph_dir/task-file-path"
handoff="$ralph_dir/handoff.md"

if [[ ! -d "$ralph_dir" ]]; then
  echo "ralph-status: no .ralph/ directory at $workspace"
  echo "(this worktree has not been initialized for ralph)"
  echo ""
  echo "Tip: pass a fragment to target a different worktree, e.g."
  echo "  ralph-status 172552    # resolves to worktree path containing '172552'"
  exit 0
fi

# -----------------------------------------------------------------------------
# Header
# -----------------------------------------------------------------------------

printf '═══════════════════════════════════════════════════════════════════\n'
printf '🐛 Ralph status — %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf '   workspace: %s\n' "$workspace"
printf '═══════════════════════════════════════════════════════════════════\n'

# -----------------------------------------------------------------------------
# Process state
# -----------------------------------------------------------------------------

if pgrep -f "ralph-setup.sh.*$workspace" >/dev/null 2>&1 ||
  pgrep -f "stream-parser.sh $workspace" >/dev/null 2>&1; then
  printf '\n● driver: RUNNING\n'
  # shellcheck disable=SC2009
  # ps + grep is intentional here: we need elapsed time + the workspace
  # path argument, neither of which pgrep -a returns in a single call.
  ps -ax -o pid,etime,command 2>/dev/null |
    grep -E "ralph-setup|stream-parser" |
    grep "$workspace" |
    grep -v grep |
    head -3 |
    awk '{printf "    pid=%-7s elapsed=%-12s %s\n", $1, $2, $3}'
else
  printf '\n○ driver: not running\n'
fi

# -----------------------------------------------------------------------------
# Iteration counter, task progress
# -----------------------------------------------------------------------------

iteration=0
[[ -f "$ralph_dir/.iteration" ]] && iteration=$(cat "$ralph_dir/.iteration")
printf '\n● iteration: %s\n' "$iteration"

if [[ -f "$task_file_path" ]]; then
  task_file=$(cat "$task_file_path")
  if [[ -f "$task_file" ]]; then
    total=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x| )\]' "$task_file" 2>/dev/null || echo 0)
    done_count=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]' "$task_file" 2>/dev/null || echo 0)
    remaining=$((total - done_count))
    printf '● tasks:     %s / %s complete (%s remaining)\n' "$done_count" "$total" "$remaining"

    next_task=$(grep -nE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[ \]' "$task_file" 2>/dev/null | head -1 || true)
    if [[ -n "$next_task" ]]; then
      printf '● next:      %s\n' "$(echo "$next_task" | sed 's/^[0-9]*://' | sed 's/^[[:space:]]*[-*][[:space:]]*\[ \][[:space:]]*//' | cut -c1-100)"
    fi
  fi
fi

# -----------------------------------------------------------------------------
# Gate state — count runs in current activity.log session
# -----------------------------------------------------------------------------

if [[ -f "$activity_log" ]]; then
  printf '\n● gates this session:\n'
  # Find the most recent "Session N started" line and count GATE events after it
  session_start_line=$(grep -n "Session .* started" "$activity_log" 2>/dev/null | tail -1 | cut -d: -f1 || echo 1)
  if [[ -z "$session_start_line" ]]; then
    session_start_line=1
  fi
  tail -n +"$session_start_line" "$activity_log" 2>/dev/null |
    grep -E "🧪 GATE (start|end)" |
    tail -10 |
    sed 's/^/    /'

  pass=$(tail -n +"$session_start_line" "$activity_log" 2>/dev/null | grep -cE "GATE end .*exit=0" || true)
  fail=$(tail -n +"$session_start_line" "$activity_log" 2>/dev/null | grep -cE "GATE end .*exit=[1-9]" || true)
  printf '    summary: %s pass / %s fail (this session)\n' "$pass" "$fail"
fi

# -----------------------------------------------------------------------------
# Most recent persisted gate logs
# -----------------------------------------------------------------------------

if [[ -d "$gates_dir" ]]; then
  printf '\n● persisted gate logs:\n'
  # Collect non-latest log files, sorted by mtime ascending, and show the
  # last five. Avoid `ls | grep` (SC2010) by using `find` + `sort`.
  # macOS ships bash 3.2 which lacks `mapfile`; use a portable read loop.
  _gate_logs=()
  while IFS= read -r _line; do
    _gate_logs+=("$_line")
  done < <(
    find "$gates_dir" -maxdepth 1 -type f -name '*.log' \
      ! -name '*-latest.log' -print0 2>/dev/null |
      xargs -0 -n1 stat -f '%m %N' 2>/dev/null |
      sort -n |
      tail -5 |
      cut -d' ' -f2-
  )
  for f in "${_gate_logs[@]}"; do
    [[ -n "$f" ]] || continue
    size=$(wc -c <"$f" 2>/dev/null | tr -d ' ')
    printf '    %s (%s bytes)\n' "$(basename "$f")" "$size"
  done
fi

# -----------------------------------------------------------------------------
# Token usage (most recent reading from activity.log)
# -----------------------------------------------------------------------------

if [[ -f "$activity_log" ]]; then
  last_tokens=$(grep "TOKENS:" "$activity_log" 2>/dev/null | tail -1 | sed 's/.*TOKENS: //' || true)
  if [[ -n "$last_tokens" ]]; then
    printf '\n● tokens:    %s\n' "$last_tokens"
  fi
fi

# -----------------------------------------------------------------------------
# Git state
# -----------------------------------------------------------------------------

if git -C "$workspace" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf '\n● git:\n'
  branch=$(git -C "$workspace" branch --show-current 2>/dev/null || echo "(detached)")
  tip=$(git -C "$workspace" log --oneline -1 2>/dev/null || true)
  staged=$(git -C "$workspace" diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
  unstaged=$(git -C "$workspace" diff --numstat 2>/dev/null | wc -l | tr -d ' ')
  untracked=$(git -C "$workspace" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
  printf '    branch:    %s\n' "$branch"
  printf '    tip:       %s\n' "$tip"
  printf '    staged:    %s files\n' "$staged"
  printf '    unstaged:  %s files\n' "$unstaged"
  printf '    untracked: %s files\n' "$untracked"
fi

# -----------------------------------------------------------------------------
# Most recent activity (last 8 lines for a glance)
# -----------------------------------------------------------------------------

if [[ -f "$activity_log" ]]; then
  printf '\n● recent activity (last 8 lines):\n'
  tail -8 "$activity_log" | sed 's/^/    /'
fi

# -----------------------------------------------------------------------------
# Handoff note from prior iteration (if present)
# -----------------------------------------------------------------------------

if [[ -f "$handoff" ]]; then
  printf '\n● handoff.md (from prior iteration):\n'
  sed 's/^/    /' "$handoff"
fi

printf '\n═══════════════════════════════════════════════════════════════════\n'
