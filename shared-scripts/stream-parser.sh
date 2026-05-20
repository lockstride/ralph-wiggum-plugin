#!/bin/bash
# Ralph Wiggum: Stream Parser (canonical schema)
#
# Reads canonical-schema JSON events (one per line) produced by
# agent-adapter.sh `agent_normalize`. Tracks token usage, detects
# failures/gutter, writes to .ralph/ logs, and emits signals on stdout.
#
# Usage:
#   eval "$(agent_build_cmd "$CLI" "$MODEL" "$PROMPT")" 2>&1 \
#     | agent_normalize "$CLI" \
#     | ./stream-parser.sh /path/to/workspace [loop_label]
#
# Emits on stdout (one per line):
#   ROTATE          — token threshold reached, stop and rotate context
#   WARN            — approaching limit, agent should wrap up
#   TURN_END        — 5 consecutive gate failures
#   GUTTER          — stuck pattern detected, or agent self-signal,
#                     or non-retryable API error
#   COMPLETE        — agent emitted <ralph>COMPLETE</ralph>
#   DEFER           — retryable API/network error, back off and retry
#
# Writes to .ralph/:
#   activity.log — all operations with context health emoji
#   errors.log   — failures and gutter/thrash detection

set -euo pipefail

WORKSPACE="${1:-.}"
LOOP_LABEL="${2:-}"
RALPH_DIR="$WORKSPACE/.ralph"
mkdir -p "$RALPH_DIR"

# Thresholds (overridable by environment, which ralph-common.sh sets
# based on the selected CLI via agent-adapter.sh defaults).
WARN_THRESHOLD="${WARN_THRESHOLD:-70000}"
ROTATE_THRESHOLD="${ROTATE_THRESHOLD:-80000}"

# Token accounting state
BYTES_READ=0
BYTES_WRITTEN=0
ASSISTANT_CHARS=0
SHELL_OUTPUT_CHARS=0
PROMPT_CHARS=3000 # rough estimate of the framing prompt + state files
WARN_SENT=0
TOOL_CALL_COUNT=0
RATE_LIMITED=0

# Gutter detection — temp files (macOS bash 3.x has no assoc arrays)
FAILURES_FILE=$(mktemp)
WRITES_FILE=$(mktemp)

# 0.10.0: Consecutive gate-failure counter. Tracks gate-run.sh invocations
# that exit nonzero without an intervening success. At threshold (5), emits
# TURN_END so the main loop ends the turn and spawns fresh. Resets at
# parser start (each new agent invocation has fresh counter) and on any
# gate-run.sh exit zero.
GATE_FAIL_STREAK=0
GATE_FAIL_STREAK_THRESHOLD="${RALPH_GATE_FAIL_STREAK_THRESHOLD:-5}"
TURN_END_LATCHED=0

# 0.10.4: The task-completion cap (RALPH_TASK_COMPLETION_CAP) was removed.
# Field data showed it never triggered rotation — gate-fail streaks and
# ROTATE handled every case.

# 0.5.3: independent heartbeat emitter pid. Set in main() once the sidecar
# is spawned; left empty here so the EXIT trap can no-op safely if main()
# exits before the spawn (e.g. test fixtures that source the file).
#
# 0.5.4: trap MUST reap the sidecar's `sleep` child before killing the
# sidecar itself. The sidecar is a `( while sleep N; do echo HB; done ) &`
# subshell; HB_SIDECAR_PID is the subshell's pid. Sending SIGTERM/KILL to
# the subshell does NOT propagate to the foreground `sleep` child — bash
# only checks for trapped signals between commands, and `sleep` blocks the
# subshell for the full interval. The sleep then becomes an orphan
# (PPID=1) holding the FIFO open across the test run, which both leaks
# memory in long-running loops and makes bats suites flaky as orphans
# accumulate across runs. `pkill -P` reaps the children first, then we
# kill the subshell so it exits promptly.
HB_SIDECAR_PID=""
_cleanup_parser() {
  if [[ -n "$HB_SIDECAR_PID" ]]; then
    pkill -P "$HB_SIDECAR_PID" 2>/dev/null || true
    kill "$HB_SIDECAR_PID" 2>/dev/null || true
  fi
  rm -f "$FAILURES_FILE" "$WRITES_FILE"
}
trap _cleanup_parser EXIT

SHELL_FAIL_THRESHOLD="${RALPH_SHELL_FAIL_THRESHOLD:-5}"
# 0.11.5: thrash threshold raised from 5/10min → 10/5min and the per-file
# counter resets on successful commit (see reset_failure_counters_on_task_boundary).
# Rationale: 0.11.4 folded Edit operations into the thrash counter, and a normal
# fix-up cycle commonly does 5+ Edits to one file. The original 5/600s threshold
# was tuned for Write-only traffic. The new threshold lets bursty Edit cycles
# breathe, but tightens the window so genuine no-progress churn still trips.
# Combined with the commit-reset, this fires when there are 10+ writes/edits to
# the same file inside 5 min WITHOUT any commit landing — the actual "stuck"
# signal we want to catch.
FILE_THRASH_THRESHOLD="${RALPH_FILE_THRASH_THRESHOLD:-10}"
FILE_THRASH_WINDOW_SECONDS="${RALPH_FILE_THRASH_WINDOW_SECONDS:-300}"

get_health_emoji() {
  local tokens=$1
  if [[ $tokens -lt $WARN_THRESHOLD ]]; then
    echo "🟢"
  elif [[ $tokens -lt $((ROTATE_THRESHOLD * 95 / 100)) ]]; then
    echo "🟡"
  else
    echo "🔴"
  fi
}

calc_tokens() {
  local total_bytes=$((PROMPT_CHARS + BYTES_READ + BYTES_WRITTEN + ASSISTANT_CHARS + SHELL_OUTPUT_CHARS))
  echo $((total_bytes / 4))
}

# 0.4.0: emit a HEARTBEAT token to stdout so the main loop's `read -t`
# timer resets on any real parser activity, not just on the narrow set
# of control signals (ROTATE/COMPLETE/…). Decouples heartbeat-alive from
# commit-cadence — a quietly productive agent keeps the heartbeat fresh
# via reads / shells / token updates, and only a truly stalled agent
# (no stream-json from claude) trips the timeout. Before 0.4.0 the
# heartbeat was effectively measuring "time since last commit" and
# would kill an agent doing legitimate multi-minute work between
# commits. Kept separate so every stdout-emitting site in this file
# can call it without repeating the `2>/dev/null || true`.
_emit_heartbeat() {
  echo "HEARTBEAT" 2>/dev/null || true
}

log_activity() {
  local message="$1"
  local timestamp
  timestamp=$(date '+%H:%M:%S')
  local tokens
  tokens=$(calc_tokens)
  local emoji
  emoji=$(get_health_emoji "$tokens")
  echo "[$timestamp] $emoji $message" >>"$RALPH_DIR/activity.log"
  _emit_heartbeat
}

log_error() {
  local message="$1"
  local timestamp
  timestamp=$(date '+%H:%M:%S')
  echo "[$timestamp] $message" >>"$RALPH_DIR/errors.log"
}

# 0.12.0: Rewrite the "## Last gate state" section of handoff.md.
# Called from the gate-end handler. The section is replaced in-place;
# the rest of handoff.md (notably the "Working set" section maintained
# by the agent) is preserved. New body comes from
# .ralph/gates/<label>-latest.summary on failure, or a one-liner on success.
update_handoff_gate_state() {
  local label="$1" exit_code="$2"
  local handoff="$RALPH_DIR/handoff.md"
  local summary="$RALPH_DIR/gates/$label-latest.summary"

  # If handoff.md does not exist (project on a pre-0.12 layout), do nothing.
  [[ -f "$handoff" ]] || return 0

  local new_body
  if [[ "$exit_code" -eq 0 ]]; then
    new_body=$(printf 'label: %s\nexit: 0\n(passing — no details to surface)\n' "$label")
  elif [[ -f "$summary" ]]; then
    new_body=$(cat "$summary")
  else
    new_body=$(printf 'label: %s\nexit: %s\n(no summary available — see .ralph/gates/%s-latest.log)\n' \
      "$label" "$exit_code" "$label")
  fi

  # Rewrite the section. Two cases: section exists (replace), or it doesn't
  # (append). Multi-line bodies don't pass cleanly through `awk -v`, so write
  # the body to a sidecar tempfile and `getline` it in.
  local tmp body_tmp
  tmp=$(mktemp)
  body_tmp=$(mktemp)
  printf '%s\n' "$new_body" >"$body_tmp"
  awk -v body_file="$body_tmp" '
    BEGIN {
      in_section=0
      printed=0
      body=""
      while ((getline line < body_file) > 0) {
        body = (body == "") ? line : body "\n" line
      }
      close(body_file)
    }
    /^## Last gate state[[:space:]]*$/ {
      print "## Last gate state"
      print ""
      print body
      print ""
      in_section=1
      printed=1
      next
    }
    in_section==1 && /^## / { in_section=0; print; next }
    in_section==1 { next }
    { print }
    END {
      if (printed==0) {
        print ""
        print "## Last gate state"
        print ""
        print body
      }
    }
  ' "$handoff" >"$tmp" 2>/dev/null
  mv "$tmp" "$handoff"
  rm -f "$body_tmp"
}

log_token_status() {
  local tokens
  tokens=$(calc_tokens)
  local pct=$((tokens * 100 / ROTATE_THRESHOLD))
  local emoji
  emoji=$(get_health_emoji "$tokens")
  local timestamp
  timestamp=$(date '+%H:%M:%S')

  local status_msg="TOKENS: $tokens / $ROTATE_THRESHOLD ($pct%)"
  if [[ $pct -ge 90 ]]; then
    status_msg="$status_msg - rotation imminent"
  elif [[ $pct -ge 72 ]]; then
    status_msg="$status_msg - approaching limit"
  fi

  local breakdown="[read:$((BYTES_READ / 1024))KB write:$((BYTES_WRITTEN / 1024))KB assist:$((ASSISTANT_CHARS / 1024))KB shell:$((SHELL_OUTPUT_CHARS / 1024))KB]"
  echo "[$timestamp] $emoji $status_msg $breakdown" >>"$RALPH_DIR/activity.log"
  # 0.4.0: emit heartbeat so the main loop's read timer resets on every
  # token-status update (fires every 30s on any claude activity).
  _emit_heartbeat
}

wrap_line() {
  local prefix="$1"
  local text="$2"
  local width="${3:-120}"

  if [[ $((${#prefix} + ${#text})) -le $width ]]; then
    printf '%s%s\n' "$prefix" "$text"
    return
  fi

  local non_alnum="${text%%[[:alnum:]]*}"
  local cont_indent=$((${#prefix} + ${#non_alnum}))
  local indent
  indent=$(printf '%*s' "$cont_indent" '')

  local first_avail=$((width - ${#prefix}))
  local break_at=$first_avail
  while [[ $break_at -gt 0 ]] && [[ "${text:$break_at:1}" != " " ]]; do
    break_at=$((break_at - 1))
  done
  [[ $break_at -eq 0 ]] && break_at=$first_avail

  printf '%s%s\n' "$prefix" "${text:0:$break_at}"
  local rest="${text:$break_at}"
  rest="${rest# }"
  [[ -z "$rest" ]] && return

  local cont_avail=$((width - cont_indent))
  [[ $cont_avail -lt 30 ]] && cont_avail=30

  while IFS= read -r seg; do
    printf '%s%s\n' "$indent" "$seg"
  done < <(printf '%s\n' "$rest" | fold -s -w "$cont_avail")
}

is_retryable_api_error() {
  local error_msg="$1"
  local lower_msg
  lower_msg=$(echo "$error_msg" | tr '[:upper:]' '[:lower:]')

  if [[ "$lower_msg" =~ (rate[[:space:]]*limit|rate_limit|rate-limit) ]] ||
    [[ "$lower_msg" =~ (quota[[:space:]]*exceeded|quota[[:space:]]*limit|hit[[:space:]]*your[[:space:]]*limit) ]] ||
    [[ "$lower_msg" =~ (too[[:space:]]*many[[:space:]]*requests|429|http[[:space:]]*429) ]]; then
    return 0
  fi
  if [[ "$lower_msg" =~ (timeout|timed[[:space:]]*out|connection[[:space:]]*timeout) ]] ||
    [[ "$lower_msg" =~ (network[[:space:]]*error|network[[:space:]]*unavailable) ]] ||
    [[ "$lower_msg" =~ (connection[[:space:]]*refused|connection[[:space:]]*reset|econnreset) ]] ||
    [[ "$lower_msg" =~ (connection[[:space:]]*closed|connection[[:space:]]*failed|etimedout|enotfound) ]]; then
    return 0
  fi
  if [[ "$lower_msg" =~ (service[[:space:]]*unavailable|503) ]] ||
    [[ "$lower_msg" =~ (bad[[:space:]]*gateway|502) ]] ||
    [[ "$lower_msg" =~ (gateway[[:space:]]*timeout|504) ]] ||
    [[ "$lower_msg" =~ (overloaded|server[[:space:]]*busy|try[[:space:]]*again) ]]; then
    return 0
  fi
  return 1
}

check_gutter() {
  local tokens
  tokens=$(calc_tokens)

  if [[ $tokens -ge $ROTATE_THRESHOLD ]]; then
    log_activity "ROTATE: Token threshold reached ($tokens >= $ROTATE_THRESHOLD)"
    echo "ROTATE" 2>/dev/null || true
    return
  fi
  if [[ $tokens -ge $WARN_THRESHOLD ]] && [[ $WARN_SENT -eq 0 ]]; then
    log_activity "WARN: Approaching token limit ($tokens >= $WARN_THRESHOLD)"
    WARN_SENT=1
    touch "$RALPH_DIR/context-warning-active" 2>/dev/null || true
    echo "WARN" 2>/dev/null || true
  fi
}

track_shell_failure() {
  local cmd="$1"
  local exit_code="$2"
  if [[ $exit_code -ne 0 ]]; then
    local count
    local single_line_cmd
    single_line_cmd=$(echo -n "$cmd" | base64)
    count=$(grep -cxF "$single_line_cmd" "$FAILURES_FILE" 2>/dev/null) || count=0
    count=$((count + 1))
    echo "$single_line_cmd" >>"$FAILURES_FILE"
    log_error "SHELL FAIL: $cmd → exit $exit_code (attempt $count)"
    # When `git commit` fails (or `git add && git commit`), surface common
    # causes the agent might miss. Most common is staging a gitignored path
    # (e.g. anything under .ralph/) — git silently leaves the index empty
    # and the commit fails with a generic exit 1. Log a hint so the next
    # attempt isn't a blind retry.
    if [[ "$cmd" == *"git commit"* ]]; then
      if [[ "$cmd" == *".ralph/"* ]] || [[ "$cmd" == *"acceptance-report"* ]]; then
        log_error "💡 HINT: \`.ralph/\` is gitignored — \`git add\` on it leaves the index empty and commit fails with exit 1. Do not stage or commit anything under .ralph/."
      elif [[ $exit_code -eq 1 ]] && [[ "$cmd" == *"git add"* ]]; then
        log_error "💡 HINT: git commit exit 1 after \`git add\` often means a staged path is gitignored (commit aborts with empty index). Run \`git status --short\` to verify staging."
      fi
    fi
    # 0.1.10: lowered from 3 to 2. A second identical failure is already
    # strong evidence of stuckness; the extra retry just burns tokens on
    # shell output and delays GUTTER detection.
    # 0.1.16: the counter is reset to zero on any successful `git commit`
    # (task boundary) via reset_failure_counters_on_task_boundary, so this
    # counts failures within the current task, not the whole session.
    # 0.3.0: First trip in a loop emits RECOVER_ATTEMPT (the loop
    # kills the agent and re-spawns it with a recovery hint prepended).
    # Second trip in the same loop falls through to GUTTER — the
    # agent already had its one chance.
    #
    # 0.4.0: threshold raised from 2 → 4 (configurable via
    # RALPH_SHELL_FAIL_THRESHOLD) so a normal red-state debug loop
    # (run gate → read log → fix → re-run) doesn't burn its only
    # recovery attempt on the first real loop.
    # 0.6.0: soft-suggestion at the lower threshold before hard recovery.
    # Writes `.ralph/skill-suggestion` pointing at `diagnosing-stuck-tasks`
    # and emits SUGGEST_SKILL to stdout. Loop does NOT kill the agent;
    # the agent's prompt directs it to read the suggestion and switch modes.
    if [[ $count -ge $SHELL_FAIL_THRESHOLD ]]; then
      log_error "⚠️ GUTTER: same command failed ${count}x"
      echo "GUTTER" 2>/dev/null || true
    fi
  fi
}

# 0.1.16: Clears the failure counter and emits a RECOVER signal on every
# successful `git commit`. This reflects that a successful commit marks
# a task boundary — any prior shell failures within the task have been
# resolved, and any latched GUTTER signal is stale.
#
# Without this reset, a session that survived a transient gate failure
# early on (fixed, gate green, committed) would still surface GUTTER at
# loop-end because FAILURES_FILE accumulates across the entire
# session and the run-loop's `signal` variable never clears once set.
reset_failure_counters_on_task_boundary() {
  : >"$FAILURES_FILE"
  # 0.11.5: also wipe per-file write/edit history. A successful commit is
  # forward progress; any prior thrash history is no longer evidence the
  # agent is stuck. Without this, a 10-edit fix-up cycle followed by a
  # clean commit would still poison the next 5-min window.
  : >"$WRITES_FILE"
  echo "RECOVER" 2>/dev/null || true
}

track_file_write() {
  local path="$1"
  local now
  now=$(date +%s)
  echo "$now:$path" >>"$WRITES_FILE"
  local cutoff=$((now - FILE_THRASH_WINDOW_SECONDS))
  local count
  count=$(awk -F: -v cutoff="$cutoff" -v path="$path" '
    $1 >= cutoff && $2 == path { count++ }
    END { print count+0 }
  ' "$WRITES_FILE")
  if [[ $count -ge $FILE_THRASH_THRESHOLD ]]; then
    local window_min=$((FILE_THRASH_WINDOW_SECONDS / 60))
    log_error "THRASHING: $path written ${count}x in ${window_min} min"
    log_error "⚠️ GUTTER: file thrash on $path"
    echo "GUTTER" 2>/dev/null || true
  fi
}

# Process one canonical-schema event line
process_line() {
  local line="$1"
  [[ -z "$line" ]] && return

  local kind
  kind=$(echo "$line" | jq -r '.kind // empty' 2>/dev/null) || return

  case "$kind" in
    system)
      local model
      model=$(echo "$line" | jq -r '.model // "unknown"' 2>/dev/null) || model="unknown"
      log_activity "SESSION START: model=$model"

      local summary_file="$RALPH_DIR/task-summary"
      if [[ -f "$summary_file" ]]; then
        local ts_done ts_total ts_remaining
        ts_done=$(grep '^done=' "$summary_file" | head -1 | cut -d= -f2) || ts_done=0
        ts_total=$(grep '^total=' "$summary_file" | head -1 | cut -d= -f2) || ts_total=0
        ts_remaining=$(grep '^remaining=' "$summary_file" | head -1 | cut -d= -f2) || ts_remaining=0
        if [[ "$ts_total" -gt 0 ]]; then
          local timestamp
          timestamp=$(date '+%H:%M:%S')
          echo "[$timestamp] 📋 Tasks: $ts_done/$ts_total complete ($ts_remaining remaining)" >>"$RALPH_DIR/activity.log"
          local task_line
          while IFS= read -r task_line; do
            local cleaned
            cleaned=$(echo "$task_line" | sed 's/^[[:space:]]*/  /' | sed 's/\[ \]/☐/')
            wrap_line "[$timestamp]    " "$cleaned" >>"$RALPH_DIR/activity.log"
          done < <(sed -n '/^---$/,$p' "$summary_file" | tail -n +2)
        fi
      fi
      ;;

    assistant_text)
      local text
      text=$(echo "$line" | jq -r '.text // empty' 2>/dev/null) || text=""
      if [[ -n "$text" ]]; then
        ASSISTANT_CHARS=$((ASSISTANT_CHARS + ${#text}))
        if [[ "$text" == *"<ralph>COMPLETE</ralph>"* ]] ||
          [[ "$text" == *"<promise>ALL_TASKS_DONE</promise>"* ]]; then
          log_activity "✅ Agent signaled COMPLETE"
          echo "COMPLETE" 2>/dev/null || true
        fi
        if [[ "$text" == *"<ralph>GUTTER</ralph>"* ]]; then
          log_activity "🚨 Agent signaled GUTTER (stuck)"
          echo "GUTTER" 2>/dev/null || true
        fi
      fi
      ;;

    tool_use)
      TOOL_CALL_COUNT=$((TOOL_CALL_COUNT + 1))
      ;;

    tool_result)
      local name bytes lines exit_code path cmd
      name=$(echo "$line" | jq -r '.name // "Other"' 2>/dev/null) || name="Other"
      bytes=$(echo "$line" | jq -r '.bytes // 0' 2>/dev/null) || bytes=0
      lines=$(echo "$line" | jq -r '.lines // 0' 2>/dev/null) || lines=0
      exit_code=$(echo "$line" | jq -r '.exit_code // 0' 2>/dev/null) || exit_code=0
      path=$(echo "$line" | jq -r '.path // ""' 2>/dev/null) || path=""
      cmd=$(echo "$line" | jq -r '.cmd // ""' 2>/dev/null) || cmd=""

      case "$name" in
        Read)
          BYTES_READ=$((BYTES_READ + bytes))
          local kb=$((bytes / 1024))
          log_activity "READ $path (${lines} lines, ~${kb}KB)"
          ;;
        Edit | MultiEdit | NotebookEdit)
          # 0.11.4: Edit operations are modifications, not reads. Distinct
          # `EDIT` token in activity.log lets monitors and operators tell
          # active editing from investigative reads at a glance. Bytes flow
          # to BYTES_WRITTEN (aligned with ralph-guard.sh, which already
          # treats Write/Edit/MultiEdit uniformly as writes). track_file_write
          # is called so Edit thrashing contributes to the file-thrash
          # GUTTER threshold — Edit thrash is more common in practice than
          # Write thrash (Edit is for fix-up loops; Write is for new files).
          BYTES_WRITTEN=$((BYTES_WRITTEN + bytes))
          local kb=$((bytes / 1024))
          log_activity "EDIT $path (${lines} lines, ${kb}KB)"
          track_file_write "$path"
          ;;
        Write)
          BYTES_WRITTEN=$((BYTES_WRITTEN + bytes))
          local kb=$((bytes / 1024))
          log_activity "WRITE $path (${lines} lines, ${kb}KB)"
          track_file_write "$path"
          ;;
        Shell)
          SHELL_OUTPUT_CHARS=$((SHELL_OUTPUT_CHARS + bytes))
          # 0.5.4: anchor the `git commit` and `git push` matches to either
          # start-of-string OR a shell separator (whitespace, &, ;, |, `(`).
          # 0.10.4: allow global flags between `git` and the subcommand
          # (e.g. `git -C /path commit`). Each flag is -<letter> <value>.
          if [[ "$cmd" =~ (^|[[:space:]\&\;\|\(])git([[:space:]]+-[[:alpha:]][[:space:]]+[^[:space:]]+)*[[:space:]]+commit ]]; then
            if [[ $exit_code -eq 0 ]]; then
              local commit_msg=""
              if [[ "$cmd" =~ -m[[:space:]]+[\"\']([^\"\']+)[\"\'] ]]; then
                commit_msg="${BASH_REMATCH[1]}"
              elif [[ "$cmd" =~ -m[[:space:]]+([^[:space:]]+) ]]; then
                commit_msg="${BASH_REMATCH[1]}"
              fi
              if [[ -n "$commit_msg" ]]; then
                log_activity "COMMIT \"$commit_msg\""
              else
                log_activity "COMMIT (via $cmd)"
              fi
              reset_failure_counters_on_task_boundary
            else
              log_activity "COMMIT FAILED $cmd → exit $exit_code"
              track_shell_failure "$cmd" "$exit_code"
            fi
          elif [[ "$cmd" =~ (^|[[:space:]\&\;\|\(])git([[:space:]]+-[[:alpha:]][[:space:]]+[^[:space:]]+)*[[:space:]]+push ]]; then
            if [[ $exit_code -eq 0 ]]; then
              log_activity "PUSH $cmd → exit 0"
            else
              log_activity "PUSH FAILED $cmd → exit $exit_code"
              track_shell_failure "$cmd" "$exit_code"
            fi
          elif [[ $exit_code -eq 0 ]]; then
            if [[ $bytes -gt 1024 ]]; then
              log_activity "SHELL $cmd → exit 0 (${bytes} chars output)"
            else
              log_activity "SHELL $cmd → exit 0"
            fi
          else
            log_activity "SHELL $cmd → exit $exit_code"
            track_shell_failure "$cmd" "$exit_code"
          fi
          # 0.10.0: gate-fail-streak tracking for TURN_END signal.
          # 0.12.0: also write the ## Last gate state section of handoff.md
          # on every gate-end (pass or fail) so the next loop has fresh state.
          if [[ "$cmd" == *gate-run.sh* ]]; then
            if [[ $exit_code -eq 0 ]]; then
              GATE_FAIL_STREAK=0
            else
              GATE_FAIL_STREAK=$((GATE_FAIL_STREAK + 1))
              if [[ $GATE_FAIL_STREAK -ge $GATE_FAIL_STREAK_THRESHOLD ]] && [[ $TURN_END_LATCHED -eq 0 ]]; then
                log_activity "🛑 TURN_END: $GATE_FAIL_STREAK consecutive gate failures — ending turn"
                TURN_END_LATCHED=1
                echo "TURN_END" 2>/dev/null || true
              fi
            fi
            # Extract label from the gate-run.sh invocation: `bash …/gate-run.sh <label> …`
            local _gate_label
            _gate_label=$(echo "$cmd" | grep -oE 'gate-run\.sh[[:space:]]+[A-Za-z0-9_-]+' | awk '{print $2}' | head -1)
            if [[ -n "$_gate_label" ]]; then
              update_handoff_gate_state "$_gate_label" "$exit_code" 2>/dev/null || true
            fi
          fi
          ;;
        *)
          # Unknown tool — count bytes as assistant output to keep
          # accounting conservative, no activity line.
          ASSISTANT_CHARS=$((ASSISTANT_CHARS + bytes))
          ;;
      esac

      check_gutter
      ;;

    rate_limit)
      local rl_status
      rl_status=$(echo "$line" | jq -r '.status // "unknown"' 2>/dev/null) || rl_status="unknown"
      if [[ "$rl_status" == "rejected" ]]; then
        RATE_LIMITED=1
        local resets_at
        resets_at=$(echo "$line" | jq -r '.resets_at // 0' 2>/dev/null) || resets_at=0
        local resets_human=""
        if [[ $resets_at -gt 0 ]]; then
          resets_human=$(date -r "$resets_at" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null) || resets_human="unix $resets_at"
        fi
        log_error "RATE LIMITED: API rejected the request. Resets at: ${resets_human:-unknown}"
        {
          echo ""
          echo "  ┌──────────────────────────────────────────────────────────┐"
          echo "  │  ⛔ RATE LIMIT HIT — API refused this request.          │"
          echo "  │  The loop will back off and retry automatically.        │"
          if [[ -n "$resets_human" ]]; then
            printf '  │  Resets at: %-46s│\n' "$resets_human"
          fi
          echo "  └──────────────────────────────────────────────────────────┘"
          echo ""
        } >>"$RALPH_DIR/activity.log"
        echo "DEFER" 2>/dev/null || true
      else
        log_activity "RATE LIMIT: status=$rl_status (within quota)"
      fi
      ;;

    error)
      local error_msg
      error_msg=$(echo "$line" | jq -r '.message // "Unknown error"' 2>/dev/null) || error_msg="Unknown error"
      log_error "API ERROR: $error_msg"
      log_activity "❌ API ERROR: $error_msg"
      if is_retryable_api_error "$error_msg"; then
        log_error "⚠️ RETRYABLE: Error may be transient (rate limit/network)"
        echo "DEFER" 2>/dev/null || true
      else
        log_error "🚨 NON-RETRYABLE: Error requires attention"
        echo "GUTTER" 2>/dev/null || true
      fi
      ;;

    result)
      local duration
      duration=$(echo "$line" | jq -r '.duration_ms // 0' 2>/dev/null) || duration=0
      local tokens
      tokens=$(calc_tokens)
      log_activity "SESSION END: ${duration}ms, ~$tokens tokens used"

      if [[ $TOOL_CALL_COUNT -eq 0 ]] && [[ $ASSISTANT_CHARS -eq 0 ]] && [[ $RATE_LIMITED -eq 0 ]]; then
        log_error "EMPTY SESSION: agent produced zero output in ${duration}ms — likely rate limited or API issue"
        {
          echo ""
          echo "  ┌──────────────────────────────────────────────────────────┐"
          echo "  │  ⚠️  EMPTY SESSION — agent started but did nothing.     │"
          echo "  │  No tool calls, no text output (${duration}ms).            │"
          echo "  │  This usually means the API rate limit was hit silently.│"
          echo "  │  The loop will back off and retry automatically.        │"
          echo "  └──────────────────────────────────────────────────────────┘"
          echo ""
        } >>"$RALPH_DIR/activity.log"
        echo "DEFER" 2>/dev/null || true
      fi
      ;;
  esac
}

main() {
  local iter_label=""
  if [[ -n "$LOOP_LABEL" ]]; then
    iter_label=" (Loop $LOOP_LABEL)"
  fi

  {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "Ralph Session Started${iter_label}: $(date)"
    echo "═══════════════════════════════════════════════════════════════"
  } >>"$RALPH_DIR/activity.log"

  # 0.5.3: spawn an independent heartbeat sidecar that emits HEARTBEAT on a
  # fixed interval regardless of input cadence. Without this, parser cannot
  # emit HEARTBEAT during long quiet periods (e.g. agent waiting on a
  # multi-minute gate or model-thinking turn) since log_activity and
  # log_token_status only fire when input arrives via the read loop. The
  # main loop's `read -t RALPH_HEARTBEAT_TIMEOUT` then trips, breaks out,
  # and the next write from this parser SIGPIPEs (no reader on the FIFO) —
  # killing parser and jq, leaving claude orphaned, and the loop diagnoses
  # this as a "PIPELINE EXIT — pipeline wedged" event. The fix decouples
  # liveness signaling from input cadence: the sidecar pings the FIFO every
  # RALPH_PARSER_HEARTBEAT_INTERVAL seconds (default 60) so the loop's read
  # timer always resets while the parser is alive. The interval must stay
  # well below RALPH_HEARTBEAT_TIMEOUT (default 300s) for the sidecar to
  # actually keep the loop unblocked.
  local hb_interval="${RALPH_PARSER_HEARTBEAT_INTERVAL:-60}"
  (
    while sleep "$hb_interval"; do
      echo "HEARTBEAT" 2>/dev/null || break
    done
  ) &
  HB_SIDECAR_PID=$!

  local last_token_log
  last_token_log=$(date +%s)

  while IFS= read -r line; do
    process_line "$line"
    local now
    now=$(date +%s)
    if [[ $((now - last_token_log)) -ge 30 ]]; then
      log_token_status
      last_token_log=$now
    fi
  done

  log_token_status
}

main
