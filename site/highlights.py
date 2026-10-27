"""/chat/: highlights (moments from the agents' own minds, site/content/moments.json from site/moments.py) and the
agents' lines spoken on stream and their confessions, by shift, with search and filters. For site/build.py; the lines
come from tools/agent_stats.py's per-shift caches (site/agents.py's collect). Every line and quote goes through
build.py's clean() (and the lines keep_line()) like any log text on the site."""
import json
from pathlib import Path

KINDS = [("spoken", "Spoken on stream"), ("confession", "Confessions")]
SEEN = {"voiced": "On stream", "chat": "In chat"}
MOMENTS = Path(__file__).resolve().parent / "content" / "moments.json"
WHY = {"aloud": "aloud", "reaction": "reaction", "plan": "plan", "strategy": "strategy", "request": "request"}

STYLE = """<style>
.hl-fold > summary { cursor: pointer; color: var(--accent); font-weight: 600; padding: 4px 0; min-height: 36px; display: flex; align-items: center; }
.hl-fold[open] > summary { color: var(--muted); font-weight: 400; }
.hl-controls { display: flex; flex-wrap: wrap; gap: 8px 16px; align-items: center; margin: .8rem 0 1rem; font-size: .92rem; }
.hl-controls input[type=search] { min-width: min(100%, 18em); }
.hl-controls label { display: inline-flex; gap: 6px; align-items: center; cursor: pointer; }
.hl-count { color: var(--muted); font-size: .88rem; }
table.hl td { vertical-align: top; }
table.hl td.t { font-variant-numeric: tabular-nums; white-space: nowrap; color: var(--muted); font-size: .85rem; }
table.hl td.who { white-space: nowrap; font-weight: 600; }
table.hl td.kind { white-space: nowrap; font-size: .82rem; color: var(--muted); }
table.hl tr[data-kind=confession] td.kind { color: var(--accent); font-weight: 600; }
table.hl td.text { overflow-wrap: anywhere; min-width: 16em; }
.hl-shift[hidden] { display: none; }
table.hl tr:target > * { background: var(--hl); }
.hl-moments { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 22rem), 1fr)); gap: 12px; margin: .6rem 0 1.6rem; }
.hl-moment { margin: 0; padding: .7rem .85rem; border-radius: var(--fx-r-1); background: var(--well); }
.hl-moment:target { outline: 2px solid var(--accent); }
.hl-moment h3 { font-size: 1rem; margin: 0 0 .2rem; }
.hl-moment .m-meta { font-size: .85rem; color: var(--muted); font-variant-numeric: tabular-nums; margin: 0 0 .4rem; }
.hl-moment blockquote { margin: .35rem 0; padding-left: .6rem; border-left: 3px solid var(--line, #8884); overflow-wrap: anywhere; }
.hl-moment blockquote cite { display: block; font-style: normal; font-size: .82rem; color: var(--muted); }
.hl-moment .m-seen { font-size: .82rem; margin: .4rem 0 0; }
.hl-moment .m-seen span { display: inline-block; padding: 1px 7px; margin-right: 4px; border-radius: 9px; background: var(--chip, #8882); }
.hl-moment .m-seen span.private { font-weight: 600; }
</style>"""

SCRIPT = """<script>
(function () {
  var q = document.getElementById('hl-q'), who = document.getElementById('hl-agent'),
      boxes = document.querySelectorAll('.hl-controls input[type=checkbox]'), count = document.getElementById('hl-count');
  var rows = Array.prototype.slice.call(document.querySelectorAll('table.hl tbody tr'));
  rows.forEach(function (r) { r._t = r.textContent.toLowerCase(); });
  try {
    var p = new URLSearchParams(location.search);
    if (p.get('q')) q.value = p.get('q');
    if (p.get('agent')) who.value = p.get('agent');
  } catch (e) {}
  function apply() {
    var words = q.value.toLowerCase().split(/\\s+/).filter(Boolean), on = {}, n = 0;
    boxes.forEach(function (b) { on[b.value] = b.checked; });
    rows.forEach(function (r) {
      var show = on[r.dataset.kind] && (!who.value || r.dataset.agent === who.value) &&
        words.every(function (w) { return r._t.indexOf(w) >= 0; });
      r.hidden = !show; if (show) n++;
    });
    var active = words.length || who.value || Array.prototype.some.call(boxes, function (b) { return !b.checked; });
    document.querySelectorAll('.hl-shift').forEach(function (s) {
      s.hidden = !s.querySelector('tbody tr:not([hidden])');
      var d = s.querySelector('details.hl-fold');
      if (d && active && !s.hidden) d.open = true;
    });
    count.textContent = n + ' of ' + rows.length + ' lines';
  }
  // a link to a line (/chat/#s12-40, from the search) opens its shift
  var target = location.hash && document.getElementById(location.hash.slice(1));
  if (target && target.closest('details')) { target.closest('details').open = true; target.scrollIntoView(); }
  q.addEventListener('input', apply); who.addEventListener('change', apply);
  boxes.forEach(function (b) { b.addEventListener('change', apply); });
  apply();
})();
</script>"""


def lines(data, keys, clean, keep_line):
    """[(shift n, [(game tick, key, kind, why, text)] in game order)] from collect()'s shifts."""
    out = []
    for n, _, st in data["shifts"]:
        rows = []
        for k, a in st["agents"].items():
            if k not in keys:
                continue
            for tick, why, text in a.get("spoken_lines") or []:
                if text and keep_line(text):
                    rows.append((tick or 0, k, "spoken", why, clean(text)))
            for tick, text in a.get("confession_lines") or []:
                if text and keep_line(text):
                    rows.append((tick or 0, k, "confession", None, clean(text)))
        rows.sort(key=lambda r: (r[0], r[1]))
        if rows:
            out.append((n, rows))
    return out


PUBLIC_KINDS = ("voiced", "chat", "confession")


def load_moments(clean, path=MOMENTS):
    """site/content/moments.json with every quote through clean(); [] without the file. Only what viewers already saw
    (site/moments.py writes no other): a quote whose kind is not voiced, chat or a confession is dropped here too."""
    try:
        data = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return []
    out = []
    for m in data if isinstance(data, list) else []:
        if not isinstance(m, dict):
            continue
        quotes = [dict(q, text=clean(q.get("text") or "")) for q in m.get("quotes") or []
                  if q.get("text") and any(k in str(q.get("kind") or "").lower() for k in PUBLIC_KINDS)]
        if quotes:
            out.append(dict(m, quotes=quotes, seen=[s for s in m.get("seen") or [] if s in ("voiced", "chat")]))
    return out


def moments_section(moments, agent, esc):
    """Highlights: one card per moment, newest shift first: title, agents, shift and time (PDT), the quotes with who
    said them and how, and who saw it (on stream, in chat, private)."""
    if not moments:
        return ""
    def name(k):
        try:
            return agent(k)["name"]
        except (KeyError, TypeError):
            return k.capitalize()
    cards = []
    for m in sorted(moments, key=lambda m: (-(m.get("shift") or 0), m.get("n") or 0)):
        who = ", ".join(name(k) for k in m.get("agents") or [])
        title = str(m.get("title") or "")
        m = dict(m, title=title[:1].upper() + title[1:])
        quotes = "".join(f'<blockquote>{esc(str(q["text"]))}<cite>{esc(name(q["who"]) if q.get("who") else "")}'
                         f'{" · " + esc(str(q["kind"])) if q.get("kind") else ""}</cite></blockquote>' for q in m["quotes"])
        seen = "".join(f'<span class="{k}">{esc(SEEN[k])}</span>' for k in m.get("seen") or [] if k in SEEN)
        cards.append(f'<article class="hl-moment" id="m{int(m.get("n") or 0)}" data-agents="{esc(" ".join(m.get("agents") or []))}">'
                     f'<h3>{esc(str(m.get("title") or ""))}</h3><p class="m-meta">{esc(who)} · Shift {esc(str(m.get("shift") or "?"))} · '
                     f'{esc(str(m.get("time") or ""))} PDT</p>{quotes}'
                     + (f'<p class="m-seen">Seen: {seen}</p>' if seen else "") + '</article>')
    return (f'<section class="hl-highlights" id="highlights"><h2>Highlights<span class="h-sub">{len(cards)} moments</span></h2>'
            f'<div class="hl-moments">{"".join(cards)}</div></section>')


def build_chat(shifts, agent, avatar, esc, game_time, order=(), moments=()):
    """The /chat/ page body and its head extras. order: the agents' keys in the site's order; moments: load_moments()."""
    total = sum(len(r) for _, r in shifts)
    counts = {k: sum(1 for _, rows in shifts for r in rows if r[2] == k) for k, _ in KINDS}
    present = {r[1] for _, rows in shifts for r in rows}
    keys = [k for k in order if k in present] + sorted(present - set(order))
    options = '<option value="">All agents</option>' + "".join(
        f'<option value="{esc(k)}">{esc(agent(k)["name"])}</option>' for k in keys)
    boxes = "".join(f'<label><input type="checkbox" value="{k}" checked> {esc(label)} ({counts[k]})</label>'
                    for k, label in KINDS)
    # each agent's colour once, for its name in the rows; the legend links its card
    colours = "".join(f"table.hl td.who.{k} {{ border-left: 3px solid {agent(k).get('color') or '#888'}; }}" for k in keys)
    legend = " ".join(f'<a class="chip" href="/agents/#{esc(k)}">{avatar(k, "sm")}{esc(agent(k)["name"])}</a>' for k in keys)
    sections = []
    # (batch270) each shift's lines folded except the newest shift's: the page was over 2 million px tall on a phone; a
    # search or an agent opens every shift with a match, a link to a line (#sN-I) opens its shift
    first = True
    for n, rows in reversed(shifts):  # the newest shift first
        trs = []
        for i, (tick, k, kind, why, text) in enumerate(rows):
            label = "Confession" if kind == "confession" else f"Spoken{' · ' + WHY[why] if why in WHY else ''}"
            # a coloured name per row (an avatar on each of a thousand rows doubled the page); id s<shift>-<i> for
            # the site search's links
            trs.append(f'<tr id="s{n}-{i}" data-kind="{kind}" data-agent="{esc(k)}"><td class="t">{esc(game_time(tick))}</td>'
                       f'<td class="who {esc(k)}">{esc(agent(k)["name"])}</td>'
                       f'<td class="kind">{esc(label)}</td><td class="text">{esc(text)}</td></tr>')
        sections.append(f'<section class="hl-shift" id="shift-{n}"><h2>Shift {n}<span class="h-sub">{len(rows)} lines</span></h2>'
                        f'<details class="hl-fold"{" open" if first else ""}><summary>The lines of shift {n}</summary>'
                        f'<div class="table-wrap"><table class="hl"><thead><tr><th scope="col">Game time</th>'
                        f'<th scope="col">Agent</th><th scope="col">Kind</th><th scope="col">Line</th></tr></thead>'
                        f'<tbody>{"".join(trs)}</tbody></table></div></details></section>')
        first = False
    body = (f'<h1>Chat highlights</h1><p class="lede">Lines the agents spoke on stream and their confessions, '
            f'{total} in all.</p>'
            f'<div class="hl-controls" role="search"><input id="hl-q" class="fx-textfield" type="search" '
            f'placeholder="Search lines" aria-label="Search lines"><select id="hl-agent" class="fx-textfield" '
            f'aria-label="Agent">{options}</select>{boxes}<span id="hl-count" class="hl-count" aria-live="polite">'
            f'{total} lines</span></div><p class="chips">{legend}</p>' + moments_section(moments, agent, esc)
            + "".join(sections) + SCRIPT)
    return body, STYLE.replace("</style>", colours + "\n</style>")
