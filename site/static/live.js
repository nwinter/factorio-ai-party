// Live page: YouTube embed (when configured) and the status panel fed by live/status.json.
// The JSON format is documented in site/README.md ("Live status JSON").
(function () {
  var panel = document.getElementById('live');
  var player = document.getElementById('player');
  if (!panel) return;
  var params = new URLSearchParams(location.search);
  var demo = params.has('demo');
  var src = demo ? '/live/status.example.json' : panel.dataset.src;
  var poll = Math.max(5, parseInt(panel.dataset.poll, 10) || 15) * 1000;
  var badge = panel.querySelector('.live-badge');
  var updated = panel.querySelector('.live-updated');
  var body = panel.querySelector('.live-body');
  var embedded = null;

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function safeColor(c) { return /^#[0-9a-f]{6}$/i.test(c || '') ? c : null; }
  function hashColor(name) {
    var h = 0; for (var i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) % 360;
    return 'hsl(' + h + ' 55% 55%)';
  }
  function ink(c) {
    if (!/^#/.test(c)) return '#fff';
    var r = parseInt(c.substr(1, 2), 16), g = parseInt(c.substr(3, 2), 16), b = parseInt(c.substr(5, 2), 16);
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) > 140 ? '#111' : '#fff';
  }
  // Pixel portrait from the art kit (avatar.js): the agent's own `avatar` parts, else a default from id and colour.
  // The renderer validates parts and colours itself and escapes the label, so status data can't inject markup.
  function avatar(a) {
    var c = safeColor(a.color);
    if (window.PogAvatar) {
      var row = { name: String(a.id || a.name || 'agent'), display_name: a.name, color: c, avatar: a.avatar };
      return '<span class="fx-slot avatar sm" aria-hidden="true">' + window.PogAvatar.svg(row, 24, { title: '' }) + '</span>';
    }
    c = c || hashColor(a.name || a.id || '?');
    return '<span class="fx-slot avatar sm letter" aria-hidden="true" style="background:' + c + ';color:' + ink(c) + '">' +
      esc((a.name || a.id || '?').charAt(0)) + '</span>';
  }
  var TONES = { live: 'red', sample: 'orange', offline: 'grey' };
  function setBadge(state, text) {
    badge.className = 'live-badge fx-chip fx-chip--' + TONES[state];
    badge.textContent = text;
  }
  var ALERT_TONES = { attack: 'danger', death: 'danger', low_power: 'warn', research: 'info' };
  var ALERT_ICONS = { attack: '⚔', death: '✝', low_power: '⚡', research: '⚗' };
  function ago(iso) {
    var t = Date.parse(iso); if (!t) return '';
    var s = Math.round((Date.now() - t) / 1000);
    if (s < 90) return s + ' s ago';
    if (s < 5400) return Math.round(s / 60) + ' min ago';
    if (s < 172800) return Math.round(s / 3600) + ' h ago';
    return new Date(t).toLocaleDateString();
  }

  function embed(videoId, channelId) {
    var key = videoId || channelId;
    if (!player || !key || embedded === key) return;
    embedded = key;
    var url = videoId
      ? 'https://www.youtube-nocookie.com/embed/' + encodeURIComponent(videoId) + '?autoplay=1&mute=1'
      : 'https://www.youtube-nocookie.com/embed/live_stream?channel=' + encodeURIComponent(channelId) + '&autoplay=1&mute=1';
    player.innerHTML = '<iframe src="' + url + '" title="Live stream" allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe>';
  }
  // the site config can set the stream ahead of any status file
  embed(player && player.dataset.video, player && player.dataset.channel);

  function render(s) {
    var live = !!s.live;
    if (demo) setBadge('sample', 'Sample'); else if (live) setBadge('live', 'Live'); else setBadge('offline', 'Offline');
    updated.textContent = s.updated && !demo ? 'updated ' + ago(s.updated) : '';
    if (s.stream && (s.stream.youtube_video_id || s.stream.youtube_channel_id)) embed(s.stream.youtube_video_id, s.stream.youtube_channel_id);

    var h = '';
    if (s.message) h += '<p class="muted small">' + esc(s.message) + '</p>';
    if (!live) {
      if (s.next && s.next.title) h += '<p><strong>Next:</strong> ' + esc(s.next.title) + (s.next.when ? ' · ' + esc(new Date(s.next.when).toLocaleString()) : '') + '</p>';
      if (s.last_run && s.last_run.url && /^\/[\w\/-]*$/.test(s.last_run.url)) h += '<p>Latest run: <a href="' + s.last_run.url + '">' + esc(s.last_run.title) + '</a></p>';
      body.innerHTML = h;
      return;
    }
    var run = s.run || {}, g = s.game || {}, r = g.research || {};
    h += '<div class="live-run"><strong>' + esc(run.title || 'Live run') + '</strong><span class="muted small">' + esc(run.subtitle || '') + '</span></div>';
    h += '<div class="live-clock"><span>Game ' + esc(g.game_time || '') + (g.paused ? ' (paused)' : '') + '</span>';
    if (run.deadline) h += '<span>Ends ' + esc(new Date(run.deadline).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })) + '</span>';
    if (r.done != null) h += '<span>' + esc(r.done) + ' techs</span>';
    if (g.rockets) h += '<span>🚀 ' + esc(g.rockets) + '</span>';
    h += '</div>';
    if (r.current) {
      var pct = Math.round((r.progress || 0) * 100);
      // Label above the bar, not on it: light text over the cyan fill is hard to read.
      var tech = String(r.current).replace(/-/g, ' ');
      h += '<div class="live-research"><div class="live-research-label"><span>Researching <strong>' + esc(tech) +
        '</strong></span><span class="live-research-pct">' + pct + '%</span></div>' +
        '<div class="fx-progress fx-progress--research fx-progress--thin" role="progressbar" aria-valuenow="' + pct +
        '" aria-valuemin="0" aria-valuemax="100" aria-label="Research progress: ' + esc(tech) + '" style="--fx-value:' + pct + '%"></div></div>';
    }
    if ((s.alerts || []).length) {
      h += '<ul class="live-alerts">' + s.alerts.slice(-3).reverse().map(function (a) {
        var tone = ALERT_TONES[a.kind] ? ' fx-alert--' + ALERT_TONES[a.kind] : '';
        return '<li class="fx-alert' + tone + '"><span class="fx-slot fx-slot--sm" aria-hidden="true">' + (ALERT_ICONS[a.kind] || '!') + '</span>' +
          '<div><div class="fx-alert-title">' + esc(String(a.kind || 'alert').replace(/_/g, ' ')) +
          ' <span class="fx-muted small">' + esc(a.game_time || '') + '</span></div>' + esc(a.text) + '</div></li>';
      }).join('') + '</ul>';
    }
    var byId = {};
    if ((s.agents || []).length) {
      h += '<h3>Agents</h3><ul class="live-agents">' + s.agents.map(function (a) {
        byId[a.id] = a;
        var act = a.state === 'dead' && a.respawn_s ? 'respawning in ' + a.respawn_s + ' s' : (a.action || '');
        var where = a.location ? (act ? ' · ' : '') + a.location : '';
        var cam = a.camera ? ' 🎥' : '';
        return '<li>' + avatar(a) + '<span><span class="a-name">' + esc(a.name || a.id) + cam + '</span>' +
          '<span class="a-act">' + esc(act + where) + '</span></span>' +
          '<span class="state" data-s="' + esc(a.state) + '">' + esc(a.state || '') + '</span></li>';
      }).join('') + '</ul>';
    }
    if ((s.chat || []).length) {
      h += '<h3>Chat</h3><ol class="chat">' + s.chat.slice(-8).map(function (c) {
        var a = byId[c.from] || { id: c.from, name: c.from };
        return '<li><span class="c-time">' + esc(c.game_time || '') + '</span><span class="chip">' + avatar(a) + esc(a.name || c.from) +
          '</span><span class="c-text">' + esc(c.text) + '</span></li>';
      }).join('') + '</ol>';
    }
    body.innerHTML = h;
  }

  function tick() {
    fetch(src, { cache: 'no-store' })
      .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
      .then(render)
      .catch(function () {
        setBadge('offline', 'Offline');
        body.innerHTML = '<p class="muted">Status is unavailable right now.</p>';
      })
      .then(function () { if (!demo) setTimeout(tick, document.hidden ? poll * 4 : poll); });
  }
  tick();
})();
