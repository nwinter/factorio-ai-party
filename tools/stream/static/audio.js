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
    #voice .cap { max-width: 1000px; padding: 7px 18px 8px 7px; border-radius: 0 3px 3px 0; display: flex; gap: 12px;
                  align-items: center; background: rgba(49, 48, 49, 0.93); border-left: 4px solid var(--edge, #ff9f1c);
                  box-shadow: inset 1px 1px 0 rgba(255,255,255,0.14), inset -1px -1px 0 rgba(0,0,0,0.55), 0 6px 22px rgba(0,0,0,0.6);
                  color: #e3e3e3; font: 500 22px/1.32 "Titillium Web", "Segoe UI", system-ui, sans-serif; opacity: 0;
                  transform: translateY(8px); transition: opacity 250ms ease, transform 250ms ease; }
    #voice .face { flex: none; width: 48px; height: 48px; border-radius: 2px; overflow: hidden; background: #1f1e1f;
                   box-shadow: 0 0 0 1px rgba(0,0,0,0.85), 0 0 0 2px rgba(255,255,255,0.08); }
    #voice .face svg { display: block; width: 100%; height: 100%; }
    #voice .body { display: flex; flex-direction: column; min-width: 0; }
    #voice .line { display: flex; align-items: center; gap: 8px; }
    #voice .cap.on { opacity: 1; transform: none; }
    #voice .who { flex: none; font-weight: 700; font-size: 14px; letter-spacing: 0.06em; text-transform: uppercase;
                  color: var(--edge, #ffe6c0); }
    #voice .role { font-size: 12.5px; color: #b0b0b0; letter-spacing: 0.04em; }
    #voice .cap .mic { flex: none; width: 8px; height: 8px; border-radius: 50%; background: #e04e3a;
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

  // an agent's colour lightened until it reads on the grey caption (4.5:1, as overlay.js does for names)
  function readable(hex) {
    const m = /^#?([0-9a-f]{6})$/i.exec(hex || "");
    if (!m) return null;
    let rgb = [0, 2, 4].map((i) => parseInt(m[1].slice(i, i + 2), 16));
    const lum = (c) => { const [r, g, b] = c.map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
      return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
    const bg = lum([49, 48, 49]);
    const base = rgb.slice();
    for (let t = 0; (lum(rgb) + 0.05) / (bg + 0.05) < 4.5 && t < 1; ) { t += 0.08; rgb = base.map((v) => v + (255 - v) * t); }
    return "#" + rgb.map((v) => Math.round(Math.min(255, v)).toString(16).padStart(2, "0")).join("");
  }

  function caption(clip) {
    if (!CAPTIONS) return null;
    const cap = document.createElement("div");
    cap.className = "cap " + clip.channel;
    // portraits: hosts from casters.js (eng/art), agents from their profile avatar (avatar.js); none without them
    const face = document.createElement("span");
    face.className = "face";
    let row = null, edge = null;
    if (clip.channel === "caster" && window.PogCasters) {
      const key = clip.who || window.PogCasters.byName(clip.speaker);
      row = key && window.PogCasters.row(key);
    } else if (clip.channel === "agent") {
      const st = window.pogState;  // overlay.js publishes the latest snapshot here
      const ag = st && (st.agents || []).find((a) => a.name === clip.agent);
      row = ag ? { name: ag.name, display_name: ag.display_name, color: ag.color, avatar: ag.avatar || undefined }
        : clip.agent ? { name: clip.agent, color: clip.color } : null;
    }
    if (row && window.PogAvatar) {
      try { face.innerHTML = window.PogAvatar.svg(row, 48, { title: clip.speaker || row.name }); } catch (err) { row = null; }
    }
    if (row && row.color) edge = readable(row.color);
    if (edge) cap.style.setProperty("--edge", edge);
    const body = document.createElement("span");
    body.className = "body";
    const line = document.createElement("span");
    line.className = "line";
    const mic = document.createElement("span");
    mic.className = "mic";
    const who = document.createElement("span");
    who.className = "who";
    who.textContent = clip.speaker || "";
    line.append(mic, who);
    // No role label ("play-by-play", "colour") on captions: the hosts go by name only.
    const text = document.createElement("span");
    text.textContent = clip.text || "";
    body.append(line, text);
    if (row && window.PogAvatar) cap.append(face);
    cap.append(body);
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
