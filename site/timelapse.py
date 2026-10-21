"""The base's time-lapse on the long run page: every shift's basemap snapshots (runs/RUN/basemap/TICK.json, written
by tools/stream/basemap_log.py, one per 10 game minutes) in one /runs/long/timelapse.json, and a section with a
scrubbable map (a slider over all the snapshots, play, a mark per shift). For site/build.py, which adds the section
to the run page; nothing shows until a shift has snapshots. The map is the live map's viewer (static/mapview.js: pan,
zoom, layers, full screen), with each snapshot's nests and turrets, and terrain frames up to its tick."""
import json
from pathlib import Path

GRID = ("cell", "x0", "y0", "w", "h", "rows")


def grid(g):
    if not isinstance(g, dict) or not isinstance(g.get("rows"), list) or not g.get("cell"):
        return None
    out = {k: g[k] for k in GRID if k in g}
    out["rows"] = [str(r) for r in g["rows"]]
    out.setdefault("h", len(out["rows"]))
    out.setdefault("w", max((len(r) for r in out["rows"]), default=0))
    return out if all(isinstance(out.get(k), (int, float)) for k in ("cell", "x0", "y0")) else None


def frames(long, runs_dir, game_time):
    """[{n, tick, game, base, core}] in order over the run's shifts (shifts without snapshots add none)."""
    out = []
    for s in long["shifts"]:
        if s.get("empty") or not s.get("n"):
            continue
        d = Path(runs_dir) / s["id"] / "basemap"
        files = sorted((p for p in d.glob("*.json") if p.stem.isdigit()), key=lambda p: int(p.stem)) if d.is_dir() else []
        for p in files:
            try:
                b = json.loads(p.read_text())
            except (OSError, ValueError):
                continue
            base = grid(b)
            if not base:
                continue
            tick = int(p.stem)
            f = {"n": s["n"], "tick": tick, "game": game_time(tick), "base": base, "core": grid(b.get("core"))}
            # enemy nests and our turrets with their range (the viewer's layers), where the snapshot has them
            nests = [n[:3] for n in b.get("nests") or [] if isinstance(n, list) and len(n) >= 3]
            turrets = [t[:3] for t in b.get("turrets") or [] if isinstance(t, list) and len(t) >= 3]
            if nests:
                f["nests"] = nests
            if turrets:
                f["turrets"] = turrets
            out.append(f)
    return out


def frame_box(frames):
    """The tiles the map shows: the union of the cores (the dense base; far outposts and long pipelines would shrink
    it), or of the coarse grids when no snapshot has a core."""
    grids = [f["core"] for f in frames if f["core"]] or [f["base"] for f in frames]
    boxes = [(g["x0"], g["y0"], g["x0"] + g["w"] * g["cell"], g["y0"] + g["h"] * g["cell"]) for g in grids]
    if not boxes:
        return None
    x0, y0 = min(b[0] for b in boxes), min(b[1] for b in boxes)
    x1, y1 = max(b[2] for b in boxes), max(b[3] for b in boxes)
    pad = max(8, (x1 - x0) * 0.04)
    return [x0 - pad, y0 - pad, x1 - x0 + 2 * pad, y1 - y0 + 2 * pad]


STYLE = """
<style>
.tlapse { margin: 1rem 0 2rem; }
.tlapse-controls { display: flex; flex-wrap: wrap; gap: 8px 14px; align-items: center; margin: .6rem 0; }
.tlapse-controls input[type=range] { flex: 1 1 16em; accent-color: var(--accent); }
.tlapse-label { font-variant-numeric: tabular-nums; font-weight: 600; min-width: 13em; }
</style>"""

SCRIPT = """<script>
(function () {
  var root = document.getElementById('tlapse'); if (!root || !window.PogMap) return;
  var range = root.querySelector('input[type=range]'), label = root.querySelector('.tlapse-label'),
      play = root.querySelector('.tlapse-play'), data = null, timer = null, view = null;
  function show(i) {
    var f = data.frames[i]; if (!f) return;
    view.set({base: f.base, core: f.core, nests: f.nests, turrets: f.turrets, terrain: data.terrain, tick: f.tick, box: data.box});
    label.textContent = 'Shift ' + f.n + ' · game ' + f.game + ' · ' + (i + 1) + ' of ' + data.frames.length;
  }
  function stop() { if (timer) { clearInterval(timer); timer = null; play.textContent = 'Play'; } }
  function load() {
    if (data) return;
    data = {frames: []};
    view = PogMap.create(root.querySelector('.tlapse-map'), {storeKey: 'pog-tlapse-map', label: 'Map of the base'});
    function get(u) { return fetch(u).then(function (r) { if (!r.ok) throw new Error(u); return r.json(); }); }
    get(root.dataset.src).then(function (d) {
      // the frames come in parts (each under the host's file size limit), in order
      return Promise.all((d.parts || []).map(get)).then(function (ps) {
        ps.forEach(function (p) { d.frames = (d.frames || []).concat(p.frames || []); });
        return d;
      });
    }).then(function (d) {
      data = d;
      range.max = d.frames.length - 1; range.value = d.frames.length - 1; range.disabled = false; play.disabled = false;
      show(d.frames.length - 1);
    }).catch(function () { label.textContent = 'The time-lapse did not load.'; });
  }
  range.addEventListener('input', function () { stop(); show(+range.value); });
  play.addEventListener('click', function () {
    if (timer) return stop();
    if (+range.value >= data.frames.length - 1) range.value = 0;
    play.textContent = 'Pause';
    timer = setInterval(function () {
      var i = +range.value + 1;
      if (i >= data.frames.length) return stop();
      range.value = i; show(i);
    }, 350);
  });
  if ('IntersectionObserver' in window) {
    var io = new IntersectionObserver(function (es) { if (es.some(function (e) { return e.isIntersecting; })) { io.disconnect(); load(); } }, {rootMargin: '300px'});
    io.observe(root);
  } else load();
})();
</script>"""


def section(frames, esc, src="/runs/long/timelapse.json"):
    """The run page's time-lapse section ("" until there are two frames to move between)."""
    if len(frames or []) < 2:
        return ""
    shifts = sorted({f["n"] for f in frames})
    marks = "".join(f'<option value="{next(i for i, f in enumerate(frames) if f["n"] == n)}" label="Shift {n}"></option>'
                    for n in shifts)
    last = frames[-1]
    return (f'{STYLE}<section class="tlapse" id="timelapse" aria-labelledby="timelapse-h">'
            f'<h2 id="timelapse-h">The base over time</h2>'
            f'<p class="small muted">{len(frames)} snapshots, one per 10 game minutes, shifts {shifts[0]} to {shifts[-1]}.</p>'
            f'<div id="tlapse" data-src="{esc(src)}"><div class="tlapse-controls">'
            f'<button class="fx-btn tlapse-play" type="button" disabled>Play</button>'
            f'<input type="range" min="0" max="{len(frames) - 1}" value="{len(frames) - 1}" step="1" list="tlapse-marks" '
            f'aria-label="Snapshot" disabled><datalist id="tlapse-marks">{marks}</datalist>'
            f'<span class="tlapse-label" aria-live="polite">Shift {last["n"]} · game {esc(last["game"])}</span></div>'
            f'<div class="tlapse-map"></div></div>'
            '<script src="/static/mapview.js"></script>' + SCRIPT + "</section>")


PART_BYTES = 8 << 20  # Cloudflare Pages serves files up to 25 MiB; the whole time-lapse passed that at shift 49


def data(frames, terrain=None, src="/runs/long/timelapse.json", part_bytes=PART_BYTES):
    """{path: text} to publish: timelapse.json (the frame box in tiles, the terrain frames ({src, x0, y0, x1, y1, tick}:
    the map-camera frames with their edges in tiles; each snapshot shows those up to its tick), count, and parts: the
    frames' files in order) and the parts (timelapse-1.json ...: {frames}, each under part_bytes, filled from the first
    frame on, so a full part's text stays the same as later shifts add frames)."""
    stem = src.rsplit(".", 1)[0]
    parts, cur, size = [], [], 0
    for f in frames:
        n = len(json.dumps(f, separators=(",", ":"))) + 1
        if cur and size + n > part_bytes:
            parts.append(cur)
            cur, size = [], 0
        cur.append(f)
        size += n
    if cur:
        parts.append(cur)
    srcs = [f"{stem}-{i}.json" for i in range(1, len(parts) + 1)]
    index = {"box": frame_box(frames), "count": len(frames), "parts": srcs}
    if terrain:
        index["terrain"] = terrain
    out = {src: json.dumps(index, separators=(",", ":"))}
    out.update({u: json.dumps({"frames": p}, separators=(",", ":")) for u, p in zip(srcs, parts)})
    return out


def inject(page_html, sec):
    """The run page with the section at the end of its main column."""
    if not sec or "</main>" not in page_html:
        return page_html
    return page_html.replace("\n</main>", "\n" + sec + "\n</main>", 1)
