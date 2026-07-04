#!/usr/bin/env bats
# Validates skill SKILL.md frontmatter against Anthropic's requirements:
# - YAML frontmatter must declare `name` and `description`
# - `name`: lowercase letters/numbers/hyphens only, ≤ 64 chars, no reserved
#   words ("anthropic", "claude")
# - `description`: non-empty, ≤ 1024 chars, third person, includes both
#   what-it-does and when-to-use
# - SKILL.md body should stay under 500 lines (best-practices guidance)
#
# Reference: https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices

load test_helper

SKILLS_DIR="$PLUGIN_ROOT/skills"

# Helper: extract a single frontmatter field value from a SKILL.md
_skill_field() {
  local skill_md="$1"
  local field="$2"
  awk -v f="$field" '
    /^---$/ { fm = !fm; next }
    fm && $0 ~ "^"f":" {
      sub("^"f":[[:space:]]*", "")
      gsub(/^"/, ""); gsub(/"$/, "")
      print
      exit
    }
  ' "$skill_md"
}

# Discover all SKILL.md files under skills/
_all_skills() {
  find "$SKILLS_DIR" -mindepth 2 -maxdepth 2 -name SKILL.md -type f 2>/dev/null
}

@test "every skill has a SKILL.md file" {
  [ -d "$SKILLS_DIR" ]
  local count
  count=$(_all_skills | wc -l | tr -d ' ')
  [ "$count" -gt 0 ]
}

@test "every skill declares a name in frontmatter" {
  while IFS= read -r skill_md; do
    [ -n "$skill_md" ] || continue
    local name
    name=$(_skill_field "$skill_md" "name")
    [ -n "$name" ] || { echo "no name in $skill_md" >&2; return 1; }
  done < <(_all_skills)
}

@test "every skill declares a description in frontmatter" {
  while IFS= read -r skill_md; do
    [ -n "$skill_md" ] || continue
    local desc
    desc=$(_skill_field "$skill_md" "description")
    [ -n "$desc" ] || { echo "no description in $skill_md" >&2; return 1; }
  done < <(_all_skills)
}

@test "skill name uses only lowercase letters, numbers, and hyphens" {
  while IFS= read -r skill_md; do
    [ -n "$skill_md" ] || continue
    local name
    name=$(_skill_field "$skill_md" "name")
    [[ "$name" =~ ^[a-z0-9-]+$ ]] || { echo "invalid name '$name' in $skill_md" >&2; return 1; }
  done < <(_all_skills)
}

@test "skill name is 64 chars or fewer" {
  while IFS= read -r skill_md; do
    [ -n "$skill_md" ] || continue
    local name
    name=$(_skill_field "$skill_md" "name")
    [ "${#name}" -le 64 ] || { echo "name '$name' exceeds 64 chars in $skill_md" >&2; return 1; }
  done < <(_all_skills)
}

@test "skill name does not contain reserved words 'anthropic' or 'claude'" {
  while IFS= read -r skill_md; do
    [ -n "$skill_md" ] || continue
    local name
    name=$(_skill_field "$skill_md" "name")
    [[ "$name" != *anthropic* ]] || { echo "name '$name' contains 'anthropic' in $skill_md" >&2; return 1; }
    [[ "$name" != *claude* ]] || { echo "name '$name' contains 'claude' in $skill_md" >&2; return 1; }
  done < <(_all_skills)
}

@test "skill description is 1024 chars or fewer" {
  while IFS= read -r skill_md; do
    [ -n "$skill_md" ] || continue
    local desc
    desc=$(_skill_field "$skill_md" "description")
    [ "${#desc}" -le 1024 ] || { echo "description in $skill_md exceeds 1024 chars (${#desc})" >&2; return 1; }
  done < <(_all_skills)
}

@test "skill description includes a 'use when' / 'use for' trigger phrase" {
  # Per best-practices doc: descriptions should specify both WHAT the skill
  # does and WHEN to use it. Heuristic check for trigger language.
  while IFS= read -r skill_md; do
    [ -n "$skill_md" ] || continue
    local desc
    desc=$(_skill_field "$skill_md" "description")
    if ! echo "$desc" | grep -qiE "use (when|for|to)|when (the|a|an|invoking|diagnosing|reviewing|the agent)"; then
      echo "description in $skill_md missing trigger phrase ('use when ...' or similar)" >&2
      echo "  description: $desc" >&2
      return 1
    fi
  done < <(_all_skills)
}

@test "skill body stays under 500 lines (best-practices guidance)" {
  while IFS= read -r skill_md; do
    [ -n "$skill_md" ] || continue
    local lines
    lines=$(wc -l < "$skill_md" | tr -d ' ')
    [ "$lines" -le 500 ] || { echo "$skill_md is $lines lines (limit 500)" >&2; return 1; }
  done < <(_all_skills)
}

@test "expected skills are present" {
  [ -f "$SKILLS_DIR/running-acceptance-evaluation/SKILL.md" ]
  [ -f "$SKILLS_DIR/verifying-acceptance-criteria/SKILL.md" ]
  [ -f "$SKILLS_DIR/addressing-acceptance-gaps/SKILL.md" ]
  [ -f "$SKILLS_DIR/ralph-plugin-speckit-update/SKILL.md" ]
}

@test "ralph-plugin-speckit-update skill is present" {
  [ -f "$SKILLS_DIR/ralph-plugin-speckit-update/SKILL.md" ]
}

@test "verifying-acceptance-criteria requires a fresh final-tier gate before flipping CLEAN" {
  # 0.14.0: eval-* label family collapsed into 'final'. 0.14.11: the gate
  # runner path is resolved from the .ralph/gate-runner breadcrumb (not
  # guessed/hardcoded), and hand-forging breadcrumbs is forbidden.
  local skill_md="$SKILLS_DIR/verifying-acceptance-criteria/SKILL.md"
  [ -f "$skill_md" ]
  grep -qE '\.ralph/gate-runner.*" +final' "$skill_md" \
    || { echo "verifier skill missing breadcrumb gate invocation (cat .ralph/gate-runner ... final)" >&2; return 1; }
  grep -qiE "fresh.*(final|gate)|cached.*does not satisfy|cached .*does not" "$skill_md" \
    || { echo "verifier skill missing freshness-of-gate-run requirement" >&2; return 1; }
  grep -qiE "hand-construct|hand-forg|hand-writ" "$skill_md" \
    || { echo "verifier skill missing the do-not-hand-forge-breadcrumbs prohibition (0.14.11)" >&2; return 1; }
  # Regression guard: the v0.13.x eval-* labels must be gone.
  ! grep -qE "eval-final|eval-rework|eval-\*" "$skill_md" \
    || { echo "verifier skill still references retired eval-* labels" >&2; return 1; }
}

@test "addressing-acceptance-gaps runs final gate via the gate-runner breadcrumb, never hand-forging (0.14.11)" {
  local skill_md="$SKILLS_DIR/addressing-acceptance-gaps/SKILL.md"
  [ -f "$skill_md" ]
  grep -qE '\.ralph/gate-runner.*" +final' "$skill_md" \
    || { echo "rework skill missing breadcrumb gate invocation (cat .ralph/gate-runner ... final)" >&2; return 1; }
  grep -qiE "hand-construct|hand-forg|hand-writ" "$skill_md" \
    || { echo "rework skill missing the do-not-hand-forge-breadcrumbs prohibition (0.14.11)" >&2; return 1; }
}

@test "addressing-acceptance-gaps marks infra-only gaps blocked instead of spinning the heavy gate (0.15.4)" {
  local skill_md="$SKILLS_DIR/addressing-acceptance-gaps/SKILL.md"
  [ -f "$skill_md" ]
  # Anti-spin: don't re-run an unconfirmable heavy gate loop after loop.
  grep -qiE "do not re-run the same heavy gate|Spinning on an unconfirmable heavy gate" "$skill_md" \
    || { echo "rework skill missing the anti-spin (don't re-run the heavy gate) guidance" >&2; return 1; }
  # Heavy final gate runs via the detached harness: foreground waiter call,
  # exit-75 → re-run joins the in-flight gate (0.16.0).
  grep -qiE "foreground" "$skill_md" \
    || { echo "rework skill missing the foreground-waiter gate guidance (0.16.0)" >&2; return 1; }
  grep -qiE "joins the in-flight" "$skill_md" \
    || { echo "rework skill missing the exit-75 join-the-in-flight-gate protocol (0.16.0)" >&2; return 1; }
  # An infra/orchestration failure that isn't feature code is a legit block reason.
  grep -qiE "infra/orchestration failure surfaced by the gate" "$skill_md" \
    || { echo "rework skill missing the infra/orchestration block-reason (0.15.4)" >&2; return 1; }
}
