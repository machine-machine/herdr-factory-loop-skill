#!/usr/bin/env python3
"""Resume the workspace's Codex orchestrator in this terminal, with explicit YOLO opt-in."""
import argparse
import datetime
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import uuid


class ResumeError(Exception):
    pass


def atomic(path, data):
    fd, name = tempfile.mkstemp(prefix='.resume-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def session_metadata(home, cwd):
    found = {}
    for path in (home / 'sessions').glob('**/*.jsonl'):
        try:
            with path.open() as stream:
                first = json.loads(stream.readline(1024 * 1024))
            meta = first['payload']
            if first.get('type') != 'session_meta' or meta.get('originator') != 'codex-tui':
                continue
            if isinstance(meta.get('source'), dict):  # subagent sessions are not orchestrators
                continue
            if Path(meta['cwd']).resolve() != cwd:
                continue
            sid = str(uuid.UUID(meta['id']))
            timestamp = datetime.datetime.fromisoformat(meta['timestamp'].replace('Z', '+00:00'))
            found[sid] = {'session_id': sid, 'timestamp': timestamp.isoformat(), 'session_file': str(path)}
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return found


def choose_session(home, cwd, receipt, explicit=None):
    sessions = session_metadata(home, cwd)
    if explicit:
        try:
            selected = str(uuid.UUID(explicit))
        except ValueError:
            raise ResumeError('--session must be an exact Codex session UUID') from None
    elif receipt:
        if receipt.get('version') != 1 or receipt.get('agent') != 'codex' or receipt.get('cwd') != str(cwd):
            raise ResumeError('Recorded orchestrator workspace or protocol mismatch')
        selected = receipt['session_id']
    else:
        if not sessions:
            raise ResumeError('No saved interactive Codex session for this directory; use its original --dir')
        ordered = sorted(sessions.values(), key=lambda s: s['timestamp'], reverse=True)
        if len(ordered) > 1 and ordered[0]['timestamp'] == ordered[1]['timestamp']:
            raise ResumeError('Ambiguous sessions; choose one with --session UUID')
        selected = ordered[0]['session_id']
    if selected not in sessions:
        raise ResumeError('Selected session is missing or belongs to another workspace; no new session started')
    return sessions[selected]


def ensure_no_live_codex(cwd, proc=Path('/proc')):
    if not proc.is_dir():
        raise ResumeError('Live-process verification currently requires Linux /proc')
    for entry in proc.iterdir():
        if not entry.name.isdigit():
            continue
        try:
            if entry.stat().st_uid != os.getuid():
                continue
            args = (entry / 'cmdline').read_bytes().split(b'\0')
            executable = Path(os.fsdecode(args[0])).name
            if executable not in ('codex', '.codex-wrapped', 'codex-yolo'):
                continue
            if (entry / 'cwd').resolve(strict=True) == cwd:
                raise ResumeError(f'Codex is already running in this workspace (PID {entry.name}); reconnect to it')
        except (FileNotFoundError, ProcessLookupError):
            continue
        except PermissionError:
            raise ResumeError('Cannot verify a Codex process; reconcile live processes before resuming') from None


def recovery_prompt(cwd):
    return (
        f'Resume the interrupted orchestration in {cwd}. First reconcile current reality: '
        'read AGENTS.md and the applicable project instructions, inspect Git status and worktrees, '
        'the .m2herd overview, RESUME.md, run receipts, worker reports and mailbox. '
        'Inspect the current Herdr agents when available and reconcile stale pane/process IDs. '
        'Follow the original task context to any other project fabric involved in this work. '
        'Do not trust stale summaries alone. Preserve existing workers and unfinished edits. '
        'Check completed commits, tests and external effects before retrying; do not redispatch '
        'completed work or duplicate uncertain actions. Then continue the previously authorized '
        'task autonomously. YOLO changes local approval behavior, not the task scope or external grants.'
    )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dir', default=os.getcwd())
    parser.add_argument('--yolo', action='store_true', required=True)
    parser.add_argument('--session', help='Explicit session UUID; otherwise use the saved binding or latest interactive session in this directory')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args(argv)
    cwd = Path(args.dir).resolve(strict=True)
    fabric = cwd / '.m2herd'
    if not (fabric / 'overview.json').is_file():
        raise ResumeError('No .m2herd fabric here; select the orchestrator workspace with --dir')
    enrollment = Path(os.environ.get('M2_ENROLLMENT_DIR', '/var/lib/m2/instance'))
    if (enrollment / 'instance.json').exists():
        raise ResumeError('Managed instance detected: native Codex recovery cannot bypass managed role identity; use m2-managed resume')
    home = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))).expanduser().resolve()
    receipt_path = fabric / 'orchestrator-session.json'
    # Held for the entire native session, not merely while writing the binding.
    with (fabric / 'orchestrator-session.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ResumeError('Orchestrator recovery is already running for this workspace') from None
        receipt = json.loads(receipt_path.read_text()) if receipt_path.exists() else None
        chosen = choose_session(home, cwd, receipt, args.session)
        ensure_no_live_codex(cwd)
        binary = shutil.which('codex')
        if not binary:
            raise ResumeError('codex is not installed')
        command = [binary, 'resume', chosen['session_id'],
                   '--dangerously-bypass-approvals-and-sandbox', recovery_prompt(cwd)]
        # Preview is non-launching and does not replace the recorded binding.
        if args.dry_run:
            print(json.dumps({'cwd': str(cwd), 'agent': 'codex', 'session_id': chosen['session_id'],
                              'yolo': True, 'command': command}, indent=2))
            return 0
        if not sys.stdin.isatty() or not sys.stdout.isatty():
            raise ResumeError('Run m2herd resume --yolo in an interactive terminal; use --dry-run for inspection')
        state = {'version': 1, 'agent': 'codex', 'cwd': str(cwd), **chosen,
                 'yolo': True, 'status': 'starting', 'resumed_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}
        atomic(receipt_path, state)
        print(f'Resuming Codex {chosen["session_id"]} in {cwd} (YOLO)', flush=True)
        child = subprocess.Popen(command, cwd=cwd)
        # The foreground process group delivers terminal SIGINT to the child too.
        previous = signal.signal(signal.SIGINT, signal.SIG_IGN)
        previous_term = signal.signal(signal.SIGTERM, lambda sig, frame: child.send_signal(sig))
        try:
            code = child.wait()
        finally:
            signal.signal(signal.SIGINT, previous)
            signal.signal(signal.SIGTERM, previous_term)
        state.update(status='exited', exit_code=code)
        atomic(receipt_path, state)
        return code if code >= 0 else 128 - code


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ResumeError, OSError, ValueError, KeyError) as exc:
        print(f'm2herd resume: {exc}', file=sys.stderr)
        sys.exit(1)
