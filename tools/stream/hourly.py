#!/usr/bin/env python3
"""What changed this hour (d25 batch197, analysis/hosts-proposal.md idea E): once an hour, one prepared piece of
60-110 words on the narrator channel, written by one model call from the run folder, checked against its facts, and
aired through tour.py's machinery (prepare/render, the hush file, looks with cut_at, the timeline log). Stdlib only.

  python3 tools/stream/hourly.py dry-run --run-dir runs/shift73 [--hours 4] [--from HH:MM] [--render]
  python3 tools/stream/hourly.py run --run-dir runs/RUN          # the stream's helper (POG_HOURLY=1, start-team.sh)
  python3 tools/stream/hourly.py repeats [--hours 24]            # NP4: analyst lines the 2 h topic rule holds back

NP1 the producer: gather() reads the hour from the run folder: scores.jsonl (rockets, research, lab use, entity and
platform counts, first row of the hour against its last), chronicle.jsonl (research, deaths, platforms created, lost,
renamed, deleted, arrivals with the first ever of a ship at a planet along the resumed-from chain, rockets by planet,
the agents' entries), factory-digest.jsonl, efficiency.jsonl, the analyst's points (tools/stream/logs/analyst-*.jsonl),
the agents' aloud lines (chat.jsonl), plan.json's lines set in the hour, and the attacks and losses the hosts called
(tools/stream/logs/caster-*.jsonl). Each is a numbered row with its source and a weight; the model gets the rows, the
camera targets (our ships by name; planet spots from the chart's labels, inside a building box as the tour build
checked) and the agents' pronouns from the stream state (they/them when none), picks two or three changes and writes
the piece with a facts list, each fact naming its row. The caster's LLMWriter on OpenRouter (Opus 5.5 with reasoning
at low effort: it refuses reasoning off, batch196; or Sonnet 5.5).

NP2 the verifier: check() holds the piece to the tour build's checks (60-110 words, a caption of at most 60
characters, no dashes, a known target) and to its facts: every number (digits, and spelled out above ten, as the
caster's check_line) and every name in the narration is in a fact's claim, every number of a claim is in the row it
names, he or she only for an agent who chose them, no "we", no advice. A piece that fails is written once more with
the reason; one that fails again is dropped with a log line.

NP3 airing (run): the piece is aired as a one- or two-stop tour (tour.Tour: the look with cut_at, the narration at
cut + lead in the tour's narrator voice, the hosts hushed for the piece only), rendered when it can air and dropped
when it is older than MAX_AGE_S. It waits while an attack, a loss or a death is fresh, a battle or an enemy group is
on air, or a look, follow, platform hold or host view of someone else's holds the camera, or a tour runs. With one
camera (no inset to put an attack in) a fresh attack, loss or death ends the piece on air; with more, the attack goes
to the inset and the piece goes on.
"""
import argparse, glob, json, os, re, signal, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import caster  # noqa: E402

LOG_DIR = os.path.join(HERE, "logs")
OUT_DIR = os.path.join(LOG_DIR, "hourly")
FEED = "http://127.0.0.1:8788"
MODEL = "anthropic/claude-opus-5.5"
HOUR_S = 3600.0
MIN_WORDS, MAX_WORDS = 60, 110
CAPTION_MAX = 60
MAX_AGE_S = 600.0  # a piece not on air this long after it was written is dropped
URGENT_S = 120.0  # an attack, loss or death this fresh comes first
URGENT_KINDS = ("attack", "loss", "death")
WAIT_STEP_S = 15.0  # how often a waiting piece looks again
ROWS_MAX = 40  # rows offered to the model, best weight first
PLANETS = ("nauvis", "vulcanus", "fulgora", "gleba", "aquilo")
# Capitalised words a narration may use without them being in its facts: the game and the show's goal.
SHOW_WORDS = {"factorio", "space", "age", "shattered", "planet", "solar", "system", "edge", "narrator"}
ADVICE = re.compile(r"\b(?:should(?:n't)?|ought to|must|needs? to|had better|would do well|it'?s time to|consider\w*|"
                    r"recommend\w*|suggest\w*|the (?:next|right|smart|obvious) (?:step|move|call)|why not|best bet|"
                    r"would be wise|the answer is to)\b", re.I)
TEAM_VOICE = re.compile(r"\b(?:we|we're|we've|we'll|our|ours|us)\b")
GENDERED = {"he": "he", "him": "he", "his": "he", "himself": "he", "she": "she", "her": "she", "hers": "she",
            "herself": "she"}
NUM = re.compile(r"\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?")


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def jsonl(path):
    try:
        with open(path) as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if isinstance(r, dict):
                    yield r
    except OSError:
        return


def iso_epoch(s):
    """'2026-10-25T02:08:43' (local) -> epoch seconds; None when it is not that."""
    try:
        return time.mktime(time.strptime(str(s)[:19], "%Y-%m-%dT%H:%M:%S"))
    except (ValueError, TypeError):
        return None


def hhmm(t):
    return time.strftime("%H:%M", time.localtime(t))


def n(v):
    """A number as a row writes it: 1,215 or 92.3."""
    return f"{v:,}" if isinstance(v, int) else f"{v:,.1f}" if isinstance(v, float) else str(v)


def rel(path):
    """A source as the report names it: from runs/ or tools/ on (the run folder may be in another checkout)."""
    p = os.path.abspath(path)
    for part in (os.sep + "runs" + os.sep, os.sep + "tools" + os.sep):
        if part in p:
            return p[p.rindex(part) + 1:]
    return p


def game_clock(tick):
    """60339736 -> '279h16m' (game time as the chronicle writes it)."""
    mins = int(tick or 0) // 3600
    return f"{mins // 60}h{mins % 60:02d}m"


def nice(name):
    """'production-science-pack' -> 'production science pack'."""
    return str(name).replace("-", " ")


# ---- the material ------------------------------------------------------------------------------------------------
class Material:
    """The hour's rows ({id, kind, key, w, text, source, lead}) and camera targets ({id, target, text})."""

    def __init__(self, run_dir, t0, t1):
        self.run_dir, self.t0, self.t1 = run_dir, t0, t1
        self.rows, self.targets, self.agents, self.notes = [], [], {}, []
        self.game_time = None

    def add(self, prefix, kind, w, text, source, key=None):
        rid = f"{prefix}{1 + sum(1 for r in self.rows if r['id'][:len(prefix)] == prefix and r['id'][len(prefix):].isdigit())}"
        m = NUM.search(text)
        self.rows.append({"id": rid, "kind": kind, "key": key or kind, "w": round(float(w), 1), "text": text,
                          "source": source, "lead": float(m.group().replace(",", "")) if m else None})
        return rid

    def target(self, target, text, source):
        tid = f"T{len(self.targets) + 1}"
        self.targets.append({"id": tid, "target": target, "text": text, "source": source})
        return tid

    def row(self, rid):
        """A row, or a target (its text is a fact too: where a ship is, what a spot shows)."""
        return next((r for r in self.rows + self.targets if r["id"] == rid), None)

    def best(self, k=ROWS_MAX):
        return sorted(self.rows, key=lambda r: (-r["w"], r["id"]))[:k]


def row_at(rows, t):
    """The last of rows ([(epoch, row)], sorted) at or before t, else the first."""
    best = rows[0] if rows else None
    for e, r in rows:
        if e <= t:
            best = (e, r)
        else:
            break
    return best


def scores_part(m, path):
    rows = sorted(((iso_epoch(r.get("t")), r) for r in jsonl(path) if iso_epoch(r.get("t")) and r.get("score")),
                  key=lambda x: x[0])
    if len(rows) < 2:
        return None
    a, b = row_at(rows, m.t0), row_at(rows, m.t1)
    if b[0] - a[0] < 600:
        return None
    (ea, ra), (eb, rb) = a, b
    sa, sb = ra["score"], rb["score"]
    span = f"{rel(path)} rows {ra['t'][11:19]} and {rb['t'][11:19]}"
    mins = (eb - ea) / 60
    prev = row_at(rows, ea - HOUR_S)
    sp = prev[1]["score"] if prev and ea - prev[0] >= 1800 else None
    d = int(sb.get("rockets") or 0) - int(sa.get("rockets") or 0)
    if d or sb.get("rockets"):
        before = int(sa.get("rockets") or 0) - int(sp.get("rockets") or 0) if sp else None
        moved = before is not None and abs(d - before) >= 0.25 * max(before, 1)
        crossed = int(sb.get("rockets") or 0) // 1000 > int(sa.get("rockets") or 0) // 1000
        m.add("S", "rockets", 3 + 2 * moved + 2 * crossed,
              f"{n(d)} rockets launched in these {round(mins)} minutes" + (f" ({n(before)} in the hour before)"
                                                                         if before is not None else "")
              + f"; {n(int(sb['rockets']))} launched in the whole run", span + ", score.rockets", "rockets")
    done = [x for x in sb.get("research_done") or [] if x not in set(sa.get("research_done") or [])]
    for name in done:
        m.add("S", "research", 8, f"research finished: {nice(name)}", span + ", score.research_done", "research:" + name)
    ia, ib = sa.get("infinite") or {}, sb.get("infinite") or {}
    for k, lv in ib.items():
        if isinstance(lv, int) and lv > int(ia.get(k) or 0) and k not in done:
            m.add("S", "research", 6, f"{nice(k)} reached level {lv} (was {int(ia.get(k) or 0)})",
                  span + ", score.infinite", "research:" + k)
    if sb.get("current_research") != sa.get("current_research") and sb.get("current_research"):
        m.add("S", "research_start", 4, f"the labs now research {nice(sb['current_research'])} (before: "
              f"{nice(sa.get('current_research') or 'nothing')})", span + ", score.current_research", "research_now")
    packs = sb.get("current_packs") or []
    ca, cb, pa, pb = sa.get("consumed") or {}, sb.get("consumed") or {}, sa.get("produced") or {}, sb.get("produced") or {}
    used = {p: (int(cb.get(p) or 0) - int(ca.get(p) or 0)) / mins for p in packs}
    if used and all(v >= 0 for v in used.values()):
        sets = min(used.values())
        made = {p: (int(pb.get(p) or 0) - int(pa.get(p) or 0)) / mins for p in packs}
        tight = min(packs, key=lambda p: made[p] / max(used[p], 0.1))
        before = None
        if sp:
            spm = (ea - prev[0]) / 60
            ub = [(int((ca.get(p) or 0)) - int(((sp.get("consumed") or {}).get(p) or 0))) / spm for p in packs]
            before = min(ub) if ub and min(ub) >= 0 else None
        moved = before is not None and abs(sets - before) >= 0.15 * max(before, 1)
        m.add("S", "science", 3 + 3 * moved,
              f"the labs used about {round(sets)} sets of science a minute this hour"
              + (f" (about {round(before)} the hour before)" if before is not None else "")
              + f", researching {nice(sb.get('current_research') or 'nothing')}; the tightest colour, "
              f"{nice(tight)}: {round(made[tight])} made and {round(used[tight])} used a minute",
              span + ", score.consumed and score.produced", "science")
    ea_, eb_ = sa.get("entities") or {}, sb.get("entities") or {}
    changes = sorted(((k, int(eb_.get(k) or 0) - int(ea_.get(k) or 0)) for k in set(ea_) | set(eb_)),
                     key=lambda x: -abs(x[1]))
    small = ("belt", "pole", "pipe", "inserter", "chest", "splitter", "wall", "rail", "lamp")
    for k, dv in [c for c in changes if abs(c[1]) >= (50 if any(w in c[0] for w in small) else 2)][:5]:
        big = any(w in k for w in ("turret", "lab", "silo", "reactor", "beacon", "drill", "assembling", "furnace"))
        m.add("S", "build", 2 + 2 * big, f"{nice(k)}: {n(int(eb_.get(k) or 0))} now, {'+' if dv > 0 else ''}{n(dv)} "
              f"in the hour", span + ", score.entities", "build:" + k)
    pa_, pb_ = {p.get("name") for p in sa.get("platforms") or []}, {p.get("name") for p in sb.get("platforms") or []}
    for name in sorted(pb_ - pa_):
        m.add("S", "platform_new", 7, f"a new platform in the fleet: {name}", span + ", score.platforms", "plat:" + name)
    for name in sorted(pa_ - pb_):
        m.add("S", "platform_gone", 8, f"platform {name} is gone from the fleet", span + ", score.platforms", "plat:" + name)
    for p in sorted(set(sb.get("planets") or []) - set(sa.get("planets") or [])):
        m.add("S", "planet", 10, f"a planet reached for the first time: {p}", span + ", score.planets", "planet:" + p)
    m.game_time = game_clock(sb.get("tick")) if sb.get("tick") else None
    m.fleet = [p for p in sb.get("platforms") or [] if isinstance(p, dict) and p.get("name")]
    m.ticks = (int(sa.get("tick") or 0), int(sb.get("tick") or 0), ea, eb)
    return rows


def chain(run_dir, most=40):
    """The run folders along resumed-from, this one first."""
    out, d = [], run_dir
    while d and os.path.isdir(d) and len(out) < most:
        out.append(d)
        try:
            prev = open(os.path.join(d, "resumed-from")).read().strip()
        except OSError:
            break
        d = os.path.join(os.path.dirname(os.path.abspath(d)), prev) if prev else None
    return out


def chronicle_part(m, run_dir):
    path = os.path.join(run_dir, "chronicle.jsonl")
    src = rel(path)
    seen_at, rows = set(), []
    for d in reversed(chain(run_dir)[1:]):  # every arrival before this shift: the firsts
        for r in jsonl(os.path.join(d, "chronicle.jsonl")):
            if r.get("kind") == "platform_arrived":
                seen_at.add((r.get("platform"), r.get("at")))
    for r in jsonl(path):
        t = float(r.get("t") or 0)
        if t < m.t0:
            if r.get("kind") == "platform_arrived":
                seen_at.add((r.get("platform"), r.get("at")))
            continue
        if t < m.t1:
            rows.append(r)
    rockets, by_cargo, arrivals, routes = {}, {}, 0, {}
    for r in rows:
        k, at = r.get("kind"), f"{src} id {r.get('id')}"
        gt = r.get("game_time")
        if r.get("type") == "entry":
            m.add("C", "entry", 6, f"{r.get('agent')}'s chronicle entry at {gt}, \"{r.get('title')}\": "
                  f"{str(r.get('text') or '')[:400]}", f"{src} entry seq {r.get('seq')}", "entry:" + str(r.get("agent")))
        elif k == "research":
            m.add("C", "research", 8, f"research finished at {gt}: {nice(r.get('name'))}"
                  + (f" (queued by {r['queued_by']})" if r.get("queued_by") else ""), at, "research:" + str(r.get("name")))
        elif k == "death":
            m.add("C", "death", 9, f"{r.get('agent')} died on {r.get('planet') or r.get('surface')} at {gt}"
                  + (f", killed by {nice(r['by'])}" if r.get("by") else ""), at, "death:" + str(r.get("agent")))
            p = r.get("position") or {}
            if r.get("surface") in PLANETS and isinstance(p.get("x"), (int, float)):
                m.target({"surface": r["surface"], "x": p["x"], "y": p["y"], "zoom": 0.6},
                         f"{caster.planet_label(r['surface'])}, where {r.get('agent')} died ({round(p['x'])}, {round(p['y'])})", at)
        elif k == "platform_created":
            m.add("C", "platform_created", 8, f"platform {r.get('platform')} was made at {r.get('at')} at {gt}"
                  + (f" by {r['by']}" if r.get("by") else ""), at, "plat:" + str(r.get("platform")))
        elif k == "platform_lost":
            m.add("C", "platform_lost", 10, f"platform {r.get('platform')} was lost at {gt}, {r.get('where')}"
                  + (f", destroyed by {nice(r['by'])}" if r.get("by") else ""), at, "plat:" + str(r.get("platform")))
        elif k in ("platform_renamed", "platform_deleted"):
            m.add("C", k, 5, str(r.get("line")), at, "plat:" + str(r.get("platform")))
        elif k == "platform_arrived":
            arrivals += 1
            if (r.get("platform"), r.get("at")) not in seen_at:
                m.add("C", "first_arrival", 7, f"{r.get('platform')} reached {r.get('at')} for the first time in the "
                      f"run, at {gt}", at, "first:" + str(r.get("platform")))
            seen_at.add((r.get("platform"), r.get("at")))
        elif k == "platform_left" and r.get("to"):
            key = f"{r.get('at')} to {r.get('to')}"
            routes[key] = routes.get(key, 0) + 1
        elif k == "rocket":
            rockets[r.get("surface")] = rockets.get(r.get("surface"), 0) + 1
            item = str(r.get("cargo") or "").split("*")[0]
            if item:
                by_cargo[item] = by_cargo.get(item, 0) + 1
    if rockets:
        top = sorted(by_cargo.items(), key=lambda x: -x[1])[:3]
        m.add("C", "rockets_by", 3, "rockets this hour by planet: " + ", ".join(
            f"{s} {c}" for s, c in sorted(rockets.items(), key=lambda x: -x[1])) + "; the most sent cargo: "
            + ", ".join(f"{nice(i)} ({c} rockets)" for i, c in top), f"{src}, kind rocket, {len(rows)} rows", "rockets_by")
    if arrivals or routes:
        busy = sorted(routes.items(), key=lambda x: -x[1])[:3]
        m.add("C", "traffic", 2, f"{arrivals} platform arrivals this hour; the busiest routes: "
              + ", ".join(f"{k} ({c})" for k, c in busy), f"{src}, kinds platform_arrived and platform_left", "traffic")


def digest_part(m, run_dir):
    path = os.path.join(run_dir, "factory-digest.jsonl")
    seen = set()
    for r in jsonl(path):
        if not m.t0 <= float(r.get("t") or 0) < m.t1:
            continue
        text = re.sub(r"^Factory digest, changed since the last one \([^)]*\):\s*", "", str(r.get("text") or ""))
        if not text or text in seen:
            continue
        seen.add(text)
        m.add("D", "digest", 4, f"factory digest at {hhmm(float(r['t']))} (to {r.get('to')}): {text[:400]}",
              f"{rel(path)} seq {r.get('seq')}", "digest:" + str(r.get("to")))


def efficiency_part(m, run_dir):
    path = os.path.join(run_dir, "efficiency.jsonl")
    rows = sorted(((float(r.get("t") or 0), r) for r in jsonl(path) if r.get("t")), key=lambda x: x[0])
    if len(rows) < 2:
        return
    (ea, ra), (eb, rb) = row_at(rows, m.t0), row_at(rows, m.t1)
    if eb - ea < 600:
        return
    span = f"{rel(path)} rows {hhmm(ea)} and {hhmm(eb)}"
    ta, tb = ra.get("team") or {}, rb.get("team") or {}
    if tb.get("machines"):  # a shift's first row counts before every machine is read: no comparison with it
        m.add("E", "machines", 2, f"{n(int(tb.get('running') or 0))} of {n(int(tb['machines']))} machines working at "
              f"{hhmm(eb)}" + (f" ({n(int(ta.get('running') or 0))} at {hhmm(ea)})" if ra is not rows[0][1] else ""),
              span + ", team", "machines")
    aa = {x.get("name"): x for x in ra.get("agents") or [] if not x.get("before")}
    made = []
    for x in rb.get("agents") or []:
        if x.get("before") or x.get("name") not in aa:
            continue
        y = aa[x["name"]]
        built = int(x.get("built_logged") or 0) - int(y.get("built_logged") or 0)
        items = int(x.get("items") or 0) - int(y.get("items") or 0)
        if built > 0:
            m.add("E", "built", 4, f"{x['name']} built {built} machine{'s' if built != 1 else ''} this hour "
                  f"({n(int(x.get('machines') or 0))} theirs now)", span + f", agents {x['name']}", "built:" + x["name"])
        made.append((items, x))
    made.sort(key=lambda z: -z[0])
    if made and made[0][0] > 0:
        items, x = made[0]
        top = (x.get("top_items") or [{}])[0].get("item")
        m.add("E", "maker", 3, f"{x['name']}'s machines made the most items this hour: {n(items)}"
              + (f" (their top item over the run: {nice(top)})" if top else ""), span + f", agents {x['name']}", "maker")


def analyst_part(m, logs_dir, most=8):
    """The analyst's points of the hour: one per topic or much the same text (the latest), the best `most` by
    priority, then the newest. The analyst writes the same point again each cycle under a new topic."""
    pts, head = [], None
    for path in sorted(glob.glob(os.path.join(logs_dir, "analyst-*.jsonl"))):
        for r in jsonl(path):
            rep = r.get("reply") or {}
            t = float(rep.get("t") or 0)
            if not m.t0 <= t < m.t1:
                continue
            for p in rep.get("talking_points") or []:
                if isinstance(p, dict) and p.get("text"):
                    pts.append((t, p, rel(path)))
            if rep.get("headline"):
                head = (t, rep["headline"], rel(path))
    kept = []
    for t, p, src in sorted(pts, key=lambda x: x[0]):
        kept = [k for k in kept if caster.topic_key(k[1]) != caster.topic_key(p)
                and not caster.near_same(str(k[1]["text"]), str(p["text"]), 0.5)] + [(t, p, src)]
    kept = sorted(kept, key=lambda x: (-int(x[1].get("priority") or 2), -x[0]))[:most]
    for t, p, src in sorted(kept, key=lambda x: x[0]):
        m.add("A", "analyst", 2 + int(p.get("priority") or 2), f"the analyst at {hhmm(t)} ({p.get('topic')}): {p['text']}",
              f"{src} reply t={round(t)}, topic {p.get('topic')}", "analyst:" + str(p.get("topic")))
    if head:
        m.add("A", "analyst_headline", 3, f"the analyst's headline at {hhmm(head[0])}: {head[1]}",
              f"{head[2]} reply t={round(head[0])}, headline", "analyst_headline")
    if not pts:
        m.notes.append("no analyst points in this hour")


def aloud_part(m, run_dir, per_agent=2):
    path = os.path.join(run_dir, "chat.jsonl")
    by = {}
    for r in jsonl(path):
        t = iso_epoch(r.get("logged_at"))
        if r.get("aloud") and t and m.t0 <= t < m.t1 and r.get("from") and r.get("text"):
            by.setdefault(r["from"], []).append((t, r))
    for name, lines in sorted(by.items()):
        for t, r in lines[-per_agent:]:
            m.add("L", "aloud", 4, f"{name} said aloud at {hhmm(t)}: {str(r['text'])[:400]}",
                  f"{rel(path)} seq {r.get('seq')}", "aloud:" + name)


def plan_part(m, run_dir):
    """plan.json's lines and goals set in the hour (by tick), in the hosts' plain English when host-plain.json has
    the rewrite (hoststory.PlainPlan), else as the agent wrote them."""
    path = os.path.join(run_dir, "plan.json")
    try:
        plan = json.load(open(path))
    except (OSError, ValueError):
        return
    try:
        english = json.load(open(os.path.join(run_dir, "host-plain.json"))).get("english") or {}
    except (OSError, ValueError, AttributeError):
        english = {}
    ta, tb = (getattr(m, "ticks", None) or (None, None))[:2]
    if not ta:
        return

    def said(raw, where):
        plain = english.get(raw)
        return (plain, f"{where} in plain English ({rel(os.path.join(run_dir, 'host-plain.json'))})") if plain else \
            (str(raw)[:300], where)
    for line in plan.get("lines") or []:
        if isinstance(line, dict) and ta <= int(line.get("tick") or 0) < tb and line.get("text"):
            text, src = said(line["text"], f"{rel(path)} lines, {line.get('agent')}")
            m.add("P", "plan", 3, f"{line.get('agent')}'s plan line, set at {game_clock(line['tick'])}: {text}", src,
                  "plan:" + str(line.get("agent")))
    if ta <= int(plan.get("goals_tick") or 0) < tb and plan.get("goals"):
        text, src = said(plan["goals"], f"{rel(path)} goals")
        m.add("P", "goals", 4, f"the team's goals, set this hour: {text[:400]}", src, "goals")


def caster_logs(logs_dir, t0, t1):
    """The caster logs that may hold rows of [t0, t1): started before t1, and the last one started before t0."""
    paths = []
    for p in sorted(glob.glob(os.path.join(logs_dir, "caster-*.jsonl"))):
        mt = re.search(r"caster-(\d{8}-\d{6})\.jsonl$", p)
        if not mt:
            continue
        start = time.mktime(time.strptime(mt.group(1), "%Y%m%d-%H%M%S"))
        if start < t1:
            paths.append((start, p))
    keep = [p for s, p in paths if s >= t0]
    before = [p for s, p in paths if s < t0]
    return before[-1:] + keep


def battles_part(m, logs_dir):
    """The attacks, losses and deaths the hosts called in the hour (the caster logs' beats with their facts)."""
    seen, attacks, losses, deaths, src = set(), {}, [], [], None
    for path in caster_logs(logs_dir, m.t0, m.t1):
        for r in jsonl(path):
            if r.get("type") != "caster" or r.get("event") not in URGENT_KINDS or not r.get("facts"):
                continue
            t = float(r.get("exchange") or r.get("t") or 0)
            if not m.t0 <= t < m.t1 or (r["event"], t) in seen:
                continue
            seen.add((r["event"], t))
            src = rel(path)
            f = r["facts"]
            text, planet = str(f.get("text") or "")[:160], str(f.get("planet") or "somewhere")
            if r["event"] == "attack":
                attacks.setdefault(planet, []).append(text)
            elif r["event"] == "loss":
                losses.append(f"{hhmm(t)} on {planet}: {text}")
            else:
                deaths.append(f"{hhmm(t)} on {planet}: {text}")
    for planet, texts in sorted(attacks.items(), key=lambda x: -len(x[1])):
        kinds = sorted(set(texts), key=texts.count, reverse=True)[:3]
        m.add("B", "attacks", 4, f"{len(texts)} attack{'s' if len(texts) != 1 else ''} on {planet} the hosts called this "
              f"hour, among them: " + "; ".join(kinds), f"{src}, event attack", "attacks:" + planet)
    for x in losses[:4]:
        m.add("B", "loss", 6, f"a loss at {x}", f"{src}, event loss", "loss")
    for x in deaths[:3]:
        m.add("B", "death", 8, f"a death at {x}", f"{src}, event death", "death")


def chart_spots(m, run_dir, most=2):
    """Planet spots where science is made: the middle of each science recipe's labels on a planet, kept when it is
    inside a building box of the chart index (the tour build's check)."""
    out = os.path.join(run_dir, "chart", "out")
    try:
        idx = json.load(open(os.path.join(out, "index.json")))["surfaces"]
    except (OSError, ValueError, KeyError, TypeError):
        return
    for planet in PLANETS:
        cells = (idx.get(planet) or {}).get("cells") or {}
        boxes = [c[4:8] for c in cells.values() if isinstance(c, list) and len(c) >= 8]
        rec = {}
        for path in glob.glob(os.path.join(out, planet, "*.labels.json")):
            try:
                labels = json.load(open(path))
            except (OSError, ValueError):
                continue
            for x, y, r in labels.get("recipes") or []:
                if str(r).endswith("science-pack"):
                    rec.setdefault(r, []).append((x, y))
        for r, pts in sorted(rec.items(), key=lambda kv: -len(kv[1]))[:most]:
            x, y = statistics.median(p[0] for p in pts), statistics.median(p[1] for p in pts)
            if any(b[0] <= x <= b[2] and b[1] <= y <= b[3] for b in boxes):
                m.target({"surface": planet, "x": round(x), "y": round(y), "zoom": 0.5},
                         f"{caster.planet_label(planet)}, where {nice(r)} is made ({len(pts)} machines)",
                         f"{rel(out)}/{planet}/*.labels.json, recipe {r}")


def roster(feed=None, logs_dir=LOG_DIR, state=None):
    """{name: {display, pronouns}}: the stream state's agents (the pronouns they chose; they/them when none), else
    the newest caster log's agent facts."""
    s = state
    if s is None and feed:
        try:
            import urllib.request
            with urllib.request.urlopen(feed.rstrip("/") + "/state.json", timeout=3) as r:
                s = json.load(r)
        except Exception:
            s = None
    out = {}
    for a in (s or {}).get("agents") or []:
        if a.get("name"):
            d = str(a.get("display_name") or a["name"])
            out[a["name"]] = {"display": d[:1].upper() + d[1:], "pronouns": caster.pronouns_of(a)}
    if out:
        return out
    for path in reversed(sorted(glob.glob(os.path.join(logs_dir, "caster-*.jsonl")))[-1:]):
        for r in jsonl(path):
            for a in ((r.get("facts") or {}).get("on_camera") or []):
                if isinstance(a, dict) and a.get("name"):
                    d = str(a["name"])
                    out.setdefault(d.lower().split()[0], {"display": d[:1].upper() + d[1:], "pronouns": caster.pronouns_of(a)})
    return out


def gather(run_dir, t0, t1, logs_dir=LOG_DIR, agents=None):
    """The hour [t0, t1) of run_dir as a Material."""
    m = Material(run_dir, t0, t1)
    m.fleet, m.ticks = [], None
    scores_part(m, os.path.join(run_dir, "scores.jsonl"))
    chronicle_part(m, run_dir)
    battles_part(m, logs_dir)
    digest_part(m, run_dir)
    efficiency_part(m, run_dir)
    analyst_part(m, logs_dir)
    aloud_part(m, run_dir)
    plan_part(m, run_dir)
    for p in m.fleet:
        where = f"at {p.get('at')}" if p.get("at") != "in transit" else f"in transit to {p.get('to')}"
        m.target({"platform": p["name"]}, f"ship {p['name']} ({where} at {hhmm(m.ticks[3])})",
                 f"{rel(os.path.join(run_dir, 'scores.jsonl'))} row {hhmm(m.ticks[3])}, score.platforms")
    chart_spots(m, run_dir)
    m.agents = agents or {}
    return m


# ---- the writer --------------------------------------------------------------------------------------------------
SYSTEM = ("You write one short prepared piece for a livestream of nine AI agents playing Factorio Space Age together: "
          "\"what changed this hour\", read on air by a documentary narrator (measured, warm, unhurried, with a point "
          "of view; never a sportscaster) while the camera holds on the change. You report what happened and why it "
          "matters. You never advise the team, never say what anyone should, must or needs to do, and never set "
          "strategy: the narrator observes.")

RULES = (
    "Pick the two or three changes of this hour that matter most (the weight is a hint, not an order; a death, a "
    "loss, a new ship, finished research or a first arrival usually matters more than a steady count; a quiet hour is "
    "allowed to be about why it was quiet). Write ONE piece of {lo}-{hi} words in total, in one or two stops, each "
    "stop a camera target from the list and the part of the narration said over it.\n"
    "- Narrate a cause and a consequence: what happened, what led to it, what it leads to. Never a reading of numbers: "
    "at most three numbers in the whole piece, rounded as spoken (\"about three hundred\").\n"
    "- A cause or a consequence must come from ONE row that states it (an agent's own reason, the analyst's \"so\"). "
    "Two rows are two separate facts: never join them with \"because\", \"so\", \"which is why\", \"it answers\" or "
    "\"that is what\" unless one of them says the link. Wrong: a research finishing \"answers\" a flaw an agent named, "
    "when no row ties them; a ship's magazines (for asteroids in space) explained by an attack on a planet's walls. "
    "Say each change with its own reason, side by side.\n"
    "- Agents by their names, with the pronouns given (they/them when the list says so). The narrator is not on the "
    "team: no \"we\" or \"our\".\n"
    "- Facts only. Every number and every name you say (agents, ships, planets, items) must be in the claim of one of "
    "your facts, and every claim must restate its row: the row's own numbers, no arithmetic.\n"
    "- Never repeat what the earlier pieces said unless its number moved.\n"
    "- No dashes (no em or en dash), no lists, no stage directions. A caption of at most {cap} characters for each "
    "stop, shown on screen.\n"
    "Reply with JSON only: {{\"changes\": [row ids], \"stops\": [{{\"target\": \"T..\", \"caption\": \"...\", "
    "\"narration\": \"...\"}}], \"facts\": [{{\"claim\": \"...\", \"source\": \"row id\"}}]}}")


def prompt(m, earlier=(), note=""):
    who = "\n".join(f"- {a['display']} ({a['pronouns']})" for _, a in sorted(m.agents.items())) or "- (none known)"
    rows = "\n".join(f"{r['id']} [weight {r['w']:g}] {r['text']}" for r in m.best())
    tg = "\n".join(f"{t['id']} {t['text']}" for t in m.targets) or "(none)"  # a target is a row a fact may name too
    prev = "\n".join(f"- {hhmm(p['window']['to'])}: " + " ".join(s["narration"] for s in p["stops"]) for p in earlier[-2:])
    user = (f"The hour: {hhmm(m.t0)} to {hhmm(m.t1)} local" + (f", game time {m.game_time}" if m.game_time else "") + ".\n"
            f"The agents and their pronouns:\n{who}\n\nWhat changed (row id, weight, the row):\n{rows or '(nothing)'}\n\n"
            f"Camera targets (each is also a row a fact may name):\n{tg}\n\n" + (f"Earlier pieces (do not repeat them):\n{prev}\n\n" if prev else "")
            + RULES.format(lo=MIN_WORDS, hi=MAX_WORDS, cap=CAPTION_MAX) + (f"\n\n{note}" if note else ""))
    return SYSTEM, user


def parse(text):
    """The model's JSON reply -> dict, or None."""
    s = str(text or "")
    a, b = s.find("{"), s.rfind("}")
    if a < 0 or b <= a:
        return None
    try:
        out = json.loads(s[a:b + 1])
    except ValueError:
        return None
    return out if isinstance(out, dict) else None


# ---- the verifier (NP2) ------------------------------------------------------------------------------------------
QUALIFIER = re.compile(r"\b(over|more than|above|at least|nearly|almost|under|just under|fewer than|less than|about|"
                       r"around|roughly|some)\s+(?:a |an )?$")
LOWER = ("over", "more than", "above", "at least")
UPPER = ("nearly", "almost", "under", "just under", "fewer than", "less than")


def said(text):
    """[(value, as said, qualifier)] for the numbers in a narration: digits, and spelled out above ten (one to ten
    are counting words, as the caster's check_line has them), each with the word before it ("over", "nearly")."""
    low, out, at = str(text).lower(), [], 0
    for mt in NUM.finditer(low):
        q = QUALIFIER.search(low[:mt.start()])
        out.append((float(mt.group().replace(",", "")), mt.group(), q.group(1) if q else None))
    for words, v in caster.spelled_numbers(low):
        i = low.find(words, at)
        at = i + len(words) if i >= 0 else at
        q = QUALIFIER.search(low[:i]) if i >= 0 else None
        if v > 10:
            out.append((float(v), words, q.group(1) if q else None))
    return out


def backed(v, q, known):
    """A said number against the facts' numbers: exact (within 1), or a round figure rounded honestly: within 10%,
    from below with over/more than (up to 1.5x), from above with nearly/under (down to 0.85x)."""
    if any(abs(v - k) < 1 for k in known):
        return True
    if not (v >= 10 and v % 10 == 0):
        return False
    if q in LOWER:
        return any(v <= k <= 1.5 * v for k in known)
    if q in UPPER:
        return any(0.85 * v <= k <= v for k in known)
    return any(abs(v - k) <= 0.1 * k for k in known)


def numbers(text):
    """The numbers in a text: digits ("3,600" is one) and spelled out ("two hundred and forty-two")."""
    low = str(text).lower()
    return [float(x.replace(",", "")) for x in NUM.findall(low)] + [float(v) for _, v in caster.spelled_numbers(low)]


def unbacked_name(text, blob, known, any_case=()):
    """A capitalised word the facts do not have: any word mid-sentence, and a known name (an agent, a ship, a planet)
    anywhere; the words of any_case (agents, planets) in lower case too. None when every one is in the facts."""
    toks = re.findall(r"[A-Za-z][\w'’-]*|[.!?:;]", text)
    for i, t in enumerate(toks):
        base = re.sub(r"'s$", "", t.lower().replace("’", "'"))
        if not t[0].isupper() and base not in any_case:
            continue
        if base in caster.CAPS_OK or base in caster.UNITS or base in caster.TENS or base in SHOW_WORDS:
            continue
        if re.search(r"\b" + re.escape(base.rstrip("s")) + r"s?\b", blob):
            continue
        if t[0].isupper() and (i == 0 or toks[i - 1] in ".!?:;") and base not in known:
            continue
        return t
    return None


def known_names(m):
    """The names a narration may only say with a fact: agents, our ships, the planets (lower case words)."""
    names = {w.lower() for a in m.agents.values() for w in re.findall(r"[A-Za-z]+", a["display"])} | set(m.agents)
    return names | {w.lower() for p in getattr(m, "fleet", []) for w in re.findall(r"[A-Za-z]+", p["name"])} | set(PLANETS)


def plain_names(m):
    """Names checked in lower case too: the agents' and the planets' (a ship's name can be a word: Needle, Chalk)."""
    return {w.lower() for a in m.agents.values() for w in re.findall(r"[A-Za-z]+", a["display"])} | set(m.agents) | \
        set(PLANETS)


def check(piece, m):
    """Why the piece cannot air, or None (NP2)."""
    if not isinstance(piece, dict):
        return "the reply is not JSON"
    stops, facts = piece.get("stops"), piece.get("facts")
    if not isinstance(stops, list) or not 1 <= len(stops) <= 2:
        return "one or two stops"
    if not isinstance(facts, list) or not facts:
        return "no facts list"
    tids = {t["id"] for t in m.targets}
    for s in stops:
        if not isinstance(s, dict) or not str(s.get("narration") or "").strip():
            return "a stop without narration"
        if s.get("target") not in tids:
            return f"target {s.get('target')!r} is not in the camera targets"
        if len(str(s.get("caption") or "")) > CAPTION_MAX:
            return f"caption over {CAPTION_MAX} characters"
    text = " ".join(" ".join(str(s["narration"]).split()) for s in stops)
    words = len(text.split())
    if not MIN_WORDS <= words <= MAX_WORDS:
        return f"{words} words (the piece is {MIN_WORDS}-{MAX_WORDS})"
    if re.search("[—–]", text + "".join(str(s.get("caption") or "") for s in stops)):
        return "a dash"
    claims = []
    for i, f in enumerate(facts):
        if not isinstance(f, dict) or not f.get("claim"):
            return f"fact {i + 1} has no claim"
        row = m.row(str(f.get("source") or ""))
        if not row:
            return f"fact {i + 1} names no row ({f.get('source')!r})"
        have = numbers(row["text"])
        for v, w, q in said(f["claim"]):
            if not backed(v, q, have):
                return f"fact {i + 1}: {w} is not in {row['id']}"
        bad = unbacked_name(str(f["claim"]), row["text"].lower(), known_names(m), plain_names(m))
        if bad:
            return f"fact {i + 1}: {bad} is not in {row['id']}"
        claims.append(str(f["claim"]))
    blob = caster.known_text(claims)
    known = set(numbers(blob))
    low = text.lower()
    for v, w, q in said(text):
        if not backed(v, q, known):
            return f"number not in the facts: {(q + ' ') if q else ''}{w}"
    bad = unbacked_name(text, blob, known_names(m), plain_names(m))
    if bad:
        return f"name not in the facts: {bad}"
    named = [a for k, a in m.agents.items() if re.search(r"\b" + re.escape(a["display"].lower()) + r"\b", low)]
    for w in re.findall(r"[a-z]+", low):
        if w in GENDERED and not any(GENDERED[w] in a["pronouns"].split("/") for a in named):
            return f"pronoun {w!r}: no agent named here chose it"
    if TEAM_VOICE.search(low.replace("’", "'")):
        return "speaks as part of the team ('we')"
    if ADVICE.search(low):
        return f"advice ('{ADVICE.search(low).group()}'): the narrator observes"
    return None


def write(m, writer, earlier=(), tries=2):
    """One piece for the hour: written, checked, written once more with the reason, else None. -> (piece, attempts)."""
    note, attempts = "", []
    for k in range(tries):
        system, user = prompt(m, earlier, note)
        spent = writer.spent
        t0 = time.time()
        try:
            raw = writer.complete(system, user, max_tokens=500)
        except Exception as x:
            attempts.append({"why": f"{type(x).__name__}: {str(x)[:200]}", "cost_usd": round(writer.spent - spent, 4)})
            continue
        piece = parse(raw)
        why = check(piece, m)
        attempts.append({"why": why, "cost_usd": round(writer.spent - spent, 4), "seconds": round(time.time() - t0, 1),
                         **({"draft": piece} if why and piece else {"raw": str(raw)[:400]} if why else {})})
        if not why:
            return piece, attempts
        note = (f"Your last draft was refused: {why}. Write the piece again, fixing that and keeping every rule.")
    return None, attempts


def finish(piece, m, run, written, model, attempts):
    """The stored piece: its stops resolved to tour targets, its facts with their rows and sources."""
    tg = {t["id"]: t for t in m.targets}
    pid = f"hourly-{run}-{time.strftime('%Y%m%d-%H%M', time.localtime(m.t1))}"
    stops = [{"id": f"{pid}-{i + 1}", "target": tg[s["target"]]["target"], "target_text": tg[s["target"]]["text"],
              "caption": " ".join(str(s.get("caption") or "").split())[:CAPTION_MAX],
              "narration": " ".join(str(s["narration"]).split())} for i, s in enumerate(piece["stops"])]
    facts = []
    for f in piece["facts"]:
        row = m.row(f["source"])
        facts.append({"claim": f["claim"], "source": f["source"], "row": row["text"], "where": row["source"]})
    return {"id": pid, "run": run, "window": {"from": m.t0, "to": m.t1, "from_local": hhmm(m.t0), "to_local": hhmm(m.t1)},
            "game_time": m.game_time, "written": written, "model": model, "changes": piece.get("changes") or [],
            "stops": stops, "facts": facts, "words": sum(len(s["narration"].split()) for s in stops),
            "cost_usd": round(sum(a.get("cost_usd") or 0 for a in attempts), 4), "attempts": attempts}


def make_writer(model):
    w = caster.LLMWriter("or", model, timeout=40)
    if "opus" in model:
        w.reasoning = {"effort": "low"}  # batch196: Opus 5.5 on OpenRouter refuses reasoning off
    return w


def openrouter_key():
    """OPENROUTER_API_KEY, else the Mac keychain's (as start-team.sh reads it); never printed."""
    if os.environ.get("OPENROUTER_API_KEY"):
        return True
    try:
        k = subprocess.run(["security", "find-generic-password", "-s", "openrouter", "-w"], capture_output=True,
                           text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        k = ""
    if k:
        os.environ["OPENROUTER_API_KEY"] = k
    return bool(k)


def tts_cost(piece, voice="el-brian"):
    """The narration's TTS list price in USD (voices.PRICE: ElevenLabs by character, OpenAI by minute at 2.5 words a
    second)."""
    import voices as V
    unit, rate = V.PRICE[V.provider_of(voice)]
    text = " ".join(s["narration"] for s in piece["stops"])
    return round(rate * (len(text) if unit == "chars" else len(text.split()) / 2.5 / 60), 4)


def piece_md(p):
    out = [f"### {p['window']['from_local']}-{p['window']['to_local']} ({p['id']})", ""]
    if not p.get("stops"):
        out += [f"Dropped: {p.get('dropped')}", ""]
    for s in p.get("stops") or []:
        t = s["target"]
        where = f"ship {t['platform']}" if "platform" in t else f"{t['surface']} ({t['x']}, {t['y']}) zoom {t.get('zoom')}"
        out += [f"Stop {s['id'].rsplit('-', 1)[-1]}: {where}. Caption: \"{s['caption']}\"", "", f"> {s['narration']}", ""]
    if p.get("facts"):
        out += ["Facts:", ""] + [f"- {f['claim']} [{f['source']}: \"{f['row'][:200]}\"; {f['where']}]" for f in p["facts"]] + [""]
    out += [f"{p.get('words', 0)} words; model {p.get('model')}, {len(p.get('attempts') or [])} call(s), "
            f"${p.get('cost_usd', 0):.4f}" + (f"; TTS about ${p['tts_usd']:.4f}" if p.get("tts_usd") is not None else "")
            + "".join(f"; draft {i + 1} refused: {a['why']}" for i, a in enumerate(p.get("attempts") or []) if a.get("why")), ""]
    return "\n".join(out)


def run_start(run_dir):
    rows = [iso_epoch(r.get("t")) for r in jsonl(os.path.join(run_dir, "scores.jsonl"))]
    rows = [t for t in rows if t]
    return (min(rows), max(rows)) if rows else (None, None)


def dry_run(a):
    start, end = run_start(a.run_dir)
    if not start:
        log(f"[hourly] {a.run_dir}: no scores.jsonl rows")
        return 1
    if a.start:
        day = time.strftime("%Y-%m-%d", time.localtime(start))
        start = time.mktime(time.strptime(f"{day} {a.start}", "%Y-%m-%d %H:%M"))
    run = os.path.basename(os.path.abspath(a.run_dir))
    agents = roster(a.feed, a.logs)
    writer = None if a.no_model else (make_writer(a.model) if openrouter_key() else None)
    if not a.no_model and writer is None:
        log("[hourly] no OpenRouter key (OPENROUTER_API_KEY or the keychain's openrouter); gathering only")
    os.makedirs(a.out, exist_ok=True)
    pieces, md = [], [f"# What changed this hour: dry run of {run}", ""]
    for k in range(a.hours):
        t0, t1 = start + k * HOUR_S, start + (k + 1) * HOUR_S
        if t1 > end + 300:
            log(f"[hourly] {hhmm(t0)}-{hhmm(t1)}: past the run's last scores row ({hhmm(end)}); stopping")
            break
        m = gather(a.run_dir, t0, t1, a.logs, agents)
        log(f"[hourly] {hhmm(t0)}-{hhmm(t1)}: {len(m.rows)} rows, {len(m.targets)} targets" +
            (f" ({'; '.join(m.notes)})" if m.notes else ""))
        if writer is None:
            for r in m.best():
                print(f"  {r['id']:4} {r['w']:4g}  {r['text'][:150]}")
            continue
        piece, attempts = write(m, writer, pieces)
        if piece:
            p = finish(piece, m, run, time.time(), a.model, attempts)
            p["tts_usd"] = tts_cost(p)
        else:
            p = {"id": f"hourly-{run}-{time.strftime('%Y%m%d-%H%M', time.localtime(t1))}", "window": {
                "from": t0, "to": t1, "from_local": hhmm(t0), "to_local": hhmm(t1)}, "model": a.model,
                "attempts": attempts, "dropped": "; ".join(str(x.get("why")) for x in attempts),
                "cost_usd": round(sum(x.get("cost_usd") or 0 for x in attempts), 4)}
            log(f"[hourly] {hhmm(t0)}-{hhmm(t1)}: dropped after {len(attempts)} drafts: {p['dropped']}")
        with open(os.path.join(a.out, p["id"] + ".json"), "w") as f:
            json.dump(dict(p, material=m.rows, targets=m.targets), f, indent=1, ensure_ascii=False)
        if piece:
            pieces.append(p)
        md.append(piece_md(p))
        print(piece_md(p))
    if writer is not None:
        cost = sum(p.get("cost_usd") or 0 for p in pieces)
        md.append(f"Model ${cost:.4f} for {len(pieces)} pieces ({sum(len(p.get('attempts') or []) for p in pieces)} calls).")
        with open(os.path.join(a.out, f"{run}-pieces.md"), "w") as f:
            f.write("\n".join(md) + "\n")
        log(f"[hourly] {len(pieces)} pieces in {a.out} ({run}-pieces.md)")
    return 0


# ---- airing (NP3) -------------------------------------------------------------------------------------------------
def blocked(s, now):
    """Why a piece cannot go on air now, or None: a fresh attack, loss or death, a battle or an enemy group on air,
    the camera held by someone (a look, a follow, a platform hold, the host view), a tour or a replay on air."""
    s = s or {}
    for a in s.get("alerts") or []:
        if isinstance(a, dict) and a.get("kind") in URGENT_KINDS and now - float(a.get("t") or 0) < URGENT_S:
            return f"a fresh {a['kind']} ({str(a.get('text') or '')[:80]})"
    on = s.get("onair") or {}
    if s.get("battle") or on.get("battle"):
        return "a battle on air"
    if on.get("attack"):
        return "an attack on air"
    if on.get("incoming"):
        return "an enemy group followed on air"
    for key, what in (("look", "a look"), ("follow", "a follow"), ("platform_hold", "a platform hold"),
                      ("hostview", "the host view"), ("tour", "a tour overlay")):
        if s.get(key):
            by = s[key].get("by") if isinstance(s[key], dict) else None
            return f"{what} on air" + (f" (by {by})" if by else "")
    if (s.get("replay") or {}).get("playing"):
        return "a replay on air"
    return None


def other_tour(run_file):
    """A tour running now (tour.py's run file with a live pid), else None."""
    try:
        with open(run_file) as f:
            other = json.load(f)
        os.kill(int(other["pid"]), 0)
    except (OSError, ValueError, KeyError, TypeError):
        return None
    return f"a tour is running (pid {other['pid']})"


def script_for(p):
    """The piece as a tour script (tools/stream/tour-FORMAT.md): its stops, facts kept for the operator."""
    return {"stops": [{"id": s["id"], "target": s["target"], "caption": s["caption"], "narration": s["narration"]}
                      for s in p["stops"]], "facts": p["facts"], "piece": p["id"]}


def render(script_path, out, feed=FEED):
    """tour.py prepare: every stop's clip in the tour's narrator voice (the first of tour.VOICES no host or agent
    speaks in that renders them all). -> the manifest, or None."""
    import tour
    a = argparse.Namespace(script=script_path, out=out, voice=",".join(tour.VOICES), feed=feed)
    return tour.read_manifest(out) if tour.prepare(a) == 0 else None


def tts_spent(manifest):
    """The clips' TTS list price in USD (voices.PRICE by the provider that rendered them)."""
    import voices as V
    total = 0.0
    for c in (manifest or {}).get("clips", {}).values():
        unit, rate = V.PRICE.get(c.get("provider") or V.provider_of(manifest.get("voice")), ("chars", 0.0))
        total += rate * (c.get("chars") or 0) if unit == "chars" else rate * (c.get("duration") or 0) / 60
    return round(total, 4)


class Airing:
    """One piece on the narrator channel (tour.Tour), rendered when it can air, dropped when it is too old."""

    def __init__(self, svc, out=OUT_DIR, cams=None, clock=time.time, sleep=time.sleep, renderer=None, hush_file=None,
                 stop_file=None, run_file=None, log_dir=LOG_DIR):
        import tour
        self.svc, self.out, self.cams, self.now, self.sleep = svc, out, cams, clock, sleep
        self.renderer = renderer or (lambda script, d: render(script, d, getattr(svc, "base", FEED)))
        self.hush_file, self.stop_file = hush_file or tour.HUSH_FILE, stop_file or tour.STOP_FILE
        self.run_file, self.log_dir = run_file or tour.RUN_FILE, log_dir
        self.started, self.ours, self.last_look = None, set(), -1e9

    def cameras(self, st):
        """How many camera clients: --cams (POG_EXPECT_CAMS), else the snapshot's cameras."""
        return self.cams or max(1, len((st or {}).get("cameras") or {}))

    def interrupt(self):
        """Why to end the piece now (looked at every 2 s), else None. With one camera nothing else shows a fresh
        attack, loss or death, so it ends the piece; with more, the attack is in the inset and the piece goes on, until
        a battle takes the program (onecam battle_all).
        Someone else's look or the host view taking the camera ends it with any count."""
        now = self.now()
        if now - self.last_look < 2:
            return None
        self.last_look = now
        try:
            st = self.svc.state()
        except Exception:
            return None
        lk = st.get("look") or {}
        if lk and lk.get("id") not in self.ours:
            return f"a look by {lk.get('by') or 'someone'} took the camera"
        if st.get("hostview"):
            return "the host view took the camera"
        if (st.get("onair") or {}).get("battle"):
            return "a battle took the camera"  # (d26 batch245 MB: a battle takes a tour's look with any count)
        if self.cameras(st) > 1:
            return None
        for a in st.get("alerts") or []:
            if isinstance(a, dict) and a.get("kind") in URGENT_KINDS and float(a.get("t") or 0) > self.started:
                return f"a {a['kind']} with one camera ({str(a.get('text') or '')[:80]})"
        on = st.get("onair") or {}
        if on.get("battle") or st.get("battle"):
            return "a battle with one camera"
        return None

    def air(self, p):
        """-> a log row: event aired (aired and skipped stops, ended early and why), expired (waited too long, and for
        what) or dropped (no voice rendered it)."""
        import tour
        deadline = float(p["written"]) + MAX_AGE_S
        d = os.path.join(self.out, p["id"])
        os.makedirs(d, exist_ok=True)
        script = os.path.join(d, "script.json")
        with open(script, "w") as f:
            json.dump(script_for(p), f, indent=1, ensure_ascii=False)
        manifest, why, waited = None, None, 0.0
        while True:
            now = self.now()
            if now >= deadline:
                return {"event": "expired", "id": p["id"], "waited_s": round(waited), "why": why,
                        "age_s": round(now - float(p["written"]))}
            try:
                st = self.svc.state()
            except Exception as x:
                st, why = None, f"the stream service does not answer ({type(x).__name__})"
            else:
                why = blocked(st, now) or other_tour(self.run_file)
            if why:
                step = min(WAIT_STEP_S, deadline - now)
                self.sleep(step)
                waited += step
                continue
            if manifest is None:  # rendered just in time: then look again, since rendering takes a few seconds
                manifest = self.renderer(script, d)
                if not manifest:
                    return {"event": "dropped", "id": p["id"], "why": "no narrator voice rendered it"}
                continue
            break
        rows = tour.checked(script_for(p)["stops"])
        if any(s and s["narration"] and not tour.clip_for(manifest, d, s) for _, s, _ in rows):
            return {"event": "dropped", "id": p["id"], "why": "a clip is missing after prepare"}
        self.ours = {s["id"] for _, s, _ in rows if s}
        self.started = self.now()
        log_path = os.path.join(self.log_dir, f"tour-{p['id']}.jsonl")
        t = tour.Tour(self.svc, rows, manifest, d, log_path, hush_file=self.hush_file, stop_file=self.stop_file,
                      clock=self.now, sleep=self.sleep, interrupt=self.interrupt)
        with open(self.run_file, "w") as f:
            json.dump({"pid": os.getpid(), "script": script, "started": self.started, "log": log_path, "by": "hourly"}, f)
        try:
            aired, skipped = t.run(rows)
        finally:
            try:
                os.remove(self.run_file)
            except FileNotFoundError:
                pass
        return {"event": "aired", "id": p["id"], "aired": aired, "skipped": skipped, "waited_s": round(waited),
                "age_s": round(self.started - float(p["written"])), "voice": manifest.get("voice"),
                "seconds": round(sum(c.get("duration") or 0 for c in manifest["clips"].values()), 1),
                "tts_usd": tts_spent(manifest), "ended_early": t.stop_why, "log": rel(log_path)}


def record(path, row):
    row = dict({"t": round(time.time(), 1), "at": time.strftime("%H:%M:%S")}, **row)
    with open(path, "a") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def run(a):
    """The stream's helper: a piece for the last hour every hour from its start (--once: one now), aired unless
    --no-air."""
    import tour
    if not os.path.isfile(os.path.join(a.run_dir, "scores.jsonl")) and not a.once:
        log(f"[hourly] {a.run_dir}: no scores.jsonl yet; the first piece is an hour from now")
    if not openrouter_key():
        log("[hourly] no OpenRouter key (OPENROUTER_API_KEY or the keychain's openrouter): not starting")
        return 1
    writer, svc = make_writer(a.model), tour.Service(a.feed)
    airing = Airing(svc, a.out, a.cams or int(os.environ.get("POG_EXPECT_CAMS") or 0) or None)
    os.makedirs(a.out, exist_ok=True)
    path = os.path.join(LOG_DIR, time.strftime("hourly-%Y%m%d-%H%M%S.jsonl"))
    run_name = os.path.basename(os.path.abspath(a.run_dir))
    stop = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
    record(path, {"event": "start", "run": run_name, "model": a.model, "air": not a.no_air, "cams": airing.cams})
    log(f"[hourly] {run_name}: one piece an hour ({a.model}), {'aired' if not a.no_air else 'not aired'}; log {path}")
    next_at = time.time() + (0 if a.once else HOUR_S)
    earlier = []
    while not stop:
        if time.time() < next_at:
            time.sleep(min(30.0, next_at - time.time()))
            continue
        t1 = time.time()
        m = gather(a.run_dir, t1 - HOUR_S, t1, a.logs, roster(a.feed, a.logs))
        piece, attempts = write(m, writer, earlier)
        if not piece:
            row = {"event": "dropped", "why": "; ".join(str(x.get("why")) for x in attempts), "rows": len(m.rows),
                   "cost_usd": round(sum(x.get("cost_usd") or 0 for x in attempts), 4)}
            log(f"[hourly] {hhmm(t1 - HOUR_S)}-{hhmm(t1)}: dropped after {len(attempts)} drafts: {row['why']}")
            record(path, row)
        else:
            p = finish(piece, m, run_name, time.time(), a.model, attempts)
            with open(os.path.join(a.out, p["id"] + ".json"), "w") as f:
                json.dump(dict(p, material=m.rows, targets=m.targets), f, indent=1, ensure_ascii=False)
            record(path, {"event": "written", "id": p["id"], "words": p["words"], "cost_usd": p["cost_usd"],
                          "drafts": len(attempts), "narration": " ".join(s["narration"] for s in p["stops"])})
            log(f"[hourly] {p['id']}: {p['words']} words, ${p['cost_usd']:.4f}")
            earlier = (earlier + [p])[-2:]
            if not a.no_air:
                res = airing.air(p)
                record(path, res)
                log(f"[hourly] {p['id']}: {res['event']}" + (f" ({res.get('why') or res.get('ended_early')})"
                                                             if res.get("why") or res.get("ended_early") else ""))
        if a.once:
            break
        next_at = max(next_at + HOUR_S, time.time() + 600)
    record(path, {"event": "end"})
    return 0


# ---- NP4: the analyst beats' repeats -------------------------------------------------------------------------------
def analyst_topics(logs_dir):
    """{point text: topic} from the analyst's cycle logs (the caster logs keep a point's text, not its topic)."""
    out = {}
    for path in sorted(glob.glob(os.path.join(logs_dir, "analyst-*.jsonl"))):
        for r in jsonl(path):
            for p in (r.get("reply") or {}).get("talking_points") or []:
                if isinstance(p, dict) and p.get("text"):
                    out[str(p["text"])] = p.get("topic")
    return out


def analyst_beats(logs_dir, t0, t1):
    """The analyst beats on air in [t0, t1): [{t, point: {topic, text, facts}, lines}] in time order, a beat being
    one exchange (its lines share `exchange`; the first carries the facts)."""
    beats, topics = {}, analyst_topics(logs_dir)
    for path in caster_logs(logs_dir, t0, t1):
        for r in jsonl(path):
            if r.get("type") != "caster" or r.get("event") != "analyst" or not r.get("pushed"):
                continue
            ex = float(r.get("exchange") or 0)
            if not t0 <= ex < t1:
                continue
            b = beats.setdefault(ex, {"t": ex, "point": None, "lines": 0, "log": rel(path)})
            b["lines"] += 1
            ap = (r.get("facts") or {}).get("analyst_point")
            if isinstance(ap, dict) and ap.get("point"):
                text = str(ap["point"])
                b["point"] = {"topic": topics.get(text), "text": text,
                              "facts": {k: v for k, v in ap.items() if k not in ("point", "kind", "pace")}}
    return [b for _, b in sorted(beats.items())]


def repeats(a):
    """How many of the analyst beats and lines on air in the last --hours the 2 h rule (caster.analyst_held) would
    have held back: each beat in order against the ones it let through."""
    t1 = a.until if a.until else time.time()
    t0 = t1 - a.hours * HOUR_S
    beats = analyst_beats(a.logs, t0, t1)
    aired, held, why = {}, [], {}
    for b in beats:
        if not b["point"]:
            continue
        w = caster.analyst_held(aired, b["point"], b["t"])
        if w:
            held.append(dict(b, why=w))
            kind = w.split(" aired")[0].split(" at ")[0] if not w.startswith("topic") else "topic"
            why["same topic, number not moved" if w.startswith("topic") else "much the same text" if w.startswith("much")
                else "same subject and number"] = why.get("same topic, number not moved" if w.startswith("topic") else
                                                          "much the same text" if w.startswith("much") else
                                                          "same subject and number", 0) + 1
        else:
            caster.analyst_aired(aired, b["point"], b["t"])
    with_point = [b for b in beats if b["point"]]
    lines = sum(b["lines"] for b in beats)
    out = {"from": time.strftime("%Y-%m-%d %H:%M", time.localtime(t0)), "to": time.strftime("%Y-%m-%d %H:%M", time.localtime(t1)),
           "beats": len(beats), "beats_with_point": len(with_point), "lines": lines,
           "last_beat": time.strftime("%Y-%m-%d %H:%M", time.localtime(beats[-1]["t"])) if beats else None,
           "topics_known": sum(1 for b in with_point if b["point"]["topic"]),
           "held_beats": len(held), "held_lines": sum(b["lines"] for b in held), "held_by": why}
    print(json.dumps(out, indent=1))
    if a.verbose:
        for b in held:
            print(f"{time.strftime('%d %H:%M', time.localtime(b['t']))}  {b['lines']} line(s)  {b['why']}: {b['point']['text'][:110]}")
    return 0


def parser():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("dry-run", help="write the pieces for past hours of a run folder; nothing airs")
    d.add_argument("--run-dir", required=True)
    d.add_argument("--hours", type=int, default=4)
    d.add_argument("--from", dest="start", metavar="HH:MM", help="the first hour's start (default: the run's first row)")
    d.add_argument("--model", default=MODEL, help="OpenRouter model id")
    d.add_argument("--no-model", action="store_true", help="gather and print the rows only")
    d.add_argument("--logs", default=LOG_DIR, help="the caster and analyst logs")
    d.add_argument("--feed", default=FEED, help="the stream service, for the agents' pronouns (else the caster logs)")
    d.add_argument("--out", default=OUT_DIR)
    q = sub.add_parser("repeats", help="NP4: the analyst beats on air the 2 h topic rule would have held back")
    q.add_argument("--hours", type=float, default=24)
    q.add_argument("--until", type=float, help="the window's end, epoch seconds (default now)")
    q.add_argument("--logs", default=LOG_DIR)
    q.add_argument("--verbose", "-v", action="store_true", help="list the beats held back")
    r = sub.add_parser("run", help="the stream's helper: a piece an hour, aired on the narrator channel")
    r.add_argument("--run-dir", required=True)
    r.add_argument("--model", default=MODEL, help="OpenRouter model id")
    r.add_argument("--logs", default=LOG_DIR, help="the caster and analyst logs")
    r.add_argument("--feed", default=FEED, help="the stream service")
    r.add_argument("--out", default=OUT_DIR, help="the pieces, their scripts and clips")
    r.add_argument("--cams", type=int, help="camera clients (default POG_EXPECT_CAMS, else the snapshot's cameras)")
    r.add_argument("--once", action="store_true", help="one piece for the last hour now, then exit")
    r.add_argument("--no-air", action="store_true", help="write the pieces only")
    return ap


def main(argv=None):
    a = parser().parse_args(argv)
    return {"dry-run": dry_run, "run": run, "repeats": repeats}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
