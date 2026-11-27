# .m2herd/evolver/ — the factory evolver's state

This is where `m2herd.sh evolve` reads and writes. It is the reviewable half of
the continual-harness loop: run trace bundles (`.m2herd/runs/`, see
`../runs/README.md`) go IN, structured proposals come OUT, and only accepted
lessons ever become live text.

```
evolver/
  signatures/<run-id>.json     # array of failure signatures detected in a run
  proposals/<proposal-id>.md   # one reviewable proposal per detected signature
  LESSONS.md                   # accepted lessons; template boilerplate + marker,
                                # lessons appended below
```

## Proposal frontmatter schema

```markdown
---
id: 2026-07-05-r-20260705T120000Z-report-missing-trace-capture
run: r-20260705T120000Z
kind: memory | template | policy | repo
target: <path the change applies to, repo-relative or .m2herd-relative>
risk: low | medium | high
status: proposed | applied | rejected
lesson: <one-line lesson appended to LESSONS.md on apply; may be empty for kind=repo>
model: <status.json .model of the slice, empty when unknown>
agent: <status.json .agent of the slice, empty when unknown>
predicted: <kind>@<where>   # the originating signature this attempt claims will not recur
outcome: pending | fixed | missed
outcome_run: <run-id that decided the outcome, empty while pending>
applied_at: <UTC ts stamped by apply, empty until then>
---

## Observed failure
## Proposed change
## Rollback
## Acceptance check
```

## The outcome fold (the attempt record)

`evolve analyze` on a run R grades **applied** proposals that R can test: R dispatched the
slice after the lesson's `applied_at` (that worker could read it) and ran it to
`done`/`failed`. The predicted `<kind>@<where>` recurs → `outcome: missed`, absent →
`outcome: fixed`, stamped with `outcome_run: R`. The first qualifying run that is analyzed
decides; a decided outcome is never rewritten; a run that skipped the slice, left it
in flight, or predates the apply leaves `pending`. A re-dispatch of the slice inside the
same run qualifies: `m2herd-up` moves the earlier attempt to `attempts/<dispatched_at>/`
first, and a `failures.json` entry dated at or before the grading dispatch is ignored.
Proposals without an `outcome:` key are never folded (`-` in `evolve proposals`).
`LESSONS.md` never carries outcomes — read them with `m2herd.sh evolve proposals`.

## The apply ladder (conservative, by `kind`)

1. **memory / policy** → append the `lesson:` line to `LESSONS.md`, flip
   `status: applied`. Safest tier — no file outside `.m2herd/evolver/` changes.
2. **template** → target MUST be under `.m2herd/`; refuse otherwise. Flip
   status, append lesson if set. Still `.m2herd`-only.
3. **repo** (target outside `.m2herd/`, e.g. `skill/SKILL.md` or `scripts/`) →
   NEVER auto-edit the target. Print a branch/patch recommendation and only
   flip `status: applied` when the operator passes `--ack-repo`; otherwise the
   proposal stays `proposed` and the recommendation prints on every run.

`reject` only ever flips frontmatter status — no file moves either way.

See `CONTRACT-m2herd.md` (§ evolver state, § evolve subcommand semantics) for
the full binding contract: signature/proposal object shapes, idempotency
rules, and exact CLI surfaces.
