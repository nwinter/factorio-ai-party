// Polls (d16 17:15): the live page's poll card and the /polls/ page, from the live API's /v1/polls
// (docs/LIVE-API.md "Polls"). One vote per client per poll; a later vote replaces it. The vote is remembered per browser
// so the card shows it chosen. All text from the API is escaped. Without the API the card stays hidden and the page
// says polls are unavailable.
(function () {
  var root = document.getElementById('polls');
  if (!root) return;
  var mode = root.dataset.mode === 'page' ? 'page' : 'card';
  var API = (root.dataset.api || '').replace(/\/$/, '');
  var REFRESH = (mode === 'page' ? 30 : 15) * 1000;
  var list = root.querySelector('.polls-list');

  // The host link (live.js keeps it as localStorage hostToken): sent as X-Host-Token, so the host's vote or idea is
  // theirs; never in a URL.
  function postHeaders() {
    var h = { 'Content-Type': 'application/json' };
    try { var t = localStorage.getItem('hostToken'); if (t) h['X-Host-Token'] = t; } catch (e) { /* no storage */ }
    return h;
  }
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function store(k, v) { try { if (v === undefined) return localStorage.getItem(k); localStorage.setItem(k, v); } catch (e) { return null; } }
  function mine() { try { return JSON.parse(store('pollVotes') || '{}') || {}; } catch (e) { return {}; } }
  function remember(id, option) { var m = mine(); m[id] = option; store('pollVotes', JSON.stringify(m)); }
  function newCid() {
    var b = new Uint8Array(12);
    try { crypto.getRandomValues(b); } catch (e) { for (var i = 0; i < b.length; i++) b[i] = Math.floor(Math.random() * 256); }
    return Array.prototype.map.call(b, function (x) { return ('0' + x.toString(16)).slice(-2); }).join('');
  }
  function left(s) {
    if (s <= 0) return 'closing';
    var mins = Math.max(1, Math.round(s / 60));
    if (mins < 60) return mins + ' min left';
    var h = Math.floor(mins / 60), m = mins % 60;
    return h + ' h' + (m ? ' ' + m + ' min' : '') + ' left';
  }
  function when(t) {
    try { return new Date(t * 1000).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }); }
    catch (e) { return ''; }
  }
  // The name: the chat's name box on the live page, else this page's own, else the one chat remembered.
  function nameNow(art) {
    var own = art && art.querySelector('[name=poll-name]');
    if (own && own.value.trim()) return own.value.trim();
    var chat = document.querySelector('#vchat-form [name=name]');
    return (chat && chat.value.trim()) || store('chatName') || '';
  }

  var data = null, fetchedAt = 0, drafts = {}, changing = {}, notes = {}, sending = {}, pending = {}, opened = {}, pastOpen = {};
  // a link to /polls/#poll-ID opens that past poll
  var hashId = /^#poll-(\d+)$/.exec((typeof location !== 'undefined' && location.hash) || '');
  if (hashId) pastOpen[hashId[1]] = true;

  // An option's details (benefits and consequences; viewer LimeLight's idea): a toggle on the card, shown on /polls/.
  function details(p, i) {
    var d = (p.details || [])[i];
    if (!d) return '';
    if (mode === 'page') return '<p class="poll-det-text small">' + esc(d) + '</p>';
    return '<details class="poll-det"' + (opened[p.id + ':' + i] ? ' open' : '') + '><summary class="small" data-det="' + i +
      '">Details</summary><p class="small">' + esc(d) + '</p></details>';
  }

  function results(p, my) {
    var max = Math.max.apply(null, p.counts.concat([1]));
    return '<ol class="poll-results">' + p.options.map(function (o, i) {
      var n = p.counts[i] || 0, pct = p.total ? Math.round(100 * n / p.total) : 0;
      // viewers' and agents' votes apart (the bar: viewers, then agents), and together
      var v = (p.viewer_counts || p.counts)[i] || 0, a = (p.agent_counts || [])[i] || 0;
      var pv = p.total ? 100 * v / p.total : 0, pa = p.total ? 100 * a / p.total : 0;
      return '<li class="' + (i === my ? 'is-mine' : '') + (n === max && p.total ? ' is-top' : '') + '">' +
        '<span class="poll-opt">' + esc(o) + (i === my ? ' <span class="poll-mine">your vote</span>' : '') + '</span>' +
        '<span class="poll-n">' + n + ' · ' + pct + '%</span>' +
        '<span class="poll-bar" aria-hidden="true"><span class="pb-v" style="width:' + pv.toFixed(1) + '%"></span>' +
        '<span class="pb-a" style="width:' + pa.toFixed(1) + '%"></span></span>' +
        '<span class="poll-split small muted">viewers ' + v + ' · agents ' + a + '</span>' +
        (details(p, i) ? '<div class="poll-det-row">' + details(p, i) + '</div>' : '') + '</li>';
    }).join('') + '</ol>';
  }
  function comments(p) {
    if (!p.comments.length) return mode === 'page' ? '<p class="muted small">No comments yet.</p>' : '';
    if (mode !== 'page') return '';
    return '<h4>Comments</h4><ul class="poll-comments">' + p.comments.map(function (c) {
      return '<li' + (c.agent ? ' class="is-agent"' : '') + '><b>' + esc(c.name) + '</b>' + (c.agent ? ' <span class="poll-ai">AI</span>' : '') +
        ' <span class="poll-chose">' + esc(p.options[c.option] || '') + '</span> ' +
        '<span class="muted small">' + esc(when(c.t)) + '</span><br>' + esc(c.comment) + '</li>';
    }).join('') + '</ul>';
  }
  function pollHtml(p, elapsed) {
    var my = mine()[p.id];
    my = typeof my === 'number' && my >= 0 && my < p.options.length ? my : null;
    var open = p.status === 'open' && p.left_s - elapsed > 0;
    var ask = open && (my === null || changing[p.id]);
    var head = '<header class="poll-head"><span class="poll-tag">' + (open ? 'POLL' : 'POLL CLOSED') + '</span> <span class="muted small">' +
      (open ? esc(left(p.left_s - elapsed)) : 'closed ' + esc(when(p.closes))) + '</span></header>';
    var body;
    if (ask) {
      var own = mode === 'page' || !document.querySelector('#vchat-form [name=name]');
      body = '<div class="poll-ask">' +
        (own ? '<input class="fx-textfield" name="poll-name" maxlength="20" placeholder="Name" aria-label="Your name" value="' + esc(nameNow()) + '">' : '') +
        '<input class="fx-textfield poll-comment" name="poll-comment" maxlength="200" placeholder="Comment (optional)" aria-label="Comment" value="' +
        esc(drafts[p.id] || '') + '"><div class="poll-opts">' + p.options.map(function (o, i) {
          return '<div class="poll-choice"><button class="fx-btn' + (i === my ? ' is-mine' : '') + '" type="button" data-vote="' + i + '"' +
            (sending[p.id] ? ' disabled' : '') + '>' + esc(o) + '</button>' + details(p, i) + '</div>';
        }).join('') + '</div></div>';
    } else {
      body = results(p, my) + (open ? '<button class="fx-btn poll-change" type="button" data-change="1">Change my vote</button>' : '');
    }
    return '<article class="poll" data-poll="' + p.id + '">' + head + '<h3 class="poll-q">' + esc(p.question) + '</h3>' +
      (p.intro ? '<p class="poll-intro">' + esc(p.intro) + '</p>' : '') + body +
      '<p class="poll-note small muted" aria-live="polite">' + esc(notes[p.id] || '') + '</p>' +
      '<p class="poll-foot small muted">' + p.total + (p.total === 1 ? ' vote' : ' votes') +
      (p.agent_counts ? ' (' + (p.viewer_total || 0) + ' from viewers, ' + (p.agent_total || 0) + ' from agents)' : '') +
      (p.comments.length ? ' · ' + p.comments.length + (p.comments.length === 1 ? ' comment' : ' comments') : '') +
      (mode === 'card' ? ' · <a href="/polls/">Comments and past polls</a>' : '') + '</p>' + comments(p) + '</article>';
  }

  function render() {
    if (!list) return;
    var el = document.activeElement;
    if (el && el.name && /^poll-/.test(el.name) && root.contains && root.contains(el)) return;  // not while typing
    var elapsed = (Date.now() - fetchedAt) / 1000;
    if (!data) {
      if (mode === 'page') list.innerHTML = '<p class="muted">Polls are unavailable right now.</p>';
      else root.hidden = true;
      return;
    }
    var open = data.open || [], closed = data.closed || [];
    if (window.PogNav) window.PogNav.polls(open.length);  // the nav's "open" (site.js)
    if (mode === 'card') {
      // d17 08:30: the card shows open polls only. With none open: one line for a poll closed in the past day
      // (its winner, a link to the past polls), else nothing.
      if (open.length) {
        root.hidden = false;
        list.innerHTML = open.map(function (p) { return pollHtml(p, elapsed); }).join('');
        return;
      }
      var last = closed.filter(function (p) { return data.now - p.closes < 86400; })[0];
      root.hidden = !last;
      list.innerHTML = last ? '<p class="polls-past-line small"><a href="/polls/#past">Past polls</a> <span class="muted">· last: ' +
        esc(last.question) + ' (' + esc(winner(last)) + ')</span></p>' : '';
      return;
    }
    // /polls/: open polls in full, then "Past polls", each closed one collapsed to a line (question, when, winner)
    list.innerHTML = '<h2>Open</h2>' + (open.length ? open.map(function (p) { return pollHtml(p, elapsed); }).join('')
      : '<p class="muted">No poll is open right now.</p>') +
      '<h2 id="past">Past polls</h2>' + (closed.length ? closed.map(pastHtml).join('') : '<p class="muted">None yet.</p>');
  }

  // A closed poll's result in words: "won: OPTION", "tie: A / B", or "no votes"
  function winner(p) {
    if (!p.total) return 'no votes';
    var max = Math.max.apply(null, p.counts), top = [];
    p.options.forEach(function (o, i) { if (p.counts[i] === max) top.push(o); });
    return (top.length > 1 ? 'tie: ' + top.join(' / ') : 'won: ' + top[0]) + ', ' + max + ' of ' + p.total + (p.total === 1 ? ' vote' : ' votes');
  }
  function pastHtml(p) {
    return '<details class="poll-past" id="poll-' + p.id + '"' + (pastOpen[p.id] ? ' open' : '') + '><summary data-past="' + p.id + '">' +
      '<span class="poll-past-q">' + esc(p.question) + '</span> <span class="poll-past-meta small muted">closed ' + esc(when(p.closes)) +
      ' · ' + esc(winner(p)) + '</span></summary>' + pollHtml(p, 0) + '</details>';
  }

  function find(id) {
    var all = data ? (data.open || []).concat(data.closed || []) : [];
    for (var i = 0; i < all.length; i++) if (all[i].id === id) return all[i];
    return null;
  }
  function replace(p) {
    if (!data || !p) return;
    ['open', 'closed'].forEach(function (k) {
      data[k] = (data[k] || []).map(function (x) { return x.id === p.id ? Object.assign({}, p, { left_s: p.left_s + (Date.now() - fetchedAt) / 1000 }) : x; });
    });
  }

  var loading = false;
  function load() {
    if (!API || loading) return;
    loading = true;
    fetch(API + '/v1/polls', { cache: 'no-store' })
      .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
      .then(function (d) { data = d; fetchedAt = Date.now(); })
      .catch(function () { if (Date.now() - fetchedAt > 5 * 60 * 1000) data = null; })  // a short outage keeps the last
      .then(function () { loading = false; render(); });
  }

  function closest(el, attr) {
    while (el && el !== root) { if (el.getAttribute && el.getAttribute(attr) != null) return el; el = el.parentNode; }
    return null;
  }
  function vote(art, id, option) {
    if (sending[id] || !API) return;
    var body = { option: option, name: nameNow(art) };
    var c = art.querySelector('[name=poll-comment]');
    body.comment = c ? c.value.trim() : '';
    var key = option + '|' + body.comment + '|' + body.name;
    if (!pending[id] || pending[id].key !== key) pending[id] = { key: key, cid: newCid() };
    body.cid = pending[id].cid;
    if (body.name) store('chatName', body.name);
    sending[id] = true; notes[id] = 'Sending…'; render();
    fetch(API + '/v1/polls/' + id + '/vote', { method: 'POST', headers: postHeaders(), body: JSON.stringify(body) })
      .then(function (r) { return r.json().then(function (d) { return { ok: r.ok, d: d }; }); })
      .then(function (res) {
        if (!res.ok) {
          var e = res.d && res.d.error ? String(res.d.error) : 'could not vote';
          notes[id] = e.charAt(0).toUpperCase() + e.slice(1) + (res.d && res.d.retry_after_s ? ' (try again in ' + res.d.retry_after_s + ' s)' : '') + '.';
          return;
        }
        pending[id] = null; drafts[id] = ''; changing[id] = false;
        remember(id, res.d.vote ? res.d.vote.option : option);
        notes[id] = res.d.replaced ? 'Vote changed.' : 'Thanks, your vote counts.';
        replace(res.d.poll);
      })
      .catch(function () { notes[id] = 'Could not send. Check your connection.'; })
      .then(function () { sending[id] = false; render(); });
  }

  root.addEventListener('click', function (ev) {
    var past = closest(ev.target, 'data-past');
    if (past) { var pid = past.getAttribute('data-past'); pastOpen[pid] = !pastOpen[pid]; return; }  // kept across refreshes
    var art = closest(ev.target, 'data-poll');
    if (!art) return;
    var id = parseInt(art.getAttribute('data-poll'), 10);
    var b = closest(ev.target, 'data-vote');
    if (b) { vote(art, id, parseInt(b.getAttribute('data-vote'), 10)); return; }
    if (closest(ev.target, 'data-change')) { changing[id] = true; notes[id] = ''; render(); return; }
    var det = closest(ev.target, 'data-det');
    if (det) { var k = id + ':' + det.getAttribute('data-det'); opened[k] = !opened[k]; }  // kept across refreshes
  });
  root.addEventListener('input', function (ev) {
    var t = ev.target, art = closest(t, 'data-poll');
    if (art && t.name === 'poll-comment') drafts[parseInt(art.getAttribute('data-poll'), 10)] = t.value;
  });
  root.addEventListener('focusout', function () { setTimeout(render, 0); });

  // A viewer's poll idea (the /polls/ page): question and 2-6 options; only the operator sees it.
  var idea = document.getElementById('poll-idea');
  if (idea) {
    var ideaNote = idea.querySelector('.poll-idea-note'), ideaCid = null, ideaKey = null, ideaSending = false;
    var nm = idea.querySelector('[name=name]');
    if (nm && !nm.value) nm.value = store('chatName') || '';
    idea.addEventListener('submit', function (ev) {
      ev.preventDefault();
      if (!API || ideaSending) { if (!API) ideaNote.textContent = 'Ideas are unavailable right now.'; return; }
      var opts = [];
      for (var i = 1; i <= 6; i++) { var o = idea.querySelector('[name=option' + i + ']'); if (o && o.value.trim()) opts.push(o.value.trim()); }
      var hrs = idea.querySelector('[name=hours]');
      var body = { name: nm ? nm.value.trim() : '', question: idea.querySelector('[name=question]').value.trim(), options: opts };
      if (hrs && hrs.value) body.hours = Number(hrs.value);
      if (opts.length < 2) { ideaNote.textContent = 'At least two options, please.'; return; }
      var key = JSON.stringify(body);
      if (key !== ideaKey) { ideaKey = key; ideaCid = newCid(); }
      body.cid = ideaCid;
      if (body.name) store('chatName', body.name);
      ideaSending = true; ideaNote.textContent = 'Sending…';
      fetch(API + '/v1/polls/suggest', { method: 'POST', headers: postHeaders(), body: JSON.stringify(body) })
        .then(function (r) { return r.json().then(function (d) { return { ok: r.ok, d: d }; }); })
        .then(function (res) {
          if (!res.ok) {
            var e = res.d && res.d.error ? String(res.d.error) : 'could not send';
            ideaNote.textContent = e.charAt(0).toUpperCase() + e.slice(1) + '.';
            return;
          }
          ideaNote.textContent = 'Sent to the operator. Thanks.';
          ideaKey = null;
          ['question', 'option1', 'option2', 'option3', 'option4', 'option5', 'option6', 'hours'].forEach(function (n) {
            var f = idea.querySelector('[name=' + n + ']'); if (f) f.value = '';
          });
        })
        .catch(function () { ideaNote.textContent = 'Could not send. Check your connection.'; })
        .then(function () { ideaSending = false; });
    });
  }

  if (!API) { render(); return; }
  load();
  setInterval(function () { if (!document.hidden) load(); }, REFRESH);
  setInterval(render, 30000);  // the time left
})();
