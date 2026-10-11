#!/usr/bin/env node
/* In-game avatar parts: splits the avatar.js art into layers the agent-harness mod draws over each bot.
 *
 * Every part (base, helmet, visor, emblem, accessory, backdrop) becomes a few 24x24 layers:
 *   fixed      the pixels whose colour never changes (skin, metal, outlines on light suits), in their own colours;
 *   o s S h a A b g G V   one white mask per colour letter that depends on the suit or the accent; the runtime
 *              tints each mask with that letter's colour from the profile (same palette rules as avatar.js);
 *   glow1..4   the glow backdrop's rings (tinted from the suit);  star4..7  night stars that depend on the name.
 * Parts whose place depends on the base (helmets and accessories by the head's top row, visors by the eye row,
 * emblems by the chest) get one variant per distinct place, so stacking layers reproduces PogAvatar.pixels.
 *
 * Writes (from the repository root):
 *   vendor/factorio-harness/mod/agent-harness_0.1.0/graphics/avatar-parts.png   one sheet, CELL px per layer
 *   vendor/factorio-harness/mod/agent-harness_0.1.0/avatar_parts.lua            the layer table (data.lua + runtime)
 *
 *   node tools/stream/avatar_sprites_mod.js           regenerate both
 *   node tools/stream/avatar_sprites_mod.js --check   also composite what the runtime draws (run under lua with a fake
 *                                                 engine) for many profiles and compare with PogAvatar.pixels
 */
"use strict";
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const { execFileSync } = require("child_process");
const PogAvatar = require("./static/avatar.js");

const ROOT = path.resolve(__dirname, "../..");
const MOD = path.join(ROOT, "vendor/factorio-harness/mod/agent-harness_0.1.0");
const SIZE = 24, UP = 4, CELL = SIZE * UP, COLUMNS = 32;
const TINTED = "osShaAbgGV";
const P = PogAvatar.PARTS;

function blank() { return Array.from({ length: SIZE }, () => Array(SIZE).fill(null)); }
// Same placement and clipping as avatar.js stamp(), but keeps the letters.
function stamp(grid, rows, x0, y0, mirror) {
  rows.forEach((row, j) => {
    if (mirror) row = row + row.split("").reverse().join("");
    for (let i = 0; i < row.length; i++) {
      const ch = row[i], x = x0 + i, y = y0 + j;
      if (ch === "." || x < 0 || y < 0 || x >= SIZE || y >= SIZE) continue;
      grid[y][x] = ch;
    }
  });
  return grid;
}
// A letter grid -> layers: one fixed-colour layer and one mask per tinted letter.
function split(grid) {
  const layers = {};
  for (let y = 0; y < SIZE; y++) for (let x = 0; x < SIZE; x++) {
    const ch = grid[y][x];
    if (!ch) continue;
    const key = TINTED.includes(ch) ? ch : "fixed";
    layers[key] = layers[key] || blank();
    layers[key][y][x] = key === "fixed" ? P.fixed[ch] : "#ffffff";
  }
  return Object.keys(layers).sort().map(k => ({ key: k, px: layers[k] }));
}
function fill(colour) { return blank().map(r => r.map(() => colour)); }

const sprites = [];   // pixel grids, sprite i+1
const parts = {};     // part key -> [[sprite index, layer key], ...]
function add(partKey, layers) {
  parts[partKey] = layers.map(l => { sprites.push(l.px); return [sprites.length, l.key]; });
}
const uniq = list => [...new Set(list)].sort((a, b) => a - b);
const bases = P.bases;
const tops = uniq(Object.values(bases).map(b => b.top));
const eyes = uniq(Object.values(bases).map(b => b.eye));
const chests = [...new Set(Object.values(bases).map(b => b.chest.join(",")))].sort();

// Backdrops (avatar.js backdrop()).
for (const name of P.options.backdrop) {
  const bd = P.backdrops[name];
  if (name === "glow") {
    const rings = [blank(), blank(), blank(), blank()];
    for (let y = 0; y < SIZE; y++) for (let x = 0; x < SIZE; x++) {
      const d = Math.max(Math.abs(2 * x - 23), Math.abs(2 * y - 19)) >> 1;
      rings[d < 4 ? 0 : d < 7 ? 1 : d < 10 ? 2 : 3][y][x] = "#ffffff";
    }
    add("backdrop/glow", rings.map((px, i) => ({ key: "glow" + (i + 1), px })));
    continue;
  }
  const g = fill(bd.bg);
  let x, y;
  if (name === "dark") { for (x = 0; x < SIZE; x++) g[0][x] = bd.edge; for (y = 0; y < SIZE; y++) g[y][0] = bd.edge; }
  else if (name === "grid") { for (y = 0; y < SIZE; y++) for (x = 0; x < SIZE; x++) if (x % 6 === 2 || y % 6 === 2) g[y][x] = bd.line; }
  else if (name === "hazard") {
    for (y = 0; y < SIZE; y++) for (x = 0; x < SIZE; x++) {
      if ((x + y) % 8 < 3) g[y][x] = bd.stripe;
      if (y < 2) g[y][x] = bd.band[Math.floor((x + y) / 3) % 2];
    }
  }
  const layers = [{ key: "fixed", px: g }];
  if (name === "night") {
    const star = "#d8dcef";
    bd.stars.forEach((s, i) => {
      if (i < 4) g[s[1]][s[0]] = star;
      else { const one = blank(); one[s[1]][s[0]] = star; layers.push({ key: "star" + i, px: one }); }
    });
  }
  add("backdrop/" + name, layers);
}
for (const name of P.options.base) {
  const b = bases[name];
  add("base/" + name, split(stamp(blank(), b.rows, 0, 0, b.mirror)));
}
for (const name of P.options.helmet) {
  if (name === "none") continue;
  const h = P.helmets[name];
  for (const top of tops) add(`helmet/${name}/${top}`, split(stamp(blank(), h.rows, h.x, top + h.dy, h.mirror)));
}
for (const name of P.options.visor) {
  if (name === "none") continue;
  const v = P.visors[name];
  for (const eye of eyes) add(`visor/${name}/${eye}`, split(stamp(blank(), v.rows, v.x, eye + v.dy, v.mirror)));
}
for (const name of P.options.emblem) {
  if (name === "none") continue;
  for (const chest of chests) {
    const [cx, cy] = chest.split(",").map(Number);
    add(`emblem/${name}/${chest}`, split(stamp(blank(), P.emblems[name], cx, cy, false)));
  }
}
for (const name of P.options.accessory) {
  if (name === "none") continue;
  const a = P.accessories[name];
  for (const top of tops) add(`accessory/${name}/${top}`, split(stamp(blank(), a.rows, 0, top + a.dy, false)));
}

// PNG (RGBA, 8 bit) without dependencies.
const CRC = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
function crc32(buf) { let c = 0xffffffff; for (const b of buf) c = CRC[(c ^ b) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; }
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}
function png(width, height, rgba) {
  const raw = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y++) rgba.copy(raw, y * (width * 4 + 1) + 1, y * width * 4, (y + 1) * width * 4);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0); ihdr.writeUInt32BE(height, 4); ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr),
    chunk("IDAT", zlib.deflateSync(raw, { level: 9 })), chunk("IEND", Buffer.alloc(0))]);
}
function sheet() {
  const rows = Math.ceil(sprites.length / COLUMNS), width = COLUMNS * CELL, height = rows * CELL;
  const rgba = Buffer.alloc(width * height * 4);
  sprites.forEach((px, i) => {
    const ox = (i % COLUMNS) * CELL, oy = Math.floor(i / COLUMNS) * CELL;
    for (let y = 0; y < SIZE; y++) for (let x = 0; x < SIZE; x++) {
      const c = px[y][x];
      if (!c) continue;
      const n = parseInt(c.slice(1), 16);
      for (let dy = 0; dy < UP; dy++) for (let dx = 0; dx < UP; dx++) {
        const at = ((oy + y * UP + dy) * width + ox + x * UP + dx) * 4;
        rgba[at] = (n >> 16) & 255; rgba[at + 1] = (n >> 8) & 255; rgba[at + 2] = n & 255; rgba[at + 3] = 255;
      }
    }
  });
  return png(width, height, rgba);
}

function lua(v, indent) {
  if (Array.isArray(v)) return "{" + v.map(x => lua(x)).join(",") + "}";
  if (v && typeof v === "object") {
    const keys = Object.keys(v).sort();
    const nl = indent ? "\n  " : "";
    return "{" + nl + keys.map(k => (/^[a-z_][a-z0-9_]*$/.test(k) ? k : "[" + JSON.stringify(k) + "]") + "=" + lua(v[k])).join("," + nl) + (indent ? "\n" : "") + "}";
  }
  return JSON.stringify(v);
}
function table() {
  const meta = {};
  for (const [name, b] of Object.entries(bases)) meta[name] = { top: b.top, eye: b.eye, chest: b.chest.join(",") };
  const layer = {};
  for (const [name, a] of Object.entries(P.accessories)) layer[name] = a.layer;
  const data = {
    cell: CELL, scale: 1 / UP, columns: COLUMNS, count: sprites.length, prefix: "agent-harness-avatar-",
    sheet: "__agent-harness__/graphics/avatar-parts.png",
    fields: P.fields, options: P.options, colors: P.colors, accents: P.accents, outline: P.fixed.o,
    glow_bg: P.backdrops.glow.bg, glow_t: [0.34, 0.24, 0.14, 0.06], bases: meta, accessory_layer: layer, parts,
  };
  return "-- Generated by tools/stream/avatar_sprites_mod.js from tools/stream/static/avatar.js; do not edit.\n" +
    "-- Avatar part layers: data.lua makes one sprite per layer, avatar.lua picks and tints them.\nreturn " + lua(data, true) + "\n";
}

function check() {
  // The runtime's draw list for many profiles, composited here, must equal PogAvatar.pixels.
  const rows = [];
  for (let i = 0; i < 400; i++) {
    const row = { name: i % 7 === 0 ? "agent" + i : "a" + PogAvatar.hash("n" + i).toString(36), avatar: PogAvatar.random(i) };
    if (i % 3) row.color = "#" + (PogAvatar.hash("c" + i) & 0xffffff).toString(16).padStart(6, "0");
    if (i % 11 === 0) row.color = "#101010";
    if (i % 13 === 0) delete row.avatar;
    if (i % 17 === 0) row.avatar = { base: "biter", helmet: "hood", emblem: "rocket", accessory: "antenna" };
    rows.push(row);
  }
  const fake = rows.map(r => `{name=${JSON.stringify(r.name)},color=${r.color ? JSON.stringify(r.color) : "nil"},avatar=${r.avatar ? lua(r.avatar) : "nil"}}`).join(",\n");
  const driver = `package.path='${MOD}/?.lua;'..package.path
local avatar=require('avatar')(require('avatar_parts'))
for _,row in ipairs({${fake}}) do
  local out={}
  for _,l in ipairs(avatar.layers(row.name,row.color,row.avatar)) do
    local t=l.tint
    out[#out+1]=l.sprite..':'..(t and string.format('%d,%d,%d',math.floor(t.r*255+0.5),math.floor(t.g*255+0.5),math.floor(t.b*255+0.5)) or '-')
  end
  io.write(table.concat(out,' '),'\\n')
end`;
  const out = execFileSync(process.env.LUA_BIN || "lua", ["-"], { input: driver }).toString().trim().split("\n");
  let bad = 0;
  rows.forEach((row, n) => {
    const want = PogAvatar.pixels(row), got = blank();
    for (const item of out[n].split(" ")) {
      const [name, tint] = item.split(":");
      const px = sprites[Number(name.slice("agent-harness-avatar-".length)) - 1];
      const rgb = tint === "-" ? null : tint.split(",").map(Number);
      for (let y = 0; y < SIZE; y++) for (let x = 0; x < SIZE; x++) {
        const c = px[y][x];
        if (!c) continue;
        got[y][x] = rgb ? "#" + rgb.map(v => v.toString(16).padStart(2, "0")).join("") : c;
      }
    }
    const diff = [];
    for (let y = 0; y < SIZE; y++) for (let x = 0; x < SIZE; x++) if (got[y][x] !== want[y][x]) diff.push(`${x},${y} ${got[y][x]} vs ${want[y][x]}`);
    if (diff.length) { bad++; if (bad <= 5) console.error(JSON.stringify(row), diff.slice(0, 4).join("; ")); }
  });
  if (bad) { console.error(`${bad} of ${rows.length} avatars differ`); process.exit(1); }
  console.log(`avatar sprites: ${rows.length} profiles composite to PogAvatar.pixels`);
}

const png_out = sheet(), table_out = table();
fs.mkdirSync(path.join(MOD, "graphics"), { recursive: true });
fs.writeFileSync(path.join(MOD, "graphics/avatar-parts.png"), png_out);
fs.writeFileSync(path.join(MOD, "avatar_parts.lua"), table_out);
console.log(`${sprites.length} layers, sheet ${COLUMNS * CELL}x${Math.ceil(sprites.length / COLUMNS) * CELL} (${png_out.length} bytes), table ${table_out.length} bytes`);
if (process.argv.includes("--check")) check();
