#!/usr/bin/env python3
"""Offline Python/JSON cost and camera scheduling measurements. Never contacts a game."""
import json
import statistics
import time
from public_race import project, Race, Director, subjects
from public_replay import synthetic, CAST


def roster(teams, per):
    return {t: [{'name': n, 'model': m, 'harness': h} for n, m, h, _ in CAST[t][:per]] for t in list(CAST)[:teams]}


def measure(teams=3, per=2, dense=False):
    """One production poll's Python work: project every team, update the race, scout the camera, encode."""
    width = 160 if dense else 40
    rosters = roster(teams, per)
    raws = {}
    for t, agents in rosters.items():
        raws[t] = {'now': 1000, 'tick': 6000, 'research': {'done_count': 12, 'current': 'automation', 'progress': .5},
                   'space': {'rockets': 0}, 'science': {'spm': 18, 'series': list(range(30))},
                   'basemap': {'tick': 6000, 'x0': 0, 'y0': 0, 'w': width, 'h': width, 'cell': 1,
                               'rows': ['.' * width if y % 3 else 'A' * width for y in range(width)]},
                   'agents': [{'name': a['name'], 'display_name': 'Agent ' + a['name'], 'color': '#34a853', 'glyph': 'G', 'motto': 'Mining today, rocket tomorrow',
                               'activity': 'acting', 'active': 'build:lab', 'position': {'x': 1, 'y': 2}, 'surface': 'nauvis', 'interest': 6, 'idle_s': 0} for a in agents],
                   'chat': [{'seq': i, 'tick': 5000 + i, 'from': agents[i % len(agents)]['name'], 'lane': 'talk', 't': 990 + i / 10,
                             'text': 'Iron is flowing. I will put down two more furnaces, then start on gears for the belts.'} for i in range(12)]}
    durations = []
    for _ in range(300):
        start = time.perf_counter()
        rows = [project(t, raws[t], agents, 1000, {'tick': 6000, 'entities': {'lab': 3}}) for t, agents in rosters.items()]
        out = Race().update(rows, 1000)
        for t, agents in rosters.items():
            subjects(raws[t], {a['name'] for a in agents}, 1000)
        wire = json.dumps(out, separators=(',', ':')).encode()
        durations.append((time.perf_counter() - start) * 1000)
    return {'projection_race_scout_json_ms': {'median': round(statistics.median(durations), 3), 'p95': round(sorted(durations)[285], 3)},
            'public_bytes': len(wire), 'browser_KiB_per_minute': round(len(wire) * 30 / 1024, 1)}


def camera(quiet=()):
    """Ten minutes at one choice every five seconds, every cut succeeding. All news goes to green (the unfair
    case); teams in `quiet` stand still, so their turns are glances."""
    teams = synthetic()[4]['teams']
    for t in teams:
        if t['team'] in quiet:
            for a in t['agents']:
                a.update(activity='idle', verb=None)
    director, cuts, on = Director(), [], []
    for now in range(0, 601, 5):
        events = [{'team': 'green', 'kind': 'rocket', 'at': now}]
        choice = director.choose(teams, events, now)
        if choice:
            cuts.append([now, *choice])
            director.success(choice[0], now)
        on.append(director.current)
    gaps = {}
    for t in (r['team'] for r in teams):
        seen = [0] + [c[0] for c in cuts if c[1] == t] + [600]
        gaps[t] = max(b - a for a, b in zip(seen, seen[1:]))
    return {'seconds': 600, 'cuts': len(cuts), 'cuts_per_minute': round(len(cuts) / 10, 1), 'max_gap_seconds': gaps,
            'airtime_share': {t: round(on.count(t) / len(on), 2) for t in gaps}, 'schedule': cuts}


if __name__ == '__main__':
    print(json.dumps({'three_by_two': measure(), 'four_by_three': measure(4, 3), 'dense_160': measure(dense=True),
                      'director_all_busy': camera(), 'director_two_quiet': camera(('yellow', 'blue'))}, indent=2))
