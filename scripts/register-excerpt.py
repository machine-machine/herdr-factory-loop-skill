#!/usr/bin/env python3
"""register-excerpt.py — the decisions/open-questions entries that concern one slice (docs §4).

  register-excerpt.py [--register PATH] [--ticket ID]... [--file PATH]... [--keyword WORD]...
                      [--max-bytes N] [--json]
  register-excerpt.py --selftest

Reads a decisions register (`{"open_questions": [...], "decisions": [...]}`, entries with `id` and free
text fields such as decision, rationale, refs, context, question) and selects entries whose text
mentions a ticket id, a touched file (full path, or a distinctive basename) or a keyword (whole word,
case-insensitive). Ranking: ticket 3, file 2, keyword 1 per hit; open questions before decisions at
the same score, newer before older. Output is capped at --max-bytes (default 12000, 0 = no cap); what
does not fit is named on one `+N weitere` line, never silently dropped.
Register path: --register, else $HERD_REGISTER, else ./decisions-questions.json.
"""
import argparse
import json
import os
import re
import sys

# basenames too common to identify a file on their own
GENERIC = {"__init__.py", "index.ts", "index.tsx", "index.js", "page.tsx", "layout.tsx", "main.py",
           "utils.py", "util.ts", "types.ts", "readme.md", "package.json", "conftest.py", "setup.py",
           "pyproject.toml", "config.py", "settings.py", "models.py", "route.ts", "app.py"}


def flatten(v):
    if isinstance(v, str):
        return v
    if isinstance(v, dict):
        return "\n".join(flatten(x) for x in v.values())
    if isinstance(v, (list, tuple)):
        return "\n".join(flatten(x) for x in v)
    return "" if v is None else str(v)


def load(path):
    with open(path, encoding="utf-8") as f:
        reg = json.load(f)
    out = []
    for kind, key in (("question", "open_questions"), ("decision", "decisions")):
        for e in reg.get(key, []) or []:
            if isinstance(e, dict) and e.get("id"):
                out.append((kind, e))
    return out


def score(entry, tickets, files, keywords):
    text = flatten(entry)
    low = text.lower()
    hits = []
    for t in tickets:
        if t and re.search(rf"(?<!\d){re.escape(t)}(?!\d)", text):
            hits.append(("ticket", t, 3))
    for f in files:
        f = f.strip().lstrip("./")
        if not f:
            continue
        base = os.path.basename(f)
        if f.lower() in low:
            hits.append(("file", f, 2))
        elif base.lower() not in GENERIC and len(base) >= 6 and \
                re.search(rf"(?<![\w.-]){re.escape(base.lower())}(?![\w-])", low):
            hits.append(("file", base, 2))
    for k in keywords:
        k = k.strip()
        if k and re.search(rf"(?<!\w){re.escape(k.lower())}(?!\w)", low):
            hits.append(("keyword", k, 1))
    return sum(h[2] for h in hits), hits


def select(entries, tickets=(), files=(), keywords=()):
    picked = []
    for kind, e in entries:
        s, hits = score(e, tickets, files, keywords)
        if s:
            picked.append({"kind": kind, "id": e["id"], "score": s, "hits": hits, "entry": e})
    picked.sort(key=lambda p: (-p["score"], p["kind"] != "question", _neg_date(p["entry"].get("date"))))
    return picked


def _neg_date(d):
    # newer first: invert the digits of an ISO date so that ascending sort puts the newest first
    return "".join(chr(ord("9") - ord(c) + ord("0")) if c.isdigit() else c for c in str(d or "0000"))


def render_entry(p, short=False):
    e = p["entry"]
    meta = ", ".join(x for x in (e.get("date"), e.get("area"), e.get("owner")) if x)
    why = "; ".join(sorted({f"{k} {v}" for k, v, _ in p["hits"]}))
    lines = [f"- **{e['id']}**" + (f" ({meta})" if meta else "") + f" — matched: {why}"]
    if short:
        # header only, when the full entry does not fit the cap; the id is the pointer to the rest
        return lines[0] + " (full text: register id above)\n"
    main = e.get("decision") if p["kind"] == "decision" else e.get("question")
    if main:
        lines.append(f"  {flatten(main).strip()}")
    for key in ("rationale", "context", "options", "blocks", "refs"):
        if e.get(key):
            lines.append(f"  {key}: {flatten(e[key]).strip()}".replace("\n", " · "))
    return "\n".join(lines) + "\n"


def render(picked, max_bytes, cmd_hint="register-excerpt.py ... --max-bytes 0"):
    out, used = [], 0
    for i, p in enumerate(picked):
        block = render_entry(p)
        size = len(block.encode("utf-8"))
        if max_bytes and used + size > max_bytes:
            # too big in full: fall back to the header line (always for the first entry)
            block = render_entry(p, short=True)
            size = len(block.encode("utf-8"))
            if not out or used + size <= max_bytes:
                out.append(block)
                used += size
                continue
            rest = picked[i:]
            ids = ", ".join(r["id"] for r in rest)
            tail = f"+{len(rest)} weitere: {ids}"
            if len(tail.encode("utf-8")) > 400:
                tail = f"+{len(rest)} weitere (all: {cmd_hint})"
            out.append(tail + "\n")
            break
        out.append(block)
        used += size
    return "".join(out)


# ---------------------------------------------------------------------------------------- selftest

def selftest():
    import tempfile
    ok = fail = 0

    def check(cond, what):
        nonlocal ok, fail
        ok, fail = (ok + 1, fail) if cond else (ok, fail + 1)
        if not cond:
            print(f"FAIL {what}", file=sys.stderr)

    reg = {"open_questions": [{"id": "q-karte-farben", "question": "Welche Farben?", "owner": "alice",
                               "context": "Ticket 10000000001, betrifft kartenstil", "blocks": ["kartenstil"]}],
           "decisions": [
               {"id": "d-old", "date": "2026-01-01", "decision": "Legende bleibt", "refs": ["app/routers/arten.py"]},
               {"id": "d-new", "date": "2026-10-01", "decision": "Legende neu", "rationale": "see arten.py"},
               {"id": "d-ticket", "date": "2026-05-05", "decision": "x", "refs": ["BOARD 10000000001"]},
               {"id": "d-near", "date": "2026-05-05", "decision": "y", "refs": ["100000000011"]},
               {"id": "d-generic", "date": "2026-05-05", "decision": "z", "refs": ["src/__init__.py"]},
               {"id": "d-none", "date": "2026-05-05", "decision": "nothing here"}]}
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(reg, f)
        path = f.name
    try:
        entries = load(path)
        check(len(entries) == 7, "load reads questions and decisions")
        ids = [p["id"] for p in select(entries, tickets=["10000000001"])]
        check(ids == ["q-karte-farben", "d-ticket"], f"ticket match, question first, digit-bounded: {ids}")
        ids = [p["id"] for p in select(entries, files=["app/routers/arten.py", "pkg/__init__.py"])]
        check(ids == ["d-new", "d-old"], f"file by path or basename, newer first, generic ignored: {ids}")
        ids = [p["id"] for p in select(entries, keywords=["legende"])]
        check(set(ids) == {"d-old", "d-new"}, f"keyword whole word case-insensitive: {ids}")
        ids = [p["id"] for p in select(entries, tickets=["10000000001"], keywords=["kartenstil"])]
        check(ids[0] == "q-karte-farben", "combined score ranks the double hit first")
        picked = select(entries, files=["arten.py"], keywords=["legende", "farben"])
        text = render(picked, max_bytes=120)
        check("+2 weitere" in text or "+1 weitere" in text, f"cap names the rest: {text!r}")
        check(len(text.encode()) < 120 + 200, "cap respected (plus the tail line)")
        check("weitere" not in render(picked, 0), "max-bytes 0 is uncapped")
    finally:
        os.unlink(path)
    print(f"register-excerpt selftest: {ok} passed, {fail} failed")
    return 1 if fail else 0


def main():
    if "--selftest" in sys.argv[1:]:
        return selftest()
    ap = argparse.ArgumentParser(prog="register-excerpt.py", description=__doc__.split("\n\n")[0],
                                 epilog="See the module docstring for matching and ranking rules.")
    ap.add_argument("--register")
    ap.add_argument("--ticket", action="append", default=[])
    ap.add_argument("--file", action="append", default=[])
    ap.add_argument("--keyword", action="append", default=[])
    ap.add_argument("--max-bytes", type=int, default=12000)
    ap.add_argument("--json", action="store_true", help="ids, scores and hits instead of text")
    ap.add_argument("--selftest", action="store_true", help="run the offline self test and exit")
    a = ap.parse_args()
    path = a.register or os.environ.get("HERD_REGISTER") or "decisions-questions.json"
    try:
        entries = load(path)
    except (OSError, ValueError) as e:
        print(f"register-excerpt: cannot read {path}: {e}", file=sys.stderr)
        return 2
    picked = select(entries, a.ticket, a.file, a.keyword)
    if a.json:
        print(json.dumps([{k: p[k] for k in ("kind", "id", "score", "hits")} for p in picked],
                         ensure_ascii=False, indent=1))
    else:
        sys.stdout.write(render(picked, a.max_bytes) or "no matching register entries\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
