#!/usr/bin/env python3
"""Offline stand-in for the `gh` subcommands herd-merge uses, backed by local bare git repos.

State file ($FAKE_GH_STATE, JSON):
  {"repos": {"acme/api": {"bare": "/tmp/.../api.git",
                          "prs": {"1": {"head": "feat-a", "base": "main", "state": "OPEN",
                                        "mergeable": null, "fail_merge": false, "merge_commit": null}}}},
   "log": [[argv...], ...]}
Like GitHub: a PR whose base branch is deleted is CLOSED; mergeable is computed with
`git merge-tree --write-tree` unless "mergeable" overrides it; squash merge = one commit on base.
"""
import json
import os
import subprocess
import sys

STATE = os.environ["FAKE_GH_STATE"]


def load():
    with open(STATE) as f:
        return json.load(f)


def save(st):
    with open(STATE, "w") as f:
        json.dump(st, f, indent=1)


def git(bare, *args, check=True):
    p = subprocess.run(["git", "-C", bare, *args], capture_output=True, text=True)
    if check and p.returncode:
        sys.exit(f"fake gh: git {args}: {p.stderr}")
    return p


def ref(bare, branch):
    p = git(bare, "rev-parse", "-q", "--verify", f"refs/heads/{branch}", check=False)
    return p.stdout.strip() if p.returncode == 0 else None


def settle(repo):
    """Close open PRs whose base branch is gone (GitHub behaviour)."""
    for pr in repo["prs"].values():
        if pr["state"] == "OPEN" and not ref(repo["bare"], pr["base"]):
            pr["state"] = "CLOSED"


def mergeable(repo, pr):
    if pr.get("mergeable"):
        return pr["mergeable"]
    b, h = ref(repo["bare"], pr["base"]), ref(repo["bare"], pr["head"])
    if not (b and h):
        return "UNKNOWN"
    p = git(repo["bare"], "merge-tree", "--write-tree", b, h, check=False)
    return "MERGEABLE" if p.returncode == 0 else "CONFLICTING"


def view(repo, n):
    pr = repo["prs"][str(n)]
    head = ref(repo["bare"], pr["head"]) or pr.get("last_head")
    if head:
        pr["last_head"] = head
    return {"number": int(n), "state": pr["state"], "headRefName": pr["head"], "headRefOid": head,
            "baseRefName": pr["base"], "mergeable": mergeable(repo, pr) if pr["state"] == "OPEN" else "UNKNOWN",
            "mergeStateStatus": "CLEAN", "url": f"https://example.invalid/pull/{n}",
            "mergeCommit": {"oid": pr["merge_commit"]} if pr.get("merge_commit") else None}


def opt(args, name):
    return args[args.index(name) + 1] if name in args else None


def main():
    args = sys.argv[1:]
    st = load()
    st.setdefault("log", []).append(args)
    for r in st["repos"].values():
        settle(r)
    out = None
    if args[:2] == ["pr", "view"]:
        out = view(st["repos"][opt(args, "--repo")], args[2])
    elif args[:2] == ["pr", "list"]:
        repo = st["repos"][opt(args, "--repo")]
        base, head = opt(args, "--base"), opt(args, "--head")
        out = [{"number": int(n), "headRefName": p["head"]} for n, p in sorted(repo["prs"].items())
               if p["state"] == "OPEN" and (base is None or p["base"] == base) and (head is None or p["head"] == head)]
    elif args[:2] == ["pr", "merge"]:
        repo = st["repos"][opt(args, "--repo")]
        pr = repo["prs"][args[2]]
        v = view(repo, args[2])
        want = opt(args, "--match-head-commit")
        if pr.get("fail_merge") or v["state"] != "OPEN" or v["mergeable"] != "MERGEABLE" or \
                (want and want != v["headRefOid"]) or "--squash" not in args:
            save(st)
            sys.exit(f"fake gh: cannot merge #{args[2]}: {v['state']} {v['mergeable']}")
        b = ref(repo["bare"], pr["base"])
        tree = git(repo["bare"], "merge-tree", "--write-tree", b, v["headRefOid"]).stdout.split()[0]
        c = git(repo["bare"], "commit-tree", tree, "-p", b, "-m", f"squash #{args[2]}").stdout.strip()
        git(repo["bare"], "update-ref", f"refs/heads/{pr['base']}", c, b)
        pr["state"], pr["merge_commit"] = "MERGED", c
        print(f"merged #{args[2]}")
    elif args[0] == "api":
        method = opt(args, "-X") or "GET"
        path = next(a for a in args[1:] if a.startswith("repos/"))
        parts = path.split("/")
        repo = st["repos"]["/".join(parts[1:3])]
        if method == "GET" and parts[3:6] == ["git", "ref", "heads"]:
            out = {"object": {"sha": ref(repo["bare"], "/".join(parts[6:]))}}
        elif method == "PATCH" and parts[3] == "pulls":
            kv = dict(a.split("=", 1) for a in args if "=" in a and not a.startswith("repos/"))
            repo["prs"][parts[4]]["base"] = kv["base"]
            out = {"number": int(parts[4])}
        elif method == "DELETE" and parts[3:5] == ["git", "refs"]:
            git(repo["bare"], "update-ref", "-d", "refs/heads/" + "/".join(parts[6:]))
            settle(repo)
        else:
            save(st)
            sys.exit(f"fake gh: unsupported api call {args}")
    else:
        save(st)
        sys.exit(f"fake gh: unsupported {args}")
    save(st)
    if out is not None:
        print(json.dumps(out))


if __name__ == "__main__":
    main()
