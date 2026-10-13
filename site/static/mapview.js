// The site's map viewer: the live map (/ and /live/, static/live.js) and the run page's time-lapse (site/timelapse.py).
// One canvas, redrawn at most once a frame: pan (drag), zoom (wheel, pinch, + and −), Reset, Full screen; layers to
// toggle (terrain, ore, buildings, turret range, nests, agents, attention, fights and alerts); a click or tap on an
// agent centres the map on it and follows it; hover or tap shows what a mark is. scene() works out every mark in
// canvas pixels without touching the DOM, so site/test_live.py checks it under node; paint() draws a scene.
//
// Data (set()): base, core, ore (grids {cell, x0, y0, w, h, rows}: one letter a cell, harness BASEMAP_LUA), nests
// [[x, y, 's'|'w']], turrets [[x, y, range]], terrain [{src, x0, y0, x1, y1, tick}] (georeferenced map-camera
// frames: the image's edges in tiles), tick (draw terrain frames up to it), agents [{name, display_name, color,
// position, alive, action, location, attention, surface, where, on_platform, travel}], fights, pins, cams, box
// [x0, y0, w, h] (a fixed frame instead of the framing on the base's core). The map is Nauvis: an agent on another
// planet, aboard a platform or in a cargo pod is listed in the map's corner ("Sol · Vulcanus"), never drawn.
(function (root) {
  'use strict';
  // the live map's colours (style.css .b-X and .o-X: the legends use those)
  var BASE = [['D', '#c8553d', 'Defence'], ['R', '#a983f0', 'Labs'], ['O', '#3fa8a3', 'Oil and chemistry'], ['A', '#5c8fd6', 'Assembly'],
    ['S', '#e08a3c', 'Smelting'], ['M', '#a6875a', 'Mining'], ['E', '#f2d34b', 'Power'], ['L', '#b9b9b9', 'Logistics'],
    ['K', '#8f8f8f', 'Storage'], ['I', '#9fcf6a', 'Inserters'], ['B', '#8a7d45', 'Belts'], ['T', '#6e6a8e', 'Rails'], ['P', '#4a6a8a', 'Pipes']];
  var ORE = [['i', '#7f9db4', 'Iron ore'], ['c', '#d0703a', 'Copper ore'], ['k', '#5a5a5a', 'Coal'], ['s', '#c2ab7a', 'Stone'],
    ['o', '#b04fb5', 'Crude oil'], ['u', '#6fe05a', 'Uranium ore'], ['x', '#9a9a9a', 'Other resource']];
  var GROUND = [['w', '#20384a', 'Water'], ['c', '#5b4a36', 'Cliffs'], ['u', '#0d0f0c', 'Uncharted']];
  var LINE_CATS = { P: 1, B: 1, I: 1, T: 1 };
  var LAYERS = [['terrain', 'Terrain'], ['ore', 'Ore'], ['buildings', 'Buildings'], ['coverage', 'Turret range'], ['nests', 'Nests'],
    ['agents', 'Agents'], ['attention', 'Attention'], ['alerts', 'Fights']];
  var DEFAULT_ON = { terrain: true, ore: true, buildings: true, coverage: false, nests: true, agents: true, attention: true, alerts: true };
  var C = { bg: '#1b1f1a', grid: '#2b302a', text: '#e8e6e1', orange: '#ff9b2e', red: '#e04e3a', nest: '#ff3b30', worm: '#ff8a7a',
    range: 'rgba(120, 200, 255, ', inset: 'rgba(16, 18, 15, .88)' };
  var CAM_SHORT = { main: 'MAIN', cam2: 'CAM 2', cam3: 'CAM 3' };

  function validGrid(g) {
    return !!(g && Array.isArray(g.rows) && g.rows.length && isFinite(g.x0) && isFinite(g.y0) && g.cell > 0);
  }
  function ok(p) { return !!(p && isFinite(p.x) && isFinite(p.y)); }
  // Not on Nauvis: another planet, aboard a platform, or riding a cargo pod (travel: ascending, aboard, descending).
  function elsewhere(a) { return !!(a.on_platform || a.travel || (a.surface && a.surface !== 'nauvis')); }
  function whereText(a) {
    if (a.travel) return a.location || a.where || 'cargo pod';
    if (a.on_platform) return (a.where || 'a platform') + ' (platform)';
    var s = a.where || String(a.surface || '').replace(/[-_]/g, ' ');
    return s.charAt(0).toUpperCase() + s.slice(1);
  }
  // A grid's runs of equal letters: {letter: [[col, row, n], ...]}, cached on the grid's content.
  var runCache = {};
  function runs(g) {
    var key = g.cell + ':' + g.x0 + ':' + g.y0 + ':' + g.rows.length + ':' + g.rows.join('|').length + ':' + (g.tick || '') + ':' + g.rows[0] + g.rows[g.rows.length >> 1];
    if (runCache[key]) return runCache[key];
    var out = {};
    g.rows.forEach(function (row, r) {
      row = String(row);
      for (var c = 0; c < row.length;) {
        var ch = row.charAt(c), n = 1;
        while (c + n < row.length && row.charAt(c + n) === ch) n++;
        if (ch !== '.' && ch !== ' ') (out[ch] || (out[ch] = [])).push([c, r, n]);
        c += n;
      }
    });
    var keys = Object.keys(runCache);
    if (keys.length > 12) delete runCache[keys[0]];
    runCache[key] = out;
    return out;
  }

  // Outposts: building cells of the coarse grid outside the core box (pipes, belts, inserters and rails left out),
  // grouped in 48-tile blocks, each drawn at the frame's edge when out of view.
  function outposts(g, box) {
    var groups = {}, out = [];
    g.rows.forEach(function (row, r) {
      row = String(row);
      for (var c = 0; c < row.length; c++) {
        var ch = row.charAt(c);
        if (ch === '.' || ch === ' ' || LINE_CATS[ch]) continue;
        var p = { x: g.x0 + (c + 0.5) * g.cell, y: g.y0 + (r + 0.5) * g.cell };
        if (p.x >= box.x0 - 16 && p.x <= box.x1 + 16 && p.y >= box.y0 - 16 && p.y <= box.y1 + 16) continue;
        var key = Math.floor(p.x / 48) + ',' + Math.floor(p.y / 48), o = groups[key] || (groups[key] = { x: 0, y: 0, n: 0 });
        o.x += p.x; o.y += p.y; o.n += 1;
      }
    });
    Object.keys(groups).forEach(function (key) { var o = groups[key]; out.push({ x: o.x / o.n, y: o.y / o.n, n: o.n }); });
    return out;
  }
  // The base's core from the coarse grid alone (a stream service without basemap.core): the box around the biggest
  // connected group of dense 32-tile blocks (pipes, belts, inserters and rails left out), plus 8 tiles.
  function baseCore(g) {
    var cells = [], cell = g.cell;
    g.rows.forEach(function (row, r) {
      row = String(row);
      for (var c = 0; c < row.length; c++) {
        var ch = row.charAt(c);
        if (ch !== '.' && ch !== ' ' && !LINE_CATS[ch]) cells.push({ x: g.x0 + (c + 0.5) * cell, y: g.y0 + (r + 0.5) * cell });
      }
    });
    if (cells.length < 12) return { x0: g.x0, y0: g.y0, x1: g.x0 + (g.w || 0) * cell, y1: g.y0 + g.rows.length * cell, out: [] };
    var blocks = {}, top = 0;
    cells.forEach(function (p) {
      var key = Math.floor(p.x / 32) + ',' + Math.floor(p.y / 32);
      blocks[key] = (blocks[key] || 0) + 1;
      top = Math.max(top, blocks[key]);
    });
    var dense = {};
    Object.keys(blocks).forEach(function (key) { if (blocks[key] >= Math.max(2, top / 5)) dense[key] = blocks[key]; });
    var seen = {}, best = null;
    Object.keys(dense).forEach(function (start) {
      if (seen[start]) return;
      var group = [], stack = [start], total = 0;
      seen[start] = true;
      while (stack.length) {
        var key = stack.pop(), bx = +key.split(',')[0], by = +key.split(',')[1];
        group.push([bx, by]); total += dense[key];
        for (var dx = -1; dx <= 1; dx++) for (var dy = -1; dy <= 1; dy++) {
          var nk = (bx + dx) + ',' + (by + dy);
          if (dense[nk] && !seen[nk]) { seen[nk] = true; stack.push(nk); }
        }
      }
      if (!best || total > best.total) best = { total: total, group: group };
    });
    var box = { x0: Infinity, y0: Infinity, x1: -Infinity, y1: -Infinity };
    best.group.forEach(function (b) {
      box.x0 = Math.min(box.x0, b[0] * 32 - 8); box.y0 = Math.min(box.y0, b[1] * 32 - 8);
      box.x1 = Math.max(box.x1, b[0] * 32 + 40); box.y1 = Math.max(box.y1, b[1] * 32 + 40);
    });
    box.out = outposts(g, box);
    return box;
  }

  // What the data holds, normalised: grids, the core box with its outposts, and the automatic view {cx, cy, span}:
  // the base's core and the agents, alerts and fights near it (far ones are pinned to the edge), or data.box.
  function prepare(data) {
    data = data || {};
    var base = validGrid(data.base) && data.base.rows.length ? data.base : null;
    var core = validGrid(data.core) && data.core.w > 0 ? data.core : null;
    var d = { base: base, fine: core, ore: validGrid(data.ore) ? data.ore : null, ground: validGrid(data.ground) ? data.ground : null };
    d.away = (data.agents || []).filter(function (a) { return a && elsewhere(a); });
    d.agents = (data.agents || []).filter(function (a) { return a && ok(a.position) && !elsewhere(a); });
    d.fights = (data.fights || []).filter(function (f) { return f && ok(f.position); });
    d.pins = (data.pins || []).filter(function (p) { return p && ok(p.position); });
    d.nests = (Array.isArray(data.nests) ? data.nests : []).filter(function (n) { return n && isFinite(n[0]) && isFinite(n[1]); });
    d.turrets = (Array.isArray(data.turrets) ? data.turrets : []).filter(function (t) { return t && isFinite(t[0]) && isFinite(t[1]) && t[2] > 0 && t[2] < 80; });
    d.terrain = (Array.isArray(data.terrain) ? data.terrain : []).filter(function (t) {
      return t && typeof t.src === 'string' && /^(\/[\w\/.-]+|https:\/\/[^"'<>\s]+)$/.test(t.src) &&
        [t.x0, t.y0, t.x1, t.y1].every(isFinite) && t.x1 > t.x0 && t.y1 > t.y0 && (data.tick == null || !(t.tick > data.tick));
    }).sort(function (a, b) { return (a.tick || 0) - (b.tick || 0); });
    d.cams = data.cams || {};
    d.box = null;
    if (core) {
      d.box = { x0: core.x0, y0: core.y0, x1: core.x0 + core.w * core.cell, y1: core.y0 + (core.h || core.rows.length) * core.cell };
      d.box.out = base ? outposts(base, d.box) : [];
    } else if (base) d.box = baseCore(base);
    var bcx = 0, bcy = 0, reach = Infinity;
    if (d.box) { bcx = (d.box.x0 + d.box.x1) / 2; bcy = (d.box.y0 + d.box.y1) / 2; reach = Math.max(96, d.box.x1 - d.box.x0, d.box.y1 - d.box.y0); }
    d.dist = function (p) { return Math.round(Math.max(Math.abs(p.x - bcx), Math.abs(p.y - bcy))); };
    var near = function (p) { return !d.box || (Math.abs(p.x - bcx) <= reach && Math.abs(p.y - bcy) <= reach); };
    if (Array.isArray(data.box) && data.box.length === 4 && data.box.every(isFinite)) {
      var b = data.box;
      d.auto = { cx: b[0] + b[2] / 2, cy: b[1] + b[3] / 2, span: Math.max(b[2], b[3]) };
    } else {
      var xs = [], ys = [];
      d.agents.map(function (a) { return a.position; }).concat(d.pins.map(function (p) { return p.position; }), d.fights.map(function (f) { return f.position; }))
        .filter(near).forEach(function (p) { xs.push(p.x); ys.push(p.y); });
      if (d.box) { xs.push(d.box.x0, d.box.x1); ys.push(d.box.y0, d.box.y1); }
      if (!xs.length) return d;
      var minX = Math.min.apply(0, xs), maxX = Math.max.apply(0, xs), minY = Math.min.apply(0, ys), maxY = Math.max.apply(0, ys);
      d.auto = { cx: (minX + maxX) / 2, cy: (minY + maxY) / 2, span: Math.max(48, maxX - minX, maxY - minY) * 1.1 };
    }
    return d;
  }

  function textWidth(s, perChar) { return String(s).length * perChar + 2; }
  // A label where it overlaps no other label, dot or tag: right, left, below, above; none free: no label.
  function placeLabel(x, y, w, taken, W, H, hasTag) {
    var tries = [{ x: 9, y: 4, anchor: 'start', b: [x + 8, y - 6, x + 8 + w, y + 6] },
      { x: -9, y: 4, anchor: 'end', b: [x - 8 - w, y - 6, x - 8, y + 6] },
      { x: 0, y: 19, anchor: 'center', b: [x - w / 2, y + 9, x + w / 2, y + 21] }];
    if (!hasTag) tries.push({ x: 0, y: -10, anchor: 'center', b: [x - w / 2, y - 21, x + w / 2, y - 9] });
    for (var i = 0; i < tries.length; i++) {
      var b = tries[i].b;
      if (b[0] < 0 || b[2] > W || b[1] < 0 || b[3] > H) continue;
      var hit = taken.some(function (t) { return b[0] < t[2] && b[2] > t[0] && b[1] < t[3] && b[3] > t[1]; });
      if (!hit) { taken.push(b); return tries[i]; }
    }
    return null;
  }
  function ago(sec) {
    sec = Math.max(0, Math.round(sec));
    return sec < 60 ? sec + ' s ago' : sec < 3600 ? Math.round(sec / 60) + ' min ago' : Math.round(sec / 3600) + ' h ago';
  }
  function cap(s) { s = String(s || '').replace(/[-_]/g, ' '); return s.charAt(0).toUpperCase() + s.slice(1); }

  // Every mark for view {cx, cy, span} (span: tiles across the shorter side) on a W x H canvas, with layers `on`.
  function scene(d, view, W, H, on) {
    on = on || DEFAULT_ON;
    var v = view || d.auto || { cx: 0, cy: 0, span: 96 };
    var k = Math.min(W, H) / v.span, hw = W / 2 / k, hh = H / 2 / k;
    var sc = { view: v, k: k, W: W, H: H, span: v.span, hits: [], far: {} };
    var px = function (x) { return W / 2 + (x - v.cx) * k; }, py = function (y) { return H / 2 + (y - v.cy) * k; };
    sc.px = px; sc.py = py;
    var inView = function (p) { return Math.abs(p.x - v.cx) <= hw - 4 / k && Math.abs(p.y - v.cy) <= hh - 4 / k; };
    var edge = function (p) {
      var dx = p.x - v.cx, dy = p.y - v.cy, t = Math.min((hw - 14 / k) / Math.max(Math.abs(dx), 1e-6), (hh - 14 / k) / Math.max(Math.abs(dy), 1e-6));
      return { x: v.cx + dx * t, y: v.cy + dy * t };
    };
    var spot = function (p) { return inView(p) ? p : edge(p); };
    var step = Math.max(v.span, 1) > 400 ? 128 : v.span > 160 ? 64 : v.span > 80 ? 32 : 16;
    sc.grid = { step: step, xs: [], ys: [] };
    for (var gx = Math.ceil((v.cx - hw) / step) * step; gx < v.cx + hw; gx += step) sc.grid.xs.push(px(gx));
    for (var gy = Math.ceil((v.cy - hh) / step) * step; gy < v.cy + hh; gy += step) sc.grid.ys.push(py(gy));
    var place = function (g) { return { x: px(g.x0), y: py(g.y0), s: g.cell * k, runs: runs(g) }; };
    sc.terrain = on.terrain ? d.terrain.filter(function (t) {
      return t.x1 > v.cx - hw && t.x0 < v.cx + hw && t.y1 > v.cy - hh && t.y0 < v.cy + hh;
    }).map(function (t) { return { src: t.src, x: px(t.x0), y: py(t.y0), w: (t.x1 - t.x0) * k, h: (t.y1 - t.y0) * k, tick: t.tick }; }) : [];
    sc.ground = on.terrain && d.ground ? place(d.ground) : null;
    sc.ore = on.ore && d.ore ? place(d.ore) : null;
    if (on.buildings && d.base) {
      sc.base = place(d.base);
      if (d.fine) { sc.core = place(d.fine); sc.clip = { x0: px(d.box.x0), y0: py(d.box.y0), x1: px(d.box.x1), y1: py(d.box.y1) }; }
    }
    // turret range: the union of every turret's reach (artillery left out), a fill and its outline
    sc.coverage = on.coverage ? d.turrets.filter(function (t) {
      return Math.abs(t[0] - v.cx) <= hw + t[2] && Math.abs(t[1] - v.cy) <= hh + t[2];
    }).map(function (t) { return { x: px(t[0]), y: py(t[1]), r: t[2] * k }; }) : [];
    sc.nests = on.nests ? d.nests.filter(function (n) { return inView({ x: n[0], y: n[1] }); }).map(function (n) {
      var m = { x: px(n[0]), y: py(n[1]), kind: n[2] === 's' ? 'spawner' : 'worm' };
      sc.hits.push({ x: m.x, y: m.y, r: 6, text: n[2] === 's' ? 'Enemy spawner' : 'Worm' });
      return m;
    }) : [];
    var taken = [];
    // the whole base in a corner when the view shows only part of it, the view's box on it
    sc.inset = null;
    if (d.base && on.buildings) {
      var ew = (d.base.w || 0) * d.base.cell, eh = d.base.rows.length * d.base.cell;
      if (Math.max(ew, eh) > v.span * 1.4) {
        var I = Math.min(104, Math.min(W, H) * 0.3), ki = I / Math.max(ew, eh), ix = W - I - 6, iy = H - I - 6;
        var ip = function (x, y) { return [ix + (x - d.base.x0) * ki, iy + (y - d.base.y0) * ki]; };
        var a0 = ip(v.cx - hw, v.cy - hh), a1 = ip(v.cx + hw, v.cy + hh);
        sc.inset = { x: ix, y: iy, size: I, s: d.base.cell * ki, runs: runs(d.base),
          view: [Math.max(ix, a0[0]), Math.max(iy, a0[1]), Math.min(ix + I, a1[0]), Math.min(iy + I, a1[1])] };
        taken.push([ix - 3, iy - 3, W, H]);
      }
    }
    sc.fights = on.alerts ? d.fights.map(function (f) {
      var at = spot(f.position), pinned = at !== f.position;
      var m = { x: px(at.x), y: py(at.y), r: pinned ? 6 : Math.max(6, (f.extent || 16) / 2 * k), now: f.age_s != null && f.age_s < 25,
        loss: f.kind === 'loss' || !!f.losses };
      sc.hits.push({ x: m.x, y: m.y, r: Math.max(8, m.r), text: f.text + (f.age_s != null ? ' · ' + ago(f.age_s) : '') +
        (f.losses ? ' · ' + f.losses + ' loss' + (f.losses > 1 ? 'es' : '') : '') + (pinned ? ' · ' + d.dist(f.position) + ' tiles from the base' : '') });
      return m;
    }) : [];
    sc.pins = on.alerts ? d.pins.filter(function (p) { return !d.fights.length || (p.kind !== 'attack' && p.kind !== 'loss'); }).map(function (p) {
      var at = spot(p.position), m = { x: px(at.x), y: py(at.y) };
      sc.hits.push({ x: m.x, y: m.y, r: 9, text: cap(p.kind) + ': ' + p.text });
      return m;
    }) : [];
    sc.outposts = on.buildings && d.box ? (d.box.out || []).filter(function (o) { return !inView(o); }).map(function (o) {
      var at = edge(o), m = { x: px(at.x), y: py(at.y) };
      sc.hits.push({ x: m.x, y: m.y, r: 7, text: 'Outpost · ' + o.n + ' building cell' + (o.n > 1 ? 's' : '') + ' · ' + d.dist(o) + ' tiles from the base' });
      return m;
    }) : [];
    var onCam = {};
    Object.keys(d.cams).forEach(function (slot) { (d.cams[slot].agents || []).forEach(function (n) { onCam[n] = slot; }); });
    sc.agents = []; sc.attention = []; sc.away = [];
    if (on.agents) {
      // agents off Nauvis: one row each in the bottom-left corner, bottom up
      d.away.forEach(function (a, i) {
        var text = (a.display_name || a.name) + ' · ' + whereText(a), y = H - 14 - i * 20;
        var m = { name: a.name, text: text, color: a.color, x: 8, y: y, w: textWidth(text, 6.3) + 22, dead: a.alive === false };
        sc.away.push(m);
        taken.push([m.x, y - 9, m.x + m.w, y + 9]);
        sc.hits.push({ x: m.x + 9, y: y, r: 10, text: text + (a.action ? ' · ' + a.action : '') });
      });
      var dots = d.agents.map(function (a) {
        var far = !inView(a.position), at = far ? edge(a.position) : a.position;
        if (far) sc.far[a.name] = d.dist(a.position);
        return { a: a, x: px(at.x), y: py(at.y), far: far, cam: onCam[a.name] ? (CAM_SHORT[onCam[a.name]] || onCam[a.name]) : '' };
      });
      dots.forEach(function (m) {
        taken.push([m.x - 7, m.y - 7, m.x + 7, m.y + 7]);
        if (m.cam) { var tw = textWidth(m.cam, 5.4); taken.push([m.x - tw / 2, m.y - 21, m.x + tw / 2, m.y - 11]); }
      });
      if (on.attention) dots.forEach(function (m) {
        var t = m.a.attention;
        if (!t || !ok(t.position) || t.platform || (t.surface && t.surface !== 'nauvis') || (t.dist != null && t.dist < 3)) return;
        var at = spot(t.position), x = px(at.x), y = py(at.y);
        sc.attention.push({ x0: m.x, y0: m.y, x1: x, y1: y, far: !!t.far, color: m.a.color });
        sc.hits.push({ x: x, y: y, r: 7, text: (m.a.display_name || m.a.name) + ' · ' + t.text + (t.age_s != null ? ' · ' + ago(t.age_s) : '') });
      });
      dots.forEach(function (m) {
        var a = m.a, name = (a.display_name || a.name) + (m.far ? ' ↗' : '');
        var lab = placeLabel(m.x, m.y, textWidth(name, 6.3), taken, W, H, !!m.cam);
        sc.agents.push({ name: a.name, label: lab ? { text: name, x: m.x + lab.x, y: m.y + lab.y, anchor: lab.anchor } : null,
          x: m.x, y: m.y, color: a.color, far: m.far, dead: a.alive === false, cam: m.cam });
        sc.hits.push({ x: m.x, y: m.y, r: 11, agent: a.name, text: (a.display_name || a.name) + (a.action ? ' · ' + a.action : '') +
          (a.location ? ' · ' + a.location : '') + (m.far ? ' · ' + sc.far[a.name] + ' tiles from the base' : '') });
      });
    }
    return sc;
  }
  // The mark under a point (canvas pixels): agents first, then the nearest other.
  function hitAt(sc, x, y) {
    var best = null, bd = Infinity;
    sc.hits.forEach(function (h) {
      var dd = Math.hypot(h.x - x, h.y - y);
      if (dd > h.r) return;
      var score = dd - (h.agent ? 100 : 0);
      if (score < bd) { bd = score; best = h; }
    });
    return best;
  }

  // ------------------------------------------------------------------ painting
  function fillRuns(ctx, g, colours, alpha) {
    ctx.save();
    ctx.translate(g.x, g.y); ctx.scale(g.s, g.s);
    if (alpha != null) ctx.globalAlpha = alpha;
    colours.forEach(function (c) {
      var list = g.runs[c[0]];
      if (!list) return;
      ctx.fillStyle = c[1];
      ctx.beginPath();
      // a hair wider than the cell, so neighbouring runs leave no seams when scaled
      for (var i = 0; i < list.length; i++) ctx.rect(list[i][0], list[i][1], list[i][2] + 0.02, 1.02);
      ctx.fill();
    });
    ctx.restore();
  }
  function circle(ctx, x, y, r) { ctx.beginPath(); ctx.arc(x, y, r, 0, Math.PI * 2); }
  function paint(ctx, sc, images, font, offscreen) {
    var W = sc.W, H = sc.H;
    ctx.fillStyle = C.bg; ctx.fillRect(0, 0, W, H);
    sc.terrain.forEach(function (t) {
      var img = images && images(t.src);
      if (img) { ctx.imageSmoothingEnabled = t.w < img.width; ctx.drawImage(img, t.x, t.y, t.w, t.h); }
    });
    ctx.imageSmoothingEnabled = true;
    if (sc.ground) fillRuns(ctx, sc.ground, GROUND, 0.9);
    ctx.strokeStyle = C.grid; ctx.lineWidth = 1; ctx.beginPath();
    sc.grid.xs.forEach(function (x) { ctx.moveTo(Math.round(x) + 0.5, 0); ctx.lineTo(Math.round(x) + 0.5, H); });
    sc.grid.ys.forEach(function (y) { ctx.moveTo(0, Math.round(y) + 0.5); ctx.lineTo(W, Math.round(y) + 0.5); });
    ctx.globalAlpha = sc.terrain.length ? 0.45 : 1; ctx.stroke(); ctx.globalAlpha = 1;
    if (sc.ore) fillRuns(ctx, sc.ore, ORE, 0.38);
    if (sc.base) {
      if (sc.core) {
        // the coarse grid only outside the fine core, so the two never draw over each other
        ctx.save(); ctx.beginPath(); ctx.rect(0, 0, W, H);
        ctx.rect(sc.clip.x1, sc.clip.y0, sc.clip.x0 - sc.clip.x1, sc.clip.y1 - sc.clip.y0);
        ctx.clip('evenodd'); fillRuns(ctx, sc.base, BASE); ctx.restore();
        fillRuns(ctx, sc.core, BASE);
      } else fillRuns(ctx, sc.base, BASE);
    }
    if (sc.coverage.length) {
      // drawn opaque on its own canvas, then laid over at a low alpha, so overlaps do not darken
      var off = offscreen && offscreen(W, H);
      var oc = off ? off.getContext('2d') : ctx;
      if (off) { oc.save(); oc.setTransform(1, 0, 0, 1, 0, 0); oc.clearRect(0, 0, off.width, off.height); oc.restore(); }
      oc.fillStyle = C.range + (off ? '1)' : '.16)');
      oc.beginPath(); sc.coverage.forEach(function (t) { oc.moveTo(t.x + t.r, t.y); oc.arc(t.x, t.y, t.r, 0, Math.PI * 2); }); oc.fill();
      if (off) { ctx.globalAlpha = 0.16; ctx.drawImage(off, 0, 0, W, H); ctx.globalAlpha = 1; }
      ctx.strokeStyle = C.range + '.55)'; ctx.lineWidth = 1;
      ctx.beginPath(); sc.coverage.forEach(function (t) { ctx.moveTo(t.x + t.r, t.y); ctx.arc(t.x, t.y, t.r, 0, Math.PI * 2); }); ctx.stroke();
    }
    sc.nests.forEach(function (n) {
      ctx.strokeStyle = '#000'; ctx.lineWidth = 1;
      if (n.kind === 'spawner') { ctx.fillStyle = C.nest; ctx.fillRect(n.x - 3, n.y - 3, 6, 6); ctx.strokeRect(n.x - 3, n.y - 3, 6, 6); }
      else { ctx.fillStyle = C.worm; circle(ctx, n.x, n.y, 2.5); ctx.fill(); ctx.stroke(); }
    });
    sc.fights.forEach(function (f) {
      ctx.setLineDash(f.now ? [] : [3, 2]);
      ctx.fillStyle = f.now ? 'rgba(224, 78, 58, .22)' : 'rgba(224, 78, 58, .10)';
      ctx.strokeStyle = f.now ? '#ff5a44' : 'rgba(224, 78, 58, .55)'; ctx.lineWidth = f.now ? 2 : 1.5;
      circle(ctx, f.x, f.y, f.r); ctx.fill(); ctx.stroke();
      ctx.setLineDash([]);
      if (f.loss) { ctx.strokeStyle = '#ffd1c9'; ctx.lineWidth = 1.6; ctx.beginPath(); ctx.moveTo(f.x - 3, f.y - 3); ctx.lineTo(f.x + 3, f.y + 3); ctx.moveTo(f.x + 3, f.y - 3); ctx.lineTo(f.x - 3, f.y + 3); ctx.stroke(); }
    });
    sc.pins.forEach(function (p) {
      ctx.fillStyle = C.red; ctx.strokeStyle = '#000'; ctx.lineWidth = 1;
      ctx.beginPath(); ctx.moveTo(p.x, p.y - 9); ctx.lineTo(p.x + 8, p.y + 6); ctx.lineTo(p.x - 8, p.y + 6); ctx.closePath(); ctx.fill(); ctx.stroke();
      ctx.fillStyle = '#fff'; ctx.font = '700 10px ' + font; ctx.textAlign = 'center'; ctx.fillText('!', p.x, p.y + 4);
    });
    sc.outposts.forEach(function (o) {
      ctx.setLineDash([2, 1.5]); ctx.strokeStyle = C.text; ctx.lineWidth = 1.5; ctx.strokeRect(o.x - 4, o.y - 4, 8, 8); ctx.setLineDash([]);
    });
    sc.attention.forEach(function (t) {
      ctx.globalAlpha = t.far ? 0.9 : 0.55; ctx.strokeStyle = t.color || C.text;
      ctx.setLineDash(t.far ? [] : [3, 3]); ctx.lineWidth = 1.5;
      ctx.beginPath(); ctx.moveTo(t.x0, t.y0); ctx.lineTo(t.x1, t.y1); ctx.stroke(); ctx.setLineDash([]);
      ctx.lineWidth = 1.8; circle(ctx, t.x1, t.y1, 3.5); ctx.stroke(); ctx.globalAlpha = 1;
    });
    sc.agents.forEach(function (a) {
      ctx.globalAlpha = a.dead ? 0.5 : 1;
      if (a.cam) {
        ctx.strokeStyle = C.orange; ctx.lineWidth = 2; circle(ctx, a.x, a.y, 10); ctx.stroke();
        ctx.font = '700 8.5px ' + font; ctx.textAlign = 'center'; ctx.lineWidth = 2.5; ctx.strokeStyle = '#000';
        ctx.strokeText(a.cam, a.x, a.y - 13); ctx.fillStyle = C.orange; ctx.fillText(a.cam, a.x, a.y - 13);
      }
      if (a.follow) { ctx.strokeStyle = '#fff'; ctx.lineWidth = 1.5; circle(ctx, a.x, a.y, 13); ctx.stroke(); }
      ctx.fillStyle = a.color || C.text; circle(ctx, a.x, a.y, 5.5); ctx.fill();
      ctx.setLineDash(a.far ? [2, 2] : []); ctx.strokeStyle = a.far ? C.text : '#000'; ctx.lineWidth = 1.5; ctx.stroke(); ctx.setLineDash([]);
      if (a.label) {
        ctx.font = '600 11px ' + font; ctx.textAlign = a.label.anchor === 'start' ? 'left' : a.label.anchor === 'end' ? 'right' : 'center';
        ctx.lineWidth = 3; ctx.strokeStyle = '#000'; ctx.strokeText(a.label.text, a.label.x, a.label.y);
        ctx.fillStyle = C.text; ctx.fillText(a.label.text, a.label.x, a.label.y);
      }
      ctx.globalAlpha = 1;
    });
    sc.away.forEach(function (a) {
      ctx.globalAlpha = a.dead ? 0.6 : 1;
      ctx.fillStyle = C.inset; ctx.fillRect(a.x - 3, a.y - 9, a.w, 18);
      ctx.fillStyle = a.color || C.text; circle(ctx, a.x + 6, a.y, 4.5); ctx.fill();
      ctx.strokeStyle = '#000'; ctx.lineWidth = 1.2; ctx.stroke();
      ctx.font = '600 11px ' + font; ctx.textAlign = 'left'; ctx.fillStyle = C.text; ctx.fillText(a.text, a.x + 16, a.y + 4);
      ctx.globalAlpha = 1;
    });
    if (sc.inset) {
      var s = sc.inset;
      ctx.fillStyle = C.inset; ctx.strokeStyle = '#3a4037'; ctx.lineWidth = 1;
      ctx.fillRect(s.x - 3, s.y - 3, s.size + 6, s.size + 6); ctx.strokeRect(s.x - 3, s.y - 3, s.size + 6, s.size + 6);
      ctx.save(); ctx.beginPath(); ctx.rect(s.x - 3, s.y - 3, s.size + 6, s.size + 6); ctx.clip();
      fillRuns(ctx, { x: s.x, y: s.y, s: s.s, runs: s.runs }, BASE); ctx.restore();
      if (s.view[2] > s.view[0] && s.view[3] > s.view[1]) {
        ctx.strokeStyle = C.orange; ctx.lineWidth = 1.5;
        ctx.strokeRect(s.view[0], s.view[1], Math.max(2, s.view[2] - s.view[0]), Math.max(2, s.view[3] - s.view[1]));
      }
    }
  }

  // ------------------------------------------------------------------ the viewer
  function store(k, v) { try { if (v === undefined) return localStorage.getItem(k); localStorage.setItem(k, v); } catch (e) { return null; } }
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return '&#' + c.charCodeAt(0) + ';'; }); }
  function has(d, layer) {
    return layer === 'terrain' ? d.terrain.length > 0 || !!d.ground : layer === 'ore' ? !!d.ore : layer === 'buildings' ? !!d.base :
      layer === 'coverage' ? d.turrets.length > 0 : layer === 'nests' ? d.nests.length > 0 : layer === 'agents' ? d.agents.length + d.away.length > 0 :
      layer === 'attention' ? d.agents.some(function (a) { return a.attention && ok(a.attention.position); }) :
      layer === 'alerts' ? d.fights.length + d.pins.length > 0 : false;
  }

  function Viewer(host, opts) {
    var self = this;
    opts = opts || {};
    this.opts = opts;
    this.key = opts.storeKey || 'pog-map';
    this.on = {};
    var saved = {};
    try { saved = JSON.parse(store(this.key + '-layers') || '{}') || {}; } catch (e) { saved = {}; }
    LAYERS.forEach(function (l) { self.on[l[0]] = l[0] in saved ? !!saved[l[0]] : DEFAULT_ON[l[0]]; });
    this.view = null; this.follow = null; this.d = prepare({}); this.sc = null;
    this.images = {}; this.frame = 0; this.ptrs = {};
    var el = this.root = document.createElement('div');
    el.className = 'mapview';
    el.innerHTML = '<div class="mapview-layers" role="group" aria-label="Map layers"></div>' +
      '<div class="mapview-stage"><canvas class="mapview-canvas" role="img" aria-label="' + esc(opts.label || 'Map of the base') + '"></canvas>' +
      '<div class="mapview-tools"><button type="button" class="fx-btn fx-btn--icon" data-mv="in" aria-label="Zoom in">+</button>' +
      '<button type="button" class="fx-btn fx-btn--icon" data-mv="out" aria-label="Zoom out">−</button>' +
      '<button type="button" class="fx-btn" data-mv="reset">Reset</button>' +
      '<button type="button" class="fx-btn" data-mv="full" aria-pressed="false">Full screen</button></div>' +
      '<div class="mapview-follow" hidden><span></span> <button type="button" class="fx-btn small" data-mv="unfollow">Stop</button></div>' +
      '<div class="mapview-tip" role="status" hidden></div></div>' +
      '<div class="mapview-legend"></div><p class="mapview-scale small"></p>';
    host.appendChild(el);
    this.canvas = el.querySelector('canvas'); this.stage = el.querySelector('.mapview-stage');
    this.tip = el.querySelector('.mapview-tip'); this.followEl = el.querySelector('.mapview-follow');
    this.font = '"Titillium Web", system-ui, sans-serif';
    try { this.font = getComputedStyle(el).fontFamily || this.font; } catch (e) { /* default */ }
    el.addEventListener('click', function (ev) { self.onClick(ev); });
    this.canvas.addEventListener('wheel', function (ev) {
      ev.preventDefault();
      var p = self.point(ev);
      self.zoomAt(p, Math.pow(1.0015, ev.deltaY * (ev.deltaMode === 1 ? 33 : 1)));
    }, { passive: false });
    this.canvas.addEventListener('pointerdown', function (ev) { self.down(ev); });
    window.addEventListener('pointermove', function (ev) { self.move(ev); }, { passive: false });
    ['pointerup', 'pointercancel'].forEach(function (t) { window.addEventListener(t, function (ev) { self.up(ev); }); });
    this.canvas.addEventListener('pointerleave', function (ev) { if (ev.pointerType === 'mouse') self.showTip(null); });
    document.addEventListener('fullscreenchange', function () { self.fullChanged(); });
    document.addEventListener('keydown', function (ev) { if (ev.key === 'Escape' && el.classList.contains('mapview--full') && !document.fullscreenElement) self.setFull(false); });
    if (window.ResizeObserver) new ResizeObserver(function () { self.draw(); }).observe(this.stage);
    else window.addEventListener('resize', function () { self.draw(); });
  }
  Viewer.prototype.set = function (data) {
    this.d = prepare(data);
    this.renderLayers();
    this.renderLegend();
    this.draw();
  };
  Viewer.prototype.current = function () {
    var v = this.view || this.d.auto;
    if (this.follow) {
      var a = this.d.agents.filter(function (x) { return x.name === this.follow; }, this)[0];
      if (a && v) v = { cx: a.position.x, cy: a.position.y, span: v.span };
    }
    return v;
  };
  Viewer.prototype.size = function () {
    var w = this.stage.clientWidth || 400, full = this.root.classList.contains('mapview--full');
    var h = full ? (this.stage.clientHeight || window.innerHeight) : Math.round(Math.min(w, (window.innerHeight || w) * 0.8));
    return { w: w, h: h };
  };
  Viewer.prototype.draw = function () {
    var self = this;
    if (this.frame) return;
    this.frame = requestAnimationFrame(function () { self.frame = 0; self.paintNow(); });
  };
  Viewer.prototype.paintNow = function () {
    var self = this, sz = this.size(), dpr = window.devicePixelRatio || 1, cv = this.canvas;
    if (!this.d.auto) { cv.style.height = '0px'; this.root.querySelector('.mapview-scale').textContent = 'No positions yet.'; return; }
    if (cv.width !== Math.round(sz.w * dpr) || cv.height !== Math.round(sz.h * dpr)) { cv.width = Math.round(sz.w * dpr); cv.height = Math.round(sz.h * dpr); }
    cv.style.height = sz.h + 'px';
    var v = this.current(), t0 = Date.now();
    this.sc = scene(this.d, v, sz.w, sz.h, this.on);
    var follow = this.follow;
    this.sc.agents.forEach(function (a) { a.follow = a.name === follow; });
    var ctx = cv.getContext('2d');
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    paint(ctx, this.sc, function (src) { return self.image(src); }, this.font, function (w, h) {
      if (!self.off) self.off = document.createElement('canvas');
      if (self.off.width !== Math.round(w * dpr) || self.off.height !== Math.round(h * dpr)) { self.off.width = Math.round(w * dpr); self.off.height = Math.round(h * dpr); }
      self.off.getContext('2d').setTransform(dpr, 0, 0, dpr, 0, 0);
      return self.off;
    });
    this.root.dataset.paintMs = Date.now() - t0;  // tools/site_shots.js reads how long a frame took
    this.root.querySelector('.mapview-scale').textContent = '≈' + Math.round(v.span) + ' tiles across · grid ' + this.sc.grid.step + ' tiles';
    var fb = this.root.querySelector('[data-mv="reset"]');
    fb.disabled = !this.view && !this.follow;
  };
  Viewer.prototype.image = function (src) {
    var self = this, im = this.images[src];
    if (!im) {
      im = this.images[src] = new Image();
      im.decoding = 'async';
      im.onload = function () { im.ready = true; self.draw(); };
      im.src = src;
    }
    return im.ready ? im : null;
  };
  Viewer.prototype.renderLayers = function () {
    var self = this, box = this.root.querySelector('.mapview-layers');
    var sig = LAYERS.map(function (l) { return has(self.d, l[0]) ? l[0] + (self.on[l[0]] ? 1 : 0) : ''; }).join(',');
    if (box.dataset.sig === sig) return;
    box.dataset.sig = sig;
    box.innerHTML = LAYERS.filter(function (l) { return has(self.d, l[0]); }).map(function (l) {
      return '<button type="button" class="fx-btn small mapview-layer" data-layer="' + l[0] + '" aria-pressed="' + (self.on[l[0]] ? 'true' : 'false') + '">' + esc(l[1]) + '</button>';
    }).join('');
  };
  Viewer.prototype.renderLegend = function () {
    var d = this.d, on = this.on, h = '';
    if (d.base && on.buildings) {
      var seen = {};
      [d.base, d.fine].forEach(function (g) { if (g) Object.keys(runs(g)).forEach(function (c) { seen[c] = 1; }); });
      h += BASE.filter(function (c) { return seen[c[0]]; }).map(function (c) { return '<li><i class="b-' + c[0] + '"></i>' + esc(c[2]) + '</li>'; }).join('');
    }
    if (d.ore && on.ore) {
      var ores = runs(d.ore);
      h += ORE.filter(function (c) { return ores[c[0]]; }).map(function (c) { return '<li class="ore"><i class="o-' + c[0] + '"></i>' + esc(c[2]) + '</li>'; }).join('');
    }
    if (d.turrets.length && on.coverage) h += '<li><i class="mv-range"></i>Turret range</li>';
    if (d.nests.length && on.nests) h += '<li><i class="nest"></i>Enemy nests</li>';
    if (d.fights.length && on.alerts) h += '<li><i class="mv-fight"></i>Fights</li>';
    var box = this.root.querySelector('.mapview-legend');
    if (box.dataset.sig !== h) { box.dataset.sig = h; box.innerHTML = h ? '<ul class="mm-legend">' + h + '</ul>' : ''; }
  };
  Viewer.prototype.point = function (ev) {
    var r = this.canvas.getBoundingClientRect(), v = this.current(), k = Math.min(r.width, r.height) / v.span;
    var dx = ev.clientX - r.left - r.width / 2, dy = ev.clientY - r.top - r.height / 2;
    return { dx: dx, dy: dy, k: k, x: v.cx + dx / k, y: v.cy + dy / k, cx: ev.clientX - r.left, cy: ev.clientY - r.top };
  };
  Viewer.prototype.zoomAt = function (p, factor) {
    var v = this.current();
    if (!v) return;
    var span = Math.min(4000, Math.max(24, v.span * factor));
    if (this.follow) { this.view = { span: span, cx: v.cx, cy: v.cy }; }
    else { var k = p.k * v.span / span; this.view = { span: span, cx: p.x - p.dx / k, cy: p.y - p.dy / k }; }
    this.draw();
  };
  Viewer.prototype.pan = function (dxPx, dyPx) {
    var v = this.current(), r = this.canvas.getBoundingClientRect(), k = Math.min(r.width || 1, r.height || 1) / v.span;
    this.setFollow(null);
    this.view = { span: v.span, cx: v.cx - dxPx / k, cy: v.cy - dyPx / k };
    this.draw();
  };
  Viewer.prototype.setFollow = function (name) {
    this.follow = name;
    var a = name && this.d.agents.filter(function (x) { return x.name === name; })[0];
    this.followEl.hidden = !a;
    if (a) this.followEl.querySelector('span').textContent = 'Following ' + (a.display_name || a.name);
    this.draw();
  };
  Viewer.prototype.showTip = function (hit, x, y) {
    if (!hit) { this.tip.hidden = true; return; }
    this.tip.textContent = hit.text;
    this.tip.hidden = false;
    var w = this.stage.clientWidth;
    this.tip.style.left = Math.max(4, Math.min(x + 12, w - 220)) + 'px';
    this.tip.style.top = Math.max(4, y + 14) + 'px';
  };
  Viewer.prototype.down = function (ev) {
    if (ev.pointerType === 'mouse' && ev.button !== 0) return;
    this.ptrs[ev.pointerId] = { x: ev.clientX, y: ev.clientY, x0: ev.clientX, y0: ev.clientY, moved: 0 };
  };
  Viewer.prototype.move = function (ev) {
    var p = this.ptrs[ev.pointerId];
    if (!p) {
      if (ev.pointerType === 'mouse' && ev.target === this.canvas && this.sc) {
        var q = this.point(ev);
        this.showTip(hitAt(this.sc, q.cx, q.cy), q.cx, q.cy);
      }
      return;
    }
    var ids = Object.keys(this.ptrs);
    if (ids.length === 1) {
      p.moved = Math.max(p.moved, Math.hypot(ev.clientX - p.x0, ev.clientY - p.y0));
      if (p.moved > 4) { this.pan(ev.clientX - p.x, ev.clientY - p.y); this.showTip(null); }
    } else if (ids.length === 2) {
      var o = this.ptrs[ids[0] == ev.pointerId ? ids[1] : ids[0]];
      var d0 = Math.hypot(p.x - o.x, p.y - o.y) || 1, d1 = Math.hypot(ev.clientX - o.x, ev.clientY - o.y) || 1;
      p.moved = 99;
      this.zoomAt(this.point({ clientX: (ev.clientX + o.x) / 2, clientY: (ev.clientY + o.y) / 2 }), d0 / d1);
      ev.preventDefault();
    } else return;
    p.x = ev.clientX; p.y = ev.clientY;
  };
  Viewer.prototype.up = function (ev) {
    var p = this.ptrs[ev.pointerId];
    delete this.ptrs[ev.pointerId];
    if (!p || p.moved > 4 || ev.type === 'pointercancel' || !this.sc || ev.target !== this.canvas) return;
    // a click or tap: an agent is followed; anything else shows its tip (a tap on nothing hides it)
    var q = this.point(ev), hit = hitAt(this.sc, q.cx, q.cy);
    if (hit && hit.agent) this.setFollow(hit.agent);
    this.showTip(hit, q.cx, q.cy);
  };
  Viewer.prototype.onClick = function (ev) {
    var b = ev.target.closest && ev.target.closest('[data-mv],[data-layer]');
    if (!b) return;
    if (b.dataset.layer) {
      var l = b.dataset.layer, saved = {};
      this.on[l] = !this.on[l];
      for (var k in this.on) saved[k] = this.on[k];
      store(this.key + '-layers', JSON.stringify(saved));
      this.renderLayers(); this.renderLegend(); this.draw();
      return;
    }
    var act = b.dataset.mv, v = this.current();
    if (act === 'reset') { this.view = null; this.setFollow(null); this.showTip(null); }
    else if (act === 'unfollow') this.setFollow(null);
    else if (act === 'full') this.setFull(!this.root.classList.contains('mapview--full'));
    else if (v) this.zoomAt({ dx: 0, dy: 0, k: 1, x: v.cx, y: v.cy }, act === 'in' ? 1 / 1.5 : 1.5);
  };
  // Full screen: the browser's own where it has one for any element, else the map fills the window.
  Viewer.prototype.setFull = function (on) {
    var el = this.root;
    if (on && el.requestFullscreen && !document.fullscreenElement) {
      el.requestFullscreen().catch(function () { el.classList.add('mapview--full'); });
      el.classList.add('mapview--full');
    } else if (!on && document.fullscreenElement === el) document.exitFullscreen();
    else el.classList.toggle('mapview--full', on);
    this.root.querySelector('[data-mv="full"]').setAttribute('aria-pressed', on ? 'true' : 'false');
    this.draw();
  };
  Viewer.prototype.fullChanged = function () {
    if (!document.fullscreenElement && this.root.classList.contains('mapview--full')) {
      this.root.classList.remove('mapview--full');
      this.root.querySelector('[data-mv="full"]').setAttribute('aria-pressed', 'false');
    }
    this.draw();
  };

  root.PogMap = {
    viewers: [],  // the page's viewers (tools/site_shots.js finds an agent's dot through them)
    create: function (host, opts) { var v = new Viewer(host, opts); root.PogMap.viewers.push(v); return v; },
    prepare: prepare, scene: scene, hitAt: hitAt, paint: paint, runs: runs,
    LAYERS: LAYERS, DEFAULT_ON: DEFAULT_ON, BASE: BASE, ORE: ORE
  };
})(typeof window !== 'undefined' ? window : this);
