# ROUTER.md — Layer 1 (routing)

> Loaded every tick alongside `FLEET.md`. Decide which stage handles the current situation,
> by mission-portfolio shape **and** fleet state. Keep it a lookup table, not prose.

## Route by portfolio shape

| Situation | Route to |
|-----------|----------|
| `missions.tsv` empty / not written yet | stay in `01_dispatch`; ask the human for the portfolio, or derive missions from `inbox/` |
| ≥1 mission with no orchestrator launched | `01_dispatch` (fanout) — `fleet-loop.sh` launches them |
| all orchestrators launched, ≥1 still driving | `01_dispatch` — RECONCILED; wait + tick |
| an orchestrator `blocked` | `01_dispatch` — NEEDS_REVIEW; read `stages/01_dispatch/review/`, decide |
| all missions `done` + collected | advance to `02_converge` |
| missions delivered, cross-mission integration needed | `02_converge` (solo) — you run the integration/report Process |

## Route by mission independence (before writing missions.tsv)

- **Truly independent** (different repos, or disjoint files/services in one repo) → one mission
  (one orchestrator) each. This is the meta-orchestrator's whole reason to exist.
- **Shared files / ordering dependency** → do NOT make them separate missions; either one
  mission whose orchestrator sequences them as stages, or serialize across two ticks.
- **A single small change** → don't meta-orchestrate; don't even herd — just do it (or hand one
  orchestrator a single mission). The meta tier earns its overhead only at ≥2 parallel missions.

## When NOT to be the meta-orchestrator

- One feature, one repo → use a single orchestrator + `herd-loop.sh` directly (tier 1).
- Exploration / unclear scope → clarify first; don't launch orchestrators into ambiguity.
- The missions share a working tree → they'll collide; collapse to one mission.
