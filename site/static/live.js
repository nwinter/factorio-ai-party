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
  // letters, one per cell of `cell` tiles from (x0, y0). Drawn as one path per category in cell units, built once
  // per snapshot tick and placed with a transform, so a 10 s refresh only moves it.
  var BASE_CATS = [['D', 'Defence'], ['R', 'Labs'], ['O', 'Oil and chemistry'], ['A', 'Assembly'], ['S', 'Smelting'],
    ['M', 'Mining'], ['E', 'Power'], ['K', 'Storage'], ['B', 'Belts and inserters'], ['P', 'Pipes']];
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
  function minimap(agents, alerts, cams, bm, fights) {
    var pts = agents.filter(function (a) { return a.position && isFinite(a.position.x) && isFinite(a.position.y); });
    // alert pins for what the fight rings do not show (deaths, power); fights have their own markers
    var pins = (alerts || []).filter(function (a) { return a.position && isFinite(a.position.x) && (!(fights || []).length || (a.kind !== 'attack' && a.kind !== 'loss')); });
    var base = validGrid(bm) && bm.w > 0 ? bm : null, ore = base && validGrid(bm.ore) ? bm.ore : null;
    if (!pts.length && !base) return '<p class="fx-muted">No positions yet.</p>';
    // With a base, frame the base; an agent far outside it (scouting, travelling) is pinned to the edge instead of
    // shrinking the base to a dot.
    var far = {};
    if (base) {
      var bw = base.w * base.cell, bh = base.rows.length * base.cell, bcx = base.x0 + bw / 2, bcy = base.y0 + bh / 2;
      var reach = Math.max(96, bw, bh);
      pts.forEach(function (a) {
        if (Math.abs(a.position.x - bcx) > reach || Math.abs(a.position.y - bcy) > reach)
          far[a.name] = Math.round(Math.max(Math.abs(a.position.x - bcx), Math.abs(a.position.y - bcy)));
      });
    }
    var near = pts.filter(function (a) { return !(a.name in far); });
    var fpos = (fights || []).filter(function (f) { return f.position && isFinite(f.position.x) && isFinite(f.position.y); });
    var xs = near.map(function (a) { return a.position.x; }).concat(pins.map(function (p) { return p.position.x; }), fpos.map(function (f) { return f.position.x; }));
    var ys = near.map(function (a) { return a.position.y; }).concat(pins.map(function (p) { return p.position.y; }), fpos.map(function (f) { return f.position.y; }));
    if (base) {
      xs.push(base.x0, base.x0 + base.w * base.cell);
      ys.push(base.y0, base.y0 + base.rows.length * base.cell);
    }
    var minX = Math.min.apply(0, xs), maxX = Math.max.apply(0, xs), minY = Math.min.apply(0, ys), maxY = Math.max.apply(0, ys);
    var span = Math.max(64, maxX - minX, maxY - minY) * 1.25, cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
    var S = 320, k = S / span;
    var px = function (x) { return (S / 2 + (x - cx) * k).toFixed(1); }, py = function (y) { return (S / 2 + (y - cy) * k).toFixed(1); };
    var grid = '', stepT = span > 400 ? 128 : span > 160 ? 64 : 32;
    for (var gx = Math.ceil((cx - span / 2) / stepT) * stepT; gx < cx + span / 2; gx += stepT) grid += '<line x1="' + px(gx) + '" x2="' + px(gx) + '" y1="0" y2="' + S + '"/>';
    for (var gy = Math.ceil((cy - span / 2) / stepT) * stepT; gy < cy + span / 2; gy += stepT) grid += '<line y1="' + py(gy) + '" y2="' + py(gy) + '" x1="0" x2="' + S + '"/>';
    var onCam = {}; Object.keys(cams || {}).forEach(function (slot) { (cams[slot].agents || []).forEach(function (n) { onCam[n] = slot; }); });
    var layer = '', legend = '';
    var place = function (g) { return 'translate(' + px(g.x0) + ' ' + py(g.y0) + ') scale(' + (g.cell * k).toFixed(4) + ')'; };
    if (base) {
      var bp = gridPaths('base', base, BASE_CATS, 'b-', base.tick);
      var op = ore ? gridPaths('ore', ore, ORE_CATS, 'o-', base.tick) : null;
      layer = (op ? '<g class="mm-ore" transform="' + place(ore) + '">' + op.paths + '</g>' : '') +
        '<g class="mm-base" transform="' + place(base) + '">' + bp.paths + '</g>';
      layer += (Array.isArray(base.nests) ? base.nests : []).filter(function (n) { return n && isFinite(n[0]) && isFinite(n[1]); }).map(function (n) {
        return n[2] === 's' ? '<rect class="nest" x="' + (px(n[0]) - 3) + '" y="' + (py(n[1]) - 3) + '" width="6" height="6"><title>Enemy spawner</title></rect>'
          : '<circle class="worm" cx="' + px(n[0]) + '" cy="' + py(n[1]) + '" r="2.5"><title>Worm</title></circle>';
      }).join('');
      legend = '<ul class="mm-legend">' + bp.cats.map(function (c) { return '<li><i class="b-' + c[0] + '"></i>' + esc(c[1]) + '</li>'; }).join('') +
        ((base.nests || []).length ? '<li><i class="nest"></i>Enemy nests</li>' : '') + '</ul>' +
        (op && op.cats.length ? '<ul class="mm-legend mm-legend-ore">' + op.cats.map(function (c) { return '<li><i class="o-' + c[0] + '"></i>' + esc(c[1]) + '</li>'; }).join('') + '</ul>' : '');
    }
    // Pinned agents sit just inside the frame edge, on the line from the frame's centre towards them.
    var edge = function (a) {
      var dx = a.position.x - cx, dy = a.position.y - cy, lim = span / 2 - 14 / k, t = lim / Math.max(Math.abs(dx), Math.abs(dy));
      return { x: cx + dx * t, y: cy + dy * t };
    };
    // fights (state.fights, push_live.py): a ring the size of the fought-over area; solid red while it goes on
    // (reported in the last 25 s), faded after; a cross where something was destroyed
    var fightMarks = (fights || []).filter(function (f) { return f.position && isFinite(f.position.x) && isFinite(f.position.y); }).map(function (f) {
      var r = Math.max(6, (f.extent || 16) / 2 * k), now = f.age_s != null && f.age_s < 25;
      return '<g class="fight' + (now ? ' now' : '') + (f.kind === 'loss' ? ' loss' : '') + '" transform="translate(' + px(f.position.x) + ' ' + py(f.position.y) + ')">' +
        '<title>' + esc(f.text + (f.age_s != null ? ' · ' + ago(f.age_s) : '') + (f.losses ? ' · ' + f.losses + ' loss' + (f.losses > 1 ? 'es' : '') : '')) + '</title>' +
        '<circle r="' + r.toFixed(1) + '"/>' + (f.kind === 'loss' || f.losses ? '<path d="M-3 -3L3 3M3 -3L-3 3"/>' : '') + '</g>';
    }).join('');
    var marks = fightMarks + pins.map(function (p) {
      return '<g class="pin" transform="translate(' + px(p.position.x) + ' ' + py(p.position.y) + ')"><title>' + esc(label(p.kind) + ': ' + p.text) + '</title>' +
        '<path d="M0 -9 L8 6 L-8 6 Z"/><text y="4" text-anchor="middle">!</text></g>';
    }).join('');
    marks += pts.map(function (a) {
      var c = safeColor(a.color) || '#999999', isFar = a.name in far, at = isFar ? edge(a) : a.position;
      var right = isFar && px(at.x) > S * 0.6;  // labels of agents pinned on the right edge go to the left of the dot
      return '<g class="dot' + (a.alive === false ? ' dead' : '') + (isFar ? ' far' : '') + '" transform="translate(' + px(at.x) + ' ' + py(at.y) + ')">' +
        '<title>' + esc((a.display_name || a.name) + (a.location ? ' · ' + a.location : '') + (isFar ? ' · about ' + far[a.name] + ' tiles from the base' : '')) + '</title>' +
        (onCam[a.name] ? '<circle r="10" class="cam"/><text class="camtag" y="-13" text-anchor="middle">' + esc(CAM_SHORT[onCam[a.name]] || onCam[a.name]) + '</text>' : '') +
        '<circle r="5.5" style="fill:' + c + '"/>' +
        '<text x="' + (right ? -9 : 9) + '" y="4"' + (right ? ' text-anchor="end"' : '') + '>' + esc(a.display_name || a.name) + (isFar ? ' ↗' : '') + '</text></g>';
    }).join('');
    return '<svg class="minimap" viewBox="0 0 ' + S + ' ' + S + '" role="img" aria-label="' + (base ? 'The base and agent positions' : 'Agent positions') + '"><rect width="' + S + '" height="' + S + '" class="mm-bg"/>' +
      '<g class="mm-grid">' + grid + '</g>' + layer + marks + '</svg>' + legend +
      '<p class="fx-muted small">About ' + Math.round(span) + ' tiles across; grid every ' + stepT + ' tiles. Orange rings: on camera. Red rings: fights (solid while going on; × where something was destroyed). Triangles: other alerts.' +
      (base ? ' Buildings in ' + base.cell + '-tile cells' + (base.buildings != null ? ' (' + esc(base.buildings) + ' in all)' : '') +
        ', refreshed every minute' + (ore ? '; ore every five minutes' : '') + '.' : '') +
      (Object.keys(far).length ? ' Dashed: agents far from the base, shown at the edge (hover for the distance).' : '') + '</p>';
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
      return '<article class="agent-live" style="--ac:' + (safeColor(a.color) || '#999999') + '">' +
        '<header>' + avatar(a, 48) + '<div><h3>' + esc(a.display_name || a.name) + (a.camera ? ' <span class="fx-chip fx-chip--orange cam-chip">' + esc(a.camera) + '</span>' : '') + '</h3>' +
        '<p class="fx-muted small">' + esc([a.model, a.role].filter(Boolean).join(' · ')) + '</p></div>' +
        '<span class="state" data-s="' + esc(act) + '">' + esc(ACT_LABEL[act] || act) + '</span></header>' +
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

  function tick() {
    var url = demo ? '/live/state.example.json' : API + '/v1/state';
    if (!demo && !API) { setBadge('offline', 'Offline'); loadStatus(); return; }
    getJSON(url).then(function (d) {
      var s = demo ? d : d.state, age = demo ? 0 : d.age_s;
      var live = s && age != null && age <= LIVE_MAX_AGE;
      if (demo) setBadge('sample', 'Sample'); else if (live) setBadge('live', 'Live'); else setBadge('offline', 'Offline');
      app.classList.toggle('has-state', !!s);
      app.classList.toggle('is-live', !!live);
      $('#updated').textContent = demo ? 'Sample data from the stream service\'s mock session.' : (d.received ? 'Updated ' + ago(age) : '');
      if (!live && !offlineStatus) loadStatus();
      if (s && (s.now !== lastNow || !live)) { lastNow = s.now; renderState(s, age); }
    }).catch(function () {
      setBadge('offline', 'Offline');
      $('#updated').textContent = 'Live data is unavailable right now.';
      if (!offlineStatus) loadStatus();
    }).then(function () { if (!demo) setTimeout(tick, document.hidden ? POLL * 4 : POLL); });
  }
  tick();
})();
