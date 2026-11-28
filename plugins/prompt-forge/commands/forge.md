---
description: Rewrite a raw prompt into a gradeable one (or audit the current draft)
argument-hint: <raw prompt> | --audit
allowed-tools: Bash(m2herd:*), Read, Write, Grep
---

Use the prompt-forge skill on this input:

$ARGUMENTS

If the argument starts with `--audit`: run `m2herd prompt audit` in the repo root (or audit the
prompt given after the flag), report every finding with its rule id, and stop — do not rewrite.

Otherwise:

1. Split the input into followup facts, constraints, intents and corrections. Facts and
   constraints keep their exact wording.
2. In an `.m2herd/` repo: `m2herd prompt new "<raw>"` then `m2herd prompt add` per line (the
   classifier routes; `--as` overrides). Outside one, work in the reply.
3. Answer the four questions explicitly — observable invariant, method order, stretch target with
   baseline and ×N, and the runnable verifier.
4. Produce the full rewritten prompt in one block: objective verbatim, context, constraints,
   method in order, done-when, verifier.
5. Close with the audit result (`m2herd prompt audit` or your own pass over the five rules) and
   name anything still open rather than filling it with a guess.

Do not hand back a description of the improvement instead of the rewritten prompt.