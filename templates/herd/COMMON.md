# Herd rules moved to `rules/`

Since 2.10.0 the rules for herd agents are role files, not a per-herd COMMON chain:

- `templates/herd/rules/WORKER.md`, `REVIEWER.md`, `FIXER.md` — the rules per role.
- `templates/herd/rules/MODELS.md` — which model and effort for which task.

`herd-context <role> <herd> [<slice>]` writes `<herd>/<slice>.ctx.<role>.md`: the role's rules with the
herd's values filled in, then the task, report, findings, clash list, memory and register excerpt.
`herd-spawn` points a worker at that file. It looks for the rules in `$HERD_RULES_DIR`, then
`<project>/.m2herd/rules/` (project overrides), then these templates.

Per-herd values are never typed into the rules. Put them into `<herd>/ctx.env` (`KEY=value` lines,
or `HERD_CTX_<KEY>` in the environment); each becomes the placeholder of the lower-cased key:

    ORCHESTRATOR=orchestrator-1
    LANGUAGE=English
    PORTS=api 8061-8069, ui 3161-3169 (slice n uses the n-th)
    TEST_CMDS=api: .venv/bin/python -m pytest -q; ui: npx tsc --noEmit && npm run lint
    UNAVAILABLE=nothing
    TICKET_CMD=lage card <id>
    REGISTER_LINT=python3 .m2herd/register-lint.py

No inline comments: everything after `=` is the value. `ORCHESTRATOR` is the `SendMessage` target for
reports (`HERD_ORCH_NAME` sets it too); `LANGUAGE` covers commits, PR texts, user-facing strings and
review findings.

Filled by `herd-context` itself: `herd`, `slice`, `role`, `report`, `status`, `worktrees`,
`base_shas`, `orch_pane`. Anything left unfilled is listed in the head of the context file.

A herd directory without `<slice>.ctx.worker.md` still works: `herd-spawn` then points the worker
at `<herd>/COMMON.md` if one exists. For a new herd, write `ctx.env` and run `herd-context` instead.
Task file format: `templates/herd/task.md.example`.
