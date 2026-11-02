# Herd review workflows

Two Claude Code Workflow-tool scripts implement the review loop of `docs/herd-flow-v2.md` §5. They
replace the per-herd copies that used to live next to each herd's `PLAN.md`.

| Script | Role | Writes herd state? |
|---|---|---|
| `review-fix-loop.js` | driver, one loop per package: start → review round → (fixer) → record | yes, through `herd-phase` |
| `review-open-prs.js` | one review round: pin, review, verify, integration probe | never |

A workflow script cannot run a shell. Every write therefore happens like this: the driver builds a
bash script byte for byte (exact `herd-phase` commands, heredocs for the files), and a low-effort
agent runs it verbatim and returns exit code + output. The tests run those same scripts for real.

## Calling it (orchestrator)

When every slice of a package is `accepted` (or a `review_ok` package went stale), call the Workflow
tool with `scriptPath` = the absolute path of `review-fix-loop.js` in your checkout of this skill repo
(`install.sh` links `skill/`, so resolve it from the repo, e.g.
`$(dirname "$(readlink -f ~/.claude/skills/herdr)")/templates/herd/workflows/review-fix-loop.js`)
and these `args` (as a JSON object, not a string):

    {
      "herd": "/abs/project/.m2herd/herden/herd-2310",
      "reviewScript": "/abs/herdr-factory-loop-skill/templates/herd/workflows/review-open-prs.js",
      "run_id": "2310T1405",
      "review": ["reviere"],
      "groups": [
        {"name": "umgriffe", "slices": ["umgriffe"], "prs": [
          {"repo": "acme/api", "short": "api", "n": 209, "head": "fix/umgriffe", "base": "origin/main",
           "wt": "/home/me/.herdr/worktrees/api/umgriffe", "worker_model": "claude-opus-5-5"}]},
        {"name": "reviere", "slices": ["reviere", "reviere-ui"], "prs": [
          {"repo": "acme/api", "short": "api", "n": 210, "head": "fix/reviere", "base": "main",
           "wt": "/home/me/.herdr/worktrees/api/reviere", "worker_model": "claude-fable-5-1"},
          {"repo": "acme/ui", "short": "ui", "n": 86, "head": "fix/reviere", "base": "main",
           "wt": "/home/me/.herdr/worktrees/ui/reviere-ui", "worker_model": "claude-opus-5-5"}]}
      ],
      "setup": {"acme/api": "uv sync -q", "acme/ui": "npm ci --no-audit --no-fund"},
      "tests": {"acme/api": ".venv/bin/python -m pytest -q -p no:cacheprovider", "acme/ui": "npx tsc --noEmit && npm run lint"},
      "fixBy": "worker",
      "reviewModel": "other",
      "stale": "delta"
    }

- `groups` is every open package **in planned merge order** — the integration probe uses it as the
  baseline. `review` picks which of them run now (default: all). Only `review` groups get events.
- `prs[].short` must be the GitHub repo name without its owner (the `repo` column of `<slice>.repos`):
  `herd-merge` and the board resolve `short#n@sha` through it.
- `prs[].slice` is optional; it defaults to the basename of `wt` when that is one of `slices`.
- `base` may be `main`, `origin/main` or a parent branch (stacked); a non-main base counts as a merge
  probe (reviewer effort `xhigh`).
- `setup[repo]` runs inside every fresh `<slice>--review` and probe worktree (again on a re-pin when a
  dependency manifest changed), with env `HERD_WT`, `HERD_SRC_WT` (the worker's worktree, e.g. to copy
  a local `.env`), `HERD_REPO`, `HERD_SLICE`, `HERD_SHA`. Keys match the full repo, its basename or
  `short`. Same lookup for `tests`.
- Optional: `herdPhase` (command, default `herd-phase`; unquoted, so `python3 /path/herd-phase` works),
  `maxFix` (3), `models` (`{opus, fable}` ids), `hot` (`{repo: [regex]}` extra hot-file patterns),
  `rules` (one paragraph of project rules appended to every prompt), `register` (decisions register
  path), `lang` (findings language, default English), `git` (`{name, email, coauthor}` for fixer commits).
- `run_id`: pass something unique (a timestamp). Scripts cannot read the clock.

`review-open-prs.js` can also run alone (`args` = `groups` + `setup`/`tests`, no `herd`): a read-only
review of the current PR heads, nothing recorded.

## What happens, and what each step writes

1. **Start** — refuses the package unless every slice's last phase is `accepted`, `review_ok`
   (stale re-probe) or `review_running` (resume of an interrupted run). Then
   `herd-phase <herd> <slice> review_running --by loop --field run_id=… --field round=1`, then
   `herd-context reviewer` (and `fixer` with `fixBy=fixer`) for each slice when `herd-context` is on
   PATH, so the prompts' `<slice>.ctx.<role>.md` exists.
   Refused → outcome `not_started`, nothing written.
2. **Pin** (child) — fetches `refs/pull/<n>/head` and the base, and checks out
   `<wt>--review` detached at the **accepted sha** from the `accepted` event (the current head when
   resuming, after a fixer round, or on a stale re-probe). The worker's worktree is never used. The
   review worktree stays for the next round; its setup log is `<wt>--review.setup.log`.
3. **Review** (child) — one main reviewer per PR. **Verify**: two skeptics per medium/high finding.
   A finding survives when at least one skeptic confirms and confirmations ≥ refutations; its final
   severity is the highest a confirmer gave. If no skeptic answers it is kept, marked unverified.
   Low findings get no skeptics.
4. **Integrate** (child, parallel to the review) — per repo of the package: worktree
   `<dirname wt>/<package>--int` on current `origin/main`, merge the earlier packages of that repo
   (baseline), run `tests[repo]`, merge this package's pinned shas (candidate), run again. New failures
   and conflicts with main are high findings without skeptics; conflicts only with an earlier
   package are low ("rebase after X merges"). The probe worktree is removed afterwards.
5. **Fix** — `fixBy=worker` (default): none. `fixBy=fixer`: one fixer per package in the worker
   worktrees (same model as the worker, the other model after the second orange round at the same
   spot), pushes without force, then the next round reviews the new head; at most `maxFix` rounds.
6. **Record** — per slice:
   - no medium/high: `review_ok` with `prs` = `short#n@sha40`, `main` = `short@sha40` per repo (the
     main the probe merged onto), `run_id`, `lows`; lows are also appended to `<herd>/NACH-MERGE.md`.
   - medium/high: writes `<herd>/<slice>.befunde-<sha7>.md` (sha7 of the slice's first PR pin;
     findings, skeptic reasons, probe summary, loop history, the `herd-spawn … --resume` hint), then
     `review_befund` (`prs`, `run_id`, `befunde_file`) and `fix_queued` (`befunde_file`). `herd-watch`
     restarts the worker from there; nobody hand-writes sign-offs.

Stale rule (`stale=delta`, default) for a `review_ok` slice: same head, or a rebase whose
`git range-diff` shows only `=` lines → probe only; code changed → delta review of the new head;
`stale=full` → full review.

## Models (no inheritance — every agent sets its own)

| Agent | Model | Effort |
|---|---|---|
| start / pin / record script runner | Opus | low |
| main reviewer | the model the worker did not use (`reviewModel=same`: the worker's); Opus when Fable gives no result | high, `xhigh` when hot (migration, auth/session/token/permission, SQL, Dockerfile, stacked base, `hot` patterns) |
| skeptics | one Opus + one Fable | medium |
| integration probe | Opus | xhigh |
| fixer | the worker's model, the other one after the 2nd orange round at the same spot | high |

## Result

`{run_id, fix_by, results: [{group, outcome, rounds, slices: {<slice>: {outcome, prs, main?, lows, befunde_file?, blocking?}}, hist, record}]}`
with `outcome` one of `review_ok`, `review_befund`, `not_started`, `error`, `record_failed`.

- `error` (pin or review failed): slices stay `review_running`; re-run the loop — Start resumes them.
- `record_failed`: the result carries `script`; run it yourself (it is the exact write sequence), do
  not re-type the commands.

## Tests

    node tests/workflows/run.mjs [-v]

Offline, temp dirs only: stub globals, throwaway bare repos with `refs/pull/<n>/head`, the real
`scripts/herd-phase`, stub `herdr`/`gh`/`lage` on PATH. Covers clean, finding, refused, fixer,
stale/delta/rebase, model switch, integration failure and standalone paths.
