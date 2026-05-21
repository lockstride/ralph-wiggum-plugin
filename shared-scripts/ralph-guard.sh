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

# Plugin root — used to construct absolute paths in [wrap] auto-rewrites
# so the agent's bash can find gate-run.sh regardless of cwd.
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || PLUGIN_ROOT=""

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

# 0.12.5: Surface guard activity to activity.log so operators can see
# when an intercept fired without having to debug the hook channel.
# Append-only writes are safe — stream-parser and this hook never race
# on the same line because each call writes a single line atomically.
_log_intercept() {
  local emoji="$1" kind="$2" detail="$3"
  local log="$WORKSPACE/.ralph/activity.log"
  [[ -d "$WORKSPACE/.ralph" ]] || return 0
  local ts
  ts=$(date '+%H:%M:%S')
  # Trim long commands so the log line stays bounded.
  if [[ ${#detail} -gt 200 ]]; then
    detail="${detail:0:200}…"
  fi
  printf '[%s] %s GUARD %s %s\n' "$ts" "$emoji" "$kind" "$detail" >>"$log" 2>/dev/null || true
}

_block() {
  # 0.12.3: Use Claude Code's documented PreToolUse hook response format.
  # The legacy `{"result":"block","reason":"..."}` form is SILENTLY IGNORED
  # by the CLI — every block call before 0.12.3 was a no-op. This was the
  # root cause of every "guard isn't enforcing" symptom: gate-wrapped bypass
  # via pipes, direct vitest invocations, state-tampering rm -rf .ralph/,
  # etc. all went through unblocked because the hook output was unrecognized.
  #
  # 0.12.5: also log to activity.log so operators see the intercept.
  local reason="$1"
  _log_intercept "⛔" "DENY" "${TOOL_INPUT_CMD:-${TOOL_INPUT_FILE_PATH:-?}} → $reason"
  jq -nc --arg reason "$reason" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}' \
    2>/dev/null
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
# Used by the [wrap] policy check so the agent can't slip past a rule on
# "pnpm all-check" by writing "pnpm run all-check".
# (npx pnpm and pnpm -w run are handled separately by the [rewrite] section.)
_normalize_pnpm() {
  local cmd="$1"
  cmd=$(echo "$cmd" | sed -E 's/^pnpm[[:space:]]+(run|exec)[[:space:]]+/pnpm /')
  echo "$cmd"
}

# Strip everything after the first pipe, redirect, or command separator so
# prefix matching sees only the head command. The agent's `pnpm basic-check
# 2>&1 | tail -30` reduces to `pnpm basic-check` for matching purposes.
# The [wrap] rewrite uses this stripped form to construct the gate-run.sh
# invocation (pipes are dropped — gate-run.sh already bounds output).
#
# Recognized terminators (in order of precedence in the regex):
#   ` && `, ` || `, ` ; `, ` | `, ` > `, ` >> `, ` 2>&1`
# Trailing whitespace is trimmed.
_strip_pipes_redirects() {
  local cmd="$1"
  cmd=$(echo "$cmd" | sed -E 's/[[:space:]]+(2>&1|>>|>|\|\||\||&&|;).*$//')
  echo "$cmd" | sed -E 's/[[:space:]]+$//'
}

# Compose the canonicalization pipeline:
#   strip env prefix → strip pipes/redirects → normalize pnpm wrappers
# The result is the form used for matching against [deny]/[wrap] rules.
# [rewrite] rules are applied on top of this (in _enforce_command_policy)
# to handle project-specific patterns like `pnpm nx X → pnpm X`.
_canonicalize() {
  local cmd
  cmd=$(_strip_env_prefix "$1")
  cmd=$(_strip_pipes_redirects "$cmd")
  cmd=$(_normalize_pnpm "$cmd")
  echo "$cmd"
}

# ---------------------------------------------------------------------------
# Command policy (rewrite / deny / wrap / protect)
# ---------------------------------------------------------------------------
#
# 0.12.3 enforcement model: canonicalize → rewrite → deny → wrap → protect.
# Every Bash command is first canonicalized (env-strip + pipe/redirect-strip
# + pnpm-wrapper-normalize). The canonical form is then matched against the
# four policy sections. Whenever a transformation fires, the hook emits an
# `updatedInput` so the agent's tool call is TRANSPARENTLY corrected — the
# agent sees its command "just work" without a block-and-retry puzzle. The
# only thing that still hard-blocks is [deny] (genuinely dangerous commands)
# and a small set of state-tampering patterns enforced outside this policy.
#
# .ralph/command-policy syntax:
#
#   [rewrite]
#   regex | replacement | reason     # regex anchored implicitly by ^/$ in pattern
#                                    # project-specific transforms (e.g. pnpm nx X → pnpm X)
#
#   [deny]
#   command-prefix | reason          # genuinely dangerous; hard block
#
#   [wrap]                           # 0.12.3 — replaces [gate-wrapped]
#   command-prefix | label           # auto-wrapped in gate-run.sh with <label>
#                                    # (label must be one of: basic|final|e2e|lint|custom)
#
#   [protect]
#   command-prefix                   # bare OK; pipe/redirect denied
#
# Backward compat: [gate-wrapped] entries are accepted and treated as [wrap]
# entries with the default label "basic". Projects should migrate to [wrap]
# with explicit labels for accurate gate logging.
#
# Falls back to .ralph/denied-commands (deny) + .ralph/protected-scripts
# (protect) when command-policy is absent. Legacy fallback never gets
# rewrite or wrap — only the new format supports them.

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
#   "rewrite_file deny_file wrap_file protect_file"
# Caller is responsible for cleanup.
#
# 0.12.3: [gate-wrapped] is a backward-compat alias for [wrap]. Entries
# from a [gate-wrapped] section are appended to the wrap file with no
# label (defaulting downstream to "basic").
_parse_command_policy() {
  local policy_file="$1"
  local rw dn wr pt
  rw=$(mktemp)
  dn=$(mktemp)
  wr=$(mktemp)
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
      "[wrap]") section="wrap" ;;
      "[gate-wrapped]") section="wrap_legacy" ;;
      "[protect]") section="protect" ;;
      "["*"]") section="" ;;
      *)
        case "$section" in
          rewrite) printf '%s\n' "$line" >>"$rw" ;;
          deny) printf '%s\n' "$line" >>"$dn" ;;
          wrap) printf '%s\n' "$line" >>"$wr" ;;
          wrap_legacy) printf '%s\n' "$line" >>"$wr" ;;
          protect) printf '%s\n' "$line" >>"$pt" ;;
        esac
        ;;
    esac
  done <"$policy_file"
  printf '%s %s %s %s' "$rw" "$dn" "$wr" "$pt"
}

# 0.12.2: Rewrites are passthrough — the command is transparently
# corrected via the hook's updatedInput mechanism, not blocked.
# Sets _REWRITE_CANONICAL to the rewritten command if a rule matched.
_REWRITE_CANONICAL=""

_apply_rewrites() {
  # $1 = stripped command, $2 = rewrite file
  # On match: sets _REWRITE_CANONICAL and returns 0.
  # Caller is responsible for feeding the rewritten form to downstream checks
  # and emitting the updatedInput hook response if nothing blocks.
  local stripped="$1" rwfile="$2"
  _REWRITE_CANONICAL=""
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
      _REWRITE_CANONICAL=$(printf '%s' "$stripped" | sed -E "s|$pattern|$replacement|")
      return 0
    fi
  done <"$rwfile"
}

_emit_rewrite() {
  local cmd="$1"
  # 0.12.5: log the transparent rewrite so operators can see when the
  # canonicalize/wrap/rewrite pipeline corrected the agent's invocation.
  local orig="${TOOL_INPUT_CMD:-?}"
  if [[ "$orig" != "$cmd" ]]; then
    _log_intercept "🔀" "REWRITE" "$orig → $cmd"
  fi
  # Use jq for safe JSON escaping of the command string.
  jq -n --arg cmd "$cmd" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":$cmd}}}' 2>/dev/null
  exit 0
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

# [wrap] auto-wrap enforcement (0.12.3).
# A listed command is TRANSPARENTLY rewritten to its gate-run.sh-wrapped
# form via the hook's `updatedInput` mechanism. The agent sees its command
# "just work" — no block, no retry, no puzzle to solve. The loop still gets
# its tracking artifacts (latest.log/.exit/.cmd/.summary, handoff section
# update, gate-fail streak tracking, completion guard) because the wrapped
# form is what actually runs.
#
# Matching uses the canonical form (env-stripped, pipe-stripped, pnpm-
# normalized) so every variant of `pnpm X | tail`, `CI=1 pnpm run X`, etc.
# resolves to the same prefix and gets wrapped identically.
#
# Rule syntax (one per line):
#   command-prefix | label
# label must be one of basic|final|e2e|lint|custom. Missing label defaults
# to "basic" (used for backward-compat [gate-wrapped] entries).
#
# On match, sets _WRAP_REWRITE to the rewritten command. _enforce_command_policy
# emits it via _emit_rewrite after all checks pass.
_WRAP_REWRITE=""

# 0.12.4: Try to match a single segment of the canonical form against the
# given wrap rules. Returns 0 with _WRAP_REWRITE set on match, or 1 on
# no match. Extracted from _apply_wrap so it can be reused by the
# compound-chain fallback below.
_try_match_wrap_segment() {
  # $1 = canonical segment to match (already env/pipe/pnpm-normalized)
  # $2 = wrap file
  local segment="$1" wrfile="$2"
  local gate_run_path="${PLUGIN_ROOT:-..}/shared-scripts/gate-run.sh"
  local rule prefix label
  while IFS= read -r rule || [[ -n "$rule" ]]; do
    [[ -z "$rule" ]] && continue
    if [[ "$rule" == *"|"* ]]; then
      prefix="${rule%%|*}"
      label="${rule#*|}"
    else
      prefix="$rule"
      label="basic"
    fi
    prefix="$(printf '%s' "$prefix" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
    label="$(printf '%s' "$label" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
    [[ -z "$prefix" ]] && continue
    case "$label" in
      basic | final | e2e | lint | custom) ;;
      *) label="basic" ;;
    esac
    if [[ "$segment" == "$prefix" || "$segment" == "$prefix "* ]]; then
      _WRAP_REWRITE="bash $gate_run_path $label $segment"
      return 0
    fi
  done <"$wrfile"
  return 1
}

_apply_wrap() {
  # $1 = original command (raw, for gate-run.sh detection + chain splitting)
  # $2 = canonical command (env/pipe/pnpm-normalized) for matching AND wrapping
  # $3 = wrap file
  local cmd="$1" canonical="$2" wrfile="$3"
  _WRAP_REWRITE=""
  [[ -s "$wrfile" ]] || return 0

  # Already wrapped — nothing to do. The agent's deliberate invocation of
  # gate-run.sh is the contract being satisfied.
  if echo "$cmd" | grep -qE 'gate-run\.sh'; then
    return 0
  fi

  # Step 1: try the simple canonical form (head segment of any chain).
  if _try_match_wrap_segment "$canonical" "$wrfile"; then
    return 0
  fi

  # Step 2 (0.12.4): if the original command is a compound chain
  # (`pnpm format:write && pnpm lint:check && pnpm test-coverage`), the
  # canonical form only captures the FIRST segment — later segments that
  # might match a [wrap] rule are invisible to the simple match above.
  # Split on `&&`/`||`/`;`, canonicalize each segment independently, and
  # try matching. On match, the WHOLE chain is replaced by the gate-wrap
  # of just that segment: the format:write/lint:check prefix is dropped
  # because basic-check/all-check already runs those steps internally.
  # This closes the most common bypass — chained "warm-up" commands
  # leading to a gated target.
  if echo "$cmd" | grep -qE '(&&|\|\||;)'; then
    local IFS=$'\n'
    local segment seg_canonical
    local _segments_seen=""
    # shellcheck disable=SC2046  # intentional word splitting on newlines
    for segment in $(printf '%s' "$cmd" | sed -E 's/[[:space:]]*(&&|\|\||;)[[:space:]]*/\n/g'); do
      segment=$(printf '%s' "$segment" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
      [[ -z "$segment" ]] && continue
      seg_canonical=$(_canonicalize "$segment")
      [[ -z "$seg_canonical" ]] && continue
      if _try_match_wrap_segment "$seg_canonical" "$wrfile"; then
        # 0.12.5: log which prefix segments got dropped. The "drop the
        # prefix" assumption is safe for `format:write && lint:check`-style
        # warm-ups (basic-check / all-check already run those) but may
        # not be safe for every project's chain. Surface the dropped
        # segments so an operator can spot a load-bearing prefix being
        # discarded.
        if [[ -n "$_segments_seen" ]]; then
          _log_intercept "🔀" "REWRITE-CHAIN" "dropped prefix: $_segments_seen | wrapped: $seg_canonical"
        fi
        return 0
      fi
      [[ -n "$_segments_seen" ]] && _segments_seen="$_segments_seen, "
      _segments_seen="${_segments_seen}${seg_canonical}"
    done
  fi
  return 0
}

_enforce_command_policy() {
  # $1 = original command (pipes/redirects/env intact)
  # $2 = canonical command (env-stripped, pipe-stripped, pnpm-normalized)
  local cmd="$1" canonical="$2"
  local policy="$WORKSPACE/.ralph/command-policy"
  local rwfile="" dnfile="" wrfile="" ptfile=""

  if [[ -f "$policy" ]]; then
    local parsed
    parsed=$(_parse_command_policy "$policy")
    rwfile="${parsed%% *}"
    parsed="${parsed#* }"
    dnfile="${parsed%% *}"
    parsed="${parsed#* }"
    wrfile="${parsed%% *}"
    ptfile="${parsed#* }"
  else
    # Legacy fallback. Only deny + protect; no rewrite, no wrap.
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

  # Enforcement order: rewrite → deny → wrap → protect.
  #
  # 0.12.3 model:
  #   - [rewrite] applies regex transforms to the canonical form (and
  #     anywhere else it appears). Project-specific (e.g. `pnpm nx X → pnpm X`).
  #     Result feeds into all downstream checks.
  #   - [deny] hard-blocks the canonical form. Only path that calls _block().
  #   - [wrap] sets _WRAP_REWRITE to the gate-run.sh-wrapped form, which we
  #     emit via updatedInput at the end. Agent sees the wrapped command
  #     execute transparently.
  #   - [protect] hard-blocks pipe/redirect of bare commands (separate from
  #     wrap because protected scripts may not be gate-runnable).
  #
  # Cleanup is best-effort — temp files in /tmp survive only until next
  # reboot, and the hook process is short-lived. Avoid installing an EXIT
  # trap because _block calls `exit 0` and on macOS `rm -f '/dev/null'`
  # errors out under `set -e`, masking the block result.
  [[ -n "$rwfile" ]] && _apply_rewrites "$canonical" "$rwfile"
  if [[ -n "$_REWRITE_CANONICAL" ]]; then
    canonical="$_REWRITE_CANONICAL"
    # 0.12.4: re-normalize pnpm wrappers after rewrite. A rule like
    # `^pnpm nx (.+)$ | pnpm \1` turns `pnpm nx run api:test-coverage`
    # into `pnpm run api:test-coverage` — without a second pnpm-normalize
    # pass, that wouldn't match `pnpm api:test-coverage` in [wrap] and
    # would slip through. Re-running normalize closes the loop.
    canonical=$(_normalize_pnpm "$canonical")
    _REWRITE_CANONICAL="$canonical"
  fi
  [[ -n "$dnfile" ]] && _apply_deny "$canonical" "$dnfile"
  [[ -n "$wrfile" ]] && _apply_wrap "$cmd" "$canonical" "$wrfile"
  [[ -n "$ptfile" ]] && _apply_protect "$cmd" "$canonical" "$ptfile"

  # No block fired — clean up tempfiles on the success path.
  [[ -n "$rwfile" ]] && rm -f "$rwfile"
  [[ -n "$dnfile" ]] && rm -f "$dnfile"
  [[ -n "$wrfile" ]] && rm -f "$wrfile"
  [[ -n "$ptfile" ]] && rm -f "$ptfile"

  # Decide what to emit. Priority:
  #   1. If [wrap] matched, emit the gate-run.sh-wrapped form (the canonical
  #      is already baked in, so [rewrite] transforms are reflected too).
  #   2. Else if [rewrite] matched (but not wrap), emit the rewritten form.
  #   3. Otherwise return — the agent's original command runs as-is.
  if [[ -n "$_WRAP_REWRITE" ]]; then
    _emit_rewrite "$_WRAP_REWRITE"
  elif [[ -n "$_REWRITE_CANONICAL" ]]; then
    _emit_rewrite "$_REWRITE_CANONICAL"
  fi
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

  # Canonicalize once — env prefix stripped, pipes/redirects stripped, pnpm
  # run/exec normalized. Every downstream check matches against this form
  # so the agent can't slip past via env-vars, pipes, or wrapper aliases.
  local canonical
  canonical=$(_canonicalize "$cmd")

  # --- Direct test tool denial ---
  # Block direct invocations of test tools without gate-run.sh wrapper.
  # Only bypass when the command is going through gate-run.sh itself.
  if ! echo "$cmd" | grep -qE 'gate-run\.sh'; then
    if echo "$canonical" | grep -qE '^(exec )?(vitest|npx vitest|pnpm vitest|yarn vitest|jest|npx jest|cypress|npx cypress|pnpm cypress)(\s|$)'; then
      _block "Direct test runner invocation denied — bypasses the gate-run.sh breadcrumbs the completion guard depends on. Use a script from .ralph/command-policy [wrap] for your test tier (unit/integration/e2e); most accept extra args for targeted runs (e.g. a single spec file). The hook routes it through gate-run.sh automatically."
    fi
    if echo "$canonical" | grep -qE '^(exec )?(tsc|npx tsc|pnpm tsc)\s+--noEmit'; then
      _block "Direct tsc invocation denied — bypasses the gate-run.sh breadcrumbs the completion guard depends on. Use a script from .ralph/command-policy [wrap] that runs type-check (often rolled into a basic-check or dedicated lint script)."
    fi
  fi

  # --- Command-policy enforcement ---
  # Preferred:  .ralph/command-policy  (sections: [rewrite] [deny] [wrap] [protect])
  # Legacy:     .ralph/denied-commands + .ralph/protected-scripts
  # On legacy use, append a one-shot deprecation note to .ralph/errors.log.
  _enforce_command_policy "$cmd" "$canonical"

  # --- Gate-without-write check ---
  if echo "$cmd" | grep -qE 'gate-run\.sh'; then
    local last_write last_gate
    last_write=$(_read_ts "$LAST_WRITE_TS")
    last_gate=$(_read_ts "$LAST_GATE_TS")

    if [[ "$last_gate" -gt 0 ]] && [[ "$last_gate" -ge "$last_write" ]]; then
      # Extract the label from the gate-run.sh invocation for a better message
      local label
      label=$(echo "$cmd" | grep -oE 'gate-run\.sh\s+(basic|final|e2e|lint|custom)' | awk '{print $2}') || label="unknown"
      _block "Gate already ran since last code write — output is cached at .ralph/gates/${label}-latest.{log,exit,summary}. Re-running produces identical output; there is no --force flag, and deleting the breadcrumb files won't bypass this. To run again: edit code to address the failure first, then retry; otherwise read .ralph/gates/${label}-latest.log and diagnose."
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
