/* Spectator-only: the public state API and static, paginated archives. */
(function () {
  'use strict';
  const root = document.getElementById('team-run');
  if (!root) return;
  const archived = root.dataset.archive === 'true';
  const el = (tag, text, cls) => { const n = document.createElement(tag); if (text !== undefined) n.textContent = text; if (cls) n.className = cls; return n; };
  const gameTime = tick => { const minutes = Math.floor((tick || 0) / 3600); const hours = Math.floor(minutes / 60); return `${Math.floor(hours / 24)}d ${hours % 24}h ${minutes % 60}m`; };
  const label = name => String(name).replace(/-/g, ' ').replace(/^./, c => c.toUpperCase());
  let state, historyPage = 0, historyPages = 0;
  function events(rows) {
    const list = el('ol', undefined, 'team-run-history');
    for (const row of rows || []) {
      const item = el('li');
      item.append(el('span', `${gameTime(row.tick)} · ${row.team ? label(row.team) + ' · ' : ''}${label(row.kind)}`, 'muted small'), el('p', row.text));
      list.append(item);
    }
    const host = document.getElementById('team-run-events');
    host.replaceChildren(list.children.length ? list : el('p', 'No contacts, pacts or trades recorded in this snapshot.'));
  }
  function render(data) {
    state = data;
    const ended = !!data.result;
    const stale = !archived && Date.now() / 1000 - data.now > 30;
    const status = document.getElementById('team-run-status');
    status.textContent = `${ended ? 'Game over' : archived ? 'Archived snapshot · no recorded game-over result' : stale || data.status === 'unavailable' ? 'Updates unavailable · last recorded progress' : 'Live'} · ${gameTime(data.tick)} game time · observed ${new Date(data.now * 1000).toLocaleString()}`;
    const result = document.getElementById('team-run-result');
    result.replaceChildren();
    if (ended) {
      const box = el('div', undefined, 'team-run-result');
      box.append(el('h2', 'Game over'), el('p', data.result.text));
      for (const [team, score] of Object.entries(data.result.scores || {})) box.append(el('p', `${label(team)} · result score ${score}`));
      result.append(box);
    }
    const cards = document.getElementById('team-run-teams');
    cards.replaceChildren();
    const teams = [...data.teams].sort((a,b) => (a.rank || 99) - (b.rank || 99) || a.team.localeCompare(b.team));
    for (const t of teams) {
      const card = el('article', undefined, 'team-run-card');
      card.dataset.team = t.team;
      if (/^#[0-9a-f]{6}$/i.test(t.color)) card.style.borderTopColor = t.color;
      const rank = (!stale || ended || archived) && !t.stale && t.rank ? `#${t.rank} · ` : '';
      card.append(el('h2', `${rank}${label(t.team)}`));
      for (const a of t.agents) card.append(el('p', `${a.display_name || label(a.name)}${a.model ? ' · ' + a.model : ''}`, 'small'));
      if (t.race) {
        card.append(el('p', `${t.race.milestones} / ${t.race.of} milestones`, 'team-run-progress'));
        const bar = el('progress'); bar.max = t.race.of; bar.value = t.race.milestones; bar.setAttribute('aria-label', `${label(t.team)} milestones`); card.append(bar);
        const detail = el('details'); detail.append(el('summary', t.race.label ? `Latest: ${t.race.label}` : 'Milestones reached'));
        const list = el('ul'); for (const m of t.race.reached) list.append(el('li', label(m))); detail.append(list); card.append(detail);
      } else card.append(el('p', 'Race standings not recorded.'));
      card.append(el('p', t.stale || stale ? 'Feed delayed' : t.gap || '', 'muted small'));
      card.append(el('p', t.coins == null ? 'Coin balance unavailable' : `${Number(t.coins).toLocaleString()} coin · ${Number(t.reserved).toLocaleString()} reserved`, 'team-run-coins'));
      if (t.pacts.length) card.append(el('p', 'Active pacts: ' + t.pacts.map(p => `#${p.id} with ${label(p.with)}`).join(', ')));
      cards.append(card);
    }
    events([...(data.events || [])].sort((a,b) => b.tick - a.tick));
  }
  async function json(url) {
    const response = await fetch(url, {cache: 'no-store'});
    if (!response.ok) throw new Error('unavailable');
    return response.json();
  }
  async function refresh() {
    try {
      if (archived) {
        render(await json('state.json'));
        historyPages = (await json('history.json')).pages;
        if (historyPages) { historyPage = 1; events(await json('events-1.json')); }
        const button = document.getElementById('team-run-older');
        button.hidden = historyPages < 2;
        button.onclick = async () => {
          button.disabled = true;
          try { const next = historyPage + 1; events(await json(`events-${next}.json`)); historyPage = next; button.hidden = historyPage >= historyPages; }
          catch (_) { document.getElementById('team-run-status').textContent = 'Older events could not be loaded. Try again.'; }
          finally { button.disabled = false; }
        };
      } else {
        const live = await json(root.dataset.api.replace(/\/$/, '') + '/v1/state');
        if (live.team_run) render(live.team_run);
        else if (state) { render(state); document.getElementById('team-run-status').textContent = 'Team progress unavailable · last recorded progress'; }
        else document.getElementById('team-run-status').textContent = 'Team progress is unavailable. Past team tests are below.';
      }
    } catch (_) {
      if (state) render(state);
      document.getElementById('team-run-status').textContent = 'Updates unavailable. ' + (state ? `Last recorded game time: ${gameTime(state.tick)}.` : 'Try again shortly.');
    }
  }
  refresh();
  if (!archived) setInterval(refresh, 10000);
})();
