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
# 0.23.0: bytes belonging to a Task sub-agent, tracked SEPARATELY. Delegated
# work never enters the orchestrator's context window, so charging it to the
# rotation budget makes a delegating loop look far fuller than it is and can
# rotate it early for no reason. Excluded from calc_tokens, still reported on
# the TOKENS line so the work stays visible to an operator.
SIDECHAIN_CHARS=0
# 0.26.0: the context size the API last reported for this session (a `usage`
# event — claude only), and the byte total at that moment. When set, it is the
# figure rotation keys on: the byte count above never sees the system prompt,
# retained thinking or any tool call's input, so it runs far below the real
# context. Bytes that arrive after a report still count, as an estimate, until
# the next report replaces it. cursor-agent reports nothing and keeps the
# byte estimate.
REPORTED_TOKENS=0
REPORTED_AT_BYTES=0
TOTAL_BYTES=0
WARN_SENT=0
TOOL_CALL_COUNT=0
RATE_LIMITED=0

# 0.24.1: per-session attribution. The parser lives for the whole LOOP, but
# the agent CLI can open several sessions inside it — Claude Code compacts its
# own context and emits a fresh init/result pair without Ralph asking for
# anything. calc_tokens is cumulative over the parser's lifetime, so every
# SESSION END reported the same loop-to-date figure: a loop with three
# sessions logged "~272926 tokens used" three times, which reads as a stuck
# counter and tells an evaluator nothing about which session was expensive.
# Track a per-session baseline so each SESSION END reports its OWN usage while
# the loop total (the number rotation actually keys on) stays visible.
SESSION_INDEX=0
SESSION_TOKENS_BASE=0

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

# 0.24.0: the run-id of the last gate end already consumed from
# .ralph/gates/last-run (written by gate-run.sh's _write_breadcrumbs). Seeded
# from whatever is on disk at parser start so a PREVIOUS loop's gate is not
# replayed as this session's first event — the streak is per-agent-invocation
# by design.
GATE_EVENT_SEEN=""
if [[ -f "$RALPH_DIR/gates/last-run" ]]; then
  GATE_EVENT_SEEN=$(head -n 1 "$RALPH_DIR/gates/last-run" 2>/dev/null || true)
fi

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

# Sets TOTAL_BYTES to every byte this session has accounted (sub-agents excluded).
_sum_bytes() {
  TOTAL_BYTES=$((PROMPT_CHARS + BYTES_READ + BYTES_WRITTEN + ASSISTANT_CHARS + SHELL_OUTPUT_CHARS))
}

calc_tokens() {
  _sum_bytes
  if [[ $REPORTED_TOKENS -gt 0 ]]; then
    echo $((REPORTED_TOKENS + (TOTAL_BYTES - REPORTED_AT_BYTES) / 4))
  else
    echo $((TOTAL_BYTES / 4))
  fi
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

# 0.24.0: record WHEN the agent last changed the ## Working set.
#
# handoff.md's own mtime cannot answer this — the plugin rewrites the file
# itself (## Last gate state, ## Auto-enriched state), so mtime tracks the
# plugin, not the agent. _auto_enrich_handoff turns this stamp into a visible
# age line, and a stale block reads exactly like a fresh one without it.
# Deliberately NOT cleared at loop start: an age that spans loops is exactly
# the signal.
#
# 0.26.0: keyed on the section's CONTENT, not on a Write/Edit tool event. The
# agent also rewrites the handoff through Bash (python heredocs, `cat >`,
# `sed -i`), which no tool event reports, so the event-keyed stamp aged a
# section that had just been rewritten. Whenever handoff.md may have changed,
# hash the section: a different hash is a new working set, however it was
# written. The plugin's own rewrites of the other sections leave it alone, and
# an identical rewrite is not news. The first look only records a baseline —
# it cannot know when the section it finds was written.
#   $1 = the path or command of the tool call just seen; the file is hashed
#        when it names handoff.md, or when the file is newer than the last look
_check_handoff_working_set() {
  local handoff="$RALPH_DIR/handoff.md" sum_file="$RALPH_DIR/handoff-working-set.sum"
  if [[ -f "$sum_file" && "${1:-}" != *handoff.md* && ! "$handoff" -nt "$sum_file" ]]; then
    return 0
  fi
  local sum prev=""
  if [[ -f "$handoff" ]]; then
    sum=$(awk '/^## Working set[[:space:]]*$/ { f = 1; next } f && /^## / { f = 0 } f' \
      "$handoff" 2>/dev/null | cksum) || return 0
  else
    # No file yet is an empty working set, so the one that creates it counts.
    sum=$(printf '' | cksum)
  fi
  [[ -f "$sum_file" ]] && prev=$(cat "$sum_file" 2>/dev/null)
  if [[ -n "$prev" && "$sum" != "$prev" ]]; then
    date +%s >"$RALPH_DIR/handoff-agent-ts" 2>/dev/null || true
  fi
  printf '%s\n' "$sum" >"$sum_file" 2>/dev/null || true
}

# 0.24.0: consume the gate's own end-of-run marker.
#
# Replaces the pre-0.24 `[[ "$cmd" == *gate-run.sh* ]]` test, which keyed on
# the MODEL's command text. ralph-guard.sh wraps a tier command via the
# PreToolUse hook's `updatedInput`, and that rewrite is invisible to the
# transcript — the tool_use event still carries `./scripts/gate.sh full`. So
# the test never matched on the normal path, and BOTH things behind it were
# dead: handoff.md's "Last gate state" was never written (cur-71: 46 gates,
# `_(none yet)_` still in the file) and GATE_FAIL_STREAK never incremented, so
# the 5-consecutive-failures TURN_END could not fire.
#
# Keying on `.ralph/gates/last-run` instead is rewrite-proof, and covers the
# `bash "$(cat .ralph/gate-runner)" final …` indirection the eval loop's
# sub-agents use — neither contains the literal string this used to need.
#
# Called from the Shell branch: a gate is always started by a shell command and
# its verdict is always observed by one (the foreground waiter's own return, or
# the poll that reads the exit breadcrumb), so every gate end is drained by the
# next tool_result at the latest.
#
# Single-slot, not a journal: two DIFFERENT labels finishing between one shell
# result and the next collapse to the later one. Per-label locking serializes
# same-label runs, and an agent running two labels concurrently is rare enough
# that a missed streak increment is the right trade against an unbounded file.
_drain_gate_event() {
  local marker="$RALPH_DIR/gates/last-run"
  [[ -f "$marker" ]] || return 0
  local line
  line=$(head -n 1 "$marker" 2>/dev/null) || return 0
  [[ -n "$line" ]] || return 0
  [[ "$line" != "$GATE_EVENT_SEEN" ]] || return 0
  GATE_EVENT_SEEN="$line"

  local _label _exit _rest
  read -r _label _exit _rest <<<"$line"
  # A malformed marker is not a gate verdict. Nothing downstream should act on
  # it, and the streak must not move on a line we could not parse. gate-run.sh
  # validates the label before it ever runs (exit 64 otherwise), so this is
  # defense in depth — but it keeps the 0.12.4 invariant that a bare numeric
  # token can never be mistaken for a label, which is why the pattern requires
  # a leading letter rather than accepting any alphanumeric.
  [[ "$_label" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || return 0
  [[ "$_exit" =~ ^[0-9]+$ ]] || return 0

  if [[ "$_exit" -eq 0 ]]; then
    GATE_FAIL_STREAK=0
  else
    GATE_FAIL_STREAK=$((GATE_FAIL_STREAK + 1))
    if [[ $GATE_FAIL_STREAK -ge $GATE_FAIL_STREAK_THRESHOLD ]] && [[ $TURN_END_LATCHED -eq 0 ]]; then
      log_activity "🛑 TURN_END: $GATE_FAIL_STREAK consecutive gate failures — ending turn"
      TURN_END_LATCHED=1
      echo "TURN_END" 2>/dev/null || true
    fi
  fi
  update_handoff_gate_state "$_label" "$_exit" 2>/dev/null || true
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

  # 0.26.0: `ctx:api` marks a figure anchored on the API-reported context; the
  # byte breakdown after it is then only the traffic, not the total. Absent on
  # the byte-estimate path, whose line is unchanged.
  local source=""
  [[ $REPORTED_TOKENS -gt 0 ]] && source="ctx:api "
  local breakdown="[${source}read:$((BYTES_READ / 1024))KB write:$((BYTES_WRITTEN / 1024))KB assist:$((ASSISTANT_CHARS / 1024))KB shell:$((SHELL_OUTPUT_CHARS / 1024))KB"
  # 0.23.0: only present when the loop actually delegated, so a non-delegating
  # run's line is byte-identical to before. `sub:` is outside the rotation
  # total on purpose — it is the sub-agents' context, not this session's.
  [[ $SIDECHAIN_CHARS -gt 0 ]] && breakdown="$breakdown sub:$((SIDECHAIN_CHARS / 1024))KB"
  breakdown="$breakdown]"
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

# 0.14.3: resolve the live task file the same way ralph-common.sh's
# _resolve_task_file does (RALPH_TASK_FILE env > .ralph/task-file-path
# breadcrumb). Prints the path on stdout, or nothing if none resolves to a
# real file. Used by the SESSION START banner so task counts reflect the
# CURRENT checkbox state, not a snapshot frozen at process launch — in
# run-to-completion mode the bash loop launches the agent once, so the
# static .ralph/task-summary never refreshes across internal rotations.
_sp_resolve_task_file() {
  if [[ -n "${RALPH_TASK_FILE:-}" ]] && [[ -f "${RALPH_TASK_FILE}" ]]; then
    printf '%s' "$RALPH_TASK_FILE"
    return
  fi
  local breadcrumb="$RALPH_DIR/task-file-path"
  if [[ -f "$breadcrumb" ]]; then
    local bf
    bf=$(cat "$breadcrumb" 2>/dev/null) || bf=""
    if [[ -n "$bf" ]] && [[ -f "$bf" ]]; then
      printf '%s' "$bf"
      return 0
    fi
  fi
  # Nothing resolved — print nothing, succeed (caller falls back to the
  # static task-summary). Explicit success so `set -e` doesn't abort on the
  # `task_file=$(...)` assignment.
  return 0
}

is_retryable_api_error() {
  local error_msg="$1"
  local lower_msg
  lower_msg=$(echo "$error_msg" | tr '[:upper:]' '[:lower:]')

  if [[ "$lower_msg" =~ (rate[[:space:]]*limit|rate_limit|rate-limit) ]] ||
    [[ "$lower_msg" =~ (quota[[:space:]]*exceeded|quota[[:space:]]*limit|hit[[:space:]]*your[[:space:]]*limit) ]] ||
    # A subscription quota is worded as a *named* limit — "You've hit your
    # session limit · resets 4am", also weekly/usage/daily/monthly. The
    # `hit your limit` pattern above requires the words adjacent, so the noun
    # in between made every one of these NON-RETRYABLE → GUTTER, halting the
    # runner on a condition that clears by itself (observed 2026-08-01: four
    # concurrent loops all died at a session limit that reset 68 min later,
    # two seconds after the structured rate_limit event had correctly said
    # "back off and retry automatically").
    [[ "$lower_msg" =~ (session|usage|weekly|daily|monthly)[[:space:]]*limit ]] ||
    [[ "$lower_msg" =~ (limit[[:space:]]*(will[[:space:]]*)?reset|resets[[:space:]]*(at|in)) ]] ||
    [[ "$lower_msg" =~ (too[[:space:]]*many[[:space:]]*requests|429|http[[:space:]]*429) ]]; then
    return 0
  fi
  if [[ "$lower_msg" =~ (timeout|timed[[:space:]]*out|connection[[:space:]]*timeout) ]] ||
    [[ "$lower_msg" =~ (network[[:space:]]*error|network[[:space:]]*unavailable) ]] ||
    [[ "$lower_msg" =~ (connection[[:space:]]*refused|connection[[:space:]]*reset|econnreset) ]] ||
    [[ "$lower_msg" =~ (connection[[:space:]]*closed|connection[[:space:]]*failed|etimedout|enotfound) ]] ||
    # A dropped socket is transient, not a stuck agent. The Anthropic SDK
    # surfaces these as "The socket connection was closed unexpectedly" —
    # note the "was" between "connection" and "closed", which the
    # `connection[[:space:]]*closed` pattern above does NOT match, and there
    # is no bare `socket` token there either. Without this branch such a
    # drop falls through to NON-RETRYABLE → GUTTER → the whole runner halts
    # (observed: a single drop stalled a run for ~3.5h until an external
    # keep-alive restarted it). DEFER's stall_count>=10 ceiling still trips
    # on a genuinely dead endpoint, so this cannot loop forever.
    [[ "$lower_msg" =~ (socket|connection[[:space:]]*was[[:space:]]*closed|closed[[:space:]]*unexpectedly|hang[[:space:]]*up|epipe) ]]; then
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

# 0.14.7: Expected-nonzero diagnostic detector. Exit 1 from a command
# composed purely of read-only utilities is informational, not a failure:
# `grep` exits 1 on no-match, `ls`/`cat` exit 1 on an absent path — the
# breadcrumb-poll idioms (`ls .ralph/stop-requested`) and no-match greps
# that dominated errors.log on otherwise-clean runs. Logging them as
# SHELL FAIL buries real failures and pollutes the shell-fail counter.
# Conservative by construction: only exit code 1 qualifies (2+ is a real
# error even for grep), and every ;/&&/||/|-separated segment must start
# with an allowlisted read-only command — anything that can mutate state
# (git, pnpm, rm, …) keeps the current behavior. `find` and `sed` are
# read-only only in some forms, so they are allowlisted only when the
# segment carries no mutating action (`find -exec/-execdir/-delete/-ok/
# -okdir/-fprint*/-fls`, `sed -i/--in-place`); any such flag drops the
# whole command back to the logged path. Quoted separators are stripped
# before splitting (see below), so a `|`/`;`/`&&`/`||` inside a quoted
# argument cannot mis-split the command.
#
# 0.20.0: the every-segment rule was already right; the VOCABULARY was too
# small, so long read-only diagnostic chains still landed in errors.log on one
# unlisted segment (a run of 19 SHELL FAIL entries was mostly this). Three
# additions, all conservative: common read-only utilities (printf/sort/awk/jq/
# stat/…), subcommand-gated `git` and `docker` (interrogation verbs only —
# several of which exit 1 as their ANSWER: `git check-ignore`, `git diff
# --quiet`, `git grep`, `docker info`), and a redirect check that treats
# `> file` as the write it is regardless of the command in front of it.
# Fill $_SUB1 / $_SUB2 with the first two words after a segment's command
# name, skipping the command's own leading flags (and the value of git's
# `-C` / `-c`, which take one). `git -C /repo worktree list --porcelain`
# yields _SUB1=worktree, _SUB2=list. $_SUB2 is verbatim — a flag can be the
# meaningful second word (`git config --get`).
_SUB1=""
_SUB2=""
_split_subcommand() {
  local seg="$1"
  local -a w
  read -ra w <<<"$seg"
  _SUB1=""
  _SUB2=""
  local i=1
  while [[ $i -lt ${#w[@]} ]]; do
    case "${w[$i]}" in
      -C | -c)
        i=$((i + 2))
        ;;
      -*)
        i=$((i + 1))
        ;;
      *)
        _SUB1="${w[$i]}"
        [[ $((i + 1)) -lt ${#w[@]} ]] && _SUB2="${w[$((i + 1))]}"
        return 0
        ;;
    esac
  done
  return 0
}

# 0.24.0: a command that carries its OWN cutoff is reporting an answer when
# that cutoff fires, not failing.
#
# Sibling of the 0.23.0 readiness-probe rule, for the shape that rule does not
# reach: a deliberate interrupt/resume harness. cur-71 logged two of them as
# SHELL FAIL — `… & bpid=$!; sleep 14; kill -INT "$bpid"; wait …` (15:33:02)
# and `timeout -k 3 12 bash -c …` (15:36:41). Both were testing that a backfill
# resumes from its checkpoint after being cut off; being cut off was the point.
#
# Deliberately narrow, on BOTH axes, because the alternative is laundering real
# failures:
#
#   - The exit code must be a cutoff signature. 124 is GNU timeout firing (and
#     0.24.0's adapter marker for the CLI's own Bash timeout); 137/143/130 are
#     KILL/TERM/INT. Every other non-zero code is the command's own verdict and
#     keeps the logged path — `timeout 300 pnpm test` exiting 1 on a real test
#     failure is still a failure.
#   - The command text must carry the instrument that did the cutting. A plain
#     `pnpm build` the tool had to kill has no self-cutoff and stays a failure,
#     so an agent hanging the loop remains visible.
#
# Callers log these on their own line rather than dropping them: a cutoff is
# not a verdict, but it is not nothing either.
_is_self_limited_cutoff() {
  local cmd="$1" exit_code="$2"
  case "$exit_code" in
    124 | 130 | 137 | 143) ;;
    *) return 1 ;;
  esac
  # `timeout`/`gtimeout` as a command word (not the substring inside
  # `--max-time` or a path), at the start of the command or after a separator.
  if printf '%s' "$cmd" | grep -qE '(^|[[:space:];&|(])g?timeout[[:space:]]'; then
    return 0
  fi
  # An explicit stop signal aimed at something the command is running. `-0` is
  # a liveness PROBE, not a cutoff, and is excluded by listing the signals.
  if printf '%s' "$cmd" | grep -qE '(^|[[:space:];&|(])(p?kill)[[:space:]]+(-[[:alpha:]]+[[:space:]]+)*-(INT|TERM|KILL|HUP|QUIT|2|3|9|15)([[:space:]]|$)'; then
    return 0
  fi
  return 1
}

_is_expected_nonzero_diagnostic() {
  local cmd="$1" exit_code="$2"
  [[ "$exit_code" -eq 1 ]] || return 1
  # 0.14.12: drop quoted spans BEFORE splitting on shell separators so a
  # `|`, `;`, `&&`, or `||` inside a quoted argument (e.g.
  # `grep -nE "test|vitest|coverage"`) can't shatter a segment and force the
  # whole command to the logged path. Only each segment's FIRST word (the
  # command name) is inspected below, and command names are never quoted, so
  # discarding quoted content is loss-free here. Unbalanced / escaped quotes
  # are rare in read-only diagnostics and fall back to logging — safe.
  local stripped
  stripped=$(printf '%s' "$cmd" | sed -E 's/"[^"]*"//g' | sed "s/'[^']*'//g")
  # The literal `$(` that opens a command substitution, held in a variable so
  # the case pattern below reads cleanly. Single quotes are the point: this must
  # never expand.
  # shellcheck disable=SC2016
  local capture_open='=$('
  local normalized="${stripped//"&&"/;}"
  normalized="${normalized//"||"/;}"
  normalized="${normalized//"|"/;}"
  local seg first
  while IFS= read -r seg; do
    seg="${seg#"${seg%%[![:space:]]*}"}"
    [[ -z "$seg" ]] && continue
    first="${seg%%[[:space:]]*}"
    # 0.18.0: peel a leading loop/branch keyword so a read-only control-flow
    # body (`for f in …; do grep -c … "$f"; done`) is inspected on its real
    # command, not the keyword — the `for … do grep -c` diagnostic idiom was
    # still landing in errors.log (run 140038) because `grep -c` exits 1 on a
    # zero count and the whole loop inherited it.
    #
    # 0.23.0: peel REPEATEDLY, and peel `{` and leading variable assignments
    # too. The single 0.18.0 peel only covered the one-line loop form. A
    # readiness probe written across several lines puts `do` alone on its own
    # segment, its body in `api=$(curl …)` shape, and a grouped condition
    # contributes a `{ [ … ]` segment — each of which fell to the logged path
    # on a keyword rather than on a command. Peeling is strictly safer than
    # allowlisting the keyword: whatever it fronts still has to clear the
    # vocabulary below, so `{ rm -rf /` is inspected on `rm`, and rejected.
    while [[ -n "$first" ]]; do
      case "$first" in
        do | then | else | elif | "{")
          seg="${seg#"$first"}"
          ;;
        # `NAME=value cmd …` (env prefix) and `NAME=$(cmd …)` (capture) both
        # front a real command — inspect that, not the assignment. For a
        # capture, splice the inner command name back on so it lands as the
        # segment's first word; its trailing `)` is inert for every check
        # below, all of which key on the first word or on flag substrings.
        [A-Za-z_]*=*)
          seg="${seg#"$first"}"
          case "$first" in
            *"$capture_open"*) seg="${first#*"$capture_open"} $seg" ;;
          esac
          ;;
        *) break ;;
      esac
      seg="${seg#"${seg%%[![:space:]]*}"}"
      first="${seg%%[[:space:]]*}"
    done
    # A segment that was nothing but keywords and/or assignments (`do`, `x=5`)
    # runs no command of its own, so there is nothing here to judge.
    [[ -z "$first" ]] && continue
    # 0.20.0: a redirect into a FILE is a write no matter how read-only the
    # command is (`printf … > f`, `sort … > out`, and the pre-existing
    # `cat > f` hole). Discards (`>/dev/null`) and fd dups (`2>&1`) are not
    # writes and stay read-only — they are ubiquitous in diagnostic idioms.
    # Checked on a throwaway copy; quoted spans are already gone, so a `>`
    # inside an argument cannot trip this.
    local _redir="${seg//>&/}"
    _redir=$(printf '%s' "$_redir" | sed -E 's/>>?[[:space:]]*\/dev\/null//g')
    [[ "$_redir" == *">"* ]] && return 1

    case "$first" in
      cd | ls | cat | grep | head | tail | wc | echo | sleep | test | \[ | true) ;;
      # 0.20.0: read-only utilities that were missing from the vocabulary, so
      # a chain built from them (`… | sort -u`, `awk … | column -t`) fell to
      # the logged path on one unlisted segment.
      printf | pwd | sort | uniq | cut | tr | awk | jq | basename | dirname | \
        stat | date | diff | column | nl | rev | file | which | type)
        # `sort -o FILE` writes in place; everything else here cannot.
        case " $seg " in
          *" -o "*) return 1 ;;
        esac
        ;;
      # Control-flow keywords are inert (they run no command themselves); a
      # segment that IS one is read-only by construction. (`in` is never a
      # segment-first — `for f in …` splits on `;`, so `in` stays mid-segment.)
      # 0.23.0: `}` closes a group, `break`/`continue` steer a loop, and
      # `case`/`esac` bracket one — all inert, all reachable as a segment's
      # first word once a probe loop is written across lines.
      for | while | until | if | do | done | then | else | elif | fi | \
        "}" | break | continue | "case" | "esac") ;;
      # 0.23.0: read-only reachability probes. A bounded readiness loop
      # (`for i in $(seq 1 40); do curl …; sleep 3; done`) ends non-zero when
      # the service never came up — or when the Bash tool's own timeout kills
      # it, which is how the observed case arrived: cur-63-66, 2026-08-07
      # 01:17:41, a 40×3s poll cut at the tool's 120s default and surfaced as
      # is_error → exit 1. Either way that is the probe's ANSWER, not a command
      # failure; logging it as one buries real failures and walks the GUTTER
      # stuck-counter on a loop that was working correctly.
      lsof | pgrep | pidof | ps | ss | netstat | ping | dig | host | \
        nslookup | seq | hostname | uname | id) ;;
      curl)
        # Transfer flags are the write surface: `-O` names the output from the
        # URL, `-T/--upload-file` and any request body push data, and an
        # explicit method is a mutation of the far side no matter how it is
        # spelled. `-o` is a write UNLESS it discards, which is exactly the
        # `-o /dev/null -w %{http_code}` status-probe idiom.
        case " $seg " in
          *" -O "* | *" --remote-name "* | *" -T "* | *" --upload-file "* | \
            *" -d "* | *" --data"* | *" -F "* | *" --form"* | \
            *" -X "* | *" --request "*) return 1 ;;
        esac
        if printf '%s' " $seg " | grep -qE ' (-o|--output)[[:space:]]'; then
          printf '%s' " $seg " | grep -qE ' (-o|--output)[[:space:]]+/dev/null([[:space:]]|$)' || return 1
        fi
        ;;
      nc)
        # Port scan only — `-l` binds a listener, which is not a probe.
        case " $seg " in
          *" -l"*) return 1 ;;
          *" -z "*) ;;
          *) return 1 ;;
        esac
        ;;
      wget)
        # Writes a file by default; only the header-only probe qualifies.
        case " $seg " in
          *" --spider "*) ;;
          *) return 1 ;;
        esac
        ;;
      git)
        # 0.20.0: git is read-only in most of its interrogation forms, and
        # several of them exit 1 to ANSWER rather than to fail — `git diff
        # --quiet` (differences exist), `git check-ignore` (path not ignored),
        # `git grep` (no match). Those chains dominated the false SHELL FAIL
        # entries. Subcommand-gated: only the listed verbs qualify; anything
        # else under git (commit, add, checkout, push, clean, reset, …) keeps
        # the logged path.
        _split_subcommand "$seg"
        case "$_SUB1" in
          status | log | show | diff | branch | describe | blame | shortlog | \
            grep | ls-files | ls-tree | ls-remote | check-ignore | check-attr | \
            rev-parse | rev-list | merge-base | name-rev | cat-file | \
            for-each-ref | symbolic-ref | count-objects | verify-commit | var) ;;
          # Verbs that both read and write depending on form: read-only only
          # in their explicit list/get shape.
          worktree | stash | remote | config | tag | submodule | notes | bisect)
            case "$_SUB2" in
              list | status | show | log | -l | -v | --list | --get | --get-all | --get-regexp) ;;
              *) return 1 ;;
            esac
            ;;
          *) return 1 ;;
        esac
        ;;
      docker)
        # Same treatment: the inspection verbs only. `docker info`/`ps` exit
        # non-zero when the daemon is down, which is exactly what the
        # `docker info >/dev/null 2>&1 && … || …` probe idiom asks about.
        _split_subcommand "$seg"
        case "$_SUB1" in
          ps | info | images | inspect | logs | version | top | port | stats | \
            events | history | diff | search) ;;
          volume | network | image | container | system | node | context | \
            compose | buildx)
            case "$_SUB2" in
              ls | ps | inspect | config | logs | df | version | history | top) ;;
              *) return 1 ;;
            esac
            ;;
          *) return 1 ;;
        esac
        ;;
      find)
        # Read-only search only; reject filesystem-mutating / exec actions.
        case " $seg " in
          *" -exec "* | *" -execdir "* | *" -delete "* | *" -ok "* | *" -okdir "* | *" -fprint"* | *" -fls "*) return 1 ;;
        esac
        ;;
      sed)
        # Read-only stream edit only; reject in-place rewrites.
        case " $seg " in
          *" -i"* | *" --in-place"*) return 1 ;;
        esac
        ;;
      *) return 1 ;;
    esac
  done <<<"${normalized//;/$'\n'}"
  return 0
}

# Records one more failure of $1 and prints how many times it has failed
# since the last task boundary. One line per failure in FAILURES_FILE: the
# command base64-encoded with the wrapping removed, so a long command is one
# line, not several.
_count_repeat() {
  local key count
  key=$(printf '%s' "$1" | base64 | tr -d '\n')
  count=$(grep -cxF "$key" "$FAILURES_FILE" 2>/dev/null) || count=0
  echo "$key" >>"$FAILURES_FILE"
  echo $((count + 1))
}

# 0.26.0: a guard denial is not a failure of the command — the command never
# ran. It goes to errors.log under its own name with the guard's reason, so
# the next agent reads a policy answer rather than a red command. Repeats still
# count toward GUTTER: re-issuing a call the guard keeps refusing is stuck,
# whatever the reason.
#   $1 = what was denied (the command, or "WRITE <path>"), $2 = the reason
track_guard_deny() {
  local subject="$1" reason="$2"
  local count
  count=$(_count_repeat "$subject")
  log_error "GUARD DENY: $subject → $reason (attempt $count)"
  if [[ $count -ge $SHELL_FAIL_THRESHOLD ]]; then
    log_error "⚠️ GUTTER: same call denied ${count}x"
    echo "GUTTER" 2>/dev/null || true
  fi
}

track_shell_failure() {
  local cmd="$1"
  local exit_code="$2"
  if [[ $exit_code -ne 0 ]]; then
    # 0.14.7: skip expected-nonzero diagnostics entirely — no errors.log
    # entry, no FAILURES_FILE count. See _is_expected_nonzero_diagnostic.
    if _is_expected_nonzero_diagnostic "$cmd" "$exit_code"; then
      return 0
    fi
    local count
    count=$(_count_repeat "$cmd")
    log_error "SHELL FAIL: $cmd → exit $exit_code (attempt $count)"
    # When `git commit` fails (or `git add && git commit`), surface common
    # causes the agent might miss. Most common is staging a gitignored path
    # (e.g. anything under .ralph/) — git silently leaves the index empty
    # and the commit fails with a generic exit 1. Log a hint so the next
    # attempt isn't a blind retry.
    if [[ "$cmd" == *"git commit"* ]]; then
      # 0.14.5: only blame gitignored staging when a .ralph/ (or
      # acceptance-report) path is actually handed to `git add` — not merely
      # mentioned elsewhere in the compound command. A trailing
      # `ls .ralph/stop-requested` (a common stop-check idiom) would otherwise
      # trigger this hint on a commit that never staged anything under .ralph/.
      local _add_args=""
      if [[ "$cmd" == *"git add"* ]]; then
        _add_args="${cmd#*git add}"
        _add_args="${_add_args%%[;&|]*}"
      fi
      if [[ "$_add_args" == *".ralph/"* ]] || [[ "$_add_args" == *"acceptance-report"* ]]; then
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

# 0.14.5: Return 0 if `git commit` is the TERMINAL command of a (possibly
# compound) command string — i.e. the command's overall exit code is the
# commit's own. Return 1 when chained commands follow the commit
# (e.g. `git commit … && git log`, or `git commit … ; ls .ralph/stop-requested`),
# because then the overall exit code belongs to that trailing command, not the
# commit. This lets the caller avoid mis-attributing a trailing command's
# non-zero exit to the commit (the classic false "COMMIT FAILED" from a
# stop-check `ls` that exits 1 when the breadcrumbs are absent).
#
# Heuristic: everything after the last `commit` token is the "tail"; if it
# contains a shell separator (; && || |) followed by a non-space character, a
# trailing command exists. A `-m` message containing a separator can only
# soften a failing terminal commit to "status unknown" (the success path never
# consults this), so we accept that rare, harmless miss rather than parse shell
# quoting here.
_commit_is_terminal() {
  local tail="${1##*commit}"
  if [[ "$tail" =~ (\;|\&\&|\|\||\|)[[:space:]]*[^[:space:]] ]]; then
    return 1
  fi
  return 0
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
    # 0.14.7: write tempo alone is not stuckness. Observed GUTTER
    # false-positives were normal incremental TDD editing — many small
    # edits with passing test runs in between and zero failed commands
    # since the last task boundary. Require corroborating failure
    # evidence (FAILURES_FILE non-empty — at least one real shell
    # failure since the last successful commit) before escalating;
    # otherwise note the tempo in activity.log and keep going. Genuine
    # stuck-loops always have failing commands in the window, so this
    # only suppresses the all-green case.
    if [[ -s "$FAILURES_FILE" ]]; then
      log_error "THRASHING: $path written ${count}x in ${window_min} min"
      log_error "⚠️ GUTTER: file thrash on $path"
      echo "GUTTER" 2>/dev/null || true
    else
      log_activity "📝 WRITE TEMPO: $path written ${count}x in ${window_min} min (no failed commands since last commit — not thrash)"
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
      SESSION_INDEX=$((SESSION_INDEX + 1))
      if [[ $SESSION_INDEX -eq 1 ]]; then
        log_activity "SESSION START: model=$model"
      else
        # 0.24.1: a second init inside one loop is the CLI rotating its OWN
        # context (Claude Code auto-compaction) — Ralph's ROTATE never fired,
        # and the loop is still the same loop. Previously this logged as a bare
        # SESSION START, indistinguishable from a fresh loop and carrying no
        # reason, so a post-hoc evaluator could not tell why the session
        # restarted. Name it, and stamp the context state that explains it.
        local _pct=$((($(calc_tokens) * 100) / ROTATE_THRESHOLD))
        log_activity "🔄 CONTEXT RESTART (#$SESSION_INDEX): agent CLI rotated its own context at ~${_pct}% of the Ralph budget — model=$model"
      fi
      SESSION_TOKENS_BASE=$(calc_tokens)
      # 0.26.0: an API-reported context is one session's own — the session
      # that follows counts from its own first report, not from the figure it
      # inherits (which a CONTEXT RESTART has just made stale).
      [[ $REPORTED_TOKENS -gt 0 ]] && SESSION_TOKENS_BASE=0

      # Prefer LIVE counts from the resolved task file so the banner tracks
      # progress on every rotation; fall back to the static task-summary
      # snapshot only when no task file resolves.
      local ts_done ts_total ts_remaining task_file
      task_file=$(_sp_resolve_task_file) || task_file=""
      if [[ -n "$task_file" ]]; then
        ts_total=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[(x| )\]' "$task_file" 2>/dev/null) || ts_total=0
        ts_done=$(grep -cE '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[x\]' "$task_file" 2>/dev/null) || ts_done=0
        ts_remaining=$((ts_total - ts_done))
        if [[ "$ts_total" -gt 0 ]]; then
          local timestamp
          timestamp=$(date '+%H:%M:%S')
          echo "[$timestamp] 📋 Tasks: $ts_done/$ts_total complete ($ts_remaining remaining)" >>"$RALPH_DIR/activity.log"
          local task_line
          while IFS= read -r task_line; do
            [[ -z "$task_line" ]] && continue
            local cleaned
            cleaned=$(echo "$task_line" | sed 's/^[[:space:]]*/  /' | sed 's/\[ \]/☐/')
            wrap_line "[$timestamp]    " "$cleaned" >>"$RALPH_DIR/activity.log"
          done < <(grep -E '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+\[ \]' "$task_file" 2>/dev/null | head -10)
        fi
      else
        local summary_file="$RALPH_DIR/task-summary"
        if [[ -f "$summary_file" ]]; then
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
      fi
      ;;

    assistant_text)
      local text sc_text
      text=$(echo "$line" | jq -r '.text // empty' 2>/dev/null) || text=""
      sc_text=$(echo "$line" | jq -r '.sidechain // false' 2>/dev/null) || sc_text="false"
      if [[ -n "$text" ]]; then
        # 0.23.0: a sub-agent's reasoning lives in ITS window, never in the
        # orchestrator's — account it apart from the rotation budget. Signal
        # detection below is deliberately unchanged: who may say COMPLETE is a
        # separate question from whose context this is.
        if [[ "$sc_text" == "true" ]]; then
          SIDECHAIN_CHARS=$((SIDECHAIN_CHARS + ${#text}))
        else
          ASSISTANT_CHARS=$((ASSISTANT_CHARS + ${#text}))
        fi
        if [[ "$text" == *"<ralph>COMPLETE</ralph>"* ]] ||
          [[ "$text" == *"<promise>ALL_TASKS_DONE</promise>"* ]]; then
          log_activity "✅ Agent signaled COMPLETE"
          echo "COMPLETE" 2>/dev/null || true
        fi
        if [[ "$text" == *"<ralph>GUTTER"*"</ralph>"* ]]; then
          # 0.18.0: structured gutter reason. The agent may qualify the signal
          # as `<ralph>GUTTER reason=<slug></ralph>` (or `GUTTER: <text>`), so a
          # supervisor around the loop can classify a mechanically-recoverable
          # gutter (e.g. `concurrent-writer`) from one that needs a human. The
          # bare `<ralph>GUTTER</ralph>` form still works — reason stays empty.
          local graw reason
          graw="${text#*<ralph>GUTTER}"
          graw="${graw%%</ralph>*}"
          graw="${graw#"${graw%%[![:space:]]*}"}" # ltrim
          graw="${graw#reason=}"
          graw="${graw#:}"
          graw="${graw#"${graw%%[![:space:]]*}"}" # ltrim after stripping prefix
          graw="${graw%"${graw##*[![:space:]]}"}" # rtrim
          graw="${graw//$'\n'/ }"                 # single line
          reason="${graw:0:200}"
          if [[ -n "$reason" ]]; then
            printf '%s' "$reason" >"$RALPH_DIR/gutter-reason" 2>/dev/null || true
            log_activity "🚨 Agent signaled GUTTER (stuck) — reason: $reason"
          else
            log_activity "🚨 Agent signaled GUTTER (stuck)"
          fi
          echo "GUTTER" 2>/dev/null || true
        fi
      fi
      ;;

    tool_use)
      TOOL_CALL_COUNT=$((TOOL_CALL_COUNT + 1))
      ;;

    adapter_error)
      # 0.26.2: agent-adapter.sh skipped an event it could not read, and the
      # stream carried on. Recorded because a CLI that changed its event shape
      # shows up here first.
      local adapter_msg
      adapter_msg=$(echo "$line" | jq -r '.message // "unknown"' 2>/dev/null) || adapter_msg="unknown"
      log_error "ADAPTER: skipped an event it could not read — $adapter_msg"
      ;;

    usage)
      local ctx
      ctx=$(echo "$line" | jq -r '.context_tokens // 0' 2>/dev/null) || ctx=0
      if [[ "$ctx" =~ ^[0-9]+$ ]] && [[ $ctx -gt 0 ]]; then
        # The first report replaces the byte estimate for this session outright.
        [[ $REPORTED_TOKENS -eq 0 ]] && SESSION_TOKENS_BASE=0
        REPORTED_TOKENS=$ctx
        _sum_bytes
        REPORTED_AT_BYTES=$TOTAL_BYTES
        # The report alone can cross a threshold — a long thinking turn grows
        # the context with no tool result in between.
        check_gutter
      fi
      ;;

    tool_result)
      local name bytes lines exit_code path cmd sidechain acct denied deny_reason
      name=$(echo "$line" | jq -r '.name // "Other"' 2>/dev/null) || name="Other"
      bytes=$(echo "$line" | jq -r '.bytes // 0' 2>/dev/null) || bytes=0
      lines=$(echo "$line" | jq -r '.lines // 0' 2>/dev/null) || lines=0
      exit_code=$(echo "$line" | jq -r '.exit_code // 0' 2>/dev/null) || exit_code=0
      path=$(echo "$line" | jq -r '.path // ""' 2>/dev/null) || path=""
      cmd=$(echo "$line" | jq -r '.cmd // ""' 2>/dev/null) || cmd=""
      sidechain=$(echo "$line" | jq -r '.sidechain // false' 2>/dev/null) || sidechain="false"
      # 0.26.0: the guard refused the call — nothing ran, nothing was written.
      denied=$(echo "$line" | jq -r '.denied // false' 2>/dev/null) || denied="false"
      deny_reason=""
      if [[ "$denied" == "true" ]]; then
        deny_reason=$(echo "$line" | jq -r '.deny_reason // ""' 2>/dev/null) || deny_reason=""
      fi

      # 0.23.0: a Task sub-agent's bytes are ITS context, not this session's.
      # Route them to SIDECHAIN_CHARS and zero the ACCOUNTING figure, so every
      # accumulator below adds nothing while the activity line still reports the
      # real size and `track_file_write` / `track_shell_failure` still fire — a
      # sub-agent's edits and failures are as real as the orchestrator's, and
      # only the rotation budget was ever wrong here.
      acct=$bytes
      if [[ "$sidechain" == "true" ]]; then
        SIDECHAIN_CHARS=$((SIDECHAIN_CHARS + bytes))
        acct=0
      fi

      case "$name" in
        Read)
          BYTES_READ=$((BYTES_READ + acct))
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
          BYTES_WRITTEN=$((BYTES_WRITTEN + acct))
          local kb=$((bytes / 1024))
          if [[ "$denied" == "true" ]]; then
            log_activity "EDIT $path → denied by guard"
            track_guard_deny "EDIT $path" "$deny_reason"
          else
            log_activity "EDIT $path (${lines} lines, ${kb}KB)"
            track_file_write "$path"
          fi
          ;;
        Write)
          BYTES_WRITTEN=$((BYTES_WRITTEN + acct))
          local kb=$((bytes / 1024))
          if [[ "$denied" == "true" ]]; then
            log_activity "WRITE $path → denied by guard"
            track_guard_deny "WRITE $path" "$deny_reason"
          else
            log_activity "WRITE $path (${lines} lines, ${kb}KB)"
            track_file_write "$path"
          fi
          ;;
        Shell)
          SHELL_OUTPUT_CHARS=$((SHELL_OUTPUT_CHARS + acct))
          if [[ "$denied" == "true" ]]; then
            # 0.26.0: never ran, so not a SHELL FAIL, a COMMIT FAILED, or a
            # PUSH FAILED — the guard already logged why as ⛔ GUARD DENY.
            log_activity "SHELL $cmd → denied by guard"
            track_guard_deny "$cmd" "$deny_reason"
          # 0.5.4: anchor the `git commit` and `git push` matches to either
          # start-of-string OR a shell separator (whitespace, &, ;, |, `(`).
          # 0.10.4: allow global flags between `git` and the subcommand
          # (e.g. `git -C /path commit`). Each flag is -<letter> <value>.
          elif [[ "$cmd" =~ (^|[[:space:]\&\;\|\(])git([[:space:]]+-[[:alpha:]][[:space:]]+[^[:space:]]+)*[[:space:]]+commit ]]; then
            local commit_msg=""
            if [[ "$cmd" =~ -m[[:space:]]+[\"\']([^\"\']+)[\"\'] ]]; then
              commit_msg="${BASH_REMATCH[1]}"
            elif [[ "$cmd" =~ -m[[:space:]]+([^[:space:]]+) ]]; then
              commit_msg="${BASH_REMATCH[1]}"
            fi
            local commit_label="COMMIT (via $cmd)"
            [[ -n "$commit_msg" ]] && commit_label="COMMIT \"$commit_msg\""
            if [[ $exit_code -eq 0 ]]; then
              # Whole command exited 0 → the commit ran and succeeded.
              log_activity "$commit_label"
              reset_failure_counters_on_task_boundary
            elif _commit_is_terminal "$cmd"; then
              # 0.14.5: `git commit` is the last command in the chain, so the
              # non-zero exit code is the commit's own — a genuine failure.
              log_activity "COMMIT FAILED $cmd → exit $exit_code"
              track_shell_failure "$cmd" "$exit_code"
            else
              # 0.14.5: trailing commands follow the commit in the chain
              # (e.g. `git commit … ; ls .ralph/stop-requested`). The overall
              # exit code is the trailing command's, NOT the commit's, so we
              # cannot call this a commit failure — record it as unknown rather
              # than fire a false COMMIT FAILED (which would also bump the
              # shell-failure counter toward GUTTER and emit a bogus hint).
              log_activity "$commit_label (compound exit=$exit_code; commit status unknown — trailing command in chain)"
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
          elif _is_self_limited_cutoff "$cmd" "$exit_code"; then
            # 0.24.0: the command set its own cutoff and the cutoff fired.
            # Visible, but not a verdict — no errors.log entry, no walk of the
            # GUTTER stuck-counter. See _is_self_limited_cutoff.
            log_activity "⏱ SHELL CUT OFF $cmd → exit $exit_code (own cutoff fired; no verdict)"
          else
            log_activity "SHELL $cmd → exit $exit_code"
            track_shell_failure "$cmd" "$exit_code"
          fi
          # 0.10.0: gate-fail-streak tracking for TURN_END signal.
          # 0.12.0: also write the ## Last gate state section of handoff.md
          # on every gate-end (pass or fail) so the next loop has fresh state.
          # 0.24.0: both now key on the gate's OWN end-of-run marker rather
          # than on `gate-run.sh` appearing in the model's command — the
          # guard's auto-wrap means it never does. See _drain_gate_event.
          # The label no longer needs the 0.12.4 canonical-set guard either:
          # it comes from gate-run.sh as a field, not from parsing a command
          # line where `2>&1` could be mistaken for one.
          _drain_gate_event
          ;;
        *)
          # Unknown tool — count bytes as assistant output to keep
          # accounting conservative, no activity line.
          ASSISTANT_CHARS=$((ASSISTANT_CHARS + acct))
          ;;
      esac

      [[ "$denied" == "true" ]] || _check_handoff_working_set "$path $cmd"
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
          # Hand the reset time to the loop's DEFER handler, which waits for it
          # instead of running the escalating backoff. Without this the epoch
          # was printed and discarded, so the generic backoff (max 300s, stall
          # ceiling 10 ≈ 33 min of waiting) always expired first on a
          # multi-hour subscription limit and the run died as a STALL.
          printf '%s\n' "$resets_at" >"$RALPH_DIR/rate-limit-resets-at" 2>/dev/null || true
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
      local tokens session_tokens
      tokens=$(calc_tokens)
      # 0.24.1: this session's own usage, not the loop-to-date total.
      session_tokens=$((tokens - SESSION_TOKENS_BASE))
      [[ $session_tokens -lt 0 ]] && session_tokens=0
      SESSION_TOKENS_BASE=$tokens
      log_activity "SESSION END: ${duration}ms, ~$session_tokens tokens this session (~$tokens loop total)"

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

  # Settle the working set's baseline before the agent can touch it, and catch
  # a rewrite the previous loop made after its last look.
  _check_handoff_working_set "handoff.md"

  while IFS= read -r line; do
    process_line "$line"
    local now
    now=$(date +%s)
    if [[ $((now - last_token_log)) -ge 30 ]]; then
      log_token_status
      last_token_log=$now
    fi
  done

  # The stream ended — catch a last rewrite before the loop renders its age.
  _check_handoff_working_set "handoff.md"
  log_token_status
}

main
