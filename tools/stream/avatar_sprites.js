#!/usr/bin/env node
// Exports the avatar.js parts as Factorio sprite layers for drawing agent avatars in-game.
//   node tools/stream/avatar_sprites.js           write tools/stream/sprites/avatar-parts.png and avatar_sprites.lua
//   node tools/stream/avatar_sprites.js --check   also verify: layers composited with their tints equal avatar.js's
//                                                 pixels, read back from the PNG, and the Lua module (run with
//                                                 `lua`) gives the same layers and tints as this script
//   --out DIR        write there instead (test_avatar.py compares that with the committed files)
//   --preview FILE   also write the atlas over dark grey at half size, for looking at it
//
// Every layer is a full 24x24 avatar canvas scaled x4 (96x96 px), so all layers share one size and one anchor (the
// centre) and are drawn at the same position. A layer is either a white mask, tinted at runtime with one colour of
// the avatar's palette (suit, suit shade, accent, outline, ...), or an untinted "detail" layer (skin, metal, fixed
// colours). Masks are pure white, so tint = final colour exactly. Spec: docs/ART-NOTES.md "Sprites for the game".
"use strict";
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const { execFileSync } = require("child_process");
const A = require("./static/avatar.js");
const P = A.PARTS;

const N = 24, SCALE = 4, CELL = N * SCALE, GAP = 4, PITCH = CELL + GAP, COLS = 20;
const OUT = process.argv.includes("--out") ? path.resolve(process.argv[process.argv.indexOf("--out") + 1]) : path.join(__dirname, "sprites");
// Palette letters that depend on the agent's colours: each gets its own white mask layer.
const PAINTS = { o: "outline", s: "suit", S: "suitdark", h: "suitlight", a: "accent", A: "accentdark",
  b: "accentlight", g: "accentsoft", G: "accentpale", V: "accentglow" };
const GLOW_T = [0.34, 0.24, 0.14, 0.06]; // glow backdrop rings, inside out (avatar.js backdrop())
const PAINT_ORDER = Object.keys(PAINTS).concat(["glow1", "glow2", "glow3", "glow4"]);

// ---------- part images: 24x24 grids of null | {paint} | "#rrggbb" ----------
const blank = () => Array.from({ length: N }, () => Array(N).fill(null));
function stamp(grid, rows, x0, y0, mirror) {
  rows.forEach((r, j) => {
    const row = mirror ? r + [...r].reverse().join("") : r;
    [...row].forEach((ch, i) => {
      const x = x0 + i, y = y0 + j;
      if (ch === "." || x < 0 || y < 0 || x >= N || y >= N) return;
      grid[y][x] = PAINTS[ch] ? { paint: ch } : P.fixed[ch];
    });
  });
  return grid;
}
function backdropImages(name) {
  const bd = P.backdrops[name], g = blank(), extra = {};
  for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) g[y][x] = bd.bg;
  if (name === "dark") {
    for (let x = 0; x < N; x++) g[0][x] = bd.edge;
    for (let y = 0; y < N; y++) g[y][0] = bd.edge;
  } else if (name === "grid") {
    for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) if (x % 6 === 2 || y % 6 === 2) g[y][x] = bd.line;
  } else if (name === "hazard") {
    for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
      if ((x + y) % 8 < 3) g[y][x] = bd.stripe;
      if (y < 2) g[y][x] = bd.band[Math.floor((x + y) / 3) % 2];
    }
  } else if (name === "glow") {
    for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
      const d = Math.max(Math.abs(2 * x - 23), Math.abs(2 * y - 19)) >> 1;
      g[y][x] = { paint: "glow" + (d < 4 ? 1 : d < 7 ? 2 : d < 10 ? 3 : 4) };
    }
  } else if (name === "night") {
    // stars 0-3 always shine; 4-7 follow bits of the name's hash, so each is its own layer
    bd.stars.forEach((s, i) => {
      if (i < 4) g[s[1]][s[0]] = "#d8dcef";
      else { const m = blank(); m[s[1]][s[0]] = "#d8dcef"; extra["star" + i] = m; }
    });
  }
  return { main: g, extra };
}

// Split one part image into layers: one mask per paint, plus one detail layer for fixed colours.
function split(grid) {
  const layers = {};
  for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
    const c = grid[y][x];
    if (!c) continue;
    const key = typeof c === "string" ? "detail" : c.paint;
    if (!layers[key]) layers[key] = blank();
    layers[key][y][x] = typeof c === "string" ? c : "#ffffff";
  }
  return PAINT_ORDER.concat(["detail"]).filter((k) => layers[k]).map((k) => ({ paint: k, grid: layers[k] }));
}

// ---------- every sprite ----------
const LAYERS = {};  // part key -> [[sprite name, paint], ...]
const IMAGES = {};  // sprite name -> grid
function add(key, spriteBase, grid) {
  LAYERS[key] = split(grid).map(({ paint, grid: g }) => {
    const name = spriteBase + "-" + (paint === "detail" ? "detail" : PAINTS[paint] || paint);
    IMAGES[name] = g;
    return [name, paint];
  });
}
for (const bd of P.options.backdrop) {
  const { main, extra } = backdropImages(bd);
  add("backdrop/" + bd, "pogav-backdrop-" + bd, main);
  for (const [k, g] of Object.entries(extra)) add("backdrop/" + bd + "/" + k, "pogav-backdrop-" + bd + "-" + k, g);
}
for (const b of P.options.base) {
  const base = P.bases[b];
  add(b + "/base", "pogav-" + b + "-base", stamp(blank(), base.rows, 0, 0, base.mirror));
  for (const e of P.options.emblem) if (e !== "none")
    add(b + "/emblem/" + e, "pogav-" + b + "-emblem-" + e, stamp(blank(), P.emblems[e], base.chest[0], base.chest[1], false));
  for (const h of P.options.helmet) if (h !== "none") {
    const hm = P.helmets[h];
    add(b + "/helmet/" + h, "pogav-" + b + "-helmet-" + h, stamp(blank(), hm.rows, hm.x, base.top + hm.dy, hm.mirror));
  }
  for (const v of P.options.visor) if (v !== "none") {
    const vs = P.visors[v];
    add(b + "/visor/" + v, "pogav-" + b + "-visor-" + v, stamp(blank(), vs.rows, vs.x, base.eye + vs.dy, vs.mirror));
  }
  for (const a of P.options.accessory) if (a !== "none") {
    const acc = P.accessories[a];
    add(b + "/accessory/" + a, "pogav-" + b + "-accessory-" + a, stamp(blank(), acc.rows, 0, base.top + acc.dy, false));
  }
}
const ACC_LAYER = {};
for (const a of P.options.accessory) if (a !== "none") ACC_LAYER[a] = P.accessories[a].layer;

// ---------- atlas (identical images share a cell) ----------
const cellOf = {}, SPRITES = {};
let cells = 0;
for (const [name, g] of Object.entries(IMAGES)) {
  const key = JSON.stringify(g);
  if (!(key in cellOf)) cellOf[key] = cells++;
  const i = cellOf[key];
  SPRITES[name] = [(i % COLS) * PITCH, Math.floor(i / COLS) * PITCH];
}
const W = Math.min(cells, COLS) * PITCH - GAP, H = Math.ceil(cells / COLS) * PITCH - GAP;
const rgba = Buffer.alloc(W * H * 4);
for (const [name, g] of Object.entries(IMAGES)) {
  const [x0, y0] = SPRITES[name];
  for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
    const c = g[y][x];
    if (!c) continue;
    const v = [1, 3, 5].map((k) => parseInt(c.slice(k, k + 2), 16));
    for (let dy = 0; dy < SCALE; dy++) for (let dx = 0; dx < SCALE; dx++) {
      const o = ((y0 + y * SCALE + dy) * W + x0 + x * SCALE + dx) * 4;
      rgba[o] = v[0]; rgba[o + 1] = v[1]; rgba[o + 2] = v[2]; rgba[o + 3] = 255;
    }
  }
}
function png(w, h, data) {
  const crcT = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
  const crc = (b) => { let c = 0xffffffff; for (const x of b) c = crcT[(c ^ x) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
  const chunk = (t, d) => { const l = Buffer.alloc(4), c = Buffer.alloc(4), td = Buffer.concat([Buffer.from(t), d]); l.writeUInt32BE(d.length); c.writeUInt32BE(crc(td)); return Buffer.concat([l, td, c]); };
  const raw = Buffer.alloc(h * (w * 4 + 1));
  for (let y = 0; y < h; y++) data.copy(raw, y * (w * 4 + 1) + 1, y * w * 4, (y + 1) * w * 4);
  const ih = Buffer.alloc(13); ih.writeUInt32BE(w, 0); ih.writeUInt32BE(h, 4); ih[8] = 8; ih[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ih), chunk("IDAT", zlib.deflateSync(raw, { level: 9 })), chunk("IEND", Buffer.alloc(0))]);
}

// ---------- palette and layer list for one profile (the Lua module ports exactly this) ----------
const W8 = [255, 255, 255], B8 = [0, 0, 0];
const parse = (h) => [1, 3, 5].map((k) => parseInt(h.slice(k, k + 2), 16));
const hex = (c) => "#" + c.map((v) => (v < 16 ? "0" : "") + v.toString(16)).join("");
const mix = (a, b, t) => [0, 1, 2].map((i) => Math.floor(a[i] + (b[i] - a[i]) * t + 0.5));
const luma = (c) => (c[0] * 299 + c[1] * 587 + c[2] * 114) / 255000;
function palette(spec) {
  const suit = parse(spec.color), accent = parse(spec.accent), dark = luma(suit) < 0.16;
  const p = {
    o: dark ? hex(mix(suit, W8, 0.42)) : P.fixed.o,
    s: hex(dark ? mix(suit, W8, 0.1) : suit),
    S: hex(dark ? mix(suit, W8, 0.04) : mix(suit, B8, 0.32)),
    h: hex(mix(suit, W8, dark ? 0.26 : 0.38)),
    a: hex(accent), A: hex(mix(accent, B8, 0.3)), b: hex(mix(accent, W8, 0.4)), g: hex(mix(accent, W8, 0.2)),
    G: hex(mix(accent, W8, 0.72)), V: hex(mix(accent, W8, 0.62)),
  };
  GLOW_T.forEach((t, i) => { p["glow" + (i + 1)] = hex(mix(parse(P.backdrops.glow.bg), suit, t)); });
  return p;
}
const nameOf = (profile) => String((profile && (profile.name || profile.display_name)) || "agent");
function layers(profile, backdrop = true) {
  const spec = A.resolve(profile), pal = palette(spec), out = [];
  const put = (key) => (LAYERS[key] || []).forEach(([sprite, paint]) => out.push(paint === "detail" ? sprite : sprite + "|" + pal[paint]));
  if (backdrop) {
    put("backdrop/" + spec.backdrop);
    if (spec.backdrop === "night") {
      const h = A.hash(nameOf(profile));
      for (let i = 4; i < 8; i++) if (((h >>> i) & 1) === 0) put("backdrop/night/star" + i);
    }
  }
  const b = spec.base;
  if (spec.accessory !== "none" && ACC_LAYER[spec.accessory] === "back") put(b + "/accessory/" + spec.accessory);
  put(b + "/base");
  if (spec.emblem !== "none") put(b + "/emblem/" + spec.emblem);
  if (spec.helmet !== "none") put(b + "/helmet/" + spec.helmet);
  if (spec.visor !== "none") put(b + "/visor/" + spec.visor);
  if (spec.accessory !== "none" && ACC_LAYER[spec.accessory] === "front") put(b + "/accessory/" + spec.accessory);
  return out;
}

// ---------- Lua module ----------
function lua(v, ind = "") {
  if (Array.isArray(v)) return "{" + v.map((x) => lua(x, ind)).join(", ") + "}";
  if (v && typeof v === "object") {
    const inner = ind + "  ";
    return "{\n" + Object.entries(v).map(([k, x]) => inner + (/^[A-Za-z_]\w*$/.test(k) ? k : "[" + JSON.stringify(k) + "]") + " = " + lua(x, inner)).join(",\n") + "\n" + ind + "}";
  }
  return JSON.stringify(v);
}
const LUA_DATA = {
  FILE: "avatar-parts.png", CELL, SCALE,
  OPTIONS: P.options, FIELDS: P.fields, PICKS: P.picks, COLORS: P.colors, ACCENTS: P.accents,
  OUTLINE: P.fixed.o, GLOW_BG: P.backdrops.glow.bg, GLOW_T, ACC_LAYER, SPRITES, LAYERS,
};
const LUA_CODE = String.raw`
-- Arithmetic 32-bit helpers: no bit32 or integer operators, so this runs in Factorio's Lua 5.2 and in Lua 5.3+.
local P32 = 4294967296
local function bitop(a, b, orop)
  local r, bit = 0, 1
  for _ = 1, 32 do
    local x, y = a % 2, b % 2
    if (orop and (x + y > 0)) or (not orop and x + y == 1) then r = r + bit end
    a = (a - x) / 2; b = (b - y) / 2; bit = bit * 2
  end
  return r
end
local function bxor(a, b) return bitop(a, b, false) end
local function bor(a, b) return bitop(a, b, true) end
local function shr(a, n) local d = 2 ^ n; return (a - a % d) / d end
local function imul(a, b)
  local al, bl = a % 65536, b % 65536
  local ah, bh = (a - al) / 65536, (b - bl) / 65536
  return ((ah * bl + al * bh) % 65536 * 65536 + al * bl) % P32
end

-- 32-bit FNV-1a over the name's UTF-8 bytes, as avatar.js
function M.hash(text)
  local h = 2166136261
  for i = 1, #text do h = imul(bxor(h, text:byte(i)), 16777619) end
  return h
end
local function rng(seed)
  local a = seed
  return function()
    a = (a + 1831565813) % P32
    local t = a
    t = imul(bxor(t, shr(t, 15)), bor(t, 1))
    t = bxor(t, (t + imul(bxor(t, shr(t, 7)), bor(t, 61))) % P32)
    return bxor(t, shr(t, 14)) % 1000003
  end
end

local function is_hex(v) return type(v) == "string" and v:match("^#%x%x%x%x%x%x$") ~= nil end
local function parse(h) return {tonumber(h:sub(2, 3), 16), tonumber(h:sub(4, 5), 16), tonumber(h:sub(6, 7), 16)} end
local function hex(c) return string.format("#%02x%02x%02x", math.floor(c[1]), math.floor(c[2]), math.floor(c[3])) end
local function mix(a, b, t)
  return {math.floor(a[1] + (b[1] - a[1]) * t + 0.5), math.floor(a[2] + (b[2] - a[2]) * t + 0.5), math.floor(a[3] + (b[3] - a[3]) * t + 0.5)}
end
local function luma(c) return (c[1] * 299 + c[2] * 587 + c[3] * 114) / 255000 end
local function dist(a, b) return math.abs(a[1] - b[1]) + math.abs(a[2] - b[2]) + math.abs(a[3] - b[3]) end
local function has(list, v) for _, x in ipairs(list) do if x == v then return true end end return false end
local WHITE, BLACK = {255, 255, 255}, {0, 0, 0}

local function name_of(profile)
  local n = profile.name
  if n == nil or n == "" then n = profile.display_name end
  if n == nil or n == "" then n = "agent" end
  return tostring(n)
end

-- The spec actually drawn for a profiles row {name, display_name, color, avatar}; same as PogAvatar.resolve.
function M.resolve(profile)
  profile = profile or {}
  local av = type(profile.avatar) == "table" and profile.avatar or {}
  local next = rng(M.hash(name_of(profile)))
  local out = {}
  for _, f in ipairs(M.FIELDS) do
    local list, r = M.OPTIONS[f], next()
    local pool = M.PICKS[f] or list
    out[f] = has(list, av[f]) and av[f] or pool[r % #pool + 1]
  end
  local color_pick, accent_pick = next(), next()
  local suit = is_hex(profile.color) and parse(profile.color) or parse(M.COLORS[color_pick % #M.COLORS + 1])
  out.color = hex(suit)
  local accent = is_hex(av.accent) and parse(av.accent) or nil
  if not accent then
    local n = #M.ACCENTS
    for i = 0, n - 1 do
      local c = parse(M.ACCENTS[(accent_pick + i) % n + 1])
      if dist(c, suit) >= 180 then accent = c break end
    end
    accent = accent or parse(M.ACCENTS[accent_pick % n + 1])
  end
  out.accent = hex(accent)
  return out
end

-- Tint colour for each paint, "#rrggbb"; same rules as avatar.js palette() (near-black suits get a light rim).
function M.palette(spec)
  local suit, accent = parse(spec.color), parse(spec.accent)
  local dark = luma(suit) < 0.16
  local p = {
    o = dark and hex(mix(suit, WHITE, 0.42)) or M.OUTLINE,
    s = hex(dark and mix(suit, WHITE, 0.1) or suit),
    S = hex(dark and mix(suit, WHITE, 0.04) or mix(suit, BLACK, 0.32)),
    h = hex(mix(suit, WHITE, dark and 0.26 or 0.38)),
    a = hex(accent), A = hex(mix(accent, BLACK, 0.3)), b = hex(mix(accent, WHITE, 0.4)),
    g = hex(mix(accent, WHITE, 0.2)), G = hex(mix(accent, WHITE, 0.72)), V = hex(mix(accent, WHITE, 0.62)),
  }
  for i, t in ipairs(M.GLOW_T) do p["glow" .. i] = hex(mix(parse(M.GLOW_BG), suit, t)) end
  return p
end

-- Layers to draw, bottom to top: {sprite = name, tint = {r, g, b, a} or nil, hex = "#rrggbb" or nil}.
-- Draw every layer at the same target, offset and scale. opts.backdrop = false leaves out the square backdrop.
function M.layers(profile, opts)
  profile, opts = profile or {}, opts or {}
  local spec = M.resolve(profile)
  local pal = M.palette(spec)
  local out = {}
  local function put(key)
    for _, l in ipairs(M.LAYERS[key] or {}) do
      local h = l[2] ~= "detail" and pal[l[2]] or nil
      local c = h and parse(h)
      out[#out + 1] = {sprite = l[1], hex = h, tint = c and {r = c[1] / 255, g = c[2] / 255, b = c[3] / 255, a = 1} or nil}
    end
  end
  if opts.backdrop ~= false then
    put("backdrop/" .. spec.backdrop)
    if spec.backdrop == "night" then
      local h = M.hash(name_of(profile))
      for i = 4, 7 do if shr(h, i) % 2 == 0 then put("backdrop/night/star" .. i) end end
    end
  end
  local b, acc = spec.base, spec.accessory
  if acc ~= "none" and M.ACC_LAYER[acc] == "back" then put(b .. "/accessory/" .. acc) end
  put(b .. "/base")
  if spec.emblem ~= "none" then put(b .. "/emblem/" .. spec.emblem) end
  if spec.helmet ~= "none" then put(b .. "/helmet/" .. spec.helmet) end
  if spec.visor ~= "none" then put(b .. "/visor/" .. spec.visor) end
  if acc ~= "none" and M.ACC_LAYER[acc] == "front" then put(b .. "/accessory/" .. acc) end
  return out, spec
end

-- Data stage: one sprite prototype per entry of M.SPRITES, e.g.
--   for _, p in pairs(require("avatar_sprites").prototypes("__agent-harness__/graphics/avatar-parts.png", 0.5)) do data:extend{p} end
function M.prototypes(filename, scale)
  local out = {}
  for name, xy in pairs(M.SPRITES) do
    out[#out + 1] = {type = "sprite", name = name, filename = filename, x = xy[1], y = xy[2],
      width = M.CELL, height = M.CELL, scale = scale or 0.5, flags = {"no-crop"}}
  end
  return out
end

return M
`;

function writeLua() {
  const head = "-- Agent avatar sprite layers: generated by tools/stream/avatar_sprites.js from tools/stream/static/avatar.js.\n" +
    "-- Do not edit; change the art in avatar.js and regenerate. Spec: docs/ART-NOTES.md \"Sprites for the game\".\n" +
    "-- Works in the data stage (M.prototypes) and the control stage (M.layers); touches no game API itself.\n";
  const data = Object.entries(LUA_DATA).map(([k, v]) => "M." + k + " = " + lua(v)).join("\n");
  return head + "local M = {}\n" + data + "\n" + LUA_CODE;
}

fs.mkdirSync(OUT, { recursive: true });
fs.writeFileSync(path.join(OUT, "avatar-parts.png"), png(W, H, rgba));
fs.writeFileSync(path.join(OUT, "avatar_sprites.lua"), writeLua());
console.log("sprites: %d layers in %d cells, atlas %dx%d px, %d part keys", Object.keys(SPRITES).length, cells, W, H, Object.keys(LAYERS).length);

// ---------- --preview FILE: the atlas on dark grey (white masks are invisible on white), half size ----------
const pi = process.argv.indexOf("--preview");
if (pi > 0) {
  const w = Math.ceil(W / 2), h = Math.ceil(H / 2), out = Buffer.alloc(w * h * 4);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const o = (y * w + x) * 4, s = ((y * 2) * W + x * 2) * 4, a = rgba[s + 3] / 255;
    const bg = ((x >> 3) + (y >> 3)) % 2 ? 0x3a : 0x44;
    for (let k = 0; k < 3; k++) out[o + k] = Math.round(rgba[s + k] * a + bg * (1 - a));
    out[o + 3] = 255;
  }
  fs.writeFileSync(process.argv[pi + 1], png(w, h, out));
}

// ---------- --check ----------
if (process.argv.includes("--check")) {
  const profiles = [];
  const colors = [undefined, "#9977ff", "#1a1a1a", "#000000", "#ffffff", "#ffcb45", "#4285F4"];
  for (const k of ["astra", "sol", "luna", "opus", "sonnet", "haiku", "grok", "gemini", "muse"]) profiles.push({ name: k });
  for (let i = 0; i < 300; i++) profiles.push({ name: "agent" + i, color: colors[i % colors.length], avatar: i % 4 ? A.random(i) : undefined });
  profiles.push({ name: "", display_name: "Shown Name", color: "#d97757" }, { name: "ñandú 👩‍🚀", avatar: { base: "drone", accent: "#ABCDEF" } });
  const C = require("./static/casters.js");
  C.keys.forEach((k) => profiles.push(C.row(k)));

  // 1) composite from the atlas (sampling each 4x4 block) and compare with avatar.js
  let bad = 0;
  for (const p of profiles) {
    const want = A.pixels(p), got = blank();
    for (const l of layers(p)) {
      const [sprite, tint] = l.split("|"), [x0, y0] = SPRITES[sprite];
      for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
        const o = ((y0 + y * SCALE + 1) * W + x0 + x * SCALE + 1) * 4;
        if (rgba[o + 3] !== 255) continue;
        const px = [rgba[o], rgba[o + 1], rgba[o + 2]];
        got[y][x] = tint ? hex(parse(tint).map((t, i) => Math.round((t * px[i]) / 255))) : hex(px);
      }
    }
    if (JSON.stringify(got) !== JSON.stringify(want)) { if (bad++ < 3) console.log("composite differs:", JSON.stringify(p)); }
  }
  // 2) the Lua module gives the same layer lists
  const tmp = fs.mkdtempSync(path.join(require("os").tmpdir(), "avsprites-"));
  const luaRows = profiles.map((p) => "{" + [p.name != null ? "name=" + JSON.stringify(p.name) : "", p.display_name ? "display_name=" + JSON.stringify(p.display_name) : "",
    p.color ? "color=" + JSON.stringify(p.color) : "", p.avatar ? "avatar=" + lua(p.avatar) : ""].filter(Boolean).join(",") + "}");
  fs.writeFileSync(path.join(tmp, "check.lua"), "package.path = " + JSON.stringify(path.join(OUT, "?.lua") + ";") + " .. package.path\n" +
    "local M = require('avatar_sprites')\nfor _, p in ipairs({" + luaRows.join(",\n") + "}) do\n" +
    "  local t = {}\n  for _, l in ipairs(M.layers(p)) do t[#t + 1] = l.hex and (l.sprite .. '|' .. l.hex) or l.sprite end\n" +
    "  print(table.concat(t, ' '))\nend\n" +
    "local n = 0 for _ in pairs(M.prototypes('x.png')) do n = n + 1 end print('prototypes ' .. n)\n");
  const outLines = execFileSync(process.env.LUA_BIN || "lua", [path.join(tmp, "check.lua")], { encoding: "utf8" }).trim().split("\n");
  let luaBad = 0;
  profiles.forEach((p, i) => { if (outLines[i] !== layers(p).join(" ")) { if (luaBad++ < 3) console.log("Lua differs:", JSON.stringify(p), "\n  lua:", outLines[i], "\n  js: ", layers(p).join(" ")); } });
  const protoLine = outLines[profiles.length];
  if (protoLine !== "prototypes " + Object.keys(SPRITES).length) { luaBad++; console.log("Lua prototypes:", protoLine); }
  fs.rmSync(tmp, { recursive: true, force: true });
  const counts = profiles.map((p) => layers(p, false).length);
  console.log("check: %d profiles; composite %s; Lua %s; layers per avatar without backdrop %d-%d", profiles.length,
    bad ? bad + " differ" : "identical to avatar.js", luaBad ? luaBad + " differ" : "identical", Math.min(...counts), Math.max(...counts));
  process.exitCode = bad || luaBad ? 1 : 0;
}
