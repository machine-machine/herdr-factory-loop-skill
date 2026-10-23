# Herd flow v2 — spec (build contract for 2.10.0)

Status: proposal, built on branch `feat/herd-flow-v2`. Nothing here takes effect until the PR is merged
and `install.sh` re-links. The flow it encodes was asked for by the herd's human on 23.10.2026:

> triage a board column → plan + queue of workers (some start, rest queued, no conflicting goals,
> clashes made visible) → worker done and the orchestrator is satisfied → move to *ready to merge* →
> orchestrator picks the moment for the ultracode review → green ✓ when clean, yellow/orange when it
> found problems and back to the TOP of the queue to fix → green items merge only on the human's go.

This document is the single schema all v2 pieces build against. Language of code and docs: English;
user-facing board strings keep the existing `HERD_BOARD_LANG=de|en` tables.

## 1. One source of state: `<herd>/herd.events.jsonl`

Append-only, one JSON object per line, written ONLY through `herd-phase` (flock on
`<herd>/herd.events.jsonl.lock`). Current state of a slice = its last `phase` event. Everything that is
a live fact (PR open?, head sha, pane alive, processes, file overlap) is **computed**, never stored.

Event fields (all events): `ts` (ISO-8601 UTC, set by herd-phase), `slice`, `phase`, `by`
(`orchestrator|worker|loop|watch|merge|recover`), optional `note` (one sentence).
Extra fields by phase:

| phase | meaning | extra fields |
|---|---|---|
| `queued` | waiting for a free slot | `pos` (int, optional) |
| `working` | worker TUI running | `pane`, `session_id`, `model`, `effort`, `wt` (list of worktrees) |
| `accepted` | orchestrator reviewed the report and is satisfied | `prs` (list of `repo#n@sha7`), `checks` (list of strings) |
| `review_running` | ultracode review loop started | `run_id`, `round` |
| `review_ok` | loop clean for these heads | `prs` (`repo#n@sha40`), `main` (`repo@sha40` per repo), `run_id`, `lows` (list) |
| `review_befund` | loop found medium/high | `prs`, `run_id`, `befunde_file` |
| `fix_queued` | back to the worker, top of the queue | `befunde_file` |
| `merged` | squash-merged on the human's go | `prs` (`repo#n@merge_sha7`), `go` (verbatim words of the go, ≤ 120 chars) |
| `parked` | intentionally stopped | `reason` |

Allowed transitions (herd-phase refuses others unless `--force` with `note`):
`queued→working`, `working→accepted|parked`, `accepted→review_running`,
`review_running→review_ok|review_befund`, `review_befund→fix_queued`, `fix_queued→working`,
`review_ok→merged|review_running|fix_queued`, `accepted→working` (orchestrator sends back), any→`parked`.

Computed states (board only, never written):
- `reported`: last phase `working`, `<slice>.out.md` exists, agent idle/done, no live process.
- `stale` on `review_ok`: any PR head ≠ recorded sha, or a merge landed on that repo's main since
  `review_ok.main` → board shows yellow „veraltet“; the orchestrator re-runs a probe (see §5).
- `needs_you`: herdr reports `blocked`, or the package is `review_ok` and not stale (merge word due).
- `clash`: `git diff --name-only origin/<base>...HEAD` of two live slices in the same repo intersect
  (test files excluded) → ⇄ mark naming the other slice.

Retired by v2 (read once by `herd-recover` for migration, then never written): `herd.map`,
`active.txt`, `done.txt`, `<slice>.started`, `<slice>.freigabe`, `~/.cache/herd-board/review-state.json`,
`herd-review-mark`.

## 2. Slice declaration: `<slice>.task.md` header + `<slice>.repos`

`<slice>.task.md` starts with a header block (YAML-ish `key: value` lines until the first blank line):

    tickets: 13362298970, 13216640480
    together_with: reviere-ui        # package partner slices, merged as one unit
    stacked_on: kartenstil            # base slice whose PRs must merge first
    model: claude-opus-5-5            # default claude-opus-5-5
    effort: high                      # default high
    needs_memory: gst-stacked-pr-merge.md, worktree-api-users-file.md

`<slice>.repos`: one line per repo `repo branch base` — the base column is REQUIRED (`origin/main`
or the parent's branch). A package = transitive closure of `together_with`; a stack = `stacked_on`.

## 3. Board lanes (`herd-board`)

Top to bottom, a lane is drawn only when non-empty:
1. **Braucht dich / Needs you** — packages ready for the merge word (✓✓ bold green + the exact word,
   e.g. `merge reviere`), and slices herdr reports `blocked` (? yellow).
2. **Warteschlange / Queue** — `fix_queued` first (! orange, always above first starts), then
   `queued` (◌ grey, „startet als n.“, and the reason it waits: slot, base not accepted, memory).
3. **Arbeit / Working** — `working` (● cyan; ⧗ while tests/build run; ↺ orange on a fix round),
   computed `reported` (✓ thin green „prüfe ich“), disturbances (⚠ still, ✕ gone).
4. **Merge-bereit / Ready to merge** — one row per package: `accepted` (◇ grey + why the review
   waits: partner, base, slot), `review_running` (… pink, round n/3), `review_ok` (✓ green @sha7),
   `stale` (yellow „veraltet“), `review_befund` (! orange, moves to the queue lane right after).
5. **Heute gemergt / Merged today** — one line, numbers green, from `merged` events plus the
   existing GitHub search fallback.

Header adds `Plätze n/m (k Review)` and `du: n`. Each slice row ends dim with model·effort (`O·hi`,
`F·hi`, `S·md`). Meaning is carried by the icon, colour only reinforces it. Never truncate with „…“;
never silently cap — overflow says `+N weitere`. Existing behaviour kept: subagents (◆ magenta),
adaptive height, `--selftest`, `NO_COLOR`, `HERD_BOARD_LANG`, `HERD_BOARD_ORG`, `HERD_BOARD_REPOS`.

## 4. Scripts

All in `scripts/`, linked by `install.sh` into `~/.local/bin` without the extension.

- `herd-phase <herd> <slice> <phase> [--field k=v …] [--note …] [--force]` — validates transition,
  appends the event, mirrors it with `lage log <ticket> herd-<phase>` when `lage` exists and the task
  header has tickets (silently skipped otherwise). `herd-phase <herd> --state [--json]` prints the
  current phase of every slice. Python 3, stdlib only, importable helpers in `scripts/herd_events.py`.
- `herd-spawn.sh <herd> <slice> [--resume]` — reads worktrees from `.repos`, model/effort from the
  task header; refuses to start when `herd-limits` says no slot (prints why); new session gets
  `--session-id <uuid4>` recorded in the `working` event; `--resume` continues THAT id with
  `claude --resume <id>` and, when the last phase is `fix_queued`, the prompt points at the
  `befunde_file`. Pane placement unchanged (tab `herde`, split the tallest pane, right when < 24 rows).
- `herd-limits` — single budget for workers AND review agents: env/`<herd>/limits.env`
  `HERD_MAX_SLOTS` (default 6), `HERD_MIN_FREE_MB` (default 8000), `HERD_MAX_LOAD` (default = cores×2.5).
  Exit 0 = slot free; prints `slots used/max, free MB, load`.
- `herd-watch <herd>` — long-running (does not exit per event): starts `fix_queued` before `queued`,
  respects `stacked_on` (base at least `accepted`), keeps a slice queued when its start fails
  (logs the error, retries next tick), recognises herdr `done`, finds the `herde` tab by label (no
  hard-coded tab id), wakes the orchestrator on reported/blocked via `herdr agent prompt` only to the
  pane named in `HERD_ORCH_PANE`.
- `herd-clash <herd>` — prints overlapping files between live slices per repo; `--json` for the board.
- `herd-context <role> <herd> <slice>` — writes `<herd>/<slice>.ctx.<role>.md` (role: worker,
  reviewer, fixer). Head: generation time, head shas, and the command behind every section.
  Sections: rules file for the role (§6), the task header + task, report (`out.md`, reviewer/fixer),
  befunde file (fixer), clash list, `needs_memory` files in full, register excerpt
  (`register-excerpt.py`: entries whose refs/rationale mention a ticket id, a touched file, or a task
  keyword; capped by bytes with a `+N weitere` line), `lage search` top 10 for the task keywords
  when `lage` exists. Pluggable: every source is skipped with a one-line note when its tool is absent.
- `herd-merge <herd> <package> --go "<verbatim words>"` — refuses unless every slice of the package is
  `review_ok`, not stale, every PR MERGEABLE with base `main` (re-read just before merging); merges in
  `stacked_on` order, API before UI within a package (`HERD_MERGE_ORDER` repo list), squash; for each
  stacked child: `rebase --onto origin/main <old-parent-head>` in its worktree, `range-diff` must show
  only `=` lines (else stop and mark the child `fix_queued`), force-with-lease, retarget base via REST,
  only then delete the parent branch. Writes `merged` with the go words. After each merge marks every
  other `review_ok` package of the same repo stale (computed) and prints what to re-probe.
  Stops at the first failure — never continues past a half-merged package.
- `herd-recover <herd>` — after a crash/reboot: reconciles events with live herdr panes, sessions and
  GitHub; appends correcting events with `by: recover`; checks every repo for empty git objects
  (`find .git/objects -type f -empty`) and reports them; restarts the board with `--anchor`.

## 5. Review loop (`templates/herd/workflows/`)

`review-fix-loop.js` + `review-open-prs.js` (moved from per-herd copies into the skill):
- starts with `herd-phase review_running`, ends with `review_ok` (with all head and main shas) or
  `review_befund` + `fix_queued`, writing `<slice>.befunde-<sha7>.md`. The orchestrator no longer
  hand-writes sign-offs.
- `HERD_FIX_BY=worker` (default): no fixer agent — findings go back to the original worker via
  `fix_queued`; `HERD_FIX_BY=fixer` keeps today's in-loop fixer.
- integration probe re-enabled: before `review_ok`, every package of the same repo is merged locally
  onto current main in the planned order and the touched suites run.
- review worktree `<slice>--review` pinned to the accepted sha; never the worker's worktree.
- model per agent (no inheritance): main reviewer = the model the worker did NOT use
  (`HERD_REVIEW_MODEL=other|same`, default `other`, fallback Opus when Fable is unavailable);
  skeptics one Opus + one Fable; effort `xhigh` for merge/auth/migration/hot-file probes.
- stale rule (`HERD_STALE=delta`, default): after a merge on main, re-run probe-merge + suites; a
  delta review of `git diff <reviewed-sha>..<new-head>` only when a rebase changed code; `full` re-reviews.
- low findings: listed in `review_ok.lows` and appended to `<herd>/NACH-MERGE.md`.
- no hard-coded org, repo, herd path or setup script: everything comes from `args` (repo list,
  setup command, test commands per repo).

## 6. Rules templates (`templates/herd/rules/`)

`WORKER.md`, `REVIEWER.md`, `FIXER.md` replace the per-herd COMMON chains. Per-herd values
(orchestrator name, ports, base shas) are filled in by `herd-context`, never typed into the rules.
`MODELS.md` — the model table below; the authoritative copy of a team's choice lives in its own
decisions register, MODELS.md is the skill default.

| Task | Model | Effort |
|---|---|---|
| Orchestrator: triage, plan, accept, packages, merge | Opus 5.5 (Fable 5.1 when Opus panes hang) | high |
| Pre-start check of the herd cut (hot files, pairs) | Fable 5.1, one agent | high |
| Worker: implementation with clear acceptance | Opus 5.5 | high |
| Worker: fuzzy domain logic, new data model, many open questions | Fable 5.1 | high |
| Fix after review | same model, same session (`--resume`); switch model after the 2nd orange round at the same spot | as worker |
| Main reviewer | the other model than the worker | high; xhigh for merge/auth/migration/hot-file probes |
| Skeptics per medium/high finding | one Opus 5.5 + one Fable 5.1 | medium |
| Conflict resolution, restacking | Opus 5.5 | high |
| Data digging, measurement | Opus 5.5 | medium |
| Team-facing ticket text | Opus 5.5 | high |
| Mechanical bulk (screenshots, list diff, lint/rename, first drafts) | Sonnet 5.5 | medium — never review, skeptic, domain slice or code on a herd branch |

## 7. `.m2herd` layout v2 and `m2herd-migrate`

Target (per project fabric): only things that stay true — rules, decisions, append-only events,
evidence reports. State is computed (`checks.sh`, `herd-board`, `lage card`).

    .m2herd/
      RESUME.md            header + the 10-line window only; old "Vorheriger Stand" → archives
      PHASE-NEXT-<date>.md exactly one
      NOTES.md             current month; older months → archives/notes/<YYYY-MM>.md
      rules/               WORKER.md REVIEWER.md FIXER.md MODELS.md limits.env (project overrides)
      herden/<herd-DDMM>/  PLAN.md, queue.txt, herd.events.jsonl, per slice: task.md, .repos,
                           status.json, out.md, befunde-<sha7>.md, ctx.<role>.md (generated, ignored)
      dispatch/            one-off investigations; > 21 days → archives/dispatch/<YYYY-MM>/
      archives/<date>/     INDEX.md one line per moved file
    ~/.cache/m2herd/<project>/   run data: screens/, runs/, backups/ (deleted 14 days after the herd merged)
    ~/.m2herd/state/<project>/   runtime state: sqlite, *.lock, poll/watch state

`m2herd-migrate [--apply]` — dry run by default: prints every move with size and every reader found
by `grep -rl` (scripts, hooks, skills) that still references the old path; `--apply` refuses while
any reader is unresolved unless `--force-readers`, writes `archives/<date>/INDEX.md`, never deletes
(except `__pycache__`), and finishes with the reader check again.
