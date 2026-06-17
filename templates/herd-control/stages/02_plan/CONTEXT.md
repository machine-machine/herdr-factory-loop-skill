# 02_plan/CONTEXT.md — Layer 2 (stage contract)

## Inputs
- Layer 4 (working): `../01_spec/output/spec.md`.
- Layer 3 (reference): `../../shared/architecture.md`.

## Process
Turn the approved spec into a technical plan: stack, structure, contracts, data model.
For SDD repos run `/speckit.plan`. Solo stage.

## Outputs
- `output/plan.md` (and `research.md`, `data-model.md`, `contracts/` if produced).

## Verify
- Plan is consistent with `shared/architecture.md` and the spec's constraints.

## Herd
```
mode: solo
gate: review
deliverable: output/plan.md
handoff: 03_tasks
```
