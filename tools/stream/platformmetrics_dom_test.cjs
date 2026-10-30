// Minimal DOM to verify the card changes values in place and removes unknown fields, without a browser service.
const assert = require("node:assert/strict"), fs = require("node:fs"), vm = require("node:vm"), path = require("node:path");
class Element {
  constructor(tag) {
    this.tagName = tag; this.children = []; this.style = {}; this._text = "";
    const classes = new Set();
    this.classList = {toggle(c, on) { if (on) classes.add(c); else classes.delete(c); }, contains(c) { return classes.has(c); }};
  }
  append(...nodes) { for (const n of nodes) { n.parent = this; this.children.push(n); } }
  remove() { this.parent.children = this.parent.children.filter(n => n !== this); }
  setAttribute(k, v) { this[k] = v; }
  set textContent(v) { this._text = v; this.children = []; }
  get textContent() { return this._text + this.children.map(n => n.textContent).join(" "); }
}
const window = {}, document = {createElement: tag => new Element(tag)};
vm.runInNewContext(fs.readFileSync(path.join(__dirname, "static/platformmetrics.js"), "utf8"), {window, document});
const box = new Element("section"), render = window.PogPlatformMetrics.render;
render(box, null); assert(box.hidden);
const p = {platform: "Resolute <b>", featured: true, tick: 100, age_s: 0, speed_kms: 120, eta_wall_s: 3600,
  leg: {from: "solar-system-edge", to: "shattered-planet", pct: 20, flown_km: 800000, left_km: 3200000},
  kills_min: 120, hits_min: 0, window_s: 20, damage_taken: 0, losses_leg: 0,
  turrets: {"rocket-turret": {count: 8, targeting: 4, empty: 0}},
  ammo: [{name: "rocket", hub: 30, turrets: 10, made_min: 5, used_min: 15, net_min: -10, buffer_min: 4}],
  asteroids: {small: 10, medium: 3, big: 1, huge: 0}, repair_packs: 50};
render(box, p); assert(!box.hidden);
assert(box.textContent.includes("Resolute <b>")); assert(box.textContent.includes("40 hub + guns"));
assert(box.textContent.includes("4 engaged")); assert(box.textContent.includes("net -10"));
assert(!box.textContent.includes("undefined")); assert(!box.textContent.includes("NaN"));
const identity = box._parts.combat._rows.get("kills_min");
render(box, {...p, kills_min: 140, ammo: [], asteroids: undefined, repair_packs: undefined});
assert.equal(box._parts.combat._rows.get("kills_min"), identity);
assert.equal(identity._value.textContent, "140"); assert(box._parts.ammo.hidden); assert(box._parts.rocks.hidden);
assert(!box.textContent.includes("Repair packs"));
// A parked ship has exactly one row of positive totals, even if its cached payload has combat/flight facts.
const parked = {...p, platform: "Asterion", at: "nauvis", leg: null, speed_kms: 0,
  turrets: {"rocket-turret": {count: 8}, "laser-turret": {count: 4}},
  ammo: [...p.ammo, {name: "railgun-ammo", hub: 3, turrets: 2}]};
render(box, parked, 0);
assert(box.classList.contains("pm-parked"));
assert.equal(box._parts.parked.textContent, "Turrets 12 Ammo 45 Repair packs 50");
for (const k of ["header", "route", "bar", "flight", "rocks", "combat", "guns", "ammo", "supplies", "foot"])
  assert(box._parts[k].hidden, k + " must be hidden in port");
const stockRow = box._parts.parked._rows.get("ammo");
render(box, {...parked, ammo: [{name: "rocket", hub: 10, turrets: 1}]}, 1);
assert.equal(box._parts.parked._rows.get("ammo"), stockRow);
assert.equal(stockRow._value.textContent, "11");
render(box, {...parked, ammo: [], turrets: {}, repair_packs: 0}, 2);
assert(box.hidden); assert.equal(box._parts.parked.textContent, "");
render(box, {...parked, ammo: [{name: "rocket", hub: 5}], turrets: {gun: {}}, repair_packs: 7}, 3);
assert.equal(box._parts.parked.textContent, "Repair packs 7"); // partial stock is not an invented total

const quiet = {...p, featured: false, tick: 1, kills_min: 0, hits_min: 0,
  leg: {from: "fulgora", to: "nauvis", pct: 56.8, flown_km: 8525.1, left_km: 6474.9},
  asteroids: {small: 0, medium: 0, big: 0, huge: 0},
  turrets: {"rocket-turret": {count: 8, targeting: 0, empty: 0}}};
const isTransit = b => b.classList.contains("pm-transit");
const isCombat = b => !b.classList.contains("pm-transit") && !b.classList.contains("pm-parked") && !b.hidden;
const flightBox = new Element("section");
render(flightBox, quiet, 0); assert(isTransit(flightBox));
assert(!flightBox._parts.flight.hidden && !flightBox._parts.bar.hidden);
assert(flightBox._parts.flight.textContent.includes("ETA · wall"));
assert.equal(flightBox._parts.ammo.textContent, "Rocket 40 hub + guns");
assert.equal(flightBox._parts.supplies.textContent, "Repair packs · hub 50");
for (const k of ["rocks", "combat", "guns", "foot", "parked"]) assert(flightBox._parts[k].hidden, k);

// Only the requested attempt/danger signals enter full; two non-triggering samples and 60 seconds clear the hold.
for (const signal of [{asteroids: {...quiet.asteroids, big: 1}}, {asteroids: {...quiet.asteroids, huge: 1}},
  {hits_min: 3}, {damage_taken: 3}]) {
  const b = new Element("section"), hot = {...quiet, ...signal, tick: 2};
  render(b, quiet, 0); assert(isTransit(b));
  render(b, hot, 20); assert(isCombat(b)); assert(!b._parts.combat.hidden && !b._parts.guns.hidden);
  render(b, {...hot, age_s: 19}, 39); // same read repainted: must not extend the hold to 99 seconds
  render(b, {...quiet, tick: 3}, 40); assert(isCombat(b));
  render(b, {...quiet, tick: 4}, 60); assert(isCombat(b));
  render(b, {...quiet, tick: 4, age_s: 19}, 79); assert(isCombat(b));
  render(b, {...quiet, tick: 5}, 80); assert(isTransit(b));
  assert(b._parts.combat.hidden && b._parts.guns.hidden);
  render(b, {...hot, tick: 6}, 100); assert(isCombat(b));
}
// A combat sample remains relevant among the last two even when more than 60 seconds separate the reads.
const recent = new Element("section");
render(recent, {...quiet, hits_min: 1}, 0);
render(recent, {...quiet, tick: 2}, 80); assert(isCombat(recent));
render(recent, {...quiet, tick: 3}, 100); assert(isTransit(recent));
// Sample age is respected: repainting an already 20-second-old combat sample starts no new 60-second window.
const aged = new Element("section");
render(aged, {...quiet, hits_min: 1, age_s: 20}, 100);
render(aged, {...quiet, tick: 2}, 120); assert(isCombat(aged));
render(aged, {...quiet, tick: 3}, 140); assert(isTransit(aged));
// The first window or a missing value is not a positive full-card trigger. Unknown data still has no row.
for (const missing of [{asteroids: undefined}, {kills_min: undefined}, {hits_min: undefined}, {damage_taken: undefined},
  {turrets: undefined}, {turrets: {gun: {count: 1}}}, {tick: undefined}]) {
  const b = new Element("section");
  render(b, {...quiet, ...missing}, 0); assert(isTransit(b));
  render(b, {...quiet, tick: 2}, 20); assert(isTransit(b));
  render(b, {...quiet, tick: 3}, 40); assert(isTransit(b));
}
// Reproduce Asterion's live 12:11 Fulgora -> Nauvis sample, including its missing rate window.
const routine = {...quiet, platform: "Asterion", speed_kms: 53, kills_min: undefined, hits_min: undefined,
  damage_taken: undefined, window_s: undefined, eta_wall_s: undefined,
  turrets: {"laser-turret": {count: 23, targeting: 7}, "gun-turret": {count: 58, targeting: 2, empty: 0},
    "rocket-turret": {count: 31, targeting: 2, empty: 0}, "railgun-turret": {count: 41, targeting: 0, empty: 0}}};
const routineBox = new Element("section");
render(routineBox, routine, 0); assert(isTransit(routineBox));
assert(routineBox._parts.flight.textContent.includes("53 km/s"));
for (const k of ["rocks", "combat", "guns"]) assert(routineBox._parts[k].hidden);
// Small/medium encounters, kills and damage dealt alone do not promote or prolong the full card.
const smallFight = {...routine, kills_min: 900, damage_dealt_min: 90000, hits_min: 0, damage_taken: 0,
  asteroids: {small: 200, medium: 100, big: 0, huge: 0}};
render(routineBox, {...smallFight, tick: 2}, 20); assert(isTransit(routineBox));
render(routineBox, {...smallFight, tick: 3, damage_taken: 1}, 40); assert(isCombat(routineBox));
render(routineBox, {...smallFight, tick: 4}, 60); assert(isCombat(routineBox));
render(routineBox, {...smallFight, tick: 5}, 80); assert(isCombat(routineBox));
render(routineBox, {...smallFight, tick: 6}, 100); assert(isTransit(routineBox));
// Each outer stop forces full in both directions, even before the first rate window or while at zero speed.
for (const stop of ["aquilo", "solar-system-edge", "shattered-planet"]) for (const endpoint of ["from", "to"]) {
  const b = new Element("section");
  const leg = {...quiet.leg, [endpoint]: stop};
  render(b, {...routine, leg}, 0); assert(isCombat(b));
  render(b, {...routine, leg, speed_kms: 0}, 1); assert(isCombat(b));
  render(b, {...routine, tick: 2}, 20); assert(isTransit(b)); // new inner leg inherits no route override
  render(b, {...parked, at: stop}, 21); assert(b.classList.contains("pm-parked"));
}
// Featured runs get the full flight card even when quiet; being parked always takes precedence.
render(flightBox, {...quiet, featured: true}, 1); assert(isCombat(flightBox));
render(flightBox, parked, 2); assert(flightBox.classList.contains("pm-parked"));
render(flightBox, {...quiet, speed_kms: 0}, 3); assert(isTransit(flightBox)); // zero speed on a leg is still flight
render(flightBox, {...quiet, leg: null}, 4); assert(isTransit(flightBox)); // positive speed, route unknown
// A different ship, leg, direction, departure, arrival or tick rollback cannot inherit another combat hold.
for (const change of [{platform: "Petrel"}, {leg: {...quiet.leg, to: "gleba"}},
  {leg: {...quiet.leg, back: true}}, {leg: {...quiet.leg, start_tick: 20}}, {tick: 0}]) {
  const b = new Element("section");
  render(b, {...quiet, hits_min: 1}, 0);
  render(b, {...quiet, tick: 2, ...change}, 20); assert(isTransit(b));
}
render(box, {platform: "Bare"}, 0); assert(box.hidden);
render(box, null); assert(box.hidden);
console.log("platform metrics DOM: slim port, routine inner flights, attempt/danger triggers, outer legs and two-sample 60s hold");
