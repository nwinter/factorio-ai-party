"""The run's chronicle on the site (viewer Alex 22:24: "a dramatic record of major events ... their own narrative
history along with the run"; viewer syndesis 22:24: each platform's creation and loss with where, what killed it and
the cargo lost). Read from each shift's runs/RUN/chronicle.jsonl (tools/stream/chronicle_log.py: the agents' entries
and the events the harness saw), along the long run's chain (site/longrun.py), for build.py:
- by_shift(): per shift, the entries and the notable events (platforms made, lost, deleted; rockets; deaths), text
  through the site's redaction (clean) and its filter (keep);
- build_page(): the Chronicle page, shift by shift, the agents' words beside the harness's record;
- timeline_rows(): platform made and lost rows for /timeline/ with their details;
- platform_losses(): each lost platform's details by name, for the long-run page's platform table."""
import json
from pathlib import Path

NAME = "chronicle.jsonl"
SHOWN = ("platform_created", "platform_lost", "platform_deleted", "rocket", "death")
LABEL = {"platform_created": "Platform built", "platform_lost": "Platform lost", "platform_deleted": "Platform deleted",
         "rocket": "Rocket", "death": "Death"}


def read(run_dir):
    """(entries, events) of a run's file, in file order; ([], []) without one."""
    entries, events = [], []
    try:
        lines = (Path(run_dir) / NAME).read_text(errors="replace").splitlines()
    except OSError:
        return entries, events
    for line in lines:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and row.get("type") == "entry" and isinstance(row.get("text"), str):
            entries.append(row)
        elif isinstance(row, dict) and row.get("type") == "event" and isinstance(row.get("kind"), str):
            events.append(row)
    return entries, events


def words(name):
    """An internal name as words: medium-metallic-asteroid -> medium metallic asteroid."""
    return str(name or "").replace("-", " ").replace("_", " ")


def cargo_text(ev):
    cargo = [c for c in ev.get("cargo") or [] if isinstance(c, dict) and c.get("name")]
    if not cargo:
        return "nothing in its hub"
    more = (ev.get("cargo_kinds") or 0) - len(cargo)
    return ", ".join(f"{int(c.get('count') or 0):,} {words(c['name'])}" for c in cargo) + (f", +{more} more kinds" if more > 0 else "")


def event_text(ev):
    """An event in one line, for people."""
    k = ev.get("kind")
    name = ev.get("platform") or "?"
    if k == "platform_created":
        return f"Platform {name} built" + (f" at {str(ev['at']).capitalize()}" if ev.get("at") else "") + (f" by {ev['by']}" if ev.get("by") else "")
    if k == "platform_lost":
        where = str(ev.get("where") or "").strip()
        hits = [words(h.get("name")) for h in ev.get("hit_by") or [] if isinstance(h, dict) and h.get("name")]
        return (f"Platform {name} lost" + (f" {where}" if where else "") + (f", destroyed by {words(ev['by'])}" if ev.get("by") else "")
                + (f"; hit most by {', '.join(hits)}" if hits else "") + f"; cargo lost: {cargo_text(ev)}")
    if k == "platform_deleted":
        return f"Platform {name} deleted (gone from the platform list with no hub loss seen)"
    if k == "rocket":
        return "Rocket launched" + (f" from {str(ev['surface']).capitalize()}" if ev.get("surface") else "") + \
            (f" to {ev['to']}" if ev.get("to") else "") + (f", cargo {ev['cargo']}" if ev.get("cargo") and ev["cargo"] != "empty" else "")
    if k == "death":
        return f"{str(ev.get('agent') or '?').capitalize()} died" + (f" on {str(ev.get('platform') or ev.get('surface')).capitalize()}"
                                                                    if ev.get("platform") or ev.get("surface") else "") + \
            (f", killed by {words(ev['by'])}" if ev.get("by") else "")
    return str(ev.get("line") or k)


def by_shift(long, runs_dir, clean=lambda s: s, keep=lambda s: True):
    """[{n, id, entries, events}] for the shifts with any row: entries {tick, agent, title, text, where, about} whose
    text keep allows, events {tick, kind, text, platform} of the SHOWN kinds."""
    out = []
    for s in (long or {}).get("shifts") or []:
        if s.get("empty"):
            continue
        entries, events = read(Path(runs_dir) / s["id"])
        rows = []
        for e in entries:
            text, title = e.get("text") or "", e.get("title") or ""
            if not keep(text) or (title and not keep(title)):
                continue
            rows.append({"tick": e.get("tick"), "agent": str(e.get("agent") or ""), "title": clean(title) or None,
                         "text": clean(text), "where": e.get("platform") or e.get("planet"),
                         "about": [clean(str(r.get("line"))) for r in e.get("refs") or [] if isinstance(r, dict) and r.get("line")]})
        evs = [{"tick": ev.get("tick"), "kind": ev["kind"], "text": clean(event_text(ev)), "platform": ev.get("platform"),
                "agent": ev.get("agent")} for ev in events if ev.get("kind") in SHOWN]
        if rows or evs:
            out.append({"n": s["n"], "id": s["id"], "entries": rows, "events": evs})
    return out


def timeline_rows(long, runs_dir):
    """[(tick, shift n, "platform", text)] of the harness's platform events (built, lost, deleted), and the set of
    (kind, name) they cover per shift id, so the score-based rows leave those out."""
    rows, covered = [], {}
    for s in (long or {}).get("shifts") or []:
        if s.get("empty"):
            continue
        _, events = read(Path(runs_dir) / s["id"])
        for ev in events:
            if ev.get("kind") in ("platform_created", "platform_lost", "platform_deleted") and isinstance(ev.get("tick"), (int, float)):
                rows.append((ev["tick"], s["n"], "platform", event_text(ev)))
                covered.setdefault(s["id"], set()).add(("built" if ev["kind"] == "platform_created" else "lost", ev.get("platform")))
    return rows, covered


def platform_losses(long, runs_dir):
    """{platform name: the last platform_lost event's line} (the long-run page's platform table)."""
    out = {}
    for s in (long or {}).get("shifts") or []:
        if s.get("empty"):
            continue
        for ev in read(Path(runs_dir) / s["id"])[1]:
            if ev.get("kind") == "platform_lost" and ev.get("platform"):
                out[ev["platform"]] = event_text(ev)
    return out


STYLE = """<style>
.chron-shift { margin: 1.4em 0; }
.chron-list { list-style: none; padding: 0; margin: 0; display: grid; gap: 10px; }
.chron-entry { padding: 8px 12px; border-left: 3px solid var(--fx-agent, #888); background: var(--surface, transparent); border-radius: 4px; }
.chron-entry h3 { margin: 0 0 4px; font-size: 1.02rem; display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
.chron-entry p { margin: 4px 0 0; overflow-wrap: anywhere; }
.chron-event { display: grid; grid-template-columns: 7em 1fr; gap: 8px; font-size: .92rem; overflow-wrap: anywhere; }
.chron-event .kind { font-weight: 600; }
.chron-filters label { margin-right: 1em; }
</style>"""

FILTER_JS = """<script>
document.addEventListener('DOMContentLoaded', function () {
  var boxes = document.querySelectorAll('.chron-filters input');
  function apply() {
    var on = {}; boxes.forEach(function (b) { on[b.value] = b.checked; });
    document.querySelectorAll('.chron-list > li').forEach(function (r) { r.hidden = !on[r.dataset.kind]; });
  }
  boxes.forEach(function (b) { b.addEventListener('change', apply); }); apply();
});
</script>"""


def build_page(shifts, agent, avatar, esc, game_time, known=()):
    """The Chronicle page: per shift, newest shift first, its entries and events in game-time order."""
    known = set(known)
    n_entries = sum(len(s["entries"]) for s in shifts)
    n_events = sum(len(s["events"]) for s in shifts)
    parts = []
    for s in reversed(shifts):
        items = [(e["tick"] or 0, 0, e) for e in s["entries"]] + [(ev["tick"] or 0, 1, ev) for ev in s["events"]]
        items.sort(key=lambda x: (x[0], x[1]))
        lis = []
        for tick, is_event, x in items:
            when = esc(game_time(tick)) if tick else "?"
            if is_event:
                lis.append(f'<li class="chron-event" data-kind="events"><span class="muted small">{when} · '
                           f'<span class="kind">{esc(LABEL.get(x["kind"], x["kind"]))}</span></span><span>{esc(x["text"])}</span></li>')
                continue
            key = x["agent"].lower()
            who = (f'<span class="chip">{avatar(key, "sm")}{esc(agent(key)["name"])}</span>'
                   if key in known else f'<span class="chip">{esc(x["agent"] or "?")}</span>')
            color = agent(key).get("color") or "#888888" if key in known else "#888888"
            about = (f'<p class="muted small">Beside: {esc("; ".join(x["about"]))}</p>' if x["about"] else "")
            lis.append(f'<li class="chron-entry" data-kind="entries" style="--fx-agent:{esc(color)}"><h3>{who}'
                       + (f'<span>{esc(x["title"])}</span>' if x["title"] else "")
                       + f'<span class="muted small">{when}{" · " + esc(str(x["where"]).capitalize()) if x["where"] else ""}</span></h3>'
                       f'<p>{esc(x["text"])}</p>{about}</li>')
        parts.append(f'<section class="chron-shift" id="shift-{s["n"]}"><h2><a href="/runs/long/shift-{s["n"]}/">Shift {s["n"]}</a></h2>'
                     f'<ol class="chron-list">{"".join(lis)}</ol></section>')
    filters = (f'<fieldset class="chron-filters"><legend class="small muted">Show</legend>'
               f'<label><input type="checkbox" value="entries" checked> The agents\' entries ({n_entries})</label>'
               f'<label><input type="checkbox" value="events" checked> The harness\'s record ({n_events})</label></fieldset>')
    body = ('<h1>Chronicle</h1><p class="lede">The run\'s story in the agents\' own words, written when something '
            'notable happened (fh chronicle), beside what the harness recorded: platforms built and lost (where, what '
            'destroyed them, the cargo lost), rockets and deaths. Game time; newest shift first.</p>'
            + (filters + "".join(parts) if parts else '<p class="muted">No entries yet.</p>'))
    return body, STYLE + "\n" + FILTER_JS
