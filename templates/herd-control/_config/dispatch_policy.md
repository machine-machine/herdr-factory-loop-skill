# dispatch_policy.md — Layer 3 (stable reference)

How the loop picks a worker and isolates it. Stable across runs — edit deliberately.

## Worker → binary → auto-approve flag

| worker  | herdr integration | binary | flag |
|---------|-------------------|--------|------|
| `codex`  | codex  | `codex` | `--dangerously-bypass-approvals-and-sandbox` |
| `claude` | claude | `claude` | `--dangerously-skip-permissions` |
| `cursor` | cursor | `cursor-agent` | `--force` |

Default worker: **codex** (long-running, focused). Use `claude` for tasks needing broad
context, `cursor` for IDE-style / codebase-aware refactors. A `slices.tsv` row may name
the worker in column 2 to override the default.

Before relying on a worker type, confirm its binary actually launches: `codex --version`,
`claude --version`, `cursor-agent --version`. A worker whose binary errors at startup will
spawn a pane that dies instantly; the loop marks the slice `gone` → `NEEDS_REVIEW` rather
than hanging. (codex + claude are validated end-to-end; cursor needs a healthy cursor-cli.)

## Isolation

- One git worktree per slice: `wip/<stage>/<slice>` off `BASE` (from `herd.conf`).
- Workers spawn `--no-focus` (never steal the orchestrator's pane).
- A worker may touch **only** its slice's files (state this in the slice prompt).

## Slices

The desired set for a fanout stage is `stages/<stage>/slices.tsv`:

```
# slice<TAB>worker(optional)
oauth	codex
rate-limit	codex
audit-log	cursor
```

For SDD, generate it from tasks.md:
`grep -E '^- \[ \] T[0-9]+ \[P\]' tasks.md | grep -oE 'T[0-9]+' | sed 's/$/\tcodex/' > stages/04_implement/slices.tsv`
