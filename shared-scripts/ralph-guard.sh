#!/bin/bash
# Ralph Wiggum: PreToolUse hook guard
#
# Single entry point for all PreToolUse decisions. Dispatches on tool_name
# (Bash, Write, Edit, MultiEdit) to enforce mechanical constraints the
# agent cannot route around:
#
#   - Gate-without-write block (Bash: gate-run.sh without intervening write)
#   - Direct-test-tool denial (Bash: vitest/cypress/tsc without gate-run.sh)
#   - Command-policy enforcement (Bash: .ralph/command-policy —
#     rewrite/deny/gate-wrapped/protect)
#     Legacy fallback: .ralph/denied-commands + .ralph/protected-scripts
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
# Detect Ralph loop context — only enforce when running inside a Ralph agent
# ---------------------------------------------------------------------------

# RALPH_AGENT_GUARD is set as a command-line prefix on the `claude -p`
# invocation in agent-adapter.sh (e.g. `RALPH_AGENT_GUARD=1 claude -p ...`).
# This scopes the var to the agent process and its children (hooks) —
# interactive Claude sessions in the same worktree are unaffected.
# The previous .ralph/ directory check broke once .ralph/ was committed to
# main in consuming repos.
[ -z "${RALPH_AGENT_GUARD:-}" ] && exit 0

WORKSPACE="${RALPH_WORKSPACE:-$(pwd)}"

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

# Normalize a pnpm invocation to its canonical script-name form so prefix
# matching catches equivalent variants:
#   pnpm run <script>  → pnpm <script>
#   pnpm exec <script> → pnpm <script>
# Used by the [gate-wrapped] policy check so the agent can't slip past a
# rule on "pnpm all-check" by writing "pnpm run all-check".
# (npx pnpm and pnpm -w run are handled separately by the [rewrite] section.)
_normalize_pnpm() {
  local cmd="$1"
  cmd=$(echo "$cmd" | sed -E 's/^pnpm[[:space:]]+(run|exec)[[:space:]]+/pnpm /')
  echo "$cmd"
}

# ---------------------------------------------------------------------------
# Command policy (rewrite / deny / protect)
# ---------------------------------------------------------------------------
#
# .ralph/command-policy syntax:
#   [rewrite]
#   regex | replacement | reason     # regex anchored implicitly by ^/$ in pattern
#
#   [deny]
#   command-prefix | reason
#
#   [gate-wrapped]
#   command-prefix                   # MUST be invoked via gate-run.sh, else denied
#
#   [protect]
#   command-prefix                   # bare OK; pipe/redirect denied
#
# Falls back to .ralph/denied-commands (deny) + .ralph/protected-scripts
# (protect) when command-policy is absent. Legacy fallback never gets
# rewrite or gate-wrapped — only the new format supports them.

_warn_legacy_policy() {
  local sentinel="$STATE_DIR/.policy-deprecation-warned"
  [[ -f "$sentinel" ]] && return 0
  : >"$sentinel"
  local errlog="$WORKSPACE/.ralph/errors.log"
  [[ -f "$errlog" ]] || return 0
  {
    echo ""
    echo "[$(date '+%H:%M:%S')] DEPRECATION: .ralph/denied-commands and"
    echo "  .ralph/protected-scripts are deprecated. Migrate to .ralph/command-policy"
    echo "  (see shared-references/templates/command-policy.md in the plugin)."
  } >>"$errlog" 2>/dev/null || true
}

# Parse command-policy into four temp files for the four sections.
# Output paths are echoed space-separated:
#   "rewrite_file deny_file gate_wrapped_file protect_file"
# Caller is responsible for cleanup.
_parse_command_policy() {
  local policy_file="$1"
  local rw dn gw pt
  rw=$(mktemp)
  dn=$(mktemp)
  gw=$(mktemp)
  pt=$(mktemp)
  local section=""
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Strip CR if present, trim trailing whitespace.
    line="${line%$'\r'}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
      "" | \#*) continue ;;
      "[rewrite]") section="rewrite" ;;
      "[deny]") section="deny" ;;
      "[gate-wrapped]") section="gate_wrapped" ;;
      "[protect]") section="protect" ;;
      "["*"]") section="" ;;
      *)
        case "$section" in
          rewrite) printf '%s\n' "$line" >>"$rw" ;;
          deny) printf '%s\n' "$line" >>"$dn" ;;
          gate_wrapped) printf '%s\n' "$line" >>"$gw" ;;
          protect) printf '%s\n' "$line" >>"$pt" ;;
        esac
        ;;
    esac
  done <"$policy_file"
  printf '%s %s %s %s' "$rw" "$dn" "$gw" "$pt"
}

_apply_rewrites() {
  # $1 = stripped command, $2 = rewrite file
  # On match: _block with the canonical form + reason.
  local stripped="$1" rwfile="$2"
  [[ -s "$rwfile" ]] || return 0
  local rule pattern replacement reason canonical
  while IFS= read -r rule || [[ -n "$rule" ]]; do
    [[ -z "$rule" ]] && continue
    # Split on ' | ' (with optional surrounding whitespace).
    pattern="${rule%%|*}"
    rule="${rule#*|}"
    replacement="${rule%%|*}"
    reason="${rule#*|}"
    # Trim whitespace from each field.
    pattern="$(printf '%s' "$pattern" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
    replacement="$(printf '%s' "$replacement" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
    reason="$(printf '%s' "$reason" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
    [[ -z "$pattern" ]] && continue
    # Apply regex. We use sed with the pattern as-is; the pattern may use ^ and $.
    if printf '%s' "$stripped" | grep -qE "$pattern" 2>/dev/null; then
      canonical=$(printf '%s' "$stripped" | sed -E "s|$pattern|$replacement|")
      local msg="[ralph] use '$canonical' instead"
      [[ -n "$reason" ]] && msg="$msg — $reason"
      _block "$msg"
    fi
  done <"$rwfile"
}

_apply_deny() {
  local stripped="$1" dnfile="$2"
  [[ -s "$dnfile" ]] || return 0
  local rule denied_cmd denied_reason
  while IFS= read -r rule || [[ -n "$rule" ]]; do
    [[ -z "$rule" ]] && continue
    denied_cmd="${rule%%|*}"
    denied_reason=""
    [[ "$rule" == *"|"* ]] && denied_reason="${rule#*|}"
    denied_cmd="$(printf '%s' "$denied_cmd" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
    denied_reason="$(printf '%s' "$denied_reason" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
    [[ -z "$denied_cmd" ]] && continue
    if [[ "$stripped" == "$denied_cmd" || "$stripped" == "$denied_cmd "* ]]; then
      _block "${denied_reason:-Command denied by project configuration.}"
    fi
  done <"$dnfile"
}

_apply_protect() {
  local cmd="$1" stripped="$2" ptfile="$3"
  [[ -s "$ptfile" ]] || return 0
  local prefix
  while IFS= read -r prefix || [[ -n "$prefix" ]]; do
    prefix="$(printf '%s' "$prefix" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
    [[ -z "$prefix" ]] && continue
    if [[ "$stripped" == "$prefix"* ]]; then
      if echo "$cmd" | grep -qE '\||\s*>\s*|>>'; then
        _block "Protected script pipe/redirect denied: '$prefix' must not be piped or redirected. Run bare or through gate-run.sh."
      fi
      return 0
    fi
  done <"$ptfile"
}

# [gate-wrapped] enforcement (0.12.1).
# A listed command MUST be invoked through the plugin's gate-run.sh wrapper,
# so the loop gets its tracking artifacts (latest.log/.exit/.cmd/.summary,
# handoff section update, gate-fail streak tracking, completion guard).
#
# Matching tightness:
#   - Env-var prefix already stripped by caller (_strip_env_prefix)
#   - `pnpm run X` and `pnpm exec X` are normalized to `pnpm X` before
#     prefix matching, so the agent can't slip past by adding `run`/`exec`
#   - Pipe/redirect of a bare invocation is still bare → blocked here
#   - Wrapping in gate-run.sh allows the command through (the wrapper
#     handles output bounding; piping the wrapped form is OK because the
#     wrapper has already done its summary work)
_apply_gate_wrapped() {
  local cmd="$1" stripped="$2" gwfile="$3"
  [[ -s "$gwfile" ]] || return 0

  # If the raw command routes through gate-run.sh, the contract is satisfied.
  if echo "$cmd" | grep -qE 'gate-run\.sh'; then
    return 0
  fi

  local normalized
  normalized=$(_normalize_pnpm "$stripped")

  local prefix
  while IFS= read -r prefix || [[ -n "$prefix" ]]; do
    prefix="$(printf '%s' "$prefix" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
    [[ -z "$prefix" ]] && continue
    if [[ "$normalized" == "$prefix" || "$normalized" == "$prefix "* ]]; then
      _block "[ralph] '$prefix' must be invoked through gate-run.sh so the loop can track its result (handoff state, exit breadcrumb, fail-streak counter). Use: bash <plugin>/shared-scripts/gate-run.sh <label> $prefix"
    fi
  done <"$gwfile"
  return 0
}

_enforce_command_policy() {
  local cmd="$1" stripped="$2"
  local policy="$WORKSPACE/.ralph/command-policy"
  local rwfile="" dnfile="" gwfile="" ptfile=""

  if [[ -f "$policy" ]]; then
    local parsed
    parsed=$(_parse_command_policy "$policy")
    rwfile="${parsed%% *}"
    parsed="${parsed#* }"
    dnfile="${parsed%% *}"
    parsed="${parsed#* }"
    gwfile="${parsed%% *}"
    ptfile="${parsed#* }"
  else
    # Legacy fallback. Only deny + protect; no rewrite, no gate-wrapped.
    local legacy_used=0
    if [[ -f "$WORKSPACE/.ralph/denied-commands" ]]; then
      dnfile=$(mktemp)
      grep -v '^\s*#' "$WORKSPACE/.ralph/denied-commands" 2>/dev/null | grep -v '^\s*$' >"$dnfile" || true
      legacy_used=1
    fi
    if [[ -f "$WORKSPACE/.ralph/protected-scripts" ]]; then
      ptfile=$(mktemp)
      grep -v '^\s*#' "$WORKSPACE/.ralph/protected-scripts" 2>/dev/null | grep -v '^\s*$' >"$ptfile" || true
      legacy_used=1
    elif [[ -n "${RALPH_PROTECTED_SCRIPTS:-}" ]]; then
      ptfile=$(mktemp)
      printf '%s' "$RALPH_PROTECTED_SCRIPTS" | tr ' ' '\n' >"$ptfile"
    fi
    if [[ "$legacy_used" -eq 1 ]]; then
      _warn_legacy_policy
    fi
  fi

  # Apply policies. Each call may _block (which exits the script). Cleanup
  # is best-effort — temp files in /tmp survive only until next reboot, and
  # the hook process is short-lived. Avoid installing an EXIT trap because
  # _block calls `exit 0` and on macOS `rm -f '/dev/null'` errors out under
  # `set -e`, masking the block result.
  #
  # Order: rewrite → deny → gate-wrapped → protect.
  # gate-wrapped fires BEFORE protect because a bare-piped invocation
  # ("pnpm all-check | tail") fails both rules — gate-wrapped's message
  # is more actionable ("wrap it") than protect's ("don't pipe it").
  [[ -n "$rwfile" ]] && _apply_rewrites "$stripped" "$rwfile"
  [[ -n "$dnfile" ]] && _apply_deny "$stripped" "$dnfile"
  [[ -n "$gwfile" ]] && _apply_gate_wrapped "$cmd" "$stripped" "$gwfile"
  [[ -n "$ptfile" ]] && _apply_protect "$cmd" "$stripped" "$ptfile"

  # No block fired — clean up tempfiles on the success path.
  [[ -n "$rwfile" ]] && rm -f "$rwfile"
  [[ -n "$dnfile" ]] && rm -f "$dnfile"
  [[ -n "$gwfile" ]] && rm -f "$gwfile"
  [[ -n "$ptfile" ]] && rm -f "$ptfile"
  return 0
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
  # Only bypass when the command is going through gate-run.sh itself.
  if ! echo "$cmd" | grep -qE 'gate-run\.sh'; then
    if echo "$stripped" | grep -qE '^(exec )?(vitest|npx vitest|pnpm vitest|pnpm exec vitest|yarn vitest|jest|npx jest|cypress|npx cypress|pnpm cypress|pnpm exec cypress)(\s|$)'; then
      _block "Direct test tool invocation denied. Run tests through gate-run.sh: bash <plugin>/shared-scripts/gate-run.sh <label> <cmd>"
    fi
    if echo "$stripped" | grep -qE '^(exec )?(tsc|npx tsc|pnpm tsc|pnpm exec tsc)\s+--noEmit'; then
      _block "Direct tsc --noEmit denied. Run type checks through gate-run.sh: bash <plugin>/shared-scripts/gate-run.sh lint tsc --noEmit"
    fi
  fi

  # --- Command-policy enforcement ---
  # Preferred:  .ralph/command-policy  (sections: [rewrite] [deny] [protect])
  # Legacy:     .ralph/denied-commands + .ralph/protected-scripts
  # On legacy use, append a one-shot deprecation note to .ralph/errors.log.
  _enforce_command_policy "$cmd" "$stripped"

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
