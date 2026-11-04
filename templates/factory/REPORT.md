# Closing report — herd <herd>

<!--
Written by the orchestrator after the last merge of a full-track herd, to `<herd>/REPORT.md`.
Every blocking finding of the herd (the review loop's findings files, G1 rounds, the cut check) gets
exactly one cause; the two question counts feed the full track's success measure
(`docs/factory-v3.md` §4). Delete this comment.
-->

Run `<run id>` · feature `specs/<feature>` · track full · G1 rounds: <n> · merged on <date>

## Summary

- <what the herd shipped, one line per package, with the PR links>
- <how many blocking findings, how many fix rounds, where most of them came from>

## Blocking findings and their cause

Every high or medium finding that survived the skeptics, from any round. Cause, exactly one:
**spec** (the requirement or acceptance criterion was wrong or missing), **cut** (the slice
boundaries, owners or order), **domain** (a rule, term or source read wrongly), **code** (the
implementation of a correct task), **integration** (merge order, a regression between packages).

| # | Slice | Finding (title) | Severity | Found by (G1 lens, cut check, reviewer, blind) | Cause | Fixed in (PR / spec version) |
|---|---|---|---|---|---|---|
| 1 | <slice> | <title> | high / medium | <who> | spec / cut / domain / code / integration | <where> |

Totals: spec <n> · cut <n> · domain <n> · code <n> · integration <n> — of <total> blocking findings.

## Blocking questions — found at G1 vs after start

A blocking question is one whose answer changed what was built. "After start" means after the
herd's first `working` event; the register decision that closed it names where it came from.

| Question (register id) | Found at | Closed by (decision id) | Held slices, if any |
|---|---|---|---|
| <q- or d- id> | G1 round <n> / after start (<slice>) | <d- id> | <slices or —> |

Counts: found at G1 <n> · found after start <n>.

## G1 cost per round

From `specs/<feature>/reviews/g1-<n>.md`: tokens, agent minutes, operator minutes, operator
questions, base shas.

| Round | Tokens | Agent minutes | Operator minutes | Operator questions |
|---|---|---|---|---|
| 1 | <k> | <min> | <min> | <n> |

## What to change next time

- <one line each: a lens that missed something, a template section nobody filled, a cause that keeps recurring>
