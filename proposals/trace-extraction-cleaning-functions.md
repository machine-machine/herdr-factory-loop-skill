# Proposal: Trace Extraction and Cleaning Functions

## Status

Proposal for review.

## Context

Current `main` already writes best-effort `.m2herd/runs/<run-id>/` bundles from
`m2herd-up dispatch/collect` and reads them from `m2herd evolve analyze`.

That is enough for mechanical failure signatures, but not enough for a real
distillation loop. Distillation needs stable, exportable, privacy-aware examples:

```text
herdr run bundle -> extracted raw records -> cleaned records -> ChatML JSONL
```

The companion bootstrap repo is:

```text
machine-machine/herdr-trace-distiller
```

This proposal defines the herdr-side function contract so the distiller can
consume herdr traces without scraping shell output or guessing file shapes.

## Goals

- Make trace extraction a first-class function boundary, not an ad hoc parser.
- Keep raw traces local and treat them as sensitive.
- Produce deterministic JSONL records suitable for SFT and later on-policy
  distillation.
- Preserve provenance so bad examples can be traced back to run/slice/source.
- Keep the existing `m2herd-up` worker flow non-blocking.

## Non-goals

- Do not train models inside `herdr-factory-loop-skill`.
- Do not publish traces automatically.
- Do not clean secrets. This proposal removes terminal noise; secret scanning is
  a separate explicit stage.
- Do not require Python in the core shell workflow unless the operator chooses
  the external distiller.

## Proposed CLI Surface

Add a new `trace` subcommand group to `m2herd.sh`:

```bash
m2herd trace extract [--dir P] [--run <id|latest|current>] --out raw.jsonl
m2herd trace clean   --input raw.jsonl --out clean.jsonl
m2herd trace format  --input clean.jsonl --out chatml.jsonl --format chatml
m2herd trace export  [--dir P] [--run <id|latest|current>] --out-dir artifacts/
```

`trace export` is a convenience wrapper:

```text
extract -> clean -> format
```

All commands are local-only and deterministic. No network calls, no LLM calls.

## Function Spec

### `trace_resolve_run`

```text
trace_resolve_run(dir, run_selector) -> run_id | empty
```

Inputs:

- `dir`: repo root or any path containing `.m2herd/`.
- `run_selector`: `current`, `latest`, or explicit run id.

Behavior:

- `current` reads `.m2herd/runs/CURRENT`, falling back to latest valid `r-*`.
- `latest` chooses the lexically greatest `r-*` directory.
- explicit id must map to `.m2herd/runs/<id>/`.
- returns empty instead of failing when no run exists.

### `trace_extract_run`

```text
trace_extract_run(dir, run_id) -> JSONL rows
```

One output row per slice.

Required output schema:

```json
{
  "schema": "m2herd.trace.raw.v1",
  "run_id": "r-20260705T120000Z",
  "slice_id": "frontend-auth",
  "source_path": ".m2herd/runs/r-20260705T120000Z/slices/frontend-auth",
  "run": {
    "goal": "string",
    "base": "main",
    "created_at": "2026-07-05T12:00:00Z"
  },
  "status": {},
  "failures": [],
  "prompt": "verbatim prompt.md",
  "report": "verbatim report.md",
  "commands": "verbatim commands.log if present",
  "notes": "optional extra trace notes if present"
}
```

Rules:

- Missing optional files become empty strings or empty arrays.
- Invalid JSON files are recorded under `parse_errors[]` and do not abort export.
- `status.json` and `failures.json` are copied as structured objects when valid.
- Output row order is deterministic: sorted by `slice_id`.

### `trace_clean_text`

```text
trace_clean_text(text) -> text
```

Removes:

- ANSI escape sequences;
- non-printing control characters except newline/tab;
- repeated blank lines beyond one;
- known provider/tool noise lines;
- terminal chrome markers that do not belong to the agent trace.

Initial noise classes:

```text
rate limit warnings
interactive menu prompts
shell color/control output
transient downloader warnings
progress bars
empty heartbeat/status-only lines
```

Does **not** remove:

- paths;
- code;
- command output;
- secrets;
- stack traces.

Those need a separate explicit redaction/scanner stage.

### `trace_clean_record`

```text
trace_clean_record(raw_record) -> clean_record
```

Required output schema:

```json
{
  "schema": "m2herd.trace.clean.v1",
  "run_id": "r-20260705T120000Z",
  "slice_id": "frontend-auth",
  "source_path": "...",
  "status": {},
  "failures": [],
  "prompt": "cleaned prompt",
  "report": "cleaned report",
  "commands": "cleaned commands",
  "quality": {
    "has_prompt": true,
    "has_report": true,
    "has_failure": false,
    "chars_prompt": 1234,
    "chars_report": 5678
  }
}
```

Rules:

- Cleaning is idempotent.
- Records with empty `prompt` and empty `report` are kept but marked low quality.
- No field should be dropped silently.

### `trace_format_chatml`

```text
trace_format_chatml(clean_record) -> training_record
```

Required output schema:

```json
{
  "messages": [
    {
      "role": "system",
      "content": "You are a coding agent worker..."
    },
    {
      "role": "user",
      "content": "## Task Context\n..."
    },
    {
      "role": "assistant",
      "content": "worker report/action"
    }
  ],
  "metadata": {
    "schema": "m2herd.trace.chatml.v1",
    "run_id": "r-20260705T120000Z",
    "slice_id": "frontend-auth",
    "source_path": "...",
    "quality": {}
  }
}
```

Rules:

- The assistant target is `report` first.
- If `report` is empty but `failures[]` exists, emit a failure-analysis target
  only when the operator passes `--include-failures`.
- Empty assistant targets are skipped by default and counted in the summary.
- The formatter must not invent reasoning.

## Handoff to `herdr-trace-distiller`

The herdr repo should remain the source of the trace bundle contract. The
distiller repo should own higher-level dataset preparation and training-loop
integration.

Suggested handoff:

```bash
m2herd trace export --run latest --out-dir artifacts/herdr-traces
herdr-trace-distiller manifest artifacts/herdr-traces/chatml.jsonl \
  --out artifacts/herdr-traces/train-manifest.json
```

The distiller may also read `.m2herd/runs` directly, but `m2herd trace export`
is the canonical interface once implemented.

## Implementation Notes

### Shell-first MVP

Implement in `scripts/m2herd.sh` using `jq`, `sed`, and `awk`:

- `trace_extract_run`
- `trace_clean_text`
- `trace_clean_jsonl`
- `trace_format_chatml`

This keeps the core tool dependency profile unchanged.

### Python Bridge Later

If the shell formatter becomes too brittle, `m2herd trace export` can delegate
to `herdr-trace-distiller` when it is on `PATH`, while preserving the same
output schema.

Delegation must be explicit in logs:

```text
trace: using herdr-trace-distiller from /path/to/bin
```

## Acceptance Criteria

Given a run with two slices, one complete and one missing `report.md`,
when `m2herd trace extract --run <id>` runs,
then it writes two raw JSONL rows and exits 0.

Given raw rows containing ANSI escapes and repeated blank lines,
when `m2herd trace clean` runs,
then the output contains no ANSI escapes and preserves meaningful command text.

Given clean rows where one row has an empty assistant target,
when `m2herd trace format --format chatml` runs,
then the empty-target row is skipped by default and reported in the summary.

Given the same input files,
when the trace commands are run twice,
then their JSONL output is byte-identical except for explicit summary logs.

Given malformed `status.json`,
when extraction runs,
then the row includes `parse_errors[]` and the command exits 0.

## Open Questions

1. Should secret scanning be a built-in `m2herd trace redact` stage or delegated
   to repo-specific tooling?
2. Should `commands.log` be captured by `m2herd-up` for pane workers, or only
   headless workers at first?
3. Should accepted `.m2herd/evolver/LESSONS.md` be injected into ChatML context
   for every trace, or kept as metadata only?
4. Should failure-only rows become negative examples, preference pairs, or stay
   out of SFT datasets entirely?

