"""herd_events — the one source of herd state (docs/herd-flow-v2.md §1).

<herd>/herd.events.jsonl is append-only; the current phase of a slice is its last `phase` event.
Live facts (PR open, head sha, pane alive, overlap) are computed elsewhere and never stored here.
Stdlib only, so the board, the watcher and the hooks can import it without a venv.
"""
import datetime
import fcntl
import glob
import json
import os
import re

EVENTS = "herd.events.jsonl"

PHASES = ("queued", "working", "accepted", "review_running", "review_ok", "review_befund",
          "fix_queued", "merged", "parked")

# from-phase -> allowed next phases; None = slice has no event yet
TRANSITIONS = {
    None: {"queued", "working", "parked"},
    "queued": {"working", "parked"},
    "working": {"accepted", "parked"},
    "accepted": {"review_running", "working", "parked"},
    "review_running": {"review_ok", "review_befund", "parked"},
    "review_befund": {"fix_queued", "parked"},
    "fix_queued": {"working", "parked"},
    "review_ok": {"merged", "review_running", "fix_queued", "parked"},
    "merged": {"parked"},
    "parked": {"queued", "working", "parked"},
}

BY = ("orchestrator", "worker", "loop", "watch", "merge", "recover")

SLICE_RE = re.compile(r"^[a-z][a-z0-9_-]{0,47}$")


class TransitionError(ValueError):
    pass


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def path(herd):
    return os.path.join(herd, EVENTS)


def claude_project_dir(cwd):
    """~/.claude/projects/<slug> of a cwd, named the way Claude Code names it: every non-alphanumeric
    character becomes "-"; a slug over 200 chars is cut and gets a hash suffix (found by glob)."""
    root = os.path.expanduser("~/.claude/projects")
    slug = re.sub(r"[^A-Za-z0-9]", "-", cwd)
    if len(slug) <= 200:
        return os.path.join(root, slug)
    hits = sorted(glob.glob(os.path.join(glob.escape(root), glob.escape(slug[:200]) + "-*")))
    return hits[0] if hits else os.path.join(root, slug[:200])


def read(herd):
    """All events in file order. A torn last line (crash mid-write) is skipped, not fatal."""
    out = []
    try:
        with open(path(herd), encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                if isinstance(ev, dict) and ev.get("slice") and ev.get("phase"):
                    out.append(ev)
    except FileNotFoundError:
        pass
    return out


def state(herd):
    """slice -> its last event (with `since` = ts of that event and `history` = phases in order)."""
    st = {}
    for ev in read(herd):
        s = ev["slice"]
        prev = st.get(s)
        hist = (prev["history"] if prev else []) + [ev["phase"]]
        st[s] = dict(ev, since=ev.get("ts"), history=hist)
    return st


def last(herd, slice_name):
    return state(herd).get(slice_name)


def append(herd, slice_name, phase, by="orchestrator", note=None, force=False, **fields):
    """Validate the transition and append one event under an exclusive lock. Returns the event."""
    if not SLICE_RE.match(slice_name or ""):
        raise ValueError(f"bad slice name {slice_name!r} (expected {SLICE_RE.pattern})")
    if phase not in PHASES:
        raise ValueError(f"unknown phase {phase!r} (one of {', '.join(PHASES)})")
    if by not in BY:
        raise ValueError(f"unknown writer {by!r} (one of {', '.join(BY)})")
    if force and not note:
        raise ValueError("--force needs a note saying why")
    os.makedirs(herd, exist_ok=True)
    with open(path(herd) + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        cur = last(herd, slice_name)
        frm = cur["phase"] if cur else None
        if not force and phase not in TRANSITIONS.get(frm, set()):
            raise TransitionError(f"{slice_name}: {frm or 'nothing'} -> {phase} is not allowed "
                                  f"(allowed: {', '.join(sorted(TRANSITIONS.get(frm, set()))) or 'none'})")
        ev = {"ts": now(), "slice": slice_name, "phase": phase, "by": by}
        for k, v in fields.items():
            if v is not None:
                ev[k] = v
        if note:
            ev["note"] = note
        if force:
            ev["forced_from"] = frm
        with open(path(herd), "a", encoding="utf-8") as f:
            f.write(json.dumps(ev, ensure_ascii=False) + "\n")
            f.flush()
            os.fsync(f.fileno())
        return ev


def task_header(herd, slice_name):
    """`key: value` lines at the top of <slice>.task.md until the first blank line (docs §2)."""
    hdr = {}
    try:
        with open(os.path.join(herd, f"{slice_name}.task.md"), encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                if not line.strip():
                    break
                m = re.match(r"^\s*([a-z_]+)\s*:\s*(.*?)\s*(#.*)?$", line)
                if not m:
                    break
                hdr[m.group(1)] = m.group(2)
    except FileNotFoundError:
        pass
    for key in ("tickets", "together_with", "needs_memory"):
        if key in hdr:
            hdr[key] = [x.strip() for x in hdr[key].split(",") if x.strip()]
    return hdr


def repos(herd, slice_name):
    """<slice>.repos lines `repo branch base` -> list of dicts; base is required (docs §2)."""
    out = []
    try:
        with open(os.path.join(herd, f"{slice_name}.repos"), encoding="utf-8") as f:
            for n, line in enumerate(f, 1):
                parts = line.split("#", 1)[0].split()
                if not parts:
                    continue
                if len(parts) < 3:
                    raise ValueError(f"{slice_name}.repos:{n}: expected `repo branch base`, got {line.strip()!r}")
                out.append({"repo": parts[0], "branch": parts[1], "base": parts[2]})
    except FileNotFoundError:
        pass
    return out


def package(herd, slice_name):
    """Transitive closure of together_with (both directions) — the merge unit."""
    slices = {f[:-len(".task.md")] for f in os.listdir(herd) if f.endswith(".task.md")} if os.path.isdir(herd) else set()
    links = {s: set(task_header(herd, s).get("together_with", [])) for s in slices}
    for s, ps in list(links.items()):
        for p in ps:
            links.setdefault(p, set()).add(s)
    seen, todo = set(), [slice_name]
    while todo:
        s = todo.pop()
        if s in seen:
            continue
        seen.add(s)
        todo.extend(links.get(s, ()))
    return sorted(seen)


# ---- factory gates (docs/factory-v3.md §2) ----------------------------------------------------------
# Gate events belong to a run (one intent from triage to merge), not to a slice. They live in
# <run>/gates.jsonl and carry `gate` + `event` instead of `slice` + `phase`, so read() above never
# mistakes one for a phase event. Only the events 3.0.0-alpha writes are listed; the rest of the
# schema (evals_frozen, eval_pass, eval_fail, drift_found) lands with the compiler and default evals.

GATES_FILE = "gates.jsonl"

TRACKS = ("quick", "standard", "full")
TIERS = ("low", "medium", "high")

# event -> the gate it belongs to
GATE_OF = {"triaged": "G0", "design_review": "G1", "design_ok": "G1"}

# from-event -> allowed next events; None = run has no gate event yet
GATE_TRANSITIONS = {
    None: {"triaged"},
    "triaged": {"triaged", "design_review"},
    "design_review": {"design_review", "design_ok", "triaged"},
    "design_ok": {"design_review", "triaged"},
}

GATE_BY = ("orchestrator", "human", "loop")

RUN_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")


def gates_path(run_dir):
    return os.path.join(run_dir, GATES_FILE)


def read_gates(run_dir):
    """All gate events of a run in file order; torn or foreign lines are skipped."""
    out = []
    try:
        with open(gates_path(run_dir), encoding="utf-8") as f:
            for line in f:
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                if isinstance(ev, dict) and ev.get("gate") and ev.get("event"):
                    out.append(ev)
    except FileNotFoundError:
        pass
    return out


def gate_state(run_dir):
    """{last, track, tier, gates: {G0: last event of G0, ...}} — the run's position in the pipeline."""
    evs = read_gates(run_dir)
    st = {"last": evs[-1] if evs else None, "track": None, "tier": None, "gates": {}}
    for ev in evs:
        st["gates"][ev["gate"]] = ev
        if ev["event"] == "triaged":
            st["track"], st["tier"] = ev.get("track"), ev.get("tier")
    return st


def append_gate(run_dir, event, by="orchestrator", note=None, force=False, **fields):
    """Validate and append one gate event under the run's lock. Rules beyond the transition table:
    a quick run has no G1; re-triage may raise track and tier, never lower them (force + note
    overrides) — except that the human's --track pick (override=True) may lower an UNSURE track; design_ok is written by the human only and carries their words verbatim."""
    if event not in GATE_OF:
        raise ValueError(f"unknown gate event {event!r} (one of {', '.join(GATE_OF)})")
    if by not in GATE_BY:
        raise ValueError(f"unknown writer {by!r} (one of {', '.join(GATE_BY)})")
    if force and not note:
        raise ValueError("--force needs a note saying why")
    if event == "triaged":
        if fields.get("track") not in TRACKS:
            raise ValueError(f"triaged needs track in {TRACKS}")
        if fields.get("tier") not in TIERS:
            raise ValueError(f"triaged needs tier in {TIERS}")
    if event == "design_review":
        try:
            if int(fields.get("open")) < 0:
                raise ValueError
        except (TypeError, ValueError):
            raise ValueError("design_review needs open = the number of findings still open (>= 0)")
    if event == "design_ok":
        if by != "human":
            raise ValueError("design_ok is the human's approval (by=human)")
        if not str(fields.get("word") or "").strip():
            raise ValueError("design_ok needs the human's words verbatim (word=...)")
    if event != "triaged" and not force and not os.path.isfile(gates_path(run_dir)):
        raise TransitionError(f"nothing -> {event} is not allowed (allowed: triaged) — no run at {run_dir}")
    os.makedirs(run_dir, exist_ok=True)
    with open(gates_path(run_dir) + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        st = gate_state(run_dir)
        frm = st["last"]["event"] if st["last"] else None
        if not force:
            if event not in GATE_TRANSITIONS.get(frm, set()):
                raise TransitionError(f"{frm or 'nothing'} -> {event} is not allowed "
                                      f"(allowed: {', '.join(sorted(GATE_TRANSITIONS.get(frm, set()))) or 'none'})")
            if event == "design_review" and st["track"] == "quick":
                raise TransitionError("a quick run has no G1 — re-triage with --track standard first")
            if event == "design_ok":
                rev = st["gates"].get("G1")
                if rev is None or rev["event"] != "design_review":
                    raise TransitionError("design_ok needs a design_review first")
                if int(rev.get("open") or 0) > 0:
                    raise TransitionError(f"design_review {rev.get('evidence', '')} still has {rev['open']} open "
                                          "finding(s) — resolve them and record a new design_review")
            if event == "triaged" and st["track"]:
                # an UNSURE triage is the human's pick: their --track override may lower its track
                humans_pick = st["gates"]["G0"].get("sure") is False and fields.get("override") is True
                if ((TRACKS.index(fields["track"]) < TRACKS.index(st["track"]) and not humans_pick)
                        or TIERS.index(fields["tier"]) < TIERS.index(st["tier"] or "low")):
                    raise TransitionError(f"re-triage may raise, never lower: was {st['track']}/{st['tier']}")
        ev = {"ts": now(), "gate": GATE_OF[event], "event": event, "by": by}
        for k, v in fields.items():
            if v is not None:
                ev[k] = v
        if note:
            ev["note"] = note
        if force:
            ev["forced_from"] = frm
        with open(gates_path(run_dir), "a", encoding="utf-8") as f:
            f.write(json.dumps(ev, ensure_ascii=False) + "\n")
            f.flush()
            os.fsync(f.fileno())
        return ev
