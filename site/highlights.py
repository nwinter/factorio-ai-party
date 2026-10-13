"""/chat/: the agents' lines spoken on stream and their confessions, by shift, with search and filters. For
site/build.py; the lines come from tools/agent_stats.py's per-shift caches (site/agents.py's collect). Every line goes
through build.py's clean() and keep_line() like any log text on the site."""

KINDS = [("spoken", "Spoken on stream"), ("confession", "Confessions")]
WHY = {"aloud": "aloud", "reaction": "reaction", "plan": "plan", "strategy": "strategy", "request": "request"}

STYLE = """<style>
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
    document.querySelectorAll('.hl-shift').forEach(function (s) {
      s.hidden = !s.querySelector('tbody tr:not([hidden])');
    });
    count.textContent = n + ' of ' + rows.length + ' lines';
  }
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


def build_chat(shifts, agent, avatar, esc, game_time, order=()):
    """The /chat/ page body and its head extras. order: the agents' keys in the site's order."""
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
                        f'<div class="table-wrap"><table class="hl"><thead><tr><th scope="col">Game time</th>'
                        f'<th scope="col">Agent</th><th scope="col">Kind</th><th scope="col">Line</th></tr></thead>'
                        f'<tbody>{"".join(trs)}</tbody></table></div></section>')
    body = (f'<h1>Chat highlights</h1><p class="lede">Lines the agents spoke on stream and their confessions, '
            f'{total} in all.</p>'
            f'<div class="hl-controls" role="search"><input id="hl-q" class="fx-textfield" type="search" '
            f'placeholder="Search lines" aria-label="Search lines"><select id="hl-agent" class="fx-textfield" '
            f'aria-label="Agent">{options}</select>{boxes}<span id="hl-count" class="hl-count" aria-live="polite">'
            f'{total} lines</span></div><p class="chips">{legend}</p>' + "".join(sections) + SCRIPT)
    return body, STYLE.replace("</style>", colours + "\n</style>")
