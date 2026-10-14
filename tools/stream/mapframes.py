#!/usr/bin/env python3
"""Terrain for the site's map: a frame of the director's base-map shot (onecam map_hold: a camera client in Factorio's
map view), georeferenced so a pixel maps to tiles, kept per area in runs/RUN/mapframes/.

    python3 tools/stream/mapframes.py runs/shift06 [--url http://127.0.0.1:8788/state.json] [--obs 127.0.0.1:4455]
    python3 tools/stream/mapframes.py runs/shift06 --frame shot.jpg --state state.json   # one saved frame, offline

Runs beside the stream service (system python3 with numpy and Pillow; serve.py stays stdlib only). It polls the
service's state.json; while the base map is on air (onair.map "on air") it takes one screenshot of that camera's OBS
source (obs-websocket GetSourceScreenshot, read-only: no scene or recording changes) and the basemap of that moment.

Georeference. The map view shows 32 * zoom * (client height / 1080) pixels per tile (the client keeps a 1080-line
view at any window size: the 2880x1620 clients show 1.44 px a tile at zoom 0.03). The view's centre is not taken from
the director's command: on 2026-10-13 13:07 the director asked for (-92,84) and the client stayed at (-12,-8), where
it had followed Gemini a moment before (cameras.lua's remote controller keeps the old view). So each frame is placed
by registering it on the basemap: the building grid rendered at that scale against the frame's building-coloured
pixels (FFT cross-correlation), and kept only when the match is clear (F1 of the two masks, MIN_SCORE). Checked on
the 13:07 frame: 1.44 px a tile, centre (-12,-8), F1 0.80.

Each kept frame: AREA.webp (the charted part; the uncharted grey and the client's "Press Tab" line transparent, at
most MAX_W pixels wide) and AREA.json {tick, t, box [x, y, w, h] in tiles, px [w, h], zoom, score, surface}. AREA is
the frame's centre in 256-tile blocks; the newest frame of an area replaces the older one, at most one per area every
EVERY_TICKS. site/terrain.py publishes them.
"""
import argparse, base64, io, json, math, os, sys, time, urllib.request

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True

SOURCES = {"main": "stream cam1", "cam2": "stream cam2", "cam3": "stream cam3"}  # tools/obs.py stream_scene
EVERY_TICKS = 36000      # at most one frame per area every 10 game minutes
SETTLE_S = 3.0           # after the map goes on air, before the screenshot (the client redraws the chart)
MIN_SCORE = 0.2          # registration F1 below this: the frame is not placed. F1 runs low for a right match (the
                         # grid's 8-tile cells are filled where the map draws thin belts and pipes): 13:07 0.39,
                         # 16:29 0.37, 16:42 0.30 (skipped at 0.3 with its peak 37 sd); the peak is the main guard
MIN_PEAK = 8.0           # the correlation peak this many standard deviations above the mean
MAX_W = 2048             # stored width at most (px)
AREA_TILES = 256
UNCHARTED = (47, 47, 47)  # the map view's uncharted chunks (sampled: 46..49 grey)


def px_per_tile(zoom, height):
    return 32.0 * zoom * height / 1080.0


def building_pixels(rgb):
    """Map-colour building pixels: machines (saturated cyan), belts and alerts (yellow), rails and walls (pale)."""
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    sat = rgb.max(-1) - rgb.min(-1)
    cyan = (b > 150) & (g > 110) & (r < 120) & (sat > 70)
    yellow = (r > 200) & (g > 170) & (b < 110)
    pale = (r > 170) & (g > 160) & (b > 100) & (sat < 90) & (r.astype(int) + g + b > 520)
    return cyan | yellow | pale


def grid_mask(basemap, ppt):
    """The basemap's building cells (coarse grid, and the fine core where it has one) at ppt pixels a tile:
    (mask, x0, y0) with the mask's top-left at tile (x0, y0)."""
    c, x0, y0 = basemap["cell"], basemap["x0"], basemap["y0"]
    rows = basemap["rows"]
    w = max(len(r) for r in rows) * c
    h = len(rows) * c
    mask = np.zeros((max(1, int(math.ceil(h * ppt)) + 1), max(1, int(math.ceil(w * ppt)) + 1)), bool)

    def fill(g):
        gc = g["cell"]
        for j, row in enumerate(g["rows"]):
            for i, ch in enumerate(str(row)):
                if ch != ".":
                    ax, ay = (g["x0"] + i * gc - x0) * ppt, (g["y0"] + j * gc - y0) * ppt
                    mask[int(ay):max(int(ay) + 1, int(ay + gc * ppt)), int(ax):max(int(ax) + 1, int(ax + gc * ppt))] = True
    core = basemap.get("core")
    if isinstance(core, dict) and core.get("rows") and core.get("cell") and core["cell"] * ppt >= 1:
        fill(core)
        # the coarse grid outside the core
        cx0, cy0 = core["x0"], core["y0"]
        cx1, cy1 = cx0 + core["w"] * core["cell"], cy0 + core["h"] * core["cell"]
        coarse = dict(basemap, rows=["".join("." if cx0 <= x0 + i * c < cx1 and cy0 <= y0 + j * c < cy1 else ch
                                             for i, ch in enumerate(str(row))) for j, row in enumerate(rows)])
        fill(coarse)
    else:
        fill(basemap)
    return mask, x0, y0


def register(rgb, basemap, ppt):
    """Where the basemap sits in the frame: (left, top, score) with tile (left, top) at pixel (0, 0); None when the
    frame has no building pixels."""
    bld = building_pixels(rgb)
    if bld.sum() < 50:
        return None
    tmpl, x0, y0 = grid_mask(basemap, ppt)
    H, W = bld.shape
    th, tw = tmpl.shape
    # cross-correlation of the frame's building pixels with the zero-mean template (empty template areas count
    # against a placement), over every offset where the template's top-left lands within the padded frame
    ph, pw = H + th, W + tw
    fi = np.fft.rfft2(bld.astype(np.float32), s=(ph, pw))
    t = tmpl.astype(np.float32)
    t -= t.mean()
    ft = np.fft.rfft2(t, s=(ph, pw))
    corr = np.fft.irfft2(fi * np.conj(ft), s=(ph, pw))
    peak = float((corr.max() - corr.mean()) / max(1e-9, corr.std()))
    dy, dx = np.unravel_index(int(np.argmax(corr)), corr.shape)
    dy = dy - ph if dy > H else dy  # negative offsets wrap around
    dx = dx - pw if dx > W else dx
    # F1 of the two masks at that offset
    ys0, xs0 = max(0, dy), max(0, dx)
    ys1, xs1 = min(H, dy + th), min(W, dx + tw)
    if ys1 <= ys0 or xs1 <= xs0:
        return None
    sub_t = tmpl[ys0 - dy:ys1 - dy, xs0 - dx:xs1 - dx]
    sub_i = bld[ys0:ys1, xs0:xs1]
    both = (sub_t & sub_i).sum()
    precision = both / max(1, tmpl.sum())
    recall = both / max(1, bld.sum())
    score = 2 * precision * recall / max(1e-9, precision + recall)
    return x0 - dx / ppt, y0 - dy / ppt, float(score), peak


def place(rgb, basemap, zoom):
    """The frame's tile box and score, trying the zoom sent and its neighbours (the director rounds to 0.01)."""
    H = rgb.shape[0]
    best = None
    for z in (zoom, zoom - 0.005, zoom + 0.005):
        if z <= 0:
            continue
        ppt = px_per_tile(z, H)
        r = register(rgb, basemap, ppt)
        if r and (best is None or r[2] > best[2]):
            best = (r[0], r[1], r[2], r[3], z, ppt)
    return best


def cutout(rgb, maxw=MAX_W):
    """RGBA of the charted part: uncharted grey and the client's bottom-centre hint line transparent; cropped to the
    charted pixels and scaled to at most maxw wide. Returns (image, crop box (x0, y0, x1, y1) in frame pixels)."""
    H, W = rgb.shape[:2]
    d = np.abs(rgb.astype(int) - np.array(UNCHARTED)).max(-1)
    alpha = np.where(d <= 14, 0, 255).astype(np.uint8)  # (JPEG ringing on the flat grey next to terrain)
    alpha[int(H * 0.965):, int(W * 0.40):int(W * 0.60)] = 0  # "Press Tab to skip cutscene"
    ys, xs = np.nonzero(alpha)
    if not len(xs):
        return None, None
    box = (int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1)
    im = Image.fromarray(np.dstack([rgb, alpha])[box[1]:box[3], box[0]:box[2]], "RGBA")
    if im.width > maxw:
        im = im.resize((maxw, round(im.height * maxw / im.width)), Image.LANCZOS)
    return im, box


def area_key(cx, cy):
    return f"{math.floor(cx / AREA_TILES)}_{math.floor(cy / AREA_TILES)}"


def frame_record(jpg, basemap, zoom, tick, surface="nauvis", now=None):
    """(webp bytes, meta) for one screenshot, or (None, reason)."""
    rgb = np.asarray(Image.open(io.BytesIO(jpg)).convert("RGB"))
    H, W = rgb.shape[:2]
    placed = place(rgb, basemap, zoom)
    if not placed:
        return None, "no buildings to match"
    left, top, score, peak, z, ppt = placed
    if score < MIN_SCORE or peak < MIN_PEAK:
        return None, f"no clear match (F1 {score:.2f}, peak {peak:.1f} sd)"
    im, box = cutout(rgb)
    if im is None:
        return None, "nothing charted"
    buf = io.BytesIO()
    im.save(buf, "WEBP", quality=80, method=4)
    tiles = [round(float(left + box[0] / ppt), 1), round(float(top + box[1] / ppt), 1), round((box[2] - box[0]) / ppt, 1),
             round((box[3] - box[1]) / ppt, 1)]
    centre = (round(float(left + W / 2 / ppt), 1), round(float(top + H / 2 / ppt), 1))
    meta = {"tick": tick, "t": round(now or time.time()), "surface": surface, "box": tiles, "px": [im.width, im.height],
            "zoom": round(z, 4), "px_per_tile": round(ppt, 4), "centre": list(centre), "score": round(score, 3),
            "peak": round(peak, 1)}
    return buf.getvalue(), meta


def save(run_dir, webp, meta, every=EVERY_TICKS):
    """Write AREA.webp and AREA.json in run_dir/mapframes (the newest per area); False when the area has a frame
    newer than `every` ticks."""
    d = os.path.join(run_dir, "mapframes")
    os.makedirs(d, exist_ok=True)
    key = area_key(*meta["centre"])
    jp = os.path.join(d, key + ".json")
    try:
        old = json.load(open(jp))
        if meta["tick"] is not None and old.get("tick") is not None and 0 <= meta["tick"] - old["tick"] < every:
            return False
    except (OSError, ValueError):
        pass
    for name, data, mode in ((key + ".webp", webp, "wb"), (key + ".json", json.dumps(dict(meta, area=key)), "w")):
        tmp = os.path.join(d, name + ".tmp")
        with open(tmp, mode) as f:
            f.write(data)
        os.replace(tmp, os.path.join(d, name))
    return True


def fetch(url):
    with urllib.request.urlopen(url, timeout=5) as r:
        s = json.load(r)
    return s.get("state", s)


def map_zoom(state):
    """The zoom the director sent for its map shot: the state's onair.map_view when the service has it, else
    mapcam.map_shot on the same basemap (what the director does), rounded as director.apply rounds it."""
    view = (state.get("onair") or {}).get("map_view") or {}
    if isinstance(view.get("zoom"), (int, float)):
        return float(view["zoom"])
    import cuts, mapcam
    frac = cuts.view_frac(json.load(open(cuts.LAYOUT)))
    shot = mapcam.map_shot(state.get("basemap"), hole=(1208, 1032), frac=frac)
    return round(min(2.0, shot["zoom"]), 2) if shot else None


def poll(run_dir, url, obs, log=lambda s: print(s, flush=True)):
    log(f"[mapframes] {time.strftime('%H:%M:%S')} start: {url}, base-map shots -> {os.path.join(run_dir, 'mapframes')}")
    done_since = None
    while True:
        try:
            s = fetch(url)
            on = s.get("onair") or {}
            if on.get("map") == "on air" and on.get("since") != done_since:
                done_since = on.get("since")
                time.sleep(SETTLE_S)
                s = fetch(url)
                on = s.get("onair") or {}
                if on.get("map") == "on air":
                    zoom = map_zoom(s)
                    src = SOURCES.get(on.get("client") or "main", "stream cam1")
                    r = obs.call("GetSourceScreenshot", {"sourceName": src, "imageFormat": "jpg", "imageCompressionQuality": 90})
                    jpg = base64.b64decode(r["imageData"].split(",", 1)[1])
                    webp, meta = frame_record(jpg, s.get("basemap") or {}, zoom, s.get("tick"))
                    if webp is None:
                        log(f"[mapframes] {time.strftime('%H:%M:%S')} skipped: {meta}")
                    else:
                        kept = save(run_dir, webp, meta)
                        log(f"[mapframes] {time.strftime('%H:%M:%S')} {'saved' if kept else 'not newer'}: {src} box {meta['box']} "
                            f"F1 {meta['score']} ({len(webp) // 1024} KB)")
        except Exception as e:  # keep polling: OBS or the service may restart
            log(f"[mapframes] {time.strftime('%H:%M:%S')} error: {type(e).__name__}: {e}")
        time.sleep(2.0)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir")
    ap.add_argument("--url", default="http://127.0.0.1:8788/state.json")
    ap.add_argument("--obs", default="127.0.0.1:4455")
    ap.add_argument("--frame", help="a saved screenshot (jpg/png) to place, with --state")
    ap.add_argument("--state", help="the state.json saved with --frame")
    a = ap.parse_args()
    if a.frame:
        s = json.load(open(a.state))
        s = s.get("state", s)
        webp, meta = frame_record(open(a.frame, "rb").read(), s["basemap"], map_zoom(s), s.get("tick"))
        if webp is None:
            sys.exit(f"not placed: {meta}")
        print(json.dumps(meta), save(a.run_dir, webp, meta, every=0))
        return
    from obsws import OBS
    host, _, port = a.obs.partition(":")
    poll(a.run_dir, a.url, OBS(host, int(port or 4455), timeout=20))


if __name__ == "__main__":
    main()
