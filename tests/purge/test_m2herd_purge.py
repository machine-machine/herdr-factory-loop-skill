#!/usr/bin/env python3
"""Offline tests for scripts/m2herd-purge (docs/herd-flow-v2.md §7, weekly purge).

  python3 tests/purge/test_m2herd_purge.py

Everything runs in a temp dir with a temp HOME (so ~/.cache/m2herd is the temp one): a synthetic fabric
with old/new/referenced/unreferenced files, a live herd, a merged herd (old and recent), run data in
the fabric and in the cache, caches, locks and empty dirs. The CLI is driven as a subprocess: dry run,
--apply, a second --apply, the lock, settings precedence, --fabrics, a failing action, usage errors,
and the systemd templates. No network, no herdr, nothing outside the temp dir.
"""
import datetime
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.realpath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
PURGE = os.path.join(REPO, "scripts", "m2herd-purge")
TODAY = datetime.date.today().isoformat()
NOW = time.time()
OLD = NOW - 40 * 86400       # older than archive (30) and run (14) limits
MID = NOW - 5 * 86400        # younger than both, older than the grace (24 h)

ok = fail = 0


def check(name, cond, detail=""):
    global ok, fail
    if cond:
        ok += 1
    else:
        fail += 1
        print(f"FAIL {name}\n{detail[-3000:]}")


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def w(base, rel, text="x\n", mtime=None, mode=None):
    p = os.path.join(base, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        f.write(text)
    if mode is not None:
        os.chmod(p, mode)
    if mtime:
        os.utime(p, (mtime, mtime))
    return p


def ev(slice_, phase, t, by="orchestrator"):
    return json.dumps({"ts": iso(t), "slice": slice_, "phase": phase, "by": by}) + "\n"


def age_dir(p, t):
    os.utime(p, (t, t))


def build(tmp):
    home = os.path.join(tmp, "home")
    proj = os.path.join(tmp, "proj")
    m = os.path.join(proj, ".m2herd")
    cache = os.path.join(home, ".cache", "m2herd", "proj")
    bin_ = os.path.join(tmp, "bin")
    os.makedirs(home)
    month_entry = f"- [{iso(NOW)}] this month: see dispatch/notes-new.md\n"
    # keep list and references from the fabric's own documents
    w(m, "RESUME.md", "# Resume\nnext: dispatch/resume-ref.out.md; the context of this work is long\n", OLD)
    w(m, "NOTES.md", "<!-- header -->\n\n<!-- === M2HERD:LIVE === -->\n"
      "- [2026-01-05T10:00:00Z] old month: see dispatch/notes-old.md\n"
      "- 2026-01-06 11:00 old month, other style: dispatch/notes-old2.md\n" + month_entry, OLD)
    w(m, "PHASE-NEXT-2026-01-01.md", "plan: dispatch/keep-a.md and the lanes/ tree\n", OLD)
    w(m, "checks.sh", "#!/bin/sh\n", OLD, 0o755)
    w(m, "tool.sh", "#!/bin/sh\necho hi\n", OLD, 0o755)
    w(m, "rules/WORKER.md", "rules\n", OLD)
    w(m, "decisions-register.json", "{}\n", OLD)
    w(m, "tickets/events.jsonl", "{}\n", OLD)
    w(m, "queue.sqlite3", "db", OLD)
    w(m, "settings.json", "{}", OLD)
    w(m, "old-top.md", "nobody reads me\n", OLD)
    w(m, "old-top-ref.md", "the project file names me\n", OLD)
    w(m, "private-note.md", "x\n", OLD, 0o600)
    w(m, "context/area/context.md", "words\n", OLD)                  # word-like name, only prose -> archived
    age_dir(os.path.join(m, "context/area"), OLD)
    w(m, "lanes/l1/a.task.md", "t\n", OLD)                           # `lanes/` named in PHASE-NEXT -> kept
    w(proj, "CLAUDE.md", "run python3 .m2herd/old-top-ref.md\n")
    # dispatch: candidates and references
    d = "dispatch/"
    w(m, d + "unused.out.md", "r\n", OLD)
    w(m, d + "fresh.out.md", "r\n")
    w(m, d + "resume-ref.out.md", "r\n", OLD)
    w(m, d + "notes-old.md", "r\n", OLD)
    w(m, d + "notes-old2.md", "r\n", OLD)
    w(m, d + "notes-new.md", "r\n", OLD)
    w(m, d + "tool-ref.md", "r\n", OLD)
    w(m, d + "private-ref.md", "r\n", OLD)
    w(m, d + "secret-ref.md", "r\n", OLD)
    w(m, "keepme.md", "see dispatch/private-ref.md\n", None, 0o600)        # owner-only, recent: still a reader
    w(m, "api-token.md", "see dispatch/secret-ref.md\n")                    # secret-looking name: never read
    w(m, d + "chain-a.md", "see dispatch/chain-b.md\n", OLD)                # both old: both archived
    w(m, d + "chain-b.md", "r\n", OLD)
    w(m, d + "keep-a.md", "see dispatch/keep-b.md\n", OLD)                  # kept by PHASE-NEXT ...
    w(m, d + "keep-b.md", "r\n", OLD)                                       # ... so its reference counts
    w(m, d + "sib-a.md", "see sib-b.md next to me\n")                        # recent, names a sibling by name
    w(m, d + "sib-b.md", "r\n", OLD)
    w(m, d + "olddir/x.md", "r\n", OLD)
    w(m, d + "olddir/y.md", "r\n", OLD)
    age_dir(os.path.join(m, d + "olddir"), OLD)
    w(m, d + "held.md", "r\n", OLD)
    w(m, d + "live-ref.md", "r\n", OLD)
    # herds
    h = d + "herde-0101/"                                                   # merged 20 d ago, all old
    w(m, h + "a.task.md", "t\n", OLD)
    w(m, h + "herd.events.jsonl", ev("a", "working", OLD) + ev("a", "merged", NOW - 20 * 86400, "merge"), OLD)
    w(m, h + "screens/s.png", "png", MID)
    h = d + "herde-0202/"                                                   # merged 3 d ago
    w(m, h + "a.task.md", "t\n", MID)
    w(m, h + "herd.events.jsonl", ev("a", "merged", NOW - 3 * 86400, "merge"), MID)
    w(m, h + "screens/t.png", "png", MID)
    h = d + "herde-0303/"                                                   # live: still working
    w(m, h + "a.task.md", "needs dispatch/live-ref.md\n", OLD)
    w(m, h + "herd.events.jsonl", ev("a", "working", OLD, "watch"), OLD)
    w(m, h + "screens/u.png", "png", OLD)
    w(m, h + "x.lock", "", OLD)
    age_dir(os.path.join(m, h), OLD)
    w(m, d + "herde-0404/herd.map", "x\n")                                  # v1, fresh -> live
    # run data in the fabric
    w(m, d + "screens/s-old/1.png", "png" * 100, OLD)
    w(m, d + "screens/s-mid/1.png", "png", MID)
    w(m, d + "screens/s-new/1.png", "png")
    w(m, "loop/runs/README.md", "r\n", OLD)
    w(m, "loop/runs/CURRENT", "r-cur")
    w(m, "loop/runs/r-cur/run.json", "{}", OLD)
    w(m, "loop/runs/r-old/run.json", "{}", OLD)
    w(m, "loop/plan.md", "p\n")                                              # keeps loop/ itself recent
    w(m, "backups/b-old.tar", "b", OLD)
    w(m, "backups/b-mid.tar", "b", MID)
    # caches, locks, empty dirs
    w(m, "dispatch/__pycache__/x.cpython.pyc", "c")
    w(m, "stray.pyc", "c")
    w(m, "stale.lock", "", OLD)
    w(m, "fresh-base.json", "{}")
    w(m, "fresh-base.json.lock", "", OLD)
    w(m, "busy.lock", "", OLD)
    os.makedirs(os.path.join(m, "empty-old"))
    age_dir(os.path.join(m, "empty-old"), OLD)
    os.makedirs(os.path.join(m, "empty-new"))
    w(m, "area2/context.md", "deep: ./deep/\n")
    os.makedirs(os.path.join(m, "area2/deep"))
    age_dir(os.path.join(m, "area2/deep"), OLD)
    os.makedirs(os.path.join(m, "rules/empty"))
    age_dir(os.path.join(m, "rules/empty"), OLD)
    # an archived herd from an earlier run whose run data is still in the cache
    w(m, "archives/2026-01-01/dispatch/herde-0505/herd.events.jsonl",
      ev("a", "merged", NOW - 20 * 86400, "merge"), OLD)
    w(m, "archives/2026-01-01/INDEX.md", "- old\n", OLD)
    # cache
    w(cache, "screens/README.md", "r\n", OLD)
    w(cache, "screens/c-old/1.png", "png" * 50, OLD)
    w(cache, "screens/c-mid/1.png", "png", MID)
    w(cache, "herden/herde-0505/screens/1.png", "png", MID)                 # archived herd merged 20 d ago
    w(cache, "herden/herde-0303/screens/1.png", "png", OLD)                 # live herd
    w(cache, "herden/herde-9999/screens/1.png", "png", OLD)                 # herd unknown -> mtime
    w(cache, "herden/herde-9998/screens/1.png", "png", MID)
    w(cache, "worker.log", "l\n", OLD)
    w(cache, "other/stuff.txt", "s\n", OLD)                                 # not run data -> untouched
    w(bin_, "tool", "cat $HOME/proj/.m2herd/dispatch/tool-ref.md\n")
    return home, proj, m, cache, bin_


def env_for(home, extra=None):
    e = {k: v for k, v in os.environ.items() if not k.startswith(("HERD_PURGE_", "M2HERD_"))}
    e.update({"HOME": home, "PYTHONDONTWRITEBYTECODE": "1", "LC_ALL": "C.UTF-8"})
    e.update(extra or {})
    return e


def cli(args, home, extra=None):
    r = subprocess.run([sys.executable, PURGE] + args, capture_output=True, text=True, env=env_for(home, extra))
    return r.returncode, r.stdout + r.stderr


def snapshot(root):
    out = set()
    for r, _, files in os.walk(root):
        for f in files:
            out.add(os.path.relpath(os.path.join(r, f), root))
    return out


def hold(path, kind):
    """A child process that keeps `path` open (kind=open) or flocked (kind=flock) until killed."""
    code = {"open": "import sys,time;f=open(sys.argv[1]);print('ok',flush=True);time.sleep(60)",
            "flock": "import fcntl,os,sys,time;fd=os.open(sys.argv[1],os.O_RDONLY);"
                     "fcntl.flock(fd,fcntl.LOCK_EX);print('ok',flush=True);time.sleep(60)"}[kind]
    p = subprocess.Popen([sys.executable, "-c", code, path], stdout=subprocess.PIPE, text=True)
    p.stdout.readline()
    return p


def main():
    tmp = tempfile.mkdtemp(prefix="m2herd-purge-test-")
    kids = []
    try:
        home, proj, m, cache, bin_ = build(tmp)
        base = [m, "--readers", bin_, "--date", TODAY]
        kids.append(hold(os.path.join(m, "dispatch/held.md"), "open"))
        kids.append(hold(os.path.join(m, "busy.lock"), "open"))
        before = snapshot(m)
        cache_before = snapshot(cache)

        # ------------------------------------------------------------------ dry run
        rc, txt = cli(base, home)
        plan = txt.split("totals")[0]
        check("dry run exit 0", rc == 0, txt)
        check("dry run changed nothing", snapshot(m) == before and snapshot(cache) == cache_before, txt)
        A = f"archives/{TODAY}/"
        archived = [ln.split()[1] for ln in plan.splitlines() if ln.startswith("ARCHIVE")]
        for rel in ("dispatch/unused.out.md", "dispatch/notes-old.md", "dispatch/notes-old2.md", "old-top.md",
                    "dispatch/chain-a.md", "dispatch/chain-b.md", "dispatch/olddir/", "context/",
                    "dispatch/herde-0101/", "private-note.md", "dispatch/secret-ref.md"):
            check(f"archive {rel}", rel in archived, plan)
        check("archive keeps the path", f"ARCHIVE dispatch/unused.out.md -> {A}dispatch/unused.out.md" in plan, plan)
        check("archive dir counts files", "dispatch/olddir/ -> " in plan and "2 files" in plan, plan)
        for rel, why in (("dispatch/fresh.out.md", "recent"), ("dispatch/resume-ref.out.md", "RESUME"),
                         ("dispatch/notes-new.md", "NOTES current month"), ("dispatch/tool-ref.md", "reader root"),
                         ("old-top-ref.md", "project file"), ("dispatch/keep-a.md", "PHASE-NEXT"),
                         ("dispatch/keep-b.md", "kept reader"), ("dispatch/sib-b.md", "sibling by name"),
                         ("dispatch/live-ref.md", "live herd"), ("dispatch/private-ref.md", "owner-only reader"),
                         ("lanes/", "word + slash"), ("RESUME.md", "keep"), ("NOTES.md", "keep"),
                         ("PHASE-NEXT-2026-01-01.md", "keep"), ("checks.sh", "keep"), ("tool.sh", "script"),
                         ("rules/", "keep"), ("decisions-register.json", "register"), ("tickets/", "jsonl"),
                         ("queue.sqlite3", "state"), ("settings.json", "engine"), ("dispatch/herde-0303/", "live"),
                         ("dispatch/herde-0404/", "live v1"), ("dispatch/herde-0202/", "recent herd")):
            check(f"keep {rel} ({why})", rel not in archived, plan)
        check("held file skipped", "SKIP    dispatch/held.md — in use by pid" in plan, plan)
        # run data in the fabric
        check("old screens deleted in place", "DELETE  dispatch/screens/s-old/" in plan, plan)
        check("mid screens moved", "MOVE    dispatch/screens/s-mid/ -> ~/.cache/m2herd/proj/screens/s-mid/" in plan, plan)
        check("fresh screens stay", "s-new" not in plan, plan)
        check("merged herd: screens deleted (merged 20 d ago)", "DELETE  dispatch/herde-0101/screens/s.png" in plan, plan)
        check("recent herd: screens to cache/herden", "MOVE    dispatch/herde-0202/screens/t.png -> "
              "~/.cache/m2herd/proj/herden/herde-0202/screens/t.png" in plan, plan)
        check("live herd untouched", "herde-0303/screens" not in plan and "herde-0303/x.lock" not in plan, plan)
        check("runs: CURRENT run and README stay", "r-cur" not in plan and "runs/README" not in plan
              and "runs/CURRENT" not in plan and "DELETE  loop/runs/r-old/" in plan, plan)
        check("backups", "DELETE  backups/b-old.tar" in plan
              and "MOVE    backups/b-mid.tar -> ~/.cache/m2herd/proj/backups/b-mid.tar" in plan, plan)
        # caches
        check("pycache", "DELETE  dispatch/__pycache__/" in plan, plan)
        check("stray pyc", "DELETE  stray.pyc" in plan, plan)
        check("stale lock", "DELETE  stale.lock" in plan, plan)
        check("lock with fresh base kept", "fresh-base.json.lock" not in plan, plan)
        check("held lock skipped", "SKIP    busy.lock — in use" in plan, plan)
        check("empty old dir", "RMDIR   empty-old/  [empty]" in plan, plan)
        check("empty fresh dir kept", "empty-new" not in plan, plan)
        check("empty dir named by a sibling kept", "area2/deep" not in plan, plan)
        check("empty dir in rules kept", "rules/empty" not in plan, plan)
        check("archives untouched", "archives/2026-01-01" not in plan, plan)
        # cache retention
        check("cache old deleted", "DELETE  ~/.cache/m2herd/proj/screens/c-old/" in plan, plan)
        check("cache mid kept", "c-mid" not in plan and "screens/README" not in plan, plan)
        check("cache herd of archived merged herd deleted", "DELETE  ~/.cache/m2herd/proj/herden/herde-0505/" in plan
              and "merged" in plan.split("herde-0505/")[1].splitlines()[0], plan)
        check("cache herd of live herd kept", "herden/herde-0303" not in plan, plan)
        check("cache unknown herd by mtime", "herden/herde-9999/" in plan and "herde-9998" not in plan, plan)
        check("cache top-level log", "DELETE  ~/.cache/m2herd/proj/worker.log" in plan, plan)
        check("cache non-run data untouched", "other/stuff" not in plan, plan)
        check("totals printed", "freed from disk (deleted)" in txt and "archived in the fabric" in txt, txt)

        rc, vtxt = cli(base + ["--verbose"], home)
        check("verbose names the reader", "KEEP    dispatch/tool-ref.md — referenced by" in vtxt
              and "KEEP    dispatch/herde-0303 — live herd" in vtxt, vtxt)
        rc, stxt = cli(base + ["--summary"], home)
        check("summary has no action lines", "ARCHIVE" not in stxt and "totals" in stxt, stxt)

        # ------------------------------------------------------------------ lock
        locker = hold(m, "flock")
        try:
            rc, ltxt = cli(base + ["--apply"], home)
            check("second run refused while one holds the lock", rc == 2 and "holds" in ltxt
                  and snapshot(m) == before, ltxt)
        finally:
            locker.kill()
            locker.wait()

        # ------------------------------------------------------------------ apply
        rc, txt = cli(base + ["--apply"], home)
        check("apply exit 0", rc == 0, txt)
        after = snapshot(m)
        cache_after = snapshot(cache)
        n_arch = sum(1 for ln in txt.split("totals")[0].splitlines() if ln.startswith("ARCHIVE"))
        with open(os.path.join(m, A, "INDEX.md"), encoding="utf-8") as f:
            idx = f.read()
        lines = [ln for ln in idx.splitlines() if ln.startswith("- ")]
        check("INDEX one line per archived entry", len(lines) == n_arch and n_arch > 0, idx)
        check("INDEX line has path, size, last modified, why", any(
            ln.startswith("- dispatch/unused.out.md (") and "last modified" in ln and "no reader" in ln
            for ln in lines), idx)
        # nothing in the fabric is deleted except caches and run data
        cachey = lambda r: "__pycache__" in r or r.endswith((".pyc", ".lock"))
        rundata = lambda r: r.startswith(("dispatch/screens/", "backups/", "loop/runs/")) or "/screens/" in r
        lost = [r for r in before if not cachey(r) and not rundata(r)
                and r not in after and os.path.join(A, r) not in after]
        check("no fabric file lost (only caches and run data leave)", not lost, "\n".join(lost))
        check("archived file is in archives", os.path.join(A, "dispatch/olddir/x.md") in after, "\n".join(sorted(after)))
        check("moved run data in the cache", "screens/s-mid/1.png" in cache_after
              and "herden/herde-0202/screens/t.png" in cache_after and "backups/b-mid.tar" in cache_after,
              "\n".join(sorted(cache_after)))
        check("old run data gone", "dispatch/screens/s-old/1.png" not in after and "screens/c-old/1.png" not in cache_after
              and "herden/herde-0505/screens/1.png" not in cache_after and "worker.log" not in cache_after)
        check("current run kept", "loop/runs/r-cur/run.json" in after and "loop/runs/CURRENT" in after)
        check("live herd intact", {r for r in before if r.startswith("dispatch/herde-0303/")}
              <= after, "\n".join(sorted(after)))
        check("held file still in place", "dispatch/held.md" in after)
        check("empty dir removed", not os.path.exists(os.path.join(m, "empty-old"))
              and os.path.isdir(os.path.join(m, "empty-new")) and os.path.isdir(os.path.join(m, "area2/deep")))
        with open(os.path.join(m, "NOTES.md"), encoding="utf-8") as f:
            notes = f.read()
        check("one NOTES line with the totals", notes.count("m2herd-purge:") == 1 and "archived" in notes
              and notes.rstrip().splitlines()[-1].startswith("- ["), notes)

        rc, txt2 = cli(base + ["--apply"], home)
        with open(os.path.join(m, "NOTES.md"), encoding="utf-8") as f:
            notes2 = f.read()
        check("second apply has nothing to do", rc == 0 and "nothing to apply" in txt2, txt2)
        check("no NOTES line when nothing changed", notes2 == notes, notes2)
    finally:
        for k in kids:
            k.kill()
            k.wait()
        shutil.rmtree(tmp, ignore_errors=True)

    settings_and_fabrics()
    failing_action()
    usage_and_templates()
    not_a_fabric()
    flock_only_locks()
    engine_run_store()
    print(f"m2herd-purge tests: {ok} passed, {fail} failed")
    return 0 if fail == 0 else 1


def not_a_fabric():
    """A project root passed instead of <proj>/.m2herd (a typo in the weekly fabrics list) is refused:
    its backups/, logs/, screens/ dirs are project data, not fabric run data."""
    tmp = tempfile.mkdtemp(prefix="m2herd-purge-test-")
    try:
        home = os.path.join(tmp, "home")
        os.makedirs(home)
        proj = os.path.join(tmp, "proj")
        os.makedirs(os.path.join(proj, ".m2herd"))
        files = [w(proj, rel, "x\n", OLD) for rel in
                 ("src/logs/app.log", "backups/db.dump", "data/screens/x/1.png", "README.md")]
        before = snapshot(proj)
        rc, txt = cli([proj, "--readers", "", "--date", TODAY, "--apply"], home)
        check("project root is refused (exit 2)", rc == 2 and "not a .m2herd fabric" in txt
              and os.path.join(proj, ".m2herd") in txt, txt)
        check("project root: nothing deleted, moved or written", snapshot(proj) == before
              and all(os.path.isfile(f) for f in files), txt)
        bare = os.path.join(tmp, "plain")
        w(bare, "logs/old.log", "x\n", OLD)
        lst = w(tmp, "fabrics", f"{bare}\n{small_fabric(tmp, 'p9')}\n")
        rc, txt = cli(["--fabrics", lst, "--readers", "", "--date", TODAY, "--apply"], home)
        check("--fabrics: a non-fabric line is refused, the others still run",
              rc == 2 and "not a .m2herd fabric" in txt and "p9/.m2herd" in txt
              and os.path.isfile(os.path.join(bare, "logs/old.log")), txt)
        link = os.path.join(tmp, "fabric-link")
        os.symlink(os.path.join(tmp, "p9", ".m2herd"), link)
        rc, txt = cli([link, "--readers", "", "--date", TODAY], home)
        check("a symlink to a .m2herd dir is a fabric", rc == 0 and "not a .m2herd fabric" not in txt, txt)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def flock_only_locks():
    """A flock-only lock (opened "a", flocked, never written) keeps its creation mtime although the
    gate hook takes it on every prompt: in a quiet fabric lock and base are both days old. Such a lock
    must stay while its base exists; only an orphaned lock (base gone) is a cache."""
    tmp = tempfile.mkdtemp(prefix="m2herd-purge-test-")
    try:
        home = os.path.join(tmp, "home")
        os.makedirs(home)
        m = small_fabric(tmp, "p8")
        for rel in ("inbox/STEER.md", "inbox/steer.ledger.jsonl", "NOTES.md"):
            w(m, rel, "x\n", MID)
            w(m, rel + ".lock", "", MID)
        w(m, "inbox/gone.json.lock", "", MID)
        rc, txt = cli([m, "--readers", "", "--date", TODAY, "--apply"], home)
        plan = txt.split("totals")[0]
        check("flock-only locks of existing files stay", rc == 0 and ".lock" not in plan.replace("gone.json.lock", "")
              and all(os.path.isfile(os.path.join(m, r + ".lock"))
                      for r in ("inbox/STEER.md", "inbox/steer.ledger.jsonl", "NOTES.md")), txt)
        check("orphaned old lock is deleted", "DELETE  inbox/gone.json.lock" in plan
              and not os.path.exists(os.path.join(m, "inbox/gone.json.lock")), txt)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def engine_run_store():
    """The fabric's top-level runs/ is the engine's run store: `m2herd evolve --run <id>` globs
    .m2herd/runs/r-* and m2herd-up writes slice status there, so purge never moves it (review PR #28)."""
    tmp = tempfile.mkdtemp(prefix="m2herd-purge-test-")
    try:
        home = os.path.join(tmp, "home")
        os.makedirs(home)
        m = small_fabric(tmp, "p7")
        w(m, "runs/CURRENT", "r-B\n", OLD)
        w(m, "runs/r-A/run.json", "{}\n", OLD)
        w(m, "runs/r-B/run.json", "{}\n", OLD)
        rc, txt = cli([m, "--readers", "", "--date", TODAY, "--apply"], home)
        plan = txt.split("totals")[0]
        check("engine run store stays in the fabric", rc == 0 and "runs/r-A" not in plan
              and os.path.isfile(os.path.join(m, "runs/r-A/run.json")), txt)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def small_fabric(tmp, name):
    m = os.path.join(tmp, name, ".m2herd")
    w(m, "dispatch/old.md", "r\n", OLD)
    w(m, "RESUME.md", "r\n")
    return m


def settings_and_fabrics():
    tmp = tempfile.mkdtemp(prefix="m2herd-purge-test-")
    try:
        home = os.path.join(tmp, "home")
        os.makedirs(home)
        m = small_fabric(tmp, "p1")
        w(m, "rules/purge.env", "# project override\nHERD_PURGE_ARCHIVE_DAYS=60\nUNRELATED=1\n")
        arg = [m, "--readers", "", "--date", TODAY]
        rc, txt = cli(arg, home)
        check("purge.env raises the archive age", rc == 0 and "dispatch/old.md" not in txt.split("totals")[0]
              and "archive 60 d" in txt, txt)
        rc, txt = cli(arg, home, {"HERD_PURGE_ARCHIVE_DAYS": "10"})
        check("environment beats purge.env", "ARCHIVE dispatch/old.md" in txt and "archive 10 d" in txt, txt)
        rc, txt = cli(arg + ["--archive-days", "100"], home, {"HERD_PURGE_ARCHIVE_DAYS": "10"})
        check("command line beats environment", "dispatch/old.md" not in txt.split("totals")[0], txt)
        rc, txt = cli(arg, home, {"HERD_PURGE_ARCHIVE_DAYS": "soon"})
        check("bad setting is a usage error", rc == 2 and "not a number" in txt, txt)
        m2 = small_fabric(tmp, "p2")
        lst = w(tmp, "fabrics", f"# weekly\n{m}\n{m2}   # second\n{os.path.join(tmp, 'gone', '.m2herd')}\n")
        rc, txt = cli(["--fabrics", lst, "--readers", "", "--date", TODAY], home)
        check("--fabrics runs every fabric", txt.count("m2herd-purge: ") >= 3 and "p2/.m2herd (dry run)" in txt, txt)
        check("--fabrics: a missing fabric makes exit 2", rc == 2 and "no directory" in txt, txt)
        check("--fabrics: dry run changed nothing", os.path.isfile(os.path.join(m2, "dispatch/old.md")))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def failing_action():
    if os.geteuid() == 0:
        print("skip failing_action (root ignores permissions)")
        return
    tmp = tempfile.mkdtemp(prefix="m2herd-purge-test-")
    try:
        home = os.path.join(tmp, "home")
        os.makedirs(home)
        m = small_fabric(tmp, "p3")
        w(m, "dispatch/old2.md", "r\n", OLD)
        arch = os.path.join(m, "archives", TODAY)
        os.makedirs(arch)
        os.chmod(arch, 0o500)
        try:
            rc, txt = cli([m, "--readers", "", "--date", TODAY, "--apply"], home)
        finally:
            os.chmod(arch, 0o700)
        check("a failed action makes exit 1", rc == 1 and "FAILED  dispatch/old" in txt, txt)
        check("failed move keeps the source", os.path.isfile(os.path.join(m, "dispatch/old.md")))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def usage_and_templates():
    home = tempfile.mkdtemp(prefix="m2herd-purge-home-")
    try:
        rc, txt = cli(["--help"], home)
        check("--help exit 0 and documents the exit codes", rc == 0 and "Exit: 0" in txt and "--apply" in txt, txt)
        rc, txt = cli([], home)
        check("no fabric is a usage error", rc == 2, txt)
        rc, txt = cli([home, "--date", "23.10.2026"], home)
        check("bad date is a usage error", rc == 2, txt)
        rc, txt = cli(["--selftest"], home)
        check("selftest passes", rc == 0 and "0 failed" in txt, txt)
    finally:
        shutil.rmtree(home, ignore_errors=True)
    sysd = os.path.join(REPO, "templates", "systemd")
    with open(os.path.join(sysd, "m2herd-purge.timer"), encoding="utf-8") as f:
        timer = f.read()
    with open(os.path.join(sysd, "m2herd-purge.service"), encoding="utf-8") as f:
        svc = f.read()
    check("timer weekly + persistent", "OnCalendar=weekly" in timer and "Persistent=true" in timer
          and "WantedBy=timers.target" in timer, timer)
    check("service runs the purge for every listed fabric", "Type=oneshot" in svc
          and "m2herd-purge --apply --fabrics %h/.config/m2herd/fabrics" in svc, svc)
    with open(os.path.join(REPO, "docs", "herd-flow-v2.md"), encoding="utf-8") as f:
        doc = f.read()
    sec = doc.split("## 7.", 1)[1] if "## 7." in doc else ""
    check("docs §7 documents the purge", all(k in sec for k in (
        "m2herd-purge", "HERD_PURGE_RUN_DAYS", "HERD_PURGE_ARCHIVE_DAYS", "rules/purge.env", "crontab",
        "templates/systemd/")), sec[-2000:])


if __name__ == "__main__":
    sys.exit(main())
