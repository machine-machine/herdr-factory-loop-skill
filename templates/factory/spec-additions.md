# Spec additions — full track

<!--
Paste these sections into `specs/<feature>/spec.md` after `/speckit.specify` (before `/speckit.clarify`);
spec-kit's own template stays untouched. The domain lens reads them at G1 (`G1-LENSES.md`, Domain).
Every source a rule cites is copied by the orchestrator to `specs/<feature>/sources/` before the
lenses start; name the local copy in the Source column, or the URL it was fetched from.
Delete this comment.
-->

## Glossary

Every domain term and every abbreviation that an acceptance criterion uses, with its meaning here and
where that meaning comes from. An abbreviation with more than one meaning in the project's register
gets its meaning spelled out, never the short form alone.

| Term | Meaning here | Source |
|---|---|---|
| <term> | <one sentence; the meaning this spec relies on, not the dictionary's> | <register decision id, source text + locator, the team, or "this spec, FT-<n>"> |
| <abbreviation> | <the long form and the meaning it has in this spec> | <where that reading is fixed> |

## Rules

One row per domain rule the change relies on: the statement, where it applies, and the passage it
rests on. The lens checks that the quoted passage says the rule, for that scope — a citation alone is
not a check. A rule whose only source is an inference (no text, "assumed", from memory) is marked
provisional and stays provisional until a source text or a register decision carries it.

| # | Rule | Scope (Bundesland or federal) | Source (path under `specs/<feature>/sources/` or URL) | Locator (page, §, Anhang, table row) | Quoted passage | Provisional |
|---|---|---|---|---|---|---|
| R1 | <one statement, e.g. "Anlage 1 lists the species at collision risk"> | <one Bundesland, several, or federal> | <sources/<file> or https://…> | <§ 44 Abs. 1 Nr. 1; p. 12; Tabelle 3, Zeile 4> | "<the sentence or clause, verbatim>" | no |
| R2 | <statement> | <scope> | — (no source obtained) | — | — | **yes** — <what was tried; who could supply it> |

Rules that contradict a register decision are a finding, not a choice: change the rule or record a
new decision first. Register search runs in both spellings (ä/ö/ü/ß and ae/oe/ue/ss).

## Shared shapes

A field, data shape, rule or file format that another module, slice or repo reads is a shared
concept. Its readers, its owner slice and — for a reader in another repo — its contract section are
written once, in the plan: see `templates/factory/plan-additions.md` (readers table, contract section,
reserved resources). The spec names the concepts; the plan says who reads and who owns them.

- <concept> — <what it is, in one line> — readers and owner: plan, readers table
