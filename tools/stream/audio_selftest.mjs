// Runs static/audio.js (the overlay's voice player) in Node with a fake DOM and a fake WebAudio graph, against a
// running serve.py. Pushes test clips, then checks: one clip at a time per channel, casters duck while an agent
// speaks and come back after, expired clips are skipped, and start/end reports reach /audio/status.
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

// ---- fake WebAudio: buffers last as long as the decoded mp3 (ffprobe), gains record their ramps
class Param {
  constructor(name, v) { this.name = name; this.value = v; }
  cancelScheduledValues() {}
  setValueAtTime(v) { this.value = v; }
  linearRampToValueAtTime(v) { note(`gain ${this.name} -> ${v.toFixed(2)}`); this.value = v; }
}
let gainCount = 0;
class FakeCtx {
  constructor() { this.state = "running"; this.currentTime = 0; this.destination = {}; }
  createGain() { const n = ["caster", "agent"][gainCount++] || "x"; return { gain: new Param(n, 1), connect() {} }; }
  resume() { return Promise.resolve(); }
  async decodeAudioData(buf) {
    const f = path.join(process.env.TMPDIR || "/tmp", `selftest-${Math.random().toString(36).slice(2)}.mp3`);
    fs.writeFileSync(f, Buffer.from(buf));
    const d = parseFloat(execFileSync("ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", f]).toString());
    fs.unlinkSync(f);
    return { duration: d };
  }
  createBufferSource() {
    const src = { buffer: null, onended: null, connect(g) { src.dest = g.gain.name; },
      start() {
        note(`play ${src.dest} ${src.buffer.duration.toFixed(2)}s`);
        if (src.dest === "agent") setTimeout(async () => { during = await status(); note(`status while agent plays: ${during.playing.map((p) => p.channel)}`); }, 400);
        setTimeout(() => { note(`end ${src.dest}`); src.onended(); }, src.buffer.duration * 1000); } };
    return src;
  }
}

// ---- fake DOM: just enough for audio.js
const el = () => ({ style: {}, classList: { add() {}, remove() {} }, append() {}, appendChild() {}, prepend() {}, remove() {}, set textContent(v) {}, set className(v) {} });
const document = { head: el(), body: el(), createElement: el, getElementById: (id) => (id === "stage" ? el() : null) };
const ctx = vm.createContext({
  window: {}, document, location: { search: "" }, URLSearchParams, console,
  requestAnimationFrame: (f) => setTimeout(f, 16), setTimeout,
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
let during = null;

await new Promise((r) => setTimeout(r, 800));
if (process.argv[3] === "--listen") {  // just be the page for N seconds (caster.py end-to-end runs)
  await new Promise((r) => setTimeout(r, parseFloat(process.argv[4] || "120") * 1000));
  const plays = log.filter((l) => / play /.test(l)).length;
  console.log(`listened: ${plays} clips played`);
  process.exit(0);
}
const s0 = await status();
note(`listeners=${s0.listeners}`);
const c1 = tone("Here they come, the biters hit the west wall, what a moment for Luna!", "draco");
const c2 = tone("Two belts, balanced.", "theia");
const c3 = tone("Vale here: the wall is the whole game now.", "thalia");
py(["--push", c1, "--push-channel", "caster", "--push-text", "caster one"]);
await new Promise((r) => setTimeout(r, 600));
py(["--push", c2, "--push-channel", "agent", "--push-text", "agent one"]);
py(["--push", c3, "--push-channel", "caster", "--push-text", "caster two"]);
py(["--push", c3, "--push-channel", "caster", "--push-text", "expired", "--push-expires", "0"]);
await new Promise((r) => setTimeout(r, 1500));
const s1 = await status();
note(`playing=${JSON.stringify(s1.playing.map((p) => p.channel))}`);
await new Promise((r) => setTimeout(r, 12000));
const s2 = await status();
note(`after: playing=${s2.playing.length} last_report=${s2.last_report ? "yes" : "no"}`);

const text = log.join("\n");
const checks = {
  "page connected as a listener": s0.listeners >= 1,
  "caster and agent overlap with the caster ducked": /gain caster -> 0\.27/.test(text) &&
    !!during && during.playing.map((p) => p.channel).sort().join() === "agent,caster",
  "caster level restored after the agent line": /gain caster -> 0\.90/.test(text),
  "second caster clip waits for the first": (text.match(/play caster/g) || []).length === 2 &&
    text.indexOf("end caster") < text.lastIndexOf("play caster"),
  "expired clip skipped": (text.match(/play caster/g) || []).length === 2,
  "all reports in, nothing left playing": s2.playing.length === 0 && !!s2.last_report,
};
let ok = true;
for (const [k, v] of Object.entries(checks)) { console.log(`${v ? "PASS" : "FAIL"} ${k}`); ok &&= v; }
process.exit(ok ? 0 : 1);
