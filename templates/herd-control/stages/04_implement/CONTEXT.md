# 04_implement/CONTEXT.md — Layer 2 (stage contract)

## Inputs
- Layer 4 (working): `slices.tsv` (the desired worker set), `../03_tasks/output/tasks.md`.
- Layer 3 (reference): `../../_config/dispatch_policy.md`, `../../_config/approval_policy.md`.

## Process
**Fanout stage** — the loop reconciles `slices.tsv` (desired) against `../../_fleet/ledger.tsv`
(observed) every tick:
- a desired slice with no worker → spawn one in its own worktree per `dispatch_policy.md`,
  send `prompts/<slice>.md`, record it in the ledger;
- a `blocked` worker → auto-approve or escalate per `approval_policy.md` (escalations land in `review/`);
- an `idle`/`done` worker → collect its output to `output/<slice>.out`, mark it collected.

Workers touch ONLY their slice and commit on `wip/04_implement/<slice>`. Workers never edit
`tasks.md` — you own it. If `prompts/<slice>.md` is missing, the loop generates a scoped default;
edit it and `RESCOPE <slice>` to refine.

## Outputs
- `output/<slice>.out` — each worker's collected result.
- commits on `wip/04_implement/<slice>` branches (the real deliverable).
- `../../_fleet/ledger.tsv` — slice → pane → branch → worktree → status.

## Verify
- Every `slices.tsv` row reached `done` and was collected. Each worker's tests pass.

## Herd
```
mode: fanout
gate: review
deliverable: output/
handoff: 05_analyze
```
