# fleet-control — the meta-orchestrator workspace

ICM workspace for the **meta-orchestrator** (tier 0): the orchestrator of orchestrators.
Driven by `scripts/fleet-loop.sh`. Same folder=desired / socket=observed reconciliation as
`herd-control/`, one level up — its "workers" are **orchestrators**, its "slices" are **missions**.

```
fleet-loop.sh (meta) → herd-loop.sh (orchestrator per mission) → workers (codex/claude/cursor)
```

## Layout
- `FLEET.md` (L0 identity) · `ROUTER.md` (L1 routing)
- `missions.tsv` — the desired orchestrator set: `mission  orchestrator  repo  intent  done_when`
- `goals/<mission>.md` — each orchestrator's generated charter + `/goal`
- `stages/01_dispatch` (fanout: launch+oversee missions) · `stages/02_converge` (solo: integrate+report)
- `_config/` (launch/approval/gate policies, allow/deny, goal_support) · `shared/` (architecture, /goal)
- `_fleet/` (observed: agents.json, missions.ledger.tsv) · `inbox/STEER.md` (live steering)

## Use
```bash
scripts/fleet-loop.sh init   --ws ~/fleet/<name> [--worker claude]
# fill ~/fleet/<name>/missions.tsv  (one row per independent mission)
scripts/fleet-loop.sh tick   --ws ~/fleet/<name>     # one pass
scripts/fleet-loop.sh run    --ws ~/fleet/<name>     # standing loop
scripts/fleet-loop.sh status --ws ~/fleet/<name>
```
Steer live by editing `inbox/STEER.md` (PAUSE/RESUME/KILL <mission>/RESCOPE/GOTO/NOTE).
