// Live page: YouTube player and live chat, the site's own viewer chat, and a dashboard drawn from the stream state
// that the Mac pushes to the live API every ~10 s. API contract: docs/LIVE-API.md. All text from the API is escaped.
(function () {
  var app = document.getElementById('live-app');
  if (!app) return;
  var cfg = app.dataset;
  var params = new URLSearchParams(location.search);
  var demo = params.has('demo');
  var API = (cfg.api || '').replace(/\/$/, '');
  var POLL = Math.max(5, parseInt(cfg.poll, 10) || 10) * 1000;
  var LIVE_MAX_AGE = 60; // seconds: older state means the run (or the pusher) has stopped
  var $ = function (sel) { return app.querySelector(sel); };

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function safeColor(c) { return /^#[0-9a-f]{6}$/i.test(c || '') ? c : null; }
  // an agent's colour for borders and map dots on the dark panels: a near-black one (Grok's) becomes the panel's text
  // colour, so it shows (as agents.ac() does on the static pages)
  function acColor(c) {
    c = safeColor(c);
    if (!c) return '#999999';
    var n = parseInt(c.slice(1), 16), l = (0.2126 * (n >> 16) + 0.7152 * ((n >> 8) & 255) + 0.0722 * (n & 255)) / 255;
    return l < 0.15 ? 'var(--fx-text)' : c;
  }
  function label(s) { s = String(s || '').replace(/[-_]/g, ' '); return s.charAt(0).toUpperCase() + s.slice(1); }
  function ago(sec) {
    if (sec == null) return '';
    if (sec < 90) return Math.round(sec) + ' s ago';
    if (sec < 5400) return Math.round(sec / 60) + ' min ago';
    if (sec < 172800) return Math.round(sec / 3600) + ' h ago';
    return Math.round(sec / 86400) + ' days ago';
  }
  function getJSON(url) {
    return fetch(url, { cache: 'no-store' }).then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); });
  }
  function store(k, v) { try { if (v === undefined) return localStorage.getItem(k); localStorage.setItem(k, v); } catch (e) { return null; } }

  // Pixel portrait from the art kit (avatar.js); the renderer validates parts and colours and escapes the label.
  function avatar(a, size) {
    var row = { name: String(a.name || a.agent || 'agent'), display_name: a.display_name, color: safeColor(a.color), avatar: a.avatar };
    var px = size || 24;
    if (window.PogAvatar) return '<span class="fx-slot avatar' + (px <= 24 ? ' sm' : '') + '" aria-hidden="true">' + window.PogAvatar.svg(row, px, { title: '' }) + '</span>';
    return '<span class="fx-slot avatar sm letter" aria-hidden="true">' + esc((a.display_name || a.name || '?').charAt(0)) + '</span>';
  }

  // ------------------------------------------------------------------ player and chat embeds
  var player = document.getElementById('player');
  var embedded = null;
  function embedPlayer(videoId, channelId) {
    var key = videoId || channelId;
    if (!player || !key || embedded === key) return;
    embedded = key;
    var url = videoId
      ? 'https://www.youtube-nocookie.com/embed/' + encodeURIComponent(videoId) + '?autoplay=1&mute=1&playsinline=1'
      : 'https://www.youtube-nocookie.com/embed/live_stream?channel=' + encodeURIComponent(channelId) + '&autoplay=1&mute=1&playsinline=1';
    player.innerHTML = '<iframe src="' + url + '" title="Live stream" allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe>';
    embedYTChat(videoId);
  }
  var ytChat = $('[data-pane="yt"]');
  function embedYTChat(videoId) {
    if (!ytChat || !videoId) return;
    var dark = document.documentElement.dataset.theme === 'dark' ||
      (!document.documentElement.dataset.theme && window.matchMedia('(prefers-color-scheme: dark)').matches);
    // YouTube only serves the chat embed when embed_domain matches the page's host.
    ytChat.innerHTML = '<iframe class="yt-chat" title="YouTube live chat" src="https://www.youtube.com/live_chat?v=' +
      encodeURIComponent(videoId) + '&embed_domain=' + encodeURIComponent(location.hostname) + (dark ? '&dark_theme=1' : '') + '"></iframe>';
    if (!store('chatTab')) selectTab('yt');
  }

  // tabs: YouTube chat / site chat
  var tabs = app.querySelectorAll('.chat-tabs .fx-tab');
  function selectTab(name) {
    tabs.forEach(function (t) {
      var on = t.dataset.tab === name;
      t.classList.toggle('is-selected', on); t.setAttribute('aria-selected', on ? 'true' : 'false');
      app.querySelector('[data-pane="' + t.dataset.tab + '"]').hidden = !on;
    });
    if (name === 'site') pollChat();
  }
  tabs.forEach(function (t) { t.addEventListener('click', function () { selectTab(t.dataset.tab); store('chatTab', t.dataset.tab); }); });
  embedPlayer(cfg.video, cfg.channel);
  if (store('chatTab')) selectTab(store('chatTab'));

  // ------------------------------------------------------------------ site chat
  var chatList = $('#vchat'), chatForm = $('#vchat-form'), chatNote = $('#vchat-note');
  var lastSeq = null, chatTimer = null, chatMsgs = [];
  function renderChat() {
    chatList.innerHTML = chatMsgs.length ? chatMsgs.slice(-150).map(function (m) {
      var t = new Date(m.t * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
      return '<li><span class="c-time">' + esc(t) + '</span> <b>' + esc(m.name) + '</b> <span class="c-text">' + esc(m.text) + '</span></li>';
    }).join('') : '<li class="fx-muted">No messages yet. Say hello.</li>';
    chatList.scrollTop = chatList.scrollHeight;
  }
  function pollChat() {
    clearTimeout(chatTimer);
    if (!API || demo) { chatNote.textContent = demo ? 'Chat is off in the sample view.' : 'Chat is not configured.'; return; }
    var visible = !app.querySelector('[data-pane="site"]').hidden;
    getJSON(API + '/v1/chat' + (lastSeq != null ? '?after=' + lastSeq : '?limit=60')).then(function (d) {
      var hidden = {}; (d.hidden || []).forEach(function (s) { hidden[s] = 1; });
      chatMsgs = chatMsgs.filter(function (m) { return !hidden[m.seq]; }).concat(d.messages || []);
      if (d.messages && d.messages.length) lastSeq = d.messages[d.messages.length - 1].seq;
      else if (lastSeq == null) lastSeq = d.last_seq || 0;
      chatForm.hidden = d.open === false;
      if (d.open === false) chatNote.textContent = 'Chat is closed right now.';
      renderChat();
    }).catch(function () { chatNote.textContent = 'Chat is unavailable right now.'; })
      .then(function () { chatTimer = setTimeout(pollChat, document.hidden || !visible ? 20000 : 4000); });
  }
  if (chatForm) {
    var nameIn = chatForm.querySelector('[name=name]'), textIn = chatForm.querySelector('[name=text]');
    nameIn.value = store('chatName') || '';
    chatForm.addEventListener('submit', function (ev) {
      ev.preventDefault();
      if (!API || demo) return;
      var body = { name: nameIn.value.trim(), text: textIn.value.trim() };
      if (!body.text) return;
      store('chatName', body.name);
      chatNote.textContent = 'Sending…';
      fetch(API + '/v1/chat', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
        .then(function (r) { return r.json().then(function (d) { return { ok: r.ok, d: d }; }); })
        .then(function (res) {
          if (!res.ok) {
            chatNote.textContent = (res.d && res.d.error ? label(res.d.error) : 'Could not send') +
              (res.d && res.d.retry_after_s ? ' (try again in ' + res.d.retry_after_s + ' s)' : '') + '.';
            return;
          }
          textIn.value = ''; chatNote.textContent = '';
          pollChat();
        })
        .catch(function () { chatNote.textContent = 'Could not send. Check your connection.'; });
    });
  }
  if (!app.querySelector('[data-pane="site"]').hidden) pollChat();
  else if (!API || demo) pollChat();

  // ------------------------------------------------------------------ charts (inline SVG, hover readout)
  var charts = {}, chartN = 0;
  function niceMax(v) {
    if (!(v > 0)) return 1;
    var p = Math.pow(10, Math.floor(Math.log10(v))), f = v / p;
    return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 5 ? 5 : 10) * p;
  }
  function fmt(v) { return v >= 100 ? Math.round(v).toLocaleString() : (Math.round(v * 10) / 10).toLocaleString(); }
  function lineChart(title, sub, series, unit) {
    var n = series.reduce(function (m, s) { return Math.max(m, s.values.length); }, 0);
    if (n < 2) return '<figure class="chart live-chart"><figcaption><strong>' + esc(title) + '</strong><span>Waiting for data.</span></figcaption></figure>';
    var W = 560, H = 210, L = 40, T = 10, B = 24;
    var direct = series.length <= 4;
    var R = direct ? 12 + 7 * series.reduce(function (m, s) { return Math.max(m, s.name.length); }, 0) : 14;
    var pw = W - L - R, ph = H - T - B;
    var vmax = 0; series.forEach(function (s) { s.values.forEach(function (v) { if (v > vmax) vmax = v; }); });
    var ymax = niceMax(vmax * 1.05);
    var X = function (i) { return L + pw * i / (n - 1); };
    var Y = function (v) { return T + ph - ph * v / ymax; };
    var g = '';
    for (var k = 0; k <= 4; k++) {
      var yv = ymax * k / 4, yy = Y(yv).toFixed(1);
      g += '<line class="grid" x1="' + L + '" x2="' + (L + pw) + '" y1="' + yy + '" y2="' + yy + '"/>' +
        '<text class="tick" x="' + (L - 6) + '" y="' + yy + '" dy="0.32em" text-anchor="end">' + fmt(yv) + '</text>';
    }
    [n - 1, Math.round((n - 1) * 2 / 3), Math.round((n - 1) / 3), 0].forEach(function (i) {
      var m = n - 1 - i;
      g += '<text class="tick" x="' + X(i).toFixed(1) + '" y="' + (H - 6) + '" text-anchor="middle">' + (m ? '−' + m + ' min' : 'now') + '</text>';
    });
    var lines = '', ends = '';
    series.forEach(function (s) {
      var off = n - s.values.length;
      var d = s.values.map(function (v, i) { return (i ? 'L' : 'M') + X(i + off).toFixed(1) + ' ' + Y(v).toFixed(1); }).join('');
      lines += '<path class="line" d="' + d + '" style="stroke:var(' + s.v + ')"/>';
      var lv = s.values[s.values.length - 1];
      ends += '<circle class="end" cx="' + X(n - 1).toFixed(1) + '" cy="' + Y(lv).toFixed(1) + '" r="4" style="fill:var(' + s.v + ')"/>';
      if (direct) s.ly = Y(lv);
    });
    if (direct) {
      // spread end labels so they don't overlap
      var order = series.slice().sort(function (a, b) { return a.ly - b.ly; });
      for (var j = 1; j < order.length; j++) if (order[j].ly - order[j - 1].ly < 13) order[j].ly = order[j - 1].ly + 13;
      order.forEach(function (s) {
        ends += '<text class="dlabel" x="' + (L + pw + 8) + '" y="' + s.ly.toFixed(1) + '" dy="0.32em">' + esc(s.name) + '</text>';
      });
    }
    var id = 'lc' + (++chartN);
    charts[id] = { series: series, n: n, W: W, L: L, pw: pw, T: T, ph: ph, ymax: ymax, unit: unit };
    var legend = series.length > 1 ? '<ul class="legend">' + series.map(function (s) {
      return '<li><i class="swatch" style="background:var(' + s.v + ')"></i>' + esc(s.name) + '</li>';
    }).join('') + '</ul>' : '';
    var rows = '';
    for (var r = n - 1; r >= 0; r--) {
      rows += '<tr><th scope="row">' + (n - 1 - r ? '−' + (n - 1 - r) + ' min' : 'now') + '</th>' + series.map(function (s) {
        var v = s.values[r - (n - s.values.length)];
        return '<td>' + (v == null ? '–' : fmt(v)) + '</td>';
      }).join('') + '</tr>';
    }
    return '<figure class="chart live-chart" id="' + id + '"><figcaption><strong>' + esc(title) + '</strong><span>' + esc(sub) + '</span></figcaption>' + legend +
      '<div class="plot"><svg class="chart-svg" viewBox="0 0 ' + W + ' ' + H + '" role="img" aria-label="' + esc(title) + '">' + g +
      '<line class="axis" x1="' + L + '" x2="' + (L + pw) + '" y1="' + (T + ph) + '" y2="' + (T + ph) + '"/>' + lines + ends +
      '<line class="cross" y1="' + T + '" y2="' + (T + ph) + '" visibility="hidden"/>' +
      '<rect class="hit" x="' + L + '" y="' + T + '" width="' + pw + '" height="' + ph + '" fill="transparent"/></svg>' +
      '<div class="tip" hidden></div></div>' +
      '<details class="table-view"><summary>Table</summary><div class="table-wrap"><table><thead><tr><th>When</th>' +
      series.map(function (s) { return '<th>' + esc(s.name) + '</th>'; }).join('') + '</tr></thead><tbody>' + rows + '</tbody></table></div></details></figure>';
  }
  function chartHover(ev) {
    var fig = ev.target.closest && ev.target.closest('figure.live-chart');
    if (!fig || !charts[fig.id]) return;
    var c = charts[fig.id], svg = fig.querySelector('svg'), tip = fig.querySelector('.tip'), cross = fig.querySelector('.cross');
    if (ev.type === 'pointerleave' || ev.target.getAttribute('class') !== 'hit') { tip.hidden = true; cross.setAttribute('visibility', 'hidden'); return; }
    var rect = svg.getBoundingClientRect(), scale = c.W / rect.width;
    var i = Math.round(((ev.clientX - rect.left) * scale - c.L) / c.pw * (c.n - 1));
    i = Math.max(0, Math.min(c.n - 1, i));
    var sx = c.L + c.pw * i / (c.n - 1);
    cross.setAttribute('x1', sx); cross.setAttribute('x2', sx); cross.setAttribute('visibility', 'visible');
    var m = c.n - 1 - i;
    tip.innerHTML = '<div class="t-head">' + (m ? m + ' min ago' : 'now') + ' · ' + esc(c.unit) + '</div>' + c.series.map(function (s) {
      var v = s.values[i - (c.n - s.values.length)];
      return '<div class="t-row"><span><i class="swatch" style="background:var(' + s.v + ')"></i>' + esc(s.name) + '</span><b>' + (v == null ? '–' : fmt(v)) + '</b></div>';
    }).join('');
    tip.hidden = false;
    var left = sx / scale + 12;
    if (left + tip.offsetWidth > rect.width) left = sx / scale - tip.offsetWidth - 12;
    tip.style.left = Math.max(0, left) + 'px';
  }
  app.addEventListener('pointermove', chartHover);
  app.addEventListener('pointerdown', chartHover);
  app.addEventListener('pointerleave', chartHover, true);

  // ------------------------------------------------------------------ minimap of agent positions
  // The base layer (state.basemap, tools/stream/harness.py BASEMAP_LUA, read once a minute): rows of category
  // letters, one per cell of `cell` tiles from (x0, y0), for the whole base, and basemap.core: the dense core at 1-2
  // tiles a cell with each building's footprint filled. Drawn as one path per category in cell units, built once per
  // snapshot tick and placed with a transform, so a refresh or a zoom only moves it.
  var BASE_CATS = [['D', 'Defence'], ['R', 'Labs'], ['O', 'Oil and chemistry'], ['A', 'Assembly'], ['S', 'Smelting'],
    ['M', 'Mining'], ['E', 'Power'], ['L', 'Logistics'], ['K', 'Storage'], ['I', 'Inserters'], ['B', 'Belts'],
    ['T', 'Rails'], ['P', 'Pipes']];
  var LINE_CATS = { P: 1, B: 1, I: 1, T: 1 };
  // Ore under and around the base (basemap.ore, read every 5 minutes): its own grid, drawn faintly under the buildings.
  var ORE_CATS = [['i', 'Iron ore'], ['c', 'Copper ore'], ['k', 'Coal'], ['s', 'Stone'], ['o', 'Crude oil'], ['u', 'Uranium ore'], ['x', 'Other resource']];
  var pathCache = {};
  function validGrid(g) {
    return g && Array.isArray(g.rows) && g.rows.length && isFinite(g.x0) && isFinite(g.y0) && g.cell > 0;
  }
  // One <path> per letter, in cell units: a run of equal letters on a row is one rectangle.
  function gridPaths(slot, g, cats, prefix, tick) {
    var key = tick + ':' + g.cell + ':' + g.x0 + ':' + g.y0 + ':' + g.rows.length + ':' + g.rows.join('').length;
    if (pathCache[slot] && pathCache[slot].key === key) return pathCache[slot];
    var d = {};
    cats.forEach(function (c) { d[c[0]] = []; });
    g.rows.forEach(function (row, r) {
      row = String(row);
      for (var c = 0; c < row.length;) {
        var ch = row.charAt(c), n = 1;
        while (c + n < row.length && row.charAt(c + n) === ch) n++;
        if (d[ch]) d[ch].push('M' + c + ' ' + r + 'h' + n + 'v1h-' + n + 'z');
        c += n;
      }
    });
    var used = cats.filter(function (c) { return d[c[0]].length; });
    pathCache[slot] = { key: key, cats: used, paths: used.map(function (c) { return '<path class="' + prefix + c[0] + '" d="' + d[c[0]].join('') + '"/>'; }).join('') };
    return pathCache[slot];
  }
  var CAM_SHORT = { main: 'MAIN', cam2: 'CAM 2', cam3: 'CAM 3' };
  // The view: null frames the core (and the agents near it); a wheel, drag, pinch or the +/− buttons set
  // {cx, cy, span} in tiles, kept across refreshes until "Fit".
  var mmView = null, mmArgs = null, mmAuto = null;
  function minimap(agents, alerts, cams, bm, fights) {
    mmArgs = [agents, alerts, cams, bm, fights];
    return '<div id="mm" class="mm">' + drawMap() + '</div>';
  }
  function drawMap() {
    var agents = mmArgs[0], alerts = mmArgs[1], cams = mmArgs[2], bm = mmArgs[3], fights = mmArgs[4];
    var pts = agents.filter(function (a) { return a.position && isFinite(a.position.x) && isFinite(a.position.y); });
    // alert pins for what the fight rings do not show (deaths, power); fights have their own markers
    var pins = (alerts || []).filter(function (a) { return a.position && isFinite(a.position.x) && (!(fights || []).length || (a.kind !== 'attack' && a.kind !== 'loss')); });
    var base = validGrid(bm) && bm.w > 0 ? bm : null, ore = base && validGrid(bm.ore) ? bm.ore : null;
    var fine = base && validGrid(bm.core) && bm.core.w > 0 ? bm.core : null;
    if (!pts.length && !base) return '<p class="fx-muted">No positions yet.</p>';
    // Frame the base's core (basemap.core from the game, or baseCore() on the coarse grid from an older stream
    // service), so a long pipeline or a far outpost does not shrink the base; agents, alerts, fights and outposts far
    // outside it are pinned to the frame's edge (dashed, the distance in the tooltip), and the inset shows the whole.
    var far = {}, core = null, bcx = 0, bcy = 0, reach = Infinity;
    if (fine) {
      core = { x0: fine.x0, y0: fine.y0, x1: fine.x0 + fine.w * fine.cell, y1: fine.y0 + fine.h * fine.cell };
      core.out = outposts(base, core);
    } else if (base) core = baseCore(base);
    if (core) {
      bcx = (core.x0 + core.x1) / 2; bcy = (core.y0 + core.y1) / 2;
      reach = Math.max(96, core.x1 - core.x0, core.y1 - core.y0);
    }
    var dist = function (p) { return Math.round(Math.max(Math.abs(p.x - bcx), Math.abs(p.y - bcy))); };
    var isNear = function (p) { return !core || (Math.abs(p.x - bcx) <= reach && Math.abs(p.y - bcy) <= reach); };
    var fpos = (fights || []).filter(function (f) { return f.position && isFinite(f.position.x) && isFinite(f.position.y); });
    var xs = [], ys = [];
    pts.filter(function (a) { return isNear(a.position); }).map(function (a) { return a.position; })
      .concat(pins.map(function (p) { return p.position; }), fpos.map(function (f) { return f.position; }))
      .filter(isNear).forEach(function (p) { xs.push(p.x); ys.push(p.y); });
    if (core) { xs.push(core.x0, core.x1); ys.push(core.y0, core.y1); }
    var minX = Math.min.apply(0, xs), maxX = Math.max.apply(0, xs), minY = Math.min.apply(0, ys), maxY = Math.max.apply(0, ys);
    mmAuto = { cx: (minX + maxX) / 2, cy: (minY + maxY) / 2, span: Math.max(48, maxX - minX, maxY - minY) * 1.1 };
    var v = mmView || mmAuto, span = v.span, cx = v.cx, cy = v.cy;
    var S = 400, k = S / span;
    var visible = function (p) { return Math.abs(p.x - cx) <= span / 2 - 4 / k && Math.abs(p.y - cy) <= span / 2 - 4 / k; };
    pts.forEach(function (a) { if (!visible(a.position)) far[a.name] = dist(a.position); });
    var px = function (x) { return (S / 2 + (x - cx) * k).toFixed(1); }, py = function (y) { return (S / 2 + (y - cy) * k).toFixed(1); };
    var grid = '', stepT = span > 400 ? 128 : span > 160 ? 64 : span > 80 ? 32 : 16;
    for (var gx = Math.ceil((cx - span / 2) / stepT) * stepT; gx < cx + span / 2; gx += stepT) grid += '<line x1="' + px(gx) + '" x2="' + px(gx) + '" y1="0" y2="' + S + '"/>';
    for (var gy = Math.ceil((cy - span / 2) / stepT) * stepT; gy < cy + span / 2; gy += stepT) grid += '<line y1="' + py(gy) + '" y2="' + py(gy) + '" x1="0" x2="' + S + '"/>';
    var onCam = {}; Object.keys(cams || {}).forEach(function (slot) { (cams[slot].agents || []).forEach(function (n) { onCam[n] = slot; }); });
    var layer = '', legend = '', inset = '', taken = [];
    var place = function (g) { return 'translate(' + px(g.x0) + ' ' + py(g.y0) + ') scale(' + (g.cell * k).toFixed(4) + ')'; };
    if (base) {
      var bp = gridPaths('base', base, BASE_CATS, 'b-', base.tick);
      var fp = fine ? gridPaths('core', fine, BASE_CATS, 'b-', base.tick) : null;
      var op = ore ? gridPaths('ore', ore, ORE_CATS, 'o-', base.tick) : null;
      layer = op ? '<g class="mm-ore" transform="' + place(ore) + '">' + op.paths + '</g>' : '';
      if (fp) {
        // the coarse grid only outside the fine core, so the two never draw over each other
        layer += '<clipPath id="mm-out"><path clip-rule="evenodd" d="M-9999 -9999H9999V9999H-9999Z M' + px(core.x0) + ' ' + py(core.y0) +
          'H' + px(core.x1) + 'V' + py(core.y1) + 'H' + px(core.x0) + 'Z"/></clipPath>' +
          '<g clip-path="url(#mm-out)"><g class="mm-base" transform="' + place(base) + '">' + bp.paths + '</g></g>' +
          '<g class="mm-base" transform="' + place(fine) + '">' + fp.paths + '</g>';
      } else layer += '<g class="mm-base" transform="' + place(base) + '">' + bp.paths + '</g>';
      layer += (Array.isArray(base.nests) ? base.nests : []).filter(function (n) { return n && isFinite(n[0]) && isFinite(n[1]); }).map(function (n) {
        return n[2] === 's' ? '<rect class="nest" x="' + (px(n[0]) - 3) + '" y="' + (py(n[1]) - 3) + '" width="6" height="6"><title>Enemy spawner</title></rect>'
          : '<circle class="worm" cx="' + px(n[0]) + '" cy="' + py(n[1]) + '" r="2.5"><title>Worm</title></circle>';
      }).join('');
      var cats = {}; bp.cats.concat(fp ? fp.cats : []).forEach(function (c) { cats[c[0]] = 1; });
      legend = '<ul class="mm-legend">' + BASE_CATS.filter(function (c) { return cats[c[0]]; }).map(function (c) { return '<li><i class="b-' + c[0] + '"></i>' + esc(c[1]) + '</li>'; }).join('') +
        ((base.nests || []).length ? '<li><i class="nest"></i>Enemy nests</li>' : '') + '</ul>' +
        (op && op.cats.length ? '<ul class="mm-legend mm-legend-ore">' + op.cats.map(function (c) { return '<li><i class="o-' + c[0] + '"></i>' + esc(c[1]) + '</li>'; }).join('') + '</ul>' : '');
      // the whole base in a corner when the view shows only part of it: the overview grid and the view's frame
      var ew = base.w * base.cell, eh = base.rows.length * base.cell;
      if (Math.max(ew, eh) > span * 1.4) {
        var I = 104, ki = I / Math.max(ew, eh), ix = S - I - 6, iy = S - I - 6;
        var ip = function (x, y) { return [(ix + (x - base.x0) * ki), (iy + (y - base.y0) * ki)]; };
        var a0 = ip(cx - span / 2, cy - span / 2), a1 = ip(cx + span / 2, cy + span / 2);
        var vx0 = Math.max(ix, a0[0]), vy0 = Math.max(iy, a0[1]), vx1 = Math.min(ix + I, a1[0]), vy1 = Math.min(iy + I, a1[1]);
        inset = '<g class="mm-inset"><title>The whole base; the box is this view</title><rect class="mm-inset-bg" x="' + (ix - 3) + '" y="' + (iy - 3) + '" width="' + (I + 6) + '" height="' + (I + 6) + '"/>' +
          '<g class="mm-base" transform="translate(' + ix.toFixed(1) + ' ' + iy.toFixed(1) + ') scale(' + (base.cell * ki).toFixed(4) + ')">' + bp.paths + '</g>' +
          (vx1 > vx0 && vy1 > vy0 ? '<rect class="mm-inset-view" x="' + vx0.toFixed(1) + '" y="' + vy0.toFixed(1) + '" width="' + Math.max(2, vx1 - vx0).toFixed(1) + '" height="' + Math.max(2, vy1 - vy0).toFixed(1) + '"/>' : '') + '</g>';
        taken.push({ x0: ix - 3, y0: iy - 3, x1: S, y1: S });
      }
    }
    // Anything outside the view sits just inside the frame edge, on the line from the view's centre towards it.
    var edge = function (p) {
      var dx = p.x - cx, dy = p.y - cy, lim = span / 2 - 14 / k, t = lim / Math.max(Math.abs(dx), Math.abs(dy), 1e-6);
      return { x: cx + dx * t, y: cy + dy * t };
    };
    var spot = function (p) { return visible(p) ? p : edge(p); };
    // fights (state.fights, push_live.py): a ring the size of the fought-over area; solid red while it goes on
    // (reported in the last 25 s), faded after; a cross where something was destroyed
    var fightMarks = fpos.map(function (f) {
      var at = spot(f.position), pinned = at !== f.position;
      var r = pinned ? 6 : Math.max(6, (f.extent || 16) / 2 * k), now = f.age_s != null && f.age_s < 25;
      return '<g class="fight' + (now ? ' now' : '') + (f.kind === 'loss' ? ' loss' : '') + '" transform="translate(' + px(at.x) + ' ' + py(at.y) + ')">' +
        '<title>' + esc(f.text + (f.age_s != null ? ' · ' + ago(f.age_s) : '') + (f.losses ? ' · ' + f.losses + ' loss' + (f.losses > 1 ? 'es' : '') : '') +
          (pinned ? ' · about ' + dist(f.position) + ' tiles from the base' : '')) + '</title>' +
        '<circle r="' + r.toFixed(1) + '"/>' + (f.kind === 'loss' || f.losses ? '<path d="M-3 -3L3 3M3 -3L-3 3"/>' : '') + '</g>';
    }).join('');
    var marks = fightMarks + pins.map(function (p) {
      var at = spot(p.position);
      return '<g class="pin" transform="translate(' + px(at.x) + ' ' + py(at.y) + ')"><title>' + esc(label(p.kind) + ': ' + p.text) + '</title>' +
        '<path d="M0 -9 L8 6 L-8 6 Z"/><text y="4" text-anchor="middle">!</text></g>';
    }).join('');
    // outposts: building clusters outside the view, a small hollow square at the edge
    marks += (core ? core.out : []).filter(function (o) { return !visible(o); }).map(function (o) {
      var at = edge(o);
      return '<rect class="outpost" x="' + (px(at.x) - 4) + '" y="' + (py(at.y) - 4) + '" width="8" height="8"><title>Outpost: ' + o.n +
        ' building cell' + (o.n > 1 ? 's' : '') + ', about ' + dist(o) + ' tiles from the base</title></rect>';
    }).join('');
    // agents: the dot (ring and camera tag when on camera), then labels placed where they collide with nothing
    var dots = pts.map(function (a) {
      var at = a.name in far ? edge(a.position) : a.position;
      return { a: a, x: +px(at.x), y: +py(at.y), far: a.name in far };
    });
    dots.forEach(function (d) {
      taken.push({ x0: d.x - 7, y0: d.y - 7, x1: d.x + 7, y1: d.y + 7 });
      if (onCam[d.a.name]) {
        var tw = textWidth(CAM_SHORT[onCam[d.a.name]] || onCam[d.a.name], 5.4);
        taken.push({ x0: d.x - tw / 2, y0: d.y - 21, x1: d.x + tw / 2, y1: d.y - 11 });
      }
    });
    marks += dots.map(function (d) {
      var a = d.a, c = acColor(a.color), name = (a.display_name || a.name) + (d.far ? ' ↗' : '');
      var lab = placeLabel(d.x, d.y, textWidth(name, 6.3), taken, S, !!onCam[a.name]);
      return '<g class="dot' + (a.alive === false ? ' dead' : '') + (d.far ? ' far' : '') + '" transform="translate(' + d.x.toFixed(1) + ' ' + d.y.toFixed(1) + ')">' +
        '<title>' + esc((a.display_name || a.name) + (a.location ? ' · ' + a.location : '') + (d.far ? ' · about ' + far[a.name] + ' tiles from the base' : '')) + '</title>' +
        (onCam[a.name] ? '<circle r="10" class="cam"/><text class="camtag" y="-13" text-anchor="middle">' + esc(CAM_SHORT[onCam[a.name]] || onCam[a.name]) + '</text>' : '') +
        '<circle r="5.5" style="fill:' + c + '"/>' +
        (lab ? '<text x="' + lab.x + '" y="' + lab.y + '"' + (lab.anchor !== 'start' ? ' text-anchor="' + lab.anchor + '"' : '') + '>' + esc(name) + '</text>' : '') + '</g>';
    }).join('');
    var cellsNote = base ? (fine ? ' Buildings near the core in ' + fine.cell + '-tile cells (each building\'s full footprint), the rest in ' + base.cell + '-tile cells'
      : ' Buildings in ' + base.cell + '-tile cells') + (base.buildings != null ? ' (' + esc(base.buildings) + ' in all)' : '') +
      ', refreshed every minute' + (ore ? '; ore every five minutes' : '') + '.' : '';
    return '<div class="mm-frame"><svg class="minimap" viewBox="0 0 ' + S + ' ' + S + '" role="img" aria-label="' + (base ? 'The base and agent positions' : 'Agent positions') + '"><rect width="' + S + '" height="' + S + '" class="mm-bg"/>' +
      '<g class="mm-grid">' + grid + '</g>' + layer + marks + inset + '</svg>' +
      '<div class="mm-zoom"><button type="button" class="fx-btn fx-btn--icon" data-mm="in" aria-label="Zoom in">+</button>' +
      '<button type="button" class="fx-btn fx-btn--icon" data-mm="out" aria-label="Zoom out">−</button>' +
      (mmView ? '<button type="button" class="fx-btn" data-mm="fit">Fit</button>' : '') + '</div></div>' + legend +
      '<p class="fx-muted small">About ' + Math.round(span) + ' tiles across; grid every ' + stepT + ' tiles. Scroll or pinch to zoom, drag to pan. ' +
      'Orange rings: on camera. Red rings: fights (solid while going on; × where something was destroyed). Triangles: other alerts.' + cellsNote +
      (Object.keys(far).length || (core && core.out.length) ? ' Dashed dots and hollow squares: agents and outposts outside the view, shown at the edge (hover for the distance).' : '') + '</p>';
  }
  // Zoom and pan: a wheel or a pinch zooms about the pointer, a drag pans (on a phone a vertical swipe still scrolls
  // the page: the map takes only what touch-action leaves it); redrawn at most once a frame.
  var mmFrame = 0;
  function redrawMap() {
    if (mmFrame) return;
    mmFrame = requestAnimationFrame(function () {
      mmFrame = 0;
      var el = document.getElementById('mm');
      if (el && mmArgs) el.innerHTML = drawMap();
    });
  }
  function mapPoint(ev, svg) {
    var r = svg.getBoundingClientRect(), v = mmView || mmAuto;
    var fx = (ev.clientX - r.left) / r.width - 0.5, fy = (ev.clientY - r.top) / r.height - 0.5;
    return { fx: fx, fy: fy, x: v.cx + fx * v.span, y: v.cy + fy * v.span, w: r.width };
  }
  function zoomAt(p, factor) {
    var v = mmView || mmAuto, span = Math.min(4000, Math.max(24, v.span * factor));
    mmView = { span: span, cx: p.x - p.fx * span, cy: p.y - p.fy * span };
    redrawMap();
  }
  app.addEventListener('wheel', function (ev) {
    var svg = ev.target.closest && ev.target.closest('.minimap');
    if (!svg || !mmAuto) return;
    ev.preventDefault();
    zoomAt(mapPoint(ev, svg), Math.pow(1.0015, ev.deltaY * (ev.deltaMode === 1 ? 33 : 1)));
  }, { passive: false });
  app.addEventListener('click', function (ev) {
    var b = ev.target.closest && ev.target.closest('[data-mm]');
    if (!b || !mmAuto) return;
    var v = mmView || mmAuto;
    if (b.dataset.mm === 'fit') { mmView = null; redrawMap(); return; }
    zoomAt({ fx: 0, fy: 0, x: v.cx, y: v.cy }, b.dataset.mm === 'in' ? 1 / 1.5 : 1.5);
  });
  var mmPtrs = {};
  app.addEventListener('pointerdown', function (ev) {
    var svg = ev.target.closest && ev.target.closest('.minimap');
    if (!svg || !mmAuto || (ev.pointerType === 'mouse' && ev.button !== 0)) return;
    mmPtrs[ev.pointerId] = { x: ev.clientX, y: ev.clientY, svg: svg };
  });
  window.addEventListener('pointermove', function (ev) {
    var p = mmPtrs[ev.pointerId];
    if (!p) return;
    var ids = Object.keys(mmPtrs), v = mmView || mmAuto, svg = document.querySelector('#mm .minimap') || p.svg;
    var w = svg.getBoundingClientRect().width || 1;
    if (ids.length === 1) {
      mmView = { span: v.span, cx: v.cx - (ev.clientX - p.x) / w * v.span, cy: v.cy - (ev.clientY - p.y) / w * v.span };
    } else if (ids.length === 2) {
      var o = mmPtrs[ids[0] == ev.pointerId ? ids[1] : ids[0]];
      var d0 = Math.hypot(p.x - o.x, p.y - o.y) || 1, d1 = Math.hypot(ev.clientX - o.x, ev.clientY - o.y) || 1;
      var mid = mapPoint({ clientX: (ev.clientX + o.x) / 2, clientY: (ev.clientY + o.y) / 2 }, svg);
      var span = Math.min(4000, Math.max(24, v.span * d0 / d1));
      mmView = { span: span, cx: mid.x - mid.fx * span - (ev.clientX - p.x) / 2 / w * span, cy: mid.y - mid.fy * span - (ev.clientY - p.y) / 2 / w * span };
      ev.preventDefault();
    } else return;
    p.x = ev.clientX; p.y = ev.clientY;
    redrawMap();
  }, { passive: false });
  ['pointerup', 'pointercancel'].forEach(function (t) { window.addEventListener(t, function (ev) { delete mmPtrs[ev.pointerId]; }); });

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

  // The base's core from the coarse grid alone (a stream service without basemap.core): where the factory is dense.
  // Pipes, belts, inserters and rails are left out (an 84-cell pipeline to an oil outpost 400 tiles north framed the
  // base as a thin strip), the other building cells are counted in 32-tile blocks, and the core is the box around the
  // biggest connected group of blocks with at least a fifth of the busiest block's count (plus 8 tiles).
  function baseCore(g) {
    var cells = [], cell = g.cell;
    g.rows.forEach(function (row, r) {
      row = String(row);
      for (var c = 0; c < row.length; c++) {
        var ch = row.charAt(c);
        if (ch !== '.' && ch !== ' ' && !LINE_CATS[ch]) cells.push({ x: g.x0 + (c + 0.5) * cell, y: g.y0 + (r + 0.5) * cell });
      }
    });
    if (cells.length < 12) return { x0: g.x0, y0: g.y0, x1: g.x0 + g.w * cell, y1: g.y0 + g.rows.length * cell, out: [] };
    var blocks = {}, top = 0;
    cells.forEach(function (p) {
      var key = Math.floor(p.x / 32) + ',' + Math.floor(p.y / 32);
      blocks[key] = (blocks[key] || 0) + 1;
      top = Math.max(top, blocks[key]);
    });
    // dense blocks, then the biggest connected group of them (8 neighbours): a dense outpost (a far oil field) is
    // its own group and stays an outpost
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
  // A label's width in map pixels (bold 11 px Titillium: about 6.3 px a character).
  function textWidth(s, perChar) { return String(s).length * perChar + 2; }
  // Put a dot's label where it overlaps no other label, dot or camera tag: right, left, below, above; none free: no
  // label (the tooltip still names the agent). Labels stay inside the map.
  function placeLabel(x, y, w, taken, S, hasTag) {
    var tries = [{ x: 9, y: 4, anchor: 'start', b: [x + 8, y - 6, x + 8 + w, y + 6] },
      { x: -9, y: 4, anchor: 'end', b: [x - 8 - w, y - 6, x - 8, y + 6] },
      { x: 0, y: 19, anchor: 'middle', b: [x - w / 2, y + 9, x + w / 2, y + 21] }];
    if (!hasTag) tries.push({ x: 0, y: -10, anchor: 'middle', b: [x - w / 2, y - 21, x + w / 2, y - 9] });
    for (var i = 0; i < tries.length; i++) {
      var b = tries[i].b;
      if (b[0] < 0 || b[2] > S || b[1] < 0 || b[3] > S) continue;
      var hit = taken.some(function (t) { return b[0] < t.x1 && b[2] > t.x0 && b[1] < t.y1 && b[3] > t.y0; });
      if (!hit) { taken.push({ x0: b[0], y0: b[1], x1: b[2], y1: b[3] }); return tries[i]; }
    }
    return null;
  }

  // What each camera shows (state.cameras: who it follows, or the fight / work / segment shot it holds), so a viewer
  // can match the stream's three pictures to the map.
  function cameraLines(cams, byName) {
    return ['main', 'cam2', 'cam3'].filter(function (slot) { return cams && cams[slot]; }).map(function (slot) {
      var c = cams[slot], who = (c.agents || []).map(function (n) { return (byName[n] || {}).display_name || n; }).join(' & ');
      var what = c.work || c.segment || c.attack || who || 'a fixed view';
      if (c.attack && who) what = who + ' · ' + c.attack;
      return '<li><span class="fx-chip fx-chip--orange cam-chip">' + esc(CAM_SHORT[slot]) + '</span> ' + esc(what) + '</li>';
    }).join('');
  }
  // Space Age inset (state.space, push_live.py): planets reached, rockets, each platform where it is or its route.
  function spaceInset(sp) {
    if (!sp || !(sp.platforms || []).length && !(sp.planets || []).length) return '';
    var rows = (sp.platforms || []).map(function (p) {
      var bar = p.route && isFinite(p.route.pct) ? '<div class="fx-progress fx-progress--thin" style="--fx-value:' + Math.max(0, Math.min(100, p.route.pct)) + '%" role="progressbar" aria-valuenow="' +
        Math.round(p.route.pct) + '" aria-valuemin="0" aria-valuemax="100" aria-label="' + esc(p.name) + ' on its way"></div>' : '';
      // where it is, plus its state when that says more than "flying" or "waiting at a stop" (no schedule, paused...)
      var st = p.state && !/^(on_the_path|waiting_at_station|paused)$/.test(p.state) ? label(p.state).toLowerCase() : '';
      return '<li><b>' + esc(p.name) + '</b> <span>' + esc([p.where || label(p.state), st].filter(Boolean).join(' · ')) + '</span>' +
        (p.speed_kms ? ' <span class="fx-muted">' + esc(p.speed_kms) + ' km/s</span>' : '') + (p.paused ? ' <span class="fx-chip fx-chip--grey">paused</span>' : '') + bar + '</li>';
    }).join('');
    return '<div class="space-inset"><h4>Space</h4><p class="small fx-muted">' + esc([(sp.planets || []).join(', '), sp.rockets ? sp.rockets + ' rocket' + (sp.rockets > 1 ? 's' : '') + ' launched' : ''].filter(Boolean).join(' · ')) + '</p>' +
      (rows ? '<ul class="platforms">' + rows + '</ul>' : '') + '</div>';
  }

  // ------------------------------------------------------------------ dashboard
  var ACT_LABEL = { acting: 'acting', thinking: 'thinking', idle: 'idle', dead: 'dead', offline: 'offline' };
  var ALERT_TONES = { attack: 'danger', death: 'danger', low_power: 'warn', research: 'info' };
  var ALERT_ICONS = { attack: '⚔', death: '✝', low_power: '⚡', research: '⚗' };
  function card(cls, title, inner) {
    return '<section class="fx-panel live-card ' + cls + '"><header class="fx-panel-title">' + esc(title) + '</header>' + inner + '</section>';
  }
  function renderState(s, age) {
    var agents = s.agents || [], chat = s.chat || [], r = s.research || {}, sci = s.science || {}, board = s.board || {};
    if (s.stream) embedPlayer(s.stream.youtube_video_id, s.stream.youtube_channel_id);
    var byName = {}; agents.forEach(function (a) { byName[a.name] = a; });
    var live = age != null && age <= LIVE_MAX_AGE;

    // status strip
    var pct = Math.round((r.progress || 0) * 100);
    var strip = '<div class="strip-item"><span class="fx-label">Game time</span><b>' + esc(s.game_time || '–') + (s.paused ? ' (paused)' : '') + '</b></div>' +
      '<div class="strip-item"><span class="fx-label">Technologies</span><b>' + esc(r.done_count != null ? r.done_count : '–') + '</b></div>' +
      '<div class="strip-item"><span class="fx-label">Science / min</span><b>' + esc(sci.spm != null ? fmt(sci.spm) : '–') + '</b></div>' +
      '<div class="strip-item"><span class="fx-label">Stage</span><b>' + esc(sci.stage_label || '–') + '</b></div>' +
      (r.current ? '<div class="strip-item strip-research"><div class="live-research-label"><span>Researching <strong>' + esc(r.label || label(r.current)) +
        '</strong></span><span class="live-research-pct">' + pct + '%</span></div><div class="fx-progress fx-progress--research fx-progress--thin" role="progressbar" aria-valuenow="' +
        pct + '" aria-valuemin="0" aria-valuemax="100" aria-label="Research progress" style="--fx-value:' + pct + '%"></div></div>' : '');
    $('#strip').innerHTML = strip;
    $('#run-title').textContent = s.title || 'Live run';
    $('#run-sub').textContent = (s.subtitle || '') + (live ? '' : (age != null ? ' · last update ' + ago(age) : ''));
    renderShift(s.shift, live, s.now);

    var alerts = (s.alerts || []).slice(-3).reverse().map(function (a) {
      var tone = ALERT_TONES[a.kind] ? ' fx-alert--' + ALERT_TONES[a.kind] : '';
      return '<li class="fx-alert' + tone + '"><span class="fx-slot fx-slot--sm" aria-hidden="true">' + (ALERT_ICONS[a.kind] || '!') + '</span>' +
        '<div><div class="fx-alert-title">' + esc(label(a.kind || 'alert')) + '</div>' + esc(a.text) + '</div></li>';
    }).join('');
    $('#alerts').innerHTML = alerts;

    // agents
    var cards = agents.map(function (a) {
      var mine = chat.filter(function (c) { return c.agent === a.name; }).slice(-2);
      var act = a.activity || (a.alive === false ? 'dead' : 'idle');
      var said = mine.map(function (c) { return '<li>' + esc(c.text) + '</li>'; }).join('');
      return '<article class="agent-live" style="--ac:' + acColor(a.color) + '">' +
        '<header>' + avatar(a, 48) + '<div><h3>' + esc(a.display_name || a.name) + (a.camera ? ' <span class="fx-chip fx-chip--orange cam-chip">' + esc(a.camera) + '</span>' : '') + '</h3>' +
        '<p class="fx-muted small">' + esc([a.model, a.role].filter(Boolean).join(' · ')) + '</p></div>' +
        '<span class="state" data-s="' + esc(act) + '">' + esc(ACT_LABEL[act] || act) + '</span></header>' +
        // its current job: its team-plan line, else its notes.md "## Now" (tools/stream/model.py job)
        (a.job ? '<p class="agent-job">' + esc(a.job) + '</p>' : '') +
        '<p class="agent-doing">' + esc(a.action || (act === 'thinking' ? 'thinking…' : '–')) + (a.location ? ' <span class="fx-muted">at ' + esc(a.location) + '</span>' : '') + '</p>' +
        (said ? '<ul class="agent-said">' + said + '</ul>' : '') + '</article>';
    }).join('');

    // board
    var claims = (board.claims || []).map(function (c) {
      var o = byName[c.agent] || {};
      return '<li>' + avatar(o.name ? o : { name: c.agent || c.owner }, 24) + '<span><b>' + esc(o.display_name || c.owner || '?') + '</b> ' + esc(c.title) + '</span></li>';
    }).join('');
    var events = (board.events || []).slice(-8).reverse().map(function (e) {
      var o = byName[e.agent] || {};
      return '<li><span class="fx-muted">' + esc(o.display_name || e.by || '?') + ' ' + esc(e.verb) + '</span> ' + esc(e.title) +
        (e.kind ? ' <span class="fx-chip fx-chip--grey">' + esc(e.kind) + '</span>' : '') + '</li>';
    }).join('');
    var boardHtml = board.available === false ? '<p class="fx-muted">The board is not running in this world.</p>' :
      '<p class="board-counts"><span class="fx-chip fx-chip--orange">' + esc(board.in_progress || 0) + ' in progress</span> ' +
      '<span class="fx-chip fx-chip--grey">' + esc(board.open_unowned || 0) + ' open</span></p>' +
      (claims ? '<h4>Who owns what</h4><ul class="board-claims">' + claims + '</ul>' : '') +
      (events ? '<h4>Recent</h4><ul class="board-events">' + events + '</ul>' : '');

    // research
    var recent = (r.recent || []).map(function (t) { return '<li>' + esc(t.label || label(t.name)) + '</li>'; }).join('');
    var research = r.current ? '<div class="live-research-label"><span><strong>' + esc(r.label || label(r.current)) + '</strong></span><span class="live-research-pct">' + pct + '%</span></div>' +
      '<div class="fx-progress fx-progress--research" style="--fx-value:' + pct + '%" role="progressbar" aria-valuenow="' + pct + '" aria-valuemin="0" aria-valuemax="100" aria-label="Research progress"></div>' : '<p class="fx-muted">Nothing being researched.</p>';
    research += '<p class="small">' + esc(r.done_count || 0) + ' technologies done</p>' + (recent ? '<h4>Latest</h4><ol class="research-recent">' + recent + '</ol>' : '');

    // charts
    var prodSeries = (s.production || []).slice(0, 4).map(function (p, i) {
      return { name: label(p.item), v: '--s' + (i + 1), values: (p.series || []).map(Number) };
    });
    var sciSeries = [{ name: 'Science packs', v: '--s1', values: (sci.series || []).map(Number) }];
    charts = {};
    var chartHtml = lineChart('Production', 'Items made per minute, last 30 minutes', prodSeries, 'per minute') +
      lineChart('Science', 'All science packs per minute, last 30 minutes', sciSeries, 'packs per minute');

    // game chat
    var gchat = chat.slice(-12).map(function (c) {
      var a = byName[c.agent] || { name: c.agent || c.from };
      return '<li>' + avatar(a, 24) + '<span><b>' + esc(a.display_name || c.from) + '</b> ' + esc(c.text) + '</span></li>';
    }).join('');

    $('#dash').innerHTML =
      card('card-agents', 'Agents', '<div class="agents-live">' + (cards || '<p class="fx-muted">No agents.</p>') + '</div>') +
      card('card-map', 'Map',
        (r.current ? '<p class="map-research small">Researching <strong>' + esc(r.label || label(r.current)) + '</strong> · ' + pct + '%</p>' : '') +
        minimap(agents, s.alerts, s.cameras, s.basemap, s.fights) +
        (s.cameras ? '<h4>On camera</h4><ul class="cam-lines">' + cameraLines(s.cameras, byName) + '</ul>' : '') +
        spaceInset(s.space)) +
      card('card-board', 'Board', boardHtml) +
      card('card-research', 'Research', research) +
      card('card-charts', 'Factory', '<div class="chart-grid">' + chartHtml + '</div>') +
      card('card-chat', 'Team chat', gchat ? '<ul class="game-chat">' + gchat + '</ul>' : '<p class="fx-muted">Quiet so far.</p>');
    app.classList.toggle('is-stale', !live);
  }

  // When this shift ends, or when the next starts (state.shift from start-team.sh: start, end, next, next_exact), in
  // the visitor's own time zone. Between shifts the line says when to come back.
  function clock(t) { return new Date(t * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }); }
  function shiftText(sh, live, nowS) {
    if (!sh || !isFinite(sh.end)) return '';
    nowS = Date.now() / 1000;
    if (live && sh.end > nowS) return 'This shift runs until ' + clock(sh.end) + ' (' + ago(sh.end - nowS).replace(' ago', '') + ' left).';
    if (sh.next == null) return 'The last shift ended at ' + clock(sh.end) + '. No next shift is scheduled yet.';
    if (sh.next > nowS + 60) return 'Next shift ' + (sh.next_exact ? 'starts at ' : 'expected around ') + clock(sh.next) +
      ' (in ' + ago(sh.next - nowS).replace(' ago', '') + '). The last one ended at ' + clock(Math.min(sh.end, nowS)) + '.';
    return 'The next shift should start any minute now; the page goes live by itself.';
  }
  function renderShift(sh, live) {
    var p = $('#next-shift');
    if (!p) return;
    var t = shiftText(sh, live);
    p.textContent = t;
    p.hidden = !t;
  }

  // ------------------------------------------------------------------ state polling and offline status
  var badge = $('#live-badge'), lastNow = null;
  var TONES = { live: 'red', sample: 'orange', offline: 'grey' };
  function setBadge(state, text) { badge.className = 'fx-chip fx-chip--' + TONES[state]; badge.textContent = text; }

  function renderOffline(st) {
    var h = '';
    if (st && st.message) h += '<p>' + esc(st.message) + '</p>';
    if (st && st.next && st.next.title) h += '<p><strong>Next:</strong> ' + esc(st.next.title) + (st.next.when ? ' · ' + esc(new Date(st.next.when).toLocaleString()) : '') + '</p>';
    if (st && st.last_run && /^\/[\w\/-]*$/.test(st.last_run.url || '')) h += '<p>Latest run: <a href="' + st.last_run.url + '">' + esc(st.last_run.title) + '</a></p>';
    h += '<p class="fx-muted small"><a href="?demo=1">See the dashboard with sample data</a>.</p>';
    $('#offline').innerHTML = h;
  }
  var offlineStatus = null;
  function loadStatus() {
    getJSON(cfg.status).then(function (st) {
      offlineStatus = st;
      if (st.stream) embedPlayer(st.stream.youtube_video_id, st.stream.youtube_channel_id);
      renderOffline(st);
    }).catch(function () { renderOffline(null); });
  }

  // The homepage's run summary (#run-summary, built at shift changes): right under the heading while no shift is live,
  // after the live show while one is.
  function placeSummary(live) {
    var sum = document.getElementById('run-summary'), head = app.querySelector('.live-head-row');
    if (!sum || !head) return;
    if (live) { if (sum.previousElementSibling !== app) app.parentNode.insertBefore(sum, app.nextSibling); }
    else if (sum.previousElementSibling !== head) head.parentNode.insertBefore(sum, head.nextSibling);
  }
  function tick() {
    var url = demo ? '/live/state.example.json' : API + '/v1/state';
    if (!demo && !API) { setBadge('offline', 'Offline'); placeSummary(false); loadStatus(); return; }
    getJSON(url).then(function (d) {
      var s = demo ? d : d.state, age = demo ? 0 : d.age_s;
      var live = s && age != null && age <= LIVE_MAX_AGE;
      if (demo) setBadge('sample', 'Sample'); else if (live) setBadge('live', 'Live'); else setBadge('offline', 'Offline');
      app.classList.toggle('has-state', !!s);
      app.classList.toggle('is-live', !!live);
      $('#updated').textContent = demo ? 'Sample data from the stream service\'s mock session.' : (d.received ? 'Updated ' + ago(age) : '');
      if (!live && !offlineStatus) loadStatus();
      if (s && (s.now !== lastNow || !live)) { lastNow = s.now; renderState(s, age); }
      placeSummary(live || demo);
    }).catch(function () {
      placeSummary(false);
      setBadge('offline', 'Offline');
      $('#updated').textContent = 'Live data is unavailable right now.';
      if (!offlineStatus) loadStatus();
    }).then(function () { if (!demo) setTimeout(tick, document.hidden ? POLL * 4 : POLL); });
  }
  tick();
})();
