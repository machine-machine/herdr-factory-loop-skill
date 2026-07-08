# herdr-factory-loop-skill

Orchestrate a fleet of AI coding agents through **herdr** — the terminal
workspace manager (workspaces → tabs → panes) running on this machine.
Spawn agents, dispatch work, watch lifecycle state (idle/working/blocked),
unblock approval prompts, fan out and converge multi-agent work, and
manage agent integrations.

> Triggered when the user mentions herdr, the fleet, "spawn an agent",
> "what are my agents doing", panes/workspaces/worktrees, herdr
> integrations, or wants an agent to drive other coding agents
> (claude/codex/cursor/opencode/etc.) running in herdr.
>
> Also triggered when an intent arrives over a chat channel
> (Mattermost, Discord, Slack, etc.) and the right response is to
> spin up a parallel **herd** of codex (or mixed) workers to achieve
> the goal — understand the intent first, then fan out concurrent
> workers, converge results, and report back on the same channel.

## Quick start

**Install** — one copy-paste command, from anywhere (symlinks the skill + hooks,
puts `m2herd` / `m2herd-up` / `m2herd-tui` on PATH):

```bash
curl -sSL https://raw.githubusercontent.com/machine-machine/herdr-factory-loop-skill/main/scripts/install.sh | bash
```

**Upgrade** — the exact same command; safe to re-run anytime (ff-only pull of the
existing clone, re-links everything):

```bash
curl -sSL https://raw.githubusercontent.com/machine-machine/herdr-factory-loop-skill/main/scripts/install.sh | bash
```

Or, once installed, upgrade the engine directly:

```bash
m2herd self-update            # pull latest (refuses a dirty tree)
m2herd self-update --check    # only report how far behind you are
```

**Install from a git checkout** (development / air-gapped):

```bash
git clone https://github.com/machine-machine/herdr-factory-loop-skill.git
cd herdr-factory-loop-skill
./scripts/install.sh          # auto-detects the checkout and installs from it
```

Then set up the whole factory (orchestrator choice + spec-kit + SDD loop) —
the installer keeps its clone at `~/.cache/herdr-factory-loop-skill`:

```bash
bash ~/.cache/herdr-factory-loop-skill/scripts/onboard.sh   # or ./scripts/onboard.sh in a checkout
```

## Typical command flow

The m2herd context fabric (per-repo, Claude Code as main orchestrator):

```
m2herd boot                      # one-command start: init .m2herd/ (warns + recommends `git init` if the folder is not a git repo), sync, resume
m2herd note "…"                  # jot a thought into NOTES.md
m2herd refile --area A           # move live notes into context/A/
m2herd resume | status | next    # where are we / what now
m2herd config list|get|set       # .m2herd/settings.json — who does the work (agents/runners/routing)
m2herd dashboard --watch         # live TUI over the fabric (`,` opens the settings editor)
m2herd evolve analyze|proposals|show|apply|reject   # turn failed runs into accepted factory lessons
```

`m2herd boot` is the recommended entry point (init + sync + resume in one
command); the older `m2herd init` still exists for finer-grained control.

The worker loop (herdr workspace):

```
m2herd-up up                     # orchestrator pane + machineroom pane in herdr
m2herd-up dispatch --slice S     # worktree + worker + file-protocol task handoff
m2herd-up dispatch --slice S --headless   # cheap non-TUI worker (claude -p / codex exec)
m2herd-up collect --slice S      # wait, harvest report, update overview.json
m2herd-up down --slice S|--all   # tear down pane + worktree (+merged branch); retry = down, then dispatch again
```

## What is herdr?

herdr is a local CLI + headless server talking over a Unix-domain socket.
You orchestrate the fleet through the `herdr` CLI (which wraps the socket
API) or by speaking JSON to the socket directly. It is the host machine's
shared substrate for running more than one coding agent at a time, in
isolated worktrees, under a single visible window.

This skill teaches an agent how to:

| # | Workflow | When to use it |
|---|----------|----------------|
| 1 | Discover the fleet | "what's running?", "where is agent X?" |
| 2 | Know thyself (CRITICAL) | Before any send/run/close — avoid corrupting your own pane |
| 3 | Spawn an agent | Bring a new claude/codex/cursor/etc. online |
| 4 | Dispatch work | Send a prompt to an agent and submit it |
| 5 | Monitor & wait | Block until an agent reaches a target state |
| 6 | Unblock a stuck agent | Resolve approval/permission prompts |
| 7 | Fan-out → converge | Classic multi-agent parallel pattern |
| 8 | Notify the human | Local desktop notifications |
| 9 | Channel-driven intent → herd | Intent arrives on a chat channel, spin up a parallel herd |
| 10 | Compound the run | Review before reporting, write a run report, promote recurring lessons into this skill |
| 11 | SDD factory loop (spec-kit × herdr) | Spec-driven development: spec → plan → tasks → herd implements `[P]` tasks → analyze → converge against the spec |
| 12 | ICM-steered loop (`herd-loop.sh`) | Make one orchestrator a standing, disk-reconstructible reconciler over a `herd-control/` workspace (folder=desired, socket=observed) |
| 13 | Meta-orchestration (`fleet-loop.sh`) | Be the orchestrator of orchestrators: launch + oversee one orchestrator per mission (each driving its own herd), `/goal`-armed to self-drive — `fleet-control/` |
| 14 | Dispatch nudge (hooks) | Claude Code `UserPromptSubmit` + Hermes `pre_llm_call` hooks that re-check "should this herd?" every turn, by default — proposes a plan, never auto-spawns |
| 15 | Context budgeting & decomposer (Hermes) | keep the orchestrator within a token budget (default GLM-5.2/384k); decompose into budget-sized slice manifests; hooks offload context on demand |
| 16 | m2herd — the Fable main-orchestrator context fabric | Claude Code (Fable) as the MAIN orchestrator: a per-repo, gitignored `.m2herd/` holds the context while the orchestrator holds pointers — note/refile/resume/sync/archive/gist via `m2herd`, a 1-orchestrator + 1-machineroom-pane workspace via `m2herd-up`, three Claude Code hooks as the heartbeat |
| 17 | evolve — the factory learns | Run trace bundles (`.m2herd/runs/`) + `m2herd evolve` (analyze/proposals/show/apply/reject): failed runs become reviewable proposals, accepted lessons land in `LESSONS.md` and auto-annotate every later dispatch |

See [`skill/SKILL.md`](./skill/SKILL.md) for the full reference and
[`skill/reference.md`](./skill/reference.md) for verbatim CLI/socket docs.

## Which stack? (stack map)

Four generations of orchestration live in this repo side by side. Pick by orchestrator:

- **Start here — §16 m2herd** (+ §17 evolve): Claude Code (Fable) is the main orchestrator;
  `.m2herd/` context fabric, `m2herd`/`m2herd-up`, the three Claude Code hooks. This is the
  actively developed path.
- **§12 / §15 herd-control**: the Hermes-era path — ICM reconciler (`herd-loop.sh`) plus the
  Hermes context-budget layer. Kept working; superseded by §16 for Claude Code.
- **§9 (with §1–§8, §10)**: manual herd recipes — raw herdr orchestration patterns any agent
  can follow by hand, no standing loop.
- **§13 fleet-control**: multi-mission meta-orchestration — one orchestrator per mission,
  each self-driving its own herd.

[`CONTRACT-m2herd.md`](./CONTRACT-m2herd.md) is the historical build contract the m2herd herd
was built against (v2.0 era + amendments) — where it disagrees with `skill/SKILL.md` ≥ 2.6.0,
SKILL.md wins.

## Onboarding (recommended): the factory loop

The onboarding TUI sets up the whole factory in one pass — pick your
orchestrator (**Claude Code**, **Hermes**, or **Cursor**), install this skill for it,
install [github/spec-kit](https://github.com/github/spec-kit)'s `specify`
CLI, and establish the SDD loop (`specify init`) in a target repo:

```bash
./scripts/onboard.sh                                                   # interactive
./scripts/onboard.sh --orchestrator claude --repo /path/to/repo --yes  # scripted
```

The choice is recorded in `~/.config/herdr-factory/config.toml`. Once
onboarded, the loop is:

```
/speckit.constitution → /speckit.specify → /speckit.clarify →
/speckit.plan → /speckit.tasks → herd implements [P] tasks →
/speckit.analyze → converge vs spec.md → compound
```

See `skill/SKILL.md` §11 for the full SDD workflow, including how
`tasks.md` `[P]` markers map to parallel herdr workers.

## Install (skill only)

### Quick install (one command)

See the curl one-liner in [Quick start](#quick-start) above. It clones
the repo and symlinks the skill into the right location for Claude
(`~/.claude/skills/herdr/`), Hermes (`~/.hermes/skills/herdr/`), and
Cursor (`~/.cursor/skills/herdr/`). For Claude and Hermes it also wires
up the dispatch-nudge hook (SKILL.md §14) so herding gets (re-)considered
every turn by default — pass `--no-nudge-hook` to skip it.

### Manual install

```bash
git clone https://github.com/machine-machine/herdr-factory-loop-skill.git
cd herdr-factory-loop-skill

# Pick the target agent platform:
ln -s "$(pwd)/skill" ~/.hermes/skills/herdr
# or
ln -s "$(pwd)/skill" ~/.claude/skills/herdr
```

### Update

See the **Upgrade** block in [Quick start](#quick-start): re-run the install
one-liner, or `m2herd self-update`. For a manual clone,
`cd herdr-factory-loop-skill && git pull` does the same — the symlinks stay
valid and the skill is reloaded on the next session.

## Repository layout

```
herdr-factory-loop-skill/
├── README.md                ← you are here
├── CHANGELOG.md             ← version history (semver)
├── CONTRACT-m2herd.md       ← historical m2herd build contract (v2.0 era + amendments; SKILL.md wins on conflict)
├── LICENSE                  ← MIT
├── CONTRIBUTING.md          ← how to propose changes
├── Makefile                 ← TUI build targets: tui (host), tui-release (cross), lint, test
├── skill/
│   ├── SKILL.md             ← the skill itself (loaded by the agent)
│   └── reference.md         ← verbatim CLI & socket reference (+ m2herd/m2herd-up CLI surfaces)
├── hooks/
│   ├── herdr-dispatch-nudge.sh  ← per-turn dispatch-nudge hook (SKILL.md §14)
│   ├── herdr-context-budget.js  ← Hermes PostToolUse context-budget hook (§15)
│   ├── herdr-context-session.sh ← Hermes SessionStart budget/pointer hook (§15)
│   ├── m2herd-session.sh        ← Claude Code SessionStart: inject .m2herd/ digest (§16)
│   ├── m2herd-precompact.sh     ← Claude Code PreCompact: refile notes before compaction (§16)
│   ├── m2herd-budget.js         ← Claude Code PostToolUse: budget advisory → offload to .m2herd/ (§16)
│   └── smoke.sh                 ← hook contract smokes: sample/empty/garbage stdin → exit 0 + valid JSON
├── tui/                         ← m2herd-tui source (Go, bubbletea): dashboard + `,` settings editor
├── prebuilt/                    ← committed m2herd-tui binaries (darwin-arm64, linux-amd64, linux-arm64)
├── templates/
│   ├── herd-control/            ← ICM orchestrator workspace scaffold (§12)
│   ├── fleet-control/           ← meta-orchestrator workspace scaffold (§13)
│   └── m2herd/                  ← .m2herd/ seeds: overview.json, RESUME.md, NOTES.md, settings.json,
│       ├── evolver/             ←   evolver seeds: LESSONS.md (marker convention) + README (§17)
│       └── runs/                ←   trace-bundle store README (§17)
└── scripts/
    ├── onboard.sh           ← onboarding TUI: orchestrator choice + spec-kit + SDD loop
    ├── install.sh           ← one-line installer (see Install section)
    ├── herd-loop.sh         ← ICM reconciliation loop over a herd-control/ workspace (§12)
    ├── fleet-loop.sh        ← meta-orchestrator loop over a fleet-control/ workspace (§13)
    ├── context-budget.sh    ← budget detect/status + slice-manifest decomposer (§15)
    ├── install-hermes-context.sh ← wires the Hermes context hooks into ~/.hermes/ (§15)
    ├── m2herd.sh            ← .m2herd/ engine: boot/init/status/note/refile/resume/sync/archive/gist/next/config/evolve/dashboard/self-update/selftest (§16–§17)
    ├── m2herd-up.sh         ← m2herd workspace bootstrap + worker dispatch/collect/down (§16)
    └── lint.sh              ← sanity checks on SKILL.md frontmatter & cross-refs
```

## CI

<!-- badge placeholder — enable once the repo has a hosted remote:
[![CI](https://<host>/<owner>/herdr-factory-loop-skill/actions/workflows/ci.yml/badge.svg)](https://<host>/<owner>/herdr-factory-loop-skill/actions/workflows/ci.yml)
-->

Every push and PR to `main` runs `.github/workflows/ci.yml` (mirrored at
`.forgejo/workflows/ci.yml` for Forgejo Actions): shell syntax checks
(`bash -n`), `scripts/lint.sh`, the herdr-free `m2herd.sh selftest`, the hook
contract smokes, an advisory shellcheck pass, and a Go build/vet of `tui/`
with a linux-amd64 `m2herd-tui` artifact. Run the same checks locally with
`make ci` before committing.

## Versioning

This skill follows [Semantic Versioning](https://semver.org/).

- **MAJOR** — breaking change to the workflow or command examples that an
  agent would follow
- **MINOR** — new workflow, new section, new command pattern added
- **PATCH** — typo fix, clarification, reference link fix, metadata update

The current version is declared in the `version` field of the YAML
frontmatter at the top of `skill/SKILL.md` and mirrored in
`CHANGELOG.md`.

## Provenance

Originally copied from a local Claude skills directory and adapted:

- Source: `~/.claude/skills/herdr/SKILL.md` (v0.6.9 of herdr / protocol 13)
- Section 9 (channel-driven herd) added by Hermes Agent session on 2026-06-11

See [`CHANGELOG.md`](./CHANGELOG.md) for the full history.

## License

MIT — see [`LICENSE`](./LICENSE).
