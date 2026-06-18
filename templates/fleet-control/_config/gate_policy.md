# gate_policy.md — Layer 3: meta-level gates

- `01_dispatch` gate = **review**: every mission collected; the meta confirms each `done_when`
  is met (from the mission's run report / collected output) before advancing.
- `02_converge` gate = **review**: cross-mission build/lint/test green; P1 review findings fixed.
- **Never auto-merge to `main` or auto-deploy to prod across missions** without explicit human
  authorization, even if a single mission's orchestrator was authorized for its own scope.
- Auto-advance (`gate: auto`) is reserved for stages with a machine-checkable deliverable and no
  cross-mission risk. Default to `review`.
