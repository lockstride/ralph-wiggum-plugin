#!/bin/bash
# Ralph Wiggum: Agent Adapter
#
# Abstracts the differences between Claude Code (`claude`) and Cursor
# (`cursor-agent`) headless modes so the rest of the loop can stay
# CLI-agnostic. Responsibilities:
#
#   1. agent_build_cmd   — assemble the correct argv for the selected CLI
#   2. agent_normalize   — a jq filter that maps both CLIs' stream-json
#                          events onto a canonical schema the parser reads
#   3. agent_check       — verify the selected CLI is installed and
#                          return a human-readable install hint otherwise
#
# Canonical event schema (one JSON object per line):
#
#   {"kind":"system","model":"<id>"}
#   {"kind":"assistant_text","text":"<chunk>"}
#   {"kind":"tool_use","name":"<Read|Write|Shell|Other>","path":"<path>","cmd":"<cmd>"}
#   {"kind":"tool_result","name":"<Read|Write|Shell|Other>","path":"<path>","cmd":"<cmd>","bytes":N,"lines":N,"exit_code":N}
#   {"kind":"result","duration_ms":N}
#   {"kind":"error","message":"<msg>"}
#   {"kind":"rate_limit","status":"<allowed|rejected>","resets_at":N}
#
# NOTE: YOLO / unattended mode is mandatory. The adapter always passes
# the "skip approval" flag for the chosen CLI. See the warning in
# ralph-setup.sh and the README about blast radius.

set -euo pipefail

# Plugin root — used to register this plugin's PreToolUse / Stop hooks
# with the spawned `claude -p` subprocess. Without `--plugin-dir` for
# our own root, `claude -p` ignores the user's enabled-plugins config
# and our hooks never load — every [wrap], [rewrite], [deny], [protect]
# rule silently becomes a no-op. (0.12.4 fix.)
RALPH_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || RALPH_PLUGIN_ROOT=""

# Normalize CLI name (accept a few common spellings)
agent_normalize_cli_name() {
  local cli="$1"
  case "$cli" in
    claude | claude-code | cc) echo "claude" ;;
    cursor | cursor-agent | ca) echo "cursor-agent" ;;
    *) echo "$cli" ;;
  esac
}

# Check whether the chosen CLI is installed. Prints install hint to stderr
# and returns non-zero if missing.
agent_check() {
  local cli
  cli="$(agent_normalize_cli_name "$1")"

  case "$cli" in
    claude)
      if ! command -v claude >/dev/null 2>&1; then
        cat >&2 <<'EOF'
❌ claude CLI not found

Install Claude Code:
  npm install -g @anthropic-ai/claude-code
  (or see https://docs.claude.com/en/docs/claude-code)

Then run `claude login` once before using Ralph.
EOF
        return 1
      fi
      ;;
    cursor-agent)
      if ! command -v cursor-agent >/dev/null 2>&1; then
        cat >&2 <<'EOF'
❌ cursor-agent CLI not found

Install via:
  curl https://cursor.com/install -fsS | bash
EOF
        return 1
      fi
      ;;
    *)
      echo "❌ Unknown agent CLI: $cli (expected 'claude' or 'cursor-agent')" >&2
      return 1
      ;;
  esac
}

# Build the invocation command for a given CLI.
#
# Args: <cli> <model> <prompt_text> [session_id]
# Prints: a bash -c-safe command string on stdout.
#
# The unattended/skip-approval flag is always included — Ralph cannot
# pause for permission prompts. The sandbox comes from running in a
# clean worktree, not from per-tool approval.
agent_build_cmd() {
  local cli model prompt_text session_id
  cli="$(agent_normalize_cli_name "$1")"
  model="$2"
  prompt_text="$3"
  session_id="${4:-}"

  # Escape all interpolated values for single-quote embedding to
  # prevent shell injection via RALPH_MODEL or session ids.
  local sq_esc="s/'/'\\\\''/g"
  local esc_prompt esc_model esc_session
  esc_prompt=$(printf '%s' "$prompt_text" | sed "$sq_esc")
  esc_model=$(printf '%s' "$model" | sed "$sq_esc")
  esc_session=$(printf '%s' "$session_id" | sed "$sq_esc")

  # Reasoning effort (claude only). Defaults to the per-CLI default
  # (xhigh for claude — the best setting for coding / agentic work).
  # Override with RALPH_EFFORT=low|medium|high|xhigh|max, threaded in
  # from ralph-setup.sh / wt-ralphspec. cursor-agent has no effort knob,
  # so agent_default_effort returns empty and the flag is omitted.
  local effort esc_effort
  effort="${RALPH_EFFORT:-$(agent_default_effort "$cli")}"
  esc_effort=$(printf '%s' "$effort" | sed "$sq_esc")

  case "$cli" in
    claude)
      # Claude Desktop injects ANTHROPIC_API_KEY="" and ANTHROPIC_BASE_URL into
      # child processes. An empty ANTHROPIC_API_KEY triggers API-key auth mode
      # with an invalid credential, causing 401. Unset both so the CLI falls
      # back to the logged-in OAuth session.
      local cmd="unset ANTHROPIC_API_KEY ANTHROPIC_BASE_URL; RALPH_AGENT_GUARD=1 claude -p --output-format stream-json --verbose --dangerously-skip-permissions"
      if [[ -n "$effort" ]]; then
        cmd="$cmd --effort '$esc_effort'"
      fi
      cmd="$cmd --model '$esc_model'"
      # 0.12.4: register THIS plugin so `claude -p` actually loads our
      # PreToolUse hook (ralph-guard.sh) and Stop hook (handoff-check.sh).
      # Without this, every guard / wrap / deny / protect rule is dead
      # code in production — `claude -p` only honors plugins it's
      # explicitly told about, unlike interactive `claude` which reads
      # the user's enabled-plugins config.
      if [[ -n "$RALPH_PLUGIN_ROOT" ]]; then
        local esc_plugin_root
        esc_plugin_root=$(printf '%s' "$RALPH_PLUGIN_ROOT" | sed "$sq_esc")
        cmd="$cmd --plugin-dir '$esc_plugin_root'"
      fi
      # 0.6.0: optional extra plugin-dirs for browser-flow / UI debugging.
      # RALPH_EXTRA_PLUGIN_DIRS is a colon-separated list (RALPH_SETUP detects
      # Playwright at startup and populates this; users may override). Empty
      # by default. Each path becomes one `--plugin-dir <path>` flag so the
      # agent has the corresponding MCP tools available without baking the
      # path into the framing prompt.
      if [[ -n "${RALPH_EXTRA_PLUGIN_DIRS:-}" ]]; then
        local _plugin_dir
        local IFS=:
        for _plugin_dir in $RALPH_EXTRA_PLUGIN_DIRS; do
          [[ -z "$_plugin_dir" ]] && continue
          local esc_dir
          esc_dir=$(printf '%s' "$_plugin_dir" | sed "$sq_esc")
          cmd="$cmd --plugin-dir '$esc_dir'"
        done
      fi
      if [[ -n "$session_id" ]]; then
        cmd="$cmd --resume '$esc_session'"
      fi
      cmd="$cmd '$esc_prompt'"
      echo "$cmd"
      ;;
    cursor-agent)
      local cmd="RALPH_AGENT_GUARD=1 cursor-agent -p --force --output-format stream-json --model '$esc_model'"
      if [[ -n "$session_id" ]]; then
        cmd="$cmd --resume='$esc_session'"
      fi
      cmd="$cmd '$esc_prompt'"
      echo "$cmd"
      ;;
    *)
      echo "Unknown agent CLI: $cli" >&2
      return 1
      ;;
  esac
}

# Return the path to the canonical-schema jq filter for a given CLI.
# The filter reads the CLI's native stream-json on stdin and emits
# one canonical JSON object per line on stdout.
agent_normalize_filter() {
  local cli
  cli="$(agent_normalize_cli_name "$1")"

  case "$cli" in
    claude)
      # Uses foreach+inputs to track tool_use_id -> name/path/cmd across
      # events, so tool_result events carry the real tool identity.
      # Requires jq -n so inputs reads the stream.
      # 0.12.2: `try inputs catch empty` — malformed JSON lines (e.g. numeric
      # literal truncation from the CLI) are silently skipped instead of
      # crashing the entire pipeline.
      cat <<'JQ'
foreach (try inputs catch empty) as $e (
  {};
  if $e.type == "assistant" then
    reduce (($e.message.content // [])[] | select(.type == "tool_use")) as $tu (
      .;
      .[$tu.id] = {
        name: (($tu.name // "Other") | if IN("Read","Edit","Write","NotebookEdit","MultiEdit") then .
              elif . == "Bash" then "Shell" else . end),
        path: ($tu.input.file_path // $tu.input.path // $tu.input.notebook_path // ""),
        cmd: (if $tu.name == "Bash" then ($tu.input.command // "") else "" end)
      }
    )
  else . end;
  if $e.type == "system" and ($e.subtype // "") == "init" then
    {kind:"system", model:($e.model // "unknown")}
  elif $e.type == "assistant" then
    (($e.message.content // [])[] |
      if .type == "text" then
        {kind:"assistant_text", text:(.text // "")}
      elif .type == "tool_use" then
        (.name // "Other") as $tname
        | (.input // {}) as $inp
        | if ($tname | IN("Read","Edit","Write","NotebookEdit","MultiEdit")) then
            {kind:"tool_use", name:$tname, path:($inp.file_path // $inp.path // $inp.notebook_path // "")}
          elif ($tname == "Bash") then
            {kind:"tool_use", name:"Shell", cmd:($inp.command // "")}
          else
            {kind:"tool_use", name:$tname, path:""}
          end
      else empty end
    )
  elif $e.type == "user" then
    . as $state |
    (($e.message.content // [])[] |
      if .type == "tool_result" then
        (.tool_use_id // "") as $tuid
        | ($state[$tuid] // {name:"Other", path:"", cmd:""}) as $info
        | (.content // "") as $c
        | ( if ($c | type) == "string" then $c
            elif ($c | type) == "array" then ($c | map(.text // "") | join("\n"))
            else "" end
          ) as $txt
        | {kind:"tool_result",
           name: $info.name,
           path: $info.path,
           cmd: $info.cmd,
           bytes: ($txt | length),
           lines: (if ($info.name | IN("Read","Edit","Write","NotebookEdit","MultiEdit"))
                   then ($txt | split("\n") | length) else 0 end),
           exit_code: (
             # 0.16.1: gate-run runs detached (0.16.0). Its waiter's transport
             # exit — 75 (still-running) or 70 (runner died) — is NOT the gate
             # verdict. Claude's stream-json exposes only is_error (a boolean),
             # so a still-running 75 would flatten to 1 and be miscounted as a
             # false SHELL FAIL feeding the GUTTER stuck-detector. For a gate-run
             # invocation, recover the real verdict from gate-run's own
             # `=== GATE <label> exit=<N>` marker and treat the transport states
             # (still-running / launched / died) as non-failures (0). Every
             # non-gate command keeps the is_error mapping unchanged.
             if ($info.cmd | test("gate-run")) then
               ([$txt | match("=== GATE [a-z0-9]+ exit=([0-9]+)"; "g")]) as $m
               | if ($m | length) > 0 then ($m[-1].captures[0].string | tonumber)
                 elif ($txt | test("STILL RUNNING|gate launched detached|RUNNER DIED")) then 0
                 else (if .is_error then 1 else 0 end) end
             else (if .is_error then 1 else 0 end) end)}
      else empty end
    )
  elif $e.type == "result" then
    if $e.is_error == true then
      {kind:"error", message:($e.result // "Session failed with is_error=true")}
    else
      {kind:"result", duration_ms:($e.duration_ms // 0)}
    end
  elif $e.type == "rate_limit_event" then
    ($e.rate_limit_info // {}) as $rl
    | {kind:"rate_limit",
       status:($rl.status // "unknown"),
       resets_at:($rl.resetsAt // 0)}
  elif $e.type == "error" then
    {kind:"error", message:($e.error.message // $e.message // "Unknown error")}
  else empty end
)
JQ
      ;;
    cursor-agent)
      # Uses foreach+inputs for consistency with the Claude filter
      # (both require jq -n). State is unused here.
      cat <<'JQ'
foreach (try inputs catch empty) as $e (
  {};
  .;
  if $e.type == "system" and ($e.subtype // "") == "init" then
    {kind:"system", model:($e.model // "unknown")}
  elif $e.type == "assistant" then
    ($e.message.content // []) as $c
    | ( if ($c | type) == "array" then
          ($c | map(select(.type == "text") | .text // "") | join(""))
        else "" end
      ) as $txt
    | if $txt != "" then {kind:"assistant_text", text:$txt} else empty end
  elif $e.type == "tool_call" and ($e.subtype // "") == "completed" then
    if ($e.tool_call.readToolCall.result.success // null) != null then
      ($e.tool_call.readToolCall.args.path // "unknown") as $p
      | ($e.tool_call.readToolCall.result.success.totalLines // 0) as $ln
      | ($e.tool_call.readToolCall.result.success.contentSize // ($ln * 100)) as $b
      | {kind:"tool_result", name:"Read", path:$p, bytes:$b, lines:$ln, exit_code:0}
    elif ($e.tool_call.writeToolCall.result.success // null) != null then
      ($e.tool_call.writeToolCall.args.path // "unknown") as $p
      | ($e.tool_call.writeToolCall.result.success.linesCreated // 0) as $ln
      | ($e.tool_call.writeToolCall.result.success.fileSize // 0) as $b
      | {kind:"tool_result", name:"Write", path:$p, bytes:$b, lines:$ln, exit_code:0}
    elif ($e.tool_call.shellToolCall.result // null) != null then
      ($e.tool_call.shellToolCall.args.command // "unknown") as $cmd
      | ($e.tool_call.shellToolCall.result.exitCode // 0) as $ec
      | (($e.tool_call.shellToolCall.result.stdout // "") + ($e.tool_call.shellToolCall.result.stderr // "")) as $o
      # 0.16.1: cursor-agent exposes the real exitCode, so completed gate
      # verdicts already flow through correctly. Only neutralize gate-run's
      # waiter TRANSPORT codes (75 still-running / 70 died) so they are not
      # counted as shell failures — mirrors the Claude-branch normalization.
      | (if ($cmd | test("gate-run")) and (($ec == 75) or ($ec == 70)) then 0 else $ec end) as $ec2
      | {kind:"tool_result", name:"Shell", cmd:$cmd, bytes:($o | length), exit_code:$ec2}
    else empty end
  elif $e.type == "result" then
    if $e.is_error == true then
      {kind:"error", message:($e.result // "Session failed with is_error=true")}
    else
      {kind:"result", duration_ms:($e.duration_ms // 0)}
    end
  elif $e.type == "error" then
    {kind:"error", message:($e.error.data.message // $e.error.message // $e.message // "Unknown error")}
  else empty end
)
JQ
      ;;
    *)
      echo "Unknown agent CLI: $cli" >&2
      return 1
      ;;
  esac
}

# Pipe native stream-json on stdin → canonical schema on stdout.
#
# Usage:
#   eval "$(agent_build_cmd claude "$MODEL" "$PROMPT")" 2>&1 \
#     | agent_normalize claude \
#     | stream-parser.sh "$workspace"
agent_normalize() {
  local cli
  cli="$(agent_normalize_cli_name "$1")"
  local filter
  filter="$(agent_normalize_filter "$cli")"
  # -n = null input so foreach/inputs reads the stream.
  # --unbuffered for real-time streaming.
  jq -n --unbuffered -c "$filter" 2>/dev/null || true
}

# Default model alias per CLI. Claude defaults to opus[1m] for the
# extended 1M-token context window. Use RALPH_MODEL to override
# (e.g. "sonnet[1m]", "opus", "sonnet" for 200K standard window).
agent_default_model() {
  local cli
  cli="$(agent_normalize_cli_name "$1")"
  case "$cli" in
    claude) echo "opus[1m]" ;;
    cursor-agent) echo "composer-2" ;;
    *) echo "" ;;
  esac
}

# Default reasoning effort per CLI. Claude's main work loop runs at
# "xhigh" — the best setting for coding / agentic work. Override with
# RALPH_EFFORT (low|medium|high|xhigh|max). cursor-agent has no effort
# knob, so it returns empty and the --effort flag is omitted entirely.
agent_default_effort() {
  local cli
  cli="$(agent_normalize_cli_name "$1")"
  case "$cli" in
    claude) echo "xhigh" ;;
    *) echo "" ;;
  esac
}

# Default rotate threshold based on CLI and model (in tokens).
# Models with the [1m] suffix have a 1M-token context window and
# rotate at 700K. Standard models (200K window) rotate at 150K.
agent_default_rotate_threshold() {
  local cli model
  cli="$(agent_normalize_cli_name "$1")"
  model="${2:-}"

  case "$cli" in
    claude)
      if [[ "$model" == *"[1m]"* ]]; then
        echo "700000"
      else
        echo "170000"
      fi
      ;;
    cursor-agent) echo "150000" ;;
    *) echo "150000" ;;
  esac
}

agent_default_warn_threshold() {
  local rotate
  rotate="$(agent_default_rotate_threshold "$1" "${2:-}")"
  echo $((rotate * 7 / 8))
}
