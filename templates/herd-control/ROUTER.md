# ROUTER.md — Layer 1 (routing)

> Navigation only — no instructions. Maps {situation} → stage. The loop reads the
> active-stage pointer from `_fleet/active_stage`; this table is how a *human or
> orchestrator* decides where to point it. ICM extension: routing is also a function
> of **fleet state**, not just task type.

## By task type (cold start — what stage does this intent enter?)

| Intent | Enter stage | Also load | Skip |
|--------|-------------|-----------|------|
| New feature, nothing written yet | `01_spec` | `_config/spec_format.md` | build/fleet docs |
| Spec approved, need a plan | `02_plan` | `shared/architecture.md` | worker prompts |
| Plan approved, break into tasks | `03_tasks` | `02_plan/output/` | — |
| Tasks ready, build it | `04_implement` | `_config/dispatch_policy.md` | research docs |
| Built, check consistency | `05_analyze` | `_config/review_checklist.md` | — |
| Reviewed, merge + report | `06_converge` | `_config/gate_policy.md` | — |
| Channel intent, skip the spec ceremony | `04_implement` (hand-write `slices.tsv` — seed: `slices.tsv.example` at the workspace root) | `_config/dispatch_policy.md` | spec/plan |

## By fleet state (warm — what to do while a stage is active)

Read `_fleet/ledger.tsv` + `_fleet/agents.json`:

| Observed | Route to |
|----------|----------|
| a desired slice has no worker | reconcile: spawn it (loop does this on `tick`) |
| ≥1 worker `blocked` | `_config/approval_policy.md` → auto-approve or escalate to `stages/<stage>/review/` |
| all slices `idle`/`done` & collected | evaluate exit criteria → gate (`_config/gate_policy.md`) |
| `inbox/STEER.md` non-empty | drain it before any dispatch (human is steering) |

## Stage order (numbering = execution order, per ICM)

```
01_spec → 02_plan → 03_tasks → 04_implement → 05_analyze → 06_converge
  solo      solo       solo        FANOUT         solo          solo
```

`solo` = the orchestrator runs the stage's Process itself (one /speckit.* step).
`FANOUT` = the loop fans the stage's `slices.tsv` out to herdr workers in parallel.
