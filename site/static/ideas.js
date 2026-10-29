// Viewers' ideas (d29 batch340 ID, viewer Aurora site:5470): the /ideas/ page, from the live API's /v1/ideas
// (docs/LIVE-API.md "Viewers' ideas"). Two sections and an idea box with the saved chat name (localStorage chatName, as
// the live page's chat keeps it). With the host link (localStorage hostToken, or ?host=TOKEN once, as live.js takes it)
// the hidden ideas show too, each with the host's tools: move up or down, to the other section, edit, hide, pin,
// highlight, priority, status and a reply. The token goes as X-Host-Token, never in a URL. All text from the API is
// escaped. Ideas go to no agent and no AI.
(function () {
  var root = document.getElementById('ideas');
  if (!root) return;
  var API = (root.dataset.api || '').replace(/\/$/, '');
  var REFRESH = 60 * 1000;
  var SECTIONS = { next_run: 'next run', general: 'general ideas' };
  var STATUS = { 'new': 'New', considering: 'Considering', planned: 'Planned', doing: 'In progress', done: 'Done',
    not_planned: 'Not planned' };
  var PRIORITY = { '': 'No priority', low: 'Low priority', medium: 'Medium priority', high: 'High priority' };
  var form = document.getElementById('idea-form');
  var note = root.querySelector('.idea-note');
  var hostLine = root.querySelector('.idea-host'), hostForget = root.querySelector('.idea-host-forget');

  function store(k, v) { try { if (v === undefined) return localStorage.getItem(k); localStorage.setItem(k, v); } catch (e) { return null; } }
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function when(t) {
    try { return new Date(t * 1000).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }); }
    catch (e) { return ''; }
  }
  function newCid() {
    var b = new Uint8Array(12);
    try { crypto.getRandomValues(b); } catch (e) { for (var i = 0; i < b.length; i++) b[i] = Math.floor(Math.random() * 256); }
    return Array.prototype.map.call(b, function (x) { return ('0' + x.toString(16)).slice(-2); }).join('');
  }

  // the host link: ?host=TOKEN once, kept in this browser and taken out of the address bar
  var hostToken = store('hostToken') || '';
  try {
    var qs = new URLSearchParams(location.search || '');
    if (qs.has('host')) {
      var given = String(qs.get('host') || '').trim();
      if (given) { hostToken = given; store('hostToken', given); }
      qs.delete('host');
      if (window.history && history.replaceState) {
        var rest = qs.toString();
        history.replaceState(null, '', location.pathname + (rest ? '?' + rest : '') + (location.hash || ''));
      }
    }
  } catch (e) { /* an old browser: no host link */ }
  function headers(json) {
    var h = json ? { 'Content-Type': 'application/json' } : {};
    if (hostToken) h['X-Host-Token'] = hostToken;
    return h;
  }
  function showHost() {
    if (hostLine) hostLine.hidden = !hostToken;
    var nb = form && form.querySelector('[name=name]');
    if (nb) { nb.disabled = !!hostToken; if (hostToken) nb.placeholder = 'Host'; }
  }
  if (hostForget) hostForget.addEventListener('click', function () {
    hostToken = '';
    try { localStorage.removeItem('hostToken'); } catch (e) { /* nothing kept */ }
    showHost();
    load();
  });
  showHost();

  var data = null, editing = {}, replying = {}, busy = false;

  function badge(cls, text) { return '<span class="idea-badge ' + cls + '">' + esc(text) + '</span>'; }

  function tools(it) {
    var other = it.section === 'next_run' ? 'general' : 'next_run';
    var opt = function (map, cur) {
      return Object.keys(map).map(function (k) {
        return '<option value="' + esc(k) + '"' + (k === cur ? ' selected' : '') + '>' + esc(map[k]) + '</option>';
      }).join('');
    };
    var b = function (act, label, extra) {
      return '<button type="button" class="fx-btn small" data-act="' + act + '" data-id="' + it.id + '"' + (extra || '') + '>' + esc(label) + '</button>';
    };
    return '<div class="idea-tools">' +
      b('up', '↑', ' aria-label="Move up"') + b('down', '↓', ' aria-label="Move down"') +
      b('section', 'To ' + SECTIONS[other]) +
      b('pinned', it.pinned ? 'Unpin' : 'Pin') + b('highlight', it.highlight ? 'Unhighlight' : 'Highlight') +
      b('hidden', it.hidden ? 'Show again' : 'Hide') + b('edit', editing[it.id] != null ? 'Cancel edit' : 'Edit') +
      b('replying', replying[it.id] != null ? 'Cancel reply' : (it.reply ? 'Edit reply' : 'Reply')) +
      '<select class="fx-textfield" data-act="priority" data-id="' + it.id + '" aria-label="Priority">' + opt(PRIORITY, it.priority || '') + '</select>' +
      '<select class="fx-textfield" data-act="status" data-id="' + it.id + '" aria-label="Status">' + opt(STATUS, it.status || 'new') + '</select>' +
      '</div>' +
      (editing[it.id] != null ? '<div class="idea-edit"><textarea class="fx-textfield" rows="3" maxlength="1000" data-edit="' + it.id + '">' +
        esc(editing[it.id]) + '</textarea>' + b('save-text', 'Save the idea') + '</div>' : '') +
      (replying[it.id] != null ? '<div class="idea-edit"><textarea class="fx-textfield" rows="3" maxlength="1000" data-reply="' + it.id + '" placeholder="Your reply (empty: none)">' +
        esc(replying[it.id]) + '</textarea>' + b('save-reply', 'Save the reply') + '</div>' : '');
  }

  function item(it, host) {
    var cls = 'idea' + (it.pinned ? ' is-pinned' : '') + (it.highlight ? ' is-highlight' : '') + (it.hidden ? ' is-hidden' : '');
    var head = '<span class="idea-name">' + esc(it.name) + '</span>' + (it.host ? badge('is-host', 'HOST') : '') +
      ' <span class="muted small">' + esc(when(it.t)) + (it.edited_t ? ' · edited' : '') + '</span>' +
      (it.pinned ? badge('is-pin', 'Pinned') : '') +
      (it.status && it.status !== 'new' ? badge('is-status st-' + it.status, STATUS[it.status] || it.status) : '') +
      (it.priority ? badge('is-prio pr-' + it.priority, PRIORITY[it.priority] || it.priority) : '') +
      (host && it.hidden ? badge('is-off', 'Hidden') : '') + (host && it.banned ? badge('is-off', 'Banned poster') : '');
    return '<li class="' + cls + '" id="idea-' + it.id + '"><div class="idea-head">' + head + '</div>' +
      '<p class="idea-text">' + esc(it.text) + '</p>' +
      (it.reply ? '<div class="idea-reply"><span class="idea-reply-by">Reply from the host</span> <span class="muted small">' +
        esc(when(it.reply_t)) + '</span><p>' + esc(it.reply) + '</p></div>' : '') +
      (host ? tools(it) : '') + '</li>';
  }

  function render() {
    var host = !!(data && data.host);
    root.querySelectorAll('.idea-section').forEach(function (sec) {
      var list = sec.querySelector('.idea-list');
      if (!data) { list.innerHTML = '<li class="muted">Ideas are not available right now.</li>'; return; }
      var items = (data.sections || {})[sec.dataset.section] || [];
      list.innerHTML = items.length ? items.map(function (it) { return item(it, host); }).join('')
        : '<li class="muted">No ideas here yet.</li>';
    });
    if (form && data && data.open === false) note.textContent = 'Ideas are closed for now.';
  }

  function find(id) {
    var all = [];
    if (data) Object.keys(data.sections || {}).forEach(function (k) { all = all.concat(data.sections[k]); });
    return all.filter(function (it) { return it.id === id; })[0];
  }

  function load() {
    if (!API) { data = null; render(); return; }
    fetch(API + '/v1/ideas', { headers: headers(false) })
      .then(function (r) { return r.json().then(function (d) { return { ok: r.ok, d: d }; }); })
      .then(function (res) {
        if (!res.ok && hostToken && res.d && res.d.error === 'host link not valid') {
          if (hostLine) hostLine.textContent = 'This host link is not valid. Open the current host link, or forget it.';
          hostToken = ''; showHost(); if (hostLine) hostLine.hidden = false;
          return load();
        }
        data = res.ok ? res.d : null;
        render();
      })
      .catch(function () { data = null; render(); });
  }

  // the host's change to one idea: POST /v1/ideas/ID, then the page again
  function change(id, body) {
    if (busy) return;
    busy = true;
    fetch(API + '/v1/ideas/' + id, { method: 'POST', headers: headers(true), body: JSON.stringify(body) })
      .then(function (r) { return r.json().then(function (d) { return { ok: r.ok, d: d }; }); })
      .then(function (res) {
        if (!res.ok) { note.textContent = (res.d && res.d.error) || 'Could not change it.'; return; }
        note.textContent = '';
        if (body.text != null) delete editing[id];
        if (body.reply != null) delete replying[id];
      })
      .catch(function () { note.textContent = 'Could not change it. Check your connection.'; })
      .then(function () { busy = false; load(); });
  }

  root.addEventListener('click', function (ev) {
    var b = ev.target.closest && ev.target.closest('button[data-act]');
    if (!b || !hostToken) return;
    var id = parseInt(b.dataset.id, 10), it = find(id), act = b.dataset.act;
    if (!it) return;
    if (act === 'up' || act === 'down') return change(id, { move: act });
    if (act === 'section') return change(id, { section: it.section === 'next_run' ? 'general' : 'next_run' });
    if (act === 'pinned' || act === 'highlight' || act === 'hidden') { var c = {}; c[act] = !it[act]; return change(id, c); }
    if (act === 'edit') { if (editing[id] != null) delete editing[id]; else editing[id] = it.text; return render(); }
    if (act === 'replying') { if (replying[id] != null) delete replying[id]; else replying[id] = it.reply || ''; return render(); }
    if (act === 'save-text') { var t = root.querySelector('[data-edit="' + id + '"]'); return change(id, { text: t ? t.value : it.text }); }
    if (act === 'save-reply') { var r = root.querySelector('[data-reply="' + id + '"]'); return change(id, { reply: r ? r.value : '' }); }
  });
  root.addEventListener('change', function (ev) {
    var s = ev.target;
    if (!s || !s.dataset || (s.dataset.act !== 'priority' && s.dataset.act !== 'status') || !hostToken) return;
    var c = {};
    c[s.dataset.act] = s.value;
    change(parseInt(s.dataset.id, 10), c);
  });
  // a draft kept while the list is drawn again
  root.addEventListener('input', function (ev) {
    var t = ev.target;
    if (t && t.dataset && t.dataset.edit) editing[t.dataset.edit] = t.value;
    if (t && t.dataset && t.dataset.reply) replying[t.dataset.reply] = t.value;
  });

  if (form) {
    var nameIn = form.querySelector('[name=name]'), textIn = form.querySelector('[name=text]');
    var sendBtn = form.querySelector('[type=submit]');
    nameIn.value = store('chatName') || '';
    var sending = false, pending = null;
    form.addEventListener('submit', function (ev) {
      ev.preventDefault();
      if (!API || sending) return;
      var sec = form.querySelector('[name=section]:checked');
      var body = { name: nameIn.value.trim(), text: textIn.value.trim(), section: sec ? sec.value : 'general' };
      if (!body.text) return;
      // one id per idea, sent again on a retry: the worker stores it once
      if (!pending || pending.text !== body.text || pending.section !== body.section) pending = { text: body.text, section: body.section, cid: newCid() };
      body.cid = pending.cid;
      if (!hostToken) store('chatName', body.name);
      sending = true; if (sendBtn) sendBtn.disabled = true;
      note.textContent = 'Sending…';
      fetch(API + '/v1/ideas', { method: 'POST', headers: headers(true), body: JSON.stringify(body) })
        .then(function (r) { return r.json().then(function (d) { return { ok: r.ok, d: d }; }); })
        .then(function (res) {
          if (!res.ok) {
            note.textContent = (res.d && res.d.error ? res.d.error : 'Could not send') +
              (res.d && res.d.retry_after_s ? ' (try again in ' + res.d.retry_after_s + ' s)' : '') + '.';
            return;
          }
          pending = null;
          if (textIn.value.trim() === body.text) textIn.value = '';
          note.textContent = res.d && res.d.guest_name ? 'Thanks! Sent as ' + res.d.guest_name + ' (type a name above to use your own).'
            : 'Thanks! Your idea is on the page.';
          load();
        })
        .catch(function () { note.textContent = 'Could not send. Check your connection.'; })
        .then(function () { sending = false; if (sendBtn) sendBtn.disabled = false; });
    });
  }

  load();
  setInterval(function () { if (!document.hidden && !busy && !Object.keys(editing).length && !Object.keys(replying).length) load(); }, REFRESH);
})();
