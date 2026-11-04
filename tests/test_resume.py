import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

path = Path(__file__).resolve().parents[1] / 'scripts/m2herd-resume.py'
spec = importlib.util.spec_from_file_location('resume', path)
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
A = '01a09f4a-b1c0-7631-a17b-234f6cf826cf'
B = '01a09d44-19f0-7c30-a471-aa4aa2c25a2f'


class ResumeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.cwd = self.root / 'workspace with spaces'
        self.cwd.mkdir()
        (self.cwd / '.m2herd').mkdir()
        (self.cwd / '.m2herd/overview.json').write_text('{}')
        self.home = self.root / 'codex'
        (self.home / 'sessions').mkdir(parents=True)
        self.env = patch.dict(os.environ, {'CODEX_HOME': str(self.home), 'M2_ENROLLMENT_DIR': str(self.root / 'enrollment')})
        self.env.start()
        self.session(A, '2026-09-14T09:41:07Z')

    def tearDown(self):
        self.env.stop()
        self.temp.cleanup()

    def session(self, sid, timestamp, cwd=None, origin='codex-tui', source='cli'):
        (self.home / 'sessions' / (sid + '.jsonl')).write_text(json.dumps({'type': 'session_meta', 'payload':
            {'id': sid, 'timestamp': timestamp, 'cwd': str(cwd or self.cwd), 'originator': origin, 'source': source}}) + '\n')

    def test_latest_interactive_only_in_exact_workspace(self):
        self.session(B, '2026-09-14T10:41:07Z', cwd=self.root)
        self.assertEqual(r.choose_session(self.home, self.cwd, None)['session_id'], A)
        self.session(B, '2026-09-14T10:41:07Z', origin='codex_exec')
        self.assertEqual(r.choose_session(self.home, self.cwd, None)['session_id'], A)
        self.session(B, '2026-09-14T10:41:07Z', source={'subagent': 'worker'})
        self.assertEqual(r.choose_session(self.home, self.cwd, None)['session_id'], A)
        self.session(B, '2026-09-14T10:41:07Z')
        self.assertEqual(r.choose_session(self.home, self.cwd, None)['session_id'], B)

    def test_binding_wins_over_newer_session(self):
        self.session(B, '2026-09-14T10:41:07Z')
        receipt = {'version': 1, 'agent': 'codex', 'cwd': str(self.cwd), 'session_id': A}
        self.assertEqual(r.choose_session(self.home, self.cwd, receipt)['session_id'], A)
        self.assertEqual(r.choose_session(self.home, self.cwd, receipt, B)['session_id'], B)
        receipt['cwd'] = str(self.root)
        with self.assertRaises(r.ResumeError):
            r.choose_session(self.home, self.cwd, receipt)

    def test_unknown_or_other_workspace_id_fails(self):
        with self.assertRaises(r.ResumeError):
            r.choose_session(self.home, self.cwd, None, B)
        with self.assertRaises(r.ResumeError):
            r.choose_session(self.home, self.cwd, None, 'last')

    def test_live_codex_is_rejected(self):
        proc = self.root / 'proc'
        pid = proc / '123'; pid.mkdir(parents=True)
        (pid / 'cmdline').write_bytes(b'/nix/store/example/bin/.codex-wrapped\0resume\0')
        (pid / 'cwd').symlink_to(self.cwd, target_is_directory=True)
        with self.assertRaisesRegex(r.ResumeError, 'already running'):
            r.ensure_no_live_codex(self.cwd, proc)
        r.ensure_no_live_codex(self.root, proc)

    def test_dry_run_does_not_launch_or_bind(self):
        with patch.object(r, 'ensure_no_live_codex'), patch.object(r.shutil, 'which', return_value='/fake/codex'), patch.object(r.subprocess, 'Popen') as start:
            r.main(['--yolo', '--dry-run', '--dir', str(self.cwd)])
            start.assert_not_called()
        self.assertFalse((self.cwd / '.m2herd/orchestrator-session.json').exists())

    def test_managed_instance_cannot_fall_back(self):
        enrollment = self.root / 'enrollment'; enrollment.mkdir()
        (enrollment / 'instance.json').write_text('{}')
        with self.assertRaisesRegex(r.ResumeError, 'Managed instance'):
            r.main(['--yolo', '--dir', str(self.cwd)])

    def test_launch_passes_exact_session_yolo_and_recovery_prompt(self):
        binary = self.root / 'codex'
        # A distinct executable directory; CODEX_HOME remains the metadata directory.
        executable = self.root / 'bin/codex'; executable.parent.mkdir()
        executable.write_text('#!' + sys.executable + '\nimport sys,json\nfrom pathlib import Path\nPath("argv.json").write_text(json.dumps(sys.argv[1:]))\n')
        executable.chmod(0o700)
        with patch.object(r, 'ensure_no_live_codex'), patch.object(r.shutil, 'which', return_value=str(executable)), patch.object(sys.stdin, 'isatty', return_value=True), patch.object(sys.stdout, 'isatty', return_value=True):
            self.assertEqual(r.main(['--yolo', '--dir', str(self.cwd)]), 0)
        argv = json.loads((self.cwd / 'argv.json').read_text())
        self.assertEqual(argv[:3], ['resume', A, '--dangerously-bypass-approvals-and-sandbox'])
        self.assertIn('reconcile', argv[-1])
        receipt = json.loads((self.cwd / '.m2herd/orchestrator-session.json').read_text())
        self.assertEqual(receipt['session_id'], A)
        self.assertEqual(receipt['status'], 'exited')

    def test_concurrent_recovery_lock(self):
        with (self.cwd / '.m2herd/orchestrator-session.lock').open('a') as lock:
            r.fcntl.flock(lock, r.fcntl.LOCK_EX | r.fcntl.LOCK_NB)
            with self.assertRaisesRegex(r.ResumeError, 'already running'):
                r.main(['--yolo', '--dir', str(self.cwd)])

    def test_no_terminal_does_not_launch_or_bind(self):
        with patch.object(r, 'ensure_no_live_codex'), patch.object(r.shutil, 'which', return_value='/fake/codex'), patch.object(sys.stdin, 'isatty', return_value=False):
            with self.assertRaisesRegex(r.ResumeError, 'interactive terminal'):
                r.main(['--yolo', '--dir', str(self.cwd)])
        self.assertFalse((self.cwd / '.m2herd/orchestrator-session.json').exists())

    def test_shell_entrypoint_and_symlink(self):
        link = self.root / 'm2herd'; link.symlink_to(path.parent / 'm2herd.sh')
        result = subprocess.run(['bash', str(link), 'resume', '--yolo', '--help'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--session', result.stdout)


if __name__ == '__main__':
    unittest.main()
