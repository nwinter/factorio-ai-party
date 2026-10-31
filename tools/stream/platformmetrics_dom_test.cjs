// No live services: exercise sample history, scene geometry and reload with a minimal DOM.
const assert = require("node:assert/strict"), fs = require("node:fs"), vm = require("node:vm"), path = require("node:path");
const rect = (left, top, width, height) => ({left, top, right: left + width, bottom: top + height, width, height});
class Element {
  constructor(tag) {
    this.tagName = tag; this.children = []; this.style = {setProperty(k, v) { this[k] = v; }}; this._text = ""; this.clientTop = 2;
    const classes = new Set();
    this.classList = {toggle(c, on) { if (on) classes.add(c); else classes.delete(c); }, contains(c) { return classes.has(c); }};
  }
  append(...nodes) { for (const n of nodes) { n.parentElement = this; this.children.push(n); } }
  remove() { this.parentElement.children = this.parentElement.children.filter(n => n !== this); }
  setAttribute(k, v) { this[k] = v; if (k === "data-mode") this.decisions = (this.decisions || 0) + 1; }
  set textContent(v) { this._text = v; this.children = []; }
  get textContent() { return this._text + this.children.map(n => n.textContent).join(" "); }
  querySelector() { return this.caption || null; }
  getBoundingClientRect() { return this.rect || rect(40, 26 + parseFloat(this.style["--pm-top"] || 14), 360, this._parts?.details.hidden ? 75 : 600); }
}
const source = fs.readFileSync(path.join(__dirname, "static/platformmetrics.js"), "utf8");
function page() {
  const window = {}, elements = {}, document = {createElement: tag => new Element(tag), getElementById: id => elements[id], querySelectorAll: () => elements.alerts ? [elements.alerts] : []};
  vm.runInNewContext(source, {window, document});
  const pane = new Element("div"), box = new Element("section"); pane.rect = rect(24, 24, 1208, 1032); pane.append(box);
  return {render: window.PogPlatformMetrics.render, box, pane, elements};
}
const p = {platform: "Resolute <b>", featured: false, tick: 100, age_s: 0, speed_kms: 120, eta_wall_s: 3600,
  leg: {from: "solar-system-edge", to: "shattered-planet", pct: 20, flown_km: 800000, left_km: 3200000},
  kills_min: 120, hits_min: 0, window_s: 20, damage_taken: 0, losses_leg: 0,
  turrets: {"rocket-turret": {count: 8, targeting: 4, empty: 0}},
  ammo: [{name: "rocket", hub: 30, turrets: 10, made_min: 5, used_min: 15, net_min: -10, buffer_min: 4}],
  fuel: {"thruster-fuel": 5000, "thruster-oxidizer": 6000},
  asteroids: {small: 10, medium: 3, big: 0, huge: 0}, repair_packs: 50};
const parked = {...p, platform: "Asterion", at: "nauvis", leg: null, speed_kms: 0};
const scene = {cameras: {main: {frame: {surface: "platform-16", position: {x: 0, y: 0}, zoom: .3, frac: .6576388889}}},
  space: {platforms: [{name: "Asterion", view: {surface: "platform-16", hull: {left: -6, top: -6, right: 8, bottom: 6}}}]}};
const mode = b => b["data-mode"];
{
  const {render, box} = page();
  render(box, null); assert(box.hidden);
  render(box, p, 0); assert.equal(mode(box), "compact"); // outer routes no longer force full
  assert(box._parts.header.textContent.includes("Resolute <b> · Solar System Edge → Shattered Planet"));
  assert(box._parts.details.hidden); assert(!box._parts.bar.hidden);
  render(box, {...p, featured: true}, 1); assert.equal(mode(box), "attempt");
  assert(box.textContent.includes("40 hub + guns") && box.textContent.includes("net -10") && box.textContent.includes("4 engaged"));
  const row = box._parts.combat._rows.get("kills_min");
  render(box, {...p, featured: true, kills_min: 140, ammo: [], asteroids: undefined, repair_packs: undefined}, 2);
  assert.equal(box._parts.combat._rows.get("kills_min"), row); assert.equal(row._value.textContent, "140");
  assert(box._parts.ammo.hidden && box._parts.rocks.hidden); assert(!box.textContent.includes("NaN"));
  render(box, {...p, featured: true, tick: 101}, 1000); assert.equal(mode(box), "attempt");
  render(box, {platform: "Bare"}, 1001); assert(!box.hidden); assert.equal(box._parts.header.textContent, "Bare · Dock unknown");
}
// Full docked telemetry is vertical, only after two clear samples. Work/scene changes collapse immediately.
{
  const {render, box, pane} = page();
  render(box, parked, 0, scene); assert.equal(mode(box), "docked-compact");
  render(box, parked, 1, scene); assert.equal(mode(box), "docked-compact"); // repaint isn't a second sample
  render(box, {...parked, tick: 101}, 20, scene); assert.equal(mode(box), "docked-full");
  assert.equal(box._parts.header.textContent, "Asterion · Docked at Nauvis");
  assert(box._parts.flight.hidden); assert(!box._parts.guns.hidden && !box._parts.supplies.hidden);
  const work = {...scene, cameras: {main: {...scene.cameras.main, work: "placing machinery"}}};
  render(box, {...parked, tick: 101}, 21, work); assert.equal(mode(box), "docked-compact");
  render(box, {...parked, tick: 101}, 22, scene); assert.equal(mode(box), "docked-compact");
  render(box, {...parked, tick: 102}, 40, scene); assert.equal(mode(box), "docked-compact");
  render(box, {...parked, tick: 103}, 60, scene); assert.equal(mode(box), "docked-full");
  const blocked = JSON.parse(JSON.stringify(scene)); blocked.space.platforms[0].view.hull.left = -100;
  render(box, {...parked, tick: 103}, 61, blocked); assert.equal(mode(box), "docked-compact");
  // A smaller real game pane cannot reuse the old clearance, nor can missing geometry.
  pane.rect = rect(24, 24, 1208, 680);
  render(box, {...parked, tick: 104}, 80, scene); assert.equal(mode(box), "docked-compact");
  render(box, {...parked, tick: 105}, 100, {}); assert.equal(mode(box), "docked-compact");
  assert.equal(box.style["--pm-top"], "14px");
  pane.rect = rect(24, 112, 1032, 883);
  render(box, {...parked, tick: 106}, 120, scene);
  render(box, {...parked, tick: 107}, 140, scene); assert.equal(mode(box), "docked-full");
  const invalid = JSON.parse(JSON.stringify(scene)); delete invalid.space.platforms[0].view.hull.left;
  render(box, {...parked, tick: 108}, 160, invalid); assert.equal(mode(box), "docked-compact");
}
// The gap is measured from the end of a beat, including when the next sample belongs to another ship.
{
  const {render, box} = page();
  render(box, p, 0); render(box, {...p, tick: 101, hits_min: 1}, 20);
  render(box, {...p, platform: "Petrel", tick: 102}, 30);
  render(box, {...p, platform: "Petrel", tick: 103, hits_min: 1}, 57); assert.equal(mode(box), "compact");
  render(box, {...p, platform: "Petrel", tick: 104, hits_min: 1}, 58); assert.equal(mode(box), "beat");
}
// A persistent big asteroid count is one event, rather than an automatic repeating full-card hold.
{
  const {render, box} = page(), rocks = {...p, asteroids: {...p.asteroids, big: 1}};
  render(box, p, 0); render(box, {...rocks, tick: 101}, 20);
  render(box, {...rocks, tick: 102}, 80); assert.equal(mode(box), "compact");
  render(box, {...p, tick: 103, kills_min: 900, damage_dealt_min: 90000}, 100); assert.equal(mode(box), "compact");
}
// Brief events expire without a new telemetry sample, do not extend, and have 30s between beats.
for (const signal of [{hits_min: 3}, {damage_taken: 40}, {asteroids: {...p.asteroids, big: 1}}, {asteroids: {...p.asteroids, huge: 1}}]) {
  const {render, box} = page();
  render(box, p, 0);
  const hot = {...p, ...signal, tick: 101};
  render(box, hot, 20); assert.equal(mode(box), "beat");
  const count = box.decisions;
  render(box, {...hot, age_s: 7}, 27); assert.equal(mode(box), "beat"); assert.equal(box.decisions, count + 1);
  render(box, {...hot, age_s: 8}, 28); assert.equal(mode(box), "compact");
  render(box, {...p, ...signal, tick: 102}, 40); assert.equal(mode(box), "compact");
  render(box, {...p, tick: 103}, 60); assert.equal(mode(box), "compact");
  render(box, {...p, ...signal, tick: 104}, 80); assert.equal(mode(box), "beat");
}
// Warnings survive beat collapse and one clean sample. Missing values never manufacture an all-clear.
{
  const {render, box} = page();
  render(box, p, 0); render(box, {...p, hits_min: 3, damage_taken: 9, tick: 101}, 20);
  render(box, {...p, hits_min: 3, damage_taken: 9, tick: 101, age_s: 8}, 28);
  assert.equal(mode(box), "compact"); assert(box._parts.warnings.textContent.includes("Damage taken 9"));
  render(box, {...p, tick: 102}, 40); assert(!box._parts.warnings.hidden);
  render(box, {...p, hits_min: undefined, damage_taken: undefined, tick: 103}, 60); assert(!box._parts.warnings.hidden);
  render(box, {...p, tick: 104}, 80); assert(box._parts.warnings.hidden);
  render(box, {...p, tick: 105, ammo: [{...p.ammo[0], buffer_min: .5}], fuel: {"thruster-fuel": 0},
    turrets: {"rocket-turret": {count: 8, empty: 1}}}, 100);
  assert.equal(mode(box), "compact");
  for (const text of ["0.5", "Fuel tanks empty", "Rocket Turret empty"]) assert(box._parts.warnings.textContent.includes(text), text);
}
// Attempts keep current warning values highlighted without duplicating them; held history remains visible.
{
  const {render, box} = page(), hot = {...p, featured: true, damage_taken: 182, hits_min: 6, fuel: {"thruster-fuel": 0}};
  render(box, hot, 0); assert.equal(mode(box), "attempt"); assert(box._parts.warnings.hidden);
  assert.equal(box._parts.combat._rows.get("damage_taken")._value.textContent, "182");
  assert(box._parts.combat._rows.get("hits_min").classList.contains("pm-bad"));
  assert(box._parts.supplies._rows.get("thruster-fuel").classList.contains("pm-bad"));
  render(box, {...p, featured: true, tick: 101}, 20);
  assert(box._parts.warnings.textContent.includes("Damage taken 182"));
  render(box, {...p, featured: true, tick: 102}, 40); assert(box._parts.warnings.hidden);
}
// Leg start, reversal, arrival and ship changes. Cooldown crosses legs; holds never cross ships/legs.
{
  const {render, box} = page();
  render(box, parked, 0, scene);
  render(box, {...p, platform: parked.platform, tick: 101}, 20, scene); assert.equal(mode(box), "beat");
  render(box, {...p, platform: parked.platform, tick: 102, leg: {...p.leg, back: true}}, 40, scene); assert.equal(mode(box), "compact");
  render(box, {...parked, tick: 103}, 60, scene); assert.equal(mode(box), "docked-beat");
  render(box, {...parked, tick: 103, age_s: 8}, 68, scene); assert.equal(mode(box), "docked-compact");
  render(box, {...p, platform: "Petrel", hits_min: 3, tick: 104}, 69, scene); assert.equal(mode(box), "compact");
  assert(box._parts.header.textContent.startsWith("Petrel ·"));
  render(box, {...p, tick: 1}, 70); assert.equal(mode(box), "compact");
}
// Scene away/back must not replay a cached beat; a page reload starts compact and retains current warnings/attempts.
{
  const {render, box} = page();
  render(box, p, 0); const hot = {...p, tick: 101, damage_taken: 20}; render(box, hot, 20);
  render(box, null, 22); assert(box.hidden);
  render(box, {...hot, age_s: 10}, 30); assert.equal(mode(box), "compact");
  const reload = page(); reload.render(reload.box, {...hot, age_s: 10}, 0);
  assert.equal(mode(reload.box), "compact"); assert(!reload.box._parts.warnings.hidden);
  reload.render(reload.box, {...hot, featured: true, age_s: 10}, 1); assert.equal(mode(reload.box), "attempt");
  const aged = page(); aged.render(aged.box, p, 0); aged.render(aged.box, {...hot, age_s: 10}, 20);
  assert.equal(mode(aged.box), "compact"); // don't replay an expired event on a late sample
}
// Caption clearance uses the visible band's bottom plus 8px, returns to 14px for lower/absent captions.
{
  const {render, box, elements} = page(), alert = new Element("div");
  alert.textContent = "Alert"; alert.rect = rect(24, 40, 600, 50); elements.alerts = alert;
  render(box, p, 0); assert.equal(box.style["--pm-top"], "72px");
  alert.rect = rect(24, 950, 600, 50); render(box, p, 1); assert.equal(box.style["--pm-top"], "14px");
  alert.rect = rect(600, 40, 100, 50); render(box, p, 2); assert.equal(box.style["--pm-top"], "14px");
}
console.log("platform metrics DOM: identity, anchored geometry, dock/work hysteresis, beats/gaps, warnings, attempts, scenes, reload and leg/ship isolation passed");
