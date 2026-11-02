#!/usr/bin/env python3
"""Claude Code PreToolUse hook (matcher Agent|Task): show the orchestrator's subagents on its herd-board.

The user watches the orchestrator's tab; in-process subagents are otherwise invisible there. Only main-thread
spawns are registered (a subagent's own children show up in its feed as "🤖 …" steps). Detaches at once and
never blocks the tool call: a background child waits for the subagent transcript whose first message is this
prompt, registers it in ~/.cache/herd-board/<anchor>.agents/ and runs `herd-board --open`, which splits the
right third of the caller's tab unless a board is already live there. No-op outside a herdr pane and in a herd
worker's pane (listed in a registered herd.map): the worker's subagents show in its own step feed.
"""
import glob, json, os, subprocess, sys, time

CACHE = os.path.expanduser("~/.cache/herd-board")


def find_transcript(subdir, prompt, since, timeout=90):
    head = prompt[:300]
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            names = os.listdir(subdir)
        except FileNotFoundError:
            names = []
        for n in names:
            if not (n.startswith("agent-") and n.endswith(".jsonl")):
                continue
            p = os.path.join(subdir, n)
            if os.path.getmtime(p) < since - 5:
                continue
            try:
                with open(p, encoding="utf-8") as f:
                    first = json.loads(f.readline())
            except (OSError, ValueError):
                continue
            content = (first.get("message") or {}).get("content")
            text = content if isinstance(content, str) else json.dumps(content, ensure_ascii=False)
            if head and head in text:
                return p
        time.sleep(1)
    return None


def is_herd_worker(pane):
    """True when ``pane`` is a herd worker: some herd registered with a board lists it in herd.map. A pane that
    registered herds itself is an orchestrator, never a worker (herdr may reuse an old worker's pane id)."""
    if os.path.exists(os.path.join(CACHE, pane.replace(":", "_") + ".herds")):
        return False
    for reg in glob.glob(os.path.join(CACHE, "*.herds")):
        try:
            herds = [l.strip() for l in open(reg, encoding="utf-8") if l.strip()]
        except OSError:
            continue
        for herd in herds:
            try:
                if any(l.strip().split("=", 1)[-1] == pane
                       for l in open(os.path.join(herd, "herd.map"), encoding="utf-8") if "=" in l):
                    return True
            except OSError:
                continue
    return False


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--child":
        subdir, prompt_file, label, since = sys.argv[2:6]
        prompt = open(prompt_file, encoding="utf-8").read()
        os.unlink(prompt_file)
        path = find_transcript(subdir, prompt, float(since))
        anchor = os.environ.get("HERDR_PANE_ID", "")
        if path and anchor:
            reg = os.path.join(CACHE, f"{anchor.replace(':', '_')}.agents")
            os.makedirs(reg, exist_ok=True)
            with open(os.path.join(reg, os.path.basename(path)), "w", encoding="utf-8") as f:
                f.write(f"{label}\n{path}\n")
            subprocess.run(["herd-board", "--open", "--anchor", anchor], capture_output=True, timeout=60)
        return

    data = json.load(sys.stdin)
    if not os.environ.get("HERDR_PANE_ID") or is_herd_worker(os.environ["HERDR_PANE_ID"]):
        return
    if data.get("agent_id") or "/subagents/" in data.get("transcript_path", ""):
        return  # spawned by a subagent — its parent's pane already shows it
    inp = data.get("tool_input") or {}
    prompt = inp.get("prompt", "")
    if not prompt:
        return
    label = (inp.get("description") or inp.get("subagent_type") or "agent")[:40]
    tp = data.get("transcript_path", "")
    subdir = os.path.join(tp[:-6] if tp.endswith(".jsonl") else tp, "subagents")
    cache = os.path.join(CACHE, "prompts")
    os.makedirs(cache, exist_ok=True)
    pf = os.path.join(cache, f"prompt-{os.getpid()}-{time.time_ns()}.txt")
    with open(pf, "w", encoding="utf-8") as f:
        f.write(prompt)
    subprocess.Popen([sys.executable, __file__, "--child", subdir, pf, label, str(time.time())],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True, close_fds=True)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
