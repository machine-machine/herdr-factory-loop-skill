# shared/goal_support.md — Layer 3 (reference): the `/goal` hook

The meta-orchestrator's autonomy primitive is **`/goal`** — a per-session **Stop hook**.
`/goal <condition>` arms a hook that **blocks the agent from stopping until the condition
holds**, re-prompting it to keep working toward the goal. This is what lets each tier run
unattended: the meta arms an orchestrator's `/goal` to its mission's `done_when`, and the
orchestrator self-drives its herd until delivered — the meta only re-engages on `blocked`
or `done`. The meta itself should run under its own `/goal` set to the fleet done condition.
**Hooks all the way down: meta-goal → orchestrator-goals → workers.**

## How `fleet-loop.sh` arms it

On launch (and re-arm on idle), the loop types the slash command into the orchestrator's TUI:

```
herdr agent send  <pane> "/goal <done_when>"
herdr pane send-keys <pane> Enter
```

It only does this for agents whose `/goal` is supported (below / `_config/goal_support.txt`).

## Capability matrix

| agent   | `/goal` | mechanism | fleet-loop behavior |
|---------|:-------:|-----------|---------------------|
| claude  | ✅ | Claude Code `/goal` slash command → session Stop hook (auto-clears when met) | arm `/goal`, re-arm on idle |
| codex   | ✅ | Codex goal/Stop equivalent | arm `/goal`, re-arm on idle |
| cursor  | ❌ | no standing-goal hook | re-nudge each tick (resend "continue your mission") |
| opencode / others | ❌ | varies | re-nudge each tick |

Override per fleet in `_config/goal_support.txt` (`<agent> <yes|no>`). When in doubt, mark an
agent `no` — a re-nudge is harmless (idempotent), a dropped goal is not.

## Degrade-gracefully contract

- **Goal-capable** orchestrator: armed once, re-armed if it ever goes `idle` before its herd is
  `DONE`. Minimal meta involvement.
- **Non-goal** orchestrator: the loop re-sends a "continue your mission" pointer every tick it is
  `idle`-but-not-`DONE`. Costs more ticks; same outcome.
- Either way completion is detected from the orchestrator's `herd-control/_fleet/active_stage ==
  DONE` (a disk signal), NOT merely from the TUI being idle — a TUI is idle while waiting too.
