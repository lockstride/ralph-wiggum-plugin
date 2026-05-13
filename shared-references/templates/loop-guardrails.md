# Universal Loop Guardrails

When a shell command exits 0, its output is the answer. Read it before re-invoking. If you need data in a different format, read the config or source file — don't re-run with different flags.

Use the project's documented scripts (`pnpm test-coverage`, `pnpm lint`, etc.) rather than hand-rolling invocations with ad-hoc flags.

---

