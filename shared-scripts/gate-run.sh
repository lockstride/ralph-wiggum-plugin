#!/bin/bash
# Ralph Wiggum: Gate runner wrapper
#
# Executes a gate command (typically `pnpm all-check`, `pnpm test-e2e:local`,
# etc.), persists the full output to .ralph/gates/<label>-<ts>.log, maintains
# a .ralph/gates/<label>-latest.log pointer, and prints a bounded,
# deterministic summary to stdout.
#
# 0.16.0: detached-runner architecture. The gate command no longer runs
# inside the caller's process tree. Every invocation splits into:
#
#   launcher — validates, acquires the per-label lock, detaches a RUNNER
#              into its own session, then becomes a WAITER.
#   runner   — the detached process that actually executes the gate, owns
#              the lock for the gate's lifetime, and writes every breadcrumb
#              (including on signal death). Immune to the caller being
#              killed: agent Bash-call timeouts, subagent-return reaps,
#              tmux kills, and loop rotations cannot reach it (own session,
#              reparented to init from birth).
#   waiter   — blocks on the per-run exit breadcrumb up to RALPH_GATE_WAIT
#              seconds. Verdict lands: prints the normal summary, exits
#              with the real gate code — indistinguishable from foreground
#              execution. Budget elapses: prints STILL RUNNING, exits 75;
#              re-running the SAME command joins the in-flight gate.
#
# The wrapped command runs under the runner in its own process group with a
# watchdog timeout, so the real exit code is preserved and hung gates are
# killed subtree-wide (0.6.3 semantics preserved).
#
# Usage:
#   gate-run.sh <label> <cmd> [args...]
#
#   <label> MUST be one of:
#     tier labels: basic | full | final  (the three tier-gate commands declared
#                  in .ralph/command-policy [gates])
#     kind labels: unit | integration | e2e | lint | format  (everything else
#                  the agent might invoke; routed via [wrap])
#
# Exit code:
#   The real exit code of <cmd> when the verdict lands within the wait
#   budget. 75 while the gate is in flight (re-run to keep waiting). 70 if
#   the runner died without a verdict. See --help for the full table.
#
# Output:
#   Compact summary to stdout (<= ~150 lines), full log on disk.
#
# Environment:
#   RALPH_GATES_DIR       Override .ralph/gates/ location (default: ./.ralph/gates).
#   RALPH_GATE_KEEP       Per-label log retention count (default: 10).
#   RALPH_GATE_TAIL       Lines of tail to include in summary (default: 60).
#   RALPH_GATE_FAIL_HEAD  Lines of failure-match output in summary (default: 80).
#   RALPH_GATE_WAIT       Waiter budget in seconds (default: 570).

set -euo pipefail

# -----------------------------------------------------------------------------
# Help / usage
# -----------------------------------------------------------------------------

_print_help() {
  cat <<'HELP'
gate-run.sh — wrapper for verification gates (tests, lint, build, etc.)

USAGE
  gate-run.sh <label> <cmd> [args...]
  gate-run.sh -h | --help

WHY
  A gate command run bare makes diagnosis expensive: pipes hide exit codes,
  large output blows past your terminal scrollback (or an agent's context
  window), and a re-run is needed to see more of the failure. Worse, a gate
  run inside an agent's shell call dies with that call: tool timeouts and
  subagent lifecycle kills turn healthy gates into false failures. This
  wrapper fixes both in one step:
    • Detaches the gate into its own session — nothing that kills the
      calling shell (tool timeout, subagent return, tmux exit) can reach it
    • Captures the command's combined stdout/stderr to
      .ralph/gates/<label>-<ts>.log
    • Waits up to RALPH_GATE_WAIT (default 570 s) for the verdict; when it
      lands, prints a bounded summary (header + tail + failure-pattern
      matches) and exits with the real command status
    • If the gate outlives the wait budget, prints STILL RUNNING and exits
      75 — re-run the SAME command to keep waiting (it joins the in-flight
      gate; it never double-runs)
    • Writes exit-code breadcrumbs at .ralph/gates/<label>-latest.exit and
      per-run at .ralph/gates/<label>-<ts>.exit — on EVERY outcome,
      including the runner being signalled (143) — plus a command
      breadcrumb at .ralph/gates/<label>-latest.cmd
    • Maintains a .ralph/gates/<label>-latest.log pointer for quick reading

LABELS (fixed set — pick the closest match)
  Tier labels — exactly one command each, declared in [gates] in
  .ralph/command-policy. The tier-command label-lock requires these
  commands to run under their own tier label:
    basic   Per-task pre-commit gate (typically format + lint + unit).
    full    Implementation-loop completion gate (basic + integration + e2e).
    final   Eval-loop gate (post-completion acceptance verification).

  Kind labels — many commands, routed via [wrap] in command-policy:
    unit         Unit test runs.
    integration  Integration test runs.
    e2e          Targeted E2E / browser / container suites.
    lint         Lint-only / type-check-only runs.
    format       Format-only runs.

  All labels share the same default 1200 s gate timeout. Tier overrides:
  RALPH_BASIC_GATE_TIMEOUT, RALPH_FULL_GATE_TIMEOUT, RALPH_FINAL_GATE_TIMEOUT.

EXAMPLES
  # tier gates (project supplies the actual commands via [gates])
  gate-run.sh basic <project basic-tier command>
  gate-run.sh full  <project full-tier command>
  gate-run.sh final <project final-tier command>
  # kind labels (free-form routing)
  gate-run.sh e2e  <project e2e command>
  gate-run.sh lint <project lint command>

EXIT CODES
  0       The wrapped command exited 0.
  N≠0     The wrapped command exited N. Passed through verbatim.
  64      Usage error (missing args, invalid label).
  70      The detached runner died without writing a verdict (hard kill,
          crash, machine sleep). The lock is cleaned; re-run to relaunch
          the gate fresh.
  75      Gate in flight — still running past the wait budget, OR a
          different command already holds this label. No verdict
          breadcrumb is written. Re-run the same command to continue
          waiting for the in-flight gate.
  124     The wrapped command exceeded its gate timeout (GNU/BSD 'timeout'
          convention).
  143     The runner was signalled (TERM/INT/HUP) mid-gate and shut the
          gate subtree down. Recorded in the breadcrumb — distinguishable
          from a real gate failure.

ENVIRONMENT
  RALPH_WORKSPACE       Workspace root (default: $PWD). Logs land under
                        $RALPH_WORKSPACE/.ralph/gates/.
  RALPH_GATES_DIR       Full override for the log directory
                        (default: $RALPH_WORKSPACE/.ralph/gates).
  RALPH_GATE_KEEP       Per-label log retention count (default 10).
  RALPH_GATE_TAIL       Lines of tail included in the summary (default 60).
  RALPH_GATE_FAIL_HEAD  Failure-match lines in the summary (default 80).
  RALPH_GATE_WAIT       Waiter budget in seconds (default 570 — under the
                        600 s ceiling of an agent Bash call). 0 = detach
                        and return 75 immediately (pure async).
  RALPH_GATE_TIMEOUT    Blanket gate timeout override (seconds) for any
                        label. Takes precedence over the per-label vars.
  RALPH_BASIC_GATE_TIMEOUT  Timeout for tier label 'basic' (default 1200).
                            Also used for the kind labels (unit/integration/
                            e2e/lint/format) — they're targeted runs and
                            share the basic-tier timeout budget.
  RALPH_FULL_GATE_TIMEOUT   Timeout for tier label 'full'  (default 1200).
  RALPH_FINAL_GATE_TIMEOUT  Timeout for tier label 'final' (default 1200).

FAILURE-PATTERN MATCHING
  On completion the wrapper greps the log for common failure signatures
  (vitest / jest / cypress / tsc / eslint / nestjs / generic stack traces)
  and prints up to RALPH_GATE_FAIL_HEAD line-numbered matches. This helps
  an agent find the failing site without re-running the gate. The regex is
  line-anchored and Node/TS-biased today; non-Node ecosystems may want to
  wrap this script or tail the full log directly.

AGENT PROTOCOL (also documented in docs/gate-run.md)
  1. Run every gate via this wrapper — never bare, never piped, never
     redirected, never with run_in_background. Call it in the FOREGROUND
     with a generous tool timeout (600000 ms). The gate itself is immune
     to your call being killed.
  2. If it exits 75 (STILL RUNNING), immediately re-run the exact same
     command — it joins the in-flight gate and keeps waiting. Repeat until
     a verdict prints. Do not switch labels, do not touch the lock, do not
     try to start a second copy — 75 means the gate is healthy and running.
  3. When a gate fails: do NOT re-run it. Read .ralph/gates/<label>-latest.log
     with offset/limit reads or targeted grep, fix the smallest thing, then
     re-run once.
  4. When a gate passes: do NOT re-read the log. The summary already printed
     everything you need. Commit and move on.

See docs/gate-run.md for the full specification.
HELP
}

# -----------------------------------------------------------------------------
# Argument validation
# -----------------------------------------------------------------------------

if [[ $# -eq 1 ]] && [[ "$1" == "-h" || "$1" == "--help" ]]; then
  _print_help
  exit 0
fi

if [[ $# -lt 2 ]]; then
  echo "usage: gate-run.sh <label> <cmd> [args...]" >&2
  echo "  <label> in: basic | full | final | unit | integration | e2e | lint | format" >&2
  echo "  run 'gate-run.sh --help' for details" >&2
  exit 64
fi

label="$1"
shift

# Agents sometimes quote the whole command as a single arg:
#   gate-run.sh basic "pnpm basic-check"   →  $@ = ("pnpm basic-check")
# Word-split it so ("$@") executes correctly.
if [[ $# -eq 1 && "$1" == *" "* ]]; then
  # shellcheck disable=SC2086
  set -- $1
fi

case "$label" in
  basic | full | final | unit | integration | e2e | lint | format) ;;
  *)
    echo "gate-run.sh: invalid label '$label' (expected basic|full|final|unit|integration|e2e|lint|format)" >&2
    echo "  run 'gate-run.sh --help' for details" >&2
    exit 64
    ;;
esac

# -----------------------------------------------------------------------------
# Paths and knobs
# -----------------------------------------------------------------------------

workspace="${RALPH_WORKSPACE:-$PWD}"
gates_dir="${RALPH_GATES_DIR:-$workspace/.ralph/gates}"
keep="${RALPH_GATE_KEEP:-10}"
tail_lines="${RALPH_GATE_TAIL:-60}"
fail_head="${RALPH_GATE_FAIL_HEAD:-80}"
wait_budget="${RALPH_GATE_WAIT:-570}"

mkdir -p "$gates_dir"

# Absolute path to this script, for re-exec as the detached runner.
_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# Normalized command string — the .cmd breadcrumb, the lock's cmd record,
# and join-matching (same-command re-runs attach to the in-flight gate
# instead of double-running) all compare this form.
_cmd_norm=$(printf '%s' "$*" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')

_lock_dir="$gates_dir/.${label}.lock"
latest_link="$gates_dir/${label}-latest.log"

# -----------------------------------------------------------------------------
# Activity log helper (best-effort; wrapper must not fail if .ralph missing)
# -----------------------------------------------------------------------------

_activity_log="$workspace/.ralph/activity.log"
_log_activity() {
  [[ -d "$workspace/.ralph" ]] || return 0
  local stamp
  stamp=$(date '+%H:%M:%S')
  printf '[%s] %s\n' "$stamp" "$1" >>"$_activity_log" 2>/dev/null || true
}

# 0.10.0: Gate-without-write and post-failure diagnosis checks are enforced
# by the PreToolUse hook (ralph-guard.sh), which runs before the agent can
# even invoke gate-run.sh.

# -----------------------------------------------------------------------------
# Gate timeout resolution (used by the runner; resolved for both roles so
# the launcher's STILL RUNNING message can cite it)
# -----------------------------------------------------------------------------

# 0.7.0: all labels default to 20 min (1200 s) — sized to ~2× the observed
# red-state tail of real monorepo suites. Projects can override per tier or
# via the blanket var. (Sizing history 0.3.5→0.7.0 lives in git.)
if [[ -n "${RALPH_GATE_TIMEOUT:-}" ]]; then
  gate_timeout="$RALPH_GATE_TIMEOUT"
else
  case "$label" in
    full) gate_timeout="${RALPH_FULL_GATE_TIMEOUT:-1200}" ;;
    final) gate_timeout="${RALPH_FINAL_GATE_TIMEOUT:-1200}" ;;
    *) gate_timeout="${RALPH_BASIC_GATE_TIMEOUT:-1200}" ;;
  esac
fi

RALPH_GATE_KILL_GRACE="${RALPH_GATE_KILL_GRACE:-10}"

# -----------------------------------------------------------------------------
# Shared: bounded verdict summary printed by the waiter (and joiners)
# -----------------------------------------------------------------------------

# Args: $1 exit code, $2 log file, $3 duration ("?" if unknown)
_print_verdict() {
  local code="$1" log="$2" duration="$3"
  local rel_log rel_latest
  rel_log="${log#"$workspace"/}"
  rel_latest="${latest_link#"$workspace"/}"

  printf '=== GATE %s exit=%s duration=%ss log=%s latest=%s ===\n' \
    "$label" "$code" "$duration" "$rel_log" "$rel_latest"

  printf -- '--- tail (last %s lines) ---\n' "$tail_lines"
  tail -n "$tail_lines" "$log" 2>/dev/null || true

  printf -- '--- failing-tests (first %s matches) ---\n' "$fail_head"
  # Common failure signatures across vitest, jest, cypress, tsc, eslint,
  # nestjs, and generic stack traces. Line-anchored to minimize false
  # positives.
  grep -n -E \
    '^\s*(FAIL|✗|× |Error:|AssertionError|TypeError|ReferenceError|SyntaxError|\s+at\s|expected|Expected|    [0-9]+\)|ERROR in|error TS[0-9]+|error\s+@|✖ )' \
    "$log" 2>/dev/null | head -n "$fail_head" || true

  printf '=== END GATE ===\n'
}

# Extract the runner's end-marker duration from a log ("?" when absent).
_log_duration() {
  local log="$1" d
  d=$(grep -oE '^=== gate-run end exit=[0-9]+ duration=[0-9]+s' "$log" 2>/dev/null |
    tail -1 | grep -oE 'duration=[0-9]+' | cut -d= -f2) || true
  printf '%s' "${d:-?}"
}

# -----------------------------------------------------------------------------
# Shared: wait for a specific run's verdict breadcrumb
# -----------------------------------------------------------------------------

# Blocks until $gates_dir/${label}-${ts}.exit appears, the runner dies, or
# the wait budget elapses. Prints the verdict / diagnosis and RETURNS the
# exit code this invocation should end with.
#
# Args: $1 run ts, $2 runner pid, $3 "joined"|"launched"
_wait_for_verdict() {
  local ts="$1" runner_pid="$2" how="$3"
  local exit_file="$gates_dir/${label}-${ts}.exit"
  local run_log="$gates_dir/${label}-${ts}.log"
  local waited=0 dead_grace=0

  while :; do
    if [[ -f "$exit_file" ]]; then
      local code duration
      code=$(cat "$exit_file" 2>/dev/null || echo 70)
      duration=$(_log_duration "$run_log")
      _print_verdict "$code" "$run_log" "$duration"
      return "$code"
    fi

    # Runner liveness. A dead runner with no verdict after a short grace
    # (covers the write-verdict-then-exit window) is a hard death: clean
    # the lock so a re-run can relaunch, and say so distinctly (70).
    # An empty/garbage pid (lock already cleaned) counts as dead.
    if ! { [[ "$runner_pid" =~ ^[0-9]+$ ]] && kill -0 "$runner_pid" 2>/dev/null; }; then
      dead_grace=$((dead_grace + 1))
      if [[ $dead_grace -ge 3 ]]; then
        # Re-check: the verdict may have landed in the grace window.
        if [[ -f "$exit_file" ]]; then
          continue
        fi
        printf '=== GATE %s RUNNER DIED without a verdict (pid=%s) log=%s ===\n' \
          "$label" "$runner_pid" "${run_log#"$workspace"/}"
        printf -- '--- last output before death ---\n'
        tail -n 20 "$run_log" 2>/dev/null || true
        printf 'The gate did not finish and wrote no breadcrumb (hard kill or crash).\n'
        printf 'Re-run the same command to relaunch it fresh.\n'
        _log_activity "🧪 GATE runner died label=$label pid=$runner_pid without verdict"
        rm -rf "$_lock_dir" 2>/dev/null || true
        return 70
      fi
    else
      dead_grace=0
    fi

    if [[ $waited -ge $wait_budget ]]; then
      printf '=== GATE %s STILL RUNNING pid=%s waited=%ss (gate timeout %ss) log=%s ===\n' \
        "$label" "$runner_pid" "$waited" "$gate_timeout" "${run_log#"$workspace"/}"
      printf 'The gate is healthy and keeps running — it is detached and cannot be\n'
      printf 'killed by this call ending. Re-run the exact same command to continue\n'
      printf 'waiting; the verdict lands in %s (and -latest.exit).\n' \
        "${exit_file#"$workspace"/}"
      _log_activity "🧪 GATE wait label=$label still running after ${waited}s (runner pid=$runner_pid, $how)"
      return 75
    fi

    sleep 1
    waited=$((waited + 1))
  done
}

# =============================================================================
# RUNNER ROLE — the detached process that actually executes the gate
# =============================================================================

if [[ "${RALPH_GATE_ROLE:-}" == "runner" ]]; then
  ts="${RALPH_GATE_TS:?runner requires RALPH_GATE_TS}"
  log_file="$gates_dir/${label}-${ts}.log"
  exit_file="$gates_dir/${label}-${ts}.exit"

  # Claim the lock: overwrite the launcher's pid with our own so contenders
  # and waiters track the process whose lifetime IS the gate's.
  echo $$ >"$_lock_dir/pid" 2>/dev/null || true
  date +%s >"$_lock_dir/epoch" 2>/dev/null || true

  cmd_status=""
  cmd_pid=""

  # Breadcrumb writer — called on every outcome so a verdict always exists
  # afterwards (modulo SIGKILL, which the waiter detects as 70).
  _write_breadcrumbs() {
    local code="$1"
    rm -f "$latest_link"
    ln -s "$(basename "$log_file")" "$latest_link" 2>/dev/null ||
      cp "$log_file" "$latest_link" 2>/dev/null || true
    # 0.3.3 / 0.6.4 breadcrumbs, consumed by the loop's COMPLETE guard and
    # the tier-command label-lock.
    printf '%s' "$code" >"$gates_dir/$label-latest.exit"
    printf '%s' "$_cmd_norm" >"$gates_dir/$label-latest.cmd"
    if [[ "$code" -ne 0 ]]; then
      # 0.10.0: last-failed breadcrumbs for the TURN_END handler.
      printf '%s' "$label" >"$gates_dir/last-failed-label"
      printf '%s' "${latest_link#"$workspace"/}" >"$gates_dir/last-failed-log"
      # 0.13.1: pointer-only structured summary (stream-parser copies it
      # into handoff.md's "Last gate state"). Capped at ~2KB.
      {
        printf 'label: %s\n' "$label"
        printf 'exit: %s\n' "$code"
        printf 'duration: %ss\n' "$(_log_duration "$log_file")"
        printf 'log: %s\n' "${latest_link#"$workspace"/}"
        printf 'cmd: %s\n' "$_cmd_norm"
        if grep -q '^=== coverage gaps ===' "$log_file" 2>/dev/null; then
          printf '\ncoverage_gaps:\n'
          awk '/^=== coverage gaps ===/{flag=1;next} /^=== /{flag=0} flag' \
            "$log_file" 2>/dev/null | head -n 30
        fi
      } >"$gates_dir/$label-latest.summary"
      local summary_bytes
      summary_bytes=$(wc -c <"$gates_dir/$label-latest.summary" 2>/dev/null | tr -d ' ')
      if [[ -n "$summary_bytes" && "$summary_bytes" -gt 2048 ]]; then
        head -c 2000 "$gates_dir/$label-latest.summary" >"$gates_dir/$label-latest.summary.tmp"
        printf '\n[truncated — see %s]\n' "${latest_link#"$workspace"/}" \
          >>"$gates_dir/$label-latest.summary.tmp"
        mv "$gates_dir/$label-latest.summary.tmp" "$gates_dir/$label-latest.summary"
      fi
    else
      # On success, remove any stale summary so the agent's view matches
      # reality.
      rm -f "$gates_dir/$label-latest.summary"
    fi
    # Per-run exit file LAST — it is the waiter's commit signal.
    printf '%s' "$code" >"$exit_file"
  }

  # Signal hardening: TERM/INT/HUP takes the gate subtree down cleanly and
  # records a distinguishable verdict (143) instead of leaving an absence
  # the agent has to infer from pgrep.
  # shellcheck disable=SC2329  # invoked indirectly via trap
  _runner_signalled() {
    trap '' TERM INT HUP # no re-entry while shutting down
    if [[ -n "$cmd_pid" ]]; then
      kill -TERM -- "-$cmd_pid" 2>/dev/null || true
      sleep "$RALPH_GATE_KILL_GRACE" 2>/dev/null || true
      kill -KILL -- "-$cmd_pid" 2>/dev/null || true
    fi
    printf '\n=== gate-run runner signalled — gate stopped ===\n' >>"$log_file" 2>/dev/null || true
    _write_breadcrumbs 143
    _log_activity "🧪 GATE end label=$label exit=143 (runner signalled) log=${latest_link#"$workspace"/}"
    rm -rf "$_lock_dir" 2>/dev/null || true
    trap - EXIT
    exit 143
  }
  trap _runner_signalled TERM INT HUP

  # EXIT backstop: a script bug (set -e abort) must still leave a verdict.
  # shellcheck disable=SC2329  # invoked indirectly via trap
  _runner_exit() {
    if [[ ! -f "$exit_file" ]]; then
      printf '\n=== gate-run runner aborted internally ===\n' >>"$log_file" 2>/dev/null || true
      _write_breadcrumbs 70
      _log_activity "🧪 GATE end label=$label exit=70 (runner aborted) log=${latest_link#"$workspace"/}"
    fi
    rm -rf "$_lock_dir" 2>/dev/null || true
  }
  trap _runner_exit EXIT

  _log_activity "🧪 GATE start label=$label cmd=$(printf '%q ' "$@")"

  # 0.15.1: anchor gate execution at the workspace root (guard rewrites can
  # strip a load-bearing `cd` prefix; root-scoped pnpm scripts fast-fail
  # from a stray cwd).
  if [[ -d "$workspace" ]]; then
    cd "$workspace" || {
      echo "gate-run.sh: cannot cd to workspace '$workspace'" >&2
      exit 126
    }
  fi

  start_epoch=$(date +%s)

  # Run the gate in its own process group (set -m job control — portable
  # across bash 3.2 and 5.x) with a watchdog that signals the whole group
  # on timeout: SIGTERM, grace, then SIGKILL (0.6.3 semantics). Output goes
  # straight to the log — the runner has no live stdout; the waiter prints
  # the bounded summary from the log when the verdict lands. (The pre-0.16
  # fifo/tee plumbing existed only to preserve live stdout and is gone.)
  set -m
  ("$@" >>"$log_file" 2>&1) &
  cmd_pid=$!
  set +m

  (
    # NOTE: plain assignments — `local` is invalid outside a function and
    # would silently break the loop under set +e.
    elapsed=0
    while [[ $elapsed -lt $gate_timeout ]]; do
      kill -0 "$cmd_pid" 2>/dev/null || exit 0
      sleep 1
      elapsed=$((elapsed + 1))
    done
    kill -TERM -- "-$cmd_pid" 2>/dev/null || true
    grace=0
    while [[ $grace -lt $RALPH_GATE_KILL_GRACE ]]; do
      kill -0 "$cmd_pid" 2>/dev/null || exit 0
      sleep 1
      grace=$((grace + 1))
    done
    kill -KILL -- "-$cmd_pid" 2>/dev/null || true
  ) &
  watchdog_pid=$!

  set +e
  wait "$cmd_pid"
  cmd_status=$?
  set -e

  if kill -0 "$watchdog_pid" 2>/dev/null; then
    kill "$watchdog_pid" 2>/dev/null || true
  fi
  wait "$watchdog_pid" 2>/dev/null || true

  # Belt-and-braces: kill anything left in the gate's pgroup (lingering
  # cypress/electron etc.). Idempotent no-op after a clean exit.
  kill -KILL -- "-$cmd_pid" 2>/dev/null || true

  # Normalize signal-death of the WRAPPED command to the conventional
  # timeout exit (124), matching GNU timeout(1).
  if [[ $cmd_status -eq 143 ]] || [[ $cmd_status -eq 137 ]]; then
    cmd_status=124
  fi

  end_epoch=$(date +%s)
  duration=$((end_epoch - start_epoch))

  if [[ $cmd_status -eq 124 ]]; then
    printf '\n⏰ Gate timed out after %ss (RALPH_GATE_TIMEOUT=%s)\n' \
      "$gate_timeout" "$gate_timeout" >>"$log_file"
    _log_activity "🧪 GATE TIMEOUT label=$label after ${gate_timeout}s"
  fi

  # Machine-readable end marker (the waiter reads duration from it).
  printf '=== gate-run end exit=%s duration=%ss ===\n' "$cmd_status" "$duration" >>"$log_file"

  # Retention: keep only the most recent $keep logs (and their per-run
  # exit files) for this label. bash-3.2-safe read-loop (no mapfile on
  # macOS /bin/bash).
  if [[ "$keep" -gt 0 ]]; then
    _old_logs=()
    while IFS= read -r _line; do
      [[ -n "$_line" ]] && _old_logs+=("$_line")
    done < <(
      find "$gates_dir" -maxdepth 1 -type f -name "${label}-*.log" \
        ! -name "${label}-latest.log" 2>/dev/null |
        sort -r
    )
    if ((${#_old_logs[@]} > keep)); then
      for ((i = keep; i < ${#_old_logs[@]}; i++)); do
        rm -f "${_old_logs[i]}" "${_old_logs[i]%.log}.exit"
      done
    fi
  fi

  _write_breadcrumbs "$cmd_status"
  _log_activity "🧪 GATE end label=$label exit=$cmd_status duration=${duration}s log=${latest_link#"$workspace"/}"

  trap - EXIT
  rm -rf "$_lock_dir" 2>/dev/null || true
  exit "$cmd_status"
fi

# =============================================================================
# LAUNCHER / WAITER ROLE (default)
# =============================================================================

# --- Join an in-flight gate of this label -----------------------------------
# A live lock holding the SAME command means the gate is already running:
# attach to it instead of double-running (this is what makes the exit-75
# protocol idempotent). A live lock with a DIFFERENT command is a genuine
# busy: surface it and leave the in-flight gate alone.
if [[ -d "$_lock_dir" && -f "$_lock_dir/ts" ]]; then
  _holder_pid=$(cat "$_lock_dir/pid" 2>/dev/null || echo "")
  _holder_ts=$(cat "$_lock_dir/ts" 2>/dev/null || echo "")
  _holder_cmd=$(cat "$_lock_dir/cmd" 2>/dev/null || echo "")
  if [[ "$_holder_pid" =~ ^[0-9]+$ ]] && kill -0 "$_holder_pid" 2>/dev/null && [[ -n "$_holder_ts" ]]; then
    if [[ "$_holder_cmd" == "$_cmd_norm" ]]; then
      printf 'gate-run.sh: joining in-flight %s gate (runner pid=%s, ts=%s)\n' \
        "$label" "$_holder_pid" "$_holder_ts"
      set +e
      _wait_for_verdict "$_holder_ts" "$_holder_pid" "joined"
      _rc=$?
      set -e
      exit "$_rc"
    fi
    _holder_age=$(($(date +%s) - $(stat -f '%m' "$_lock_dir" 2>/dev/null || stat -c '%Y' "$_lock_dir" 2>/dev/null || echo 0)))
    echo "gate-run.sh: the '$label' gate is busy running a DIFFERENT command (pid=$_holder_pid, ${_holder_age}s elapsed): $_holder_cmd" >&2
    echo "  Wait for it (re-run your command later) — do NOT delete the lock or relabel to dodge it. Its verdict lands in .ralph/gates/${label}-latest.{log,exit}." >&2
    _log_activity "🧪 GATE BLOCKED label=$label — busy with different cmd (pid=$_holder_pid, age=${_holder_age}s)"
    exit 75
  fi
fi

# --- Acquire the per-label lock ----------------------------------------------
# 0.5.4 mkdir-mutex with 0.12.5 dead-holder steal and 0.14.2 PID-recycling
# detection. Serializes concurrent gates of one label; orphaned locks from
# hard-killed runners are reclaimed here. mkdir is atomic across POSIX
# filesystems and works without coreutils' `flock` (absent on macOS).
_lock_wait="${RALPH_GATE_LOCK_WAIT:-60}"
_lock_acquired=0
_lock_waited=0
while [[ $_lock_waited -lt $_lock_wait ]]; do
  if mkdir "$_lock_dir" 2>/dev/null; then
    _lock_acquired=1
    # 0.12.5: pid inside the lock so contenders detect a dead holder
    # instantly. 0.14.2: creation epoch so contenders detect PID recycling.
    echo $$ >"$_lock_dir/pid" 2>/dev/null || true
    date +%s >"$_lock_dir/epoch" 2>/dev/null || true
    break
  fi
  if [[ -f "$_lock_dir/pid" ]]; then
    _holder_pid=$(cat "$_lock_dir/pid" 2>/dev/null || echo "")
    if [[ -n "$_holder_pid" ]] && ! kill -0 "$_holder_pid" 2>/dev/null; then
      _log_activity "🧪 GATE LOCK STOLEN label=$label — holder pid=$_holder_pid is dead"
      rm -rf "$_lock_dir"
      continue
    fi
    # PID alive — recycled? A process that STARTED AFTER the lock's epoch
    # cannot be the original holder (macOS reuses PIDs aggressively).
    if [[ -n "$_holder_pid" ]] && [[ -f "$_lock_dir/epoch" ]]; then
      _lock_epoch=$(cat "$_lock_dir/epoch" 2>/dev/null || echo "0")
      _proc_lstart=$(ps -p "$_holder_pid" -o lstart= 2>/dev/null || echo "")
      if [[ -n "$_proc_lstart" ]]; then
        # macOS: date -jf; Linux: date -d
        _proc_epoch=$(date -jf "%a %b %d %T %Y" "$_proc_lstart" +%s 2>/dev/null ||
          date -d "$_proc_lstart" +%s 2>/dev/null ||
          echo "0")
        if [[ "$_proc_epoch" -gt "$_lock_epoch" ]]; then
          _log_activity "🧪 GATE LOCK STOLEN label=$label — pid=$_holder_pid is alive but started after lock (lock_epoch=${_lock_epoch}, proc_epoch=${_proc_epoch}); PID was recycled"
          rm -rf "$_lock_dir"
          continue
        fi
      fi
    fi
  fi
  # Fallback time-based steal for pid-less (pre-0.12.5) locks.
  _stale_after="${RALPH_GATE_STALE_LOCK_SEC:-2700}"
  _lock_age=$(($(date +%s) - $(stat -f '%m' "$_lock_dir" 2>/dev/null || stat -c '%Y' "$_lock_dir" 2>/dev/null || echo 0)))
  if [[ $_lock_age -gt $_stale_after ]]; then
    _log_activity "🧪 GATE LOCK STOLEN label=$label — prior holder appears dead (age=${_lock_age}s)"
    rm -rf "$_lock_dir"
    continue
  fi
  sleep 1
  _lock_waited=$((_lock_waited + 1))
done
if [[ $_lock_acquired -eq 0 ]]; then
  # 0.13.5: a live lock means another gate of THIS label is genuinely still
  # running — transient "busy", not a failure to own. Exit 75 (EX_TEMPFAIL);
  # no breadcrumb is written, so the last real verdict is untouched.
  _holder_pid=$(cat "$_lock_dir/pid" 2>/dev/null || echo "?")
  _holder_age=$(($(date +%s) - $(stat -f '%m' "$_lock_dir" 2>/dev/null || stat -c '%Y' "$_lock_dir" 2>/dev/null || echo 0)))
  if [[ "$_holder_pid" =~ ^[0-9]+$ ]] && kill -0 "$_holder_pid" 2>/dev/null; then
    _holder_state="alive — still running"
  else
    _holder_state="not detectable (it should be reclaimed automatically on the next attempt)"
  fi
  echo "gate-run.sh: the '$label' gate is already running (pid=$_holder_pid, ${_holder_age}s elapsed, $_holder_state); waited ${_lock_wait}s for it." >&2
  echo "  Do NOT delete the lock or re-run this gate under a different label — both are dodges. Re-run the same command to join the in-flight gate, then read .ralph/gates/${label}-latest.{log,exit} for its result. (lock dir: $_lock_dir)" >&2
  _log_activity "🧪 GATE BLOCKED label=$label — gate already running (pid=$_holder_pid, age=${_holder_age}s); waited ${_lock_wait}s"
  exit 75
fi

# Until the runner claims the lock, it is ours to clean on abort.
trap 'rm -rf "$_lock_dir" 2>/dev/null || true' EXIT

# --- Prepare the run and detach the runner -----------------------------------

# UTC timestamp + launcher pid: same-second launches of one label must not
# collide on run identity, or a re-launch could read the prior run's stale
# verdict as its own.
ts="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
log_file="$gates_dir/${label}-${ts}.log"

# Header so operators grepping the log know exactly what ran and when.
{
  printf '=== gate-run label=%s ts=%s cwd=%s\n' "$label" "$ts" "$workspace"
  printf '=== cmd:'
  printf ' %q' "$@"
  printf '\n'
  printf '===\n'
} >"$log_file"

printf '%s' "$ts" >"$_lock_dir/ts"
printf '%s' "$_cmd_norm" >"$_lock_dir/cmd"

# Detach into a new session, doubly-forked so the runner is reparented to
# init from birth: a PID-tree walk from this call finds nothing, and a
# process-group / session kill of this call cannot reach it. Verified
# against both observed kill paths (Bash-tool timeout kill; subagent-return
# background reap). macOS has no setsid(1) — perl's POSIX::setsid is the
# portable equivalent; plain double-fork is the degraded last resort
# (reparented but same session — survives tree walks, not session kills).
export RALPH_GATE_ROLE=runner RALPH_GATE_TS="$ts" \
  RALPH_WORKSPACE="$workspace" RALPH_GATES_DIR="$gates_dir" \
  RALPH_GATE_KEEP="$keep" RALPH_GATE_KILL_GRACE
if command -v setsid >/dev/null 2>&1; then
  (setsid nohup bash "$_self" "$label" "$@" </dev/null >>"$log_file" 2>&1 &)
elif command -v perl >/dev/null 2>&1; then
  # 0.18.0: fork BEFORE setsid. POSIX::setsid() fails (returns -1) if the
  # caller is already a process-group leader, and the pre-0.18 one-liner
  # called it directly and ignored the result — so on any job-control layout
  # where the backgrounded perl was a group leader, the "new session" silently
  # never happened and the runner stayed in the caller's session, reachable by
  # a session-scoped kill (a caller-death SIGINT then reached the wrapped test
  # command → the spurious exit=130 gates in run 140038). A forked child is
  # never a group leader, so setsid always succeeds; die loudly if it somehow
  # does not, rather than degrade to a same-session runner.
  # shellcheck disable=SC2016 # $p/$!/@ARGV are perl variables — must NOT be
  # expanded by the shell; single quotes are correct.
  (nohup perl -MPOSIX -e 'my $p=fork(); exit 0 if $p; POSIX::setsid()!=-1 or die "gate-run detach: setsid failed: $!"; exec @ARGV or die "gate-run detach: exec failed: $!"' \
    -- bash "$_self" "$label" "$@" </dev/null >>"$log_file" 2>&1 &)
else
  printf '=== gate-run warning: no setsid/perl — degraded detach (reparent only) ===\n' >>"$log_file"
  (nohup bash "$_self" "$label" "$@" </dev/null >>"$log_file" 2>&1 &)
fi
unset RALPH_GATE_ROLE RALPH_GATE_TS

# Wait for the runner to claim the lock (it overwrites pid with its own).
# A fast gate may claim, run, AND clean up between polls — a landed per-run
# verdict counts as claimed too.
_claimed=0
_claim_ticks=0
while [[ $_claim_ticks -lt 75 ]]; do # 75 × 0.2s = 15s
  if [[ -f "$gates_dir/${label}-${ts}.exit" ]]; then
    _claimed=1
    break
  fi
  _lock_pid=$(cat "$_lock_dir/pid" 2>/dev/null || echo "")
  if [[ "$_lock_pid" =~ ^[0-9]+$ ]] && [[ "$_lock_pid" != "$$" ]]; then
    _claimed=1
    break
  fi
  sleep 0.2
  _claim_ticks=$((_claim_ticks + 1))
done
if [[ $_claimed -eq 0 ]]; then
  echo "gate-run.sh: detached runner failed to start within 15s — see ${log_file#"$workspace"/}" >&2
  tail -n 10 "$log_file" 2>/dev/null || true
  _log_activity "🧪 GATE runner failed to start label=$label"
  exit 70 # EXIT trap cleans the lock
fi

# Lock now belongs to the runner; do not clean it on our exit.
trap - EXIT
runner_pid=$(cat "$_lock_dir/pid" 2>/dev/null || echo "")

printf 'gate-run.sh: %s gate launched detached (runner pid=%s, ts=%s, gate timeout %ss)\n' \
  "$label" "${runner_pid:-already-finished}" "$ts" "$gate_timeout"

set +e
_wait_for_verdict "$ts" "$runner_pid" "launched"
_rc=$?
set -e
exit "$_rc"
