"""/agents/: one card per agent with its numbers across the long run's shifts, records and a comparison table; and
/timeline/: the run's events in order. For site/build.py; the numbers come from tools/agent_stats.py (cached per
shift), the events from the shifts' score logs and the director's deaths. Labels and numbers only."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))
import agent_stats  # noqa: E402

# (key, label, kind): kind "n" a count, "tiles" a distance, "pct" a share
CARD = [("shifts", "Shifts", "n"), ("actions", "Game actions", "n"), ("built", "Buildings placed", "n"),
        ("mined", "Mine actions", "n"), ("walked", "Tiles walked", "tiles"), ("deaths", "Deaths", "n"),
        ("research", "Research queued", "n"), ("research_done", "Research finished", "n"),
        ("rockets", "Rockets launched", "n"), ("say", "Chat lines", "n"), ("voiced", "Spoken on stream", "n"),
        ("tells", "Tells", "n"), ("confessions", "Confessions", "n"), ("viewer_answers", "Viewer replies", "n"),
        ("operator", "Operator requests", "n"), ("active", "Minutes acting", "pct"), ("fail_rate", "Failed requests", "pct")]
TABLE = ["actions", "built", "walked", "deaths", "research", "rockets", "say", "voiced", "active"]
SUM = ["requests", "actions", "talk", "reads", "failed", "built", "mined", "walked", "research", "research_done",
       "rockets", "say", "aloud_marked", "tells", "confessions", "viewer_answers", "deaths", "voiced", "operator",
       "active_min", "minutes"]
RECORDS = [("built", "Most buildings placed in a shift"), ("walked", "Most tiles walked in a shift"),
           ("actions", "Most game actions in a shift"), ("rockets", "Most rockets launched in a shift"),
           ("say", "Most chat lines in a shift"), ("voiced", "Most lines spoken on stream in a shift"),
           ("research", "Most research queued in a shift"), ("deaths", "Most deaths in a shift")]
TICKS_PER_MIN = 3600


def game_span(ticks):
    m = int(ticks // TICKS_PER_MIN)
    return f"{m // 60}h{m % 60:02d}m" if m >= 60 else f"{m}m"


def fmt(v, kind="n"):
    if v is None:
        return "–"
    if kind == "pct":
        return f"{v:.0f}%"
    return f"{v:,}"


def collect(long, runs_dir, keys, cache_dir=None, names=()):
    """{"shifts": [(n, id, stats)], "totals": {key: summed stats}, "per_shift": {key: [(n, stats)]},
    "survival": {key: (longest ticks, shift n where it ended, current streak ticks)}} for the shifts that played."""
    runs_dir = Path(runs_dir)
    shifts = []
    for s in long["shifts"]:
        if s.get("empty") or not (runs_dir / s["id"]).is_dir():
            continue
        st = agent_stats.load(runs_dir / s["id"], cache_dir, names)
        shifts.append((s["n"], s["id"], st))
    # operator requests: each seq (the game's id) in the first shift whose inbox has it (until the stream service's
    # fix each new inbox repeated the earlier shifts' requests)
    filed = set()
    for _, _, st in shifts:
        new = set()
        for a in st["agents"].values():
            mine = [q for q in a.get("operator_seqs") or [] if q not in filed]
            a["operator"] = len(mine)
            new.update(mine)
        filed |= new
    totals, per, voice = {}, {}, {}
    for n, _, st in shifts:
        for k, a in st["agents"].items():
            if k not in keys:
                continue
            t = totals.setdefault(k, {f: 0 for f in SUM} | {"shifts": 0})
            t["shifts"] += 1
            for f in SUM:
                t[f] += a.get(f) or 0
            per.setdefault(k, []).append((n, a))
            if a.get("voice"):
                voice[k] = a["voice"]
    totals = {k: totals[k] for k in keys if k in totals}  # site.json's order
    for t in totals.values():
        t["active"] = 100 * t["active_min"] / t["minutes"] if t["minutes"] else None
        t["fail_rate"] = 100 * t["failed"] / t["requests"] if t["requests"] else None
    survival = {}
    for k in totals:
        start, best, best_n, prev = None, 0, None, None
        for n, _, st in shifts:
            a = st["agents"].get(k)
            if not a or st.get("tick0") is None:
                continue
            if prev is None:
                prev = st["tick0"]
            for d in a.get("death_ticks") or []:
                if d - prev > best:
                    best, best_n = d - prev, n
                prev = d
            start = st.get("tick1")
        current = (start - prev) if start is not None and prev is not None else 0
        if current > best:
            best, best_n = current, None
        survival[k] = (best, best_n, current)
    return {"shifts": shifts, "totals": totals, "per_shift": per, "voice": voice, "survival": survival}


def records(data):
    """[(label, key, value text, shift n)] for each record with a holder (a value above zero)."""
    out = []
    for f, label in RECORDS:
        best = None
        for k, rows in data["per_shift"].items():
            for n, a in rows:
                v = a.get(f) or 0
                if v and (best is None or v > best[1]):
                    best = (k, v, n)
        if best:
            out.append((label, best[0], fmt(best[1], "tiles" if f == "walked" else "n"), best[2]))
    surv = [(v[0], k, v[1]) for k, v in data["survival"].items() if v[0]]
    if surv:
        ticks, k, n = max(surv)
        out.append(("Longest survival (game time)", k, game_span(ticks), n))
    deaths = [(t["deaths"], k) for k, t in data["totals"].items()]
    zero = sorted(k for d, k in deaths if d == 0)
    if zero:
        out.append(("No deaths in the run", zero, "0", None))
    return out


STYLE = """<style>
.agent-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 330px), 1fr)); gap: 16px; }
.agent-card { padding: 14px 16px; border-top: 4px solid var(--ac); }
.agent-card .voice { margin: .15rem 0 0; color: var(--muted); font-size: .82rem; }
.agent-card .kv { grid-template-columns: repeat(auto-fill, minmax(104px, 1fr)); }
.agent-card .kv dd { font-variant-numeric: tabular-nums; }
.agent-card .spark { display: flex; align-items: flex-end; gap: 3px; height: 34px; margin: .4rem 0 0; }
.agent-card .spark span { flex: 1; background: var(--ac); opacity: .8; min-height: 2px; border-radius: 1px; }
.agent-card .spark-label { font-size: .75rem; color: var(--muted); margin: .15rem 0 0; }
.records { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 300px), 1fr)); gap: 10px; padding: 0; list-style: none; }
.records li { background: var(--surface); border: 1px solid var(--panel-border); border-radius: var(--radius); box-shadow: var(--panel-shadow); padding: 10px 14px; }
.records .r-label { color: var(--muted); font-size: .82rem; display: block; }
.records .r-value { font-size: 1.4rem; font-weight: 700; color: var(--heading); font-variant-numeric: tabular-nums; margin-right: .4em; }
.records .r-shift { color: var(--muted); font-size: .82rem; }
table.compare td { font-variant-numeric: tabular-nums; white-space: nowrap; position: relative; }
table.compare td .bar { position: absolute; left: 12px; right: 12px; bottom: 3px; height: 3px; border-radius: 2px; background: var(--line); }
table.compare td .bar i { display: block; height: 100%; border-radius: 2px; background: var(--ac, var(--accent)); opacity: .8; }
table.compare th button { all: unset; cursor: pointer; }
table.makers td.agents-cell { white-space: normal; min-width: 12em; }
table.makers td.agents-cell .chip { margin-right: 8px; font-size: .88rem; }
table.compare th button:focus-visible { outline: var(--fx-focus); }
table.compare th[aria-sort] button::after { content: " ▾"; }
table.compare th[aria-sort=ascending] button::after { content: " ▴"; }
.tl-filters { display: flex; flex-wrap: wrap; gap: 6px 14px; margin: .6rem 0 1rem; font-size: .92rem; }
.tl-filters label { display: inline-flex; gap: 6px; align-items: center; cursor: pointer; }
table.timeline-table td { font-variant-numeric: tabular-nums; }
table.timeline-table tr:target > * { background: var(--hl); }
table.timeline-table td.kind { white-space: nowrap; color: var(--muted); }
table.timeline-table tr[data-kind=rocket] td.kind, table.timeline-table tr[data-kind=platform] td.kind,
table.timeline-table tr[data-kind=planet] td.kind { color: var(--accent); font-weight: 600; }
</style>"""

SORT_JS = """<script>
document.querySelectorAll('table.compare').forEach(function (t) {
  t.querySelectorAll('thead th').forEach(function (th, i) {
    var b = th.querySelector('button'); if (!b) return;
    b.addEventListener('click', function () {
      var asc = th.getAttribute('aria-sort') === 'descending';
      t.querySelectorAll('thead th').forEach(function (h) { h.removeAttribute('aria-sort'); });
      th.setAttribute('aria-sort', asc ? 'ascending' : 'descending');
      var rows = Array.prototype.slice.call(t.tBodies[0].rows);
      rows.sort(function (a, c) {
        var x = parseFloat(a.cells[i].dataset.v), y = parseFloat(c.cells[i].dataset.v);
        if (isNaN(x)) return isNaN(y) ? 0 : 1; if (isNaN(y)) return -1;
        return asc ? x - y : y - x;
      });
      rows.forEach(function (r) { t.tBodies[0].appendChild(r); });
    });
  });
});
</script>"""


def card(k, t, data, agent, avatar, esc):
    a = agent(k)
    dl = "".join(f"<div><dt>{esc(label)}</dt><dd>{fmt(round(t[f]) if kind == 'pct' and t[f] is not None else t[f], kind)}</dd></div>"
                 for f, label, kind in CARD)
    best, best_n, current = data["survival"].get(k, (0, None, 0))
    dl += f"<div><dt>Longest survival</dt><dd>{game_span(best)}</dd></div>"
    rows = data["per_shift"].get(k, [])
    top = max((r.get("built") or 0 for _, r in rows), default=0)
    spark = ""
    if top:
        bars = "".join(f'<span style="height:{max(4, round(100 * (r.get("built") or 0) / top))}%" '
                       f'title="Shift {n}: {r.get("built") or 0} built"></span>' for n, r in rows)
        spark = f'<div class="spark" aria-hidden="true">{bars}</div><p class="spark-label">Buildings placed per shift</p>'
    voice = data["voice"].get(k)
    maker = a.get("maker")
    return (f'<article class="agent-card" id="{esc(k)}" style="--ac:{esc(a.get("color") or "#888")}">'
            f'<header>{avatar(k, "lg")}<div><h3>{esc(a["name"])}</h3>'
            f'<p class="model">{esc(a.get("model", ""))}{" · " + esc(maker) if maker else ""} · {esc(a.get("harness", ""))}</p>'
            f'{f"<p class=voice>Voice: {esc(voice)}</p>" if voice else ""}</div></header>'
            f'<dl class="kv">{dl}</dl>{spark}</article>')


def compare_table(data, agent, avatar, esc):
    labels = {f: label for f, label, _ in CARD}
    labels["walked"] = "Tiles walked"
    cols = TABLE
    tops = {f: max((t[f] or 0 for t in data["totals"].values()), default=0) for f in cols}
    head = '<th scope="col">Agent</th>' + "".join(
        f'<th scope="col"><button type="button">{esc(labels[f])}</button></th>' for f in cols)
    body = []
    for k, t in sorted(data["totals"].items(), key=lambda kv: -kv[1]["actions"]):
        a = agent(k)
        cells = []
        for f in cols:
            v = t[f]
            w = round(100 * (v or 0) / tops[f]) if tops[f] else 0
            shown = fmt(round(v) if f == "active" and v is not None else v, "pct" if f == "active" else "n")
            cells.append(f'<td data-v="{v if v is not None else ""}">{shown}<span class="bar"><i style="width:{w}%"></i></span></td>')
        body.append(f'<tr style="--ac:{esc(a.get("color") or "#888")}"><th scope="row">'
                    f'<a class="chip" href="#{esc(k)}">{avatar(k, "sm")}{esc(a["name"])}</a></th>{"".join(cells)}</tr>')
    return (f'<div class="table-wrap"><table class="compare"><thead><tr>{head}</tr></thead>'
            f'<tbody>{"".join(body)}</tbody></table></div>')


MAKER_COLS = ["actions", "built", "walked", "deaths", "research", "rockets", "say", "voiced"]


def rate(v):
    return f"{v:,.0f}" if v >= 100 else f"{v:.1f}"


def maker_rows(data, agent):
    """[(maker, [keys], agent-shifts, {field: per agent-shift}, minutes acting %)], most game actions per agent-shift
    first. An agent-shift is one agent on one shift, so a lab with three agents compares with a lab with one."""
    groups = {}
    for k, t in data["totals"].items():
        groups.setdefault(agent(k).get("maker") or "Other", []).append(k)
    rows = []
    for maker, ks in groups.items():
        n = sum(data["totals"][k]["shifts"] for k in ks)
        if not n:
            continue
        per = {f: sum(data["totals"][k][f] or 0 for k in ks) / n for f in MAKER_COLS}
        mins = sum(data["totals"][k]["minutes"] for k in ks)
        act = 100 * sum(data["totals"][k]["active_min"] for k in ks) / mins if mins else None
        rows.append((maker, ks, n, per, act))
    return sorted(rows, key=lambda r: -r[3]["actions"])


def maker_table(data, agent, avatar, esc):
    labels = {f: label for f, label, _ in CARD}
    rows = maker_rows(data, agent)
    tops = {f: max((r[3][f] for r in rows), default=0) for f in MAKER_COLS}
    head = ('<th scope="col">Maker</th><th scope="col">Agents</th>'
            '<th scope="col"><button type="button">Agent-shifts</button></th>'
            + "".join(f'<th scope="col"><button type="button">{esc(labels[f])}</button></th>' for f in MAKER_COLS)
            + '<th scope="col"><button type="button">Minutes acting</button></th>')
    body = []
    for maker, ks, n, per, act in rows:
        chips = " ".join(f'<a class="chip" href="#{esc(k)}">{avatar(k, "sm")}{esc(agent(k)["name"])}</a>' for k in ks)
        cells = [f'<td class="agents-cell" data-v="">{chips}</td>', f'<td data-v="{n}">{n}</td>']
        for f in MAKER_COLS:
            w = round(100 * per[f] / tops[f]) if tops[f] else 0
            cells.append(f'<td data-v="{per[f]:.3f}">{rate(per[f])}<span class="bar"><i style="width:{w}%"></i></span></td>')
        cells.append(f'<td data-v="{act if act is not None else ""}">{fmt(round(act) if act is not None else None, "pct")}</td>')
        body.append(f'<tr><th scope="row">{esc(maker)}</th>{"".join(cells)}</tr>')
    return (f'<p class="small muted">Per agent-shift: one agent on one shift.</p>'
            f'<div class="table-wrap"><table class="compare makers"><thead><tr>{head}</tr></thead>'
            f'<tbody>{"".join(body)}</tbody></table></div>')


def build_agents(data, agent, avatar, esc):
    """The /agents/ page body and its head extras."""
    shifts = data["shifts"]
    n0, n1 = (shifts[0][0], shifts[-1][0]) if shifts else (None, None)
    span = f"Shift {n0}" if n0 == n1 else f"Shifts {n0} to {n1}"
    order = list(data["totals"])
    recs = []
    for label, k, value, n in records(data):
        if isinstance(k, list):
            who = " ".join(f'<a class="chip" href="#{esc(x)}">{avatar(x, "sm")}{esc(agent(x)["name"])}</a>' for x in k)
            recs.append(f'<li><span class="r-label">{esc(label)}</span><span class="chips">{who}</span></li>')
            continue
        recs.append(f'<li><span class="r-label">{esc(label)}</span><span class="r-value">{esc(value)}</span>'
                    f'<a class="chip" href="#{esc(k)}">{avatar(k, "sm")}{esc(agent(k)["name"])}</a>'
                    f'{f" <span class=r-shift>shift {n}</span>" if n else " <span class=r-shift>still alive</span>"}</li>')
    cards = "".join(card(k, data["totals"][k], data, agent, avatar, esc) for k in order)
    body = (f'<h1>Agents</h1><p class="lede">{esc(span)} of the long run. Counted from each agent\'s game requests, '
            f'the director\'s death log and the stream\'s voice log.</p>'
            f'<h2 id="records">Records</h2><ul class="records">{"".join(recs)}</ul>'
            f'<h2 id="compare">Comparison</h2>{compare_table(data, agent, avatar, esc)}'
            f'<h2 id="makers">By maker</h2>{maker_table(data, agent, avatar, esc)}'
            f'<h2 id="cards">The team</h2><div class="agent-grid">{cards}</div>'
            f'<h2 id="notes">Definitions</h2><dl class="kv defs">'
            + "".join(f"<div><dt>{esc(a)}</dt><dd>{esc(b)}</dd></div>" for a, b in DEFS) + "</dl>" + SORT_JS)
    return body, STYLE


DEFS = [("Game actions", "requests that change the game: moves, builds, crafts, transfers, queues"),
        ("Buildings placed", "entities built by hand, by build queues and by belt, pipe and pole routes"),
        ("Mine actions", "mining requests and queued mining jobs, ore included"),
        ("Tiles walked", "straight lines between move targets; hops over 400 tiles left out"),
        ("Research queued", "technologies with the agent as queued_by in the research queue"),
        ("Spoken on stream", "chat lines the stream voiced"),
        ("Viewer replies", "chat lines that start with @ and a name outside the team"),
        ("Minutes acting", "minutes with a game action, of the minutes on shift"),
        ("Longest survival", "game time between deaths, or since the last one")]


# ---------------------------------------------------------------- timeline

def timeline_events(long, runs_dir, keys, techs, data):
    """[(game tick, shift n, kind, text, agent key or None)] in order: research finished, rockets, platforms built,
    planets reached (from the score logs), deaths (from the agents' stats)."""
    runs_dir = Path(runs_dir)
    out = []
    prev = None
    for s in long["shifts"]:
        if s.get("empty"):
            continue
        p = runs_dir / s["id"] / "scores.jsonl"
        if not p.exists():
            continue
        for line in p.read_text().splitlines():
            try:
                sc = json.loads(line)["score"]
            except (ValueError, KeyError, TypeError):
                continue
            done = sc.get("research_done") or []
            row = {"tick": sc.get("tick"), "done": set(done if isinstance(done, list) else []),
                   "rockets": sc.get("rockets") or 0,
                   "platforms": {q.get("name") for q in sc.get("platforms") or [] if isinstance(q, dict) and q.get("hub", True)},
                   "planets": set(sc.get("planets") or [])}
            if row["tick"] is None:
                continue
            if prev:
                t = row["tick"]
                for tech in sorted(row["done"] - prev["done"]):
                    out.append((t, s["n"], "research", techs(tech), None))
                if row["rockets"] > prev["rockets"]:
                    a, b = prev["rockets"] + 1, row["rockets"]
                    out.append((t, s["n"], "rocket", f"Rocket {a}" if a == b else f"Rockets {a} to {b}", None))
                for pf in sorted(row["platforms"] - prev["platforms"]):
                    out.append((t, s["n"], "platform", f"Platform {pf} built", None))
                for pl in sorted(row["planets"] - prev["planets"]):
                    out.append((t, s["n"], "planet", f"Reached {pl.capitalize()}", None))
            prev = row
    for n, _, st in data["shifts"]:
        for k, a in st["agents"].items():
            if k in keys:
                for d in a.get("death_ticks") or []:
                    out.append((d, n, "death", "Died", k))
    out.sort(key=lambda e: (e[0], e[2]))
    return out


KINDS = [("research", "Research"), ("rocket", "Rockets"), ("platform", "Platforms"), ("planet", "Planets"),
         ("death", "Deaths")]
KIND_ONE = {"research": "Research", "rocket": "Rocket", "platform": "Platform", "planet": "Planet", "death": "Death"}

FILTER_JS = """<script>
document.addEventListener('DOMContentLoaded', function () {
  var boxes = document.querySelectorAll('.tl-filters input');
  function apply() {
    var on = {}; boxes.forEach(function (b) { on[b.value] = b.checked; });
    document.querySelectorAll('table.timeline-table tbody tr').forEach(function (r) { r.hidden = !on[r.dataset.kind]; });
  }
  boxes.forEach(function (b) { b.addEventListener('change', apply); }); apply();
});
</script>"""


def build_timeline(events, agent, avatar, esc, game_time):
    counts = {k: sum(1 for e in events if e[2] == k) for k, _ in KINDS}
    filters = "".join(f'<label><input type="checkbox" value="{k}" checked> {esc(label)} ({counts[k]})</label>'
                      for k, label in KINDS)
    rows = []
    for i, (tick, n, kind, text, who) in enumerate(events):
        chip = (f'<a class="chip" href="/agents/#{esc(who)}">{avatar(who, "sm")}{esc(agent(who)["name"])}</a> '
                if who else "")
        # id e<i>: the site search links an event (search.py uses the same order)
        rows.append(f'<tr id="e{i}" data-kind="{kind}"><td>{esc(game_time(tick))}</td><td>{n}</td>'
                    f'<td class="kind">{esc(KIND_ONE[kind])}</td><td>{chip}{esc(text)}</td></tr>')
    body = (f'<h1>Timeline</h1><p class="lede">The long run\'s events in game time.</p>'
            f'<fieldset class="tl-filters"><legend class="small muted">Show</legend>{filters}</fieldset>'
            f'<div class="table-wrap"><table class="timeline-table"><thead><tr><th scope="col">Game time</th>'
            f'<th scope="col">Shift</th><th scope="col">Kind</th><th scope="col">Event</th></tr></thead>'
            f'<tbody>{"".join(rows)}</tbody></table></div>')
    return body, STYLE + "\n" + FILTER_JS
