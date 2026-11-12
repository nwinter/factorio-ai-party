#!/usr/bin/env python3
"""Offline: what the one public camera would have shown over a finished run, the earlier rule against the
present one. No game, no camera client; every cut is taken to succeed, so this measures the choice alone.

  python3 tools/mt/camera_eval.py /abs/runs/t292/op [--tree /abs/launch-tree] [--out result.json]

The run is rebuilt from its own logs (public_replay.moments): what each agent was doing and where, every five
seconds. Base centres come from the run's own camera log (op/public-stream.log), the points the earlier rule
framed when nobody was acting. For each rule, every step is one of:

  action    an agent with an action running is inside the frame
  standing  agents are in the frame, none of them acting
  empty     no agent in the frame (a base with nobody at it, or open ground)

The earlier rule (mt289, through mt/batch290-cp4): rotate at the dwell, news first, +2 for a team with anyone
acting; frame the first acting agent's position at that moment, else the base centre, else an agent; a fixed
view. The present rule is public_race.Director with subjects() and public_overlay.shots(): follow the agent.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import re

from public_race import project, Race, Director, subjects
from public_overlay import shots, ZOOMS
from public_replay import moments

SCREEN = (1920, 1080)  # the camera client; 32 px a tile at zoom 1


class Earlier:
    """public_race.Director as of mt/batch290-cp4, kept here only as the baseline of this comparison."""
    def __init__(self, dwell=30):
        self.minimum, self.dwell = max(10, min(20, dwell / 2)), dwell
        self.current, self.since, self.shown, self.started = None, 0, {}, None

    def choose(self, teams, events, now):
        if self.started is None:
            self.started = now
        eligible = [r for r in teams if not r['stale'] and not r['paused']]
        if not eligible or (self.current and now - self.since < self.minimum):
            return None
        others = [r for r in eligible if r['team'] != self.current]
        if not others:
            return eligible[0]['team'] if self.current is None else None
        age = lambda r: now - self.shown.get(r['team'], self.started - self.dwell)
        overdue = [r for r in others if age(r) >= self.dwell * max(2, len(teams))]
        if overdue:
            return max(overdue, key=age)['team']
        def interest(r):
            recent = [e for e in events if e['team'] == r['team'] and now - e['at'] <= 40 and e['at'] > self.shown.get(r['team'], -1)]
            weight = max(({'rocket': 10, 'death': 9, 'platform_lost': 9, 'contact': 8, 'pact': 8, 'research': 6, 'build': 4}.get(e['kind'], 0) for e in recent), default=0)
            return weight + 2 * any(a['activity'] == 'acting' for a in r['agents']), weight
        best = max(others, key=lambda r: (interest(r)[0], age(r)))
        if self.current is None or now - self.since >= self.dwell or interest(best)[1]:
            return best['team']
        return None

    def success(self, team, now):
        self.current, self.since = team, now
        self.shown[team] = now

    @staticmethod
    def target(state):
        for a in state.get('agents') or []:
            p = a.get('position') or {}
            if a.get('activity') == 'acting' and p:
                return p['x'], p['y']
        core = (state.get('basemap') or {}).get('core')
        if core:
            return core['x0'] + core['w'] * core['cell'] / 2, core['y0'] + core['h'] * core['cell'] / 2
        for a in state.get('agents') or []:
            if a.get('position'):
                return a['position']['x'], a['position']['y']
        return None


def cores_of(op):
    """Each team's base centre as the run's own camera log framed it: its most repeated fixed target."""
    seen = {}
    try:
        text = (Path(op) / 'public-stream.log').read_text(errors='replace')
    except OSError:
        return {}
    for team, x, y in re.findall(r"^camera: (\w+) \{.*?'x': (-?[0-9.]+), 'y': (-?[0-9.]+)", text, re.M):
        seen.setdefault(team, Counter())[(float(x), float(y))] += 1
    return {team: points.most_common(1)[0][0] for team, points in seen.items() if points.most_common(1)[0][1] >= 3}


def view(centre, zoom, agents):
    """action | standing | empty for a frame centred on `centre` at `zoom`."""
    if not centre:
        return 'empty'
    hw, hh = SCREEN[0] / (32 * zoom) / 2, SCREEN[1] / (32 * zoom) / 2
    inside = [a for a in agents if a.get('position') and abs(a['position']['x'] - centre[0]) <= hw and abs(a['position']['y'] - centre[1]) <= hh]
    return 'action' if any(a['activity'] == 'acting' for a in inside) else 'standing' if inside else 'empty'


def evaluate(op, tree=None, step=5.0):
    cores = cores_of(op)
    race, earlier, present = Race(), Earlier(), Director()
    old = new = None   # the shot on air under each rule
    tally = {'earlier': Counter(), 'present': Counter()}
    cuts, air, acting_steps, steps = Counter(), {'earlier': Counter(), 'present': Counter()}, 0, 0
    for now, rosters, raws, scores, views in moments(op, tree, step, cores=cores):
        rows = [project(team, raws[team], rosters[team], now, scores.get(team)) for team in rosters]
        events = race.update(rows, now, views['contacts'], views['pacts'])['events']
        everyone = [a for raw in raws.values() for a in raw['agents']]
        scout = {t: subjects(raws[t], {a['name'] for a in rosters[t]}, now) for t in rosters}
        team = earlier.choose(rows, events, now)
        if team:
            earlier.success(team, now)
            old = {'team': team, 'at': Earlier.target(raws[team])}
            cuts['earlier'] += 1
        choice = present.choose(rows, events, now, scout)
        if choice:
            shot = shots(raws[choice[0]], present.best(scout.get(choice[0])))[0]
            present.success(choice[0], now, shot['agent'])
            new = dict(shot, team=choice[0], zoom=shot['zooms'][0])
            cuts['present'] += 1
        steps += 1
        acting_steps += any(a['activity'] == 'acting' for a in everyone)
        if old:
            tally['earlier'][view(old['at'], 0.6, everyone)] += 1
            air['earlier'][old['team']] += 1
        if new:
            followed = next((a for a in raws[new['team']]['agents'] if a['name'] == new['agent']), None) if new['kind'] == 'follow' else None
            centre = (followed['position']['x'], followed['position']['y']) if followed and followed.get('position') else (new['x'], new['y'])
            tally['present'][view(centre, new['zoom'], everyone)] += 1
            air['present'][new['team']] += 1
    share = lambda c: {k: round(c[k] / max(1, sum(c.values())), 3) for k in ('action', 'standing', 'empty')}
    return {'run': Path(op).parent.name, 'minutes': round(steps * step / 60, 1), 'base_centres': {t: list(p) for t, p in cores.items()},
            'someone_was_acting': round(acting_steps / max(1, steps), 3),
            'earlier': dict(share(tally['earlier']), cuts=cuts['earlier'], airtime={t: round(n / steps, 2) for t, n in air['earlier'].items()}),
            'present': dict(share(tally['present']), cuts=cuts['present'], airtime={t: round(n / steps, 2) for t, n in air['present'].items()})}


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('op', type=Path, nargs='*', help="one or more finished runs' op directories")
    ap.add_argument('--tree', type=Path)
    ap.add_argument('--out', type=Path)
    args = ap.parse_args()
    if not args.op:
        ap.print_help()
    else:
        results = [evaluate(op, args.tree) for op in args.op]
        text = json.dumps(results, indent=2)
        if args.out:
            args.out.write_text(text + '\n')
        print(text)
