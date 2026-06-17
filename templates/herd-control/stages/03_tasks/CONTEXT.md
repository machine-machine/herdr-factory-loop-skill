# 03_tasks/CONTEXT.md — Layer 2 (stage contract)

## Inputs
- Layer 4 (working): `../02_plan/output/plan.md`.

## Process
Break the plan into tasks. Mark independent tasks `[P]` (disjoint files → parallelizable).
For SDD repos run `/speckit.tasks`. Solo stage. Then materialize the dispatch contract for
the next stage:
`grep -E '^- \[ \] T[0-9]+ \[P\]' output/tasks.md | grep -oE 'T[0-9]+' | sed 's/$/\tcodex/' > ../04_implement/slices.tsv`

## Outputs
- `output/tasks.md` — every requirement maps to ≥1 task; `[P]` markers honest.
- `../04_implement/slices.tsv` — the desired worker set for the fanout stage.

## Verify
- Every spec requirement maps to a task. `[P]` tasks really touch disjoint files.

## Herd
```
mode: solo
gate: review
deliverable: output/tasks.md
handoff: 04_implement
```
