"""herd_events — the one source of herd state (docs/herd-flow-v2.md §1).

<herd>/herd.events.jsonl is append-only; the current phase of a slice is its last `phase` event.
Live facts (PR open, head sha, pane alive, overlap) are computed elsewhere and never stored here.
Stdlib only, so the board, the watcher and the hooks can import it without a venv.
"""
import datetime
import fcntl
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
