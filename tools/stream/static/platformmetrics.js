/* The attempt card: keyed rows keep their DOM nodes while numbers change. Unknown values have no row. */
(function () {
  const finite = (v) => typeof v === "number" && Number.isFinite(v);
  const num = (v) => finite(v) ? v.toLocaleString("en-US", {maximumFractionDigits: 1}) : "";
  const label = (v) => String(v || "").replace(/-/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
  const short = (v) => ({"piercing-rounds-magazine": "Piercing", "firearm-magazine": "Firearm",
    "uranium-rounds-magazine": "Uranium", "railgun-ammo": "Railgun", "explosive-rocket": "Explosive rocket"})[v] || label(v);
  const duration = (s) => s >= 3600 ? `${Math.floor(s / 3600)}h ${Math.floor(s % 3600 / 60)}m` : s >= 60 ? `${Math.floor(s / 60)}m ${Math.floor(s % 60)}s` : `${Math.ceil(s)}s`;
  function node(tag, cls, text) {
    const n = document.createElement(tag); n.className = cls;
    if (text !== undefined) n.textContent = text;
    return n;
  }
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
  function render(box, p) {
    if (!box) return;
    box.hidden = !p || !p.platform;
    if (box.hidden) return;
    if (!box._parts) {
      const header = node("div", "pm-head"), name = node("strong", "pm-name"), tag = node("span", "pm-tag");
      header.append(name, tag);
      const route = node("div", "pm-route"), bar = node("div", "pm-progress"), fill = node("i", ""); bar.append(fill);
      const flight = node("div", "pm-flight"), rocks = node("div", "pm-rocks"), combat = node("div", "pm-combat");
      const guns = node("div", "pm-guns"), ammo = node("div", "pm-ammo"), supplies = node("div", "pm-supplies");
      const foot = node("div", "pm-foot");
      box.append(header, route, bar, flight, rocks, combat, guns, ammo, supplies, foot);
      box._parts = {name, tag, route, bar, fill, flight, rocks, combat, guns, ammo, supplies, foot};
    }
    const b = box._parts, l = p.leg || {};
    put(b.name, p.platform); put(b.tag, p.featured ? "FEATURED SHIP" : "ON CAMERA");
    put(b.route, l.turned_back ? `Returning to ${label(l.to)}` : l.from && l.to ? `${label(l.from)} → ${label(l.to)}` : p.at ? `At ${label(p.at)}` : "");
    b.route.hidden = !b.route.textContent; b.bar.hidden = !finite(l.pct);
    if (finite(l.pct)) b.fill.style.width = Math.max(0, Math.min(100, l.pct)) + "%";
    const flight = [];
    if (finite(l.pct)) flight.push(["progress", l.turned_back ? "Position on leg" : "Flown", `${num(l.flown_km)} km · ${num(l.pct)}%`]);
    if (finite(l.left_km)) flight.push(["left", "Left", `${num(l.left_km)} km`]);
    if (finite(p.speed_kms)) flight.push(["speed", "Speed · game", `${num(p.speed_kms)} km/s`, "Distance per game second"]);
    if (finite(p.eta_wall_s)) flight.push(["eta", "ETA · wall", `≈ ${duration(p.eta_wall_s)}`, "At the current ship speed and recently observed game ticks per wall second"]);
    if (p.paused) flight.push(["paused", "Simulation", "Paused"]);
    else if (p.platform_paused) flight.push(["paused", "Schedule", "Paused"]);
    rows(b.flight, flight);
    const rocks = [];
    for (const size of ["small", "medium", "big", "huge"]) if (finite((p.asteroids || {})[size]))
      rocks.push([size, label(size), num(p.asteroids[size]), "Asteroids inside the main camera frame at the last sample"]);
    rows(b.rocks, rocks); b.rocks.setAttribute("aria-label", "Asteroids in sampled view");
    const combat = [];
    for (const [key, title] of [["kills_min", "Kills/min"], ["hits_min", "Hits taken/min"], ["damage_dealt_min", "Damage dealt/min"]])
      if (finite(p[key])) combat.push([key, title, num(p[key])]);
    if (finite(p.damage_taken)) combat.push(["damage", `Taken · ${num(p.window_s)}s`, num(p.damage_taken), "Damage taken during this sampling window; repairs do not subtract from it", p.damage_taken > 0]);
    if (finite(p.losses_leg)) combat.push(["lost", "Lost this leg", num(p.losses_leg), "Destroyed entities recorded since this leg began; foundation tiles excluded", p.losses_leg > 0]);
    rows(b.combat, combat);
    const guns = [];
    for (const [name, g] of Object.entries(p.turrets || {})) {
      const values = [finite(g.count) ? `${num(g.count)} total` : "", finite(g.targeting) ? `${num(g.targeting)} engaged` : "",
        finite(g.empty) ? `${num(g.empty)} empty` : ""].filter(Boolean);
      if (values.length) guns.push([name, label(name).replace(/ Turret$/, ""), values.join(" · "), "Engaged: has a shooting target at this instant. Empty: no loaded ammunition.", g.empty > 0]);
    }
    rows(b.guns, guns);
    const ammunition = [];
    for (const a of p.ammo || []) {
      const stock = finite(a.hub) && finite(a.turrets) ? `${num(a.hub + a.turrets)} hub + guns` :
        finite(a.hub) ? `${num(a.hub)} hub` : finite(a.turrets) ? `${num(a.turrets)} guns` : "";
      const flow = finite(a.made_min) && finite(a.used_min) ? `+${num(a.made_min)} / −${num(a.used_min)} per min` : "";
      const net = finite(a.net_min) ? `net ${a.net_min > 0 ? "+" : ""}${num(a.net_min)}` : "";
      const left = finite(a.buffer_min) ? `${num(a.buffer_min)} min buffer` : "";
      if (stock || flow) ammunition.push([a.name, short(a.name), [stock, flow, net, left].filter(Boolean).join(" · "),
        "Stock: hub and loaded turrets, all qualities; belts and machines excluded. Made/used: surface item statistics, including ammo used in crafting. Buffer time: this stock / current net use, without feed or ingredient guarantees.", finite(a.buffer_min) && a.buffer_min < 2]);
    }
    rows(b.ammo, ammunition);
    const supply = [];
    if (finite(p.repair_packs)) supply.push(["repair", "Repair packs · hub", num(p.repair_packs), "All qualities", p.repair_packs === 0]);
    for (const [name, title] of [["thruster-fuel", "Fuel · tanks"], ["thruster-oxidizer", "Oxidizer · tanks"]])
      if (finite((p.fuel || {})[name])) supply.push([name, title, num(p.fuel[name]), "Thruster and storage tanks; pipes and machines excluded"]);
    rows(b.supplies, supply);
    put(b.foot, [finite(p.window_s) ? `Rates / wall min · ${num(p.window_s)}s sample` : "", finite(p.age_s) ? `${num(p.age_s)}s ago` : ""].filter(Boolean).join(" · "));
  }
  window.PogPlatformMetrics = {render};
})();
