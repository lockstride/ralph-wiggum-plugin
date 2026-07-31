# Locating the plugin clone

Some plugin skills (`ralph-wiggum-plugin-update`, `eval-ralph`) need to reach the
**development clone** of `ralph-wiggum-plugin` from an arbitrary working directory.
They are normally invoked from the project where the Ralph work is happening — a
consumer repo or a worktree — not from the plugin repo itself, so neither the
current directory nor a hardcoded absolute path can be relied on.

## Two copies exist — pick the right one

| Copy | Path | Use it for |
|------|------|------------|
| **Installed copy** | `${CLAUDE_PLUGIN_ROOT}`, e.g. `~/.claude/plugins/cache/lockstride-marketplace/ralph-wiggum-plugin/<version>/` | Reading shipped references and shared scripts; identifying the version a given run actually used. |
| **Development clone** | resolved below | Anything that reads git history or **writes** — commits, version bumps, tags, releases. |

> **Never write to the installed copy.** Edits there appear to succeed and are then
> silently discarded by the next `ralph --update`, which replaces the whole
> versioned directory. If you find yourself editing a path containing
> `.claude/plugins/cache/`, stop and re-resolve.

## Resolution order

1. **`$RALPH_PLUGIN_DIR`**, if set and it contains `.claude-plugin/plugin.json`.
2. **`~/development/ralph-wiggum-plugin`** — the conventional layout. Tilde-based,
   so it survives a different macOS username.
3. **Search, and verify by git remote** (a directory of the right name is not
   proof; confirm the origin):

   ```bash
   find ~ -maxdepth 4 -type d -name ralph-wiggum-plugin 2>/dev/null | while read -r d; do
     git -C "$d" remote get-url origin 2>/dev/null | grep -q 'ralph-wiggum-plugin' && echo "$d"
   done
   ```

4. **Ask the operator** for the path. Do not guess, and do not silently fall back
   to the installed copy.

Confirm whatever you resolve before acting on it:

```bash
git -C "$dir" rev-parse --show-toplevel
cat "$dir/.claude-plugin/plugin.json"
```

## Shorthand

Steps 1–2 cover the common case and are safe to inline in a skill:

```bash
cd "${RALPH_PLUGIN_DIR:-$HOME/development/ralph-wiggum-plugin}"
```

Fall through to steps 3–4 if that path does not exist or is not a git repo.
