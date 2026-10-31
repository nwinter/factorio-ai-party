/* One anchored ship card. Telemetry advances history once; repaints only expire wall-time beats. */
(function () {
  const BEAT = 8, GAP = 30, WARNING_HOLD = 20;
  const finite = v => typeof v === "number" && Number.isFinite(v);
  const num = v => finite(v) ? v.toLocaleString("en-US", {maximumFractionDigits: 1}) : "";
  const label = v => String(v || "").replace(/-/g, " ").replace(/\b\w/g, c => c.toUpperCase());
  const short = v => ({"piercing-rounds-magazine": "Piercing", "firearm-magazine": "Firearm",
    "uranium-rounds-magazine": "Uranium", "railgun-ammo": "Railgun", "explosive-rocket": "Explosive rocket"})[v] || label(v);
  const duration = s => s >= 3600 ? `${Math.floor(s / 3600)}h ${Math.floor(s % 3600 / 60)}m` : s >= 60 ? `${Math.floor(s / 60)}m ${Math.floor(s % 60)}s` : `${Math.ceil(s)}s`;
  const clock = () => typeof performance === "undefined" ? Date.now() / 1000 : performance.now() / 1000;
  const total = values => values && values.length && values.every(finite) ? values.reduce((sum, v) => sum + v, 0) : null;
  function node(tag, cls) { const n = document.createElement(tag); n.className = cls; return n; }
  function put(n, value) { if (n.textContent !== value) n.textContent = value; }
  function rows(parent, data) {
    parent._rows = parent._rows || new Map();
    const keep = new Set();
    for (const [key, title, value, hint, bad] of data) {
      keep.add(key);
      let row = parent._rows.get(key);
      if (!row) {
        row = node("div", "pm-row"); row._key = node("span", "pm-key"); row._value = node("span", "pm-value");
        row.append(row._key, row._value); parent.append(row); parent._rows.set(key, row);
      }
      put(row._key, title); put(row._value, value); row.title = hint || "";
      row.classList.toggle("pm-bad", !!bad);
    }
    for (const [key, row] of parent._rows) if (!keep.has(key)) { row.remove(); parent._rows.delete(key); }
    parent.hidden = !data.length;
  }
  const overlaps = (a, b, pad = 0) => a.left < b.right + pad && a.right > b.left - pad && a.top < b.bottom + pad && a.bottom > b.top - pad;
  function captionRects(box) {
    const cam = box.parentElement;
    if (!cam) return [];
    return [document.getElementById("alerts"), cam.querySelector(".cam-label.on"),
      ...document.querySelectorAll("#voice .cap.on")].filter(n => n && n.textContent.trim())
      .map(n => n.getBoundingClientRect()).filter(r => r.width > 0 && r.height > 0);
  }
  function clearCaption(box) {
    const cam = box.parentElement;
    if (!cam || !box.getBoundingClientRect) return;
    const frame = cam.getBoundingClientRect(), card = box.getBoundingClientRect();
    let top = 14;
    for (const r of captionRects(box))
      if (r.left < card.right && r.right > card.left && r.top < frame.top + frame.height / 2)
        top = Math.max(top, Math.ceil(r.bottom - frame.top - cam.clientTop + 8));
    box.style.setProperty("--pm-top", top + "px");
  }
  function clearsWorksite(box, p, scene) {
    // A work/follow shot has no trustworthy work-area bounds: reserve the pane, rather than guessing.
    // For an overview use the complete surveyed foundation and acknowledged frame already in the snapshot.
    const cam = (scene.cameras || {}).main || {}, frame = cam.frame || {};
    const view = (((scene.space || {}).platforms || []).find(s => s.name === p.platform) || {}).view || {};
    const hull = view.hull || view.bounds, pos = frame.position, pane = box.parentElement;
    if (!pane || !hull || !pos || cam.work || cam.attention || cam.work_close || frame.follow || cam.map ||
        frame.surface !== view.surface || ![pos.x, pos.y, frame.zoom, frame.frac, ...Object.values(hull)].every(finite) ||
        frame.zoom <= 0 || frame.frac <= 0 || frame.frac > 1) return false;
    const r = pane.getBoundingClientRect(), card = box.getBoundingClientRect();
    const sx = r.width * frame.zoom / (60 * frame.frac), sy = r.height * frame.zoom / 33.75;
    const ship = {left: r.left + r.width / 2 + (hull.left - pos.x) * sx,
      right: r.left + r.width / 2 + (hull.right - pos.x) * sx,
      top: r.top + r.height / 2 + (hull.top - pos.y) * sy,
      bottom: r.top + r.height / 2 + (hull.bottom - pos.y) * sy};
    return card.right <= r.right - 14 && card.bottom <= r.bottom - 58 &&
      !overlaps(card, ship, 12) && !captionRects(box).some(c => overlaps(card, c, 8));
  }
  function warningReadings(p) {
    const out = new Map();
    const add = (key, title, value, bad) => { if (finite(value)) out.set(key, bad ? [key, title, num(value), "Last positive reading; clears after two clean samples and at least 20 seconds", true] : null); };
    add("hits", "Hits taken/min", p.hits_min, p.hits_min > 0);
    add("damage", "Damage taken", p.damage_taken, p.damage_taken > 0);
    add("lost", "Lost this leg", p.losses_leg, p.losses_leg > 0);
    for (const [name, g] of Object.entries(p.turrets || {})) add("empty:" + name, `${label(name)} empty`, g.empty, g.empty > 0);
    for (const a of p.ammo || []) {
      add("buffer:" + a.name, `${short(a.name)} buffer · min`, a.buffer_min, a.buffer_min < 2);
      if (!finite(a.buffer_min) && finite(a.net_min) && a.net_min >= 0 && total([a.hub, a.turrets]) > 0)
        out.set("buffer:" + a.name, null);
    }
    for (const [name, title] of [["thruster-fuel", "Fuel tanks empty"], ["thruster-oxidizer", "Oxidizer tanks empty"]])
      add(name, title, (p.fuel || {})[name], (p.fuel || {})[name] === 0);
    return out;
  }
  function sample(box, p, now) {
    const l = p.leg || {}, flying = !!(l.from && l.to) || (finite(p.speed_kms) && p.speed_kms > 0);
    const key = JSON.stringify([p.platform, l.connection, l.from, l.to, l.back, l.start_tick, p.at]);
    let a = box._activity;
    const reset = !a || a.ship !== p.platform || (finite(p.tick) && finite(a.tick) && p.tick < a.tick);
    if (reset) a = box._activity = {ship: p.platform, key, tick: null, flying, until: -Infinity,
      warnings: new Map(), clear: 0, dockFull: false, rocks: {}};
    const changed = a.key !== key;
    const fresh = changed || (finite(p.tick) && p.tick !== a.tick);
    if (fresh) {
      const at = now - (finite(p.age_s) ? Math.max(0, p.age_s) : 0), rocks = p.asteroids || {};
      const event = changed || (!reset && ((p.hits_min > 0 || p.damage_taken > 0) ||
        ["big", "huge"].some(k => finite(rocks[k]) && rocks[k] > (a.rocks[k] || 0))));
      if (changed) { a.until = -Infinity; a.warnings.clear(); a.clear = 0; a.dockFull = false; }
      if (event && at >= (box._nextBeat ?? -Infinity) && at + BEAT > now) { a.until = at + BEAT; box._nextBeat = a.until + GAP; }
      for (const [key, reading] of warningReadings(p)) {
        if (reading) a.warnings.set(key, {row: reading, until: at + WARNING_HOLD, clean: 0});
        else if (a.warnings.has(key)) {
          const w = a.warnings.get(key); w.clean++;
          if (w.clean >= 2 && at >= w.until) a.warnings.delete(key);
        }
      }
      a.key = key; a.tick = p.tick; a.flying = flying; a.rocks = rocks;
    }
    return {a, fresh};
  }
  function render(box, p, now = clock(), scene = {}) {
    if (!box) return;
    if (box._timer) window.clearTimeout(box._timer);
    box._latest = {p, scene}; box.hidden = !p || !p.platform;
    if (box.hidden) return; // retain history through scene gaps; a cached sample cannot replay a beat
    if (!box._parts) {
      const header = node("strong", "pm-head"), summary = node("div", "pm-summary"), warnings = node("div", "pm-warnings");
      const details = node("div", "pm-details"), bar = node("div", "pm-progress"), fill = node("i", ""); bar.append(fill);
      const flight = node("div", "pm-flight"), rocks = node("div", "pm-rocks"), combat = node("div", "pm-combat");
      const guns = node("div", "pm-guns"), ammo = node("div", "pm-ammo"), supplies = node("div", "pm-supplies"), foot = node("div", "pm-foot");
      details.append(flight, rocks, combat, guns, ammo, supplies, foot);
      box.append(header, bar, summary, warnings, details);
      box._parts = {header, summary, warnings, details, bar, fill, flight, rocks, combat, guns, ammo, supplies, foot};
      if (window.ResizeObserver && box.parentElement) {
        const observer = new window.ResizeObserver(() => { const v = box._latest; render(box, v.p, clock(), v.scene); });
        for (const n of [box.parentElement, document.getElementById("alerts"), document.getElementById("voice")]) if (n) observer.observe(n);
      }
    }
    const b = box._parts, l = p.leg || {}, {a, fresh} = sample(box, p, now), parked = !a.flying;
    const where = l.from && l.to ? `${label(l.from)} → ${label(l.to)}` : p.at ? `Docked at ${label(p.at)}` : parked ? "Dock unknown" : "Route unknown";
    put(b.header, `${p.platform} · ${where}`);
    box.setAttribute("aria-label", `${p.platform} · ${where}`);
    // Keep the complete identity on the first line, including long outer-system routes.
    b.header.style.fontSize = "16px";
    if (b.header.scrollWidth > b.header.clientWidth && b.header.clientWidth)
      b.header.style.fontSize = (16 * b.header.clientWidth / b.header.scrollWidth).toFixed(2) + "px";
    b.bar.hidden = parked || !finite(l.pct);
    if (finite(l.pct)) b.fill.style.width = Math.max(0, Math.min(100, l.pct)) + "%";
    const summary = parked ? [] : [finite(p.speed_kms) ? `${num(p.speed_kms)} km/s` : "", finite(l.pct) ? `${num(l.pct)}% flown` : "",
      finite(p.eta_wall_s) ? `ETA ≈ ${duration(p.eta_wall_s)}` : "", l.turned_back ? "Returning" : ""];
    if (parked) for (const [title, value] of [["turrets", total(p.turrets && Object.values(p.turrets).map(g => g.count))],
      ["ammo", total(p.ammo && p.ammo.map(r => total([r.hub, r.turrets])))], ["repair packs", p.repair_packs]])
      if (finite(value) && value > 0) summary.push(`${num(value)} ${title}`);
    if (p.paused) summary.push("Simulation paused"); else if (p.platform_paused) summary.push("Schedule paused");
    put(b.summary, summary.filter(Boolean).join(" · ")); b.summary.hidden = !b.summary.textContent;
    rows(b.warnings, [...a.warnings.values()].map(w => w.row));
    const flight = [];
    if (!parked) {
      if (finite(l.pct)) flight.push(["progress", l.turned_back ? "Position on leg" : "Flown", `${num(l.flown_km)} km · ${num(l.pct)}%`]);
      if (finite(l.left_km)) flight.push(["left", "Left", `${num(l.left_km)} km`]);
      if (finite(p.speed_kms)) flight.push(["speed", "Speed · game", `${num(p.speed_kms)} km/s`]);
      if (finite(p.eta_wall_s)) flight.push(["eta", "ETA · wall", `≈ ${duration(p.eta_wall_s)}`]);
    }
    rows(b.flight, flight);
    rows(b.rocks, ["small", "medium", "big", "huge"].filter(k => finite((p.asteroids || {})[k])).map(k =>
      [k, label(k), num(p.asteroids[k]), "Asteroids inside the main camera frame at the last sample"]));
    const combat = [];
    for (const [key, title] of [["kills_min", "Kills/min"], ["hits_min", "Hits taken/min"], ["damage_dealt_min", "Damage dealt/min"],
      ["damage_taken", `Taken · ${num(p.window_s)}s`], ["losses_leg", "Lost this leg"]])
      if (finite(p[key])) combat.push([key, title, num(p[key]), "", ["hits_min", "damage_taken", "losses_leg"].includes(key) && p[key] > 0]);
    rows(b.combat, combat);
    const guns = [];
    for (const [name, g] of Object.entries(p.turrets || {})) {
      const values = [finite(g.count) ? `${num(g.count)} total` : "", finite(g.targeting) ? `${num(g.targeting)} engaged` : "",
        finite(g.empty) ? `${num(g.empty)} empty` : ""].filter(Boolean);
      if (values.length) guns.push([name, label(name).replace(/ Turret$/, ""), values.join(" · "), "Engaged: has a target. Empty: no loaded ammunition.", g.empty > 0]);
    }
    rows(b.guns, guns);
    const ammunition = [];
    for (const r of p.ammo || []) {
      const stock = finite(r.hub) && finite(r.turrets) ? `${num(r.hub + r.turrets)} hub + guns` : finite(r.hub) ? `${num(r.hub)} hub` : finite(r.turrets) ? `${num(r.turrets)} guns` : "";
      const flow = finite(r.made_min) && finite(r.used_min) ? `+${num(r.made_min)} / −${num(r.used_min)} per min` : "";
      const net = finite(r.net_min) ? `net ${r.net_min > 0 ? "+" : ""}${num(r.net_min)}` : "";
      const left = finite(r.buffer_min) ? `${num(r.buffer_min)} min buffer` : "";
      if (stock || flow) ammunition.push([r.name, short(r.name), [stock, flow, net, left].filter(Boolean).join(" · "),
        "Stock: hub + loaded guns, all qualities. Belts/machines excluded. Rates include crafting use. Buffer is stock / net use, not an endurance guarantee.", finite(r.buffer_min) && r.buffer_min < 2]);
    }
    rows(b.ammo, ammunition);
    const supply = [];
    if (finite(p.repair_packs)) supply.push(["repair", "Repair packs · hub", num(p.repair_packs), "All qualities", p.repair_packs === 0]);
    for (const [name, title] of [["thruster-fuel", "Fuel · tanks"], ["thruster-oxidizer", "Oxidizer · tanks"]])
      if (finite((p.fuel || {})[name])) supply.push([name, title, num(p.fuel[name]), "Thruster and storage tanks; pipes/machines excluded"]);
    rows(b.supplies, supply);
    put(b.foot, [p.featured && !parked ? "FEATURED ATTEMPT" : "", finite(p.window_s) ? `Rates / wall min · ${num(p.window_s)}s sample` : "",
      finite(p.age_s) ? `${num(p.age_s)}s ago` : ""].filter(Boolean).join(" · "));
    // Measure the full candidate synchronously, before painting; commit just one mode below.
    b.details.hidden = false;
    clearCaption(box);
    if (parked) {
      a.safe = clearsWorksite(box, p, scene);
      if (!a.safe) { a.clear = 0; a.dockFull = false; }
      else if (fresh) { a.clear++; if (a.clear >= 2) a.dockFull = true; }
    }
    const full = parked ? a.dockFull || (a.safe && now < a.until) : !!p.featured || now < a.until;
    const mode = parked ? full ? a.dockFull ? "docked-full" : "docked-beat" : "docked-compact" : p.featured ? "attempt" : full ? "beat" : "compact";
    box.setAttribute("data-mode", mode);
    b.details.hidden = !full;
    // A beat must end even if telemetry arrives only every 20 seconds or the socket temporarily stalls.
    if ((parked ? !a.dockFull : !p.featured) && now < a.until && window.setTimeout)
      box._timer = window.setTimeout(() => { const v = box._latest; render(box, v.p, clock(), v.scene); }, (a.until - now) * 1000 + 1);
  }
  window.PogPlatformMetrics = {render};
})();
