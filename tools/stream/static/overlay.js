// Stream overlay: renders /events snapshots into a 1920x1080 transparent page (OBS browser source).
(() => {
  "use strict";
  const params = new URLSearchParams(location.search);
  if (params.has("preview")) document.body.classList.add("preview");

  const PANEL = [49, 48, 49]; // --fx-frame (factorio-ui.css)
  const DEEP = [36, 35, 36];
  const SLOT_LABEL = { main: "Main", cam2: "Cam 2", cam3: "Cam 3" };
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
  const ALERT_ICON = { attack: "⚔️", loss: "🔥", death: "💀", power: "⚡", research: "🔬", info: "ℹ️", space: "🚀" };
  // board event verbs as a viewer reads them ("Astra took: ...")
  const VERB = { posted: "posted", taken: "took", assigned: "assigned", released: "released", started: "started",
    done: "finished", blocked: "is blocked on", dropped: "dropped", reopened: "reopened" };
  const KIND = { request: "request", task: "task", claim: "claim", harness: "tool", note: "note" };

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
  // portrait.html sets data-layout="layout-portrait" for the 9:16 canvas
  fetch("/static/" + (document.body.dataset.layout || "layout") + ".json").then((r) => r.json()).then((l) => {
    layout = l;
    for (const [slot, [x, y, w, h]] of Object.entries(l.cams)) {
      const c = $("cam-" + slot);
      if (!c) continue;
      Object.assign(c.style, { left: x + "px", top: y + "px", width: w + "px", height: h + "px" });
    }
    const m = l.cams.main;
    if (m) Object.assign($("alerts").style, { left: m[0] + "px", width: m[2] + "px", top: m[1] + 64 + "px" });
    if (m) Object.assign($("segment").style, { left: m[0] + "px", top: m[1] + "px", width: m[2] + "px", height: m[3] + "px" });
  });

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
        r1.append(c.name, c.badge, c.world, c.harness);
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
      // motto from `profiles`; an agent that never called `profile` gets a quiet note instead
      const unset = a.profile_set === false;
      const motto = unset ? "profile not set" : a.motto ? "“" + clean(a.motto) + "”" : "";
      // line two: model, then the motto (or a quiet "profile not set"; the role when there is neither)
      const msig = [a.model, a.role, motto].join("|");
      if (c.model.dataset.sig !== msig) {
        c.model.dataset.sig = msig;
        c.model.textContent = "";
        c.model.append(el("b", "", a.model || "model ?"));
        if (motto) c.model.append(document.createTextNode(" · "), el(unset ? "span" : "i", unset ? "unset" : "", motto));
        else if (a.role) c.model.append(document.createTextNode(" · " + a.role));
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
      c.root.classList.toggle("oncam", !!a.camera);
      c.root.classList.toggle("main", a.camera === "main");
      c.root.classList.toggle("dead", a.activity === "dead");
      c.root.classList.toggle("offline", a.activity === "offline");
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
  // production: science per minute (all packs) as the headline, then four item cells. The model ranks items by the
  // stage the factory has reached; the top two stay put and the other two cells page through the rest.
  function renderProduction(s) {
    const sci = s.science || {};
    const spm = $("spm");
    const has = sci.spm != null;
    setText(spm, has ? fmtRate(sci.spm) : "none yet");
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
        const chip = el("span", "pack");
        chip.title = SHORT_PACK[p.item] || plabel;
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
  function renderChat(s) {
    const list = $("chat-list");
    const all = s.chat || [];
    // talk lane: conversation and confessionals (model.chat_lane); logistics go to the ticker, viewers to their lane
    const msgs = all.filter((m) => (m.lane || "talk") === "talk").slice(-10); // the well clips the oldest
    renderTicker(s, all.filter((m) => m.lane === "log").slice(-2));
    const keys = new Set();
    for (const m of msgs) {
      const key = String(m.seq ?? m.tick + m.from + m.text);
      keys.add(key);
      let node = shown.get(key);
      const ag = agentFor(s, m);
      if (!node) {
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
        list.appendChild(node);
        shown.set(key, node);
      }
      if (ag) { applyPalette(node, ag); fillAvatar(node._av, ag, "sm"); }
      setText(node._from, ag ? ag.display_name : m.from);
      const age = s.now - (m.t || s.now);
      setText(node._when, (m.tick != null ? gameTime(m.tick) + " · " : "") + ago(age));
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

  // viewers lane (viewers.py via serve.py): the last two messages that passed the filters, while recent
  const VIEWER_RECENT_S = 300;
  const vnodes = new Map();
  function renderViewers(s) {
    const lane = $("viewer-lane");
    const list = $("viewer-list");
    const msgs = (s.viewers || []).filter((v) => s.now - (v.t || 0) < VIEWER_RECENT_S).slice(-2);
    lane.hidden = !msgs.length;
    const keys = new Set();
    for (const v of msgs) {
      const key = String(v.id || v.seq);
      keys.add(key);
      if (vnodes.has(key)) continue;
      const n = el("div", "vmsg");
      // names and text are viewers' own words: textContent only (el() never parses HTML)
      n.append(el("span", "src" + (v.source === "site" ? " site" : ""), v.source === "site" ? "SITE" : "YT"),
        el("span", "vname" + (v.staff ? " staff" : ""), v.name || "viewer"), el("span", "vtext", v.text || ""));
      if (v.order) n.append(el("span", "order", "to the agents"));
      list.appendChild(n);
      vnodes.set(key, n);
    }
    for (const [key, n] of vnodes) if (!keys.has(key)) { n.remove(); vnodes.delete(key); }
  }

  // ---------- team board: recent events, open unowned requests, active claims, harness changelog ----------
  const boardNodes = new Map();
  function boardAvatar(s, name) {
    const ag = name && s.agents.find((a) => a.name === name);
    if (ag) return [ag, avatar(ag, "xxs")];
    return [null, el("span", "tool", "⚙")];
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
    const rows = 3 - cl.length; // 160 px panel: three lines between the header and the claims row
    const events = (b.events || []).slice(-rows);
    const keys = new Set();
    for (const e of events) {
      const key = "e" + (e.seq ?? e.tick + ":" + e.id + ":" + e.verb);
      keys.add(key);
      let n = boardNodes.get(key);
      if (!n) {
        n = el("div", "bev");
        const [ag, av] = boardAvatar(s, e.agent);
        n._av = av;
        if (ag) applyPalette(n, ag);
        n._who = el("span", "who", ag ? ag.display_name : e.by === "operator" ? "Operator" : e.by || "?");
        const verb = el("span", "verb " + e.verb, VERB[e.verb] || e.verb);
        n.append(av, n._who, verb);
        if (e.verb === "posted" && KIND[e.kind]) n.append(el("span", "kind", KIND[e.kind]));
        let title = clean(e.title);
        if (e.verb === "assigned" && e.owner) {
          const owner = s.agents.find((a) => a.name === e.owner_agent);
          title += " → " + (owner ? owner.display_name : e.owner);
        }
        n.append(el("span", "title", title));
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
    for (const [key, n] of boardNodes) if (!keys.has(key)) { n.remove(); boardNodes.delete(key); }
    let empty = log.querySelector(".empty");
    if (!events.length && !cl.length && !empty) log.appendChild(el("div", "empty", "Nothing on the board yet"));
    else if ((events.length || cl.length) && empty) empty.remove();

    const box = $("board-claims");
    const claims = b.claims || [];
    const csig = claims.map((c) => c.id + (c.agent || c.owner) + c.title).join("|") + "|" + b.claims_total
      + "|" + claims.map((c) => { const a = s.agents.find((x) => x.name === c.agent); return a ? a.color + a.glyph : ""; }).join("");
    if (box.dataset.sig !== csig) {
      box.dataset.sig = csig;
      box.textContent = "";
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

  const alertNodes = new Map();
  function renderAlerts(s) {
    const box = $("alerts");
    const live = new Set();
    for (const a of s.alerts || []) {
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
    for (const slot of ["main", "cam2", "cam3"]) {
      const frame = $("cam-" + slot);
      if (!frame) continue;
      const label = frame.querySelector(".cam-label");
      const cam = (s.cameras || {})[slot];
      const agents = cam ? cam.agents.map((n) => s.agents.find((a) => a.name === n)).filter(Boolean) : [];
      if (slot !== "main") renderFill(frame, s, !agents.length && !(cam && cam.attack));
      const sig = agents.map((a) => a.name + a.color + a.glyph + a.display_name).join("|") + "|" + (cam && cam.attack || "");
      const death = !!(cam && cam.attack && cam.alert === "death");
      label.classList.toggle("attack", !!(cam && cam.attack) && !death);
      label.classList.toggle("death", death);
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
      const doing = cam.attack ? (cam.attack.startsWith(lead.display_name) ? "under attack" : "attack nearby")
        : agents.length > 1 ? "working together" : lead.activity === "acting" && lead.action ? humanItem(lead.action)
        : lead.activity === "thinking" ? "thinking" : "";
      setText(label._doing, doing ? "· " + doing : "");
      frame.style.borderColor = cam.attack ? "rgba(224,78,58,0.75)" : palette(lead).ink + "66";
      frame.style.setProperty("--bracket", cam.attack ? "rgba(224,78,58,0.9)" : palette(lead).ink + "b0");
      applyPalette(label, lead);
      label.classList.add("on");
    }
  }

  // Space Age panel (right column, above chat): planets reached, space-age science made, up to three platforms with
  // where they are or their route (progress bar) and speed. Hidden until there is something (model space.active).
  function renderSpace(s) {
    const sp = s.space || {};
    const box = $("space");
    if (!box) return;
    box.hidden = !sp.active;
    if (!sp.active) return;
    const sig = JSON.stringify([sp.planets, (sp.science || []).map((p) => [p.item, fmtRate(p.total)]), sp.rockets,
      (sp.platforms || []).slice(0, 3).map((p) => [p.name, p.where, p.route && p.route.pct, p.speed_kms, p.paused])]);
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
    const list = sp.platforms || [];
    for (const p of list.slice(0, 3)) {
      const row = el("div", "plat");
      row.append(el("span", "pname", p.name), el("span", "pwhere", p.where));
      if (p.route) {
        const bar = el("span", "bar pbar"), i = el("i");
        i.style.width = p.route.pct + "%";
        bar.append(i);
        row.append(bar);
      }
      row.append(el("span", "pspeed", p.paused ? "paused" : p.speed_kms ? p.speed_kms + " km/s" : ""));
      plats.append(row);
    }
    if (list.length > 3) plats.append(el("div", "plat more", "+" + (list.length - 3) + " more platforms"));
    box.classList.toggle("noplats", !list.length);
  }

  // A side camera nobody is on (fewer agents than cameras, or the director paired them) would show an empty or stale
  // capture: after 4 s unused the hole gets an opaque desk card (the analyst's read, else research), gone on reuse.
  const PACE = { ahead: "ahead", "on pace": "onpace", behind: "behind" };
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
  const FULL = { production: 1, research: 1, recap: 1, space: 1 }; // these cover the main camera; spotlight/overview are a card on it
  function factRow(label, value, cls) {
    const r = el("div", "srow" + (cls ? " " + cls : ""));
    r.append(el("span", "k", label), el("span", "v", value == null || value === "" ? "–" : String(value)));
    return r;
  }
  function segmentBody(seg) {
    const f = seg.facts || {};
    const body = el("div", "sbody");
    if (seg.type === "production") {
      const head = el("div", "shead");
      head.append(el("span", "big", f.science_per_min != null ? fmtRate(f.science_per_min) : "–"), el("span", "unit", " science / min"),
        el("span", "stage", f.stage ? f.stage + " stage" : ""));
      body.append(head);
      const packs = el("div", "spacks");
      for (const [name, rate] of Object.entries(f.packs || {})) packs.append(el("span", "chip", name + " " + fmtRate(rate)));
      body.append(packs);
      const t = el("div", "stable");
      t.append(el("div", "th", "Item"), el("div", "th num", "now /min"), el("div", "th num", "10 min ago"));
      for (const it of f.items || []) {
        const icon = itemIcon(it.id || it.item.replace(/ /g, "-"), 32);
        const name = el("div", "td item");
        if (icon) name.append(icon);
        name.append(el("span", "", it.item));
        const delta = it.rate_now != null && it.rate_10min_ago ? it.rate_now - it.rate_10min_ago : 0;
        t.append(name, el("div", "td num" + (delta > 0 ? " up" : delta < 0 ? " down" : ""), fmtRate(it.rate_now)),
          el("div", "td num faint", fmtRate(it.rate_10min_ago)));
      }
      body.append(t);
      if (f.biggest_gain || f.biggest_drop)
        body.append(el("div", "snote", [f.biggest_gain && "Up most: " + f.biggest_gain, f.biggest_drop && "Down most: " + f.biggest_drop].filter(Boolean).join("   ·   ")));
    } else if (seg.type === "research") {
      body.append(el("div", "shead big", f.current || "No research queued"));
      const bar = el("div", "bar sbar");
      const fill = el("i");
      fill.style.width = (f.progress_pct || 0) + "%";
      bar.append(fill);
      body.append(bar, factRow("Progress", f.progress_pct != null ? f.progress_pct + "%" : null),
        factRow("Technologies done", f.done_count), factRow("Latest", (f.recent || []).join(", ")));
    } else if (seg.type === "recap") {
      body.append(factRow("Science per minute", f.science_per_min != null ? fmtRate(f.science_per_min) : null),
        factRow("Research finished", (f.research_done || []).join(", ") || "none"),
        factRow("Board items done", (f.board_done || []).join(", ") || "none"),
        factRow("Attacks", f.attacks || 0), factRow("Deaths", (f.deaths || []).length ? f.deaths.join(", ") : "none"));
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
    } else if (seg.type === "overview") {
      body.append(factRow("Agents in the world", f.agents_in_world + " of " + f.agents_total),
        factRow("Spread", "about " + f.spread_tiles + " tiles from the centre"),
        factRow("Areas", (f.locations || []).join(", ")));
    }
    return body;
  }
  const isFull = (seg) => !!FULL[seg.type] || (seg.type === "space_moment" && !(seg.facts || {}).agent); // a landing shows the agent
  function renderSegment(s) {
    const box = $("segment");
    const seg = s.segment;
    const show = !!seg && seg.state !== "ended";
    // a full panel shares the camera with at most the newest alert banner (overlay.css body.seg-full)
    document.body.classList.toggle("seg-full", show && isFull(seg));
    if (!show) {
      if (!box.hidden && !box.classList.contains("out")) {
        box.classList.add("out");
        setTimeout(() => { box.hidden = true; box.classList.remove("out"); box.dataset.sig = ""; }, 700);
      }
      return;
    }
    const sig = seg.id;
    if (box.dataset.sig !== sig) {
      box.dataset.sig = sig;
      box.classList.remove("out");
      box.className = (isFull(seg) ? "full" : "lower") + " seg-" + seg.type;
      box.textContent = "";
      const panel = el("div", "spanel");
      const title = el("div", "stitle");
      title.append(el("span", "tag", seg.type === "spotlight" ? "Spotlight" : seg.type === "overview" ? "Overview"
        : seg.type === "attack_replay" ? "Replay" : seg.type === "space" || seg.type === "space_moment" ? "Space Age" : "Analysis"),
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
    }
    const total = Math.max(1, seg.ends - seg.started);
    box._time.firstChild.style.width = Math.max(0, Math.min(1, (seg.ends - s.now) / total)) * 100 + "%";
  }

  function render(s) {
    state = s;
    window.pogState = s; // audio.js finds speaking agents' avatars here
    renderHead(s);
    renderCards(s);
    renderProduction(s);
    renderSpace(s);
    renderChat(s);
    renderViewers(s);
    renderBoard(s);
    renderAlerts(s);
    renderCams(s);
    renderSegment(s);
    watchVoice();
    watchAlerts();
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
    const es = new EventSource("/events");
    es.onmessage = (e) => { lastMsg = Date.now(); try { render(JSON.parse(e.data)); } catch (err) { console.error(err); } };
    es.onerror = () => { /* EventSource retries by itself */ };
  }
  connect();
  setInterval(() => {
    if (Date.now() - lastMsg < 6000) return;
    fetch("/state.json", { cache: "no-store" }).then((r) => r.json()).then((s) => { if (s && s.agents) render(s); }).catch(() => {});
  }, 3000);
})();
