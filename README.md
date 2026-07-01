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
| 14 | Context budgeting & decomposer (Hermes) | keep the orchestrator within a token budget (default GLM-5.2/384k); decompose into budget-sized slice manifests; hooks offload context on demand |

See [`skill/SKILL.md`](./skill/SKILL.md) for the full reference and
[`skill/reference.md`](./skill/reference.md) for verbatim CLI/socket docs.

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

```bash
# from a fresh agent environment
curl -sSL https://raw.githubusercontent.com/machine-machine/herdr-factory-loop-skill/main/scripts/install.sh | bash
```

This will clone the repo and symlink the skill into the right location
for Claude (`~/.claude/skills/herdr/`), Hermes (`~/.hermes/skills/herdr/`),
and Cursor (`~/.cursor/skills/herdr/`).

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

```bash
cd herdr-factory-loop-skill && git pull
```

The symlink stays valid, the skill is reloaded on next session.

## Repository layout

```
herdr-factory-loop-skill/
├── README.md                ← you are here
├── CHANGELOG.md             ← version history (semver)
├── LICENSE                  ← MIT
├── CONTRIBUTING.md          ← how to propose changes
├── skill/
│   ├── SKILL.md             ← the skill itself (loaded by the agent)
│   └── reference.md         ← verbatim CLI & socket reference
└── scripts/
    ├── onboard.sh           ← onboarding TUI: orchestrator choice + spec-kit + SDD loop
    ├── install.sh           ← one-line installer (see Install section)
    └── lint.sh              ← sanity checks on SKILL.md frontmatter & cross-refs
```

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
