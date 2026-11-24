"""(note-mt309-z6) The player scope's profile against sandbox-exec's 65,535-byte data object limit: agy's history
folders (brain, conversations, config/projects) grow with every agy session on this Mac."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('agent_scope', ROOT/'tools/agent-scope.py')
scope = importlib.util.module_from_spec(spec); spec.loader.exec_module(scope)


def fake_home(tmp, n):
    """A home with n agy sessions: a brain folder, a conversation and a project file each."""
    home = Path(tmp).resolve()/'home'
    agy = home/'.gemini/antigravity-cli'
    for d in (agy/'brain', agy/'conversations', home/'.gemini/config/projects'):
        d.mkdir(parents=True)
    for _ in range(n):
        u = str(uuid.uuid4())
        (agy/'brain'/u).mkdir(); (agy/'brain'/u/'task.md').write_text('old')
        (agy/'conversations'/f'{u}.db').write_text('old')
        (home/'.gemini/config/projects'/f'{uuid.uuid4()}.json').write_text('old')
    return home


def sandboxed(policy, *cmd):
    return subprocess.run(['/usr/bin/sandbox-exec', '-f', str(policy), *cmd], capture_output=True, text=True)


@unittest.skipUnless(sys.platform == 'darwin', 'macOS sandbox')
class ProfileSize(unittest.TestCase):
    def test_other_players_do_not_grow_with_agy_history(self):
        with tempfile.TemporaryDirectory() as tmp:
            small = len(scope.profile(ROOT, fake_home(tmp + '/a', 10)))
            big = len(scope.profile(ROOT, fake_home(tmp + '/b', 3000)))
            self.assertLess(abs(big - small), 200)
            home = fake_home(tmp + '/c', 3000); policy = Path(tmp)/'p.sb'
            policy.write_text(scope.profile(ROOT, home))
            self.assertEqual(sandboxed(policy, '/bin/echo', 'ok').returncode, 0)
            old = next((home/'.gemini/antigravity-cli/conversations').iterdir())
            self.assertNotEqual(sandboxed(policy, '/bin/cat', str(old)).returncode, 0)

    def test_agy_player_keeps_new_entries_and_compiles_at_four_times_today(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = fake_home(tmp, 2000)      # 4x the 501 sessions on chonk on Nov 24 (1,502 entries); 2,500 fail
            policy = Path(tmp)/'p.sb'; policy.write_text(scope.profile(ROOT, home, agy_player=True))
            self.assertEqual(sandboxed(policy, '/bin/echo', 'ok').returncode, 0, sandboxed(policy, '/bin/echo').stderr)
            convs = home/'.gemini/antigravity-cli/conversations'
            old = next(convs.iterdir())
            self.assertNotEqual(sandboxed(policy, '/bin/cat', str(old)).returncode, 0)
            new = convs/f'{uuid.uuid4()}.db'; new.write_text('mine')
            r = sandboxed(policy, '/bin/cat', str(new))
            self.assertEqual((r.returncode, r.stdout), (0, 'mine'), r.stderr)
            brain = home/'.gemini/antigravity-cli/brain'/str(uuid.uuid4())
            r = sandboxed(policy, '/bin/mkdir', str(brain))
            self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == '__main__':
    unittest.main()
