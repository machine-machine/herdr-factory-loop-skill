# prompt-forge — the prompt optimiser

A prompt that was typed in one breath is usually a role adjective, an instance of a
symptom, and no way to tell whether the result is good. `m2herd prompt` turns that into
a prompt that specifies a method, an invariant, a stretch target and an external grader.

Source: Felix Riesenberger (led Claude AI / Co-Work / Claude Code Desktop engineering at
Anthropic) on how he actually prompts agents. Everything below is a mechanical restatement
of five rules he gives, so that the rules can be checked instead of remembered.

## The five rules

| # | Rule | Why |
|---|---|---|
| R1 | Say what an experienced X **does**, not that the agent **is** an experienced X | The role sentence only changes vocabulary; the verb sequence changes method. Naming the method also exposes that you know it. |
| R2 | Name a stretch target **with the baseline and the ×N factor**, plus "it is possible — try every way" | Asked for 5 s → get 5 s. Asked for 200 ms from 5 s (25×) → the agent stops optimising around the slow design. The clause pre-empts the early "impossible". |
| R3 | Ask for the **invariant**, not the instance | "Fix crash 17" produces a patch for 17. "The app does not crash" makes the agent find the class. |
| R4 | The agent **never grades itself** — a runnable verifier does | Self-assessment converges on "looks good". A command that a third party can run converts opinion into a result. |
| R5 | Raw sentence → **four explicit questions** → full rewrite | The questions force the four things a prompt cannot omit: observable, method order, number, verifier. |

## The distinction the optimiser has to make

A session sends two materially different things, in the same chat bubble stream:

- **Followup information** — "the file is at `src/perf.ts`", "the client dropped v2",
  "the last run took 4.1 s". This is *state*. It is filed **verbatim** under `## Context`,
  never reworded, never promoted to a task.
- **A prompt with an intent** — "make it faster", "build a meter". This is an
  *instruction*. It is filed under `## Intents` and decomposed under the four questions
  with a verifier.

Both directions of confusion are expensive. A fact turned into a task burns a worker on
work that already exists; a task buried in a context blob loses its acceptance criteria.
There is a third and fourth kind worth naming: a **constraint** ("never above 4 MB") is a
boundary, not work, and a **correction** ("no — profile first") supersedes an earlier
intent instead of joining it.

Classification is deterministic (`prompt_classify`), with `--as` as the override when the
heuristic is wrong. Heuristics look for contradiction markers, boundary wording, and
state-only carriers (paths, versions) without a leading imperative.

## Use

```bash
m2herd prompt new "mach die app schneller"          # opens the file + the interview
m2herd prompt add "die datei liegt in src/perf.ts" # -> ## Context   (fact, verbatim)
m2herd prompt add "darf nicht ueber 4 MB gehen"    # -> ## Constraints
m2herd prompt add --as constraint "..."            # override the classifier
m2herd prompt add "nein, stattdessen erst profilen" # -> strikes the old intent, adds a correction
m2herd prompt audit                                  # exits 1 until the prompt is gradeable
m2herd prompt show
```

`audit` is the external check applied to the optimiser itself — the same R4 it demands of
prompts. It fails on a missing verifier, role adjectives without a method, "as fast as
possible" without a number, and an empty `## Done when`.

All decisions are appended to `.m2herd/prompt/ledger.jsonl`, so a misroute is auditable
after the fact instead of invisible.

## Hook

While a prompt is under construction, `hooks/m2herd-prompt-intent.sh` (UserPromptSubmit)
classifies each turn and states the branch, so the agent does not decide from mood. It is
silent outside `.m2herd/` repos, on slash commands, and on chatter under four words.

## Honest limits

- The classifier is word- and shape-based. German/English only. A terse intent with a path
  in it ("src/perf.ts: make it lazy") routes to `context`; use `--as`.
- "Do what an experienced X would do" is a lever on capable models. A small model may just
  restate the sentence — pair R1 with an explicit ordered method list when the model is weak.
- R2's stretch target can produce over-engineering: a 25× demand may buy a rewrite where a
  2× fix was fine. State the ×N rather than a bare number, so the tradeoff is visible.
- The verifier is only as good as it is external. `npm test` that the agent itself wrote is
  weaker than a harness that existed before the task.