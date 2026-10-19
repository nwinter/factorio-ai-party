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
    # Exactly the two runtime research/use facts survive halfway/manual delivery and UTF-8 packing.
    use = ["Agent equipment: power-armor-mk2 researched; worn: modular-armor x6, light-armor x1",
           "Building tiers: nauvis stone-furnace 140, steel-furnace 60, electric-furnace 0; vehicles researched / built: tank 0"]
    with_use = dict(REPORT, research_use=use)
    from factory_digest import facts
    assert all(facts(with_use).count(line) == 1 for line in use)
    joined = ' '.join(messages(with_use))
    for text in ('power-armor-mk2', 'modular-armor x6', 'steel-furnace 60', 'electric-furnace 0', 'tank 0'):
        assert text in joined, joined
    assert all(len(m.encode()) <= LIMIT for m in messages(with_use))
    # Lua's JSON encoder may represent an empty table as an empty array.
    assert 'drills reporting no resources: 0' in ' '.join(messages({'surfaces': [{'surface': 'nauvis', 'machines': [], 'fuel': []}]}))
    huge = {'surfaces': [{'surface': 'é'*600, 'machines': {}}]}
    assert all(len(m.encode()) <= LIMIT for m in messages(huge))
    # ---- (d17 batch35 D2) the scheduled digest as a delta, to owners by claim ------------------------------------------
    from factory_digest import current, delta, delta_messages, owners, moved
    CLAIMS = [{'id': 1, 'kind': 'claim', 'status': 'claimed', 'owner': 'astra', 'surface': 'nauvis',
               'area': {'left_top': {'x': -1, 'y': 0}, 'right_bottom': {'x': 1.5, 'y': 3}}},
              {'id': 2, 'kind': 'claim', 'status': 'claimed', 'owner': 'opus', 'surface': 'nauvis',
               'area': {'left_top': {'x': 100, 'y': 100}, 'right_bottom': {'x': 120, 'y': 120}}},
              {'id': 3, 'kind': 'claim', 'status': 'done', 'owner': 'luna', 'surface': 'nauvis',
               'area': {'left_top': {'x': -10, 'y': -10}, 'right_bottom': {'x': 10, 'y': 10}}}]
    BLOCKED = [{'id': 521, 'kind': 'project', 'status': 'blocked', 'owner': 'haiku', 'title': 'Coal supply line to the boilers'}]
    OPEN = [{'id': 900, 'kind': 'request', 'status': 'open', 'title': 'Swiftlet needs 200 rockets', 'requested_by': 'sol'},
            {'id': 901, 'kind': 'request', 'status': 'open', 'owner': 'opus', 'title': 'taken'}]
    LESSONS = [{'id': 44, 'owner': 'sol', 'rule': 'Keep 400 shells at the north wall', 'check': {'until': 'item_count'},
                'state': 'unresolved: check not met (artillery-shell 120 of 400)'},
               {'id': 45, 'owner': 'grok', 'rule': 'resolved one', 'check': {'until': 'item_count'}, 'state': 'check met 1h ago (resolved)'}]
    assert owners('nauvis', [{'x': 0, 'y': 2}], CLAIMS) == ['astra'], 'the claim holding the position'
    assert owners('nauvis', [{'x': 50, 'y': 50}], CLAIMS) == ['astra', 'opus'], 'else every open claim on the surface'
    assert owners('gleba', [], CLAIMS) == ['team'], 'no claim there: the team'
    DOING = [{'id': 7, 'kind': 'task', 'status': 'doing', 'owner': 'gemini', 'title': 'Fulgora south factory'},
             {'id': 8, 'kind': 'project', 'status': 'claimed', 'owner': 'sol', 'title': 'Swiftlet relay to Fulgora'},
             {'id': 9, 'kind': 'task', 'status': 'done', 'owner': 'grok', 'title': 'fulgora old'}]
    assert owners('fulgora', [], CLAIMS, DOING) == ['gemini', 'sol'], 'no claim there: the agents holding items that name it'
    assert owners('fulgoran', [], CLAIMS, DOING) == ['team']
    assert moved(None, 3) and moved(3, 0) and not moved(10, 11) and moved(10, 12) and not moved(4, 4)
    cur = current(REPORT, CLAIMS, BLOCKED, OPEN, LESSONS)
    assert cur['dry|nauvis|electric-mining-drill']['to'] == ['astra'], cur['dry|nauvis|electric-mining-drill']
    assert cur['short|nauvis|assembling-machine']['to'] == ['astra', 'opus'] and cur['short|nauvis|assembling-machine']['value'] == 3
    assert 'fuel|nauvis|biochamber' not in cur and cur['fuel|nauvis|stone-furnace']['value'] == 3
    assert cur['labs|nauvis']['value'] == 5 and cur['lesson|44']['to'] == ['sol'] and 'lesson|45' not in cur
    assert cur['blocked|521']['to'] == ['haiku'] and cur['unowned|900']['to'] == ['team'] and 'unowned|901' not in cur
    first = delta(None, cur)
    assert ('haiku', 'decision', '#521 project blocked: Coal supply line to the boilers') in first
    assert ('team', 'decision', '#900 request open, no owner: Swiftlet needs 200 rockets (by sol)') in first
    assert not [r for r in first if r[0] == 'team' and r[1] == 'blocker'], 'nauvis has owners: no team broadcast of its blockers'
    # the next digest: only what moved, what cleared, nothing that held still
    report2 = json.loads(json.dumps(REPORT))
    m2 = report2['surfaces'][0]['machines']
    m2['assembling-machine-2']['counts'] = {'item_ingredient_shortage': 9, 'full_output': 2}
    m2['electric-mining-drill']['counts'] = {}
    m2['lab']['counts'] = {'working': 9, 'missing_science_packs': 6}
    cur2 = current(report2, CLAIMS, [], OPEN, LESSONS)
    rows = delta(cur, cur2)
    texts = [r[2] for r in rows]
    assert 'nauvis: input shortage 9 assembling-machine (was 3)' in texts and 'nauvis: labs not working 6 (was 5)' not in texts, texts
    assert 'cleared: nauvis: 4 electric-mining-drill reporting no resources at (0,2),(1,2),(2,2)' in texts
    assert 'cleared: #521 project blocked: Coal supply line to the boilers' in texts
    assert not [t for t in texts if 'output full' in t or 'lesson #44' in t or '#900' in t], 'unchanged: not said again'
    packed = delta_messages(rows, 'tick 6000, 10 game min ago', {'astra': ['most repeated haul: iron-plate 12 times']})
    assert set(packed) == {'astra', 'opus', 'haiku'}, packed
    assert packed['astra'][0].startswith('Factory digest, changed since the last one (tick 6000, 10 game min ago): blockers: ')
    assert 'your hauls: most repeated haul: iron-plate 12 times.' in ' '.join(packed['astra']) and 'iron-plate' not in ' '.join(packed['opus'])
    assert all(len(t.encode()) <= LIMIT for ts in delta_messages(first, 'x').values() for t in ts)
    assert all(w not in ' '.join(t for ts in delta_messages(first, 'x').values() for t in ts).lower() for w in ('consider', 'should', 'please', 'recommend'))

    calls, sends, cache = [], [], {}
    fail_part = None
    def dispatch(action, args, request_id=None):
        nonlocal fail_part
        calls.append(action)
        if action == 'factory_digest': return REPORT
        if action == 'board':
            return {'items': CLAIMS if args.get('kind') == 'claim' else BLOCKED if args.get('status') == 'blocked'
                    else OPEN if args.get('kind') == 'request' else []}
        if action == 'lessons': return {'lessons': LESSONS}
        assert action == 'tell' and args['to'] and request_id
        if request_id not in cache:
            sends.append((args['to'], args['text'])); cache[request_id] = {'seq': len(sends)}
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
        job = json.load(open(d.path))['half']
        assert len(out) == len(job['messages']) and len(sends) == len(out)
        assert calls.count('factory_digest') == 1
        assert {to for to, _ in sends} == {'astra', 'opus', 'haiku', 'sol', 'team'}, sends
        assert [t for to, t in sends if to == 'team'] == ['Factory digest, changed since the last one (no earlier digest: what holds now): decisions needed: #900 request open, no owner: Swiftlet needs 200 rockets (by sol).']
        assert json.load(open(d.path))['last']['tick'] == 6000
        before = len(calls)
        assert Digest(run, 20000).step(12900, dispatch) == [] and len(calls) == before
        # Deadline changes within the same run do not send a second halfway digest.
        assert Digest(run, 21000).step(14000, dispatch) == [] and len(calls) == before
        assert Digest(run, 20000).step(20000, dispatch) == []
        Digest(run, 20000).step(21000, dispatch, manual=True)
        assert len(sends) == len(out) + len(messages(REPORT)) and all(to == 'team' for to, _ in sends[len(out):]), \
            'operator request: the full census to the team, even after deadline'
        before = len(sends)
        Digest(run, 20000).step(12800, dispatch, dry_run=True)
        assert len(sends) == before
        assert all(row['sent'] is False for row in map(json.loads, open(d.log)) if row.get('dry_run'))
        # the next run resumes from this one: its delta compares with this run's last digest
        nxt = os.path.join(os.path.dirname(run), os.path.basename(run) + '-next')
        os.makedirs(nxt)
        open(os.path.join(nxt, 'resumed-from'), 'w').write(os.path.basename(run) + '\n')
        before = len(sends)
        Digest(nxt, 20000).step(12800, dispatch)
        assert len(sends) == before, 'nothing changed since the last run\'s digest: no tell'
        assert json.load(open(os.path.join(nxt, 'factory-digest.json')))['half']['done']
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
        assert calls[before] == 'factory_digest' and set(calls[before:]) == {'factory_digest', 'tell'}, 'on request: the census, no board reads'
    print('factory digest: ok (facts, UTF-8 size, deadline, restart, ambiguous reply, manual and dry run; the delta to owners)')


if __name__ == '__main__':
    main()
