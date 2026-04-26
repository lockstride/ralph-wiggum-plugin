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
#   RECOVER_ATTEMPT — recoverable stuck pattern hit (2× same shell fail or
#                     5× file thrash) for the FIRST time this loop.
#                     Loop kills agent, prepends .ralph/recovery-hint.md
#                     to the next loop prompt, retries (0.3.0).
#   GUTTER          — stuck pattern detected after recovery already used,
#                     OR agent self-signal, OR non-retryable API error.
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
# 0.6.0: tracks which skills we've already suggested this loop so we
# don't spam the same suggestion every turn after the threshold trips.
# One-line-per-skill format; cleared by reset_failure_counters_on_task_boundary.
SUGGESTED_SKILLS_FILE=$(mktemp)

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
  rm -f "$FAILURES_FILE" "$WRITES_FILE" "${SUGGESTED_SKILLS_FILE:-}"
}
trap _cleanup_parser EXIT

# 0.3.0: Active-recovery state. The first recoverable stuck pattern in an
# loop emits RECOVER_ATTEMPT (not GUTTER); subsequent stuck patterns
# in the same loop emit GUTTER as before. The loop's per-invocation
# budget caps total recovery attempts across loops.
RECOVERY_ATTEMPTED=0
RECOVERY_HINT_FILE="$RALPH_DIR/recovery-hint.md"

# Read-without-write stall detection: if the agent executes N consecutive
# read/shell operations without any write, it is a smell worth logging —
# but it is NOT evidence of stuckness on its own. 1M-context models
# legitimately read 25-40 files up-front on foundational phases with no
# handoff.md. The stall is surfaced to errors.log + activity.log for
# operator visibility, but does NOT emit a GUTTER signal (0.2.4). Real
# stuckness is caught by the shell-failure and thrashing heuristics.
CONSECUTIVE_READS=0
MAX_READS_WITHOUT_WRITE="${RALPH_MAX_READS_WITHOUT_WRITE:-40}"

# 0.4.0: Stuck-pattern thresholds. Pre-0.4.0 these were hardcoded at 2
# (shell-fail) and 5 (file-thrash) in the body of their respective
# detectors, which killed agents on the most ordinary red-state workflow:
# run gate, read log, make targeted fix, re-run gate — if the fix didn't
# work, that was attempt #2 and the loop killed the loop with no
# third try. The new 4 / 5 defaults give the agent a realistic debug
# budget without letting genuine infinite loops run forever. Raise via
# env var for longer debug sessions, lower (back to 2) for aggressive
# bail-out behaviour.
SHELL_FAIL_THRESHOLD="${RALPH_SHELL_FAIL_THRESHOLD:-5}"
FILE_THRASH_THRESHOLD="${RALPH_FILE_THRASH_THRESHOLD:-5}"

# 0.6.0: Soft-suggestion threshold for shell-failures and file-thrash. Fires
# BEFORE the hard recovery threshold and writes `.ralph/skill-suggestion`
# pointing the agent at `diagnosing-stuck-tasks`. Same session, no kill —
# the agent's next turn picks up the suggestion. Default 3 catches early
# stuck patterns (1 fix attempt + 2 retries) before the 5-strike hard
# escalation kicks in.
SHELL_FAIL_SUGGEST_THRESHOLD="${RALPH_SHELL_FAIL_SUGGEST_THRESHOLD:-3}"
FILE_THRASH_SUGGEST_THRESHOLD="${RALPH_FILE_THRASH_SUGGEST_THRESHOLD:-3}"

get_health_emoji() {
  local tokens=$1
  local pct=$((tokens * 100 / ROTATE_THRESHOLD))
  if [[ $pct -lt 60 ]]; then
    echo "🟢"
  elif [[ $pct -lt 80 ]]; then
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
    echo "WARN" 2>/dev/null || true
  fi
}

# 0.6.0: Soft suggestion — write a one-shot marker that the running agent's
# next turn picks up. Does NOT kill the agent; same session continues. The
# agent reads `.ralph/skill-suggestion` per its prompt and is expected to
# invoke the named skill. Used for early stuck-pattern signals (3 same-cmd
# failures) where we want the agent to pivot strategy without paying the
# cold-start tax of a fresh loop. Pre-0.6.0 the only escalation path
# was RECOVER_ATTEMPT (kill + restart with hint), which was correct for
# hard recovery but expensive for "you might be on the wrong track."
SKILL_SUGGESTION_FILE="$RALPH_DIR/skill-suggestion"

_write_skill_suggestion() {
  local skill="$1"
  local trigger="$2"
  local detail="$3"
  cat >"$SKILL_SUGGESTION_FILE" <<EOF
## Loop suggestion (consume once, then delete this file)

**Skill to invoke**: \`${skill}\`

**Why**: ${trigger}

**Context**: ${detail}

The loop detected a pattern that suggests you should switch cognitive postures.
Read the skill's SKILL.md and follow its workflow before continuing the
procedural execute-gate-commit cycle. After the skill completes (or you decide
to override its recommendation), delete this file with \`rm .ralph/skill-suggestion\`.
EOF
}

# 0.3.0: Recovery-hint helpers. Each writes a trigger-specific block to
# .ralph/recovery-hint.md, which build_prompt() prepends to the next
# loop's framing prompt and deletes (consume-once).
_write_recovery_hint_shell() {
  local cmd="$1"
  local exit_code="$2"
  cat >"$RECOVERY_HINT_FILE" <<EOF
## Recovery Hint from Prior Loop

Your prior loop ran the following command twice with the same exit code (\`${exit_code}\`) before being killed by the recovery system:

\`\`\`
${cmd}
\`\`\`

- **Do not retry that exact command** — it will fail the same way.
- Read the persisted output of the failing run before trying anything else.
- Diagnose the root cause: missing dependency, wrong directory, gate misconfiguration, or an environment assumption that does not hold.
- If the command is a gate, the failing log is at \`.ralph/gates/<label>-latest.log\`.

This hint will not appear again — you have one shot to recover before the loop escalates to GUTTER.
EOF
}

_write_recovery_hint_thrash() {
  local path="$1"
  local count="$2"
  cat >"$RECOVERY_HINT_FILE" <<EOF
## Recovery Hint from Prior Loop

Your prior loop rewrote \`${path}\` ${count} times within 10 minutes before being killed by the recovery system.

- **Stop editing that file in this loop** until you understand why prior edits did not settle.
- Run \`git diff HEAD -- ${path}\` and read your own changes carefully.
- Consider that the failing test or symptom may originate elsewhere — repeatedly rewriting the same file is a strong sign you are debugging the wrong layer.

This hint will not appear again — you have one shot to recover before the loop escalates to GUTTER.
EOF
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
    if [[ $count -ge $SHELL_FAIL_SUGGEST_THRESHOLD ]] && [[ $count -lt $SHELL_FAIL_THRESHOLD ]]; then
      if ! grep -qxF "diagnosing-stuck-tasks" "$SUGGESTED_SKILLS_FILE" 2>/dev/null; then
        _write_skill_suggestion "diagnosing-stuck-tasks" \
          "Same gate command has failed ${count} times" \
          "Command: ${cmd}"
        echo "diagnosing-stuck-tasks" >>"$SUGGESTED_SKILLS_FILE"
        log_activity "💡 Skill suggestion: diagnosing-stuck-tasks (shell-fail ${count}x)"
        echo "SUGGEST_SKILL" 2>/dev/null || true
      fi
    fi
    if [[ $count -ge $SHELL_FAIL_THRESHOLD ]]; then
      if [[ $RECOVERY_ATTEMPTED -eq 0 ]]; then
        _write_recovery_hint_shell "$cmd" "$exit_code"
        log_error "🔁 RECOVERABLE STUCK PATTERN: same command failed ${count}x — emitting RECOVER_ATTEMPT"
        log_activity "🔁 Recoverable stuck pattern (shell-fail ${count}x): $cmd"
        RECOVERY_ATTEMPTED=1
        echo "RECOVER_ATTEMPT" 2>/dev/null || true
      else
        log_error "⚠️ GUTTER: same command failed ${count}x (recovery already used this loop)"
        echo "GUTTER" 2>/dev/null || true
      fi
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
  CONSECUTIVE_READS=0
  # 0.6.0: also clear the per-loop suggested-skill marker so the
  # next stuck pattern (probably on a different command) gets a fresh
  # suggestion. The skill-suggestion file itself is consumed by the
  # agent, not us.
  : >"$SUGGESTED_SKILLS_FILE"
  # Tell run_loop to clear any latched GUTTER/WARN signals. The
  # consumer treats RECOVER as "the bad thing is over; keep going".
  echo "RECOVER" 2>/dev/null || true
}

track_file_write() {
  local path="$1"
  local now
  now=$(date +%s)
  echo "$now:$path" >>"$WRITES_FILE"
  local cutoff=$((now - 600))
  local count
  count=$(awk -F: -v cutoff="$cutoff" -v path="$path" '
    $1 >= cutoff && $2 == path { count++ }
    END { print count+0 }
  ' "$WRITES_FILE")
  # 0.6.0: soft-suggestion at lower threshold for thrash too.
  if [[ $count -ge $FILE_THRASH_SUGGEST_THRESHOLD ]] && [[ $count -lt $FILE_THRASH_THRESHOLD ]]; then
    if ! grep -qxF "diagnosing-stuck-tasks" "$SUGGESTED_SKILLS_FILE" 2>/dev/null; then
      _write_skill_suggestion "diagnosing-stuck-tasks" \
        "Same file rewritten ${count} times in 10 minutes" \
        "Path: ${path}"
      echo "diagnosing-stuck-tasks" >>"$SUGGESTED_SKILLS_FILE"
      log_activity "💡 Skill suggestion: diagnosing-stuck-tasks (file thrash ${count}x on $path)"
      echo "SUGGEST_SKILL" 2>/dev/null || true
    fi
  fi
  if [[ $count -ge $FILE_THRASH_THRESHOLD ]]; then
    log_error "THRASHING: $path written ${count}x in 10 min"
    # 0.3.0: First trip in a loop emits RECOVER_ATTEMPT; second
    # trip falls through to GUTTER. See track_shell_failure for rationale.
    if [[ $RECOVERY_ATTEMPTED -eq 0 ]]; then
      _write_recovery_hint_thrash "$path" "$count"
      log_error "🔁 RECOVERABLE STUCK PATTERN: file thrash on $path — emitting RECOVER_ATTEMPT"
      log_activity "🔁 Recoverable stuck pattern (thrash ${count}x): $path"
      RECOVERY_ATTEMPTED=1
      echo "RECOVER_ATTEMPT" 2>/dev/null || true
    else
      log_error "⚠️ GUTTER: file thrash on $path (recovery already used this loop)"
      echo "GUTTER" 2>/dev/null || true
    fi
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
        Read | Edit | MultiEdit | NotebookEdit)
          BYTES_READ=$((BYTES_READ + bytes))
          local kb=$((bytes / 1024))
          log_activity "READ $path (${lines} lines, ~${kb}KB)"
          # Read-without-write stall: increment counter
          CONSECUTIVE_READS=$((CONSECUTIVE_READS + 1))
          ;;
        Write)
          BYTES_WRITTEN=$((BYTES_WRITTEN + bytes))
          local kb=$((bytes / 1024))
          log_activity "WRITE $path (${lines} lines, ${kb}KB)"
          track_file_write "$path"
          # Write resets the read-without-write counter
          CONSECUTIVE_READS=0
          ;;
        Shell)
          SHELL_OUTPUT_CHARS=$((SHELL_OUTPUT_CHARS + bytes))
          # 0.5.4: anchor the `git commit` and `git push` matches to either
          # start-of-string OR a shell separator (whitespace, &, ;, |, `(`),
          # not just start-of-string. Spec-Kit-style agents canonically batch
          # `git add <paths> && git commit -m "..."` as a single shell call,
          # which the prior `^git ` anchor missed entirely. Without this fix,
          # reset_failure_counters_on_task_boundary never fires, the per-task
          # shell-failure counter accumulates across the whole loop, and
          # a loop with N successful commits + a few unrelated transient
          # failures eventually trips the recovery threshold for no real
          # reason. Field log: 14 successful commits in one loop produced
          # exactly one `COMMIT` activity-log line.
          if [[ "$cmd" =~ (^|[[:space:]\&\;\|\(])git[[:space:]]+commit ]]; then
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
              # Task boundary: clear any accumulated shell-failure history
              # and release any latched GUTTER/WARN signals. See
              # reset_failure_counters_on_task_boundary for rationale.
              reset_failure_counters_on_task_boundary
            else
              log_activity "COMMIT FAILED $cmd → exit $exit_code"
              track_shell_failure "$cmd" "$exit_code"
            fi
          elif [[ "$cmd" =~ (^|[[:space:]\&\;\|\(])git[[:space:]]+push ]]; then
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
          ;;
        *)
          # Unknown tool — count bytes as assistant output to keep
          # accounting conservative, no activity line.
          ASSISTANT_CHARS=$((ASSISTANT_CHARS + bytes))
          ;;
      esac

      # Read-without-write stall: Shell also counts as a non-write op
      # (already tracked in Read case above; Shell increments here).
      if [[ "$name" == "Shell" ]]; then
        CONSECUTIVE_READS=$((CONSECUTIVE_READS + 1))
      fi

      # Check read-without-write stall threshold.
      # 0.2.4: Downgraded from GUTTER to a logged-only observation. A
      # stall is a smell (worth surfacing to the operator for diagnosis)
      # but not evidence of stuckness on its own. Real stuckness comes
      # from repeated identical shell failures or file thrashing, which
      # are handled elsewhere.
      # 0.6.1: also emit SUGGEST_SKILL pointing at `reviewing-loop-progress`.
      # Empirical evidence (12 stall warnings in a single dmatrix.refactor
      # session with zero escalation) showed the logged-only treatment was
      # too passive — agents that read 40+ files with no write are usually
      # confused about the task, not legitimately exploring. The lighter
      # `reviewing-loop-progress` skill (one-paragraph "what am I actually
      # doing" reflection) is the right intervention here, not the heavier
      # `diagnosing-stuck-tasks` (reserved for repeated gate failures).
      # Deduped per-loop via SUGGESTED_SKILLS_FILE so the same stall
      # pattern doesn't spam suggestions every 40 ops.
      if [[ $CONSECUTIVE_READS -ge $MAX_READS_WITHOUT_WRITE ]]; then
        log_error "⚠️ READ-WITHOUT-WRITE STALL: $CONSECUTIVE_READS consecutive reads/shells without a write (informational only)"
        log_activity "⚠️ Read-without-write stall: $CONSECUTIVE_READS ops without a write"
        if ! grep -qxF "reviewing-loop-progress" "$SUGGESTED_SKILLS_FILE" 2>/dev/null; then
          _write_skill_suggestion "reviewing-loop-progress" \
            "Agent has performed ${CONSECUTIVE_READS} reads/shells with no write in between" \
            "Long read-without-write streaks usually mean the agent is confused about the task or thrashing through unrelated files. A meta-reflection (one paragraph: what am I doing, what's working, what's not) is cheaper than another 40 reads."
          echo "reviewing-loop-progress" >>"$SUGGESTED_SKILLS_FILE"
          log_activity "💡 Skill suggestion: reviewing-loop-progress (read-without-write stall)"
          echo "SUGGEST_SKILL" 2>/dev/null || true
        fi
        CONSECUTIVE_READS=0
      fi

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
