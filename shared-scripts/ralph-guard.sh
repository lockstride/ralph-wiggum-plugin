#!/bin/bash
# Ralph Wiggum: PreToolUse hook guard
#
# Single entry point for all PreToolUse decisions. Dispatches on tool_name
# (Bash, Write, Edit, MultiEdit) to enforce mechanical constraints the
# agent cannot route around:
#
#   - Gate-without-change block (Bash: a gate re-run with no Write/Edit and no
#     working-tree change since that label's last verdict)
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
# The working-tree record each verdict ran against is gate-run.sh's, beside
# the other gate breadcrumbs: .ralph/gates/<label>-latest.tree.
#
# Hook input: JSON on stdin with tool_name and tool_input.
# Hook output: JSON on stdout — a PreToolUse permissionDecision (deny, or
#              allow with updatedInput), or nothing (exit 0) to allow as-is.

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

# Keep in sync with the tool_result branch of agent-adapter.sh's Claude filter.
RALPH_GUARD_DENY_MARKER="[ralph-guard] "

_block() {
  # 0.12.3: Use Claude Code's documented PreToolUse hook response format.
  # The legacy `{"result":"block","reason":"..."}` form is SILENTLY IGNORED
  # by the CLI — every block call before 0.12.3 was a no-op. This was the
  # root cause of every "guard isn't enforcing" symptom: gate-wrapped bypass
  # via pipes, direct vitest invocations, state-tampering rm -rf .ralph/,
  # etc. all went through unblocked because the hook output was unrecognized.
  #
  # 0.12.5: also log to activity.log so operators see the intercept.
  #
  # 0.26.0: the reason reaches the agent as the failed tool call's result, so
  # it opens with RALPH_GUARD_DENY_MARKER. The marker is how agent-adapter.sh
  # tells a denial — the command never ran — from a command that ran and
  # failed, so the parser logs it as a GUARD DENY rather than a SHELL FAIL.
  local reason="$1"
  _log_intercept "⛔" "DENY" "${TOOL_INPUT_CMD:-${TOOL_INPUT_FILE_PATH:-?}} → $reason"
  jq -nc --arg reason "${RALPH_GUARD_DENY_MARKER}${reason}" \
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

# 0.26.0: a package-local binary spelled out by path — `./node_modules/.bin/nx`,
# `../node_modules/.bin/vitest`, or absolute — is exactly what the workspace's
# package manager resolves for `pnpm nx` / `npx nx` / `yarn nx`. Left as a
# path it matches no rule, which makes it an unguarded, uncached way to run
# anything a rule exists for. Rewritten to the package manager's own exec form
# (named by the lockfile), every [rewrite]/[deny]/[wrap] rule and the
# direct-runner denial see the command it is, and wherever the canonical form
# is emitted it still runs the same binary.
_normalize_local_bin() {
  local cmd="$1"
  local re='^([^[:space:]]*/)?node_modules/\.bin/([^[:space:]/]+)(.*)$'
  if [[ "$cmd" =~ $re ]]; then
    local tool="${BASH_REMATCH[2]}" rest="${BASH_REMATCH[3]}" exec_form
    if [[ -f "$WORKSPACE/pnpm-lock.yaml" ]]; then
      exec_form="pnpm"
    elif [[ -f "$WORKSPACE/yarn.lock" ]]; then
      exec_form="yarn"
    else
      exec_form="npx"
    fi
    cmd="$exec_form $tool$rest"
  fi
  echo "$cmd"
}

# Compose the canonicalization pipeline:
#   strip env prefix → strip pipes/redirects → package-local binary path →
#   normalize pnpm wrappers
# The result is the form used for matching against [deny]/[wrap] rules.
# [rewrite] rules are applied on top of this (in _enforce_command_policy)
# to handle project-specific patterns like `pnpm nx X → pnpm X`.
_canonicalize() {
  local cmd
  cmd=$(_strip_env_prefix "$1")
  cmd=$(_strip_pipes_redirects "$cmd")
  cmd=$(_normalize_local_bin "$cmd")
  cmd=$(_normalize_pnpm "$cmd")
  echo "$cmd"
}

# Recognize a command that EXECUTES the gate harness. Two invocation forms
# reach the hook and both must be caught:
#   bash /path/to/shared-scripts/gate-run.sh <label> <command>
#   bash "$(cat .ralph/gate-runner)" <label> <command>
# The second is the indirection every eval-loop sub-agent is instructed to
# use; its literal text never contains "gate-run.sh", so matching that string
# alone skipped the per-label cache AND the tier lock for the entire eval
# phase (0.24.1).
#
# Merely REFERENCING the harness (ls, cat, grep, test -f, wc -l) is not a
# match — the command must actually run it via bash/sh.
_is_gate_invocation() {
  echo "$1" | grep -qE '(^|[;&|] *)(bash|sh) .*(/gate-run\.sh\b|\.ralph/gate-runner)'
}

# Reduce a gate invocation to "<label> <command…>" by stripping the runner
# token, whichever form it took. The gate-runner substitution is stripped
# first so a direct gate-run.sh path passes through it untouched.
_gate_invocation_tail() {
  printf '%s' "$1" | sed -E \
    -e 's|.*\.ralph/gate-runner[^)]*\)"?[[:space:]]+||' \
    -e 's|.*/gate-run\.sh[[:space:]]+||'
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

# pnpm's own subcommands: `pnpm <name>` for these never looks for a script.
_is_pnpm_builtin() {
  case "$1" in
    add | audit | bin | cat-file | cat-index | config | create | dedupe | deploy | \
      dlx | doctor | env | exec | fetch | find-hash | i | import | init | install | \
      install-test | it | licenses | link | list | ln | ls | outdated | pack | patch | \
      patch-commit | patch-remove | prune | publish | rb | rebuild | recursive | \
      remove | restart | rm | root | run | run-script | self-update | server | setup | \
      start | stop | store | t | test | tst | un | uninstall | unlink | up | update | \
      upgrade | why)
      return 0
      ;;
  esac
  return 1
}

# 0.26.0: a [rewrite] must not hand the shell a pnpm script that does not exist.
#
# A blanket rule like `^pnpm nx (.+)$ | pnpm \1` is right for every nx target
# with a same-named root script and wrong for every other one: it turns a valid
# `pnpm nx run <project>:<target>` into a `pnpm <project>:<target>` that can
# only fail "command not found", which reads as a broken command and invites a
# hunt for a spelling the policy does not see. When the rewritten
# `pnpm <name>` names no root script, pnpm subcommand or package-local binary,
# deny it instead and say which scripts do exist.
#   $1 = rewritten canonical command
_deny_unresolvable_rewrite() {
  local canonical="$1"
  local re='^pnpm[[:space:]]+([^[:space:]]+)'
  [[ "$canonical" =~ $re ]] || return 0
  local name="${BASH_REMATCH[1]}"
  # A flag (-w, --filter, -r …) or a pnpm subcommand is not a script lookup.
  [[ "$name" == -* ]] && return 0
  _is_pnpm_builtin "$name" && return 0
  local pkg="$WORKSPACE/package.json"
  [[ -f "$pkg" ]] || return 0
  [[ -e "$WORKSPACE/node_modules/.bin/$name" ]] && return 0
  local has
  has=$(jq -r --arg n "$name" '(.scripts // {}) | has($n)' "$pkg" 2>/dev/null) || return 0
  [[ "$has" == "false" ]] || return 0

  # Suggest root scripts that run the same target: for an nx-style
  # `<project>:<target>` name, those whose name contains <target>.
  local target="${name#*:}" near
  target="${target#_}"
  near=$(jq -r --arg t "$target" \
    '[(.scripts // {}) | keys[] | select(contains($t))] | .[:8] | map("pnpm " + .) | join(", ")' \
    "$pkg" 2>/dev/null) || near=""
  _block "Command-policy [rewrite] turned this command into '${canonical}', but '${name}' is not a script in package.json or a binary in node_modules/.bin, so it could only fail with 'command not found'. Run a script that exists${near:+ instead — e.g. ${near}}. If the [rewrite] rule itself is wrong, record the corrected row and a one-line why in .ralph/policy-proposal for the operator."
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
  # After [deny], so an explicit deny row keeps its own, more specific reason.
  [[ -n "$_REWRITE_CANONICAL" ]] && _deny_unresolvable_rewrite "$canonical"
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
  #
  # 0.24.1: whichever form we emit is what actually reaches the shell, so the
  # per-label gate cache and the tier lock have to judge THAT form — and have
  # to do it here, because _emit_rewrite exits the hook. Deferring to the
  # caller's check left `last-gate-ts.<label>` unwritten for every auto-wrapped
  # gate, which is the normal path: the cache's `last_gate > 0` precondition
  # could then never hold, so no re-run was ever blocked.
  if [[ -n "$_WRAP_REWRITE" ]]; then
    _guard_gate_invocation "$_WRAP_REWRITE" "$_WRAP_REWRITE"
    _emit_rewrite "$_WRAP_REWRITE"
  elif [[ -n "$_REWRITE_CANONICAL" ]]; then
    _guard_gate_invocation "$_REWRITE_CANONICAL" "$_REWRITE_CANONICAL"
    _emit_rewrite "$_REWRITE_CANONICAL"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Bash dispatch
# ---------------------------------------------------------------------------

# 0.26.0: judge a deletion one chained command at a time. The command that
# deletes must itself name .ralph as a path component (`.ralph-postmortems/`
# is a different directory) — an `rm` of something else followed by a
# read-only `grep … .ralph/…` later in the chain is not tampering. A deletion
# is `rm`, with or without flags, or `find … -delete`, once env assignments and
# the sudo/command/builtin/exec/nohup/time/xargs wrappers in front are peeled.
_deny_ralph_deletion() {
  local cmd="$1"
  local ralph_path='(^|[^A-Za-z0-9_.-])\.ralph([^A-Za-z0-9_.-]|$)'
  local assignment='^[A-Za-z_][A-Za-z0-9_]*='
  local _sep seg first in_xargs skip_value
  _sep=$(printf '\037')
  local IFS="$_sep"
  # shellcheck disable=SC2046  # intentional word splitting on the sentinel
  for seg in $(printf '%s' "$cmd" | tr '\n' "$_sep" |
    sed -E "s/[[:space:]]*(&&|\|\||;|\||&)[[:space:]]*/$_sep/g"); do
    in_xargs=0
    skip_value=0
    # Peel the words in front of the command that actually runs.
    while :; do
      seg="${seg#"${seg%%[![:space:]]*}"}"
      first="${seg%%[[:space:]]*}"
      [[ -n "$first" ]] || break
      if [[ $skip_value -eq 1 ]]; then
        skip_value=0
      elif [[ $in_xargs -eq 1 && "$first" == -* ]]; then
        # xargs options, plus the value of those that take it separately.
        case "$first" in
          -n | -I | -L | -P | -d | -E | -s) skip_value=1 ;;
        esac
      else
        case "$first" in
          xargs) in_xargs=1 ;;
          sudo | command | builtin | exec | nohup | time) ;;
          *=*) [[ "$first" =~ $assignment ]] || break ;;
          *) break ;;
        esac
      fi
      seg="${seg#"$first"}"
    done
    case "$first" in
      rm | '\rm' | */rm)
        if printf '%s' "$seg" | grep -qE "$ralph_path"; then
          _block "State tampering denied: cannot delete .ralph/ directory or contents via rm. These are managed by the loop."
        fi
        ;;
      find | */find)
        if printf '%s' "$seg" | grep -qE "$ralph_path" &&
          printf '%s ' "$seg" | grep -qE '[[:space:]]-delete[[:space:]]'; then
          _block "State tampering denied: cannot delete .ralph/ contents via find -delete."
        fi
        ;;
    esac
  done
  return 0
}

_guard_bash() {
  local cmd="$TOOL_INPUT_CMD"
  [[ -z "$cmd" ]] && return 0

  # --- State-tampering denial ---
  # Block attempts to delete or manipulate .ralph/ state
  _deny_ralph_deletion "$cmd"
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
  # 0.26.0: every package-manager exec form is covered — _canonicalize maps a
  # `node_modules/.bin/<tool>` path onto whichever of them the lockfile names.
  if ! echo "$cmd" | grep -qE 'gate-run\.sh'; then
    if echo "$canonical" | grep -qE '^(exec )?((npx|pnpm|yarn) )?(vitest|jest|cypress)(\s|$)'; then
      _block "Direct test runner invocation denied — bypasses the gate-run.sh breadcrumbs the completion guard depends on. Use a script from .ralph/command-policy [wrap] for your test tier (unit/integration/e2e); most accept extra args for targeted runs (e.g. a single spec file). The hook routes it through gate-run.sh automatically."
    fi
    if echo "$canonical" | grep -qE '^(exec )?((npx|pnpm|yarn) )?tsc\s+--noEmit'; then
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

  # --- Gate-without-change check (per-label) ---
  # Runs here for a command that already invokes the harness itself. The
  # auto-wrapped path cannot reach this point — _enforce_command_policy
  # exits via _emit_rewrite — so it calls _guard_gate_invocation directly
  # on the wrapped form before emitting (0.24.1).
  _guard_gate_invocation "$cmd" "$canonical"
}

# --- Gate-without-change check (per-label) ---
# Different labels run different commands, so a successful 'basic' does
# NOT make a subsequent 'full' redundant — the cache must be tracked
# per label, not globally. (Without this, [risky] tasks that need 'full'
# after 'basic' would get incorrectly blocked.)
#
# 0.14.2: Only match actual gate invocations — commands where the harness
# is being EXECUTED (via bash/sh), not merely referenced (ls, cat, grep,
# test -f, wc -l, etc.). The previous bare `grep -qE 'gate-run\.sh'`
# caught diagnostic reads, assigned them label "unknown", and blocked
# them via the per-label cache — a false positive that wasted agent turns.
#
# 0.24.1: called from BOTH paths a gate can reach the shell by — the agent
# invoking the harness directly, and the [wrap]/[rewrite] rewrite that
# builds the harness invocation on the agent's behalf. Only reaching it on
# the direct path left the cache unarmed: `last-gate-ts.<label>` was never
# written, so the `last_gate > 0` precondition below could never hold and
# no re-run was ever blocked.
#
#   $1 = command as it will actually run (wrapped form on the rewrite path)
#   $2 = its canonical form, used for the tier comparison
_guard_gate_invocation() {
  local cmd="$1" canonical="$2"
  _is_gate_invocation "$cmd" || return 0

  local label
  label=$(_gate_invocation_tail "$cmd" | awk '{print $1}')
  # An unrecognized label is not a gate we can reason about — enforcing a
  # cache on it would repeat the 0.14.2 false-positive. Let it through.
  case "$label" in
    basic | full | final | unit | integration | e2e | lint | format) ;;
    *) return 0 ;;
  esac

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

  # Drop the runner token and the label, leaving the gated command. Trailing
  # shell segments (`; echo "GATE_EXIT=$?"`, ` | tail -20`) are stripped too —
  # without that the comparison never matched the pin for the eval loop's
  # usual `…; echo` shape, silently disarming the lock.
  local gated_cmd expected_tiers=""
  gated_cmd=$(_gate_invocation_tail "$canonical" | awk '{ $1=""; sub(/^ /, ""); print }')
  gated_cmd=$(_strip_pipes_redirects "$gated_cmd")
  gated_cmd=$(printf '%s' "$gated_cmd" | sed -E 's/[[:space:]]*;.*$//')
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
      _block "The tier-gate command '${gated_cmd}' must run under label '${_expected_pretty}', not '${label}'. A pass under '${label}' lands in a per-label cache the completion/eval guards don't read, AND escapes the '${_expected_pretty}' gate cache — re-running a tier command under a fresh label to fish for green is dodging ownership of the failure. Re-run as: gate-run.sh ${_expected_pretty%%|*} ${gated_cmd}. If that label reports it already ran with nothing changed since, the cache is signalling: FIX the failing code (you own every failure, flaky infra included)."
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

  # 0.26.0: a Write/Edit event is not the only way code changes — a Bash
  # edit re-opens the gate too, via _tree_changed_since_verdict. Checked last,
  # and only when everything else says deny: it is the one costly test.
  if [[ $_inflight -eq 0 ]] && [[ "$_verdict_ts" -ge "$last_gate" ]] &&
    [[ "$last_gate" -gt 0 ]] && [[ "$last_gate" -ge "$last_write" ]] &&
    ! _tree_changed_since_verdict "$label"; then
    _block "Gate '${label}' already ran and nothing has changed since — no Write/Edit, and no tracked or untracked file differs from the tree it ran against. Output is cached at .ralph/gates/${label}-latest.{log,exit,summary}. Re-running produces identical output; there is no --force flag, and deleting the breadcrumb files won't bypass this. To run again: change code to address the failure first, then retry; otherwise read .ralph/gates/${label}-latest.log and diagnose. (Other gate labels can still run — this cache is per-label.)"
  fi

  # Record the per-label gate invocation timestamp
  _write_ts "$last_gate_ts_file"
}

# 0.26.0: whether the working tree differs from the one the label's last
# verdict ran against.
#
# last-write-ts moves only on Write/Edit/MultiEdit, but the agent also edits
# through Bash — python heredocs, `sed -i`, `perl -i`, `cat >` — and a cache
# keyed on tool events alone denies a re-run of code that HAS changed, which
# teaches the agent to route around the gate.
#
# gate-run.sh records the tree's fingerprint (tree-fingerprint.sh) as
# <label>-latest.tree at the END of every run, so whatever the gate itself
# rewrote — a format:write step, test artifacts git does not ignore — is part
# of the record rather than a change. Environmental remediation (nx reset,
# docker restarts) touches no tracked or unignored file and still leaves the
# gate cached. A Bash edit made while the same label's gate is running lands
# inside that record and is not seen as a change; a Write/Edit then still is.
#
# Can only re-open a gate, never close one: no record, or no fingerprint now,
# means "unknown" and the timestamps alone decide.
_tree_changed_since_verdict() {
  local label="$1"
  local recorded current
  recorded=$(cat "$WORKSPACE/.ralph/gates/${label}-latest.tree" 2>/dev/null) || recorded=""
  [[ -n "$recorded" ]] || return 1
  current=$(bash "$PLUGIN_ROOT/shared-scripts/tree-fingerprint.sh" "$WORKSPACE" 2>/dev/null) || current=""
  [[ -n "$current" && "$current" != "$recorded" ]]
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
      .ralph/handoff.md | .ralph/errors.log | .ralph/guardrails.md | .ralph/diagnosis.md | .ralph/progress.md | .ralph/acceptance-report.md | .ralph/policy-proposal)
        # Allowed.
        # 0.20.0: policy-proposal is the sanctioned answer to "the pinned
        # command in .ralph/command-policy is the thing that's wrong". An
        # agent that diagnosed a stale [gates] pin used to have NO legal move:
        # command-policy is loop-managed and editing it is denied (correctly —
        # a loop that can rewrite its own completion bar has no bar), so the
        # run deadlocked. This is a proposal channel, not policy: nothing
        # reads it back, the guard and the gate cache are unchanged, and the
        # operator decides whether to apply it. It ships in the post-mortem
        # bundle (_write_postmortem) so the decision has the evidence.
        # acceptance-report.md is writable because it is the eval loop's
        # primary output: the orchestrator (running-acceptance-evaluation)
        # appends History lines, and the verifier sub-agent
        # (verifying-acceptance-criteria) records gaps and Status. It lives
        # under .ralph/ (per-run state, gitignored) but is not commit-tracked
        # so writing it never leaks into git history.
        ;;
      *)
        _block "Write to '$rel_path' denied. Files under .ralph/ (except handoff.md, errors.log, guardrails.md, diagnosis.md, progress.md, acceptance-report.md, policy-proposal) are managed by the loop. If you believe .ralph/command-policy itself is wrong (e.g. a [gates] tier pins a command this run has since changed), do NOT edit it — write .ralph/policy-proposal with the rows you believe are correct and a one-line why, then stop. The operator applies it."
        ;;
    esac
  fi

  # Block writes to the external state directory
  if [[ "$path" == "$STATE_DIR"* ]]; then
    _block "Write to ralph state directory denied. State files are managed by the hook."
  fi

  # --- Record WRITE event ---
  # last-write-ts invalidates the per-label gate cache: a gate stays cached
  # until the agent writes code (or the working tree otherwise changes — see
  # _tree_changed_since_verdict). Only *code/artifact* writes should count.
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
