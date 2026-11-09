// Real browser, real service handler and a fault-injecting HTTP proxy. No live services.
// node overlay_recovery_browser.mjs OUTPUT PLAYWRIGHT_MODULE [soak seconds, default 600]
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
const here = path.dirname(fileURLToPath(import.meta.url));
const [out, module = 'playwright', soak = '600'] = process.argv.slice(2);
if (!out) throw Error('OUTPUT PLAYWRIGHT_MODULE [soak seconds] required');
fs.mkdirSync(out, { recursive: true });
const { chromium } = await import(module);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (fn, label, ms = 30000) => {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (await fn()) return; await sleep(100); }
  throw Error('timeout: ' + label);
};
const child = spawn(process.env.POG_TEST_PYTHON || 'agent-python', [path.join(here, 'overlay_recovery_fixture.py'), '--out', out], { stdio: ['ignore', 'pipe', 'pipe'] });
let stderr = '';
child.stderr.on('data', b => { stderr += b; });
const port = await new Promise((resolve, reject) => {
  let text = '';
  child.stdout.on('data', b => { text += b; if (text.includes('\n')) resolve(JSON.parse(text.split('\n')[0]).port); });
  child.once('exit', code => reject(Error('fixture exited ' + code + stderr)));
});
const upstream = 'http://127.0.0.1:' + port;
const command = async (action, rest) => (await fetch(upstream + '/__fixture', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action, ...rest }) })).json();
let baseline = false, blockEvents = false, delayedState = null;
const rules = new Map(), eventSockets = new Set(), traffic = [], checks = [];
const oldJS = execFileSync('git', ['show', (process.env.POG_RECOVERY_BASE || 'ddebcfaa') + ':tools/stream/static/overlay.js'], { cwd: here });
const proxy = http.createServer(async (req, res) => {
  const pathname = req.url.split('?')[0];
  const rule = rules.get(pathname)?.shift();
  traffic.push({ t: Date.now(), path: pathname, fault: rule || null });
  if (rule === 'hang') { await sleep(8000); if (res.destroyed) return; }
  if (rule === 'stall') { res.writeHead(200, { 'Content-Type': 'text/event-stream' }); res.write(': stalled\n\n'); eventSockets.add(res); res.on('close', () => eventSockets.delete(res)); return; }
  if (rule === 'invalid') { res.writeHead(200); res.end('{'); return; }
  if (rule === 'shape') { res.writeHead(200); res.end('{}'); return; }
  if (rule === 503 || (pathname === '/events' && blockEvents)) { res.writeHead(503); res.end('fixture outage'); return; }
  if (baseline && pathname === '/static/overlay.js') { res.writeHead(200, { 'Content-Type': 'text/javascript' }); res.end(oldJS); return; }
  if (pathname === '/state.json' && delayedState && !delayedState.captured) {
    const pending = delayedState;
    pending.body = await (await fetch(upstream + '/state.json')).text(); pending.captured = true;
    await pending.wait;
    if (!res.destroyed) { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(pending.body); }
    return;
  }
  const target = http.request(upstream + req.url, { method: req.method, headers: req.headers }, response => {
    res.writeHead(response.statusCode, response.headers); response.pipe(res);
  });
  target.on('error', () => { if (!res.headersSent) res.writeHead(502); res.end(); });
  res.on('close', () => { target.destroy(); eventSockets.delete(res); });
  if (pathname === '/events') eventSockets.add(res);
  req.pipe(target);
});
await new Promise(r => proxy.listen(0, '127.0.0.1', r));
const url = 'http://127.0.0.1:' + proxy.address().port;
const browser = await chromium.launch({ headless: true, executablePath: process.env.POG_TEST_CHROMIUM,
  args: ['--autoplay-policy=no-user-gesture-required'] });
const check = (name, detail = {}) => { checks.push({ name, t: Date.now(), ...detail }); console.log('PASS ' + name); };
let page;
const state = value => command('state', { value });
const health = () => page.evaluate(() => window.PogOverlayHealth.snapshot());
const visible = async key => (await health()).layers[key].visible;
const screenshot = name => page.screenshot({ path: path.join(out, name + '.png') });
try {
  baseline = true; rules.set('/static/layout.json', [503]);
  page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
  await page.goto(url); await sleep(12000);
  assert.equal(await page.locator('#cam-main .cam-bar').count(), 0);
  assert.equal(traffic.filter(x => x.path === '/static/layout.json').length, 1);
  await screenshot('baseline-failed-layout');
  check('baseline: one failed layout leaves bar absent despite continuing state');
  await page.close(); baseline = false;

  rules.set('/static/layout.json', [503, 'invalid', 'shape', 'hang']);
  rules.set('/static/layout-3cam.json', ['hang', 503]);
  rules.set('/overlay/health', [503, 'hang']);
  page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
  const pageErrors = [];
  page.on('pageerror', e => pageErrors.push(String(e)));
  await page.goto(url);
  await until(() => visible('bar'), 'primary layout recovers', 40000);
  const early = await health();
  assert(early.requests.layout.failures === 4);
  assert(!early.requests['trio-layout'].okAt);
  await screenshot('recovered-main-before-trio');
  check('main recovered after HTTP, malformed JSON, invalid shape, timeout; trio still pending');
  await until(async () => (await health()).requests['trio-layout'].okAt, 'trio recovers');
  await state({ program: { layout: 'trio' }, cameras: { main: { agents: [], map: 'Nauvis main' }, cam2: { agents: [], map: 'Gleba second' }, cam3: { agents: [], map: 'Vulcanus third' } } });
  await until(() => page.evaluate(() => document.body.classList.contains('trio')), 'trio');
  assert(await page.locator('#cam-cam2 .cam-label').isVisible());
  await state({});
  await until(() => page.evaluate(() => !document.body.classList.contains('trio')), 'onecam restored');
  check('trio enters and returns to onecam after late layout retry');

  const speech = await command('speech', { seconds: 8 });
  await until(() => visible('caption'), 'speech caption');
  await screenshot('speech-caption');
  check('real WebAudio speech draws subtitle');
  await until(async () => (await (await fetch(upstream + '/audio/status')).json()).playing.length === 0, 'speech ends');
  const now = Date.now() / 1000;
  await state({ tour: [{ id: 'recovery-tour', cut: now, until: now + 10, view: { position: { x: 0, y: 0 }, zoom: 1 },
    subs_at: now, subs: [{ t0: 0, t1: 10, text: 'Tour narration subtitle' }], marks: [] }] });
  await command('speech', { seconds: 6, text: 'Tour narration subtitle', meta: { caption: false, at: now + 1, tour: 'recovery-tour', segment: { id: 'recovery-tour', part: 1, parts: 1 } } });
  await until(() => visible('tour'), 'tour subtitle');
  assert(await visible('bar')); await screenshot('tour');
  await sleep(10000); await state({});
  await until(async () => !(await visible('tour')), 'tour exit');
  check('timed tour narration and own subtitle, then normal exit');

  const recap = { active: true, run: 'fixture', id: 'recap', title: 'Recorded shift', text: 'Earlier events', speaker: 'Rook', phase: 'recap' };
  await state({ shift_recap: recap });
  await until(async () => (await health()).recap && !(await visible('bar')), 'recap entry');
  assert(!(await visible('voice'))); assert(await visible('recap'));
  await screenshot('recap');
  // Capture an old recap HTTP response, then let a newer SSE exit arrive first.
  let release;
  delayedState = { wait: new Promise(r => { release = r; }) };
  await until(() => delayedState.captured, 'delayed poll captured', 20000);
  await state({ shift_recap: null });
  await until(() => visible('bar'), 'recap SSE exit');
  release(); await sleep(800); delayedState = null;
  assert(!(await health()).recap); assert(await visible('bar'));
  check('late HTTP recap snapshot cannot undo newer SSE exit');

  await state({ shift_recap: recap });
  await until(async () => (await health()).recap, 'second recap entry');
  blockEvents = true; for (const res of eventSockets) res.destroy();
  rules.set('/state.json', [503, 'hang', 'invalid']);
  await state({ shift_recap: null });
  await until(() => visible('bar'), 'recap exit over failed poll recovery', 40000);
  assert(!(await health()).recap);
  blockEvents = false;
  await command('speech', { seconds: 6, text: 'Subtitles restored after recap' });
  await until(() => visible('caption'), 'caption after recap');
  await screenshot('recap-exit-speech');
  check('SSE outage and failed/hung/malformed polls recover recap exit and subtitles');

  await page.evaluate(() => console.error('intentional health console probe'));
  await until(async () => {
    const s = await (await fetch(upstream + '/overlay/status')).json();
    return s.health.sessions.some(x => x.errors.some(e => e.message.includes('intentional health console probe')) && x.layers.bar.visible);
  }, 'health report with errors and visibility');
  check('health POST retry, status and JSONL include visible layers and console/fetch errors');

  // An existing subtitle, not only a newly created one, must be uncovered on recap exit.
  await until(async () => !(await visible('caption')), 'previous caption ends');
  await command('speech', { seconds: 8, text: 'Existing subtitle survives recap visibility' });
  await until(() => visible('caption'), 'existing subtitle');
  await state({ shift_recap: recap }); await until(async () => !(await visible('caption')), 'existing caption hidden');
  await state({ shift_recap: { ...recap, holding: true } }); await until(() => visible('caption'), 'holding restores existing caption');
  await state({});
  check('recap holding/exit restores the same still-playing subtitle');
  await until(async () => !(await visible('caption')), 'existing subtitle ends');

  await state({ platform_metrics: { platform: 'Solstice', speed_kms: 120,
    leg: { from: 'nauvis', to: 'gleba', pct: 45 }, tick: 100, age_s: 0 } });
  await until(() => visible('platform'), 'platform telemetry');
  await state({ shift_recap: recap }); await until(async () => !(await visible('platform')), 'recap hides platform');
  await state({ platform_metrics: { platform: 'Solstice', speed_kms: 120,
    leg: { from: 'nauvis', to: 'gleba', pct: 46 }, tick: 101, age_s: 0 } });
  await until(() => visible('platform'), 'platform after recap');
  await screenshot('platform-restored');
  check('platform card redraws from current state after recap');
  await state({});

  rules.set('/events', ['stall']); for (const res of eventSockets) res.destroy();
  await until(() => traffic.some(x => x.path === '/events' && x.fault === 'stall'), 'silent SSE connection');
  await command('speech', { seconds: 4, text: 'Speech after silent SSE watchdog' });
  await until(() => visible('caption'), 'silent SSE watchdog resumes audio', 40000);
  assert((await health()).errors.some(e => e.message.includes('stalled for 20s')));
  check('silent SSE watchdog reconnects audio and state without page reload');

  const end = Date.now() + Number(soak) * 1000;
  let cycle = 0;
  while (Date.now() < end) {
    await state({ cameras: { main: { agents: [], map: 'Nauvis soak ' + cycle } } });
    await until(() => visible('label'), 'soak label');
    const clip = await command('speech', { seconds: 2, text: 'Soak speech ' + cycle });
    await until(() => visible('caption'), 'soak speech');
    assert(await visible('bar'));
    await sleep(3000);
    await state({ shift_recap: { ...recap, id: 'soak-' + cycle } });
    await until(async () => (await health()).recap, 'soak recap');
    if (cycle % 2 === 0) {
      blockEvents = true; for (const res of eventSockets) res.destroy(); rules.set('/state.json', [503]);
    }
    await state({ shift_recap: null });
    await until(() => visible('bar'), 'soak restore', 30000);
    blockEvents = false;
    assert(!(await health()).classes.includes('recap-active'));
    assert.equal(await page.locator('#cam-main .cam-bar').count(), 1);
    check('soak cycle ' + cycle++, { clip: clip.id });
    await sleep(Math.min(12000, Math.max(0, end - Date.now())));
  }
  assert.deepEqual(pageErrors, []);
  await screenshot('soak-final');
  const receipts = fs.readFileSync(path.join(out, 'audio-played.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
  assert(receipts.some(x => x.id === speech.id && x.state === 'end' && x.completed));
  check('soak complete with whole speech receipts, no page exceptions or duplicate bars', { seconds: Number(soak), cycles: cycle });
  // Portrait uses the same retry/recovery path but never acquires landscape trio holes.
  await page.close(); page = await browser.newPage({ viewport: { width: 1080, height: 1920 } });
  await page.goto(url + '/portrait');
  await until(() => visible('bar'), 'portrait bar');
  await state({ shift_recap: recap }); await until(async () => (await health()).recap, 'portrait recap');
  await state({}); await until(() => visible('bar'), 'portrait exit');
  await command('speech', { seconds: 4 }); await until(() => visible('caption'), 'portrait caption');
  await screenshot('portrait-restored');
  check('portrait recap exit restores bar and subtitles');
  fs.writeFileSync(path.join(out, 'summary.json'), JSON.stringify({ passed: true, checks, final: await health() }, null, 2));
} catch (err) {
  if (page && !page.isClosed()) { await screenshot('failure'); fs.writeFileSync(path.join(out, 'failure-health.json'), JSON.stringify(await page.evaluate(() => window.PogOverlayHealth?.snapshot()), null, 2)); }
  fs.writeFileSync(path.join(out, 'summary.json'), JSON.stringify({ passed: false, checks, error: String(err) }, null, 2));
  throw err;
} finally {
  fs.writeFileSync(path.join(out, 'traffic.json'), JSON.stringify(traffic, null, 2));
  fs.writeFileSync(path.join(out, 'fixture-stderr.log'), stderr);
  await browser.close(); proxy.closeAllConnections(); proxy.close(); child.kill('SIGTERM');
}
