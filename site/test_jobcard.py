#!/usr/bin/env python3
"""Live agent cards show the job with where it comes from and its age (d20 batch54 N3, viewer Aurora):
python3 site/test_jobcard.py. A focus, a stale plan line and neither, through push_live and static/live.js."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from test_live import LIVE_JS, map_state
from push_live import public_state

SITE = Path(__file__).resolve().parent


def render(s, root):
    js, data = Path(root, 'test.js'), Path(root, 'state.json')
    js.write_text(LIVE_JS)
    data.write_text(json.dumps(s))
    r = subprocess.run(['node', str(js), str(SITE / 'static/live.js'), str(data)], capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)['agents']


def main():
    if not shutil.which('node'):
        print('site job cards: skipped (no node)')
        return
    s = map_state(True)
    a0, a1, a2 = s['agents'][:3]
    a0.update(job='#1355 Steel line coal; step 2 coal filter', job_from='focus', job_label='focus, set 5 min ago', job_age_s=300, job_tick=1)
    a1.update(job='manual top-ups at Fulgora', job_from='plan', job_label='plan line, set 2 h ago; no focus set', job_age_s=7200, job_tick=1)
    a2.update(job=None, job_from=None, job_label='no focus, plan line or notes job')
    out = public_state(s)
    assert out['agents'][0]['job_label'] == 'focus, set 5 min ago' and out['agents'][1]['job_age_s'] == 7200
    with tempfile.TemporaryDirectory() as root:
        cards = render(out, root)
        assert '<span class="fx-muted small job-from">focus, set 5 min ago:</span> #1355 Steel line coal; step 2 coal filter</p>' in cards, cards
        assert '<span class="fx-muted small job-from">plan line, set 2 h ago; no focus set:</span> manual top-ups at Fulgora</p>' in cards
        assert '<p class="agent-job fx-muted small">no focus, plan line or notes job</p>' in cards
        # a state from before job_label: the source still named
        for a in out['agents'][:3]:
            a.pop('job_label', None)
        cards = render(out, root)
        assert '<span class="fx-muted small job-from">plan line:</span> manual top-ups at Fulgora</p>' in cards, cards
        assert '<span class="fx-muted small job-from">focus:</span> #1355' in cards
    print('site job cards: ok (focus, a stale plan line and neither, each labelled with its age; an older state names the source)')


if __name__ == '__main__':
    main()
