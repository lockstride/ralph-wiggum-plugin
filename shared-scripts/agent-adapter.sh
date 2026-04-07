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

  # Escape prompt for embedding in a single-quoted string
  local esc_prompt
  esc_prompt=$(printf '%s' "$prompt_text" | sed "s/'/'\\\\''/g")

  case "$cli" in
    claude)
      # Claude Code headless: -p <prompt> with stream-json output.
      # --dangerously-skip-permissions grants all tools without prompts.
      # --verbose is required by Claude Code when combining -p with
      # stream-json so that tool calls actually appear in the stream.
      local cmd="claude -p --output-format stream-json --verbose --dangerously-skip-permissions --effort high --model \"$model\""
      if [[ -n "$session_id" ]]; then
        cmd="$cmd --resume \"$session_id\""
      fi
      cmd="$cmd '$esc_prompt'"
      echo "$cmd"
      ;;
    cursor-agent)
      # cursor-agent headless: -p --force with stream-json output.
      # --force is cursor-agent's permissive/unattended mode.
      local cmd="cursor-agent -p --force --output-format stream-json --model \"$model\""
      if [[ -n "$session_id" ]]; then
        cmd="$cmd --resume=\"$session_id\""
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
      cat <<'JQ'
# Claude Code stream-json → canonical events
# Claude emits one JSON object per line with a "type" discriminator.
. as $e
| if .type == "system" and (.subtype // "") == "init" then
    {kind:"system", model:(.model // "unknown")}
  elif .type == "assistant" then
    # Assistant message content is an array of blocks; text and tool_use mixed.
    (.message.content // [])
    | map(
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
    | .[]
  elif .type == "user" then
    # tool_result comes back wrapped in a user message
    (.message.content // [])
    | map(
        if .type == "tool_result" then
          (.content // "") as $c
          | ( if ($c | type) == "string" then $c
              elif ($c | type) == "array" then ($c | map(.text // "") | join("\n"))
              else "" end
            ) as $txt
          | {kind:"tool_result", name:"Other",
             bytes: ($txt | length),
             exit_code: (if .is_error then 1 else 0 end)}
        else empty end
      )
    | .[]
  elif .type == "result" then
    {kind:"result", duration_ms:(.duration_ms // 0)}
  elif .type == "error" then
    {kind:"error", message:(.error.message // .message // "Unknown error")}
  else empty end
JQ
      ;;
    cursor-agent)
      cat <<'JQ'
# cursor-agent stream-json → canonical events
. as $e
| if .type == "system" and (.subtype // "") == "init" then
    {kind:"system", model:(.model // "unknown")}
  elif .type == "assistant" then
    (.message.content // []) as $c
    | ( if ($c | type) == "array" then
          ($c[0].text // "")
        else "" end
      ) as $txt
    | {kind:"assistant_text", text:$txt}
  elif .type == "tool_call" and (.subtype // "") == "completed" then
    if (.tool_call.readToolCall.result.success // null) != null then
      (.tool_call.readToolCall.args.path // "unknown") as $p
      | (.tool_call.readToolCall.result.success.totalLines // 0) as $ln
      | (.tool_call.readToolCall.result.success.contentSize // ($ln * 100)) as $b
      | {kind:"tool_result", name:"Read", path:$p, bytes:$b, lines:$ln, exit_code:0}
    elif (.tool_call.writeToolCall.result.success // null) != null then
      (.tool_call.writeToolCall.args.path // "unknown") as $p
      | (.tool_call.writeToolCall.result.success.linesCreated // 0) as $ln
      | (.tool_call.writeToolCall.result.success.fileSize // 0) as $b
      | {kind:"tool_result", name:"Write", path:$p, bytes:$b, lines:$ln, exit_code:0}
    elif (.tool_call.shellToolCall.result // null) != null then
      (.tool_call.shellToolCall.args.command // "unknown") as $cmd
      | (.tool_call.shellToolCall.result.exitCode // 0) as $ec
      | ((.tool_call.shellToolCall.result.stdout // "") + (.tool_call.shellToolCall.result.stderr // "")) as $o
      | {kind:"tool_result", name:"Shell", cmd:$cmd, bytes:($o | length), exit_code:$ec}
    else empty end
  elif .type == "result" then
    {kind:"result", duration_ms:(.duration_ms // 0)}
  elif .type == "error" then
    {kind:"error", message:(.error.data.message // .error.message // .message // "Unknown error")}
  else empty end
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
  # -c = compact, -R = raw input, but we want parsed JSON, so skip -R.
  # Use --unbuffered for real-time streaming.
  jq --unbuffered -c "$filter" 2>/dev/null || true
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
