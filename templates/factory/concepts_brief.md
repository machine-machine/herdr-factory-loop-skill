# Concepts brief — <feature>

<!--
Full track, before `/speckit.specify`: the brief is its input and the scope lens reads it at G1.
One page: at most 60 lines including this comment, three sections with exactly these headings.
Copy to the feature's folder as `concepts_brief.md`; delete this comment. Write what you saw,
not what you expect: a brief that reproduces nothing says so and what was tried.
-->

Run `<run id>` · triaged full on <date> · input: <tickets, evidence files, the operator's answers>

## Who uses it and where

- **User:** <role, by name where the project knows them — the person whose work changes>
- **Where:** <the screen, file, report or command they use today; the one they will use after>
- **Form of the result:** <what they get: a column, a section of a document, an answer in chat, a file>
- **Today:** <how they do it now, in one or two sentences>

## The problem reproduced

- **Reproduced on:** <real data or staging: project, dataset or environment; date>
- **How:** <the command, query or click path, verbatim>
- **Seen:** <the wrong or missing result, quoted or as a screenshot path>
- **Expected:** <what the user needed instead, in their words where possible>

or

- **Could not reproduce.** Tried: <commands, data, environment>; what was seen instead; why the
  problem is still believed real (ticket, transcript, a second report).

## Open questions

Blocking — the answer changes what is built; each goes to the spec as a requirement, a register
decision or an operator question:

1. <question> — options: (a) …, (b) … — recommended: (a), because … — who can answer: <operator | team>

Safe defaults — built this way unless someone objects; changeable later without rework:

1. <question> — default: <what is built> — why it is safe: <no data written, behind a flag, one-line change>
