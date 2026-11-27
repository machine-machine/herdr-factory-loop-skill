# Factory pipeline 3.0 — spec (build contract for 3.0.0)

This is what 3.0 builds and how its parts fit. `skill/SKILL.md` §11 is the agent-facing summary and
wins on conflict; this file wins over the PRD it was written from ([`docs/prd/factory-v3.md`](prd/factory-v3.md)).
Herd flow v2 ([`docs/herd-flow-v2.md`](herd-flow-v2.md)) stays the execution engine; nothing here
rewrites it. Status per item is a command, never a sentence: `m2herd gate status`, `herd-phase <herd>
--state`, `git log`.

## 1. The pipeline

One column of stages, six gates. A gate records a verdict before work moves on; a failed gate never
advances and loops back to the stage that owns the fix.

    G0 triage ─► spec chain (spec-kit) ─► G1 design review ─► tasks ─► cut ─► G2 cut check
       ─► G3 frozen evals ─► herd (herd flow v2) ─► G4 slice done ─► G5 merge on the human's go
       ─► drift check after merge (P1)

| Gate | Verdict | Who decides | Writes | Since |
|---|---|---|---|---|
| G0 triage | track quick/standard/full + risk tier | rules; the human when UNSURE | `triaged` | 3.0.0-alpha |
| G1 design | EGM findings on spec + plan resolved | the human (`m2herd gate approve <run> G1`) | `design_review`, `design_ok` | 3.0.0-alpha |
| G2 cut check | `HERD-CUT.md` PASS / CONCERNS / FAIL | FAIL blocks; CONCERNS need the human's ack | `HERD-CUT.out.md` (existing) | 2.10.0 |
| G3 evals | one frozen eval per AC, red on the base sha | the human (`m2herd eval approve`) | `evals_frozen` | 3.0.0 |
| G4 slice done | approved evals green at the accepted sha **and** `review_ok` | the review loop | `eval_pass`/`eval_fail`, `review_ok` | review 2.10.0; evals 3.0.0 |
| G5 merge | integration probe passed, `/speckit.analyze` no CRITICAL | the human's verbatim go (`herd-merge`) | `merged` (existing) | 2.10.0 |

Quick runs skip the spec chain, G1, G2 and G3: one slice, gates G4 + G5 only.

## 2. Gate events

A **run** is one intent from triage to merge. Its gate events live in
`.m2herd/factory/<run>/gates.jsonl`, append-only, written only through `herd_events.append_gate`
(flock on `gates.jsonl.lock`) — the CLI is `scripts/m2herd-gate`, reached as `m2herd triage` and
`m2herd gate …`. A gate event carries `gate` + `event` instead of `slice` + `phase`, so the phase
reader (`herd_events.read`) never mistakes one for a slice event.

    {"ts": "...Z", "gate": "G0", "event": "triaged", "by": "orchestrator", "track": "standard",
     "tier": "medium", "sure": true, "reasons": ["2 file areas: api, ui"], "intent": "...",
     "files": [...], "areas": [...], "feature": "specs/007-x", "source": "cli"}
    {"ts": "...Z", "gate": "G1", "event": "design_review", "by": "orchestrator",
     "evidence": "specs/007-x/reviews/g1-2.md", "open": 0, "round": 2}
    {"ts": "...Z", "gate": "G1", "event": "design_ok", "by": "human", "word": "<verbatim>"}

Transitions (from the run's last gate event):

| From | Allowed next |
|---|---|
| nothing | `triaged` |
| `triaged` | `triaged` (re-triage), `design_review` |
| `design_review` | `design_review` (next round), `design_ok`, `triaged` |
| `design_ok` | `design_review` (spec changed), `triaged` |

Extra rules: a quick run has no `design_review` (re-triage to standard first). Re-triage may raise
track and tier, never lower them — except that the human's `--track` pick (`override: true`) may
lower the track of an UNSURE triage, because an unsure triage is theirs to decide. `design_ok` needs `by: human`, the human's words in `word`, and a
last `design_review` with `open: 0`. `--force` needs a note and records `forced_from`, as in
`herd-phase`.

Reserved for 3.0.0 (same file, same rules): `evals_frozen` (G3), `eval_pass` / `eval_fail` (G4,
per slice, with the sha), `drift_found` (after merge). Once a herd exists, slice-level events
(`eval_pass`, `eval_fail`) go to `herd.events.jsonl` with a `slice` like every phase event, and
`herd-phase` refuses `review_ok` without an `eval_pass` at the same sha (FR-13).

## 3. G0 triage — the rule table

`m2herd triage "<intent>" [--files a,b] [--track T] [--tier T] [--id ID] [--feature DIR]
[--source chat] [--dry-run] [--json]`. The default run id is the intent's slug plus a hash of the
whole intent, so a re-triage of the same intent hits the same run and different intents never share
one. An UNSURE run's `gate status` names the human as the next actor. Pure rules, no model, no network: the same intent and file
list always give the same answer. First matching row wins (`scripts/m2herd-gate`, `HIGH_RISK`,
`FULL`, `QUICK`, `LOW_TIER`):

| Row | Fires on | Track | Sure |
|---|---|---|---|
| 1 | a risk word: auth, login, password, OAuth, SSO, permission, credential, secret, token, payment, billing, invoice, checkout, migration, schema change, infrastructure, Terraform, deploy, client/customer data, PII, GDPR, encryption | full | yes |
| 2 | a new-system word: new system, new service, greenfield, client-facing, customer-facing, public API | full | yes |
| 3 | a domain word in the intent — a word on the project's list `.m2herd/rules/domain-words.txt` | full | yes |
| 4 | `--files` spans two or more areas (an area = first path component; first two under `src/`, `lib/`, `app(s)/`, `packages/`, `services/`, `internal/`, `cmd/`, `pkg/`) | standard | yes |
| 5 | a quick word (typo, wording, rename, comment, README, changelog, bump, config, flag, lint, format, one-line, failing test) and one area | quick | yes, or no when `--files` is missing |
| 6 | nothing fired | standard | no — the human picks |

Tier: **high** on any row-1 word; **low** when the words say docs/tests/tooling/CI or every file is
under `docs/`, `tests/`, `spec/`, CI dirs or is a `.md`; else **medium**. `--tier` only raises.
`--track` overrides the track and is recorded as a reason; a high-tier run below the full track is
refused without `--force --note`. `--source chat` marks channel text as untrusted (SEC-4): a
high-tier chat run records `needs_approval` and `gate status` sends it to the STEER inbox first
(advisory in the alpha: no gate refuses the run yet; 3.0.0 adds the approval event).

Domain words (row 3) match the intent only, never `--files` paths: case-insensitive, whole words with a hyphen as a word break, `word*` for any ending, ä/ö/ü/ß equal to ae/oe/ue/ss; `#` starts a comment, the skill ships no list, a missing file means no domain row, and the `triaged` event records the hits as `domain_words`.

## 4. G1 — the design review

Standard and full runs only. The orchestrator runs EGM review on `spec.md` + `plan.md` +
`contracts/` in fresh subagents (full track: plus the product, architecture, UX and QA lenses
through EGM review loop), writes the findings to `specs/<feature>/reviews/g1-<n>.md`, works them
through with EGM resolve, and records `m2herd gate record <run> design_review --evidence <file>
--open <n>`. With `open: 0` it hands the human the findings file and the approval command; the
human's words go in verbatim (`m2herd gate approve <run> G1 --word "…"`). Goldfish reviewers use a
different model family from the spec author when one is configured (`MODELS.md`).

A Hermes, Cursor or pi orchestrator cannot start the subagents EGM needs; G1 then runs inside a
headless `claude -p` worker that has the plugin, and its findings file is collected like a slice
report. `scripts/onboard.sh` records which route applies (`[egm] subagents = native | claude-p`).

## 5. Cut — the compiler (`m2herd cut`, 3.0.0)

`m2herd cut --from specs/<feature>` turns spec-kit output into herd-flow-v2 input. Dry run by
default; `--apply` writes; `--selftest`; fixtures from real spec-kit output under `tests/cut/`.

| spec-kit | herd flow v2 |
|---|---|
| `spec.md` requirement with a stable ID (`FR-001`, `SC-002`) | copied into every slice that covers it; an unnumbered requirement makes the compiler refuse |
| `tasks.md` task marked `[P]` | its own slice, parallel |
| unmarked task that gates a `[P]` wave | `stacked_on` for every slice of that wave |
| tasks of one user story touching one file area | one slice (merged when they would clash) |
| acceptance scenarios of the story | numbered Given/When/Then ACs in `<slice>.task.md` |
| files named in the task | expected files; two live slices on one file → stack or merge (`herd-clash` logic) before any start |
| — | `model`/`effort` from `MODELS.md`, `PLAN.md` with the cut and why, `<slice>.repos` with base |

Workers never edit `tasks.md`; the orchestrator ticks it on the integration branch.

## 6. Risk tiers and the worker runtime

Triage assigns the tier; a slice can raise it, never lower it.

| Tier | Runtime | Extra gates |
|---|---|---|
| low | pane or headless, current permission flags | none |
| medium | headless in a rootless container (podman or bubblewrap), worktree + read-only eval dir mounted, no home dir | blind pass on |
| high | container with an egress allowlist (git remote, registries, model endpoints), no credentials in env | full track, `xhigh` review effort, the human reads the diff before go |

Secrets never enter a worktree's environment; a test that needs one uses a fixture or a broker the
eval calls, not the worker. The containers are P1; until they land, medium and high slices run
with today's flags and the tier only changes the gates.

## 7. Upstreams

| Upstream | Adoption | Pin |
|---|---|---|
| github/spec-kit | the one artifact chain, unchanged | `SPEC_KIT_REF` in `scripts/onboard.sh` (the commit the fleet runs), passed to `uv tool install` / `uvx` |
| google/elephant-goldfish-model (Apache-2.0) | Claude Code plugin `egm@egm`: review, resolve, review loop, drift report; brainstorm and bootstrap on the full track. Not used: draft, its `docs/designs/` layout | `EGM_PIN` in `scripts/onboard.sh`; the plugin CLI cannot install a ref, so onboarding compares the installed `gitCommitSha` with the pin and warns on a mismatch |
| bmad-code-org/bmad-method (MIT) | ideas only, never installed: right-sized tracks, role lenses for G1, verified context for inherited codebases | `NOTICE` |

BMAD stays uninstalled because its skills, next to this skill, spec-kit and EGM, would add a third
set of broad triggers to every turn; no command or file uses its name (trademark).

## 8. The blind pass (G4)

Review loop arg `blind: true` (spec name `HERD_REVIEW_BLIND`) starts a goldfish reviewer beside the
main reviewer for every PR that gets a review. It reads the slice's task (ACs + requirement text),
the pinned diff and the repo — never the worker's report, the reviewer context, earlier findings,
the PR text or chat. Its findings carry `source: blind` and go through the same two skeptics.
Rules: `templates/herd/rules/GOLDFISH.md`; arg details: `templates/herd/workflows/README.md`.
3.0.0-alpha ships it **off**; 3.0.0 turns it on, and the blind-only-findings metric decides
whether it stays on.

## 9. Eval validity (G3, 3.0.0)

An eval counts only when (1) it was drafted by a test-writer agent that is not the slice's worker
(`templates/herd/rules/TEST-WRITER.md`), (2) it fails on the base sha and the failure is recorded,
(3) the human approved it — the existing `m2herd eval approve` checksum freeze (§18), mounted
read-only for the worker. An AC that cannot be automated is `manual:` with a named checker; a slice
whose ACs are all manual cannot run on the quick track. Score-type evals route through `m2herd
loop` (P2).

## 10. Where 3.0.0-alpha differs from the PRD

- **No "Needs you" lane.** The PRD puts G1/G3 approvals and G2 CONCERNS in a herd-board "Needs you"
  lane. That lane was removed in 2.10 on the operator's request (the merge word lives in the
  Ready-to-merge row, herd-flow-v2 §3). Gates follow the same rule: a gate waiting on the human is
  shown where its work waits, with the exact approval command. In the alpha that place is
  `m2herd gate status`; the board rows come with 3.0.0.
- **Gate log location.** The PRD writes pre-herd gates to `specs/<feature>/gates.jsonl`. Triage
  happens before spec-kit creates the feature dir, and a quick run never gets one, so the log lives
  per run under `.m2herd/factory/<run>/` and the events carry `feature` once it exists.
- **No `factory` block in `.m2herd/settings.json` yet.** The settings editor in `m2herd-tui`
  rewrites the file from its own struct and would drop an unknown block; the block lands together
  with the TUI change (and a rebuilt `prebuilt/`). Until then: `--track`, `--tier` and the review
  loop's `blind` arg.
- **The herd view is "Herd".** Worker TUIs go to the tab `herd` (was `herde`); a tab still labelled
  `herde` is recognised until it closes, unless `HERD_SPAWN_TAB` names another label.

## 11. Tests

`tests/gates/test_gates.py` (transitions, rule table, CLI, the `m2herd` wrapper) runs in
`make test-herd`. Still to come with their features: `tests/cut/` (compiler fixtures from real
spec-kit output), `tests/bench/` (golden tasks for `m2herd bench`, 12 tasks, three runs each).
