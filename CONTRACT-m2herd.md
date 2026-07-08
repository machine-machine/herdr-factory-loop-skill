> **STATUS: historical build contract.** This is the v2.0-era contract the m2herd herd was
> built against, plus its amendments. It is kept as the record of what was promised to whom;
> it is no longer the leading spec. **Where it disagrees with `skill/SKILL.md` ≥ 2.6.0, the
> SKILL wins** — the shipped code and §16/§17 of the skill are the source of truth.

# m2herd contract (v2.0.0) — pre-committed; ALL slices build against this

Doctrine: **Claude Code (Fable) is the MAIN orchestrator.** The folder holds the
context, the orchestrator holds pointers. `.m2herd/` is the per-repo context
fabric: repo-root, gitignored, the Claude-Code-native superset of the §12/§15
herd-control concepts. The orchestrator keeps only the most important things in
its live window and offloads everything else into `.m2herd/`, from which it can
delegate any piece to herdr workers at will.

This file is the schema the herd builds against. Do not change it mid-run; if a
slice can't honor it, STOP and report the conflict in your answer file instead
of improvising.

## Doctrine amendment (v1.1 — orchestrator-issued, binding)

**Living harness loop.** The hooks are the heartbeat (SessionStart orients, PostToolUse
watches the budget, PreCompact refiles before compaction eats notes); drift is an ERROR.
`m2herd.sh sync --check` exits **3** with a human-readable drift report when overview.json
and the context/ tree disagree (missing areas, orphan entries); plain `sync` repairs.
The hooks nudge the orchestrator to run `m2herd sync` when drift is detected.

**Memory tiers — division of labor.** `.m2herd/` is the PROJECT's working memory (files,
links, state — things you point workers at). AMS (memory.machinemachine.ai) is the FLEET's
recall (searchable gists, cross-project). `~/.claude` auto-memory is the orchestrator's own
lessons. `.m2herd` never tries to be a vector store; AMS never holds file trees. Bridge:
`m2herd.sh gist [--push]` emits a one-paragraph project gist (goal, status, one line per
active area); `--push` pipes it to the pluggable command `$M2HERD_GIST_CMD` if set (the
--llm pattern), else prints it with a note. Self-documentation is the point: every refile
IS the documentation act; nothing lives only in the live window.

**Decay discipline.** `m2herd.sh archive --area A` distills a done area: context.md is
reduced to its header + ≤10 summary lines with `status: archived` added to the header;
`deep/` stays lossless and untouched; overview.json area entry gets `"status": "archived"`
(areas[].status: "active"|"archived", default "active" — schema addition). `status`/`resume`
show archived areas as a one-line footer, not full entries. Living ≠ hoarding.

**PATH wiring (slice D).** install.sh also symlinks `scripts/m2herd.sh` → `~/.local/bin/m2herd`
and `scripts/m2herd-up.sh` → `~/.local/bin/m2herd-up` (idempotent, --uninstall removes), so any
repo can run the engine. Hooks call `command -v m2herd` and degrade silently when absent.

## Doctrine amendment v1.2 — agentic loop: the machine prompts itself (binding)

**The orchestrator is also the intent coach.** A fuzzy goal is not dispatchable. The
orchestrator's first job is to sharpen intent into `goal` + `done_when` + slices, recording
what it cannot resolve as `open_questions` instead of guessing. Schema addition to
overview.json (both optional, engine writes them): `"done_when": "string"` and
`"open_questions": ["string"]`. `init --goal` seeds `done_when: ""` — empty means
"intent not yet coached".

**`m2herd.sh next` — the self-prompting primitive (slice A).** Mechanical priority walk,
NO LLM calls, prints exactly one line starting `NEXT: `:
1. drift (`sync --check` logic fails)            → `NEXT: context drift — run: m2herd sync`
2. `done_when` empty                              → `NEXT: coach the intent — set done_when + record open_questions (m2herd.sh has no opinion; you do)`
3. loose content in NOTES.md below the marker     → `NEXT: refile notes — run: m2herd refile --area <pick>`
4. workers[] entry with state spawned|working whose pane is gone/idle → `NEXT: collect worker <slice> — run: m2herd-up collect --slice <slice>`
5. open_questions non-empty                       → `NEXT: resolve open question: <first>`
6. otherwise                                      → `NEXT: compare RESUME.md against goal/done_when and dispatch or finish`
Add `next` to the selftest (drive at least cases 2, 3, 6).

**Hooks inject the next move (slice B).** m2herd-session.sh appends the output of
`m2herd next` (when the binary exists; bounded ~3s; silent-fail) to its additionalContext,
after the RESUME digest. Every wake-up = orientation + the next move. This supersedes the
v1.1 drift-nudge for the session hook (drift is case 1 of `next`); m2herd-precompact.sh
keeps its own v1.1 drift line.

**Docs (slice D).** §16 opens with the agentic-loop doctrine: the folder is a living harness
loop — hooks are the heartbeat, `next` is the pulse it injects, the orchestrator coaches
intent before dispatching, and the machine prompts itself from its own state. Document
`next`, `done_when`/`open_questions`.

## Amendment v1.3 — the dashboard (tier-1 TUI, read-only)

**`m2herd.sh dashboard [--dir P]` (slice A).** A pure RENDERER over existing state — no new
state, no writes, ever. Composes, in order:
1. header: goal • status • done_when • drift dot (`●` clean / `◐ drift` from the sync --check
   logic) • humanized age of updated_at (3m/7h/4d)
2. the `NEXT:` line (same code path as `next`)
3. AREAS table: name, status (active/archived), age from each context.md header `updated:`,
   related links — archived rendered dim/one-line; staleness ages make rot VISIBLE
4. WORKERS table (slice, state, branch) when workers[] non-empty
5. OPEN QUESTIONS list when non-empty
6. NOTES tail: last 5 content lines below the marker
Plain ASCII + tput colors when a tty (degrade to plain when piped). Add a dashboard smoke to
selftest (runs against the tmpdir fixture, asserts NEXT line + area row present).

**Machineroom pane (slice C).** The machineroom pane command becomes:
`watch -n 2 -t "m2herd dashboard"` when `command -v m2herd` AND watch exist; else the
existing NOTES.md viewer fallback chain. The pane is a WATCHER, never a writer.

**Read-only doctrine (slice D, §16).** One writer (the orchestrator), many watchers. The
dashboard displays the same self-prompt the machine injects into itself. Any future
interactive tier (fswatch repaint = tier 2; bubbletea/textual navigation = tier 3 — roadmap
only, NOT built now) may add navigation, never editing; the only input concession a TUI may
ever make is a keypress that opens an inbox file (STEER.md-style) — steering goes through
the loop, never directly into the state files.

## Amendment v1.4 — dashboard layout, observed fleet column, STEER inbox

**Layout (slice A).** dashboard renders the reference mock: boxed header line
`m2herd · <repo-basename> ── ● <status> · drift ✓|◐`, then `goal` / `done_when` /
`budget` rows (budget: newest `/tmp/claude-ctx-*.json` bridge file if any — bar + "N% of
BUDGET" + "updated <age> ago"; omit row when none), then NEXT, then AREAS and WORKERS
**side-by-side** when the tty is ≥100 cols (stacked otherwise), then OPEN QUESTIONS,
NOTES tail, and a static footer: `read-only · steering: .m2herd/inbox/STEER.md`.

**Observed fleet column (slice A).** When `herdr` is on PATH, dashboard queries
`herdr agent list` ONCE and the WORKERS table shows desired (workers[].state) AND observed
(pane agent_status) — mismatch marked `!`. Silent degrade to desired-only without herdr.
Dashboard remains read-only: herdr READS are allowed, herdr writes/sends are FORBIDDEN here.

**STEER inbox (slice A + B).** `init` also scaffolds `.m2herd/inbox/STEER.md` (boilerplate +
marker, STEER.md pattern). `next` gains a case between drift and coach-intent:
non-empty content below the marker → `NEXT: drain steering — read .m2herd/inbox/STEER.md,
act, then clear below the marker`. (Slice B: no change — session hook already injects next.)

**Docs (slice D).** Document the layout, the desired-vs-observed workers column, and the
steering contract: TUI keys (tier 3) APPEND to STEER.md; the orchestrator drains it via
`next`; a watcher pane never runs herdr mutations directly.

## .m2herd/ layout (created by `m2herd.sh init`)

```
.m2herd/
  overview.json               # central machine-readable index — schema below
  RESUME.md                   # come-back file: where we are, in-flight work, next 3 commands
  NOTES.md                    # central notes file (the machineroom pane live-views this)
  context/<area>/context.md   # distilled per-area context; annotation header below
  context/<area>/deep/        # lossless deep-dives (worker outputs, logs, transcripts)
  dispatch/<slice>.task.md    # worker task files (file protocol)
  dispatch/<slice>.out.md     # worker answers
```

`m2herd.sh init` also appends `.m2herd/` to the repo's `.gitignore` (idempotent).

## overview.json schema

```json
{
  "goal": "string",
  "status": "active|paused|done",
  "updated_at": "ISO-8601 UTC",
  "areas": [
    {"name": "string", "path": ".m2herd/context/<name>/", "summary": "string", "related": ["<area>"]}
  ],
  "workers": [
    {"slice": "string", "pane_id": "string", "worktree": "string", "branch": "string",
     "state": "spawned|working|done|failed", "task": ".m2herd/dispatch/<slice>.task.md",
     "out": ".m2herd/dispatch/<slice>.out.md"}
  ],
  "notes_file": ".m2herd/NOTES.md",
  "resume_file": ".m2herd/RESUME.md"
}
```

`workers` may be `[]`. Writers always rewrite the whole file with jq (no sed patching).

## context.md annotation header (every context/<area>/context.md starts with)

```
---
area: <name>
related: [<other area names>]   # where to find the sibling pieces
deep: ./deep/                   # lossless material for this area
updated: <ISO-8601 UTC>
---
```

## CLI surfaces (exact signatures — build THESE, nothing else)

### scripts/m2herd.sh — the engine (slice A)
```
m2herd.sh boot   [--dir P] [--goal "…"]   # recommended entry point: init (if needed) + sync + resume + next; loud tty-gated warning + `git init` recommendation when --dir is not a git repo (non-fatal)
m2herd.sh init   [--dir P] [--goal "…"]   # scaffold .m2herd/ from templates/m2herd/, gitignore it
m2herd.sh status [--dir P]                # render overview.json human-readably
m2herd.sh note   [--dir P] "text"         # append "- [<UTC ts>] text" to NOTES.md
m2herd.sh refile [--dir P] --area A       # create/refresh context/A/ (+header), move NOTES.md content below the marker into it, update overview.json
m2herd.sh resume [--dir P]                # print RESUME.md + one line per area from overview.json
m2herd.sh sync   [--dir P]                # regenerate overview.json areas[] from the context/ tree; refresh RESUME.md skeleton preserving hand-written notes
m2herd.sh selftest                        # tmpdir end-to-end: init → note → refile → sync → status → resume; asserts schema fields with jq
```
`--dir` defaults to `$PWD`. Everything idempotent.

### scripts/m2herd-up.sh — workspace bootstrap + dispatch (slice C)
```
m2herd-up.sh up       [--repo P] [--goal "…"]      # ensure herdr workspace for repo: EXACTLY ONE orchestrator pane (claude) + ONE machineroom pane running the live viewer; runs m2herd.sh init if missing
m2herd-up.sh dispatch --slice S [--repo P] [--base BRANCH] [--agent claude|codex|cursor]
                                                    # worktree wip/m2herd-<S> off BASE (default: current branch), spawn worker, file-protocol dispatch of .m2herd/dispatch/S.task.md, record in overview.json workers[]
m2herd-up.sh collect  --slice S [--repo P]          # wait idle, copy worker report to dispatch/S.out.md, update workers[] state
m2herd-up.sh --dry-run <same args>                  # print every herdr/git command instead of running it
```
Notes pane viewer command (exact): `watch -n 2 -t cat .m2herd/NOTES.md` if `watch`
exists, else a `while :; do clear; cat .m2herd/NOTES.md; sleep 2; done` bash loop.
Herdr rules (binding): identify `$SELF` first and never touch it; after `agent start`
RE-RESOLVE the pane by cwd from `herdr agent list` (returned pane_id can be off by one);
no `agent start --split` (stray-pane bug); settle ~1s between `agent send` and Enter.
Worker pane placement (TUI dispatch): orchestrator always keeps the LEFT 50% of its tab;
workers subdivide the RIGHT half via `herdr pane split` — first worker splits the
orchestrator `--direction right --ratio 0.5`, each further worker splits the LAST worker
pane `--direction down --ratio 0.5`; fall back to `agent start --no-focus` when the
orchestrator pane cannot be resolved. `up` and TUI `dispatch` warn (tty-gated, non-fatal)
when not running inside a herdr pane (bounded ancestor-process walk, never HERDR_* env);
`up` probes the herdr server first and fails with a clear "start herdr" message.

### hooks (slice B; filenames fixed — install.sh registers by FILENAME)
```
hooks/m2herd-session.sh     SessionStart: if cwd (or $M2HERD_DIR) has .m2herd/, inject a digest —
                            overview.json goal/status/areas count + first 30 lines of RESUME.md —
                            as {hookSpecificOutput:{hookEventName:"SessionStart",additionalContext}}.
                            bash + jq, silent-fail, bounded stdin read (timed loop, never $(cat)), always exit 0.
hooks/m2herd-precompact.sh  PreCompact: same detection; inject additionalContext instructing the model to
                            refresh RESUME.md + overview.json and refile loose NOTES.md content into
                            context/<area>/ BEFORE compaction proceeds. Envelope hookEventName:"PreCompact".
                            Never blocks (exit 0 always).
hooks/m2herd-budget.js      PostToolUse: adapt hooks/herdr-context-budget.js — same bridge file
                            (/tmp/claude-ctx-<session>.json), same 60/75/85 thresholds/debounce/traversal
                            guard — but keyed on .m2herd/ presence (not herd.conf) and the advisory tells the
                            orchestrator to offload into .m2herd/context/<area>/ + refresh RESUME.md.
                            hookEventName ALWAYS "PostToolUse" (no env-conditional). Silent-fail.
```
Each hook slice ships a smoke: pipe a sample payload + empty stdin + garbage stdin, assert valid JSON out and exit 0.

### docs + wiring (slice D)
- `skill/SKILL.md`: version → **2.0.0**; new **§16 "m2herd — the Fable main-orchestrator context fabric"**
  documenting doctrine, layout, engine, workspace shape (1 orchestrator pane + 1 machineroom pane), hooks,
  install; cheat-sheet row. Do NOT renumber existing sections.
- `README.md`: capabilities row 16; structure tree entries for the new files.
- `CHANGELOG.md`: `## [2.0.0] - 2026-07-02` entry.
- `scripts/install.sh`: register the three m2herd hooks for the **claude** target (SessionStart,
  PreCompact, PostToolUse — extend the existing register_claude_hook pattern; dedupe/uninstall keyed on
  hook FILENAME like the nudge fix; timestamped .bak; `--no-m2herd-hooks` to skip; node required for the
  .js one — degrade with a warning). `scripts/onboard.sh`: mention m2herd in step 3 output.
- D documents the OTHER slices from THIS CONTRACT (not from their code) — signatures above are binding.

## ownership (touch ONLY your files)

| Slice | Files owned |
|-------|-------------|
| A engine    | `scripts/m2herd.sh`, `templates/m2herd/**` |
| B hooks     | `hooks/m2herd-session.sh`, `hooks/m2herd-precompact.sh`, `hooks/m2herd-budget.js` |
| C workspace | `scripts/m2herd-up.sh` |
| D docs+wire | `skill/SKILL.md`, `README.md`, `CHANGELOG.md`, `scripts/install.sh`, `scripts/onboard.sh` |

## Amendment v2.1 — continual-harness factory evolver (trace + proposal contract)

**Doctrine.** The folder holds the context; the evolver closes the loop from real run
telemetry back into the factory itself. Run trace bundles are written by `m2herd-up.sh`
and read by `m2herd.sh evolve`, which classifies boring, mechanical failure signatures,
writes reviewable proposal files, and only ever mutates live text (`LESSONS.md` or a
`.m2herd`-scoped template) on explicit `apply` — repo-level files get a patch/branch
recommendation, never an auto-edit. Templates for both trees ship under
`templates/m2herd/evolver/` and `templates/m2herd/runs/`.

### §1. Run trace bundles (`.m2herd/runs/`, written by `m2herd-up.sh`, read by `m2herd.sh evolve`)

```
.m2herd/runs/CURRENT                    # plain text file: the active run-id, no newline padding
.m2herd/runs/<run-id>/
  run.json                              # {"run_id","created_at","goal","base","slices":["<slice>",...]}
  slices/<slice>/
    prompt.md                           # verbatim copy of .m2herd/dispatch/<slice>.task.md at dispatch time
    report.md                           # verbatim copy of .m2herd/dispatch/<slice>.out.md at collect time
    status.json                         # see schema below
    failures.json                       # OPTIONAL, orchestrator- or worker-authored; array, may be absent
```

- run-id format: `r-<UTC %Y%m%dT%H%M%SZ>`, e.g. `r-20260705T120000Z`.
- Run lifecycle: `dispatch` reads `.m2herd/runs/CURRENT`; if missing, it creates a new
  run-id, `mkdir -p`s the run dir, writes `run.json`, and writes `CURRENT`. Rotation = the
  orchestrator deletes `CURRENT`; the next dispatch starts a fresh run. No dedicated
  rotation subcommand in the MVP.
- `run.json.goal` is copied from `.m2herd/overview.json .goal`; `base` is the dispatch `--base`.
- `slices[]` in `run.json` is appended (dedup) on each dispatch. jq whole-file rewrites only.

`status.json` schema:
```json
{
  "slice": "<slice>",
  "state": "spawned|working|done|failed",
  "agent": "claude|codex|cursor",
  "runner": "pane|headless",
  "model": "<model or empty>",
  "branch": "wip/m2herd-<slice>",
  "worktree": "<abs path>",
  "dispatched_at": "<ISO-8601 UTC>",
  "collected_at": "<ISO-8601 UTC or empty>",
  "tokens": 0,
  "cost_usd": 0.0
}
```
`tokens`/`cost_usd` are filled by collect when the headless usage JSON provides them,
else left `0`.

`failures.json` entry schema (deliberately boring):
```json
[{"kind":"test_failure","severity":"high|medium|low","where":"slice:<slice>",
  "evidence":"<one line>","suspected_cause":"<one line>"}]
```

### §2. Evolver state (`.m2herd/evolver/`, owned by `m2herd.sh evolve`)

```
.m2herd/evolver/
  signatures/<run-id>.json              # array of signature objects (see below)
  proposals/<proposal-id>.md            # markdown + YAML frontmatter (see below)
  LESSONS.md                            # accepted lessons; template boilerplate + marker line,
                                         # lessons appended below
```

- proposal-id format: `<YYYY-MM-DD>-<run-id>-<slug>` (slug = kebab, from the signature kind + slice).
- signature object: `{"kind","severity","where","evidence","confidence":"high|medium|low","source":"mechanical|failures.json"}`.
- `LESSONS.md` uses the standard m2herd marker convention (`<!-- === M2HERD:LIVE === -->`);
  accepted lessons are appended below the marker as `- [<UTC ts>] (<proposal-id>) <lesson text>`.
- All evolve commands `mkdir -p` what they need — NO dependency on template seeds existing.

Proposal file format:
```markdown
---
id: 2026-07-05-r-20260705T120000Z-report-missing-trace-capture
run: r-20260705T120000Z
kind: memory | template | policy | repo
target: <path the change applies to, repo-relative or .m2herd-relative>
risk: low | medium | high
status: proposed | applied | rejected
lesson: <one-line lesson appended to LESSONS.md on apply; may be empty for kind=repo>
---

## Observed failure
<evidence from the run>

## Proposed change
<what to change>

## Rollback
<how to undo>

## Acceptance check
<how to verify the change helped>
```

### §3. `m2herd evolve` subcommand semantics

```
m2herd evolve analyze  [--dir P] [--run <id|latest|current>]   # default: current, falling back to latest
m2herd evolve proposals [--dir P]                              # list: id, kind, risk, status
m2herd evolve show <id> [--dir P]                              # print the proposal file
m2herd evolve apply <id> [--dir P]                             # see apply ladder below
m2herd evolve reject <id> [--dir P]                            # frontmatter status -> rejected (no file moves)
```

- `analyze` is MECHANICAL — no LLM calls, same doctrine as `next`. It detects only boring
  signatures: slice `status.json` `state=="failed"`; `report.md` missing or empty at
  collect; `status.json` missing for a dispatched slice (in `run.json` `slices[]` but no
  dir); plus every entry of any `failures.json` passed through verbatim
  (`source:"failures.json"`). It writes `signatures/<run-id>.json` and one skeleton
  proposal per signature (kind defaults: mechanical signatures → `memory`, risk low, status
  proposed, lesson prefilled with a one-line statement of the failure). Idempotent:
  re-running must not duplicate signatures or proposal files (key on proposal-id).
- `--run latest` = lexically greatest run dir (run-ids sort chronologically by construction).
- `apply` rules (conservative ladder):
  - kind `memory` or `policy`: append the `lesson:` line to `LESSONS.md` (append-once by
    proposal-id), flip frontmatter `status: applied`.
  - kind `template`: target MUST be under `.m2herd/`; refuse otherwise. Flip status,
    append lesson if set.
  - kind `repo` (targets outside `.m2herd/`, e.g. `skill/SKILL.md` or `scripts/`): NEVER
    edit the target. Print a branch/patch recommendation ("open a branch, apply by hand,
    see proposal") and flip `status: applied` only with `--ack-repo`; without it, leave
    proposed and exit 0 with the recommendation printed.
- `reject`: flip frontmatter status only. Both apply/reject are idempotent.
- Frontmatter edits: rewrite the whole frontmatter block deterministically (awk/sed on the
  `^status:` line inside the frontmatter fence is acceptable here — files are ours), or
  regenerate the file; do NOT corrupt the body.

### §4. Lesson surfacing

- `m2herd resume` prints, after the areas list, a `Recent factory lessons:` section with
  the last 5 lesson lines from `LESSONS.md` — only when `LESSONS.md` has content below the marker.
- `m2herd-up dispatch` (both pane and headless): when `LESSONS.md` has content below the
  marker, the pointer message sent to the worker gains one sentence: `Also read <abs path
  to .m2herd/evolver/LESSONS.md> (accepted factory lessons) before starting.` The task
  file itself is NOT mutated.

Template seeds for both trees (`evolver/README.md`, `evolver/LESSONS.md`, `runs/README.md`)
live under `templates/m2herd/`. `skill/SKILL.md` documentation for the `evolve` commands
lands separately once those commands are released.

## Amendment v2.2 — settings layer, teardown, state honesty (recorded post-hoc, 2026-07-07)

Recorded by the docs slice to close the gap between this contract and the shipped surface
(the audit found "shipped surface exceeds the binding contract without amendments").

**Settings config layer.** `.m2herd/settings.json` (seed: `templates/m2herd/settings.json`,
`schema_version: 1`) configures WHO does the work; it is config, never state. Settled schema:
`orchestrator.{agent,runner}`, `workers.{agent,runner,max,base,model,settle_seconds,
wait_timeout_minutes}`, and `routing: [{pattern, agent, runner?, model?}]` (first match wins).
Surface: `m2herd config list|get|set` with defaults + validation (invalid enum → exit 2),
whole-file jq rewrites. Dispatch resolution precedence: CLI flag → routing rule → workers
default → builtin, with the winning source logged.
*Shipped drift (known, tracked as the `schema_drift_from_spec` factory lesson):* the engine's
`config` currently validates `workers.{agent,runner,max}` + `routing[].pattern`, while
`m2herd-up.sh` reads `workers.{default_agent,default_model,runner,base,settle_seconds,
wait_timeout_minutes,max_concurrent}` + `routing[].match`. The settled schema above is the
convergence target; until then SKILL.md §16.6 documents both live key sets.

**TUI settings editor — read-only exception.** The `,` key in `m2herd-tui` opens a settings
editor. This is the single sanctioned exception to the read-only watcher doctrine (v1.3): it
may edit the CONFIG FILE only (`.m2herd/settings.json`, validated, atomic tmp+rename) — never
`overview.json` or any state file. Steering still goes through `inbox/STEER.md`.

**Teardown + retry.** `m2herd-up down [--slice S | --all] [--force]`: close the worker pane
(never `$SELF`; an unresolvable self is treated as could-be-me and skipped), remove the
worktree (dirty needs `--force`), `git branch -d` only when merged, set workers[]
`state: "down"` only when nothing was refused. Idempotent. Retry = `down --slice S`, then
dispatch again — no `retry` subcommand.

**Collect state honesty.** `collect` marks a slice `failed` — never silently `done` — on a
dead pane without a report, a recycled/missing headless pid, or an EMPTY report file. A full
verify gate (running the slice's tests at collect) is NOT shipped; state honesty is the
shipped guarantee.

**Context-budget bridge.** The bridge file `/tmp/claude-ctx-<session>.json` is READ by
`m2herd-budget.js`, the dashboard budget row, and `context-budget.sh status`; its WRITER is
external (host statusline/session script) and is NOT shipped by this repo. Default budget on
all readers: 384000.

**Hook smokes.** The per-slice smoke obligation (§ hooks) is discharged by `hooks/smoke.sh`
(sample/empty/garbage stdin → exit 0 + valid JSON for every hook).

## conventions (all slices)
- bash: `set -euo pipefail`, mechanical + idempotent, the style of `scripts/herd-loop.sh`.
- jq required for JSON (hooks degrade silent without it); timestamps `date -u +%Y-%m-%dT%H:%M:%SZ`.
- templates/m2herd/ ships RESUME.md, NOTES.md, overview.json seeds with a `<!-- marker -->` line
  separating template boilerplate from live content (same pattern as STEER.md).
- Run your selftest/smoke BEFORE committing; commit on your branch with message `m2herd/<slice>: <summary>`.
