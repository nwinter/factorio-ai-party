"""Facts from the harness's completed surveys, sent by idle_nudge at deadline - 2 h.

No game scans beyond the operator factory_digest read (cached factory counts,
engine vehicle counters, and a small agent loadout read). The
outbox is durable across supervisor restarts; each tell has a stable request ID.
"""
import fcntl
import hashlib
import json
import os
import uuid

PREFIX = "Factory digest (cached): "
LIMIT = 480  # below tell's 500-byte Lua limit, including the prefix
INPUT = {"item_ingredient_shortage", "fluid_ingredient_shortage", "no_input_fluid", "low_input_fluid", "no_ingredients"}
DRY = {"no_minable_resources", "no_resources"}


def at(pos):
    return f"({pos['x']:g},{pos['y']:g})"


def counts(by):
    return ", ".join(f"{n} {name}" for name, n in sorted(by.items(), key=lambda x: (-x[1], x[0])) if n) or "0"


def facts(report):
    rows = []
    for surface in report.get("surfaces", []):
        name = surface["surface"]
        machines = surface.get("machines")
        if machines is None:
            rows.append(f"{name}: {surface.get('survey_unknown', 'no completed survey cached')}.")
        else:
            scope = f"{name}, survey {surface.get('survey_age_s', 0)} game s old"
            dry, short, full, labs, unknown = [], {}, {}, {}, 0
            for proto, m in sorted((machines or {}).items()):
                c, kind = m.get("counts", {}), m.get("type", proto)
                if kind == "mining-drill":
                    n = sum(c.get(k, 0) for k in DRY)
                    if n:
                        positions = [p for k in sorted(DRY) for p in m.get("positions", {}).get(k, [])]
                        shown = sorted(positions, key=lambda p: (p['y'], p['x']))[:3]
                        places = ",".join(at(p) for p in shown)
                        dry.append(f"{n} {proto}" + (f" at {places}" if places else " (positions unavailable)")
                                   + (f" (+{n-len(shown)} unlisted)" if shown and n > len(shown) else ""))
                n = sum(c.get(k, 0) for k in INPUT)
                short[kind] = short.get(kind, 0) + n
                full[kind] = full.get(kind, 0) + c.get("full_output", 0)
                if kind == "lab":
                    for status, n in c.items():
                        if status == "unknown": unknown += n
                        elif status != "working": labs[status] = labs.get(status, 0) + n
            rows.append(f"{scope}: drills reporting no resources: {'; '.join(dry) or '0'}.")
            rows.append(f"{scope}: input shortage: {counts(short)}; output full: {counts(full)}.")
            fuel = []
            for proto, f in sorted((surface.get("fuel") or {}).items()):
                if f.get("type") in ("boiler", "furnace") and (f.get("empty") or f.get("low")):
                    fuel.append(f"{proto}: {f.get('empty', 0)} no fuel, {f.get('low', 0)} burning last buffered fuel")
            rows.append(f"{scope}: boiler/furnace fuel: {'; '.join(fuel) or '0 empty or on last buffered fuel'}; "
                        f"labs not working: {sum(labs.values())} ({counts(labs)})" + (f"; {unknown} labs status unknown" if unknown else "") + ".")
        ends = surface.get("ends") or []
        if ends:
            full_lanes = sum(bool(e['lanes'].get(k)) for e in ends for k in ('left_full', 'right_full'))
            empty = sum(bool(e['lanes'].get(k)) for e in ends for k in ('left_empty', 'right_empty'))
            places = [at(e['position']) for e in ends if any(e['lanes'].get(k) for k in ('left_full', 'right_full'))]
            empty_places = [at(e['position']) for e in ends if any(e['lanes'].get(k) for k in ('left_empty', 'right_empty'))]
            rows.append(f"{name}: {len(ends)} traced belt ends, observations {min(e['age_s'] for e in ends)}–{max(e['age_s'] for e in ends)} game s old: "
                        f"{full_lanes} full lanes" + (f" at {','.join(places[:3])}" if places else "") + f", {empty} empty lanes"
                        + (f" at {','.join(empty_places[:3])}" if empty_places else "") + "; sampled ends only.")
        else:
            rows.append(f"{name}: no belt-end contents observed by trace in the last 5 game min.")
    if not rows:
        rows.append("No completed planetary surveys or recent traced belt-end contents cached.")
    if report.get("more_surfaces"):
        rows.append(f"{report['more_surfaces']} more cached surfaces omitted.")
    rows.extend(report.get("research_use") or [])
    rows.append("Machine counts are cached; belt ends are sampled; equipment/vehicle times are stated above; missing data is unknown."
                if report.get("research_use") else "Cached planets and sampled ends only; missing data is unknown.")
    return rows


def messages(report):
    """Pack facts without truncating a UTF-8 tell. Long facts split at spaces."""
    prefix = f"Factory digest (snapshot tick {report['tick']}; ages at snapshot): " if report.get("tick") is not None else PREFIX
    out, text = [], prefix
    for fact in facts(report):
        for word in fact.split():
            # Prototype/surface names may be arbitrary strings in a modded game.
            while len((prefix + word).encode()) > LIMIT:
                if text != prefix: out.append(text.rstrip()); text = prefix
                cut = word.encode()[:LIMIT-len(prefix.encode())].decode('utf-8', 'ignore')
                out.append(prefix + cut); word = word[len(cut):]
            if len((text + word + ' ').encode()) > LIMIT:
                out.append(text.rstrip()); text = prefix
            text += word + ' '
    if text != prefix: out.append(text.rstrip())
    return out


def save(path, state):
    temp = path + '.tmp'
    with open(temp, 'w') as f:
        json.dump(state, f, ensure_ascii=False)
        f.write('\n'); f.flush(); os.fsync(f.fileno())
    os.replace(temp, path)


class Digest:
    def __init__(self, run_dir, deadline):
        self.path = os.path.join(run_dir, 'factory-digest.json')
        self.log = os.path.join(run_dir, 'factory-digest.jsonl')
        self.deadline = deadline

    def step(self, now, dispatch, manual=False, dry_run=False):
        """One check; never read the factory before due, or after auto delivery.

        A manual request uses its own outbox and does not consume the halfway
        send. A dry run neither sends nor marks the real event delivered.
        """
        if not manual and (self.deadline is None or now < self.deadline-7200 or now >= self.deadline):
            return []
        with open(self.path + '.lock', 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                with open(self.path) as f: state = json.load(f)
            except FileNotFoundError:
                state = {}
            key = 'half'
            if manual:
                key = 'manual'
                # Resume an incomplete manual request, start a new one after it completes.
                if state.get(key, {}).get('done'): state.pop(key)
            job = state.get(key)
            if job and job.get('done') and not dry_run:
                return []
            if not job or dry_run:
                report = dispatch('factory_digest', {})
                job = {'id': hashlib.sha256((os.path.realpath(self.path)+key+uuid.uuid4().hex).encode()).hexdigest()[:24],
                       'created': now, 'tick': report.get('tick'), 'messages': messages(report), 'next': 0}
                if not dry_run:
                    state[key] = job; save(self.path, state)
            sent = []
            for i in range(job['next'], len(job['messages'])):
                text = job['messages'][i]
                entry = {'t': now, 'kind': 'manual' if manual else 'half', 'tick': job['tick'], 'part': i+1, 'text': text}
                try:
                    result = {} if dry_run else dispatch('tell', {'to': 'team', 'text': text}, request_id=f"digest-{job['id']}-{i}")
                    if result.get('cut'): raise RuntimeError('digest tell was truncated')
                    entry.update(sent=not dry_run, dry_run=dry_run, seq=result.get('seq'))
                    if not dry_run:
                        job['next'] = i+1; job['done'] = job['next'] == len(job['messages']); save(self.path, state)
                    sent.append(entry)
                except Exception as e:
                    entry.update(sent=False, error=f'{type(e).__name__}: {e}'[:200])
                    raise
                finally:
                    with open(self.log, 'a') as f: f.write(json.dumps(entry, ensure_ascii=False)+'\n')
            return sent
