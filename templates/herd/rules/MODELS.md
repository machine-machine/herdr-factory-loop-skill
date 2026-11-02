# Which model for which herd task

The skill default. A team's own choice is a decision and lives in its decisions register; copy this
file to `.m2herd/rules/MODELS.md` only as a pointer to that decision, never as a second copy of it.

A slice picks its model in the task header (`model:`, default `claude-opus-5-5`; `effort:`, default
`high`). The board shows the pair at the end of each row: `O·hi`, `F·hi`, `S·md`. Model ids used by
the scripts: Opus 5.5 = `claude-opus-5-5`, Fable 5.1 = `claude-fable-5-1`, Sonnet 5.5 =
`claude-sonnet-5-5`.

| Task | Model | Effort | Why |
|---|---|---|---|
| Orchestrator: triage, plan, accept, packages, merge | Opus 5.5 (Fable 5.1 when Opus panes hang) | high | Long sessions with many small decisions and the merge gate; Opus holds the thread. When Opus panes loop on refused API connections, Fable keeps the herd moving. |
| Pre-start check of the herd cut (hot files, pairs) | Fable 5.1, one agent | high | A second model's look at the cut finds the hot files and missing pairs the planner did not see. One agent is enough — it reads, it does not build. |
| Worker: implementation with clear acceptance | Opus 5.5 | high | Fast and dependable when the acceptance is written down; most slices are this. |
| Worker: fuzzy domain logic, new data model, many open questions | Fable 5.1 | high | Better at holding open questions, recording decisions and asking instead of inventing. |
| Fix after review | same model, same session (`--resume`); switch model after the 2nd orange round at the same spot | as worker | The session already has the context and the reasons. Two failed rounds at one spot mean a blind spot of that model; a fresh model sees it. |
| Main reviewer | the other model than the worker | high; xhigh for merge/auth/migration/hot-file probes | A model reviewing its own kind of reasoning tends to confirm it. Merge, auth, migration and hot files are where a missed bug costs most. |
| Skeptics per medium/high finding | one Opus 5.5 + one Fable 5.1 | medium | Two models disagreeing is the signal; each checks one finding, so medium effort is enough. |
| Conflict resolution, restacking | Opus 5.5 | high | Mechanical but must be exact (`rebase --onto`, `range-diff` with only `=` lines). |
| Data digging, measurement | Opus 5.5 | medium | Many queries, little judgement per step; numbers are checked against a command anyway. |
| Team-facing ticket text | Opus 5.5 | high | Plain words for readers without the technical context; tone matters more than speed. |
| Mechanical bulk (screenshots, list diff, lint/rename, first drafts) | Sonnet 5.5 | medium — never review, skeptic, domain slice or code on a herd branch | Cheap and fast for work whose result is checked mechanically. Never where its output is trusted as judgement or merged. |

## Rules file per role

Each table row above runs under one rules file; `herd-context <role> <herd> [<slice>]` renders it.

| Rules file | `herd-context` role | Table row(s) |
|---|---|---|
| `ORCHESTRATOR.md` | `orchestrator` (no slice) | Orchestrator; conflict resolution, restacking; team-facing ticket text |
| `HERD-CUT.md` | `herd-cut` (no slice) | Pre-start check of the herd cut |
| `WORKER.md` | `worker` | Worker (both rows); fix after review (its "Fix round" section) |
| `REVIEWER.md` | `reviewer` | Main reviewer; skeptics (its "As a skeptic" section — the loop points skeptics at the reviewer context) |
| `FIXER.md` | `fixer` | Fix after review, only with `fixBy: "fixer"` |

Data digging and mechanical bulk run as one-off agents of the orchestrator without a rules file of
their own; their prompt names what they may touch.

## Settings that follow from the table

- Review loop arg `reviewModel: "other"` (default; `HERD_REVIEW_MODEL` in the spec) picks the main
  reviewer as the model the worker did not use; `"same"` keeps it. When Fable is unavailable the
  loop falls back to Opus. `models: {opus, fable}` overrides the ids.
- `fixBy: "worker"` (default; `HERD_FIX_BY`) sends findings back to the worker's session;
  `"fixer"` runs a separate fixer agent inside the loop (rules in `FIXER.md`).
