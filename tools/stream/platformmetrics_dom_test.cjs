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
const p = {platform: "Resolute <b>", featured: true, age_s: 0, speed_kms: 120,
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
// Arrival removes flight-only facts even when the sample still carries known zeroes/rates/fuel.
render(box, {...p, platform: "Asterion", at: "nauvis", leg: null, speed_kms: 0,
  fuel: {"thruster-fuel": 2000, "thruster-oxidizer": 2000}});
assert(box.classList.contains("pm-compact")); assert.equal(box._parts.route.textContent, "At Nauvis");
assert(box._parts.flight.hidden && box._parts.rocks.hidden && box._parts.combat.hidden && box._parts.bar.hidden);
assert.equal(box._parts.guns.textContent, "Turrets Rocket 8");
assert.equal(box._parts.ammo.textContent, "Rocket 40 hub + guns");
assert.equal(box._parts.supplies.textContent, "Repair packs · hub 50");
assert(box._parts.tag.hidden && box._parts.foot.hidden);
// Unknown stock is omitted at a stop, known zero is shown; the row survives a stock update.
const stockRow = box._parts.ammo._rows.get("rocket");
render(box, {platform: "Asterion", at: "nauvis", speed_kms: 0,
  ammo: [{name: "rocket", hub: 0, turrets: 0}, {name: "railgun-ammo", made_min: 10}],
  turrets: {"rocket-turret": {count: 0}, "gun-turret": {empty: 2}}});
assert.equal(box._parts.ammo._rows.get("rocket"), stockRow);
assert.equal(box._parts.ammo.textContent, "Rocket 0 hub + guns");
assert.equal(box._parts.guns.textContent, "Turrets Rocket 0");
assert(box._parts.supplies.hidden);
// Stopped mid-flight keeps the full card; departure restores flight rows on the same card.
render(box, {...p, speed_kms: 0});
assert(!box.classList.contains("pm-compact")); assert(!box._parts.combat.hidden && !box._parts.rocks.hidden);
assert(!box._parts.tag.hidden && !box._parts.foot.hidden);
assert(box._parts.ammo.textContent.includes("net -10"));
render(box, {...p, leg: null}); assert(!box.classList.contains("pm-compact"));
render(box, {platform: "Bare"}); assert(box._parts.flight.hidden); assert(box._parts.combat.hidden);
assert(!box.textContent.includes("Kills/min"));
render(box, null); assert(box.hidden);
console.log("platform metrics DOM: unknowns hidden, zeroes shown, stable rows, compact arrival and full flight restored");
