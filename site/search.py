"""/search/: one search over the agents, the shifts, the timeline's events and the chat highlights. For site/build.py:
index() makes /search/index.json (kind, title, text, url), which the page loads when it opens; build_search() is the
page. Every text in the index is already on a page of the site (and so already cleaned)."""

KINDS = [("agent", "Agents"), ("shift", "Shifts"), ("event", "Events"), ("line", "Chat")]

STYLE = """<style>
.search-box { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; margin: .8rem 0 1.2rem; }
.search-box input { flex: 1 1 18em; font-size: 1.05rem; }
.search-count { color: var(--muted); font-size: .88rem; }
.search-group h2 { font-size: 1.15rem; margin: 1.4rem 0 .5rem; }
.search-group h2 .h-sub { display: inline; margin-left: .4em; font-size: .9rem; }
.search-results { list-style: none; padding: 0; margin: 0; }
.search-results li { padding: 6px 0; border-bottom: 1px solid var(--line); }
.search-results li:last-child { border-bottom: 0; }
.search-results a { font-weight: 600; }
.search-results .sub { color: var(--muted); font-size: .85rem; margin-left: .4em; }
.search-results .text { display: block; color: var(--ink-2); font-size: .92rem; overflow-wrap: anywhere; }
.search-results mark { background: var(--hl); color: inherit; padding: 0 1px; }
.search-more { color: var(--muted); font-size: .85rem; }
</style>"""

SCRIPT = """<script>
(function () {
  var q = document.getElementById('search-q'), out = document.getElementById('search-out'),
      count = document.getElementById('search-count'), index = null, LIMIT = 25;
  var kinds = %s;
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'}[c]; }); }
  function mark(s, words) {
    var h = esc(s);
    words.forEach(function (w) {
      var e = esc(w).replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
      h = h.replace(new RegExp('(' + e + ')', 'ig'), '<mark>$1</mark>');
    });
    return h;
  }
  function run() {
    var words = q.value.toLowerCase().split(/\\s+/).filter(Boolean);
    try { history.replaceState(null, '', words.length ? '?q=' + encodeURIComponent(q.value) : location.pathname); } catch (e) {}
    if (!index) { count.textContent = 'Loading…'; return; }
    if (!words.length) { out.innerHTML = ''; count.textContent = index.length + ' entries'; return; }
    var groups = {}, n = 0;
    index.forEach(function (e) {
      var hay = e._h || (e._h = (e.title + ' ' + (e.text || '') + ' ' + (e.sub || '')).toLowerCase());
      if (words.every(function (w) { return hay.indexOf(w) >= 0; })) { (groups[e.kind] = groups[e.kind] || []).push(e); n++; }
    });
    var html = '';
    kinds.forEach(function (k) {
      var g = groups[k[0]]; if (!g) return;
      html += '<section class="search-group"><h2>' + esc(k[1]) + '<span class="h-sub">' + g.length + '</span></h2><ul class="search-results">';
      g.slice(0, LIMIT).forEach(function (e) {
        html += '<li><a href="' + esc(e.url) + '">' + mark(e.title, words) + '</a>' +
          (e.sub ? '<span class="sub">' + esc(e.sub) + '</span>' : '') +
          (e.text ? '<span class="text">' + mark(e.text, words) + '</span>' : '') + '</li>';
      });
      html += '</ul>' + (g.length > LIMIT ? '<p class="search-more">' + (g.length - LIMIT) + ' more: narrow the search</p>' : '') + '</section>';
    });
    out.innerHTML = html;
    count.textContent = n + (n === 1 ? ' result' : ' results');
  }
  try { var p = new URLSearchParams(location.search); if (p.get('q')) q.value = p.get('q'); } catch (e) {}
  q.addEventListener('input', run);
  fetch('/search/index.json').then(function (r) { return r.json(); }).then(function (d) { index = d; run(); })
    .catch(function () { count.textContent = 'The search index did not load.'; });
  run();
})();
</script>"""


def index(long, stats, events, chat, agent, game_time, keys):
    """[{kind, title, sub, text, url}]: the agents, the shifts that played, the timeline's events (in its order, so
    /timeline/#e<i> is the event) and the chat highlights (/chat/#s<shift>-<i>)."""
    out = []
    for k in keys:
        if k not in stats["totals"]:
            continue
        a = agent(k)
        t = stats["totals"][k]
        out.append({"kind": "agent", "title": a["name"], "url": f"/agents/#{k}",
                    "sub": " · ".join(x for x in (a.get("model"), a.get("maker"), a.get("harness")) if x),
                    "text": f"{t['shifts']} shifts, {t['built']:,} buildings placed, {t['deaths']} deaths"})
    for s in long["shifts"]:
        if s.get("empty") or not s.get("n"):
            continue
        out.append({"kind": "shift", "title": f"Shift {s['n']}", "url": f"/runs/long/shift-{s['n']}/",
                    "sub": f"game time {s.get('game0', '')} to {s.get('game1', '')}",
                    "text": ", ".join(str(m) for m in (s.get("moments") or [])[:12])})
    for i, (tick, n, kind, text, who) in enumerate(events):
        title = f"{agent(who)['name']} died" if who else text
        out.append({"kind": "event", "title": title, "url": f"/timeline/#e{i}", "sub": f"shift {n} · {game_time(tick)}"})
    for n, rows in chat:
        for i, (tick, k, kind, why, text) in enumerate(rows):
            out.append({"kind": "line", "title": agent(k)["name"], "url": f"/chat/#s{n}-{i}", "text": text,
                        "sub": f"{'confession' if kind == 'confession' else 'spoken'} · shift {n} · {game_time(tick)}"})
    return out


def build_search(entries, esc):
    import json
    body = ('<h1>Search</h1><div class="search-box" role="search"><input id="search-q" class="fx-textfield" '
            'type="search" placeholder="Agents, research, rockets, deaths, chat lines" aria-label="Search the site" '
            f'autofocus><span id="search-count" class="search-count" aria-live="polite">{len(entries)} entries</span>'
            '</div><div id="search-out"></div>' + SCRIPT.replace("%s", json.dumps(KINDS)))
    return body, STYLE
