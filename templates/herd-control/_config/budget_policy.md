# budget_policy.md — Layer 3 (stable reference)

How the orchestrator stays inside its context window. Stable across runs — internalize
as a constraint, do not rewrite per run.

## The setting

`herd.conf` carries two keys the loop and hooks share:

```
MODEL=GLM-5.2
BUDGET=384000
```

`BUDGET` is the context window in tokens; `MODEL` names the model it belongs to. Defaults
are **GLM-5.2 / 384000**. Resolution order (first hit wins):

1. `herd.conf` `MODEL` / `BUDGET` (per-workspace override).
2. `~/.hermes/config.yaml` `model.context_length`.
3. Built-in default `GLM-5.2 / 384000`.

The static budget is then **refined by live detection**: `context-budget.sh status` reads
the statusline bridge file (`/tmp/claude-ctx-<session>.json`) for real usage; absent that,
it estimates from bytes (`tokens ≈ ceil(bytes / 4)`).

## Thresholds

Measured as `used_pct` of `BUDGET`:

| level | % of BUDGET | loop behaviour |
|-------|-------------|----------------|
| WARNING  | 60% | advisory only — start thinking about offload |
| HIGH     | 75% | advisory **and** spill the pointer |
| CRITICAL | 85% | advisory **and** spill the pointer — drop raw history now |

## Per-slice fraction

When the decomposer splits an intent, each slice's context manifest must fit
**≤ `BUDGET × 0.25`**. A slice whose estimate exceeds the fraction is flagged, not silently
emitted — it must be split further or its file list trimmed to links.

## Offload doctrine

**The folder holds the context; the orchestrator holds pointers.**

Working knowledge lives as file links in the workspace, not in live context. On HIGH or
CRITICAL the loop spills `_fleet/context_pointer.md` — active stage, a short ledger digest,
and links to each slice's distilled manifest. Workers are handed
`stages/<stage>/context/<slice>.md` manifests (links + a byte-estimate header, never inlined
file bodies). The orchestrator may then drop raw history and reload from the pointer.

## See also

- `scripts/context-budget.sh` — the engine: `detect` / `status` / `plan` / `pointer`.
- `hooks/herdr-context-budget.js` — PostToolUse: awareness + spills the pointer on HIGH/CRITICAL.
- `hooks/herdr-context-session.sh` — SessionStart: loads MODEL/BUDGET + the active pointer on resume.
