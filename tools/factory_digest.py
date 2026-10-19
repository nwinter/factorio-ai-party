"""Facts from the harness's completed surveys, sent by idle_nudge at deadline - 2 h.

(d17 batch35 D2, viewer Aurora) the scheduled digest is a delta: what changed since the last digest (this run's, or
the run it resumed from) among blockers, failed checks (lessons whose check is not met) and decisions needed (items
blocked, requests nobody owns), each told to its owner by board claim; the team gets only what has no owner or needs
anyone (an open request nobody owns). The full census goes on request (--digest-now).

No game scans beyond the operator factory_digest read (cached factory counts,
engine vehicle counters, and a small agent loadout read). The
outbox is durable across supervisor restarts; each tell has a stable request ID.
"""
import fcntl
import hashlib
import json
import os
import re
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


# ---- the delta (d17 batch35 D2, viewer Aurora 12:5x: "Keep routine digests to changed blockers, failed checks and
# needed decisions, routed to their owners. Keep full censuses on demand; reserve team broadcasts for issues needing
# team action.") -----------------------------------------------------------------------------------------------------
DELTA_PREFIX = "Factory digest, changed since the last one"


def moved(was, now):
    """A count that changed enough to say: new, cleared, or by at least 2 and a fifth."""
    if was is None or now == 0 or was == 0:
        return was != now
    return abs(now - was) >= max(2, 0.2 * was)


def inside(pos, area):
    lt, rb = (area or {}).get("left_top") or {}, (area or {}).get("right_bottom") or {}
    return lt and rb and lt["x"] <= pos["x"] <= rb["x"] and lt["y"] <= pos["y"] <= rb["y"]


def owners(surface, positions, claims, held=()):
    """Whom a fact goes to: the owners of the claims holding its positions, else of every claim on its surface, else of
    the items agents hold (claimed, doing, blocked) whose title names the surface (at most 3), else the team. Claims:
    the board's claim items (area, surface, owner)."""
    on = [c for c in claims if c.get("owner") and c.get("surface") == surface and c.get("status") in ("open", "claimed", "doing")]
    hit = sorted({c["owner"] for c in on for p in positions or [] if inside(p, c.get("area"))})
    if hit or on:
        return hit or sorted({c["owner"] for c in on})
    rx = re.compile(r"(?<![\w-])" + re.escape(str(surface).casefold()) + r"(?![\w-])")
    named = sorted({it["owner"] for it in held if it.get("owner") and it.get("status") in ("claimed", "doing", "blocked")
                    and rx.search(str(it.get("title") or "").casefold())})
    return named if 0 < len(named) <= 3 else ["team"]


def current(report, claims=(), blocked=(), requests=(), lessons=(), doing=()):
    """{key: {value, text, to, kind}} for what the delta compares: per surface the drills with no resources, input
    shortage and full output by machine type, boilers and furnaces without fuel, labs not working (blockers); lessons
    whose check is not met (failed checks); items blocked and requests nobody owns (decisions needed)."""
    out = {}
    held = list(blocked) + list(doing)
    for surface in report.get("surfaces", []):
        name, machines = surface["surface"], surface.get("machines")
        if not isinstance(machines, dict):
            continue
        short, full, labs = {}, {}, 0
        for proto, m in sorted(machines.items()):
            c, kind = m.get("counts", {}), m.get("type", proto)
            if kind == "mining-drill":
                n = sum(c.get(k, 0) for k in DRY)
                pos = [p for k in sorted(DRY) for p in (m.get("positions") or {}).get(k, [])]
                if n:
                    shown = sorted(pos, key=lambda p: (p["y"], p["x"]))[:3]
                    out[f"dry|{name}|{proto}"] = {"kind": "blocker", "value": n, "to": owners(name, shown, claims, held),
                                                  "text": f"{name}: {n} {proto} reporting no resources" + (f" at {','.join(at(p) for p in shown)}" if shown else "")}
            short[kind] = short.get(kind, 0) + sum(c.get(k, 0) for k in INPUT)
            full[kind] = full.get(kind, 0) + c.get("full_output", 0)
            if kind == "lab":
                labs += sum(n for st, n in c.items() if st not in ("working", "unknown"))
        surface_to = owners(name, [], claims, held)
        for kind, n in short.items():
            if n:
                out[f"short|{name}|{kind}"] = {"kind": "blocker", "value": n, "to": surface_to, "text": f"{name}: input shortage {n} {kind}"}
        for kind, n in full.items():
            if n:
                out[f"full|{name}|{kind}"] = {"kind": "blocker", "value": n, "to": surface_to, "text": f"{name}: output full {n} {kind}"}
        for proto, f in sorted((surface.get("fuel") or {}).items() if isinstance(surface.get("fuel"), dict) else []):
            n = (f.get("empty") or 0) + (f.get("low") or 0)
            if f.get("type") in ("boiler", "furnace") and n:
                out[f"fuel|{name}|{proto}"] = {"kind": "blocker", "value": n, "to": surface_to,
                                               "text": f"{name}: {proto} {f.get('empty', 0)} no fuel, {f.get('low', 0)} on last buffered fuel"}
        if labs:
            out[f"labs|{name}"] = {"kind": "blocker", "value": labs, "to": surface_to, "text": f"{name}: labs not working {labs}"}
    for ls in lessons:
        st = str(ls.get("state") or "")
        if ls.get("check") and st.startswith("unresolved"):
            out[f"lesson|{ls['id']}"] = {"kind": "check", "value": 1, "to": [ls.get("owner") or "team"],
                                         "text": f"lesson #{ls['id']} {st}: {str(ls.get('rule') or '')[:120]}"}
    for it in blocked:
        if it.get("status") == "blocked":
            out[f"blocked|{it['id']}"] = {"kind": "decision", "value": 1, "to": [it.get("owner") or "team"],
                                          "text": f"#{it['id']} {it.get('kind')} blocked: {str(it.get('title') or '')[:100]}"}
    for it in requests:
        if it.get("kind") == "request" and it.get("status") == "open" and not it.get("owner"):
            out[f"unowned|{it['id']}"] = {"kind": "decision", "value": 1, "to": ["team"],
                                          "text": f"#{it['id']} request open, no owner: {str(it.get('title') or '')[:100]}"
                                                  + (f" (by {it['requested_by']})" if it.get("requested_by") else "")}
    return out


def delta(prev, cur):
    """[(recipient, kind, text)]: what is new or moved since prev, and what cleared (to whom it went then)."""
    rows = []
    for k, f in cur.items():
        p = (prev or {}).get(k)
        if p is None or moved(p.get("value"), f["value"]):
            note = "" if p is None or f["kind"] != "blocker" else f" (was {p['value']})"
            for to in f["to"]:
                rows.append((to, f["kind"], f["text"] + note))
    for k, p in (prev or {}).items():
        if k not in cur:
            for to in p.get("to") or ["team"]:
                rows.append((to, p.get("kind", "blocker"), "cleared: " + p["text"]))
    return rows


HEAD = {"blocker": "blockers", "check": "failed checks", "decision": "decisions needed", "haul": "your hauls"}


def delta_messages(rows, since, extra=None):
    """{recipient: [tell texts]}: each recipient's rows by heading, packed under LIMIT. extra: {agent: [line]} for that
    agent only (D5's most repeated haul)."""
    by = {}
    for to, kind, text in rows:
        by.setdefault(to, {}).setdefault(kind, []).append(text)
    for agent, lines in (extra or {}).items():
        for line in lines:
            by.setdefault(agent, {}).setdefault("haul", []).append(line)
    out = {}
    for to in sorted(by):
        prefix = f"{DELTA_PREFIX} ({since}): "
        parts = [f"{HEAD[k]}: " + "; ".join(by[to][k]) + "." for k in ("blocker", "check", "decision", "haul") if by[to].get(k)]
        msgs, text = [], prefix
        for word in " ".join(parts).split():
            word = word if len((prefix + word).encode()) <= LIMIT else word.encode()[:LIMIT - len(prefix.encode()) - 1].decode("utf-8", "ignore")
            if len((text + word + " ").encode()) > LIMIT:
                msgs.append(text.rstrip()); text = prefix
            text += word + " "
        if text != prefix:
            msgs.append(text.rstrip())
        out[to] = msgs
    return out


def board_reads(dispatch):
    """The claims, blocked items, open requests, lessons and items held now the delta routes by (operator board reads; an older runtime
    without the operator lessons read gives no failed checks)."""
    def read(action, args, key):
        try:
            return (dispatch(action, args) or {}).get(key) or []
        except Exception:  # noqa: BLE001
            return []
    return (read("board", {"kind": "claim", "limit": 100}, "items"), read("board", {"status": "blocked", "limit": 100}, "items"),
            read("board", {"kind": "request", "status": "open", "limit": 100}, "items"), read("lessons", {"limit": 64}, "lessons"),
            read("board", {"status": ["claimed", "doing"], "limit": 100}, "items"))


def save(path, state):
    temp = path + '.tmp'
    with open(temp, 'w') as f:
        json.dump(state, f, ensure_ascii=False)
        f.write('\n'); f.flush(); os.fsync(f.fileno())
    os.replace(temp, path)


class Digest:
    """extra: optional fn(report) -> {agent: [line]}, lines for that agent only in the delta (D5's hauls)."""

    def __init__(self, run_dir, deadline, extra=None):
        self.run_dir = run_dir
        self.path = os.path.join(run_dir, 'factory-digest.json')
        self.log = os.path.join(run_dir, 'factory-digest.jsonl')
        self.deadline = deadline
        self.extra = extra

    def earlier(self):
        """The last digest's facts: this run's, else the run it resumed from (runs/RUN/resumed-from)."""
        try:
            name = open(os.path.join(self.run_dir, 'resumed-from')).readline().strip()
            with open(os.path.join(os.path.dirname(os.path.abspath(self.run_dir)), name, 'factory-digest.json')) as f:
                return json.load(f).get('last')
        except (OSError, ValueError):
            return None

    def delta_job(self, report, dispatch, state, now):
        """(D2) the scheduled digest: what changed since the last one, each fact to its owner by claim."""
        cur = current(report, *board_reads(dispatch))
        last = state.get('last') or self.earlier()
        if last and last.get('tick') is not None and report.get('tick') is not None:
            since = f"tick {last['tick']}, {max(0, (report['tick'] - last['tick']) // 3600)} game min ago"
        else:
            since = "no earlier digest: what holds now"
        extra = {}
        if self.extra:
            try:
                extra = self.extra(report) or {}
            except Exception:  # noqa: BLE001
                extra = {}
        packed = delta_messages(delta((last or {}).get('facts'), cur), since, extra)
        msgs = [{'to': to, 'text': t} for to, texts in packed.items() for t in texts]
        return msgs, {'tick': report.get('tick'), 't': now, 'facts': cur}

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
                # the full census on request (manual); the scheduled one is the delta, to owners (D2)
                msgs, last = (messages(report), None) if manual else self.delta_job(report, dispatch, state, now)
                job = {'id': hashlib.sha256((os.path.realpath(self.path)+key+uuid.uuid4().hex).encode()).hexdigest()[:24],
                       'created': now, 'tick': report.get('tick'), 'messages': msgs, 'next': 0, 'done': not msgs or None}
                if not dry_run:
                    state[key] = job
                    if last:
                        state['last'] = last
                    save(self.path, state)
            sent = []
            for i in range(job['next'], len(job['messages'])):
                m = job['messages'][i]
                to, text = (m['to'], m['text']) if isinstance(m, dict) else ('team', m)
                entry = {'t': now, 'kind': 'manual' if manual else 'half', 'tick': job['tick'], 'part': i+1, 'to': to, 'text': text}
                try:
                    result = {} if dry_run else dispatch('tell', {'to': to, 'text': text}, request_id=f"digest-{job['id']}-{i}")
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
