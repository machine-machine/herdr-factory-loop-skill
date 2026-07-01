<!--
.m2herd/inbox/STEER.md — the steering inbox of the m2herd context fabric (STEER.md pattern).

Watchers, humans, and future TUI tiers APPEND intents below the marker — they never touch
the state files directly. The ORCHESTRATOR drains this file (`m2herd next` says when),
acts on each line with judgment, then clears everything below the marker.

Everything ABOVE the marker is template boilerplate; everything BELOW is live steering.
-->

<!-- === M2HERD:LIVE === -->
