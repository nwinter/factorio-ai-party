"""The team's blueprint library on the site (/blueprints/; viewer Foobator, asked twice).

tools/bplibrary.py mirrors the library (blueprint_save and friends in the harness) into each shift's folder:
runs/RUN/blueprints/index.json (every entry's facts) and NAME.txt (its blueprint string). The page reads the newest
shift folder that has a copy: per entry its name, author, footprint, entity counts, description, uses, last use, the
surface it was saved on, and the blueprint string behind a copy control, so a viewer can import it into their own
game.

Pictures (d17 08:35): "Show the picture" loads FPSR's embed (fpsr.fprints.xyz/?embed=1, MIT, Factorio 2.x with Space
Age, quality and elevated rails) in an iframe under the entry and hands it the string by postMessage, the documented
third-party protocol (fpsr:ready -> fpsr:load {version: 1, blueprint} -> fpsr:loaded / fpsr:error). Nothing loads from
FPSR until a viewer asks; "Hide" removes the iframe. FPSR's planner draws every entity and tile of the 23 library
blueprints of shift 28; Factorio Blueprint Editor (base game only) refuses 14 of them (platforms, Aquilo, recyclers).
"""
import json
import re
from pathlib import Path

NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,39}")

# (d24 batch145 PQ1, viewer Foobator: "a search function and maybe categories ... some kind of mark for
# current/experimental/obsolete") Categories come from facts the library holds: where the entry was saved (a planet, or
# a space platform's surface), and the entities in it (its counts, every entity name). An entry is in a kind when it
# holds at least one of the kind's entities; it can be in several, or in none. The page shows these rules.
KINDS = [
    ("rail", "Rail", ("straight-rail", "curved-rail-a", "curved-rail-b", "half-diagonal-rail", "rail-ramp", "rail-support",
                      "elevated-straight-rail", "elevated-curved-rail-a", "elevated-curved-rail-b", "elevated-half-diagonal-rail",
                      "train-stop", "rail-signal", "rail-chain-signal", "locomotive", "cargo-wagon", "fluid-wagon", "artillery-wagon")),
    ("power", "Power and heat", ("solar-panel", "accumulator", "steam-engine", "steam-turbine", "boiler", "nuclear-reactor",
                                 "heat-exchanger", "heat-pipe", "fusion-reactor", "fusion-generator", "lightning-rod",
                                 "lightning-collector", "heating-tower", "burner-generator")),
    ("defence", "Defence", ("gun-turret", "laser-turret", "flamethrower-turret", "rocket-turret", "railgun-turret",
                            "tesla-turret", "artillery-turret", "stone-wall", "gate", "land-mine")),
    ("science", "Science (labs)", ("lab", "biolab")),
    ("smelting", "Smelting and casting", ("stone-furnace", "steel-furnace", "electric-furnace", "foundry")),
    ("mining", "Mining and pumping", ("burner-mining-drill", "electric-mining-drill", "big-mining-drill", "pumpjack", "offshore-pump")),
    ("chemistry", "Oil and chemistry", ("oil-refinery", "chemical-plant", "cryogenic-plant")),
    ("crafting", "Assembly and special crafting", ("assembling-machine-1", "assembling-machine-2", "assembling-machine-3",
                                                   "electromagnetic-plant", "biochamber", "centrifuge", "recycler", "crusher")),
    ("hull", "Platform hull", ("space-platform-hub", "thruster", "asteroid-collector", "cargo-bay")),
    ("robots", "Robots and logistic chests", ("roboport", "requester-chest", "passive-provider-chest", "active-provider-chest",
                                              "storage-chest", "buffer-chest")),
    ("circuits", "Circuits", ("arithmetic-combinator", "decider-combinator", "constant-combinator", "selector-combinator",
                              "programmable-speaker", "power-switch", "display-panel")),
]
STATUSES = ("current", "experimental", "obsolete")
SORTS = (("newest", "Newest saved"), ("used", "Most used"), ("name", "Name"))


def entity_names(e):
    """The entity names in an entry's counts ("stone-wall*52 gun-turret*4"; a short form ends "+3 more")."""
    return [part.rsplit("*", 1)[0] for part in str(e.get("counts") or "").split() if "*" in part]


def place_of(e):
    """('platform', 'Space platform') for a platform's surface, (planet, Planet) for a planet, else None."""
    surface = str(e.get("surface") or "")
    if not surface:
        return None
    if surface.startswith("platform-"):
        return "platform", "Space platform"
    return surface, surface.capitalize()


def kinds_of(e):
    names = set(entity_names(e))
    return [k for k, _, ents in KINDS if names.intersection(ents)]


def status_of(e):
    v = e.get("status")
    return v if v in STATUSES else "none"


def latest(long, runs_dir):
    """The newest shift's copy of the library: {shift (n), id, written, revision, tick, entries [{..., string}]}, or
    None when no shift has one."""
    for s in reversed((long or {}).get("shifts") or []):
        folder = Path(runs_dir) / s["id"] / "blueprints"
        try:
            index = json.loads((folder / "index.json").read_text())
        except (OSError, ValueError):
            continue
        entries = []
        for e in index.get("entries") or []:
            if not isinstance(e, dict) or not NAME.fullmatch(str(e.get("name", ""))):
                continue
            try:
                text = (folder / f"{e['name']}.txt").read_text().strip()
            except OSError:
                text = None
            entries.append(dict(e, string=text or None))
        entries.sort(key=lambda e: (-(e.get("saved_tick") or 0), e["name"]))
        return {"shift": s["n"], "id": s["id"], "written": index.get("written"), "revision": index.get("revision"),
                "tick": index.get("tick"), "entries": entries}
    return None


STYLE = """<style>
.bp-list{list-style:none;padding:0;display:grid;gap:1rem}
.bp-entry{border:1px solid var(--fx-border,#444);border-left:4px solid var(--fx-agent,#888);padding:.75rem 1rem;border-radius:4px}
.bp-entry h2{font-size:1.1rem;margin:0 0 .25rem;display:flex;flex-wrap:wrap;gap:.5rem;align-items:center}
.bp-entry dl{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:.15rem .75rem;margin:.5rem 0}
.bp-entry dd,.bp-entry p,.bp-entry h2{overflow-wrap:anywhere;min-width:0}
.bp-entry dt{color:var(--fx-muted,#aaa)}
.bp-entry dd{margin:0}
.bp-entry textarea{width:100%;height:5rem;font-family:monospace;font-size:.75rem;word-break:break-all}
.bp-copy{margin-top:.25rem}
.bp-pic{margin:.5rem 0}
.bp-pic iframe{display:block;width:100%;height:24rem;border:1px solid var(--fx-border,#444);margin-top:.4rem;background:#1b1b1b}
.bp-pic.is-large iframe{height:80vh}
.bp-pic-note:empty{display:none}
.bp-tools{display:flex;flex-wrap:wrap;gap:.5rem 1rem;align-items:end;margin:1rem 0 .5rem}
.bp-tools label{display:flex;flex-direction:column;gap:.15rem;font-size:.85rem;color:var(--fx-muted,#aaa)}
.bp-tools input,.bp-tools select{font:inherit;padding:.3rem .45rem;min-width:9rem}
.bp-tools input[type=search]{min-width:16rem}
.bp-shown{margin:.25rem 0 .75rem}
.bp-tools[hidden],.bp-shown[hidden]{display:none}
.bp-status{font-size:.75rem;padding:.05rem .45rem;border-radius:999px;border:1px solid currentColor;font-weight:600}
.bp-status--current{color:#3fae5a}
.bp-status--experimental{color:#d9a40e}
.bp-status--obsolete{color:#c45050}
.bp-status--none{color:var(--fx-muted,#999);font-weight:400}
.bp-kinds{font-size:.8rem;color:var(--fx-muted,#aaa)}
</style>"""

# Search, filters and sorting (d24 batch145 PQ1): in the page, over each entry's data attributes; nothing reloads. The
# URL keeps them (?q=&place=&kind=&status=&sort=), so a view can be shared. Without script every entry shows.
FILTER_JS = """<script>
(function () {
  // (the page's head carries this script: it starts once the list is parsed)
  if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', start); return; }
  start();
  function start() {
  var tools = document.getElementById('bp-tools'), list = document.getElementById('bp-list');
  if (!tools || !list) return;
  var q = document.getElementById('bp-q'), place = document.getElementById('bp-place'), kind = document.getElementById('bp-kind'),
    status = document.getElementById('bp-status'), sort = document.getElementById('bp-sort'), shown = document.getElementById('bp-shown');
  var items = Array.prototype.slice.call(list.children), total = items.length, sorted = 'newest';
  var params = new URLSearchParams(location.search);
  function pick(sel, v) { if (v && Array.prototype.some.call(sel.options, function (o) { return o.value === v; })) sel.value = v; }
  q.value = params.get('q') || ''; pick(place, params.get('place')); pick(kind, params.get('kind')); pick(status, params.get('status')); pick(sort, params.get('sort'));
  function order() {
    if (sort.value === sorted) return;
    sorted = sort.value;
    var by = sorted === 'name' ? function (a, b) { return a.dataset.name < b.dataset.name ? -1 : a.dataset.name > b.dataset.name ? 1 : 0; }
      : sorted === 'used' ? function (a, b) { return (+b.dataset.uses - +a.dataset.uses) || (+b.dataset.saved - +a.dataset.saved); }
      : function (a, b) { return (+b.dataset.saved - +a.dataset.saved) || (a.dataset.name < b.dataset.name ? -1 : 1); };
    items.slice().sort(by).forEach(function (li) { list.appendChild(li); });
  }
  function apply() {
    var words = q.value.toLowerCase().split(/\\s+/).filter(Boolean), n = 0;
    items.forEach(function (li) {
      var d = li.dataset, ok = words.every(function (w) { return d.q.indexOf(w) >= 0; })
        && (!place.value || d.place === place.value)
        && (!kind.value || (' ' + d.kinds + ' ').indexOf(' ' + kind.value + ' ') >= 0)
        && (!status.value || d.status === status.value);
      li.hidden = !ok; if (ok) n++;
    });
    order();
    shown.textContent = n === total ? 'Showing all ' + total + ' blueprints' : 'Showing ' + n + ' of ' + total + ' blueprints';
    var p = new URLSearchParams();
    if (q.value.trim()) p.set('q', q.value.trim());
    [['place', place], ['kind', kind], ['status', status]].forEach(function (x) { if (x[1].value) p.set(x[0], x[1].value); });
    if (sort.value !== 'newest') p.set('sort', sort.value);
    var s = p.toString();
    history.replaceState(null, '', location.pathname + (s ? '?' + s : '') + location.hash);
  }
  [q, place, kind, status, sort].forEach(function (el) { el.addEventListener(el === q ? 'input' : 'change', apply); });
  tools.hidden = false; shown.hidden = false;
  apply();
  }
})();
</script>"""

COPY_JS = """<script>
document.addEventListener('click', function (ev) {
  var b = ev.target.closest && ev.target.closest('.bp-copy');
  if (!b) return;
  var box = document.getElementById(b.getAttribute('data-for'));
  if (!box) return;
  function done(ok) { b.textContent = ok ? 'Copied' : 'Select and copy the text above'; setTimeout(function () { b.textContent = 'Copy the blueprint string'; }, 2500); }
  if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(box.value).then(function () { done(true); }, function () { box.select(); done(false); });
  else { box.select(); try { done(document.execCommand('copy')); } catch (e) { done(false); } }
});
</script>"""


FPSR = "https://fpsr.fprints.xyz"  # the renderer's origin: the embed's src and the only target of the string

# The picture: FPSR's embed in an iframe, given the entry's string once it says fpsr:ready (it repeats that every 250 ms
# until a load arrives). Only messages from that iframe count; the string goes to FPSR's origin only.
PIC_JS = """<script>
(function () {
  var FPSR = '@FPSR@';
  document.addEventListener('click', function (ev) {
    var b = ev.target.closest && ev.target.closest('[data-pic]');
    if (!b) return;
    var box = b.closest('.bp-pic'), note = box.querySelector('.bp-pic-note'), act = b.getAttribute('data-pic');
    var frame = box.querySelector('iframe');
    if (act === 'large') { box.classList.toggle('is-large'); b.textContent = box.classList.contains('is-large') ? 'Smaller' : 'Larger'; return; }
    if (frame) {  // hide: the iframe goes, and its memory with it
      window.removeEventListener('message', frame.onFpsr); frame.remove(); box.classList.remove('is-large'); note.textContent = '';
      b.textContent = 'Show the picture'; box.querySelector('[data-pic=large]').hidden = true;
      return;
    }
    var text = document.getElementById(box.getAttribute('data-for'));
    if (!text) return;
    frame = document.createElement('iframe');
    frame.src = FPSR + '/?embed=1';
    frame.title = 'Picture of ' + box.getAttribute('data-name') + ', drawn by FPSR';
    frame.setAttribute('referrerpolicy', 'no-referrer');
    note.textContent = 'Loading the picture from FPSR…';
    frame.onFpsr = function (e) {
      if (!frame.contentWindow || e.source !== frame.contentWindow || e.origin !== FPSR) return;
      var d = e.data || {};
      if (d.type === 'fpsr:ready') frame.contentWindow.postMessage({ type: 'fpsr:load', version: 1, blueprint: text.value }, FPSR);
      else if (d.type === 'fpsr:loaded') note.textContent = '';
      else if (d.type === 'fpsr:error') note.textContent = 'FPSR could not draw it: ' + String(d.message || 'unknown error').slice(0, 200);
    };
    window.addEventListener('message', frame.onFpsr);
    box.appendChild(frame);
    b.textContent = 'Hide the picture'; box.querySelector('[data-pic=large]').hidden = false;
  });
})();
</script>""".replace("@FPSR@", FPSR)


# (d19 batch42 B4, seq 870: lab-belt-four41 was in the team library and not on the page) The page is built at each
# shift change from the newest shift's copy; the live state's `library` (tools/stream/library.py: the newest 15 entries,
# no strings) adds the ones saved since, with author and time. Nothing shows without a live shift.
LIVE_JS = """<script>
(function () {
  // (d24 batch145) in the page's head: it starts once the page is parsed (before, the section was never found)
  if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', start); return; }
  start();
  function start() {
  var sec = document.getElementById('bp-live');
  if (!sec || !window.fetch) return;
  var api = (sec.getAttribute('data-api') || '').replace(/[/]$/, '');
  if (!api) return;
  var have = {};
  document.querySelectorAll('.bp-entry[data-saved]').forEach(function (li) { have[li.id] = +li.getAttribute('data-saved') || 0; });
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return '&#' + c.charCodeAt(0) + ';'; }); }
  fetch(api + '/v1/state', { cache: 'no-store' }).then(function (r) { return r.ok ? r.json() : null; }).then(function (d) {
    var s = d && d.state, lib = s && s.library;
    if (!lib || !Array.isArray(lib.entries) || !isFinite(s.tick) || !isFinite(s.now)) return;
    var rows = lib.entries.filter(function (e) { return e && e.name && (!(e.name in have) || (e.saved_tick || 0) > have[e.name]); });
    if (!rows.length) return;
    sec.querySelector('ul').innerHTML = rows.map(function (e) {
      var at = isFinite(e.saved_tick) ? new Date((s.now - (s.tick - e.saved_tick) / 60) * 1000) : null;
      var when = at ? at.toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }) : 'time unknown';
      var facts = [e.author ? 'by ' + e.author : '', 'saved ' + when, e.entities != null ? e.entities + ' entities' : '',
        e.footprint ? e.footprint + ' tiles' : '', e.surface ? 'on ' + String(e.surface).replace('platform-', 'platform ') : ''].filter(Boolean);
      return '<li class="bp-entry"><h2>' + esc(e.name) + (e.name in have ? ' <span class="chip">saved again</span>' : '') + '</h2>' +
        (e.description ? '<p>' + esc(e.description) + '</p>' : '') + '<p class="muted small">' + esc(facts.join(' · ')) + '</p></li>';
    }).join('');
    sec.hidden = false;
  }).catch(function () {});
  }
})();
</script>"""


def build_page(lib, agent, avatar, esc, game_time, known=(), api=""):
    """The Blueprints page: (body, extra_head). api: the live API (site/config.json live_api_url): the entries saved
    since the page was built come from its state."""
    known = set(known)
    if not lib or not lib["entries"]:
        body = ('<h1>Blueprints</h1><p class="lede">The team\'s shared blueprint library.</p>'
                '<p class="muted">No blueprints saved yet.</p>')
        return body, STYLE
    items = []
    for i, e in enumerate(lib["entries"]):
        key = str(e.get("author") or "").lower()
        who = (f'<span class="chip">{avatar(key, "sm")}{esc(agent(key)["name"])}</span>' if key in known
               else f'<span class="chip">{esc(e.get("author") or "?")}</span>')
        color = (agent(key).get("color") or "#888888") if key in known else "#888888"
        rows = [("Author", who)]
        if e.get("footprint"):
            rows.append(("Footprint", esc(f'{e["footprint"]} tiles')))
        counts = e.get("counts")
        if counts:
            rows.append(("Entities", esc(f'{e.get("entities") or "?"}: ' + str(counts).replace("*", " x"))))
        elif e.get("entities") is not None:
            rows.append(("Entities", esc(str(e["entities"]))))
        if e.get("tiles"):
            rows.append(("Tiles", esc(str(e["tiles"]))))
        if e.get("surface"):
            pname = f' ({e["platform_name"]})' if e.get("platform_name") else ""
            rows.append(("Saved on", esc(str(e["surface"]).replace("platform-", "platform ") + pname)))
        if e.get("saved_tick"):
            rows.append(("Saved", esc(f'game time {game_time(e["saved_tick"])}')))
        uses = e.get("uses") or 0
        last = (f', last {e["last_used"]}' if e.get("last_used") and e["last_used"] != "never" else ", never placed")
        rows.append(("Uses", esc(f'{uses}' + last)))
        # (PQ1) the status mark: who set it and when; no mark reads "not marked" (never inferred from age)
        st = status_of(e)
        if st != "none":
            by = f' by {e["status_by"]}' if e.get("status_by") else ""
            at = f', game time {game_time(e["status_tick"])}' if e.get("status_tick") else ""
            note = f': {e["status_note"]}' if e.get("status_note") else ""
            rows.append(("Status", esc(f"{st}, marked{by}{at}{note}")))
        else:
            rows.append(("Status", esc("not marked")))
        if e.get("retired"):
            rows.append(("Retired", esc(str(e["retired"]))))
        kinds = kinds_of(e)
        place = place_of(e)
        labels = [label for k, label, _ in KINDS if k in kinds]
        if labels:
            rows.append(("Kinds", esc(", ".join(labels))))
        dl = "".join(f"<dt>{k}</dt><dd>{v}</dd>" for k, v in rows)
        desc = f'<p>{esc(e["description"])}</p>' if e.get("description") else ""
        if e.get("string"):
            box = f"bp-{i}"
            pic = (f'<div class="bp-pic" data-for="{box}" data-name="{esc(e["name"])}">'
                   '<button type="button" class="fx-btn fx-btn--small" data-pic="show">Show the picture</button> '
                   '<button type="button" class="fx-btn fx-btn--small" data-pic="large" hidden>Larger</button> '
                   f'<span class="muted small">drawn by <a href="{FPSR}/" rel="noopener">FPSR</a>, a blueprint renderer</span>'
                   '<p class="bp-pic-note small muted" aria-live="polite"></p></div>')
            string = pic + (f'<details><summary>Blueprint string ({len(e["string"]):,} characters)</summary>'
                      f'<textarea id="{box}" readonly aria-label="Blueprint string of {esc(e["name"])}">{esc(e["string"])}</textarea>'
                      f'<button type="button" class="fx-btn fx-btn--small bp-copy" data-for="{box}">Copy the blueprint string</button></details>')
        else:
            string = '<p class="muted small">The string is not in this copy.</p>'
        surface = str(e.get("surface") or "")
        search = " ".join(str(x) for x in [e["name"], e.get("author") or "", e.get("description") or "", " ".join(entity_names(e)),
                                             surface, surface.replace("platform-", "platform "), e.get("platform_name") or "",
                                             "not marked" if st == "none" else st] if x).lower()
        mark = (f'<span class="bp-status bp-status--{st}">{"not marked" if st == "none" else st}</span>')
        items.append(f'<li class="bp-entry" id="{esc(e["name"])}" data-saved="{int(e.get("saved_tick") or 0)}" '
                     f'data-uses="{int(uses)}" data-name="{esc(e["name"].lower())}" data-q="{esc(search)}" '
                     f'data-place="{esc(place[0] if place else "")}" data-kinds="{esc(" ".join(kinds))}" data-status="{st}" '
                     f'style="--fx-agent:{esc(color)}"><h2>{esc(e["name"])} {mark}</h2>'
                     f'{desc}<dl>{dl}</dl>{string}</li>')
    when = f' (shift {lib["shift"]}, copied {esc(str(lib["written"]).replace("T", " "))})' if lib.get("written") else f' (shift {lib["shift"]})'
    live = (f'<section id="bp-live" data-api="{esc(api)}" hidden><h2>Saved since this page was built</h2>'
            '<p class="muted small">From the live game: the team\'s newest library entries that are not below, or were '
            'saved again, with author and time. Their blueprint strings and pictures come with the next site build, at '
            'the shift change.</p><ul class="bp-list"></ul></section>') if api else ""
    body = ('<h1>Blueprints</h1><p class="lede">The team\'s shared blueprint library: what the agents saved for each other '
            f'with blueprint_save, as the last copy holds it{when}. Each string imports into your own game '
            '(Import string in the blueprint library). "Show the picture" draws it with FPSR, a blueprint renderer on '
            'another site, which the string is sent to.</p>'
            f'<p class="muted small">{len(lib["entries"])} blueprints; times are the copy\'s. This page is built at each '
            'shift change from the library as that shift left it.</p>'
            f'{live}{tools(lib["entries"], esc)}<ul class="bp-list" id="bp-list">{"".join(items)}</ul>')
    return body, STYLE + "\n" + COPY_JS + "\n" + PIC_JS + "\n" + FILTER_JS + ("\n" + LIVE_JS if api else "")


def tools(entries, esc):
    """The search box, the place, kind and status filters, the sort, the count shown and how a kind is decided. Hidden
    until the page's script runs (without it every entry shows)."""
    places, kinds, statuses = {}, {}, {}
    for e in entries:
        p = place_of(e)
        if p:
            places.setdefault(p[0], [p[1], 0])[1] += 1
        for k in kinds_of(e):
            kinds[k] = kinds.get(k, 0) + 1
        st = status_of(e)
        statuses[st] = statuses.get(st, 0) + 1
    order = ["nauvis", "vulcanus", "fulgora", "gleba", "aquilo"]
    place_opts = "".join(f'<option value="{esc(k)}">{esc(v[0])} ({v[1]})</option>'
                         for k, v in sorted(places.items(), key=lambda kv: (kv[0] == "platform", order.index(kv[0]) if kv[0] in order else 9, kv[0])))
    kind_opts = "".join(f'<option value="{k}">{esc(label)} ({kinds[k]})</option>' for k, label, _ in KINDS if kinds.get(k))
    status_opts = "".join(f'<option value="{v}">{"Not marked" if v == "none" else v.capitalize()} ({statuses.get(v, 0)})</option>'
                          for v in STATUSES + ("none",))
    sort_opts = "".join(f'<option value="{k}">{label}</option>' for k, label in SORTS)
    rules = "".join(f'<li><b>{esc(label)}</b>: {esc(", ".join(ents))}</li>' for _, label, ents in KINDS)
    return ('<form id="bp-tools" class="bp-tools" role="search" hidden onsubmit="return false">'
            '<label>Search<input type="search" id="bp-q" placeholder="name, author, description, entity, surface" '
            'autocomplete="off" aria-describedby="bp-shown"></label>'
            f'<label>Where saved<select id="bp-place"><option value="">Anywhere</option>{place_opts}</select></label>'
            f'<label>Kind<select id="bp-kind"><option value="">Any kind</option>{kind_opts}</select></label>'
            f'<label>Status<select id="bp-status"><option value="">Any status</option>{status_opts}</select></label>'
            f'<label>Sort<select id="bp-sort">{sort_opts}</select></label></form>'
            '<p id="bp-shown" class="bp-shown muted small" aria-live="polite" hidden></p>'
            '<details class="small"><summary>How a kind and a status are decided</summary>'
            '<p>Where saved is the surface the entry was captured on: a planet, or a space platform. A kind comes from the '
            'entities in the blueprint: an entry is in a kind when it holds at least one of the entities below, so it can '
            f'be in several kinds or in none.</p><ul>{rules}</ul>'
            '<p>The status is a mark an agent sets on its entry (or a teammate\'s): current, experimental or obsolete, '
            'with who set it and when. An entry nobody has marked reads "not marked"; the page never guesses one from '
            'age. "Uses" says when it was last placed.</p></details>')
