<!--
.m2herd/inbox/STEER.md — the steering inbox of the m2herd context fabric (STEER.md pattern).

Watchers, humans, and future TUI tiers APPEND intents below the marker — they never touch
the state files directly. One entry per line: `- <ISO ts> <Source>: finding; finding; ...`
for a watcher (one finding per subject, ids as plain numbers, an optional trailing
`. Check: /path` pointer), `- [<ISO ts>] <text>` for a human or the TUI.

The ORCHESTRATOR does not clear this file by hand. `m2herd-steer` reads it into a ledger
(inbox/steer.ledger.jsonl): repeats fold into one item, every item ends in exactly one
recorded action (rules: templates/herd/rules/STEER.md), `m2herd-steer verify` proves it,
and `m2herd-steer compact` moves closed entries to archives/steer/<YYYY-MM>.md.

Everything ABOVE the marker is template boilerplate; everything BELOW is live steering.
-->

<!-- === M2HERD:LIVE === -->
