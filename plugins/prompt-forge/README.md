# prompt-forge (Claude Code plugin)

Turns a one-breath prompt into a gradeable one. Facts stay verbatim, intents get decomposed,
the agent stops grading itself.

Source: Felix Riesenberger (ex-Anthropic engineering lead) on how he prompts agents.

## Install

```
/plugin marketplace add machine-machine/herdr-factory-loop-skill
/plugin install prompt-forge@machine-machine-skills
```

## What you get

- **skill `prompt-forge`** — the four questions, the five rules, the split between followup
  information (context, verbatim) and a prompt with an intent (decomposed).
- **`/prompt-forge:forge <raw prompt>`** — does the rewrite inline.
- **agent `prompt-auditor`** (sonnet, read-only) — grades a prompt against the rules and
  returns findings, never rewrites.

## Inside an `.m2herd/` repo

The mechanical half is `m2herd prompt new|add|classify|audit`; the audit is the same check the
agent runs, so it can gate a hand-off. Outside a fabric repo the plugin works on its own, in the
reply.

## Honest limits

The classifier is word- and shape-based (de/en). A terse intent carrying a path routes to
context — use `--as`. R2's stretch target can buy over-engineering: state the baseline and the
×N so the price is visible.