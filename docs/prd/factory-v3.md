> Source document for 3.0 as written on 2026-11-03. It is not maintained: where it differs from
> [`docs/factory-v3.md`](../factory-v3.md) (the build contract) or `skill/SKILL.md`, those win.
> Known differences are listed in factory-v3.md §10.

# PRD — herdr factory loop: Reliable Software Factory

Nov 3, 2026 · @Mariusz

## Summary

Version 3.0 turns the skill's four side-by-side orchestration paths into one stage-gated pipeline. A slice counts as done only when a frozen, executable eval is green and a zero-context reviewer finds nothing that survives the skeptics. spec-kit stays the artifact chain, herd flow v2 stays the execution engine, [EGM](https://github.com/google/elephant-goldfish-model) adds goldfish reviews at three gates, and [BMAD](https://github.com/bmad-code-org/bmad-method) contributes right-sized tracks and role lenses as borrowed ideas, not as an install.

Three changes carry most of the value:

1. **One front half.** A compiler turns `specs/<feature>/tasks.md` into herd-flow-v2 slice files, so §11 (spec-kit) and §16 (m2herd) stop being parallel worlds.
2. **Goldfish gates.** EGM reviews spec and plan before the cut. A new blind reviewer pass judges each slice without seeing the worker's report.
3. **Executable done.** Every acceptance criterion becomes a draft eval before dispatch. The human freezes it with the existing `m2herd eval approve`, and the worker cannot touch it.

Ship plan: 3.0.0-alpha today (triage, spec gate, blind review flag, unified SKILL.md §11), 3.0.0 once the compiler and default evals land.

## Background and problem

The 2.10.0 engine is already strong at execution; reliability breaks at the seams between its parts. Herd flow v2 has a cut check (`HERD-CUT.md`), a review loop with an other-model reviewer and two skeptics, an integration probe, merge only on the human's go, and the unreleased `eval`/`loop` layer with checksum-frozen evals. What it lacks is one path from idea to merged code that uses all of that every time.

| Capability | Where it lives in 2.10 | Gap |
| --- | --- | --- |
| Spec chain | §11 spec-kit: spec.md, plan.md, tasks.md | Not connected to herd flow v2. §11.2 dispatches by hand-rolled bash; §16 reads `PLAN.md` + `<slice>.task.md` instead |
| Sizing | §11.4 "When NOT to SDD" (prose) | No recorded decision; every run picks its own ceremony level |
| Design review | none before tasks | Spec and plan are only checked by their own author; HERD-CUT checks slices, not the design |
| Slice cut check | `HERD-CUT.md` | Good; reused as gate G2 |
| Code review | `review-fix-loop.js`, REVIEWER.md | Reviewer reads the worker's report first, which anchors it on the worker's claims |
| Executable checks | §18 `eval`/`loop` | Opt-in per slice and drafted by hand; not part of the definition of done |
| Consistency | `/speckit.analyze` pre-merge | No post-merge check that specs still match code |
| Learning | §17 evolve, `LESSONS.md` | No fixed task set to prove a factory change helped |
| Isolation | git worktrees | Workers run with `--dangerously-skip-permissions` / `--dangerously-bypass-approvals-and-sandbox` |

The README itself lists four orchestration generations side by side (§9 manual, §12/§15 herd-control, §13 fleet-control, §16 m2herd). An agent reading SKILL.md has to choose between them, and the spec-kit path it is told to prefer is the one least connected to the v2 machinery.

## Goals and non-goals

The goal is a factory whose output you can promise to a client: every merged slice traces to a requirement, passed a check its builder could not edit, and survived a reviewer who never saw the builder's story.

**Goals**

- One documented path from intent to merge, with numbered gates G0–G5 and a recorded verdict at each.
- Process sized to the work: a typo never gets a spec; a cross-repo feature never skips one.
- Design flaws caught before fan-out, when they cost one rewrite instead of N parallel rewrites.
- "Done" defined by frozen executable evals plus a surviving-findings-free review, not by worker self-report.
- Requirement-level traceability: spec requirement → slice → AC → eval → PR → findings.
- A benchmark that shows whether a factory change (including this one) improved outcomes.

**Non-goals**

- Installing BMAD alongside spec-kit. Two planners and two loop drivers would compete for the same artifacts and triggers.
- Replacing herd flow v2, the event log, `herd-board` or the review loop. 3.0 feeds them; it does not rewrite them.
- Full autonomy. Merge stays on the human's verbatim go; G1 and G3 add two more human approvals.
- Removing the §12/§13 Hermes paths in this release. They are marked legacy, not deleted.

## Users and operating modes

Three actors share the pipeline; only the human approves gates.

| Actor | What it does in 3.0 | Touchpoints |
| --- | --- | --- |
| Human operator | Picks the track when triage is unsure, approves G1 (design) and G3 (frozen evals), gives the merge go | `herd-board` "Needs you" lane, STEER inbox, chat channel |
| Main orchestrator (Claude Code / Fable; Hermes and Cursor supported) | Runs triage, the spec stages, the compiler and the gates; holds pointers, not context | `m2herd`, `m2herd-up`, `.m2herd/` |
| Workers, reviewers, skeptics, goldfish | Build one slice, or review one artifact with a fixed, minimal context | headless or pane agents via `herd-spawn` / `m2herd-up dispatch` |

Each run takes one of three tracks, chosen at G0 and recorded as an event:

- **Quick** — one slice, no spec. Typos, config, a contained bug with a failing test. Gates: G4 + G5 only.
- **Standard** — spec-kit chain, goldfish review of spec + plan, compiled slices. The default for anything that touches more than one file area.
- **Full** — Standard plus EGM brainstorm before the spec and role-lens reviews (product, architecture, UX, QA). For new systems, client-facing features, auth, payments and migrations.

## Target pipeline

The 3.0 loop is one column of stages, six of them gates that record a verdict before work moves on. Stages 2–5 are new or newly connected; stages 6–8 are herd flow v2 with two additions (frozen evals as part of done, the blind pass).

&#91;embedded content: factory pipeline 3.0 · 9 stages, 6 gates\]

Quick-track work skips stages 2–5 and enters the herd as one slice. Every failed gate loops back to the stage that owns the fix: G1 findings to the spec, G4 findings to the slice's worker, a failed integration probe to the herd.

## Functional requirements

Every gate writes one event to `herd.events.jsonl` (or, before a herd exists, to `specs/<feature>/gates.jsonl`) with its verdict, evidence path and approver. A failed gate never advances the phase. P0 rows make up 3.0.0; P1 and P2 follow in minor releases.

| ID | Gate | Requirement | Priority | Source |
| --- | --- | --- | --- | --- |
| FR-01 | G0 Triage | `m2herd triage "<intent>"` picks Quick, Standard or Full from explicit rules (file areas touched, risk words such as auth, payment, migration, new system) and records track + reason; `--track` overrides | P0 | BMAD planning paths |
| FR-02 | G0 | Repo with no constitution or design docs → offer EGM bootstrap once to document the existing codebase | P2 | EGM bootstrap, BMAD brownfield |
| FR-03 | Spec | Full track starts with EGM brainstorm; its `concepts_brief.md` is the input to `/speckit.specify` | P2 | EGM brainstorm |
| FR-04 | Spec | Every requirement in `spec.md` has a stable ID; the compiler refuses a spec with an unnumbered requirement | P0 | new |
| FR-05 | G1 Design | Orchestrator runs EGM review on `spec.md` + `plan.md` + `contracts/` in fresh subagents; findings land in `specs/<feature>/reviews/g1-<n>.md`, are worked through with EGM resolve, and `design_ok` needs the human's approval | P0 | EGM review, resolve |
| FR-06 | G1 | Full track adds a role-lens reviewer group (product, architecture, UX, QA) through EGM review loop | P1 | BMAD roles, EGM review loop |
| FR-07 | G1 | Goldfish reviewers use a different model family from the spec author when one is configured (same rule as `MODELS.md` "other") | P1 | existing rule |
| FR-08 | Cut | `m2herd cut --from specs/<feature>` compiles `tasks.md` into `PLAN.md`, `<slice>.task.md` headers and `.repos`: `[P]` tasks become parallel slices, ordered tasks become `stacked_on`, requirement IDs and ACs are copied per slice, model and effort come from `MODELS.md` | P0 | new |
| FR-09 | Cut | Compiler names expected files per slice and runs `herd-clash` logic before any start; an overlap becomes a stack or a merged slice | P1 | existing herd-clash |
| FR-10 | G2 Cut check | `HERD-CUT.md` runs on the compiled herd; FAIL blocks, CONCERNS needs the human's ack | P0 | existing |
| FR-11 | G3 Evals | A test-writer agent (never the slice's worker) drafts one eval per AC via `m2herd eval draft`; each eval must fail on the base sha to count; the human approves and the existing checksum freeze applies | P0 | existing §18 |
| FR-12 | G3 | An AC that cannot be automated is marked `manual:` with a named checker; a slice whose ACs are all manual cannot run on the Quick track | P1 | new |
| FR-13 | G4 Slice | Definition of done: approved evals green in the pinned review worktree at the accepted sha, and `review_ok`; `herd-phase` refuses `review_ok` without an eval pass record | P0 | new on existing |
| FR-14 | G4 | Blind goldfish pass in the review loop: context is the slice's ACs, requirement text, diff and repo, with no worker report and no earlier findings; its findings go through the same skeptics | P0 | EGM principle |
| FR-15 | G4 | Score-type evals (latency, accuracy) route the slice through `m2herd loop` automatically | P2 | existing §18 |
| FR-16 | G5 Merge | Integration probe passes, `/speckit.analyze` has no CRITICAL, and `herd-merge` gets the human's verbatim go | P0 | existing |
| FR-17 | After merge | EGM drift report compares `specs/<feature>/` with main; drift becomes an evolve proposal of a new kind `spec`; a weekly timer runs it like `m2herd-purge` | P1 | EGM drift report |
| FR-18 | All | `m2herd trace` builds `specs/<feature>/trace.json` (requirement → slice → AC → eval → PR → findings) and lists gaps such as a requirement with no eval | P1 | new |
| FR-19 | Learn | evolve gets signatures for gate failures: G1 finding classes, evals that go red after accept, findings only the blind pass caught | P1 | existing §17 |

## Changes to the repo

Most of 3.0 is new glue around existing parts: two new scripts, five new events, three rule files and a rewritten §11. Like herd flow v2, the build contract goes in its own doc, `docs/factory-v3.md`, and SKILL.md wins on conflict.

| Path | Change | FR |
| --- | --- | --- |
| `skill/SKILL.md` | §11 rewritten as "The factory pipeline" with gates G0–G5; §11.2 bash dispatch removed in favour of `m2herd cut` + `herd-watch`; stack map marks §9, §12, §13, §15 as legacy; version 3.0.0; description gains triggers for triage, gates, EGM | all |
| `docs/factory-v3.md` (new) | Build contract: gate semantics, event schema additions, compiler mapping rules, eval validity rule | all |
| `scripts/m2herd-cut` (new, Python) | Parses `spec.md` requirement IDs and `tasks.md`, writes `PLAN.md`, `<slice>.task.md`, `.repos`; dry run by default; `--selftest` | FR-04, 08, 09 |
| `scripts/m2herd.sh` | New subcommands `triage`, `cut`, `gate status/approve`, `trace`, `bench`; `eval draft --from-ac <slice>` | FR-01, 11, 18 |
| `scripts/herd_events.py`, `scripts/herd-phase` | New events `triaged`, `design_review`, `design_ok`, `evals_frozen`, `eval_pass`, `eval_fail`, `drift_found`; `review_ok` only after `eval_pass` at the same sha | FR-13 |
| `templates/herd/workflows/review-fix-loop.js` | `blind` arg (`HERD_REVIEW_BLIND=1`, default on in 3.0.0) starts the goldfish reviewer beside the main reviewer | FR-14 |
| `templates/herd/rules/GOLDFISH.md` (new) | Rules for the blind reviewer: what it gets, what it never reads, finding format shared with REVIEWER.md | FR-14 |
| `templates/herd/rules/TEST-WRITER.md` (new) | Rules for the eval author: one eval per AC, red on base, no access to the worker's branch | FR-11 |
| `templates/herd/rules/ORCHESTRATOR.md`, `MODELS.md` | Gate duties and approvals; model rows for goldfish and test writer | FR-05, 07 |
| `templates/m2herd/settings.json` | `factory` block: default track, gates on/off, blind review, sandbox mode | FR-01, 14 |
| `hooks/herdr-dispatch-nudge.sh` | Nudge proposes `m2herd triage` instead of a herd plan | FR-01 |
| `scripts/herd-board` | "Needs you" lane shows G1 and G3 approvals and G2 CONCERNS | FR-05, 10, 11 |
| `scripts/onboard.sh` | Installs the EGM plugin at a pinned ref, checks the orchestrator can start fresh subagents, records the ref in `~/.config/herdr-factory/config.toml` | FR-05 |
| `tests/cut/`, `tests/gates/`, `tests/bench/` (new) | Compiler fixtures from real spec-kit output, gate transition tests, golden-task fixtures | FR-08, 13, bench |
| `README.md`, `CHANGELOG.md` | One stack map entry "start here: the factory pipeline"; 3.0.0 entry with migration notes | all |

## Upstream integration

EGM is a pinned dependency, BMAD is a source of ideas, and spec-kit remains the one artifact format. That split keeps one owner per stage and one set of files per feature.

| Upstream | How it is adopted | Taken | Left out | Licence and pinning |
| --- | --- | --- | --- | --- |
| [github/spec-kit](https://github.com/github/spec-kit) | Kept as today | spec.md, plan.md, contracts, tasks.md, analyze, clarify | nothing new | MIT; pin the `uv tool install` git ref in onboard.sh |
| [google/elephant-goldfish-model](https://github.com/google/elephant-goldfish-model) | Dependency: plugin installed by onboard.sh | review, resolve, review loop, drift report; brainstorm and bootstrap on the Full track | draft (spec-kit's plan.md is the design doc); its `docs/designs/` layout | Apache-2.0; pin a commit; any vendored prompt keeps its licence header and goes in `NOTICE` |
| [bmad-code-org/bmad-method](https://github.com/bmad-code-org/bmad-method) | Ideas only, no install | Right-sized planning paths (→ tracks), role perspectives (→ G1 lenses), verified context for inherited codebases (→ FR-02) | PRD/architecture/story chain, BMad Loop, `bmad setup`, its skills | MIT; "BMad" is a trademark, so no command or file uses the name; credit goes in README and NOTICE |

Two integration constraints shape the design:

- EGM stops a review when the agent cannot create fresh subagents. Claude Code orchestrators can; for a Hermes orchestrator, G1 runs inside a headless `claude -p` worker that has the plugin installed, and its findings file is collected like any slice report.
- EGM and BMAD both ship skills with broad triggers. Installing BMAD skills next to this skill and spec-kit would add a third set of competing triggers to every turn, which is the main reason it stays uninstalled.

## Security and risk-tiered autonomy

Worktrees isolate code, not credentials or network, so 3.0 ties how much a worker may do to the risk of the slice. Triage assigns the tier; a slice can raise it, never lower it.

| Tier | Typical slices | Worker runtime | Extra gates |
| --- | --- | --- | --- |
| Low | docs, tests, internal tooling | pane or headless, current permission flags allowed | none |
| Medium | application code | headless in a container, worktree mounted, no home directory | blind pass on |
| High | auth, payments, migrations, infrastructure, client data | container with egress allowlist, no credentials in env | Full track, `xhigh` review effort, human reads the diff before go |

Requirements:

- **SEC-1** Medium and high workers run in a rootless container (podman or bubblewrap) with only the worktree and a read-only eval directory mounted; `~/.ssh`, `~/.config` and cloud credentials are not visible.
- **SEC-2** Egress is limited to the git remote, package registries and model endpoints listed in `settings.json`.
- **SEC-3** Secrets never enter a worktree's environment; tests that need them use fixtures or a broker that the eval, not the worker, calls.
- **SEC-4** Intents arriving over a chat channel (§9) are untrusted text. They can start a Low or Medium run; a High run needs the human's approval in the STEER inbox first.
- **SEC-5** The approved eval directory stays checksum-verified (existing §18) and is mounted read-only into the worker container.

## Metrics and benchmark

3.0 ships only if the benchmark shows it beats 2.10 on hidden-test pass rate at no more than 30% extra cost per merged slice. All numbers below come from the event log and `status.json`, so they need no new telemetry; targets are proposals until a 2.10 baseline exists.

| Metric | Definition | Proposed target |
| --- | --- | --- |
| Hidden-test pass rate | Share of bench slices whose held-back tests pass after merge | above 2.10 baseline |
| First-pass acceptance | Share of slices reaching `review_ok` with no `fix_queued` | above 2.10 baseline |
| Escaped defects | Bugs traced to a merged slice within 30 days | half of 2.10 baseline |
| Eval coverage | Requirements with at least one frozen eval, Standard and Full tracks | 90% or more |
| Blind-only findings | Surviving findings that only the blind pass raised | tracked; if near zero after 30 slices, make the blind pass opt-in |
| Late design defects | G4 findings classed as design, not code | falling release over release |
| Cost per merged slice | Tokens and USD from `status.json` | at most 1.3× 2.10 |
| Lead time | Triage to merge, per track | Quick track unchanged |

**Benchmark (`m2herd bench`).** A fixed set of 12 golden tasks in fixture repos: 4 per track, each with acceptance tests held back from every agent. The bench runs a config (2.10 or 3.0 settings) three times per task, since agent runs vary, and writes one comparison table to `.m2herd/bench/`. Every factory change and every evolve lesson promoted to a template runs the bench first.

**Acceptance for this PRD:** all P0 requirements merged with tests; the bench meets the first two targets and the cost ceiling; one real feature on a client repo has gone through the Standard track end to end.

## Rollout

Ship the alpha today with the parts that need no compiler; the compiler and executable done follow in a week, sandboxing and tracing in weeks 2–3. Dates are proposals; the exit checks are not.

&#91;embedded content: rollout · 3 phases, 2 exit checks (dates proposed)\]

Today, in order:

- [ ] Run `make ci` and tag `v2.10.0` as the fallback
- [ ] Write `docs/factory-v3.md` from this PRD: gates, event additions, compiler mapping, eval validity rule
- [ ] Rewrite SKILL.md §11 as the factory pipeline, update the README stack map, set version 3.0.0-alpha
- [ ] Add `triaged`, `design_review`, `design_ok` to `herd_events.py` with transition tests
- [ ] Implement `m2herd triage` with its rule table and `--track` override
- [ ] Pin EGM in `onboard.sh`, check subagent support, record the ref in `config.toml`
- [ ] Wire G1: EGM review on spec + plan, findings file, approval on the board
- [ ] Add `GOLDFISH.md` and the `blind` arg to the review loop, default off
- [ ] Dogfood: take `m2herd cut` itself through G0–G1 as the first Standard-track feature

## Risks and open questions

The biggest risk is gate fatigue: three human approvals per feature turn into rubber stamps unless each one shows a short, decidable summary.

| Risk | Effect | Mitigation |
| --- | --- | --- |
| Gate fatigue | Human approves G1/G3 without reading; gates become theatre | Board shows one screen per gate: findings left open, evals with their red-on-base proof; approvals batch per herd |
| Ceremony on small work | Lead time grows, people bypass the factory | Triage + Quick track; lead-time metric per track |
| Wrong evals | A misread AC gets frozen and the worker optimizes to it | Test writer is never the worker; red-on-base rule; on High tier a goldfish reviews the evals against the requirement text |
| Reviewer cost | Blind pass + skeptics push cost past the ceiling | Blind-only findings metric decides whether it stays default on |
| Upstream drift | An EGM or spec-kit update changes prompts or file layout | Pinned refs; bench run before any bump; compiler fixtures from real spec-kit output |
| Sandbox friction | Tools missing in containers, slower starts | Containers for headless workers first; pane workers stay on Low tier |

Open questions:

- [ ] Does EGM's drift report read spec-kit's `specs/<feature>/` layout as is, or does it need an index under `docs/designs/`?
- [ ] Can a Hermes orchestrator start subagents EGM accepts, or is the headless `claude -p` route the only one?
- [ ] Blind pass beside the main reviewer, or instead of it once the metric is in?
- [ ] Which model family serves as the goldfish when the author is Fable: Opus, Codex, or a local model?
- [ ] Which 12 tasks form the bench, and from which repos (own projects only, to keep client code out)?
- [ ] Version: ship as 3.0.0 (breaking workflow per the repo's semver rules) or 2.11 with §11 marked experimental?

## References

- [machine-machine/herdr-factory-loop-skill](https://github.com/machine-machine/herdr-factory-loop-skill) — base; read at `main` (SKILL.md 2.10.0, CHANGELOG Unreleased with `eval`/`loop`, `docs/herd-flow-v2.md`, `templates/herd/rules/`)
- [google/elephant-goldfish-model](https://github.com/google/elephant-goldfish-model) — EGM skills: brainstorm, draft, resolve, bootstrap, review, review loop, drift report
- [bmad-code-org/bmad-method](https://github.com/bmad-code-org/bmad-method) — planning paths, role perspectives, brownfield context, BMad Loop
- [github/spec-kit](https://github.com/github/spec-kit) — the spec chain the factory keeps
