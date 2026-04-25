#!/bin/bash
# Ralph Wiggum: Gate runner wrapper
#
# Executes a gate command (typically `pnpm all-check`, `pnpm test-e2e:local`,
# etc.) with pipefail-safe semantics, persists the full output to
# .ralph/gates/<label>-<ts>.log, maintains a .ralph/gates/<label>-latest.log
# pointer, and prints a bounded, deterministic summary to stdout.
#
# The wrapped command runs in the caller's working directory under
# `set -o pipefail` so the real exit code is preserved regardless of
# pipes the caller constructs inside its own command string.
#
# Usage:
#   gate-run.sh <label> <cmd> [args...]
#
#   <label> MUST be one of: basic | final | e2e | lint | custom
#
# Examples:
#   gate-run.sh final pnpm all-check
#   gate-run.sh basic pnpm basic-check
#   gate-run.sh e2e pnpm test-e2e:local
#
# Exit code:
#   The real exit code of <cmd>, via ${PIPESTATUS[0]}. `tee`'s status is
#   ignored.
#
# Output:
#   Compact summary to stdout (<= ~150 lines), full log on disk.
#
# Environment:
#   RALPH_GATES_DIR       Override .ralph/gates/ location (default: ./.ralph/gates).
#   RALPH_GATE_KEEP       Per-label log retention count (default: 10).
#   RALPH_GATE_TAIL       Lines of tail to include in summary (default: 60).
#   RALPH_GATE_FAIL_HEAD  Lines of failure-match output in summary (default: 80).

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
  window), and a re-run is needed to see more of the failure. This wrapper
  fixes that in one step:
    • Tees the command's combined stdout/stderr to .ralph/gates/<label>-<ts>.log
    • Prints a bounded summary (header + tail + failure-pattern matches)
    • Exits with the real command status via PIPESTATUS (pipefail-safe)
    • Writes an exit-code breadcrumb at .ralph/gates/<label>-latest.exit
    • Maintains a .ralph/gates/<label>-latest.log pointer for quick reading

LABELS (fixed set — pick the closest match; use 'custom' for anything else)
  basic   Fast pre-commit gate (format, lint, unit tests). Default timeout 600 s.
  final   Full verification gate (basic + integration/E2E). Default timeout 900 s.
  e2e     Targeted E2E / browser / container suite. Default timeout 600 s.
  lint    Lint-only or type-check-only runs. Default timeout 600 s.
  custom  Anything that does not fit the four above. Default timeout 600 s.

EXAMPLES
  gate-run.sh basic pnpm basic-check
  gate-run.sh final pnpm all-check
  gate-run.sh e2e   pnpm test-e2e:local
  gate-run.sh lint  pnpm lint:check

EXIT CODES
  0       The wrapped command exited 0.
  N≠0     The wrapped command exited N. Passed through verbatim.
  64      Usage error (missing args, invalid label).
  124     The command exceeded its timeout (GNU/BSD 'timeout' convention).

ENVIRONMENT
  RALPH_WORKSPACE       Workspace root (default: $PWD). Logs land under
                        $RALPH_WORKSPACE/.ralph/gates/.
  RALPH_GATES_DIR       Full override for the log directory
                        (default: $RALPH_WORKSPACE/.ralph/gates).
  RALPH_GATE_KEEP       Per-label log retention count (default 10).
  RALPH_GATE_TAIL       Lines of tail included in the summary (default 60).
  RALPH_GATE_FAIL_HEAD  Failure-match lines in the summary (default 80).
  RALPH_GATE_TIMEOUT    Blanket timeout override (seconds) for any label.
                        Takes precedence over the per-label vars below.
  RALPH_FINAL_GATE_TIMEOUT  Timeout for label=final   (default 900).
  RALPH_BASIC_GATE_TIMEOUT  Timeout for every other label (default 600).

FAILURE-PATTERN MATCHING
  On completion the wrapper greps the log for common failure signatures
  (vitest / jest / cypress / tsc / eslint / nestjs / generic stack traces)
  and prints up to RALPH_GATE_FAIL_HEAD line-numbered matches. This helps
  an agent find the failing site without re-running the gate. The regex is
  line-anchored and Node/TS-biased today; non-Node ecosystems may want to
  wrap this script or tail the full log directly.

AGENT PROTOCOL (also documented in docs/gate-run.md)
  1. Run every gate via this wrapper — never bare, never piped, never
     redirected. Piping hides exit codes and makes you re-run to see more.
  2. When a gate fails: do NOT re-run it. Read .ralph/gates/<label>-latest.log
     with offset/limit reads or targeted grep, fix the smallest thing, then
     re-run once.
  3. When a gate passes: do NOT re-read the log. The summary already printed
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
  echo "  <label> in: basic | final | e2e | lint | custom" >&2
  echo "  run 'gate-run.sh --help' for details" >&2
  exit 64
fi

label="$1"
shift

case "$label" in
  basic | final | e2e | lint | custom) ;;
  *)
    echo "gate-run.sh: invalid label '$label' (expected basic|final|e2e|lint|custom)" >&2
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

mkdir -p "$gates_dir"

# UTC timestamp. Portable between macOS and GNU date.
ts=$(date -u '+%Y%m%dT%H%M%SZ')
log_file="$gates_dir/${label}-${ts}.log"
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

# -----------------------------------------------------------------------------
# Run the command, capturing real exit code via PIPESTATUS
# -----------------------------------------------------------------------------

# Write a header into the log file so operators grepping the file know
# exactly what was run and when.
{
  printf '=== gate-run label=%s ts=%s cwd=%s\n' "$label" "$ts" "$workspace"
  printf '=== cmd:'
  printf ' %q' "$@"
  printf '\n'
  printf '===\n'
} >"$log_file"

# 0.5.4: per-label mkdir-mutex. Prevents two concurrent gate runs of the
# same label from racing on the shared $latest_link symlink, the shared
# coverage/ output dirs, and the long-lived nx daemon. Concurrent runs are
# almost always orphans from a killed iteration whose deep pnpm/nx/vitest
# subtree survived the loop's pgrep-based reaper — when that happens, the
# new iteration's first gate would clobber and corrupt the orphan's output
# (or vice versa) and report a spurious failure. The mutex serializes the
# two so the orphan finishes (or is reaped by the next sweep) before the
# new run starts. mkdir is atomic across POSIX filesystems and works without
# coreutils' `flock`, which is not on macOS by default.
_lock_dir="$gates_dir/.${label}.lock"
_lock_wait="${RALPH_GATE_LOCK_WAIT:-60}"
_lock_acquired=0
_lock_waited=0
while [[ $_lock_waited -lt $_lock_wait ]]; do
  if mkdir "$_lock_dir" 2>/dev/null; then
    _lock_acquired=1
    break
  fi
  # Stale-lock heuristic: if the lock dir is older than the largest
  # plausible gate timeout (RALPH_GATE_STALE_LOCK_SEC, default 1800s = 30
  # min, well above the 900s final-gate cap), the prior holder almost
  # certainly died without cleanup. Steal the lock rather than block.
  _stale_after="${RALPH_GATE_STALE_LOCK_SEC:-1800}"
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
  echo "gate-run.sh: another gate-run.sh is holding the $label lock; waited ${_lock_wait}s and gave up" >&2
  echo "  (lock dir: $_lock_dir — remove manually if you are sure no other gate is running)" >&2
  _log_activity "🧪 GATE BLOCKED label=$label — could not acquire lock after ${_lock_wait}s"
  exit 64
fi
trap 'rmdir "$_lock_dir" 2>/dev/null || true' EXIT

_log_activity "🧪 GATE start label=$label cmd=$(printf '%q ' "$@")"

start_epoch=$(date +%s)

# Gate timeout: kill hung commands (e.g. wedged nx daemon) instead of
# waiting forever.
#
# 0.3.5: Per-label defaults. Final gates (pnpm all-check, full E2E suites)
# are empirically 3–5× slower than basic gates (lint + unit tests).
#
# 0.3.8: Defaults re-targeted to ~2× measured monorepo runtimes after
# field reports of repeated GATE TIMEOUT on `pnpm basic-check` at 300 s.
#
# 0.3.9: Raised again. In-worktree measurements showed `pnpm basic-check`
# takes ~4:15 on main but >6 min in a red-state worktree (failing tests
# slow Vitest's retry-and-report path; lint/format still finish quickly).
# Agent-mode iterations legitimately contain broken states — the default
# has to accommodate that, not the green-path best case. New defaults:
#
#   basic  10 min (600 s) — clean ~4 min, red-state ~6–8 min
#   final  15 min (900 s) — clean ~5–8 min, red-state ~10–12 min
#
# Projects with larger suites can override via the env vars below.
#
# Env vars cascade:
#
#   RALPH_FINAL_GATE_TIMEOUT  → used when label=final  (default 900)
#   RALPH_BASIC_GATE_TIMEOUT  → used when label=basic  (default 600)
#   RALPH_GATE_TIMEOUT        → blanket override for any label (no default;
#                                takes precedence over the per-label vars
#                                when set, for backward compat)
if [[ -n "${RALPH_GATE_TIMEOUT:-}" ]]; then
  gate_timeout="$RALPH_GATE_TIMEOUT"
elif [[ "$label" == "final" ]]; then
  gate_timeout="${RALPH_FINAL_GATE_TIMEOUT:-900}"
else
  gate_timeout="${RALPH_BASIC_GATE_TIMEOUT:-600}"
fi

# Resolve the timeout command portably (GNU timeout on Linux,
# gtimeout via coreutils on macOS, or a shell-based fallback).
_timeout_cmd=""
if command -v timeout >/dev/null 2>&1; then
  _timeout_cmd="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  _timeout_cmd="gtimeout"
fi

# Execute the command with stderr merged into stdout, tee into the log
# file (append, since we already wrote the header), and let pipefail
# surface the real command exit code via PIPESTATUS.
# The timeout wrapper returns 124 when the command is killed.
# If neither timeout nor gtimeout is available, run without a timeout
# (degraded but functional — install coreutils for full support).
set +e
set -o pipefail
if [[ -n "$_timeout_cmd" ]]; then
  "$_timeout_cmd" "$gate_timeout" "$@" 2>&1 | tee -a "$log_file"
else
  "$@" 2>&1 | tee -a "$log_file"
fi
cmd_status=${PIPESTATUS[0]}
set +o pipefail
set -e

# Report timeout clearly so the agent can take corrective action
# (e.g. restart a stuck daemon) instead of re-running blindly.
if [[ $cmd_status -eq 124 ]]; then
  printf '\n⏰ Gate timed out after %ss (RALPH_GATE_TIMEOUT=%s)\n' \
    "$gate_timeout" "$gate_timeout" | tee -a "$log_file"
  _log_activity "🧪 GATE TIMEOUT label=$label after ${gate_timeout}s"
fi

end_epoch=$(date +%s)
duration=$((end_epoch - start_epoch))

# -----------------------------------------------------------------------------
# Update "latest" pointer. Prefer a symlink; fall back to a copy on
# filesystems that reject symlinks (rare, but FAT32 / some network mounts).
# -----------------------------------------------------------------------------

rm -f "$latest_link"
if ln -s "$(basename "$log_file")" "$latest_link" 2>/dev/null; then
  :
else
  cp "$log_file" "$latest_link"
fi

# -----------------------------------------------------------------------------
# Retention: keep only the most recent $keep logs for this label.
# -----------------------------------------------------------------------------

# List matching timestamped logs in reverse-chronological order and delete
# anything beyond $keep. Portable across bash 3.2 (macOS /bin/bash) —
# `mapfile` is bash-4+ only, so we use a read-loop instead. Any user
# invoking gate-run.sh under system bash on macOS hit a silent
# `mapfile: command not found` + set -e abort prior to 0.3.4, which
# skipped retention AND the GATE-end activity-log line.
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
      rm -f "${_old_logs[i]}"
    done
  fi
fi

# -----------------------------------------------------------------------------
# Summary output
# -----------------------------------------------------------------------------

# Relative path for the summary line (nicer for LLM grepping).
rel_log="${log_file#"$workspace"/}"
rel_latest="${latest_link#"$workspace"/}"

{
  printf '=== GATE %s exit=%s duration=%ss log=%s latest=%s ===\n' \
    "$label" "$cmd_status" "$duration" "$rel_log" "$rel_latest"

  printf -- '--- tail (last %s lines) ---\n' "$tail_lines"
  tail -n "$tail_lines" "$log_file" 2>/dev/null || true

  printf -- '--- failing-tests (first %s matches) ---\n' "$fail_head"
  # Look for common failure signatures across vitest, jest, cypress, tsc,
  # eslint, nestjs, and generic stack traces. Line-anchored to minimize
  # false positives.
  grep -n -E \
    '^\s*(FAIL|✗|× |Error:|AssertionError|TypeError|ReferenceError|SyntaxError|\s+at\s|expected|Expected|    [0-9]+\)|ERROR in|error TS[0-9]+|error\s+@|✖ )' \
    "$log_file" 2>/dev/null | head -n "$fail_head" || true

  printf '=== END GATE ===\n'
}

_log_activity "🧪 GATE end label=$label exit=$cmd_status duration=${duration}s log=$rel_latest"

# 0.3.3: Breadcrumb file consumed by the loop's COMPLETE guard. Single
# decimal integer, no newline. Present one-per-label at
# .ralph/gates/<label>-latest.exit. The most recently-modified file
# across all labels represents the last gate the agent ran.
printf '%s' "$cmd_status" >"$gates_dir/$label-latest.exit"

exit "$cmd_status"
