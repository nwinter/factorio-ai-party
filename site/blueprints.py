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
.bp-entry dl{display:grid;grid-template-columns:max-content 1fr;gap:.15rem .75rem;margin:.5rem 0}
.bp-entry dt{color:var(--fx-muted,#aaa)}
.bp-entry dd{margin:0}
.bp-entry textarea{width:100%;height:5rem;font-family:monospace;font-size:.75rem;word-break:break-all}
.bp-copy{margin-top:.25rem}
.bp-pic{margin:.5rem 0}
.bp-pic iframe{display:block;width:100%;height:24rem;border:1px solid var(--fx-border,#444);margin-top:.4rem;background:#1b1b1b}
.bp-pic.is-large iframe{height:80vh}
.bp-pic-note:empty{display:none}
</style>"""

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
            rows.append(("Saved on", esc(str(e["surface"]).replace("platform-", "platform "))))
        if e.get("saved_tick"):
            rows.append(("Saved", esc(f'game time {game_time(e["saved_tick"])}')))
        uses = e.get("uses") or 0
        rows.append(("Uses", esc(f'{uses}' + (f', last {e["last_used"]}' if e.get("last_used") and e["last_used"] != "never" else ", never placed"))))
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
        items.append(f'<li class="bp-entry" id="{esc(e["name"])}" data-saved="{int(e.get("saved_tick") or 0)}" style="--fx-agent:{esc(color)}"><h2>{esc(e["name"])}</h2>'
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
            f'{live}<ul class="bp-list">{"".join(items)}</ul>')
    return body, STYLE + "\n" + COPY_JS + "\n" + PIC_JS + ("\n" + LIVE_JS if api else "")
