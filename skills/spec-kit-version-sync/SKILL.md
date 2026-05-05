---
name: spec-kit-version-sync
description: Syncs the current project's Spec Kit installation to the latest tagged release or a specified version. Use when you need to upgrade Spec Kit, pin to a specific version, or keep the specify-cli binary and project integration files in sync. Upgrades the specify-cli binary via uv if needed, then runs specify integration upgrade to update scripts, templates, and manifests. Does not commit any changes.
---

# spec-kit-version-sync

Sync this project's Spec Kit files to the target version.

## Step 1 — Determine the target version

If `$ARGUMENTS` is non-empty, treat it as the target version. Strip any leading `v` (so `v0.8.5` becomes `0.8.5`). Confirm the result looks like a valid semver string (`X.Y.Z`). If it doesn't match, stop and report the error.

If `$ARGUMENTS` is empty, fetch the latest tagged release from the GitHub API:

```bash
curl -s https://api.github.com/repos/github/spec-kit/releases/latest
```

Parse the `tag_name` field and strip the leading `v`. If the API call fails or returns no tag, report the error and stop.

## Step 2 — Check the current specify-cli version

```bash
specify --version
```

Parse the version number from the output (the second token after `specify`). If `specify` is not on PATH, proceed to Step 3 (install from scratch).

## Step 3 — Upgrade specify-cli if needed

If the installed version does not match the target version:

```bash
uv tool install --reinstall "specify-cli==$TARGET_VERSION"
```

Confirm the new version with `specify --version`. If the install fails (e.g. the version is not on PyPI), report the error with the exact pip output and stop.

If the installed version already matches the target, skip this step.

## Step 4 — Apply the Spec Kit project upgrade

From the project root (the directory containing `.specify/`):

```bash
specify integration upgrade
```

If the command reports locally-modified files and blocks the upgrade, show the output to the user and stop. **Do not** run with `--force` automatically — that decision belongs to the user.

## Step 5 — Report changes

Run:

```bash
git diff --stat
git diff --name-status
```

Summarize what changed: which files were added, modified, or removed, and the new version now recorded in `.specify/init-options.json`.

**Do not stage or commit any changes.** Leave the working tree exactly as `specify integration upgrade` left it. Staging, committing, and pushing are for the user.
