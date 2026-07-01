# Changelog

All notable changes to this skill are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
adheres to [Semantic Versioning](https://semver.org/).

## [2.1.0] - 2026-07-02

### Added
- **`m2herd dashboard --watch [--interval N]`** — built-in flicker-free repaint loop (alt-screen,
  hidden cursor, home-cursor redraw instead of `clear` — no more blinking) with tput colors kept
  in watch mode; the machineroom pane now runs this instead of a shell `clear` loop.
- **`m2herd self-update [--check]`** — `--check` fetches the engine repo and caches the
  behind-count in `~/.cache/m2herd/update-status` (the watch loop refreshes it every 10 min);
  the dashboard header renders "N commit(s) behind — run: m2herd self-update" while fresh (<24h).
  Plain `self-update` ff-only-pulls the engine repo, refusing a dirty tree.
- **Dashboard colors + human dates** — cyan branding, magenta `NEXT:` prefix, green/yellow/red
  state words painted AFTER column alignment (padding stays correct), dimmed labels/footer, and
  NOTES timestamps rendered local + human-short (`14:32` today, `Jul 1 14:32` otherwise).

### Changed
- **Notes pane → machineroom.** The m2herd-up tab label is now `machineroom` (old
  `m2herd-notes` label still detected for idempotence).

## [2.0.0] - 2026-07-02

m2herd: the Fable main-orchestrator context fabric. **Claude Code (Fable) is the MAIN
orchestrator**; every repo it orchestrates carries a gitignored `.m2herd/` at the repo root —
the Claude-Code-native superset of the §12/§15 herd-control concepts. Doctrine: **the folder
holds the context, the orchestrator holds pointers**, and the fabric is an **agentic loop —
the machine prompts itself from its own state**. Pillars: the *living harness loop* (the hooks
are the heartbeat, `m2herd next` is the pulse they inject; drift is an error — `sync --check`
exits 3), the *intent coach* (a fuzzy goal is not dispatchable: sharpen it into `goal` +
`done_when` + slices, record `open_questions` instead of guessing), *self-documentation*
(every refile IS the documentation act; nothing lives only in the live window), *memory tiers*
(`.m2herd/` = project working memory, AMS = fleet recall, `~/.claude` = the orchestrator's own
lessons; `gist --push` is the bridge), and *decay discipline* (`archive --area`; living ≠
hoarding). Built as a 4-slice herd against the pre-committed `CONTRACT-m2herd.md` (v1.2).

### Added
- **`scripts/m2herd.sh`** (slice A — the engine) — mechanical, idempotent bash over `.m2herd/`:
  `init` (scaffold from `templates/m2herd/`, gitignore it), `status`, `note` (timestamped append
  to NOTES.md), `refile --area A` (move loose notes below the marker into `context/A/` + update
  `overview.json`), `resume` (RESUME.md + one line per area), `sync` (regenerate `areas[]` from
  the `context/` tree; refresh the RESUME.md skeleton preserving hand-written notes) /
  `sync --check` (drift report, exit 3), `archive --area A` (distill a done area to header +
  ≤10 summary lines, `status: archived`; `deep/` stays lossless), `gist [--push]` (one-paragraph
  project gist; `--push` pipes to `$M2HERD_GIST_CMD`), `next` (the self-prompting primitive: a
  mechanical 7-case priority walk — drift → drain steering (`.m2herd/inbox/STEER.md` content
  below the marker) → uncoached intent → loose notes → collectable worker → first open question →
  compare RESUME vs goal/done_when — printing exactly one `NEXT: ` line, no LLM calls),
  `dashboard` (read-only tier-1 TUI — a pure renderer over existing state, no writes ever: boxed
  header `m2herd · <repo> ── ● <status> · drift ✓|◐`, goal/done_when/budget rows (budget from the
  newest `/tmp/claude-ctx-*.json` bridge file; omitted when none), the `NEXT:` line from the same
  code path as `next`, AREAS and WORKERS side-by-side on a ≥100-col tty (stacked otherwise) with
  staleness ages that make rot visible and a desired-vs-observed workers column — one
  `herdr agent list` read per render, mismatches marked `!`, silent degrade without herdr; herdr
  reads allowed in a watcher pane, herdr mutations forbidden — OPEN QUESTIONS, NOTES tail, and a
  `read-only · steering: .m2herd/inbox/STEER.md` footer; tput colors on a tty, plain when piped;
  one writer, many watchers — future tiers may add fswatch repaint (2) or bubbletea/textual
  navigation (3), never editing; TUI keys' only write is an APPEND below the STEER.md marker,
  drained by the orchestrator via `next`), and `selftest` (tmpdir end-to-end with jq schema
  assertions, incl. `next` cases and a dashboard smoke). `init` also scaffolds
  `.m2herd/inbox/STEER.md` (boilerplate + marker).
  `overview.json` gains optional `done_when` (seeded empty by `init --goal` = "intent not yet
  coached") and `open_questions[]`. `templates/m2herd/` ships the
  `overview.json`/`RESUME.md`/`NOTES.md` seeds with a `<!-- marker -->` line separating
  boilerplate from live content.
- **The three Claude Code hooks** (slice B — the heartbeat), all keyed on `.m2herd/` presence,
  silent-fail, never blocking: `hooks/m2herd-session.sh` (SessionStart: inject a digest —
  overview.json goal/status/areas count + first 30 lines of RESUME.md — plus the output of
  `m2herd next`, so every wake-up = orientation + the next move), `hooks/m2herd-precompact.sh`
  (PreCompact: instruct the model to refresh RESUME.md/overview.json and refile loose NOTES.md
  content into `context/<area>/` BEFORE compaction proceeds), `hooks/m2herd-budget.js`
  (PostToolUse: the 60/75/85% bridge-file budget watcher adapted from `herdr-context-budget.js`,
  advising offload into `.m2herd/context/<area>/` + RESUME.md refresh; envelope always
  `PostToolUse`).
- **`scripts/m2herd-up.sh`** (slice C — the workspace): `up` ensures the fixed workspace shape —
  EXACTLY ONE orchestrator pane (claude) + ONE watcher pane running `watch -n 2 -t "m2herd
  dashboard"` when `m2herd` and `watch` exist (NOTES.md viewer fallback chain otherwise; the
  pane watches, never writes) — and runs `m2herd.sh init` if missing; `dispatch --slice S` worktrees
  `wip/m2herd-<S>`, spawns a worker (claude/codex/cursor), file-protocol-dispatches
  `.m2herd/dispatch/S.task.md`, and records it in `overview.json workers[]`; `collect --slice S`
  waits idle and lands the report in `dispatch/S.out.md`; `--dry-run` prints every herdr/git
  command instead of running it.
- **Docs + wiring** (slice D): `skill/SKILL.md` §16 (doctrine, layout, engine, workspace shape,
  hooks, install) + cheat-sheet row + m2herd trigger phrases in the frontmatter; README
  capability row 16 + repository-layout entries; `scripts/install.sh` registers the three m2herd
  hooks for the **claude** target (`SessionStart`/`PreCompact`/`PostToolUse`, the `.js` with
  matcher `Bash|Edit|Write|MultiEdit|Agent|Task`, all timeout 10) — dedupe AND uninstall keyed on
  hook FILENAME, timestamped `.bak` before edits, `--no-m2herd-hooks` to skip, warn+skip the `.js`
  when `node` is missing — and symlinks `scripts/m2herd.sh` → `~/.local/bin/m2herd` and
  `scripts/m2herd-up.sh` → `~/.local/bin/m2herd-up` (idempotent; `--uninstall` removes) so any
  repo can run the engine and the hooks can find it; `scripts/onboard.sh` step 3 notes the m2herd
  hooks + PATH symlinks ship with the claude install.

Major bump: the default claude install now registers three new hooks (SessionStart, PreCompact,
PostToolUse) and adds two PATH symlinks — a behavior change to `install.sh`'s defaults.

## [1.9.0] - 2026-07-02

### Fixed (merge review)
- `herdr-context-budget.js` no longer flips its envelope to `AfterTool` when `GEMINI_API_KEY`
  happens to be exported — always `PostToolUse`.
- `herd-loop.sh rotate` records the new orchestrator pane in `_fleet/orchestrator` (and
  `run --auto-rotate` drops its stale `--orchestrator` override), so a second rotation retires
  the right pane instead of a renumbered stranger; digest deep-dive links now resolve from
  `_fleet/` (`../stages/<stage>/output/<slice>.out`).
- `herdr-context-session.sh` reads stdin with a real timeout (the old `$(cat)` blocked forever
  if the host never closed stdin); its settings entry now carries `timeout: 10` too.
- `install-hermes-context.sh` keys idempotence/uninstall on the hook filename, not the full
  command with the absolute node path (nvm upgrades re-appended duplicates), and uninstall
  strips only our command from a matcher group instead of deleting the whole group.

Dynamic compression: keep summaries in the live window, deep-dives in files. Builds on the v1.8.0
budget layer with a strict division of labor — Hermes compresses the live window lossily, the folder
holds the lossless deep-dives, and a rolling digest + session-rotation bridge the two.

### Added
- **`context-budget.sh summarize` + `compact`** — `summarize --ws WS --stage S --slice X` distills one
  worker's `output/<slice>.out` to a ≤6-line summary (its final "what I did / how I verified" report if
  present, else a head+tail heuristic — never a full-body copy; `--llm "CMD"` pipes the `.out` through
  CMD instead). `compact --ws WS` regenerates `_fleet/context_pointer.md` as a rolling narrative — active
  stage + the digest + slice `context.md` links, links only.
- **Rolling `_fleet/digest.md`** — `herd-loop.sh collect_slice` now summarizes each finished worker's
  result and appends `## <slice>` + the summary + a link to `output/<slice>.out` (append-once per slice,
  idempotent). The digest is the summary; the full `.out` remains the on-disk deep-dive.
- **Session-rotation on CRITICAL** — the `herdr-context-budget.js` hook drops a `_fleet/.needs_rotation`
  sentinel when usage crosses **CRITICAL 85%** (once per crossing); `herd-loop.sh run` detects it and
  emits `STATUS: NEEDS_ROTATION` instead of looping on a saturated window. New `herd-loop.sh rotate --ws WS`
  starts a fresh orchestrator that boots from `_fleet/context_pointer.md` + `digest.md` (via the
  SessionStart hook), retires the old pane, and clears the sentinel — enforced reorg by restart. Refuses
  to close `$SELF`, the new pane, or an empty/unknown pane id; `--dry-run` prints the plan and spawns/closes
  nothing. Opt-in **`herd-loop.sh run --auto-rotate [--orchestrator PANE] [--max-rotations 5]`** rotates
  automatically on `NEEDS_ROTATION` and keeps ticking (capped; a refused rotate is contained so it can't
  crash the loop).
- **Hermes-compressor wiring** — `install-hermes-context.sh --compression on|off` tunes (or disables) the
  `~/.hermes/config.yaml` `compression:` block (`enabled`, `threshold` 0.5, `target_ratio` 0.2,
  `protect_first_n`/`protect_last_n`) to budget-aligned values. Backs up config, touches only those keys,
  idempotent, `--dry-run` diffs. Documents the lossy-live / lossless-folder contract.
- **`skill/SKILL.md` §15.5 (Dynamic compression)** — the division of labor (Hermes compresses the live
  window lossily; the folder holds lossless deep-dives; the rolling `_fleet/digest.md` stores per-slice
  summaries while the full `.out` is the deep-dive; session-rotation on CRITICAL reboots the orchestrator
  from the pointer/digest), plus the `summarize`/`compact` and `--compression` wiring.
- **`templates/herd-control/_config/budget_policy.md`** — compression tiers (Hermes compresses at 50%;
  our hook advises at 60/75/85% and signals rotation at CRITICAL), the digest/deep-dive convention, and
  the `_fleet/.needs_rotation` rotation signal file.

## [1.8.0] - 2026-07-02

Context budgeting: keep the orchestrator inside a token budget — the folder holds the context,
the orchestrator holds pointers.

### Added
- **`scripts/context-budget.sh`** — the decomposer/budget engine (`detect`/`status`/`plan`/
  `pointer`). `detect` resolves `MODEL`/`BUDGET` in order (`herd.conf` → `~/.hermes/config.yaml`
  `model.context_length` → default **GLM-5.2 / 384000**) and prints `SOURCE=`. `status` reads the
  live bridge file (`/tmp/claude-ctx-<session>.json`) for usage vs budget. `plan` splits an intent
  into slices and writes a per-slice context manifest at `stages/<stage>/context/<slice>.md` — file
  **links only**, with a byte/token-estimate header, each sized to fit a budget fraction (default
  `BUDGET × 0.25`); oversized slices are flagged (`fits: NO`), not silently emitted. `pointer`
  regenerates one slice's manifest after a RESCOPE/edit.
- **`hooks/herdr-context-budget.js`** — a Hermes **PostToolUse** hook (awareness + restructure on
  demand). Reads the bridge file + `BUDGET`; on **WARNING 60% / HIGH 75% / CRITICAL 85%** (debounced;
  severity escalation bypasses the debounce) it injects an offload advisory, and on HIGH/CRITICAL
  spills a compact `_fleet/context_pointer.md` (active stage, ledger digest, links to each slice's
  distilled `context.md`) so the orchestrator can drop raw history and reload from the pointer.
  Idempotent spill, silent-fail, `session_id` path-traversal guard, never blocks a tool.
- **`hooks/herdr-context-session.sh`** — a **SessionStart** hook that surfaces `MODEL`/`BUDGET` and
  any existing `_fleet/context_pointer.md`, so a resumed orchestrator starts inside its budget.
- **`scripts/install-hermes-context.sh`** — self-installer for `~/.hermes/`: copies the hooks,
  `jq`-merges their PostToolUse/SessionStart declarations into `settings.json` (keyed by command
  string → idempotent), sets the GLM-5.2/384k default in `config.yaml`, and verifies with
  `hermes hooks doctor`. Backs up config before editing; `--dry-run` / `--uninstall` supported.
  Onboarding (§11.0) and `install.sh --hermes` run it automatically for the Hermes orchestrator.
- **`templates/herd-control/_config/budget_policy.md`** — L3 reference for the thresholds and the
  offload doctrine; budget awareness added as a global `AGENT.md` constraint. `herd-loop.sh` `init`
  writes `MODEL`/`BUDGET` (with `--model`/`--budget` overrides) and `gen_prompt` points each worker
  at its slice `context.md` instead of hard-coding a file list.
- **`skill/SKILL.md` §15 (Context budgeting & the decomposer)** — the budget setting and resolution
  order, the `context-budget.sh` decomposer and its budget-sized slice manifests, the two Hermes
  hooks and the offload doctrine, and the self-installer + onboarding wiring.

## [1.7.0] - 2026-07-01

Default-on dispatch nudge: hooks for Claude Code and Hermes that re-check "should this herd?"
every turn, so the fleet gets considered without the user having to say "herdr" first — the
model still proposes a plan and gets explicit confirmation before anything is spawned.

### Added
- **`hooks/herdr-dispatch-nudge.sh`** — a single script wired into Claude Code's
  `UserPromptSubmit` hook and Hermes's `pre_llm_call` shell hook (its documented
  `UserPromptSubmit` equivalent). Fires every turn, discards its input, and always returns the
  same short reminder to check §9/§11/§13 applicability and get confirmation before spawning —
  it never parses the prompt or decides anything itself; that judgment stays with the model.
- **`skill/SKILL.md` §14 (Default-on dispatch nudge)** — documents the hook, why it can't embed
  the decomposability judgment itself, the install/uninstall flow, and the Hermes non-interactive
  consent gotcha (`--accept-hooks` / `HERMES_ACCEPT_HOOKS=1` / `hooks_auto_accept: true`), which
  matters most for exactly the channel-driven case §9 is built for.
- **`scripts/install.sh`** — installs and idempotently registers the hook by default for
  `claude`/`hermes` targets (`--no-nudge-hook` to skip; `--uninstall` cleanly removes the
  registration and symlink). Requires `jq` (Claude) / `yq` v4 (Hermes) for registration; degrades
  to "hook file installed, not wired up" with a warning if either is missing. Takes a
  timestamped `.bak-<ts>` copy of `settings.json`/`config.yaml` before every edit. Cursor is
  skipped (no shell-hook mechanism).
- **`scripts/onboard.sh`** — step 3 now notes that the nudge hook is part of the default install.

## [1.6.1] - 2026-06-19

### Fixed
- **Dispatch race — prompt typed but never submitted.** `submit_prompt` (herd-loop.sh) and
  the orchestrator dispatch sites (fleet-loop.sh) fired `agent send` and `pane send-keys Enter`
  back-to-back. A TUI (claude/codex) needs a beat to render injected text into its input box;
  the Enter raced the text, submitted an empty line, and left the prompt sitting in the input
  unsubmitted. Now settle between the text and the Enter (`SUBMIT_SETTLE`, default 1s) — and in
  fleet-loop.sh the three paired sites are unified behind a single `submit_pane` helper.
- Docs (SKILL.md, reference.md): the dispatch examples, the `send ≠ submit` gotcha, and the
  cheat-sheet now teach the settle-before-Enter step.

## [1.6.0] - 2026-06-19

Meta-orchestration: the orchestrator of orchestrators. A tier above §12 — launch and oversee
orchestrators (each driving its own herd of workers), with `/goal` as the autonomy hook.

### Added
- **`templates/fleet-control/`** — an ICM workspace for the **meta-orchestrator** (tier 0),
  mirroring `herd-control/` one level up: `FLEET.md` (L0 meta identity), `ROUTER.md` (L1),
  `missions.tsv` (the desired orchestrator set — `mission  orchestrator  repo  intent  done_when`),
  `goals/<mission>.md` (each orchestrator's generated charter+goal), two stages
  `01_dispatch` (**fanout**: one orchestrator per mission) and `02_converge` (**solo**:
  cross-mission integration + meta run report), `_config/` (launch / approval / gate policies +
  `goal_support.txt`), `shared/` (architecture, the `/goal` hook), `_fleet/` (observed),
  `inbox/STEER.md` (live steering).
- **`scripts/fleet-loop.sh`** — the meta reconciler. Same folder=desired / socket=observed loop
  as `herd-loop.sh`, but its "workers" are **orchestrators** and its "slices" are **missions**.
  Each `tick`: observe fleet → drain steering → launch an orchestrator per missing mission (in its
  repo, scaffold its herd-control workspace, **arm its `/goal`** to the mission's `done_when`) →
  refresh status from the orchestrator pane **and** its `herd-control/_fleet/active_stage == DONE`
  → auto-approve routine blocks or escalate → collect → gate. Mechanical work only; escalates
  judgment via a `STATUS:` line (`AWAITING_SOLO`/`RECONCILED`/`NEEDS_REVIEW`/`MISSION_COMPLETE`/
  `ADVANCED`/`DONE`). `run` is the standing loop; `inbox/STEER.md` steers it over **missions**.
- **`/goal` autonomy hook** — `fleet-loop.sh` arms each orchestrator's `/goal <done_when>` (a
  session Stop hook) so it self-drives its herd; the meta only re-engages on `blocked`/`done`.
  Per-agent capability matrix (claude/codex ✅, cursor ❌ → re-nudge) in `shared/goal_support.md`
  + overridable via `_config/goal_support.txt`. Hooks all the way down: meta-goal →
  orchestrator-goals → workers.
- **`skill/SKILL.md` §13 (Meta-orchestration)** — the three-tier model, when to use it (a
  portfolio of ≥2 independent missions), the `/goal` hook propagation, the workspace + loop, and
  the discipline rules (no tier reaches two levels down; completion is a disk signal;
  cross-mission merges / prod-deploys escalate to the human).

## [1.5.0] - 2026-06-17

ICM-steered orchestration: the folder is the orchestrator, herdr is the body.

### Added
- **`templates/herd-control/`** — a filesystem-native control workspace built on the
  Interpretable Context Methodology (ICM, arXiv:2603.16021). Layered context
  (`AGENT.md` identity / `ROUTER.md` routing / per-stage `CONTEXT.md` contracts with
  Inputs·Process·Outputs·Verify / `_config`+`shared` reference / `_fleet`+`output`
  working artifacts) and six numbered stages (spec→plan→tasks→implement→analyze→converge).
  The implement stage is **fanout** (workers per `slices.tsv`); the rest are **solo**.
- **`scripts/herd-loop.sh`** — the reconciliation loop. Treats the folder as *desired*
  state and the herdr socket as *observed* state: `observe` snapshots the fleet to
  `_fleet/`, `tick` spawns missing workers (codex/claude/cursor in worktrees), collects
  finished ones, auto-approves routine blocks or escalates the rest (`_config/approve_*.txt`),
  and gates stage advancement. Does the mechanical work; escalates judgment via a `STATUS:`
  line. `run` is the standing loop; `inbox/STEER.md` is the live steering channel
  (PAUSE/RESUME/KILL/RESCOPE/GOTO/NOTE). Fleet observation + dispatch ledger are written to
  disk every tick, keeping the orchestrator state reconstructible from the folder alone.

## [1.4.0] - 2026-06-15

Cursor joins the loop as a first-class orchestrator **and** worker.

### Added
- **Cursor as an orchestrator.** `scripts/onboard.sh` now offers
  `cursor` alongside `claude` and `hermes` (the old `both` choice is
  renamed `all` and still accepted as a legacy alias). Cursor is
  spec-kit-native, so onboarding wires `specify init --here --integration
  cursor` (prompts land in `.cursor/commands/`) and verifies the
  `cursor-agent` CLI in the substrate checks.
- **Cursor as a worker.** `scripts/install.sh` gained `--cursor`
  (symlinks the skill into `~/.cursor/skills/herdr`) and now installs for
  all three agents by default. SKILL.md §9.1 documents the worker
  binary+flag table — cursor workers spawn via
  `herdr agent start cursor -- "$(command -v cursor-agent)" --force`, the
  Cursor analog of `--dangerously-skip-permissions`. §9.2/§11.2 dispatch
  blocks note how to swap codex for a cursor worker.

## [1.3.0] - 2026-06-11

The factory loop becomes spec-driven: spec-kit in front, herdr behind.

### Added
- **scripts/onboard.sh** — onboarding TUI (gum-aware, plain-bash
  fallback). Choose the orchestrator (**Claude Code**, **Hermes**, or
  both), verify the substrate (herdr server, jq, git), install the skill
  for the chosen agent, install spec-kit's `specify` CLI via
  `uv tool install`, run `specify init` in a target repo, and record the
  setup in `~/.config/herdr-factory/config.toml`. Non-interactive mode:
  `--orchestrator <x> --repo <path> --yes`.
  - Detects spec-kit's `--integration` vs legacy `--ai` flag.
  - Hermes is wired via spec-kit's generic integration
    (`--integration generic --integration-options="--commands-dir
    .hermes/commands/"`); Claude via the native claude integration.
- **Section 11: SDD factory loop — spec-kit × herdr**
  - 11.0 Onboarding and orchestrator/integration mapping.
  - 11.1 Stage-by-stage loop table (constitution → specify → clarify →
    plan → tasks → implement → analyze → converge → compound) with the
    gate each stage must pass.
  - 11.2 Dispatch `tasks.md` to the herd — `[P]` tasks become parallel
    workers in their own worktrees; `tasks.md` replaces the ad-hoc
    `/tmp/herd-plan.md`; workers never edit `tasks.md`; `/speckit.analyze`
    runs before the §9.5 review wave; converge verifies against
    `spec.md` acceptance criteria.
  - 11.3 SDD gates: no spec → no herd; `tasks.md` is the only source of
    slices; `[NEEDS CLARIFICATION]` blocks planning; CRITICAL analyze
    findings block the merge; compound grades `[P]` prediction quality.
  - 11.4 When NOT to SDD.
- Quick reference table — rows for onboarding, the SDD loop, and
  orchestrator lookup.
- Frontmatter description — SDD/spec-kit/factory-loop trigger conditions.
- README — onboarding section, repo-layout and workflow-table updates.
- **§4 file protocol** for long prompts and reliable deliverables: prompt
  file → one-line pointer → `wait output --match <sentinel>` → read the
  answer file. `pane read` is for monitoring, the file protocol is for
  deliverables. (Lesson promoted from the ask-fable skill dry runs, per
  §10.3.)
- Gotchas: `agent start` argv[0] must be the binary; result shape is
  `.result.agent.pane_id`; first run in a new cwd can block on the
  folder-trust prompt.

### Fixed
- **All `agent start` examples were broken** — they passed flags alone
  after `--` (e.g. `-- --dangerously-skip-permissions`), which fails with
  "No viable candidates found in PATH". herdr requires the binary as
  argv[0]: `-- "$(command -v claude)" --dangerously-skip-permissions`.
  Verified against herdr 0.6.9 on 2026-06-11. Affected §3, §7, §9.2,
  §9.5, §11.2, and the quick-reference spawn row.
- Pane-id extraction in examples corrected from `.result.pane_id` to
  `.result.agent.pane_id`.

## [1.2.0] - 2026-06-11

Compound-engineering pass, inspired by
[Every's Compound Engineering guide](https://every.to/guides/compound-engineering):
each orchestration run should make the next one easier, not just ship
its own deliverable.

### Added
- **Section 10: Compound — make the next herd cheaper than this one**
  - 10.1 Write a run report per herd (`~/.herdr/runs/<date>-<slug>.md`)
    with splits, reusable prompts, blockers, timings, and a single
    `next time` line.
  - 10.2 Store the gist where the fleet can find it (shared memory
    system if available, `~/.herdr/runs/` otherwise).
  - 10.3 Promote recurring lessons into this skill via PR — a lesson
    merged here is learned once, by every future agent.
- **§9.5 review stage** — spawn parallel reviewer agents (one lens
  each: correctness / security / conventions) on the integration branch
  before posting the summary; fix P1 findings first, carry P2/P3 as
  known issues. New step 6 points converge at §10.
- **§9.1 steps 7–8** — write the herd plan to `/tmp/herd-plan.md`
  before spawning (plans are the source of truth; prompts, summary, and
  run report all derive from it; ack on the channel for risky herds),
  and check `~/.herdr/runs/` / fleet memory for prior art before
  decomposing from scratch.
- Quick reference table — rows for review-before-report and
  compound-a-run; channel-intent row updated with plan + review steps.

## [1.1.0] - 2026-06-11

### Added
- **Section 9: Channel-driven intent → spin up a herdr "herd"** —
  a complete workflow for when an intent arrives over a chat channel
  (Mattermost, Discord, Slack, etc.) and the right response is a parallel
  herd of codex (or mixed) workers.
  - 9.1 Understand the intent first (re-read, identify deliverable,
    ask one focused clarifying question if ambiguous, decompose into
    independent slices, pick base ref, pick worker type)
  - 9.2 Spawn the herd (one worktree per worker, all in parallel,
    `--no-focus` on every worker, tight scoped prompt per worker)
  - 9.3 Monitor the herd (event-driven via `events.subscribe` OR
    per-worker polling loop)
  - 9.4 Unblock workers (auto-approve routine stuff, escalate
    destructive prompts back to the channel)
  - 9.5 Converge (merge wip branches into an integration branch,
    run tests, post summary, optional teardown)
  - 9.6 Channel-style checklist to paste into the channel after launch
  - 9.7 Explicit "when NOT to herd" guardrails
- Quick reference table — new row for the channel-intent → herd flow.
- Frontmatter description — extended trigger conditions to include
  channel-driven intents.

## [1.0.0] - 2026-06-11

### Added
- Initial import of the herdr skill from local Claude skills directory
  (`~/.claude/skills/herdr/SKILL.md`, v0.6.9 of herdr / protocol 13).
- Workflows 1-8: discover the fleet, know thyself, spawn an agent,
  dispatch work, monitor & wait, unblock a stuck agent, fan-out →
  converge, notify the human.
- Full CLI & socket reference (reference.md) covering environment
  variables, server/sessions/workspaces/tabs/worktrees/panes/agents
  methods, integration management, notifications, socket payload
  examples, agent detection internals, and config keys.
- Quick reference table at the bottom of SKILL.md.
- This repo: README, CHANGELOG, LICENSE (MIT), CONTRIBUTING, install
  script, lint script.

[1.3.0]: #130---2026-06-11
[1.2.0]: #120---2026-06-11
[1.1.0]: #110---2026-06-11
[1.0.0]: #100---2026-06-11
