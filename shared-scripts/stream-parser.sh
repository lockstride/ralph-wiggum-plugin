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
#     | ./stream-parser.sh /path/to/workspace [iteration]
#
# Emits on stdout (one per line):
#   ROTATE   — token threshold reached, stop and rotate context
#   WARN     — approaching limit, agent should wrap up
#   GUTTER   — stuck pattern detected (3× same failure, 5× file thrash)
#   COMPLETE — agent emitted <ralph>COMPLETE</ralph>
#   DEFER    — retryable API/network error, back off and retry
#
# Writes to .ralph/:
#   activity.log — all operations with context health emoji
#   errors.log   — failures and gutter/thrash detection

set -euo pipefail

WORKSPACE="${1:-.}"
ITERATION="${2:-}"
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

# Gutter detection — temp files (macOS bash 3.x has no assoc arrays)
FAILURES_FILE=$(mktemp)
WRITES_FILE=$(mktemp)
trap 'rm -f "$FAILURES_FILE" "$WRITES_FILE"' EXIT

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

log_activity() {
  local message="$1"
  local timestamp
  timestamp=$(date '+%H:%M:%S')
  local tokens
  tokens=$(calc_tokens)
  local emoji
  emoji=$(get_health_emoji "$tokens")
  echo "[$timestamp] $emoji $message" >>"$RALPH_DIR/activity.log"
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

track_shell_failure() {
  local cmd="$1"
  local exit_code="$2"
  if [[ $exit_code -ne 0 ]]; then
    local count
    count=$(grep -c "^${cmd}$" "$FAILURES_FILE" 2>/dev/null) || count=0
    count=$((count + 1))
    echo "$cmd" >>"$FAILURES_FILE"
    log_error "SHELL FAIL: $cmd → exit $exit_code (attempt $count)"
    if [[ $count -ge 3 ]]; then
      log_error "⚠️ GUTTER: same command failed ${count}x"
      echo "GUTTER" 2>/dev/null || true
    fi
  fi
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
  if [[ $count -ge 5 ]]; then
    log_error "⚠️ THRASHING: $path written ${count}x in 10 min"
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
      # Informational — real accounting happens on tool_result
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
          ;;
        Write)
          BYTES_WRITTEN=$((BYTES_WRITTEN + bytes))
          local kb=$((bytes / 1024))
          log_activity "WRITE $path (${lines} lines, ${kb}KB)"
          track_file_write "$path"
          ;;
        Shell)
          SHELL_OUTPUT_CHARS=$((SHELL_OUTPUT_CHARS + bytes))
          if [[ "$cmd" =~ ^git[[:space:]]+commit ]]; then
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
            else
              log_activity "COMMIT FAILED $cmd → exit $exit_code"
              track_shell_failure "$cmd" "$exit_code"
            fi
          elif [[ "$cmd" =~ ^git[[:space:]]+push ]]; then
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
      check_gutter
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
      ;;
  esac
}

main() {
  local iter_label=""
  if [[ -n "$ITERATION" ]]; then
    iter_label=" (Iteration $ITERATION)"
  fi

  {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "Ralph Session Started${iter_label}: $(date)"
    echo "═══════════════════════════════════════════════════════════════"
  } >>"$RALPH_DIR/activity.log"

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
