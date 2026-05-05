---
name: ralph-plugin-speckit-update
description: Updates the ralph-wiggum-plugin's own Spec Kit integration when a new Spec Kit version is released. Use when Spec Kit releases a new tagged version and the plugin's internal files need to be brought in sync — covers the adaptation guide, prompt-resolver, fallback prompt template, docs, and any skills or tests that reference Spec Kit conventions. Follows the ralph-wiggum-plugin-update workflow for versioning, testing, commit, push, and local install update.
---

# ralph-plugin-speckit-update

Update the ralph-wiggum-plugin's internal Spec Kit integration files to match a new Spec Kit release.

## Step 1 — Understand what changed in Spec Kit

Gather the diff for the new release. There are two sources; use whichever is available:

**Option A — staged diff in a consumer project** (preferred when the user has already applied the upgrade to a project like dmatrix):
```bash
git diff --staged --stat
git diff --staged -- .specify/ .claude/skills/speckit-*/SKILL.md
```
Read the full diffs for changed scripts, templates, manifests, and skill files. Focus on:
- New or renamed bash scripts under `.specify/scripts/bash/`
- Template changes under `.specify/templates/`
- Command naming convention changes (e.g. dot → hyphen: `speckit.implement` → `speckit-implement`)
- Changes to the JSON schemas in `.specify/integration.json`, `.specify/init-options.json`, `.specify/integrations/speckit.manifest.json`
- Changed step logic in `.claude/skills/speckit-*/SKILL.md` files

**Option B — GitHub release page**:
Fetch `https://github.com/github/spec-kit/releases/tag/vX.Y.Z` and read the release notes.

## Step 2 — Identify plugin files that need updating

The plugin files that depend on Spec Kit internals are:

| File | What it depends on |
|---|---|
| `shared-references/templates/speckit-adaptation-guide.md` | Skill/command naming; transformation rules for speckit-implement |
| `shared-references/templates/speckit-prompt.md` | Step-level logic from speckit-implement (fallback loop prompt) |
| `shared-scripts/prompt-resolver.sh` | Candidate lookup paths; log message strings; gen-prompt heredoc |
| `docs/development.md`, `docs/gate-run.md`, `README.md` | Prose references to Spec Kit file names and conventions |
| `tests/prompt-resolver.bats` | Log message string assertions |

For each change found in Step 1, trace which of these files is affected. Be specific — note the exact string, path, or behavior that needs to change.

## Step 3 — Apply the changes

Edit only what is actually affected. Common patterns:

- **Command naming changes** (e.g. `speckit.tasks` → `speckit-tasks`): update every reference across all five file groups above, including log message strings and test assertions.
- **New or renamed setup scripts** (e.g. `check-prerequisites.sh` → `setup-tasks.sh`): update any references in `speckit-prompt.md` and the adaptation guide if they name the script.
- **New JSON output fields** from a setup script: update `speckit-prompt.md` if its per-task flow references the script's output keys.
- **Template structural changes** (new sections, removed directives): update the adaptation guide's transformation rules and example pair if they describe that structure.
- **Candidate lookup path ordering** in `prompt-resolver.sh`: if Spec Kit changed where the skill lives, reorder or add a candidate path.

Do not touch files unrelated to Spec Kit.

## Step 4 — Run tests

```bash
bash lint.sh
```

All 170 tests must pass. If any fail, fix the underlying issue before proceeding — do not skip or work around failing tests.

## Step 5 — Bump the version

This is a **patch** bump (Spec Kit integration maintenance, no new plugin features).

Update `"version"` in `.claude-plugin/plugin.json`.

## Step 6 — Commit, push, and update

Stage all changed files by name (no `git add .`). Write a Conventional Commits message:

```
chore(speckit): align with Spec Kit vX.Y.Z

<bullet summary of what changed and which plugin files were updated>
```

Then:
```bash
git push
ralph --update
```

Confirm `ralph --update` exits successfully and reports the new version.
