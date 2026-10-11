// Voice player for the stream overlay: plays clips that tools/stream/caster.py pushes through serve.py.
// Two channels, each one clip at a time: "caster" (Rook and Vale) and "agent" (voiced agent chat). While an agent
// speaks, the caster channel ducks. In OBS, enable "Control audio via OBS" on the browser source so OBS mixes this
// (and ducks game audio under it with a sidechain compressor: tools/obs.py stream-audio).
// URL knobs: ?mute (no audio), ?duck=0.3 (caster gain while an agent speaks), ?caster=0.9, ?agent=1.0 (channel
// gains), ?captions=0 (hide captions). A desktop browser needs one click before audio starts (autoplay policy).
(() => {
  const params = new URLSearchParams(location.search);
  if (params.has("mute")) return;
  const num = (k, d) => (params.has(k) && !isNaN(parseFloat(params.get(k))) ? parseFloat(params.get(k)) : d);
  const DUCK = num("duck", 0.3);
  const VOL = { caster: num("caster", 0.9), agent: num("agent", 1.0) };
  const CAPTIONS = params.get("captions") !== "0";

  const style = document.createElement("style");
  style.textContent = `
    #voice { position: absolute; left: 24px; width: 1208px; top: 704px; transform: translateY(calc(-100% - 18px));
             display: flex; flex-direction: column; align-items: center; gap: 8px; pointer-events: none; }
    #voice .cap { max-width: 1000px; padding: 8px 18px 9px 10px; border-radius: 14px; display: flex; gap: 12px;
                  align-items: flex-start; background: rgba(10, 12, 18, 0.82); border: 1px solid rgba(255,255,255,0.10);
                  color: #eef0f5; font: 500 22px/1.32 "Segoe UI", system-ui, sans-serif; opacity: 0;
                  transform: translateY(8px); transition: opacity 250ms ease, transform 250ms ease; }
    #voice .cap.on { opacity: 1; transform: none; }
    #voice .who { flex: none; font-weight: 700; font-size: 15px; letter-spacing: 0.04em; text-transform: uppercase;
                  padding: 3px 9px; border-radius: 999px; margin-top: 3px; background: #2a3040; color: #cfd6e6; }
    #voice .cap.agent .who { color: #0d0f15; }
    #voice .cap .mic { flex: none; width: 10px; height: 10px; border-radius: 50%; margin-top: 11px; background: #f43f5e;
                       animation: voicepulse 1s ease-in-out infinite; }
    @keyframes voicepulse { 50% { opacity: 0.35; } }
    #voice-unlock { position: fixed; right: 16px; bottom: 16px; padding: 10px 14px; border-radius: 10px; z-index: 9;
                    background: #f43f5e; color: #fff; font: 600 16px system-ui, sans-serif; cursor: pointer; }`;
  document.head.appendChild(style);
  const box = document.createElement("div");
  box.id = "voice";
  (document.getElementById("stage") || document.body).appendChild(box);

  let ctx = null;
  const gains = {};
  function audioCtx() {
    if (!ctx) {
      ctx = new (window.AudioContext || window.webkitAudioContext)();
      for (const ch of ["caster", "agent"]) {
        gains[ch] = ctx.createGain();
        gains[ch].gain.value = VOL[ch];
        gains[ch].connect(ctx.destination);
      }
    }
    return ctx;
  }
  // Desktop browsers start the context suspended until a click; OBS's browser source does not.
  function unlockButton() {
    if (document.getElementById("voice-unlock")) return;
    const b = document.createElement("div");
    b.id = "voice-unlock";
    b.textContent = "click to enable stream audio";
    b.onclick = () => audioCtx().resume().then(() => b.remove());
    document.body.appendChild(b);
  }
  if (audioCtx().state === "suspended") unlockButton();

  const queues = { caster: [], agent: [] };
  const busy = { caster: false, agent: false };

  function report(id, state) {
    fetch("/audio/played", { method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id, state }) }).catch(() => {});
  }

  function duck(on) {
    const g = gains.caster.gain, t = ctx.currentTime;
    g.cancelScheduledValues(t);
    g.setValueAtTime(g.value, t);
    g.linearRampToValueAtTime(on ? VOL.caster * DUCK : VOL.caster, t + (on ? 0.15 : 0.6));
  }

  function caption(clip) {
    if (!CAPTIONS) return null;
    const cap = document.createElement("div");
    cap.className = "cap " + clip.channel;
    const who = document.createElement("span");
    who.className = "who";
    who.textContent = clip.speaker || "";
    if (clip.channel === "agent" && clip.color) who.style.background = clip.color;
    const mic = document.createElement("span");
    mic.className = "mic";
    const text = document.createElement("span");
    text.textContent = clip.text || "";
    cap.append(mic, who, text);
    // agents above casters, so the newest voice sits closest to the action
    if (clip.channel === "agent") box.prepend(cap); else box.appendChild(cap);
    requestAnimationFrame(() => cap.classList.add("on"));
    return cap;
  }

  async function playNext(ch) {
    if (busy[ch]) return;
    const clip = queues[ch].shift();
    if (!clip) return;
    if (Date.now() / 1000 > clip.expires) { report(clip.id, "skip"); return playNext(ch); }
    busy[ch] = true;
    let cap = null;
    try {
      const c = audioCtx();
      if (c.state === "suspended") { await c.resume().catch(() => {}); if (c.state === "suspended") unlockButton(); }
      const data = await fetch(clip.url, { cache: "no-store" }).then((r) => r.arrayBuffer());
      const buf = await c.decodeAudioData(data);
      const src = c.createBufferSource();
      src.buffer = buf;
      src.connect(gains[ch]);
      if (ch === "agent") duck(true);
      cap = caption(clip);
      report(clip.id, "start");
      await new Promise((done) => { src.onended = done; src.start(); });
      report(clip.id, "end");
    } catch (err) {
      console.error("voice clip failed", clip.id, err);
      report(clip.id, "error");
    } finally {
      if (ch === "agent" && !queues.agent.length) duck(false);
      if (cap) { cap.classList.remove("on"); setTimeout(() => cap.remove(), 400); }
      busy[ch] = false;
      setTimeout(() => playNext(ch), 300);
    }
  }

  function connect() {
    const es = new EventSource("/audio-events");
    es.onmessage = (e) => {
      try {
        const clip = JSON.parse(e.data);
        const ch = clip.channel === "agent" ? "agent" : "caster";
        queues[ch].push(clip);
        playNext(ch);
      } catch (err) { console.error(err); }
    };
  }
  connect();
})();
