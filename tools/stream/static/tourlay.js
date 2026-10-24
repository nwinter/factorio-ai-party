// The tour over the camera (d23 batch128 CK3, Nick 17:30: "controls for annotating the screen"): the snapshot's `tour`
// (tools/stream/tourlay.py; tour.py posts one entry a stop ahead) drawn in the on-air camera hole (#cam-main): marks
// at map positions (arrow, circle, box, label) from the stop's cut (the look's `aired` when the look on air has the
// entry's id) between their from_s and to_s, faded in and out. World to screen: the client keeps a 1080-line view
// (1 tile = 32 * zoom px at 1080 lines; mapframes.py), cropped to the hole's shape about its centre, so a tile is
// 32 * zoom * (hole height / 1080) px (a hole wider than 16:9: width / 1920); the camera's centre and zoom are the
// view's, or where its move is now (camerapath.py's math, as cameras.lua plays it). ?tourlay=0 turns it off.
// (CK4) The narration's captions (subs: {t0, t1, text} from subs_at, the narration's moment on the page's audio
// clock) in a band at the hole's bottom (above the bar) or top (subs_pos top: an old clip has its own bubbles low).
// (CK5) An old clip (clip {url, start_s, play, caption, title}): a muted <video> over the whole hole (the library's
// clips are the hole's 1208 x 1032, so 1:1), loaded when the entry arrives (a stop ahead), played from the cut at
// start_s, kept within 0.35 s of the clock, held on its last frame to the stop's end; an ARCHIVE badge with its
// caption ("from shift 48, Oct 20"). Muted: its sound is the old hosts' voices and that hour's game, under the
// narrator; the stream's own game sound goes on as the bed (ducked under the voices as always).
(() => {
  const params = new URLSearchParams(location.search);
  const NS = "http://www.w3.org/2000/svg";
  const FADE = 0.3;

  // ---- camerapath.py: where a camera is t seconds into its move
  const ZOOM_K = 20;
  function ease(f, kind) {
    f = f <= 0 ? 0 : f >= 1 ? 1 : f;
    if (kind === "linear") return f;
    if (kind === "in") return 1 - Math.cos(Math.PI * f / 2);
    if (kind === "out") return Math.sin(Math.PI * f / 2);
    return 0.5 - 0.5 * Math.cos(Math.PI * f);
  }
  const stepLen = (a, b) => Math.hypot(b.x - a.x, b.y - a.y) + ZOOM_K * Math.abs(Math.log(b.zoom / a.zoom));
  function tangent(pts, steps, i, k) {
    const n = pts.length;
    if (i === 0) return steps[0] > 1e-9 ? (pts[1][k] - pts[0][k]) / steps[0] : 0;
    if (i === n - 1) return steps[i - 1] > 1e-9 ? (pts[i][k] - pts[i - 1][k]) / steps[i - 1] : 0;
    const h = steps[i - 1] + steps[i];
    return h > 1e-9 ? (pts[i + 1][k] - pts[i - 1][k]) / h : 0;
  }
  function hermite(a, b, ma, mb, h, u) {
    const u2 = u * u, u3 = u2 * u;
    return (2 * u3 - 3 * u2 + 1) * a + (u3 - 2 * u2 + u) * h * ma + (-2 * u3 + 3 * u2) * b + (u3 - u2) * h * mb;
  }
  function along(pts, g) {
    const n = pts.length;
    if (n === 1 || g <= 0) return [pts[0].x, pts[0].y, pts[0].zoom];
    if (g >= 1) return [pts[n - 1].x, pts[n - 1].y, pts[n - 1].zoom];
    const steps = [];
    let total = 0;
    for (let i = 0; i < n - 1; i++) { steps.push(stepLen(pts[i], pts[i + 1])); total += steps[i]; }
    if (total <= 1e-9) return [pts[n - 1].x, pts[n - 1].y, pts[n - 1].zoom];
    let want = g * total, i = 0;
    while (i < steps.length - 1 && want > steps[i]) { want -= steps[i]; i++; }
    const h = steps[i], u = h > 1e-9 ? want / h : 1, p1 = pts[i], p2 = pts[i + 1];
    const z = Math.exp(Math.log(p1.zoom) + (Math.log(p2.zoom) - Math.log(p1.zoom)) * u);
    return [hermite(p1.x, p2.x, tangent(pts, steps, i, "x"), tangent(pts, steps, i + 1, "x"), h, u),
      hermite(p1.y, p2.y, tangent(pts, steps, i, "y"), tangent(pts, steps, i + 1, "y"), h, u), z];
  }
  function moveAt(move, t) {
    const segs = move.segments;
    if (t <= segs[0].t0) return along(segs[0].pts, 0);
    let last = segs[0];
    for (const s of segs) {
      if (t < s.t1) {
        if (t < s.t0) break;
        const span = s.t1 - s.t0;
        return along(s.pts, ease(span > 0 ? (t - s.t0) / span : 1, s.ease));
      }
      last = s;
    }
    return along(last.pts, 1);
  }

  // ---- which entry, and where things are on screen
  // The entry on now: its start (the cut; the look's aired when the look on air is this one) passed, its until not.
  function active(s, now) {
    let best = null;
    for (const e of (s && s.tour) || []) {
      const lk = s.look;
      const start = lk && lk.id === e.id && lk.aired ? lk.aired : e.cut;
      if (start <= now && now < e.until && (!best || start >= best.start)) best = { e, start };
    }
    return best;
  }
  function viewAt(e, start, now) {
    const v = e.view;
    if (v.move) { const [x, y, zoom] = moveAt(v.move, now - start); return { x, y, zoom }; }
    return { x: v.position.x, y: v.position.y, zoom: v.zoom };
  }
  const pxPerTile = (W, H, zoom) => 32 * zoom * (W / H < 16 / 9 ? H / 1080 : W / 1920);
  const toScreen = (W, H, v) => (p) => {
    const k = pxPerTile(W, H, v.zoom);
    return [W / 2 + (p.x - v.x) * k, H / 2 + (p.y - v.y) * k];
  };
  const COMPASS = { n: [0, -1], ne: [1, -1], e: [1, 0], se: [1, 1], s: [0, 1], sw: [-1, 1], w: [-1, 0], nw: [-1, -1] };
  function markTimes(m, length) {
    const when = (v, d) => (v == null ? d : v === "end" ? length : v < 0 ? length + v : v);
    return [when(m.from_s, 0), when(m.to_s, length)];
  }
  // A mark's shape on screen at t seconds from the cut: {type, opacity, ...px}; null when it does not show now.
  function markGeom(m, t, length, W, H, v) {
    const [t0, t1] = markTimes(m, length);
    if (t < t0 || t >= t1) return null;
    const opacity = Math.max(0, Math.min(1, (t - t0) / FADE, (t1 - t) / FADE));
    const at = toScreen(W, H, v)(m.at), k = pxPerTile(W, H, v.zoom);
    const g = { type: m.type, opacity, at, color: m.color || "#ff9f1c", text: m.text || "" };
    if (m.type === "circle") g.r = Math.max(14, m.radius * k);
    if (m.type === "box") { g.w = Math.max(16, m.w * k); g.h = Math.max(16, m.h * k); }
    if (m.type === "arrow") {
      let dx, dy;
      if (typeof m.from === "object" && m.from) {
        const [fx, fy] = toScreen(W, H, v)(m.from);
        dx = fx - at[0]; dy = fy - at[1];
      } else { [dx, dy] = COMPASS[m.from || "nw"]; }
      const d = Math.hypot(dx, dy) || 1, len = typeof m.from === "object" && m.from ? d : m.length || 110;
      const ux = dx / d, uy = dy / d, gap = 8;
      g.head = [at[0] + ux * gap, at[1] + uy * gap];
      g.tail = [at[0] + ux * (gap + len), at[1] + uy * (gap + len)];
      g.dir = [ux, uy];
    }
    return g;
  }
  // (CK5) where an old clip should be at now: its start_s plus the time since the cut, held at its end
  const clipAt = (clip, start, now) => clip.start_s + Math.max(0, Math.min(now - start, clip.play));
  // (CK4) the caption on now: the one whose [t0, t1) holds now - subs_at, or null
  function captionAt(e, now) {
    if (!e || !e.subs || e.subs_at == null) return null;
    const t = now - e.subs_at;
    return e.subs.find((c) => c.t0 <= t && t < c.t1) || null;
  }
  window.PogTourLay = { moveAt, along, ease, active, viewAt, toScreen, pxPerTile, markGeom, markTimes, captionAt, clipAt };
  if (params.get("tourlay") === "0" || typeof document === "undefined" || !document.createElementNS) return;

  // ---- drawing
  const style = document.createElement("style");
  style.textContent = `
    svg.tour-marks { position: absolute; pointer-events: none; overflow: hidden; z-index: 3; }
    .tour-subs { position: absolute; left: 6%; right: 6%; display: flex; justify-content: center; pointer-events: none;
      z-index: 4; transition: opacity 150ms ease; opacity: 0; }
    .tour-subs.on { opacity: 1; }
    .tour-subs.bottom { bottom: 72px; } .tour-subs.top { top: 64px; }
    .tour-subs span { max-width: 100%; padding: 6px 16px 8px; border-radius: 3px; background: rgba(20, 20, 20, 0.78);
      color: #f4f4f4; text-align: center; font: 600 31px/1.25 "Titillium Web", "Segoe UI", system-ui, sans-serif;
      text-shadow: 0 1px 2px #000; box-shadow: 0 4px 18px rgba(0,0,0,0.5); }
    video.tour-clip { position: absolute; object-fit: cover; z-index: 2; opacity: 0; background: #000;
      transition: opacity 200ms ease; pointer-events: none; }
    video.tour-clip.on { opacity: 1; }
    .tour-clipcap { position: absolute; left: 18px; top: 16px; z-index: 4; display: none; align-items: center; gap: 10px;
      padding: 6px 14px 7px 10px; background: rgba(30, 29, 30, 0.88); border-left: 4px solid #e8c547; border-radius: 0 3px 3px 0;
      color: #f0f0f0; font: 600 22px/1.2 "Titillium Web", "Segoe UI", system-ui, sans-serif; pointer-events: none; }
    .tour-clipcap.on { display: flex; }
    .tour-clipcap b { color: #e8c547; font-size: 15px; letter-spacing: 0.12em; }
    .tour-clipcap i { font-style: normal; color: #b8b8b8; font-size: 18px; }
    svg.tour-marks text { font: 600 22px "Titillium Web", "Segoe UI", system-ui, sans-serif; fill: #f2f2f2;
      paint-order: stroke; stroke: rgba(0,0,0,0.85); stroke-width: 4px; stroke-linejoin: round; }`;
  document.head.appendChild(style);
  let svg = null, host = null;
  function layer() {
    host = document.getElementById("cam-main");
    if (!host) return null;
    if (!svg || svg.parentNode !== host) {
      svg = document.createElementNS(NS, "svg");
      svg.setAttribute("class", "tour-marks");
      host.appendChild(svg);
    }
    // the capture fills the hole's border box: the layer covers it (not just the inside of the border)
    Object.assign(svg.style, { left: -host.clientLeft + "px", top: -host.clientTop + "px",
      width: host.offsetWidth + "px", height: host.offsetHeight + "px" });
    return svg;
  }
  const node = (tag, attrs) => { const n = document.createElementNS(NS, tag); for (const k in attrs) n.setAttribute(k, attrs[k]); return n; };
  // a shape drawn twice: a dark outline, then its colour
  function stroked(tag, attrs, color) {
    const g = node("g", {});
    g.append(node(tag, Object.assign({ fill: "none", stroke: "rgba(0,0,0,0.85)", "stroke-width": 7, "stroke-linejoin": "round", "stroke-linecap": "round" }, attrs)),
      node(tag, Object.assign({ fill: "none", stroke: color, "stroke-width": 3.5, "stroke-linejoin": "round", "stroke-linecap": "round" }, attrs)));
    return g;
  }
  // text kept inside the hole (its width estimated: 0.55 em a character at 22 px), 10 px from the edges
  let HW = 0, HH = 0;
  function label(x, y, text, anchor) {
    const w = text.length * 22 * 0.55, m = 10;
    anchor = anchor || "middle";
    let left = anchor === "start" ? x : anchor === "end" ? x - w : x - w / 2;
    left = Math.max(m, Math.min(HW - m - w, left));
    y = Math.max(m + 11, Math.min(HH - m - 11, y));
    const t = node("text", { x: left, y, "text-anchor": "start", "dominant-baseline": "middle" });
    t.textContent = text;
    return t;
  }
  function drawMark(g) {
    const out = node("g", { opacity: g.opacity.toFixed(3) });
    const [x, y] = g.at;
    if (g.type === "circle") {
      out.append(stroked("circle", { cx: x, cy: y, r: g.r }, g.color));
      if (g.text) out.append(label(x, y + g.r + 20, g.text));
    } else if (g.type === "box") {
      out.append(stroked("rect", { x: x - g.w / 2, y: y - g.h / 2, width: g.w, height: g.h, rx: 3 }, g.color));
      if (g.text) out.append(label(x, y + g.h / 2 + 20, g.text));
    } else if (g.type === "arrow") {
      const [hx, hy] = g.head, [tx, ty] = g.tail, [ux, uy] = g.dir, s = 16;
      const px = -uy, py = ux;  // across the arrow
      const head = `${hx},${hy} ${hx + ux * s + px * s * 0.6},${hy + uy * s + py * s * 0.6} ${hx + ux * s - px * s * 0.6},${hy + uy * s - py * s * 0.6}`;
      out.append(stroked("line", { x1: tx, y1: ty, x2: hx + ux * 6, y2: hy + uy * 6 }, g.color));
      const tri = stroked("polygon", { points: head }, g.color);
      tri.lastChild.setAttribute("fill", g.color);
      out.append(tri);
      if (g.text) out.append(label(tx + ux * 14, ty + uy * 14, g.text, ux > 0.3 ? "start" : ux < -0.3 ? "end" : "middle"));
    } else if (g.type === "label") {
      out.append(stroked("circle", { cx: x, cy: y, r: 5 }, g.color));
      out.lastChild.lastChild.setAttribute("fill", g.color);
      out.append(stroked("line", { x1: x + 4, y1: y - 4, x2: x + 16, y2: y - 22 }, g.color));
      out.append(label(x + 20, y - 30, g.text, "start"));
    }
    return out;
  }
  let subsBox = null, subsKey = "";
  function drawSubs(on, live, now) {
    if (!host) return;
    if (!subsBox || subsBox.parentNode !== host) {
      subsBox = document.createElement("div");
      subsBox.className = "tour-subs bottom";
      subsBox.append(document.createElement("span"));
      host.appendChild(subsBox);
    }
    const c = live ? captionAt(on.e, now) : null;
    const key = c ? on.e.id + "|" + c.t0 + "|" + (on.e.subs_pos || "bottom") : "";
    if (key === subsKey) return;
    subsKey = key;
    if (c) {
      subsBox.className = "tour-subs on " + (on.e.subs_pos === "top" ? "top" : "bottom");
      subsBox.firstChild.textContent = c.text;
    } else subsBox.classList.remove("on");
  }
  const vids = new Map();  // entry id -> its <video>
  let badge = null, badgeKey = "";
  function drawClips(s, on, now) {
    if (!host) return;
    const want = new Set();
    for (const e of (s && s.tour) || []) {
      if (!e.clip || now >= e.until) continue;
      want.add(e.id);
      if (vids.has(e.id)) continue;
      const v = document.createElement("video");
      v.className = "tour-clip";
      v.muted = true; v.defaultMuted = true; v.playsInline = true; v.preload = "auto";
      v.addEventListener("loadedmetadata", () => { if (v.paused) v.currentTime = e.clip.start_s; });
      v.src = e.clip.url;
      Object.assign(v.style, { left: -host.clientLeft + "px", top: -host.clientTop + "px",
        width: host.offsetWidth + "px", height: host.offsetHeight + "px" });
      host.appendChild(v);
      vids.set(e.id, v);
    }
    for (const [id, v] of vids) if (!want.has(id)) { v.pause(); v.removeAttribute("src"); v.load(); v.remove(); vids.delete(id); }
    const cur = on && on.e.clip ? vids.get(on.e.id) : null;
    for (const v of vids.values()) {
      v.classList.toggle("on", v === cur);
      if (v !== cur && !v.paused) v.pause();
    }
    if (cur) {
      const c = on.e.clip, at = clipAt(c, on.start, now), playing = now - on.start < c.play;
      if (cur.readyState >= 1 && Math.abs(cur.currentTime - at) > 0.35) cur.currentTime = at;
      if (playing && cur.paused) cur.play().catch(() => {});
      if (!playing && !cur.paused) cur.pause();  // its last frame stays to the stop's end
    }
    if (!badge || badge.parentNode !== host) {
      badge = document.createElement("div");
      badge.className = "tour-clipcap";
      host.appendChild(badge);
    }
    const key = cur ? on.e.id : "";
    if (key !== badgeKey) {
      badgeKey = key;
      badge.replaceChildren();
      if (cur) {
        const b = document.createElement("b"); b.textContent = "ARCHIVE";
        const t = document.createElement("span"); t.textContent = on.e.clip.caption || "an earlier moment";
        badge.append(b, t);
        if (on.e.clip.title) { const i = document.createElement("i"); i.textContent = on.e.clip.title; badge.append(i); }
      }
      badge.classList.toggle("on", !!cur);
    }
  }
  // the stop's length (for "end" and negative times): from its cut to its until less the look's spare
  const lengthOf = (e) => (e.length != null ? e.length : e.until - e.cut);
  let shown = "";
  function frame() {
    const s = window.pogState, now = Date.now() / 1000;
    const on = active(s, now);
    const cam = s && s.cameras && s.cameras.main;
    // on air: the program shows its look (an old clip's stop shows the clip whatever the camera does)
    const live = on && (on.e.clip || !cam || !cam.look || !cam.look.id || cam.look.id === on.e.id);
    const L = layer();
    if (L) {
      if (!live || !(on.e.marks || []).length) {
        if (shown) { L.replaceChildren(); shown = ""; }
      } else {
        const W = host.offsetWidth, H = host.offsetHeight, v = viewAt(on.e, on.start, now), t = now - on.start;
        HW = W; HH = H;
        const geoms = on.e.marks.map((m) => markGeom(m, t, lengthOf(on.e), W, H, v)).filter(Boolean);
        L.replaceChildren(...geoms.map(drawMark));
        shown = on.e.id;
      }
    }
    drawSubs(on, live, now);
    drawClips(s, live ? on : null, now);
    if (window.PogTourLay.onFrame) window.PogTourLay.onFrame(s, now, on);
    // animate while an entry is on (moves and fades); otherwise look again four times a second (clips load ahead)
    if (on) requestAnimationFrame(frame); else setTimeout(frame, 250);
  }
  frame();
})();
