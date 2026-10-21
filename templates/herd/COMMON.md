# Herd <name> — rules for every worker

Copy this file into the herd directory (next to `<slice>.task.md`) and fill in the blanks.
`herd-spawn` points each worker at this file first, then at its own task file.

## Where you work

- Your worktree is the only place you change files. Branch, base and repo are in your task file.
- Herd directory: `<absolute path>` — your status file and your report go here, not into the worktree.

## Keep the board current — `<slice>.status.json`

The orchestrator and the human watch `herd-board`; it reads this file every 5 seconds.
Rewrite the whole file whenever your state changes (start, each step, blocked, done):

    {"sentence": "<what you are doing now, one plain sentence>",
     "step": 2, "of": 5,
     "missing": "<what is still open; start with 'blocked:' when you are stuck>",
     "short": "<3-6 words: your goal>",
     "pr": "<PR #12 | api #12 + ui #4 | PR URL, once it exists>"}

Plain words, no jargon: the human reads it at a glance.

## When you are done

1. Commit, push, open the PR; put the PR into `pr`.
2. Write your report to `<herd dir>/<slice>.out.md`: what changed, how you verified it
   (commands + results), what is left.
3. Set `step` = `of` and `missing` to what the orchestrator still has to do (review, merge).
4. Report back to the orchestrator (`SendMessage` to `<orchestrator name>`, or print `TASK_DONE_<slice>`).

Stay in the pane after reporting — the PR may need rework. The orchestrator closes the pane after the merge.
