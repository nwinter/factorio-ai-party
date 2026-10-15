#!/usr/bin/env python3
"""Public wait line and quoted reason on the live card: python3 site/test_waitcard.py."""
import json
from pathlib import Path
import subprocess
import tempfile

from test_live import LIVE_JS, map_state
from push_live import public_state

SITE = Path(__file__).resolve().parent


def main():
    s = map_state(True)
    line = 'waiting: crafting done, ~2 min (idle 5 min)'
    reason = 'I am waiting for <gears> & more plates.'
    s['agents'][0].update(wait_line=line, wait_reason=reason)
    s['agents'][1].update(wait_line=None, wait_reason='old reason must not appear')
    out = public_state(s)
    assert out['agents'][0]['wait_line'] == line and out['agents'][0]['wait_reason'] == reason
    assert 'wait_estimates' not in out['agents'][0]  # no raw journal/condition payload on the public site
    with tempfile.TemporaryDirectory() as root:
        js, data = Path(root, 'test.js'), Path(root, 'state.json')
        js.write_text(LIVE_JS)
        data.write_text(json.dumps(s))
        r = subprocess.run(['node', str(js), str(SITE / 'static/live.js'), str(data)], capture_output=True, text=True, timeout=30)
        assert r.returncode == 0, r.stderr
        cards = json.loads(r.stdout)['agents']
        assert '<p class="agent-wait">' + line + '</p>' in cards, cards
        assert '“I am waiting for &lt;gears&gt; &amp; more plates.”' in cards
        assert '<gears>' not in cards and 'old reason must not appear' not in cards
        s['agents'][0].update(wait_line=None, wait_reason=None)
        data.write_text(json.dumps(s))
        r = subprocess.run(['node', str(js), str(SITE / 'static/live.js'), str(data)], capture_output=True, text=True, timeout=30)
        assert r.returncode == 0, r.stderr
        assert 'agent-wait' not in json.loads(r.stdout)['agents']
    print('site wait cards: ok (public fields, exact line, own quote escaped, no quote after wake)')


if __name__ == '__main__':
    main()
