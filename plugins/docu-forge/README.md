# docu-forge (Claude Code plugin)

One sentence in, an animated short documentary out — sourced research, a 15-second hook, a
locked character sheet, a scene plan that a human approves before a single render is paid for,
then assets, cut and packaging.

## Install

```
/plugin marketplace add machine-machine/herdr-factory-loop-skill
/plugin install docu-forge@machine-machine-skills
```

## Pipeline

`brief → research.md (real sources only) → script.md (hook ≤ 15 s) → characters.md (canonical
appearance + palette + seeds, pasted verbatim into every prompt) → scene-plan.csv → **gate +
human approval** → images/voice/subs → cut → packaging`

The gate is code, not advice:

```bash
bash scripts/docu-gate.sh <project-dir>
```

It fails a scene without narration or visual, a character missing from the sheet, a cited fact
with no source, a source not in `research.md`, a hook over 15 s and a runtime more than 15 % off
the brief.

## Honest limits

The generation stage is the only one that costs money per attempt, which is why the gate sits in
front of it. Everything before the gate is text: cheap, and fully re-doable. If the film is
boring, it was boring in the plan.

Voice: the user's own recording wins over TTS. One voice per character maximum, fixed for the
film.