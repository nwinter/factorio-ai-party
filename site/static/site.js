// Theme toggle and chart hover readouts. No dependencies.
(function () {
  var root = document.documentElement;
  var btn = document.querySelector('.theme-toggle');
  if (btn) {
    btn.addEventListener('click', function () {
      var dark = root.dataset.theme
        ? root.dataset.theme === 'dark'
        : window.matchMedia('(prefers-color-scheme: dark)').matches;
      root.dataset.theme = dark ? 'light' : 'dark';
      try { localStorage.setItem('theme', root.dataset.theme); } catch (e) {}
    });
  }

  // the nav (batch270): the Menu button on a phone shows the whole list, with More's links in it; More closes on a
  // click outside it or Escape
  var hdr = document.querySelector('.site-header'), tog = document.querySelector('.nav-toggle'), more = document.querySelector('.nav-more');
  if (tog && hdr) {
    tog.addEventListener('click', function () {
      var open = hdr.classList.toggle('nav-open');
      tog.setAttribute('aria-expanded', open ? 'true' : 'false');
      if (more) more.open = open;
    });
  }
  if (more) {
    document.addEventListener('click', function (e) {
      if (more.open && !more.contains(e.target) && !(hdr && hdr.classList.contains('nav-open'))) more.open = false;
    });
    document.addEventListener('keydown', function (e) { if (e.key === 'Escape') more.open = false; });
  }
  // A poll open: "open" beside Polls and a dot on More and Menu. The homepage's and /polls/'s poll script reports it
  // (PogNav.polls); other pages ask the live API's /v1/polls at most once in 10 minutes per tab.
  function polls(open) {
    if (!open) return;
    document.querySelectorAll('.nav-dot').forEach(function (d) { d.hidden = false; });
    document.querySelectorAll('.site-nav a[href="/polls/"]').forEach(function (a) {
      if (!a.querySelector('.nav-chip')) a.insertAdjacentHTML('beforeend', '<span class="nav-chip">open</span>');
      a.setAttribute('title', open === 1 ? 'A poll is open: vote' : open + ' polls are open: vote');
    });
  }
  window.PogNav = { polls: polls };
  var api = hdr && (hdr.dataset.api || '').replace(/\/$/, '');
  if (api && !document.getElementById('polls')) {
    var cached = null;
    try { cached = JSON.parse(sessionStorage.getItem('pollsOpen') || 'null'); } catch (e) { /* no storage */ }
    if (cached && Date.now() - cached.at < 600000) polls(cached.open);
    else if (window.fetch) {
      fetch(api + '/v1/polls').then(function (r) { return r.ok ? r.json() : null; }).then(function (d) {
        var n = d && d.open ? d.open.length : 0;
        try { sessionStorage.setItem('pollsOpen', JSON.stringify({ at: Date.now(), open: n })); } catch (e) { /* no storage */ }
        polls(n);
      }).catch(function () { /* no API: no dot */ });
    }
  }

  function fmtMin(m) {
    var s = Math.round(m * 60), h = Math.floor(s / 3600), mm = Math.floor((s % 3600) / 60), ss = s % 60;
    return h ? h + 'h' + String(mm).padStart(2, '0') + 'm' : mm + 'm' + String(ss).padStart(2, '0') + 's';
  }
  function valueAt(pts, x, step) {
    // last point at or before x (step and sampled series both read this way)
    var v = null;
    for (var i = 0; i < pts.length; i++) { if (pts[i][0] <= x + 1e-9) v = pts[i][1]; else break; }
    return v;
  }

  // milestones: show one kind (the buttons are hidden until this script runs, so without it every row shows)
  // On a phone the full list is long: the first 15, and a button for the rest (a kind shows all of its rows).
  document.querySelectorAll('.kind-filter').forEach(function (bar) {
    var wrap = bar.nextElementSibling, table = wrap && wrap.querySelector('table');
    if (!table) return;
    bar.hidden = false;
    var rows = Array.prototype.slice.call(table.querySelectorAll('tbody tr')), FIRST = 15, more = null;
    function show(kind, all) {
      var n = 0;
      rows.forEach(function (tr) {
        var match = !kind || tr.dataset.kind === kind;
        tr.hidden = !match || (!all && ++n > FIRST);
      });
      if (more) more.hidden = all || rows.filter(function (tr) { return !kind || tr.dataset.kind === kind; }).length <= FIRST;
    }
    if (window.matchMedia && window.matchMedia('(max-width: 640px)').matches && rows.length > FIRST) {
      more = document.createElement('button');
      more.type = 'button';
      more.className = 'fx-btn small firsts-more';
      more.textContent = 'Show all ' + rows.length;
      wrap.parentNode.insertBefore(more, wrap.nextSibling);
      more.addEventListener('click', function () {
        var on = bar.querySelector('[aria-pressed="true"]');
        show(on ? on.dataset.kind : '', true);
      });
      show('', false);
    }
    bar.addEventListener('click', function (ev) {
      var b = ev.target.closest('button[data-kind]');
      if (!b) return;
      bar.querySelectorAll('button').forEach(function (x) { x.setAttribute('aria-pressed', String(x === b)); });
      show(b.dataset.kind, !!b.dataset.kind || !more);
    });
  });

  // "A shift is on now": the run pages are built at shift changes, so whether a shift is live comes from the live API
  document.querySelectorAll('.live-banner[data-api]').forEach(function (el) {
    var api = el.dataset.api.replace(/\/$/, '');
    if (!api || !window.fetch) return;
    fetch(api + '/v1/state', { cache: 'no-store' }).then(function (r) { return r.ok ? r.json() : null; }).then(function (d) {
      if (d && d.state && d.age_s != null && d.age_s < 60 && !d.state.paused) el.hidden = false;
    }).catch(function () {});
  });

  // The agents page: each card's "Now" from the live state (push_live.py agents[].loadout), every 30 s; hidden when no
  // shift is on or the agent has no live loadout.
  var grid = document.querySelector('.agent-grid[data-api]');
  if (grid && window.fetch) {
    var api2 = grid.dataset.api.replace(/\/$/, '');
    var words = function (s) { return String(s || '').replace(/[-_]+/g, ' '); };
    var num = function (n) { return Number(n || 0).toLocaleString('en-US'); };
    var row = function (dl, k, v) {
      if (!v) return;
      var d = document.createElement('div'), dt = document.createElement('dt'), dd = document.createElement('dd');
      dt.textContent = k; dd.textContent = v; d.appendChild(dt); d.appendChild(dd); dl.appendChild(d);
    };
    var fill = function (sec, lo, age, haul) {
      var dl = sec.querySelector('.now-kv');
      dl.textContent = '';
      // (d17 batch35 D5) its most repeated haul this shift, and what feeds that destination without hands now
      if (haul) {
        row(dl, 'Most repeated haul', words(haul.item) + ' to ' + words(haul.to_name || 'a spot') + ', ' + num(haul.times) + ' times this shift');
        row(dl, 'Fed there now', haul.feed ? haul.feed.replace(/^.*without hands now: /, '') : '');
      }
      var guns = [];
      (lo.guns || []).forEach(function (g, i) {
        if (!g) return;
        var a = (lo.ammo || [])[i];
        guns.push(words(g.name) + (a ? ': ' + num(a.count) + ' ' + words(a.name) : ': no ammo'));
      });
      row(dl, 'Guns', guns.join('; '));
      var ar = lo.armor;
      if (ar) {
        row(dl, 'Armor', words(ar.name) + (ar.quality ? ' (' + ar.quality + ')' : ''));
        row(dl, 'Equipment', (ar.equipment || []).map(function (e) { return (e.count > 1 ? e.count + '× ' : '') + words(e.name.replace(/-equipment$/, '')) + (e.quality ? ' (' + e.quality + ')' : ''); }).join(', '));
        if (ar.shield) row(dl, 'Shield', Math.round(ar.shield.now) + ' / ' + Math.round(ar.shield.max));
      }
      if (lo.health) row(dl, 'Health', Math.round(lo.health.now) + ' / ' + Math.round(lo.health.max));
      row(dl, 'Vehicle', lo.vehicle ? words(lo.vehicle) : '');
      row(dl, 'Carrying', (lo.items || []).map(function (it) { return words(it.name) + ' ' + num(it.count); }).join(', '));
      if (lo.slots) row(dl, 'Free slots', lo.slots.free + ' / ' + lo.slots.total);
      var c = lo.crafting;
      if (c && c.queue && c.queue.length) row(dl, 'Crafting', c.queue.map(function (q, i) {
        return words(q.recipe) + ' ×' + q.count + (i === 0 && c.progress ? ' (' + Math.round(c.progress * 100) + '%)' : '');
      }).join(', '));
      var b = lo.building;
      if (b) row(dl, 'Building', words(b.kind) + (b.total != null ? ' ' + b.done + ' of ' + b.total : ''));
      row(dl, 'As of', Math.round(age) + ' s ago');
      sec.hidden = !dl.children.length;
    };
    var poll = function () {
      fetch(api2 + '/v1/state', { cache: 'no-store' }).then(function (r) { return r.ok ? r.json() : null; }).then(function (d) {
        var fresh = d && d.state && d.age_s != null && d.age_s < 120;
        var by = {}, hauls = {};
        ((fresh && d.state.agents) || []).forEach(function (a) { if (a.loadout) by[a.name] = a.loadout; if (a.haul) hauls[a.name] = a.haul; });
        grid.querySelectorAll('.agent-now').forEach(function (sec) {
          var lo = by[sec.dataset.agent], haul = hauls[sec.dataset.agent];
          if (!lo && !haul) { sec.hidden = true; return; }
          fill(sec, lo || {}, (d.age_s || 0) + ((lo || {}).age_s || 0), haul);
        });
      }).catch(function () {});
    };
    poll();
    setInterval(poll, 30000);
  }

  // a page's charts can share one list of [game minute, Pacific time] (#chart-clock) for the hover's real time
  var pageClock = null;
  try { var pc = document.getElementById('chart-clock'); if (pc) pageClock = JSON.parse(pc.textContent); } catch (e) {}

  // (batch314 B, viewer Aurora) each line chart is drawn again here at the page's own width (build.py line_chart's
  // SVG is what shows without this script): the range the page's range bar sets (every chart shares it), packs hidden
  // or shown from the legend, an optional 1-game-hour average drawn apart from the 10-game-minute points, holes in the
  // record shaded with the lines broken there, and the shift starts in a strip under the axis, every k-th labelled
  // so none collide. The hover reads exact values.
  var NS = 'http://www.w3.org/2000/svg';
  var full = function (v) { return Number(v).toLocaleString('en-US', { maximumFractionDigits: 2 }); };
  function niceTicks(vmax, n) {
    if (!(vmax > 0)) return [0, 1];
    var raw = vmax / n, mag = raw >= 1 ? Math.pow(10, String(Math.floor(raw)).length) / 10 : Math.pow(10, Math.floor(Math.log10(raw)));
    var step = mag, fs = [1, 2, 2.5, 5, 10];
    for (var i = 0; i < fs.length; i++) { step = fs[i] * mag; if (vmax / step <= n) break; }
    var out = [];
    for (var v = 0; v < vmax + step * 0.999; v += step) out.push(Math.round(v * 1e6) / 1e6);
    return out;
  }
  function rangeTicks(lo, hi, n) {
    // ticks across [lo, hi] at a nice step (game minutes; hour steps once the span is over 3 hours)
    var span = hi - lo, cands = [1, 2, 5, 10, 15, 30, 60, 120, 180, 300, 600, 1200, 1800, 3000, 6000, 12000, 30000, 60000];
    var step = cands[cands.length - 1];
    for (var i = 0; i < cands.length; i++) { if (span / cands[i] <= n) { step = cands[i]; break; } }
    var out = [];
    for (var v = Math.ceil(lo / step) * step; v <= hi + 1e-9; v += step) out.push(v);
    return out;
  }
  function tickText(m, hours) {
    if (!hours) return full(m);
    var h = Math.floor(m / 60), mm = Math.round(m - h * 60);
    return mm ? h.toLocaleString('en-US') + 'h' + String(mm).padStart(2, '0') : h.toLocaleString('en-US') + 'h';
  }
  function el(tag, attrs, parent, text) {
    var e = document.createElementNS(NS, tag);
    for (var k in attrs) e.setAttribute(k, attrs[k]);
    if (text != null) e.textContent = text;
    if (parent) parent.appendChild(e);
    return e;
  }
  function inGap(gaps, x) { for (var i = 0; i < gaps.length; i++) if (x > gaps[i][0] && x < gaps[i][1]) return gaps[i]; return null; }
  function crosses(gaps, a, b) { for (var i = 0; i < gaps.length; i++) if (a <= gaps[i][0] && b >= gaps[i][1]) return true; return false; }
  // the mean of the points in the game hour up to each point (a hole starts it again)
  function hourMean(pts, gaps) {
    var out = [], lo = 0, sum = 0;
    for (var i = 0; i < pts.length; i++) {
      if (i && crosses(gaps, pts[i - 1][0], pts[i][0])) { lo = i; sum = 0; }
      sum += pts[i][1];
      while (pts[i][0] - pts[lo][0] >= 60) { sum -= pts[lo][1]; lo++; }  // a window ends at its point: 6 make the hour
      out.push([pts[i][0], Math.round(sum / (i - lo + 1) * 10) / 10, i - lo + 1]);
    }
    return out;
  }
  function markStep(xs, nums, w) {
    var ks = [1, 2, 5, 10, 20, 25, 50, 100, 200, 500];
    for (var i = 0; i < ks.length; i++) {
      var last = null, ok = true;
      for (var j = 0; j < xs.length && ok; j++) {
        if (ks[i] !== 1 && nums[j] % ks[i]) continue;
        if (last !== null && xs[j] - last < w) ok = false;
        last = xs[j];
      }
      if (ok) return ks[i];
    }
    return 1000;
  }

  window.PogCharts = { niceTicks: niceTicks, rangeTicks: rangeTicks, hourMean: hourMean, markStep: markStep, crosses: crosses, inGap: inGap };  // site/test_longcharts.py
  var charts = [];
  document.querySelectorAll('figure.chart').forEach(function (fig) {
    var dataEl = fig.querySelector('.chart-data'), plot = fig.querySelector('.plot'), tip = fig.querySelector('.tip');
    if (!dataEl || !plot || !tip) return;
    var d = JSON.parse(dataEl.textContent);
    var st = { lo: null, hi: null, hidden: {}, smooth: false };
    var c = { fig: fig, d: d, st: st };
    var legend = fig.querySelector('.legend');
    // clickable legend: a button per series, pressed while it is shown
    if (legend && d.series.length > 1) {
      legend.querySelectorAll('li').forEach(function (li, i) {
        var b = document.createElement('button');
        b.type = 'button'; b.className = 'legend-btn'; b.setAttribute('aria-pressed', 'true');
        b.innerHTML = li.innerHTML;
        b.title = 'Hide or show ' + d.series[i].name;
        li.textContent = ''; li.appendChild(b);
        b.addEventListener('click', function () {
          st.hidden[i] = !st.hidden[i];
          b.setAttribute('aria-pressed', String(!st.hidden[i]));
          draw(c);
        });
      });
      var all = document.createElement('li');
      all.innerHTML = '<button type="button" class="legend-btn legend-all" hidden>Show all</button>';
      legend.appendChild(all);
      all.firstChild.addEventListener('click', function () {
        st.hidden = {};
        legend.querySelectorAll('.legend-btn[aria-pressed]').forEach(function (b) { b.setAttribute('aria-pressed', 'true'); });
        draw(c);
      });
      c.allBtn = all.firstChild;
    }
    charts.push(c);
    draw(c);
    function at(ev) {
      if (!c.g) return;
      var g = c.g, rect = c.svg.getBoundingClientRect(), scale = g.W / (rect.width || g.W);
      var px = (ev.clientX - rect.left) * scale;
      var x = Math.max(g.lo, Math.min(g.hi, g.lo + (px - g.L) / g.pw * (g.hi - g.lo)));
      var sx = g.X(x);
      c.cross.setAttribute('x1', sx); c.cross.setAttribute('x2', sx); c.cross.setAttribute('visibility', 'visible');
      var rows = '', gap = inGap(d.gaps || [], x);
      g.vis.forEach(function (s, k) {
        var dot = c.dots[k];
        var v = gap ? null : valueAt(s.pts, x, d.step);
        if (v === null || !s.pts.length || x > s.pts[s.pts.length - 1][0] + 2 || x < s.pts[0][0] - 2) { dot.setAttribute('visibility', 'hidden'); return; }
        dot.setAttribute('cx', sx); dot.setAttribute('cy', g.Y(v)); dot.setAttribute('visibility', 'visible');
        rows += '<div class="t-row"><span><i class="swatch" style="background:var(' + s.var + ')"></i>' +
          s.name.replace(/</g, '&lt;') + '</span><b>' + full(v) + '</b></div>';
        if (s.avg) {
          var a = null;
          for (var i = 0; i < s.avg.length && s.avg[i][0] <= x + 1e-9; i++) a = s.avg[i];
          if (a) rows += '<div class="t-row t-avg"><span>1-game-hour average (' + a[2] + ' window' + (a[2] === 1 ? '' : 's') + ')</span><b>' + full(a[1]) + '</b></div>';
        }
      });
      if (gap) rows = '<div class="t-row"><span>No score rows from ' + fmtMin(gap[0]) + ' to ' + fmtMin(gap[1]) + '</span></div>';
      if (!rows) { tip.hidden = true; return; }
      var clock = d.clock === 'page' ? pageClock : d.clock;
      var when = clock && clock.length ? valueAt(clock, x) : null;  // the real time (Pacific) at that game time
      tip.innerHTML = '<div class="t-head">' + fmtMin(x) + (when ? ' · ' + when : '') + ' · ' + d.y + '</div>' + rows;
      tip.hidden = false;
      var left = sx / scale + 12;
      if (left + tip.offsetWidth > rect.width) left = sx / scale - tip.offsetWidth - 12;
      tip.style.left = Math.max(0, left) + 'px';
    }
    function leave() {
      tip.hidden = true;
      if (c.cross) c.cross.setAttribute('visibility', 'hidden');
      (c.dots || []).forEach(function (dot) { dot.setAttribute('visibility', 'hidden'); });
    }
    plot.addEventListener('pointermove', function (ev) { if (ev.target.closest('.hit')) at(ev); });
    plot.addEventListener('pointerdown', function (ev) { if (ev.target.closest('.hit')) at(ev); });
    plot.addEventListener('pointerleave', leave);
  });

  function draw(c) {
    var d = c.d, st = c.st, fig = c.fig, plot = fig.querySelector('.plot');
    var W = Math.max(260, Math.round(plot.clientWidth || 640));
    var H = Math.round(Math.max(220, Math.min(420, W * (W < 560 ? 0.62 : 0.4))));
    var old = plot.querySelector('svg');
    var x0 = d.x0 || 0, dataHi = d.xmax;
    d.series.forEach(function (s) { if (s.pts.length) dataHi = Math.max(x0, s.pts[s.pts.length - 1][0]); });
    var lo = st.lo === null ? x0 : Math.max(x0, st.lo), hi = st.hi === null ? Math.max(dataHi, lo + 1) : st.hi;
    var gaps = d.gaps || [];
    // the series in range: a step series starts at its value at lo
    var vis = [];
    d.series.forEach(function (s, i) {
      if (st.hidden[i]) return;
      var pts = [], before = null;
      s.pts.forEach(function (p) { if (p[0] < lo) before = p; else if (p[0] <= hi) pts.push(p); });
      if (d.step && before) pts.unshift([lo, before[1]]);
      var avg = st.smooth && d.smooth ? hourMean(s.pts, gaps).filter(function (p) { return p[0] >= lo && p[0] <= hi; }) : null;
      vis.push({ name: s.name, var: s.var, dash: s.dash, pts: pts, avg: avg });
    });
    if (c.allBtn) c.allBtn.hidden = !Object.keys(st.hidden).some(function (k) { return st.hidden[k]; });
    var ymaxRaw = 0;
    vis.forEach(function (s) { s.pts.forEach(function (p) { if (p[1] > ymaxRaw) ymaxRaw = p[1]; }); });
    var yt = niceTicks(ymaxRaw || 1, W < 560 ? 4 : 5), ymax = yt[yt.length - 1];
    var cw = W < 560 ? 9.2 : 7.4;  // a character's width: 16 px text on a phone (style.css), 13 px else
    var labW = Math.max.apply(null, yt.map(function (v) { return full(v).length; })) * cw + 12;
    var SB = d.marks && d.marks.length ? 22 : 0;
    var L = Math.max(36, labW), R = 14, T = 10, B = 40 + SB;
    var pw = W - L - R, ph = H - T - B;
    var X = function (v) { return L + pw * (v - lo) / ((hi - lo) || 1); };
    var Y = function (v) { return T + ph * (1 - v / ymax); };
    var svg = document.createElementNS(NS, 'svg');
    svg.setAttribute('viewBox', '0 0 ' + W + ' ' + H); svg.setAttribute('width', W); svg.setAttribute('height', H);
    svg.setAttribute('class', 'chart-svg drawn'); svg.setAttribute('role', 'img');
    var title = old && old.querySelector('title');
    if (title) { svg.setAttribute('aria-labelledby', title.id); svg.appendChild(title.cloneNode(true)); }
    yt.forEach(function (v) {
      el('line', { class: 'grid', x1: L, x2: W - R, y1: Y(v), y2: Y(v) }, svg);
      el('text', { class: 'tick', x: L - 6, y: Y(v) + 4, 'text-anchor': 'end' }, svg, full(v));
    });
    rangeTicks(lo, hi, Math.max(2, Math.floor(pw / (cw * 9 + 20)))).forEach(function (v) {
      el('text', { class: 'tick', x: X(v), y: T + ph + 16, 'text-anchor': 'middle' }, svg, tickText(v, d.hours));
    });
    gaps.forEach(function (g) {
      var a = Math.max(g[0], lo), b = Math.min(g[1], hi);
      if (b > a) el('title', {}, el('rect', { class: 'gap', x: X(a), y: T, width: X(b) - X(a), height: ph }, svg), 'No score rows ' + fmtMin(g[0]) + ' to ' + fmtMin(g[1]));
    });
    // shift starts: a dashed line in the plot, a tick in the strip, every k-th labelled
    var ms = (d.marks || []).filter(function (m) { return m[0] >= lo && m[0] <= hi; });
    if (ms.length) {
      var xs = ms.map(function (m) { return X(m[0]); }), nums = ms.map(function (m) { return parseInt(m[1].replace(/\D/g, ''), 10) || 0; });
      var k = markStep(xs, nums, cw * Math.max.apply(null, ms.map(function (m) { return m[1].length; })) + 10);
      var sy = T + ph + 22;
      ms.forEach(function (m, j) {
        el('line', { class: 'mark', x1: xs[j], x2: xs[j], y1: T, y2: T + ph }, svg);
        el('line', { class: 'mark-tick', x1: xs[j], x2: xs[j], y1: sy, y2: sy + 4 }, svg);
        if (k === 1 || nums[j] % k === 0) el('text', { class: 'mark-label', x: xs[j], y: sy + 15, 'text-anchor': 'middle' }, svg, m[1]);
      });
    }
    el('line', { class: 'axis', x1: L, x2: W - R, y1: T + ph, y2: T + ph }, svg);
    el('text', { class: 'axis-label', x: L + pw / 2, y: H - 4, 'text-anchor': 'middle' }, svg, d.xl + (SB && W >= 560 ? ' · S: shift starts' : ''));
    var path = function (pts) {
      var out = [];
      pts.forEach(function (p, j) {
        var brk = j === 0 || p[0] < pts[j - 1][0] || crosses(gaps, pts[j - 1][0], p[0]);
        if (brk) out.push('M' + X(p[0]).toFixed(1) + ',' + Y(p[1]).toFixed(1));
        else if (d.step) out.push('H' + X(p[0]).toFixed(1) + 'V' + Y(p[1]).toFixed(1));
        else out.push('L' + X(p[0]).toFixed(1) + ',' + Y(p[1]).toFixed(1));
      });
      return out.join(' ');
    };
    vis.forEach(function (s) {
      if (!s.pts.length) return;
      var line = el('path', { class: 'line' + (s.avg ? ' sampled' : ''), d: path(s.pts) }, svg);
      line.style.stroke = 'var(' + s.var + ')';
      if (s.dash) line.style.strokeDasharray = '6 3';
      if (s.avg && s.avg.length) {
        var a = el('path', { class: 'line avg', d: path(s.avg) }, svg);
        a.style.stroke = 'var(' + s.var + ')';
      }
      var e = s.pts[s.pts.length - 1];
      if (e[1]) el('circle', { class: 'end', cx: X(e[0]), cy: Y(e[1]), r: 4 }, svg).style.fill = 'var(' + s.var + ')';
    });
    if (!vis.length) el('text', { class: 'axis-label', x: L + pw / 2, y: T + ph / 2, 'text-anchor': 'middle' }, svg, 'Every series is hidden: click one in the legend');
    c.cross = el('line', { class: 'cross', x1: 0, x2: 0, y1: T, y2: T + ph, visibility: 'hidden' }, svg);
    c.dots = vis.map(function (s) {
      var dot = el('circle', { r: '4.5', class: 'hover-dot', visibility: 'hidden' }, svg);
      dot.style.fill = 'var(' + s.var + ')';
      return dot;
    });
    el('rect', { class: 'hit', x: L, y: T, width: pw, height: ph, fill: 'transparent' }, svg);
    if (old) plot.replaceChild(svg, old); else plot.insertBefore(svg, plot.firstChild);
    c.svg = svg;
    c.g = { W: W, L: L, pw: pw, lo: lo, hi: hi, X: X, Y: Y, vis: vis };
  }

  // the range bar: every chart on the page takes the range; the average shows on the charts that offer it
  var bar = document.querySelector('.chart-range');
  if (bar && charts.length) {
    bar.hidden = false;
    var sel = bar.querySelector('select'), smooth = bar.querySelector('[data-smooth]');
    var setRange = function (lo, hi, btn) {
      bar.querySelectorAll('button[data-range]').forEach(function (b) { b.setAttribute('aria-pressed', String(b === btn)); });
      if (btn) sel.value = '';
      charts.forEach(function (c) { c.st.lo = lo; c.st.hi = hi; draw(c); });
    };
    bar.addEventListener('click', function (ev) {
      var b = ev.target.closest('button[data-range]');
      if (!b) return;
      setRange(b.dataset.range === 'recent' ? parseFloat(b.dataset.lo) : null, null, b);
    });
    sel.addEventListener('change', function () {
      var o = sel.selectedOptions[0];
      if (!o || !o.value) { setRange(null, null, bar.querySelector('[data-range="full"]')); return; }
      setRange(parseFloat(o.dataset.lo), parseFloat(o.dataset.hi), null);
    });
    smooth.addEventListener('change', function () {
      charts.forEach(function (c) { c.st.smooth = smooth.checked; draw(c); });
    });
  }
  var rt = null;
  window.addEventListener('resize', function () {
    clearTimeout(rt);
    rt = setTimeout(function () { charts.forEach(draw); }, 150);
  });
})();
