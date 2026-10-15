// Stream overlay: renders /events snapshots into a 1920x1080 transparent page (OBS browser source).
(() => {
  "use strict";
  const params = new URLSearchParams(location.search);
  if (params.has("preview")) document.body.classList.add("preview");

  const PANEL = [49, 48, 49]; // --fx-frame (factorio-ui.css)
  const DEEP = [36, 35, 36];
  const SLOT_LABEL = { main: "Main", cam2: "Cam 2", cam3: "Cam 3", inset: "Inset" };
  // One camera on air (layout.json mode "onecam", tools/stream/onecam.py): a bar along the on-air view's bottom edge
  // holds who it follows; toasts (at most TOAST_MAX, identical lines merged, TOAST_S seconds) sit just above it.
  const BAR_H = 44, TOAST_MAX = 2, TOAST_S = 12;
  let onecam = false;
  const ITEM = {
    "iron-plate": ["Iron plate", "#9fb3c8"], "copper-plate": ["Copper plate", "#e0895a"],
    "steel-plate": ["Steel", "#c7ccd6"], "electronic-circuit": ["Green circuit", "#5fd068"],
    "advanced-circuit": ["Red circuit", "#ef5b5b"], "plastic-bar": ["Plastic", "#e8e8e8"],
    "automation-science-pack": ["Red science", "#f05454"], "logistic-science-pack": ["Green science", "#4cc764"],
    "military-science-pack": ["Military sci.", "#9aa0a6"], "chemical-science-pack": ["Blue science", "#4aa3ff"],
    "production-science-pack": ["Purple sci.", "#b06cf0"], "utility-science-pack": ["Yellow sci.", "#f5d142"],
    "space-science-pack": ["Space sci.", "#f0f0f0"], "metallurgic-science-pack": ["Metallurgic sci.", "#f08a3a"],
    "electromagnetic-science-pack": ["Electromag. sci.", "#e05ad0"], "agricultural-science-pack": ["Agricultural sci.", "#b8d84a"],
    "cryogenic-science-pack": ["Cryogenic sci.", "#6ad0f0"], "promethium-science-pack": ["Promethium sci.", "#8a5ad8"],
    "iron-ore": ["Iron ore", "#7d97b0"], "copper-ore": ["Copper ore", "#c8784a"], "coal": ["Coal", "#8d8d8d"],
    "stone": ["Stone", "#b5a27a"], "stone-brick": ["Stone brick", "#c9b48a"], "iron-gear-wheel": ["Gears", "#a9b6c4"],
    "copper-cable": ["Copper cable", "#e6965f"], "transport-belt": ["Belts", "#f2c230"], "inserter": ["Inserters", "#e8b04a"],
    "firearm-magazine": ["Ammo", "#e3c25a"], "piercing-rounds-magazine": ["Piercing ammo", "#e07a5a"],
    "stone-wall": ["Walls", "#b8b0a0"], "engine-unit": ["Engines", "#c4a383"], "sulfur": ["Sulfur", "#e8e05a"],
    "battery": ["Batteries", "#b0c8a0"], "solid-fuel": ["Solid fuel", "#9a9a9a"], "processing-unit": ["Blue circuit", "#5a8cff"],
    "electric-engine-unit": ["Elec. engines", "#7fc0e0"], "flying-robot-frame": ["Robot frames", "#9fb0c0"],
    "low-density-structure": ["Low density", "#d0a070"], "rocket-fuel": ["Rocket fuel", "#f08a3a"],
    "rocket-part": ["Rocket parts", "#e8e8e8"], "satellite": ["Satellite", "#d8e0e8"],
  };
  const SHORT_PACK = { "automation-science-pack": "Red", "logistic-science-pack": "Green", "military-science-pack": "Military",
    "chemical-science-pack": "Blue", "production-science-pack": "Purple", "utility-science-pack": "Yellow", "space-science-pack": "Space",
    "metallurgic-science-pack": "Metallurgic", "electromagnetic-science-pack": "Electromagnetic", "agricultural-science-pack": "Agricultural",
    "cryogenic-science-pack": "Cryogenic", "promethium-science-pack": "Promethium" };
  const PROD_CELLS = 4, PROD_PINNED = 2, PROD_ROTATE_S = 10;
  const ATTENTION_ICON = { looking: "👁️", building: "🏗️", configuring: "⚙️", "moving items": "📦", fighting: "⚔️" };
  const ALERT_ICON = { attack: "⚔️", loss: "🔥", death: "💀", power: "⚡", research: "🔬", info: "ℹ️", space: "🚀", arrival: "🛰️" };
  // board event verbs as a viewer reads them ("Astra took: ...")
  const VERB = { posted: "posted", taken: "took", assigned: "assigned", released: "released", started: "started",
    done: "finished", blocked: "is blocked on", dropped: "dropped", reopened: "reopened", step: "finished a step of" };
  const KIND = { request: "request", task: "task", claim: "claim", harness: "tool", note: "note", project: "project" };
  const PROJ_S = 9; // the board shows for 18 s at a time (rotateWidgets): its bottom row gives claims and projects half each

  // ---------- colour handling: agents pick any colour; keep everything readable on the dark panels ----------
  function parseHex(c) {
    const m = /^#?([0-9a-f]{6}|[0-9a-f]{3})$/i.exec((c || "").trim());
    if (!m) return null;
    let h = m[1];
    if (h.length === 3) h = h.split("").map((x) => x + x).join("");
    return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16));
  }
  const toHex = (rgb) => "#" + rgb.map((v) => Math.round(Math.max(0, Math.min(255, v))).toString(16).padStart(2, "0")).join("");
  function lum(rgb) {
    const [r, g, b] = rgb.map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  }
  const contrast = (a, b) => { const x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); };
  const mix = (a, b, t) => a.map((v, i) => v + (b[i] - v) * t);
  function hashColor(name) {
    let h = 0;
    for (const ch of name || "?") h = (h * 31 + ch.codePointAt(0)) >>> 0;
    const hue = h % 360;
    return hslToRgb(hue / 360, 0.62, 0.58);
  }
  function hslToRgb(h, s, l) {
    const f = (n) => { const k = (n + h * 12) % 12; const a = s * Math.min(l, 1 - l); return l - a * Math.max(-1, Math.min(k - 3, 9 - k, 1)); };
    return [f(0) * 255, f(8) * 255, f(4) * 255];
  }
  const paletteCache = new Map();
  function palette(agent) {
    const key = (agent.color || "") + "|" + agent.name;
    if (paletteCache.has(key)) return paletteCache.get(key);
    const base = parseHex(agent.color) || hashColor(agent.name);
    // text in the agent's colour, lightened until it reads on the panel (4.5:1)
    let ink = base, t = 0;
    while (contrast(ink, PANEL) < 4.5 && t < 1) { t += 0.08; ink = mix(base, [255, 255, 255], t); }
    // glyph colour: whichever of near-white / near-black contrasts better with the fill
    const glyph = contrast(base, [255, 255, 255]) >= contrast(base, [17, 17, 17]) ? "#ffffff" : "#111111";
    // ring: when the fill nearly disappears into the panel, outline it in a lightened version of itself
    const ring = contrast(base, PANEL) < 1.8 ? toHex(mix(base, [255, 255, 255], 0.55)) : "rgba(0,0,0,0.22)";
    // edge: the ink at ~55% for camera rings; tint: a dark wash of the colour behind emoji glyphs (no color-mix in OBS)
    const p = { fill: toHex(base), ink: toHex(ink), glyph, ring, edge: toHex(ink) + "8c", tint: toHex(mix(base, DEEP, 0.72)) };
    paletteCache.set(key, p);
    return p;
  }
  function applyPalette(el, agent) {
    const p = palette(agent);
    el.style.setProperty("--agent", p.fill);
    el.style.setProperty("--agent-ink", p.ink);
    el.style.setProperty("--glyph-ink", p.glyph);
    el.style.setProperty("--ring", p.ring);
    el.style.setProperty("--agent-edge", p.edge);
    el.style.setProperty("--agent-tint", p.tint);
  }

  // ---------- small DOM helpers ----------
  const $ = (id) => document.getElementById(id);
  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }
  function setText(e, text) { text = text == null ? "" : String(text); if (e.textContent !== text) e.textContent = text; }
  // 12345678 -> "12.3M", 45600 -> "45.6K" (tokens.py short)
  function shortNum(v) {
    v = Number(v || 0);
    for (const [d, u] of [[1e9, "B"], [1e6, "M"], [1e3, "K"]])
      if (v >= d) { const x = v / d; return (x < 100 ? x.toFixed(1) : x.toFixed(0)) + u; }
    return String(Math.round(v));
  }
  function graphemes(s) {
    if (window.Intl && Intl.Segmenter) return [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(s)].map((x) => x.segment);
    return Array.from(s);
  }
  const EMOJI_RE = /\p{Extended_Pictographic}/u;
  function glyphOf(agent) {
    let g = (agent.glyph || "").trim();
    if (!g) g = (agent.display_name || agent.name || "?").trim();
    const parts = graphemes(g);
    const emoji = parts.length && EMOJI_RE.test(parts[0]);
    const text = emoji ? parts[0] : parts.slice(0, 2).join("");
    return { text, two: !emoji && graphemes(text).length > 1, emoji };
  }
  function avatar(agent, size) {
    const a = el("div", "avatar" + (size ? " " + size : ""));
    fillAvatar(a, agent, size);
    return a;
  }
  function fillAvatar(a, agent, size) {
    // agent-designed pixel art (avatar.js, docs/ART-NOTES.md); unset parts are drawn from the name
    if (window.PogAvatar && agent.name && !agent.tool) {
      a.className = "avatar pix" + (size ? " " + size : "");
      applyPalette(a, agent);
      const sig = "pix|" + agent.name + "|" + (agent.color || "") + "|" + JSON.stringify(agent.avatar || null);
      if (a.dataset.sig !== sig) {
        a.dataset.sig = sig;
        try {
          a.innerHTML = window.PogAvatar.svg({ name: agent.name, display_name: agent.display_name, color: agent.color,
            avatar: agent.avatar || undefined }, 48, { title: agent.display_name || agent.name });
          return;
        } catch (err) { console.error(err); }
      } else return;
    }
    const g = glyphOf(agent);
    a.className = "avatar" + (size ? " " + size : "") + (g.two ? " two" : "") + (g.emoji ? " emo" : "");
    applyPalette(a, agent);
    const sig = g.text + g.emoji;
    if (a.dataset.sig !== sig) {
      a.dataset.sig = sig;
      a.textContent = "";
      a.appendChild(el("span", g.emoji ? "emoji" : "", g.text));
    }
  }
  const clean = (s) => (s || "").replace(/\[\/?[a-z-]+(=[^\]]*)?\]/gi, ""); // strip Factorio rich-text tags
  const humanItem = (s) => (s || "").replace(/[_-]+/g, " ");

  // ---------- layout ----------
  let layout = null;
  // The director's trio (onecam.py: one big tile and two small ones for a minute or two, snapshot program.layout):
  // the landscape page takes layout-3cam.json's holes while it lasts. The portrait page stays one camera.
  let trioCams = null, curMode = null;
  // portrait.html sets data-layout="layout-portrait" for the 9:16 canvas
  // ?layout=layout-3cam brings back the three-camera layout (main and two side cameras)
  fetch("/static/" + (params.get("layout") || document.body.dataset.layout || "layout") + ".json").then((r) => r.json()).then((l) => {
    layout = l;
    onecam = l.mode === "onecam";
    document.body.classList.toggle("onecam", onecam);
    if (onecam) SLOT_LABEL.main = "On air";
    const trio = onecam && !document.body.classList.contains("portrait") && !params.get("layout");
    const go = (t) => {
      trioCams = t;
      for (const c of document.querySelectorAll(".cam")) if (!l.cams[c.dataset.slot] && !(t && t[c.dataset.slot])) c.remove();
      // a bar along each view's bottom edge: it holds the label and covers the client's bottom-centre hint ("Press Tab
      // to skip cutscene" stays on the cam clients after the Space Age intro, though they are spectators)
      if (onecam) for (const id of ["cam-main", "cam-cam2", "cam-cam3", "cam-inset"]) if ($(id)) $(id).append(el("div", "cam-bar"));
      applyLayout(curMode === "trio" && t ? "trio" : "onecam");
    };
    if (trio) fetch("/static/layout-3cam.json").then((r) => r.json()).then((t) => go(t.cams)).catch(() => go(null));
    else go(null);
  });

  function applyLayout(mode) {
    if (!layout) return;
    curMode = mode;
    const l = layout, cams = mode === "trio" ? trioCams : l.cams;
    document.body.classList.toggle("trio", mode === "trio");
    for (const [slot, [x, y, w, h]] of Object.entries(cams)) {
      const c = $("cam-" + slot);
      if (!c) continue;
      Object.assign(c.style, { left: x + "px", top: y + "px", width: w + "px", height: h + "px" });
    }
    const m = cams.main;
    const [cw, ch] = l.canvas || [1920, 1080];
    if (m) {
      const st = document.body.style;
      st.setProperty("--main-bottom", m[1] + m[3] + "px");
      st.setProperty("--bar-h", (onecam ? BAR_H : 0) + "px");
      st.setProperty("--canvas-h", ch + "px");
    }
    if (m && onecam) {
      Object.assign($("alerts").style, { right: cw - m[0] - m[2] + 14 + "px", bottom: ch - m[1] - m[3] + BAR_H + 10 + "px" });
    } else if (m) Object.assign($("alerts").style, { left: m[0] + "px", width: m[2] + "px", top: m[1] + 64 + "px" });
    if (m) Object.assign($("segment").style, { left: m[0] + "px", top: m[1] + "px", width: m[2] + "px",
      height: m[3] - (onecam ? BAR_H : 0) + "px" });
  }

  // ---------- render ----------
  const cards = new Map();
  let researchCard = null;
  let state = null;

  function renderHead(s) {
    setText($("title"), s.title || "Player of Games");
    setText($("subtitle"), s.subtitle || "");
    setText($("clock"), s.game_time || "");
    const sub = $("clock-sub");
    const stale = s.poll_ok && s.now - s.poll_ok > 20;
    setText(sub, s.paused ? "game paused" : stale ? "reconnecting…" : "game time");
    sub.classList.toggle("warn", !!(s.paused || stale));
  }

  function renderCards(s) {
    const box = $("cards");
    const agents = s.agents.filter((a) => a.seen !== false || a.display_name);
    const space = s.space || {};
    // 2 columns; the research card takes one cell. Up to 7 agents: 4 roomy rows; 8-9: 5 rows; 10-12: 7 compact rows.
    const density = agents.length <= 7 ? "1" : agents.length <= 9 ? "2" : "3";
    if (document.body.dataset.density !== density) document.body.dataset.density = density;
    const keep = new Set();
    agents.forEach((a, i) => {
      keep.add(a.name);
      let c = cards.get(a.name);
      if (!c) {
        c = { root: el("div", "card panel") };
        c.av = avatar(a);
        const body = el("div", "body");
        const r1 = el("div", "row1");
        c.name = el("div", "name");
        c.badge = el("div", "badge");
        c.harness = el("div", "harness");
        c.world = el("div", "world");
        c.tok = el("div", "tok");  // tokens this shift (model.py, tokens.py)
        c.tok.title = "tokens this shift";
        r1.append(c.name, c.badge, c.world, c.harness, c.tok);
        c.model = el("div", "model");
        const doing = el("div", "doing");
        c.dot = el("span", "dot");
        c.txt = el("span", "txt");
        c.where = el("span", "where");
        doing.append(c.dot, c.txt, c.where);
        body.append(r1, c.model, doing);
        c.root.append(c.av, body);
        cards.set(a.name, c);
        box.appendChild(c.root);
      }
      c.root.style.order = i;
      applyPalette(c.root, a);
      fillAvatar(c.av, a);
      setText(c.name, a.display_name || a.name);
      setText(c.harness, a.harness || "");
      setText(c.tok, a.tokens ? shortNum(a.tokens) + " tok" : "");
      // line two: model, then the agent's current job (a viewer, shift05: "displaying the current plan of each bot
      // instead of the motto"; model.py job: its team-plan line, else its notes.md "## Now"); without one the motto
      // from `profiles` (an agent that never called `profile` gets a quiet note instead), else the role
      const unset = a.profile_set === false;
      const job = a.job ? clean(a.job) : "";
      const motto = job ? "" : unset ? "profile not set" : a.motto ? "“" + clean(a.motto) + "”" : "";
      const msig = [a.model, a.role, job, motto].join("|");
      if (c.model.dataset.sig !== msig) {
        c.model.dataset.sig = msig;
        c.model.textContent = "";
        c.model.append(el("b", "", a.model || "model ?"));
        if (job) c.model.append(document.createTextNode(" · "), el("span", "job", job));
        else if (motto) c.model.append(document.createTextNode(" · "), el(unset ? "span" : "i", unset ? "unset" : "", motto));
        else if (a.role) c.model.append(document.createTextNode(" · " + a.role));
        c.model.title = job && a.motto ? "“" + clean(a.motto) + "”" : "";
      }
      c.dot.className = "dot " + a.activity;
      let doing = a.action || "";
      if (a.activity === "thinking" && !a.active) doing = "thinking…";
      if (a.activity === "idle" && !doing) doing = "idle";
      setText(c.txt, humanItem(doing));
      // Space Age: which planet or platform the body is on, once more than Nauvis is in play
      const world = space.active && a.where ? a.where : "";
      setText(c.world, world);
      c.world.className = "world" + (world ? " on " + (a.on_platform ? "platform" : "p-" + (a.surface || "")) : "");
      setText(c.where, a.location && a.location !== world ? "· " + a.location : "");
      // the harness label gives way when the name does not fit beside the planet and tokens (Nick, 12:20: "Sonnet and
      // Gemini and Muse Spark names are cut off next to the planet location and harness")
      c.root.classList.remove("squeezed");
      if (c.harness.textContent && c.name.scrollWidth > c.name.clientWidth + 1) c.root.classList.add("squeezed");
      c.root.classList.toggle("oncam", !!a.camera);
      c.root.classList.toggle("main", a.camera === "main");
      c.root.classList.toggle("dead", a.activity === "dead");
      c.root.classList.toggle("offline", a.activity === "offline");
      c.root.classList.toggle("resting", a.activity === "resting");
      setText(c.badge, a.camera ? SLOT_LABEL[a.camera] || a.camera : "");
    });
    for (const [name, c] of cards) if (!keep.has(name)) { c.root.remove(); cards.delete(name); }

    if (!researchCard) {
      researchCard = { root: el("div", "card panel research") };
      const top = el("div", "top");
      researchCard.tech = el("div", "tech");
      researchCard.pct = el("div", "pct");
      top.append(el("span", "rlabel", "Research"), researchCard.tech, researchCard.pct);
      const bar = el("div", "bar");
      researchCard.fill = el("i");
      bar.append(researchCard.fill);
      researchCard.recent = el("div", "recent");
      researchCard.root.append(el("div", "panel-title", "Research"), top, bar, researchCard.recent);
      box.appendChild(researchCard.root);
    }
    researchCard.root.style.order = 999;
    researchCard.root.style.gridColumn = agents.length % 2 === 0 ? "1 / span 2" : "";
    const r = s.research || {};
    setText(researchCard.tech, r.label || "No research queued");
    setText(researchCard.pct, r.progress != null ? Math.floor(r.progress * 100) + "%" : r.done_count ? r.done_count + " done" : "");
    researchCard.fill.style.width = (r.progress != null ? Math.max(0, Math.min(1, r.progress)) * 100 : 0) + "%";
    const rec = (r.recent || []).slice(0, 3).map((x) => x.label);
    researchCard.recent.textContent = "";
    researchCard.recent.append(el("b", "", (r.done_count || 0) + " done"));
    if (rec.length) researchCard.recent.append(document.createTextNode(" · latest " + rec.join(", ")));
  }

  function sparkPath(series, w, h) {
    if (!series || series.length < 2) return null;
    const max = Math.max(...series, 1e-6);
    const step = w / (series.length - 1);
    const pts = series.map((v, i) => [i * step, h - 2 - (v / max) * (h - 5)]);
    const line = pts.map((p, i) => (i ? "L" : "M") + p[0].toFixed(1) + " " + p[1].toFixed(1)).join(" ");
    return { line, area: line + ` L ${w} ${h} L 0 ${h} Z` };
  }
  const fmtRate = (v) => (v == null ? "–" : v === 0 ? "0" : v >= 1000 ? (v / 1000).toFixed(1) + "k" : v >= 100 ? Math.round(v) : v >= 10 ? v.toFixed(0) : v.toFixed(1));
  // production: science per minute as players say it (SPM: research units a minute, the labs' use of packs in sets;
  // operator 15:51) as the headline, the labs' use of each pack beside it (a pack the running research takes and the
  // labs did not use, dimmed), packs made on a line under it; then four item cells. The model ranks items by the
  // stage the factory has reached; the top two stay put and the other two cells page through the rest.
  function renderProduction(s) {
    const sci = s.science || {};
    const spm = $("spm");
    const has = sci.spm != null;
    setText(spm, has ? fmtRate(sci.spm) : "none yet");
    const made = (sci.made || {}).per_min;
    setText($("sci-sub"), [has ? "research units/min" : "", made != null ? "made " + fmtRate(made) + "/min, all colours" : ""]
      .filter(Boolean).join(" · "));
    spm.classList.toggle("none", !has);
    spm.nextElementSibling.style.display = has ? "" : "none";
    const sp = sparkPath(sci.series, 120, 26);
    const spark = $("spm-spark");
    spark.style.display = sp ? "" : "none";
    if (sp) { spark.querySelector(".l").setAttribute("d", sp.line); spark.querySelector(".a").setAttribute("d", sp.area); }
    const packs = $("packs");
    const psig = (sci.packs || []).map((p) => p.item + ":" + fmtRate(p.rate)).join(",");
    if (packs.dataset.sig !== psig) {
      packs.dataset.sig = psig;
      packs.textContent = "";
      for (const p of sci.packs || []) {
        const [plabel, color] = itemInfo(p.item);
        const chip = el("span", "pack" + (p.running && !p.rate ? " idle" : ""));
        chip.title = (SHORT_PACK[p.item] || plabel) + ": used by the labs, per minute";
        let swatch = itemIcon(p.item, 16);
        if (!swatch) { swatch = el("i"); swatch.style.setProperty("--c", color); }
        chip.append(swatch, document.createTextNode(fmtRate(p.rate)));
        packs.append(chip);
      }
    }
    setText($("stage-label"), sci.stage_label ? sci.stage_label + " stage" : "");
    $("sci").classList.toggle("many", (sci.packs || []).length >= 5); // five or more pack chips: drop spark + stage

    const all = s.production || [];
    let items = all;
    if (all.length > PROD_CELLS) {
      const rest = all.slice(PROD_PINNED);
      const per = PROD_CELLS - PROD_PINNED;
      const pages = Math.ceil(rest.length / per);
      const page = Math.floor((s.now || 0) / PROD_ROTATE_S) % pages;
      items = all.slice(0, PROD_PINNED).concat(rest.slice(page * per, page * per + per));
    }
    renderSparks(items);
  }
  // item labels, colours and 16x16 pixel icons from eng/art's items.js (docs/ART-NOTES.md "Item icons"); the
  // ITEM table is the fallback when items.js is missing
  function itemInfo(name) {
    const P = window.PogItems;
    if (P) { try { return [P.label(name), P.color(name)]; } catch (err) { console.error(err); } }
    return ITEM[name] || [humanItem(name), "#cccccc"];
  }
  function itemIcon(name, size) {
    const P = window.PogItems;
    if (!P) return null;
    const box = el("span", "item-icon");
    try { box.innerHTML = P.svg(name, size); } catch (err) { console.error(err); return null; }
    return box;
  }
  function renderSparks(items) {
    const box = $("sparks");
    const sig = items.map((x) => x.item).join(",");
    if (box.dataset.sig !== sig) {
      box.dataset.sig = sig;
      box.textContent = "";
      if (!items.length) box.appendChild(el("div", "empty", "Waiting for the first plates…"));
      for (const it of items) {
        const [label, color] = itemInfo(it.item);
        const cell = el("div", "spark");
        cell.dataset.item = it.item;
        const icon = itemIcon(it.item, 32);
        if (icon) cell.append(icon);
        const lbl = el("div", "lbl");
        lbl.append(el("span", "", label), el("span", "val"));
        const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
        svg.setAttribute("viewBox", "0 0 140 14");
        svg.setAttribute("preserveAspectRatio", "none");
        svg.innerHTML = `<defs><linearGradient id="g-${it.item}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${color}" stop-opacity="0.35"/><stop offset="1" stop-color="${color}" stop-opacity="0"/></linearGradient></defs>` +
          `<path class="a" fill="url(#g-${it.item})"/><path class="l" fill="none" stroke="${color}" stroke-width="1.8" stroke-linejoin="round" vector-effect="non-scaling-stroke"/>`;
        const main = el("div", "main");
        main.append(lbl, svg);
        cell.append(main);
        box.appendChild(cell);
      }
    }
    for (const it of items) {
      const cell = box.querySelector(`[data-item="${it.item}"]`);
      if (!cell) continue;
      setText(cell.querySelector(".val"), fmtRate(it.rate));
      const p = sparkPath(it.series, 140, 14);
      if (p) {
        cell.querySelector("path.l").setAttribute("d", p.line);
        cell.querySelector("path.a").setAttribute("d", p.area);
      }
    }
  }

  function agentFor(s, m) {
    return (m.agent && s.agents.find((a) => a.name === m.agent)) || null;
  }
  function ago(sec) {
    sec = Math.max(0, Math.round(sec));
    if (sec < 10) return "now";
    if (sec < 60) return sec + "s ago";
    if (sec < 3600) return Math.floor(sec / 60) + "m ago";
    return Math.floor(sec / 3600) + "h ago";
  }
  const gameTime = (tick) => { const m = Math.floor(tick / 3600); return Math.floor(m / 60) + "h" + String(m % 60).padStart(2, "0"); };
  const shown = new Map();
  // viewer messages (viewers.py via serve.py) that passed the filters, while recent: in the main feed, marked as
  // viewers, scrolling away with the rest (shake7: Nick's line stayed up in a lane of its own)
  const VIEWER_RECENT_S = 300;
  // Pinned viewer lines and Q&A pairs (#chat-pins, above the feed), newest first. Viewers' words: textContent only.
  const pinned = new Map();
  // the operator's own line (game chat from `server`, model lane "operator"): an OP badge where agents have an avatar
  function operatorRow(m) {
    const row = el("div", "msg operator");
    const content = el("div", "content");
    const meta = el("div", "meta");
    row._from = el("span", "from", "Operator");
    row._when = el("span", "when");
    meta.append(row._from, el("span", "tag otag", "operator"), row._when);
    row._text = el("div", "text", clean(m.text));
    content.append(meta, row._text);
    row.append(el("div", "obadge", "OP"), content);
    return row;
  }
  // what became of a viewer's line in the game (static/chatfeed.js deliveryLabel): "→ Astra", "not sent: too soon"
  function showDelivery(span, v, s) {
    if (!span || !window.pogChat || !window.pogChat.deliveryLabel) return;
    const d = window.pogChat.deliveryLabel(v, s.agents);
    setText(span, d);
    span.className = "dlv" + (d.startsWith("not sent") ? " no" : "");
  }
  function renderPins(s, pins) {
    const box = $("chat-pins");
    if (!box) return;
    const keys = new Set();
    let prev = null;
    for (const p of pins) {
      keys.add(p.key);
      const sig = p.keys.join("|"); // a second answer to the same question rebuilds its pin
      let node = pinned.get(p.key);
      if (node && node._sig !== sig) { node.remove(); node = null; }
      if (!node) {
        node = el("div", "pin " + p.kind);
        node._sig = sig;
        if (p.kind === "operator") {
          node.append(operatorRow(p.m));
        } else {
          const q = el("div", "msg viewer q");
          const qc = el("div", "content");
          const qm = el("div", "meta");
          node._dlv = el("span", "dlv");
          qm.append(el("span", "from" + (p.v.staff ? " staff" : ""), p.v.name || "viewer"),
            el("span", "tag vtag", p.kind === "qa" ? "viewer asked" : "viewer"), node._dlv);
          qc.append(qm, el("div", "text", p.v.text || ""));
          q.append(el("div", "vbadge" + (p.v.source === "site" ? " site" : ""), p.v.source === "site" ? "SITE" : "YT"), qc);
          node.append(q);
        }
        for (const m of p.answers || []) {
          const ag = agentFor(s, m);
          const a = el("div", "msg answer");
          const av = avatar(ag || { name: m.from || "?", display_name: m.from || "?", color: "#5a4a2e", glyph: "?" }, "sm");
          const ac = el("div", "content");
          const am = el("div", "meta");
          am.append(el("span", "from", ag ? ag.display_name : m.from), el("span", "tag atag", "answers"));
          ac.append(am, el("div", "text", clean(m.text)));
          a.append(av, ac);
          if (ag) applyPalette(a, ag);
          node.append(a);
        }
        pinned.set(p.key, node);
      }
      if (p.v) showDelivery(node._dlv, p.v, s);
      if (prev ? prev.nextElementSibling !== node : box.firstElementChild !== node) {
        if (prev) prev.after(node); else box.prepend(node);
      }
      prev = node;
    }
    for (const [k, n] of pinned) if (!keys.has(k)) { n.remove(); pinned.delete(k); }
  }
  function renderChat(s) {
    const list = $("chat-list");
    const all = s.chat || [];
    // one feed by time: conversation and confessionals (model.chat_lane "talk"), harness notices (lane "notice":
    // votes and their results, humans joining; votes.lua, players.lua), tells (the team's main channel: direct lines
    // "Sol → Astra", a burst between the same two folded into one, static/chatfeed.js) and viewers (a line relayed
    // into the game shows once, from s.viewers; its game-chat copy, lane "viewer", is skipped).
    // Logistics chat and server lines (lane "log") are not shown: the ticker that held them is gone (Nick: "I can
    // barely see any of it"; the tells it mostly carried are here now).
    // a viewer's line and an agent's answer to it are pinned above the feed for 25 s (static/chatfeed.js viewerPins)
    // and leave the feed meanwhile; tells and talk scroll below them
    const pins = window.pogChat && window.pogChat.viewerPins ? window.pogChat.viewerPins(s) : [];
    const pinnedKeys = new Set(pins.flatMap((p) => p.keys || []));
    renderPins(s, pins);
    const talk = all.filter((m) => !m.tell && ((m.lane || "talk") === "talk" || m.lane === "notice" || m.lane === "operator")).slice(-10)
      .map((m) => ({ m, t: m.t || s.now, key: String(m.seq ?? m.tick + m.from + m.text) }))
      .filter((it) => !pinnedKeys.has(it.key));
    const tells = (window.pogChat ? window.pogChat.foldTells(all.filter((m) => m.tell)) : []).slice(-6)
      .map((g) => ({ g, t: g.t || s.now, key: g.key }));
    const viewers = (s.viewers || []).filter((v) => s.now - (v.t || 0) < VIEWER_RECENT_S).slice(-4)
      .map((v) => ({ v, t: v.t || s.now, key: "v:" + String(v.id || v.seq) }))
      .filter((it) => !pinnedKeys.has(it.key));
    const msgs = talk.concat(tells, viewers).sort((a, b) => a.t - b.t).slice(-10); // the well clips the oldest
    const keys = new Set();
    let prev = null;
    for (const it of msgs) {
      const key = it.key, m = it.m, v = it.v, g = it.g;
      keys.add(key);
      let node = shown.get(key);
      const ag = m && agentFor(s, m);
      if (g) {
        const from = agentFor(s, { agent: g.agent, from: g.from });
        const to = s.agents.find((a) => a.display_name === g.to || a.name === g.to);
        if (!node) {
          node = el("div", "msg tell");
          node._av = avatar(from || { name: g.from || "?", display_name: g.from || "?", color: "#5a4a2e", glyph: "?" }, "xs");
          const content = el("div", "content");
          const meta = el("div", "meta");
          node._from = el("span", "from");
          node._to = el("span", "to");
          node._count = el("span", "tcount");
          node._when = el("span", "when");
          meta.append(node._from, el("span", "arrow", "→"), node._to, node._count, node._when);
          node._text = el("div", "text");
          content.append(meta, node._text);
          node.append(node._av, content);
          shown.set(key, node);
        }
        if (from) { applyPalette(node._from, from); fillAvatar(node._av, from, "xs"); }
        if (to) applyPalette(node._to, to);
        setText(node._from, from ? from.display_name : g.from);
        setText(node._to, g.to);
        setText(node._count, g.count > 1 ? "+" + (g.count - 1) : "");
        setText(node._text, clean(g.body)); // the latest of a burst, in full
      } else if (!node && v) {
        // names and text are viewers' own words: textContent only (el() never parses HTML)
        node = el("div", "msg viewer");
        const content = el("div", "content");
        const meta = el("div", "meta");
        node._from = el("span", "from" + (v.staff ? " staff" : ""), v.name || "viewer");
        node._when = el("span", "when");
        node._dlv = el("span", "dlv");  // delivery: "→ Astra", "→ team", "not sent: too soon" (updated every render)
        meta.append(node._from, el("span", "tag vtag", "viewer"), node._dlv, node._when);
        content.append(meta, el("div", "text", v.text || ""));
        node.append(el("div", "vbadge" + (v.source === "site" ? " site" : ""), v.source === "site" ? "SITE" : "YT"), content);
        shown.set(key, node);
      } else if (!node && m.lane === "operator") {
        node = operatorRow(m);
        shown.set(key, node);
      } else if (!node) {
        node = el("div", "msg" + (ag ? "" : " server") + (m.aloud ? " aloud" : "") + (m.confess ? " confess" : ""));
        node._av = avatar(ag || { name: m.from || "server", display_name: m.from || "server", color: "#5a4a2e", glyph: "⚙", tool: true }, "sm");
        const content = el("div", "content");
        const meta = el("div", "meta");
        node._from = el("span", "from");
        node._when = el("span", "when");
        meta.append(node._from);
        if (m.confess) meta.append(el("span", "tag", "to camera"));
        meta.append(node._when);
        node._text = el("div", "text", clean(m.text));
        content.append(meta, node._text);
        node.append(node._av, content);
        shown.set(key, node);
      }
      if (m && m.lane !== "operator") {
        if (ag) { applyPalette(node, ag); fillAvatar(node._av, ag, "sm"); }
        setText(node._from, ag ? ag.display_name : m.from);
      }
      if (v) showDelivery(node._dlv, v, s);
      // time order: a viewer line can land between two agent lines
      if (prev ? prev.nextElementSibling !== node : list.firstElementChild !== node) {
        if (prev) prev.after(node); else list.prepend(node);
      }
      prev = node;
      const age = s.now - it.t;
      const tick = m ? m.tick : g ? g.tick : null;
      setText(node._when, (tick != null ? gameTime(tick) + " · " : "") + ago(age));
      node.classList.toggle("old", age > 90 && age <= 240);
      node.classList.toggle("older", age > 240);
    }
    for (const [key, node] of shown) if (!keys.has(key)) { node.remove(); shown.delete(key); }
    let empty = list.querySelector(".empty");
    if (!msgs.length && !empty) {
      empty = el("div", "empty", s.errors && s.errors.chat ? "Chat unavailable (no connected reader)" : "No messages yet");
      list.appendChild(empty);
    } else if (msgs.length && empty) empty.remove();
  }

  // logistics ticker: the last two coordination lines, one line each
  const ticks = new Map();
  function renderTicker(s, lines) {
    const box = $("chat-ticker");
    const keys = new Set();
    for (const m of lines) {
      const key = String(m.seq ?? m.tick + m.from + m.text);
      keys.add(key);
      let n = ticks.get(key);
      const ag = agentFor(s, m);
      if (!n) {
        n = el("div", "tick");
        if (ag) { applyPalette(n, ag); n.append(avatar(ag, "xxs")); }
        n.append(el("span", "tfrom", ag ? ag.display_name : m.from || "server"), el("span", "ttext", clean(m.text)));
        n._when = el("span", "twhen");
        n.append(n._when);
        box.appendChild(n);
        ticks.set(key, n);
      }
      setText(n._when, ago(s.now - (m.t || s.now)));
    }
    for (const [key, n] of ticks) if (!keys.has(key)) { n.remove(); ticks.delete(key); }
  }

  // ---------- team board: recent events, open unowned requests, active claims, harness changelog ----------
  const boardNodes = new Map();
  function boardAvatar(s, name) {
    const ag = name && s.agents.find((a) => a.name === name);
    if (ag) return [ag, avatar(ag, "xxs")];
    return [null, el("span", "tool", "⚙")];
  }
  // A project's progress: a short bar and "3/7" (board kind project; model.projects_snapshot, a project event's own)
  function projProgress(done, total) {
    const box = el("span", "prog");
    if (total == null) return box;
    const bar = el("span", "bar"), i = el("i");
    i.style.width = (total ? Math.round(100 * done / total) : 0) + "%";
    bar.append(i);
    box.append(bar, el("span", "n", total ? done + "/" + total : "no steps"));
    return box;
  }
  function renderBoard(s) {
    const b = s.board || {};
    const panel = $("board");
    const on = !!b.available;
    if (panel.hidden === on) panel.hidden = !on;
    document.body.classList.toggle("has-board", on);
    if (!on) return;

    const stats = $("board-stats");
    const ssig = [b.open_unowned, b.in_progress, b.claims_total].join("|");
    if (stats.dataset.sig !== ssig) {
      stats.dataset.sig = ssig;
      stats.textContent = "";
      const stat = (n, one, many, cls) => {
        const e = el("span", cls || "");
        e.append(el("b", "", n), document.createTextNode(n === 1 ? one : many));
        return e;
      };
      stats.append(stat(b.open_unowned || 0, "open request", "open requests", "open" + (b.open_unowned ? " some" : "")),
        stat(b.in_progress || 0, "in progress", "in progress"), stat(b.claims_total || 0, "claim", "claims"));
    }

    const log = $("board-log");
    const cl = (b.changelog || []).filter((c) => s.now - (c.t || 0) < 600).slice(-1);
    // the team plan's goals (board_plan) take the top line while there are any
    const plan = b.plan && b.plan.goals ? b.plan : null;
    const rows = 3 - cl.length - (plan ? 1 : 0); // 160 px panel: three lines between the header and the claims row
    const events = (b.events || []).slice(-rows);
    const keys = new Set();
    for (const e of events) {
      const key = "e" + (e.seq ?? e.tick + ":" + e.id + ":" + e.verb);
      keys.add(key);
      let n = boardNodes.get(key);
      if (!n) {
        n = el("div", "bev");
        // a finished technology (research.lua) is an event with no agent behind it
        const [ag, av] = e.kind === "research" ? [null, el("span", "tool", "🔬")] : boardAvatar(s, e.agent);
        n._av = av;
        if (ag) applyPalette(n, ag);
        n._who = el("span", "who", ag ? ag.display_name : e.kind === "research" ? "Research" : e.by === "operator" ? "Operator" : e.by || "?");
        const verb = el("span", "verb " + e.verb, VERB[e.verb] || e.verb);
        n.append(av, n._who, verb);
        if (e.verb === "posted" && KIND[e.kind]) n.append(el("span", "kind", KIND[e.kind]));
        let title = clean(e.title);
        if (e.verb === "assigned" && e.owner) {
          const owner = s.agents.find((a) => a.name === e.owner_agent);
          title += " → " + (owner ? owner.display_name : e.owner);
        }
        n.append(el("span", "title", title));
        // a project's progress after this change (the event's own: rows are built once)
        if (e.kind === "project" && e.steps_total != null) n.append(projProgress(e.steps_done, e.steps_total));
        n._when = el("span", "when");
        n.append(n._when);
        log.appendChild(n);
        boardNodes.set(key, n);
      }
      const ag = e.agent && s.agents.find((a) => a.name === e.agent);
      if (ag) { applyPalette(n, ag); fillAvatar(n._av, ag, "xxs"); setText(n._who, ag.display_name); }
      const age = s.now - (e.t || s.now);
      setText(n._when, ago(age));
      n.classList.toggle("old", age > 300);
      n.style.order = 1;
    }
    for (const c of cl) {
      const key = "c" + c.t + c.text;
      keys.add(key);
      let n = boardNodes.get(key);
      if (!n) {
        n = el("div", "bev changelog");
        n.append(el("span", "tool", "🛠"), el("span", "ver", "Harness " + (c.version || "update")),
          el("span", "title", clean(c.text)));
        n._when = el("span", "when");
        n.append(n._when);
        log.appendChild(n);
        boardNodes.set(key, n);
      }
      setText(n._when, ago(s.now - (c.t || s.now)));
      n.style.order = 2; // the changelog line sits under the events, nearest the claims
    }
    if (plan) {
      const key = "p" + plan.goals;
      keys.add(key);
      let n = boardNodes.get(key);
      if (!n) {
        n = el("div", "bev plan");
        n.append(el("span", "tool", "📋"), el("span", "ver", "Plan"), el("span", "title", clean(plan.goals)));
        log.appendChild(n);
        boardNodes.set(key, n);
      }
      n.style.order = 0; // the plan sits above the events
    }
    for (const [key, n] of boardNodes) if (!keys.has(key)) { n.remove(); boardNodes.delete(key); }
    let empty = log.querySelector(".empty");
    if (!events.length && !cl.length && !plan && !empty) log.appendChild(el("div", "empty", "Nothing on the board yet"));
    else if ((events.length || cl.length || plan) && empty) empty.remove();

    // The bottom row: the claims, or the open projects with their progress; with both, they take turns (PROJ_S each)
    const box = $("board-claims");
    const claims = b.claims || [], projects = b.projects || [];
    const showProj = projects.length > 0 && (!claims.length || Math.floor(s.now / PROJ_S) % 2 === 0);
    const face = (c) => { const a = s.agents.find((x) => x.name === c.agent); return a ? a.color + a.glyph : ""; };
    const csig = showProj
      ? "p|" + projects.map((p) => p.id + (p.agent || p.owner || "") + p.title + p.done + "/" + p.total + face(p)).join("|") + "|" + b.projects_total
      : "c|" + claims.map((c) => c.id + (c.agent || c.owner) + c.title).join("|") + "|" + b.claims_total + "|" + claims.map(face).join("");
    if (box.dataset.sig !== csig) {
      box.dataset.sig = csig;
      box.textContent = "";
      if (showProj) {
        box.append(el("span", "lbl", projects.length === 1 ? "Project" : "Projects"));
        const shown = projects.slice(0, 2);
        for (const p of shown) {
          const chip = el("span", "claim proj");
          const [, av] = p.agent ? boardAvatar(s, p.agent) : [null, el("span", "tool", "🏗")];
          chip.append(av, el("span", "", clean(p.title)), projProgress(p.done, p.total));
          box.append(chip);
        }
        const more = (b.projects_total || projects.length) - shown.length;
        if (more > 0) box.append(el("span", "more", "+" + more));
      } else {
        box.append(el("span", "lbl", "Claims"));
        if (!claims.length) box.append(el("span", "more", "none yet"));
        const shown = claims.slice(0, 3);
        for (const c of shown) {
          const chip = el("span", "claim");
          const [, av] = boardAvatar(s, c.agent);
          chip.append(av, el("span", "", clean(c.title)));
          box.append(chip);
        }
        const more = (b.claims_total || claims.length) - shown.length;
        if (more > 0) box.append(el("span", "more", "+" + more));
      }
    }
  }

  const alertNodes = new Map();
  // "Research complete: X · unlocks A, B, C": a lower third on the main camera for a few seconds when a technology
  // finishes (model.py research_news; unlocks from research.lua's board event when the runtime has it)
  function renderResearchCard(s) {
    const box = $("research-card");
    if (!box || !window.pogSeg) return;
    const c = window.pogSeg.researchCard(s.research_news);
    if (!c) {
      if (!box.hidden && !box.classList.contains("out")) {
        box.classList.add("out");
        setTimeout(() => { box.hidden = true; box.classList.remove("out"); box.dataset.key = ""; }, 600);
      }
      return;
    }
    if (box.dataset.key !== c.key) {
      box.dataset.key = c.key;
      box.classList.remove("out");
      box.textContent = "";
      box._unlocks = el("div", "rc-unlocks");
      box.append(el("span", "rc-tag", "Research complete"), el("div", "rc-name", c.label), box._unlocks);
      box.hidden = false;
    }
    setText(box._unlocks, c.unlocks ? "Unlocks " + c.unlocks : ""); // may arrive a poll after the card
  }

  // One camera: what the on-air label or the inset already says is not repeated; identical lines (a loss re-reported,
  // two chunks of one attack) are one toast; the newest TOAST_MAX, each for TOAST_S seconds.
  function toasts(s) {
    const cams = s.cameras || {};
    const shown = new Set([cams.main && cams.main.attack, cams.inset && cams.inset.attack].filter(Boolean));
    const seen = new Map();
    for (const a of [...(s.alerts || [])].sort((x, y) => y.t - x.t)) {
      if (s.now && a.t && s.now - a.t > TOAST_S) continue;
      if (shown.has(a.text) || (a.kind === "research" && s.research_news)) continue;
      const key = a.kind + "|" + a.text;
      if (!seen.has(key)) seen.set(key, a);
    }
    return [...seen.values()].slice(0, TOAST_MAX).reverse();
  }

  function renderAlerts(s) {
    const box = $("alerts");
    const live = new Set();
    for (const a of onecam ? toasts(s) : s.alerts || []) {
      if (a.kind === "research" && s.research_news) continue; // the research card says it (renderResearchCard)
      live.add(a.id);
      if (alertNodes.has(a.id)) continue;
      const n = el("div", "alert " + a.kind);
      n.append(el("span", "ico", ALERT_ICON[a.kind] || "•"), el("span", "", a.text));
      box.appendChild(n);
      alertNodes.set(a.id, n);
    }
    for (const [id, n] of alertNodes) {
      if (live.has(id) || n.classList.contains("out")) continue;
      n.classList.add("out");
      setTimeout(() => { n.remove(); alertNodes.delete(id); }, 800);
    }
  }

  function renderCams(s) {
    for (const slot of ["main", "inset", "cam2", "cam3"]) {
      const frame = $("cam-" + slot);
      if (!frame) continue;
      const label = frame.querySelector(".cam-label");
      const cam = (s.cameras || {})[slot];
      if (slot === "inset") frame.classList.toggle("on", !!cam); // up only while the director has an inset
      const cloudKey = renderCloud(frame, cam && cam.map ? cam : null, s);
      const agents = cam ? cam.agents.map((n) => s.agents.find((a) => a.name === n)).filter(Boolean) : [];
      if (slot !== "main" && slot !== "inset" && !(onecam && curMode !== "trio")) renderFill(frame, s, !agents.length && !(cam && cam.attack));
      const sig = agents.map((a) => a.name + a.color + a.glyph + a.display_name).join("|") + "|" + (cam && cam.attack || "")
        + "|" + (cam && cam.work || "");
      const death = !!(cam && cam.attack && cam.alert === "death");
      label.classList.toggle("attack", !!(cam && cam.attack) && !death);
      label.classList.toggle("death", death);
      if (cam && cam.map) { // Factorio's own map of the whole base (onecam.py base map; cameras.lua map camera)
        // the cloud's key inside the label (in onecam the bar along the bottom: a key of its own overlapped it, 13:59)
        const msig = "map|" + cam.map + "|" + (cloudKey ? cloudKey.text + cloudKey.rgb : "");
        if (label.dataset.sig !== msig) {
          label.dataset.sig = msig;
          label.textContent = "";
          label.append(el("span", "ico", "🗺️"), el("span", "", cam.map));
          if (cloudKey) {
            const key = el("span", "cloud-key"), sw = el("i", "sw");
            sw.style.background = `linear-gradient(90deg, rgba(${cloudKey.rgb}, 0.45), rgba(${cloudKey.rgb}, 0.85))`;
            sw.style.borderColor = `rgb(${cloudKey.bright})`;
            key.append(sw, el("span", "", cloudKey.text));
            label.append(key);
          }
        }
        label.classList.remove("attack", "death");
        frame.style.borderColor = "";
        frame.style.removeProperty("--bracket");
        label.classList.add("on");
        continue;
      }
      if (cam && cam.platform && !agents.length) { // a space platform: a visit or a departure (onecam.py)
        const psig = "plat|" + cam.platform.label;
        if (label.dataset.sig !== psig) {
          label.dataset.sig = psig;
          label.textContent = "";
          label.append(el("span", "ico", cam.platform.why === "departure" ? "🚀" : "🛰️"), el("span", "", cam.platform.label));
        }
        label.classList.remove("attack", "death");
        frame.style.borderColor = "";
        frame.style.removeProperty("--bracket");
        label.classList.add("on");
        continue;
      }
      if (cam && (cam.battle || cam.incoming || cam.enemy) && !cam.attack && !agents.length) { // a key battle's area,
        // an enemy group on its way, or a big enemy coming (the inset; onecam.py), no agent in it
        const text = cam.battle || cam.incoming || cam.enemy;
        if (label.dataset.sig !== "battle|" + text) {
          label.dataset.sig = "battle|" + text;
          label.textContent = "";
          label.append(el("span", "ico", cam.battle ? "⚔️" : "⚠️"), el("span", "", text));
        }
        frame.style.borderColor = "rgba(224,78,58,0.75)";
        frame.style.setProperty("--bracket", "rgba(224,78,58,0.9)");
        label.classList.remove("death");
        label.classList.add("on", "attack");
        continue;
      }
      if (cam && cam.attack && !agents.length) { // a base attack nobody is near, or where an agent fell
        if (label.dataset.sig !== sig) {
          label.dataset.sig = sig;
          label.textContent = "";
          label.append(el("span", "ico", death ? "💀" : ALERT_ICON[cam.alert] || "⚔️"), el("span", "", cam.attack));
        }
        frame.style.borderColor = "rgba(224,78,58,0.75)";
        frame.style.setProperty("--bracket", "rgba(224,78,58,0.9)");
        label.classList.add("on");
        continue;
      }
      if (!agents.length) { label.classList.remove("on"); frame.style.borderColor = ""; frame.style.removeProperty("--bracket"); continue; }
      if (label.dataset.sig !== sig) {
        label.dataset.sig = sig;
        label.textContent = "";
        // (a platform work shot shows the platform, not the character: "Astra · working on Starling")
        if (onecam && slot === "main" && !cam.work) label.append(el("span", "following", "Following"));
        // the inset on where the agent on air is looking or working (onecam.py attention): its kind as an icon
        if (cam.attention) label.append(el("span", "ico", ATTENTION_ICON[cam.attention.kind] || "👁️"));
        label.append(...agents.flatMap((a, i) => {
          const who = el("span", "who");
          applyPalette(who, a);
          who.append(avatar(a, slot === "main" ? "sm" : "xs"), el("span", "", a.display_name));
          return i ? [el("span", "amp", "&"), who] : [who];
        }));
        label._doing = el("span", "doing");
        label.append(label._doing);
      }
      const lead = agents[0];
      // a work shot (director work_target): the camera shows the agent's work, not its body: "Sol · building on
      // Solstice (from the ground)"
      const work = cam.work && (cam.work.startsWith(lead.display_name + " ") ? cam.work.slice(lead.display_name.length + 1) : cam.work);
      const onair = s.onair && s.onair.agent === lead.name && s.onair.doing; // plan line, claim or action (onecam.py)
      const doing = cam.attack ? (cam.attack.startsWith(lead.display_name) ? "under attack" : "attack nearby")
        : work ? work
        : slot === "main" && onair ? clean(onair)
        : cam.doing ? clean(cam.doing) // a trio's small tile: its plan line, claim or action (serve.py)
        : agents.length > 1 ? "working together" : lead.activity === "acting" && lead.action ? humanItem(lead.action)
        : lead.activity === "thinking" ? "thinking" : "";
      setText(label._doing, doing ? "· " + doing : "");
      frame.style.borderColor = cam.attack ? "rgba(224,78,58,0.75)" : palette(lead).ink + "66";
      frame.style.setProperty("--bracket", cam.attack ? "rgba(224,78,58,0.9)" : palette(lead).ink + "b0");
      applyPalette(label, lead);
      label.classList.add("on");
    }
  }

  // Space Age panel (right column, above chat): planets reached, space-age science made, then a two-line card per
  // platform (model.platform_card): name, where or its route (bar, %), speed or paused/drifting, who is aboard or
  // working on it; hub health bar, guns armed of all, rounds in the turrets and ammo in the hub, repair packs, asteroid
  // hits a minute, cargo highlights. A lost platform shows for two minutes with its cause. Under fire first; two
  // cards on the 1080p frame, three on the vertical page. Hidden until there is something (model space.active).
  const PLAT_SHOW = () => (document.body.classList.contains("portrait") ? 3 : 2);
  function platLine2(p) {
    const line = el("div", "pl2");
    if (p.hub && p.hub.pct != null) {
      const hp = el("span", "pchip php" + (p.hub.pct < 35 ? " bad" : p.hub.pct < 70 ? " warn" : ""));
      const bar = el("span", "bar hpbar"), i = el("i");
      i.style.width = Math.max(0, Math.min(100, p.hub.pct)) + "%";
      bar.append(i);
      hp.append(el("span", "k", "hub"), bar, el("span", "v", p.hub.pct + "%"));
      line.append(hp);
    }
    if (p.guns) {
      const g = p.guns;
      line.append(el("span", "pchip" + (g.total && !g.armed ? " bad" : g.empty || g.low ? " warn" : ""),
        g.total ? "guns " + g.armed + "/" + g.total : "no guns"));
    }
    if (p.ammo) line.append(el("span", "pchip" + (!p.ammo.turrets && !p.ammo.hub ? " bad" : ""),
      "ammo " + fmtRate(p.ammo.turrets) + " · hub " + fmtRate(p.ammo.hub)));
    if (p.repair != null) line.append(el("span", "pchip" + (!p.repair && p.damaged ? " bad" : ""), "repair " + fmtRate(p.repair)));
    if (p.hits_per_min) line.append(el("span", "pchip hits", "hits " + p.hits_per_min + "/min"));
    for (const c of p.cargo || []) {
      const chip = el("span", "pchip cargo");
      chip.title = itemInfo(c.item)[0];
      let icon = itemIcon(c.item, 14);
      if (!icon) { icon = el("i"); icon.style.setProperty("--c", itemInfo(c.item)[1]); }
      chip.append(icon, document.createTextNode(fmtRate(c.count)));
      line.append(chip);
    }
    return line;
  }
  function platCard(p) {
    const card = el("div", "plat" + (p.hits_per_min ? " hit" : ""));
    const top = el("div", "pl1");
    top.append(el("span", "pname", p.name));
    if (p.route) {
      const bar = el("span", "bar pbar"), i = el("i");
      i.style.width = p.route.pct + "%";
      bar.append(i);
      top.append(el("span", "pwhere", p.where), bar, el("span", "ppct", p.route.pct + "%"));
    } else top.append(el("span", "pwhere", p.where));
    const speed = p.drifting ? "drifting back" : p.paused ? "paused" : p.speed_kms ? p.speed_kms + " km/s" : "";
    if (speed) top.append(el("span", "pspeed" + (p.drifting ? " warn" : ""), speed));
    const who = (p.aboard || []).map((n) => n).concat((p.working || []).map((n) => n + " (remote)"));
    if (who.length) top.append(el("span", "pwho", who.join(", ")));
    card.append(top);
    const l2 = platLine2(p);
    if (l2.children.length) card.append(l2);
    return card;
  }
  function renderSpace(s) {
    const sp = s.space || {};
    const box = $("space");
    if (!box) return;
    box.hidden = !sp.active;
    box.dataset.hot = sp.hot ? "1" : "";
    if (!sp.active) return;
    const sig = JSON.stringify([sp.planets, (sp.science || []).map((p) => [p.item, fmtRate(p.total)]), sp.rockets,
      sp.platforms || [], (sp.lost || []).map((x) => x.name), PLAT_SHOW()]);
    if (box.dataset.sig === sig) return;
    box.dataset.sig = sig;
    const planets = $("space-planets");
    planets.textContent = "";
    for (const name of sp.planets || []) planets.append(el("span", "planet p-" + name.toLowerCase().replace(/ /g, "-"), name));
    const sci = $("space-sci");
    sci.textContent = "";
    for (const p of sp.science || []) {
      const chip = el("span", "pack");
      chip.title = p.label;
      let swatch = itemIcon(p.item, 16);
      if (!swatch) { swatch = el("i"); swatch.style.setProperty("--c", itemInfo(p.item)[1]); }
      chip.append(swatch, document.createTextNode(fmtRate(p.total)));
      sci.append(chip);
    }
    if (!(sp.science || []).length && sp.rockets) sci.append(el("span", "rockets", sp.rockets + (sp.rockets > 1 ? " rockets" : " rocket")));
    const plats = $("space-plats");
    plats.textContent = "";
    const list = sp.platforms || [], lost = sp.lost || [], room = PLAT_SHOW();
    let shown = 0;
    for (const x of lost.slice(0, room)) { // a lost platform: briefly, with its cause
      const row = el("div", "plat lost");
      const top = el("div", "pl1");
      top.append(el("span", "pname", x.name), el("span", "plost", "LOST"),
        el("span", "pwhere", [x.cause, x.where].filter(Boolean).join(" · ")));
      row.append(top);
      plats.append(row);
      shown++;
    }
    for (const p of list.slice(0, Math.max(0, room - shown))) { plats.append(platCard(p)); shown++; }
    const more = list.length + lost.length - shown;
    if (more > 0) plats.append(el("div", "plat more", "+" + more + " more"));
    box.classList.toggle("noplats", !list.length && !lost.length);
  }

  // A side camera nobody is on (fewer agents than cameras, or the director paired them) would show an empty or stale
  // capture: after 4 s unused the hole gets an opaque desk card (the analyst's read, else research), gone on reuse.
  const PACE = { ahead: "ahead", "on pace": "onpace", behind: "behind" };
  // The pollution or spore cloud over a map shot (onecam.py cloud shot and base map; clouds.py): each charted chunk in
  // the pollutant's map colour, stronger where there is more, under a dark diagonal hatch, and the cloud's edge drawn
  // dark with a bright line of the same hue inside it (the first shot, 13:59: the game's olive was lost on Gleba's
  // yellow-green ground); the nests it reached ringed. The camera client renders 1080 px of height at the shot's zoom
  // (1 tile = 32 * zoom px) and the hole shows its centre, scaled to the hole's height. Returns the key for the
  // camera's label ({rgb, a, text}), or null.
  function renderCloud(frame, cam, s) {
    const view = cam && cam.map_view;
    const pos = view && view.position;
    const cloud = view && pos && (s.clouds || []).find((c) => c.surface === view.surface);
    let cv = frame.querySelector("canvas.cam-cloud");
    if (!cloud || !(cloud.cells || []).length || !(view.zoom > 0)) {
      if (cv) cv.classList.remove("on");
      return null;
    }
    if (!cv) {
      cv = document.createElement("canvas");
      cv.className = "cam-cloud";
      frame.insertBefore(cv, frame.firstChild);
    }
    const col = cloud.color || {}, rgbs = [col.r, col.g, col.b].map((v) => Math.round(255 * (v || 0)));
    const rgb = rgbs.join(", "), top = Math.max(1, ...rgbs);
    const bright = rgbs.map((v) => Math.round(v * 255 / top)).join(", "); // the hue at full strength: olive -> yellow
    const W = frame.clientWidth, H = frame.clientHeight;
    const sig = [W, H, pos.x, pos.y, view.zoom, cloud.tick, cloud.chunks, cloud.max].join("|");
    if (cv.dataset.sig !== sig) {
      cv.dataset.sig = sig;
      cv.width = W; cv.height = H;
      const ctx = cv.getContext("2d"), k = H / 1080 * 32 * view.zoom, side = 32 * k;
      const lmax = Math.log1p(cloud.max || 1);
      const at = new Set(cloud.cells.map(([cx, cy]) => cx + "," + cy));
      const px = (cx) => W / 2 + (cx * 32 - pos.x) * k, py = (cy) => H / 2 + (cy * 32 - pos.y) * k;
      const shown = cloud.cells.filter(([cx, cy]) => px(cx) <= W && py(cy) <= H && px(cx) + side >= 0 && py(cy) + side >= 0);
      ctx.clearRect(0, 0, W, H);
      for (const [cx, cy, amt] of shown) {
        ctx.fillStyle = `rgba(${rgb}, ${(0.45 + 0.4 * Math.log1p(amt) / lmax).toFixed(3)})`;
        ctx.fillRect(px(cx), py(cy), side + 0.5, side + 0.5); // a hair wider: no seams between neighbours
      }
      if (side >= 8) { // a dark diagonal hatch over the cells: the cloud reads as a layer on any ground
        ctx.save();
        ctx.beginPath();
        for (const [cx, cy] of shown) ctx.rect(px(cx), py(cy), side + 0.5, side + 0.5);
        ctx.clip();
        ctx.strokeStyle = "rgba(0, 0, 0, 0.35)"; ctx.lineWidth = 2;
        ctx.beginPath();
        for (let d = -H; d < W; d += 11) { ctx.moveTo(d, H); ctx.lineTo(d + H, 0); }
        ctx.stroke();
        ctx.restore();
      }
      // the edge: each side of a cell with no cell beyond it, dark and wide, then the bright hue on top
      ctx.beginPath();
      for (const [cx, cy] of shown) {
        const x = px(cx), y = py(cy);
        if (!at.has(cx + "," + (cy - 1))) { ctx.moveTo(x, y); ctx.lineTo(x + side, y); }
        if (!at.has(cx + "," + (cy + 1))) { ctx.moveTo(x, y + side); ctx.lineTo(x + side, y + side); }
        if (!at.has((cx - 1) + "," + cy)) { ctx.moveTo(x, y); ctx.lineTo(x, y + side); }
        if (!at.has((cx + 1) + "," + cy)) { ctx.moveTo(x + side, y); ctx.lineTo(x + side, y + side); }
      }
      ctx.lineCap = "square";
      ctx.strokeStyle = "rgba(0, 0, 0, 0.85)"; ctx.lineWidth = 5; ctx.stroke();
      ctx.strokeStyle = `rgb(${bright})`; ctx.lineWidth = 2; ctx.stroke();
      for (const n of cloud.reached || []) {
        const x = W / 2 + (n.x - pos.x) * k, y = H / 2 + (n.y - pos.y) * k;
        ctx.strokeStyle = "#000"; ctx.lineWidth = 2.5; ctx.beginPath(); ctx.arc(x, y, 9, 0, Math.PI * 2); ctx.stroke();
        ctx.strokeStyle = "#ff5a44"; ctx.lineWidth = 2; ctx.beginPath(); ctx.arc(x, y, 8, 0, Math.PI * 2); ctx.stroke();
      }
    }
    cv.classList.add("on");
    const name = cloud.pollutant === "spores" ? "spores" : "pollution";
    const n = (cloud.reached || []).length;
    return { rgb, bright, text: `up to ${fmtAmount(cloud.max)} ${name} per chunk · ${cloud.chunks} chunk${cloud.chunks === 1 ? "" : "s"}`
      + (n ? ` · ${n} nest${n === 1 ? "" : "s"} reached` : "") };
  }
  function fmtAmount(v) { return v >= 100 ? String(Math.round(v)) : String(Math.round(v * 10) / 10); }

  function renderFill(frame, s, unused) {
    let fill = frame.querySelector(".cam-fill");
    if (!fill) { fill = el("div", "cam-fill"); frame.prepend(fill); }
    const now = Date.now();
    if (!unused) { frame._idle = 0; fill.classList.remove("on"); frame.classList.remove("filled"); return; }
    frame._idle = frame._idle || now;
    if (now - frame._idle < 4000) return;
    const an = s.analyst, r = s.research || {}, sp = s.space;
    const lines = (an && (an.storylines || []).filter((x) => x && x.status !== "resolved" && x.title).slice(0, 3)) || [];
    const sig = JSON.stringify([an && an.headline, an && (an.judgement || {}).pace, lines.map((x) => [x.title, x.text]),
      r.label, Math.round((r.progress || 0) * 50), r.done_count, sp && sp.summary]);
    if (fill.dataset.sig !== sig) {
      fill.dataset.sig = sig;
      fill.textContent = "";
      const head = el("div", "fhead");
      if (an && an.headline) {
        head.append(el("span", "tag", "Analyst desk"));
        const pace = (an.judgement || {}).pace;
        if (PACE[pace]) head.append(el("span", "pace " + PACE[pace], pace));
        fill.append(head, el("div", "fbig", clean(an.headline)));
        for (const x of lines) {
          const row = el("div", "fline");
          row.append(el("span", "k", clean(x.title)), el("span", "v", clean(x.text || "")));
          fill.append(row);
        }
      } else {
        head.append(el("span", "tag", "Research"));
        fill.append(head, el("div", "fbig", r.label || "No research queued"));
        const bar = el("div", "bar fbar"), i = el("i");
        i.style.width = Math.round((r.progress || 0) * 100) + "%";
        bar.append(i);
        fill.append(bar);
        const recent = (r.recent || []).map((x) => x.label).slice(0, 3).join(", ");
        if (recent) { const row = el("div", "fline"); row.append(el("span", "k", "Latest"), el("span", "v", recent)); fill.append(row); }
      }
      if (sp && sp.summary) { const row = el("div", "fline space"); row.append(el("span", "k", "Space"), el("span", "v", sp.summary)); fill.append(row); }
    }
    fill.classList.add("on");
    frame.classList.add("filled");
  }

  // ---------- segments (tools/stream/segments.py): drawn from segment.facts only, so the casters match the screen ----------
  // Every segment is a card in the main camera's lower left, clear of its centre (Nick on shake7: the full panel over
  // the whole camera stayed far longer than it took to read). FULL stays for a type that ever needs the whole camera.
  const FULL = {};
  function factRow(label, value, cls) {
    const r = el("div", "srow" + (cls ? " " + cls : ""));
    r.append(el("span", "k", label), el("span", "v", value == null || value === "" ? "–" : String(value)));
    return r;
  }
  function segmentBody(seg) {
    const f = seg.facts || {};
    const body = el("div", "sbody");
    if (seg.type === "production") { // only the lines that moved (segments.py production_moves), at most three
      const t = el("div", "stable");
      t.append(el("div", "th", "Changed in 10 min"), el("div", "th num", "now /min"), el("div", "th num", ""));
      for (const it of f.items || []) {
        const icon = itemIcon(it.id || it.item.replace(/ /g, "-"), 28);
        const name = el("div", "td item");
        if (icon) name.append(icon);
        name.append(el("span", "", it.item));
        const pct = it.change_pct || 0;
        t.append(name, el("div", "td num", fmtRate(it.rate_now)),
          el("div", "td num" + (pct > 0 ? " up" : pct < 0 ? " down" : ""), (pct > 0 ? "+" : "") + pct + "%"));
      }
      body.append(t);
      if (f.science_per_min != null)
        body.append(el("div", "snote", fmtRate(f.science_per_min) + " SPM (research)" + (f.stage ? " · " + f.stage + " stage" : "")));
    } else if (seg.type === "research") {
      body.append(el("div", "shead big", f.current || "No research queued"));
      const bar = el("div", "bar sbar");
      const fill = el("i");
      fill.style.width = (f.progress_pct || 0) + "%";
      bar.append(fill);
      body.append(bar, factRow("Progress", f.progress_pct != null ? f.progress_pct + "%" : null),
        factRow("Technologies done", f.done_count), factRow("Latest", (f.recent || []).join(", ")));
    } else if (seg.type === "recap") {
      // only what happened (segments.py recap_news refuses an empty window)
      if ((f.research_done || []).length) body.append(factRow("Researched", f.research_done.join(", ")));
      if ((f.board_done || []).length) body.append(factRow("Done", f.board_done.join(", ")));
      if (f.attacks) body.append(factRow("Attacks", f.attacks));
      if ((f.deaths || []).length) body.append(factRow("Deaths", f.deaths.join(", ")));
    } else if (seg.type === "spotlight") {
      body.append(factRow(f.model || "model ?", f.motto ? "“" + clean(f.motto) + "”" : ""),
        factRow("Now", [humanItem(f.doing || ""), f.location].filter(Boolean).join(" · ")));
      if ((f.said || []).length) body.append(factRow("Said", "“" + clean(f.said[f.said.length - 1]) + "”", "said"));
      if ((f.claims || []).length) body.append(factRow("Claims", f.claims.join(", ")));
    } else if (seg.type === "attack_replay") { // shown on the stream page for the 2.5 s before the replay scene cuts in
      body.append(factRow("Coming up", f.event), factRow("Length", f.seconds != null ? f.seconds + " s" : null));
    } else if (seg.type === "space") {
      body.append(factRow("Planets reached", (f.planets || []).join(", ")), factRow("Rockets launched", f.rockets || 0));
      for (const p of f.platforms || [])
        body.append(factRow(p.name, [p.where, p.speed_kms ? p.speed_kms + " km/s" : "", p.paused ? "paused" : ""].filter(Boolean).join(" · ")));
      const sci = Object.entries(f.science || {}).map(([k, v]) => k + " " + fmtRate(v.total) + (v.per_min ? " (" + fmtRate(v.per_min) + "/min)" : ""));
      if (sci.length) body.append(factRow("Science made", sci.join(", ")));
      if ((f.away || []).length) body.append(factRow("Off Nauvis", f.away.join(", ")));
    } else if (seg.type === "space_moment") {
      if (f.moment === "first_rocket") body.append(factRow("Rockets launched", f.rockets));
      if (f.platform) body.append(factRow("Platform", f.platform));
      if (f.where) body.append(factRow("Where", f.where));
      if (f.planet) body.append(factRow("Planet", f.planet));
      if (f.agent) body.append(factRow("Who", f.agent));
      if (f.planets_reached) body.append(factRow("Planets reached", f.planets_reached));
      body.append(factRow("Game time", f.game_time));
    } else if (seg.type === "hauling") { // items moved by hand this shift, most first (segments.py build_hauling)
      const t = el("div", "stable");
      t.append(el("div", "th", "Hand hauling"), el("div", "th num", "items"), el("div", "th num", "calls"));
      const n = (v) => Number(v || 0).toLocaleString("en-US");
      for (const r of f.rows || [])
        t.append(el("div", "td", r.rank + ". " + r.agent), el("div", "td num", n(r.items)), el("div", "td num faint", n(r.calls)));
      body.append(t);
      if (f.minutes != null) body.append(el("div", "snote", "this shift · last " + f.minutes + " min"));
    } else if (seg.type === "efficiency") { // the team's machines this shift and one agent's (segments.py build_efficiency)
      const n = (v) => Number(v || 0).toLocaleString("en-US");
      body.append(factRow("Made by machines", n(f.team_items_this_shift) + " items"),
        factRow("Machines", n(f.machines) + " · " + n(f.machines_working) + " working"));
      if (f.moved_by_machines_pct != null) body.append(factRow("Moved by machines", f.moved_by_machines_pct + "% (rest by hand)"));
      if (f.agent_line) body.append(el("div", "snote", f.agent_line));
    } else if (seg.type === "tokens") { // tokens each agent's model read and wrote this shift (segments.py build_tokens)
      const t = el("div", "stable");
      t.append(el("div", "th", "Agent"), el("div", "th num", "tokens"), el("div", "th num", "cached"),
        el("div", "th num", "turns"), el("div", "th num", "per action"));
      for (const r of f.rows || [])
        t.append(el("div", "td", r.rank + ". " + r.agent), el("div", "td num", shortNum(r.tokens)),
          el("div", "td num faint", r.cached_pct + "%"), el("div", "td num faint", Number(r.turns || 0).toLocaleString("en-US")),
          el("div", "td num faint", r.per_action != null ? shortNum(r.per_action) : "–"));
      body.append(t);
      if (f.minutes != null) body.append(el("div", "snote", "this shift · last " + f.minutes + " min · team " + f.team_text));
    } else if (seg.type === "overview") {
      body.append(factRow("Agents in the world", f.agents_in_world + " of " + f.agents_total),
        factRow("Spread", "about " + f.spread_tiles + " tiles from the centre"),
        factRow("Areas", (f.locations || []).join(", ")));
    }
    return body;
  }
  const isFull = (seg) => !!FULL[seg.type];
  function hideSegment(box) {
    document.body.classList.remove("seg-full");
    if (box.hidden || box.classList.contains("out")) return;
    box.classList.add("out");
    setTimeout(() => { box.hidden = true; box.classList.remove("out"); box.dataset.sig = ""; box._t1 = 0; }, 700);
  }
  function renderSegment(s) {
    const box = $("segment");
    const seg = s.segment;
    const sv = window.pogSeg; // static/segview.js
    const show = sv ? sv.cardVisible(seg, s.now) && box._expired !== seg.id : !!seg && seg.state !== "ended";
    // a full panel shares the camera with at most the newest alert banner (overlay.css body.seg-full)
    document.body.classList.toggle("seg-full", show && isFull(seg));
    if (!show) return hideSegment(box);
    const sig = seg.id;
    if (box.dataset.sig !== sig) {
      box.dataset.sig = sig;
      box.classList.remove("out");
      box.className = (isFull(seg) ? "full" : "lower") + " seg-" + seg.type;
      box.textContent = "";
      const panel = el("div", "spanel");
      const title = el("div", "stitle");
      title.append(el("span", "tag", seg.type === "spotlight" ? "Spotlight" : seg.type === "overview" ? "Overview"
        : seg.type === "attack_replay" ? "Replay" : seg.type === "space" || seg.type === "space_moment" ? "Space Age"
        : seg.type === "hauling" || seg.type === "tokens" || seg.type === "efficiency" ? "Stats" : "Analysis"),
        el("span", "", seg.title));
      if (seg.type === "spotlight") {
        const ag = (s.agents || []).find((a) => a.name === (seg.facts || {}).name);
        if (ag) { applyPalette(title, ag); title.prepend(avatar(ag, "sm")); }
      }
      box._time = el("div", "stime");
      box._time.append(el("i"));
      panel.append(title, segmentBody(seg), box._time);
      box.append(panel);
      box.hidden = false;
      box._t0 = seg.started * 1000 + Date.now() - s.now * 1000; // local ms
    }
    // The time bar and the card's end run on this page's clock (segTick), so the bar moves between snapshots and the
    // card goes on time even if snapshots stop. A replay's card counts down to the cut to the replay scene.
    box._id = seg.id;
    box._t1 = (sv ? sv.cardUntil(seg) : seg.ends) * 1000 + Date.now() - s.now * 1000;
    segTick();
  }
  function segTick() {
    const box = $("segment");
    if (!box || box.hidden || box.classList.contains("out") || !box._t1) return;
    const now = Date.now();
    if (now > box._t1 + (window.pogSeg ? window.pogSeg.GRACE_S : 1.5) * 1000) {
      box._expired = box._id; // a late snapshot of this segment does not bring the card back
      return hideSegment(box);
    }
    box._time.firstChild.style.width = Math.max(0, Math.min(1, (box._t1 - now) / Math.max(1000, box._t1 - box._t0))) * 100 + "%";
  }
  setInterval(segTick, 250);

  // The service's page files changed since this page loaded (serve.py static_version): load the new page. An OBS
  // browser source keeps its page until refreshed; after eng/onecam the vertical canvas kept the three-camera page.
  let pageVersion = null;
  function staleCheck(s) {
    if (!s.static_version) return false;
    if (!pageVersion) pageVersion = s.static_version;
    if (pageVersion === s.static_version) return false;
    location.reload();
    return true;
  }

  // ---------- loadout strips (Nick, 08:55: guns and ammo in combat, armor, building progress, what they carry) ----------
  // The agent on the main camera and the one in the inset get one strip each, inside the camera frame, in the mode
  // model.py picked (tools/stream/loadout.py: combat | building | carrying); none when there is none. Main's strip
  // gives way to a segment card (both sit lower left).
  const LOADOUT_HEAD = { combat: "Combat", building: "Building", carrying: "Carrying" };
  function loIcon(name, size) {
    const i = itemIcon(name, size);
    if (i) return i;
    const sw = el("i", "lo-swatch");
    sw.style.background = itemInfo(name)[1];
    return sw;
  }
  function loBar(label, now, max, cls) {
    const row = el("div", "lo-bar " + cls);
    const bar = el("span", "bar");
    const fill = el("i");
    fill.style.width = Math.max(0, Math.min(100, max ? (100 * now) / max : 0)) + "%";
    bar.append(fill);
    row.append(el("span", "lo-k", label), bar, el("span", "lo-v", Math.round(now) + "/" + Math.round(max)));
    return row;
  }
  function loEquipment(L, small) {
    const eq = (L.armor && L.armor.equipment) || [];
    if (!eq.length) return null;
    const row = el("div", "lo-equip");
    for (const e of eq.slice(0, small ? 4 : 6)) {
      const it = el("span", "lo-eq");
      it.append(loIcon(e.name, small ? 16 : 20), el("span", "", (e.count > 1 ? e.count + "× " : "") + humanItem(e.name.replace(/-equipment$/, ""))));
      row.append(it);
    }
    return row;
  }
  function loadoutBody(L, small) {
    const box = el("div", "lo-body");
    if (L.mode === "combat") {
      const guns = L.guns || [];
      for (const [i, g] of guns.entries()) {
        if (small && i > 0) break;
        const row = el("div", "lo-gun" + (i ? " lo-other" : ""));
        row.append(loIcon(g.name, i ? 20 : small ? 24 : 36), el("span", "lo-name", humanItem(g.name)));
        if (g.ammo) row.append(loIcon(g.ammo, i ? 16 : small ? 20 : 28), el("b", "lo-count", String(g.count)));
        else row.append(el("span", "lo-empty", "no ammo"));
        box.append(row);
      }
      if (!guns.length) box.append(el("div", "lo-empty", "no gun"));
      const sh = L.armor && L.armor.shield;
      if (sh) box.append(loBar("shield", sh.now, sh.max, "shield"));
      if (L.health && L.health.max) box.append(loBar("health", L.health.now, L.health.max, "health"));
    } else if (L.mode === "building") {
      const c = L.crafting;
      if (c && c.queue && c.queue.length) {
        const head = c.queue[0];
        const row = el("div", "lo-craft");
        row.append(loIcon(head.recipe, small ? 20 : 28), el("span", "lo-name", humanItem(head.recipe) + " ×" + head.count));
        const bar = el("span", "bar");
        const fill = el("i");
        fill.style.width = Math.round((c.progress || 0) * 100) + "%";
        bar.append(fill);
        row.append(bar);
        box.append(row);
        if (c.queue.length > 1) {
          const next = el("div", "lo-queue");
          for (const q of c.queue.slice(1, small ? 3 : 6)) {
            const it = el("span", "lo-q");
            it.append(loIcon(q.recipe, 16), el("span", "", "×" + q.count));
            next.append(it);
          }
          box.append(next);
        }
      }
      const b = L.building;
      if (b) {
        const what = { construct: "construct", build_path: "build path", place_ghosts: "ghosts" }[b.kind] || b.kind.replace(/_/g, " ");
        box.append(el("div", "lo-build", b.total != null ? what + " " + b.done + " of " + b.total : what));
      }
    } else if (L.mode === "carrying") {
      const row = el("div", "lo-items");
      for (const it of (L.items || []).slice(0, small ? 4 : 6)) {
        const cell = el("span", "lo-item");
        cell.append(loIcon(it.name, small ? 20 : 28), el("b", "", fmtCount(it.count)));
        cell.title = humanItem(it.name);
        row.append(cell);
      }
      box.append(row);
    }
    if (L.mode !== "building") {
      const eq = loEquipment(L, small);
      if (eq) box.append(eq);
    }
    return box;
  }
  function fmtCount(n) { return n >= 10000 ? Math.round(n / 1000) + "k" : n >= 1000 ? (n / 1000).toFixed(1) + "k" : String(n); }
  function renderLoadouts(s) {
    const byName = new Map((s.agents || []).map((a) => [a.name, a]));
    const seg = $("segment");
    for (const slot of ["main", "inset"]) {
      const frame = $("cam-" + slot);
      if (!frame) continue;
      let strip = frame.querySelector(".loadout");
      const cam = (s.cameras || {})[slot] || {};
      const who = (cam.agents || [])[0];
      const L = who && byName.get(who) ? byName.get(who).loadout : null;
      const hidden = !L || (slot === "inset" && !frame.classList.contains("on")) || (slot === "main" && seg && !seg.hidden);
      if (hidden) { if (strip) strip.hidden = true; continue; }
      if (!strip) { strip = el("div", "loadout"); frame.append(strip); }
      const { age_s, ...shown } = L;
      const sig = JSON.stringify(shown);
      if (strip.dataset.sig !== sig) {
        strip.dataset.sig = sig;
        strip.textContent = "";
        strip.className = "loadout panel lo-" + slot + " lo-" + L.mode;
        const head = el("div", "lo-head");
        head.append(el("span", "lo-mode", LOADOUT_HEAD[L.mode] || L.mode));
        if (L.why && L.mode === "combat") head.append(el("span", "lo-why", L.why));
        if (L.armor && L.armor.name && L.mode !== "building") head.append(el("span", "lo-armor", humanItem(L.armor.name)));
        strip.append(head, loadoutBody(L, slot === "inset"));
      }
      strip.hidden = false;
    }
    loadoutClear();
  }
  // Chat first (viewer Enginerd, 10:59: "the combat info box often overlays the chat messages, I think the chat
  // messages are more important"): a strip whose box meets a caption on screen (audio.js #voice) or the chat panel
  // steps aside until it no longer does. Checked on each render and whenever the captions change.
  function overlaps(a, b) { return a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom; }
  function loadoutClear() {
    const strips = document.querySelectorAll(".loadout:not([hidden])");
    if (!strips.length) return;
    const boxes = [];
    for (const c of document.querySelectorAll("#voice .cap.on")) boxes.push(c.getBoundingClientRect());
    for (const id of ["chat", "chat-pins", "chat-ticker"]) {
      const e = $(id);
      if (e && e.offsetParent !== null) boxes.push(e.getBoundingClientRect());
    }
    for (const s of strips) {
      s.classList.remove("lo-yield");
      const r = s.getBoundingClientRect();
      if (r.width && boxes.some((b) => b.width && b.height && overlaps(r, b))) s.classList.add("lo-yield");
    }
  }
  let loadoutWatched = false;
  function watchLoadoutClear() {
    const v = $("voice");
    if (loadoutWatched || !v || !window.MutationObserver) return;
    loadoutWatched = true;
    new MutationObserver(loadoutClear).observe(v, { childList: true, subtree: true, attributes: true, attributeFilter: ["class"] });
  }

  function render(s) {
    if (staleCheck(s)) return;
    state = s;
    const mode = onecam && trioCams && s.program && s.program.layout === "trio" ? "trio" : "onecam";
    if (layout && mode !== curMode) applyLayout(mode);
    window.pogState = s; // audio.js finds speaking agents' avatars here
    renderHead(s);
    renderCards(s);
    renderProduction(s);
    renderSpace(s);
    renderChat(s);
    renderBoard(s);
    renderAlerts(s);
    renderResearchCard(s);
    renderCams(s);
    renderSegment(s);
    renderLoadouts(s);
    rotateWidgets();
    watchVoice();
    watchLoadoutClear();
    watchAlerts();
  }

  // Widgets under the cards (science, team board, Space) take turns in one slot instead of stacking, so chat keeps
  // its room (Nick on shake7: once Space appeared there was barely room for chat). Only widgets with something to
  // show (not `hidden` by their own render) take part; each stays ROT_S seconds.
  const WIDGETS = ["prod", "board", "space"], ROT_S = 18;
  let rotCur = null, rotSince = 0;
  function rotateWidgets() {
    const now = Date.now() / 1000;
    const ids = document.body.classList.contains("portrait") ? ["prod", "space"] : WIDGETS; // portrait has no board
    const live = ids.filter((id) => $(id) && !$(id).hidden);
    if (!live.length) return;
    // a platform under fire or just lost: the Space widget holds the slot (model space.hot)
    const hot = live.includes("space") && $("space").dataset.hot === "1";
    if (hot ? rotCur !== "space" : !live.includes(rotCur) || now - rotSince >= ROT_S) {
      const next = hot ? "space" : live.length === 1 ? live[0] : live[(live.indexOf(rotCur) + 1) % live.length];
      if (next !== rotCur) {
        rotCur = next;
        const n = $(next);
        n.classList.remove("rot-in");
        void n.offsetWidth; // restart the fade-in
        n.classList.add("rot-in");
      }
      rotSince = now;
    }
    for (const id of WIDGETS) if ($(id)) $(id).classList.toggle("rot-off", id !== rotCur);
  }

  // Voice captions (audio.js #voice) grow up from the main camera's bottom edge. Their height goes to --voice-clear
  // (caption stack + gap, 0 without captions) so segment and replay cards keep clear of them (overlay.css).
  // Alert banners stack down from the main camera's top: a full panel starts below them (--alerts-clear).
  let alertsWatched = false;
  function watchAlerts() {
    const a = $("alerts"), seg = $("segment");
    if (alertsWatched || !a || !seg || !window.ResizeObserver) return;
    alertsWatched = true;
    new ResizeObserver(() => {
      const r = a.getBoundingClientRect(), top = parseFloat(getComputedStyle(seg).top) || 0; // valid while hidden too
      if (onecam) { // toasts sit above the bar: captions and lower cards rise above them
        document.body.style.setProperty("--toasts-clear", a.children.length && r.height > 1 ? Math.ceil(r.height + 10) + "px" : "0px");
        return;
      }
      const clear = a.children.length && r.height > 1 ? Math.ceil(r.bottom - top + 14) : 0;
      document.body.style.setProperty("--alerts-clear", clear + "px");
    }).observe(a);
  }
  let voiceWatched = false;
  function watchVoice() {
    const v = $("voice");
    if (voiceWatched || !v || !window.ResizeObserver) return;
    voiceWatched = true;
    new ResizeObserver(() => {
      const h = v.getBoundingClientRect().height;
      document.body.style.setProperty("--voice-clear", h > 1 ? Math.ceil(h + 30) + "px" : "0px");
    }).observe(v);
  }

  // ---------- feed: SSE with a polling fallback ----------
  let lastMsg = 0;
  function connect() {
    // One event stream per page, shared with audio.js (voice clips arrive on it as `audio` events): a browser keeps
    // 6 connections per host and each open stream holds one (shake7: all 6 held, the voice clips never loaded).
    const es = window.pogEvents || (window.pogEvents = new EventSource("/events?audio=1"));
    es.onmessage = (e) => { lastMsg = Date.now(); try { render(JSON.parse(e.data)); } catch (err) { console.error(err); } };
    es.onerror = () => { /* EventSource retries by itself */ };
  }
  connect();
  setInterval(() => {
    if (Date.now() - lastMsg < 6000) return;
    fetch("/state.json", { cache: "no-store" }).then((r) => r.json()).then((s) => { if (s && s.agents) render(s); }).catch(() => {});
  }, 3000);
})();
