# gate_policy.md — Layer 3 (stable reference)

What happens when a stage's exit criteria are met. ICM default: **human review between
every stage** ("every output is an edit surface"). This loop honors that by default and
lets you opt specific stages into auto-advance.

Each stage `CONTEXT.md` declares its own gate in its Herd block:

```
gate: review     # STAGE_COMPLETE → stop, notify, wait for `herd-loop.sh advance`
gate: auto       # STAGE_COMPLETE → loop advances to the next stage immediately
```

Recommended defaults:

| Stage | gate | why |
|-------|------|-----|
| 01_spec, 02_plan, 03_tasks | `review` | cheap to review, expensive to get wrong downstream |
| 04_implement | `review` | never auto-advance past unreviewed code |
| 05_analyze | `review` | CRITICAL findings must block the merge |
| 06_converge | `review` | merging + pushing is irreversible-ish |

Set `auto` only on a stage you have run enough times to trust unattended.
The global kill switch: drop `PAUSE` into `inbox/STEER.md` — the loop drains it and stops before any dispatch.
