// Voice player for the stream overlay: plays clips that tools/stream/caster.py pushes through serve.py.
// One voice at a time (Nick, HOSTS3 item 5): one queue for the hosts (Rook and Vale) and the agents' voiced chat. A
// new clip waits for the one playing, or, when it matters more, fades it out and plays next. Rank, high to low:
// urgent events (attack, death, rocket: rank "urgent" from caster.py) > an agent speaking aloud > answers to viewers >
// host banter. A Rook/Vale exchange stays together (its next line goes before other clips of the same rank), and a
// clip still waiting when it expires is dropped, never played late. In OBS, enable "Control audio via OBS" on the
// browser source so OBS mixes this (and ducks game audio under it: tools/obs.py stream-audio).
// URL knobs: ?mute (no audio), ?caster=0.9, ?agent=1.0 (gains), ?fade=0.25 (seconds to fade out an interrupted
// clip), ?captions=0 (hide captions). A desktop browser needs one click before audio starts (autoplay policy).
(() => {
  const params = new URLSearchParams(location.search);
  if (params.has("mute")) return;
  const num = (k, d) => (params.has(k) && !isNaN(parseFloat(params.get(k))) ? parseFloat(params.get(k)) : d);
  const VOL = { caster: num("caster", 0.9), agent: num("agent", 1.0) };
  const FADE = num("fade", 0.25);
  const RANK = { urgent: 3, agent: 2, viewer: 1, banter: 0 };
  const CAPTIONS = params.get("captions") !== "0";

  const style = document.createElement("style");
  style.textContent = `
    #voice { position: absolute; left: 24px; width: 1208px;
             top: calc(var(--main-bottom, 704px) - var(--bar-h, 0px) - var(--toasts-clear, 0px)); transform: translateY(calc(-100% - 18px));
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
    #voice .cap.operator { --edge: #e8c547; background: rgba(52, 46, 30, 0.95); }
    #voice .obadge { flex: none; width: 48px; height: 48px; border-radius: 2px; display: flex; align-items: center;
                     justify-content: center; background: #e8c547; color: #2a2208; font-weight: 700; font-size: 18px;
                     letter-spacing: 0.04em; }
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
  function audioCtx() {
    if (!ctx) ctx = new (window.AudioContext || window.webkitAudioContext)();
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

  const queue = [];
  let current = null;       // {clip, rank, src, gain, cut}
  let lastExchange = null;  // the exchange of the last host line, to keep Rook and Vale together

  function report(id, state) {
    fetch("/audio/played", { method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id, state }) }).catch(() => {});
  }

  const rankOf = (clip) => (clip.rank in RANK ? RANK[clip.rank] : clip.channel === "agent" ? RANK.agent : RANK.banter);
  const expired = (clip) => clip.expires && Date.now() / 1000 > clip.expires;

  // the next clip: drop the expired, then the highest rank; among equals, the current exchange's next line, then
  // the oldest
  function pick() {
    for (let i = queue.length - 1; i >= 0; i--) if (expired(queue[i])) { report(queue[i].id, "skip"); queue.splice(i, 1); }
    if (!queue.length) return null;
    let best = 0;
    for (let i = 1; i < queue.length; i++) {
      const a = queue[i], b = queue[best], ra = rankOf(a), rb = rankOf(b);
      const cont = (c) => lastExchange != null && c.exchange === lastExchange;
      if (ra > rb || (ra === rb && cont(a) && !cont(b))) best = i;
    }
    return queue.splice(best, 1)[0];
  }

  // a clip that matters more fades the current one out (FADE seconds) and goes next
  function interrupt() {
    const c = current;
    if (!c || c.cut) return;
    c.cut = true;
    if (!c.src) return;  // still loading: it will not start
    const g = c.gain.gain, t = ctx.currentTime;
    g.cancelScheduledValues(t);
    g.setValueAtTime(g.value, t);
    g.linearRampToValueAtTime(0, t + FADE);
    setTimeout(() => { try { c.src.stop(); } catch (err) { /* already ended */ } }, FADE * 1000 + 30);
  }

  function arrive(clip) {
    queue.push(clip);
    if (current && !current.cut && rankOf(clip) > current.rank) interrupt();
    else playNext();
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
    if (clip.channel === "operator") {  // the operator: a plain OP badge, no avatar
      const badge = document.createElement("span");
      badge.className = "obadge";
      badge.textContent = "OP";
      who.textContent = "Operator";
      cap.append(badge);
    } else if (row && window.PogAvatar) cap.append(face);
    cap.append(body);
    // agents (and the operator) above casters, so the newest voice sits closest to the action
    if (clip.channel === "agent" || clip.channel === "operator") box.prepend(cap); else box.appendChild(cap);
    requestAnimationFrame(() => cap.classList.add("on"));
    return cap;
  }

  async function playNext() {
    if (current) return;
    const clip = pick();
    if (!clip) return;
    const cur = current = { clip, rank: rankOf(clip), cut: false };
    let cap = null, state = "end";
    try {
      const c = audioCtx();
      if (c.state === "suspended") { await c.resume().catch(() => {}); if (c.state === "suspended") unlockButton(); }
      const data = await fetch(clip.url, { cache: "no-store" }).then((r) => r.arrayBuffer());
      const buf = await c.decodeAudioData(data);
      if (cur.cut) { state = "cut"; return; }          // something that matters more arrived while it loaded
      if (expired(clip)) { state = "skip"; return; }   // never late
      const g = c.createGain();
      g.gain.value = VOL[clip.channel === "agent" || clip.channel === "operator" ? "agent" : "caster"];
      g.connect(c.destination);
      const src = c.createBufferSource();
      src.buffer = buf;
      src.connect(g);
      cur.src = src;
      cur.gain = g;
      cap = caption(clip);
      report(clip.id, "start");
      // an urgent line does not reset it, so an exchange it interrupted can still finish together
      if (clip.channel === "caster" && cur.rank < RANK.urgent) lastExchange = clip.exchange != null ? clip.exchange : null;
      await new Promise((done) => { src.onended = done; src.start(); });
      if (cur.cut) state = "cut";
    } catch (err) {
      console.error("voice clip failed", clip.id, err);
      state = "error";
    } finally {
      report(clip.id, state);
      if (cap) { cap.classList.remove("on"); setTimeout(() => cap.remove(), 400); }
      current = null;
      setTimeout(playNext, cur.cut ? 60 : 300);
    }
  }

  function connect() {
    // the page's one event stream (overlay.js opens it first; /events?audio=1 sends new clips as `audio` events)
    const es = window.pogEvents || (window.pogEvents = new EventSource("/events?audio=1"));
    es.addEventListener("audio", (e) => {
      try { arrive(JSON.parse(e.data)); } catch (err) { console.error(err); }
    });
  }
  connect();
})();
