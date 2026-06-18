# launch_policy.md — Layer 3: how the meta launches orchestrators

- **One orchestrator per mission**, started in the mission's repo cwd (NOT a worktree — the
  orchestrator creates per-worker worktrees itself via `herd-loop.sh`).
- **Agent choice** (the `orchestrator` column in `missions.tsv`):
  - `claude` — broad-context missions, ambiguous specs, review-heavy work. Supports `/goal`.
  - `codex` — long, focused implementation missions. Supports `/goal`.
  - `cursor` — IDE-style, codebase-aware refactors. No `/goal` → re-nudged each tick.
- herdr requires a **unique agent name**; the loop uses `"<agent>-orch-<mission>"`.
- After launch the loop: sends the bootstrap pointer to `goals/<mission>.md`, then arms `/goal`
  (goal-capable agents) or relies on per-tick re-nudge.
- The orchestrator owns its mission end-to-end. The meta never sends work to a mission's
  *workers* — only to the *orchestrator*.
