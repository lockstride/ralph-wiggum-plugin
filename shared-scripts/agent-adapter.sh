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

  case "$cli" in
    claude)
      local cmd="claude -p --output-format stream-json --verbose --dangerously-skip-permissions --effort high --model '$esc_model'"
      if [[ -n "$session_id" ]]; then
        cmd="$cmd --resume '$esc_session'"
      fi
      cmd="$cmd '$esc_prompt'"
      echo "$cmd"
      ;;
    cursor-agent)
      local cmd="cursor-agent -p --force --output-format stream-json --model '$esc_model'"
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
      cat <<'JQ'
foreach inputs as $e (
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
           exit_code: (if .is_error then 1 else 0 end)}
      else empty end
    )
  elif $e.type == "result" then
    {kind:"result", duration_ms:($e.duration_ms // 0)}
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
foreach inputs as $e (
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
      | {kind:"tool_result", name:"Shell", cmd:$cmd, bytes:($o | length), exit_code:$ec}
    else empty end
  elif $e.type == "result" then
    {kind:"result", duration_ms:($e.duration_ms // 0)}
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
        echo "150000"
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
