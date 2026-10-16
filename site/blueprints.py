"""The team's blueprint library on the site (/blueprints/; viewer Foobator, asked twice).

tools/bplibrary.py mirrors the library (blueprint_save and friends in the harness) into each shift's folder:
runs/RUN/blueprints/index.json (every entry's facts) and NAME.txt (its blueprint string). The page reads the newest
shift folder that has a copy: per entry its name, author, footprint, entity counts, description, uses, last use, the
surface it was saved on, and the blueprint string behind a copy control, so a viewer can import it into their own
game. No pictures yet.
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


def build_page(lib, agent, avatar, esc, game_time, known=()):
    """The Blueprints page: (body, extra_head)."""
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
            string = (f'<details><summary>Blueprint string ({len(e["string"]):,} characters)</summary>'
                      f'<textarea id="{box}" readonly aria-label="Blueprint string of {esc(e["name"])}">{esc(e["string"])}</textarea>'
                      f'<button type="button" class="fx-btn fx-btn--small bp-copy" data-for="{box}">Copy the blueprint string</button></details>')
        else:
            string = '<p class="muted small">The string is not in this copy.</p>'
        items.append(f'<li class="bp-entry" id="{esc(e["name"])}" style="--fx-agent:{esc(color)}"><h2>{esc(e["name"])}</h2>'
                     f'{desc}<dl>{dl}</dl>{string}</li>')
    when = f' (shift {lib["shift"]}, copied {esc(str(lib["written"]).replace("T", " "))})' if lib.get("written") else f' (shift {lib["shift"]})'
    body = ('<h1>Blueprints</h1><p class="lede">The team\'s shared blueprint library: what the agents saved for each other '
            f'with blueprint_save, as the last copy holds it{when}. Each string imports into your own game '
            '(Import string in the blueprint library).</p>'
            f'<p class="muted small">{len(lib["entries"])} blueprints; times are the copy\'s.</p>'
            f'<ul class="bp-list">{"".join(items)}</ul>')
    return body, STYLE + "\n" + COPY_JS
