---
name: prompt-forge
description: "Turn a raw one-breath prompt into a gradeable one. Fires when sharpening a brief, a worker prompt or a delegation: separates followup facts (filed verbatim) from intents (decomposed), asks four questions, demands an external verifier. Triggers: 'sharpen this prompt', 'make this a good prompt', 'brief a worker', 'prompt for the agent', 'why is my prompt bad'."
---

# prompt-forge

A prompt typed in one breath is usually a role adjective, one instance of a symptom, and no
way to tell whether the result is good. This skill turns it into a prompt that names a method,
an invariant, a stretch target and an external grader.

Source: Felix Riesenberger (led Claude AI / Co-Work / Claude Code Desktop engineering at
Anthropic) on how he actually prompts agents; restated as five checkable rules.

## The split that decides everything

Every turn in a session is one of four things. Getting the first two confused is the classic
failure in both directions — a fact promoted to a task burns work that already exists, a task
buried in context loses its acceptance criteria.

- **Followup information** — a path, a version, a measurement, a client statement. It is
  *state*. File it **verbatim**. Never reword it, never promote it to a task.
- **A prompt with an intent** — "make it faster", "build a meter". It is an *instruction*.
  Decompose it.
- **Constraint** — "never above 4 MB". A boundary, not work.
- **Correction** — "no, profile first". It *replaces* an earlier intent; strike that one.

In an `.m2herd/` repo the mechanical form is `m2herd prompt add "<text>" [--as …]` — the
classifier routes it and writes the decision to a ledger; `--as` overrides.

## The four questions (answer all four, then rewrite)

1. What is the observable that says done? State it as an invariant, not an instance.
2. What would an experienced X do first, and in what order?
3. What is the stretch target, its baseline, and the ×N factor?
4. Which runnable command proves it, and what makes it fail?

A prompt that still has an unanswered question or no verifier is not done.

## The five rules

- **R1 — verbs over adjectives.** "You are an expert in X" changes vocabulary only. "Do what an
  experienced X would do" changes method. On a weak model, add the ordered method list — the
  phrase alone won't carry it.
- **R2 — a stretch target with the baseline and the ×N.** Asked for 5 s you get 5 s; asked for
  200 ms from 5 s you get a different design. Add "it is possible — try every way" so the early
  "impossible" is pre-empted. Say the ×N so the cost of over-engineering is visible.
- **R3 — invariants over instances.** "The app does not crash", not "fix crash 17".
- **R4 — the agent never grades itself.** A command somebody else can run. `npm test` the agent
  wrote is weaker than a harness that existed before the task.
- **R5 — one sentence → four questions → full rewrite.** Not a paragraph-shaped patch of the
  original: patches inherit the original's vagueness.

## Procedure

1. Take the raw prompt. Split it line by line into fact / constraint / intent / correction.
   Facts and constraints keep their wording — do not "improve" a path.
2. Answer the four questions. #3 needs a number and its baseline; if the user gave none, ask
   once, and if still absent, state the assumption and mark it.
3. Write the verifier as a real command line. If it cannot fail, it is decoration.
4. Rewrite the whole prompt: objective (verbatim), context block, constraints, method in order,
   done-when invariant, verifier.
5. Self-check with `/prompt-forge:forge --audit` or `m2herd prompt audit` — exit 1 means it is
   not ready. Fix and repeat; do not argue with the finding.
6. Hand over the *rewritten* prompt, not a description of how it improved.

## Pitfalls

- Over-reusing R2: a 25× target buys a rewrite where 2× was fine. State baseline and ×N.
- Rewriting a fact into a sentence — the path, hash or value must be byte-identical.
- A verifier that only the author can run (a private script, a browser by hand).
- Dropping the user's words "to make it read better"; the objective stays verbatim.