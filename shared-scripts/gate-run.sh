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
# Argument validation
# -----------------------------------------------------------------------------

if [[ $# -lt 2 ]]; then
  echo "usage: gate-run.sh <label> <cmd> [args...]" >&2
  echo "  <label> in: basic | final | e2e | lint | custom" >&2
  exit 64
fi

label="$1"
shift

case "$label" in
  basic | final | e2e | lint | custom) ;;
  *)
    echo "gate-run.sh: invalid label '$label' (expected basic|final|e2e|lint|custom)" >&2
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

_log_activity "🧪 GATE start label=$label cmd=$(printf '%q ' "$@")"

start_epoch=$(date +%s)

# Execute the command with stderr merged into stdout, tee into the log
# file (append, since we already wrote the header), and let pipefail
# surface the real command exit code via PIPESTATUS.
set +e
set -o pipefail
"$@" 2>&1 | tee -a "$log_file"
cmd_status=${PIPESTATUS[0]}
set +o pipefail
set -e

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
# anything beyond $keep. Use find + sort to stay portable.
if [[ "$keep" -gt 0 ]]; then
  mapfile -t _old_logs < <(
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

exit "$cmd_status"
