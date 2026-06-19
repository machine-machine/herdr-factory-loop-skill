# 02_converge/CONTEXT.md — Layer 2 (stage contract)

## Inputs
- Layer 4 (working): `../01_dispatch/output/*.md` (each mission's collected result + its branches).
- Layer 3 (reference): `../../_config/gate_policy.md`, `../../shared/architecture.md`.

## Process
**Solo stage** — the meta-orchestrator runs this; `fleet-loop.sh` only checks the deliverable.
Across the delivered missions:
1. Decide the integration shape — independent PRs per mission, or one integration branch that
   merges each mission's branches (only if they share a repo and you've checked for conflicts).
2. Run the cross-mission gate: build/lint/test on the integrated result; spawn reviewer
   orchestrators/workers if the diff warrants it (correctness / security / conventions).
3. Fix or dispatch fixes for cross-mission P1s (re-open the relevant mission via `RESCOPE`).
4. Write the meta run report to `~/.herdr/runs/<date>-<fleet>.md`: per-mission verdict, the
   `/goal` conditions and whether each held, what compounded, and one `next time` line.
5. Write `output/CONVERGENCE.md` summarizing the portfolio outcome (this is the deliverable).

Destructive cross-mission actions (merges to `main`, prod deploys) are escalated to the human
unless explicitly authorized — see `gate_policy.md`.

## Outputs
- `output/CONVERGENCE.md` — portfolio outcome: each mission's status, branches, gate verdict.
- `~/.herdr/runs/<date>-<fleet>.md` — the compounding run report.

## Verify
- Every mission's `done_when` is satisfied with evidence. Cross-mission integration builds/tests
  green. P1s fixed or explicitly deferred with a reason.

## Fleet
```
mode: solo
gate: review
deliverable: output/CONVERGENCE.md
handoff: DONE
```
