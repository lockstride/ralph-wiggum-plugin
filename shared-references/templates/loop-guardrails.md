# Universal Loop Guardrails

These rules apply to **every** Ralph loop regardless of prompt mode (PROMPT.md, custom prompt file, or spec mode). The mode-specific prompt below may extend them; it must not contradict them.

## Command-variant spirals (general anti-pattern)

When a shell command exits 0, **the output it produced is the answer.** Re-running the same script with different reporters / flags / pipes / parsers to slice that output more narrowly is the single most common form of token waste in unattended loops. Past loops have burned 2+ minutes running 15 variants of the same coverage command, just trying to extract one number that was already in the first run's output.

**Hard rules:**

1. **A successful command's output is authoritative.** Read it (in full, scrolled if needed) before re-invoking. If the output didn't include the data you wanted, the next move is to **read the relevant config or source file** (`vitest.config.ts`, `project.json`, `package.json` scripts, `tsconfig.json`, the test file itself, etc.) — not to re-run with different flags.

2. **Three variants of the same script without an Edit/Write between them = stuck pattern.** Concretely: invoking the same binary or `pnpm` / `nx` / `npx` script three or more times in a row, with different flags each time, and no file edit between them, is treated like a gate-failure debug loop. **Stop tweaking flags.** Read the config. If you still cannot make progress, escalate via `<ralph>GUTTER</ralph>` rather than burn another cycle.

3. **Prefer the project's documented script over hand-rolled invocations.** If the project exposes `pnpm test-coverage`, `pnpm lint`, `pnpm typecheck`, etc., run those — do not re-implement them inline (e.g. `npx vitest run --coverage --coverage.reporter=json --coverage.reportsDirectory=…`). Documented scripts encode the canonical flags; reaching past them to assemble an ad-hoc pipeline almost always means you've lost track of what you're actually looking for.

4. **When the output format isn't what you wanted, the next move is `Read`, not another command.** The format is decided in config or in the test/script source, not on the command line. Read once, decide, then act — do not iterate on the shell.

This generalizes the same discipline that gate runs already enforce (no piping/filtering, no re-running gates "to be safe") to every other command you invoke. Trust the first successful run; read configs to understand outputs; treat repeat invocations of the same script as a signal to stop and think — not as the next thing to try.

---

