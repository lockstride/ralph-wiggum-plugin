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
#     gates/rewrite/deny/wrap/protect)
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
# Per-label gate timestamps live at "$STATE_DIR/last-gate-ts.<label>"
# (different gates run different commands, so the cache must be per-label).

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

# Inline copy of _load_gates_from_policy. The guard runs as a standalone
# hook process and does not source ralph-common.sh; keeping a small private
# copy mirrors the existing pattern (see _canonicalize, _normalize_pnpm).
# Keep this implementation in sync with ralph-common.sh:_load_gates_from_policy.
_guard_load_gates() {
  local policy="$1"
  local basic_var="$2" full_var="$3" final_var="$4"
  local basic_cmd="" full_cmd="" final_cmd=""

  if [[ -f "$policy" ]]; then
    local section="" line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      line="$(printf '%s' "$line" | sed -E 's/[[:space:]]+$//')"
      case "$line" in
        "" | \#*) continue ;;
        "[gates]")
          section="gates"
          continue
          ;;
        "["*"]")
          section=""
          continue
          ;;
      esac
      [[ "$section" == "gates" ]] || continue
      [[ "$line" == *"|"* ]] || continue
      key="${line%%|*}"
      value="${line#*|}"
      key="$(printf '%s' "$key" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
      value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
      # shellcheck disable=SC2034  # tier locals are read indirectly via eval below
      case "$key" in
        basic) basic_cmd="$value" ;;
        full) full_cmd="$value" ;;
        final) final_cmd="$value" ;;
      esac
    done <"$policy"
  fi
  eval "$basic_var=\$basic_cmd"
  eval "$full_var=\$full_cmd"
  eval "$final_var=\$final_cmd"
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
#   [wrap]
#   command-prefix | label           # auto-wrapped in gate-run.sh with <label>
#                                    # label ∈ basic|full|final|unit|integration|e2e|lint|format
#
#   [protect]
#   command-prefix                   # bare OK; pipe/redirect denied

# Parse command-policy into four temp files for the four sections.
# Output paths are echoed space-separated:
#   "rewrite_file deny_file wrap_file protect_file"
# Caller is responsible for cleanup. The [gates] section is recognized
# here so its rows don't fall through to other buckets, but its content
# is consumed by _load_gates_from_policy in ralph-common.sh — not by
# this parser's enforcement path.
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
      "[gates]") section="gates" ;;
      "[rewrite]") section="rewrite" ;;
      "[deny]") section="deny" ;;
      "[wrap]") section="wrap" ;;
      "[protect]") section="protect" ;;
      "["*"]") section="" ;;
      *)
        case "$section" in
          rewrite) printf '%s\n' "$line" >>"$rw" ;;
          deny) printf '%s\n' "$line" >>"$dn" ;;
          wrap) printf '%s\n' "$line" >>"$wr" ;;
          protect) printf '%s\n' "$line" >>"$pt" ;;
          gates) ;; # consumed by _load_gates_from_policy in ralph-common.sh
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
  # 0.18.0: when the rewrite routes through gate-run.sh, also pin the Bash
  # tool timeout to its 600000 ms (10 min) ceiling via updatedInput. The
  # framing prompt already ASKS the agent to set this, but the agent forgot in
  # the field (run 140038), so the gate waiter's Bash call was cut at the 120 s
  # default. When Claude Code kills a timed-out Bash call it signals the call's
  # process tree; the detached runner survives, but the SIGINT still reached
  # the wrapped test command's group and recorded a spurious exit=130 on four
  # `full` gates. Forcing the ceiling here makes the fix mechanical, not
  # advisory — the 120 s kill window never opens. Non-gate rewrites keep the
  # tool's own default timeout (no timeout field emitted).
  if [[ "$cmd" == *gate-run.sh* ]]; then
    jq -n --arg cmd "$cmd" \
      '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":$cmd,"timeout":600000}}}' 2>/dev/null
  else
    # Use jq for safe JSON escaping of the command string.
    jq -n --arg cmd "$cmd" \
      '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":$cmd}}}' 2>/dev/null
  fi
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
# label must be one of basic|full|final|unit|integration|e2e|lint|format.
# Missing or unrecognized label → the rule is skipped (no silent fallback).
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
  # 0.14.0: every [wrap] row must specify an explicit, valid label —
  # silent fallback to "basic" hid misclassification. Rows without `|`
  # or with an unrecognized label are skipped (the segment falls through
  # to whatever other policy/check would handle it).
  local segment="$1" wrfile="$2"
  local gate_run_path="${PLUGIN_ROOT:-..}/shared-scripts/gate-run.sh"
  local rule prefix label
  while IFS= read -r rule || [[ -n "$rule" ]]; do
    [[ -z "$rule" ]] && continue
    [[ "$rule" == *"|"* ]] || continue
    prefix="${rule%%|*}"
    label="${rule#*|}"
    prefix="$(printf '%s' "$prefix" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
    label="$(printf '%s' "$label" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')"
    [[ -z "$prefix" || -z "$label" ]] && continue
    case "$label" in
      basic | full | final | unit | integration | e2e | lint | format) ;;
      *) continue ;;
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
    # 0.14.6: split ONLY on shell separators (&&/||/;), never on literal
    # newlines that may live inside a quoted argument such as a multi-line
    # `git commit -m "<body>"`. The old `IFS=$'\n'` word-split on newlines
    # too, so a commit-body line that happened to start with a gated command
    # (e.g. "pnpm all-check …") was mis-detected as a gate target — polluting
    # gates/<label>-latest.cmd and triggering a spurious COMPLETE BLOCKED.
    # Use an ASCII unit-separator (0x1f) sentinel: it cannot appear in a real
    # command line, so splitting on it isolates exactly the shell-level
    # segments while any embedded newline stays inside its segment.
    local _sep
    _sep=$(printf '\037')
    local IFS="$_sep"
    local segment seg_canonical
    local _segments_seen=""
    # shellcheck disable=SC2046  # intentional word splitting on the sentinel
    for segment in $(printf '%s' "$cmd" | sed -E "s/[[:space:]]*(&&|\|\||;)[[:space:]]*/$_sep/g"); do
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

    # 0.14.0: [gates] commands are auto-wrapped under their tier label —
    # the project does not need to duplicate them in [wrap]. We append
    # synthesized wrap rules to the parsed wrap file before enforcement.
    # The command prefix is canonicalized (env-prefix + pipe stripped,
    # pnpm-normalized) so it matches the canonical form the [wrap]
    # matcher uses. (Caveat: env prefixes are dropped at wrap time —
    # if a [gates] command relies on a leading env var, wrap it in a
    # shell script so the env lives inside the script.)
    local _g_basic _g_full _g_final _g_can
    _guard_load_gates "$policy" _g_basic _g_full _g_final
    if [[ -n "$_g_basic" ]]; then
      _g_can=$(_canonicalize "$_g_basic")
      [[ -n "$_g_can" ]] && printf '%s | basic\n' "$_g_can" >>"$wrfile"
    fi
    if [[ -n "$_g_full" ]]; then
      _g_can=$(_canonicalize "$_g_full")
      [[ -n "$_g_can" ]] && printf '%s | full\n' "$_g_can" >>"$wrfile"
    fi
    if [[ -n "$_g_final" ]]; then
      _g_can=$(_canonicalize "$_g_final")
      [[ -n "$_g_can" ]] && printf '%s | final\n' "$_g_can" >>"$wrfile"
    fi
  fi
  # No policy file → no rewrite/deny/wrap/protect rules. Tier-gate
  # validation (in ralph-setup.sh / loop entry points) has already failed
  # the loop if .ralph/command-policy is missing, so this branch only
  # matters for the test harness and the hook running outside an active
  # loop (e.g. interactive debugging). Pass commands through unchanged.

  # Enforcement order: rewrite → deny → wrap → protect.
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
  # Block hand-forging gate breadcrumbs. gate-run.sh is the only writer of
  # .ralph/gates/*-latest.{exit,cmd,log,summary}; the completion guard trusts
  # those files. An agent that can't locate gate-run.sh must not reconstruct
  # them by redirecting into the dir (e.g. `echo 0 > .ralph/gates/final-latest.exit`).
  if echo "$cmd" | grep -qE '(>>?|\btee\b)[[:space:]]*[^|&;]*\.ralph/gates/'; then
    _block "State tampering denied: cannot write .ralph/gates/ breadcrumbs by hand — gate-run.sh owns them and the completion guard trusts them. Run the gate harness instead: bash \"\$(cat .ralph/gate-runner)\" <label> <command> (label in basic|full|final; command from .ralph/command-policy [gates])."
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

  # --- Blanket git-add denial (0.15.4) ---
  # `git add .` / `-A` / `--all` stage files that were untracked at loop start,
  # committing orphans unrelated to the current task and tripping the
  # orphan-leak detector. The framing prompt already asks for explicit-path
  # staging (0.15.2), but a prompt rule alone did not stop it in practice, so
  # make it enforceable. Deny only the blanket forms: explicit paths
  # (`git add src/foo.ts`), `git add -u`/`--update` (tracked modifications
  # only — no untracked files), and `git commit -a` (also tracked-only) are
  # untouched. Matches the canonical head command, so a leading `git add -A`
  # or `git add -A && git commit` is caught while a commit *message* mentioning
  # "git add -A" is not.
  if echo "$canonical" | grep -qE '^(exec )?git[[:space:]]+add([[:space:]]|$)' &&
    echo "$canonical" | grep -qE '(^|[[:space:]])(-A|--all|\.)([[:space:]]|$)'; then
    _block "Blanket 'git add' denied — 'git add .', '-A', and '--all' sweep up files that were untracked at loop start, committing orphans unrelated to this task and tripping the orphan-leak detector. Stage by explicit path instead: git add <path> [<path>…] (run 'git status' first to see exactly what you'd add). To stage only tracked modifications, 'git add -u' is fine."
  fi

  # --- Command-policy enforcement ---
  # .ralph/command-policy: [gates] [rewrite] [deny] [wrap] [protect].
  _enforce_command_policy "$cmd" "$canonical"

  # --- Gate-without-write check (per-label) ---
  # Different labels run different commands, so a successful 'basic' does
  # NOT make a subsequent 'full' redundant — the cache must be tracked
  # per label, not globally. (Without this, [risky] tasks that need 'full'
  # after 'basic' would get incorrectly blocked.)
  #
  # 0.14.2: Only match actual gate invocations — commands where gate-run.sh
  # is being EXECUTED (via bash/sh), not merely referenced (ls, cat, grep,
  # test -f, wc -l, etc.). The previous bare `grep -qE 'gate-run\.sh'`
  # caught diagnostic reads, assigned them label "unknown", and blocked
  # them via the per-label cache — a false positive that wasted agent turns.
  if echo "$cmd" | grep -qE '(^|[;&|] *)(bash|sh) .*/gate-run\.sh\b'; then
    local label
    label=$(echo "$cmd" | grep -oE 'gate-run\.sh\s+(basic|full|final|unit|integration|e2e|lint|format)' | awk '{print $2}') || label="unknown"

    # --- Tier-command label lock (0.14.0) ---
    # The three tier-gate commands declared in [gates] (basic / full / final)
    # are "owned" by their tier labels. Running a tier command under any
    # other label (a) writes the breadcrumb to a per-label cache the tier's
    # downstream consumer doesn't read (e.g. _complete_allowed reads
    # full-latest.{cmd,exit}, not unit-latest.{...}), and (b) escapes the
    # per-label gate cache so the agent can re-run hoping for a different
    # result. That is the "relabel to fish for green" anti-pattern. A flaky
    # or failing gate is the agent's to fix at the source.
    #
    # If the same command is declared for more than one tier (allowed —
    # e.g. full = final), ANY of those tier labels satisfies the lock.
    local _basic_gate _full_gate _final_gate
    _guard_load_gates "$WORKSPACE/.ralph/command-policy" \
      _basic_gate _full_gate _final_gate
    _basic_gate=$(_normalize_pnpm "$_basic_gate")
    _basic_gate=$(printf '%s' "$_basic_gate" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
    _full_gate=$(_normalize_pnpm "$_full_gate")
    _full_gate=$(printf '%s' "$_full_gate" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
    _final_gate=$(_normalize_pnpm "$_final_gate")
    _final_gate=$(printf '%s' "$_final_gate" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')

    local gated_cmd expected_tiers=""
    gated_cmd=$(printf '%s' "$canonical" | sed -E "s|.*gate-run\.sh[[:space:]]+${label}[[:space:]]+||")
    gated_cmd=$(_normalize_pnpm "$gated_cmd")
    gated_cmd=$(printf '%s' "$gated_cmd" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')

    [[ -n "$_basic_gate" && "$gated_cmd" == "$_basic_gate" ]] && expected_tiers="$expected_tiers basic"
    [[ -n "$_full_gate" && "$gated_cmd" == "$_full_gate" ]] && expected_tiers="$expected_tiers full"
    [[ -n "$_final_gate" && "$gated_cmd" == "$_final_gate" ]] && expected_tiers="$expected_tiers final"
    expected_tiers="${expected_tiers# }"

    if [[ -n "$expected_tiers" ]]; then
      local _t _ok=0
      for _t in $expected_tiers; do
        [[ "$_t" == "$label" ]] && {
          _ok=1
          break
        }
      done
      if [[ $_ok -eq 0 ]]; then
        local _expected_pretty="${expected_tiers// /|}"
        _block "The tier-gate command '${gated_cmd}' must run under label '${_expected_pretty}', not '${label}'. A pass under '${label}' lands in a per-label cache the completion/eval guards don't read, AND escapes the '${_expected_pretty}' gate cache — re-running a tier command under a fresh label to fish for green is dodging ownership of the failure. Re-run as: gate-run.sh ${_expected_pretty%%|*} ${gated_cmd}. If that label reports it already ran since your last code edit, the cache is signalling: FIX the failing code (you own every failure, flaky infra included)."
      fi
    fi

    local last_gate_ts_file="$STATE_DIR/last-gate-ts.$label"
    local last_write last_gate
    last_write=$(_read_ts "$LAST_WRITE_TS")
    last_gate=$(_read_ts "$last_gate_ts_file")

    # 0.16.0: gates run detached; the exit-75 protocol makes re-running the
    # same command the CONTINUATION mechanism, not a wasteful repeat. Two
    # cases must pass the per-label cache:
    #   1. A live runner holds the label lock → this invocation joins the
    #      in-flight gate (gate-run.sh serializes; it never double-runs).
    #   2. No verdict landed at/after the last recorded invocation → that
    #      run died without a breadcrumb; a relaunch is legitimate.
    local _inflight=0 _gate_lock="$WORKSPACE/.ralph/gates/.${label}.lock"
    if [[ -d "$_gate_lock" ]]; then
      local _gl_pid
      _gl_pid=$(cat "$_gate_lock/pid" 2>/dev/null || echo "")
      [[ "$_gl_pid" =~ ^[0-9]+$ ]] && kill -0 "$_gl_pid" 2>/dev/null && _inflight=1
    fi
    local _verdict_ts=0 _gate_exit_f="$WORKSPACE/.ralph/gates/${label}-latest.exit"
    if [[ -f "$_gate_exit_f" ]]; then
      _verdict_ts=$(stat -f '%m' "$_gate_exit_f" 2>/dev/null || stat -c '%Y' "$_gate_exit_f" 2>/dev/null || echo 0)
    fi

    if [[ $_inflight -eq 0 ]] && [[ "$_verdict_ts" -ge "$last_gate" ]] &&
      [[ "$last_gate" -gt 0 ]] && [[ "$last_gate" -ge "$last_write" ]]; then
      _block "Gate '${label}' already ran since last code write — output is cached at .ralph/gates/${label}-latest.{log,exit,summary}. Re-running produces identical output; there is no --force flag, and deleting the breadcrumb files won't bypass this. To run again: edit code to address the failure first, then retry; otherwise read .ralph/gates/${label}-latest.log and diagnose. (Other gate labels can still run — this cache is per-label.)"
    fi

    # Record the per-label gate invocation timestamp
    _write_ts "$last_gate_ts_file"
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
      .ralph/handoff.md | .ralph/errors.log | .ralph/guardrails.md | .ralph/diagnosis.md | .ralph/progress.md | .ralph/acceptance-report.md)
        # Allowed.
        # acceptance-report.md is writable because it is the eval loop's
        # primary output: the orchestrator (running-acceptance-evaluation)
        # appends History lines, and the verifier sub-agent
        # (verifying-acceptance-criteria) records gaps and Status. It lives
        # under .ralph/ (per-run state, gitignored) but is not commit-tracked
        # so writing it never leaks into git history.
        ;;
      *)
        _block "Write to '$rel_path' denied. Files under .ralph/ (except handoff.md, errors.log, guardrails.md, diagnosis.md, progress.md, acceptance-report.md) are managed by the loop."
        ;;
    esac
  fi

  # Block writes to the external state directory
  if [[ "$path" == "$STATE_DIR"* ]]; then
    _block "Write to ralph state directory denied. State files are managed by the hook."
  fi

  # --- Record WRITE event ---
  # last-write-ts invalidates the per-label gate cache: a gate stays cached
  # until the agent writes code. Only *code/artifact* writes should count.
  # Writes that reach here under .ralph/ are the allowlisted loop bookkeeping
  # files (handoff/errors/guardrails/diagnosis/progress/acceptance-report) —
  # everything else under .ralph/ was denied above. Bumping the cache for
  # those is a false "code changed" signal: in the eval loop it let the
  # agent's own acceptance-report edits re-open the expensive final gate with
  # no underlying code change (0.15.4). Skip the bump for .ralph/ state files.
  if [[ "$rel_path" != .ralph/* ]]; then
    _write_ts "$LAST_WRITE_TS"
  fi
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
