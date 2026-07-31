---
name: ralph-wiggum-plugin-update
description: Use this skill when the user wants to implement changes to the ralph-wiggum-plugin, including updating plugin code, bumping the version, writing or updating tests, committing with Conventional Commits, pushing to remote, tagging and publishing a GitHub release, and refreshing the local install via `ralph --update`. Trigger whenever the user says things like "update ralph", "implement this in ralph", "push these changes to ralph", "update the plugin", or describes changes that should be applied to the ralph-wiggum-plugin repo.
argument-hint: "[patch|minor|major] [change note]"
---

# ralph-wiggum-plugin Update Workflow

This skill implements changes to the `ralph-wiggum-plugin` repo, keeping versioning, tests, and git hygiene consistent.

## Step 1: Resolve the development clone

This skill is normally invoked from whatever project you are working in, not from the plugin repo — so resolve the clone before touching anything. Full resolution order (env var → conventional path → search by git remote → ask) is in `${CLAUDE_PLUGIN_ROOT}/shared-references/locating-the-plugin-clone.md`. The common case:

```bash
cd "${RALPH_PLUGIN_DIR:-$HOME/development/ralph-wiggum-plugin}"
git rev-parse --show-toplevel   # confirm you landed in the right git repo
```

If that path does not exist or is not a git repo, follow the full resolution order in the reference; ask the user rather than guessing.

> **Write only to this clone.** `${CLAUDE_PLUGIN_ROOT}` points at the *installed* copy of this very plugin (under `.claude/plugins/cache/`). Edits there look like they worked and are silently wiped by the next `ralph --update`.

## Step 2: Understand the changes

Review the current conversation for context on what needs to be implemented. Extract:
- What is changing (features, fixes, refactors, breaking changes)
- Any explicit instructions the user gave about scope or approach

If the conversation context is ambiguous about what to change, ask the user to clarify before touching any files.

## Step 3: Implement the changes

Make the code changes as discussed. Follow the existing code style and architecture in the repo.

## Step 4: Add or update tests

Add new tests or update existing ones to cover the changes. Tests are [bats](https://bats-core.readthedocs.io/) files in `tests/*.bats` — roughly one per shared script (`gate-run.bats` covers `shared-scripts/gate-run.sh`, `stream-parser.bats` covers `stream-parser.sh`, and so on), with shared setup in `tests/test_helper.bash`. Follow the conventions in the neighbouring test file rather than introducing a new style.

Run the full gate before committing:

```bash
./lint.sh
```

That runs shellcheck, shfmt, and the bats suite — the same checks the pre-commit hook enforces. `./lint.sh --fix` auto-formats with shfmt instead of just reporting.

## Step 5: Determine the version bump

Infer the bump type from the nature of the changes:
- **patch** — bug fixes, minor tweaks, no API changes
- **minor** — new features, backwards-compatible additions
- **major** — breaking changes

If the user specified the bump type explicitly in the conversation, use that instead.

Bump the version in `.claude-plugin/plugin.json` — this is the version source of truth. `ralph --update` reads the `version` field from this manifest to decide whether an update is available, so a git tag alone is **not** enough; the tagged commit must also declare the new version here. (This repo has no `package.json`.)

## Step 6: Commit using Conventional Commits

Stage all changes and write a commit message following the [Conventional Commits](https://www.conventionalcommits.org/) spec:

```
<type>(optional scope): <short description>

[optional body with more detail]

[optional footer — e.g. BREAKING CHANGE: ...]
```

Common types: `feat`, `fix`, `refactor`, `test`, `chore`, `docs`

A pre-commit hook runs the lint/test gate (shellcheck, shfmt, bats). If `bats` is not installed locally it blocks the commit and instructs you to use `--no-verify` explicitly with justification — in that case re-run with `git commit --no-verify` and note in the commit body that bats was unavailable so the gate was skipped.

**Example:**
```
feat(agent): add retry logic on timeout

Implements exponential backoff for transient CLI errors.
Closes #42
```

## Step 7: Push to remote

```bash
git push
```

## Step 8: Tag and publish a GitHub release

Create an annotated git tag and push it, then publish a GitHub release using the `gh` CLI:

```bash
git tag -a v<NEW_VERSION> -m "<commit subject line>"
git push origin v<NEW_VERSION>
gh release create v<NEW_VERSION> --title "v<NEW_VERSION>" --generate-notes
```

- `--generate-notes` auto-populates the release body from commits since the last tag.
- The tag must point at the commit that declares `<NEW_VERSION>` in `.claude-plugin/plugin.json` (the version bump from Step 5). If you tagged before bumping, move the tag: `git tag -fa v<NEW_VERSION> -m "..."` then `git push --force origin v<NEW_VERSION>`.
- If the `gh` CLI is unavailable, report this to the user and skip; do not block the rest of the workflow.

## Step 9: Update the local install

```bash
ralph --update
```

`ralph --update` is a shell function wrapping `claude plugin update ralph-wiggum-plugin@lockstride-marketplace` (falling back to `claude plugin install` if the plugin isn't installed). The marketplace entry sources the plugin straight from `https://github.com/lockstride/ralph-wiggum-plugin.git` with no version pin, so the update pulls the default branch and reads `version` from `.claude-plugin/plugin.json` at HEAD.

That means **Step 7's push is what makes the new version installable** — the GitHub release in Step 8 is for changelog/humans and does not gate the update. Running this before pushing reports no update available.

Confirm the command exits successfully. If it errors, report the output to the user.

## Step 10: Confirm completion

Summarize what was done:
- Files changed
- Version bumped from X → Y
- Commit message used
- GitHub release published (or skipped, with reason)
- Whether `ralph --update` succeeded
