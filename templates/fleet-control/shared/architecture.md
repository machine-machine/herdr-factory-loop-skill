# shared/architecture.md — Layer 3: the three-tier model

```
META-ORCHESTRATOR            tier 0   fleet-loop.sh over THIS fleet-control/ workspace
  ├─ orchestrator (mission A)  tier 1   herd-loop.sh over ~/.herdr/fleet/<fleet>/A/ (herd-control)
  │    ├─ worker A1              tier 2   codex/claude/cursor in a worktree
  │    └─ worker A2
  └─ orchestrator (mission B)  tier 1   herd-loop.sh over ~/.herdr/fleet/<fleet>/B/
       ├─ worker B1              tier 2
       └─ worker B2
```

- Each tier reconciles **desired (folder)** vs **observed (herdr socket + lower tier's disk
  state)** and escalates judgment upward via a `STATUS:` line. State is files, all the way down.
- The meta watches orchestrators; orchestrators watch workers. No tier reaches two levels down:
  the meta never sends work to a worker; an orchestrator never reasons about another mission.
- Autonomy flows down via `/goal` Stop hooks (`shared/goal_support.md`); results + escalations
  flow up via `output/` and `review/`.
