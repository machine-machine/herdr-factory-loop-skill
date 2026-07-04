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

## conventions (all slices)
- bash: `set -euo pipefail`, mechanical + idempotent, the style of `scripts/herd-loop.sh`.
- jq required for JSON (hooks degrade silent without it); timestamps `date -u +%Y-%m-%dT%H:%M:%SZ`.
- templates/m2herd/ ships RESUME.md, NOTES.md, overview.json seeds with a `<!-- marker -->` line
  separating template boilerplate from live content (same pattern as STEER.md).
- Run your selftest/smoke BEFORE committing; commit on your branch with message `m2herd/<slice>: <summary>`.
