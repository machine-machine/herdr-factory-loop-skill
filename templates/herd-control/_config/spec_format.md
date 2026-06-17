# spec_format.md — Layer 3 (stable reference)

The shape a spec must take before it can leave `01_spec`. (For SDD repos, this is
satisfied by spec-kit's `specs/<feature>/spec.md` — point this stage's Inputs at it.)

A compliant spec has:
- **User stories** with acceptance criteria (testable, not aspirational).
- **Scope** and explicit **non-goals**.
- **No `[NEEDS CLARIFICATION]` markers** left (resolve via clarify, or ask the human).
- Constraints the build must honor (perf, security, compatibility).
