#!/bin/bash
# Ralph Wiggum: PreToolUse hook guard
#
# Single entry point for all PreToolUse decisions. Dispatches on tool_name
# (Bash, Write, Edit, MultiEdit) to enforce mechanical constraints the
# agent cannot route around:
#
#   - Gate-without-write block (Bash: gate-run.sh without intervening write)
#   - Direct-test-tool denial (Bash: vitest/cypress/tsc without gate-run.sh)
#   - Protected-script pipe/redirect denial (Bash: .ralph/protected-scripts)
#   - Denied-command blocking (Bash: .ralph/denied-commands)
#   - State-tampering denial (Bash: rm -rf .ralph/, edits to state paths)
#   - Forbidden-path denial (Write/Edit/MultiEdit: .ralph/gates/*, state dir)
#   - Write-event recording (Write/Edit/MultiEdit: updates last-write-ts)
#
# State lives outside the workspace at:
#   $XDG_STATE_HOME/ralph/<sha256(realpath(workspace))>/
#   (fallback: $HOME/.local/state/ralph/...)
#
# Hook input: JSON on stdin with tool_name and tool_input.
# Hook output: JSON on stdout — {"result":"block","reason":"..."} to deny,
#              or nothing (exit 0) to allow.

set -euo pipefail

# ---------------------------------------------------------------------------
# Parse hook input
# ---------------------------------------------------------------------------

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || true
TOOL_INPUT_CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || true
TOOL_INPUT_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || true

[[ -z "$TOOL_NAME" ]] && exit 0

# ---------------------------------------------------------------------------
# Detect Ralph loop context — only enforce when running inside a Ralph loop
# ---------------------------------------------------------------------------

# The loop sets RALPH_WORKSPACE; if unset, this isn't a Ralph-managed session.
WORKSPACE="${RALPH_WORKSPACE:-}"
[[ -z "$WORKSPACE" ]] && exit 0
[[ -d "$WORKSPACE/.ralph" ]] || exit 0

# ---------------------------------------------------------------------------
# State directory (outside workspace so agent can't tamper)
# ---------------------------------------------------------------------------

_workspace_hash() {
  local real_path
  real_path=$(cd "$WORKSPACE" 2>/dev/null && pwd -P) || real_path="$WORKSPACE"
  echo -n "$real_path" | shasum -a 256 | cut -d' ' -f1
}

STATE_BASE="${XDG_STATE_HOME:-$HOME/.local/state}/ralph"
STATE_DIR="$STATE_BASE/$(_workspace_hash)"
mkdir -p "$STATE_DIR"

LAST_WRITE_TS="$STATE_DIR/last-write-ts"
LAST_GATE_TS="$STATE_DIR/last-gate-ts"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_block() {
  local reason="$1"
  printf '{"result":"block","reason":"%s"}\n' "$reason"
  exit 0
}

_read_ts() {
  local f="$1"
  [[ -f "$f" ]] || {
    echo "0"
    return
  }
  local val
  val=$(cat "$f" 2>/dev/null) || val="0"
  [[ "$val" =~ ^[0-9]+$ ]] || val="0"
  echo "$val"
}

_write_ts() {
  local f="$1"
  local ts
  ts=$(date +%s)
  local tmp="${f}.tmp.$$"
  echo "$ts" >"$tmp"
  mv -f "$tmp" "$f"
}

# Strip leading env-var assignments from a command to get the canonical
# command prefix. E.g. "FOO=bar bash ./scripts/run.sh" → "bash ./scripts/run.sh"
_strip_env_prefix() {
  local cmd="$1"
  echo "$cmd" | sed -E 's/^([A-Za-z_][A-Za-z_0-9]*=[^ ]* +)*//'
}

# ---------------------------------------------------------------------------
# Bash dispatch
# ---------------------------------------------------------------------------

_guard_bash() {
  local cmd="$TOOL_INPUT_CMD"
  [[ -z "$cmd" ]] && return 0

  # --- State-tampering denial ---
  # Block attempts to delete or manipulate .ralph/ state
  if echo "$cmd" | grep -qE '(rm\s+(-[a-zA-Z]*[rf]|--force|--recursive)\s+|rm\s+-[a-zA-Z]*\s+).*\.ralph(/|$)'; then
    _block "State tampering denied: cannot delete .ralph/ directory or contents via rm. These are managed by the loop."
  fi
  if echo "$cmd" | grep -qE 'find\s+.*\.ralph.*-delete'; then
    _block "State tampering denied: cannot delete .ralph/ contents via find -delete."
  fi

  local stripped
  stripped=$(_strip_env_prefix "$cmd")

  # --- Direct test tool denial ---
  # Block direct invocations of test tools without gate-run.sh wrapper.
  # Only block when the command is NOT going through gate-run.sh or exec.
  if ! echo "$cmd" | grep -qE 'gate-run\.sh|exec'; then
    if echo "$stripped" | grep -qE '^(vitest|npx vitest|pnpm vitest|yarn vitest|jest|npx jest|cypress|npx cypress|pnpm cypress)(\s|$)'; then
      _block "Direct test tool invocation denied. Run tests through gate-run.sh: bash <plugin>/shared-scripts/gate-run.sh <label> <cmd>"
    fi
    if echo "$stripped" | grep -qE '^(tsc|npx tsc|pnpm tsc)\s+--noEmit'; then
      _block "Direct tsc --noEmit denied. Run type checks through gate-run.sh: bash <plugin>/shared-scripts/gate-run.sh lint tsc --noEmit"
    fi
  fi

  # --- Denied-commands blocking (.ralph/denied-commands) ---
  # Each line: command-prefix|denial reason
  # Exact-command match (not prefix of longer command), so
  # "pnpm api:test-e2e" blocks "pnpm api:test-e2e --flag" but NOT
  # "pnpm api:test-e2e:local".
  if [[ -f "$WORKSPACE/.ralph/denied-commands" ]]; then
    local denied_cmd denied_reason
    while IFS='|' read -r denied_cmd denied_reason; do
      [[ -z "$denied_cmd" || "$denied_cmd" == \#* ]] && continue
      denied_cmd="${denied_cmd%"${denied_cmd##*[![:space:]]}"}"
      denied_cmd="${denied_cmd#"${denied_cmd%%[![:space:]]*}"}"
      [[ -z "$denied_cmd" ]] && continue
      if [[ "$stripped" == "$denied_cmd" || "$stripped" == "$denied_cmd "* ]]; then
        denied_reason="${denied_reason%"${denied_reason##*[![:space:]]}"}"
        denied_reason="${denied_reason#"${denied_reason%%[![:space:]]*}"}"
        _block "${denied_reason:-Command denied by project configuration.}"
      fi
    done <"$WORKSPACE/.ralph/denied-commands"
  fi

  # --- Protected-script pipe/redirect denial (.ralph/protected-scripts) ---
  # One command prefix per line. Falls back to RALPH_PROTECTED_SCRIPTS env var.
  local _protected_scripts=""
  if [[ -f "$WORKSPACE/.ralph/protected-scripts" ]]; then
    _protected_scripts=$(grep -v '^\s*#' "$WORKSPACE/.ralph/protected-scripts" | grep -v '^\s*$' | tr '\n' '|')
  elif [[ -n "${RALPH_PROTECTED_SCRIPTS:-}" ]]; then
    _protected_scripts=$(echo "$RALPH_PROTECTED_SCRIPTS" | tr ' ' '|')
  fi

  if [[ -n "$_protected_scripts" ]]; then
    local prefix
    while IFS='|' read -r prefix; do
      [[ -z "$prefix" ]] && continue
      if [[ "$stripped" == "$prefix"* ]]; then
        if echo "$cmd" | grep -qE '\||\s*>\s*|>>'; then
          _block "Protected script pipe/redirect denied: '$prefix' must not be piped or redirected. Run bare or through gate-run.sh."
        fi
        break
      fi
    done <<<"${_protected_scripts//|/$'\n'}"
  fi

  # --- Gate-without-write check ---
  if echo "$cmd" | grep -qE 'gate-run\.sh'; then
    local last_write last_gate
    last_write=$(_read_ts "$LAST_WRITE_TS")
    last_gate=$(_read_ts "$LAST_GATE_TS")

    if [[ "$last_gate" -gt 0 ]] && [[ "$last_gate" -ge "$last_write" ]]; then
      # Extract the label from the gate-run.sh invocation for a better message
      local label
      label=$(echo "$cmd" | grep -oE 'gate-run\.sh\s+(basic|final|e2e|lint|custom)' | awk '{print $2}') || label="unknown"
      _block "Gate would produce identical output — no code writes since last gate run. Read .ralph/gates/${label}-latest.log instead, diagnose the failure, make a fix, then retry."
    fi

    # Record the gate invocation timestamp
    _write_ts "$LAST_GATE_TS"
  fi
}

# ---------------------------------------------------------------------------
# Write/Edit/MultiEdit dispatch
# ---------------------------------------------------------------------------

_guard_write() {
  local path="$TOOL_INPUT_PATH"
  [[ -z "$path" ]] && return 0

  # Resolve to a path relative to the workspace for matching
  local rel_path="$path"
  if [[ "$path" == "$WORKSPACE/"* ]]; then
    rel_path="${path#"$WORKSPACE"/}"
  fi

  # --- Forbidden-path denial ---
  # Block writes to .ralph/ except allowlisted files
  if [[ "$rel_path" == .ralph/* ]]; then
    case "$rel_path" in
      .ralph/handoff.md | .ralph/errors.log | .ralph/guardrails.md | .ralph/diagnosis.md | .ralph/progress.md)
        # Allowed
        ;;
      *)
        _block "Write to '$rel_path' denied. Files under .ralph/ (except handoff.md, errors.log, guardrails.md, diagnosis.md, progress.md) are managed by the loop."
        ;;
    esac
  fi

  # Block writes to the external state directory
  if [[ "$path" == "$STATE_DIR"* ]]; then
    _block "Write to ralph state directory denied. State files are managed by the hook."
  fi

  # --- Record WRITE event ---
  _write_ts "$LAST_WRITE_TS"
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------

case "$TOOL_NAME" in
  Bash)
    _guard_bash
    ;;
  Write | Edit | MultiEdit)
    _guard_write
    ;;
esac

exit 0
