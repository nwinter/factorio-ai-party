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
// [x0, y0, w, h] (a fixed frame instead of the framing on the base's core), clouds [{surface, label, pollutant, color
// {r, g, b, a}, cells [[cx, cy, amount]], max, reached [{x, y}]}] (the stream's pollution and spore layer per surface,
// tools/stream/clouds.py: 32-tile chunks, drawn in the game's map colour, the amount on hover), surface (the surface
// shown, default nauvis), planets {surface: grid} (another planet's coarse map, the census's; push_live sends one a
// push and live.js keeps them; the viewer keeps every surface seen and its last map, remember()), now_tick (the state's
// game tick: a kept map's age). The map is Nauvis, with its base; a switch shows another planet with a map or a cloud
// (Gleba's spores) and only what is known there: its buildings, the cloud, the nests it reached, the agents on it. An agent elsewhere (another
// planet, aboard a platform or in a cargo pod) is listed in the map's corner ("Sol · Vulcanus"), never drawn.
(function (root) {
  'use strict';
  // the live map's colours (style.css .b-X and .o-X: the legends use those)
  // (d22 batch75 AK4, viewer Foobator: "can walls be a separate item?") walls and gates W; D the turrets (frames read
  // before it have walls in D too); (d22 batch97 BG3) no K: storage was never emitted apart from L
  var BASE = [['D', '#c8553d', 'Defence'], ['W', '#e9dcc0', 'Walls and gates'], ['R', '#a983f0', 'Labs'], ['O', '#3fa8a3', 'Oil and chemistry'], ['A', '#5c8fd6', 'Assembly'],
    ['S', '#e08a3c', 'Smelting'], ['M', '#a6875a', 'Mining'], ['E', '#f2d34b', 'Power'], ['L', '#b9b9b9', 'Logistics and storage'],
    ['I', '#9fcf6a', 'Inserters'], ['B', '#8a7d45', 'Belts'], ['T', '#6e6a8e', 'Rails'], ['P', '#4a6a8a', 'Pipes']];
  var ORE = [['i', '#7f9db4', 'Iron ore'], ['c', '#d0703a', 'Copper ore'], ['k', '#5a5a5a', 'Coal'], ['s', '#c2ab7a', 'Stone'],
    ['o', '#b04fb5', 'Crude oil'], ['u', '#6fe05a', 'Uranium ore'], ['x', '#9a9a9a', 'Other resource']];
  var GROUND = [['w', '#20384a', 'Water'], ['c', '#5b4a36', 'Cliffs'], ['u', '#0d0f0c', 'Uncharted']];
  var LINE_CATS = { P: 1, B: 1, I: 1, T: 1 };
  var LAYERS = [['chart', 'Chart'], ['terrain', 'Terrain'], ['ore', 'Ore'], ['cloud', 'Pollution'], ['buildings', 'Buildings'], ['coverage', 'Turret range'],
    ['readiness', 'Turret state'], ['library', 'Blueprints'], ['power', 'Power'], ['robots', 'Logistics'], ['nests', 'Nests'], ['threats', 'Attacks'], ['agents', 'Agents'], ['attention', 'Attention'], ['alerts', 'Fights']];
  var DEFAULT_ON = { chart: true, terrain: true, ore: true, cloud: true, buildings: true, coverage: false, readiness: true, library: true, power: false, robots: false, nests: true, threats: true, agents: true, attention: true, alerts: true };
  var C = { bg: '#1b1f1a', grid: '#2b302a', text: '#e8e6e1', orange: '#ff9b2e', red: '#e04e3a', nest: '#ff3b30', worm: '#ff8a7a',
    range: 'rgba(120, 200, 255, ', inset: 'rgba(16, 18, 15, .88)', empty: '#ff3b30', nopower: '#f2c94c', unknown: '#9a9a9a' };
  // (d20 batch50 G1, viewer Aurora: "Could the map flag turrets lacking ammo, fuel or energy and mark stale or unknown
  // readings?") basemap.turret_state (tools/stream/turretstate.py): counts per state and the turrets not armed now as
  // [x, y, state (e empty, p no power, u unknown), name, age_s at as_of], read once a minute.
  var READY = { e: 'empty (no ammo, shells or fluid)', p: 'no power (less than one shot\'s energy)', u: 'unknown' };
  function turretName(n) { return n ? cap(String(n).replace(/-turret$/, ' turret')) : 'Turret'; }
  function agoText(s) { s = Math.max(0, Math.round(s)); return s < 90 ? s + ' s' : s < 5400 ? Math.round(s / 60) + ' min' : Math.round(s / 3600) + ' h'; }
  var CAM_SHORT = { main: 'MAIN', cam2: 'CAM 2', cam3: 'CAM 3' };
  var TERRAIN_DESAT = 0.6, TERRAIN_DIM = 0.45;  // how much colour the terrain loses, and how far it fades to the ground
  function num(x) { return typeof x === 'number' && isFinite(x); }
  var OLD_TERRAIN_S = 30 * 60;  // (AK9) a terrain frame this old on the live map is labelled with its age

  // (d21 batch68 AD1) a grid push_live run-length packs (rle: "12A" is twelve A cells), unpacked once; others as they are
  function unpack(g) {
    if (!g || !g.rle || !Array.isArray(g.rows)) return g;
    var out = Object.assign({}, g, { rows: g.rows.map(function (r) { return String(r).replace(/(\d+)(\D)/g, function (m, n, c) { return new Array(+n + 1).join(c); }); }) });
    delete out.rle;
    if (g.core) out.core = unpack(g.core);
    return out;
  }
  function unpackData(data) {
    if (!data) return data;
    var planets = {};
    Object.keys(data.planets || {}).forEach(function (k) { planets[k] = unpack(data.planets[k]); });
    // (AD3) each planet's networks map: its electric grid packed as the others
    var nets = {};
    Object.keys(data.net_maps && typeof data.net_maps === 'object' ? data.net_maps : {}).forEach(function (k) {
      var m = data.net_maps[k];
      if (m && typeof m === 'object') nets[k] = Object.assign({}, m, { electric: unpack(m.electric) });
    });
    return Object.assign({}, data, { base: unpack(data.base), core: unpack(data.core), ore: unpack(data.ore), ground: unpack(data.ground), planets: planets, net_maps: nets });
  }
  function validGrid(g) {
    return !!(g && Array.isArray(g.rows) && g.rows.length && isFinite(g.x0) && isFinite(g.y0) && g.cell > 0);
  }
  function ok(p) { return !!(p && isFinite(p.x) && isFinite(p.y)); }
  // Not on the surface shown (Nauvis): another planet, aboard a platform, or riding a cargo pod (travel: ascending,
  // aboard, descending).
  function elsewhere(a, surface) { return !!(a.on_platform || a.travel || (a.surface || 'nauvis') !== (surface || 'nauvis')); }
  function whereText(a) {
    if (a.travel) return a.location || a.where || 'cargo pod';
    if (a.on_platform) return (a.where || 'a platform') + ' (platform)';
    var s = a.where || String(a.surface || 'nauvis').replace(/[-_]/g, ' ');
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
  // connected group of dense blocks (pipes, belts, inserters and rails left out), plus 8 tiles. A block is 32 tiles,
  // or 4 cells of a coarser grid (d19 batch42 B1, viewer Aurora: on Fulgora's 32-tile grid each block held one cell,
  // none was dense, and reading the group of none stopped the switch with the previous planet still drawn); with no
  // dense group, the box around every cell.
  function baseCore(g) {
    var cells = [], cell = g.cell, B = Math.max(32, 4 * cell);
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
      var key = Math.floor(p.x / B) + ',' + Math.floor(p.y / B);
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
    if (best) best.group.forEach(function (b) {
      box.x0 = Math.min(box.x0, b[0] * B - 8); box.y0 = Math.min(box.y0, b[1] * B - 8);
      box.x1 = Math.max(box.x1, b[0] * B + B + 8); box.y1 = Math.max(box.y1, b[1] * B + B + 8);
    });
    else cells.forEach(function (p) {
      box.x0 = Math.min(box.x0, p.x - cell / 2 - 8); box.y0 = Math.min(box.y0, p.y - cell / 2 - 8);
      box.x1 = Math.max(box.x1, p.x + cell / 2 + 8); box.y1 = Math.max(box.y1, p.y + cell / 2 + 8);
    });
    box.out = outposts(g, box);
    return box;
  }

  // (d21 batch68 AD3, viewer Aurora: "Could maps show logistic/power network IDs and coverage, plus a selected item's
  // source-to-consumer blockers?") a planet's networks map (netmap.lua via push_live): electric networks {id, letter,
  // poles} and the grid of their poles' supply areas; logistic networks with their roboports [x, y, logistic radius,
  // construction radius] and robots [logistic, idle, construction, idle]; per item its sources and consumers by kind
  // and logistic network (0: outside every one) {kind, net, n, amount, unpowered, box [x0, y0, x1, y1], pos [[x, y]]}.
  var NET_LETTERS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  function netColour(i, a) { return 'hsla(' + Math.round((i * 137.508 + 48) % 360) + ', 70%, 58%, ' + (a == null ? 1 : a) + ')'; }
  var POWER = NET_LETTERS.split('').map(function (c, i) { return [c, netColour(i)]; }).concat([['*', '#9a9a9a']]);
  function nums(t, n) {
    var f = String(t).split(',').map(Number);
    return f.length >= n && f.every(isFinite) ? f : null;
  }
  var KIND = { A: ['crafter', 'crafters'], M: ['drill', 'drills'], R: ['lab', 'labs'], P: ['provider chest', 'provider chests'],
    S: ['storage chest', 'storage chests'], B: ['buffer chest', 'buffer chests'], Q: ['requester chest', 'requester chests'], L: ['cargo landing pad', 'cargo landing pads'], T: ['machine trash slot', 'machines\' trash slots'] };
  function itemGroups(text) {
    return String(text || '').split(';').map(function (t) {
      var kind = String(t).split(',')[0], f = nums(String(t).slice(kind.length + 1), 6);
      if (!f || !KIND[kind]) return null;
      var one = f.length < 8;
      var g = { kind: kind, net: f[0], n: f[1], amount: f[2], unpowered: f[3], box: one ? [f[4], f[5], f[4], f[5]] : [f[4], f[5], f[6], f[7]], pos: [] };
      if (one) g.pos.push([f[4], f[5]]);
      else for (var i = 8; i + 1 < f.length; i += 2) g.pos.push([f[i], f[i + 1]]);
      return g;
    }).filter(Boolean);
  }
  function parseNet(m) {
    if (!m || typeof m !== 'object') return null;
    var e = m.electric && typeof m.electric === 'object' ? m.electric : {}, byLetter = {}, list = [];
    String(e.nets || '').split(';').forEach(function (t) {
      var f = String(t).split(',');
      if (f.length === 3 && f[1] && isFinite(+f[0])) { var n = { id: +f[0], letter: f[1], poles: +f[2] }; byLetter[f[1]] = n; list.push(n); }
    });
    var logistic = (Array.isArray(m.logistic) ? m.logistic : []).map(function (n, i) {
      var ports = [];
      String(n.ports || '').split(';').forEach(function (t) { var f = nums(t, 2); if (f) ports.push([f[0], f[1], n.lr, n.cr]); });
      String(n.odd || '').split(';').forEach(function (t) { var f = nums(t, 4); if (f) ports.push(f.slice(0, 4)); });
      return { id: n.id, i: i, ports: ports, robots: nums(n.robots || '', 4) };
    }).filter(function (n) { return n.ports.length > 0; });
    var items = {}, names = [];
    (Array.isArray(m.items) ? m.items : []).forEach(function (i) {
      if (!Array.isArray(i) || typeof i[0] !== 'string') return;
      items[i[0]] = { s: itemGroups(i[1]), c: itemGroups(i[2]) };
      names.push(i[0]);
    });
    names.sort();
    return { tick: m.tick, grid: validGrid(e) ? e : null, byLetter: byLetter, nets: list, poles: e.poles, more: e.more, more_poles: e.more_poles,
      outside: e.outside, cellFrom: e.cell_from, logistic: logistic, items: items, names: names, left_out: m.left_out || 0,
      research: m.research };
  }
  function netName(id) { return id ? 'logistic network #' + id : 'outside every logistic network'; }
  // An item's groups in words, each with its gaps: a group outside every logistic network; a consumer whose network has
  // no source of the item (or the planet none); a source whose network has no consumer of it; members with an electric
  // energy source on no electric network.
  function itemFacts(net, name) {
    var it = net && net.items[name];
    if (!it) return null;
    var srcAt = {}, useAt = {};
    it.s.forEach(function (g) { if (g.net) srcAt[g.net] = (srcAt[g.net] || 0) + g.n; });
    it.c.forEach(function (g) { if (g.net) useAt[g.net] = (useAt[g.net] || 0) + g.n; });
    var marks = [];
    [['s', it.s], ['c', it.c]].forEach(function (rg) {
      rg[1].forEach(function (g) {
        var k = KIND[g.kind] || [g.kind, g.kind], what = g.n + ' ' + (g.n === 1 ? k[0] : k[1]), gaps = [];
        if (rg[0] === 's') what += g.kind === 'A' ? ' making it' : g.kind === 'M' ? ' mining it' : g.kind === 'T' || g.kind === 'R' ? ' holding ' + g.amount + ' in trash slots' : ' holding ' + g.amount;
        else what += g.kind === 'A' ? ' whose recipe takes it' : g.kind === 'R' ? ' the research takes it in' : ' asking for ' + g.amount;
        if (!g.net) gaps.push('outside every logistic network');
        else if (rg[0] === 'c' && !srcAt[g.net]) gaps.push(it.s.length ? 'no source of it in network #' + g.net : 'no source of it on this planet');
        else if (rg[0] === 's' && it.c.length && !useAt[g.net]) gaps.push('no consumer of it in network #' + g.net);
        if (g.unpowered) gaps.push(g.unpowered + ' on no electric network');
        var where = g.n === 1 ? 'at (' + g.box[0] + ', ' + g.box[1] + ')' : 'in x ' + g.box[0] + '..' + g.box[2] + ', y ' + g.box[1] + '..' + g.box[3];
        marks.push({ role: rg[0], g: g, gaps: gaps, text: (rg[0] === 's' ? 'Source of ' : 'Consumer of ') + name + ': ' + what + ' · ' +
          (g.net ? netName(g.net) : 'its spot outside every logistic network') + ' · ' + where + (gaps.length ? ' · gap: ' + gaps.join('; ') : '') });
      });
    });
    var count = function (list) { return list.reduce(function (a, g) { return a + g.n; }, 0); };
    var lines = [name + ': ' + count(it.s) + ' source' + (count(it.s) === 1 ? '' : 's') + ' in ' + it.s.length + ' group' + (it.s.length === 1 ? '' : 's') + ', ' +
      count(it.c) + ' consumer' + (count(it.c) === 1 ? '' : 's') + ' in ' + it.c.length + ' group' + (it.c.length === 1 ? '' : 's')];
    if (!it.s.length) lines.push('no source of it on this planet (crafter, drill, chest, landing pad or trash slot)');
    if (!it.c.length) lines.push('no consumer of it on this planet (crafter, lab or request)');
    var gapped = marks.filter(function (m) { return m.gaps.length; });
    lines.push(gapped.length ? gapped.length + ' group' + (gapped.length === 1 ? '' : 's') + ' with a gap: ' + gapped.map(function (m) {
      return (m.role === 's' ? 'source ' : 'consumer ') + (KIND[m.g.kind] || [m.g.kind, m.g.kind])[1] + ' ' + (m.g.net ? '#' + m.g.net : '(no network)') + ': ' + m.gaps.join('; ');
    }).join(' · ') : 'every source and consumer shares a logistic network with the other side');
    return { marks: marks, lines: lines, gaps: gapped.length };
  }
  function hasGap(net, name) { var f = itemFacts(net, name); return !!(f && f.gaps); }
  function netLabel(n) { return n.id ? 'Logistic network #' + n.id : 'In no logistic network'; }
  function robotText(n) {
    var r = n.robots;
    return n.ports.length + ' roboport' + (n.ports.length === 1 ? '' : 's') + (r ? ', logistic robots ' + r[0] + ' (' + r[1] + ' idle), construction robots ' + r[2] + ' (' + r[3] + ' idle)' : '');
  }
  // The networks under a tile position, as the game's map shows them on hover: the electric network a pole of which
  // supplies the cell, the logistic networks whose roboports' logistic (or only construction) area covers it.
  function netHit(d, x, y, on) {
    if (!d || !d.net) return null;
    var parts = [];
    if (on.power && d.net.grid) {
      var g = d.net.grid, cx = Math.floor((x - g.x0) / g.cell), cy = Math.floor((y - g.y0) / g.cell), row = g.rows[cy];
      var ch = row && cx >= 0 ? row.charAt(cx) : '';
      if (ch && ch !== '.') {
        var n = d.net.byLetter[ch];
        parts.push(n ? 'Electric network #' + n.id + ': ' + n.poles + ' pole' + (n.poles === 1 ? '' : 's') : 'One of ' + (d.net.more || 'the') + ' smaller electric networks');
      }
    }
    if (on.robots) d.net.logistic.forEach(function (n) {
      var inside = function (r) { return n.ports.some(function (p) { return Math.abs(x - p[0]) <= p[r] && Math.abs(y - p[1]) <= p[r]; }); };
      var inL = inside(2), inC = !inL && inside(3);
      if (inL || inC) parts.push((inL ? 'Logistic area' : 'Construction area only') + ' of ' + (n.id ? 'logistic network #' + n.id : 'roboports in no logistic network') + ': ' + robotText(n));
    });
    return parts.length ? { text: parts.join(' · ') } : null;
  }

  // (d22 batch97 BG3: a map like the Galaxy of Fame's) the chart the stream service draws from the game
  // (tools/stream/chart.py): 384-tile cells at 1 px a tile in the game's map colours, published with the site under
  // data.chart.base (/live/chart/); data.chart.index {v, cell, tick, surfaces: {name: {platform, cells: {"cx,cy":
  // [version, oldest read tick, newest, chunks, x0, y0, x1, y1 (the box round our buildings)]}}}}; data.chart_labels:
  // the labels files loaded so far (the viewer's cache: src -> {recipes, stops}).
  var CHART_CELL = 384;
  function chartSafe(s) { return String(s).replace(/[^\w.-]/g, '_'); }
  function chartCells(data, surface) {
    var ch = data.chart, idx = ch && ch.index, sf = idx && idx.surfaces && idx.surfaces[surface];
    if (!sf || !sf.cells || typeof sf.cells !== 'object') return [];
    var cell = num(idx.cell) ? idx.cell : CHART_CELL, base = typeof ch.base === 'string' ? ch.base : '/live/chart/';
    return Object.keys(sf.cells).map(function (k) {
      var m = /^(-?\d+),(-?\d+)$/.exec(k), r = sf.cells[k];
      if (!m || !Array.isArray(r) || !num(r[0])) return null;
      var cx = +m[1], cy = +m[2], stem = base + chartSafe(surface) + '/' + cx + '_' + cy;
      return { cx: cx, cy: cy, x0: cx * cell, y0: cy * cell, cell: cell, v: r[0], t0: r[1], t1: r[2], n: r[3],
        box: r.length >= 8 && [r[4], r[5], r[6], r[7]].every(num) ? [r[4], r[5], r[6], r[7]] : null,
        src: stem + '.png?v=' + r[0], labels: stem + '.labels.json?v=' + r[0] };
    }).filter(Boolean);
  }
  function chartAge(d, t) { return num(t) && d.now_tick != null && d.now_tick >= t ? (d.now_tick - t) / 60 : null; }

  // What the data holds, normalised: grids, the core box with its outposts, and the automatic view {cx, cy, span}:
  // the base's core and the agents, alerts and fights near it (far ones are pinned to the edge), or data.box.
  function prepare(data) {
    data = data || {};
    var surface = data.surface || 'nauvis', home = surface === 'nauvis';
    // another planet: its coarse map and (AD1) its dense core, as Nauvis's (data.planets, the census's; no ore or terrain there)
    var away = !home && data.planets && data.planets[surface];
    var base = home ? (validGrid(data.base) && data.base.rows.length ? data.base : null) : (validGrid(away) && away.rows.length ? away : null);
    var fine = home ? data.core : base && away.core;
    var core = validGrid(fine) && fine.w > 0 ? fine : null;
    var d = { surface: surface, now_tick: isFinite(data.now_tick) ? data.now_tick : null, base: base, fine: core, ore: home && validGrid(data.ore) ? data.ore : null,
      ground: home && validGrid(data.ground) ? data.ground : null };
    // (d22 batch75 AK9, viewer Aurora site:4272: "Terrain is blank north of the base where Opus explored ... make newly
    // charted areas appear automatically with visible terrain freshness") the charted ground read from the game
    // (tools/stream/terrain_grid.py: each chunk's tiles at 8-tile cells in the game's map colours, cliffs): its own
    // palette, its age (the newest read, the oldest chunk's) beside the frames' capture times
    if (d.ground) {
      var pal = (Array.isArray(data.ground.palette) ? data.ground.palette : []).filter(function (p) {
        return Array.isArray(p) && typeof p[0] === 'string' && p[0].length === 1 && /^#[0-9a-f]{6}$/i.test(p[1]);
      });
      d.groundPal = pal.length ? pal : GROUND;
      var nowT = num(data.now) ? data.now : Date.now() / 1000;
      d.groundAge = num(data.ground.t) ? Math.max(0, nowT - data.ground.t) : num(data.ground.age_s) ? data.ground.age_s : null;
      d.groundOldest = num(data.ground.oldest_tick) && d.now_tick != null ? Math.max(0, (d.now_tick - data.ground.oldest_tick) / 60) : null;
      d.groundChunks = num(data.ground.chunks) ? data.ground.chunks : null;
    }
    // the clouds: the one of the surface shown, and the surfaces that have one (the switch)
    d.clouds = (Array.isArray(data.clouds) ? data.clouds : []).filter(function (c) {
      return c && c.surface && Array.isArray(c.cells) && c.cells.length && c.cells.every(function (x) { return x && isFinite(x[0]) && isFinite(x[1]) && x[2] > 0; });
    });
    d.cloud = d.clouds.filter(function (c) { return c.surface === surface; })[0] || null;
    // the planets with a map (the switch)
    d.planets = Object.keys(data.planets || {}).filter(function (k) { return k !== 'nauvis' && validGrid(data.planets[k]) && data.planets[k].rows.length; }).sort();
    d.chart = chartCells(data, surface);
    d.chartLabels = data.chart_labels || {};
    var ts = d.chart.map(function (c) { return c.t0; }).filter(num), tn = d.chart.map(function (c) { return c.t1; }).filter(num);
    d.chartOldest = ts.length ? chartAge(d, Math.min.apply(0, ts)) : null;
    d.chartNewest = tn.length ? chartAge(d, Math.max.apply(0, tn)) : null;
    d.cloudAt = {};
    if (d.cloud) d.cloud.cells.forEach(function (x) { d.cloudAt[x[0] + ',' + x[1]] = x[2]; });
    d.away = (data.agents || []).filter(function (a) { return a && elsewhere(a, surface); });
    d.agents = (data.agents || []).filter(function (a) { return a && ok(a.position) && !elsewhere(a, surface); });
    d.fights = home ? (data.fights || []).filter(function (f) { return f && ok(f.position); }) : [];
    d.pins = home ? (data.pins || []).filter(function (p) { return p && ok(p.position); }) : [];
    // (d22 batch97 BG3) enemy groups on their way and demolishers near ours (harness attack_groups_live and
    // big_enemies_live, read every 2-10 s; push_live's threats), on the surface shown
    var th = data.threats || {}, here = function (x) { return x && ok(x.position) && (x.surface || 'nauvis') === surface; };
    d.groups = (Array.isArray(th.incoming) ? th.incoming : []).filter(here);
    d.big = (Array.isArray(th.big) ? th.big : []).filter(here);
    d.nests = (home && Array.isArray(data.nests) ? data.nests : []).filter(function (n) { return n && isFinite(n[0]) && isFinite(n[1]); });
    // (G1) each turret's readiness; ages from the state's game tick (now_tick) when it has one
    var ts = home && data.base && data.base.turret_state;
    d.tstate = ts && typeof ts === 'object' && ts.counts && typeof ts.counts === 'object' ? {
      counts: ts.counts, more: ts.more || 0, every: ts.every_s || 60,
      late: isFinite(data.now_tick) && isFinite(ts.as_of) && data.now_tick >= ts.as_of ? (data.now_tick - ts.as_of) / 60 : 0,
      flagged: (Array.isArray(ts.flagged) ? ts.flagged : []).filter(function (f) { return f && isFinite(f[0]) && isFinite(f[1]) && READY[f[2]]; }) } : null;
    d.turrets = (home && Array.isArray(data.turrets) ? data.turrets : []).filter(function (t) { return t && isFinite(t[0]) && isFinite(t[1]) && t[2] > 0 && t[2] < 80; });
    // (d19 batch42 B2, viewer Aurora) what the turret list is: every turret read in the map's defence cells (the stream's
    // sweep, tools/stream/turretsweep.py), or the basemap's first 600 only (capped: more stand that are not drawn)
    var tr = home && data.turrets_read && typeof data.turrets_read === 'object' ? data.turrets_read : null;
    d.turretNote = !d.turrets.length ? '' : tr && tr.complete ? 'all ' + tr.turrets + ' turrets' + (tr.drawn < tr.turrets ? ', ' + (tr.turrets - tr.drawn) + ' within 2 tiles of another merged' : '')
      : (tr && tr.capped) || d.turrets.length >= 600 ? 'incomplete: the first ' + d.turrets.length + ' turrets read; the rest are not drawn yet' : '';
    d.turretsCapped = !!d.turretNote && d.turretNote.indexOf('incomplete') === 0;
    d.terrain = (home && Array.isArray(data.terrain) ? data.terrain : []).filter(function (t) {
      return t && typeof t.src === 'string' && /^(\/[\w\/.-]+|https:\/\/[^"'<>\s]+)$/.test(t.src) &&
        [t.x0, t.y0, t.x1, t.y1].every(isFinite) && t.x1 > t.x0 && t.y1 > t.y0 && (data.tick == null || !(t.tick > data.tick));
    }).sort(function (a, b) { return (a.tick || 0) - (b.tick || 0); });
    // (d19 batch42 B3, viewer Aurora) when the frames drawn were captured: the newest and oldest wall time (or game tick)
    var caps = d.terrain.map(function (t) { return isFinite(t.t) ? t.t : null; }).filter(function (t) { return t != null; });
    d.terrainNow = num(data.now) ? data.now : null;
    d.terrainNote = !d.terrain.length ? '' : caps.length ? 'captured ' + when(Math.min.apply(0, caps)) +
      (Math.max.apply(0, caps) - Math.min.apply(0, caps) > 600 ? ' to ' + when(Math.max.apply(0, caps)) : '')
      : 'captured at game tick ' + d.terrain[d.terrain.length - 1].tick;
    // (d21 batch68 AD2, viewer Aurora) the team library's placed areas on this surface (libareas.lua via push_live)
    d.areas = (Array.isArray(data.library_areas) ? data.library_areas : []).filter(function (a) {
      return a && typeof a.name === 'string' && Array.isArray(a.box) && a.box.length === 4 && a.box.every(isFinite) && a.box[2] > a.box[0] && a.box[3] > a.box[1] &&
        (a.surface || 'nauvis') === surface;
    });
    // (AD3) this planet's networks map
    d.net = parseNet(data.net_maps && data.net_maps[surface]);
    d.cams = data.cams || {};
    d.box = null;
    if (core) {
      d.box = { x0: core.x0, y0: core.y0, x1: core.x0 + core.w * core.cell, y1: core.y0 + (core.h || core.rows.length) * core.cell };
      d.box.out = base ? outposts(base, d.box) : [];
    } else if (base) d.box = baseCore(base);
    else if (home && data.base && Array.isArray(data.base.core_box) && data.base.core_box.length === 4 && data.base.core_box.every(num)) {
      // (BG3) with the chart published push_live leaves out the grids and sends the core's box: the framing
      var cb = data.base.core_box;
      d.box = { x0: cb[0], y0: cb[1], x1: cb[2], y1: cb[3], out: [] };
    }
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
      else if (d.chart.some(function (c) { return c.box; })) {
        d.chart.forEach(function (c) { if (c.box) { xs.push(c.box[0], c.box[2]); ys.push(c.box[1], c.box[3]); } });
      } else if (d.chart.length) d.chart.forEach(function (c) { xs.push(c.x0, c.x0 + c.cell); ys.push(c.y0, c.y0 + c.cell); });
      else if (d.cloud) d.cloud.cells.forEach(function (x) { xs.push(x[0] * 32, x[0] * 32 + 32); ys.push(x[1] * 32, x[1] * 32 + 32); });
      if (!xs.length) return d;
      var minX = Math.min.apply(0, xs), maxX = Math.max.apply(0, xs), minY = Math.min.apply(0, ys), maxY = Math.max.apply(0, ys);
      d.auto = { cx: (minX + maxX) / 2, cy: (minY + maxY) / 2, span: Math.max(48, maxX - minX, maxY - minY) * 1.1 };
    }
    return d;
  }

  // prepare(), and when a layer's data breaks it, the view without that layer (the planet's map, then the clouds), so a
  // switch always shows the surface chosen; d.missing names what was left out (the scale line says so).
  function prepareSafe(data) {
    var drop = [['planets', 'map'], ['base', 'map'], ['clouds', 'pollution'], ['terrain', 'terrain'], ['turrets', 'turret range']];
    var tried = Object.assign({}, data), missing = [];
    for (var i = 0; ; i++) {
      try {
        var d = prepare(tried);
        d.missing = missing;
        return d;
      } catch (e) {
        if (i >= drop.length) { d = prepare({ surface: data && data.surface }); d.missing = ['everything']; return d; }
        if (tried[drop[i][0]] != null) { tried[drop[i][0]] = null; missing.push(drop[i][1]); }
      }
    }
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
  // A map point as the game's tile: "x 123, y -45 · Nauvis" (the tile's corner, as the game's own positions floor it).
  function coordsText(x, y, surface) {
    return 'x ' + Math.floor(x) + ', y ' + Math.floor(y) + ' · ' + cap(surface || 'nauvis');
  }
  // A capture's wall time as the reader's local date and time ("Oct 19, 07:47").
  function when(t) {
    var dt = new Date(t * 1000);
    try { return dt.toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }); } catch (e) { return dt.toISOString().slice(0, 16).replace('T', ' '); }
  }
  function ago(sec) {
    sec = Math.max(0, Math.round(sec));
    return sec < 60 ? sec + ' s ago' : sec < 3600 ? Math.round(sec / 60) + ' min ago' : Math.round(sec / 3600) + ' h ago';
  }
  function cap(s) { s = String(s || '').replace(/[-_]/g, ' '); return s.charAt(0).toUpperCase() + s.slice(1); }
  // (d20 batch50 D1, viewer Aurora: "Could partial map updates retain the last map with its age? Tabs sometimes disappear
  // and reset the selected planet") A push brings one planet's map, and a planet or a cloud can be missing from one:
  // every surface seen once keeps its switch and its last map (memo {planets, seen}, the viewer's own), the newer of
  // two maps by tick. data.now_tick (the state's game tick) gives each kept map's age; OLD_S and older says it.
  // (d22 batch75 AK1, viewer Aurora: "Planet buttons and network layers disappear between refreshes. Could each planet
  // keep its last valid map and overlays, with their age shown, until a replacement arrives?") data.gone (live.js: a
  // world rolled back, a planet left out of the listings for an hour) drops a surface's maps. A kept map is held
  // (heldAge) when the state lists a newer one for its planet (planet_list, net_list) or does not list it; live.js marks
  // Nauvis's basemap and the clouds it kept while a state had none (home_held, clouds_held: seconds since they came).
  // The switch, the scale line and the legend give a held map's age.
  var OLD_S = 600;
  function remember(memo, data) {
    data = data || {};
    memo.planets = memo.planets || {}; memo.seen = memo.seen || {}; memo.nets = memo.nets || {};
    (Array.isArray(data.gone) ? data.gone : []).forEach(function (k) {
      delete memo.planets[k]; delete memo.nets[k];
      if (memo.seen[k] && memo.seen[k].planet) delete memo.seen[k];
    });
    var ps = data.planets && typeof data.planets === 'object' ? data.planets : {};
    Object.keys(ps).sort().forEach(function (k) {
      var m = ps[k];
      if (k === 'nauvis' || !validGrid(m) || !m.rows.length) return;
      var old = memo.planets[k];
      if (!old || !(old.tick > m.tick)) memo.planets[k] = m;
      if (!memo.seen[k]) memo.seen[k] = { text: cap(k), planet: true };
    });
    (Array.isArray(data.clouds) ? data.clouds : []).forEach(function (c) {
      if (c && typeof c.surface === 'string' && c.surface !== 'nauvis' && !memo.seen[c.surface]) memo.seen[c.surface] = { text: c.label || cap(c.surface) };
    });
    // (BG3) every surface the published chart has: a planet by name, a platform by its own name
    var cs = data.chart && data.chart.index && data.chart.index.surfaces;
    Object.keys(cs && typeof cs === 'object' ? cs : {}).sort().forEach(function (k) {
      var row = cs[k];
      if (k === 'nauvis' || !row || !row.cells || !Object.keys(row.cells).length) return;
      if (!memo.seen[k] || !memo.seen[k].planet) memo.seen[k] = row.platform ? { text: String(row.platform), platform: true, chart: true } : { text: cap(k), planet: true, chart: true };
    });
    var seen = {};
    Object.keys(memo.seen).forEach(function (k) { seen[k] = memo.seen[k]; });
    var planets = {};
    Object.keys(memo.planets).forEach(function (k) { planets[k] = memo.planets[k]; });
    // (AD3) a push brings one planet's networks map: each kept, the newer by tick
    var nm = data.net_maps && typeof data.net_maps === 'object' ? data.net_maps : {};
    Object.keys(nm).forEach(function (k) { var m = nm[k], old = memo.nets[k]; if (m && (!old || !(old.tick > m.tick))) memo.nets[k] = m; });
    var nets = {};
    Object.keys(memo.nets).forEach(function (k) { nets[k] = memo.nets[k]; });
    return Object.assign({}, data, { planets: planets, seen: seen, net_maps: nets });
  }
  // (AK1) a kept map's age in game seconds when it is held: the state lists a newer one for its planet (list: data.planet_list
  // or data.net_list, [{surface, tick}]) or none; null when it is the newest listed, or without a listing.
  function heldAge(data, list, m, k) {
    if (!m || !Array.isArray(list)) return null;
    var row = list.filter(function (x) { return x && x.surface === k; })[0];
    if (row && !(isFinite(row.tick) && isFinite(m.tick) && m.tick < row.tick)) return null;
    var now = data.now_tick;
    return isFinite(m.tick) && isFinite(now) && now >= m.tick ? (now - m.tick) / 60 : -1;
  }
  // A kept planet map's age in game seconds (null without both ticks), and how a switch or the scale line says it.
  function mapAge(data, k) {
    var m = data && (k === 'nauvis' ? data.base : data.planets && data.planets[k]), now = data && (data.now_tick != null ? data.now_tick : null);
    return m && isFinite(m.tick) && isFinite(now) && now >= m.tick ? (now - m.tick) / 60 : null;
  }
  function ageText(sec) {
    if (sec < 60) return 'under 1 min';
    var m = Math.floor(sec / 60);
    return m >= 60 ? Math.floor(m / 60) + ' h ' + (m % 60) + ' min' : m + ' min';
  }
  // The surface switch: Nauvis, then every surface seen (planets with a map by name, then cloud-only ones), each kept
  // map OLD_S or older with its age ("Gleba · 12 min old"); [] while nothing but Nauvis is known.
  function switchList(data) {
    var seen = (data && data.seen) || {}, planets = [], clouds = [], platforms = [];
    Object.keys(seen).sort().forEach(function (k) {
      var age = mapAge(data, k), held = heldAge(data, data.planet_list, data.planets && data.planets[k], k) != null;
      var row = { surface: k, text: seen[k].text + (age != null && (age >= OLD_S || held) ? ' · ' + ageText(age) + ' old' : ''), age: age, held: held };
      (seen[k].platform ? platforms : data.planets && data.planets[k] || seen[k].chart ? planets : clouds).push(row);
    });
    platforms.forEach(function (r) { r.platform = true; });
    var others = planets.concat(clouds, platforms);
    return others.length ? [{ surface: 'nauvis', text: 'Nauvis' }].concat(others) : [];
  }

  // A train stop's name as text: rich text tags as words ("[item=iron-plate]" -> "iron plate"), at most 40 characters.
  function plainLabel(t) {
    t = String(t == null ? '' : t).replace(/\[(?:item|fluid|virtual-signal|entity|recipe|planet|space-location|quality)=([^\],]+)(?:,[^\]]*)?\]/g, function (m, n) { return n.replace(/-/g, ' '); })
      .replace(/\[\/?[a-z-]+(=[^\]]*)?\]/g, '').replace(/\s+/g, ' ').trim();
    return t.length > 40 ? t.slice(0, 39) + '…' : t;
  }
  // The chart's cell under a tile position: when its chunks were read (game time before the state's tick).
  function chartHit(d, x, y) {
    if (!d.chart || !d.chart.length) return null;
    var c = d.chart.filter(function (c) { return x >= c.x0 && x < c.x0 + c.cell && y >= c.y0 && y < c.y0 + c.cell; })[0];
    if (!c) return null;
    var a = chartAge(d, c.t0), b = chartAge(d, c.t1);
    var when = a == null ? 'read time unknown' : 'read ' + (b != null && Math.abs(a - b) >= 60 ? ago(b).replace(/ ago$/, '') + ' to ' + ago(a) : ago(a));
    return { text: 'Chart cell (' + c.cx + ', ' + c.cy + '), ' + c.n + ' chunks, ' + when };
  }
  // The cloud's chunk under a tile position: its amount, as the game's map shows it on hover.
  function cloudHit(d, x, y) {
    if (!d.cloud) return null;
    var cx = Math.floor(x / 32), cy = Math.floor(y / 32), amt = d.cloudAt[cx + ',' + cy];
    if (amt == null) return null;
    return { text: (d.cloud.pollutant === 'spores' ? 'Spores' : 'Pollution') + ' ' + amt + ' in chunk (' + cx + ', ' + cy + '), tiles ' +
      cx * 32 + '..' + (cx * 32 + 31) + ', ' + cy * 32 + '..' + (cy * 32 + 31) };
  }

  // Every mark for view {cx, cy, span} (span: tiles across the shorter side) on a W x H canvas, with layers `on`.
  // A placed library area in words and its state: bad (an open hookup or a failed check), unverified (no check,
  // stale or not run, or hookups not read) or ok (its check passed and no hookup open).
  function hookText(h) {
    if (!h) return 'hookups not read yet';
    if (h.capped) return 'hookups not read: over ' + h.capped + ' of ours in the area';
    if (h.too_big) return 'hookups not read: the area is over ' + h.too_big + ' tiles a side';
    if (h.error || h.gone) return 'hookups not read' + (h.gone ? ': its surface is gone' : '');
    if (h.n === 0) return 'nothing of ours stands there now' + (h.g ? ' but ' + h.g + ' ghost' + (h.g > 1 ? 's' : '') : '');
    var b = h.b || [], p = h.p || [], i = h.i || [], e = h.e || [], parts = [];
    var pair = function (what, j, o) { return j || o ? what + ' ' + (j || 0) + ' joined' + (o ? ', ' + o + ' open' : '') : ''; };
    [pair('belts in', b[0], b[1]), pair('belts out', b[2], b[3]), pair('pipes', p[0], p[1]), pair('inserters in', i[0], i[1]), pair('inserters out', i[2], i[3])]
      .forEach(function (t) { if (t) parts.push(t); });
    parts.push(e[0] ? 'power: ' + e[0] + ' pole' + (e[0] > 1 ? 's' : '') + ', ' + (e[1] || 0) + ' wired out' : 'power: no pole in it');
    if (e[2]) parts.push(e[2] + ' machine' + (e[2] > 1 ? 's' : '') + ' with no power');
    if (e[3]) parts.push(e[3] + ' on low power');
    if (h.g) parts.push(h.g + ' still a ghost');
    var open = (Array.isArray(h.open) ? h.open : []).map(function (o) { return o[2] + ' at (' + o[0] + ', ' + o[1] + ')'; });
    return 'hookups: ' + parts.join(', ') + (open.length ? '; open: ' + open.join('; ') : '');
  }
  function areaMark(a, now, px, py) {
    var h = a.hookups, c = a.check;
    var since = function (t) { return isFinite(now) && isFinite(t) && now >= t ? agoText((now - t) / 60) + ' ago' : 'at tick ' + t; };
    var open = h && !h.capped && !h.too_big && !h.error && !h.gone && h.n !== 0 ? (h.b ? h.b[1] + h.b[3] : 0) + (h.p ? h.p[1] : 0) + (h.i ? h.i[1] + h.i[3] : 0) + (h.e ? h.e[2] : 0) : null;
    var state = open > 0 || (c && c.state === 'fail') ? 'bad' : open === null || !c || c.state !== 'pass' ? 'unverified' : 'ok';
    var parts = ['Blueprint ' + a.name, 'placed' + (a.by ? ' by ' + a.by : '') + ' ' + since(a.tick)];
    if (a.deleted) parts.push('no library entry of that name now');
    else if (a.placed_save == null) parts.push('which save was placed: not recorded (placed before d21)');
    else parts.push(a.saved_tick > a.placed_save ? 'the entry was saved again since (' + since(a.saved_tick) + ')' : 'the entry as saved then');
    if (a.retired) parts.push('retired' + (a.retired.by ? ' by ' + a.retired.by : '') + (a.retired.reason ? ': ' + a.retired.reason : '') + (a.retired.replaced_by ? '; replaced by ' + a.retired.replaced_by : ''));
    parts.push(c ? 'check "' + (c.name || '#' + c.id) + '": ' + c.state + (isFinite(c.tick) ? ', last run ' + since(c.tick) : '') : 'no check of it');
    parts.push(hookText(h) + (h && isFinite(h.t) && !h.capped ? ' (read ' + since(h.t) + ')' : ''));
    if (a.description) parts.push(a.description);
    var x0 = px(a.box[0]), y0 = py(a.box[1]), x1 = px(a.box[2]), y1 = py(a.box[3]);
    return { x0: x0, y0: y0, x1: x1, y1: y1, name: a.name, state: state, retired: !!a.retired, text: parts.join(' · ') };
  }
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
    sc.chart = on.chart ? d.chart.filter(function (c) {
      return c.x0 + c.cell > v.cx - hw && c.x0 < v.cx + hw && c.y0 + c.cell > v.cy - hh && c.y0 < v.cy + hh;
    }).map(function (c) { return { src: c.src, labels: c.labels, x: px(c.x0), y: py(c.y0), s: c.cell * k }; }) : [];
    var charted = sc.chart.length > 0;
    sc.smooth = k < 1;  // nearest-neighbour from 1 px a tile up
    // recipe and train stop names as text over it, decluttered: stops from 0.5 px a tile, recipes from 6 (a 3-tile
    // machine 18 px), each kept only where it overlaps no label kept before it (stops first)
    sc.labels = [];
    if (charted) {
      var boxes = [], lab = function (x, y, text, kind) {
        var w = Math.min(160, text.length * (kind === 'stop' ? 6.2 : 5.4) + 6), h = kind === 'stop' ? 14 : 12, X = px(x), Y = py(y);
        if (X < -w || Y < -h || X > W + w || Y > H + h) return;
        var b = [X - w / 2, Y - h / 2, X + w / 2, Y + h / 2];
        if (boxes.some(function (o) { return b[0] < o[2] && b[2] > o[0] && b[1] < o[3] && b[3] > o[1]; })) return;
        boxes.push(b); sc.labels.push({ x: X, y: Y, text: text, kind: kind });
      };
      var files = sc.chart.map(function (c) { return d.chartLabels[c.labels]; }).filter(Boolean);
      if (k >= 0.5) files.forEach(function (f) { (f.stops || []).forEach(function (r) { if (Array.isArray(r) && num(r[0]) && num(r[1])) lab(r[0], r[1], plainLabel(r[2]), 'stop'); }); });
      if (k >= 6) files.forEach(function (f) { (f.recipes || []).forEach(function (r) { if (Array.isArray(r) && num(r[0]) && num(r[1])) lab(r[0], r[1], String(r[2] || '').replace(/-/g, ' '), 'recipe'); }); });
    }
    sc.terrain = on.terrain && !charted ? d.terrain.filter(function (t) {
      return t.x1 > v.cx - hw && t.x0 < v.cx + hw && t.y1 > v.cy - hh && t.y0 < v.cy + hh;
    }).map(function (t) { return { src: t.src, x: px(t.x0), y: py(t.y0), w: (t.x1 - t.x0) * k, h: (t.y1 - t.y0) * k, tick: t.tick, t: t.t }; }) : [];
    sc.ground = on.terrain && d.ground && !charted ? place(d.ground) : null;
    if (sc.ground) { sc.ground.pal = d.groundPal || GROUND; sc.ground.gw = d.ground.w; sc.ground.gh = d.ground.h; }
    // (AK9) on the live map (data.now; not the run pages' time-lapse), each frame OLD_TERRAIN_S or more old and not
    // under a newer frame: "terrain from 2 h ago" at its top-left corner (kept inside the map)
    var tNow = d.terrainNow;
    sc.terrainAges = sc.terrain.filter(function (t, i) {
      if (!num(tNow) || !num(t.t) || tNow - t.t < OLD_TERRAIN_S) return false;
      return !sc.terrain.slice(i + 1).some(function (u) { return u.x <= t.x + 1 && u.y <= t.y + 1 && u.x + u.w >= t.x + t.w - 1 && u.y + u.h >= t.y + t.h - 1; });
    }).map(function (t) { return { x: Math.max(6, t.x + 6), y: Math.max(16, t.y + 16), text: 'terrain from ' + ago(tNow - t.t) }; })
      .reverse().filter(function (l, i, all) {  // the newest first; none within 60 px of one kept
        return !all.slice(0, i).some(function (m) { return m.kept && Math.abs(m.x - l.x) < 60 && Math.abs(m.y - l.y) < 60; }) && (l.kept = true);
      });
    sc.ore = on.ore && d.ore && !charted ? place(d.ore) : null;
    // the cloud: each chunk in view in the pollutant's map colour, stronger where there is more (as the overlay draws it)
    sc.cloud = null;
    if (on.cloud && d.cloud) {
      var cc = d.cloud.color || {}, rgb = [cc.r, cc.g, cc.b].map(function (x) { return Math.round(255 * (x || 0)); }).join(', ');
      var ca = cc.a || 0.58, lmax = Math.log(1 + (d.cloud.max || 1));
      sc.cloud = { rgb: rgb, cells: [], reached: [] };
      d.cloud.cells.forEach(function (x) {
        if (x[0] * 32 + 32 < v.cx - hw || x[0] * 32 > v.cx + hw || x[1] * 32 + 32 < v.cy - hh || x[1] * 32 > v.cy + hh) return;
        sc.cloud.cells.push({ x: px(x[0] * 32), y: py(x[1] * 32), s: 32 * k, a: +(ca * (0.3 + 0.7 * Math.log(1 + x[2]) / lmax)).toFixed(3) });
      });
      (d.cloud.reached || []).forEach(function (n) {
        if (!ok(n) || !inView(n)) return;
        var m = { x: px(n.x), y: py(n.y) };
        sc.cloud.reached.push(m);
        sc.hits.push({ x: m.x, y: m.y, r: 8, text: 'Enemy nest the ' + (d.cloud.pollutant === 'spores' ? 'spores' : 'pollution') + ' reached' });
      });
    }
    if (on.buildings && d.base && !charted) {
      sc.base = place(d.base);
      if (d.fine) { sc.core = place(d.fine); sc.clip = { x0: px(d.box.x0), y0: py(d.box.y0), x1: px(d.box.x1), y1: py(d.box.y1) }; }
    }
    // turret range: the union of every turret's reach (artillery left out), a fill and its outline
    sc.coverage = on.coverage ? d.turrets.filter(function (t) {
      return Math.abs(t[0] - v.cx) <= hw + t[2] && Math.abs(t[1] - v.cy) <= hh + t[2];
    }).map(function (t) { return { x: px(t[0]), y: py(t[1]), r: t[2] * k }; }) : [];
    sc.ready = on.readiness && d.tstate ? d.tstate.flagged.filter(function (f) { return inView({ x: f[0], y: f[1] }); }).map(function (f) {
      var m = { x: px(f[0] + 0.5), y: py(f[1] + 0.5), st: f[2] };
      var age = f[4] != null && isFinite(f[4]) ? f[4] + d.tstate.late : null;
      sc.hits.push({ x: m.x, y: m.y, r: 6, text: turretName(f[3]) + ': ' + READY[f[2]] +
        (age == null ? (f[2] === 'u' ? ' (never read)' : '') : f[2] === 'u' ? ' (last read ' + agoText(age) + ' ago)' : ' (read ' + agoText(age) + ' ago)') });
      return m;
    }) : [];
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
    sc.threats = !on.threats ? [] : d.groups.map(function (g) {
      var at = spot(g.position), pinned = at !== g.position, t = ok(g.target) ? g.target : null;
      var m = { x: px(at.x), y: py(at.y), tx: t && !pinned ? px(t.x) : null, ty: t && !pinned ? py(t.y) : null, big: false };
      sc.hits.push({ x: m.x, y: m.y, r: 9, text: (g.label || (g.size || '?') + ' enemies on their way') + (g.age_s != null ? ' · seen ' + ago(g.age_s) : '') +
        (pinned ? ' · ' + d.dist(g.position) + ' tiles from the base' : '') });
      return m;
    }).concat(d.big.map(function (e) {
      var at = spot(e.position), pinned = at !== e.position, n = ok(e.nearest) ? e.nearest : null;
      var m = { x: px(at.x), y: py(at.y), tx: n && !pinned && e.closing ? px(n.x) : null, ty: n && !pinned && e.closing ? py(n.y) : null, big: true };
      sc.hits.push({ x: m.x, y: m.y, r: 10, text: (e.label || cap(String(e.name || 'demolisher').replace(/-/g, ' '))) +
        (e.closing ? ' · closing' + (e.eta_s != null ? ', about ' + agoText(e.eta_s) + ' away' : '') : '') });
      return m;
    }));
    sc.pins = on.alerts ? d.pins.filter(function (p) { return !d.fights.length || (p.kind !== 'attack' && p.kind !== 'loss'); }).map(function (p) {
      var at = spot(p.position), m = { x: px(at.x), y: py(at.y) };
      sc.hits.push({ x: m.x, y: m.y, r: 9, text: cap(p.kind) + ': ' + p.text });
      return m;
    }) : [];
    // (AD3) power networks: each cell some pole of a network supplies, in its colour; logistic networks: each roboport's
    // logistic area (and construction area, fainter); a picked item's sources and consumers, its gaps ringed
    sc.power = on.power && d.net && d.net.grid ? place(d.net.grid) : null;
    sc.robots = on.robots && d.net ? d.net.logistic.map(function (n) {
      var ports = n.ports.filter(function (p) { return Math.abs(p[0] - v.cx) <= hw + p[3] && Math.abs(p[1] - v.cy) <= hh + p[3]; }).map(function (p) {
        var m = { x: px(p[0]), y: py(p[1]), l: p[2] * k, c: p[3] * k };
        if (inView({ x: p[0], y: p[1] })) sc.hits.push({ x: m.x, y: m.y, r: 6, text: 'Roboport at (' + p[0] + ', ' + p[1] + '), ' + (n.id ? 'logistic network #' + n.id : 'in no logistic network') + ': ' + robotText(n) });
        return m;
      });
      return { i: n.i, ports: ports };
    }) : [];
    sc.item = [];
    var facts = on.item && d.net ? itemFacts(d.net, on.item) : null;
    if (facts) facts.marks.forEach(function (m) {
      var b = m.g.box, mk = { role: m.role, gap: m.gaps.length > 0, one: m.g.n === 1, x0: px(b[0]), y0: py(b[1]), x1: px(b[2] + 1), y1: py(b[3] + 1),
        pts: m.g.pos.map(function (p) { return [px(p[0] + 0.5), py(p[1] + 0.5)]; }) };
      sc.item.push(mk);
      mk.pts.forEach(function (q) { sc.hits.push({ x: q[0], y: q[1], r: 7, text: m.text }); });
      if (!mk.one) sc.hits.push({ x: (mk.x0 + mk.x1) / 2, y: (mk.y0 + mk.y1) / 2, r: Math.max(8, Math.min(mk.x1 - mk.x0, mk.y1 - mk.y0) / 2), text: m.text });
    });
    sc.areas = on.library ? d.areas.map(function (a) { return areaMark(a, d.now_tick, px, py); }).filter(function (m) {
      return m.x1 > 0 && m.y1 > 0 && m.x0 < W && m.y0 < H;
    }) : [];
    sc.areas.forEach(function (m) {
      sc.hits.push({ x: (m.x0 + m.x1) / 2, y: (m.y0 + m.y1) / 2, r: Math.max(10, Math.min(m.x1 - m.x0, m.y1 - m.y0) / 2), text: m.text });
    });
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
        if (!t || !ok(t.position) || t.platform || (t.surface || 'nauvis') !== d.surface || (t.dist != null && t.dist < 3)) return;
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
    // (AK9) the ground read from the game first, the frames over it (where a frame has no charted ground it is
    // transparent and the ground shows), then one dimming pass over both
    if (sc.ground) fillRuns(ctx, sc.ground, sc.ground.pal || GROUND, 1);
    (sc.chart || []).forEach(function (c) {
      var img = images && images(c.src);
      if (img) { ctx.imageSmoothingEnabled = !!sc.smooth; ctx.drawImage(img, c.x, c.y, c.s, c.s); }
    });
    ctx.imageSmoothingEnabled = true;
    var shown = sc.terrain.filter(function (t) {
      var img = images && images(t.src);
      if (img) { ctx.imageSmoothingEnabled = t.w < img.width; ctx.drawImage(img, t.x, t.y, t.w, t.h); }
      return !!img;
    });
    ctx.imageSmoothingEnabled = true;
    if (shown.length || sc.ground) {
      // terrain is the background: part of its colour taken out (a grey 'saturation' blend), then dimmed toward the
      // map's ground colour, so buildings, nests and agents stand out (and the frame's own alert icons recede);
      // composite modes rather than ctx.filter, which older Safari ignores. One path: overlapping frames dim once.
      ctx.save();
      ctx.beginPath();
      shown.forEach(function (t) { ctx.rect(t.x, t.y, t.w, t.h); });
      if (sc.ground) ctx.rect(sc.ground.x, sc.ground.y, sc.ground.gw * sc.ground.s, sc.ground.gh * sc.ground.s);
      ctx.globalCompositeOperation = 'saturation'; ctx.globalAlpha = TERRAIN_DESAT; ctx.fillStyle = '#808080'; ctx.fill();
      ctx.globalCompositeOperation = 'source-over'; ctx.globalAlpha = TERRAIN_DIM; ctx.fillStyle = C.bg; ctx.fill();
      ctx.restore();
    }
    // (AK9) an old frame's age at its corner
    (sc.terrainAges || []).forEach(function (l) {
      ctx.font = '600 10px ' + font; ctx.textAlign = 'left'; ctx.lineWidth = 3; ctx.strokeStyle = 'rgba(0, 0, 0, .75)';
      ctx.strokeText(l.text, l.x, l.y); ctx.fillStyle = 'rgba(232, 230, 225, .8)'; ctx.fillText(l.text, l.x, l.y);
    });
    ctx.strokeStyle = C.grid; ctx.lineWidth = 1; ctx.beginPath();
    sc.grid.xs.forEach(function (x) { ctx.moveTo(Math.round(x) + 0.5, 0); ctx.lineTo(Math.round(x) + 0.5, H); });
    sc.grid.ys.forEach(function (y) { ctx.moveTo(0, Math.round(y) + 0.5); ctx.lineTo(W, Math.round(y) + 0.5); });
    ctx.globalAlpha = sc.terrain.length ? 0.45 : 1; ctx.stroke(); ctx.globalAlpha = 1;
    if (sc.ore) fillRuns(ctx, sc.ore, ORE, 0.38);
    if (sc.cloud) {
      sc.cloud.cells.forEach(function (c) { ctx.fillStyle = 'rgba(' + sc.cloud.rgb + ', ' + c.a + ')'; ctx.fillRect(c.x, c.y, c.s + 0.5, c.s + 0.5); });
      sc.cloud.reached.forEach(function (n) {
        ctx.strokeStyle = '#000'; ctx.lineWidth = 3; circle(ctx, n.x, n.y, 6); ctx.stroke();
        ctx.strokeStyle = '#ff5a44'; ctx.lineWidth = 1.8; circle(ctx, n.x, n.y, 6); ctx.stroke();
      });
    }
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
    // (G1) turrets that cannot fire: red (empty), amber (no power) dots ringed in black; unknown ones a grey ring
    (sc.ready || []).forEach(function (m) {
      ctx.lineWidth = 1.2;
      if (m.st === 'u') { ctx.strokeStyle = C.unknown; circle(ctx, m.x, m.y, 3); ctx.stroke(); return; }
      ctx.fillStyle = m.st === 'e' ? C.empty : C.nopower; ctx.strokeStyle = '#000';
      circle(ctx, m.x, m.y, 3.2); ctx.fill(); ctx.stroke();
    });
    if (sc.power) fillRuns(ctx, sc.power, POWER, 0.3);
    (sc.robots || []).forEach(function (n) {
      if (!n.ports.length) return;
      ctx.fillStyle = netColour(n.i + 7, 0.05); ctx.beginPath();
      n.ports.forEach(function (p) { ctx.rect(p.x - p.c, p.y - p.c, 2 * p.c, 2 * p.c); }); ctx.fill();
      ctx.fillStyle = netColour(n.i + 7, 0.14); ctx.beginPath();
      n.ports.forEach(function (p) { ctx.rect(p.x - p.l, p.y - p.l, 2 * p.l, 2 * p.l); }); ctx.fill();
      ctx.strokeStyle = netColour(n.i + 7); ctx.lineWidth = 1.2;
      n.ports.forEach(function (p) { ctx.strokeRect(p.x - 3, p.y - 3, 6, 6); });
    });
    (sc.item || []).forEach(function (m) {
      var col = m.role === 's' ? '#6fd36f' : '#5cb8ff';
      if (!m.one) {
        ctx.setLineDash(m.gap ? [4, 3] : []); ctx.strokeStyle = m.gap ? C.red : col; ctx.lineWidth = 1.5;
        ctx.strokeRect(m.x0, m.y0, Math.max(3, m.x1 - m.x0), Math.max(3, m.y1 - m.y0)); ctx.setLineDash([]);
      }
      m.pts.forEach(function (q) {
        ctx.fillStyle = col; circle(ctx, q[0], q[1], 3.5); ctx.fill();
        ctx.strokeStyle = m.gap ? C.red : '#000'; ctx.lineWidth = m.gap ? 2 : 1; circle(ctx, q[0], q[1], m.gap ? 5.5 : 3.5); ctx.stroke();
      });
    });
    (sc.areas || []).forEach(function (m) {
      var col = m.state === 'bad' ? C.red : m.state === 'unverified' ? C.orange : '#6fd36f';
      ctx.fillStyle = m.state === 'bad' ? 'rgba(224, 78, 58, .10)' : 'rgba(255, 255, 255, .04)';
      ctx.fillRect(m.x0, m.y0, m.x1 - m.x0, m.y1 - m.y0);
      ctx.setLineDash(m.state === 'unverified' || m.retired ? [4, 3] : []); ctx.strokeStyle = col; ctx.lineWidth = 1.5;
      ctx.strokeRect(m.x0, m.y0, m.x1 - m.x0, m.y1 - m.y0); ctx.setLineDash([]);
      if (m.x1 - m.x0 > 46) {
        ctx.font = '600 10px ' + font; ctx.textAlign = 'left'; ctx.fillStyle = col;
        ctx.fillText(m.name.length > 28 ? m.name.slice(0, 27) + '…' : m.name, m.x0 + 3, Math.max(m.y0 + 11, 11));
      }
    });
    (sc.labels || []).forEach(function (l) {
      ctx.font = (l.kind === 'stop' ? '700 10.5px ' : '600 9px ') + font; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      ctx.lineWidth = 3; ctx.strokeStyle = 'rgba(0, 0, 0, .8)'; ctx.strokeText(l.text, l.x, l.y);
      ctx.fillStyle = l.kind === 'stop' ? '#ffd27a' : 'rgba(240, 238, 232, .92)'; ctx.fillText(l.text, l.x, l.y);
      ctx.textBaseline = 'alphabetic';
    });
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
    sc.threats.forEach(function (t) {
      if (t.tx != null) {
        ctx.setLineDash([5, 3]); ctx.strokeStyle = 'rgba(255, 90, 68, .8)'; ctx.lineWidth = 1.5;
        ctx.beginPath(); ctx.moveTo(t.x, t.y); ctx.lineTo(t.tx, t.ty); ctx.stroke(); ctx.setLineDash([]);
      }
      ctx.strokeStyle = '#000'; ctx.lineWidth = 1;
      if (t.big) { ctx.fillStyle = '#ff7a1a'; circle(ctx, t.x, t.y, 6); ctx.fill(); ctx.stroke(); ctx.strokeStyle = '#ff7a1a'; ctx.lineWidth = 1.5; circle(ctx, t.x, t.y, 10); ctx.stroke(); }
      else { ctx.fillStyle = '#ff5a44'; ctx.beginPath(); ctx.moveTo(t.x, t.y - 6); ctx.lineTo(t.x + 6, t.y); ctx.lineTo(t.x, t.y + 6); ctx.lineTo(t.x - 6, t.y); ctx.closePath(); ctx.fill(); ctx.stroke(); }
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
    return layer === 'chart' ? d.chart.length > 0 : layer === 'terrain' ? d.terrain.length > 0 || !!d.ground : layer === 'ore' ? !!d.ore : layer === 'buildings' ? !!d.base :
      layer === 'cloud' ? !!d.cloud : layer === 'library' ? d.areas.length > 0 :
      layer === 'power' ? !!(d.net && d.net.grid) : layer === 'robots' ? !!(d.net && d.net.logistic.length) :
      layer === 'coverage' ? d.turrets.length > 0 : layer === 'readiness' ? !!d.tstate : layer === 'nests' ? d.nests.length > 0 : layer === 'agents' ? d.agents.length + d.away.length > 0 :
      layer === 'attention' ? d.agents.some(function (a) { return a.attention && ok(a.attention.position); }) :
      layer === 'alerts' ? d.fights.length + d.pins.length > 0 : layer === 'threats' ? d.groups.length + d.big.length > 0 : false;
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
    this.view = null; this.follow = null; this.d = prepare({}); this.sc = null; this.data = {};
    this.surface = 'nauvis';  // the surface shown: Nauvis, or another with a cloud (the switch)
    this.images = {}; this.frame = 0; this.ptrs = {};
    var el = this.root = document.createElement('div');
    el.className = 'mapview';
    el.innerHTML = '<div class="mapview-layers" role="group" aria-label="Planets and map layers"></div>' +
      '<div class="mapview-stage"><canvas class="mapview-canvas" role="img" aria-label="' + esc(opts.label || 'Map of the base') + '"></canvas>' +
      '<div class="mapview-tools"><button type="button" class="fx-btn fx-btn--icon" data-mv="in" aria-label="Zoom in">+</button>' +
      '<button type="button" class="fx-btn fx-btn--icon" data-mv="out" aria-label="Zoom out">−</button>' +
      '<button type="button" class="fx-btn" data-mv="reset">Reset</button>' +
      '<button type="button" class="fx-btn" data-mv="full" aria-pressed="false">Full screen</button></div>' +
      '<div class="mapview-follow" hidden><span></span> <button type="button" class="fx-btn small" data-mv="unfollow">Stop</button></div>' +
      '<div class="mapview-tip" role="status" hidden></div><div class="mapview-coords" hidden></div></div>' +
      '<div class="mapview-legend"></div><p class="mapview-scale small"></p>';
    host.appendChild(el);
    this.canvas = el.querySelector('canvas'); this.stage = el.querySelector('.mapview-stage');
    this.tip = el.querySelector('.mapview-tip'); this.followEl = el.querySelector('.mapview-follow');
    this.coordsEl = el.querySelector('.mapview-coords');
    this.font = '"Titillium Web", system-ui, sans-serif';
    try { this.font = getComputedStyle(el).fontFamily || this.font; } catch (e) { /* default */ }
    el.addEventListener('click', function (ev) { self.onClick(ev); });
    // (AD3) the item picked: its sources and consumers on the planet shown
    this.item = null;
    el.addEventListener('change', function (ev) {
      if (ev.target && ev.target.hasAttribute && ev.target.hasAttribute('data-platform')) {
        // (BG3) a platform's chart from the picker
        if (ev.target.value) self.onClick({ target: { closest: function () { return { dataset: { surface: ev.target.value } }; } } });
        return;
      }
      if (!ev.target || !ev.target.hasAttribute || !ev.target.hasAttribute('data-item')) return;
      self.item = ev.target.value || null; self.showTip(null);
      self.renderLayers(); self.renderLegend(); self.draw();
    });
    this.canvas.addEventListener('wheel', function (ev) {
      ev.preventDefault();
      var p = self.point(ev);
      self.zoomAt(p, Math.pow(1.0015, ev.deltaY * (ev.deltaMode === 1 ? 33 : 1)));
    }, { passive: false });
    this.canvas.addEventListener('pointerdown', function (ev) { self.down(ev); });
    window.addEventListener('pointermove', function (ev) { self.move(ev); }, { passive: false });
    ['pointerup', 'pointercancel'].forEach(function (t) { window.addEventListener(t, function (ev) { self.up(ev); }); });
    this.canvas.addEventListener('pointerleave', function (ev) { if (ev.pointerType === 'mouse') { self.showTip(null); self.showCoords(null); } });
    document.addEventListener('fullscreenchange', function () { self.fullChanged(); });
    document.addEventListener('keydown', function (ev) { if (ev.key === 'Escape' && el.classList.contains('mapview--full') && !document.fullscreenElement) self.setFull(false); });
    if (window.ResizeObserver) new ResizeObserver(function () { self.draw(); }).observe(this.stage);
    else window.addEventListener('resize', function () { self.draw(); });
  }
  Viewer.prototype.set = function (data) {
    // (D1) every surface seen keeps its switch and last map: the surface shown and the view (pan, zoom) stay
    this.memo = this.memo || {};
    data = this.data = remember(this.memo, unpackData(data));
    data.chart_labels = this.labelCache = this.labelCache || {};
    if (this.surface !== 'nauvis' && !data.seen[this.surface]) this.surface = 'nauvis';
    this.d = prepareSafe(this.surface === 'nauvis' ? data : Object.assign({}, data, { surface: this.surface }));
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
    var where = this.d.surface && this.d.surface !== 'nauvis' ? ' on ' + cap(this.d.surface) : '';
    var gone = this.d.missing && this.d.missing.length ? ' · left out (unreadable): ' + this.d.missing.join(', ') : '';
    if (!this.d.auto) { cv.style.height = '0px'; this.root.querySelector('.mapview-scale').textContent = 'No positions yet' + where + '.' + gone; return; }
    if (cv.width !== Math.round(sz.w * dpr) || cv.height !== Math.round(sz.h * dpr)) { cv.width = Math.round(sz.w * dpr); cv.height = Math.round(sz.h * dpr); }
    cv.style.height = sz.h + 'px';
    var v = this.current(), t0 = Date.now();
    var ctx = cv.getContext('2d');
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    try {
      this.sc = scene(this.d, v, sz.w, sz.h, Object.assign({}, this.on, { item: this.item }));
      var follow = this.follow;
      this.sc.agents.forEach(function (a) { a.follow = a.name === follow; });
      paint(ctx, this.sc, function (src) { return self.image(src); }, this.font, function (w, h) {
        if (!self.off) self.off = document.createElement('canvas');
        if (self.off.width !== Math.round(w * dpr) || self.off.height !== Math.round(h * dpr)) { self.off.width = Math.round(w * dpr); self.off.height = Math.round(h * dpr); }
        self.off.getContext('2d').setTransform(dpr, 0, 0, dpr, 0, 0);
        return self.off;
      });
    } catch (e) {
      // never the previous surface's picture under this one's name: a blank map that says so
      ctx.clearRect(0, 0, sz.w, sz.h);
      this.sc = null;
      this.root.querySelector('.mapview-scale').textContent = 'The map' + where + ' could not be drawn (' + String(e && e.message || e).slice(0, 80) + ').';
      return;
    }
    this.root.dataset.paintMs = Date.now() - t0;  // tools/site_shots.js reads how long a frame took
    this.chartLabels();
    // (AD1) the buildings' read on every surface: Nauvis's basemap once a minute, a planet's kept map
    var age = mapAge(this.data, this.d.surface);
    var old = age == null ? '' : ' · map from ' + (age < 60 ? 'under a minute' : ageText(age)) + ' ago';
    // (AK1) the last map this page has, kept while the state brings none newer
    var held = this.d.surface === 'nauvis' ? this.data.home_held != null : heldAge(this.data, this.data.planet_list, this.data.planets[this.d.surface], this.d.surface) != null;
    if (held && this.d.base) old += ' (kept until a newer one arrives)';
    // (AK9) the terrain's age where it is older than the ground read: the newest frame drawn
    var tf = this.sc.terrain.filter(function (t) { return num(t.t); }), tn = this.d.terrainNow;
    var newest = tf.length && num(tn) ? Math.max.apply(0, tf.map(function (t) { return t.t; })) : null;
    if (newest != null && tn - newest >= OLD_TERRAIN_S) old += ' · terrain frames from ' + ago(tn - newest) + (this.d.groundAge != null ? ', ground read ' + ago(this.d.groundAge) : '');
    else if (this.sc.ground && this.d.groundAge != null) old += ' · ground read ' + ago(this.d.groundAge);
    if (this.sc.chart.length && this.d.chartOldest != null) {
      old = ' · chart: oldest cell ' + ago(this.d.chartOldest).replace(/ ago$/, '') + (this.d.chartNewest != null ? ', newest ' + ago(this.d.chartNewest).replace(/ ago$/, '') : '') +
        (this.d.base ? '' : '');
    }
    this.root.querySelector('.mapview-scale').textContent = '≈' + Math.round(v.span) + ' tiles across · grid ' + this.sc.grid.step + ' tiles' + old + gone;
    var fb = this.root.querySelector('[data-mv="reset"]');
    fb.disabled = !this.view && !this.follow;
  };
  Viewer.prototype.chartLabels = function () {
    var self = this;
    this.labelCache = this.labelCache || {};
    (this.sc && this.sc.chart || []).forEach(function (c) {
      if (self.labelCache[c.labels] !== undefined || typeof fetch !== 'function') return;
      self.labelCache[c.labels] = null;
      fetch(c.labels).then(function (r) { return r.ok ? r.json() : null; }).then(function (j) {
        if (!j) return;
        self.labelCache[c.labels] = j; self.d.chartLabels = self.labelCache; self.draw();
      }).catch(function () { /* the cell shows without its labels */ });
    });
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
  // (d22 batch75 AK3, viewer Aurora, site:4119: "Could the map separate planet tabs from layer filters? Give planets their
  // own row, group layers below (terrain, networks, combat), and keep the item filter in a consistent spot.") The planet
  // tabs in a row of their own; under them the layers in GROUPS, each under its label. A layer the viewer has had once
  // keeps its button and its spot (disabled where the surface shown has none of it), and the item picker opens the
  // Networks group on every planet (disabled where no networks map is read), so a planet switch or a push moves nothing.
  // Each layer's on/off is the viewer's (store: KEY-layers), across planet switches and reloads.
  // (d22 batch75 AK5, viewer Aurora: "compact the toolbar: Terrain + Networks in one row, Combat + Team below. Narrow the
  // item picker, use Power/Logistics labels, keep planets separate and wrap groups on small screens") the groups two to
  // a row, each label over its buttons (style.css .mapview-groups: one a row when the toolbar is narrow); the network
  // toggles say Power and Logistics, their full names (LONG) in the tooltip and the disabled reason.
  var LONG = { power: 'Power networks', robots: 'Logistic networks', chart: 'Chart: the ground, resources and buildings in the game\'s map colours' };
  // (d22 batch75 AK7, viewer Aurora site:4183: "Could you put category labels beside the buttons and tighten the gaps
  // between groups, rows and the planet selector?") each label at the left of its buttons at every width, the pairs
  // below a row each (style.css .mapview-pair)
  var PAIRS = [['terrain', 'networks'], ['combat', 'team']];
  var GROUPS = [['terrain', 'Terrain', ['chart', 'terrain', 'ore', 'buildings', 'cloud']], ['networks', 'Networks', ['power', 'robots']],
    ['combat', 'Combat', ['coverage', 'readiness', 'nests', 'threats', 'alerts']], ['team', 'Team', ['agents', 'attention', 'library']]];
  // (d22 batch75 AK10, viewer Aurora site:4283: "Could disabled map layers distinguish missing data from a real zero?
  // Vulcanus currently labels unavailable power and logistics overlays as 'none', which is easy to misread.") Why a
  // layer has nothing on the surface shown: "not read" with why (no read of it in the state, a read this page has not
  // had yet, a layer read on Nauvis only, a read that covers some surfaces only), or "none" where a read says zero.
  function absentWhy(data, d, k) {
    var where = cap(d.surface || 'nauvis'), home = d.surface === 'nauvis';
    var listed = function (list) { return Array.isArray(list) ? list.filter(function (x) { return x && x.surface === d.surface; })[0] || null : undefined; };
    var names = function (list) { return (list || []).map(function (x) { return cap(x.surface); }).join(', '); };
    if (k === 'power' || k === 'robots' || k === 'item') {
      if (d.net) {
        var age = num(d.net.tick) && d.now_tick != null ? ' (read ' + ago(Math.max(0, (d.now_tick - d.net.tick) / 60)) + ')' : '';
        return k === 'power' ? 'none: the networks map of ' + where + age + ' has no electric network'
          : k === 'robots' ? 'none: the networks map of ' + where + age + ' has no logistic network (no roboport of ours)'
          : 'none: the networks map of ' + where + age + ' has no item source or consumer';
      }
      var l = listed(data.net_list);
      if (l) return 'not read yet: a networks map of ' + where + ' is listed (game tick ' + l.tick + '); it comes with a later update';
      if (l === null) return 'not read: the game has made no networks map of ' + where + (data.net_list.length ? ' (it has: ' + names(data.net_list) + ')' : '');
      return 'not read: no networks maps in the live state yet';
    }
    if (k === 'buildings') {
      if (home) return 'not read: no base map in the live state yet';
      var pm = data.planets && data.planets[d.surface];
      if (pm && Array.isArray(pm.rows) && !pm.rows.length) return 'none: the map of ' + where + ' read shows no building of ours';
      var lp = listed(data.planet_list);
      if (lp) return 'not read yet: a map of ' + where + ' is listed; it comes with a later update';
      return 'not read: no map of ' + where + ' in the live state';
    }
    if (k === 'terrain' || k === 'ore' || k === 'coverage' || k === 'readiness' || k === 'nests' || k === 'alerts') {
      var what = { terrain: 'terrain', ore: 'ore', coverage: 'turrets', readiness: 'turret states', nests: 'nests', alerts: 'fights and alert pins' }[k];
      if (!home) return 'not read: ' + what + (k === 'terrain' || k === 'ore' ? ' is' : ' are') + ' read on Nauvis only';
      if (k === 'terrain') return 'not read: no terrain frame or charted ground in the live state yet';
      if (k === 'ore') return 'not read: no ore grid in the live state yet';
      if (k === 'readiness') return 'not read: no turret state in the live state yet';
      if (k === 'alerts') return 'none: no fight or alert pin now';
      if (!d.base) return 'not read: no base map in the live state yet';
      return k === 'coverage' ? 'none: the base read lists no turret' : 'none: the base read lists no spawner or worm near the base';
    }
    if (k === 'cloud') {
      var read = (data.clouds || []).filter(function (c) { return c && c.surface; });
      return 'not read: the last pollution read has no row for ' + where + ' (it reads the surfaces an agent is on' +
        (read.length ? '; it has: ' + read.map(function (c) { return cap(c.surface); }).join(', ') : '') + ')';
    }
    if (k === 'library') return data.library_read === false ? 'not read: no library areas in the live state yet' : 'none: no placed library area on ' + where;
    if (k === 'chart') return data.chart && data.chart.index ? 'not read: the published chart has no cell of ' + where + ' yet (the stream service draws it; the site publishes it hourly)'
      : 'not read: no chart published yet';
    if (k === 'threats') return 'none: no enemy group on its way and no demolisher near ours on ' + where + ' now (read every 2-10 s)';
    if (k === 'agents') return 'none: no agent on ' + where + ' now';
    if (k === 'attention') return 'none: no agent on ' + where + ' has an attention mark now';
    return 'none on ' + where + ' now';
  }
  Viewer.prototype.renderLayers = function () {
    var self = this, box = this.root.querySelector('.mapview-layers');
    // other surfaces with a map (another planet's buildings) or a cloud: a switch between them and Nauvis
    // (D1) every surface seen once, a kept map with its age
    var surfaces = switchList(this.data);
    var names = this.d.net ? this.d.net.names : [];
    if (this.item && names.indexOf(this.item) < 0) this.item = null;
    var had = this.had = this.had || {};
    LAYERS.forEach(function (l) { if (has(self.d, l[0])) had[l[0]] = true; });
    // what another surface has keeps its place here too: a cloud anywhere, a networks map of any planet
    if (this.d.clouds.length) had.cloud = true;
    Object.keys(this.data.net_maps || {}).forEach(function (k) {
      var n = parseNet(self.data.net_maps[k]);
      if (n) { had.item = true; if (n.grid) had.power = true; if (n.logistic.length) had.robots = true; }
    });
    var where = cap(this.d.surface || 'nauvis');
    var sig = 'item:' + (this.item || '') + ':' + names.length + ':' + (this.d.net ? this.d.net.tick : '') + '|' + LAYERS.map(function (l) { return had[l[0]] ? l[0] + (has(self.d, l[0]) ? 1 : 0) + (self.on[l[0]] ? 1 : 0) : ''; }).join(',') + '|' +
      surfaces.map(function (x) { return x.surface + x.text; }).join(',') + '|' + this.surface + (this.d.turretsCapped ? '|capped' : '') + (had.item ? '|item' : '') +
      // (AK10) a disabled layer's reason can change with nothing else (a map listed, then read)
      '|' + LAYERS.concat([['item']]).map(function (l) { return had[l[0]] && !has(self.d, l[0]) ? absentWhy(self.data, self.d, l[0]) : ''; }).join(',');
    if (box.dataset.sig === sig) return;
    box.dataset.sig = sig;
    var byKey = {}, short = {};
    LAYERS.forEach(function (l) { byKey[l[0]] = LONG[l[0]] || l[1]; short[l[0]] = l[1]; });
    var plats = surfaces.filter(function (x) { return x.platform; });
    var planets = surfaces.length ? '<div class="mapview-planets" role="group" aria-label="Planet">' + surfaces.filter(function (x) { return !x.platform; }).map(function (x) {
      return '<button type="button" class="fx-btn small mapview-surface" data-surface="' + esc(x.surface) + '" aria-pressed="' + (self.surface === x.surface ? 'true' : 'false') + '">' + esc(x.text) + '</button>';
    }).join('') + (plats.length ? '<select class="mapview-platform" data-platform aria-label="Platform"><option value="">Platform…</option>' + plats.map(function (x) {
      return '<option value="' + esc(x.surface) + '"' + (self.surface === x.surface ? ' selected' : '') + '>' + esc(x.text) + '</option>';
    }).join('') + '</select>' : '') + '</div>' : '';
    var boxes = {};
    GROUPS.forEach(function (g) { boxes[g[0]] = ''; });
    GROUPS.forEach(function (g) { boxes[g[0]] = (function () {
      var keys = g[2].filter(function (k) { return had[k]; }), item = g[0] === 'networks' && had.item;
      if (!keys.length && !item) return '';
      var buttons = keys.map(function (k) {
        var text = k === 'cloud' && self.d.cloud && self.d.cloud.pollutant === 'spores' ? 'Spores' : k === 'coverage' && self.d.turretsCapped ? 'Turret range (incomplete)' : short[k];
        var here = has(self.d, k);
        var title = here ? LONG[k] : byKey[k] + ': ' + absentWhy(self.data, self.d, k);
        return '<button type="button" class="fx-btn small mapview-layer"' + (here ? '' : ' disabled') + (title ? ' title="' + esc(title) + '"' : '') +
          ' data-layer="' + k + '" aria-pressed="' + (self.on[k] ? 'true' : 'false') + '">' + esc(text) + '</button>';
      }).join('');
      // (AK7) the narrow picker says "Item: -" where no networks map is; why, in its tooltip
      var pick = !item ? '' : '<select class="fx-select small mapview-item" data-item' + (names.length ? '' : ' disabled title="' + esc('Item: ' + absentWhy(self.data, self.d, 'item')) + '"') +
        ' aria-label="An item: its sources and consumers on this planet">' + (names.length ? '<option value="">Item: -</option>' + names.map(function (n) {
          return '<option value="' + esc(n) + '"' + (n === self.item ? ' selected' : '') + '>' + esc(cap(n) + (hasGap(self.d.net, n) ? ' · gap' : '')) + '</option>';
        }).join('') : '<option value="">Item: -</option>') + '</select>';
      return '<div class="mapview-gbox"><span class="mapview-group-label" aria-hidden="true">' + esc(g[1]) + '</span><div class="mapview-group" data-group="' + g[0] +
        '" role="group" aria-label="' + esc(g[1]) + ' layers">' + pick + buttons + '</div></div>';
    })(); });
    // (AK7) Terrain + Networks and Combat + Team each a row of their own (side by side where they fit), never paired otherwise
    var groups = PAIRS.map(function (p) {
      var inner = p.map(function (k) { return boxes[k]; }).join('');
      return inner ? '<div class="mapview-pair">' + inner + '</div>' : '';
    }).join('');
    box.innerHTML = planets + (groups ? '<div class="mapview-groups">' + groups + '</div>' : '');
  };
  Viewer.prototype.renderLegend = function () {
    var d = this.d, on = this.on, h = '';
    if (d.chart.length && on.chart) {
      h += '<li><i class="mv-chart"></i>' + esc('Chart: the ground, resources and buildings in the game\'s map colours, read from the game (' +
        d.chart.length + ' cell' + (d.chart.length > 1 ? 's' : '') + (d.chartOldest != null ? '; oldest cell ' + ago(d.chartOldest).replace(/ ago$/, '') : '') +
        (d.chartNewest != null ? ', newest ' + ago(d.chartNewest).replace(/ ago$/, '') : '') + '; the site publishes it hourly); recipe and train stop names as text') + '</li>';
    }
    if (d.terrain.length && on.terrain) h += '<li><i class="mv-terrain"></i>Terrain: the game\'s map view, ' + esc(d.terrainNote) + '</li>';
    // (AK9) the charted ground read from the game, and how fresh it is
    if (d.ground && on.terrain && d.groundPal !== GROUND) {
      h += '<li><i class="mv-terrain" style="background: ' + esc((d.groundPal[0] || [])[1] || '#555') + '"></i>' + esc('Charted ground, read from the game' +
        (d.groundChunks != null ? ' (' + d.groundChunks + ' chunks)' : '') + (d.groundAge != null ? ': newest read ' + ago(d.groundAge) : '') +
        (d.groundOldest != null && d.groundOldest > OLD_TERRAIN_S ? ', oldest ' + ago(d.groundOldest) : '')) + '</li>';
    }
    if (d.base && on.buildings) {
      var seen = {};
      [d.base, d.fine].forEach(function (g) { if (g) Object.keys(runs(g)).forEach(function (c) { seen[c] = 1; }); });
      h += BASE.filter(function (c) { return seen[c[0]]; }).map(function (c) { return '<li><i class="b-' + c[0] + '"></i>' + esc(c[2]) + '</li>'; }).join('');
    }
    if (d.ore && on.ore) {
      var ores = runs(d.ore);
      h += ORE.filter(function (c) { return ores[c[0]]; }).map(function (c) { return '<li class="ore"><i class="o-' + c[0] + '"></i>' + esc(c[2]) + '</li>'; }).join('');
    }
    if (d.cloud && on.cloud) {
      var cc = d.cloud.color || {}, rgb = [cc.r, cc.g, cc.b].map(function (x) { return Math.round(255 * (x || 0)); }).join(', ');
      h += '<li><i class="mv-cloud" style="background: linear-gradient(90deg, rgba(' + rgb + ', .2), rgba(' + rgb + ', .6))"></i>' +
        esc((d.cloud.pollutant === 'spores' ? 'Spores' : 'Pollution') + ' per chunk, up to ' + d.cloud.max +
          (this.data.clouds_held != null ? ', read ' + agoText((d.cloud.age_s || 0) + this.data.clouds_held) + ' ago (kept until a newer one arrives)' : '')) + '</li>';
      if ((d.cloud.reached || []).length) h += '<li><i class="mv-reached"></i>Nests it reached</li>';
    }
    if (d.turrets.length && on.coverage) h += '<li' + (d.turretsCapped ? ' class="mv-incomplete"' : '') + '><i class="mv-range"></i>Turret range' +
      (d.turretNote ? ' (' + esc(d.turretNote) + ')' : '') + '</li>';
    if (d.areas.length && on.library) {
      var n3 = { bad: 0, unverified: 0, ok: 0 };
      d.areas.forEach(function (a) { n3[areaMark(a, d.now_tick, function (x) { return x; }, function (y) { return y; }).state]++; });
      h += '<li><i class="mv-area" style="border: 2px solid ' + C.red + '"></i>' + esc('Blueprints: ' + n3.bad + ' with an open hookup or a failed check') + '</li>' +
        '<li><i class="mv-area" style="border: 2px dashed ' + C.orange + '"></i>' + esc(n3.unverified + ' not verified (no passing check, or hookups not read)') + '</li>' +
        '<li><i class="mv-area" style="border: 2px solid #6fd36f"></i>' + esc(n3.ok + ' check passed, every hookup joined') + '</li>';
    }
    var net = d.net, netAge = net && isFinite(d.now_tick) && isFinite(net.tick) && d.now_tick >= net.tick ? ', read ' + agoText((d.now_tick - net.tick) / 60) + ' ago' : '';
    // (AK1) the last one this page has while the state lists a newer one or none
    if (net && heldAge(this.data, this.data.net_list, this.data.net_maps[d.surface], d.surface) != null) netAge += ' (kept until a newer one arrives)';
    if (net && net.grid && on.power) {
      h += net.nets.slice(0, 6).map(function (n) {
        return '<li><i style="background: ' + netColour(NET_LETTERS.indexOf(n.letter), 0.6) + '"></i>' + esc('Electric network #' + n.id + ': ' + n.poles + ' pole' + (n.poles === 1 ? '' : 's')) + '</li>';
      }).join('') + '<li>' + esc((net.nets.length > 6 ? (net.nets.length - 6) + ' more listed' + (net.more ? ', ' : '') : '') + (net.more ? net.more + ' smaller (grey, ' + net.more_poles + ' poles)' : '') +
        (net.nets.length > 6 || net.more ? '; ' : '') + 'a cell of ' + net.grid.cell + ' tile' + (net.grid.cell === 1 ? '' : 's') + ' shows a network when some of it is in one of its poles\' supply area' + netAge +
        (net.outside ? '; ' + net.outside + ' pole' + (net.outside === 1 ? '' : 's') + ' beyond the grid' : '')) + '</li>';
    }
    if (net && net.logistic.length && on.robots) {
      h += net.logistic.slice(0, 6).map(function (n) {
        return '<li><i style="background: ' + netColour(n.i + 7, 0.35) + '; box-shadow: 0 0 0 1px ' + netColour(n.i + 7) + '"></i>' + esc(netLabel(n) + ': ' + robotText(n)) + '</li>';
      }).join('') + '<li>' + esc((net.logistic.length > 6 ? (net.logistic.length - 6) + ' more; ' : '') + 'each roboport\'s logistic area, its construction area fainter' + netAge) + '</li>';
    }
    var facts = this.item && net ? itemFacts(net, this.item) : null;
    if (facts) {
      h += '<li><i style="background: #6fd36f; border-radius: 50%"></i>Sources</li><li><i style="background: #5cb8ff; border-radius: 50%"></i>Consumers</li>' +
        '<li><i style="border: 2px solid ' + C.red + '; border-radius: 50%"></i>A gap (other network, outside every one, or no power)</li>' +
        facts.lines.map(function (t) { return '<li class="mv-item-line">' + esc(t) + '</li>'; }).join('') +
        (net.left_out ? '<li>' + esc(net.left_out + ' items not sent this time (the map\'s share of the page)') + '</li>' : '');
    }
    if (d.tstate && on.readiness) {
      var c = d.tstate.counts, n = function (k) { return +c[k] || 0; };
      h += '<li><i class="mv-ready-e"></i>Turrets: ' + esc(n('armed') + ' armed, ' + n('empty') + ' empty, ' + n('no_power') + ' no power') +
        '</li><li><i class="mv-ready-u"></i>' + esc(n('unknown') + ' unknown (not read since the last refresh, every ' + d.tstate.every + ' s; newest reading ' +
        agoText(d.tstate.late) + ' ago)' + (d.tstate.more ? '; ' + d.tstate.more + ' more not marked' : '')) + '</li>';
    }
    if (d.nests.length && on.nests) h += '<li><i class="nest"></i>Enemy nests</li>';
    if (d.fights.length && on.alerts) h += '<li><i class="mv-fight"></i>Fights</li>';
    if (d.groups.length && on.threats) h += '<li><i class="mv-group"></i>Enemies on their way (a dashed line to their target)</li>';
    if (d.big.length && on.threats) h += '<li><i class="mv-big"></i>Demolishers near ours</li>';
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
  Viewer.prototype.cloudHit = function (q) {
    return (q && this.on.cloud ? cloudHit(this.d, q.x, q.y) : null) || (q && this.on.chart ? chartHit(this.d, q.x, q.y) : null);
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
  // (d19 batch43 A4, viewer Foobator: "how can i see coordinates of my mouse cursor on the maps") the game tile under
  // the mouse, or under the last tap on a touch screen, and the surface shown, in the map's corner
  Viewer.prototype.showCoords = function (q) {
    if (!this.coordsEl) return;
    if (!q || !this.sc) { this.coordsEl.hidden = true; return; }
    this.coordsEl.textContent = coordsText(q.x, q.y, this.d.surface);
    this.coordsEl.hidden = false;
  };
  Viewer.prototype.move = function (ev) {
    var p = this.ptrs[ev.pointerId];
    if (!p) {
      if (ev.pointerType === 'mouse' && ev.target === this.canvas && this.sc) {
        var q = this.point(ev);
        this.showTip(hitAt(this.sc, q.cx, q.cy) || this.cloudHit(q) || netHit(this.d, q.x, q.y, this.on), q.cx, q.cy);
        this.showCoords(q);
      }
      return;
    }
    if (ev.pointerType === 'mouse' && this.sc) this.showCoords(this.point(ev));
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
    var q = this.point(ev), hit = hitAt(this.sc, q.cx, q.cy) || this.cloudHit(q) || netHit(this.d, q.x, q.y, this.on);
    if (hit && hit.agent) this.setFollow(hit.agent);
    this.showTip(hit, q.cx, q.cy);
    this.showCoords(q);
  };
  Viewer.prototype.onClick = function (ev) {
    var b = ev.target.closest && ev.target.closest('[data-mv],[data-layer],[data-surface]');
    if (!b) return;
    if (b.dataset.surface) {  // another surface's cloud, or back to Nauvis: a fresh view framed on it
      this.surface = b.dataset.surface; this.view = null; this.follow = null; this.followEl.hidden = true; this.showTip(null); this.showCoords(null);
      this.set(this.data);
      return;
    }
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
    prepare: prepare, areaMark: areaMark, hookText: hookText, parseNet: parseNet, itemFacts: itemFacts, netHit: netHit, unpack: unpack, unpackData: unpackData, scene: scene, hitAt: hitAt, cloudHit: cloudHit, chartHit: chartHit, chartCells: chartCells, plainLabel: plainLabel, paint: paint, runs: runs, coordsText: coordsText,
    remember: remember, switchList: switchList, mapAge: mapAge, heldAge: heldAge, OLD_S: OLD_S, GROUPS: GROUPS, absentWhy: absentWhy,
    LAYERS: LAYERS, DEFAULT_ON: DEFAULT_ON, BASE: BASE, ORE: ORE
  };
})(typeof window !== 'undefined' ? window : this);
