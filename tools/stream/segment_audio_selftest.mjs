// Runs static/audio.js in Node with a fake DOM, WebAudio and event stream (as tour_audio_selftest.mjs): the segment
// hold (d28 batch319 SU, viewer Aurora site:5401). A narrated piece's parts ({segment: {id, part, parts}}) hold the
// routine lines until the last part has played; an urgent line may go between two parts; an operator line held
// longer than its expiry still plays after, host banter drops; a `release` event, a failed last part and a timeout
// each end the hold (no stuck mute); a clip sent twice (a reconnect's replay) plays once; a page loaded again gets
// the queued lines replayed and plays each once.
//   node tools/stream/segment_audio_selftest.mjs        (test_segmenthold.py runs it)
import fs from "node:fs";
import vm from "node:vm";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const src = fs.readFileSync(path.join(here, "static", "audio.js"), "utf8");
const now = () => Date.now() / 1000;
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const fails = [];
const check = (ok, what) => { if (!ok) fails.push(what); console.log(`${ok ? "ok  " : "FAIL"} ${what}`); };

class Param { constructor(v) { this.value = v; } cancelScheduledValues() {} setValueAtTime(v) { this.value = v; }
  linearRampToValueAtTime(v) { this.value = v; } }

// one page: audio.js in its own context, with its own clock of plays and reports
function page(search) {
  const P = { plays: [], reports: [], active: 0, maxActive: 0, listeners: {}, clips: {} };
  class FakeCtx {
    constructor() { this.state = "running"; this.t0 = Date.now(); this.destination = {}; }
    get currentTime() { return (Date.now() - this.t0) / 1000; }
    createGain() { return { gain: new Param(1), connect() {} }; }
    resume() { return Promise.resolve(); }
    async decodeAudioData(buf) { const j = JSON.parse(Buffer.from(buf).toString()); return { duration: j.seconds, name: j.name }; }
    createBufferSource() {
      const self = this;
      let timer = null, end = null, ended = false;
      const s = { buffer: null, onended: null, connect() {},
        start(when) {
          const w = Math.max(0, ((when || 0) - self.currentTime) * 1000);
          timer = setTimeout(() => {
            P.active += 1; P.maxActive = Math.max(P.maxActive, P.active);
            P.plays.push({ name: s.buffer.name, start: now(), end: null });
            end = setTimeout(() => s.finish(), s.buffer.duration * 1000);
          }, w);
        },
        stop() { clearTimeout(timer); if (end) { clearTimeout(end); s.finish(); } },
        finish() { if (ended) return; ended = true; P.active -= 1;
          const p = P.plays.find((x) => x.name === s.buffer.name && x.end == null); if (p) p.end = now();
          if (s.onended) s.onended(); } };
      return s;
    }
  }
  const el = () => ({ style: { setProperty() {} }, classList: { add() {}, remove() {} }, append() {}, appendChild() {},
    prepend() {}, remove() {}, set textContent(v) {}, set className(v) {}, set innerHTML(v) {} });
  const document = { head: el(), body: el(), createElement: el, getElementById: (id) => (id === "stage" ? el() : null) };
  class FakeES { addEventListener(k, f) { P.listeners[k] = f; } }
  const fakeFetch = async (u, o) => {
    if (u === "/audio/played") { P.reports.push(JSON.parse(o.body)); return { ok: true }; }
    const c = P.clips[u.split("/").pop()];
    if (!c || c.fail) throw new Error("404");  // the service restarted: the clip is gone
    return { arrayBuffer: async () => Buffer.from(JSON.stringify({ seconds: c.seconds, name: c.name })) };
  };
  const ctx = vm.createContext({ window: {}, document, location: { search: search || "" }, URLSearchParams, console,
    requestAnimationFrame: (f) => setTimeout(f, 16), setTimeout, clearTimeout, fetch: fakeFetch, EventSource: FakeES });
  ctx.window.AudioContext = FakeCtx;
  vm.runInContext(src, ctx);
  P.win = ctx.window;
  let seq = 0;
  P.send = (name, seconds, meta, id) => {
    id = id || `${name}-${++seq}`;
    P.clips[id] = { name, seconds, fail: !!(meta && meta.fail) };
    const clip = Object.assign({ id, url: `/audio/clip/${id}`, t: now(), expires: now() + 30, channel: "agent", speaker: name,
      text: name, duration: seconds }, meta || {});
    delete clip.fail;
    P.listeners.audio({ data: JSON.stringify(clip) });
    return clip;
  };
  P.event = (o) => P.listeners.audio({ data: JSON.stringify(Object.assign({ t: now() }, o)) });
  P.played = (name) => P.plays.filter((p) => p.name === name);
  P.skip = (id) => P.reports.find((r) => r.id === id && r.state === "skip");
  return P;
}
const seg = (id, part, parts) => ({ channel: "narrator", rank: "urgent", segment: { id, part, parts } });

// 1. a burst during a two-part piece: nothing routine between the parts; an urgent line may go in the gap; an operator
//    line held past its expiry plays after; host banter past its expiry drops; one voice at a time
{
  const P = page("?holdgap=3");
  await wait(50);
  const t = now();
  P.send("N1", 0.8, Object.assign(seg("hour-1", 1, 2), { at: t + 0.5 }));
  await wait(150);
  for (const n of ["A1", "A2", "A3"]) P.send(n, 0.3);
  P.send("OP", 0.3, { channel: "operator", rank: "agent", expires: now() + 1.2 });
  P.send("BANTER", 0.3, { channel: "caster", rank: "banter", expires: now() + 1.2 });
  await wait(1400);  // N1 has ended (t+1.3); the gap until part 2
  P.send("URGENT", 0.3, { channel: "caster", rank: "urgent" });
  await wait(100);
  P.send("N2", 0.8, Object.assign(seg("hour-1", 2, 2), { at: t + 2.4 }));
  await wait(3800);
  const n2 = P.played("N2")[0];
  const routine = ["A1", "A2", "A3", "OP"].map((n) => P.played(n)[0]);
  check(routine.every((p) => p), "every routine line played once the piece was over");
  check(routine.every((p) => p && p.start >= n2.end - 0.05), "none between the parts or over them (they waited for the last part)");
  const u = P.played("URGENT")[0];
  check(u && u.start < n2.start && u.start > P.played("N1")[0].end - 0.05, "the urgent line went in the gap between the parts");
  check(P.played("OP").length === 1, "the operator line, held past its expiry, kept its place and played");
  check(P.played("BANTER").length === 0 && P.skip(P.reports.find((r) => r.state === "skip") && P.reports.find((r) => r.state === "skip").id)
    && P.reports.some((r) => r.state === "skip" && r.reason === "expired"), "host banter past its expiry dropped (skip: expired)");
  check(P.maxActive === 1, "one voice at a time");
}

// 2. the end of a hold: a `release` event (the tour stopped early), a failed last part (the clip is gone after a
//    restart), a timeout (the next part never came): each lets the waiting lines play, nothing stays muted
{
  const P = page("?holdgap=1");
  await wait(50);
  let t = now();
  P.send("R1", 0.4, Object.assign(seg("piece-r", 1, 3), { at: t + 0.3 }));
  await wait(100);
  P.send("B1", 0.2);
  await wait(800);  // R1 ended at t+0.7; parts 2-3 never come
  check(P.played("B1").length === 0, "held after part 1 of 3");
  P.event({ channel: "control", release: "piece-r" });
  await wait(400);
  check(P.played("B1").length === 1, "a release event ends the hold at once");

  t = now();
  P.send("F1", 0.3, Object.assign(seg("piece-f", 1, 2), { at: t + 0.2 }));
  P.send("F2", 0.3, Object.assign(seg("piece-f", 2, 2), { at: t + 0.8, fail: true }));
  await wait(100);
  P.send("B2", 0.2);
  await wait(1300);
  check(P.reports.some((r) => r.state === "error" && P.clips[r.id] && P.clips[r.id].name === "F2"), "the failed part reports error");
  check(P.played("B2").length === 1, "a failed last part ends the hold");

  t = now();
  P.send("T1", 0.3, Object.assign(seg("piece-t", 1, 2), { at: t + 0.2 }));
  await wait(100);
  P.send("B3", 0.2);
  await wait(900);
  check(P.played("B3").length === 0, "held while the next part may still come (holdgap)");
  await wait(1000);
  check(P.played("B3").length === 1, "the hold times out when the next part never comes");
  check(P.win.pogVoiceHolding() === false, "no hold left");
}

// 3. a reconnect sends the queued clips again: each plays once; a page loaded again mid-piece gets them replayed
{
  const P = page("");
  await wait(50);
  const c = P.send("DUP", 0.2);
  P.listeners.audio({ data: JSON.stringify(c) });  // the same clip again (the service's replay to a reconnect)
  await wait(500);
  check(P.played("DUP").length === 1, "a clip sent twice plays once");

  const t = now();
  const old = page("?holdgap=1");
  await wait(50);
  old.send("M1", 0.5, Object.assign(seg("piece-m", 1, 2), { at: t + 0.3 }));
  await wait(100);
  const q1 = old.send("Q1", 0.2), q2 = old.send("Q2", 0.2);
  await wait(300);
  // the page reloads during part 1: the new page has no queue and no hold; the service replays what is queued (the
  // timed part 1 is past, part 2 comes later as usual)
  const fresh = page("?holdgap=1");
  await wait(50);
  for (const q of [q1, q2]) { fresh.clips[q.id] = old.clips[q.id]; fresh.listeners.audio({ data: JSON.stringify(q) }); }
  fresh.clips["M2"] = { name: "M2", seconds: 0.4 };
  fresh.listeners.audio({ data: JSON.stringify(Object.assign({ id: "M2", url: "/audio/clip/M2", t: now(), expires: now() + 30,
    duration: 0.4, text: "M2", speaker: "Narrator", at: t + 1.0 }, seg("piece-m", 2, 2))) });
  await wait(2000);
  const m2 = fresh.played("M2")[0];
  check(fresh.played("Q1").length === 1 && fresh.played("Q2").length === 1, "the reloaded page plays the replayed lines, once each");
  check(m2 && fresh.played("Q1")[0].start >= m2.end - 0.05, "and holds them for the piece's last part");
  check(fresh.maxActive === 1, "one voice at a time after the reload");
}

console.log(fails.length ? `FAILED: ${fails.length}` : "segment_audio_selftest: all ok");
process.exit(fails.length ? 1 : 0);
