// Stream overlay: renders /events snapshots into a 1920x1080 transparent page (OBS browser source).
(() => {
  "use strict";
  const params = new URLSearchParams(location.search);
  if (params.has("preview")) document.body.classList.add("preview");

  const PANEL = [13, 15, 21];
  const SLOT_LABEL = { main: "Main", cam2: "Cam 2", cam3: "Cam 3" };
  const ITEM = {
    "iron-plate": ["Iron plate", "#9fb3c8"], "copper-plate": ["Copper plate", "#e0895a"],
    "steel-plate": ["Steel", "#c7ccd6"], "electronic-circuit": ["Green circuit", "#5fd068"],
    "advanced-circuit": ["Red circuit", "#ef5b5b"], "plastic-bar": ["Plastic", "#e8e8e8"],
    "automation-science-pack": ["Red science", "#f05454"], "logistic-science-pack": ["Green science", "#4cc764"],
    "military-science-pack": ["Military sci.", "#9aa0a6"], "chemical-science-pack": ["Blue science", "#4aa3ff"],
    "production-science-pack": ["Purple sci.", "#b06cf0"], "utility-science-pack": ["Yellow sci.", "#f5d142"],
    "space-science-pack": ["Space sci.", "#f0f0f0"],
  };
  const ALERT_ICON = { attack: "⚔️", loss: "🔥", death: "💀", power: "⚡", research: "🔬", info: "ℹ️" };
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
    const p = { fill: toHex(base), ink: toHex(ink), glyph, ring };
    paletteCache.set(key, p);
    return p;
  }
  function applyPalette(el, agent) {
    const p = palette(agent);
    el.style.setProperty("--agent", p.fill);
    el.style.setProperty("--agent-ink", p.ink);
    el.style.setProperty("--glyph-ink", p.glyph);
    el.style.setProperty("--ring", p.ring);
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
  fetch("/static/layout.json").then((r) => r.json()).then((l) => {
    layout = l;
    for (const [slot, [x, y, w, h]] of Object.entries(l.cams)) {
      const c = $("cam-" + slot);
      if (!c) continue;
      Object.assign(c.style, { left: x + "px", top: y + "px", width: w + "px", height: h + "px" });
    }
    const m = l.cams.main;
    if (m) Object.assign($("alerts").style, { left: m[0] + "px", width: m[2] + "px", top: m[1] + 64 + "px" });
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
        r1.append(c.name, c.badge, c.harness);
        c.model = el("div", "model");
        c.motto = el("div", "motto");
        const doing = el("div", "doing");
        c.dot = el("span", "dot");
        c.txt = el("span", "txt");
        c.where = el("span", "where");
        doing.append(c.dot, c.txt, c.where);
        body.append(r1, c.model, c.motto, doing);
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
      const msig = [a.model, a.role, motto, density].join("|");
      if (c.model.dataset.sig !== msig) {
        c.model.dataset.sig = msig;
        c.model.textContent = "";
        c.model.append(el("b", "", a.model || "model ?"));
        if (density === "3" && motto) c.model.append(document.createTextNode(" · "), el("i", "", motto));
        else if (a.role) c.model.append(document.createTextNode(" · " + a.role));
        setText(c.motto, motto);
        c.motto.classList.toggle("unset", unset);
      }
      c.dot.className = "dot " + a.activity;
      let doing = a.action || "";
      if (a.activity === "thinking" && !a.active) doing = "thinking…";
      if (a.activity === "idle" && !doing) doing = "idle";
      setText(c.txt, humanItem(doing));
      setText(c.where, a.location ? "· " + a.location : "");
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
      top.append(researchCard.tech, researchCard.pct);
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
  function renderProduction(s) {
    const box = $("sparks");
    const items = s.production || [];
    const sig = items.map((x) => x.item).join(",");
    if (box.dataset.sig !== sig) {
      box.dataset.sig = sig;
      box.textContent = "";
      if (!items.length) box.appendChild(el("div", "empty", "Waiting for the first plates…"));
      for (const it of items) {
        const [label, color] = ITEM[it.item] || [humanItem(it.item), "#cccccc"];
        const cell = el("div", "spark");
        cell.dataset.item = it.item;
        const lbl = el("div", "lbl");
        lbl.append(el("span", "", label), el("span", "val"));
        const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
        svg.setAttribute("viewBox", "0 0 180 32");
        svg.setAttribute("preserveAspectRatio", "none");
        svg.innerHTML = `<defs><linearGradient id="g-${it.item}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${color}" stop-opacity="0.35"/><stop offset="1" stop-color="${color}" stop-opacity="0"/></linearGradient></defs>` +
          `<path class="a" fill="url(#g-${it.item})"/><path class="l" fill="none" stroke="${color}" stroke-width="1.8" stroke-linejoin="round" vector-effect="non-scaling-stroke"/>`;
        cell.append(lbl, svg);
        box.appendChild(cell);
      }
    }
    for (const it of items) {
      const cell = box.querySelector(`[data-item="${it.item}"]`);
      if (!cell) continue;
      setText(cell.querySelector(".val"), fmtRate(it.rate));
      const p = sparkPath(it.series, 180, 32);
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
    const msgs = (s.chat || []).slice(-7);
    const keys = new Set();
    for (const m of msgs) {
      const key = String(m.seq ?? m.tick + m.from + m.text);
      keys.add(key);
      let node = shown.get(key);
      const ag = agentFor(s, m);
      if (!node) {
        node = el("div", "msg" + (ag ? "" : " server"));
        node._av = avatar(ag || { name: m.from || "server", display_name: m.from || "server", color: "#3b4252", glyph: "⚙" }, "sm");
        const content = el("div", "content");
        const meta = el("div", "meta");
        node._from = el("span", "from");
        node._when = el("span", "when");
        meta.append(node._from, node._when);
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
      const sig = agents.map((a) => a.name + a.color + a.glyph + a.display_name).join("|") + "|" + (cam && cam.attack || "");
      label.classList.toggle("attack", !!(cam && cam.attack));
      if (cam && cam.attack && !agents.length) { // a base attack nobody is near: the camera shows the place
        if (label.dataset.sig !== sig) {
          label.dataset.sig = sig;
          label.textContent = "";
          label.append(el("span", "ico", "⚔️"), el("span", "", cam.attack));
        }
        frame.style.borderColor = "rgba(248,113,113,0.55)";
        label.classList.add("on");
        continue;
      }
      if (!agents.length) { label.classList.remove("on"); frame.style.borderColor = ""; continue; }
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
      frame.style.borderColor = palette(lead).ink + "66";
      label.classList.add("on");
    }
  }

  function render(s) {
    state = s;
    renderHead(s);
    renderCards(s);
    renderProduction(s);
    renderChat(s);
    renderBoard(s);
    renderAlerts(s);
    renderCams(s);
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
