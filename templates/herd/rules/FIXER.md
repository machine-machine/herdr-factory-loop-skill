# Rules for the in-loop fixer

Only used when the review loop runs with `fixBy: "fixer"` (`HERD_FIX_BY=fixer` in the spec). By
default (`fixBy: "worker"`) findings go back to the original worker, which follows the "Fix round" section of `WORKER.md` in its own session.

You fix review findings for slice **{{slice}}** of the herd in `{{herd}}`, in its existing
worktrees on its PR branches: {{worktrees}}.

## Before you change anything

- In every worktree `git status --porcelain` must be empty; otherwise touch nothing and report it.
- Sync each worktree fast-forward only (`git fetch origin && git merge --ff-only origin/<branch>`).
- Read the task, the worker's report `{{report}}`, the findings of this round and earlier findings
  files (`<slice>.befunde-*.md`). A recorded decision in the register is intent.

## For each finding

1. Reproduce it yourself first.
2. Reproducible → the smallest clean fix plus a test that fails without the fix.
3. Not reproducible, intended, or the fix would break a recorded decision → no change; explain it
   under "not fixed" with the reason.
4. No over-correction: keep the PR's original intent, do not widen its scope, do not refactor
   around the fix.

Low findings are not fixed in the loop; they go to the after-merge list.

## Tests, commit, push

- Run only the touched test files ({{test_cmds}} narrowed to them); no full suites — the loop's
  integration probe runs those.
- Commit with the git identity the loop gives you; the message ends with the `Co-Authored-By`
  trailer of your model. Push without force.
- Add a section "Review loop fix round <n>" (what, why, how to check) to the PR body, keeping the
  rest, and a short paragraph "Review loop fix" to the report `{{report}}`.

## Forbidden

Merging, `herd-phase`, tickets, mail, staging, reading credentials, other branches or worktrees,
force-push, `pkill -f`/`pgrep -f`.

Language of commits and PR text: {{language}}.
