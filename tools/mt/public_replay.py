#!/usr/bin/env python3
"""Offline overlay replay: no Harness, clients, server launch, OBS or broadcast.

  python tools/mt/public_replay.py --write FIXTURE.json                        # synthetic, 3 teams x 2 agents
  python tools/mt/public_replay.py --write FIXTURE.json --teams 4 --agents 3   # synthetic, 4 teams x 3 agents
  python tools/mt/public_replay.py --write FIXTURE.json --run /abs/runs/t292/op --tree /abs/launch-tree
  python tools/mt/public_replay.py --serve FIXTURE.json --port 8796

Every frame goes through the production path: raw team feeds -> public_race.project -> Race.update ->
audience -> Director.choose with subjects(). The synthetic cast, lines and timings are invented and say so
on screen. A recorded replay rebuilds the feeds from a finished run's own logs (agent journals, team chat,
score and pact records); what those logs do not hold (SPM, research progress, base maps) stays absent.
"""
import argparse
import bisect
import copy
from datetime import datetime
import gzip
import http.server
import json
from pathlib import Path
import re
import time
import urllib.parse

from public_race import project, Race, Director, diplomacy, subjects, clock, verb_class
from public_overlay import asset, audience, shots, CAMERA_RECT

HERE = Path(__file__).resolve().parent
TEAMS = ('green', 'yellow', 'blue', 'red')
BASES = {'green': (-700, -650), 'yellow': (680, -700), 'blue': (-660, 690), 'red': (700, 700)}
# The stream model's interest weights (tools/stream/model.py ACTION_WEIGHT) and half-life, to rebuild `interest`.
WEIGHT = {'build': 3.0, 'place': 3.0, 'mine': 1.2, 'craft': 1.0, 'insert': 1.2, 'take': 1.0, 'feed': 1.2,
          'transfer': 1.2, 'collect': 1.0, 'pickup': 1.0, 'refuel': 1.2, 'move_to': 0.6, 'research': 2.0,
          'deconstruct': 3.0, 'configure': 1.0, 'use_item': 1.0}
HALF_LIFE = 75.0

# ---- synthetic cast: invented names and personas, the shapes the harness `profile` action allows -------------------
CAST = {
    'green': [('gemini', 'Gemini 3.8 Flash', 'Antigravity', {'display_name': 'Vesper', 'color': '#34a853', 'glyph': '♊', 'motto': 'Mining today, rocket tomorrow', 'pronouns': 'she/her'}),
              ('gemini2', 'Gemini 3.8 Flash', 'Antigravity', {'display_name': 'Juno', 'color': '#9bd14f', 'glyph': 'J', 'motto': 'Power first, then everything else'}),
              ('gemini3', 'Gemini 3.8 Flash', 'Antigravity', {'display_name': 'Castor', 'color': '#2fbfa0', 'motto': 'A belt is a promise', 'pronouns': 'he/him',
                                                               'avatar': {'base': 'robot', 'helmet': 'power', 'visor': 'mono'}})],
    'yellow': [('grok', 'Grok 4.7', 'Grok Build', {'display_name': 'Grok the Unyielding', 'color': '#e8b923', 'glyph': 'G', 'motto': 'plates then orbit'}),
               ('grok2', 'Grok 4.7', 'Grok Build', {'display_name': 'Sprocket', 'color': '#ff8a3c', 'glyph': '⚙', 'motto': 'Red science, then the edge.', 'pronouns': 'they/them'}),
               ('grok3', 'Grok 4.7', 'Grok Build', {'display_name': 'Bolt', 'color': '#ffe27a', 'motto': 'Fast hands, short belts'})],
    'blue': [('muse', 'Muse Spark 1.3', 'Muse Code', {'display_name': 'Calliope', 'color': '#5aa9ff', 'glyph': '♪', 'motto': 'Every blueprint a sketch', 'pronouns': 'she/her'}),
             ('muse2', 'Muse Spark 1.3', 'Muse Code', {'display_name': 'Thalia', 'color': '#7dd3fc', 'motto': 'Measure twice, smelt once'}),
             ('muse3', 'Muse Spark 1.3', 'Muse Code', {})],  # no profile yet: roster name, a colour beside the team's
    'red': [('astra', 'GPT-6 Astra', 'Codex', {'display_name': 'Astra', 'color': '#e8743b', 'glyph': '✦', 'motto': 'Ratios first.'}),
            ('sol', 'GPT-6.1 Sol', 'Codex', {'display_name': 'Sol Invictus', 'color': '#ffb08a', 'motto': 'Keep the labs lit'}),
            ('terra', 'GPT-6.1 Terra', 'Codex', {})],
}
# (step, team, speaker index, 'talk' | recipient index, text). Invented, in the register of the real t291/t292 lines.
LINES = [
    (1, 'green', 0, 1, 'Iron is flowing. I will put down two more furnaces, then start on gears.'),
    (2, 'yellow', 1, 'talk', 'Boiler is lit and the steam engine is turning. First lab goes down next.'),
    (3, 'green', 1, 0, 'Good. I am running copper wire for the first lab. Shout when the gears land.'),
    (4, 'blue', 0, 1, 'I mined enough stone for four furnaces. Heading back to the iron drill to set up smelting.'),
    (5, 'yellow', 0, 1, 'Copper drill is fed. I am hand-crafting circuits until the assembler takes over.'),
    (6, 'blue', 1, 0, 'Furnaces coming. Skip the stone hike, bring coal to the drills when you can.'),
    (8, 'red', 0, 'talk', 'Ratios first: two drills a furnace until we have power. Then we scale.'),
    (9, 'yellow', 2, 0, 'Belts are down from the iron patch to the furnaces. Twelve plates a minute and climbing.'),
    (11, 'green', 2, 0, 'Assembler one is making gears. I will chain the second one for belts so we stop hand-crafting.'),
    (12, 'red', 1, 0, 'Labs are placed but dry. I need ten red science to start automation.'),
    (13, 'green', 0, 'talk', 'Red science is on the belt. Labs are drinking. Automation is ours in a minute.'),
    (15, 'yellow', 1, 0, 'Logistics is next. I will queue it now and feed the labs from the chest by the boiler.'),
    (17, 'blue', 0, 1, 'Coal is thin here. I am standing by the drills until the next delivery.'),
    (19, 'yellow', 0, 'talk', 'We just charted Green on the east ridge. They are close. Opening a channel.'),
    (22, 'green', 1, 0, 'Yellow wants a cease-fire and a trade depot between the bases. Equal shares looks fair to me.'),
    (24, 'green', 0, 1, 'Agreed. Accept it, then send fifty iron through the depot and I will check what arrives.'),
    (27, 'yellow', 2, 1, 'Depot chests are placed. Fifty copper going in now, watch for forty on their side.'),
    (29, 'red', 2, 0, 'Second boiler is on. Power is steady, the labs stopped flickering.'),
    (31, 'yellow', 1, 'talk', 'Viewer question: yes, we split it. I keep the labs fed, Grok runs copper, Bolt builds belts.'),
    (33, 'green', 2, 1, 'Forty copper arrived, cut ten. The ledger matches. Trade is real.'),
    (35, 'blue', 1, 0, 'Fuel is here. Restarting the furnaces, then the lab. We are behind but not out.'),
    (38, 'yellow', 0, 1, 'Steel is done. I am moving to engines, you take the military line so the walls go up.'),
    (41, 'red', 0, 1, 'Green and Yellow signed. We should talk to Blue before we are the only ones without a friend.'),
    (44, 'green', 0, 'talk', 'Oil is two screens north. I am walking there with pumpjack parts as soon as steel lands.'),
    (47, 'yellow', 1, 0, 'Labs ran dry for a moment. Fixed: the inserter was facing the wrong way.'),
    (50, 'blue', 0, 'talk', 'Lab is running again. Logistics is on the board.'),
]
TALKS = [  # explicit diplomacy (after contact): (step, from team, speaker index, to team, text)
    (20, 'yellow', 0, 'green', 'Yellow to Green: cease-fire, equal shares, and a trade depot between our bases. Fair?'),
    (23, 'green', 1, 'yellow', 'Green accepts the shape. Propose it as a pact and we will sign.'),
    (36, 'yellow', 1, 'green', 'Depot works both ways. We can send copper every hour if you send iron.'),
]
VIEWERS = [(10, 'site', 'site:104', 'Green, can one of you handle power while the other feeds the labs?'),
           (30, 'youtube', 'yt:Ugx7', 'Yellow, how are you three splitting the work?'),
           (46, 'site', 'site:131', 'Blue, what is holding you back right now?')]
TECHS = ['automation', 'logistics', 'electronics', 'steel-processing', 'logistic-science-pack', 'automation-2', 'military',
         'stone-wall', 'gun-turret', 'fast-inserter', 'optics', 'engine', 'fluid-handling', 'oil-processing',
         'advanced-circuit', 'sulfur-processing', 'plastics', 'chemical-science-pack', 'solar-energy', 'electric-energy-distribution-1']
PHASES = [('build:assembling-machine-1', 3), ('', 1), ('craft:iron-gear-wheel', 2), ('move_to', 2), ('mine:iron-ore', 3),
          ('', 1), ('insert:lab', 2), ('', 2), ('build:stone-furnace', 2), ('craft:electronic-circuit', 2), ('', 1)]


def phase(team, index, step):
    """(activity, active kind) for a synthetic agent: a busy cycle, offset per agent. Blue runs out of fuel and
    stands still from step 14 to 34, the quiet team the camera only glances at."""
    if team == 'blue' and 14 <= step < 34:
        return 'idle', ''
    if team == 'red' and index == 2 and step % 9 < 5:
        return 'resting', ''
    spot = (step + index * 5 + TEAMS.index(team) * 3) % sum(n for _, n in PHASES)
    for kind, n in PHASES:
        if spot < n:
            return ('acting', kind) if kind else ('thinking', '')
        spot -= n
    return 'thinking', ''


def synthetic(teams=3, per=2, steps=56):
    order = TEAMS[:teams]
    rosters = {t: [dict(name=n, model=m, harness=h) for n, m, h, _ in CAST[t][:per]] for t in order}
    race, director, frames, camera = Race(), Director(), [], None
    heat = {(t, a['name']): 0.0 for t in order for a in rosters[t]}
    still = {key: 0.0 for key in heat}
    start, speed = [9, 7, 5, 4], [10, 6, 15, 12]  # technologies at the start; steps a technology
    for step in range(steps):
        now, tick = 1000.0 + step * 5, 180000 + step * 300
        raws, scores = {}, {}
        for ti, team in enumerate(order):
            bx, by = BASES[team]
            agents = []
            for i, (name, model, harness, profile) in enumerate(CAST[team][:per]):
                activity, active = phase(team, i, step)
                kind = active.partition(':')[0]
                heat[team, name] = min(30.0, heat[team, name] * 0.5 ** (5 / HALF_LIFE) + (WEIGHT.get(kind, 0.0) if activity == 'acting' else 0.0))
                still[team, name] = 0.0 if activity in ('acting', 'thinking') else still[team, name] + 5
                pos = {'x': bx + 6 * i + (step * 3 + i * 7) % 11, 'y': by + 4 * i + (step * 2) % 7}
                row = {'name': name, 'display_name': profile.get('display_name') or name.capitalize(), 'profile_set': bool(profile),
                       'activity': activity, 'active': active or False, 'position': pos, 'surface': 'nauvis', 'alive': True,
                       'interest': round(heat[team, name], 2), 'idle_s': still[team, name],
                       'did': {'action': 'build', 't': now, 'position': pos, 'surface': 'nauvis'} if kind == 'build' else None}
                row.update({k: profile[k] for k in ('color', 'glyph', 'motto', 'pronouns', 'avatar') if k in profile})
                agents.append(row)
            done = start[ti] + step // speed[ti]
            recent = [{'name': TECHS[start[ti] + k - 1], 'tick': 180000 + k * speed[ti] * 300} for k in range(1, step // speed[ti] + 1)][-4:]
            chat = []
            for at, lteam, who, to, text in LINES:
                if lteam != team or at > step or who >= per or (to != 'talk' and to >= per):
                    continue
                speaker, said = CAST[team][who][0], 180000 + at * 300
                line = {'seq': at if to == 'talk' else f't{at}', 'tick': said, 'from': speaker, 'agent': speaker, 't': 1000.0 + at * 5}
                if to == 'talk':
                    line.update(text=text, lane='talk')
                    if text.startswith('Viewer question'):
                        line.update(reply_to=3, replies_to=[{'seq': 3, 'source': 'youtube'}])
                else:
                    line.update(tell=True, lane='tell', to=[CAST[team][to][0]], body=text, text='presentation text is ignored')
                chat.append(line)
            grid = [['.'] * 44 for _ in range(30)]
            for row in range(4, 26):
                grid[row][8] = 'B'
                for col in range(11, min(40, 14 + step // 2 + ti * 2)):
                    grid[row][col] = 'B' if row in (8, 14, 21) else ['M', 'S', 'A', 'R', 'E'][(row // 4 + ti) % 5] if col % 4 == 0 else '.'
            viewers, delivery = [], []
            for at, source, ident, text in VIEWERS:
                if at <= step and now - (1000.0 + at * 5) <= 170:
                    viewers.append({'id': ident, 'source': source, 'name': 'A viewer', 'text': text, 't': 1000.0 + at * 5})
                    if source == 'site' and step >= at + 1 + ti * 2:  # each team's relay confirms in its own time
                        delivery.append({'id': ident, 'status': 'relayed'})
            raws[team] = {'now': now, 'tick': tick, 'agents': agents, 'chat': chat[-10:],
                          'research': {'current': TECHS[min(done, len(TECHS) - 1)], 'progress': (step % speed[ti]) / speed[ti], 'done_count': done, 'recent': recent},
                          'science': {'spm': [24.6, 31.2, 8.4, 12.0][ti] + step * [.3, .5, .05, .2][ti],
                                      'series': [max(0, (j - 4) * (ti + 1) + ((j * 7 + step) % 11) - 5) for j in range(30)], 'stage': 2,
                                      'made': {'packs': [{'item': 'automation-science-pack', 'total': 200}, {'item': 'logistic-science-pack', 'total': 40 if ti < 2 else 0}]}},
                          'space': {'rockets': 0}, 'viewers': viewers, 'viewers_status': {'delivery': delivery},
                          'board': {'doing_items': [{'id': i + 1, 'title': ['Iron smelting and coal power', 'Red science and labs', 'Belts to the furnaces'][i], 'owner': CAST[team][i][0]} for i in range(per)]},
                          'basemap': {'tick': tick - 600, 'x0': bx - 88, 'y0': by - 60, 'w': 44, 'h': 30, 'cell': 4, 'rows': [''.join(r) for r in grid]}}
            scores[team] = {'tick': tick, 'research': TECHS[:done],
                            'entities': {'burner-mining-drill': 4 + ti % 2, 'electric-mining-drill': max(0, step // 12 - ti), 'stone-furnace': 6 - ti + step // 10,
                                         'assembling-machine-1': max(0, 3 - ti + step // 14), 'steam-engine': 2, 'lab': max(1, 3 - ti + step // 20)}}
        views = {'contacts': [{'kind': 'chart', 'team': 'yellow', 'other': 'green', 'tick': 180000 + 19 * 300},
                              {'kind': 'chart', 'team': 'green', 'other': 'yellow', 'tick': 180000 + 19 * 300}] if step >= 19 else [],
                 'pacts': [], 'diplomacy': [{'kind': 'diplomacy', 'from_team': a, 'to_team': b, 'agent': CAST[a][who][0], 'text': text, 'tick': 180000 + at * 300, 'seq': n + 1}
                                            for n, (at, a, who, b, text) in enumerate(TALKS) if at <= step and who < per]}
        if step >= 24:
            views['pacts'].append({'id': 3, 'a': 'yellow', 'b': 'green', 'status': 'active' if step >= 26 else 'proposed',
                                   'proposed_tick': 180000 + 24 * 300, 'accepted_tick': 180000 + 26 * 300})
        frame, camera = assemble(race, director, rosters, raws, scores, views, now, camera,
                                 f'Synthetic replay · {teams} teams × {per} agents · invented lines')
        frames.append(frame)
    return frames


def assemble(race, director, rosters, raws, scores, views, now, camera, fixture):
    """One frame the way PublicOverlay.poll builds it; the camera 'cut' always succeeds."""
    rows = [project(team, raws[team], rosters[team], now, scores.get(team)) for team in rosters]
    talks = diplomacy(views.get('diplomacy'), rows)
    data = race.update(rows, now, views.get('contacts') or [], views.get('pacts') or [], talks)
    fresh = {t: raws[t] for t, r in zip(rosters, rows) if not r['stale']}
    data.update(v=2, now=now, diplomacy=talks, layout={'camera': list(CAMERA_RECT)}, fixture=fixture, **audience(fresh, rosters, now))
    scout = {t: subjects(raw, {a['name'] for a in rosters[t]}, now) for t, raw in fresh.items()}
    choice = director.choose(rows, data['events'], now, scout)
    if choice:
        team, reason = choice
        shot = shots(raws[team], director.best(scout.get(team)))[0]
        director.success(team, now, shot['agent'])
        camera = {'team': team, 'surface': 'nauvis', 'since': now, 'reason': reason, 'agent': shot['agent'], 'kind': shot['kind']}
    data['camera'] = camera
    return copy.deepcopy(data), camera


# ---- a finished run, rebuilt from its own logs -------------------------------------------------------------------------
def epoch(text):
    return datetime.fromisoformat(str(text).replace('Z', '+00:00')).timestamp()


def jsonl(path):
    out = []
    opener = gzip.open if str(path).endswith('.gz') else open
    try:
        with opener(path, 'rt') as f:
            for line in f:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        pass
    return out


def journal(path):
    """One agent's requests with their replies: [{t, end, tick, action, args, ok, result}]."""
    asked, out = {}, []
    for r in jsonl(path):
        if r.get('event') == 'request' and isinstance(r.get('request'), dict):
            asked[r['request'].get('id')] = (epoch(r['at']), r['request'])
        elif r.get('event') == 'response' and isinstance(r.get('response'), dict):
            resp = r['response']
            t, q = asked.pop(resp.get('id'), (None, None))
            if q:
                out.append({'t': t, 'end': epoch(r['at']), 'tick': resp.get('tick'), 'action': q.get('action'),
                            'args': q.get('args') if isinstance(q.get('args'), dict) else {},
                            'ok': bool(resp.get('ok')), 'result': resp.get('result') if isinstance(resp.get('result'), dict) else {}})
    return out


def timeline(calls):
    """What the stream feed would have said of this agent, from its journal: spans in which an action ran
    (the reply's until_tick or hand_s; a moment for an instant call), rests, positions, and the request
    that last changed the map. Reads, speech and board calls are not actions."""
    spans, rests, spots, dids = [], [], [], []
    for c in calls:
        kind, res, args = c['action'], c['result'], c['args']
        p = args.get('position') if isinstance(args.get('position'), dict) else None
        here = re.search(r'where you stand \((-?[0-9.]+),(-?[0-9.]+)\)', str(res.get('logistics_here') or ''))
        if here:
            spots.append((c['end'], float(here.group(1)), float(here.group(2))))
        if kind == 'sleep' and c['ok']:
            rests.append((c['end'], c['end'] + float(res.get('sleeping_s') or args.get('seconds') or 0)))
        if not c['ok'] or verb_class(kind) is None or kind in ('research',):
            continue
        ticks = (res.get('until_tick') - c['tick']) if isinstance(res.get('until_tick'), (int, float)) and isinstance(c['tick'], (int, float)) else None
        seconds = ticks / 60 if ticks else float(res.get('hand_s') or 0)
        item = args.get('item') or args.get('recipe')
        spans.append({'t': c['end'], 'end': c['end'] + max(3.0, min(seconds, 90.0)), 'kind': kind,
                      'active': kind + (':' + item if isinstance(item, str) else ''), 'to': p})
        if p and all(isinstance(p.get(k), (int, float)) for k in ('x', 'y')):
            spots.append((spans[-1]['end'] if kind == 'move_to' else c['end'], float(p['x']), float(p['y'])))
            if kind in ('build', 'place', 'deconstruct'):
                dids.append((c['end'], float(p['x']), float(p['y']), kind))
    return {'spans': spans, 'rests': rests, 'spots': sorted(spots), 'dids': dids}


def agent_at(line, now, heat):
    """The feed row of one agent at a moment (activity, active, position, interest, idle_s, did)."""
    span = next((s for s in reversed(line['spans']) if s['t'] <= now < s['end']), None)
    last = max((min(s['end'], now) for s in line['spans'] if s['t'] <= now), default=None)
    resting = any(a <= now < b for a, b in line['rests'])
    i = bisect.bisect_right(line['spots'], (now, 1e18, 1e18)) - 1
    spot = line['spots'][i] if i >= 0 else (line['spots'][0] if line['spots'] else None)
    did = next((d for d in reversed(line['dids']) if d[0] <= now and now - d[0] <= 120), None)
    idle = None if last is None else max(0.0, now - last)
    activity = 'acting' if span else 'resting' if resting else 'thinking' if idle is not None and idle < 25 else 'idle'
    return {'activity': activity, 'active': span['active'] if span else False, 'surface': 'nauvis', 'alive': True,
            'position': {'x': spot[1], 'y': spot[2]} if spot else None, 'interest': round(heat, 2),
            'idle_s': 0.0 if span else idle,
            'did': {'action': did[3], 't': did[0], 'position': {'x': did[1], 'y': did[2]}, 'surface': 'nauvis'} if did else None}


def profiles_of(tree, run):
    """The agents' own `profile` choices (name, colour, glyph, motto), from their journals back along the
    resumed-from chain: a profile set in an earlier run is still the agent's in the runs resumed from it."""
    chain, out = [], {}
    while run and run not in chain:
        chain.append(run)
        try:
            run = (tree / 'runs' / run / 'resumed-from').read_text().strip()
        except OSError:
            break
    for name in reversed(chain):
        for path in sorted((tree / 'runs' / name).glob('*/*/journal.jsonl.gz')):
            for c in journal(path):
                if c['action'] == 'profile' and c['ok'] and c['args']:
                    row = out.setdefault(path.parent.name, {'profile_set': True})
                    row.update({k: c['result'][k] for k in ('display_name', 'color', 'glyph', 'motto', 'pronouns', 'avatar')
                                if c['result'].get(k) is not None})
    return out


def recorded(op, tree=None, step=5.0, label=None, profiles=None):
    """Frames every `step` seconds over a finished run. op: runs/RUN/op of the operator's worktree; tree: the
    launch tree (default: the path op/launch-tree names), whose runs/RUN/TEAM/AGENT/journal.jsonl.gz hold
    what each agent did and said. profiles: {agent: {display_name, color, glyph, motto, ...}} as the run's
    feeds carried them (the logs do not record profiles)."""
    op = Path(op)
    run = op.parent.name
    tree = Path(tree) if tree else Path((op / 'launch-tree').read_text().strip())
    rosters, lines, calls = {}, {}, {}
    for row in (op / 'teams.tsv').read_text().splitlines():
        f = row.split('\t')
        if row.strip() and not row.startswith('#') and len(f) >= 8 and (op / f[0]).is_dir():
            rosters.setdefault(f[0], []).append({'name': f[1], 'model': f[6], 'harness': f[7]})
    for team, agents in rosters.items():
        for a in agents:
            calls[a['name']] = journal(tree / 'runs' / run / team / a['name'] / 'journal.jsonl.gz')
            lines[a['name']] = timeline(calls[a['name']])
    profiles = profiles_of(tree, run) if profiles is None else profiles
    stamps = sorted((c['end'], c['tick']) for cs in calls.values() for c in cs if isinstance(c['tick'], (int, float)))
    if not stamps:
        raise SystemExit('no journals with ticks under ' + str(tree / 'runs' / run))
    times, ticks = [s[0] for s in stamps], [s[1] for s in stamps]

    def tick_at(now):
        i = bisect.bisect_right(times, now) - 1
        if i < 0:
            return ticks[0]
        if i >= len(times) - 1:
            return ticks[-1] + (now - times[-1]) * 60
        span = times[i + 1] - times[i]
        return ticks[i] + (ticks[i + 1] - ticks[i]) * ((now - times[i]) / span if span else 0)

    def time_of(tick):
        i = bisect.bisect_right(ticks, tick) - 1
        return times[0] - (ticks[0] - tick) / 60 if i < 0 else times[i] + (tick - ticks[i]) / 60

    # Team talk from the chat log (viewer lines stay in the viewer lane); tells from the senders' journals.
    chats = {team: [] for team in rosters}
    for team, agents in rosters.items():
        names = {a['name'] for a in agents}
        for m in jsonl(op / team / 'chat.jsonl'):
            if m.get('viewer') or m.get('from') not in names or not isinstance(m.get('tick'), (int, float)):
                continue
            chats[team].append({'seq': m.get('seq'), 'tick': m['tick'], 'from': m['from'], 'agent': m['from'], 'text': m.get('text'),
                                't': time_of(m['tick']), 'lane': 'talk'})
        for a in agents:
            for c in calls[a['name']]:
                if c['action'] == 'tell' and c['ok'] and isinstance(c['result'].get('seq'), int):
                    to = c['result'].get('to') or c['args'].get('to')
                    body = c['args'].get('summary') or c['args'].get('text')
                    chats[team].append({'seq': f"t{c['result']['seq']}", 'tick': c['tick'], 'from': a['name'], 'agent': a['name'], 'tell': True,
                                        'lane': 'tell', 'to': to if isinstance(to, list) else [to], 'body': body, 'text': 'ignored', 't': c['end']})
        chats[team].sort(key=lambda m: m['tick'])
    scores = {team: [r['score'] for r in jsonl(op / team / 'scores.jsonl') if isinstance(r.get('score'), dict) and r['score'].get('tick') is not None] for team in rosters}
    view = json.loads((op / 'views.json').read_text()) if (op / 'views.json').exists() else {}
    race, director, frames, camera = Race(), Director(), [], None
    heat = {name: 0.0 for name in calls}
    seen = {name: 0 for name in calls}
    now, end = times[0] + 20, times[-1]
    while now <= end:
        tick = tick_at(now)
        raws, score_rows = {}, {}
        for team, agents in rosters.items():
            rows_ = []
            for a in agents:
                name, spans = a['name'], lines[a['name']]['spans']
                heat[name] *= 0.5 ** (step / HALF_LIFE)
                while seen[name] < len(spans) and spans[seen[name]]['t'] <= now:
                    heat[name] = min(30.0, heat[name] + WEIGHT.get(spans[seen[name]]['kind'], 1.0))
                    seen[name] += 1
                row = dict(agent_at(lines[name], now, heat[name]), name=name)
                row.update((profiles or {}).get(name) or {})
                rows_.append(row)
            prior = [s for s in scores[team] if s['tick'] <= tick]
            score = prior[-1] if prior else None
            raws[team] = {'now': now, 'tick': tick, 'agents': rows_, 'chat': [m for m in chats[team] if m['tick'] <= tick][-12:],
                          'research': {'current': score.get('current_research') if score else None,
                                       'done_count': len(score.get('research_done') or []) if score else None},
                          'space': {'rockets': score.get('rockets') if score else None}}
            if score:
                score_rows[team] = {'tick': score['tick'], 'research': score.get('research_done') or [], 'entities': score.get('entities') or {},
                                    'rockets': score.get('rockets')}
        pacts = []
        for p in view.get('pacts') or []:
            if not isinstance(p.get('proposed_tick'), (int, float)) or p['proposed_tick'] > tick:
                continue
            row = {k: p.get(k) for k in ('id', 'a', 'b', 'proposed_tick', 'accepted_tick', 'ended_tick')}
            if isinstance(p.get('ended_tick'), (int, float)) and p['ended_tick'] <= tick:
                row['status'] = p.get('status')
            elif isinstance(p.get('accepted_tick'), (int, float)) and p['accepted_tick'] <= tick:
                row['status'] = 'active'
            else:
                row['status'] = 'proposed'
            pacts.append(row)
        views = {'contacts': [c for c in view.get('contacts') or [] if isinstance(c.get('tick'), (int, float)) and c['tick'] <= tick],
                 'pacts': pacts, 'diplomacy': []}
        frame, camera = assemble(race, director, rosters, raws, score_rows, views, now, camera, label or f'Replay · {run} logs')
        frames.append(frame)
        now += step
    return frames


def serve(path, port):
    frames = json.loads(path.read_text())
    start = time.monotonic()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            parsed = urllib.parse.urlsplit(self.path)
            if parsed.path == '/state.json':
                query = urllib.parse.parse_qs(parsed.query)
                try:
                    index = int(query.get('frame', [int((time.monotonic() - start) / 2) % len(frames)])[0])
                except ValueError:
                    self.send_error(400)
                    return
                body, mime = json.dumps(rebase(frames[max(0, min(index, len(frames) - 1))], time.time())).encode(), 'application/json'
            else:
                found = asset(parsed.path)
                if not found:
                    self.send_error(404)
                    return
                body, mime = found
            self.send_response(200)
            self.send_header('Content-Type', mime)
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', port), Handler)
    print(f'Replay only: http://127.0.0.1:{port}/ ({len(frames)} frames)', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def rebase(frame, now):
    """A recorded frame, with its wall-clock stamps moved to `now` (the page ages viewer lines and news)."""
    state = copy.deepcopy(frame)
    shift = now - state['now']
    state['now'] = now
    for m in state.get('viewers', []):
        m['t'] += shift
    for m in state.get('feed', []) + state.get('events', []):
        if isinstance(m.get('at'), (int, float)):
            m['at'] += shift
    for r in (state.get('viewer_delivery') or {}).values():
        r['t'] = now
    if state.get('camera'):
        state['camera']['since'] += shift
    return state


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--write', type=Path)
    ap.add_argument('--teams', type=int, default=3, choices=(2, 3, 4))
    ap.add_argument('--agents', type=int, default=2, choices=(1, 2, 3))
    ap.add_argument('--run', type=Path, help="a finished run's op directory")
    ap.add_argument('--tree', type=Path, help='its launch tree (default: op/launch-tree)')
    ap.add_argument('--profiles', type=Path, help='JSON {agent: profile fields} the run carried')
    ap.add_argument('--label')
    ap.add_argument('--serve', type=Path)
    ap.add_argument('--port', type=int, default=8796)
    args = ap.parse_args()
    if args.write:
        if args.run:
            frames = recorded(args.run, args.tree, label=args.label, profiles=json.loads(args.profiles.read_text()) if args.profiles else None)
        else:
            frames = synthetic(args.teams, args.agents)
        args.write.write_text(json.dumps(frames, separators=(',', ':')))
        print(f'{len(frames)} frames, {args.write.stat().st_size} bytes: {args.write}')
    elif args.serve:
        serve(args.serve, args.port)
    else:
        ap.print_help()
