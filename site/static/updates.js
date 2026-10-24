// The Updates page (/updates/, site/updates.py; d24 batch159 QB1, viewer Aurora 11:27-11:28): search, status and area
// filters and the sort, kept in the URL (?q=&status=&area=&sort=) as the blueprint page does; and a recheck every 3
// minutes while the page is visible and when the reader comes back to it: /updates/stamp.json (a few dozen bytes), and
// /updates/updates.json only when its stamp changed, which adds new rows and replaces changed ones in place: the scroll
// position, the filters and the open details stay as they were.
// Without script the page shows every row, newest first in its group.
(function () {
  'use strict';
  var RECHECK_MS = 3 * 60 * 1000, RETURN_MS = 30 * 1000;
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();

  function start() {
    var root = document.getElementById('upd-root'), tools = document.getElementById('upd-tools');
    if (!root || !tools) return;
    var q = document.getElementById('upd-q'), status = document.getElementById('upd-status'), area = document.getElementById('upd-area'),
      sort = document.getElementById('upd-sort'), shown = document.getElementById('upd-shown'), note = document.getElementById('upd-live-note');
    var built = root.getAttribute('data-built') || '', stamp = root.getAttribute('data-stamp') || '', lastCheck = Date.now(), busy = false;
    var params = new URLSearchParams(location.search);
    function pick(sel, v) { if (v && Array.prototype.some.call(sel.options, function (o) { return o.value === v; })) sel.value = v; }
    q.value = params.get('q') || ''; pick(status, params.get('status')); pick(area, params.get('area')); pick(sort, params.get('sort'));
    // the page itself keeps the reader's place when rows come in above it (scroll anchoring would move it a second time)
    document.documentElement.style.overflowAnchor = 'none';

    function lists() { return Array.prototype.slice.call(root.querySelectorAll('ul.upd-list[data-group]')); }
    function rows() { return Array.prototype.slice.call(root.querySelectorAll('li.upd')); }
    // newest first by the chosen date; rows without it after, newest stage first; then by id for a stable order
    function order() {
      var k = sort.value || 'stage';
      lists().forEach(function (ul) {
        var items = Array.prototype.slice.call(ul.children);
        items.sort(function (a, b) {
          var x = +a.dataset[k] || 0, y = +b.dataset[k] || 0;
          if (x !== y) return y - x;
          var s = (+b.dataset.stage || 0) - (+a.dataset.stage || 0);
          return s || (a.id < b.id ? -1 : 1);
        });
        items.forEach(function (li) { ul.appendChild(li); });
      });
    }
    function apply() {
      var words = q.value.toLowerCase().split(/\s+/).filter(Boolean), n = 0, total = 0;
      rows().forEach(function (li) {
        var d = li.dataset, ok = words.every(function (w) { return (d.q || '').indexOf(w) >= 0; })
          && (!status.value || d.status === status.value) && (!area.value || d.area === area.value);
        li.hidden = !ok; total++; if (ok) n++;
      });
      order();
      lists().forEach(function (ul) {  // a group heading shows while the view shows rows of it, and how many of them
        var g = ul.getAttribute('data-group'), head = root.querySelector('[data-group-head="' + g + '"]');
        var all = ul.children.length, on = Array.prototype.filter.call(ul.children, function (li) { return !li.hidden; }).length;
        if (head && head.tagName === 'H3') { head.hidden = !on; ul.hidden = !on; }
        var c = head && head.querySelector('.upd-n');
        if (c) c.textContent = on === all ? all : on + ' of ' + all;
      });
      shown.textContent = n === total ? 'Showing all ' + total + ' updates' : 'Showing ' + n + ' of ' + total + ' updates';
      var p = new URLSearchParams();
      if (q.value.trim()) p.set('q', q.value.trim());
      if (status.value) p.set('status', status.value);
      if (area.value) p.set('area', area.value);
      if (sort.value && sort.value !== 'stage') p.set('sort', sort.value);
      var s = p.toString();
      history.replaceState(null, '', location.pathname + (s ? '?' + s : '') + location.hash);
    }
    [q, status, area, sort].forEach(function (el) { el.addEventListener(el === q ? 'input' : 'change', apply); });
    tools.hidden = false; shown.hidden = false;
    apply();

    // ---- the recheck
    function fromHtml(html) { var t = document.createElement('template'); t.innerHTML = html.trim(); return t.content.firstElementChild; }
    // the first thing at or below the top of the window, and where it is: put back there after the change
    function anchor() {
      var els = root.parentNode.querySelectorAll('li.upd:not([hidden]), h2, h3:not([hidden]), #upd-notices li');
      for (var i = 0; i < els.length; i++) {
        var r = els[i].getBoundingClientRect();
        if (r.bottom > 0) return { el: els[i], top: r.top };
      }
      return null;
    }
    function counts() {
      lists().forEach(function (ul) {
        var g = ul.getAttribute('data-group'), head = root.querySelector('[data-group-head="' + g + '"]');
        if (head && ul.children.length && !head.id) head.id = g.replace(' ', '-');  // first row of a group the build had none of
      });
      var none = document.getElementById('upd-none-open'), done = document.getElementById('upd-none-verified');
      if (none) none.hidden = rows().some(function (li) { return li.dataset.status !== 'verified'; });
      if (done) done.hidden = rows().some(function (li) { return li.dataset.status === 'verified'; });
    }
    function mark(li, text) {
      var head = li.querySelector('.upd-head');
      if (!head || head.querySelector('.upd-new')) return;
      var chip = document.createElement('span');
      chip.className = 'fx-chip fx-chip--orange upd-new'; chip.textContent = text;
      head.appendChild(document.createTextNode(' ')); head.appendChild(chip);
    }
    // a change anywhere on the page (rows above, the note at the top) leaves the reader's row where it was
    function keep(fn) {
      var at = anchor(), before = at ? at.el.getBoundingClientRect().top : 0;
      fn();
      if (at && at.el.isConnected) window.scrollBy(0, at.el.getBoundingClientRect().top - before);
    }
    function said(text) { var t = new Date(); return 'Rechecked ' + ('0' + t.getHours()).slice(-2) + ':' + ('0' + t.getMinutes()).slice(-2) + ': ' + text; }
    function merge(j) { keep(function () { mergeRows(j); }); }
    function mergeRows(j) {
      var added = 0, changed = 0;
      (j.rows || []).forEach(function (r) {
        var old = document.getElementById('u-' + r.id), ul = root.querySelector('ul.upd-list[data-group="' + r.status + '"]');
        if (!ul || (old && old.dataset.sig === r.sig)) return;
        var li = fromHtml(r.html);
        if (!li) return;
        if (old) {  // the same details stay open, in the same order
          var was = old.querySelectorAll('details'), now = li.querySelectorAll('details');
          for (var i = 0; i < was.length && i < now.length; i++) now[i].open = was[i].open;
          li.hidden = old.hidden;
          old.parentNode.removeChild(old);
          mark(li, 'changed'); changed++;
        } else { mark(li, 'new'); added++; }
        ul.appendChild(li);
      });
      if (j.counts) document.getElementById('upd-counts').innerHTML = j.counts;
      if (j.updated) document.getElementById('upd-updated').textContent = j.updated;
      if (j.checked) document.getElementById('upd-checked').textContent = j.checked;
      var notices = document.getElementById('upd-notices');
      if (j.notices && notices && notices.outerHTML !== j.notices) notices.outerHTML = j.notices;
      built = j.built || built; root.setAttribute('data-built', built);
      stamp = j.stamp || stamp; root.setAttribute('data-stamp', stamp);
      counts(); apply();
      note.textContent = said(added || changed ? [added ? added + ' new' : '', changed ? changed + ' changed' : '']
        .filter(Boolean).join(', ') + ' (marked).' : 'no change.');
    }
    function check() {
      if (busy || document.visibilityState !== 'visible') return;
      busy = true; lastCheck = Date.now();
      function get(name) {
        return fetch('/updates/' + name + '?t=' + Date.now(), { cache: 'no-store' })
          .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); });
      }
      get('stamp.json')
        .then(function (s) {
          if (s.stamp && s.stamp === stamp) { keep(function () { note.textContent = said('no change.'); }); return; }
          return get('updates.json').then(merge);
        })
        .catch(function () { keep(function () { note.textContent = 'The recheck could not reach the site; it tries again in 3 minutes.'; }); })
        .then(function () { busy = false; });
    }
    setInterval(check, RECHECK_MS);
    document.addEventListener('visibilitychange', function () {
      if (document.visibilityState === 'visible' && Date.now() - lastCheck > RETURN_MS) check();
    });
    window.PogUpdates = { check: check, merge: merge, apply: apply };  // tests drive these
  }
})();
