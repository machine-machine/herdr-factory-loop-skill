# .m2herd/runs/ — the trace bundle layer

Written by `m2herd-up.sh` dispatch/collect, read by `m2herd.sh evolve`. Every
dispatched herd produces one run; every slice in that herd produces one trace
bundle inside it.

```
runs/
  CURRENT                    # plain text: the active run-id, no trailing newline padding
  <run-id>/
    run.json                 # {"run_id","created_at","goal","base","slices":["<slice>",...]}
    slices/<slice>/
      prompt.md               # verbatim copy of .m2herd/dispatch/<slice>.task.md at dispatch time
      report.md                # verbatim copy of .m2herd/dispatch/<slice>.out.md at collect time
      status.json              # slice/state/agent/runner/model/branch/worktree/
                                # dispatched_at/collected_at/tokens/cost_usd — see CONTRACT-m2herd.md
      failures.json             # OPTIONAL, orchestrator- or worker-authored; array, may be absent
```

## run-id format

`r-<UTC %Y%m%dT%H%M%SZ>`, e.g. `r-20260705T120000Z` — sorts chronologically as
a plain string, so `--run latest` is just "lexically greatest run dir".

## Rotation

There is no dedicated rotation subcommand in the MVP. `dispatch` reads
`CURRENT`; if it's missing, it creates a fresh run-id, `mkdir -p`s the run dir,
writes `run.json`, and writes `CURRENT`. To start a new run, delete `CURRENT` —
the next dispatch picks up from there. Every dispatch inside the same run
appends (dedup) its slice to `run.json`'s `slices[]`.

See `CONTRACT-m2herd.md` (§ run trace bundles) for the full binding contract:
exact JSON schemas for `run.json`, `status.json`, and `failures.json`.
