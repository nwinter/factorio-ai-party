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
      var x = Math.max(0, Math.min(d.xmax, (px - d.L) / d.pw * d.xmax));
      var sx = d.L + d.pw * x / d.xmax;
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
      tip.innerHTML = '<div class="t-head">' + fmtMin(x) + ' · ' + d.y + '</div>' + rows;
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
