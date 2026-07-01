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

## .m2herd/ layout (created by `m2herd.sh init`)

```
.m2herd/
  overview.json               # central machine-readable index — schema below
  RESUME.md                   # come-back file: where we are, in-flight work, next 3 commands
  NOTES.md                    # central notes file (the notes pane live-views this)
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
m2herd-up.sh up       [--repo P] [--goal "…"]      # ensure herdr workspace for repo: EXACTLY ONE orchestrator pane (claude) + ONE notes pane running the live viewer; runs m2herd.sh init if missing
m2herd-up.sh dispatch --slice S [--repo P] [--base BRANCH] [--agent claude|codex|cursor]
                                                    # worktree wip/m2herd-<S> off BASE (default: current branch), spawn worker, file-protocol dispatch of .m2herd/dispatch/S.task.md, record in overview.json workers[]
m2herd-up.sh collect  --slice S [--repo P]          # wait idle, copy worker report to dispatch/S.out.md, update workers[] state
m2herd-up.sh --dry-run <same args>                  # print every herdr/git command instead of running it
```
Notes pane viewer command (exact): `watch -n 2 -t cat .m2herd/NOTES.md` if `watch`
exists, else a `while :; do clear; cat .m2herd/NOTES.md; sleep 2; done` bash loop.
Herdr rules (binding): identify `$SELF` first and never touch it; after `agent start`
RE-RESOLVE the pane by cwd from `herdr agent list` (returned pane_id can be off by one);
no `--split` (stray-pane bug); settle ~1s between `agent send` and Enter.

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
  documenting doctrine, layout, engine, workspace shape (1 orchestrator pane + 1 notes pane), hooks,
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
