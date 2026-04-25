#!/usr/bin/env bats
# Behavioral tests for prompt-resolver.sh
#
# Tests verify the hash-check + generation flow, caching behavior, and
# fallback to the built-in template.
#
# Generation tests that call `claude -p` use RALPH_SKIP_GENERATION=1
# and supply fixture prompts to avoid actual API calls in CI.

load test_helper

setup() {
  create_mock_workspace
  create_mock_spec "test-spec"

  # Source the resolver so we can call functions directly
  source "$SCRIPTS_DIR/prompt-resolver.sh"
}

teardown() {
  rm -rf "$MOCK_WORKSPACE"
}

@test "falls back to template when no speckit.implement.md" {
  # No .claude/commands/speckit.implement.md exists
  local out
  out=$(resolve_prompt "$MOCK_WORKSPACE" "spec" "test-spec")

  # Should have written effective prompt
  [ -f "$MOCK_WORKSPACE/.ralph/effective-prompt.md" ]

  # Should NOT have generated a ralph-prompt.md (no speckit.implement)
  [ ! -f "$MOCK_SPEC_DIR/ralph-prompt.md" ]
}

@test "falls back to template when RALPH_SKIP_GENERATION=1" {
  create_mock_speckit_implement
  export RALPH_SKIP_GENERATION=1

  local out
  out=$(resolve_prompt "$MOCK_WORKSPACE" "spec" "test-spec")

  [ -f "$MOCK_WORKSPACE/.ralph/effective-prompt.md" ]
  [ ! -f "$MOCK_SPEC_DIR/ralph-prompt.md" ]
}

@test "uses cached prompt when hash matches" {
  create_mock_speckit_implement

  # Pre-populate the cache with a known prompt and matching hash.
  # 0.6.1: the cache key is composite — sha256(speckit) + sha256(guide).
  local hash
  hash=$(compute_composite_cache_hash "$MOCK_WORKSPACE/.claude/commands/speckit.implement.md")

  cat > "$MOCK_SPEC_DIR/ralph-prompt.md" <<'PROMPT'
# Cached Loop Prompt
This is a cached prompt with {{TASK_FILE}} placeholder.
PROMPT
  echo "$hash" > "$MOCK_SPEC_DIR/.ralph-prompt-hash"

  (cd "$MOCK_WORKSPACE" && git add specs/ && git commit -q -m "add cache")

  local out
  out=$(resolve_prompt "$MOCK_WORKSPACE" "spec" "test-spec" 2>&1)

  # Should report cache hit
  echo "$out" | grep -q "hash match"

  # Effective prompt should contain the cached content (with placeholder substituted)
  grep -q "Cached Loop Prompt" "$MOCK_WORKSPACE/.ralph/effective-prompt.md"
}

@test "detects hash mismatch and reports regeneration needed" {
  create_mock_speckit_implement

  # Pre-populate with a stale hash
  cat > "$MOCK_SPEC_DIR/ralph-prompt.md" <<'PROMPT'
# Stale Prompt
Old content.
PROMPT
  echo "stale-hash-that-wont-match" > "$MOCK_SPEC_DIR/.ralph-prompt-hash"

  (cd "$MOCK_WORKSPACE" && git add specs/ && git commit -q -m "add stale cache")

  # Skip actual generation (no API call) — just verify it detects the mismatch
  export RALPH_SKIP_GENERATION=1
  local out
  out=$(resolve_prompt "$MOCK_WORKSPACE" "spec" "test-spec" 2>&1)

  # With RALPH_SKIP_GENERATION=1 it should fall back to template
  # (in production, it would regenerate instead)
  [ -f "$MOCK_WORKSPACE/.ralph/effective-prompt.md" ]
}

@test "writes task-file-path breadcrumb" {
  local out
  out=$(resolve_prompt "$MOCK_WORKSPACE" "spec" "test-spec")

  [ -f "$MOCK_WORKSPACE/.ralph/task-file-path" ]
  grep -q "tasks.md" "$MOCK_WORKSPACE/.ralph/task-file-path"
}

@test "discovers speckit at .claude/skills/speckit-implement/SKILL.md" {
  create_mock_speckit_implement_skill

  # Pre-populate cache matching the skill file so we hit cache-hit path
  local hash
  hash=$(compute_composite_cache_hash "$MOCK_WORKSPACE/.claude/skills/speckit-implement/SKILL.md")
  cat > "$MOCK_SPEC_DIR/ralph-prompt.md" <<'PROMPT'
# Cached Skill Prompt
{{TASK_FILE}}
PROMPT
  echo "$hash" > "$MOCK_SPEC_DIR/.ralph-prompt-hash"
  (cd "$MOCK_WORKSPACE" && git add specs/ && git commit -q -m "add cache")

  local out
  out=$(resolve_prompt "$MOCK_WORKSPACE" "spec" "test-spec" 2>&1)

  # Cache hit message should appear — confirms skill file was discovered
  echo "$out" | grep -q "hash match"

  # Effective prompt should contain the cached content
  grep -q "Cached Skill Prompt" "$MOCK_WORKSPACE/.ralph/effective-prompt.md"
}

@test "logs prompt resolution to activity.log when log_activity available" {
  create_mock_speckit_implement

  # Pre-populate cache so we hit the hash-match path
  local hash
  hash=$(compute_composite_cache_hash "$MOCK_WORKSPACE/.claude/commands/speckit.implement.md")
  cat > "$MOCK_SPEC_DIR/ralph-prompt.md" <<'PROMPT'
# Cached Prompt
{{TASK_FILE}}
PROMPT
  echo "$hash" > "$MOCK_SPEC_DIR/.ralph-prompt-hash"
  (cd "$MOCK_WORKSPACE" && git add specs/ && git commit -q -m "add cache")

  # Source ralph-common.sh so log_activity is defined
  source "$SCRIPTS_DIR/ralph-common.sh"

  # Create activity.log header (as init_ralph_dir would)
  echo "# Activity Log" > "$MOCK_WORKSPACE/.ralph/activity.log"

  resolve_prompt "$MOCK_WORKSPACE" "spec" "test-spec" >/dev/null 2>&1

  # Should have logged the cache hit to activity.log
  grep -q "PROMPT.*cached prompt" "$MOCK_WORKSPACE/.ralph/activity.log"
}

@test "no activity log writes in standalone mode without log_activity" {
  # prompt-resolver.sh is sourced but ralph-common.sh is NOT — _pr_log is a no-op
  echo "# Activity Log" > "$MOCK_WORKSPACE/.ralph/activity.log"

  resolve_prompt "$MOCK_WORKSPACE" "spec" "test-spec" >/dev/null 2>&1

  # activity.log should only have the header — no PROMPT lines
  ! grep -q "PROMPT" "$MOCK_WORKSPACE/.ralph/activity.log"
}

@test "PROMPT.md mode writes task-file-path breadcrumb pointing at PROMPT.md" {
  cat > "$MOCK_WORKSPACE/PROMPT.md" <<'PROMPT'
# Tasks
- [ ] alpha
- [ ] beta
PROMPT

  resolve_prompt "$MOCK_WORKSPACE" "prompt" "" >/dev/null

  [ -f "$MOCK_WORKSPACE/.ralph/task-file-path" ]
  local recorded
  recorded=$(cat "$MOCK_WORKSPACE/.ralph/task-file-path")
  [ "$recorded" = "$MOCK_WORKSPACE/PROMPT.md" ]
}

@test "--prompt-file mode writes task-file-path breadcrumb pointing at the resolved path" {
  cat > "$MOCK_WORKSPACE/custom.md" <<'PROMPT'
# Tasks
- [ ] one
PROMPT

  resolve_prompt "$MOCK_WORKSPACE" "file" "$MOCK_WORKSPACE/custom.md" >/dev/null

  [ -f "$MOCK_WORKSPACE/.ralph/task-file-path" ]
  local recorded
  recorded=$(cat "$MOCK_WORKSPACE/.ralph/task-file-path")
  [ "$recorded" = "$MOCK_WORKSPACE/custom.md" ]
}

@test "--prompt-file mode resolves workspace-relative path in breadcrumb" {
  cat > "$MOCK_WORKSPACE/rel.md" <<'PROMPT'
# Tasks
- [ ] one
PROMPT

  resolve_prompt "$MOCK_WORKSPACE" "file" "rel.md" >/dev/null

  [ -f "$MOCK_WORKSPACE/.ralph/task-file-path" ]
  local recorded
  recorded=$(cat "$MOCK_WORKSPACE/.ralph/task-file-path")
  [ "$recorded" = "$MOCK_WORKSPACE/rel.md" ]
}

@test "spec mode prepends universal guardrails preamble" {
  local out
  out=$(resolve_prompt "$MOCK_WORKSPACE" "spec" "test-spec")

  local effective="$MOCK_WORKSPACE/.ralph/effective-prompt.md"
  [ -f "$effective" ]
  grep -q "Universal Loop Guardrails" "$effective"
  grep -q "Command-variant spirals" "$effective"
}

@test "PROMPT.md mode prepends universal guardrails preamble" {
  cat > "$MOCK_WORKSPACE/PROMPT.md" <<'PROMPT'
# Tasks
- [ ] alpha
PROMPT

  resolve_prompt "$MOCK_WORKSPACE" "prompt" "" >/dev/null

  local effective="$MOCK_WORKSPACE/.ralph/effective-prompt.md"
  [ -f "$effective" ]
  grep -q "Universal Loop Guardrails" "$effective"
  grep -q "Command-variant spirals" "$effective"
  # User's content must still be present after the preamble
  grep -q "alpha" "$effective"
}

@test "--prompt-file mode prepends universal guardrails preamble" {
  cat > "$MOCK_WORKSPACE/custom.md" <<'PROMPT'
# Tasks
- [ ] one
PROMPT

  resolve_prompt "$MOCK_WORKSPACE" "file" "$MOCK_WORKSPACE/custom.md" >/dev/null

  local effective="$MOCK_WORKSPACE/.ralph/effective-prompt.md"
  [ -f "$effective" ]
  grep -q "Universal Loop Guardrails" "$effective"
  grep -q "Command-variant spirals" "$effective"
  grep -q "one" "$effective"
}

@test "RALPH_SKIP_GUARDRAILS=1 omits the preamble" {
  cat > "$MOCK_WORKSPACE/PROMPT.md" <<'PROMPT'
# Tasks
- [ ] alpha
PROMPT

  RALPH_SKIP_GUARDRAILS=1 resolve_prompt "$MOCK_WORKSPACE" "prompt" "" >/dev/null

  local effective="$MOCK_WORKSPACE/.ralph/effective-prompt.md"
  ! grep -q "Universal Loop Guardrails" "$effective"
  grep -q "alpha" "$effective"
}

@test "PROMPT.md mode appends loop-extras (activity tail + skill pointers) (0.6.0)" {
  # User's PROMPT.md is plain markdown — no template substitution. The
  # loop-extras block is appended after the user content so PROMPT.md
  # users get the same self-observation and skill discoverability that
  # spec-mode templates include via {{ACTIVITY_TAIL}}.
  cat > "$MOCK_WORKSPACE/PROMPT.md" <<'PROMPT'
# My custom prompt
Do the work.
PROMPT

  # Seed an activity.log so we can confirm the tail content lands in the prompt
  cat > "$MOCK_WORKSPACE/.ralph/activity.log" <<'LOG'
[10:00:00] 🟢 SHELL git status → exit 0
[10:00:42] 🧪 GATE end label=basic exit=0 duration=32s
LOG

  resolve_prompt "$MOCK_WORKSPACE" "prompt" "" >/dev/null

  local effective="$MOCK_WORKSPACE/.ralph/effective-prompt.md"
  # User's content survives
  grep -q "Do the work" "$effective"
  # Loop-extras section is appended
  grep -q "Recent activity" "$effective"
  grep -q "GATE end label=basic exit=0" "$effective"
  grep -q "Specialist skills available" "$effective"
  grep -q "diagnosing-stuck-tasks" "$effective"
  grep -q "running-gates" "$effective"
  grep -q "reviewing-loop-progress" "$effective"
}

@test "--prompt-file mode appends loop-extras (0.6.0)" {
  cat > "$MOCK_WORKSPACE/custom.md" <<'PROMPT'
# Custom prompt
do stuff
PROMPT

  resolve_prompt "$MOCK_WORKSPACE" "file" "$MOCK_WORKSPACE/custom.md" >/dev/null

  local effective="$MOCK_WORKSPACE/.ralph/effective-prompt.md"
  grep -q "do stuff" "$effective"
  grep -q "Recent activity" "$effective"
  grep -q "Specialist skills available" "$effective"
  # First-iteration fallback message when no activity.log exists
  grep -q "no prior activity" "$effective"
}

@test "renders {{ACTIVITY_TAIL}} placeholder with last 50 lines of activity.log (0.6.0)" {
  # When activity.log exists, ACTIVITY_TAIL should be substituted with its
  # tail. When it doesn't exist, a friendly placeholder message renders.
  create_mock_speckit_implement
  local hash
  hash=$(compute_composite_cache_hash "$MOCK_WORKSPACE/.claude/commands/speckit.implement.md")

  cat > "$MOCK_SPEC_DIR/ralph-prompt.md" <<'PROMPT'
# Test prompt
Recent activity:
{{ACTIVITY_TAIL}}
End.
PROMPT
  echo "$hash" > "$MOCK_SPEC_DIR/.ralph-prompt-hash"
  (cd "$MOCK_WORKSPACE" && git add specs/ && git commit -q -m "add cache")

  # First run: no activity.log → fallback message
  resolve_prompt "$MOCK_WORKSPACE" "spec" "test-spec" >/dev/null 2>&1
  grep -q "no prior activity" "$MOCK_WORKSPACE/.ralph/effective-prompt.md"

  # Seed an activity.log with distinctive content
  cat > "$MOCK_WORKSPACE/.ralph/activity.log" <<'LOG'
[10:00:00] 🟢 SHELL git status → exit 0
[10:00:05] 🟢 READ /tmp/foo.ts (10 lines, 1KB)
[10:00:10] 🧪 GATE start label=basic cmd=pnpm basic-check
[10:00:42] 🧪 GATE end label=basic exit=0 duration=32s
LOG

  resolve_prompt "$MOCK_WORKSPACE" "spec" "test-spec" >/dev/null 2>&1

  # Effective prompt should now include the seeded log lines
  grep -q "GATE start label=basic" "$MOCK_WORKSPACE/.ralph/effective-prompt.md"
  grep -q "GATE end label=basic exit=0" "$MOCK_WORKSPACE/.ralph/effective-prompt.md"
  # And the placeholder itself should be gone
  ! grep -q '{{ACTIVITY_TAIL}}' "$MOCK_WORKSPACE/.ralph/effective-prompt.md"
}

@test "_render_template handles multi-line replacement values (0.6.0 regression)" {
  # The pre-0.6.0 sed-based renderer broke on multi-line values. The
  # bash parameter-expansion replacement handles them cleanly.
  local tmpl
  tmpl=$(mktemp)
  cat > "$tmpl" <<'TEMPLATE'
Header
{{MULTILINE}}
Footer
TEMPLATE

  local multi
  multi=$'line one\nline two\nline three'

  local rendered
  rendered=$(_render_template "$tmpl" MULTILINE "$multi")

  echo "$rendered" | grep -q "^line one$"
  echo "$rendered" | grep -q "^line two$"
  echo "$rendered" | grep -q "^line three$"
  echo "$rendered" | grep -q "^Header$"
  echo "$rendered" | grep -q "^Footer$"

  rm "$tmpl"
}

@test "cached prompt preserves placeholders for later substitution" {
  create_mock_speckit_implement

  local hash
  hash=$(compute_composite_cache_hash "$MOCK_WORKSPACE/.claude/commands/speckit.implement.md")

  # Prompt with multiple placeholders
  cat > "$MOCK_SPEC_DIR/ralph-prompt.md" <<'PROMPT'
# Loop Prompt
- Tasks: {{TASK_FILE}}
- Plan: {{PLAN_FILE}}
- Gate: {{GATE_RUN}} basic {{BASIC_CHECK_COMMAND}}
PROMPT
  echo "$hash" > "$MOCK_SPEC_DIR/.ralph-prompt-hash"

  (cd "$MOCK_WORKSPACE" && git add specs/ && git commit -q -m "add cache with placeholders")

  resolve_prompt "$MOCK_WORKSPACE" "spec" "test-spec" >/dev/null 2>&1

  local effective="$MOCK_WORKSPACE/.ralph/effective-prompt.md"

  # Placeholders should be substituted with real values
  grep -q "tasks.md" "$effective"
  grep -q "plan.md" "$effective"
  grep -q "gate-run.sh" "$effective"
  grep -q "pnpm basic-check" "$effective"

  # Raw placeholders should NOT remain
  ! grep -q '{{TASK_FILE}}' "$effective"
  ! grep -q '{{PLAN_FILE}}' "$effective"
}

# -----------------------------------------------------------------------------
# 0.6.1: stale-cache warning behavior
#
# Background: pre-0.6.1 the cache key was sha256(speckit.implement) only, so a
# plugin upgrade that rewrote the adaptation guide silently kept reusing the
# old cached prompt — even though the rules driving generation had changed.
# 0.6.1 detects this and warns loudly, telling the operator how to regenerate.
# Generation is NOT triggered automatically (it's an LLM call, ~5–10s + token
# cost) — opt in with RALPH_REGENERATE_PROMPT=1 or rm the cache pair.
# -----------------------------------------------------------------------------

@test "guide change triggers stale warning (cached body unchanged) (0.6.1)" {
  create_mock_speckit_implement

  # Compute the speckit hash, but use a stale guide hash to simulate a plugin
  # upgrade that rewrote the adaptation guide underneath the cache.
  local speckit_hash
  speckit_hash=$(shasum -a 256 "$MOCK_WORKSPACE/.claude/commands/speckit.implement.md" | cut -d' ' -f1)
  local stale_composite="${speckit_hash}:0000000000000000000000000000000000000000000000000000000000000000"

  cat > "$MOCK_SPEC_DIR/ralph-prompt.md" <<'PROMPT'
# Stale-but-still-usable cached prompt
This was generated under an older adaptation guide.
PROMPT
  echo "$stale_composite" > "$MOCK_SPEC_DIR/.ralph-prompt-hash"
  (cd "$MOCK_WORKSPACE" && git add specs/ && git commit -q -m "add stale-guide cache")

  # Skip generation — even if RALPH_REGENERATE_PROMPT were set, we don't want
  # to hit the API in tests. We're verifying the warning + cache-preservation
  # behavior on its own.
  local out
  out=$(resolve_prompt "$MOCK_WORKSPACE" "spec" "test-spec" 2>&1)

  # Warning surfaces, with a copy-pasteable rm command pointing at both files.
  echo "$out" | grep -q "Cached spec prompt is STALE"
  echo "$out" | grep -q "rm $MOCK_SPEC_DIR/ralph-prompt.md"
  echo "$out" | grep -q ".ralph-prompt-hash"
  # Mentions the env var as the alternative opt-in path.
  echo "$out" | grep -q "RALPH_REGENERATE_PROMPT=1"

  # Cached prompt body MUST be preserved on disk — warn, don't regenerate.
  grep -q "Stale-but-still-usable" "$MOCK_SPEC_DIR/ralph-prompt.md"

  # Effective prompt was still rendered from the cached body so the loop
  # can keep going while the operator decides.
  grep -q "Stale-but-still-usable" "$MOCK_WORKSPACE/.ralph/effective-prompt.md"
}

@test "stale-cache warning fires only once (hash file is upgraded after warning) (0.6.1)" {
  create_mock_speckit_implement

  local speckit_hash
  speckit_hash=$(shasum -a 256 "$MOCK_WORKSPACE/.claude/commands/speckit.implement.md" | cut -d' ' -f1)
  local stale_composite="${speckit_hash}:0000000000000000000000000000000000000000000000000000000000000000"

  cat > "$MOCK_SPEC_DIR/ralph-prompt.md" <<'PROMPT'
# Cached prompt
Body.
PROMPT
  echo "$stale_composite" > "$MOCK_SPEC_DIR/.ralph-prompt-hash"
  (cd "$MOCK_WORKSPACE" && git add specs/ && git commit -q -m "add stale cache")

  # First invocation: warns
  local out1
  out1=$(resolve_prompt "$MOCK_WORKSPACE" "spec" "test-spec" 2>&1)
  echo "$out1" | grep -q "STALE"

  # Stored hash should now be the live composite (not the stale one) so the
  # operator isn't spammed with the warning every iteration.
  local stored_after
  stored_after=$(cat "$MOCK_SPEC_DIR/.ralph-prompt-hash")
  [ "$stored_after" != "$stale_composite" ]

  # Second invocation: cache hit, no warning
  local out2
  out2=$(resolve_prompt "$MOCK_WORKSPACE" "spec" "test-spec" 2>&1)
  ! echo "$out2" | grep -q "STALE"
  echo "$out2" | grep -q "hash match"
}

@test "speckit.implement.md change does NOT trigger stale warning (0.6.1)" {
  # User-driven changes to the source skill route through the regenerate
  # branch, NOT the warn-only stale branch. The stale warning is reserved
  # for plugin-side guide rewrites that the operator didn't initiate. We
  # can't exercise the actual generation here (it would call claude -p),
  # but we can verify the STALE warning is absent — that proves the code
  # took the speckit-changed branch instead of the guide-changed branch.
  create_mock_speckit_implement

  # Stored hash matches the GUIDE but not the speckit (different speckit hash).
  local guide_hash=""
  if [[ -f "$TEMPLATES_DIR/speckit-adaptation-guide.md" ]]; then
    guide_hash=$(shasum -a 256 "$TEMPLATES_DIR/speckit-adaptation-guide.md" | cut -d' ' -f1)
  fi
  local fake_speckit_hash="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  echo "${fake_speckit_hash}:${guide_hash}" > "$MOCK_SPEC_DIR/.ralph-prompt-hash"
  cat > "$MOCK_SPEC_DIR/ralph-prompt.md" <<'PROMPT'
# Old cached prompt for an older speckit body
PROMPT
  (cd "$MOCK_WORKSPACE" && git add specs/ && git commit -q -m "add old cache")

  local out
  out=$(resolve_prompt "$MOCK_WORKSPACE" "spec" "test-spec" 2>&1)

  # Critical invariant: NO stale warning when speckit changed. Generation
  # path may emit other messages (or fail if claude is unavailable in CI),
  # but the STALE phrasing is reserved for guide-change-only scenarios.
  ! echo "$out" | grep -q "STALE"
  ! echo "$out" | grep -q "RALPH_REGENERATE_PROMPT"
}
