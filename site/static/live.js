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
    // (the joined pane already shows the YouTube lines: it stays the default; YouTube's own chat is the other tab)
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
  // One pane, both chats in time order (Luna 13:54, a viewer's suggestion): the site's comments (/v1/chat, every 4 s)
  // and the YouTube lines the stream service passed (state.youtube_chat, push_live.py), each with its source.
  var lastSeq = null, chatTimer = null, chatMsgs = [], ytLines = [];
  function joinedChat() {
    var all = chatMsgs.map(function (m) { return { src: 'site', name: m.name, text: m.text, t: m.t, k: 's' + m.seq }; })
      .concat(ytLines.map(function (m) { return { src: 'yt', name: m.name, text: m.text, t: m.t, k: 'y' + m.id }; }));
    all.sort(function (a, b) { return (a.t || 0) - (b.t || 0) || (a.k < b.k ? -1 : 1); });
    return all.slice(-150);
  }
  function renderChat() {
    if (!chatList) return;
    var all = joinedChat(), sig = all.map(function (m) { return m.k; }).join(',');
    if (chatList.dataset.sig === sig) return;  // nothing new: keep the reader's scroll
    chatList.dataset.sig = sig;
    var atEnd = chatList.scrollHeight - chatList.scrollTop - chatList.clientHeight < 40;
    chatList.innerHTML = all.length ? all.map(function (m) {
      var t = new Date(m.t * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
      return '<li class="c-' + m.src + '"><span class="c-time">' + esc(t) + '</span> <span class="c-src c-src-' + m.src + '">' +
        (m.src === 'yt' ? 'YT' : 'SITE') + '</span> <b>' + esc(m.name) + '</b> <span class="c-text">' + esc(m.text) + '</span></li>';
    }).join('') : '<li class="fx-muted">No messages yet. Say hello.</li>';
    if (atEnd || !chatList.dataset.seen) chatList.scrollTop = chatList.scrollHeight;
    chatList.dataset.seen = '1';
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

  // ------------------------------------------------------------------ the map (static/mapview.js)
  // state.basemap (tools/stream/harness.py BASEMAP_LUA, read once a minute): the coarse grid, the dense core, ore,
  // nests, turrets with their range and terrain frames; the agents with their attention; fights and alert pins. The
  // viewer is made once and kept across refreshes (its zoom, layers, follow and full screen with it).
  var CAM_SHORT = { main: 'MAIN', cam2: 'CAM 2', cam3: 'CAM 3' };
  var mapView = null;
  function mapData(s) {
    var bm = s.basemap || {};
    return { base: bm, core: bm.core, ore: bm.ore, ground: bm.terrain_grid, nests: bm.nests, turrets: bm.turrets, terrain: bm.terrain,
      agents: s.agents || [], fights: s.fights || [], pins: s.alerts || [], cams: s.cameras || {},
      clouds: s.clouds || [] };  // pollution and spores per chunk (tools/stream/clouds.py), a layer and a surface switch
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
  var ACT_LABEL = { acting: 'acting', thinking: 'thinking', idle: 'idle', dead: 'dead', offline: 'offline', resting: 'resting' };
  var ALERT_TONES = { attack: 'danger', death: 'danger', low_power: 'warn', research: 'info' };
  var ALERT_ICONS = { attack: '⚔', death: '✝', low_power: '⚡', research: '⚗' };
  // The dashboard's cards are made once; each refresh fills their bodies (the map card keeps its viewer).
  var CARDS = [['agents', 'Agents'], ['map', 'Map'], ['board', 'Board'], ['research', 'Research'], ['charts', 'Factory'], ['chat', 'Team chat']];
  function cards() {
    if ($('#cb-agents')) return;
    $('#dash').innerHTML = CARDS.map(function (c) {
      return '<section class="fx-panel live-card card-' + c[0] + '"><header class="fx-panel-title">' + esc(c[1]) + '</header><div class="card-body" id="cb-' + c[0] + '"></div></section>';
    }).join('');
    $('#cb-map').innerHTML = '<p class="map-research small" id="map-research" hidden></p><div id="mm" class="mm"></div><div id="map-cams"></div><div id="map-space"></div>';
    if (window.PogMap) mapView = window.PogMap.create($('#mm'), { storeKey: 'pog-live-map', label: 'The base and agent positions' });
  }
  function fill(sel, html) { var el = $(sel); if (el) el.innerHTML = html; }
  function renderState(s, age) {
    var agents = s.agents || [], chat = s.chat || [], r = s.research || {}, sci = s.science || {}, board = s.board || {};
    if (s.stream) embedPlayer(s.stream.youtube_video_id, s.stream.youtube_channel_id);
    ytLines = Array.isArray(s.youtube_chat) ? s.youtube_chat.filter(function (m) { return m && m.text && isFinite(m.t); }) : [];
    renderChat();
    var byName = {}; agents.forEach(function (a) { byName[a.name] = a; });
    var live = age != null && age <= LIVE_MAX_AGE;

    // status strip
    var pct = Math.round((r.progress || 0) * 100);
    var strip = '<div class="strip-item"><span class="fx-label">Game time</span><b>' + esc(s.game_time || '–') + (s.paused ? ' (paused)' : '') + '</b></div>' +
      '<div class="strip-item"><span class="fx-label">Technologies</span><b>' + esc(r.done_count != null ? r.done_count : '–') + '</b></div>' +
      '<div class="strip-item"><span class="fx-label">SPM</span><b>' + esc(sci.spm != null ? fmt(sci.spm) : '–') + '</b></div>' +
      '<div class="strip-item"><span class="fx-label">Packs made / min</span><b>' + esc((sci.made || {}).per_min != null ? fmt(sci.made.per_min) : '–') + '</b></div>' +
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
    var agentCards = agents.map(function (a) {
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
    // open projects (board kind project): owner, title and progress ("3 of 7 steps") with a bar
    var projects = (board.projects || []).map(function (p) {
      var o = byName[p.agent] || {}, pct = p.total ? Math.round(100 * p.done / p.total) : 0;
      return '<li>' + avatar(o.name ? o : { name: p.agent || p.owner || '?' }, 24) + '<div><span><b>' + esc(p.title) + '</b> ' +
        '<span class="fx-muted">' + esc(p.owner ? (o.display_name || p.owner) : 'no owner') + (p.status === 'blocked' ? ', blocked' : '') + '</span></span>' +
        '<div class="project-progress"><div class="fx-progress fx-progress--health fx-progress--thin" role="progressbar" aria-valuenow="' + pct +
        '" aria-valuemin="0" aria-valuemax="100" aria-label="' + esc(p.title) + ' progress" style="--fx-value:' + pct + '%"></div>' +
        '<span class="small">' + esc(p.progress || '') + '</span></div></div></li>';
    }).join('');
    var moreProjects = (board.projects_total || 0) - (board.projects || []).length;
    var events = (board.events || []).slice(-8).reverse().map(function (e) {
      var o = byName[e.agent] || {};
      var verb = e.verb === 'step' ? 'finished a step of' : e.verb;
      return '<li><span class="fx-muted">' + esc(o.display_name || e.by || '?') + ' ' + esc(verb) + '</span> ' + esc(e.title) +
        (e.kind ? ' <span class="fx-chip fx-chip--grey">' + esc(e.kind) + '</span>' : '') +
        (e.verb === 'step' && e.step ? ' <span class="fx-muted">' + esc(e.step) + '</span>' : '') +
        (e.kind === 'project' && e.progress ? ' <span class="fx-muted">(' + esc(e.progress) + ')</span>' : '') + '</li>';
    }).join('');
    var boardHtml = board.available === false ? '<p class="fx-muted">The board is not running in this world.</p>' :
      '<p class="board-counts"><span class="fx-chip fx-chip--orange">' + esc(board.in_progress || 0) + ' in progress</span> ' +
      '<span class="fx-chip fx-chip--grey">' + esc(board.open_unowned || 0) + ' open</span></p>' +
      (projects ? '<h4>Projects</h4><ul class="board-projects">' + projects + '</ul>' +
        (moreProjects > 0 ? '<p class="fx-muted small">+' + esc(moreProjects) + ' more</p>' : '') : '') +
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
    var sciSeries = [{ name: 'SPM', v: '--s1', values: (sci.series || []).map(Number) }];
    charts = {};
    var chartHtml = lineChart('Production', 'Items made per minute, last 30 minutes', prodSeries, 'per minute') +
      lineChart('Science', 'SPM: research units a minute (the labs\' use of packs in sets), last hour', sciSeries, 'research units per minute');

    // game chat
    var gchat = chat.slice(-12).map(function (c) {
      var a = byName[c.agent] || { name: c.agent || c.from };
      // a relayed viewer line says where the viewer wrote (Luna 13:54): "viewer Joonazan (YouTube)"
      var src = c.source ? ' <span class="fx-muted small">(' + esc(c.source) + ')</span>' : '';
      return '<li>' + avatar(a, 24) + '<span><b>' + esc(a.display_name || c.from) + '</b>' + src + ' ' + esc(c.text) + '</span></li>';
    }).join('');

    cards();
    fill('#cb-agents', '<div class="agents-live">' + (agentCards || '<p class="fx-muted">No agents.</p>') + '</div>');
    var mr = $('#map-research');
    if (mr) { mr.innerHTML = r.current ? 'Researching <strong>' + esc(r.label || label(r.current)) + '</strong> · ' + pct + '%' : ''; mr.hidden = !r.current; }
    if (mapView) mapView.set(mapData(s));
    fill('#map-cams', s.cameras ? '<h4>On camera</h4><ul class="cam-lines">' + cameraLines(s.cameras, byName) + '</ul>' : '');
    fill('#map-space', spaceInset(s.space));
    fill('#cb-board', boardHtml);
    fill('#cb-research', research);
    fill('#cb-charts', '<div class="chart-grid">' + chartHtml + '</div>');
    fill('#cb-chat', gchat ? '<ul class="game-chat">' + gchat + '</ul>' : '<p class="fx-muted">Quiet so far.</p>');
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

  // Watchers: YouTube's "watching now" (state.watching, read by the stream once a minute) and the live pages open on
  // this site (site_watching, from the heartbeat below); each part shown only when known, none while offline.
  function watchingText(s, site, live) {
    if (!live) return '';
    var yt = s && s.watching && typeof s.watching.youtube === 'number' ? s.watching.youtube : null;
    var parts = [];
    if (yt != null) parts.push(yt + ' YouTube');
    if (typeof site === 'number' && site > 0) parts.push(site + ' site');
    return parts.length ? 'Watching: ' + parts.join(' · ') : '';
  }
  function setWatching(t) { var w = $('#watching'); if (w) { w.textContent = t; w.hidden = !t; } }
  // One random id per page load (never stored), sent once a minute while the page is open.
  if (API && !demo && window.crypto && crypto.getRandomValues) {
    var hereId = Array.prototype.map.call(crypto.getRandomValues(new Uint8Array(12)), function (b) {
      return ('0' + b.toString(16)).slice(-2);
    }).join('');
    var beat = function () {
      fetch(API + '/v1/here', { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: JSON.stringify({ id: hereId }) })
        .catch(function () {});
    };
    beat();
    setInterval(beat, 60000);
  }

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
      setWatching(watchingText(s, demo ? null : d.site_watching, live || demo));
      app.classList.toggle('has-state', !!s);
      app.classList.toggle('is-live', !!live);
      $('#updated').textContent = demo ? 'Sample data from the stream service\'s mock session.' : (d.received ? 'Updated ' + ago(age) : '');
      if (!live && !offlineStatus) loadStatus();
      if (s && (s.now !== lastNow || !live)) { lastNow = s.now; renderState(s, age); }
      placeSummary(live || demo);
    }).catch(function () {
      placeSummary(false);
      setBadge('offline', 'Offline');
      setWatching('');
      $('#updated').textContent = 'Live data is unavailable right now.';
      if (!offlineStatus) loadStatus();
    }).then(function () { if (!demo) setTimeout(tick, document.hidden ? POLL * 4 : POLL); });
  }
  tick();
})();
