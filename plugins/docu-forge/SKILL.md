---
name: docu-forge
description: "Produce an animated short documentary end to end from one sentence: sourced research, 15-second hook, fixed character sheet, scene plan with a human cost gate, then images, voice, subtitles, cut and packaging. Triggers: 'make a documentary', 'animierte Doku', 'docu about X', 'explainer video with characters', 'YouTube short doc'."
---

# docu-forge

One sentence in, a finished documentary out — without an animation studio. The whole trick is
that the process is fixed and every stage has an artefact the next stage reads. You supply
judgement and the human gate; tools supply pixels, voice and cuts.

The pipeline, in order. Do not run stages out of order, and do not open a later stage to
"make progress" while an earlier artefact is still empty.

## 0. Brief

One sentence from the user fills four slots: subject, length, language, audience. If length or
language is absent, take 10 min and the user's language and say so. Write it to `brief.md`
(template `templates/brief.md`).

## 1. Research — sources or it did not happen

Collect **real** sources: primary documents, reputable reporting, papers. Write `research.md`
with one numbered source per line: `[S1] <title> — <url> — <date>`. Facts carry their source id
inline. Anything without a source is marked `(unsourced)` and is allowed only for colour, never
for a number, a name or a date.

Hard rule: **nothing invented**. If a claim cannot be sourced, either drop it or say it is
contested.

## 2. Script

`script.md`. Structure: hook in the **first 15 seconds** (a question, a contradiction or a
stake), then beats, then a resolution that pays the hook off. One idea per beat. Every factual
sentence ends with its `[Sn]`. Narration is written to be spoken: short clauses, no subordinate
clause stacks, numbers rounded to what a listener holds.

Read length check: ~140 spoken words per minute of runtime. If the script is 30 % over the
target runtime, cut, do not speed up.

## 3. Character sheet — lock it before anything is drawn

`characters.md` (template `templates/characters.md`). Each character gets: name, one canonical
paragraph of appearance, palette (named hex), silhouette rule, and **three seed images**. Every
later image prompt pastes the canonical paragraph verbatim, so the face does not drift between
scenes. Chibi proportions are stated once, globally, with the proportion ratio.

A character that changes costume mid-film is a second entry, not an edit.

## 4. Scene plan — and the gate

`scene-plan.csv` (template `templates/scene-plan.csv`): `scene,duration_s,narration,visual,characters,sources`.

Then run the gate:

```bash
bash scripts/docu-gate.sh <project-dir>
```

It fails on: a scene without narration or without a visual, a character not in the sheet, a
factual scene with no source, a total duration more than 15 % off the brief, and a hook section
longer than 15 s. **Nothing is generated until the human approves the plan.** That gate is the
whole point — generation is the only stage that costs money per attempt.

## 5. Assets

Per approved scene: image, then voice, then subtitles. Batch by type, not by scene — one style
sweep catches drift early. Reject a render that breaks the sheet (wrong silhouette, wrong
palette) instead of patching it later.

Voice: the user's own recording wins; otherwise TTS with a fixed voice id for the whole film,
one voice per character maximum.

## 6. Cut

Assemble in scene order, burn subtitles (not sidecar only), duck music under narration, normalise
to −16 LUFS, and hold each hook beat for its full duration. Cut against the narration, never
against the music.

## 7. Packaging

`packaging.md`: title (one concrete promise, no colon stacking), description with the source list
and chapters, thumbnail brief that matches the hook's first frame.

## 8. Delivery

Hand over: the video file, `packaging.md`, and `research.md` as the source appendix. Name the
sources that were weak, and any scene you had to cut.

## Pitfalls

- Generating before approval. Every retry costs; a plan edit costs nothing.
- Sourcing after scripting — the script then bends to what is easy to find.
- Prompt drift: pasting a *paraphrase* of the character paragraph instead of the canonical one.
- Over-length. Cut beats; a 10-minute film that should have been 6 loses the hook's payoff.
- Music carrying the emotion the narration failed to earn.