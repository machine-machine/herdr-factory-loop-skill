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

    tickets: 1111111111, 2222222222
    together_with: reviere-ui        # package partner slices, merged as one unit
    stacked_on: kartenstil            # base slice whose PRs must merge first
    model: claude-opus-5-5            # default claude-opus-5-5
    effort: high                      # default high
    needs_memory: stacked-pr-merge.md, worktree-setup.md

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

`WORKER.md`, `REVIEWER.md`, `FIXER.md` replace the per-herd COMMON chains; `ORCHESTRATOR.md` and
`HERD-CUT.md` (the pre-start check of the cut) are herd-level roles: `herd-context orchestrator|herd-cut
<herd>` takes no slice and writes `<herd>/ctx.<role>.md` (plan, every task header or task, packages,
stacks, clashes, phases, register excerpt); the cut check reports to `<herd>/HERD-CUT.out.md`. The
skeptic has no file of its own — the loop points skeptics at the reviewer context, so `REVIEWER.md`
carries an "As a skeptic" section. Per-herd values (orchestrator name, ports, base shas) are filled
in by `herd-context`, never typed into the rules.

Every role file has the same shape, borrowed from the BMad Method's agent personas (MIT; attribution
in `NOTICE`): a **Role** table (owns, gets, hands off, never), numbered **Principles**, the
**Workflow** or checks, the **handoff artifact** and its vocabulary, then the hard rules. Borrowed
where it fits the flow:
- orchestrator ← Product Owner: requirements written once in the task with their source, scope
  decided once and recorded, queue ordered riskiest-first, done as a check the orchestrator runs,
  replan when a report shows a later task no longer fits; a readiness standard before `queued`.
- cut check ← readiness gate `PASS | CONCERNS | FAIL` plus the set and dependency checks and the
  Architect's focus on invariants between slices built apart (hot files, missing pairs, interfaces).
- worker ← Developer: the task is the spec, acceptance criteria `AC<n>` as vocabulary, no criterion
  met without a check that would fail, red-green-refactor; the report sections and the blocking
  conditions (`unclear intent`, `intent gap`, `decision needed`, `verification failed`,
  `environment`, `base moved`) of the unattended build workflow.
- reviewer/skeptic ← code review: lenses (acceptance, edge cases, verification gap, safety), verify
  the claim before grading it, severity = harm of one occurrence, zero findings is valid;
  pre-existing problems go to the after-merge list as `pre-existing:` lows.
- fixer and the worker's fix round ← finding routing: fix / decision needed / not fixed.
- `task.md.example` ← story format: numbered Given/When/Then criteria with a check each,
  *Must not change* boundaries, marked `Assumption:` lines.
Not borrowed: named personas, greetings, menus and customisation layers (agents here are started
non-interactively); PRD, architecture and epic documents and a stored ticket tree or plan `status`
(the flow writes down decisions, never state — phases live only in `herd.events.jsonl`); a
`WAIVED` gate state (a medium/high finding is fixed or refuted, never waived); forced minimum
finding counts.
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
    ~/.cache/m2herd/<project>/   run data: screens/, runs/, backups/, logs (deleted by m2herd-purge, below)
    ~/.m2herd/state/<project>/   runtime state: sqlite, *.lock, poll/watch state

`m2herd-migrate [--apply]` — dry run by default: prints every move with size and every reader found
by `grep -rl` (scripts, hooks, skills) that still references the old path; `--apply` refuses while
any reader is unresolved unless `--force-readers`, writes `archives/<date>/INDEX.md`, never deletes
(except `__pycache__`), and finishes with the reader check again.

### 7.1 Weekly purge: `m2herd-purge`

Migration happens once; files keep piling up afterwards (one fabric grew from 98 MB to 718 MB in a
day, ~630 MB of it screenshots and run data). `m2herd-purge <fabric>` runs weekly and removes what
nobody uses any more. `--help` has the full rules; the policy is:

a. **Run data is deleted.** Under `~/.cache/m2herd/<project>/` every entry of a run-data dir
   (`screens/ screenshots/ runs/ backups/ logs/`, `HERD_PURGE_RUN_DIRS`) and every top-level `*.log`
   is deleted when its newest file is older than `HERD_PURGE_RUN_DAYS` (14). Herd run data
   (`herden/<herd>/`) is one unit and counts from the herd's last `merged` event in
   `<herd>/herd.events.jsonl` (read through `herd_events.py`, also in `archives/`). A herd with a
   slice that is not `merged`/`parked` keeps all of its data, however old. When no event file is
   found, the newest file mtime counts. `runs/CURRENT` and the run it names stay.
b. **Inside the fabric only caches are deleted:** `__pycache__/`, stray `*.pyc`, `*.lock` files no
   process holds (no fd in `/proc`, a non-blocking `flock` succeeds, lock and base file unused for
   `HERD_PURGE_GRACE_HOURS`, 24), and empty dirs (empty for the grace time or emptied by this run; one
   a sibling file names as `<dir>/`, like `deep: ./deep/`, stays). Everything else that is **no longer
   used** is **moved** to `archives/<date>/<same path>`, and each move gets one line in
   `archives/<date>/INDEX.md` (path, size, last modified, why). A file is no longer used when all three
   hold: nothing in it changed for `HERD_PURGE_ARCHIVE_DAYS` (30), no reader references it, and it is
   not on the keep list. Units are the top-level entries plus the entries of `dispatch/` and
   `herden/`. A herd dir moves as a whole or stays, and no other dir is split either.
   - *Readers* are the `m2herd-migrate` reader check, imported from that script: fixed strings
     `.m2herd/<path>` under the `--readers` roots (`HERD_PURGE_READERS`, default
     `~/.local/bin,~/.claude/hooks,~/.claude/skills`) plus the fabric's own scripts. On top of that
     come the project dir's top-level files (decisions register, `CLAUDE.md`) and every text file of
     the fabric that stays (RESUME, PHASE-NEXT, rules, live herds, recent reports; of `NOTES.md`
     only the current month). A bare word like `context` counts only as `context/` or
     `.m2herd/context`, so prose does not keep a dir. A reference from a file archived in the same
     run keeps nothing.
   - *Keep list:* `RESUME.md`, `NOTES.md`, `PHASE-NEXT-*`, `rules/`, `herden/`, `dispatch/`,
     `archives/`, `checks.sh`, top-level register/decisions files, the m2herd engine's files (names in
     `templates/m2herd/`), top-level scripts, runtime state (`*.sqlite3`, `*.db` and their side files,
     `*state.json`, `.sync-*`; `m2herd-migrate` moves those), files with a `<file>.lock` sibling,
     `*.jsonl` logs and dirs that hold one, dotfiles, live herds (v2: a slice not merged/parked; v1:
     changed within `--live-hours`, 48), and `HERD_PURGE_KEEP` globs.
c. **Run data found inside the fabric** goes to the cache first, the way migrate moves it: any dir
   named like a run-data dir, so `dispatch/screens/`, `<herd>/screens/`, `<loop>/runs/` and `backups/`.
   `dispatch/screens` → `screens/`, `<herd>/…` → `herden/<herd>/…`, any other path keeps its path.
   After the move it falls under (a). An entry that (a) would delete straight away is deleted in
   place, so it is never copied first. Entries newer than the grace time stay, and so do live herds.

`archives/` is never touched, and nothing a process holds open is moved or deleted. Settings come
from the command line, then the environment, then `<fabric>/rules/purge.env` (`KEY=VALUE` lines),
then the defaults.

Dry run by default: every action is printed with its size and reason, followed by totals (deleted,
moved to the cache, archived, freed from disk). `--summary` prints only the totals and `--verbose`
adds every kept entry with its reason. `--apply` does it. A `flock` on the fabric dir keeps two runs
apart. When `--apply` changed something, one `- [<UTC ts>] m2herd-purge: …` line is appended to
`NOTES.md` under `NOTES.md.lock`. Exit 0 = ok (also nothing to do), 1 = an action failed (the rest
still ran; each failure is printed), 2 = usage error, missing fabric, or another run holds the lock.

**Weekly, for every fabric.** List the fabrics in `~/.config/m2herd/fabrics`, one path per line,
`#` for comments; `m2herd-purge --fabrics <file>` runs them in turn. The systemd user units in
`templates/systemd/` (`m2herd-purge.service` + `.timer`: `OnCalendar=weekly`, `Persistent=true`) run
`m2herd-purge --apply --fabrics %h/.config/m2herd/fabrics`. Nothing is installed or enabled for you:
copy both into `~/.config/systemd/user/`, do one dry run, then
`systemctl --user enable --now m2herd-purge.timer`. Without systemd, add a crontab line instead
(`crontab -e`): `17 4 * * 1 $HOME/.local/bin/m2herd-purge --apply --fabrics $HOME/.config/m2herd/fabrics >>$HOME/.cache/m2herd/purge.log 2>&1`

## 8. STEER: intelligent determinism

Watchers append to `.m2herd/inbox/STEER.md` faster than anyone reads it, and a snapshot watcher
re-posts the same findings every run with new counters, so the file grows into noise nobody
drains. Hooks are deterministic but cannot judge; an agent judges but forgets. The fix splits
the work in three and lets each part do only what it is good at:

1. **Deterministic intake — `scripts/m2herd-steer`** (python3 stdlib). Parses every entry below
   the marker; a `- <ts> <Source>: a; b; c[. Word: /path]` line is split into findings, anything
   else is one finding. Key = normalised text (timestamps out, numbers below 6 digits -> `#`,
   ids -> `<id>`) plus the subject (leading id chain, else first id, else text); `Label: id,id,…`
   lists key on the label and carry the ids. Repeats fold into one item with first/last seen and
   count. Append-only ledger `inbox/steer.ledger.jsonl` (flock `<ledger>.lock`): `seen`, `ack`,
   `defer`, `superseded`, plus `compacted`/`vanished` so no line is ever counted twice. The intake
   itself supersedes what a newer report replaced: a newer status for the same subject, or — for
   snapshot watchers (consecutive reports share findings) — a finding absent from the source's
   last 2 reports. Event-style sources (one finding per line) never lose items by absence.
2. **Deterministic gate — `hooks/m2herd-steer-gate.sh`** (UserPromptSubmit, and Stop with argv
   `Stop`). Pending > 0 → one `additionalContext` line: count, top 3 keys (urgent words first),
   the rules path and the exact commands. Silent at 0, in herd worker panes (`M2HERD_WORKER=1`,
   `HERD_SLICE`, herd.map membership as in `herd-board-subagents.py`), in subagents, on
   `stop_hook_active`, with `M2HERD_STEER_GATE=0`. Same open set at most once per 30 min per
   session (state in `~/.m2herd/state/<project>/steer-gate.json`). Never emits a `decision`, so
   it never blocks a turn.
3. **Agent judgment — `templates/herd/rules/STEER.md`**. Per item exactly one ledger action:
   `done` (reopens when reported again), `ticket` / `register` / `delegated` (repeats stay quiet,
   new ids reopen), `dropped` (never reopens), `defer --until` (open again after the date). One
   subagent per group of related items, never per item; human lines are never dropped silently.
4. **Deterministic verification — `m2herd-steer verify`** exits 1 while any item is neither acked,
   superseded nor deferred into the future. This repo has no fabric check script; a project wires
   `m2herd-steer --fabric <root> verify` into its own checks (session start, after a merge). Then
   `m2herd-steer compact` moves entries whose findings are all closed into
   `archives/steer/<YYYY-MM>.md` under `<STEER.md>.lock` (same-dir tmp + rename; a line an unlocked
   appender writes meanwhile is carried over). Open or deferred entries never move; STEER.md is
   never cleared by hand.

Tests: `python3 tests/steer/test_steer.py` (offline, temp HOME; a synthetic STEER.md with a
snapshot watcher, an event-style watcher and human/TUI lines; hook format, rate limit, worker
silence, compaction, append-only ledger).
