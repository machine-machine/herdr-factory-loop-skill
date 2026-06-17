# 06_converge/CONTEXT.md — Layer 2 (stage contract)

## Inputs
- Layer 4 (working): `../05_analyze/output/analyze.md`, the integration branch.
- Layer 3 (reference): `../../_config/gate_policy.md`.

## Process
Fix remaining P1s, run the project's full test/lint suite on the integration branch, then
push and open the PR (or hand the branch to the human). Verify against the spec's acceptance
criteria, not just "tests pass". Solo stage. Pushing is escalate-only — see `approval_policy.md`.

## Outputs
- `output/converge.md` — merge result, test/lint verdict, PR link, open P2/P3.
- A run report in `~/.herdr/runs/<date>-<slug>.md` with a `next time:` line (herdr §10).

## Verify
- Acceptance criteria in `01_spec/output/spec.md` are met. Tests green. Run report written.

## Herd
```
mode: solo
gate: review
deliverable: output/converge.md
handoff: DONE
```
