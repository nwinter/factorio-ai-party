// Real overlay + WebAudio + original prepared speech. The fixture never calls OBS/game/TTS/live services.
// node recap_speech_browser.mjs SOURCE_RUN OUTPUT_DIR [PLAYWRIGHT_MODULE]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import assert from 'node:assert/strict';

const here = path.dirname(fileURLToPath(import.meta.url));
const [source, out, module = 'playwright'] = process.argv.slice(2);
if (!source || !out) throw new Error('SOURCE_RUN OUTPUT_DIR [PLAYWRIGHT_MODULE] required');
const { chromium } = await import(module);
fs.mkdirSync(out, { recursive: true });
const browser = await chromium.launch({ headless: true, executablePath: process.env.POG_TEST_CHROMIUM,
  args: ['--autoplay-policy=no-user-gesture-required'] });
const sleep = ms => new Promise(r => setTimeout(r, ms));
const run = promisify(execFile);
async function until(fn, label, seconds = 65) {
  const end = Date.now() + seconds * 1000;
  while (Date.now() < end) { if (await fn()) return; await sleep(100); }
  throw new Error('timeout: ' + label);
}

async function instrument(page) {
  await page.addInitScript(() => {
    const Native = window.AudioContext;
    const audit = window.audioAudit = { maxSources: 0, peak: 0, samples: [], receipts: [] };
    const contexts = [];
    window.AudioContext = class extends Native {
      constructor(...args) {
        super(...args);
        const mix = super.createGain(), dest = this.createMediaStreamDestination(), analyser = this.createAnalyser();
        mix.connect(dest); mix.connect(analyser);
        const recorder = new MediaRecorder(dest.stream), chunks = [];
        recorder.ondataavailable = e => chunks.push(e.data);
        recorder.start();
        const sources = [];
        contexts.push({ recorder, chunks });
        const gain = this.createGain.bind(this), source = this.createBufferSource.bind(this);
        this.createGain = () => {
          const g = gain(), connect = g.connect.bind(g);
          g.connect = destination => { if (destination === this.destination) connect(mix); return connect(destination); };
          return g;
        };
        this.createBufferSource = () => {
          const s = source(), start = s.start.bind(s), connect = s.connect.bind(s);
          const row = { when: Infinity, ended: false, gain: null };
          s.connect = g => { row.gain = g; return connect(g); };
          s.start = (when = this.currentTime) => { row.when = when; sources.push(row); return start(when); };
          s.addEventListener('ended', () => { row.ended = true; });
          return s;
        };
        const data = new Float32Array(analyser.fftSize);
        setInterval(() => {
          analyser.getFloatTimeDomainData(data);
          const peak = Math.max(...data.map(Math.abs));
          const active = sources.filter(s => !s.ended && s.when <= this.currentTime && s.gain.gain.value > 0).length;
          audit.maxSources = Math.max(audit.maxSources, active);
          audit.peak = Math.max(audit.peak, peak);
          audit.samples.push({ t: Date.now() / 1000, active, peak });
        }, 20);
      }
    };
    const nativeFetch = window.fetch;
    window.fetch = (...args) => {
      if (args[0] === '/audio/played') audit.receipts.push(JSON.parse(args[1].body));
      return nativeFetch(...args);
    };
    window.saveAudioAudit = async () => {
      const recordings = [];
      for (const c of contexts) {
        if (c.recorder.state !== 'inactive') await new Promise(r => { c.recorder.onstop = r; c.recorder.stop(); });
        const bytes = new Uint8Array(await new Blob(c.chunks).arrayBuffer());
        let binary = ''; for (const b of bytes) binary += String.fromCharCode(b);
        recordings.push(btoa(binary));
      }
      return { audit, recordings };
    };
  });
}

const summary = [];
try {
  for (const scenario of (process.env.POG_TEST_SCENARIOS || 'entry-playing,entry-loading,interruption,reload,reconnect').split(',')) {
    const dir = path.join(out, scenario);
    const child = spawn(process.env.POG_TEST_PYTHON || 'agent-python', [path.join(here, 'recap_speech_fixture.py'),
      '--source', source, '--out', dir], { stdio: ['ignore', 'pipe', 'pipe'] });
    let stderr = '';
    child.stderr.on('data', b => { stderr += b; });
    const url = await new Promise((resolve, reject) => {
      let data = '';
      child.stdout.on('data', b => { data += b; if (data.includes('\n')) resolve(JSON.parse(data.split('\n')[0]).url); });
      child.on('exit', code => reject(new Error('fixture exit ' + code + ': ' + stderr)));
    });
    const context = await browser.newContext({ viewport: { width: 1920, height: 1080 } });
    const page = await context.newPage(), errors = [];
    page.on('pageerror', e => errors.push(e.message));
    await instrument(page);
    const command = async body => (await fetch(url + '/__fixture', { method: 'POST', body: JSON.stringify(body) })).json();
    const status = async () => (await fetch(url + '/audio/status')).json();
    const rows = () => fs.existsSync(path.join(dir, 'audio-played.jsonl'))
      ? fs.readFileSync(path.join(dir, 'audio-played.jsonl'), 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : [];
    const save = async suffix => {
      const { audit, recordings } = await page.evaluate(() => window.saveAudioAudit());
      fs.writeFileSync(path.join(dir, suffix + '.json'), JSON.stringify(audit));
      recordings.forEach((s, i) => fs.writeFileSync(path.join(dir, `${suffix}-${i}.webm`), Buffer.from(s, 'base64')));
      assert(audit.maxSources <= 1, scenario + ': overlapping WebAudio sources');
      assert(audit.peak > 0.01, scenario + ': no nonzero audio samples');
      return audit;
    };
    try {
      await page.goto(url + '/?preview');
      await until(async () => (await status()).listeners > 0, 'overlay connected');
      let before = null;
      if (scenario.startsWith('entry')) {
        let loading = false, delay = scenario === 'entry-loading';
        if (delay) await page.route('**/audio/clip/*', async route => {
          if (delay) { delay = false; loading = true; await sleep(1600); }
          await route.continue();
        });
        before = await command({ action: 'push', seconds: 4 });
        await until(async () => scenario === 'entry-loading' ? loading : (await status()).playing.some(r => r.id === before.id), 'pre-recap clip');
      }
      const started = Date.now() / 1000;
      await command({ action: 'start' });
      const probes = [];
      for (const body of [{ channel: 'agent' }, { channel: 'operator' }, { channel: 'caster', rank: 'urgent' },
                          { channel: 'narrator', timed: true }, { channel: 'caster', rank: 'banter', ttl: 1 }])
        probes.push(await command({ action: 'push', ...body }));
      await until(async () => (await status()).playing.some(r => !probes.some(p => p.id === r.id) && r.id !== before?.id), 'recap playback');
      if (scenario === 'entry-playing')
        await run(path.join(here, 'overlay_shot.sh'), [url + '/?preview&mute', path.join(dir, 'entry.png'), '--wait-ms', '1200']);
      if (scenario === 'interruption') {
        await sleep(600);
        await command({ action: 'interrupt' });
      } else if (scenario === 'reload') {
        await sleep(600); await save('before-reload'); await page.reload();
      } else if (scenario === 'reconnect') {
        // Closing the actual SSE socket proves reconnect; Chromium's offline emulation can leave SSE open.
        const before = (await (await fetch(url + '/overlay/status')).json()).pages.main.connects;
        assert((await command({ action: 'disconnect' })).disconnected > 0);
        await until(async () => (await (await fetch(url + '/overlay/status')).json()).pages.main.connects > before,
          'EventSource reconnects');
      }
      await until(async () => !(await status()).speech_owner, 'recap releases speech');
      await until(() => probes.slice(0, 4).every(p => rows().some(r => r.id === p.id && r.completed)), 'held probes heard');
      const log = rows(), ended = log.filter(r => r.recap && r.ended), completed = ended.filter(r => r.completed);
      const release = scenario === 'interruption'
        ? JSON.parse(fs.readFileSync(path.join(dir, 'commands.json'))).find(c => c.action === 'interrupt').t
        : Math.max(...completed.map(r => r.t));
      for (const p of probes.slice(0, 4)) {
        assert.equal(log.filter(r => r.id === p.id && r.completed).length, 1, 'deduplicated completion');
        assert(log.find(r => r.id === p.id && r.state === 'start').t >= release, 'foreign start before release');
      }
      assert(!log.some(r => r.id === probes[4].id && r.state === 'start'), 'stale banter started');
      if (scenario !== 'interruption') assert.equal(new Set(completed.map(r => r.recap.line)).size, 2, 'both whole recap lines');
      else assert.equal(completed.length, 0, 'interrupted recap counted as heard');
      if (scenario === 'entry-loading') assert(!log.some(r => r.id === before.id && r.state === 'start' && r.t < release));
      if (scenario === 'reload') assert(ended.some(r => r.state === 'reload' && !r.completed));
      if (scenario === 'reconnect') assert(ended.some(r => r.state === 'held' && !r.completed));
      assert.equal(errors.length, 0, errors.join('\n'));
      if (scenario === 'entry-playing')
        await run(path.join(here, 'overlay_shot.sh'), [url + '/?preview&mute', path.join(dir, 'end.png'), '--wait-ms', '1200']);
      await page.screenshot({ path: path.join(dir, 'end-browser.png') });
      const audit = await save('output');
      summary.push({ scenario, url, started, release, completed: completed.length, maxSources: audit.maxSources,
                     peak: audit.peak, errors, pass: true });
      console.log(JSON.stringify(summary.at(-1)));
      fs.writeFileSync(path.join(out, 'summary.json'), JSON.stringify(summary, null, 2));
    } finally {
      await context.close();
      child.kill('SIGTERM'); // only the fixture process created above
      fs.writeFileSync(path.join(dir, 'service.stderr'), stderr);
    }
  }
} finally { await browser.close(); }
