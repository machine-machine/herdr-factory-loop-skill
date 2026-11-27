# LifeOS — the personal layer (fleet default)

[LifeOS](https://github.com/danielmiessler/LifeOS) (MIT, formerly PAI) is the operator's personal
AI harness: TELOS (current state → ideal state), personal memory, the Algorithm loop. It is a
fleet default in the sense that every machine carries it, **not** that every repo uses it.

## The split

| Layer | Owner | Answers |
|---|---|---|
| Personal identity, goals, memory | LifeOS | who and why |
| Repo context, slices, worker dispatch | m2herd (`.m2herd/`) | where the work stands |
| Fleet skills, services, awareness | nix-m2o / Buzz | how we operate |

Rule of thumb: LifeOS lives in `~/.claude` and `~/`-level memory. Nothing LifeOS owns belongs in
`.m2herd/`, and no TELOS text belongs in a repo.

## Install

The fleet ships the skill and its prerequisites, not the identity:

- `skills/lifeos-fleet` in nix-m2o (SKILL.md + `scripts/install-lifeos.sh`, pinned, reversible)
- `bun` and `unzip` in `tools.nix` — without unzip the upstream bun installer dies on NixOS

Then, per machine:

```bash
~/.claude/skills/lifeos-fleet/scripts/install-lifeos.sh   # backup + pinned bootstrap
/LifeOS setup                                             # interactive, once
```

## Collisions to reconcile

`statusLine` (one only, never both), `PreCompact` and `SessionStart` (additive, but verify after
setup), Pulse on port 31337 (one per machine), `settings.json` (diff before/after). After
`/LifeOS setup`, re-run `herdr-factory-loop-skill/scripts/install.sh` and confirm all six fabric
hooks are still registered.

## Why default and not optional

A machine without the personal layer still works, but the operator re-explains themselves on
every fresh box. A machine with it installed and never set up is worse: an empty TELOS renders an
empty dashboard and looks broken. So the default is *installed + interview prompted*, not merely
*available*.