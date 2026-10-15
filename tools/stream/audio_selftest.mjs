// Runs static/audio.js (the overlay's voice player) in Node with a fake DOM and a fake WebAudio graph, against a
// running serve.py. Pushes overlapping clips, then checks one voice at a time (HOSTS3 item 5): never two clips
// playing, no clip cut off (viewer craigNZ830, shift01: queue voice lines, play them in order), a clip that matters
// more plays next (urgent, then an agent, then host banter), the rest of a Rook/Vale exchange goes before other
// banter, an expired clip is dropped, and every report reaches /audio/status.
//   python3 tools/stream/serve.py --mock --port 8796 &
//   node --experimental-eventsource tools/stream/audio_selftest.mjs http://127.0.0.1:8796
import fs from "node:fs";
import vm from "node:vm";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const base = process.argv[2] || "http://127.0.0.1:8796";
const here = path.dirname(fileURLToPath(import.meta.url));
const t0 = Date.now();
const log = [];
const status = async () => (await fetch(base + "/audio/status")).json();
const note = (...a) => { const line = `${((Date.now() - t0) / 1000).toFixed(2)}s ${a.join(" ")}`; log.push(line); console.log(line); };

// ---- fake WebAudio: buffers last as long as the decoded mp3 (ffprobe); each clip gets its own gain
let lastText = "", active = 0, maxActive = 0;
class Param {
  constructor(v) { this.value = v; }
  cancelScheduledValues() {}
  setValueAtTime(v) { this.value = v; }
  linearRampToValueAtTime(v) { if (v === 0) note(`fade ${this.owner}`); this.value = v; }
}
class FakeCtx {
  constructor() { this.state = "running"; this.t0 = Date.now(); this.destination = {}; }
  get currentTime() { return (Date.now() - this.t0) / 1000; }  // the audio clock: the page measures what it played
  createGain() { return { gain: new Param(1), connect() {} }; }
  resume() { return Promise.resolve(); }
  async decodeAudioData(buf) {
    const f = path.join(process.env.TMPDIR || "/tmp", `selftest-${Math.random().toString(36).slice(2)}.mp3`);
    fs.writeFileSync(f, Buffer.from(buf));
    const d = parseFloat(execFileSync("ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", f]).toString());
    fs.unlinkSync(f);
    return { duration: d };
  }
  createBufferSource() {
    let timer = null, ended = false;
    const src = { buffer: null, onended: null, name: "",
      connect(g) { src.g = g; },
      start() {
        src.name = lastText;
        src.g.gain.owner = src.name;
        active += 1; maxActive = Math.max(maxActive, active);
        note(`play ${src.name}`);
        timer = setTimeout(() => src.finish("end"), src.buffer.duration * 1000);
      },
      stop() { clearTimeout(timer); src.finish("stopped"); },
      finish(how) { if (ended) return; ended = true; active -= 1; note(`${how} ${src.name}`); src.onended(); } };
    return src;
  }
}

// ---- fake DOM: just enough for audio.js; the caption's last text is the clip's text
const el = () => ({ style: { setProperty() {} }, classList: { add() {}, remove() {} }, append() {}, appendChild() {},
  prepend() {}, remove() {}, set textContent(v) { lastText = v; }, set className(v) {}, set innerHTML(v) {} });
const document = { head: el(), body: el(), createElement: el, getElementById: (id) => (id === "stage" ? el() : null) };
const ctx = vm.createContext({
  window: {}, document, location: { search: "" }, URLSearchParams, console,
  requestAnimationFrame: (f) => setTimeout(f, 16), setTimeout, clearTimeout,
  fetch: (u, o) => fetch(new URL(u, base), o), EventSource: class extends EventSource { constructor(u) { super(new URL(u, base)); } },
});
ctx.window.AudioContext = FakeCtx;
ctx.AudioContext = FakeCtx;
vm.runInContext(fs.readFileSync(path.join(here, "static", "audio.js"), "utf8"), ctx);

// ---- push clips (tone TTS via voices.py) and watch
const py = (args) => execFileSync("python3", [path.join(here, "caster.py"), "--feed", base, ...args]).toString();
const tone = (text, voice) => {
  const out = execFileSync("python3", [path.join(here, "voices.py"), text, "--tts", "tone", "--voice", voice, "--out", process.env.TMPDIR || "/tmp"]).toString();
  return JSON.parse(out.split("\n")[0]).file;
};
const push = (file, text, ...more) => py(["--push", file, "--push-text", text, ...more]);
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

await wait(800);
if (process.argv[3] === "--listen") {  // just be the page for N seconds (caster.py end-to-end runs)
  await wait(parseFloat(process.argv[4] || "120") * 1000);
  console.log(`listened: ${log.filter((l) => / play /.test(l)).length} clips played`);
  process.exit(0);
}
const s0 = await status();
note(`listeners=${s0.listeners}`);
const long = tone("Here they come, the biters hit the west wall, what a moment for Luna, and the turrets are dry!", "draco");
const short = tone("Two belts, balanced.", "theia");
const mid = tone("Vale here: the wall is the whole game now.", "thalia");
push(long, "A1", "--push-channel", "caster", "--push-rank", "banter", "--push-exchange", "A");
await wait(500);
push(mid, "B1", "--push-channel", "caster", "--push-rank", "banter", "--push-exchange", "B");
push(short, "A2", "--push-channel", "caster", "--push-rank", "banter", "--push-exchange", "A");
await wait(400);
push(long, "G", "--push-channel", "agent");                               // an agent speaks aloud: A1 plays on
await wait(900);
push(short, "U", "--push-channel", "caster", "--push-rank", "urgent");   // a death: next, ahead of G
push(short, "X", "--push-channel", "caster", "--push-rank", "banter", "--push-expires", "0");  // already stale
await wait(20000);
const s2 = await status();
note(`after: playing=${s2.playing.length} last_report=${s2.last_report ? "yes" : "no"}`);

const text = log.join("\n");
const order = log.filter((l) => / play /.test(l)).map((l) => l.split(" play ")[1]);
note(`order: ${order.join(" ")}`);
const checks = {
  "page connected as a listener": s0.listeners >= 1,
  "never two voices at once": maxActive === 1,
  "no clip is cut off (no fade, no stop)": !/ fade | stopped /.test(text),
  "what matters more plays next: urgent, the agent, then the rest of the exchange before other banter":
    order.join(" ") === "A1 U G A2 B1",
  "an expired clip is dropped": !order.includes("X"),
  "all reports in, nothing left playing": s2.playing.length === 0 && !!s2.last_report,
  // (viewer syndesis, shift14 23:04) the page's own measure: every clip played its length, none counted early
  "the service counts them played whole, none ended early": !!s2.voice && !!s0.voice &&
    s2.voice.played_last_hour - s0.voice.played_last_hour === 5 && s2.voice.ended_early_last_hour === s0.voice.ended_early_last_hour,
};
let ok = true;
for (const [k, v] of Object.entries(checks)) { console.log(`${v ? "PASS" : "FAIL"} ${k}`); ok &&= v; }
process.exit(ok ? 0 : 1);
