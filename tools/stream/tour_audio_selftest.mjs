// Runs static/audio.js (the overlay's voice player) in Node with a fake DOM, a fake WebAudio graph and a scripted
// event stream (no service): the tour's timed clips (d23 batch128 CK1). A clip with `at` starts at that moment on the
// audio clock and reports started_at; a queued agent line that would still play then waits for it and plays after; a
// short one that fits plays first; a cancelled timed clip never plays; never two voices at once.
//   node tools/stream/tour_audio_selftest.mjs        (test_touraudio.py runs it)
import fs from "node:fs";
import vm from "node:vm";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const t0 = Date.now();
const now = () => Date.now() / 1000;
const log = [], reports = [];
const note = (...a) => log.push(`${((Date.now() - t0) / 1000).toFixed(2)}s ${a.join(" ")}`);
let active = 0, maxActive = 0;
const played = {};  // clip name -> epoch seconds it started

class Param { constructor(v) { this.value = v; } cancelScheduledValues() {} setValueAtTime(v) { this.value = v; }
  linearRampToValueAtTime(v) { this.value = v; } }
class FakeCtx {
  constructor() { this.state = "running"; this.t0 = Date.now(); this.destination = {}; }
  get currentTime() { return (Date.now() - this.t0) / 1000; }
  createGain() { return { gain: new Param(1), connect() {} }; }
  resume() { return Promise.resolve(); }
  async decodeAudioData(buf) { return { duration: JSON.parse(Buffer.from(buf).toString()).seconds, name: JSON.parse(Buffer.from(buf).toString()).name }; }
  createBufferSource() {
    const self = this;
    let timer = null, end = null, ended = false;
    const src = { buffer: null, onended: null,
      connect() {},
      start(when) {
        const wait = Math.max(0, ((when || 0) - self.currentTime) * 1000);
        timer = setTimeout(() => {
          active += 1; maxActive = Math.max(maxActive, active);
          played[src.buffer.name] = now(); note(`play ${src.buffer.name}`);
          end = setTimeout(() => src.finish("end"), src.buffer.duration * 1000);
        }, wait);
      },
      stop() { clearTimeout(timer); if (end) { clearTimeout(end); src.finish("stopped"); } else if (!ended) { ended = true; } },
      finish(how) { if (ended) return; ended = true; active -= 1; note(`${how} ${src.buffer.name}`); if (src.onended) src.onended(); } };
    return src;
  }
}
const el = () => ({ style: { setProperty() {} }, classList: { add() {}, remove() {} }, append() {}, appendChild() {},
  prepend() {}, remove() {}, set textContent(v) {}, set className(v) {}, set innerHTML(v) {} });
const document = { head: el(), body: el(), createElement: el, getElementById: (id) => (id === "stage" ? el() : null) };
const listeners = {};
class FakeES { constructor() {} addEventListener(k, f) { listeners[k] = f; } }
const clips = {};
const fakeFetch = async (u, o) => {
  if (u === "/audio/played") { reports.push(JSON.parse(o.body)); return { ok: true }; }
  const c = clips[u.split("/").pop()];
  return { arrayBuffer: async () => Buffer.from(JSON.stringify({ seconds: c.seconds, name: c.name })) };
};
const ctx = vm.createContext({ window: {}, document, location: { search: "" }, URLSearchParams, console,
  requestAnimationFrame: (f) => setTimeout(f, 16), setTimeout, clearTimeout, fetch: fakeFetch, EventSource: FakeES });
ctx.window.AudioContext = FakeCtx;
ctx.AudioContext = FakeCtx;
vm.runInContext(fs.readFileSync(path.join(here, "static", "audio.js"), "utf8"), ctx);

let seq = 0;
const send = (name, seconds, meta) => {
  const id = `c${++seq}`;
  clips[id] = { name, seconds };
  listeners.audio({ data: JSON.stringify(Object.assign({ id, url: `/audio/clip/${id}`, t: now(), expires: now() + 30,
    channel: "agent", speaker: name, text: name, duration: seconds }, meta || {})) });
  return id;
};
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

await wait(100);
const at1 = now() + 2.0;
send("N1", 1.0, { channel: "narrator", rank: "urgent", at: at1 });
await wait(300);
send("A_long", 2.5);    // would still play at at1: waits, plays after N1
send("A_short", 0.6);   // fits before at1: plays first, while A_long waits
const at2 = now() + 1.2;
const cut = send("N_cancelled", 1.0, { channel: "narrator", rank: "urgent", at: at2 + 30 });
await wait(200);
listeners.audio({ data: JSON.stringify({ id: "x1", channel: "control", cancel: cut, t: now() }) });
await wait(6200);

const start1 = reports.find((r) => r.state === "start" && r.id === "c1");
const order = log.filter((l) => / play /.test(l)).map((l) => l.split(" play ")[1]);
const checks = {
  "the timed clip starts at its moment (within 0.15 s)": Math.abs(played.N1 - at1) < 0.15,
  "its start report says when (started_at within 0.15 s)": !!start1 && Math.abs(start1.started_at - at1) < 0.15,
  "an agent line that would still play at that moment waits, then plays after it": order.indexOf("A_long") > order.indexOf("N1")
    && played.A_long >= at1 + 1.0 - 0.05,
  "a short agent line that fits before it plays first": order[0] === "A_short" && played.A_short + 0.6 < at1,
  "a cancelled timed clip never plays": !order.includes("N_cancelled") && reports.some((r) => r.id === cut && r.state === "skip"),
  "never two voices at once": maxActive === 1,
  "every clip that played reported its end": ["c1", "c2", "c3"].every((id) => reports.some((r) => r.id === id && r.state === "end")),
};
console.log(log.join("\n"));
let ok = true;
for (const [k, v] of Object.entries(checks)) { console.log(`${v ? "PASS" : "FAIL"} ${k}`); ok &&= v; }
process.exit(ok ? 0 : 1);
