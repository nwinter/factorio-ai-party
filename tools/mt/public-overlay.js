'use strict';
/* The Factory Race: the team tests' broadcast overlay (mt294). One 1920x1080 canvas over the game camera.
 *
 * Canvas only (mt288: DOM text vanished in OBS after about a minute). Targets OBS's browser source (CEF, Chrome 103+).
 * Look: factory-floor signage. Gunmetal plates with cut corners and bevels, hazard stripes, a conveyor belt for
 * news, enamel team colours, cream stencil lettering (Big Shoulders Display) over the game's own interface face
 * (Titillium Web). Every agent appears with its own portrait, name and colour inside its team's colour.
 *
 * Reads only /state.json (public_race.project and friends). Nothing here invents a value: missing data is not drawn.
 */
const canvas = document.getElementById('race'), ctx = canvas.getContext('2d');
const W = 1920, H = 1080, M = 16;
const Q = new URLSearchParams(location.search);
const C = {void0: '#191817', void1: '#100f0f', plate: '#2c2a29', plate2: '#232221', raised: '#3a3836', well: '#171615',
  seam: '#4b4744', ink: '#f6ecd9', text: '#e9e3d9', muted: '#aea699', dim: '#7b746a', dark: '#141312',
  amber: '#ffb224', hazard: '#f6c315', gold: '#ffd66b', red: '#ff5a48', green: '#6ad36f', cyan: '#56c8ee'};
const TEAM = {green: '#58d36c', yellow: '#ffcc33', blue: '#4da6ff', red: '#ff5f4f', purple: '#b78aff',
  orange: '#ff9a3c', cyan: '#33d1c1', pink: '#ff7eb6', white: '#e9e4da'};
const SPARE = ['#b78aff', '#ff9a3c', '#33d1c1', '#ff7eb6', '#c0d04a', '#9aa7ff'];
const FAM = {disp: '"Big Shoulders Display","Arial Narrow","Segoe UI",sans-serif', ui: '"Titillium Web","Segoe UI",system-ui,sans-serif'};
const LAMP = {acting: C.green, thinking: C.amber, idle: C.dim, resting: C.dim, offline: C.red, dead: C.red};
const STARTUP = ['burner-mining-drill', 'stone-furnace', 'steam-engine', 'lab', 'assembling-machine-1'];
const FACTORY = [['burner-mining-drill', 'electric-mining-drill'], ['stone-furnace', 'steel-furnace', 'electric-furnace'],
  ['assembling-machine-1', 'assembling-machine-2', 'assembling-machine-3'], ['lab', 'biolab']];
const CREDIT_S = 14, CREDIT_EVERY = 3600;  // the Wube credit: at the start of a clip, then briefly once an hour

let state = {teams: [], events: [], feed: [], viewers: [], now: 0}, lost = false, loaded = Date.now() / 1000, shift = 0;
let R = rects([16, 188, 1408, 792]);
function rects(cam) {
  const [x, y, w, h] = cam, railX = x + w + M;
  return {cam: {x, y, w, h}, strip: {x: M, y: M, w: W - 2 * M, h: y - M - 8},
    rail: {x: railX, y, w: W - M - railX, h}, band: {x: M, y: y + h + 8, w: W - 2 * M, h: H - M - (y + h + 8)}};
}

// ---- small maths, colour -------------------------------------------------------------------------------------
const clamp = (v, a, b) => Math.max(a, Math.min(b, v)), lerp = (a, b, k) => a + (b - a) * k;
const outCubic = k => 1 - Math.pow(1 - k, 3), outBack = k => 1 + 2.2 * Math.pow(k - 1, 3) + 1.2 * Math.pow(k - 1, 2);
const cap = s => String(s || '').replace(/-/g, ' ').replace(/^./, c => c.toUpperCase());
function hash(s) { let h = 2166136261; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } return h >>> 0; }
const rgbOf = h => [parseInt(h.slice(1, 3), 16), parseInt(h.slice(3, 5), 16), parseInt(h.slice(5, 7), 16)];
const memo = new Map();
function keep(key, make) { let v = memo.get(key); if (v === undefined) { v = make(); if (memo.size > 6000) memo.clear(); memo.set(key, v); } return v; }
function mix(a, b, k) { return keep('m' + a + b + k, () => { const p = rgbOf(a), q = rgbOf(b); return '#' + p.map((v, i) => Math.round(lerp(v, q[i], k)).toString(16).padStart(2, '0')).join(''); }); }
// alpha in steps of 1/50: an animated fade must not mint a new cache entry every frame
function fade(hex, a) { a = Math.round(a * 50) / 50; return keep('a' + hex + a, () => { const p = rgbOf(hex); return `rgba(${p[0]},${p[1]},${p[2]},${a})`; }); }
const luma = hex => { const p = rgbOf(hex); return (p[0] * 299 + p[1] * 587 + p[2] * 114) / 255000; };
function turn(hex, deg, light) {  // hue-rotate a colour; teammates without a colour of their own get neighbours of the team's
  return keep('t' + hex + deg + light, () => {
    let [r, g, b] = rgbOf(hex).map(v => v / 255); const max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min;
    let h = 0, l = (max + min) / 2; const s = d ? d / (1 - Math.abs(2 * l - 1)) : 0;
    if (d) h = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
    h = ((h * 60 + deg) % 360 + 360) % 360; l = clamp(l + light, .2, .82);
    const c = (1 - Math.abs(2 * l - 1)) * s, x = c * (1 - Math.abs((h / 60) % 2 - 1)), m = l - c / 2;
    const v = h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : h < 180 ? [0, c, x] : h < 240 ? [0, x, c] : h < 300 ? [x, 0, c] : [c, 0, x];
    return '#' + v.map(n => Math.round((n + m) * 255).toString(16).padStart(2, '0')).join('');
  });
}
const teamColor = t => TEAM[t] || SPARE[hash(String(t)) % SPARE.length];
const bright = hex => luma(hex) < .42 ? mix(hex, '#ffffff', .45) : hex;  // readable on dark plates
function agentColor(a, team, index) {
  return /^#[0-9a-f]{6}$/i.test(a.color || '') ? a.color.toLowerCase() : turn(teamColor(team), [0, 34, -34, 68, -68][index % 5], index % 2 ? .06 : 0);
}

// ---- time and animation ----------------------------------------------------------------------------------------
const T = () => performance.now() / 1000 + shift;
const tweens = new Map(); let busyUntil = 0, settled = false;
const busy = until => { if (until > busyUntil) busyUntil = until; };
function tween(key, target, dur = .45, ease = outCubic) {
  const t = T(); let a = tweens.get(key);
  if (!a) { a = {from: target, to: target, t0: t - dur, dur, ease}; tweens.set(key, a); }
  if (a.to !== target) { a.from = at(a, t); a.to = target; a.t0 = settled ? t - dur : t; a.dur = dur; a.ease = ease; }
  a.seen = t; if (t < a.t0 + a.dur) busy(a.t0 + a.dur);
  return at(a, t);
}
function at(a, t) { return a.from + (a.to - a.from) * a.ease(clamp((t - a.t0) / a.dur, 0, 1)); }
function start(key, from, to, dur, ease = outCubic) { tweens.set(key, {from, to, t0: settled ? T() - dur : T(), dur, ease, seen: T()}); busy(T() + dur); }
function prune() { const t = T(); for (const [k, a] of tweens) if (t - a.seen > 30) tweens.delete(k); }

// ---- text ----------------------------------------------------------------------------------------------------------
const font = (px, weight = 600, fam = 'ui', italic = false) => `${italic ? 'italic ' : ''}${weight} ${px}px ${FAM[fam]}`;
let fontNow = '', spacingNow = 0;
function use(f, ls = 0) {
  if (fontNow !== f) { ctx.font = f; fontNow = f; }
  if (spacingNow !== ls && 'letterSpacing' in ctx) { ctx.letterSpacing = ls + 'px'; spacingNow = ls; }
}
// save/restore also restores the canvas font, so the cached font is forgotten on every pop
function pop() { ctx.restore(); fontNow = ''; spacingNow = -1; }
function width(s, f, ls = 0) { return keep('w' + f + ls + '|' + s, () => { use(f, ls); return ctx.measureText(s).width; }); }
function fit(s, f, max, ls = 0) {
  s = String(s == null ? '' : s);
  if (max <= 0) return '';
  if (width(s, f, ls) <= max) return s;
  return keep('f' + f + ls + '|' + max + '|' + s, () => {
    let lo = 0, hi = s.length;
    while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (width(s.slice(0, mid).trimEnd() + '…', f, ls) <= max) lo = mid; else hi = mid - 1; }
    return lo ? s.slice(0, lo).trimEnd() + '…' : '';
  });
}
function wrap(s, f, max, lines) {  // -> up to `lines` strings; the last ends with … when text remains
  return keep('r' + f + '|' + max + '|' + lines + '|' + s, () => {
    const words = String(s || '').split(/\s+/).filter(Boolean), out = []; let cur = '';
    for (let i = 0; i < words.length; i++) {
      let word = words[i];
      while (width(word, f) > max && word.length > 1) {  // one unbroken run wider than the line (a long id or number)
        let n = word.length; while (n > 1 && width((cur ? cur + ' ' : '') + word.slice(0, n), f) > max) n--;
        if (n <= 1 && cur) { out.push(cur); cur = ''; continue; }
        out.push((cur ? cur + ' ' : '') + word.slice(0, n)); cur = ''; word = word.slice(n);
      }
      const next = cur ? cur + ' ' + word : word;
      if (width(next, f) > max && cur) { out.push(cur); cur = word; } else cur = next;
    }
    if (cur) out.push(cur);
    if (out.length > lines) { const last = out.slice(lines - 1).join(' '); out.length = lines; out[lines - 1] = fit(last, f, max); }
    return out;
  });
}
function text(s, x, y, f, color, o = {}) {
  s = String(s == null ? '' : s); if (!s) return 0;
  const ls = o.ls || 0; use(f, ls); ctx.fillStyle = color;
  const w = o.align ? width(s, f, ls) : 0;
  ctx.fillText(s, o.align === 'right' ? x - w : o.align === 'center' ? x - w / 2 : x, y);
  return o.align ? w : width(s, f, ls);
}

// ---- shapes -----------------------------------------------------------------------------------------------------
function cutPath(x, y, w, h, c, corners = 'tl,br') {
  const tl = corners.includes('tl') ? c : 0, tr = corners.includes('tr') ? c : 0, br = corners.includes('br') ? c : 0, bl = corners.includes('bl') ? c : 0;
  ctx.beginPath(); ctx.moveTo(x + tl, y); ctx.lineTo(x + w - tr, y); ctx.lineTo(x + w, y + tr); ctx.lineTo(x + w, y + h - br);
  ctx.lineTo(x + w - br, y + h); ctx.lineTo(x + bl, y + h); ctx.lineTo(x, y + h - bl); ctx.lineTo(x, y + tl); ctx.closePath();
}
function plate(x, y, w, h, o = {}) {
  const c = o.cut == null ? 10 : o.cut;
  cutPath(x, y, w, h, c, o.corners);
  if (o.fill !== null) {
    const g = ctx.createLinearGradient(0, y, 0, y + h); g.addColorStop(0, o.fill || C.plate); g.addColorStop(1, o.fill2 || o.fill || C.plate2);
    ctx.fillStyle = g; ctx.fill();
  }
  if (o.bevel !== false) {  // light from the upper left, as the game's own frames
    cutPath(x + .75, y + .75, w - 1.5, h - 1.5, c, o.corners);
    const g = ctx.createLinearGradient(x, y, x + Math.min(w, 2 * h), y + h); g.addColorStop(0, 'rgba(255,255,255,.16)'); g.addColorStop(.5, 'rgba(255,255,255,.03)'); g.addColorStop(1, 'rgba(0,0,0,.6)');
    ctx.strokeStyle = g; ctx.lineWidth = 1.5; ctx.stroke();
  }
}
function box(x, y, w, h, color) { ctx.fillStyle = color; ctx.fillRect(x, y, w, h); }
function well(x, y, w, h) { box(x, y, w, h, C.well); box(x, y, w, 1.5, 'rgba(0,0,0,.7)'); box(x, y + h - 1, w, 1, 'rgba(255,255,255,.07)'); }
let hazardFill = null, treadFill = null;
function patterns() {
  const hz = document.createElement('canvas'); hz.width = hz.height = 24; const a = hz.getContext('2d');
  a.fillStyle = C.hazard; a.fillRect(0, 0, 24, 24); a.fillStyle = '#17150f';
  for (const dx of [-24, 0, 24]) { a.beginPath(); a.moveTo(dx, 24); a.lineTo(dx + 12, 24); a.lineTo(dx + 36, 0); a.lineTo(dx + 24, 0); a.closePath(); a.fill(); }
  hazardFill = ctx.createPattern(hz, 'repeat');
  const td = document.createElement('canvas'); td.width = td.height = 36; const b = td.getContext('2d');
  b.strokeStyle = 'rgba(255,255,255,.022)'; b.lineWidth = 2;
  for (const dx of [-36, 0, 36]) { b.beginPath(); b.moveTo(dx, 36); b.lineTo(dx + 36, 0); b.stroke(); }
  treadFill = ctx.createPattern(td, 'repeat');
}
function hazard(x, y, w, h, alpha = 1) { ctx.save(); ctx.globalAlpha *= alpha; ctx.fillStyle = hazardFill; ctx.fillRect(x, y, w, h); pop(); }
function tag(s, x, y, color, o = {}) {  // a skewed stencil label; returns its width
  const f = font(o.size || 12, 700), ls = 1, tw = width(s, f, ls), h = o.h || 20, w = tw + 18, k = 5;
  ctx.beginPath(); ctx.moveTo(x + k, y); ctx.lineTo(x + w, y); ctx.lineTo(x + w - k, y + h); ctx.lineTo(x, y + h); ctx.closePath();
  ctx.fillStyle = o.solid ? color : fade(color, .16); ctx.fill();
  text(s, x + 9, y + h - (h - (o.size || 12)) / 2 - 2, f, o.solid ? (o.ink || C.dark) : color, {ls});
  return w;
}
function padlock(x, y, color) {  // 10 x 12: this line stays inside its team
  ctx.strokeStyle = color; ctx.lineWidth = 1.6; ctx.beginPath(); ctx.arc(x + 5, y + 4.5, 3, Math.PI, 0); ctx.lineTo(x + 8, y + 6); ctx.moveTo(x + 2, y + 4.5); ctx.lineTo(x + 2, y + 6); ctx.stroke();
  box(x, y + 5.5, 10, 6.5, color);
}
function lamp(x, y, r, color, pulse) {
  if (pulse) { const k = .5 + .5 * Math.sin(T() * 4.2); ctx.beginPath(); ctx.arc(x, y, r + 2 + 3 * k, 0, 7); ctx.fillStyle = fade(color, .28 * (1 - k)); ctx.fill(); }
  ctx.beginPath(); ctx.arc(x, y, r, 0, 7); ctx.fillStyle = color; ctx.fill();
  ctx.strokeStyle = 'rgba(0,0,0,.75)'; ctx.lineWidth = 1.5; ctx.stroke();
}
function belt(x, y, w, h, color, k, moving) {  // a progress bar that runs like a transport belt
  well(x, y, w, h); if (!(k > 0)) return;
  const fw = Math.max(3, w * clamp(k, 0, 1));
  ctx.save(); ctx.beginPath(); ctx.rect(x, y, fw, h); ctx.clip();
  box(x, y, fw, h, color); ctx.fillStyle = 'rgba(0,0,0,.22)';
  const off = moving ? (T() * 22) % 16 : 0;
  for (let px = x - 16 + off; px < x + fw + h; px += 16) { ctx.beginPath(); ctx.moveTo(px, y + h); ctx.lineTo(px + h, y); ctx.lineTo(px + h + 7, y); ctx.lineTo(px + 7, y + h); ctx.closePath(); ctx.fill(); }
  box(x, y, fw, 1.5, 'rgba(255,255,255,.3)'); pop();
}

// ---- pictures: game icons, agent portraits ---------------------------------------------------------------------
const imgs = new Map();
function icon(kind, name, x, y, size) {
  if (!name) return false; const url = `/static/game/${kind}/${name}.webp`;
  if (!imgs.has(url)) { const im = new Image(); im.onload = () => kick(); im.onerror = () => imgs.set(url, null); imgs.set(url, im); im.src = url; }
  const im = imgs.get(url); if (im && im.complete && im.naturalWidth) { ctx.drawImage(im, x, y, size, size); return true; }
  return false;
}
function slot(kind, name, x, y, size) { well(x, y, size, size); icon(kind, name, x + 3, y + 3, size - 6); }
const faces = new Map();
function face(a, color) {  // the main stream's pixel portraits: parts the agent chose, else from its name
  const key = a.name + color + JSON.stringify(a.avatar || 0);
  if (!faces.has(key)) {
    const c = document.createElement('canvas'); c.width = c.height = 24; const g = c.getContext('2d');
    try {
      const px = PogAvatar.pixels({name: a.name, color, avatar: a.avatar || undefined});
      for (let y = 0; y < 24; y++) for (let x = 0; x < 24; x++) if (px[y][x]) { g.fillStyle = px[y][x]; g.fillRect(x, y, 1, 1); }
    } catch (e) { g.fillStyle = color; g.fillRect(0, 0, 24, 24); }
    faces.set(key, c);
  }
  return faces.get(key);
}
function portrait(a, x, y, size, ring) {
  const was = ctx.imageSmoothingEnabled; ctx.imageSmoothingEnabled = false;
  ctx.drawImage(face(a, a.tone), x, y, size, size); ctx.imageSmoothingEnabled = was;
  const lw = size >= 64 ? 3 : 2; ctx.strokeStyle = ring; ctx.lineWidth = lw; ctx.strokeRect(x + lw / 2, y + lw / 2, size - lw, size - lw);
  ctx.strokeStyle = 'rgba(0,0,0,.75)'; ctx.lineWidth = 1; ctx.strokeRect(x - .5, y - .5, size + 1, size + 1);
}

// ---- model: what the state says, indexed for drawing ----------------------------------------------------------
let model = {order: [], agents: new Map(), teams: new Map(), cam: null};
const said = new Map();  // agent key -> when its latest line appeared on the feed
const flashed = new Map();  // team -> when it last made news
const who = (team, name) => model.agents.get(team + '/' + name);
function statusOf(a, t) {
  if (t.stale) return {word: 'DELAYED', color: C.amber};
  if (t.paused) return {word: 'PAUSED', color: C.amber};
  if (!a.activity) return {word: (a.model || '').toUpperCase(), color: C.dim};  // no activity read: say only what the roster knows
  if (a.activity === 'acting') return {word: (a.action || 'WORKING').toUpperCase(), color: C.green, live: true};
  if (a.activity === 'thinking') return {word: 'THINKING', color: C.amber};
  if (a.activity === 'idle') return {word: 'STANDING BY' + (a.idle_s >= 60 ? ' ' + Math.floor(a.idle_s / 60) + 'M' : ''), color: C.dim};
  return {word: {resting: 'BETWEEN TURNS', offline: 'OFFLINE', dead: 'DOWN'}[a.activity], color: LAMP[a.activity]};
}
let clockTop = null;
function ingest(s) {
  // An older save was loaded (the game clock went back): news and speech from after it no longer happened.
  const ticks = (s.teams || []).filter(t => !t.stale && t.tick != null).map(t => t.tick), top = ticks.length ? Math.max(...ticks) : null;
  if (top != null && clockTop != null && top < clockTop - 1800) rewind();
  if (top != null) clockTop = top;
  state = s; lost = false;
  if (s.layout && Array.isArray(s.layout.camera) && s.layout.camera.length === 4 && s.layout.camera.every(Number.isFinite)) R = rects(s.layout.camera);
  const agents = new Map(), teams = new Map();
  for (const t of s.teams || []) {
    teams.set(t.team, t);
    (t.agents || []).forEach((a, i) => { a.team = t.team; a.tone = agentColor(a, t.team, i); a.shown = a.display_name || cap(a.name); agents.set(t.team + '/' + a.name, a); });
  }
  const order = [...(s.teams || [])].sort((a, b) => (a.rank == null ? 99 : a.rank) - (b.rank == null ? 99 : b.rank));
  model = {order, agents, teams, cam: s.camera && teams.has(s.camera.team) ? s.camera : null};
  feedSync(s); newsSync(s);
  document.getElementById('summary').textContent = order.map(t => `${t.team}${t.rank != null ? ': ' + t.gap : ''}${t.research && t.research.done_count != null ? ', ' + t.research.done_count + ' technologies' : ''}. ` +
    (t.agents || []).map(a => { const st = statusOf(a, t); return a.shown + (st.word ? ': ' + st.word.toLowerCase() : ''); }).join('. ')).join(' / ');
}

function rewind() {
  feed.items.length = 0; feed.queue.length = 0; feed.known.clear(); feed.first = true;
  news.cards.length = 0; news.seen.clear(); news.first = true; news.banners.length = 0; news.banner = null; said.clear();
}

// ---- the standings strip: one card a team, rosters inside ------------------------------------------------------
function gapWord(t) {
  const m = /^(\d+) (tech|rocket|startup step)s? back$/.exec(t.gap || '');
  return m ? '−' + m[1] + ' ' + (m[2] === 'startup step' ? 'STEP' : m[2].toUpperCase()) + (m[1] === '1' ? '' : 'S') : '';
}
function drawStrip() {
  const teams = model.order, n = teams.length; if (!n) return;
  const gap = n > 4 ? 8 : 10, cw = (R.strip.w - (n - 1) * gap) / n;
  const cards = teams.map((t, i) => { const want = R.strip.x + i * (cw + gap); return {t, x: tween('card.' + t.team, want, .8), want}; });
  cards.sort((a, b) => Math.abs(a.x - a.want) - Math.abs(b.x - b.want));  // a card on the move passes over the others
  for (const c of cards) drawCard(c.t, c.x, R.strip.y, cw, R.strip.h);
}
function drawCard(t, x, y, w, h) {
  const col = teamColor(t.team), on = model.cam && model.cam.team === t.team, rw = w >= 420 ? 74 : w >= 300 ? 60 : 50;
  ctx.save(); if (t.stale) ctx.globalAlpha = .62;
  plate(x, y, w, h, {cut: 14, fill: mix(C.plate, col, .07), fill2: C.plate2});
  // the rank block: enamel in the team's colour; the leader's wears a hazard band
  ctx.save(); cutPath(x, y, rw, h, 14, 'tl'); ctx.clip();
  const g = ctx.createLinearGradient(0, y, 0, y + h); g.addColorStop(0, mix(col, '#ffffff', .12)); g.addColorStop(1, mix(col, '#000000', .2)); ctx.fillStyle = g; ctx.fillRect(x, y, rw, h);
  if (t.leader && t.rank != null && !t.stale) hazard(x, y, rw, 12);
  pop(); box(x + rw - 2, y, 2, h, 'rgba(0,0,0,.35)');
  const moved = tween('rank.' + t.team, t.rank == null ? 0 : t.rank, .5, outBack), lift = Math.abs(moved - (t.rank || 0)) * 14;
  const links = [...new Set((t.pacts || []).map(p => p.with))].filter(o => model.teams.has(o));
  text(t.rank == null ? '–' : String(t.rank), x + rw / 2, y + (links.length ? 92 : 104) - lift, font(rw >= 70 ? 88 : 68, 900, 'disp'), '#15130f', {align: 'center'});
  if (links.length) {  // pact partners, in their own colours, under the numeral
    const bw = 12 + Math.min(4, links.length) * 14, bx = x + (rw - bw) / 2;
    box(bx, y + h - 50, bw, 18, 'rgba(0,0,0,.6)');
    links.slice(0, 4).forEach((o, i) => box(bx + 7 + i * 14, y + h - 46, 10, 10, teamColor(o)));
    text('PACT', x + rw / 2, y + h - 16, font(12, 700), '#15130f', {align: 'center', ls: 1.2});
  }
  if (on) { ctx.save(); cutPath(x + 1.5, y + 1.5, w - 3, h - 3, 13); ctx.strokeStyle = col; ctx.lineWidth = 3; ctx.shadowColor = col; ctx.shadowBlur = 14; ctx.stroke(); pop(); }
  const hit = flashed.get(t.team), since = hit == null ? 9 : T() - hit;
  if (since < 1.6) {  // it just made news: the card lights up once
    const k = 1 - since / 1.6; ctx.save(); ctx.globalAlpha *= k; cutPath(x, y, w, h, 14); ctx.fillStyle = fade('#ffffff', .16); ctx.fill();
    cutPath(x + 2, y + 2, w - 4, h - 4, 12); ctx.strokeStyle = mix(col, '#ffffff', .5); ctx.lineWidth = 4; ctx.stroke(); pop(); busy(hit + 1.6);
  }
  const list = (t.agents || []).slice(0, 6), k = list.length, cx = x + rw + 14, cr = x + w - 14;
  const each = k ? (cr - cx - (k - 1) * 8) / k : 0;
  // rosters: a row of chips when each has room for a name; a column beside the numbers for three agents on a
  // narrow card (four teams); portraits alone when there are many teams
  const mode = !k ? 'none' : each >= 150 ? 'row' : w >= 420 && k <= 3 ? 'column' : 'faces';
  const rosterW = mode === 'column' ? Math.round((cr - cx) * .5) : 0, ir = cr - (rosterW ? rosterW + 12 : 0), stacked = mode === 'column';
  // name and standing
  const nameF = font(w >= 420 ? 40 : 30, 800, 'disp'), name = fit(t.team.toUpperCase(), nameF, (ir - cx) * (stacked ? 1 : .5), 1);
  let nx = cx + text(name, cx, y + 44, nameF, C.ink, {ls: 1}) + 12;
  const stats = [], rockets = t.space && t.space.rockets, done = t.research && t.research.done_count, spm = t.science && t.science.spm;
  if (rockets > 0) stats.push({v: String(rockets), u: rockets === 1 ? 'ROCKET' : 'ROCKETS', key: 'rk'});
  if (t.startup && t.startup_steps != null) stats.push({v: t.startup_steps + '/5', u: 'BUILT', key: 'st'});
  else if (done != null) stats.push({v: String(done), u: done === 1 ? 'TECH' : 'TECHS', key: 'td'});
  if (spm != null && !t.startup) stats.push({v: spm.toFixed(1), u: 'SPM', key: 'sp'});
  const vf = font(stacked ? 30 : w >= 420 ? 38 : 28, 800, 'disp'), uf = font(12, 700);
  const stat = (s, right, base) => {  // a number jolts when it changes
    const bump = tween('stat.' + t.team + s.key, parseFloat(s.v) || 0, .6, outBack), jolt = Math.min(6, Math.abs(bump - (parseFloat(s.v) || 0)) * 6);
    text(s.u, right, base, uf, C.muted, {align: 'right', ls: 1}); text(s.v, right - width(s.u, uf, 1) - 5, base - jolt, vf, C.ink, {align: 'right'});
  };
  const sw = s => width(s.v, vf) + 5 + width(s.u, uf, 1);
  // the standing comes first (a delayed feed, the leader, the gap); then as many numbers as fit, the ranked one first
  const flag = t.stale ? 'FEED DELAYED' : t.leader && t.rank != null ? (t.gap === 'Joint lead' ? 'JOINT LEAD' : 'LEADER') : '';
  const gw = !flag ? gapWord(t) : '', flagW = flag ? width(flag, font(13, 700), 1) + 22 : gw ? width(gw, font(16, 700), .5) : 0;
  let gx = ir;
  if (stacked) { let sx = cx; for (const s of stats) { if (sx + sw(s) > ir) break; stat(s, sx + sw(s), y + 84); sx += sw(s) + 14; } }
  else {
    const keep = []; let used = 0;
    for (const s of stats) { const need = sw(s) + 16; if (nx + (t.stale ? flagW + 14 : 0) + used + need > ir) break; keep.push(s); used += need; }
    for (let i = keep.length - 1; i >= 0; i--) { stat(keep[i], gx, y + 44); gx -= sw(keep[i]) + 16; }
    if (w >= 560 && t.science && (t.science.series || []).length > 1 && gx - nx - flagW > 130) { spark(t.science.series, gx - 96, y + 18, 96, 24, col); gx -= 112; }
  }
  if (flag) hazardTag(flag, nx, y + 22, gx - nx);
  else if (gw && gx - nx > flagW + 4) text(gw, nx, y + 42, font(16, 700), bright(col), {ls: .5});
  // research, or the opening foundations, and the factory's size
  const top = stacked ? y + 104 : y + 58, r = t.research || {}; let br = ir;
  const counts = t.entities ? FACTORY.map(names => [names[0], names.reduce((sum, key) => sum + (t.entities[key] || 0), 0)]).filter(c => c[1] > 0) : [];
  if (counts.length && (!t.startup || r.current) && !stacked && (w >= 560 || !r.current)) {
    const n = Math.min(counts.length, 4), fw = n * 56; let fx = r.current ? br - fw : cx;
    for (const [item, count] of counts.slice(0, n)) { icon('item', item, fx, top + 3, 28); text(String(count), fx + 31, top + 25, font(19, 700), C.text); fx += 56; }
    if (r.current) br -= fw + 12;
  }
  if (t.startup && t.entities && !r.current) {
    let fx = cx; if (!stacked) { text('OPENING', cx, top + 23, font(12, 700), C.muted, {ls: 1}); fx += 74; }
    for (const item of STARTUP) { if (fx + 34 > br) break; const have = (t.entities[item] || 0) > 0; ctx.save(); if (!have) ctx.globalAlpha *= .22; slot('item', item, fx, top, 34); pop(); if (have) box(fx, top + 34, 34, 3, col); fx += stacked ? 36 : 40; }
  } else if (r.current) {
    slot('tech', r.current, cx, top, 34);
    const pf = font(stacked ? 18 : 22, 800, 'disp'), pct = r.progress != null ? Math.round(r.progress * 100) + '%' : '', pw = pct ? width(pct, pf) + 8 : 0;
    text(fit(cap(r.label || r.current), font(17, 700), br - cx - 42 - (stacked ? 0 : pw)), cx + 42, top + 16, font(17, 700), C.text);
    if (pct) text(pct, br, top + (stacked ? 35 : 17), pf, bright(col), {align: 'right'});
    if (r.progress != null) belt(cx + 42, top + 24, br - cx - 42 - (stacked ? pw : 0), 10, col, r.progress, !t.stale && !t.paused);
  }
  // the roster
  if (mode === 'row') list.forEach((a, i) => drawChip(a, t, cx + i * (each + 8), y + 108, each, col, 48));
  else if (mode === 'column') { const pitch = k > 2 ? 52 : 70, y0 = y + (h - (k - 1) * pitch - 48) / 2; list.forEach((a, i) => drawChip(a, t, cr - rosterW, y0 + i * pitch, rosterW, col, 48)); }
  else if (mode === 'faces') { const size = each >= 50 ? 48 : Math.max(24, Math.floor(each) - 2); list.forEach((a, i) => drawChip(a, t, cx + i * (each + 8), y + 108, size + 4, col, size)); }
  pop();
}
function hazardTag(s, x, y, room) {
  const f = font(13, 700), w = width(s, f, 1) + 22; if (w > room) return;
  ctx.save(); ctx.beginPath(); ctx.moveTo(x + 6, y); ctx.lineTo(x + w, y); ctx.lineTo(x + w - 6, y + 22); ctx.lineTo(x, y + 22); ctx.closePath(); ctx.clip();
  hazard(x, y, w, 22); box(x + 5, y + 3, w - 10, 16, '#17150f'); pop();
  text(s, x + 11, y + 16, f, C.hazard, {ls: 1});
}
function spark(values, x, y, w, h, color) {
  const top = Math.max(1, ...values); ctx.beginPath();
  values.forEach((v, i) => { const px = x + i * w / (values.length - 1), py = y + h - v / top * h; if (i) ctx.lineTo(px, py); else ctx.moveTo(px, py); });
  ctx.strokeStyle = color; ctx.lineWidth = 2; ctx.stroke(); box(x, y + h + 1, w, 1, C.seam);
}
function drawChip(a, t, x, y, w, col, size) {
  const st = statusOf(a, t), onAir = model.cam && model.cam.team === t.team && model.cam.agent === a.name;
  portrait(a, x + 2, y, size, col);
  if (a.activity) lamp(x + size - 2, y + size - 4, size >= 40 ? 6 : 4, LAMP[a.activity] || C.dim, a.activity === 'acting' && !t.stale);
  const spoke = said.get(t.team + '/' + a.name), since = spoke == null ? 99 : T() - spoke;
  if (since < 2.4) {  // it just spoke: a ring opens from its portrait
    const k2 = since / 2.4; ctx.strokeStyle = fade(bright(col), .9 * (1 - k2)); ctx.lineWidth = 3; ctx.strokeRect(x + 2 - 8 * k2, y - 8 * k2, size + 16 * k2, size + 16 * k2); busy(spoke + 2.4);
  }
  if (onAir) { box(x - 1, y - 3, 30, 14, C.red); text('CAM', x + 3, y + 8, font(10, 700), '#fff', {ls: .8}); }
  if (w < size + 60) return;
  const tx = x + size + 12, room = x + w - tx, nf = font(18, 700);
  let ox = 0; const fits = extra => width(a.shown, nf) + extra <= room;
  if (a.icon && fits(24)) { icon('item', a.icon, tx, y + 3, 20); ox = 24; }
  else if (a.glyph && fits(width(a.glyph, font(16, 700)) + 6)) { ox = text(a.glyph, tx, y + 20, font(16, 700), bright(a.tone)) + 6; }
  text(fit(a.shown, nf, room - ox), tx + ox, y + 20, nf, C.ink);
  text(fit(st.word, font(12, 700), room, .8), tx, y + 40, font(12, 700), st.color, {ls: .8});
}

// ---- the feed: every team's speech on one clock ---------------------------------------------------------------
const feed = {items: [], queue: [], known: new Set(), first: true, next: 0};
function feedRows(s) {
  const rowsOut = [];
  for (const m of s.feed || []) {
    const t = model.teams.get(m.team), a = t && who(m.team, m.name);
    if (m.kind === 'market') {
      if (t && m.system === true && m.name === 'Trading Post' && model.teams.has(m.to_team) && m.to_team !== m.team && typeof m.text === 'string' && m.text)
        rowsOut.push({id: 'a:' + m.id, kind: 'market', team: m.team, to_team: m.to_team, text: m.text, tick: m.tick, at: m.at || 0});
      continue;
    }
    if (!a || !['talk', 'tell', 'diplomacy', 'board', 'identity'].includes(m.kind) || typeof m.text !== 'string') continue;
    if (m.kind === 'identity' ? typeof m.title !== 'string' || !m.title : !m.text) continue;
    // Drawn only under its own team; a tell must name teammates, diplomacy another launched team.
    const names = new Set(t.agents.map(x => x.name));
    if (m.kind === 'tell' && !(Array.isArray(m.to) && m.to.length && m.to.every(n => n === 'team' || names.has(n)))) continue;
    if (m.kind === 'diplomacy' && (!model.teams.has(m.to_team) || m.to_team === m.team)) continue;
    rowsOut.push({id: 'a:' + m.id, kind: m.kind, team: m.team, name: m.name, to: m.to || [], to_team: m.to_team, text: m.text, title: m.title, tick: m.tick, at: m.at || 0, reply: !!m.reply});
  }
  // The audience lane stays its own kind even if a malformed producer puts team rows here.
  for (const m of s.viewers || []) {
    if (!['site', 'youtube'].includes(m.source) || (m.kind && m.kind !== 'viewer') || (m.lane && m.lane !== 'viewer') || m.team || m.agent || m.from || m.tell || m.operator || m.confess) continue;
    if (typeof m.text !== 'string' || !m.text || !(Date.now() / 1000 - (m.t || 0) <= 600)) continue;
    rowsOut.push({id: 'v:' + (m.id || m.source + ':' + m.t + ':' + hash(m.text)), kind: 'viewer', source: m.source, text: m.text, at: m.t, site: typeof m.id === 'string' && /^site:[0-9]+$/.test(m.id) ? m.id.slice(5) : null, delivery: m.delivery, targets: m.targets});
  }
  return rowsOut.sort((a, b) => a.at - b.at);
}
function feedSync(s) {
  const rowsNow = feedRows(s), live = new Map(rowsNow.map(r => [r.id, r]));
  for (const it of feed.items) {
    const r = live.get(it.id);
    if (r) { it.delivery = r.delivery; it.targets = r.targets; }
    else if (it.kind === 'viewer') it.leaving = true;  // moderated or expired upstream: the page keeps no copy
  }
  feed.queue = feed.queue.filter(r => r.kind !== 'viewer' || live.has(r.id));
  const fresh = rowsNow.filter(r => !feed.known.has(r.id));
  for (const r of fresh) feed.known.add(r.id);
  if (feed.first) { feed.first = false; for (const r of fresh.slice(-9)) feed.items.push(Object.assign(r, {t0: -1e9})); }
  else feed.queue.push(...fresh);
  if (feed.known.size > 2000) feed.known = new Set([...feed.known].slice(-800));
}
function feedPump() {
  const t = T();
  if (feed.queue.length > 10) { for (const r of feed.queue.splice(0, feed.queue.length - 4)) feed.items.push(Object.assign(r, {t0: -1e9})); }
  if (feed.queue.length && (t >= feed.next || settled)) {
    const r = feed.queue.shift(); r.t0 = settled ? -1e9 : t; feed.items.push(r);
    if (r.kind === 'identity' && !settled) news.banners.push({kind: 'identity', team: r.team, agent: r.name, text: r.title, persona: r.text});
    if (!settled) start('in.' + r.id, 0, 1, .42);  // its slot opens and pushes the older lines up
    if (speaks(r) && r.kind !== 'viewer') said.set(r.team + '/' + r.name, t);
    feed.next = t + (feed.queue.length > 5 ? .45 : feed.queue.length > 1 ? 1.3 : speaks(r) ? clamp(r.text.length / 30, 2.2, 6) : 1.6);
  }
  if (feed.queue.length) busy(feed.next + .05);
  feed.items = feed.items.filter(it => !(it.leaving && tween('in.' + it.id, 0, .4) < .01));
  if (feed.items.length > 16) feed.items.splice(0, feed.items.length - 16);
}
function clockOf(tick) { if (tick == null) return ''; const sec = Math.floor(tick / 60), h = Math.floor(sec / 3600), m = Math.floor(sec % 3600 / 60), ss = String(sec % 60).padStart(2, '0'); return h ? h + ':' + String(m).padStart(2, '0') + ':' + ss : m + ':' + ss; }
function receipt(it) {
  let out = it.delivery === 'held' ? 'QUEUED' : it.delivery === 'operator' ? 'TO OPERATOR' : '';
  const d = it.site && state.viewer_delivery ? state.viewer_delivery[it.site] : null;  // mt290's receipts, by public site sequence
  if (d) {
    if (d.s === 'operator') out = 'TO OPERATOR';
    else if (d.s === 'held') out = 'QUEUED';
  }
  return out;
}
const BIG = font(23, 600), SMALL = font(18, 600);
function laneOf(it) {  // who a team line is for; every team line but an answer to a viewer wears the padlock
  if (it.kind === 'tell') return 'TO ' + it.to.map(n => n === 'team' ? 'TEAM' : ((who(it.team, n) || {}).shown || cap(n)).toUpperCase()).join(', ');
  return 'TO TEAM';
}
const speaks = it => !['board', 'identity', 'market'].includes(it.kind);  // system facts never impersonate an agent
const NOTE = font(16, 600), PERSONA = font(18, 600, 'ui', true);
function measure(it, w, big) {
  if (it.kind === 'market') return 35 + wrap(it.text, SMALL, w - 32, 3).length * 24 + 12;
  if (it.kind === 'board') return 30 + wrap(it.text, NOTE, w - 62, 2).length * 21;
  if (it.kind === 'identity') return 66 + (it.text ? wrap('“' + it.text + '”', PERSONA, w - 96, 2).length * 23 + 4 : 0);
  if (it.kind === 'viewer') {
    const tw = w - 56 - 28, n = wrap(it.text, big ? font(21, 600) : SMALL, tw, big ? 6 : 2).length;
    return 34 + n * (big ? 28 : 24) + (receipt(it) ? 22 : 0) + 10;
  }
  if (big) return 12 + 72 + 12 + wrap(it.text, BIG, w - 34, 7).length * 30 + 12 + (it.kind === 'diplomacy' ? 26 : 0);
  return (it.kind === 'diplomacy' ? 26 : 0) + Math.max(68, 34 + wrap(it.text, SMALL, w - 90, it.kind === 'diplomacy' ? 3 : 2).length * 24 + 10);
}
function typed(lines, it) {  // the newest line is typed out as it arrives
  const shown = (T() - it.t0) * 75; let total = 0; for (const l of lines) total += l.length;
  if (shown >= total) return lines;
  busy(it.t0 + total / 75 + .05); let left = shown; const out = [];
  for (const l of lines) { if (left <= 0) break; out.push(l.slice(0, Math.ceil(left))); left -= l.length; }
  return out;
}
function drawNote(it, x, y, w, h) {
  const a = who(it.team, it.name), col = teamColor(it.team);
  if (it.kind === 'board') {  // the team board: a plan, note or step, pinned under its author
    plate(x + 22, y, w - 22, h, {cut: 8, corners: 'tr,bl', fill: '#262524', fill2: '#201f1e', bevel: false}); box(x + 22, y, 3, h - 8, fade(col, .8));
    portrait(a, x + 34, y + 8, 24, col);
    const nw = text(fit(a.shown, font(15, 700), w * .4), x + 66, y + 22, font(15, 700), bright(col));
    text('TEAM BOARD', x + 74 + nw, y + 21, font(11, 700), C.dim, {ls: 1}); text(clockOf(it.tick), x + w - 12, y + 21, font(12, 600), C.dim, {align: 'right'});
    wrap(it.text, NOTE, w - 62, 2).forEach((l, i) => text(l, x + 34, y + 45 + i * 21, NOTE, C.muted));
    return;
  }
  // an agent has chosen who it is: name and persona, announced once
  plate(x, y, w, h, {cut: 12, corners: 'tr,bl', fill: mix('#35322c', col, .1), fill2: '#28261f'});
  ctx.save(); cutPath(x, y, w, h, 12, 'tr,bl'); ctx.clip(); hazard(x, y, w, 5, .9); pop(); box(x, y + 5, 6, h - 17, col);
  portrait(a, x + 18, y + 16, 48, col);
  text('NEW IDENTITY', x + 78, y + 28, font(12, 700), C.gold, {ls: 1.5});
  const tw2 = width('NEW IDENTITY', font(12, 700), 1.5);
  text(it.team.toUpperCase() + ' · ' + (a.model || cap(it.name)).toUpperCase(), x + 88 + tw2, y + 28, font(11, 700), C.dim, {ls: 1});
  text(fit(it.title.toUpperCase(), font(30, 800, 'disp'), w - 96, .5), x + 78, y + 58, font(30, 800, 'disp'), C.ink, {ls: .5});
  if (it.text) wrap('“' + it.text + '”', PERSONA, w - 96, 2).forEach((l, i) => text(l, x + 78, y + 82 + i * 23, PERSONA, C.text));
}
function drawBubble(it, x, y, w, h, e, life) {
  if (it.kind === 'market') {
    ctx.save(); ctx.globalAlpha *= clamp(life * 1.4 - .2, 0, 1);
    plate(x, y, w, h, {cut: 10, fill: '#34312a', fill2: '#25241f'});
    box(x, y + 6, 5, h - 12, teamColor(it.team)); box(x + w - 5, y + 6, 5, h - 12, teamColor(it.to_team));
    text('TRADING POST · SYSTEM', x + 16, y + 24, font(14, 700), C.gold, {ls: .8});
    text(clockOf(it.tick), x + w - 16, y + 24, font(13, 600), C.muted, {align: 'right'});
    wrap(it.text, SMALL, w - 32, 3).forEach((l, i) => text(l, x + 16, y + 54 + i * 24, SMALL, C.text));
    pop(); return;
  }
  if (!speaks(it)) { ctx.save(); ctx.globalAlpha *= clamp(life * 1.4 - .2, 0, 1); drawNote(it, x, y, w, h); pop(); return; }
  ctx.save(); ctx.globalAlpha *= clamp(life * 1.4 - .2, 0, 1);
  const big = e > .5, body = ctx.globalAlpha * clamp(Math.abs(e - .5) * 4, 0, 1);  // the two layouts cross-fade inside one plate
  if (it.kind === 'viewer') {
    const bx = x + 56, bw = w - 56, src = it.source === 'youtube' ? ['YOUTUBE', '#ff6a5c'] : ['SITE', C.amber];
    plate(bx, y, bw, h, {cut: 10, corners: 'tr,bl', fill: '#3b3a3a', fill2: '#313030'}); ctx.globalAlpha = body;
    const tw2 = tag(src[0], bx + 12, y + 9, src[1], {solid: true, ink: '#1a1210'});
    text('VIEWER', bx + 20 + tw2, y + 24, font(13, 700), C.muted, {ls: 1});
    const f = big ? font(21, 600) : SMALL, pitch = big ? 28 : 24; let lines = wrap(it.text, f, bw - 28, big ? 6 : 2);
    if (big) lines = typed(lines, it);
    lines.forEach((l, i) => text(l, bx + 14, y + 34 + (big ? 21 : 18) + i * pitch, f, C.text));
    const rc = receipt(it);
    if (rc) { const ry = y + h - 14, done = rc.startsWith('SENT TO ALL'); text((done ? '✓✓ ' : rc.includes('OF') || rc.startsWith('SENT') ? '✓ ' : '') + rc, bx + 14, ry, font(12, 700), done ? C.green : C.muted, {ls: .8}); }
    pop(); return;
  }
  const a = who(it.team, it.name), col = teamColor(it.team), dip = it.kind === 'diplomacy', other = dip ? teamColor(it.to_team) : col;
  plate(x, y, w, h, {cut: 12, corners: 'tr,bl', fill: mix('#302e2d', col, big ? .13 : .08), fill2: mix('#262524', col, .05)});
  box(x, y, 6, h - 12, col); ctx.beginPath(); ctx.moveTo(x, y + h - 12); ctx.lineTo(x + 6, y + h - 12); ctx.lineTo(x + 6, y + h - 6); ctx.closePath(); ctx.fillStyle = col; ctx.fill();
  let top = y;
  if (dip) {  // a treaty line: both teams' colours and a gold header
    box(x + w - 6, y + 12, 6, h - 12, other);
    box(x + 6, y, w - 18, 24, fade(C.gold, .16)); text('DIPLOMACY', x + 18, y + 17, font(13, 700), C.gold, {ls: 1.5});
    const tf = font(13, 700), ax = x + 18 + width('DIPLOMACY', tf, 1.5) + 14;
    const fw2 = text(it.team.toUpperCase(), ax, y + 17, tf, bright(col), {ls: 1}); text('→', ax + fw2 + 7, y + 17, tf, C.gold); text(String(it.to_team).toUpperCase(), ax + fw2 + 26, y + 17, tf, bright(other), {ls: 1});
    top = y + 26;
  }
  const stamp = clockOf(it.tick), lane = dip ? '' : laneOf(it);
  ctx.globalAlpha = body;
  if (big) {
    portrait(a, x + 18, top + 12, 72, col);
    const nf = font(32, 800, 'disp'), nx = x + 104, room = x + w - 14 - nx;
    let ox = 0; if (a.icon) { icon('item', a.icon, nx, top + 16, 24); ox = 30; } else if (a.glyph) ox = text(a.glyph, nx, top + 38, font(22, 700), bright(a.tone)) + 8;
    text(fit(a.shown.toUpperCase(), nf, room - ox - width(stamp, font(14, 600)) - 10, .5), nx + ox, top + 40, nf, C.ink, {ls: .5});
    text(stamp, x + w - 14, top + 38, font(14, 600), C.dim, {align: 'right'});
    const tw2 = tag(it.team.toUpperCase(), nx, top + 50, col, {solid: true});
    if (lane) { const lx = nx + tw2 + 10, locked = !it.reply; if (locked) padlock(lx, top + 53, C.muted); text(fit(lane, font(13, 700), room - tw2 - 26, .8), lx + (locked ? 16 : 0), top + 65, font(13, 700), it.reply ? C.cyan : C.muted, {ls: .8}); }
    typed(wrap(it.text, BIG, w - 34, 7), it).forEach((l, i) => text(l, x + 20, top + 96 + 23 + i * 30, BIG, C.ink));
  } else {
    portrait(a, x + 16, top + 10, 48, col);
    const nx = x + 76, room = x + w - 14 - nx, nf = font(17, 700), sw = width(stamp, font(13, 600));
    const nw = text(fit(a.shown, nf, room * .55), nx, top + 25, nf, bright(col));
    if (lane) { const lx = nx + nw + 12, locked = !it.reply; if (locked) padlock(lx, top + 13, C.dim); text(fit(lane, font(12, 700), room - nw - sw - 40, .8), lx + (locked ? 15 : 0), top + 24, font(12, 700), it.reply ? C.cyan : C.muted, {ls: .8}); }
    text(stamp, x + w - 14, top + 24, font(13, 600), C.dim, {align: 'right'});
    wrap(it.text, SMALL, w - 90, dip ? 3 : 2).forEach((l, i) => text(l, nx, top + 49 + i * 24, SMALL, C.text));
  }
  pop();
}
function drawRail() {
  const r = R.rail; plate(r.x, r.y, r.w, r.h, {cut: 14, corners: 'tr,bl', fill: '#242322', fill2: '#1c1b1a'});
  hazard(r.x + 1, r.y + 1, 10, 42); box(r.x + 11, r.y + 1, r.w - 12 - 14, 42, '#2f2d2c'); box(r.x + 1, r.y + 43, r.w - 2, 2, 'rgba(0,0,0,.6)');
  text('TEAM RADIO', r.x + 24, r.y + 33, font(30, 800, 'disp'), C.ink, {ls: 1.5});
  const lf = font(11, 700), legendText = 'TEAM ONLY · DIPLOMACY · VIEWERS', lw = width(legendText, lf, 1);
  padlock(r.x + r.w - 20 - lw - 16, r.y + 17, C.muted); text(legendText, r.x + r.w - 20, r.y + 28, lf, C.muted, {align: 'right', ls: 1});
  feedPump();
  const x = r.x + 10, w = r.w - 20, top = r.y + 50, bottom = r.y + r.h - 10, gap = 8, items = feed.items;
  let last = items.length - 1; while (last >= 0 && !speaks(items[last])) last--;
  ctx.save(); ctx.beginPath(); ctx.rect(r.x + 2, top, r.w - 4, bottom - top + 6); ctx.clip();
  let y = bottom; const shown = [];
  for (let i = items.length - 1; i >= 0; i--) {
    const it = items[i], e = tween('e.' + it.id, i === last ? 1 : 0, .38), life2 = tween('in.' + it.id, it.leaving ? 0 : 1, .42);
    const hh = lerp(measure(it, w, false), measure(it, w, true), e);
    y -= (hh + gap) * life2;
    if (y + hh < top - 20) break;
    drawBubble(it, x, y, w, hh, e, life2); shown.push({id: it.id, kind: it.kind, team: it.team, y, h: hh});
  }
  pop();
  const g = ctx.createLinearGradient(0, top, 0, top + 46); g.addColorStop(0, '#232221'); g.addColorStop(1, 'rgba(35,34,33,0)'); ctx.fillStyle = g; ctx.fillRect(r.x + 2, top, r.w - 4, 46);
  if (!items.length && !feed.queue.length) legend(r, top);
  debug.feed = shown;
}
function legend(r, top) {  // before anyone speaks: what this column carries
  const rowsL = [[C.text, 'TEAM RADIO', 'Agents talking inside their own team. Other teams cannot hear it.'],
    [C.gold, 'DIPLOMACY', 'Messages one team sends another after they meet.'],
    [C.cyan, 'VIEWERS', 'Chat from the site and YouTube reaches every team.']];
  rowsL.forEach(([color, head, body], i) => { const y = top + 26 + i * 96; box(r.x + 24, y, 4, 70, color); text(head, r.x + 40, y + 20, font(22, 800, 'disp'), color, {ls: 1}); wrap(body, font(17, 600), r.w - 76, 2).forEach((l, j) => text(l, r.x + 40, y + 44 + j * 22, font(17, 600), C.muted)); });
}

// ---- the band: show bug, the news belt, the game clock -----------------------------------------------------------
const news = {cards: [], seen: new Set(), first: true, phase: 0, banners: [], banner: null, last: 0};
const KIND = {research: 'RESEARCH', rocket: 'ROCKET', death: 'LOST', platform_lost: 'SPACE', contact: 'CONTACT', pact: 'DIPLOMACY', build: 'BUILT'};
function newsSync(s) {
  const events = (s.events || []).filter(e => model.teams.has(e.team) && typeof e.text === 'string' && e.id).sort((a, b) => (a.tick || 0) - (b.tick || 0));
  for (const e of events) {
    if (news.seen.has(e.id)) continue; news.seen.add(e.id);
    news.cards.push(Object.assign({}, e, {born: news.first ? -1e9 : T()}));
    // Fresh news lights its team's card; a milestone (not one more of a building the team already has) gets a banner too.
    if (!news.first && s.now - (e.at || 0) <= 60) { flashed.set(e.team, T()); if (e.kind !== 'build' || /^First /.test(e.text)) news.banners.push(e); }
  }
  news.first = false; news.cards.sort((a, b) => (a.tick || 0) - (b.tick || 0));
  if (news.cards.length > 10) news.cards.splice(0, news.cards.length - 10);
}
function cardWidth(e) { return clamp(Math.max(width(e.text, font(20, 700)), 150) + 78, 230, 440); }
function drawBand() {
  const b = R.band, bugW = 318, clockW = 300;
  // the show bug
  plate(b.x, b.y, bugW, b.h, {cut: 14, corners: 'tl,br'}); hazard(b.x + 1, b.y + 1, 12, b.h - 2);
  text('THE FACTORY RACE', b.x + 28, b.y + 42, font(40, 900, 'disp'), C.ink, {ls: 1});
  const basis = /^Rank/.test(state.ranking || '') ? 'RANKED BY ROCKETS, THEN TECHS' : /^Startup/.test(state.ranking || '') ? 'OPENING: FIVE FIRST BUILDINGS' : '';
  const lines = ['AI TEAM TEST · FACTORIO: SPACE AGE'].concat(basis ? [basis] : []), pick = Math.floor(T() / 12) % lines.length;
  text(fit(lines[pick], font(12, 700), bugW - 44, 1), b.x + 28, b.y + 62, font(12, 700), C.amber, {ls: 1});
  // the clock
  const cx = b.x + b.w - clockW; plate(cx, b.y, clockW, b.h, {cut: 14, corners: 'tl,br'});
  const ticks = (state.teams || []).filter(t => !t.stale && t.tick != null).map(t => t.tick), paused = (state.teams || []).some(t => t.paused);
  const stale = lost || Date.now() / 1000 - state.now > 25;
  let mode = state.fixture ? ['REPLAY', C.amber] : stale ? ['DELAYED', C.amber] : paused ? ['PAUSED', C.amber] : ['LIVE', C.red];
  lamp(cx + 30, b.y + 23, 7, mode[1], mode[0] === 'LIVE'); text(mode[0], cx + 44, b.y + 28, font(14, 700), mode[1], {ls: 1.5});
  text('GAME TIME', cx + clockW - 24, b.y + 28, font(12, 700), C.muted, {align: 'right', ls: 1.5});
  if (ticks.length) {
    const run = !stale && !paused && !state.fixture ? clamp(Date.now() / 1000 - state.now, 0, 12) * 60 : 0, digits = clockOf(Math.max(...ticks) + run), df = font(46, 800, 'disp');
    let dx = cx + clockW - 24; for (let i = digits.length - 1; i >= 0; i--) { const ch = digits[i], cell = ch === ':' ? 12 : 24; text(ch, dx - cell / 2, b.y + b.h - 9, df, C.ink, {align: 'center'}); dx -= cell; }
  }
  // the belt: news rides in from the right and queues at the left, oldest first
  const x0 = b.x + bugW + 8, x1 = cx - 8, bw = x1 - x0; well(x0, b.y, bw, b.h);
  const moving = T() < news.last + .9; if (moving) { news.phase += 3.2; busy(news.last + .95); }
  ctx.save(); ctx.beginPath(); ctx.rect(x0, b.y, bw, b.h); ctx.clip();
  box(x0, b.y + 8, bw, b.h - 16, '#201f1e'); box(x0, b.y + 6, bw, 3, '#4c4946'); box(x0, b.y + b.h - 9, bw, 3, '#4c4946');
  ctx.strokeStyle = 'rgba(246,195,21,.13)'; ctx.lineWidth = 3;
  for (let px = x0 + bw + 40 - (news.phase % 44); px > x0 - 40; px -= 44) { ctx.beginPath(); ctx.moveTo(px + 13, b.y + 18); ctx.lineTo(px, b.y + b.h / 2); ctx.lineTo(px + 13, b.y + b.h - 18); ctx.stroke(); }
  const cards = news.cards, widths = cards.map(cardWidth), total = widths.reduce((a, v) => a + v + 10, 10);
  let px = x0 + 10 - Math.max(0, total - bw);
  cards.forEach((e, i) => {
    const key = 'news.' + e.id;
    if (!tweens.get(key)) { if (e.born > 0) { start(key, x1 + 30, px, .85); news.last = T(); } else tween(key, px, .85); }
    const before = tweens.get(key).to, cxp = tween(key, px, .85); if (before !== px) news.last = T();
    if (cxp + widths[i] > x0 && cxp < x1) drawNews(e, cxp, b.y + 11, widths[i], b.h - 22); px += widths[i] + 10;
  });
  pop();
  if (total > bw) { const g2 = ctx.createLinearGradient(x0, 0, x0 + 70, 0); g2.addColorStop(0, '#191817'); g2.addColorStop(1, 'rgba(25,24,23,0)'); ctx.fillStyle = g2; ctx.fillRect(x0, b.y + 2, 70, b.h - 4); }
  if (!cards.length) text('RACE NEWS', x0 + 22, b.y + b.h / 2 + 8, font(20, 800, 'disp'), C.dim, {ls: 2});
}
function drawNews(e, x, y, w, h) {
  const col = teamColor(e.team);
  plate(x, y, w, h, {cut: 9, corners: 'tl,br', fill: mix('#343231', col, .1), fill2: '#2a2928'}); box(x + 9, y, w - 9, 3, col);
  slot(e.icon_kind || 'item', e.icon, x + 9, y + 8, h - 14);
  let tx = x + 62; tx += text(e.team.toUpperCase(), tx, y + 21, font(13, 700), bright(col), {ls: 1}) + 8;
  if (e.other && model.teams.has(e.other)) { box(tx, y + 11, 10, 10, teamColor(e.other)); tx += 18; }
  text((e.observed ? '~' : '') + clockOf(e.tick), tx, y + 21, font(12, 600), C.dim, {ls: .5});
  text(fit(e.text, font(20, 700), w - 72), x + 62, y + 44, font(20, 700), C.ink);
}

// ---- over the camera: frame, who is on air, banners, the credit -------------------------------------------------
function drawCamera() {
  const c = R.cam, cam = model.cam, team = cam && model.teams.get(cam.team), col = team ? teamColor(team.team) : C.seam;
  ctx.strokeStyle = '#0c0b0b'; ctx.lineWidth = 4; ctx.strokeRect(c.x - 2, c.y - 2, c.w + 4, c.h + 4);
  ctx.strokeStyle = col; ctx.lineWidth = 2; ctx.strokeRect(c.x - 1, c.y - 1, c.w + 2, c.h + 2);
  ctx.fillStyle = fade(C.ink, .75);
  for (const [px, py, sx, sy] of [[c.x + 8, c.y + 8, 1, 1], [c.x + c.w - 8, c.y + 8, -1, 1], [c.x + 8, c.y + c.h - 8, 1, -1], [c.x + c.w - 8, c.y + c.h - 8, -1, -1]]) { ctx.fillRect(px, py, 26 * sx, 3 * sy); ctx.fillRect(px, py, 3 * sx, 26 * sy); }
  if (team) {
    const k = tween('cut.' + cam.team + '.' + (cam.agent || '') + '.' + Math.round(cam.since || 0), 1, .6), slide = (1 - k) * -30;
    ctx.save(); ctx.globalAlpha = k;
    // top left: which team, and why the camera is here
    const tx = c.x + 22 + slide, ty = c.y + 22, nf = font(30, 800, 'disp'), label = team.team.toUpperCase();
    const why = team.stale ? 'FEED DELAYED' : team.paused ? 'WORLD PAUSED' : String(cam.reason || 'Following the action').toUpperCase();
    const tw2 = 132 + width(label, nf, 1) + 28 + width(why, font(13, 700), 1) + 20;
    plate(tx, ty, tw2, 40, {cut: 10, corners: 'tl,br', fill: 'rgba(28,27,26,.93)', fill2: 'rgba(20,19,19,.93)'});
    ctx.save(); cutPath(tx, ty, 118, 40, 10, 'tl'); ctx.clip(); hazard(tx, ty, 118, 40); box(tx + 5, ty + 5, 108, 30, '#17150f'); pop();
    text('ON CAMERA', tx + 14, ty + 26, font(15, 700), C.hazard, {ls: 1.5});
    box(tx + 124, ty + 6, 5, 28, col); const lw = text(label, tx + 138, ty + 30, nf, C.ink, {ls: 1});
    text(why, tx + 138 + lw + 16, ty + 26, font(13, 700), C.muted, {ls: 1});
    lowerThird(c, cam, team, col, slide);
    pop();
  }
  banner(c); credit(c);
  if (state.fixture) { const s = String(state.fixture).toUpperCase(), w = width(s, font(13, 700), 1) + 26; plate(c.x + c.w - w - 20, c.y + 22, w, 28, {cut: 7, fill: 'rgba(28,27,26,.9)', fill2: 'rgba(20,19,19,.9)'}); text(s, c.x + c.w - w - 7, c.y + 41, font(13, 700), C.amber, {ls: 1}); }
  if (lost || Date.now() / 1000 - state.now > 25) { const w = 560, x = c.x + (c.w - w) / 2, y = c.y + 76; ctx.save(); cutPath(x, y, w, 50, 10); ctx.clip(); hazard(x, y, w, 50); box(x + 6, y + 6, w - 12, 38, '#17150f'); pop(); text('FEED DELAYED · SHOWING THE LAST CONFIRMED STATE', x + w / 2, y + 32, font(17, 700), C.hazard, {align: 'center', ls: 1}); }
}
function lowerThird(c, cam, team, col, slide) {
  const a = cam.agent && who(team.team, cam.agent), h = 104, x = c.x + 22 + slide, y = c.y + c.h - h - 24;
  if (a) {  // the agent the camera follows: portrait, chosen name, persona, what it is doing
    const st = statusOf(a, team), nf = font(44, 800, 'disp'), name = a.shown.toUpperCase();
    const meta = [a.model, a.pronouns].filter(Boolean).join(' · '), spoke = said.get(team.team + '/' + a.name), line = lastLine(team.team, a.name);
    const quote = line && spoke != null && T() - spoke < 9 ? line.text : '';
    const sub = quote ? '“' + quote + '”' : a.persona ? '“' + a.persona + '”' : a.task ? 'Task: ' + a.task : '';
    const w = clamp(Math.max(width(name, nf, 1) + (a.glyph || a.icon ? 44 : 0) + width(meta, font(15, 600)) + 40, width(sub, font(19, 600, 'ui', true)) + 20, 330) + 130, 420, 760);
    plate(x, y, w, h, {cut: 14, corners: 'tl,br', fill: 'rgba(30,29,28,.94)', fill2: 'rgba(20,19,19,.94)'}); box(x, y + 14, 7, h - 14, col);
    portrait(a, x + 22, y + 16, 72, col);
    let nx = x + 112; if (a.icon) { icon('item', a.icon, nx, y + 16, 32); nx += 40; } else if (a.glyph) nx += text(a.glyph, nx, y + 46, font(30, 700), bright(a.tone)) + 10;
    const nw = text(fit(name, nf, w - (nx - x) - 20, 1), nx, y + 50, nf, C.ink, {ls: 1});
    text(fit(meta, font(15, 600), w - (nx - x) - nw - 34), nx + nw + 14, y + 48, font(15, 600), C.muted);
    // with no activity read, the model beside the name already says all the roster knows
    if (a.activity || team.stale || team.paused) { if (a.activity) lamp(x + 120, y + 67, 6, LAMP[a.activity] || C.dim, a.activity === 'acting'); text(fit(st.word, font(15, 700), w - 150, 1), x + (a.activity ? 134 : 112), y + 72, font(15, 700), st.color, {ls: 1}); }
    if (sub) text(fit(sub, font(19, 600, 'ui', true), w - 130), x + 112, y + 94, font(19, 600, 'ui', true), quote ? C.ink : C.text);
    if (quote) busy(spoke + 9.1);
    return;
  }
  // a base shot: the team's factory, counted from its buildings
  const counts = team.entities ? FACTORY.map(names => [names[0], names.reduce((sum, k) => sum + (team.entities[k] || 0), 0)]).filter(c2 => c2[1] > 0) : [];
  const title = team.team.toUpperCase() + ' BASE', nf = font(44, 800, 'disp'), w = Math.max(width(title, nf, 1) + 60, counts.length * 78 + 40);
  const hh = counts.length ? h : 72, yy = c.y + c.h - hh - 24;
  plate(x, yy, w, hh, {cut: 14, corners: 'tl,br', fill: 'rgba(30,29,28,.94)', fill2: 'rgba(20,19,19,.94)'}); box(x, yy + 14, 7, hh - 14, col);
  text(title, x + 26, yy + 50, nf, C.ink, {ls: 1});
  counts.forEach(([item, n], i) => { icon('item', item, x + 26 + i * 78, yy + 60, 32); text(String(n), x + 62 + i * 78, yy + 85, font(22, 700), C.text); });
}
function lastLine(team, name) { for (let i = feed.items.length - 1; i >= 0; i--) { const it = feed.items[i]; if (it.team === team && it.name === name && speaks(it)) return it; } return null; }
function banner(c) {
  const t = T(); if (!news.banner && news.banners.length) { news.banner = Object.assign({t0: t}, news.banners.shift()); }
  const b = news.banner; if (!b) return; const age = t - b.t0, hold = news.banners.length ? 4.5 : 7;
  if (age > hold || !model.teams.has(b.team)) { news.banner = null; busy(t + .1); return; } busy(b.t0 + hold + .1);
  const k = outBack(clamp(age / .5, 0, 1)), out = clamp((hold - age) / .4, 0, 1), col = teamColor(b.team), tf = font(38, 800, 'disp');
  const a = b.kind === 'identity' ? who(b.team, b.agent) : null, sub = a && b.persona ? '“' + b.persona + '”' : '', sf = font(19, 600, 'ui', true);
  if (b.kind === 'identity' && !a) { news.banner = null; return; }
  const w = clamp(Math.max(width(b.text.toUpperCase(), tf, 1), sub ? Math.min(width(sub, sf), 760) : 0) + 150, 520, 980), h = sub ? 118 : 92;
  const x = c.x + (c.w - w) / 2, y = c.y + 78 - (1 - k) * 60;
  ctx.save(); ctx.globalAlpha = Math.min(clamp(age / .25, 0, 1), out);
  plate(x, y, w, h, {cut: 16, corners: 'tl,br', fill: 'rgba(32,30,29,.96)', fill2: 'rgba(20,19,19,.96)'});
  ctx.save(); cutPath(x, y, w, h, 16); ctx.clip(); hazard(x, y, w, 7); box(x, y + h - 7, w, 7, col); pop();
  if (a) portrait(a, x + 20, y + 20, 72, col); else slot(b.icon_kind || 'item', b.icon, x + 20, y + 18, 60);
  const tx = x + (a ? 108 : 96);
  const hw = text(b.team.toUpperCase(), tx, y + 36, font(15, 700), bright(col), {ls: 1.5});
  text('· ' + (a ? 'NEW IDENTITY · ' + (a.model || '').toUpperCase() : KIND[b.kind] || 'NEWS'), tx + 8 + hw, y + 36, font(15, 700), C.muted, {ls: 1.5});
  text(fit(b.text.toUpperCase(), tf, w - (tx - x) - 24, 1), tx, y + 74, tf, C.ink, {ls: 1});
  if (sub) text(fit(sub, sf, w - (tx - x) - 24), tx, y + 100, sf, C.text);
  pop();
}
function credit(c) {  // Wube's graphics credit: at the start of a clip and briefly each hour
  const phase = ((Date.now() / 1000 - loaded) + shift) % CREDIT_EVERY; if (phase > CREDIT_S) return;
  const a = Math.min(clamp(phase / .8, 0, 1), clamp((CREDIT_S - phase) / .8, 0, 1)), s = 'Graphics copyright Wube Software', f = font(16, 600), w = width(s, f) + 30;
  busy(T() + .2); ctx.save(); ctx.globalAlpha = a;
  plate(c.x + c.w - w - 22, c.y + c.h - 60, w, 36, {cut: 8, fill: 'rgba(28,27,26,.9)', fill2: 'rgba(20,19,19,.9)'}); text(s, c.x + c.w - w - 7, c.y + c.h - 36, f, C.text);
  pop();
}

// Display-only market facts: sampled shipment coordinates, never a wealth standing or camera target.
function drawMarket() {
  const data = state.market || {}, markers = Array.isArray(data.markers) ? data.markers : [], prices = Array.isArray(data.last_prices) ? data.last_prices : [];
  if (!markers.length && !prices.length) { debug.market = null; return; }
  const surface = (markers[0] || {}).surface, ships = markers.filter(m => m.surface === surface).slice(0, 3), ps = prices.slice(0, 2);
  const c = R.cam, w = 390, x = c.x + c.w - w - 18, y = c.y + 74, h = 44 + (ships.length ? 134 : 0) + ps.length * 45;
  plate(x, y, w, h, {cut: 12, fill: 'rgba(33,31,27,.95)', fill2: 'rgba(22,21,19,.95)'});
  text('TRADING POST', x + 16, y + 28, font(24, 800, 'disp'), C.gold, {ls: 1});
  text(ships.length ? cap(surface).toUpperCase() : 'LAST TRADES', x + w - 16, y + 27, font(12, 700), C.muted, {align: 'right'});
  let py = y + 44;
  if (ships.length) {
    const points = ships.map(m => [m.x, m.y]);
    for (const t of model.teams.values()) { const m = t.map; if (surface === 'nauvis' && m) points.push([m.x0, m.y0], [m.x0 + m.w * m.cell, m.y0 + m.h * m.cell]); }
    const x0 = Math.floor(Math.min(...points.map(p => p[0])) / 256) * 256 - 32, y0 = Math.floor(Math.min(...points.map(p => p[1])) / 256) * 256 - 32;
    const span = Math.max(256, Math.max(...points.map(p => p[0])) - x0 + 32, Math.max(...points.map(p => p[1])) - y0 + 32);
    const mx = x + 12, my = py, size = 114;
    box(mx, my, size, size, C.well);
    for (let i = 1; i < 4; i++) { box(mx + i * size / 4, my, 1, size, '#33332e'); box(mx, my + i * size / 4, size, 1, '#33332e'); }
    ships.forEach((m, i) => {
      const px = mx + (m.x - x0) / span * size, qy = my + (m.y - y0) / span * size;
      box(px - 6, qy - 6, 12, 12, teamColor(m.to)); box(px - 4, qy - 4, 8, 8, teamColor(m.from));
      text(String(i + 1), px + 8, qy + 4, font(12, 700), C.ink);
      const lx = x + 140, ly = py + 12 + i * 39, eta = Math.max(0, Math.ceil((m.arrival_tick - (clockTop || data.tick)) / 60));
      const status = m.state === 'waiting' ? 'WAITING FOR SPACE' : m.state === 'quarantined' ? 'HELD' : eta ? eta + 's TO ARRIVAL' : 'ARRIVING';
      text(fit((i + 1) + '. ' + m.from.toUpperCase() + ' → ' + m.to.toUpperCase() + ' · ' + status, font(11, 700), w - 154), lx, ly, font(11, 700), C.muted);
      text(fit(m.count + ' ' + cap(m.item) + ' · ' + Math.round(m.x) + ',' + Math.round(m.y), font(16, 600), w - 154), lx, ly + 19, font(16, 600), C.text);
    });
    text('SAMPLED POSITIONS' + (markers.length > ships.length ? ' · +' + (markers.length - ships.length) + ' MORE' : ''), mx, py + 127, font(10, 700), C.dim, {ls: .5});
    py += 134;
  }
  ps.forEach(p => {
    box(x + 12, py, w - 24, 1, C.seam);
    text(fit(cap(p.item) + ' · ' + p.price + ' coin each', font(17, 600), w - 30), x + 15, py + 20, font(17, 600), C.ink);
    const detail = p.a.toUpperCase() + ' ↔ ' + p.b.toUpperCase() + ' · ' + p.count + ' units · ' + (p.thin ? 'THIN: ONE PRINT' : p.prints + ' PRINTS') + ' · ' + clockOf(p.tick);
    text(fit(detail, font(11, 700), w - 30), x + 15, py + 36, font(11, 700), p.thin ? C.amber : C.muted);
    py += 45;
  });
  debug.market = {markers: ships.length, prices: ps.length, surface};
}

// ---- frame ------------------------------------------------------------------------------------------------------------
const debug = {feed: [], frames: 0};
function draw() {
  if (!hazardFill) patterns();
  fontNow = ''; spacingNow = -1; ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.globalAlpha = 1; ctx.textBaseline = 'alphabetic';
  ctx.clearRect(0, 0, W, H);
  const g = ctx.createLinearGradient(0, 0, 0, H); g.addColorStop(0, C.void0); g.addColorStop(1, C.void1); ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
  ctx.fillStyle = treadFill; ctx.fillRect(0, 0, W, H);
  ctx.clearRect(R.cam.x, R.cam.y, R.cam.w, R.cam.h);
  drawStrip(); drawRail(); drawBand(); drawMarket(); drawCamera();
  debug.frames++; if (debug.frames % 600 === 0) prune();
}
let queued = 0, lastDraw = 0;
const ambient = Q.get('ambient') !== '0';  // belts and lamps keep moving between changes
function frame() {
  queued = 0; const t = performance.now();
  if (t - lastDraw >= 30) { lastDraw = t; draw(); }
  if (ambient || T() < busyUntil) kick();
}
function kick() { if (!queued) queued = requestAnimationFrame(frame); }
function render(s) { ingest(s); draw(); kick(); }
async function poll() { try { const r = await fetch('/state.json', {cache: 'no-store'}); if (!r.ok) throw Error('unavailable'); render(await r.json()); } catch (e) { lost = true; draw(); } }
// For screenshots and tests: finish every animation and typed line now, or move the clock.
function settle() { settled = true; for (const a of tweens.values()) a.t0 = -1e9; for (let i = 0; i < 40 && feed.queue.length; i++) feedPump(); for (const it of feed.items) it.t0 = -1e9; news.banner = null; news.banners.length = 0; said.clear(); draw(); for (const a of tweens.values()) a.t0 = -1e9; draw(); settled = false; }
function advance(seconds) { shift += seconds; draw(); }
window.render = render; window.raceState = () => state; window.settle = settle; window.advance = advance; window.overlayDebug = debug;
if (document.fonts && document.fonts.addEventListener) document.fonts.addEventListener('loadingdone', () => { memo.clear(); kick(); });
['800 30px "Big Shoulders Display"', '900 40px "Big Shoulders Display"', '600 20px "Titillium Web"', '700 20px "Titillium Web"', 'italic 600 20px "Titillium Web"'].forEach(f => { if (document.fonts && document.fonts.load) document.fonts.load(f).then(() => { memo.clear(); kick(); }, () => {}); });
if (Q.get('poll') !== '0') { poll(); setInterval(poll, 2000); }
setInterval(() => { draw(); }, 500);  // a heartbeat if the page is not being composited
