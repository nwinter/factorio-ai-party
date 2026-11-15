"""No server access: portable paths and lease ownership failures."""
import importlib.util
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

CODE = Path(__file__).resolve().parent / 'mt306'
sys.path.insert(0, str(CODE))
import config
import server_guard as guard
from gc_sweep import setting
import argparse


class HandoffTests(unittest.TestCase):
    def test_gc_sweep_settings_are_explicit_bounded_pairs(self):
        self.assertEqual(setting('100/400'),(100,400))
        for bad in ('100', '100/400/2', 'x/200', '10/200', '100/10000'):
            with self.assertRaises(argparse.ArgumentTypeError): setting(bad)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        for name, value in [('CLAIM', root/'claim'), ('HERE', root/'out'), ('RECEIPT', root/'out/lease.json')]:
            ctx = patch.object(guard, name, value)
            ctx.start(); self.addCleanup(ctx.stop)

    def test_repository_and_import_do_not_need_credentials_or_claim(self):
        self.assertTrue((config.TREE/'tools/mt/standin_load.py').is_file())
        with patch('pathlib.Path.read_text', side_effect=AssertionError('import read private state')):
            spec = importlib.util.spec_from_file_location('mt306_test_padlib', CODE/'padlib.py')
            spec.loader.exec_module(importlib.util.module_from_spec(spec))

    def test_atomic_claim_preserves_an_existing_owner(self):
        guard.CLAIM.write_text('eng-mt307 rehearsal\n')
        with self.assertRaises(FileExistsError): guard.claim('test')
        self.assertEqual(guard.CLAIM.read_text(), 'eng-mt307 rehearsal\n')
        self.assertFalse(guard.RECEIPT.exists())

    def test_release_requires_restoration_and_same_claim(self):
        guard.claim('test')
        with patch.object(guard, 'remote') as remote:
            with self.assertRaisesRegex(AssertionError, 'restore'): guard.release()
            remote.assert_not_called()
        row = guard.owned(); row['restored_at']='verified'; guard.write(row)
        guard.CLAIM.write_text('eng-mt307 replacement\n')
        with self.assertRaisesRegex(AssertionError, 'claim changed'): guard.release()
        self.assertTrue(guard.CLAIM.exists())

    def test_reused_pid_is_never_stopped(self):
        guard.claim('test')
        row=guard.owned(); row.update(backup_complete=True,pid=123,process_start='original')
        guard.write(row)
        with patch.object(guard, 'remote', side_effect=['123\n','different\n']), patch.object(guard.subprocess,'run') as run:
            with self.assertRaisesRegex(AssertionError, 'PID reused'): guard.restore()
            run.assert_not_called()

    def test_verified_release_writes_wake(self):
        guard.claim('test')
        row=guard.owned(); row['restored_at']='verified'; guard.write(row)
        with patch.object(guard, 'remote', return_value=''), patch('builtins.print'): guard.release()
        self.assertFalse(guard.CLAIM.exists())
        wake=json.loads((guard.CLAIM.parent/'mt306-wake.jsonl').read_text())
        self.assertIn('ENGWAKE eng-mt306 released imac2',wake['text'])

    def test_profile_audit_includes_cold_partial_bucket(self):
        base=Path(self.tmp.name)/'bench'
        base.with_suffix('.json').write_text(json.dumps({'windows':[{'from_tick':62,'until_tick':182}]}))
        lines=[]
        for tick,n,ms in [(60,58,300),(120,60,60),(180,3,3)]:
            for key,mult in [('tick',1),('*',2)]:
                lines.append(f'agent-harness profile second tick={tick} n={n} key={key} time=Duration: {ms*mult}ms')
        Path(str(base)+'.profile.log').write_text('\n'.join(lines))
        subprocess.run([sys.executable,str(CODE/'audit_boundaries.py'),str(base)],check=True,capture_output=True)
        result=json.loads(Path(str(base)+'-boundaries-audit.json').read_text())
        self.assertEqual(result['profiled_ticks'],121)
        self.assertEqual(result['tick_max'],300)
        self.assertAlmostEqual(result['tick_ms_per_s'],363*60/121)


if __name__ == '__main__': unittest.main()
