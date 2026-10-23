"""Temp-dir world for the mergectx tests: bare origin repos, slice worktrees, a herd dir, a fake gh."""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.normpath(os.path.join(HERE, "..", "..", "scripts"))
sys.path.insert(0, SCRIPTS)
import herd_events as he  # noqa: E402


class World:
    def __init__(self):
        self.tmp = tempfile.mkdtemp(prefix="mergectx-")
        self.bin = os.path.join(self.tmp, "bin")
        self.herd = os.path.join(self.tmp, "herd")
        self.wtroot = os.path.join(self.tmp, "wt")
        for d in (self.bin, self.herd, self.wtroot):
            os.makedirs(d)
        self.state = os.path.join(self.tmp, "gh-state.json")
        with open(self.state, "w") as f:
            json.dump({"repos": {}, "log": []}, f)
        with open(os.path.join(self.bin, "gh"), "w") as f:
            f.write(f"#!/bin/sh\nexec {sys.executable} {os.path.join(HERE, 'fake_gh.py')} \"$@\"\n")
        os.chmod(os.path.join(self.bin, "gh"), 0o755)
        # a sealed PATH: the fake gh plus git and python only — never the real gh, herdr or lage
        sysbin = os.path.join(self.tmp, "sysbin")
        os.makedirs(sysbin)
        for tool in ("git", "python3"):
            os.symlink(os.path.realpath(shutil.which(tool)), os.path.join(sysbin, tool))
        self.env = dict(os.environ, PATH=f"{self.bin}:{sysbin}", FAKE_GH_STATE=self.state,
                        HERD_WT_ROOT=self.wtroot, HERD_ORG="acme", HERD_MERGE_POLL="0", HERD_MERGE_TRIES="3",
                        GIT_CONFIG_NOSYSTEM="1", PYTHONDONTWRITEBYTECODE="1", GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
                        GIT_COMMITTER_EMAIL="t@t")
        self.env.pop("HERD_BOARD_ORG", None)
        for k in ("HERD_MERGE_ORDER", "HERD_REGISTER", "HERD_MEMORY_DIR", "HERD_RULES_DIR", "HERD_ORCH_NAME",
                  "HERD_ORCH_PANE", "HERD_CLASH_EXCLUDE"):
            self.env.pop(k, None)
        self._pr = {}

    def close(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    # ------------------------------------------------------------------ git
    def sh(self, cwd, *args, check=True):
        p = subprocess.run(args, cwd=cwd, env=self.env, capture_output=True, text=True)
        if check and p.returncode:
            raise AssertionError(f"{args}: {p.stderr}")
        return p.stdout.strip()

    def repo(self, name, files):
        """Bare origin acme/<name> with `files` on main."""
        bare = os.path.join(self.tmp, f"{name}.git")
        self.sh(self.tmp, "git", "init", "-q", "--bare", "-b", "main", bare)
        seed = os.path.join(self.tmp, f"seed-{name}")
        self.sh(self.tmp, "git", "clone", "-q", bare, seed)
        self.write(seed, files)
        self.sh(seed, "git", "add", "-A")
        self.sh(seed, "git", "commit", "-qm", "seed")
        self.sh(seed, "git", "push", "-q", "origin", "HEAD:main")
        st = self.gh_state()
        st["repos"][f"acme/{name}"] = {"bare": bare, "prs": {}}
        self.save_gh(st)
        self._pr[name] = 0
        return bare

    @staticmethod
    def write(wt, files):
        for path, text in files.items():
            full = os.path.join(wt, path)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w") as f:
                f.write(text)

    def worktree(self, repo, slice_name, branch, base="main"):
        wt = os.path.join(self.wtroot, repo, slice_name)
        self.sh(self.tmp, "git", "clone", "-q", os.path.join(self.tmp, f"{repo}.git"), wt)
        self.sh(wt, "git", "checkout", "-qb", branch, f"origin/{base}")
        return wt

    def commit(self, wt, files, msg="change"):
        self.write(wt, files)
        self.sh(wt, "git", "add", "-A")
        self.sh(wt, "git", "commit", "-qm", msg)
        self.sh(wt, "git", "push", "-q", "-u", "origin", "HEAD")
        return self.sh(wt, "git", "rev-parse", "HEAD")

    def main_sha(self, repo):
        return self.sh(self.tmp, "git", "-C", os.path.join(self.tmp, f"{repo}.git"), "rev-parse", "refs/heads/main")

    # ------------------------------------------------------------------ gh state
    def gh_state(self):
        with open(self.state) as f:
            return json.load(f)

    def save_gh(self, st):
        with open(self.state, "w") as f:
            json.dump(st, f, indent=1)

    def open_pr(self, repo, head, base="main", **extra):
        st = self.gh_state()
        n = str(len(st["repos"][f"acme/{repo}"]["prs"]) + 1)
        st["repos"][f"acme/{repo}"]["prs"][n] = dict({"head": head, "base": base, "state": "OPEN",
                                                       "mergeable": None, "merge_commit": None}, **extra)
        self.save_gh(st)
        return int(n)

    def pr(self, repo, n):
        return self.gh_state()["repos"][f"acme/{repo}"]["prs"][str(n)]

    def set_pr(self, repo, n, **kv):
        st = self.gh_state()
        st["repos"][f"acme/{repo}"]["prs"][str(n)].update(kv)
        self.save_gh(st)

    def calls(self, prefix=None):
        log = self.gh_state()["log"]
        return [c for c in log if prefix is None or c[:len(prefix)] == prefix]

    # ------------------------------------------------------------------ herd
    def slice(self, name, repos, header=None, phase="review_ok", prs=None, mains=None):
        """repos: list of (repo, branch, base); writes task.md + .repos and events up to `phase`."""
        hdr = "".join(f"{k}: {v}\n" for k, v in (header or {}).items()) or "model: claude-opus-5-5\n"
        with open(os.path.join(self.herd, f"{name}.task.md"), "w") as f:
            f.write(hdr + f"\n# {name} task\n\nDo the {name} thing.\n")
        with open(os.path.join(self.herd, f"{name}.repos"), "w") as f:
            for r, b, base in repos:
                f.write(f"{r} {b} {base}\n")
        wts = [os.path.join(self.wtroot, r, name) for r, _, _ in repos]
        chain = ["working", "accepted", "review_running", "review_ok"]
        for ph in chain[:chain.index(phase) + 1] if phase in chain else ["working", phase]:
            fields = {"wt": wts} if ph == "working" else {}
            if ph == "review_ok":
                fields.update(prs=prs or [], main=mains or [], run_id="t", lows=[])
            if ph == "accepted":
                fields.update(prs=prs or [], checks=[])
            if ph == "parked":
                fields.update(reason="test")
            he.append(self.herd, name, ph, **fields)

    def fake_tool(self, name, script):
        path = os.path.join(self.bin, name)
        with open(path, "w") as f:
            f.write("#!/bin/sh\n" + script)
        os.chmod(path, 0o755)

    def run(self, script, *args):
        p = subprocess.run([sys.executable, os.path.join(SCRIPTS, script), *args], env=self.env,
                           capture_output=True, text=True)
        return p.returncode, p.stdout, p.stderr
