/* The shift player on /videos/shift-N/ (site/videos_page.py, batch270; from tools/archive/player/index.html).
   The video is the shift's HLS rendition on R2 (hls.js where the browser has no HLS of its own), beside its timeline
   (shift.json from tools/archive/r2_shifts.py: on air, events, voiced lines, chat, stats, parts). The page's
   <script id="pl-data" type="application/json"> holds the URLs, the shift's timeline rows (with their /timeline/
   anchors) and the planets in the order the run reached them. Captions start off (the video has them burned in).
   PogPlayer.step is the event jump, exported for site/test_videos_page.py. */
(function () {
  'use strict';
  var LEAD = 3;  // seconds of video before an event a jump lands on

  // The event to jump to from wall time ref: the first one more than half a second after it (dir 1) or the last one
  // more than half a second before it (dir -1). Events at the same second count as one.
  function pick(events, ref, dir) {
    var i;
    if (dir > 0) {
      for (i = 0; i < events.length; i++) if (events[i].t > ref + 0.5) return events[i];
    } else {
      for (i = events.length - 1; i >= 0; i--) if (events[i].t < ref - 0.5) return events[i];
    }
    return null;
  }
  // One press of next (1) or previous (-1) at wall time now. cursor: the event the last jump went to; while the
  // playhead is still around it (from the lead-in to 5 s after) the jump counts from that event, so a second press
  // goes on to the one after it (a jump lands LEAD s early, before its own event: counting from the playhead found
  // the same event again). Returns {t, seek, cursor} or null at either end.
  function step(events, now, cursor, dir, lead) {
    lead = lead == null ? LEAD : lead;
    var ref = cursor && now >= cursor.t - lead - 1 && now <= cursor.t + 5 ? cursor.t : now;
    var e = pick(events, ref, dir);
    return e ? { t: e.t, seek: e.t - lead, cursor: { t: e.t } } : null;
  }
  var PogPlayer = { pick: pick, step: step, LEAD: LEAD };
  if (typeof module !== 'undefined' && module.exports) module.exports = PogPlayer;
  if (typeof document === 'undefined') return;
  window.PogPlayer = PogPlayer;

  var cfgEl = document.getElementById('pl-data');
  if (!cfgEl) return;
  var CFG = JSON.parse(cfgEl.textContent);
  var COLORS = { astra: '#4aa3ff', sol: '#f2c94c', luna: '#b07cff', opus: '#ff8c42', sonnet: '#5b8def',
    haiku: '#3cc6b5', grok: '#d9a441', gemini: '#6fa8ff', muse: '#4cd06a' };
  var SHOTS = { '@platform': 'Platform shot', '@attack': 'Attack shot', '@incoming': 'Incoming attack',
    '@segment': 'Host segment', '@map': 'Base map', '@replay': 'Replay', '@fallback': 'Planet view (the platform was lost)' };
  var DANGER = { battle: 1, loss: 1, death: 1, platform_lost: 1 };
  var PROGRESS = { research: 1, rocket: 1, arrival: 1, platform_created: 1, platform_deleted: 1, maiden: 1, segment: 1 };
  var $ = function (id) { return document.getElementById(id); };
  var video = $('pl-video');
  var D = null, span = 1, events = [], cursor = null, icons = {}, sparks = [];

  var fmtWall = function (t) { return new Date(t * 1000).toLocaleTimeString('en-US', { timeZone: 'America/Los_Angeles', hour: '2-digit', minute: '2-digit', hour12: false }); };
  var fmtRel = function (s) { s = Math.max(0, Math.floor(s)); var h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), x = s % 60; return (h ? h + ':' + String(m).padStart(2, '0') : m) + ':' + String(x).padStart(2, '0'); };
  var pct = function (t) { return Math.max(0, Math.min(100, (t - D.t0) / span * 100)) + '%'; };
  var esc = function (s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); };
  var nameOf = function (s) { return s ? s.charAt(0).toUpperCase() + s.slice(1) : s; };
  var colorOf = function (who) { return COLORS[(who || '').toLowerCase().split(' ')[0]] || 'var(--muted)'; };
  var num = function (v) { return v == null ? '–' : typeof v === 'number' ? v.toLocaleString('en-US') : v; };
  // a whole shift from several recordings: parts = [[video s, wall t, seconds, name]] back to back
  var toWall = function (v) {
    if (!D.parts) return D.t0 + v;
    var p = D.parts[0];
    D.parts.forEach(function (x) { if (x[0] <= v) p = x; });
    return p[1] + Math.min(v - p[0], p[2]);
  };
  var toVideo = function (t) {
    if (!D.parts) return t - D.t0;
    for (var i = 0; i < D.parts.length; i++) { var p = D.parts[i]; if (t < p[1] + p[2]) return p[0] + Math.max(0, t - p[1]); }
    var l = D.parts[D.parts.length - 1];
    return l[0] + l[2];
  };
  var now = function () { return toWall(video.currentTime || 0); };
  // a game tick to wall time, through the score rows (every 2 minutes)
  var tickWall = function (tick) {
    var r = D.stats, ti = D.stats_cols.indexOf('tick');
    if (!r.length || ti < 0) return null;
    if (tick <= r[0][ti]) return r[0][0];
    for (var i = 1; i < r.length; i++) {
      if (tick <= r[i][ti]) { var a = r[i - 1], b = r[i]; return a[0] + (b[0] - a[0]) * (tick - a[ti]) / Math.max(1, b[ti] - a[ti]); }
    }
    return r[r.length - 1][0];
  };
  // the game's icons (site/static/game/index.json; Graphics copyright Wube Software): a name, a level without its own
  // picture falls back to the level below or the base name (site/gameicons.py key)
  function iconKey(kind, name) {
    var have = icons[kind] || {};
    name = String(name || '').trim().toLowerCase().replace(/ /g, '-');
    if (have[name]) return name;
    var m = /^(.*?)-(\d+)$/.exec(name);
    if (m) {
      for (var k = Math.min(+m[2], 20); k > 0; k--) if (have[m[1] + '-' + k]) return m[1] + '-' + k;
      if (have[m[1]]) return m[1];
    }
    return null;
  }
  function icon(kind, name, size) {
    var k = iconKey(kind, name);
    return k ? '<img class="gi" src="/static/game/' + kind + '/' + k + '.webp" width="' + (size || 20) + '" height="' + (size || 20) + '" alt="">' : '';
  }

  function lane(name, build) {
    var row = document.createElement('div');
    row.className = 'pl-lane';
    row.innerHTML = '<span class="pl-lname">' + name + '</span><div class="pl-track"></div>';
    build(row.querySelector('.pl-track'));
    $('pl-lanes').appendChild(row);
  }
  function el(cls, style, tip) {
    var d = document.createElement('div');
    d.className = cls;
    Object.keys(style).forEach(function (k) { d.style[k] = style[k]; });
    if (tip) d.dataset.tip = tip;
    return d;
  }
  function buildLanes() {
    lane('On air', function (tr) {
      D.onair.forEach(function (r) {
        var a = r[0], b = r[1], subj = r[3], reason = r[4], agent = subj.charAt(0) !== '@';
        var st = { left: pct(Math.max(a, D.t0)), width: (Math.min(b, D.t1) - Math.max(a, D.t0)) / span * 100 + '%' };
        if (agent) st.background = colorOf(subj);
        tr.appendChild(el('pl-band' + (subj === '@replay' ? ' replay' : agent ? '' : ' shot'), st,
          fmtWall(a) + ' ' + (agent ? nameOf(subj) : SHOTS[subj] || subj) + ': ' + reason));
      });
    });
    var marks = function (kinds, color) {
      return function (tr) {
        events.forEach(function (e) {
          if (!kinds[e.kind]) return;
          var big = e.kind === 'death' || e.kind === 'platform_lost' || e.kind === 'maiden' || (e.score || 0) >= 3;
          tr.appendChild(el('pl-mark' + (big ? ' big' : ''), { left: pct(e.t), background: color }, fmtWall(e.t) + ' ' + e.title));
        });
      };
    };
    lane('Danger', marks(DANGER, 'var(--bad)'));
    lane('Progress', marks(PROGRESS, 'var(--good)'));
    lane('Chat', function (tr) {
      D.chat.forEach(function (c) {
        if (c.t < D.t0) return;
        tr.appendChild(el('pl-tick', { left: pct(c.t), background: c.kind === 'agent' ? colorOf(c.who) : 'var(--s1)' },
          fmtWall(c.t) + ' ' + (c.kind === 'agent' ? nameOf(c.who) : c.who) + ': ' + c.text.slice(0, 120)));
      });
    });
    lane('Voices', function (tr) {
      D.lines.forEach(function (l) {
        var bg = l.channel === 'agent' ? colorOf(l.agent || l.who) : 'var(--muted)';
        tr.appendChild(el('pl-voice', { left: pct(Math.max(l.t, D.t0)), width: Math.max(0.3, l.dur / span * 100) + '%', background: bg },
          fmtWall(l.t) + ' ' + l.who + ': ' + (l.text || '').slice(0, 140)));
      });
    });
    var ph = el('pl-playhead', { left: '0%' });
    ph.id = 'pl-playhead';
    $('pl-lanes').appendChild(ph);
  }

  // a small line chart of one stats column over the shift, with the playhead; a click seeks
  function spark(col, label, fmt) {
    var ci = D.stats_cols.indexOf(col);
    if (ci < 0) return '';
    var pts = D.stats.filter(function (r) { return r[ci] != null && typeof r[ci] === 'number'; }).map(function (r) { return [r[0], r[ci]]; });
    if (pts.length < 2) return '';
    var lo = Math.min.apply(null, pts.map(function (p) { return p[1]; })), hi = Math.max.apply(null, pts.map(function (p) { return p[1]; }));
    if (hi === lo) hi = lo + 1;
    var W = 200, H = 34, d = pts.map(function (p, i) {
      return (i ? 'L' : 'M') + ((p[0] - D.t0) / span * W).toFixed(1) + ' ' + (H - 3 - (p[1] - lo) / (hi - lo) * (H - 6)).toFixed(1);
    }).join('');
    sparks.push(col);
    return '<figure class="pl-spark" data-col="' + col + '" title="' + esc(label) + ' over the shift: ' + esc(fmt(lo)) + ' to ' + esc(fmt(hi)) + '. Click to jump.">' +
      '<svg viewBox="0 0 ' + W + ' ' + H + '" preserveAspectRatio="none" aria-hidden="true"><path d="' + d + '" fill="none" stroke="currentColor" stroke-width="1.6" vector-effect="non-scaling-stroke"/>' +
      '<line class="pl-sparkhead" x1="0" x2="0" y1="0" y2="' + H + '" vector-effect="non-scaling-stroke"/></svg>' +
      '<figcaption class="sr-only">' + esc(label) + ' from ' + esc(fmt(lo)) + ' to ' + esc(fmt(hi)) + '</figcaption></figure>';
  }

  function statsCard() {
    var c = function (k) { return D.stats_cols.indexOf(k); };
    var rows = [
      ['rockets', 'Rockets', icon('item', 'rocket-part', 22), function (v) { return num(v); }],
      ['research', 'Technologies', icon('item', 'lab', 22), function (v) { return num(v); }],
      ['spm', 'Science per minute', icon('item', 'automation-science-pack', 22), function (v) { return v == null ? '–' : Math.round(v).toLocaleString('en-US'); }],
      ['packs_per_min', 'Packs made per minute', icon('item', 'space-science-pack', 22), function (v) { return v == null ? '–' : Math.round(v).toLocaleString('en-US'); }]
    ].filter(function (r) { return c(r[0]) >= 0; });
    $('pl-stats').innerHTML = rows.map(function (r) {
      return '<div class="pl-stat" data-col="' + r[0] + '">' + r[2] + '<div class="pl-stat-body"><span class="pl-stat-label">' + r[1] +
        '</span><b class="pl-stat-val">–</b><span class="pl-stat-delta muted"></span></div>' + spark(r[0], r[1], r[3]) + '</div>';
    }).join('') +
      '<div class="pl-stat pl-research"><div class="pl-stat-body"><span class="pl-stat-label">Researching</span><span id="pl-researching">–</span></div></div>' +
      '<div class="pl-stat"><div class="pl-stat-body"><span class="pl-stat-label">Planets reached</span><span id="pl-planets">–</span></div></div>' +
      '<div class="pl-stat"><div class="pl-stat-body"><span class="pl-stat-label">Space platforms</span><span id="pl-plat">–</span></div></div>' +
      '<div class="pl-stat"><div class="pl-stat-body"><span class="pl-stat-label">Agent deaths this shift</span><span id="pl-deaths">–</span></div></div>';
    $('pl-stats').addEventListener('click', function (ev) {
      var f = ev.target.closest('.pl-spark');
      if (!f) return;
      var r = f.getBoundingClientRect();
      seekWall(D.t0 + (ev.clientX - r.left) / r.width * span);
    });
    $('pl-stats').__fmt = rows.reduce(function (m, r) { m[r[0]] = r[3]; return m; }, {});
  }

  // the shift's timeline rows (research, rockets, platforms, planets, deaths): a jump into the video and a link to
  // the row on /timeline/
  function eventsCard() {
    var rows = (CFG.timeline || []).map(function (r) { return { tick: r[0], kind: r[1], text: r[2], anchor: r[3], who: r[4], t: tickWall(r[0]) }; })
      .filter(function (r) { return r.t != null; });
    if (!rows.length) { $('pl-events-card').hidden = true; return; }
    var ICON = { research: function (r) { return icon('tech', r.name || r.text, 20) || icon('item', 'lab', 20); },
      rocket: function () { return icon('item', 'rocket-part', 20); }, platform: function () { return icon('item', 'space-platform-hub', 20); },
      planet: function (r) { return icon('place', (r.text.split(' ').pop() || '').toLowerCase(), 20); },
      death: function (r) { return r.who ? '<img class="gi pl-av" src="/static/avatars/' + esc(r.who) + '.svg" width="20" height="20" alt="">' : ''; } };
    $('pl-events').innerHTML = rows.map(function (r, i) {
      return '<li data-t="' + r.t + '" data-i="' + i + '"><button type="button" class="pl-ev-go" title="Jump to ' + esc(fmtWall(r.t)) + '">' +
        '<span class="pl-ev-time">' + fmtWall(r.t) + '</span>' + (ICON[r.kind] ? ICON[r.kind](r) : '') + '<span>' + esc(r.text) + '</span></button>' +
        (r.anchor != null ? '<a class="pl-ev-tl" href="/timeline/#e' + r.anchor + '" title="On the timeline">timeline</a>' : '') + '</li>';
    }).join('');
    $('pl-events').addEventListener('click', function (ev) {
      var b = ev.target.closest('.pl-ev-go');
      if (b) seekWall(+b.parentNode.dataset.t - LEAD);
    });
    $('pl-events-n').textContent = rows.length;
  }

  function at(rows, t) { var r = null; for (var i = 0; i < rows.length; i++) { if (rows[i][0] <= t) r = rows[i]; else break; } return r; }

  var lastRender = 0;
  function render() {
    if (!D) return;
    var t = now();
    $('pl-clock').textContent = fmtWall(t) + ' Pacific · ' + fmtRel(video.currentTime || 0) + ' into the video';
    var track = document.querySelector('.pl-lane .pl-track');
    if (track) $('pl-playhead').style.left = 'calc(' + track.offsetLeft + 'px + ' + (t - D.t0) / span + ' * (100% - ' + track.offsetLeft + 'px))';
    var x = ((t - D.t0) / span * 200).toFixed(1);
    document.querySelectorAll('.pl-sparkhead').forEach(function (l) { l.setAttribute('x1', x); l.setAttribute('x2', x); });
    var on = null;
    for (var i = 0; i < D.onair.length; i++) if (D.onair[i][0] <= t && t < D.onair[i][1]) { on = D.onair[i]; break; }
    if (on) {
      var subj = on[3], agent = subj.charAt(0) !== '@';
      $('pl-onair').innerHTML = '<span class="pl-dot" style="background:' + (agent ? colorOf(subj) : subj === '@replay' ? 'var(--bad)' : 'var(--muted)') + '"></span>' +
        esc(agent ? nameOf(subj) : SHOTS[subj] || subj.slice(1));
      $('pl-onair-why').textContent = on[4] + (on[5] ? ' · ' + nameOf(on[5][0]) + ' (' + Math.round(on[5][1]) + ', ' + Math.round(on[5][2]) + ')' : '');
    } else { $('pl-onair').textContent = '–'; $('pl-onair-why').textContent = ''; }
    var sp = null;
    for (i = 0; i < D.lines.length; i++) { var l = D.lines[i]; if (l.t <= t && t < l.t + l.dur) { sp = l; break; } }
    $('pl-speak').innerHTML = sp ? '<b style="color:' + (sp.channel === 'agent' ? colorOf(sp.agent || sp.who) : 'inherit') + '">' + esc(sp.who) + '</b> ' + esc(sp.text) : '<span class="muted">Nobody is speaking.</span>';
    var row = at(D.stats, t) || D.stats[0];
    if (row) {
      var r = {};
      D.stats_cols.forEach(function (k, j) { r[k] = row[j]; });
      var first = {};
      D.stats_cols.forEach(function (k, j) { first[k] = D.stats[0][j]; });
      var fmt = $('pl-stats').__fmt || {};
      document.querySelectorAll('.pl-stat[data-col]').forEach(function (s) {
        var k = s.dataset.col;
        s.querySelector('.pl-stat-val').textContent = (fmt[k] || num)(r[k]);
        var dlt = (k === 'rockets' || k === 'research') && typeof r[k] === 'number' && typeof first[k] === 'number' ? r[k] - first[k] : null;
        s.querySelector('.pl-stat-delta').textContent = dlt ? '+' + dlt.toLocaleString('en-US') + ' this shift' : '';
      });
      $('pl-researching').innerHTML = r.researching ? icon('tech', r.researching, 24) + ' ' + esc(r.researching) : '–';
      var reached = (CFG.planets || []).filter(function (p) { return p[1] <= (r.tick || 0); });
      $('pl-planets').innerHTML = reached.length ? reached.map(function (p) { return '<span class="pl-planet" title="' + esc(nameOf(p[0])) + '">' + (icon('place', p[0], 22) || esc(nameOf(p[0]))) + '</span>'; }).join('') +
        ' <span class="muted">' + reached.length + '</span>' : (r.planets != null ? r.planets : '–');
      $('pl-plat').innerHTML = icon('item', 'space-platform-hub', 20) + ' ' + num(r.platforms);
      $('pl-deaths').textContent = num(r.deaths);
      $('pl-asof').textContent = 'Game time ' + r.game_time + ' · as of ' + fmtWall(r.t) + ' (the score is read every 2 minutes)';
    }
    var evs = document.querySelectorAll('#pl-events li');
    var cur = -1;
    evs.forEach(function (li, j) { if (+li.dataset.t <= t + 1) cur = j; });
    evs.forEach(function (li, j) { li.classList.toggle('past', j <= cur); li.classList.toggle('cur', j === cur); });
    var lines = D.chat.filter(function (c) { return c.t <= t; }).slice(-6).reverse();
    $('pl-chat').innerHTML = lines.map(function (c) {
      return '<li class="' + c.kind + '"><span class="pl-who" style="color:' + (c.kind === 'agent' ? colorOf(c.who) : 'var(--s1)') + '">' +
        esc(c.kind === 'agent' ? nameOf(c.who) : c.who) + '</span><span class="muted small"> ' + fmtRel(t - c.t) + ' ago</span><div>' +
        esc(c.text.length > 220 ? c.text.slice(0, 219) + '…' : c.text) + '</div></li>';
    }).join('');
  }

  function seekWall(t) {
    video.currentTime = Math.max(0, toVideo(Math.min(D.t1, t)));
    render();
  }
  function jump(dir) {
    var s = step(events, now(), cursor, dir, LEAD);
    if (!s) return;
    cursor = s.cursor;
    seekWall(s.seek);
    if (video.paused) video.play().catch(function () {});
  }

  function wire() {
    var lanes = $('pl-lanes'), tip = $('pl-tip');
    lanes.addEventListener('click', function (ev) {
      var tr = lanes.querySelector('.pl-track').getBoundingClientRect();
      var f = (ev.clientX - tr.left) / tr.width;
      if (f >= 0 && f <= 1) { cursor = null; seekWall(D.t0 + f * span); }
    });
    lanes.addEventListener('mousemove', function (ev) {
      var hit = ev.target.closest('[data-tip]');
      if (!hit) { tip.hidden = true; return; }
      tip.textContent = hit.dataset.tip;
      tip.hidden = false;
      tip.style.left = Math.min(ev.pageX + 12, document.documentElement.clientWidth - 316) + 'px';
      tip.style.top = ev.pageY + 14 + 'px';
    });
    lanes.addEventListener('mouseleave', function () { tip.hidden = true; });
    $('pl-prev').onclick = function () { jump(-1); };
    $('pl-next').onclick = function () { jump(1); };
    document.addEventListener('keydown', function (e) {
      if (e.target.closest && e.target.closest('input, textarea, select')) return;
      if (e.key === 'j') jump(1);
      if (e.key === 'k') jump(-1);
    });
    video.addEventListener('timeupdate', function () { var n = Date.now(); if (n - lastRender > 200) { lastRender = n; render(); } });
    video.addEventListener('seeked', render);
  }

  // captions: off at first (the hosts' lines are burned into the picture); the CC button turns them on
  function captions() {
    var tr = document.createElement('track');
    tr.kind = 'captions'; tr.label = 'Hosts and agents'; tr.srclang = 'en'; tr.src = CFG.vtt;
    video.appendChild(tr);
    var on = false;
    try { on = localStorage.getItem('pog-cc') === '1'; } catch (e) { /* no storage */ }
    var btn = $('pl-cc');
    var set = function (v) {
      on = v;
      if (video.textTracks[0]) video.textTracks[0].mode = v ? 'showing' : 'hidden';
      btn.setAttribute('aria-pressed', v ? 'true' : 'false');
      try { localStorage.setItem('pog-cc', v ? '1' : '0'); } catch (e) { /* no storage */ }
    };
    tr.addEventListener('load', function () { set(on); });
    set(on);
    btn.onclick = function () { set(!on); };
  }

  function attach() {
    if (video.canPlayType('application/vnd.apple.mpegurl')) video.src = CFG.src;
    else if (window.Hls && window.Hls.isSupported()) { var h = new window.Hls({ capLevelToPlayerSize: true }); h.loadSource(CFG.src); h.attachMedia(video); }
    else { $('pl-status').textContent = 'This browser cannot play the video here. It is on YouTube too.'; return; }
    captions();
    video.addEventListener('loadedmetadata', function () { ready.video = true; startAt(); }, { once: true });
  }
  // ?at=EPOCH (a moment on /videos/ or a chapter): the wall time to start at, once the timeline and the video are
  // both loaded; a chapter link on this page (data-at) seeks without a reload
  var ready = { video: false, data: false }, startWall = parseFloat(new URLSearchParams(location.search).get('at'));
  function startAt() {
    if (!ready.video || !ready.data || isNaN(startWall)) return;
    seekWall(startWall);
    startWall = NaN;
  }
  document.addEventListener('click', function (ev) {
    var a = ev.target.closest && ev.target.closest('a[data-at]');
    if (!a || !D) return;
    ev.preventDefault();
    cursor = null;
    seekWall(+a.dataset.at);
    video.scrollIntoView({ block: 'center', behavior: 'smooth' });
    video.play().catch(function () {});
    history.replaceState(null, '', '?at=' + a.dataset.at);
  });

  // the big play button over the poster, and the page around a playing video: when the header and the video do not
  // both fit the window, the header scrolls away with the page (it stays at the top otherwise)
  function chrome() {
    var big = $('pl-big'), box = video.parentNode;
    big.addEventListener('click', function () { video.play().catch(function () {}); });
    video.addEventListener('play', function () {
      box.classList.add('started');
      var r = video.getBoundingClientRect(), hdr = document.querySelector('.site-header');
      var top = hdr && getComputedStyle(hdr).position === 'sticky' ? hdr.offsetHeight : 0;
      if (r.top < top || r.bottom > innerHeight) window.scrollBy({ top: r.top - top - 8, behavior: 'smooth' });
    });
    video.addEventListener('ended', function () { box.classList.add('ended'); });
    var fit = function () {
      var hdr = document.querySelector('.site-header');
      document.body.classList.toggle('pl-tight', !!hdr && hdr.offsetHeight + video.offsetHeight + 40 > innerHeight);
    };
    addEventListener('resize', fit);
    fit();
  }

  chrome();
  fetch('/static/game/index.json').then(function (r) { return r.json(); }).then(function (d) {
    Object.keys(d).forEach(function (k) { icons[k] = {}; d[k].forEach(function (n) { icons[k][n] = 1; }); });
  }).catch(function () { /* text without icons */ }).then(function () {
    return fetch(CFG.data).then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); });
  }).then(function (d) {
    D = d;
    span = d.t1 - d.t0;
    events = d.events.slice().sort(function (a, b) { return a.t - b.t; });
    $('pl-span').textContent = fmtWall(d.t0) + ' to ' + fmtWall(d.t1) + ' Pacific · ' + events.length + ' events · ' + d.lines.length + ' voiced lines';
    buildLanes();
    statsCard();
    eventsCard();
    wire();
    render();
    ready.data = true;
    startAt();
  }).catch(function (e) {
    $('pl-status').textContent = 'The timeline could not load (' + e.message + '); the video still plays.';
  });
  attach();
})();
