# Changelog

All notable changes to this skill are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
adheres to [Semantic Versioning](https://semver.org/).

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

[1.2.0]: #120---2026-06-11
[1.1.0]: #110---2026-06-11
[1.0.0]: #100---2026-06-11
