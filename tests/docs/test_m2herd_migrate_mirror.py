#!/usr/bin/env python3
"""Apply m2herd-migrate to a mirror of a real .m2herd fabric and prove nothing is lost.

  python3 tests/docs/test_m2herd_migrate_mirror.py [<src .m2herd>]

The source is only read. The mirror lives in a temp dir: same tree, same mtimes and modes, every file
emptied except RESUME.md and NOTES.md (copied in full so the splits run on real text); owner-only files
and secret-looking names are never opened, they become empty placeholders. Then: dry run, --apply
(refused while readers exist), --apply --force-readers, and the checks:
  - every file of the mirror still exists afterwards, in the fabric, the cache or the state root,
    except the files inside __pycache__ (the one thing the migration deletes);
  - NOTES.md lines: kept + archived == original; RESUME.md lines: kept + archived == original;
  - INDEX.md has one line per applied action; a second dry run plans no moves, splits or deletions.
Without a source argument a small synthetic fabric is used (same as m2herd-migrate --selftest, but
through the CLI).
"""
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
MIGRATE = os.path.join(HERE, "..", "..", "scripts", "m2herd-migrate")
SECRET = re.compile(r"(env|credential|secret|token|passw)", re.I)
FULL = {"RESUME.md", "NOTES.md"}

ok = fail = 0


def check(name, cond, detail=""):
    global ok, fail
    if cond:
        ok += 1
    else:
        fail += 1
        print(f"FAIL {name}\n{detail[-3000:]}")


def mirror(src, dst):
    for root, dirs, files in os.walk(src):
        rel = os.path.relpath(root, src)
        d = os.path.join(dst, rel) if rel != "." else dst
        os.makedirs(d, exist_ok=True)
        for n in files:
            s = os.path.join(root, n)
            t = os.path.join(d, n)
            st = os.lstat(s)
            if stat.S_ISLNK(st.st_mode):
                os.symlink(os.readlink(s), t)
                continue
            if not stat.S_ISREG(st.st_mode):
                continue
            if rel == "." and n in FULL and not SECRET.search(n):
                shutil.copyfile(s, t)
            else:
                open(t, "w").close()
            os.chmod(t, stat.S_IMODE(st.st_mode))
            os.utime(t, (st.st_atime, st.st_mtime))
    for root, dirs, _ in os.walk(src, topdown=False):  # dir mtimes last, writing files bumped them
        for n in dirs:
            s = os.path.join(root, n)
            t = os.path.join(dst, os.path.relpath(s, src))
            if os.path.isdir(t) and not os.path.islink(s):
                st = os.lstat(s)
                os.utime(t, (st.st_atime, st.st_mtime))
    st = os.lstat(src)
    os.utime(dst, (st.st_atime, st.st_mtime))


def synthetic(dst):
    old = __import__("time").time() - 40 * 86400
    for rel, text, mt in [
        ("RESUME.md", "".join(f"h{i}\n" for i in range(20)) + "## Stand\nx\n### Vorheriger Stand (a)\ny\n", None),
        ("NOTES.md", "<!-- === M2HERD:LIVE === -->\n- [2026-08-01T00:00:00Z] a\n- [2026-10-01T00:00:00Z] b\n", None),
        ("PHASE-NEXT-2026-09-01.md", "p\n", None), ("PHASE-NEXT-2026-10-20.md", "p\n", None),
        ("dispatch/herde-0101/herd.map", "m\n", old), ("dispatch/old.out.md", "o\n", old),
        ("dispatch/screens/s.png", "s", None), ("x.sqlite3", "d", None), ("__pycache__/a.pyc", "c", None)]:
        p = os.path.join(dst, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)
        if mt:
            os.utime(p, (mt, mt))
    os.utime(os.path.join(dst, "dispatch/herde-0101"), (old, old))


def files_under(root):
    out = set()
    for r, dirs, files in os.walk(root):
        for n in files:
            out.add(os.path.join(r, n))
    return out


def lines(p):
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.readlines()


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else None
    tmp = tempfile.mkdtemp(prefix="m2herd-migrate-mirror-")
    try:
        proj = os.path.join(tmp, "proj")
        m = os.path.join(proj, ".m2herd")
        if src:
            mirror(os.path.abspath(src), m)
        else:
            synthetic(m)
        cache, state = os.path.join(tmp, "cache"), os.path.join(tmp, "state")
        readers = os.path.join(tmp, "readers")
        os.makedirs(readers)
        with open(os.path.join(readers, "r.sh"), "w") as f:
            f.write("ls .m2herd/dispatch/screens\n")
        base = [sys.executable, MIGRATE, m, "--readers", readers, "--date", "2026-10-23",
                "--cache-root", cache, "--state-root", state, "--project", "proj"]
        before = files_under(m)
        pyc = {p for p in before if "/__pycache__/" in p}
        notes0 = lines(os.path.join(m, "NOTES.md")) if os.path.exists(os.path.join(m, "NOTES.md")) else []
        resume0 = lines(os.path.join(m, "RESUME.md")) if os.path.exists(os.path.join(m, "RESUME.md")) else []

        dry = subprocess.run(base, capture_output=True, text=True)
        check("dry run exit 0", dry.returncode == 0, dry.stdout + dry.stderr)
        check("dry run changed nothing", files_under(m) == before)
        planned = [ln for ln in dry.stdout.splitlines() if ln.startswith(("MOVE ", "SPLIT ", "DELETE "))]
        refused = subprocess.run(base + ["--apply"], capture_output=True, text=True)
        check("apply refused while readers exist", refused.returncode == 3 and files_under(m) == before,
              refused.stdout)
        ap = subprocess.run(base + ["--apply", "--force-readers"], capture_output=True, text=True)
        check("forced apply exit 0", ap.returncode == 0, ap.stdout + ap.stderr)
        applied = [ln for ln in ap.stdout.splitlines() if ln.startswith(("MOVE ", "SPLIT ", "DELETE "))]
        check("apply ran the dry run's plan", len(applied) == len(planned), f"{len(applied)} vs {len(planned)}")

        after = files_under(m) | files_under(cache) | files_under(state)
        lost = []
        for p in before - pyc:
            if p in after:
                continue
            rel = os.path.relpath(p, m)
            cands = [os.path.join(m, "herden", rel[len("dispatch/"):]) if rel.startswith("dispatch/") else None,
                     os.path.join(cache, "proj", rel[len("dispatch/"):]) if rel.startswith("dispatch/") else None,
                     os.path.join(cache, "proj", rel), os.path.join(state, "proj", rel),
                     os.path.join(m, "archives", "2026-10-23", rel)]
            arch = [q for q in after if q.startswith(os.path.join(m, "archives", "dispatch") + "/")
                    and q.endswith("/" + rel[len("dispatch/"):])] if rel.startswith("dispatch/") else []
            if not any(c and c in after for c in cands) and not arch:
                lost.append(rel)
        check("no file lost (only __pycache__ deleted)", not lost, "\n".join(sorted(lost)[:40]))
        check("__pycache__ gone", not any("/__pycache__/" in p for p in files_under(m)))

        if notes0:
            kept = lines(os.path.join(m, "NOTES.md"))
            arch = []
            nd = os.path.join(m, "archives", "notes")
            for n in sorted(os.listdir(nd)) if os.path.isdir(nd) else []:
                arch += [ln for ln in lines(os.path.join(nd, n))[2:]]  # minus header + blank line
            check("NOTES lines conserved", sorted(kept + arch) == sorted(notes0),
                  f"kept {len(kept)} + archived {len(arch)} vs {len(notes0)}")
        if resume0:
            kept = lines(os.path.join(m, "RESUME.md"))
            rp = os.path.join(m, "archives", "2026-10-23", "RESUME-previous.md")
            arch = lines(rp)[2:] if os.path.exists(rp) else []
            check("RESUME lines conserved", kept + arch == resume0, f"{len(kept)} + {len(arch)} vs {len(resume0)}")
        idx = os.path.join(m, "archives", "2026-10-23", "INDEX.md")
        n_idx = sum(1 for ln in lines(idx) if ln.startswith("- ")) if os.path.exists(idx) else -1
        check("INDEX one line per action", n_idx == len(applied), f"{n_idx} vs {len(applied)}")
        again = subprocess.run(base, capture_output=True, text=True)
        check("second dry run plans nothing", not any(ln.startswith(("MOVE ", "SPLIT ", "DELETE "))
                                                       for ln in again.stdout.splitlines()), again.stdout)
        print(f"mirror: {len(before)} files, {len(planned)} actions planned and applied")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"test_m2herd_migrate_mirror: {ok} passed, {fail} failed")
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
