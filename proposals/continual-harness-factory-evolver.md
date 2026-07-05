# Proposal: Continual Harness Factory Evolver

## Status

Proposal.

## Context

`herdr-factory-loop-skill` is already good at the substrate layer:

- create isolated worktrees;
- spawn one or more coding agents;
- dispatch scoped tasks;
- monitor lifecycle state;
- collect reports;
- converge the work back into a coherent outcome.

The current compounding loop is mostly human/orchestrator-driven. A run can
produce notes and reports, and a future orchestrator can learn from them, but
there is no first-class mechanism that observes repeated execution failures and
turns them into concrete updates to the factory itself.

`machine-machine/continual-harness` points at the missing layer. Its core idea is
not Pokemon-specific: keep an agent running, observe trajectory windows, classify
failure patterns, and mutate the harness in place. The mutable harness includes:

- prompt/policy;
- subagents;
- skills;
- memory.

For herdr, the equivalent mutable harness is the factory context:

- dispatch policy;
- slice/decomposition templates;
- worker role prompts;
- `.m2herd/` memory and resume files;
- reusable lessons promoted into proposals or skill edits.

## Goal

Add a factory evolver layer that turns real herdr run telemetry into structured,
reviewable improvements to future herds.

The target loop:

```text
run herd -> collect trajectories -> detect failure signatures ->
propose prompt/role/memory/skill updates -> apply approved updates ->
dispatch better next herd
```

This should make herdr behave less like a terminal multiplexer with agent
helpers and more like a compounding factory that improves its own operating
procedure over time.

## Non-goals

- Do not vendor or depend on the Pokemon benchmark implementation.
- Do not auto-edit `skill/SKILL.md` without a review gate.
- Do not give workers unrestricted access to the herdr socket or host state.
- Do not require a specific model provider.
- Do not make this a hidden autonomous self-modification path.

## Design Principles

1. **Disk is the contract.** Every proposed evolution is reconstructible from
   files under `.m2herd/` or a dedicated control workspace.
2. **Observed before desired.** The evolver reads actual run traces, not just
   idealized plans.
3. **Proposals before mutations.** Risky updates are written as reviewable
   proposal files before they touch live skill or template files.
4. **Small surface to workers.** Workers can emit reports and telemetry; they do
   not directly mutate global factory policy.
5. **Composable with existing loops.** The first version should work with
   `m2herd-up dispatch/collect`, `herd-loop.sh`, and `fleet-loop.sh` rather than
   replacing them.

## Proposed Architecture

### 1. Trace Capture

Each worker run writes a normalized trace bundle:

```text
.m2herd/runs/<run-id>/
├── intent.md
├── plan.md
├── slices/
│   └── <slice-id>/
│       ├── prompt.md
│       ├── report.md
│       ├── status.json
│       ├── changed-files.txt
│       ├── commands.log
│       └── failures.json
├── converge.md
└── outcome.json
```

`failures.json` is deliberately boring JSON:

```json
[
  {
    "kind": "test_failure",
    "severity": "high",
    "where": "slice:frontend-auth",
    "evidence": "pnpm test failed in auth-form.spec.ts",
    "suspected_cause": "worker changed validation contract without updating tests"
  }
]
```

Early implementations can derive this from worker reports and command exits. A
later version can add hook-based capture for richer telemetry.

### 2. Failure Classifier

The classifier converts raw run material into recurring signatures:

- unclear intent;
- bad slice decomposition;
- overlapping file ownership;
- worker drift outside scope;
- missing repo context;
- flaky or missing verification;
- approval/permission deadlock;
- context-window pressure;
- poor convergence plan;
- repeated same-file merge conflict.

Output:

```text
.m2herd/evolver/signatures/<timestamp>-<run-id>.json
```

The classifier should include direct evidence and confidence. Low-confidence
items can still be useful but must not auto-apply.

### 3. Evolver Passes

The evolver mirrors the Continual Harness pattern but maps it to herdr concepts.

| Continual Harness component | Herdr factory equivalent | Example mutation |
|---|---|---|
| system prompt | dispatch/converge policy | add rule for avoiding same-file slice overlap |
| subagents | worker roles | create a verifier role for risky frontend changes |
| skills | reusable workflows/scripts | propose a `m2herd verify` command |
| memory | `.m2herd/` context | add durable lesson to `RESUME.md` or `context/<area>/` |

The first pass should generate proposal files only:

```text
.m2herd/evolver/proposals/
├── 2026-07-05-run123-dispatch-policy.md
├── 2026-07-05-run123-worker-role-verifier.md
└── 2026-07-05-run123-memory-update.md
```

Each proposal includes:

- source run id;
- observed failure;
- proposed change;
- target file or template;
- risk level;
- rollback note;
- acceptance check.

### 4. Review and Apply

Add commands to `m2herd`:

```bash
m2herd evolve analyze --run <run-id>
m2herd evolve proposals
m2herd evolve show <proposal-id>
m2herd evolve apply <proposal-id>
m2herd evolve reject <proposal-id>
```

`apply` starts conservative:

- memory updates can apply to `.m2herd/context/` or `.m2herd/RESUME.md`;
- worker role templates can apply under `.m2herd/templates/`;
- edits to `skill/SKILL.md`, repo scripts, or global templates become a patch
  file or branch recommendation, not an automatic mutation.

### 5. Factory Feedback

`m2herd resume` and `m2herd next` should surface accepted evolutions:

```text
Recent factory lessons:
- Split frontend/backend/test ownership explicitly when routes share files.
- Add a verifier slice when a task changes form validation or auth flows.
- Require `pnpm --filter <package> test` before collect for web slices.
```

`m2herd-up dispatch` can then include accepted lessons in the generated worker
prompt. This makes the improvement visible in the next run without relying on
the orchestrator remembering it.

## Integration Points

### `m2herd-up collect`

Extend collection so every slice writes a report, status, and command/test
summary into `.m2herd/runs/<run-id>/slices/<slice-id>/`.

### `m2herd refile`

Allow accepted memory proposals to refile into specific areas:

```bash
m2herd evolve apply <proposal-id> --area frontend
```

### `herd-loop.sh`

After a converge pass, optionally run:

```bash
m2herd evolve analyze --run latest --propose-only
```

### `fleet-loop.sh`

At fleet scale, track cross-mission signatures:

- which repos repeatedly need verifier workers;
- which task types trigger worker drift;
- which orchestrator prompts produce the cleanest convergence reports.

## Minimal Viable Version

1. Create `.m2herd/runs/<run-id>/` during `m2herd-up dispatch`.
2. Save worker prompts and collected reports per slice.
3. Add `m2herd evolve analyze --run <run-id>` that reads those files and writes
   proposal markdown under `.m2herd/evolver/proposals/`.
4. Add `m2herd evolve proposals/show/apply/reject` for local memory/template
   proposals.
5. Inject accepted local lessons into `m2herd resume` and future dispatch
   prompts.

This MVP does not need a database, socket protocol change, or worker-side MCP
surface.

## Later Extensions

- Hook capture from Claude/Codex/Hermes lifecycle events.
- Automatic conflict detection from git worktree metadata.
- A verifier worker that reviews proposed evolutions before apply.
- Cross-repo fleet memory for recurring operational lessons.
- Scored decomposition policies based on historical run outcomes.
- Provider/model-specific worker role tuning.

## Open Questions

1. Should accepted lessons live inside each repo's `.m2herd/` only, or should
   some graduate into a global herdr factory memory?
2. Should proposal files be plain markdown, JSON, or markdown with frontmatter?
3. Should `m2herd evolve apply` be allowed to open a branch with repo-level
   changes automatically?
4. How much telemetry should be captured from terminal panes before it becomes
   too noisy or privacy-sensitive?
5. Should worker prompts include all accepted lessons, or only lessons tagged to
   the current area/task type?

## Suggested First Implementation Branch

Start with:

- `scripts/m2herd.sh`: add `evolve` subcommands and local proposal registry;
- `scripts/m2herd-up.sh`: write run/slice trace files during dispatch/collect;
- `templates/m2herd/`: seed `evolver/` folders and a short README;
- `CONTRACT-m2herd.md`: document the new trace/proposal file contract.

Keep `skill/SKILL.md` unchanged until the commands exist and the flow is tested.

