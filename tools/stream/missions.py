"""Dated mission coverage from existing stream observations; no game reads or model calls.

A mission is a ship and directed leg (including its departure tick). Only capture-completed
Rook lines establish milestones. State follows resumed-from, never an unrelated run.
"""
import copy
import hashlib
import math
import json
import os
import re
import time

MAX_AGE = 45
EVERY = 180
RETRY = 60
MILESTONES = (10, 25, 50, 75, 90)


def label(value):
    words = str(value or '').replace('-', ' ')
    return {'shattered planet': 'Shattered Planet', 'solar system edge': 'Solar system edge'}.get(words, words.capitalize())


def named(name, text):
    return bool(name and re.search(r'(?<![\w-])' + re.escape(name) + r'(?![\w-])', str(text or ''), re.I))


def mission_claim(name, text):
    """Keep provenance when the analyst uses 'the ship' instead of repeating its name."""
    return named(name, text) or bool(re.search(
        r'\b(?:ship|voyage|flight|leg|asteroids?|ammunition|ammo|thrusters?|railgun|repair|repairs)\b', str(text), re.I))


def metric(s, now):
    m = s.get('mission_metrics') or s.get('platform_metrics') or {}
    # Missing acquisition time fails closed; never freshen an old snapshot at receipt.
    at = m.get('sample_t')
    if (not isinstance(at, (int, float)) or not 0 <= now - at <= MAX_AGE or s.get('paused') or m.get('paused')
            or m.get('platform_paused')):
        return None
    name = m.get('platform')
    feature = s.get('featured_platform') or {}
    goals = ((s.get('board') or {}).get('plan') or {}).get('goals')
    if not ((feature.get('status') == 'active' and feature.get('name') == name) or named(name, goals)):
        return None
    p = next((p for p in (s.get('space') or {}).get('platforms') or [] if p.get('name') == name), None)
    if not p:
        return None
    leg = m.get('leg') or {}
    route = p.get('route_ids')
    if route and route != [leg.get('from'), leg.get('to')]:
        return None
    if not leg.get('start_tick') or not leg.get('to'):
        return None
    return m


def identity(m):
    leg = m['leg']
    return json.dumps([m['platform'], leg.get('from'), leg.get('to'), leg.get('back'), leg['start_tick']])


def context(s, now):
    """Bounded current Goals, dated existing speech/work/chronicle, and fresh voyage facts for analyst/hosts."""
    plan = (s.get('board') or {}).get('plan') or {}
    out = {'goals': str(plan.get('goals') or '')[:1200], 'run_target': s.get('run_target'),
           'projects': [{k: p[k] for k in ('name', 'agent', 'text', 'tick') if k in p}
                        for p in (plan.get('doing') or [])[:12]],
           'rule': ('Goals are intent; dated reports are history, not current telemetry. Never infer repair success. '
                    'Voyage rates are per wall minute; speed is km per game second. ETA is estimated wall seconds '
                    'at current speed and UPS. Ammo buffer uses hub and loaded stock with net production/consumption '
                    '(including crafting), not endurance or guaranteed gun feeding. Structure losses exclude foundation.')}
    m = metric(s, now)
    if m:
        out['voyage_sample'] = {k: copy.deepcopy(v) for k, v in m.items() if k != 'asteroids'}
        out['voyage_sample']['age_s'] = round(now - m['sample_t'], 1)
    feature = s.get('featured_platform') or {}
    name = (m or {}).get('platform') or feature.get('name')
    out['dated_mission_facts'] = [{k: r[k] for k in ('tick', 'game_time', 'platform', 'kind', 'line', 'title', 'text') if k in r}
                                  for r in (s.get('chronicle') or {}).get('events', []) +
                                  (s.get('chronicle') or {}).get('entries', [])
                                  if r.get('tick') is not None and (r.get('platform') == name or
                                     named(name, str(r.get('text') or '') + str(r.get('line') or ''))) ][-6:]
    out['recent_speech'] = [{'agent': a.get('display_name') or a.get('name'), **a['last_said']}
                            for a in s.get('agents') or [] if (a.get('last_said') or {}).get('text') and
                            0 <= now - (a['last_said'].get('t') or 0) <= 180 and
                            named(name, a['last_said']['text'])][-3:]
    return out


def analyst_source(s, now):
    m = metric(s, now)
    if not m:
        return None
    from commentary_freshness import fingerprint
    return {'platform': m['platform'], 'sample_t': m['sample_t'],
            'revision': fingerprint({k: v for k, v in m.items() if k not in ('age_s', 'sample_t', 'asteroids')})}


def digest_context(s, now, limit=6000):
    data = context(s, now)
    # Bound the added input to existing analyst calls, retaining Goals and the sampled voyage first.
    for key in ('projects', 'dated_mission_facts', 'recent_speech'):
        while data.get(key) and len(json.dumps(data, ensure_ascii=False)) > limit:
            data[key].pop()
    text = json.dumps(data, ensure_ascii=False)
    if len(text) > limit:
        data.pop('voyage_sample', None)  # oversized/malformed observations are not a reason to grow prompts
        text = json.dumps(data, ensure_ascii=False)
    if len(text) > limit:
        data.pop('run_target', None)
        text = json.dumps(data, ensure_ascii=False)
    return text


def cues(s, m, now):
    name = m['platform']
    repairs = [w for w in s.get('work') or [] if w.get('platform') == name and
               0 <= now - (w.get('t') or 0) <= 30 and any(x in ' '.join(str(w.get(k) or '') for k in
               ('kind', 'action', 'verb', 'label')).lower() for x in ('repair', 'build', 'construct'))]
    p = next((p for p in (s.get('space') or {}).get('platforms') or [] if p.get('name') == name), {})
    surface = (p.get('view') or {}).get('surface')
    repairing = [a for a in s.get('agents') or [] if a.get('alive') and
                 str(a.get('active') or '').split(':')[0] == 'repair' and
                 ((surface and a.get('surface') == surface) or (a.get('attention') or {}).get('platform') == name)]
    danger = p.get('danger') or {}
    fire = danger.get('kind') == 'fire' and 0 <= now - (danger.get('last') or 0) <= 30
    return bool(repairs or repairing), fire


def guard(kind, s, m, now):
    """Only facts actually spoken in this pair. No percentage noise can retract a repair observation."""
    if kind.startswith('ammo:'):
        return ammo_lines(m, kind.split(':', 1)[1])
    if kind.startswith('report:'):
        return dict(reports(s, m, now)).get(kind)
    repair, fire = cues(s, m, now)
    damage = (m.get('hits_min') or 0) > 0 or (m.get('damage_taken') or 0) > 0
    if kind == 'first-loss':
        return m.get('losses_leg')
    if kind == 'repair':
        return repair
    if kind == 'damage':
        return [fire, damage]
    if kind == 'empty':
        return sum(g.get('empty', 0) for g in (m.get('turrets') or {}).values())
    if kind == 'recovery':
        return [m.get('hits_min') == 0, m.get('damage_taken') == 0, not fire]
    if kind.startswith(('negative:', 'recovered:')):
        ammo = next((a for a in m.get('ammo') or [] if a['name'] == kind.split(':', 1)[1]), {})
        net = ammo.get('net_min')
        return None if net is None else net < 0
    pct = m['leg'].get('pct')
    if kind.startswith('progress:'):
        return pct is not None and pct >= int(kind.split(':')[1])
    return None if pct is None else [f'{pct:.1f}', progress_meaning(s, m)]


def ammo_lines(m, ammo):
    a = next((a for a in m.get('ammo') or [] if a.get('name') == ammo), {})
    keys = ('made_min', 'used_min', 'hub', 'turrets')
    if not all(isinstance(a.get(k), (int, float)) and math.isfinite(a[k]) and a[k] >= 0 for k in keys):
        return None
    if not (a['made_min'] or a['used_min']):
        return None
    made, used, hub, loaded = (f"{a[k]:,.0f}" for k in keys)
    return [f"{m['platform']}: {ammo.replace('-', ' ')} made {made}, used {used} per wall minute in the latest sample.",
            f"Reserves: {hub} in the hub and {loaded} loaded in turrets. Use includes crafting; stock does not prove every gun is fed."]


def reports(s, m, now):
    """Short, verbatim, dated agent statements; never turn a plan or trial into a result."""
    agents = {a['name']: a.get('display_name') or a['name'] for a in s.get('agents') or []}
    rows = list(s.get('chat') or [])
    rows += [dict(a['last_said'], agent=a['name']) for a in s.get('agents') or [] if a.get('last_said')]
    rows += [dict(r, agent=r.get('agent') or r.get('name')) for r in
             ((s.get('board') or {}).get('plan') or {}).get('doing', [])]
    result = {}
    for r in rows:
        tick = r.get('tick')
        agent = r.get('agent')
        text = r.get('body') or r.get('text') or ''
        if agent not in agents or not isinstance(tick, (int, float)) or not named(m['platform'], text):
            continue
        # Game-tick age is explicit for plans; wall dates also constrain chat across pauses.
        if not 0 <= (s.get('tick') or 0) - tick <= 60 * 60 * 60:
            continue
        if r.get('t') is not None and not 0 <= now - r['t'] <= 3600:
            continue
        sentences = re.split(r'(?<=[.!?])\s+', text)
        for i, sentence in enumerate(sentences):
            # Keep ship attribution explicit; retain following result/next-step sentences when they fit.
            if not named(m['platform'], sentence):
                continue
            for following in sentences[i + 1:]:
                if len(sentence) + len(following) + 1 > 260:
                    break
                sentence += ' ' + following
            if not 15 <= len(sentence) <= 260 or not re.search(
                    r'ammo|rail|rocket|feed|iron|refit|test|trial|bottleneck|qualif|next|debug|restor', sentence, re.I):
                continue
            key = 'report:' + hashlib.sha256(f'{agent}:{tick}:{sentence}'.encode()).hexdigest()[:16]
            hours, minutes = divmod(int(tick // 3600), 60)
            result[key] = (tick, f"At game hour {hours}, minute {minutes}, {agents[agent]} reported: {sentence}")
    return [(k, v[1]) for k, v in sorted(result.items(), key=lambda item: item[1][0], reverse=True)]


def progress_meaning(s, m):
    return 'This is distance along the current leg. The destination is still ahead, and arrival has not been confirmed.'


class Missions:
    def __init__(self, run_dir=None):
        self.path = os.path.join(run_dir, 'host-missions.json') if run_dir else None
        self.rows, self.heard, self.attempted = {}, [], 0
        if run_dir:
            import chronicle_log
            for p in chronicle_log.chain(os.path.join(run_dir, 'chronicle.jsonl')):
                try:
                    with open(os.path.join(os.path.dirname(p), 'host-missions.json')) as f:
                        data = json.load(f)
                    self.rows, self.heard = data['missions'], data.get('heard', [])
                    break
                except (OSError, ValueError, KeyError, TypeError):
                    continue

    def event(self, s, now):
        m = metric(s, now)
        if not m or now - self.attempted < RETRY:
            return None
        key = identity(m)
        old = self.rows.get(key, {})
        if now - max([r.get('t', 0) for r in self.rows.values()] or [0]) < EVERY:
            return None
        heard = set(old.get('milestones', []))
        leg, name = m['leg'], m['platform']
        pct = leg.get('pct')
        repair, fire = cues(s, m, now)
        net = {a['name']: a['net_min'] for a in m.get('ammo') or [] if isinstance(a.get('net_min'), (int, float))}
        danger = fire or (m.get('hits_min') or 0) > 0 or (m.get('damage_taken') or 0) > 0
        empty = sum(g.get('empty', 0) for g in (m.get('turrets') or {}).values())
        # Each key corresponds to words in the Rook line, never to unseen candidate observations.
        choices = []
        if m.get('losses_leg', 0) > 0 and 'first-loss' not in heard:
            choices.append(('first-loss', f"{name} has recorded its first structure losses on this leg; the latest count is {m['losses_leg']}.",
                            'That count excludes foundation tiles. It records losses, not the damage still awaiting repair.'))
        if repair and 'repair' not in heard:
            choices.append(('repair', f"Repair or construction work is active aboard {name}.",
                            'That is work in progress. We do not yet have a confirmed repair result.'))
        if danger and 'damage' not in heard:
            text = f"{name} is under asteroid fire." if fire else f"{name}'s latest sampling window records incoming hits or damage."
            choices.append(('damage', text, 'The next samples will show whether those hits continue; they do not tell us the remaining hull health.'))
        if empty and 'empty' not in heard:
            choices.append(('empty', f"{name}'s sample shows {empty} turrets with empty ammunition inventories.",
                            'Those inventories are empty even if ammunition exists elsewhere aboard the ship.'))
        for ammo, rate in net.items():
            word = ammo.replace('-', ' ')
            if rate < 0 and 'negative:' + ammo not in heard:
                choices.append(('negative:' + ammo, f"On {name}, {word} consumption is exceeding production in the latest sample.",
                                'The measured ammunition stock is being drawn down. That is not a prediction of how long the ship can survive.'))
            if rate >= 0 and old.get('net', {}).get(ammo, 0) < 0 and 'recovered:' + ammo not in heard:
                choices.insert(0, ('recovered:' + ammo, f"{name}'s {word} production is now keeping up with measured consumption.",
                                   'That reverses the earlier stock drawdown in this sampling window; it does not prove every gun is supplied.'))
        if old.get('danger') and m.get('hits_min') == 0 and m.get('damage_taken') == 0 and not fire and 'recovery' not in heard:
            choices.insert(0, ('recovery', f"{name}'s latest window records no new hits or damage.",
                               'The earlier hits have stopped in this sample. That does not mean the previous damage has been repaired.'))
        if isinstance(pct, (int, float)):
            crossed = [v for v in MILESTONES if pct >= v and 'progress:' + str(v) not in heard]
            if crossed:
                v = max(crossed)
                choices.append(('progress:' + str(v), f"{name} has passed {v} percent of the leg toward {label(leg['to'])}.",
                                'That measures distance along this leg, not a guarantee of reaching the destination.'))
        # Routine detail uses the existing three-minute slot, even on a slow leg.
        # Rotate ammunition types by last completed Rook report, not by snapshot noise.
        ammo_choices = []
        for a in m.get('ammo') or []:
            lines = ammo_lines(m, a.get('name'))
            if lines:
                kind = 'ammo:' + a['name']
                last = max((r['t'] for r in self.heard if r['platform'] == name and r['milestone'] == kind), default=0)
                buffer = a.get('buffer_min')
                urgency = buffer if isinstance(buffer, (int, float)) and math.isfinite(buffer) else float('inf')
                ammo_choices.append((last, urgency, kind, *lines))
        dated = [(kind, line, 'That is a dated agent report, not a fresh measurement or a confirmed outcome of the next test.')
                 for kind, line in reports(s, m, now) if kind not in heard]
        routine = [(kind, rook, vale) for _, _, kind, rook, vale in sorted(ammo_choices)]
        choices.extend((dated + routine) if old.get('last', '').startswith('ammo:') else (routine + dated))
        # Long outer-system legs move slowly: a new spoken tenth, with at least .05% actual progress.
        if isinstance(pct, (int, float)) and (old.get('pct') is None or
                (pct - old['pct'] >= .05 and f'{pct:.1f}' != f"{old['pct']:.1f}")):
            choices.append(('progress', f"{name} is {pct:.1f} percent along the leg toward {label(leg['to'])}.",
                            progress_meaning(s, m)))
            if not old and not routine and not dated and not (danger or repair or empty or m.get('losses_leg', 0)) and not crossed:
                choices.insert(0, choices.pop())
        if not choices:
            return None
        kind, rook, vale = choices[0]
        return {'kind': 'mission', 'prio': 7, 't': now, 'platform': name, 'mission_id': key,
                'milestone': kind, 'sample_t': m['sample_t'], 'sample_tick': m.get('tick'),
                'guard': guard(kind, s, m, now),
                'lines': [('pbp', rook), ('color', vale)],
                'mission_state': {'pct': pct, 'danger': danger, 'net': net},
                'facts': {'platform': name, 'observation': rook, 'meaning': vale,
                          'sample_tick': m.get('tick'), 'sample_t': m['sample_t']}}

    def invalid(self, e, s, now):
        m = metric(s, now)
        if not m or identity(m) != e.get('mission_id') or now - e['sample_t'] >= MAX_AGE:
            return 'mission sample expired or leg changed'
        # New samples may refresh unchanged spoken facts; changed claims cancel before each push.
        if guard(e['milestone'], s, m, now) != e['guard']:
            return 'mission observation changed'
        return None

    def completed(self, e, now, text, who="pbp"):
        key = e['mission_id']
        row = self.rows.setdefault(key, {})
        if who != 'pbp':
            milestone = e['milestone'] + ':detail'
            if any(r['milestone'] == milestone and r['sample_t'] == e['sample_t'] and r['platform'] == e['platform'] for r in self.heard):
                return
            self.heard.append({'t': now, 'sample_t': e['sample_t'], 'sample_tick': e.get('sample_tick'),
                               'platform': e['platform'], 'milestone': milestone, 'text': text})
            self.save()
            return
        if row.get('t', 0) >= now:
            return
        heard = set(row.get('milestones', []))
        heard.add(e['milestone'])
        if e['milestone'].startswith('progress:'):
            heard.update('progress:' + str(v) for v in MILESTONES if v <= int(e['milestone'].split(':')[1]))
        row.update(copy.deepcopy(e['mission_state']), t=now, milestones=sorted(heard), last=e['milestone'], sample_tick=e.get('sample_tick'))
        self.heard.append({'t': now, 'sample_t': e['sample_t'], 'sample_tick': e.get('sample_tick'),
                           'platform': e['platform'], 'milestone': e['milestone'], 'text': text})
        self.save()

    def save(self):
        self.heard = self.heard[-120:]
        if self.path:
            tmp = self.path + '.tmp'
            with open(tmp, 'w') as f:
                json.dump({'missions': self.rows, 'heard': self.heard}, f, ensure_ascii=False)
            os.replace(tmp, self.path)
