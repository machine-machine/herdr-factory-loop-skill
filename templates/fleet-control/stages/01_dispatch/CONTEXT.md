# 01_dispatch/CONTEXT.md — Layer 2 (stage contract)

## Inputs
- Layer 4 (working): `missions.tsv` (the desired orchestrator set), `goals/<mission>.md` (generated).
- Layer 3 (reference): `../../_config/launch_policy.md`, `../../_config/approval_policy.md`,
  `../../shared/goal_support.md`.

## Process
**Fanout stage** — `fleet-loop.sh` reconciles `missions.tsv` (desired) against
`../../_fleet/missions.ledger.tsv` (observed) every tick:
- a desired mission with no orchestrator → **launch** one in the mission's repo, generate
  `goals/<mission>.md`, send the bootstrap pointer, and **arm its `/goal`** to `done_when`
  (per `goal_support.md`; agents without `/goal` are re-nudged each tick);
- a `blocked` orchestrator → auto-approve or escalate per `approval_policy.md` (escalations → `review/`);
- an `idle` orchestrator whose herd isn't DONE → re-arm its goal (or nudge it onward);
- a `done` mission (its `herd-control/_fleet/active_stage` == `DONE`) → collect to `output/<mission>.md`.

You (the meta) do NOT drive any mission's workers — each orchestrator owns its herd. You only
launch, observe, unblock, and collect. The orchestrators run their own `herd-loop.sh`.

## Outputs
- `output/<mission>.md` — each mission's collected rollup (its herd ledger + final stage).
- `../../_fleet/missions.ledger.tsv` — mission → orchestrator → pane → repo → herd_ws → goal → status.

## Verify
- Every `missions.tsv` row reached `done` and was collected, OR is terminal (`abandoned`/`error`
  with a `review/` note). Each mission's acceptance (its `done_when`) is met per its run report.

## Fleet
```
mode: fanout
gate: review
deliverable: output/
handoff: 02_converge
```
