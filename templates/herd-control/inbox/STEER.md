<!--
inbox/STEER.md — live steering channel (Layer 4).

You (or your orchestrator agent) edit THIS FILE to steer the loop without killing it.
The loop drains it at the start of every tick, acts, then clears it back to this empty
template. Anything below the marker is treated as a command/intent.

Recognized first-word commands (rest of line is the argument):
  PAUSE            stop the loop before any dispatch this tick (STATUS: PAUSED)
  RESUME           clear a prior PAUSE
  KILL <slice>     close the worker for <slice> and mark it abandoned in the ledger
  RESCOPE <slice>  re-dispatch <slice> after you edit its prompts/<slice>.md
  GOTO <stage>     set the active stage pointer (e.g. GOTO 04_implement)
  NOTE <text>      free-text intent for the orchestrator to read and act on with judgment

Lines that are not a recognized command are left for the orchestrator (you) to interpret.
-->

=== STEER ===
