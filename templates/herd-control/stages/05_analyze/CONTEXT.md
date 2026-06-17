# 05_analyze/CONTEXT.md — Layer 2 (stage contract)

## Inputs
- Layer 4 (working): `../04_implement/output/`, the `wip/04_implement/*` branches.
- Layer 3 (reference): `../../_config/review_checklist.md`.

## Process
Merge the worker branches onto an integration branch, then check it. For SDD repos run
`/speckit.analyze` first (spec↔plan↔tasks↔code drift); CRITICAL findings block the merge.
Then run the review wave: one reviewer agent per lens in `review_checklist.md` (this can be
a small fanout — declare its lenses in `slices.tsv` here if you want the loop to drive it).
Solo by default.

## Outputs
- `output/analyze.md` — consistency report + review findings, P1/P2/P3 tagged.

## Verify
- No CRITICAL `/speckit.analyze` findings. All P1 review findings have an owner/fix.

## Herd
```
mode: solo
gate: review
deliverable: output/analyze.md
handoff: 06_converge
```
