# review_checklist.md — Layer 3 (stable reference)

The lenses the converge/analyze review wave applies. One reviewer agent per lens
(herdr §9.5). Severity-tag every finding P1 (must fix) / P2 (should fix) / P3 (nit).

- **correctness** — does the diff do what the spec's acceptance criteria require?
- **conventions** — does it match the repo's existing patterns and the constitution?
- **security** — only if the diff touches auth, input handling, secrets, or network.
- **spec drift** — `/speckit.analyze`: spec ↔ plan ↔ tasks ↔ code consistency.

Gate: fix all P1s before `06_converge` may complete. Carry P2/P3 into the run report.
