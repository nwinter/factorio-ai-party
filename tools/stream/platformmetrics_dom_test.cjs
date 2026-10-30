// Minimal DOM to verify the card changes values in place and removes unknown fields, without a browser service.
const assert = require("node:assert/strict"), fs = require("node:fs"), vm = require("node:vm"), path = require("node:path");
class Element {
  constructor(tag) { this.tagName = tag; this.children = []; this.style = {}; this._text = ""; this.classList = {toggle() {}}; }
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
render(box, {platform: "Bare"}); assert(box._parts.flight.hidden); assert(box._parts.combat.hidden);
assert(!box.textContent.includes("Kills/min"));
render(box, null); assert(box.hidden);
console.log("platform metrics DOM: unknowns hidden, zeroes shown, numbers update in the same nodes");
