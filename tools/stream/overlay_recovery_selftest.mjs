// Exercise the production retry primitive with short timers; no browser/package/network dependency.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
const source = fs.readFileSync(new URL('static/overlay.js', import.meta.url), 'utf8');
const prefix = source.slice(0, source.indexOf('  let reportDelay =')) + '\n})();';
let active = 0, maxActive = 0, revision = 0;
const delays = [], attempts = [];
const responses = [503, 'invalid', {}, 'hang', { agents: [] }];
const window = { addEventListener() {}, fetch: async (url, options) => {
  active++; maxActive = Math.max(maxActive, active); attempts.push(url); revision++;
  const response = responses.shift();
  try {
    if (response === 'hang') await new Promise((resolve, reject) => options.signal.addEventListener('abort', () => reject(Error('aborted'))));
    return { ok: response !== 503, status: response === 503 ? 503 : 200,
      async json() { if (response === 'invalid') throw Error('invalid JSON'); return response; } };
  } finally { active--; }
} };
const context = { window, console: { error() {} }, AbortController, Date, Math, Promise, URLSearchParams,
  setTimeout(fn, ms) { delays.push(ms); return setTimeout(fn, ms === 5000 ? 20 : 1); }, clearTimeout,
  fetch(...args) { return window.fetch(...args); } };
vm.runInNewContext(prefix, context);
const h = window.PogOverlayHealth;
const result = await h.retryJSON('state', '/state.json', s => Array.isArray(s?.agents), () => revision);
assert.deepEqual(result.value, { agents: [] });
assert.equal(result.revision, 4); // revision captured before the successful request
assert.equal(attempts.length, 5);
assert.equal(maxActive, 1);
assert.deepEqual(delays.filter(x => x !== 5000), [500, 1000, 2000, 4000]);
assert.equal(active, 0);
console.log('overlay retry: HTTP, parse, validation, abort, exponential backoff, one in flight, per-attempt revision passed');
