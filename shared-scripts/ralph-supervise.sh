#!/usr/bin/env bash
# Supervisor for a Ralph run.
#
# Wraps a single `ralph-setup.sh …` invocation (work loop, plus the chained
# acceptance-eval loop when --evaluate is used). On every terminal outcome it
# notifies the operator (macOS desktop notification + an activity.log
# breadcrumb the foreground `tail -f` shows), and for a
# *mechanically-recoverable* halt it auto-resumes the run ONCE — the fix for
# the run-140038 failure mode, where a rotation zombie guttered the loop and
# the run then sat dead for ~4h because nobody was watching.
#
# Resume is safe: init_ralph_dir only creates missing state files, plan
# checkboxes live in git, and re-running ralph-setup continues the remaining
# `[ ]` work (or, if the work loop already finished, re-enters the eval phase).
#
# The run itself is unchanged — this only observes its exit and decides
# notify / resume. It is deliberately conservative: it auto-resumes ONLY for an
# explicit allowlist of reason slugs (a genuine "stuck after investigation"
# gutter is not retried, since a fresh session would just re-gutter).
#
# 0.21.0: moved here from the consuming repos, where each carried its own
# committed copy resolved workspace-relative. That fork meant a fix reached
# only the repo it was made in, and — worse — a worktree branched before a fix
# ran the stale copy forever (observed 2026-08-01: two worktrees kept
# misreporting clean runs as operator-stopped hours after the bug was fixed on
# main). Living in the plugin, `ralph --update` fixes every consumer at once.
# It is agnostic to what the run is doing: no ticket, spec, or tracker
# knowledge, only the loop driver's own markers in .ralph/.
#
# Usage:
#   ralph-supervise.sh <workspace> <session> <base64-command>
#     <workspace>       worktree root (holds .ralph/)
#     <session>         tmux session name (notification context)
#     <base64-command>  the ralph-setup invocation, base64-encoded so the
#                       nested tmux/sh/bash quoting layers can't mangle it
#
# Config (env):
#   RALPH_SUPERVISE_MAX_RESUMES   default 1   — auto-resumes for a mechanical halt (0 = notify-only)
#   RALPH_SUPERVISE_RECOVERABLE   default "concurrent-writer" — reason slugs (space/comma) that auto-resume
#   RALPH_SUPERVISE_NOTIFY        default 1   — 0 disables desktop notifications
set -u

workspace="${1:?supervisor: workspace required}"
session="${2:?supervisor: session required}"
command_b64="${3:?supervisor: base64 command required}"

ralph_dir="$workspace/.ralph"
max_resumes="${RALPH_SUPERVISE_MAX_RESUMES:-1}"
recoverable="${RALPH_SUPERVISE_RECOVERABLE:-concurrent-writer}"
notify_enabled="${RALPH_SUPERVISE_NOTIFY:-1}"

# Portable base64 decode (GNU: -d, BSD/macOS: -D).
_b64_decode() {
  base64 -d 2>/dev/null || base64 -D 2>/dev/null
}

command_str="$(printf '%s' "$command_b64" | _b64_decode)"
if [[ -z "$command_str" ]]; then
  echo "supervisor: failed to decode command — aborting" >&2
  exit 64
fi

_ts() { date '+%H:%M:%S'; }

# A breadcrumb the operator's `tail -f .ralph/activity.log` surfaces live.
_breadcrumb() {
  [[ -d "$ralph_dir" ]] || return 0
  printf '[%s] 🔔 SUPERVISOR: %s\n' "$(_ts)" "$1" >>"$ralph_dir/activity.log" 2>/dev/null || true
}

# Desktop notification (macOS). Best-effort; never fails the run.
_notify() {
  local title="$1" msg="$2"
  [[ "$notify_enabled" == "1" ]] || return 0
  if command -v osascript >/dev/null 2>&1; then
    local t="${title//\\/\\\\}" m="${msg//\\/\\\\}"
    t="${t//\"/\\\"}"
    m="${m//\"/\\\"}"
    osascript -e "display notification \"$m\" with title \"$t\" sound name \"Glass\"" >/dev/null 2>&1 || true
  fi
  printf '\a' >&2 2>/dev/null || true
}

# Line count of activity.log, used to fence classification to the current run.
_log_lines() {
  wc -l <"$ralph_dir/activity.log" 2>/dev/null | tr -d '[:space:]' || echo 0
}

# The loop driver's own terminal markers, anchored to the shape log_activity
# writes: "[HH:MM:SS] " followed by the driver's message.
#
# Anchoring matters because activity.log also echoes agent-authored text —
# shell command source, file paths, gate `cmd=` strings — and that text can
# contain any substring, including these markers. A bare `grep "STOP REQUESTED"`
# matched a *probe command* the agent ran to check for a stop file
# (`ls .ralph/stop-requested … && echo "STOP REQUESTED"`), so a run that had
# finished cleanly was reported as operator-stopped (observed 2026-08-01).
# Likewise a bare `grep "GUTTER"` matched the COMPLETE-BLOCKED line's own
# "escalate via <ralph>GUTTER</ralph>" instruction text, and the supervisor's
# prior "SUPERVISOR: GUTTER" breadcrumb.
#
# Only the driver writes these, always at the start of its message, so
# requiring the timestamp prefix excludes both single-line tool echoes (whose
# message starts with a tool glyph) and multi-line command continuations
# (which carry no timestamp at all).
_TS_RE='^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] '
_STOP_RE="${_TS_RE}LOOP .* END — (🛑 STOP REQUESTED|🤝 GRACEFUL YIELD \(stop-requested)"
_STALL_RE="${_TS_RE}RALPH STOP — 🚨 STALL"
_GUTTER_RE="${_TS_RE}(LOOP .* END — 🚨 GUTTER|RALPH STOP — 🚨)"

# Classify the just-ended run from its exit code + the tail of activity.log.
# Echoes one of: complete | stopped | gutter | stall | error
#
# $2 is the log line count captured *before* the run started: classification
# reads only lines appended since then. Without that fence a resume whose inner
# command exits quickly re-reads the PREVIOUS run's terminal line — a stale
# "STOP REQUESTED" then reports `stopped` and the supervisor refuses to resume
# a run nobody stopped (observed 2026-08-01: two loops that had finished every
# plan task were held down by a stop line from 5h earlier).
_classify() {
  local rc="$1" start_line="${2:-0}" recent
  recent=$(tail -n "+$((start_line + 1))" "$ralph_dir/activity.log" 2>/dev/null | tail -n 80 || true)
  if [[ "$rc" -eq 0 ]]; then
    # rc=0 is a clean completion unless the operator asked to stop (that path
    # also returns 0). The context-warning graceful yield is NOT a stop.
    if grep -qE "$_STOP_RE" <<<"$recent"; then
      echo stopped
    else
      echo complete
    fi
    return
  fi
  # rc != 0 — the run ended on a terminal gutter or stall.
  if grep -qE "$_STALL_RE" <<<"$recent"; then
    echo stall
  elif grep -qE "$_GUTTER_RE" <<<"$recent"; then
    echo gutter
  else
    echo error
  fi
}

# The agent's structured gutter reason (plugin ≥ 0.18.0). The GUTTER handler
# deletes .ralph/gutter-reason after bundling, so read the durable copy from
# the newest gutter post-mortem's meta. Fall back to an errors.log signature
# scan for the concurrent-loop hazard (which predates structured reasons).
_gutter_reason() {
  local r="" pm
  # shellcheck disable=SC2012 # timestamped filenames — ls -t is the simplest portable mtime sort
  pm=$(ls -t "$workspace"/.ralph-postmortems/*-gutter.tar.gz 2>/dev/null | head -1)
  if [[ -n "$pm" ]]; then
    r=$(tar -xzOf "$pm" ./post-mortem-meta.txt 2>/dev/null | sed -n 's/^gutter_reason: //p' | head -1)
  fi
  if [[ -z "$r" ]] &&
    grep -qiE "concurrent-loop hazard|TWO ralph|concurrent.*worktree" "$ralph_dir/errors.log" 2>/dev/null; then
    r="concurrent-writer"
  fi
  printf '%s' "$r"
}

_is_recoverable() {
  local reason="$1" slug
  [[ -n "$reason" ]] || return 1
  for slug in ${recoverable//,/ }; do
    [[ "$reason" == "$slug" ]] && return 0
  done
  return 1
}

# Sourcing for tests: expose the helpers without running the loop.
[[ -n "${RALPH_SUPERVISE_LIB_ONLY:-}" ]] && return 0

resumes=0
while :; do
  log_mark=$(_log_lines)
  bash -c "$command_str"
  rc=$?

  case "$(_classify "$rc" "$log_mark")" in
    complete)
      _breadcrumb "run COMPLETE — work + acceptance eval finished, gate green"
      _notify "🐛 Ralph $session ✅" "Run complete — work + acceptance eval finished, gate green."
      exit 0
      ;;
    stopped)
      _breadcrumb "run STOPPED by operator — no auto-resume"
      _notify "🐛 Ralph $session 🛑" "Stopped by you. Reattach: tmux attach -t $session"
      exit 0
      ;;
    gutter)
      reason="$(_gutter_reason)"
      if _is_recoverable "$reason" && ((resumes < max_resumes)); then
        resumes=$((resumes + 1))
        _breadcrumb "GUTTER (${reason}) is mechanically recoverable — auto-resuming (attempt $resumes/$max_resumes)"
        _notify "🐛 Ralph $session ♻️" "Gutter ($reason) — auto-resuming ($resumes/$max_resumes)."
        sleep 3
        continue
      fi
      _breadcrumb "GUTTER (${reason:-unclassified}) — needs attention$([[ $resumes -gt 0 ]] && echo " (already auto-resumed ${resumes}×)")"
      _notify "🐛 Ralph $session 🚨" "Gutter${reason:+ ($reason)} — needs you. Worktree: $workspace"
      exit 1
      ;;
    stall)
      _breadcrumb "STALL — needs attention (likely rate limit or silent bail)"
      _notify "🐛 Ralph $session 🚨" "Stalled (rate limit / silent bail). Worktree: $workspace"
      exit 1
      ;;
    *)
      _breadcrumb "run ended rc=$rc (unclassified) — needs attention"
      _notify "🐛 Ralph $session ⚠️" "Ended rc=$rc (unclassified). Reattach: tmux attach -t $session"
      exit "$rc"
      ;;
  esac
done
