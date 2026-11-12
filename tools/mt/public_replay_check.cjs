// PLAYWRIGHT=/abs/node_modules/playwright node tools/mt/public_replay_check.cjs ARTIFACTS [PORT]
//
// The production overlay page at 1920x1080 in headless Chromium, fed replay frames. Needs
//   python3 tools/mt/public_replay.py --serve ARTIFACTS/fixtures/synthetic-3x2.json --port PORT   (default 8796)
// and ARTIFACTS/fixtures/{synthetic-3x2,synthetic-4x3,synthetic-3x2-opening}.json; t291-replay.json and
// t292-replay.json (real logs) and ARTIFACTS/stills/*.png (camera stills) are used when present.
// Writes ARTIFACTS/after/*.png and ARTIFACTS/browser-check.json; exits 1 on any failed check.
const {chromium} = require(process.env.PLAYWRIGHT || 'playwright');
const fs = require('node:fs'), path = require('node:path');

(async () => {
  const dir = process.argv[2], port = process.argv[3] || 8796, out = path.join(dir, 'after');
  fs.mkdirSync(out, {recursive: true});
  const load = name => { const p = path.join(dir, 'fixtures', name); return fs.existsSync(p) ? JSON.parse(fs.readFileSync(p)) : null; };
  const pairs = load('synthetic-3x2.json'), trios = load('synthetic-4x3.json'), opening = load('synthetic-3x2-opening.json');
  const t291 = load('t291-replay.json'), t292 = load('t292-replay.json');
  const still = name => { const p = path.join(dir, 'stills', name); return fs.existsSync(p) ? fs.readFileSync(p).toString('base64') : null; };
  const browser = await chromium.launch({headless: true});
  const errors = [], checks = {}, shots = [];
  const fail = (name, detail) => { errors.push(name + (detail === undefined ? '' : ': ' + JSON.stringify(detail).slice(0, 400))); };

  async function open(query = 'poll=0&ambient=0') {
    const page = await browser.newPage({viewport: {width: 1920, height: 1080}, deviceScaleFactor: 1});
    page.on('pageerror', e => errors.push('pageerror ' + e.message));
    page.on('console', m => { if (m.type() === 'error') errors.push('console ' + m.text()); });
    page.on('response', r => { if (r.status() >= 400) errors.push(r.status() + ' ' + r.url()); });
    await page.goto(`http://127.0.0.1:${port}/?${query}`);
    await page.evaluate(() => document.fonts.ready);
    // Record every text drawn, for the checks below.
    await page.evaluate(() => {
      window.drawn = []; const fill = ctx.fillText;
      ctx.fillText = function (s, x, y, ...rest) { window.drawn.push({s: String(s), x, y, a: ctx.globalAlpha}); return fill.call(this, s, x, y, ...rest); };
    });
    return page;
  }
  // A recorded frame with its wall-clock stamps moved to now (the page ages viewer lines and news).
  const rebase = s => {
    const now = Date.now() / 1000, shift = now - s.now, c = structuredClone(s); c.now = now;
    (c.viewers || []).forEach(v => { v.t += shift; });
    (c.feed || []).concat(c.events || []).forEach(m => { if (typeof m.at === 'number') m.at += shift; });
    if (c.camera) c.camera.since += shift;
    return c;
  };
  async function camera(page, name, cam) {
    const b64 = name && still(name);
    await page.evaluate(([b64, c]) => {
      document.getElementById('cam-still')?.remove(); if (!b64) return;
      const img = document.createElement('img'); img.id = 'cam-still'; img.src = 'data:image/png;base64,' + b64;
      img.style.cssText = `position:absolute;left:${c[0]}px;top:${c[1]}px;width:${c[2]}px;height:${c[3]}px;z-index:-1`;
      document.body.prepend(img); document.body.style.background = '#000';
    }, [b64, cam || [16, 188, 1408, 792]]);
  }
  // Walk the frames before `index` so the feed and belt hold their history, then settle and capture.
  async function show(page, frames, index, walk = 8) {
    for (let i = Math.max(0, index - walk); i <= index; i++) await page.evaluate(s => { render(s); settle(); }, rebase(frames[i]));
    await page.evaluate(() => { advance(30); settle(); window.drawn.length = 0; draw(); });
    return page.evaluate(() => window.drawn.slice());
  }
  async function shot(page, name) { await page.waitForTimeout(120); await page.screenshot({path: path.join(out, name)}); shots.push(name); }
  const texts = drawn => drawn.map(d => d.s);
  const has = (drawn, s) => drawn.some(d => d.s.includes(s));
  // A name as drawn: whole, or cut with an ellipsis after at least four characters.
  const named = (drawn, n) => drawn.some(d => d.s === n || d.s === n.toUpperCase() || (d.s.endsWith('…') && d.s.length >= 5 && n.toUpperCase().startsWith(d.s.slice(0, -1).toUpperCase())));
  // Text placed outside the canvas (the belt and the feed clip their own overflow just inside it).
  const astray = drawn => drawn.filter(d => d.x > 1920 || d.y > 1080 || d.y < 0 || d.x < -140);

  // ---- the after set ---------------------------------------------------------------------------------------------
  let page = await open();
  await camera(page, 'still-ore-day.png');
  let drawn = await show(page, pairs, 36, 14); await shot(page, 'after-3x2-race.png');
  // every element reads something: standings, roster, research, feed, news, clock, camera label
  for (const need of ['YELLOW', 'GREEN', 'BLUE', 'TEAM RADIO', 'THE FACTORY RACE', 'GAME TIME', 'ON CAMERA', 'TECHS', 'SPM'])
    if (!has(drawn, need)) fail('3x2 is missing', need);
  const names3 = pairs[36].teams.flatMap(t => t.agents.map(a => a.display_name));
  for (const n of names3) if (!named(drawn.filter(d => d.y < 190), n)) fail('3x2 roster name not drawn', n);
  checks.pairs_names = names3;

  page = await open(); await camera(page, 'still-ore-two.png');
  drawn = await show(page, trios, 40, 14); await shot(page, 'after-4x3-race.png');
  // 4 teams x 3 agents: twelve names in the strip, each inside its own card and none clipped away
  const strip = drawn.filter(d => d.y < 190);
  const names12 = trios[40].teams.flatMap(t => t.agents.map(a => a.display_name));
  const seen12 = names12.filter(n => named(strip, n));
  if (seen12.length !== 12) fail('4x3 strip does not name twelve agents', {seen: seen12.length, names12});
  if (astray(drawn).length) fail('text drawn off canvas', astray(drawn).slice(0, 4));
  checks.trio_names = seen12;
  page = await open(); await camera(page, 'still-ore-two.png');
  drawn = await show(page, trios, 6, 6); await shot(page, 'after-4x3-identities.png');
  if (!has(drawn, 'NEW IDENTITY') || !has(drawn, 'TEAM BOARD')) fail('identity announcements and board notes not drawn');

  page = await open(); await camera(page, 'still-forest.png');
  drawn = await show(page, opening, 9, 9); await shot(page, 'after-opening.png');
  if (!has(drawn, 'OPENING') || !has(drawn, 'BUILT')) fail('opening foundations not drawn', texts(drawn).slice(0, 40));

  if (t292) {
    page = await open(); await camera(page, 'still-plaza-day.png');
    await show(page, t292, 300, 30); await shot(page, 'after-t292-waiting.png');
    page = await open(); await camera(page, 'still-plaza-night.png');
    await show(page, t292, 45, 30); await shot(page, 'after-t292-trade.png');
  }
  if (t291) {
    page = await open(); await camera(page, 'still-ore-two.png');
    drawn = await show(page, t291, 180, 30); await shot(page, 'after-t291-pacts.png');
    page = await open(); await camera(page, 'still-forest.png');
    await show(page, t291, 60, 30); await shot(page, 'after-t291-early.png');
    // The same page shown an earlier moment (a save reload): what came after it is dropped.
    await show(page, t291, 180, 30);
    const back = await show(page, t291, 20, 4);
    const late = t291[180].events.map(e => e.text).filter(x => !t291[20].events.some(e => e.text === x));
    if (late.some(x => has(back, x))) fail('news from after a reloaded save stayed on the belt', late.filter(x => has(back, x)));
    // the real profiles the agents set (journals): chosen glyphs and mottos reach the page
    checks.t291_names = t291[180].teams.flatMap(t => t.agents.map(a => [a.display_name, a.glyph, a.color]));
  }

  // ---- states --------------------------------------------------------------------------------------------------------
  const base = rebase(pairs[36]);
  const state = async (name, mutate, shotName, cam = 'still-plaza-day.png') => {
    const p = await open(); await camera(p, cam);
    const s = structuredClone(base); mutate(s);
    const d = await p.evaluate(s2 => { render(s2); settle(); advance(30); settle(); window.drawn.length = 0; draw(); return window.drawn.slice(); }, s);
    if (shotName) { await p.waitForTimeout(120); await p.screenshot({path: path.join(out, shotName)}); shots.push(shotName); }
    checks[name] = d.length; await p.close(); return d;
  };
  drawn = await state('stale', s => { const t = s.teams[0]; t.stale = true; t.rank = null; t.leader = false; t.gap = 'Feed delayed'; }, 'after-stale-team.png');
  if (!has(drawn, 'FEED DELAYED')) fail('stale team not marked');
  drawn = await state('paused', s => s.teams.forEach(t => { t.paused = true; }), null);
  if (!has(drawn, 'PAUSED')) fail('paused world not marked');
  drawn = await state('lost', s => { s.now -= 90; }, 'after-feed-delayed.png');
  if (!has(drawn, 'SHOWING THE LAST CONFIRMED STATE') || !has(drawn, 'DELAYED')) fail('lost feed not marked');
  // Missing telemetry: the roster's model label stands in for activity; nothing invented, no placeholder words.
  drawn = await state('missing', s => {
    s.teams.forEach(t => { t.agents.forEach(a => { a.activity = null; a.action = null; a.verb = null; a.idle_s = null; a.persona = ''; a.task = null; });
      t.science = {spm: null, series: [], stage: 0, packs: []}; t.research = {current: null, label: '', progress: null, done_count: t.research.done_count, completed: null}; t.entities = null; t.map = null; t.pacts = []; });
    s.feed = []; s.viewers = []; s.events = []; s.diplomacy = []; s.camera.agent = null; s.camera.kind = 'base';
  }, 'after-missing-telemetry.png');
  const models = [...new Set(base.teams.flatMap(t => t.agents.map(a => a.model.toUpperCase())))];
  for (const m of models) if (!has(drawn, m)) fail('model label fallback missing', m);
  const placeholder = texts(drawn).filter(t => /UNKNOWN|Awaiting|undefined|null|NaN|SPM —|No research|Waiting for/i.test(t));
  if (placeholder.length) fail('placeholder text drawn', placeholder);
  if (!has(drawn, 'Agents talking inside their own team')) fail('empty feed does not explain itself');
  // Long everything: 24-character names, 300-character lines, a 160-character persona.
  drawn = await state('long', s => {
    s.teams.forEach(t => t.agents.forEach((a, i) => { a.display_name = ['Maximilian the Relentless', 'Bartholomew of the Belts'][i % 2].slice(0, 24); a.persona = 'A meticulous planner who refuses to place a single inserter until the whole bus is drawn on paper, twice, and then argues with the paper anyway for an hour'.slice(0, 160); }));
    s.feed.forEach(m => { if (m.kind !== 'identity') m.text = (m.text + ' We need enough copper plates for every assembler, a steady supply of iron gears, and a separate belt for science so neither of us has to stop the line again. ').repeat(3).slice(0, 299) + '…'; });
  }, 'after-long-names-and-lines.png');
  if (astray(drawn).length || drawn.some(d => d.x > 1904)) fail('long text starts outside the layout', astray(drawn).concat(drawn.filter(d => d.x > 1904)).slice(0, 3));
  // Two teams, then six: the strip and the feed hold; names shrink to portraits before anything overlaps.
  await state('two', s => { s.teams = s.teams.slice(0, 2); s.feed = s.feed.filter(m => s.teams.some(t => t.team === m.team) && (!m.to_team || s.teams.some(t => t.team === m.to_team))); s.events = s.events.filter(e => s.teams.some(t => t.team === e.team)); if (!s.teams.some(t => t.team === s.camera.team)) s.camera.team = s.teams[0].team; }, 'after-two-teams.png');
  const six = structuredClone(rebase(trios[40]));
  ['purple', 'orange'].forEach((name, i) => { const t = structuredClone(six.teams[i]); t.team = name; t.rank = 5 + i; t.leader = false; t.gap = (6 + i) + ' techs back'; t.pacts = []; t.agents.forEach(a => { a.name = name + a.name; a.display_name = cap(name) + ' ' + a.display_name.split(' ')[0]; }); six.teams.push(t); });
  function cap(s) { return s[0].toUpperCase() + s.slice(1); }
  page = await open(); await camera(page, 'still-ore-day.png');
  await page.evaluate(s => { render(s); settle(); advance(30); settle(); }, six); await shot(page, 'after-six-teams.png');

  // ---- isolation: a line is drawn only under its own team; the viewer lane takes only viewer rows --------------------
  page = await open();
  const iso = structuredClone(base);
  iso.feed = [{id: 'x1', kind: 'talk', team: 'green', name: iso.teams.find(t => t.team === 'green').agents[0].name, to: [], text: 'GREEN-OWN-LINE', tick: 1, at: iso.now - 5},
    {id: 'x2', kind: 'talk', team: 'green', name: iso.teams.find(t => t.team === 'yellow').agents[0].name, to: [], text: 'FOREIGN-SENDER', tick: 2, at: iso.now - 4},
    {id: 'x3', kind: 'tell', team: 'green', name: iso.teams.find(t => t.team === 'green').agents[0].name, to: [iso.teams.find(t => t.team === 'yellow').agents[0].name], text: 'CROSS-TEAM-TELL', tick: 3, at: iso.now - 3},
    {id: 'x4', kind: 'diplomacy', team: 'green', name: iso.teams.find(t => t.team === 'green').agents[0].name, to: [], to_team: 'nowhere', text: 'UNKNOWN-TEAM-DIPLOMACY', tick: 4, at: iso.now - 2},
    {id: 'x5', kind: 'operator', team: 'green', name: iso.teams.find(t => t.team === 'green').agents[0].name, to: [], text: 'OPERATOR-LANE', tick: 5, at: iso.now - 1},
    {id: 'x6', kind: 'talk', team: 'hidden', name: 'ghost', to: [], text: 'UNKNOWN-TEAM', tick: 6, at: iso.now - 1}];
  iso.viewers = [{source: 'site', text: 'VIEWER-OWN-LINE', t: iso.now - 6, id: 'site:9'},
    {source: 'site', text: 'TEAM-ROW-IN-VIEWERS', t: iso.now - 6, team: 'green'}, {source: 'site', text: 'TELL-IN-VIEWERS', t: iso.now - 6, tell: true},
    {source: 'operator', text: 'OPERATOR-IN-VIEWERS', t: iso.now - 6}, {source: 'youtube', text: 'STALE-VIEWER', t: iso.now - 5000}];
  drawn = await page.evaluate(s => { render(s); settle(); advance(30); settle(); window.drawn.length = 0; draw(); return window.drawn.slice(); }, iso);
  const marks = texts(drawn).filter(t => /-LINE$|FOREIGN|CROSS|UNKNOWN-TEAM|OPERATOR|IN-VIEWERS|STALE/.test(t));
  checks.isolation = marks;
  if (JSON.stringify(marks.sort()) !== JSON.stringify(['GREEN-OWN-LINE', 'VIEWER-OWN-LINE'])) fail('isolation', marks);
  if (drawn.filter(d => /OWN-LINE/.test(d.s)).some(d => d.x < 1440 || d.y < 188 || d.y > 980)) fail('speech drawn outside the feed column');
  // A moderated viewer line disappears with its source row: the page keeps no copy.
  const gone = structuredClone(iso); gone.viewers = [];
  drawn = await page.evaluate(s => { render(s); settle(); advance(30); settle(); window.drawn.length = 0; draw(); return window.drawn.slice(); }, gone);
  if (has(drawn, 'VIEWER-OWN-LINE')) fail('a removed viewer line stayed on screen');

  // ---- the camera window stays clear; the Wube credit shows at the start and once an hour ------------------------------
  page = await open();
  await page.evaluate(s => { render(s); settle(); }, base);
  drawn = await page.evaluate(() => { window.drawn.length = 0; draw(); return window.drawn.slice(); });
  const creditStart = has(drawn, 'Graphics copyright Wube Software');
  const creditLater = await page.evaluate(() => { advance(40); window.drawn.length = 0; draw(); return window.drawn.some(d => d.s.includes('Wube')); });
  const creditHour = await page.evaluate(() => { advance(3600 - 40 + 3); window.drawn.length = 0; draw(); return window.drawn.some(d => d.s.includes('Wube')); });
  const creditAfter = await page.evaluate(() => { advance(30); window.drawn.length = 0; draw(); return window.drawn.some(d => d.s.includes('Wube')); });
  checks.credit = {creditStart, creditLater, creditHour, creditAfter};
  if (!creditStart || creditLater || !creditHour || creditAfter) fail('Wube credit timing', checks.credit);
  const page2 = await open(); await page2.evaluate(s => { render(s); settle(); advance(30); settle(); }, base);
  const geometry = await page2.evaluate(() => ({canvas: [canvas.width, canvas.height], scroll: [document.documentElement.scrollWidth, document.documentElement.scrollHeight],
    centre: ctx.getImageData(720, 560, 1, 1).data[3], corners: [[20, 192], [1420, 192], [20, 976], [1420, 976]].map(([x, y]) => ctx.getImageData(x, y, 1, 1).data[3]),
    outside: [[8, 500], [1432, 500], [700, 184], [700, 984]].map(([x, y]) => ctx.getImageData(x, y, 1, 1).data[3]), summary: document.getElementById('summary').textContent}));
  checks.geometry = geometry;
  if (geometry.centre !== 0) fail('camera window is not transparent');
  if (geometry.outside.some(a => a !== 255)) fail('the surround is not opaque', geometry.outside);
  if (geometry.canvas.join() !== '1920,1080' || geometry.scroll.join() !== '1920,1080') fail('page is not exactly 1920x1080', geometry);
  if (!/Vesper|Grok/.test(geometry.summary)) fail('accessible summary lacks agent names');

  // ---- motion: a new line types in, the belt carries news, a milestone drops a banner -----------------------------------
  page = await open('poll=0');
  await camera(page, 'still-ore-day.png');
  for (let i = 20; i <= 26; i++) await page.evaluate(s => { render(s); settle(); }, rebase(trios[i]));
  await page.evaluate(() => { advance(30); settle(); });
  const fresh = rebase(trios[27]); fresh.events.forEach(e => { if (!trios[26].events.some(o => o.id === e.id)) e.at = fresh.now; });
  await page.evaluate(s => render(s), fresh);
  await page.waitForTimeout(700);
  await shot(page, 'after-motion-700ms.png');
  const mid = await page.evaluate(() => ({typing: overlayDebug.feed.length, frames: overlayDebug.frames}));
  await page.waitForTimeout(1500);
  const later = await page.evaluate(() => overlayDebug.frames);
  checks.motion = {frames_in_1500ms: later - mid.frames};
  if (later - mid.frames < 20) fail('the page stopped animating', checks.motion);

  // ---- cost: script time of one full draw ----------------------------------------------------------------------------
  const cost = async (frames, index) => {
    const p = await open(); for (let i = Math.max(0, index - 8); i <= index; i++) await p.evaluate(s => { render(s); settle(); }, rebase(frames[i]));
    const t = await p.evaluate(() => { const times = []; for (let i = 0; i < 300; i++) { const t0 = performance.now(); draw(); times.push(performance.now() - t0); } times.sort((a, b) => a - b); return {median: times[150], p95: times[285], max: times[299]}; });
    await p.close(); return t;
  };
  checks.draw_ms = {three_by_two: await cost(pairs, 36), four_by_three: await cost(trios, 40)};
  if (checks.draw_ms.four_by_three.p95 > 12) fail('a draw takes too long', checks.draw_ms);

  // ---- soak (MT_SOAK=seconds): the page polling the replay server as OBS would, through the fixture's wrap-around
  // (the game clock goes back there, as when an older save is loaded)
  if (process.env.MT_SOAK) {
    const seconds = parseInt(process.env.MT_SOAK, 10), p = await open('');
    await camera(p, 'still-ore-day.png');
    const samples = [];
    for (let t = 0; t < seconds; t += 5) {
      await p.waitForTimeout(5000);
      samples.push(await p.evaluate(() => ({frames: overlayDebug.frames, feed: overlayDebug.feed.length, tweens: tweens.size, memo: memo.size,
        clock: raceState().teams.length ? Math.max(...raceState().teams.map(t => t.tick || 0)) : 0, heap: performance.memory ? Math.round(performance.memory.usedJSHeapSize / 1048576) : null})));
    }
    await p.screenshot({path: path.join(out, 'after-soak.png')}); shots.push('after-soak.png');
    const clocks = samples.map(x => x.clock), wrapped = clocks.some((c, i) => i && c < clocks[i - 1]);
    checks.soak = {seconds, frames: samples[samples.length - 1].frames, fps: +(samples[samples.length - 1].frames / seconds).toFixed(1), wrapped,
      distinct_clocks: new Set(clocks).size, max_feed: Math.max(...samples.map(x => x.feed)), max_tweens: Math.max(...samples.map(x => x.tweens)),
      max_memo: Math.max(...samples.map(x => x.memo)), heap_mb: [samples[0].heap, samples[samples.length - 1].heap]};
    if (checks.soak.distinct_clocks < seconds / 5 * .6) fail('the polled page stopped updating', checks.soak);
    if (checks.soak.fps < 20) fail('the polled page animates too slowly', checks.soak);
    if (checks.soak.max_tweens > 3000) fail('animation state grows without bound', checks.soak);
    await p.close();
  }

  const result = {shots, errors, checks};
  fs.writeFileSync(path.join(dir, 'browser-check.json'), JSON.stringify(result, null, 2));
  console.log(JSON.stringify({shots: shots.length, errors, draw_ms: checks.draw_ms, credit: checks.credit, motion: checks.motion, isolation: checks.isolation, soak: checks.soak}, null, 2));
  await browser.close();
  if (errors.length) process.exit(1);
})().catch(e => { console.error(String(e && e.stack || e).slice(0, 1500)); process.exit(1); });
