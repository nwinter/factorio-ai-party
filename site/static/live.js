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
  // A team agent's portrait (viewer syndesis, 22:13) takes focus and carries data-agent: hovering, focusing or tapping
  // it shows the agent's plan line and job (planTip below); a click, Enter or a second tap scrolls to its line in the
  // Team plan.
  var team = {};  // the agents of the last state, by name
  function avatar(a, size) {
    var name = String(a.name || a.agent || 'agent');
    var row = { name: name, display_name: a.display_name, color: safeColor(a.color), avatar: a.avatar };
    var px = size || 24;
    var cls = 'fx-slot avatar' + (px <= 24 ? ' sm' : '');
    var who = team[name] ? ' data-agent="' + esc(name) + '" tabindex="0" role="button" aria-label="' +
      esc((team[name].display_name || name) + ': plan line and job') + '"' : ' aria-hidden="true"';
    if (window.PogAvatar) return '<span class="' + cls + '"' + who + '>' + window.PogAvatar.svg(row, px, { title: '' }) + '</span>';
    return '<span class="fx-slot avatar sm letter"' + who + '>' + esc((a.display_name || a.name || '?').charAt(0)) + '</span>';
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
  var lastSeq = null, chatTimer = null, chatMsgs = [], ytLines = [], replyLines = [], delivery = {};
  // Agents' and the Operator's lines that answer a viewer or speak to the viewers (state.viewer_replies: tools/stream/
  // viewer_replies.py; d15 08:07: what the models said back stays readable after it scrolled past live). Shown
  // unless the reader unticks them (remembered per browser).
  var showReplies = store('chatReplies') !== '0';
  var THREAD_S = 20 * 60, NEW_S = 10 * 60;  // (AK6) a reply threads under a line at most THREAD_S older; "new" for NEW_S
  // The viewer line a reply answers, in this list: the same viewer, the same words (the relay's "@astra " stripped,
  // its cut "…" too), written before the reply.
  // every leading @name (AA2: "@Muse @Luna Could ..." on the site, "@Luna Could ..." in the reply's quote)
  function bareText(s) { return String(s || '').replace(/^(?:@\S+\s+)+/, '').replace(/(?:…|\.\.\.)$/, '').trim().toLowerCase(); }
  function answered(list, r) { return sourceAt(list, r.answers, r.t); }
  // (d22 batch75 AK6) every line a reply answers: answers, then also (one reply to several lines)
  function sources(r) { return [r.answers].concat(Array.isArray(r.also) ? r.also : []).filter(function (a) { return a && a.name; }); }
  // Where in the list the line `a` (a reply's answers or also) is, or -1: by the id it was written under (the Operator's
  // named line, AA2; AK6: every relayed line keeps it through the harness), else the same viewer and words before t.
  function sourceAt(list, a, t) {
    if (!a || !a.name) return -1;
    var id = /^site:(\d+)$/.exec(String(a.id || ''));
    if (id) {
      for (var j = list.length - 1; j >= 0; j--) if (list[j].src === 'site' && String(list[j].seq) === id[1]) return j;
    }
    if (/^yt:/.test(String(a.id || ''))) {
      for (var y = list.length - 1; y >= 0; y--) if (list[y].src === 'yt' && list[y].k === 'y' + a.id) return y;
    }
    var r = { t: t };
    var name = String(a.name).toLowerCase(), body = bareText(a.text);
    for (var i = list.length - 1; i >= 0; i--) {
      var m = list[i];
      if (m.src === 'agent' || String(m.name || '').toLowerCase() !== name || (m.t || 0) > (r.t || 0) + 5) continue;
      var mine = bareText(m.text);
      if (body && mine && (mine.indexOf(body) === 0 || body.indexOf(mine) === 0)) return i;
    }
    return -1;
  }
  function joinedChat() {
    var all = chatMsgs.map(function (m) { return { src: m.channel === 'viewers' ? 'viewers' : 'site', name: m.name, text: m.text, t: m.t, k: 's' + m.seq, seq: m.seq, host: m.host === true }; })
      .concat(ytLines.map(function (m) { return { src: 'yt', name: m.name, text: m.text, t: m.t, k: 'y' + m.id, host: m.host === true }; }));
    all.sort(function (a, b) { return (a.t || 0) - (b.t || 0) || (a.k < b.k ? -1 : 1); });
    all = all.slice(-150);
    // (d20 batch65 AA1, viewer Aurora 04:06) the line an Operator reply answers shows "Operator replied", the replies
    // shown or not
    replyLines.forEach(function (r) {
      if (r.by !== 'operator' || r.kind !== 'reply') return;
      var at = answered(all, r);
      if (at >= 0 && (!all[at].opReply || (r.t || 0) < (all[at].opReply.t || 0))) all[at].opReply = { seq: r.seq, t: r.t };
    });
    if (!showReplies || !replyLines.length) return all;
    // A reply goes right after the viewer line it answers (after earlier replies to it) when that line is in the list
    // and at most THREAD_S older; else in time order among the rest (AK6: "Keep new replies easy to spot without
    // scattering unrelated conversations": a reply to an old line stays at the bottom, with its quote that jumps to it).
    // Each line answered counts its replies (the first one's key: a jump to it).
    var first = all.length ? all[0].t || 0 : 0;
    replyLines.slice().sort(function (a, b) { return (a.t || 0) - (b.t || 0); }).forEach(function (r) {
      if ((r.t || 0) < first) return;
      var item = { src: 'agent', by: r.by, name: r.by, text: r.text, t: r.t, k: 'a' + r.seq, to: r.to || [], kind: r.kind, history: r.history === true,
        link: r.link, answers: r.answers, also: r.also, part: r.part, quotes: [] };
      var at = -1;
      sources(r).forEach(function (a, n) {
        var i = sourceAt(all, a, r.t);
        item.quotes.push({ a: a, k: i >= 0 ? all[i].k : null });
        if (i < 0) return;
        all[i].replies = all[i].replies || { n: 0, first: item.k };
        all[i].replies.n++;
        if (n === 0) at = i;
      });
      if (at >= 0 && (r.t || 0) - (all[at].t || 0) <= THREAD_S) {
        item.thread = true;
        while (at + 1 < all.length && all[at + 1].src === 'agent' && all[at + 1].thread) at++;
        all.splice(at + 1, 0, item);
        return;
      }
      item.away = !!(r.answers && r.answers.name);  // linked to a line this list does not show, or one long before
      var i = all.length;
      while (i > 0 && (all[i - 1].t || 0) > (item.t || 0)) i--;
      all.splice(i, 0, item);
    });
    return all;
  }
  // (d20 batch57 S1, viewer Aurora 15:24: "Could replies link to ... only the question they answer?") how a reply found
  // its line (state.viewer_replies link: tools/stream/viewer_replies.py): reply_to (the agent named it), the viewer's only
  // line in the 15 minutes before, their only one to this agent, or the time the Operator's reply names; "none": shown in
  // time order, linked to no line. A line this list does not show is quoted.
  function linkHtml(m) {
    var how = linkInner(m);
    return how ? ' <span class="c-link c-link-' + esc(m.link) + ' fx-muted">' + how + '</span>' : '';
  }
  // (AK8) the same words (HTML: the name escaped) for a reply's Details
  function linkInner(m) {
    if (m.kind !== 'reply' || !m.link) return '';
    var a = m.answers || {}, who = esc(a.name || '');
    var how = m.link === 'none' ? 'not linked to a question'
      : m.link === 'only_line' ? 'matched by name: ' + who + "'s only recent line"
      : m.link === 'only_to' ? 'matched by name: ' + who + "'s only recent line to " + esc(m.by === 'operator' ? 'the Operator' : agentName(m.by))
      : m.link === 'time' ? 'matched by the time it names'
      : m.link === 'name' ? 'linked by name: ' + who + "'s open line to " + esc(m.by === 'operator' ? 'the Operator' : agentName(m.by))
      : m.link === 'reply_to' ? 'linked by the reply itself: it named this line (reply_to)'
      : '';
    return how;
  }
  // (d22 batch75 AK6, viewer Aurora site:4176: "Could replies show a short clickable quote of the source message, with a
  // reply count on the original?") over a reply, a short quote of each line it answers: a button to that line when the
  // list shows it, else the quote alone
  var QUOTE = 70;
  function quotesHtml(m) {
    var q = (m.quotes || []).map(function (x) {
      var t = bareText(x.a.text) ? String(x.a.text).replace(/^(?:@\S+\s+)+/, '') : '';
      var body = '↪ ' + x.a.name + (t ? ': “' + (t.length > QUOTE ? t.slice(0, QUOTE - 1) + '…' : t) + '”' : '');
      return x.k ? '<button type="button" class="c-quote" data-jump="' + esc(x.k) + '" title="to the line it answers">' + esc(body) + '</button>'
        : '<span class="c-quote c-quote-away fx-muted" title="not in this list">' + esc(body) + '</span>';
    }).join('');
    return q ? '<span class="c-quotes">' + q + '</span>' : '';
  }
  // the reply count on a line answered: a button to its first reply
  function repliesHtml(m) {
    if (!m.replies || !m.replies.n) return '';
    return ' <button type="button" class="c-replies" data-jump="' + esc(m.replies.first) + '" title="to the first reply">' + esc('· ' + m.replies.n + (m.replies.n === 1 ? ' reply' : ' replies')) + '</button>';
  }
  // (d22 batch75 AK8, viewer Aurora site:4249/4250: "For replies directly under their actual parent question, remove the
  // repeated quote and use a compact header. Keep delivery status visible, with context links for standalone replies."
  // and "Put a small Details button in each header for routing and matching info. Keep full replies visible, put reply
  // counts inline and tighten spacing. Preserve open details and scroll on refresh.") A reply threaded under its line:
  // no quote of that line (its other lines' quotes stay), a one-line header (who, when, to whom, new), its full text
  // below; a reply standing alone keeps its quotes, links to the lines it answers. Each header has a Details button:
  // the routing and matching (to whom, the lines it answers with their ids and deliveries, how it was linked, its part,
  // history). Open details and the list's scroll are kept across re-renders and page reloads (this tab's sessionStorage).
  function sess(k, v) { try { if (v === undefined) return sessionStorage.getItem(k); sessionStorage.setItem(k, v); } catch (e) { return null; } }
  var openDetails = {};
  (function () { try { (JSON.parse(sess('chatDetails') || '[]') || []).forEach(function (k) { openDetails[k] = 1; }); } catch (e) { /* none kept */ } })();
  function keepDetails() { sess('chatDetails', JSON.stringify(Object.keys(openDetails).slice(-50))); }
  function detailsHtml(m) {
    var rows = [], row = function (r) { rows.push('<span class="c-det-row">' + esc(r) + '</span>'); };
    if (m.to && m.to.length) row((m.kind === 'to_viewers' ? 'to the viewers, naming ' : 'to ') + m.to.join(', '));
    (m.quotes || []).forEach(function (x) {
      var a = x.a || {}, id = a.id ? ' (' + a.id + ')' : '';
      var seq = /^site:(\d+)$/.exec(String(a.id || '')), d = seq ? delivery[seq[1]] : null;
      var went = d && d.s ? '; that line: ' + (d.s === 'relayed' ? 'delivered to ' + ((Array.isArray(d.to_all) && d.to_all.length ? d.to_all : d.to ? [d.to] : []).map(agentName).join(', ') || 'the agents')
        : d.s === 'operator' ? 'delivered to the Operator' : d.s + (d.why ? ': ' + d.why : '')) : '';
      row('answers ' + a.name + id + (x.k ? '' : ', not in this list') + went);
    });
    // how it was linked (linkInner: HTML, the name escaped)
    var link = linkInner(m);
    if (link) rows.push('<span class="c-det-row c-link c-link-' + esc(m.link) + '">' + link + '</span>');
    else if (m.kind === 'reply' && m.link) row('linked: ' + m.link);
    if (Array.isArray(m.part) && m.part.length === 2 && m.part[1] > 1) row('part ' + m.part[0] + ' of ' + m.part[1]);
    if (m.history) row('read again after a stream service restart (history)');
    return rows.join('');
  }
  function replyHtml(m, t) {
    var a = m.by === 'operator' ? { name: 'operator', display_name: 'Operator' } : (team[m.by] || { name: m.by });
    var col = m.by === 'operator' ? null : acColor(safeColor(a.color));
    var who = esc(a.display_name || a.name || m.by);
    var key = m.k.slice(1);
    // threaded: the line above is the first one it answers, so that quote is not repeated
    var shown = m.thread ? { k: m.k, kind: m.kind, quotes: (m.quotes || []).slice(1) } : m;
    var tag = m.kind === 'to_viewers' ? ' <span class="c-src c-src-agent">TO VIEWERS</span>' : m.thread ? '' : ' <span class="c-src c-src-agent">REPLY</span>';
    var to = m.to && m.to.length ? ' <span class="c-to fx-muted">↩ ' + esc(m.to.join(', ')) + '</span>' : '';
    // (d19 batch42 A5, viewer Aurora) a reply read again at a stream restart keeps its own time and says it is history
    if (m.history) to += ' <span class="c-history fx-muted" title="said before the stream service restarted">history</span>';
    // (AA2) one of a split reply's parts
    if (Array.isArray(m.part) && m.part.length === 2 && m.part[1] > 1) to += ' <span class="c-part fx-muted">' + esc(m.part[0]) + '/' + esc(m.part[1]) + '</span>';
    // (AK6) a reply from the last NEW_S: marked new
    var fresh = !m.history && m.t && Date.now() / 1000 - m.t < NEW_S;
    if (fresh) to += ' <span class="c-new-tag">new</span>';
    var open = openDetails[key] === 1;
    var det = detailsHtml(m);
    var btn = det ? ' <button type="button" class="c-details-btn" data-det="' + esc(key) + '" aria-expanded="' + open + '" aria-controls="cd-' + esc(key) + '" title="routing and matching">Details</button>' : '';
    return '<li class="c-agent' + (m.thread ? ' c-thread' : ' c-alone') + (m.history ? ' c-hist' : '') + (fresh ? ' c-new' : '') + '" id="c-a' + esc(key) + '"' + (col ? ' style="--ac:' + col + '"' : '') +
      '>' + quotesHtml(shown) + '<span class="c-head"><b class="c-agent-name">' + who + '</b> <span class="c-time">' + esc(t) + '</span>' + tag + to + btn + '</span>' +
      (det ? '<span class="c-details fx-muted" id="cd-' + esc(key) + '"' + (open ? '' : ' hidden') + '>' + det + '</span>' : '') +
      '<span class="c-text">' + esc(m.text) + '</span></li>';
  }
  // A site line's delivery: "to Sol", "to Sol, Luna", "held", "to the Operator", "not relayed: why" (the viewers-only
  // lines never go). (d19 batch42 A3, A4, viewer Aurora) a line in the operator's inbox shows that receipt on its own,
  // beside what became of the agents' copy; a group line names every recipient. (d20 batch65 AA1, viewer Aurora 04:06:
  // "Could chat show confirmed Operator inbox delivery separately from game relay rejection?") a line the Operator
  // answered shows "Operator replied", a button to that reply; one to the Operator alone is never "not relayed".
  function agentName(n) { return team[n] && team[n].display_name || n; }
  function hm(t) { return new Date(t * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }); }
  function operatorHtml(m, d) {
    var why = d && d.s === 'operator' && d.why && d.why !== "to the operator's inbox" ? ' (' + d.why + ')' : '';
    if (m.opReply) {
      var lbl = 'Operator replied' + (m.opReply.t ? ' at ' + hm(m.opReply.t) : '');
      return ' <button type="button" class="c-delivery c-delivery-replied" data-reply="' + esc(m.opReply.seq) + '">' + esc(lbl) + '</button>' +
        (why ? '<span class="c-delivery c-delivery-operator fx-muted">' + esc(why) + '</span>' : '');
    }
    if (!d || !(d.s === 'operator' || d.op)) return '';
    return ' <span class="c-delivery c-delivery-operator fx-muted">' + esc('delivered to the Operator' + why) + '</span>';
  }
  // (d20 batch65 AA5, viewer Aurora 09:46: "Could messages sent between shifts stay queued until delivery, with
  // queued/delivered/expired labels?") A site line past the seq the stream service has read up to (state.viewer_read)
  // is queued: read when the service runs again (a new shift or a restart reads every line it missed); when the state
  // is old, the service is not running and the label says so.
  var readUpTo = null, serviceLive = true;
  function isQueued(m) {
    return m.src === 'site' && readUpTo != null && m.seq > readUpTo && !(delivery[m.seq] && delivery[m.seq].s);
  }
  function deliveryHtml(m) {
    var d = m.src === 'site' ? delivery[m.seq] : null;
    if (isQueued(m)) {
      return operatorHtml(m, null) + ' <span class="c-delivery c-delivery-queued fx-muted">' + esc(serviceLive ? 'queued' :
        'queued: the stream service is not running (between shifts or restarting); it reads this line when it starts') + '</span>';
    }
    if (!d || !d.s) return operatorHtml(m, null);
    var who = Array.isArray(d.to_all) && d.to_all.length ? d.to_all : d.to ? [d.to] : [];
    // (d20 batch57 S5, operator 19:12) a record lost at a stream service restart says so; one read back after a restart says
    // when it was sent when that was a minute or more after the line
    var sent = d.at && isFinite(d.at) && m.t && d.at - m.t >= 60 ? ' (sent ' + new Date(d.at * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) + ')' : '';
    if (d.s === 'operator') return operatorHtml(m, d);
    var txt = d.s === 'relayed' && d.lost ? 'delivered to the agents (details lost at a stream service restart)'
      : d.s === 'relayed' ? (who.length ? 'delivered to ' + who.map(agentName).join(', ') : 'delivered to the agents') + sent + (d.why ? ': ' + d.why : '')
      : d.s === 'held' ? 'held' + (d.why ? ': ' + d.why : '')
      : d.s === 'expired' ? 'expired' + (d.why ? ': ' + d.why : '')
      : 'not relayed' + (d.why ? ': ' + d.why : '');
    var html = ' <span class="c-delivery c-delivery-' + esc(d.s) + ' fx-muted">' + esc(txt) + '</span>';
    return operatorHtml(m, d) + html;
  }
  function renderChat() {
    if (!chatList) return;
    var all = joinedChat(), sig = all.map(function (m) { var d = m.src === 'site' && delivery[m.seq]; return m.k + (d ? ':' + d.s + (d.op ? '+op' : '') + (d.to_all ? '+' + d.to_all.length : '') + (d.why ? '+' + d.why.length : '') : '') + (m.opReply ? '+r' + m.opReply.seq : '') + (isQueued(m) ? '+q' + serviceLive : '') + (m.replies ? '+n' + m.replies.n : '') + (m.thread ? '+t' : ''); }).join(',');
    if (chatList.dataset.sig === sig) return;  // nothing new: keep the reader's scroll
    chatList.dataset.sig = sig;
    var atEnd = chatList.scrollHeight - chatList.scrollTop - chatList.clientHeight < 40;
    // (AK8) the line at the top of the view and how far down it sits, to put back after the list is rebuilt; on the
    // first render after a reload, the one this tab kept (unless it was at the end)
    var anchor = !atEnd && chatList.dataset.seen ? topLine() : null;
    chatList.innerHTML = all.length ? all.map(function (m) {
      var t = new Date(m.t * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
      if (m.src === 'agent') return replyHtml(m, t);
      var src = m.host ? 'host' : m.src;
      return '<li class="c-' + m.src + (m.host ? ' c-host' : '') + '" id="c-' + esc(m.k) + '"><span class="c-time">' + esc(t) + '</span> <span class="c-src c-src-' + src + '">' +
        (m.host ? 'HOST' : m.src === 'yt' ? 'YT' : m.src === 'viewers' ? 'VIEWERS' : 'SITE') + '</span> <b>' + esc(m.name) + '</b> <span class="c-text">' + esc(m.text) + '</span>' +
        deliveryHtml(m) + repliesHtml(m) + '</li>';
    }).join('') : '<li class="fx-muted">No messages yet. Say hello.</li>';
    // the place this tab kept: once its line is in the list (the replies come with the state, after the first chat
    // poll), within 15 s of loading and until the reader scrolls
    if (keptScroll && Date.now() < keptUntil) { if (document.getElementById(keptScroll.id)) { anchor = keptScroll; keptScroll = null; } }
    else keptScroll = null;
    var back = anchor && document.getElementById(anchor.id);
    if (back) chatList.scrollTop += back.getBoundingClientRect().top - chatList.getBoundingClientRect().top - anchor.off;
    else if (atEnd || !chatList.dataset.seen) chatList.scrollTop = chatList.scrollHeight;
    chatList.dataset.seen = '1';
  }
  // (AK8) the first line whose bottom is in view: its id and its top's distance from the list's top
  function topLine() {
    var top = chatList.getBoundingClientRect().top, li = chatList.children;
    for (var i = 0; i < li.length; i++) {
      var r = li[i].getBoundingClientRect();
      if (r.bottom > top + 1 && li[i].id) return { id: li[i].id, off: r.top - top };
    }
    return null;
  }
  var keptScroll = (function () {
    try { var k = JSON.parse(sess('chatScroll') || 'null'); return k && !k.end && k.id ? k : null; } catch (e) { return null; }
  })(), keptUntil = Date.now() + 15000;
  var scrollKeep = null;
  if (chatList) ['wheel', 'touchstart', 'keydown', 'mousedown'].forEach(function (e) { chatList.addEventListener(e, function () { keptScroll = null; }, { passive: true }); });
  if (chatList) chatList.addEventListener('scroll', function () {
    if (keptScroll) return;  // not yet put back: the kept place stays
    clearTimeout(scrollKeep);
    scrollKeep = setTimeout(function () {
      var end = chatList.scrollHeight - chatList.scrollTop - chatList.clientHeight < 40, at = end ? null : topLine();
      sess('chatScroll', JSON.stringify(end ? { end: true } : at ? { id: at.id, off: at.off } : { end: true }));
    }, 150);
  });
  // One poll at a time (joonazan, d15 08:05: "the site sends messages twice quite often"): a send and a tab switch
  // each called pollChat while a poll was in flight, both appended the same new messages, and each started its own
  // timer, so polls ran in parallel from then on. A call during a poll now asks for one more after it, and messages
  // merge by seq.
  var polling = false, pollAgain = false;
  function mergeChat(list, add) {
    var seen = {};
    list.forEach(function (m) { seen[m.seq] = 1; });
    (add || []).forEach(function (m) { if (!seen[m.seq]) { seen[m.seq] = 1; list.push(m); } });
    list.sort(function (a, b) { return a.seq - b.seq; });
    return list;
  }
  function pollChat() {
    clearTimeout(chatTimer);
    if (!API || demo) { chatNote.textContent = demo ? 'Chat is off in the sample view.' : 'Chat is not configured.'; return; }
    if (polling) { pollAgain = true; return; }
    polling = true; pollAgain = false;
    var visible = !app.querySelector('[data-pane="site"]').hidden;
    // channels=all: the viewers-only lines too (the Worker leaves them out for the relay to the game)
    getJSON(API + '/v1/chat' + (lastSeq != null ? '?after=' + lastSeq : '?limit=60') + '&channels=all').then(function (d) {
      var hidden = {}; (d.hidden || []).forEach(function (s) { hidden[s] = 1; });
      chatMsgs = mergeChat(chatMsgs.filter(function (m) { return !hidden[m.seq]; }), d.messages);
      if (d.messages && d.messages.length) lastSeq = Math.max(lastSeq || 0, d.messages[d.messages.length - 1].seq);
      else if (lastSeq == null) lastSeq = d.last_seq || 0;
      chatForm.hidden = d.open === false;
      if (d.open === false) chatNote.textContent = 'Chat is closed right now.';
      renderChat();
    }).catch(function () { chatNote.textContent = 'Chat is unavailable right now.'; })
      .then(function () {
        polling = false;
        clearTimeout(chatTimer);
        if (pollAgain) { pollChat(); return; }
        chatTimer = setTimeout(pollChat, document.hidden || !visible ? 20000 : 4000);
      });
  }
  var repliesBox = $('#vchat-replies');
  if (repliesBox) {
    repliesBox.checked = showReplies;
    repliesBox.addEventListener('change', function () {
      showReplies = repliesBox.checked;
      store('chatReplies', showReplies ? '1' : '0');
      chatList.dataset.sig = '';
      renderChat();
    });
  }
  // "Operator replied" (AA1): to that reply in the list, showing the replies first when they are hidden
  if (chatList) chatList.addEventListener('click', function (ev) {
    // (AK8) a reply's Details: open or close in place, kept for later renders and a reload
    var dt = ev.target && ev.target.closest ? ev.target.closest('[data-det]') : null;
    if (dt) {
      var k = dt.getAttribute('data-det'), box = document.getElementById('cd-' + k);
      var open = !(openDetails[k] === 1);
      if (open) openDetails[k] = 1; else delete openDetails[k];
      keepDetails();
      dt.setAttribute('aria-expanded', String(open));
      if (box) box.hidden = !open;
      return;
    }
    // (AK6) a quote over a reply: to the line it answers; a reply count: to the first reply
    var j = ev.target && ev.target.closest ? ev.target.closest('[data-jump]') : null;
    if (j) {
      var to = document.getElementById('c-' + j.getAttribute('data-jump'));
      if (!to) return;
      if (to.scrollIntoView) to.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
      to.classList.add('is-flash');
      setTimeout(function () { to.classList.remove('is-flash'); }, 1600);
      return;
    }
    var b = ev.target && ev.target.closest ? ev.target.closest('[data-reply]') : null;
    if (!b) return;
    if (!showReplies) {
      showReplies = true;
      if (repliesBox) repliesBox.checked = true;
      chatList.dataset.sig = '';
      renderChat();
    }
    var el = document.getElementById('c-a' + b.getAttribute('data-reply'));
    if (!el) return;
    if (el.scrollIntoView) el.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    el.classList.add('is-flash');
    setTimeout(function () { el.classList.remove('is-flash'); }, 1600);
  });
  // The host link (d16 17:11): ?host=TOKEN once; kept in this browser, taken out of the address bar, and sent as
  // X-Host-Token with each chat post (never in a URL the page fetches). The Worker posts those lines under the host's
  // name with a HOST badge and refuses a token that does not match.
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
  var hostLine = $('#vchat-host'), hostForget = $('#vchat-host-forget');
  function showHost() {
    if (hostLine) hostLine.hidden = !hostToken;
    var nb = chatForm && chatForm.querySelector('[name=name]');
    if (nb) { nb.disabled = !!hostToken; if (hostToken) nb.placeholder = 'Host'; }
  }
  if (hostForget) hostForget.addEventListener('click', function () {
    hostToken = '';
    try { localStorage.removeItem('hostToken'); } catch (e) { /* nothing kept */ }
    showHost();
    if (chatNote) chatNote.textContent = 'Host link forgotten in this browser.';
  });
  showHost();
  if (chatForm) {
    var nameIn = chatForm.querySelector('[name=name]'), textIn = chatForm.querySelector('[name=text]');
    // Viewers only (viewer LimeLight555, d16 10:36): the line stays on this site, never sent to the agents or the
    // stream; remembered per browser
    var viewersBox = chatForm.querySelector('[name=viewers]');
    if (viewersBox) {
      viewersBox.checked = store('chatViewers') === '1';
      viewersBox.addEventListener('change', function () { store('chatViewers', viewersBox.checked ? '1' : '0'); });
    }
    var sendBtn = chatForm.querySelector('[type=submit]');
    nameIn.value = store('chatName') || '';
    // A message id made once per message and sent again on a retry: the worker stores a message once per id, so a
    // second press or a retry after a slow reply cannot post it twice. One send at a time.
    var sending = false, pending = null;  // pending: {text, cid} of the message not yet confirmed
    function newCid() {
      var b = new Uint8Array(12);
      try { crypto.getRandomValues(b); } catch (e) { for (var i = 0; i < b.length; i++) b[i] = Math.floor(Math.random() * 256); }
      return Array.prototype.map.call(b, function (x) { return ('0' + x.toString(16)).slice(-2); }).join('');
    }
    chatForm.addEventListener('submit', function (ev) {
      ev.preventDefault();
      if (!API || demo || sending) return;
      var body = { name: nameIn.value.trim(), text: textIn.value.trim() };
      if (viewersBox && viewersBox.checked) body.channel = 'viewers';
      if (!body.text) return;
      if (!pending || pending.text !== body.text || pending.channel !== body.channel) pending = { text: body.text, channel: body.channel, cid: newCid() };
      body.cid = pending.cid;
      store('chatName', body.name);
      sending = true; if (sendBtn) sendBtn.disabled = true;
      chatNote.textContent = 'Sending…';
      var headers = { 'Content-Type': 'application/json' };
      if (hostToken) headers['X-Host-Token'] = hostToken;
      fetch(API + '/v1/chat', { method: 'POST', headers: headers, body: JSON.stringify(body) })
        .then(function (r) { return r.json().then(function (d) { return { ok: r.ok, d: d }; }); })
        .then(function (res) {
          if (!res.ok) {
            if (hostToken && res.d && res.d.error === 'host link not valid') {
              chatNote.textContent = 'This host link is not valid, so nothing was sent. Use Forget above, or open the current host link.';
              return;
            }
            chatNote.textContent = (res.d && res.d.error ? label(res.d.error) : 'Could not send') +
              (res.d && res.d.retry_after_s ? ' (try again in ' + res.d.retry_after_s + ' s)' : '') + '.';
            return;
          }
          pending = null;
          if (res.d && res.d.message) chatMsgs = mergeChat(chatMsgs, [res.d.message]);
          if (textIn.value.trim() === body.text) textIn.value = '';
          // (d22 batch75 AK12) a blank name: the Worker's guest name for this poster ("Guest abcd"), said once
          chatNote.textContent = res.d && res.d.guest_name ? 'Sent as ' + res.d.guest_name + ' (type a name above to use your own).' : '';
          renderChat();
          pollChat();
        })
        .catch(function () { chatNote.textContent = 'Could not send. Check your connection.'; })
        .then(function () { sending = false; if (sendBtn) sendBtn.disabled = false; });
    });
  }
  // Share a blueprint (viewer LimeLight, d16 16:17): POST /v1/blueprints; the Mac pulls it into the agents' team-tools
  var bpForm = $('#bp-form'), bpNote = $('#bp-note');
  if (bpForm) {
    var bpSending = false, bpPending = null;
    bpForm.addEventListener('submit', function (ev) {
      ev.preventDefault();
      if (!API || demo || bpSending) return;
      var nameBox = chatForm && chatForm.querySelector('[name=name]');
      var body = { name: nameBox ? nameBox.value.trim() : '', title: bpForm.querySelector('[name=title]').value.trim(),
        string: bpForm.querySelector('[name=string]').value.replace(/\s+/g, '') };
      if (!body.title || !body.string) return;
      if (body.string.length > 1048576) { bpNote.textContent = 'Blueprint strings are at most 1 MB.'; return; }
      if (!bpPending || bpPending.string !== body.string) {
        var b = new Uint8Array(12);
        try { crypto.getRandomValues(b); } catch (e) { for (var i = 0; i < b.length; i++) b[i] = Math.floor(Math.random() * 256); }
        bpPending = { string: body.string, cid: Array.prototype.map.call(b, function (x) { return ('0' + x.toString(16)).slice(-2); }).join('') };
      }
      body.cid = bpPending.cid;
      bpSending = true;
      bpNote.textContent = 'Sending…';
      fetch(API + '/v1/blueprints', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
        .then(function (r) { return r.json().then(function (d) { return { ok: r.ok, d: d }; }); })
        .then(function (res) {
          if (!res.ok) {
            bpNote.textContent = (res.d && res.d.error ? label(res.d.error) : 'Could not send') +
              (res.d && res.d.retry_after_s ? ' (try again in ' + res.d.retry_after_s + ' s)' : '') + '.';
            return;
          }
          var bp = res.d.blueprint || {};
          bpPending = null;
          bpNote.textContent = 'Shared as #' + bp.id + ': ' + (bp.kind === 'blueprint_book' ? 'a book of ' + bp.blueprints +
            ' blueprints, ' : 'a blueprint, ') + bp.entities + ' entities. The agents get it within a few minutes.';
          bpForm.querySelector('[name=string]').value = '';
        })
        .catch(function () { bpNote.textContent = 'Could not send. Check your connection.'; })
        .then(function () { bpSending = false; });
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
  // The other planets' coarse maps (viewers craigNZ830 and Foobator, d15 07:05): state.planet_map brings one planet a
  // push (push_live.py), and planet_maps the others that fit; kept here by surface; a local state's planet_maps has them
  // all. (d20 batch50 D1, viewer Aurora: tabs disappeared and reset the selected planet) A planet a push leaves out keeps
  // its last map; the map viewer labels it with its age (mapview.js remember).
  // (d22 batch75 AK1, viewer Aurora: "Planet buttons and network layers disappear between refreshes") both kinds of map
  // are kept across page loads too (this browser's storage, KEPT_KEY): a page loaded while the stream service restarts
  // or the push stops has every planet's last map and networks map, and Nauvis's last basemap and the last clouds while
  // a state has none (keepLast). A map whose tick is past the state's (a world rolled back) goes; a planet the states this
  // page reads have left out for GONE_S goes; storage older than KEEP_S is not read.
  var KEPT_KEY = 'pog-live-kept', KEEP_S = 12 * 3600, GONE_S = 3600, LAST_SAVE_S = 60;
  var planetMaps = {}, netMaps = {}, unlisted = {}, last = {}, keptDirty = false, lastDirty = false, keptSaved = 0;
  (function () {
    var k;
    try { k = JSON.parse(store(KEPT_KEY) || 'null'); } catch (e) { k = null; }
    if (!k || typeof k !== 'object' || !(Date.now() / 1000 - k.saved < KEEP_S)) return;
    ['planets', 'nets'].forEach(function (kind) {
      var into = kind === 'planets' ? planetMaps : netMaps, from = k[kind] && typeof k[kind] === 'object' ? k[kind] : {};
      Object.keys(from).forEach(function (s) { if (from[s] && from[s].surface === s) into[s] = from[s]; });
    });
    if (k.unlisted && typeof k.unlisted === 'object') Object.keys(k.unlisted).forEach(function (s) { if (isFinite(k.unlisted[s])) unlisted[s] = k.unlisted[s]; });
    ['home', 'clouds'].forEach(function (x) { if (k.last && k.last[x] && isFinite(k.last[x].at) && k.last[x].v) last[x] = k.last[x]; });
  })();
  // (AK1) Nauvis's basemap and the clouds as the state has them, else the last this page had: {bm, home_held, clouds,
  // clouds_held} (held: seconds since it came; a basemap from past the state's tick goes)
  function keepLast(s) {
    var now = Date.now() / 1000, out = { bm: s.basemap || {}, clouds: Array.isArray(s.clouds) ? s.clouds : [] };
    if (last.home && isFinite(s.tick) && last.home.v.tick > s.tick) { delete last.home; keptDirty = true; }
    if (s.basemap && Array.isArray(s.basemap.rows)) { last.home = { at: now, v: s.basemap }; lastDirty = true; }
    else if (last.home) { out.bm = last.home.v; out.home_held = now - last.home.at; }
    if (out.clouds.length) { last.clouds = { at: now, v: out.clouds }; lastDirty = true; }
    else if (last.clouds) { out.clouds = last.clouds.v; out.clouds_held = now - last.clouds.at; }
    return out;
  }
  function keepIn(maps, m, grid) {
    if (!m || typeof m.surface !== 'string' || grid && !Array.isArray(m.rows)) return;
    var old = maps[m.surface];
    if (!old || !(old.tick > m.tick)) { maps[m.surface] = m; keptDirty = true; }
  }
  function keepPlanets(s) {
    keepIn(planetMaps, s.planet_map, true);
    if (s.planet_maps && typeof s.planet_maps === 'object') Object.keys(s.planet_maps).forEach(function (k) { keepIn(planetMaps, Object.assign({ surface: k }, s.planet_maps[k]), true); });
    return planetMaps;
  }
  // (d21 batch68 AD3) each planet's networks map: state.net_map brings one a push (push_live.py), kept here by surface
  function keepNets(s) {
    keepIn(netMaps, s.net_map, false);
    if (s.net_maps && !Array.isArray(s.net_maps) && typeof s.net_maps === 'object') Object.keys(s.net_maps).forEach(function (k) { keepIn(netMaps, Object.assign({ surface: k }, s.net_maps[k]), false); });
    return netMaps;
  }
  // (AK1) after keepPlanets and keepNets: a kept map from past the state's tick goes, and a planet the state's listings
  // (its planets, net_maps) have left out for GONE_S; the kept maps saved when they changed (the basemap and clouds at most
  // every LAST_SAVE_S). The surfaces gone.
  function keepUp(s) {
    var now = Date.now() / 1000, gone = [], listed = {}, lists = [s.planets, s.net_maps].filter(Array.isArray);
    lists.forEach(function (list) { list.forEach(function (x) { if (x && typeof x.surface === 'string') listed[x.surface] = true; }); });
    [planetMaps, netMaps].forEach(function (maps) {
      Object.keys(maps).forEach(function (k) {
        if (listed[k] || !lists.length) delete unlisted[k];
        else if (!unlisted[k]) { unlisted[k] = now; keptDirty = true; }
        if (isFinite(s.tick) && maps[k].tick > s.tick || now - (unlisted[k] || now) >= GONE_S) {
          delete maps[k]; keptDirty = true;
          if (gone.indexOf(k) < 0) gone.push(k);
        }
      });
    });
    Object.keys(unlisted).forEach(function (k) { if (!planetMaps[k] && !netMaps[k]) delete unlisted[k]; });
    if (keptDirty || lastDirty && now - keptSaved >= LAST_SAVE_S) {
      keptDirty = lastDirty = false; keptSaved = now;
      store(KEPT_KEY, JSON.stringify({ saved: now, planets: planetMaps, nets: netMaps, unlisted: unlisted, last: last }));
    }
    return gone;
  }
  function mapData(s) {
    var kl = keepLast(s), bm = kl.bm;
    return { base: bm, core: bm.core, ore: bm.ore, ground: bm.terrain_grid, nests: bm.nests, turrets: bm.turrets, turrets_read: bm.turrets_read, terrain: bm.terrain,
      planets: keepPlanets(s), now_tick: s.tick,
      now: typeof s.now === 'number' ? s.now : Date.now() / 1000,  // (AK9) the terrain's age is the live map's: from now
      library_areas: s.library_areas && Array.isArray(s.library_areas.areas) ? s.library_areas.areas : [],  // (AD2) placed library areas
      library_read: !!(s.library_areas && Array.isArray(s.library_areas.areas)),  // (AK10) read at all: "none" vs "not read"
      net_maps: keepNets(s),  // (AD3) electric and logistic networks, items' sources and consumers
      // (AK1) the newest tick of each planet's maps the state lists, and the surfaces dropped (keepUp)
      planet_list: Array.isArray(s.planets) ? s.planets : null, net_list: Array.isArray(s.net_maps) ? s.net_maps : null, gone: keepUp(s),
      agents: s.agents || [], fights: s.fights || [], pins: s.alerts || [], cams: s.cameras || {},
      clouds: kl.clouds, home_held: kl.home_held, clouds_held: kl.clouds_held };  // pollution and spores per chunk (tools/stream/clouds.py), a layer and a surface switch
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
  // (d22 batch75 AK2, viewer Foobator: "can in transit be listed first and the rest have their planetary waiting time
  // displayed?") the platforms in transit first, each with its progress bar; the rest in the stream's order with how
  // long (game time) each has been at its planet, "12+ min" when it was there before the stream service first read it.
  function waitedText(p) {
    if (!isFinite(p.waited_s) || p.waited_s < 0) return '';
    var m = Math.floor(p.waited_s / 60), more = p.waited_more ? '+' : '';
    if (m < 1) return more ? '' : 'waiting under 1 min';
    return 'waiting ' + (m < 60 ? m + more + ' min' : Math.floor(m / 60) + ' h ' + (m % 60) + more + ' min');
  }
  function inTransit(p) { return !!(p.route || p.state === 'on_the_path' || p.where === 'in transit'); }
  function spaceInset(sp) {
    if (!sp || !(sp.platforms || []).length && !(sp.planets || []).length) return '';
    var plats = (sp.platforms || []).filter(inTransit).concat((sp.platforms || []).filter(function (p) { return !inTransit(p); }));
    var rows = plats.map(function (p) {
      var bar = p.route && isFinite(p.route.pct) ? '<div class="fx-progress fx-progress--thin" style="--fx-value:' + Math.max(0, Math.min(100, p.route.pct)) + '%" role="progressbar" aria-valuenow="' +
        Math.round(p.route.pct) + '" aria-valuemin="0" aria-valuemax="100" aria-label="' + esc(p.name) + ' on its way"></div>' : '';
      // where it is, plus its state when that says more than "flying" or "waiting at a stop" (no schedule, paused...)
      var st = p.state && !/^(on_the_path|waiting_at_station|paused)$/.test(p.state) ? label(p.state).toLowerCase() : '';
      return '<li><b>' + esc(p.name) + '</b> <span>' + esc([p.where || label(p.state), st].filter(Boolean).join(' · ')) + '</span>' +
        (p.speed_kms ? ' <span class="fx-muted">' + esc(p.speed_kms) + ' km/s</span>' : '') + (inTransit(p) || !waitedText(p) ? '' : ' <span class="fx-muted">' + esc(waitedText(p)) + '</span>') +
        (p.paused ? ' <span class="fx-chip fx-chip--grey">paused</span>' : '') + bar + '</li>';
    }).join('');
    return '<div class="space-inset"><h4>Space</h4><p class="small fx-muted">' + esc([(sp.planets || []).join(', '), sp.rockets ? sp.rockets + ' rocket' + (sp.rockets > 1 ? 's' : '') + ' launched' : ''].filter(Boolean).join(' · ')) + '</p>' +
      (rows ? '<ul class="platforms">' + rows + '</ul>' : '') + '</div>';
  }

  // ------------------------------------------------------------------ dashboard
  var ACT_LABEL = { acting: 'acting', thinking: 'thinking', idle: 'idle', dead: 'dead', offline: 'offline', resting: 'resting' };
  var ALERT_TONES = { attack: 'danger', death: 'danger', low_power: 'warn', research: 'info' };
  var ALERT_ICONS = { attack: '⚔', death: '✝', low_power: '⚡', research: '⚗' };
  // The dashboard's cards are made once; each refresh fills their bodies (the map card keeps its viewer).
  var CARDS = [['agents', 'Agents'], ['map', 'Map'], ['plan', 'Team plan'], ['board', 'Board'], ['research', 'Research'], ['chronicle', 'Chronicle'], ['charts', 'Factory'], ['chat', 'Team chat']];
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
    replyLines = Array.isArray(s.viewer_replies) ? s.viewer_replies.filter(function (m) { return m && m.text && m.by && isFinite(m.t); }) : [];
    // (d17 batch35 D1, viewer Aurora) each site line's delivery from the relay: relayed (to whom), held, operator, not relayed (why)
    delivery = s.viewer_delivery && typeof s.viewer_delivery === 'object' ? s.viewer_delivery : {};
    readUpTo = s.viewer_read && isFinite(s.viewer_read.after) ? s.viewer_read.after : null;  // (AA5) queued past it
    serviceLive = age == null || age <= LIVE_MAX_AGE;
    team = {}; (s.agents || []).forEach(function (a) { team[a.name] = a; });
    renderChat();
    var byName = {}; agents.forEach(function (a) { byName[a.name] = a; });
    team = byName; lastState = s;
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
        // its current job: its board_focus, else its team-plan line, else its notes.md "## Now" (tools/stream/model.py
        // job_card), always with where it comes from and its age (d20 batch54 N3, viewer Aurora)
        jobHtml(a) + workHtml(a) +
        '<p class="agent-doing">' + esc(a.action || (act === 'thinking' ? 'thinking…' : '–')) + (a.location ? ' <span class="fx-muted">at ' + esc(a.location) + '</span>' : '') + '</p>' +
        (a.wait_line ? '<p class="agent-wait">' + esc(a.wait_line) + '</p>' +
          (a.wait_reason ? '<p class="agent-wait-reason">“' + esc(a.wait_reason) + '”</p>' : '') : '') +
        (said ? '<ul class="agent-said">' + said + '</ul>' : '') + '</article>';
    }).join('');

    // board
    var claims = (board.claims || []).map(function (c) {
      var o = byName[c.agent] || {};
      return '<li>' + avatar(o.name ? o : { name: c.agent || c.owner }, 24) + '<span><b>' + esc(o.display_name || c.owner || '?') + '</b> ' + esc(c.title) +
        evidenceHtml('item' + c.id, c) + '</span></li>';
    }).join('');
    // open projects (board kind project): owner, title and progress ("3 of 7 steps") with a bar; each opens to its steps
    var projects = projectsHtml(board, byName, 'board', false);
    // the jobs behind the counts (viewer joonazan, d15 08:19: "I can't see the open jobs"): open tasks and requests
    // nobody owns, and those an agent claimed or is doing (state.board.open_items / doing_items, newest change first)
    function who(name) { var o = byName[name] || {}; return o.display_name || name || ''; }
    var openJobs = (board.open_items || []).map(function (j) {
      return '<li><span class="fx-chip fx-chip--grey">' + esc(j.kind || 'task') + '</span> <b>' + esc(j.title) + '</b>' +
        (j.requested_by ? ' <span class="fx-muted">asked by ' + esc(who(j.requested_by)) + '</span>' : '') + evidenceHtml('item' + j.id, j) + '</li>';
    }).join('');
    var doingJobs = (board.doing_items || []).map(function (j) {
      var o = byName[j.agent] || {};
      return '<li>' + avatar(o.name ? o : { name: j.agent || j.owner || '?' }, 24) + '<span><b>' + esc(o.display_name || j.owner || '?') + '</b> ' +
        esc(j.title) + ' <span class="fx-chip fx-chip--grey">' + esc(j.kind || 'task') + '</span>' +
        (j.status === 'claimed' ? ' <span class="fx-muted">claimed</span>' : '') + evidenceHtml('item' + j.id, j) + '</span></li>';
    }).join('');
    function more(total, shown) { return total > shown ? '<p class="fx-muted small">+' + esc(total - shown) + ' more</p>' : ''; }
    var jobsHtml = (openJobs ? '<h4>Open jobs</h4><ul class="board-jobs">' + openJobs + '</ul>' + more(board.open_items_total || 0, (board.open_items || []).length) : '') +
      (doingJobs ? '<h4>In progress</h4><ul class="board-claims board-doing">' + doingJobs + '</ul>' + more(board.doing_items_total || 0, (board.doing_items || []).length) : '');
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
      '<span class="fx-chip fx-chip--grey">' + esc(board.open_unowned || 0) + ' open</span></p>' + jobsHtml +
      (projects ? '<h4>Projects</h4>' + projects : '') +
      (claims ? '<h4>Who owns what</h4><ul class="board-claims">' + claims + '</ul>' : '') +
      (events ? '<h4>Recent</h4><ul class="board-events">' + events + '</ul>' : '') + remindersHtml(s.reminders, byName);

    // research
    var recent = (r.recent || []).map(function (t) { return '<li>' + esc(t.label || label(t.name)) + '</li>'; }).join('');
    var research = r.current ? '<div class="live-research-label"><span><strong>' + esc(r.label || label(r.current)) + '</strong></span><span class="live-research-pct">' + pct + '%</span></div>' +
      '<div class="fx-progress fx-progress--research" style="--fx-value:' + pct + '%" role="progressbar" aria-valuenow="' + pct + '" aria-valuemin="0" aria-valuemax="100" aria-label="Research progress"></div>' : '<p class="fx-muted">Nothing being researched.</p>';
    research += '<p class="small">' + esc(r.done_count || 0) + ' technologies done</p>' + (recent ? '<h4>Latest</h4><ol class="research-recent">' + recent + '</ol>' : '');
    // (d20 batch57 S4, viewer Foobator 18:25: "the current level of ever increasing recurring research") each infinite
    // technology researched at least once, the highest level first: the level reached; the tech tree names the next one
    var reps = Array.isArray(r.repeating) ? r.repeating : [];
    if (reps.length) {
      research += '<h4>Repeating research</h4><p class="small fx-muted">Level reached (the tech tree shows the next level).</p><ul class="research-levels">' +
        reps.map(function (x) {
          var now = x.researching ? ' <span class="fx-muted">researching ' + esc(x.next) + (isFinite(x.progress) ? ': ' + Math.floor(x.progress * 100) + '%' : '') + '</span>' : '';
          return '<li' + (x.researching ? ' class="is-researching"' : '') + '><span class="rl-name">' + esc(x.label || label(x.name)) + '</span> <b class="rl-level">' + esc(x.level) + '</b>' + now + '</li>';
        }).join('') + '</ul>';
    }

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
    fill('#cb-plan', planHtml(s, byName));
    fill('#cb-board', boardHtml);
    fill('#cb-chronicle', chronicleHtml(s.chronicle, byName));
    fill('#cb-research', research);
    fill('#cb-charts', '<div class="chart-grid">' + chartHtml + '</div>');
    fill('#cb-chat', gchat ? '<ul class="game-chat">' + gchat + '</ul>' : '<p class="fx-muted">Quiet so far.</p>');
    app.classList.toggle('is-stale', !live);
    if (tipFor) showTip(tipFor, tipAnchor());  // (the portrait under the tip was drawn again)
  }

  // The run's chronicle (state.chronicle, tools/stream/model.py; viewers Alex and syndesis 22:24): the agents' newest
  // entries in their own words, newest first, with what each is filed beside, and the harness's newest notable events
  // (platforms built and lost with where, what destroyed them and the cargo; rockets; deaths). The whole run, by
  // shift: /chronicle/.
  var CHRON_EVENTS = { platform_created: 'Built', platform_lost: 'Lost', platform_deleted: 'Deleted', rocket: 'Rocket', death: 'Death' };
  function chronicleHtml(ch, byName) {
    ch = ch || {};
    var entries = (ch.entries || []).slice().reverse().map(function (e) {
      var o = byName[e.agent] || {};
      return '<li class="chron-entry" style="--ac:' + acColor(o.color) + '">' + avatar(o.name ? o : { name: e.agent || e.name || '?' }, 24) +
        '<div><b>' + esc(o.display_name || e.name || e.agent || '?') + '</b>' + (e.title ? ' <span class="chron-title">' + esc(e.title) + '</span>' : '') +
        ' <span class="fx-muted small">' + esc([e.game_time, e.where].filter(Boolean).join(' · ')) + '</span>' +
        '<p class="chron-text">' + esc(e.text) + '</p>' +
        ((e.about || []).length ? '<p class="fx-muted small">Beside: ' + esc(e.about.join('; ')) + '</p>' : '') + '</div></li>';
    }).join('');
    var events = (ch.events || []).filter(function (x) { return CHRON_EVENTS[x.kind]; }).slice(-6).reverse().map(function (x) {
      var cargo = x.kind === 'platform_lost' ? (x.cargo && x.cargo.length ? x.cargo.map(function (c) { return c.count + ' ' + label(c.name).toLowerCase(); }).join(', ') : 'nothing in its hub') : '';
      return '<li><span class="fx-chip fx-chip--grey">' + esc(CHRON_EVENTS[x.kind]) + '</span> ' + esc(x.line || '') +
        (cargo ? ' <span class="fx-muted">· cargo lost: ' + esc(cargo) + '</span>' : '') +
        (x.game_time ? ' <span class="fx-muted small">' + esc(x.game_time) + '</span>' : '') + '</li>';
    }).join('');
    return (entries ? '<ul class="chron-entries">' + entries + '</ul>' : '<p class="fx-muted">No entries yet this shift.</p>') +
      (events ? '<h4>The harness\'s record</h4><ul class="chron-events">' + events + '</ul>' : '') +
      '<p class="small"><a href="/chronicle/">The whole chronicle, by shift</a></p>';
  }

  // ------------------------------------------------------------------ the team plan (viewer Alex, 22:12)
  // state.board.plan (tools/stream/model.py plan_snapshot): the goals and each agent's line, with the game tick each was
  // set (when the runtime gives it); state.board.projects with progress and next step; the open and taken request
  // counts. "Set N min ago" is game time: the state's tick less the line's, at 60 ticks a second.
  var lastState = null;
  function lineId(name) { return 'plan-line-' + String(name || '').toLowerCase().replace(/[^a-z0-9_-]/g, '-'); }
  function gameAgo(s, tick) {
    if (tick == null || s.tick == null || !isFinite(tick) || !isFinite(s.tick)) return '';
    return ago(Math.max(0, (s.tick - tick) / 60));
  }
  // A card's job with its label (model.py job_card: "focus, set 5 min ago", "plan line, set 2 h ago; no focus set");
  // a state from before job_label names the source alone.
  function jobLabel(a) {
    if (a.job_label) return a.job_label;
    return a.job_from === 'plan' ? 'plan line' : a.job_from === 'notes' ? 'notes.md Now line' : a.job_from || '';
  }
  function jobHtml(a) {
    var label = jobLabel(a);
    if (!a.job) return label ? '<p class="agent-job fx-muted small">' + esc(label) + '</p>' : '';
    return '<p class="agent-job"><span class="fx-muted small job-from">' + esc(label) + ':</span> ' + esc(a.job) + '</p>';
  }
  // Beside the job (d20 batch70 AF3, viewer Aurora): the plan line when the job shows the focus, a stale flag on either
  // with the times, and the agent's current work: watches with their end and latest sample, queue steps, a standing
  // order, a request repeated at a steady interval (tools/stream/workcard.py).
  function workHtml(a) {
    var plan = a.plan_line ? '<p class="agent-job agent-plan-line"><span class="fx-muted small job-from">' + esc(a.plan_line_label || 'plan line') + ':</span> ' + esc(a.plan_line) + '</p>' : '';
    var stale = (a.stale || []).map(function (x) { return '<li><span class="fx-chip fx-chip--orange step-tag">stale</span> ' + esc(x) + '</li>'; }).join('');
    var work = (a.work || []).map(function (x) { return '<li>' + esc(x) + '</li>'; }).join('');
    return plan + (stale ? '<ul class="agent-stale">' + stale + '</ul>' : '') +
      (work ? '<ul class="agent-work">' + work + '</ul>' : '') + (a.work_cut ? '<p class="fx-muted small">+' + esc(a.work_cut) + ' more</p>' : '');
  }
  function planLine(plan, name) {
    var hit = null;
    ((plan && plan.doing) || []).forEach(function (l) { if (l.agent === name || (!l.agent && l.name === name)) hit = l; });
    return hit;
  }
  // Projects on the Board and Team plan cards (viewer Foobator, d15 08:31: "the site lists projects, but we cant see the
  // individual steps. there is also no way to browse hidden projects"). Each project opens to its steps (done with who
  // and when, the next one marked, the rest open), what it needs, its handoff and who asked for it; which ones are open
  // survives the refresh. "Show all" adds the projects the card hides and the last finished ones (state.board
  // projects_more, projects_done), remembered per browser.
  var openProjects = {}, showAllProjects = store('projectsAll') === '1';
  function stepsHtml(p) {
    var steps = (p.steps || []).map(function (st) {
      var mark = st.done ? '✓' : st.next ? '→' : '○', cls = st.done ? 'done' : st.next ? 'next' : 'todo';
      // a step's own owner, and parallel steps (no order between them and their parallel neighbours; d15 batch5 J2)
      return '<li class="step step-' + cls + (st.parallel ? ' step-parallel' : '') + '"><span class="step-mark" aria-hidden="true">' + mark + '</span> ' +
        (st.n != null ? '<span class="fx-muted">' + esc(st.n) + '.</span> ' : '') + esc(st.text) +
        (st.owner ? ' <span class="fx-muted small step-owner">· ' + esc((team[st.owner] || {}).display_name || st.owner) + '</span>' : '') +
        (st.parallel ? ' <span class="fx-chip fx-chip--grey step-tag" title="No order between this step and the parallel steps next to it">parallel</span>' : '') +
        (st.done && st.by ? ' <span class="fx-muted small">done by ' + esc((team[st.by] || {}).display_name || st.by) + (st.ago ? ', ' + esc(st.ago) + ' ago' : '') + '</span>' : '') +
        (st.next ? ' <span class="fx-chip fx-chip--orange step-tag">next</span>' : '') + '</li>';
    }).join('');
    var needs = p.needs ? Object.keys(p.needs).map(function (k) { return esc(p.needs[k]) + ' ' + esc(label(k)); }).join(', ') : '';
    var who = p.requested_by ? ((team[p.requested_by] || {}).display_name || p.requested_by) : '';
    var body = (steps ? '<ol class="project-steps">' + steps + '</ol>' : p.steps_cut ? ''
        : '<p class="fx-muted small">' + (p.total ? 'Its step list is not available yet.' : 'No steps yet.') + '</p>') +
      (p.steps_cut ? '<p class="fx-muted small">' + (steps ? 'Only its open steps are shown here' : 'Its steps are left out here') + ' to keep the page small.</p>'
        : p.steps_partial ? '<p class="fx-muted small">The next open steps; the whole list comes with a later refresh.</p>' : '') +
      (p.status === 'blocked' ? '<p class="small"><span class="fx-chip fx-chip--grey">blocked</span></p>' : '') +
      (needs ? '<p class="small"><span class="fx-muted">Needs:</span> ' + needs + '</p>' : '') +
      (p.handoff ? '<p class="small">' + longText('proj' + p.id + ':handoff', p.handoff, 'Handoff:') + '</p>' : '') +
      (p.evidence ? '<div class="small">' + evidenceHtml('proj' + p.id, p) + '</div>' : '') +
      (who ? '<p class="small fx-muted">Asked by ' + esc(who) + '</p>' : '');
    return body;
  }
  // (d22 batch75 AK11, viewer Foobator site:4284: "can projects that are actively being worked on and blocked projects be
  // easier to see on site? also, could you show blocker reason?") a project's status as the board holds it, a chip
  // (Doing green, Blocked red, the rest grey; "focus" where an agent's board focus is on it), and under its title why it
  // is blocked: the open items in its blocked_by, its newest note, a focus's blocker, and the progress check's last state
  // (tools/stream/model.py project_state). The model puts those worked on, then the blocked ones, first.
  var STATUS_CHIP = { doing: 'fx-chip--green', blocked: 'fx-chip--red' };
  function projectFacts(p, byName) {
    var who = function (n) { var o = byName[n] || {}; return o.display_name || n; };
    var rows = [];
    (p.blocked_by || []).forEach(function (b) {
      rows.push('Blocked by #' + b.id + (b.title ? ' ' + b.title : '') + (b.status ? ' (' + b.status + (b.owner ? ', ' + who(b.owner) : ', no owner') + ')' : ''));
    });
    (p.focus || []).forEach(function (f) { if (f.blocker) rows.push(who(f.agent) + '\'s focus blocker: ' + f.blocker); });
    if (p.note && p.note.text) {
      var when = p.note.tick != null && lastState ? gameAgo(lastState, p.note.tick) : '';
      rows.push((p.status === 'blocked' ? 'Marked blocked; newest note' : 'Newest note') + (p.note.by ? ' by ' + who(p.note.by) : '') + (when ? ', ' + when : '') + ': ' + p.note.text);
    }
    var c = p.check;
    if (c && c.state) {
      rows.push('Progress check' + (c.checked_s != null ? ' ' + ago(c.checked_s) : '') + ': ' + c.state + (c.error ? ' (' + c.error + ')' : '') +
        (c.last_change_s != null ? '; last board change ' + ago(c.last_change_s) : ''));
    }
    return rows.map(function (r) { return '<span class="small project-fact">' + esc(r) + '</span>'; }).join('');
  }
  function projectItem(p, byName, card, withNext) {
    var o = byName[p.agent] || {}, pct = p.total ? Math.round(100 * p.done / p.total) : 0, key = card + ':' + p.id;
    var chip = p.status && p.status !== 'done' ? ' <span class="fx-chip ' + (STATUS_CHIP[p.status] || 'fx-chip--grey') + ' project-status">' + esc(p.status) + '</span>' : '';
    var focus = (p.focus || []).map(function (f) { var fo = byName[f.agent] || {}; return ' <span class="fx-chip fx-chip--grey project-status" title="board focus' + (f.step ? ': ' + esc(f.step) : '') + '">' + esc((fo.display_name || f.agent) + ' focus') + '</span>'; }).join('');
    var head = avatar(o.name ? o : { name: p.agent || p.owner || '?' }, 24) + '<span class="project-head"><span><b>' + esc(p.title) + '</b>' + chip + focus + ' ' +
      '<span class="fx-muted">' + esc(p.owner ? (o.display_name || p.owner) : 'no owner') +
      (p.status === 'done' ? ', finished' : '') + '</span></span>' + (p.status !== 'done' ? projectFacts(p, byName) : '') +
      '<span class="project-progress"><span class="fx-progress fx-progress--health fx-progress--thin" role="progressbar" aria-valuenow="' + pct +
      '" aria-valuemin="0" aria-valuemax="100" aria-label="' + esc(p.title) + ' progress" style="--fx-value:' + pct + '%"></span>' +
      '<span class="small">' + esc(p.progress || '') + '</span></span>' +
      (withNext && p.next && p.status !== 'done' ? '<span class="small plan-next"><span class="fx-muted">Next:</span> ' + esc(p.next) + '</span>' : '') + '</span>';
    return '<li><details class="project" data-project="' + esc(key) + '"' + (openProjects[key] ? ' open' : '') + '><summary>' + head +
      '</summary><div class="project-body">' + stepsHtml(p) + '</div></details></li>';
  }
  // (d19 batch43 A2, batch41 B2) A long text shown whole: one line, cut with an ellipsis by CSS, that opens to all of it
  // (a reminder's result up to 1000 characters, evidence lines); the reader's open ones stay open across refreshes.
  var openLong = {};
  function longText(key, text, label) {
    text = String(text || '');
    var head = label ? '<span class="fx-muted">' + esc(label) + '</span> ' : '';
    if (text.length <= 110) return '<span class="lt-short">' + head + esc(text) + '</span>';
    return '<details class="lt" data-lt="' + esc(key) + '"' + (openLong[key] ? ' open' : '') + '><summary>' + head +
      '<span class="lt-line">' + esc(text) + '</span></summary><div class="lt-full">' + esc(text) + '</div></details>';
  }
  // A board item's or reminder's evidence (the runtime's lines, oldest first): the newest first, each whole.
  function evidenceHtml(key, row) {
    var ev = Array.isArray(row && row.evidence) ? row.evidence : [];
    if (!ev.length) return '';
    return '<div class="evidence">' + ev.slice().reverse().map(function (line, i) {
      return longText(key + ':ev' + (ev.length - 1 - i), line, i ? 'earlier evidence:' : 'evidence:');
    }).join('') + (row.evidence_more ? '<span class="fx-muted small">+' + esc(row.evidence_more) + ' earlier</span>' : '') + '</div>';
  }
  // A reminder's states, "astra overdue (2 runs missed (the first at tick 7200, 1m00s ago; the last at ...)); sol
  // acknowledged", one per recipient: split on "; " outside parentheses (d19 batch46 item 0: batch41's missed-runs text
  // has its own "; ", and the chip broke in two on the live page).
  function splitStates(text) {
    var out = [], depth = 0, cur = '';
    text = String(text || '');
    for (var i = 0; i < text.length; i++) {
      var ch = text.charAt(i);
      if (ch === '(') depth++;
      else if (ch === ')') depth = Math.max(0, depth - 1);
      if (depth === 0 && ch === ';' && text.charAt(i + 1) === ' ') { if (cur) out.push(cur); cur = ''; i++; continue; }
      cur += ch;
    }
    if (cur) out.push(cur);
    return out;
  }
  // The team's reminder jobs (d15 batch5 group I; viewer Foobator's idea, Astra and Sol's design): who set each, its
  // message, when it is next due, the last result and its age, and each recipient's state (pending, acknowledged,
  // overdue). Reminders only send the agents a line; they never act in the game.
  // (d20 batch65 AA4, viewer Aurora 08:56: "Could the reminder list expand beyond its first 12 entries? ... Active/overdue
  // filters") The first REM_SHOWN; "Show all N" opens every job the state carries, with All / Active / Overdue filters
  // (active: on and not done; overdue: a recipient overdue). The reader's choice stays across refreshes.
  var REM_SHOWN = 12, remAll = store('remindersAll') === '1', remFilter = store('remindersFilter') || 'all';
  var REM_FILTERS = [['all', 'All'], ['active', 'Active'], ['overdue', 'Overdue']];
  function remStates(j) {
    return splitStates(j.states).map(function (st) { var m = /^(\S+) (\S+)(.*)$/.exec(st) || []; return { who: m[1], state: m[2], rest: m[3] }; });
  }
  function remIs(j, f) {
    if (f === 'active') return !!j.enabled && !j.done;
    if (f === 'overdue') return remStates(j).some(function (x) { return x.state === 'overdue'; });
    return true;
  }
  // (d20 batch70 AF2, viewer Aurora: "show each recipient's latest result") each recipient's latest: acknowledged when,
  // with what (by the backup for them), or waiting how long with the runs missed; and the backup, named.
  function remLatestHtml(j, byName) {
    var rows = Array.isArray(j.latest) ? j.latest : [];
    var out = rows.map(function (x) {
      var who = (byName[x.agent] || byName[x.name] || {}).display_name || x.name;
      var by = x.by ? ' by ' + ((byName[x.by] || {}).display_name || x.by) + ' for them' : '';
      if (x.waiting_s != null) {
        var head = who + ': waiting ' + ago(x.waiting_s).replace(/ ago$/, '') + (x.missed ? ', ' + x.missed + ' run' + (x.missed === 1 ? '' : 's') + ' missed' : '') +
          (x.backup_told ? ', backup told' : '') + (x.acked_ago_s != null ? '; last acknowledged ' + ago(x.acked_ago_s) + by : '; never acknowledged');
        return x.result ? longText('rem' + j.id + ':latest:' + x.name, x.result, head + ':') : '<span class="lt-short">' + esc(head) + '</span>';
      }
      if (x.acked_ago_s == null) return '<span class="lt-short">' + esc(who + ': ' + (x.state || 'scheduled') + ', never acknowledged') + '</span>';
      var line = who + ': acknowledged ' + ago(x.acked_ago_s) + by;
      return x.result ? longText('rem' + j.id + ':latest:' + x.name, x.result, line + ':') : '<span class="lt-short">' + esc(line + ', no result given') + '</span>';
    }).join('');
    var backup = j.backup ? '<span class="fx-muted small">Backup: ' + esc((byName[j.backup] || {}).display_name || j.backup) + '</span>' : '';
    return out || backup ? '<div class="rem-latest">' + backup + out + '</div>' : '';
  }
  function remindersHtml(rem, byName) {
    if (!rem || !(rem.jobs || []).length) return '';
    var STATE = { pending: 'fx-chip--orange', overdue: 'fx-chip--red', acknowledged: 'fx-chip--green' };
    var jobs = rem.jobs, total = Math.max(rem.total || 0, jobs.length), opened = remAll && total > REM_SHOWN;
    var list = opened ? jobs.filter(function (j) { return remIs(j, remFilter); }) : jobs.slice(0, REM_SHOWN);
    var rows = list.map(function (j) {
      var o = byName[j.agent] || {};
      var due = j.done ? 'done' : !j.enabled ? 'off' : j.next_due_in_s != null ? 'next in ' + ago(j.next_due_in_s).replace(/ ago$/, '') : '';
      var states = remStates(j).map(function (x) {
        var who = byName[x.who] || {};
        return '<span class="fx-chip ' + (STATE[x.state] || 'fx-chip--grey') + '">' + esc((who.display_name || x.who || '') + ' ' + (x.state || '') + (x.rest || '')) + '</span>';
      }).join(' ');
      return '<li>' + avatar(o.name ? o : { name: j.agent || j.owner || '?' }, 24) + '<span><b>' + esc(o.display_name || j.owner || '?') + '</b> ' +
        esc(j.name ? j.name + ': ' : '') + esc(j.message) + ' <span class="fx-muted">' + esc([j.cadence, due].filter(Boolean).join(', ')) + '</span>' +
        (j.last_result ? longText('rem' + j.id + ':result', j.last_result, 'last result' + (j.result_age_s != null ? ' ' + ago(j.result_age_s) : '') + ':') : '') +
        evidenceHtml('rem' + j.id, j) + (states ? '<br>' + states : '') + remLatestHtml(j, byName) + '</span></li>';
    }).join('');
    var filters = !opened ? '' : '<div class="rem-filters" role="group" aria-label="Show reminders">' + REM_FILTERS.map(function (f) {
      var n = jobs.filter(function (j) { return remIs(j, f[0]); }).length;
      return '<button type="button" class="fx-btn fx-btn--small" data-rem-filter="' + f[0] + '" aria-pressed="' + (remFilter === f[0]) + '">' +
        esc(f[1]) + ' (' + n + ')</button>';
    }).join(' ') + '</div>';
    var none = opened && !list.length ? '<p class="fx-muted small">No ' + esc(remFilter) + ' reminders.</p>' : '';
    var unsent = opened && total > jobs.length ? '<p class="fx-muted small">+' + esc(total - jobs.length) + ' more not sent (the page\'s size limit)</p>' : '';
    var toggle = total > REM_SHOWN ? '<button type="button" class="fx-btn fx-btn--small rem-all" data-action="reminders-all" aria-expanded="' + opened + '">' +
      (opened ? 'Show the first ' + REM_SHOWN : 'Show all ' + total + ' reminders (+' + (total - Math.min(REM_SHOWN, jobs.length)) + ' more)') + '</button>' : '';
    return '<div class="board-rem"><h4>Reminders</h4>' + filters + (rows ? '<ul class="board-claims board-reminders">' + rows + '</ul>' : '') + none + unsent + toggle + '</div>';
  }
  app.addEventListener('click', function (ev) {
    var b = ev.target && ev.target.closest ? ev.target.closest('[data-action="reminders-all"], [data-rem-filter]') : null;
    if (!b) return;
    if (b.dataset.remFilter) { remFilter = b.dataset.remFilter; store('remindersFilter', remFilter); }
    else { remAll = !remAll; store('remindersAll', remAll ? '1' : '0'); }
    var box = b.closest('.board-rem');
    if (box && lastState) {
      box.outerHTML = remindersHtml(lastState.reminders, team);
      var again = app.querySelector(b.dataset.remFilter ? '[data-rem-filter="' + remFilter + '"]' : '[data-action="reminders-all"]');
      if (again) again.focus();
    }
  });
  function projectsHtml(board, byName, card, withNext) {
    var shown = (board.projects || []).map(function (p) { return projectItem(p, byName, card, withNext); }).join('');
    var more = (board.projects_more || []).map(function (p) { return projectItem(p, byName, card, withNext); }).join('');
    var done = (board.projects_done || []).map(function (p) { return projectItem(p, byName, card, withNext); }).join('');
    var hidden = Math.max(0, (board.projects_total || 0) - (board.projects || []).length);
    if (!shown && !more && !done) return '';
    var n = (board.projects || []).length + (board.projects_more || []).length + (board.projects_done || []).length;
    var extra = more || done ? '<button type="button" class="fx-btn fx-btn--small projects-all" data-action="projects-all" aria-expanded="' +
        (showAllProjects ? 'true' : 'false') + '">' + (showAllProjects ? 'Show fewer projects' : 'Show all ' + n + ' projects') + '</button>' +
        '<div class="projects-more"' + (showAllProjects ? '' : ' hidden') + '>' + (more ? '<ul class="board-projects">' + more + '</ul>' : '') +
        (done ? '<h5>Finished</h5><ul class="board-projects">' + done + '</ul>' : '') + '</div>'
      : (hidden > 0 ? '<p class="fx-muted small">+' + esc(hidden) + ' more</p>' : '');
    return (shown ? '<ul class="board-projects">' + shown + '</ul>' : '') + extra;
  }
  // A project opened or closed by the reader stays so on the next refresh; the "show all" button flips every card.
  app.addEventListener('toggle', function (ev) {
    var d = ev.target;
    if (d && d.dataset && d.dataset.project) openProjects[d.dataset.project] = !!d.open;
    if (d && d.dataset && d.dataset.lt) openLong[d.dataset.lt] = !!d.open;
  }, true);
  app.addEventListener('click', function (ev) {
    var b = ev.target && ev.target.closest ? ev.target.closest('[data-action="projects-all"]') : null;
    if (!b) return;
    showAllProjects = !showAllProjects;
    store('projectsAll', showAllProjects ? '1' : '0');
    Array.prototype.forEach.call(app.querySelectorAll('.projects-more'), function (el) { el.hidden = !showAllProjects; });
    Array.prototype.forEach.call(app.querySelectorAll('[data-action="projects-all"]'), function (el) {
      var n = (lastState && lastState.board) ? ((lastState.board.projects || []).length + (lastState.board.projects_more || []).length + (lastState.board.projects_done || []).length) : '';
      el.textContent = showAllProjects ? 'Show fewer projects' : 'Show all ' + n + ' projects';
      el.setAttribute('aria-expanded', showAllProjects ? 'true' : 'false');
    });
  });
  function planHtml(s, byName) {
    var board = s.board || {}, plan = board.plan || null;
    if (board.available === false) return '<p class="fx-muted">The board is not running in this world.</p>';
    var html = '';
    if (plan && plan.goals) {
      var gw = gameAgo(s, plan.goals_tick);
      html += '<h4>Goals</h4><p class="plan-goals">' + esc(plan.goals) + '</p>' + (gw ? '<p class="fx-muted small plan-when">set ' + esc(gw) + '</p>' : '');
    }
    var lines = ((plan && plan.doing) || []).map(function (l) {
      var name = l.agent || l.name, o = byName[name] || {}, when = gameAgo(s, l.tick);
      var setter = l.by ? ((byName[l.by] || {}).display_name || l.by) : '';
      return '<li class="plan-line" id="' + esc(lineId(name)) + '" style="--ac:' + acColor(o.color) + '">' + avatar(o.name ? o : { name: name }, 24) +
        '<div><b>' + esc(o.display_name || l.name || name) + '</b> <span class="plan-text">' + esc(l.text) + '</span>' +
        (when || setter ? '<span class="fx-muted small plan-when">' + esc([when ? 'set ' + when : '', setter ? 'by ' + setter : ''].filter(Boolean).join(' ')) + '</span>' : '') +
        '</div></li>';
    }).join('');
    var without = Object.keys(byName).filter(function (n) { return !planLine(plan, n); }).map(function (n) { return byName[n].display_name || n; });
    html += '<h4>Who is on what</h4>' + (lines ? '<ul class="plan-lines">' + lines + '</ul>' : '<p class="fx-muted">No agent has a line on the plan yet.</p>') +
      (without.length && lines ? '<p class="fx-muted small">No line: ' + esc(without.join(', ')) + '</p>' : '');
    var projects = projectsHtml(board, byName, 'plan', true);
    html += '<h4>Open projects</h4>' + (projects || '<p class="fx-muted">None open.</p>');
    html += '<h4>Requests</h4><p class="board-counts"><span class="fx-chip fx-chip--grey">' + esc(board.open_unowned || 0) + ' open, nobody on them</span> ' +
      '<span class="fx-chip fx-chip--orange">' + esc(board.in_progress || 0) + ' in progress</span></p>';
    if (plan && plan.edited) html += '<p class="fx-muted small">Plan last edited ' + esc(plan.edited) + '.</p>';
    return html;
  }

  // The portrait tip: the agent's plan line, its notes' "Now" line when that is its job, and what it does now.
  var tip = document.createElement('div');
  tip.className = 'plan-tip'; tip.setAttribute('role', 'tooltip'); tip.hidden = true;
  app.appendChild(tip);
  var tipFor = null, lastPointer = 'mouse';
  function tipAnchor() { return tipFor ? app.querySelector('.avatar[data-agent="' + tipFor.replace(/["\\]/g, '') + '"]') : null; }
  function tipHtml(name) {
    var a = team[name] || {}, s = lastState || {}, line = planLine((s.board || {}).plan, name);
    var act = a.activity || (a.alive === false ? 'dead' : 'idle');
    var rows = '<div class="t-head">' + esc(a.display_name || name) + '</div>' +
      '<div class="t-line"><span class="fx-muted">Plan:</span> ' + (line ? esc(line.text) + (line.tick != null ? ' <span class="fx-muted">(set ' + esc(gameAgo(s, line.tick)) + ')</span>' : '')
        : '<span class="fx-muted">no line on the team plan</span>') + '</div>';
    if (a.job && a.job_from !== 'plan') rows += '<div class="t-line"><span class="fx-muted">Job (' + esc(jobLabel(a)) + '):</span> ' + esc(a.job) + '</div>';
    rows += '<div class="t-line"><span class="fx-muted">Now:</span> ' + esc(a.action || ACT_LABEL[act] || act) + '</div>';
    rows += '<div class="t-foot fx-muted">' + (lastPointer === 'touch' ? 'Tap again' : 'Click') + ' for its line in the Team plan</div>';
    return rows;
  }
  function showTip(name, el) {
    if (!el || !team[name]) { hideTip(); return; }
    tipFor = name;
    tip.innerHTML = tipHtml(name);
    tip.hidden = false;
    var r = el.getBoundingClientRect(), w = tip.offsetWidth || 260, vw = window.innerWidth || 1024;
    var left = Math.max(8, Math.min(r.left, vw - w - 8)), top = r.bottom + 6;
    if (top + (tip.offsetHeight || 120) > (window.innerHeight || 800) - 8) top = Math.max(8, r.top - (tip.offsetHeight || 120) - 6);
    tip.style.left = left + 'px'; tip.style.top = top + 'px';
  }
  function hideTip() { tipFor = null; tip.hidden = true; }
  function toLine(name) {
    hideTip();
    var el = document.getElementById(lineId(name)) || $('.card-plan');
    if (!el) return;
    if (el.scrollIntoView) el.scrollIntoView({ behavior: 'smooth', block: 'center' });
    el.classList.add('is-flash');
    setTimeout(function () { el.classList.remove('is-flash'); }, 1600);
  }
  function portrait(ev) { return ev.target && ev.target.closest ? ev.target.closest('.avatar[data-agent]') : null; }
  app.addEventListener('pointerdown', function (ev) { lastPointer = ev.pointerType || 'mouse'; });
  app.addEventListener('pointerover', function (ev) {
    var p = portrait(ev);
    if (p && ev.pointerType !== 'touch') showTip(p.dataset.agent, p);
  });
  app.addEventListener('pointerout', function (ev) {
    var p = portrait(ev);
    if (p && ev.pointerType !== 'touch' && !(ev.relatedTarget && p.contains(ev.relatedTarget))) hideTip();
  });
  app.addEventListener('focusin', function (ev) { var p = portrait(ev); if (p) showTip(p.dataset.agent, p); });
  app.addEventListener('focusout', function (ev) { if (portrait(ev)) hideTip(); });
  app.addEventListener('click', function (ev) {
    var p = portrait(ev);
    if (!p) { if (lastPointer === 'touch') hideTip(); return; }
    var name = p.dataset.agent;
    // a tap shows the tip first; a tap on the same portrait while its tip shows goes to the line
    if (lastPointer === 'touch' && tipFor !== name) { ev.preventDefault(); showTip(name, p); return; }
    toLine(name);
  });
  app.addEventListener('keydown', function (ev) {
    var p = portrait(ev);
    if (p && (ev.key === 'Enter' || ev.key === ' ')) { ev.preventDefault(); toLine(p.dataset.agent); }
    if (ev.key === 'Escape') hideTip();
  });

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
