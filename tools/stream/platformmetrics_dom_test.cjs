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
function page(storage = new Map(), epoch = 0) {
  let time = 0, serial = 0;
  const timers = new Map();
  const window = {localStorage: {getItem: key => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, value)},
    setTimeout: (cb, ms) => { timers.set(++serial, {cb, at: time + ms / 1000}); return serial; },
    clearTimeout: id => timers.delete(id)};
  const elements = {}, document = {createElement: tag => new Element(tag), getElementById: id => elements[id], querySelectorAll: () => elements.alerts ? [elements.alerts] : []};
  vm.runInNewContext(source, {window, document, Date: {now: () => (1700000000 + epoch + time) * 1000}, performance: {now: () => time * 1000}});
  const pane = new Element("div"), box = new Element("section"); pane.rect = rect(24, 24, 1208, 1032); pane.append(box);
  return {render: (box, p, now = time, scene) => { time = now; window.PogPlatformMetrics.render(box, p, now, scene); }, box, pane, elements, storage,
    advance: now => { time = now; for (const [id, timer] of timers) if (timer.at <= now) {timers.delete(id); timer.cb();} }};
}
const p = {platform: "Resolute <b>", featured: false, tick: 100, age_s: 0, speed_kms: 120, eta_wall_s: 3600,
  leg: {from: "solar-system-edge", to: "shattered-planet", pct: 20, flown_km: 800000, left_km: 3200000},
  kills_min: 120, hits_min: 0, window_s: 20, damage_taken: 0, losses_leg: 0,
  turrets: {"rocket-turret": {count: 8, targeting: 4, empty: 0}},
  ammo: [{name: "rocket", hub: 30, turrets: 10, made_min: 5, used_min: 15, net_min: -10, buffer_min: 4}],
  fuel: {"thruster-fuel": 5000, "thruster-oxidizer": 6000},
  asteroids: {small: 10, medium: 3, big: 0, huge: 0}, repair_packs: 50};
const parked = {...p, platform: "Asterion", at: "nauvis", leg: null, speed_kms: 0};
const scene = {cameras: {main: {ship: {name: "Asterion"}, frame: {surface: "platform-16", position: {x: 0, y: 0}, zoom: .3, frac: .6576388889}}},
  space: {platforms: [{name: "Asterion", view: {surface: "platform-16", hull: {left: -6, top: -6, right: 8, bottom: 6}}}]}};
const mode = b => b["data-mode"];
// A failed OBS receipt removes main while a previous telemetry sample may still be cached.
// Neither the current page nor a reload may resurrect that sample without a visible ship.
for (const cameras of [{}, {main: null}, {main: {agents: []}}]) {
  const first = page();
  first.render(first.box, parked, 0, scene); assert(!first.box.hidden);
  first.render(first.box, parked, 1, {cameras}); assert(first.box.hidden);
  const reloaded = page(first.storage);
  reloaded.render(reloaded.box, parked, 2, {cameras}); assert(reloaded.box.hidden);
  reloaded.render(reloaded.box, parked, 3, scene); assert(!reloaded.box.hidden);
}
{
  const {render, box} = page();
  render(box, null); assert(box.hidden);
  render(box, p, 0); assert.equal(mode(box), "compact"); // outer routes no longer force full
  assert(box._parts.header.textContent.includes("Resolute <b> · Solar System Edge → Shattered Planet"));
  assert(box._parts.details.hidden); assert(!box._parts.bar.hidden);
  render(box, {...p, featured: true}, 1); assert.equal(mode(box), "compact");
  assert(box.textContent.includes("40 hub + guns") && box.textContent.includes("net -10") && box.textContent.includes("4 engaged"));
  const row = box._parts.combat._rows.get("kills_min");
  render(box, {...p, featured: true, kills_min: 140, ammo: [], asteroids: undefined, repair_packs: undefined}, 2);
  assert.equal(box._parts.combat._rows.get("kills_min"), row); assert.equal(row._value.textContent, "140");
  assert(box._parts.ammo.hidden && box._parts.rocks.hidden); assert(!box.textContent.includes("NaN"));
  render(box, {...p, featured: true, tick: 101}, 1000); assert.equal(mode(box), "beat");
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
// Non-featured four-second beats have 150 seconds after their end, across ships and page reloads.
for (const featured of [false]) {
  const store = new Map(), first = page(store), {render, box} = first;
  const flight = {...p, featured}, rocks = {...flight, asteroids: {...p.asteroids, big: 1}};
  render(box, flight, 0); render(box, {...rocks, tick: 101}, 20);
  assert.equal(mode(box), "beat");
  render(box, {...rocks, tick: 101, age_s: 3}, 23); assert.equal(mode(box), "beat");
  first.advance(24.01); assert.equal(mode(box), "compact"); // timer, without new telemetry
  render(box, {...flight, platform: "Petrel", tick: 102}, 30);
  render(box, {...rocks, platform: "Petrel", tick: 103}, 173); assert.equal(mode(box), "compact");
  render(box, {...flight, platform: "Petrel", tick: 104}, 173.5);
  render(box, {...rocks, platform: "Petrel", tick: 105}, 174); assert.equal(mode(box), "beat");
  const reload = page(store, 175);
  reload.render(reload.box, rocks, 0); assert.equal(mode(reload.box), "compact");
  reload.render(reload.box, {...flight, tick: 106}, 1);
  reload.render(reload.box, {...rocks, tick: 107}, 20); assert.equal(mode(reload.box), "compact");
  reload.render(reload.box, {...flight, tick: 108}, 152);
  reload.render(reload.box, {...rocks, tick: 109}, 153); assert.equal(mode(reload.box), "beat");
}
// Featured attempts open regularly without an event: 12 seconds on, 48 off, one shared page budget.
{
  const store = new Map(), first = page(store), flight = {...p, featured: true};
  const {render, box} = first;
  render(box, flight, 0); assert.equal(mode(box), "compact"); // cold baseline
  render(box, {...flight, tick: 101}, 20); assert.equal(mode(box), "beat");
  render(box, {...flight, tick: 101, age_s: 11}, 31); assert.equal(mode(box), "beat");
  first.advance(32.01); assert.equal(mode(box), "compact");
  render(box, {...flight, tick: 102}, 40); assert.equal(mode(box), "compact");
  render(box, {...flight, tick: 103}, 60); assert.equal(mode(box), "compact");
  const portrait = page(store, 60);
  portrait.render(portrait.box, flight, 0);
  portrait.render(portrait.box, {...flight, tick: 104}, 19); assert.equal(mode(portrait.box), "compact");
  render(box, {...flight, tick: 104}, 80); assert.equal(mode(box), "beat");
  portrait.render(portrait.box, {...flight, tick: 105}, 20); assert.equal(mode(portrait.box), "compact");
  const reload = page(store, 81);
  reload.render(reload.box, {...flight, tick: 104}, 0); assert.equal(mode(reload.box), "compact");
  // Switching to non-featured cannot evade the reservation, and its next beat reserves the normal 154s.
  render(box, {...p, tick: 105}, 100);
  render(box, {...p, tick: 106, asteroids: {...p.asteroids, huge: 1}}, 139); assert.equal(mode(box), "compact");
  render(box, {...p, tick: 107, asteroids: {...p.asteroids, huge: 2}}, 140); assert.equal(mode(box), "beat");
  render(box, {...flight, tick: 108}, 160); assert.equal(mode(box), "compact");
  render(box, {...flight, tick: 109}, 294); assert.equal(mode(box), "beat");
}
// Periodic beats need fresh telemetry, yield to caption collisions and do not resume after a cut.
{
  const {render, box, elements} = page(), flight = {...p, featured: true};
  render(box, flight, 0);
  render(box, {...flight, tick: 101, age_s: 5}, 20); assert.equal(mode(box), "compact");
  render(box, {...flight, tick: 102}, 40); assert.equal(mode(box), "beat");
  render(box, flight, 41, {cameras: {}}); assert(box.hidden);
  render(box, {...flight, tick: 102}, 42); assert.equal(mode(box), "compact");
  const alert = new Element("div"); alert.textContent = "Caption";
  alert.rect = rect(24, 500, 600, 50); elements.alerts = alert;
  render(box, {...flight, tick: 103}, 100); assert.equal(mode(box), "compact");
  delete elements.alerts;
  render(box, {...flight, tick: 103}, 101); assert.equal(mode(box), "compact");
}
// A persistent asteroid count and high outgoing damage are not repeating detail triggers.
{
  const {render, box} = page(), rocks = {...p, asteroids: {...p.asteroids, big: 1}};
  render(box, p, 0); render(box, {...rocks, tick: 101}, 20);
  render(box, {...rocks, tick: 102}, 180); assert.equal(mode(box), "compact");
  render(box, {...p, tick: 103, kills_min: 900, damage_dealt_min: 90000}, 200); assert.equal(mode(box), "compact");
}
// Alerts stay compact, even during a beat and a featured attempt. Held warnings retain their clean-sample rule.
for (const featured of [false, true]) {
  const {render, box} = page(), flight = {...p, featured};
  render(box, flight, 0);
  render(box, {...flight, tick: 101, asteroids: {...p.asteroids, huge: 1}}, 20);
  assert.equal(mode(box), "beat");
  render(box, {...flight, hits_min: 3, damage_taken: 9, tick: 102}, 21);
  assert.equal(mode(box), "compact"); assert(box._parts.warnings.textContent.includes("Damage taken 9"));
  render(box, {...flight, tick: 103}, 40); assert(!box._parts.warnings.hidden);
  render(box, {...flight, hits_min: undefined, damage_taken: undefined, tick: 104}, 60); assert(!box._parts.warnings.hidden);
  render(box, {...flight, tick: 105}, 80); assert(box._parts.warnings.hidden);
  render(box, {...flight, tick: 106, hits_min: 4, damage_taken: 20, losses_leg: 2,
    ammo: [{...p.ammo[0], buffer_min: .5}], fuel: {"thruster-fuel": 0, "thruster-oxidizer": 0},
    turrets: {"rocket-turret": {count: 8, empty: 1}}}, 200);
  assert.equal(mode(box), "compact"); assert.equal(box._parts.warnings._rows.size, 3);
  assert(box._parts.warnings.textContent.includes("Other alerts +5"));
  for (const text of ["0.5", "Fuel tanks empty", "Rocket Turret empty", "Lost this leg: 2"])
    assert(box._parts.warnings.title.includes(text), text);
}
// Closeups immediately interrupt a beat, and never queue one for the next camera cut.
const detailShots = [
  {platform: {why: "bow"}}, {platform: {why: "danger"}}, {platform: {why: "work"}},
  ...["bow guns", "guns in action", "working production", "repair/build detail"]
    .map(framing => ({platform: {why: "featured", framing}})),
  {platform: {why: "visit", label: "Resolute · bow defense"}},
  {work: "placing machines"}, {attention: {}}, {work_close: {}}, {frame: {follow: 3}},
  {attack: "Incoming"}, {alert: "loss"}, {battle: "battle"}, {fight: {}}, {follow: "Sol"}
];
for (const shot of detailShots) {
  const {render, box} = page(), flight = {...p, featured: true};
  const close = {cameras: {main: {...shot, ship: {name: p.platform}}}};
  render(box, flight, 0);
  render(box, {...flight, tick: 101, asteroids: {...p.asteroids, big: 1}}, 20); assert.equal(mode(box), "beat");
  render(box, {...flight, tick: 101}, 21, close); assert.equal(mode(box), "compact");
  render(box, {...flight, tick: 101}, 22); assert.equal(mode(box), "compact");
  render(box, {...flight, tick: 102, asteroids: {...p.asteroids, huge: 2}}, 180, close);
  assert.equal(mode(box), "compact");
  render(box, {...flight, tick: 102}, 181); assert.equal(mode(box), "compact");
  render(box, {...parked, tick: 103}, 200, { ...scene, cameras: {main: {...scene.cameras.main, ...shot}}});
  render(box, {...parked, tick: 104}, 220, { ...scene, cameras: {main: {...scene.cameras.main, ...shot}}});
  assert.equal(mode(box), "docked-compact");
}
// The actual featured flight cycle must have an eligible shot. Generic "bow" filtering used to block all of it.
{
  const flight = {...p, featured: true};
  const main = {ship: {name: p.platform}, platform: {why: "featured", framing: "bow and approaching asteroids",
    label: "Featured: Resolute · bow and approaching asteroids"}};
  const orientation = {cameras: {main}};
  const {render, box, advance} = page();
  render(box, flight, 0, orientation);
  render(box, {...flight, tick: 101}, 20, orientation); assert.equal(mode(box), "beat"); // no event
  advance(31.99); assert.equal(mode(box), "beat");
  advance(32.01); assert.equal(mode(box), "compact");
  render(box, {...flight, tick: 102}, 40, orientation); assert.equal(mode(box), "compact");
  render(box, {...flight, tick: 103}, 60, orientation); assert.equal(mode(box), "compact");
  render(box, {...flight, tick: 104}, 80, orientation); assert.equal(mode(box), "beat");
  const guns = {cameras: {main: {...main, platform: {...main.platform, framing: "guns in action"}}}};
  render(box, {...flight, tick: 104}, 81, guns); assert.equal(mode(box), "compact");
  render(box, {...flight, tick: 104}, 82, orientation); assert.equal(mode(box), "compact");
  // The exception is narrowly scoped to featured orientation, never work/alerts or non-featured bow shots.
  for (const extra of [{work: "repair"}, {attention: {}}, {attack: "incoming"}, {alert: "loss"},
                       {battle: "battle"}, {follow: "Sol"}, {frame: {follow: 3}}]) {
    const q = page(), scene = {cameras: {main: {...main, ...extra}}};
    q.render(q.box, flight, 0, scene);
    q.render(q.box, {...flight, tick: 101}, 20, scene); assert.equal(mode(q.box), "compact");
  }
  for (const featured of [false, true]) {
    const q = page(), scene = {cameras: {main: {...main, platform: {...main.platform, why: featured ? "bow" : "featured"}}}};
    q.render(q.box, {...flight, featured}, 0, scene);
    q.render(q.box, {...flight, featured, tick: 101, asteroids: {...p.asteroids, huge: 1}}, 20, scene);
    assert.equal(mode(q.box), "compact");
  }
  const q = page(); q.render(q.box, flight, 0, orientation);
  q.render(q.box, {...flight, tick: 101, hits_min: 3}, 20, orientation); assert.equal(mode(q.box), "compact");
}
// Leg start, reversal and arrival retain the gap. Parked details still require actual clearance.
{
  const {render, box} = page();
  render(box, parked, 0, scene);
  render(box, {...p, platform: parked.platform, tick: 101}, 20, scene); assert.equal(mode(box), "beat");
  render(box, {...p, platform: parked.platform, tick: 102, leg: {...p.leg, back: true}}, 40, scene); assert.equal(mode(box), "compact");
  render(box, {...parked, tick: 103}, 60, scene); assert.equal(mode(box), "docked-compact");
  render(box, {...parked, tick: 104}, 80, scene); assert.equal(mode(box), "docked-full");
  render(box, {...parked, tick: 105}, 300, scene); assert.equal(mode(box), "docked-full");
  render(box, {...p, tick: 1}, 301); assert.equal(mode(box), "compact"); // new ship/tick reset is a baseline
}
// Camera gaps cancel a beat; reload restores only the deadline, never the full card.
{
  const first = page(), {render, box} = first, hot = {...p, tick: 101, asteroids: {...p.asteroids, huge: 1}};
  render(box, p, 0); render(box, hot, 20); assert.equal(mode(box), "beat");
  render(box, null, 21); assert(box.hidden);
  render(box, {...hot, age_s: 2}, 22); assert.equal(mode(box), "compact");
  const reload = page(first.storage, 23); reload.render(reload.box, {...hot, featured: true, age_s: 3}, 0);
  assert.equal(mode(reload.box), "compact");
  reload.render(reload.box, {...p, tick: 102}, 1);
  reload.render(reload.box, {...hot, tick: 103}, 20); assert.equal(mode(reload.box), "compact");
  const aged = page(); aged.render(aged.box, p, 0); aged.render(aged.box, {...hot, age_s: 5}, 20);
  assert.equal(mode(aged.box), "compact"); // don't replay an expired event on a late sample
}
// Blocked storage fails compact; corrupt/future state and backwards clocks establish a conservative gap.
for (const store of [
  {get: () => {throw Error("denied");}, set: () => {}},
  {get: () => undefined, set: () => {throw Error("quota");}},
  new Map([["pog:platform-metrics:next-detail:v1", "broken"]]),
  new Map([["pog:platform-metrics:next-detail:v1", String(1700009999)]])
]) {
  const {render, box} = page(store);
  render(box, p, 0); render(box, {...p, tick: 101, asteroids: {...p.asteroids, big: 1}}, 20);
  assert.equal(mode(box), "compact");
}
// A fresh but delayed sample from inside the gap cannot replay just after the gap expires.
{
  const {render, box} = page();
  render(box, p, 0); render(box, {...p, tick: 101, asteroids: {...p.asteroids, huge: 1}}, 20);
  render(box, {...p, tick: 102}, 160);
  render(box, {...p, tick: 103, age_s: 2, asteroids: {...p.asteroids, huge: 1}}, 175);
  assert.equal(mode(box), "compact");
}
// A delayed event either gets three readable seconds or is discarded, never a subsecond flash.
for (const age of [1, 1.1, 3.9, 4]) {
  const {render, box, advance} = page();
  render(box, p, 0);
  render(box, {...p, tick: 101, age_s: age, asteroids: {...p.asteroids, huge: 1}}, 20);
  assert.equal(mode(box), age <= 1 ? "beat" : "compact");
  if (age <= 1) {
    advance(22.99); assert.equal(mode(box), "beat");
    advance(23.01); assert.equal(mode(box), "compact");
  }
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

// Real featured-director public snapshots supplied by test_featured.py, not hand-written framing labels.
if (process.argv.includes("--featured-scenes")) {
  const snapshots = JSON.parse(fs.readFileSync(0, "utf8"));
  assert(snapshots.length > 0);
  for (const scene of snapshots) {
    const {render, box} = page(), flight = {...p, platform: "Resolute", featured: true};
    render(box, flight, 0, scene);
    render(box, {...flight, tick: 101}, 20, scene); // real orientation must open without an event
    const orientation = scene.cameras.main.platform.framing === "bow and approaching asteroids";
    assert.equal(mode(box), orientation ? "beat" : "compact", JSON.stringify(scene.cameras.main.platform));
    assert.equal(box._parts.details.hidden, !orientation);
    assert(box._parts.summary.textContent.includes("120 km/s"));
    assert(box._parts.summary.textContent.includes("20% flown"));
  }
  console.log("real featured director shots: orientation permits details; gun/work closeups stay compact");
}
