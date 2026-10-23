# STEER triage — rules for the orchestrator

The gate hook (`hooks/m2herd-steer-gate.sh`) tells you when `.m2herd/inbox/STEER.md` holds
findings nobody has handled. The intake is mechanical (`m2herd-steer`): repeated reports fold into
one item with a stable key, a count and first/last seen; older states of a watcher's subject are
superseded automatically. What is left needs judgment, and that is yours. The ledger then proves
you gave it: `m2herd-steer verify` exits 1 while any item is open.

## The one rule

**Every open item ends in exactly one ledger action.** Not a thought, not a chat line, not an edit
of STEER.md — a `m2herd-steer ack <key> --action … --note "…"` or `m2herd-steer defer <key>
--until <date> --note "…"`. An item you cannot decide on is a question: that is `register` (or
`ticket`), never silence.

## When

- The gate fires on a prompt or at a stop. If you are in the middle of the user's task, finish it
  first; the line comes back (at most every 30 minutes for the same open set).
- Between tasks, at session start, and before a context clear or a save point: triage to zero.
- Never inside a herd worker pane — workers do not triage the orchestrator's inbox.

## How

1. `m2herd-steer list --open` (add `--json` to read ids and hints). Items with `NEEDS_HUMAN`,
   `BLOCK`, `FAIL`, `ERROR`, `PAUSE`, `KILL` sort first, then reopened items, then the oldest.
2. Look at the evidence before deciding: the `hint` path, the ids, the count (x46 over three weeks
   is a standing condition, x1 is an event). `list --all` shows what was superseded and why.
3. Decide per item, using the table. Items that belong together (same subject, same cause) may
   share one decision; say so in the note.
4. Record it. `ack` takes several keys when the same note is true for all of them.
5. `m2herd-steer verify` must exit 0. Then `m2herd-steer compact` moves the closed entries to
   `archives/steer/<YYYY-MM>.md`.
6. Tell the user one line: `STEER: N triaged — a done, b ticket, c register, d delegated, e dropped,
   f deferred` plus anything that needs them. No more than that.

| The item is … | Do | Record |
|---|---|---|
| small, inside your remit, checkable now | do it, check it | `--action done --note "<what changed: commit, command, result>"` |
| real work for later or for someone else | one ticket in the team's tracker (update the existing one if it is there) | `--action ticket --note "<ticket id>: <title>"` |
| a decision taken, or a question only a human can answer | an entry in the decisions register (`d-…` / `q-…`) | `--action register --note "<entry id>"` |
| unclear, needs digging across files or systems | ONE subagent for all items that belong together, with the keys in its prompt; the subagent closes them with `done` or hands back a ticket/register id | `--action delegated --note "<subagent or worker name>: <question>"` |
| noise: duplicate, stale, already handled elsewhere, a watcher bug | nothing, or a ticket against the watcher when it keeps producing noise | `--action dropped --note "<why it is noise>"` |
| legitimately waiting (a person, a date, a deploy) | nothing yet | `defer <key> --until <date, at most 14 days> --note "<what you wait for>"` |

## What the actions mean afterwards

- `done` — reopens if the watcher reports the item again: a finding that comes back was not done.
- `ticket`, `register`, `delegated` — the work is tracked elsewhere; repeats stay quiet, but new ids
  in the item (a list that grew) reopen it.
- `dropped` — never reopens. Use it for kinds of report that are noise, and say why.
- `defer` — open again once the date has passed.
- `superseded` — written by the intake, not by you: a newer status for the same subject, or a
  snapshot watcher's item missing from its last two reports. It reopens when reported again. A
  watcher that caps its report length can hide an item this way; when a watcher's picture looks
  too clean, check `list --all` and the watcher's own state (the `hint`).

## Never

- Edit or clear STEER.md by hand. Removed entries keep their items open in the ledger; `compact`
  is the only rewrite.
- Ack an item you have not looked at, or bulk-ack to make `verify` pass.
- Drop a line a human wrote (no source label, or the TUI's `- [ts] text`) without telling them:
  those are instructions. Act on them, or ask.
- Start one subagent per item. Group by cause; one agent per group.
- Paste STEER content into the chat. The keys and the counts are enough.
