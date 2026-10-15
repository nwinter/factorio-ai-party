#!/usr/bin/env python3
"""Factory digest formatting and halfway delivery. No credentials, clock or game required."""
import json
import os
import sys
import tempfile
from unittest.mock import patch
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from factory_digest import Digest, messages, LIMIT

REPORT = {'tick': 6000, 'surfaces': [
    {'surface': 'nauvis', 'survey_age_s': 32, 'machines': {
        'electric-mining-drill': {'type': 'mining-drill', 'counts': {'no_minable_resources': 4},
                                 'positions': {'no_minable_resources': [{'x': x, 'y': 2} for x in range(4)]}},
        'assembling-machine-2': {'type': 'assembling-machine', 'counts': {'item_ingredient_shortage': 3, 'full_output': 2}},
        'stone-furnace': {'type': 'furnace', 'counts': {'no_ingredients': 2}},
        'lab': {'type': 'lab', 'counts': {'working': 4, 'missing_science_packs': 3, 'no_power': 2, 'unknown': 1}}},
     'fuel': {'stone-furnace': {'type': 'furnace', 'empty': 2, 'low': 1}, 'biochamber': {'type': 'assembling-machine', 'empty': 5}},
     'ends': [{'position': {'x': 3.5, 'y': 8}, 'age_s': 12, 'lanes': {'left_empty': True, 'right_full': True}}]},
    {'surface': 'gleba', 'survey_unknown': 'cached survey predates digest fields', 'ends': []}]}


def main():
    text = ' '.join(messages(REPORT))
    for fragment in ('4 electric-mining-drill at (0,2),(1,2),(2,2)', '+1 unlisted', '3 assembling-machine', '2 furnace',
                     '2 no fuel, 1 burning last buffered fuel', 'labs not working: 5', '1 labs status unknown',
                     '1 full lanes at (3.5,8), 1 empty lanes at (3.5,8)', 'survey 32 game s old', 'sampled ends only',
                     'gleba: cached survey predates digest fields'):
        assert fragment in text, (fragment, text)
    assert 'biochamber' not in text
    assert all(len(m.encode()) <= LIMIT < 500 for m in messages(REPORT))
    assert all("snapshot tick 6000; ages at snapshot" in m for m in messages(REPORT))
    assert all(w not in text.lower() for w in ('consider', 'should', 'please', 'recommend'))
    assert 'No completed planetary surveys' in messages({})[0]
    # Lua's JSON encoder may represent an empty table as an empty array.
    assert 'drills reporting no resources: 0' in ' '.join(messages({'surfaces': [{'surface': 'nauvis', 'machines': [], 'fuel': []}]}))
    huge = {'surfaces': [{'surface': 'é'*600, 'machines': {}}]}
    assert all(len(m.encode()) <= LIMIT for m in messages(huge))
    calls, sends, cache = [], [], {}
    fail_part = None
    def dispatch(action, args, request_id=None):
        nonlocal fail_part
        calls.append(action)
        if action == 'factory_digest': return REPORT
        assert action == 'tell' and args['to'] == 'team' and request_id
        if request_id not in cache:
            sends.append(args['text']); cache[request_id] = {'seq': len(sends)}
        if fail_part == request_id or fail_part == 'first':
            fail_part = request_id
            raise ConnectionError('reply lost after delivery')
        return cache[request_id]
    with tempfile.TemporaryDirectory() as run:
        d = Digest(run, 20000)
        assert d.step(12799, dispatch) == [] and not calls
        fail_part = 'first'
        try: d.step(12800, dispatch)
        except ConnectionError: pass
        else: raise AssertionError('lost reply must be reported')
        assert len(sends) == 1
        saved = json.load(open(d.path)); assert saved['half']['next'] == 0
        fail_part = None
        # Retry after a process restart: same id, no duplicate tell, then remaining parts.
        out = Digest(run, 20000).step(12860, dispatch)
        assert len(out) == len(messages(REPORT)) and len(sends) == len(out)
        assert calls.count('factory_digest') == 1
        before = len(calls)
        assert Digest(run, 20000).step(12900, dispatch) == [] and len(calls) == before
        # Deadline changes within the same run do not send a second halfway digest.
        assert Digest(run, 21000).step(14000, dispatch) == [] and len(calls) == before
        assert Digest(run, 20000).step(20000, dispatch) == []
        Digest(run, 20000).step(21000, dispatch, manual=True)
        assert len(sends) == len(out)*2, 'operator request works even after deadline'
        before = len(sends)
        Digest(run, 20000).step(12800, dispatch, dry_run=True)
        assert len(sends) == before
        assert all(row['sent'] is False for row in map(json.loads, open(d.log)) if row.get('dry_run'))
    with tempfile.TemporaryDirectory() as run:
        before = len(sends)
        Digest(run, None).step(15000, dispatch)
        assert len(sends) == before
        Digest(run, 20000).step(100, dispatch, manual=True)
        assert len(sends) > before
        assert 'half' not in json.load(open(os.path.join(run, 'factory-digest.json')))
        before = len(sends)
        Digest(run, 20000).step(12800, dispatch)
        assert len(sends) > before, 'manual request does not consume scheduled send'
    # Exercise the operator CLI path without credentials or any idle report.
    import idle_nudge
    with tempfile.TemporaryDirectory() as run:
        before = len(calls)
        class FakeHarness:
            def __init__(self, *args): pass
            def dispatch(self, action, args, request_id=None):
                return dispatch(action, args, request_id=request_id)
        with patch.object(idle_nudge, 'Harness', FakeHarness), patch.object(idle_nudge, 'log'), \
             patch.object(sys, 'argv', ['idle_nudge.py', '--run', run, '--world', 'n', '--digest-now']):
            idle_nudge.main()
        assert calls[before] == 'factory_digest' and set(calls[before:]) == {'factory_digest', 'tell'}
    print('factory digest: ok (facts, UTF-8 size, deadline, restart, ambiguous reply, manual and dry run)')


if __name__ == '__main__':
    main()
