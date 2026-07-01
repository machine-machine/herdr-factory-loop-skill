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

Measured as `used_pct` of `BUDGET`. Note the two independent actors: **Hermes' native compressor**
fires first, at 50% of the window, and rewrites live history in place; **our hook** advises (and, at
the top, signals a rotation) on top of that.

| level | % of BUDGET | actor | behaviour |
|-------|-------------|-------|-----------|
| COMPRESS | 50% | Hermes | native compressor summarizes the live window lossily (`compression.threshold`) |
| WARNING  | 60% | our hook | advisory only — start thinking about offload |
| HIGH     | 75% | our hook | advisory **and** spill the pointer |
| CRITICAL | 85% | our hook | advisory, spill the pointer, **and** signal session-rotation — drop raw history now |

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

## Dynamic compression — the division of labor

Three actors compress, each with a distinct job. The rule: **lossy in the live window, lossless
on disk.**

- **Hermes' native compressor — the LIVE window, lossily.** The `~/.hermes/config.yaml`
  `compression:` block (`enabled: true`, `threshold: 0.5`, `target_ratio: 0.2`, `protect_first_n`,
  `protect_last_n`) replaces raw history with LLM summaries in place once the window hits 50%. We
  *tune* this to the budget via `install-hermes-context.sh --compression on|off`; we never replace
  it with our own live-window summarizer.
- **The folder — the lossless deep-dives.** `stages/*/output/<slice>.out` and the
  `stages/*/context/<slice>.md` manifests stay on disk in full, so after a lossy in-window
  compression the orchestrator reloads *exact* content from disk instead of a summary.

### Digest / deep-dive convention

`_fleet/digest.md` is a rolling, per-slice summary; the full `.out` is the deep-dive.
`herd-loop.sh collect_slice` runs `context-budget.sh summarize` on each finished worker's
`output/<slice>.out` (its final "what I did / how I verified" report if present, else a head+tail
heuristic — **never a full-body copy**, ≤6 lines) and appends `## <slice>` + that summary + a link
back to `output/<slice>.out`. Append-once per slice (idempotent). Read the digest to stay oriented;
follow the link only when the full text is needed. `context-budget.sh compact` regenerates
`_fleet/context_pointer.md` as a rolling narrative — active stage + the digest + slice `context.md`
links, **links only**.

### Rotation signal file

At CRITICAL the `herdr-context-budget.js` hook drops `_fleet/.needs_rotation` (once per crossing).
`herd-loop.sh run` detects the sentinel and yields `STATUS: NEEDS_ROTATION` rather than looping on a
saturated window. `herd-loop.sh rotate --ws WS` then starts a fresh orchestrator that boots from
`_fleet/context_pointer.md` + `digest.md` (via the SessionStart hook), retires the old pane, and
clears `.needs_rotation` — enforced reorg by restart. It **refuses to close `$SELF`, the new pane,
or an empty/unknown pane id**; `--dry-run` prints the plan and spawns/closes nothing.

## See also

- `scripts/context-budget.sh` — the engine: `detect` / `status` / `plan` / `pointer` / `summarize` / `compact`.
- `hooks/herdr-context-budget.js` — PostToolUse: awareness, spills the pointer on HIGH/CRITICAL, signals rotation at CRITICAL.
- `hooks/herdr-context-session.sh` — SessionStart: loads MODEL/BUDGET + the active pointer on resume/rotation.
- `scripts/install-hermes-context.sh` — `--compression on|off` tunes the Hermes `compression:` block.
