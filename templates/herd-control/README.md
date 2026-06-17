# herd-control — an ICM-steered herdr workspace

A filesystem-native control room for driving a herdr fleet. It marries two ideas:

- **ICM** ([Interpretable Context Methodology](https://arxiv.org/abs/2603.16021)) — the folder
  *is* the agent: numbered stage folders, layered context (identity → routing → stage
  contract → reference → working artifacts), and **state that is reconstructible from disk
  alone**.
- **herdr** — a live fleet of coding agents (codex/claude/cursor) in panes, with
  authoritative lifecycle state over a socket.

The bridge between them is a **reconciliation loop** (`scripts/herd-loop.sh`):

```
folder (desired state)  ─reconcile─►  herdr socket (observed state)
        ▲                                     │
        └──────── _fleet/ (observed, on disk) ◄┘
```

## Layers (ICM)

| Layer | Here | Role |
|-------|------|------|
| 0 identity | `AGENT.md` | orchestrator charter — loaded every tick |
| 1 routing | `ROUTER.md` | which stage handles the situation (by task type **and** fleet state) |
| 2 contract | `stages/NN_*/CONTEXT.md` | per-stage Inputs / Process / Outputs / Verify |
| 3 reference | `_config/`, `shared/`, `stages/*/references/` | stable — internalized as constraints |
| 4 working | `stages/*/output/`, `_fleet/`, `inbox/` | artifacts unique to this run |

## Quick start

```bash
# 1. scaffold a workspace bound to a target repo
scripts/herd-loop.sh init --ws ~/herd/myfeature --repo /path/to/repo --base main

# 2. produce the first deliverable (solo stage 01_spec), e.g. /speckit.specify → output/spec.md
# 3. drive it
scripts/herd-loop.sh tick   --ws ~/herd/myfeature        # one reconciliation pass
scripts/herd-loop.sh run    --ws ~/herd/myfeature        # standing loop (polls)
scripts/herd-loop.sh status --ws ~/herd/myfeature        # see the ledger + active stage
```

`tick` prints a `STATUS:` line — see `AGENT.md` for what each status means and what the
orchestrator should do next. The loop does the **mechanical** work (observe, spawn, collect,
gate); it escalates **judgment** (what to spec, how to fix a P1, non-routine approvals) back
to you via `STATUS: AWAITING_SOLO` / `NEEDS_REVIEW` / `STAGE_COMPLETE`.

## Steering

Edit `inbox/STEER.md` while the loop runs — it drains commands each tick:
`PAUSE`, `RESUME`, `KILL <slice>`, `RESCOPE <slice>`, `GOTO <stage>`, `NOTE <text>`.

## Channel-intent / generic herds (no SDD)

Skip the spec ceremony: `GOTO 04_implement`, hand-write `stages/04_implement/slices.tsv`
(`slice<TAB>worker`), and tick. The loop fans those slices out as workers directly.
