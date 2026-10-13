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

  // a page's charts can share one list of [game minute, Pacific time] (#chart-clock) for the hover's real time
  var pageClock = null;
  try { var pc = document.getElementById('chart-clock'); if (pc) pageClock = JSON.parse(pc.textContent); } catch (e) {}

  document.querySelectorAll('figure.chart').forEach(function (fig) {
    var dataEl = fig.querySelector('.chart-data');
    var svg = fig.querySelector('svg');
    var hit = fig.querySelector('.hit');
    var cross = fig.querySelector('.cross');
    var tip = fig.querySelector('.tip');
    if (!dataEl || !svg || !hit) return;
    var d = JSON.parse(dataEl.textContent);
    var NS = 'http://www.w3.org/2000/svg';
    var dots = d.series.map(function (s) {
      var c = document.createElementNS(NS, 'circle');
      c.setAttribute('r', '4.5'); c.setAttribute('class', 'hover-dot');
      c.style.fill = 'var(' + s.var + ')'; c.setAttribute('visibility', 'hidden');
      svg.appendChild(c);
      return c;
    });
    var y0 = d.T + d.ph, yTop = d.T, ymax = d.ymax || 1;

    function move(ev) {
      var rect = svg.getBoundingClientRect();
      var scale = d.W / rect.width;
      var px = (ev.clientX - rect.left) * scale;
      var x0 = d.x0 || 0, x = Math.max(x0, Math.min(d.xmax, x0 + (px - d.L) / d.pw * (d.xmax - x0)));
      var sx = d.L + d.pw * (x - x0) / ((d.xmax - x0) || 1);
      cross.setAttribute('x1', sx); cross.setAttribute('x2', sx); cross.setAttribute('visibility', 'visible');
      var rows = '';
      d.series.forEach(function (s, i) {
        var v = valueAt(s.pts, x, d.step);
        if (v === null || !s.pts.length || x > s.pts[s.pts.length - 1][0] + 2) { dots[i].setAttribute('visibility', 'hidden'); return; }
        dots[i].setAttribute('cx', sx);
        dots[i].setAttribute('cy', y0 - (y0 - yTop) * v / ymax);
        dots[i].setAttribute('visibility', 'visible');
        rows += '<div class="t-row"><span><i class="swatch" style="background:var(' + s.var + ')"></i>' +
          s.name.replace(/</g, '&lt;') + '</span><b>' + v.toLocaleString() + '</b></div>';
      });
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
      tip.hidden = true; cross.setAttribute('visibility', 'hidden');
      dots.forEach(function (c) { c.setAttribute('visibility', 'hidden'); });
    }
    hit.addEventListener('pointermove', move);
    hit.addEventListener('pointerdown', move);
    hit.addEventListener('pointerleave', leave);
  });
})();
