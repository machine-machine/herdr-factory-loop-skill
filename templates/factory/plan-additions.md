# Plan additions — full track

<!--
Paste these sections into `specs/<feature>/plan.md` after `/speckit.plan`; spec-kit's own template stays
untouched. The architecture lens checks them against the repos at the base sha (`G1-LENSES.md`,
Architecture); the cut turns the owner column into slices and stacks. Delete this comment.
-->

## Readers

Every shared concept the change touches (a field, data shape, rule or file format read by more than
one module, slice or repo): its readers found mechanically — the command recorded, so the lens can
re-run it at the base sha — and the one slice allowed to change it. A slice that needs a concept it
does not own stacks on the owner.

| Concept | Readers (module, slice, repo or script) | Command used | Owner slice |
|---|---|---|---|
| <concept> | <repo>/<path>, <repo>/<path>, <script> | `git grep -n "<name>" <sha> -- <paths>` or `graphify affected "<symbol>()"` | <slice> |

A reader in another repo links to the contract section below. Readers nobody found yet are a
finding at G1, not a surprise at the merge.

## Contract section

At most one page. The one place a cross-repo or cross-slice shape is written; both sides build from
this text and the spec names it under "Shared shapes" (`templates/factory/spec-additions.md`). One
block per shape:

### <shape name> — <producer slice> → <consumer slice(s)>

- **Carried as:** <API route + method, event name, file format + path, table + column>
- **Fields:** `<name>`: <type>, <required | optional>, <meaning>; …
- **Error cases:** <what the consumer sees when the producer has nothing, refuses, or fails>
- **Versioning:** <what changes without breaking the consumer; what needs both sides>
- **Example:** one real instance, verbatim (a request and response, a file excerpt, a row)

## Reserved resources

Numbers and names that two herds cannot both take: migration numbers, ports, route prefixes, event
names, feature flags, file names in a shared folder. Listed here so the cut check can compare them with
every other live herd before a slice starts.

| Resource | Value(s) reserved | Slice | How it was checked (command, against which herds) |
|---|---|---|---|
| migration number | <nnn> | <slice> | `ls <migrations dir>` at the base sha + the reserved tables of live herds |
| <port, route, flag, event> | <value> | <slice> | <command> |
