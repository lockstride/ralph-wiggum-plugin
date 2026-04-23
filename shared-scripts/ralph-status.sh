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
#
# 0.4.1 layout: sections separated by uppercase labels + blank lines; iteration
# derived from activity.log (the loop's internal counter is not persisted to
# .ralph/.iteration); gate history collapsed to start+end pairs; recent
# activity filtered to meaningful events (commits, gates, iteration
# transitions) rather than every Read/TOKENS line.

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
# 0.5.1: ralph-evaluate.sh drops this breadcrumb so status can visibly
# distinguish an acceptance-evaluation run from a regular implementation run.
eval_ground_truth_path="$ralph_dir/eval-ground-truth"

if [[ ! -d "$ralph_dir" ]]; then
  echo "ralph-status: no .ralph/ directory at $workspace"
  echo "(this worktree has not been initialized for ralph)"
  echo ""
  echo "Tip: pass a fragment to target a different worktree, e.g."
  echo "  ralph-status 172552    # resolves to worktree path containing '172552'"
  exit 0
fi

# Eval-mode detection — truthy when ralph-evaluate.sh is (or was) driving
# this workspace. Used to decorate the header and inject a mode row into
# the STATUS section so operators can tell at a glance which loop they're
# looking at.
_eval_mode=false
_eval_ground_truth=""
if [[ -f "$eval_ground_truth_path" ]]; then
  _eval_mode=true
  _eval_ground_truth=$(cat "$eval_ground_truth_path")
fi

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# Find the byte offset of the most recent ITERATION START line. Everything
# after that line is "this session." Returns "" if no ITERATION START found,
# which callers interpret as "whole log."
_find_session_start() {
  if [[ ! -f "$activity_log" ]]; then
    echo ""
    return
  fi
  # awk handles the file in one pass and is faster than grep + cut. We want
  # the line number of the most recent match; awk scans forward then prints
  # at END so no post-processing is needed.
  awk '/ITERATION [0-9.]+ START/ { line=NR } END { if (line) print line }' \
    "$activity_log"
}

# Emit a section header with consistent spacing.
_section() {
  printf '\n%s\n' "$1"
}

# -----------------------------------------------------------------------------
# Header
# -----------------------------------------------------------------------------

printf '═══════════════════════════════════════════════════════════════════\n'
if [[ "$_eval_mode" == "true" ]]; then
  printf '🐛 Ralph status — %s   [ACCEPTANCE EVAL]\n' "$(date '+%Y-%m-%d %H:%M:%S')"
else
  printf '🐛 Ralph status — %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
fi
printf '   workspace: %s\n' "$workspace"
printf '═══════════════════════════════════════════════════════════════════\n'

# -----------------------------------------------------------------------------
# STATUS — the headline a glance should give: running? iteration? progress?
# -----------------------------------------------------------------------------

_section 'STATUS'

if [[ "$_eval_mode" == "true" ]]; then
  printf '  mode:      acceptance eval (ground truth: %s)\n' "$_eval_ground_truth"
fi

# Driver process state
if pgrep -f "ralph-setup.sh.*$workspace" >/dev/null 2>&1 ||
  pgrep -f "stream-parser.sh $workspace" >/dev/null 2>&1; then
  # Grab the ralph-setup or stream-parser PID + elapsed time. Using ps + grep
  # (SC2009 accepted) because pgrep doesn't emit elapsed time.
  _driver_row=$(
    # shellcheck disable=SC2009
    ps -ax -o pid=,etime=,command= 2>/dev/null |
      grep -E "ralph-setup|stream-parser" |
      grep "$workspace" |
      grep -v grep |
      head -1 |
      awk '{printf "pid=%s elapsed=%s", $1, $2}'
  )
  printf '  driver:    ● RUNNING  %s\n' "${_driver_row:-(pid lookup failed)}"
else
  printf '  driver:    ○ not running\n'
fi

# Iteration + retry — read from activity.log since the loop's internal
# counter isn't persisted (known gap, captured in 0.4.1 TODO).
if [[ -f "$activity_log" ]]; then
  _last_iter=$(awk '/ITERATION [0-9.]+ START/ { m=$0 } END { if (m) print m }' "$activity_log" |
    sed -E 's/.*ITERATION ([0-9.]+) START.*/\1/')
  if [[ -n "$_last_iter" ]]; then
    printf '  iteration: %s\n' "$_last_iter"
  else
    printf '  iteration: (none started yet)\n'
  fi
fi

# Task progress + next unchecked task
if [[ -f "$task_file_path" ]]; then
  task_file=$(cat "$task_file_path")
  if [[ -f "$task_file" ]]; then
    total=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x| )\]' "$task_file" 2>/dev/null || echo 0)
    done_count=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]' "$task_file" 2>/dev/null || echo 0)
    remaining=$((total - done_count))
    printf '  tasks:     %s / %s complete (%s remaining)\n' "$done_count" "$total" "$remaining"

    next_task=$(grep -nE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[ \]' "$task_file" 2>/dev/null | head -1 || true)
    if [[ -n "$next_task" ]]; then
      _next_text=$(echo "$next_task" |
        sed 's/^[0-9]*://' |
        sed 's/^[[:space:]]*[-*][[:space:]]*\[ \][[:space:]]*//' |
        cut -c1-90)
      printf '  next:      %s\n' "$_next_text"
    fi
  fi
fi

# Token usage
if [[ -f "$activity_log" ]]; then
  _last_tokens=$(awk '/TOKENS:/ { m=$0 } END { if (m) print m }' "$activity_log" |
    sed -E 's/.*TOKENS: ([0-9]+) \/ ([0-9]+) \(([0-9]+%)\).*/\1 \/ \2 (\3)/')
  if [[ -n "$_last_tokens" ]]; then
    printf '  tokens:    %s\n' "$_last_tokens"
  fi
fi

# -----------------------------------------------------------------------------
# GATES — collapse start+end pairs into one pass/fail line per run,
#         session-scoped so the count reflects THIS iteration only.
# -----------------------------------------------------------------------------

session_start_line=$(_find_session_start)

if [[ -f "$activity_log" ]]; then
  _section 'GATES (this session)'
  _gate_slice=$(
    if [[ -n "$session_start_line" ]]; then
      tail -n +"$session_start_line" "$activity_log"
    else
      cat "$activity_log"
    fi
  )

  # Collapse start + end pairs into a single line. The stream-parser always
  # emits `🧪 GATE start label=… cmd=…` immediately before `🧪 GATE end
  # label=… exit=N duration=Ns log=…` for the matching run, so a simple
  # awk state machine pairs them.
  _gate_pairs=$(
    echo "$_gate_slice" |
      awk '
        /🧪 GATE start/ {
          start_ts = substr($0, 2, 8)
          match($0, /label=[^ ]+/); start_label = substr($0, RSTART+6, RLENGTH-6)
          next
        }
        /🧪 GATE end/ {
          end_ts = substr($0, 2, 8)
          match($0, /label=[^ ]+/); end_label = substr($0, RSTART+6, RLENGTH-6)
          match($0, /exit=[0-9]+/);  exit_code = substr($0, RSTART+5, RLENGTH-5)
          match($0, /duration=[0-9]+s/); duration = substr($0, RSTART+9, RLENGTH-10)
          sym = (exit_code == 0) ? "✔" : "✘"
          # Orphan end without a matching start falls back to "?" for start.
          if (!start_ts) { start_ts = "?" }
          printf "  %s %-6s %ss  %s → %s  exit=%s\n", sym, end_label, duration, start_ts, end_ts, exit_code
          start_ts = ""; start_label = ""
        }
      '
  )

  if [[ -n "$_gate_pairs" ]]; then
    # Show the last 5 pairs so the banner doesn't dominate the screen.
    echo "$_gate_pairs" | tail -5
    _total=$(echo "$_gate_pairs" | grep -c .)
    _pass=$(echo "$_gate_pairs" | grep -c '^[[:space:]]*✔' || true)
    _fail=$(echo "$_gate_pairs" | grep -c '^[[:space:]]*✘' || true)
    printf '  summary:   %s pass / %s fail (%s total this session)\n' \
      "$_pass" "$_fail" "$_total"
  else
    # No gate events yet in this session.
    if [[ -n "$session_start_line" ]]; then
      echo "  (no gates run yet in this iteration)"
    else
      echo "  (no ITERATION START marker found; session scoping unavailable)"
    fi
  fi
fi

# -----------------------------------------------------------------------------
# GIT — branch, tip, and dirty state (collapsed to "clean" when nothing dirty)
# -----------------------------------------------------------------------------

if git -C "$workspace" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  _section 'GIT'
  branch=$(git -C "$workspace" branch --show-current 2>/dev/null || echo "(detached)")
  tip=$(git -C "$workspace" log --oneline -1 2>/dev/null || true)
  staged=$(git -C "$workspace" diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
  unstaged=$(git -C "$workspace" diff --numstat 2>/dev/null | wc -l | tr -d ' ')
  untracked=$(git -C "$workspace" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
  printf '  branch:    %s\n' "$branch"
  printf '  tip:       %s\n' "${tip:-(no commits)}"
  if [[ "$staged" -eq 0 && "$unstaged" -eq 0 && "$untracked" -eq 0 ]]; then
    printf '  state:     clean\n'
  else
    printf '  state:     %s staged, %s unstaged, %s untracked\n' \
      "$staged" "$unstaged" "$untracked"
  fi
fi

# -----------------------------------------------------------------------------
# RECENT — meaningful events only (commits, gate starts/ends, iteration
#          transitions, parser signals). Skips TOKENS/READ noise that
#          dominates activity.log and makes state changes hard to spot.
# -----------------------------------------------------------------------------

if [[ -f "$activity_log" ]]; then
  _section 'RECENT (meaningful events, last 8)'
  # Pattern list kept narrow on purpose — every pattern here is either a
  # state transition or a decision point. Expand only if it would answer
  # "what is the loop doing right now?" without re-reading the raw log.
  _recent=$(grep -E 'COMMIT|🧪 GATE|ITERATION [0-9.]+ (START|END)|PARSER EXIT|HEARTBEAT TIMEOUT|RECOVER_ATTEMPT|GUTTER|DEFERRED|ORPHAN|PIPELINE DRAIN|STOP_REQUESTED|ROTATE' \
    "$activity_log" 2>/dev/null |
    grep -vE 'test -f .*stop-requested|cat .*handoff\.md|READ .*handoff\.md' |
    tail -8 || true)
  if [[ -n "$_recent" ]]; then
    # shellcheck disable=SC2001 # sed needed: parameter expansion ${_recent//^/  }
    # can't anchor to line-start in bash 3.2 without a loop; sed is clearer here.
    echo "$_recent" | sed 's/^/  /'
  else
    echo "  (no meaningful events yet)"
  fi
fi

# -----------------------------------------------------------------------------
# HANDOFF — navigation note the next iteration will read
# -----------------------------------------------------------------------------

if [[ -f "$handoff" ]]; then
  _section 'HANDOFF (navigation note from prior iteration)'
  sed 's/^/  /' "$handoff"
fi

# -----------------------------------------------------------------------------
# GATE LOGS — compact listing (only if there are persisted logs to surface)
# -----------------------------------------------------------------------------

if [[ -d "$gates_dir" ]]; then
  _gate_log_count=$(find "$gates_dir" -maxdepth 1 -type f -name '*.log' ! -name '*-latest.log' 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$_gate_log_count" -gt 0 ]]; then
    _section "GATE LOGS (last 5 of $_gate_log_count persisted)"
    # macOS bash 3.2 — portable read loop, no mapfile.
    while IFS= read -r _f; do
      [[ -n "$_f" ]] || continue
      _size=$(wc -c <"$_f" 2>/dev/null | tr -d ' ')
      # stat -f '%m' gives mtime on macOS; use ls -T for portable formatted
      # timestamp if we need it later. For now size + basename is enough
      # context for an operator to know which one to Read.
      printf '  %s (%s bytes)\n' "$(basename "$_f")" "$_size"
    done < <(
      find "$gates_dir" -maxdepth 1 -type f -name '*.log' \
        ! -name '*-latest.log' -print0 2>/dev/null |
        xargs -0 -n1 stat -f '%m %N' 2>/dev/null |
        sort -n |
        tail -5 |
        cut -d' ' -f2-
    )
  fi
fi

printf '\n═══════════════════════════════════════════════════════════════════\n'
