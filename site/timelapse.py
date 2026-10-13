"""The base's time-lapse on the long run page: every shift's basemap snapshots (runs/RUN/basemap/TICK.json, written
by tools/stream/basemap_log.py, one per 10 game minutes) in one /runs/long/timelapse.json, and a section with a
scrubbable map (a slider over all the snapshots, play, a mark per shift). For site/build.py, which adds the section
to the run page; nothing shows until a shift has snapshots. The map uses the live map's category colours (.b-X)."""
import json
from pathlib import Path

CATS = [("D", "Defence"), ("R", "Labs"), ("O", "Oil and chemistry"), ("A", "Assembly"), ("S", "Smelting"),
        ("M", "Mining"), ("E", "Power"), ("L", "Logistics"), ("K", "Storage"), ("I", "Inserters"), ("B", "Belts"),
        ("T", "Rails"), ("P", "Pipes")]
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
            out.append({"n": s["n"], "tick": tick, "game": game_time(tick), "base": base, "core": grid(b.get("core"))})
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
.tlapse-stage { background: var(--well); box-shadow: var(--well-shadow); border-radius: var(--fx-r-1); }
.tlapse-stage svg { display: block; width: 100%; height: auto; max-height: 72vh; }
.tlapse-stage .coarse path { opacity: .45; }
.tlapse-stage path { shape-rendering: crispEdges; }
.tlapse-controls { display: flex; flex-wrap: wrap; gap: 8px 14px; align-items: center; margin: .6rem 0; }
.tlapse-controls input[type=range] { flex: 1 1 16em; accent-color: var(--accent); }
.tlapse-label { font-variant-numeric: tabular-nums; font-weight: 600; min-width: 13em; }
.tlapse-legend { display: flex; flex-wrap: wrap; gap: 4px 12px; font-size: .82rem; color: var(--ink-2); margin: .4rem 0 0; padding: 0; list-style: none; }
.tlapse-legend i { display: inline-block; width: 10px; height: 10px; margin-right: 5px; vertical-align: -1px; border-radius: 2px; }
</style>"""

SCRIPT = """<script>
(function () {
  var root = document.getElementById('tlapse'); if (!root) return;
  var svg = root.querySelector('svg'), range = root.querySelector('input[type=range]'),
      label = root.querySelector('.tlapse-label'), play = root.querySelector('.tlapse-play'), data = null, timer = null;
  var CATS = %s;
  function paths(g) {
    var d = {}; CATS.forEach(function (c) { d[c] = []; });
    g.rows.forEach(function (row, r) {
      for (var c = 0; c < row.length;) {
        var ch = row.charAt(c), n = 1;
        while (c + n < row.length && row.charAt(c + n) === ch) n++;
        if (d[ch]) d[ch].push('M' + c + ' ' + r + 'h' + n + 'v1h-' + n + 'z');
        c += n;
      }
    });
    return CATS.filter(function (c) { return d[c].length; }).map(function (c) {
      return '<path class="b-' + c + '" d="' + d[c].join('') + '"/>';
    }).join('');
  }
  function layer(g, cls) {
    return '<g class="' + cls + '" transform="translate(' + g.x0 + ' ' + g.y0 + ') scale(' + g.cell + ')">' + paths(g) + '</g>';
  }
  function show(i) {
    var f = data.frames[i]; if (!f) return;
    svg.innerHTML = layer(f.base, 'coarse') + (f.core ? layer(f.core, 'core') : '');
    label.textContent = 'Shift ' + f.n + ' · game ' + f.game + ' · ' + (i + 1) + ' of ' + data.frames.length;
  }
  function stop() { if (timer) { clearInterval(timer); timer = null; play.textContent = 'Play'; } }
  function load() {
    if (data) return;
    data = {frames: []};
    fetch(root.dataset.src).then(function (r) { return r.json(); }).then(function (d) {
      data = d;
      svg.setAttribute('viewBox', d.box.join(' '));
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
    legend = "".join(f'<li><i class="b-{c}"></i>{esc(name)}</li>' for c, name in CATS)
    last = frames[-1]
    return (f'{STYLE}<section class="tlapse" id="timelapse" aria-labelledby="timelapse-h">'
            f'<h2 id="timelapse-h">The base over time</h2>'
            f'<p class="small muted">{len(frames)} snapshots, one per 10 game minutes, shifts {shifts[0]} to {shifts[-1]}.</p>'
            f'<div id="tlapse" data-src="{esc(src)}"><div class="tlapse-controls">'
            f'<button class="fx-btn tlapse-play" type="button" disabled>Play</button>'
            f'<input type="range" min="0" max="{len(frames) - 1}" value="{len(frames) - 1}" step="1" list="tlapse-marks" '
            f'aria-label="Snapshot" disabled><datalist id="tlapse-marks">{marks}</datalist>'
            f'<span class="tlapse-label" aria-live="polite">Shift {last["n"]} · game {esc(last["game"])}</span></div>'
            f'<div class="tlapse-stage"><svg role="img" aria-label="Map of the base" viewBox="0 0 1 1"></svg></div>'
            f'<ul class="tlapse-legend">{legend}</ul></div>'
            + SCRIPT.replace("%s", json.dumps([c for c, _ in CATS])) + "</section>")


def data(frames):
    """timelapse.json: the frame box (tiles) and the frames."""
    return json.dumps({"box": frame_box(frames), "frames": frames}, separators=(",", ":"))


def inject(page_html, sec):
    """The run page with the section at the end of its main column."""
    if not sec or "</main>" not in page_html:
        return page_html
    return page_html.replace("\n</main>", "\n" + sec + "\n</main>", 1)
