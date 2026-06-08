#!/bin/bash
# Ralph Wiggum: Loop status snapshot
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
# 0.4.1 layout: sections separated by uppercase labels + blank lines; loop
# derived from activity.log (the driver's internal counter is not persisted
# to .ralph/.loop); gate history collapsed to start+end pairs; recent
# activity filtered to meaningful events (commits, gates, loop transitions)
# rather than every Read/TOKENS line.

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

# 0.13.4: parse the acceptance report once so the PROGRESS and ACCEPTANCE
# sections can surface eval-specific signal (verdict, status, last mode,
# gap counts, history). All fields are best-effort — a missing / malformed
# report leaves the variables empty and the section prints "(not seeded)".
_eval_status=""        # CLEAN / UNVERIFIED / (placeholder text from template)
_eval_verdict_glyph="" # ✅ / ⏳
_eval_verdict_label="" # verified / pending
_eval_last_mode=""
_eval_last_loop=""
_eval_gaps_open=0
_eval_gaps_blocked=0
_eval_gaps_resolved=0
_eval_history_count=0
_eval_history_last=""

if [[ "$_eval_mode" == "true" ]]; then
  _report="$ralph_dir/acceptance-report.md"
  if [[ -f "$_report" ]]; then
    # Top-level checkbox decides the verdict glyph. The line is created by
    # the report template and never moves, so a simple grep is robust.
    if grep -qE '^- \[x\] All acceptance criteria met and verified' "$_report"; then
      _eval_verdict_glyph="✅"
      _eval_verdict_label="verified"
    else
      _eval_verdict_glyph="⏳"
      _eval_verdict_label="pending"
    fi

    _eval_status=$(grep -m1 -E '^\*\*Status:\*\*' "$_report" | sed -E 's/^\*\*Status:\*\*[[:space:]]*//' | tr -d '\r' || true)
    _eval_last_mode=$(grep -m1 -E '^\*\*Last mode:\*\*' "$_report" | sed -E 's/^\*\*Last mode:\*\*[[:space:]]*//' | tr -d '\r' || true)
    _eval_last_loop=$(grep -m1 -E '^\*\*Last loop:\*\*' "$_report" | sed -E 's/^\*\*Last loop:\*\*[[:space:]]*//' | tr -d '\r' || true)

    # Gap counts: scan only the Gaps section (between `## Gaps` and the
    # next `## ` heading). Excludes the top-level "All acceptance criteria
    # met" checkbox, which lives above the Gaps section.
    _gaps_slice=$(awk '
      /^## Gaps[[:space:]]*$/ { in_g = 1; next }
      in_g && /^## / { in_g = 0 }
      in_g { print }
    ' "$_report")
    if [[ -n "$_gaps_slice" ]]; then
      _eval_gaps_resolved=$(echo "$_gaps_slice" | grep -cE '^- \[x\]' || true)
      _eval_gaps_blocked=$(echo "$_gaps_slice" | grep -cE '^- \[ \].*\(blocked:' || true)
      _eval_gaps_open=$(echo "$_gaps_slice" | grep -cE '^- \[ \]' || true)
      _eval_gaps_open=$((_eval_gaps_open - _eval_gaps_blocked))
      [[ "$_eval_gaps_open" -lt 0 ]] && _eval_gaps_open=0
    fi

    # History: count `loop N -` / `iter N -` lines and capture the most recent.
    _eval_history_count=$(grep -cE '^(loop|iter)[[:space:]]+[0-9]+[[:space:]]+-' "$_report" || true)
    if [[ "$_eval_history_count" -gt 0 ]]; then
      _eval_history_last=$(grep -E '^(loop|iter)[[:space:]]+[0-9]+[[:space:]]+-' "$_report" | tail -1)
    fi
  fi
fi

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# Find the byte offset of the most recent LOOP START line (or the
# pre-0.6.3 ITERATION START line, for backward compat with workspaces
# that still have older activity log entries). Everything after that
# line is "this session." Returns "" if no marker is found, which
# callers interpret as "whole log."
_find_session_start() {
  if [[ ! -f "$activity_log" ]]; then
    echo ""
    return
  fi
  # awk handles the file in one pass and is faster than grep + cut. We want
  # the line number of the most recent match; awk scans forward then prints
  # at END so no post-processing is needed.
  awk '/(LOOP|ITERATION) [0-9.]+ START/ { line=NR } END { if (line) print line }' \
    "$activity_log"
}

# Emit a section header with consistent spacing.
_section() {
  printf '\n%s\n' "$1"
}

# Strip "<lineno>:" prefix from grep -n and the leading "- [x] " / "- [ ] "
# checkbox marker. Returns just the task text.
_task_strip() {
  echo "$1" |
    sed 's/^[0-9]*://' |
    sed -E 's/^[[:space:]]*[-*][[:space:]]*\[(x| )\][[:space:]]*//'
}

# Pull the leading task ID (T001, T012a, etc.) out of the description so
# we can put it in the section header for an at-a-glance ID without
# scanning the body. Falls back to empty if the text doesn't start with
# the conventional Spec Kit T-pattern.
_task_id() {
  echo "$1" | grep -oE '^T[0-9]+[a-z]?' | head -1
}

# Print one labeled section: header + body. Body is wrapped to leave a
# right margin so text doesn't run all the way to the terminal edge.
# Wrap width = terminal_cols - right_margin - mb_safety, where the
# multibyte-safety buffer absorbs the BSD fold quirk (it counts UTF-8
# byte length, so lines with `→` / `—` chars run a few cols wider than
# the requested width). Continuation lines start at column 0, matching
# the body's first line — single-column flow, no indent alignment.
_print_task_section() {
  local label="$1"
  local text="$2"
  local id
  id=$(_task_id "$text")
  if [[ -n "$id" ]]; then
    _section "$label ($id)"
  else
    _section "$label"
  fi

  # stty fails when stdin isn't a TTY (subshell, pipe); the trailing
  # `|| true` keeps the script alive under set -o pipefail in that case.
  local term_cols=""
  term_cols=$(stty size 2>/dev/null | awk '{print $2}' || true)
  if [[ -z "$term_cols" ]] || [[ "$term_cols" -le 0 ]]; then
    term_cols=${COLUMNS:-100}
  fi

  local right_margin=10
  local mb_safety=5
  local wrap_at=$((term_cols - right_margin - mb_safety))

  if [[ $wrap_at -lt 30 ]]; then
    # Terminal too narrow to wrap helpfully — emit raw and let it soft-wrap.
    printf '%s\n' "$text"
  else
    printf '%s\n' "$text" | fold -s -w "$wrap_at"
  fi
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
# PROGRESS — at-a-glance task counts. The single most-asked question from
# operators glancing at status, surfaced above STATUS so it is visible
# without scrolling on small terminals. Falls through silently when no task
# file is configured (e.g. PROMPT.md mode without a checkbox-style file).
# -----------------------------------------------------------------------------

if [[ "$_eval_mode" == "true" ]]; then
  # In eval mode the "task file" is the acceptance report, which only
  # holds a single top-level checkbox. The TASKS line as printed in the
  # main loop ("1/1 complete, 0%") is misleading — verdict + gap counts
  # are the actually-meaningful summary.
  if [[ -n "$_eval_verdict_glyph" ]]; then
    if [[ "$_eval_verdict_label" == "verified" ]]; then
      printf '\n📋 ACCEPTANCE: %s %s\n' "$_eval_verdict_glyph" "$_eval_verdict_label"
    else
      _summary_extras=""
      if [[ "$_eval_gaps_open" -gt 0 || "$_eval_gaps_blocked" -gt 0 ]]; then
        _summary_extras=" ($_eval_gaps_open open"
        [[ "$_eval_gaps_blocked" -gt 0 ]] && _summary_extras="$_summary_extras, $_eval_gaps_blocked blocked"
        _summary_extras="$_summary_extras)"
      fi
      printf '\n📋 ACCEPTANCE: %s %s%s\n' "$_eval_verdict_glyph" "$_eval_verdict_label" "$_summary_extras"
    fi
  else
    printf '\n📋 ACCEPTANCE: (report not seeded yet)\n'
  fi
elif [[ -f "$task_file_path" ]]; then
  _task_file=$(cat "$task_file_path")
  if [[ -f "$_task_file" ]]; then
    _total=$(
      grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x| )\]' "$_task_file" 2>/dev/null
      true
    )
    _done=$(
      grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]' "$_task_file" 2>/dev/null
      true
    )
    if [[ "$_total" -gt 0 ]]; then
      _remaining=$((_total - _done))
      _pct=$((_remaining * 100 / _total))
      printf '\n📋 TASKS: %s / %s complete  (%s remaining, %s%%)\n' \
        "$_done" "$_total" "$_remaining" "$_pct"
    fi
  fi
fi

# -----------------------------------------------------------------------------
# STATUS — the headline a glance should give: running? loop? progress?
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

# Loop number + retry — read from activity.log since the driver's
# internal counter isn't persisted (known gap, captured in 0.4.1 TODO).
# Matches both LOOP (0.6.3+) and pre-0.6.3 ITERATION markers.
if [[ -f "$activity_log" ]]; then
  _last_loop=$(awk '/(LOOP|ITERATION) [0-9.]+ START/ { m=$0 } END { if (m) print m }' "$activity_log" |
    sed -E 's/.*(LOOP|ITERATION) ([0-9.]+) START.*/\2/')
  if [[ -n "$_last_loop" ]]; then
    printf '  loop:      %s\n' "$_last_loop"
  else
    printf '  loop:      (none started yet)\n'
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

# Active signals (breadcrumb files)
_signals=""
[[ -f "$ralph_dir/stop-requested" ]] && _signals="stop-requested"
if [[ -f "$ralph_dir/context-warning-active" ]]; then
  [[ -n "$_signals" ]] && _signals="$_signals, "
  _signals="${_signals}context-warning-active"
fi
if [[ -n "$_signals" ]]; then
  printf '  signals:   ⚠️  %s\n' "$_signals"
fi

# -----------------------------------------------------------------------------
# PREVIOUS / CURRENT / NEXT — task triplet as separate labeled sections.
# 'current' is the task the agent is mid-flight on (agents flip [ ] →
# [x] only after committing, so the first unchecked task is in-flight).
# Sections are omitted when empty: no PREVIOUS before the first commit,
# no NEXT when current is the last task.
# -----------------------------------------------------------------------------

if [[ "$_eval_mode" == "true" ]]; then
  # 0.13.4: dedicated ACCEPTANCE section, since the generic PREVIOUS/
  # CURRENT/NEXT block reads the report's top-level checkbox as if it
  # were a task — uninformative for eval. The fields below come from
  # the parser block near the top of the script.
  _section 'ACCEPTANCE'
  if [[ -z "$_eval_status" || "$_eval_status" == '_(filled by orchestrator)_' ]]; then
    printf '  status:    (not yet run — orchestrator hasn'\''t set Status)\n'
  else
    printf '  status:    %s\n' "$_eval_status"
  fi

  if [[ -z "$_eval_last_mode" || "$_eval_last_mode" == '_(filled by orchestrator)_' ]]; then
    printf '  last mode: (none yet)\n'
  else
    if [[ -n "$_eval_last_loop" && "$_eval_last_loop" != '_(filled by orchestrator)_' ]]; then
      printf '  last mode: %s  (loop %s)\n' "$_eval_last_mode" "$_eval_last_loop"
    else
      printf '  last mode: %s\n' "$_eval_last_mode"
    fi
  fi

  printf '  gaps:      %s open, %s blocked, %s resolved\n' \
    "$_eval_gaps_open" "$_eval_gaps_blocked" "$_eval_gaps_resolved"

  if [[ "$_eval_history_count" -eq 0 ]]; then
    printf '  history:   (no loops recorded yet)\n'
  elif [[ "$_eval_history_count" -eq 1 ]]; then
    printf '  history:   1 entry — %s\n' "$(echo "$_eval_history_last" | cut -c1-100)"
  else
    printf '  history:   %s entries — last: %s\n' \
      "$_eval_history_count" "$(echo "$_eval_history_last" | cut -c1-100)"
  fi
elif [[ -f "$task_file_path" ]]; then
  task_file=$(cat "$task_file_path")
  if [[ -f "$task_file" ]]; then
    _prev_task=$(grep -nE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]' "$task_file" 2>/dev/null | tail -1 || true)
    _curr_task=$(grep -nE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[ \]' "$task_file" 2>/dev/null | head -1 || true)
    _next_task=$(grep -nE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[ \]' "$task_file" 2>/dev/null | sed -n '2p' || true)

    [[ -n "$_prev_task" ]] && _print_task_section PREVIOUS "$(_task_strip "$_prev_task")"
    [[ -n "$_curr_task" ]] && _print_task_section CURRENT "$(_task_strip "$_curr_task")"
    [[ -n "$_next_task" ]] && _print_task_section NEXT "$(_task_strip "$_next_task")"
  fi
fi

# -----------------------------------------------------------------------------
# GATES — collapse start+end pairs into one pass/fail line per run,
#         session-scoped so the count reflects THIS loop only.
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
      echo "  (no gates run yet in this loop)"
    else
      echo "  (no LOOP/ITERATION START marker found; session scoping unavailable)"
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
# RECENT — meaningful events only (commits, gate starts/ends, loop
#          transitions, parser signals). Skips TOKENS/READ noise that
#          dominates activity.log and makes state changes hard to spot.
# -----------------------------------------------------------------------------

if [[ -f "$activity_log" ]]; then
  _section 'RECENT (meaningful events, last 8)'
  # Pattern list kept narrow on purpose — every pattern here is either a
  # state transition or a decision point. Expand only if it would answer
  # "what is the loop doing right now?" without re-reading the raw log.
  _recent=$(grep -E 'COMMIT|🧪 GATE|(LOOP|ITERATION) [0-9.]+ (START|END)|PARSER EXIT|HEARTBEAT TIMEOUT|RECOVER_ATTEMPT|GUTTER|DEFERRED|ORPHAN|PIPELINE DRAIN|STOP_REQUESTED|ROTATE|RALPH STOP|🛌 NATURAL END' \
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
# HANDOFF — navigation note the next loop will read
# -----------------------------------------------------------------------------

if [[ -f "$handoff" ]]; then
  _section 'HANDOFF (navigation note from prior loop)'
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
