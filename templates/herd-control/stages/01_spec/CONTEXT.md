# 01_spec/CONTEXT.md — Layer 2 (stage contract)

## Inputs
- Layer 4 (working): `../../inbox/` — the raw intent.
- Layer 3 (reference): `../../_config/spec_format.md`.

## Process
Turn the intent into an implementation-ready spec. For SDD repos run `/speckit.specify`
then `/speckit.clarify`; resolve every `[NEEDS CLARIFICATION]` (ask the human if needed).
This is a **solo** stage — you (the orchestrator) do it; no workers are fanned out.

## Outputs
- `output/spec.md` — the approved spec (or a pointer to `specs/<feature>/spec.md`).

## Verify
- Spec satisfies every requirement in `_config/spec_format.md`. No clarification markers left.

## Herd
```
mode: solo
gate: review
deliverable: output/spec.md
handoff: 02_plan
```
