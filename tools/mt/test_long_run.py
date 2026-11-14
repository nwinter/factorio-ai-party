import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parent))
import autosave

class Saves(unittest.TestCase):
    def test_retention_keeps_hourly_and_recent_after_rollback(self):
        rows=[dict(file=str(i),tick=i*54000,copied_at=i) for i in range(24)]
        rows.append(dict(file='rollback',tick=1,copied_at=30))
        keep=autosave.retain(rows,3)
        self.assertEqual(keep,{'0','4','8','12','16','20','22','23','rollback'})
    def test_verify_rejects_corruption(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(autosave,'ARCHIVE',Path(temp)):
            root=Path(temp)/'trial'/'saves';root.mkdir(parents=True)
            path=root/'one.zip';path.write_bytes(b'good')
            (root/'index.json').write_text(json.dumps({'copies':[dict(file='one.zip',sha256=autosave.sha(path))]}))
            self.assertEqual(autosave.verified('trial','one.zip')[0],path)
            path.write_bytes(b'bad')
            with self.assertRaises(RuntimeError):autosave.verified('trial','one.zip')
            with self.assertRaises(ValueError):autosave.verified('trial','../one.zip')

if __name__=='__main__':unittest.main()
