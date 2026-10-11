/* Agent avatars: small parametric pixel-art portraits in a Factorio mood.
 *
 * An agent picks a few named parts with the harness `profile` action:
 *   {"avatar": {"base": "robot", "helmet": "power", "visor": "mono", "emblem": "gear",
 *               "accessory": "antenna", "backdrop": "hazard", "accent": "#33ccff"}}
 * Every field is optional. Unset (or unknown) parts follow from the agent's name, so an agent with no avatar
 * still gets a stable portrait from its name and colour. The suit is the profile colour; `accent` is the second
 * colour (hardhat, emblem, glow), otherwise picked from the name to contrast with the suit.
 *
 * Dependency-free. Browser: <script src="avatar.js"></script> then PogAvatar.svg(profileRow, 48).
 * Node: const PogAvatar = require("./avatar.js").  Python port: tools/stream/avatar.py (reads PARTS from this file).
 *
 * API
 *   PogAvatar.svg(profile, size?, opts?)  SVG string. profile = a `profiles` row ({name, color, avatar, display_name})
 *                                         opts.title: aria-label text (default "<display name> avatar")
 *   PogAvatar.resolve(profile)            the full spec actually drawn: {base, helmet, visor, emblem, accessory,
 *                                         backdrop, color, accent}
 *   PogAvatar.pixels(profile)             24 rows of 24 "#rrggbb" strings (null = transparent; never with a backdrop)
 *   PogAvatar.random(seed)                a random valid avatar spec (for galleries and tests)
 *   PogAvatar.validate(avatar)            list of error strings, same rules as the harness (empty = valid)
 *   PogAvatar.PARTS                       the part lists
 *
 * All art is original: hand-placed pixels on a 24x24 grid, no game sprites.
 */
(function (root) {
  "use strict";

  // Shared with tools/stream/avatar.py: strict JSON between the markers.
  /*@parts*/
  var PARTS = {
    "fields": ["base", "helmet", "visor", "emblem", "accessory", "backdrop"],
    "options": {
      "base": ["engineer", "robot", "biter", "drone"],
      "helmet": ["none", "hardhat", "armor", "power", "crest", "hood"],
      "visor": ["none", "goggles", "slit", "wide", "mono", "grid"],
      "emblem": ["none", "gear", "bolt", "flask", "plate", "circuit", "rocket", "leaf", "star"],
      "accessory": ["none", "antenna", "headlamp", "scarf", "tank", "horns", "earpiece", "pipe", "headset"],
      "backdrop": ["dark", "grid", "hazard", "glow", "night"]
    },
    "picks": {
      "accessory": ["none", "antenna", "headlamp", "scarf", "tank", "horns", "earpiece", "pipe"]
    },
    "colors": ["#e8743b", "#5aa9ff", "#2fbf71", "#ffcb45", "#b58cff", "#ff6b8a", "#3ddcc4", "#c8c8c0",
               "#ff9f1c", "#8fd14f", "#7dd3fc", "#d97757"],
    "accents": ["#ffb627", "#ff6a2b", "#3ee0ff", "#7cff6b", "#ff4d6d", "#f2f2f2", "#ffd94a", "#5b8cff"],
    "fixed": {
      "o": "#14110f", "m": "#c4c2bc", "M": "#85827c", "n": "#45423f", "k": "#e3b48a", "K": "#b9825a",
      "r": "#3a2a20", "R": "#5e4434", "x": "#141414", "w": "#efeadf", "v": "#1a2630", "y": "#f0b429",
      "Y": "#1d1b18", "B": "#ddd2b2", "N": "#a59c7f", "p": "#7d7b78", "P": "#b3b0aa", "l": "#fff6c2",
      "L": "#f5c542"
    },
    "bases": {
      "engineer": {"top": 4, "eye": 10, "chest": [9, 17], "mirror": true, "rows": [
        "............", "............", "............", "............",
        "........oooo", ".......orrRR", "......orrrrr", "......orkkkk",
        "......okkkkk", "......okkkkk", "......okkxkk", "......okkkkk",
        "......oKkkkk", ".......oKkkK", "........oKKK", ".........okk",
        "......ooonSs", "....oohhssSs", "...ohhssssss", "..ohssssssss",
        "..ohssssssss", ".ohsssssssss", ".ohsssssssss", ".ohsssssssss"]},
      "robot": {"top": 4, "eye": 9, "chest": [9, 18], "mirror": true, "rows": [
        "............", "............", "............", "............",
        "......oooooo", ".....ommmmmm", ".....omhhhhh", ".....omsssss",
        ".....omsssss", ".....omsggss", ".....omsggss", ".....omsssss",
        ".....omSSSSS", ".....ommmmmm", "......oMnMnM", "........onMn",
        "......oonnnn", "....oommssss", "...omMmsssss", "..omMmssssss",
        "..oMMmssssss", ".omMmsssssss", ".omMmsssssss", ".omMmsssssss"]},
      "biter": {"top": 5, "eye": 10, "chest": [9, 18], "mirror": true, "rows": [
        "............", "............", "............", "............",
        "............", "........oooo", "......oohhhh", ".....ohhssSs",
        "....ohsssSss", "...ohssssSss", "..ohsssssSss", "..osssssSsss",
        "..oSssssSsss", "...oSSSSSSSS", "...oggoonnnn", "....oonnnnBo",
        "......onnBBo", "..oo...oBBo.", ".oSSo.ohSSSS", "oSo..ohsssss",
        "So..ohssssss", "So.ohsssssss", "o..ohsssssss", "...ohsssssss"]},
      "drone": {"top": 4, "eye": 9, "chest": [9, 17], "mirror": true, "rows": [
        "............", "............", "............", "............",
        "........oooo", "......oohhhh", ".....ohhssss", ".....ohsssss",
        "....ohssssss", "....ohssggss", "....ohssggss", "....osssssss",
        "....oSssssss", ".....oSSssss", ".....ommmmmm", "......onnnnn",
        "oooooo.oMmmm", "nMMMMn.oMsss", "..on...oMsss", "..oMoooonsss",
        "...o...oMSSS", "........oggg", ".........oGg", "..........og"]}
    },
    "helmets": {
      "hardhat": {"x": 4, "dy": -2, "mirror": true, "rows": [
        "....oooo", "...oabbb", "..oaaaab", "..oaaaaa", "oAAAAAAA", ".ooooooo"]},
      "armor": {"x": 4, "dy": -2, "mirror": true, "rows": [
        "......oo", "....oomm", "...ommmm", "..ommmmm", "..omMmmm", "..omMooo",
        "..omMo..", "..omMo..", "..omMo..", "..omMo..", "..omMo..", "...oMMoo"]},
      "power": {"x": 4, "dy": -3, "mirror": true, "rows": [
        ".......o", "......oa", "....ooas", "...ohhss", "..ohssss", "..ohssss", ".oAhSooo",
        ".oAhSo..", ".oAhSo..", "..ohSo..", "..ohSo..", "...oSSoo", "....oooo"]},
      "crest": {"x": 4, "dy": -4, "mirror": true, "rows": [
        "......oo", ".....oaa", "......ob", ".....oab", "......oa"]},
      "hood": {"x": 4, "dy": -2, "mirror": true, "rows": [
        ".....ooo", "...ooSSS", "..oSSSSS", ".oSSSSSS", ".oSSoooo", ".oSSo...", ".oSo....",
        ".oSo....", ".oSo....", ".oSo....", ".oSSo...", "..oSSo..", "...oSSoo", "....oSSS"]}
    },
    "visors": {
      "goggles": {"x": 6, "dy": -1, "mirror": true, "rows": [
        ".oooo.", "novVon", "novvon", ".oooo."]},
      "slit": {"x": 6, "dy": -1, "mirror": true, "rows": [
        "oooooo", "oggggg", "oooooo"]},
      "wide": {"x": 6, "dy": -1, "mirror": false, "rows": [
        "oooooooooooo", "ovvvvvvVVvvo", "ovvvvvVVvvvo", "oovvvvvvvvoo", ".oooooooooo."]},
      "mono": {"x": 6, "dy": -1, "mirror": true, "rows": [
        "...ooo", "nnnogg", "nnnogG", "...ooo"]},
      "grid": {"x": 6, "dy": -1, "mirror": true, "rows": [
        "oooooo", "ovgvgv", "ogvgvg", "oooooo"]}
    },
    "accessories": {
      "antenna": {"layer": "front", "dy": -5, "rows": [
        "................oGo.....", "................ogo.....", ".................o......",
        ".................M......", ".................M......", ".................M......",
        "................oMo....."]},
      "headlamp": {"layer": "front", "dy": 1, "rows": [
        ".........oooooo.........", "........olLLLLlo........", ".........oooooo........."]},
      "scarf": {"layer": "front", "dy": 10, "rows": [
        "........oooooooo........", ".......oaaaaaaaao.......", ".......obbAaaaAao.......",
        "........oooooaaAo.......", "............oaAo........", "............oaao........",
        "............oAo.........", ".............o.........."]},
      "tank": {"layer": "back", "dy": 7, "rows": [
        "..oooo............oooo..", ".oMmmMo..........oMmmMo.", ".oMmmMo..........oMmmMo.",
        ".oMmmMo..........oMmmMo.", ".oMmmMo..........oMmmMo.", ".oaaaao..........oaaaao.",
        ".oMmmMo..........oMmmMo.", ".oMmmMo..........oMmmMo."]},
      "horns": {"layer": "back", "dy": -4, "rows": [
        "..oo................oo..", "..oBo..............oBo..", "...oBo............oBo...",
        "...oBNo..........oNBo...", "....oBNo........oNBo....", ".....oBNo......oNBo.....",
        "......oNo......oNo......"]},
      "earpiece": {"layer": "front", "dy": 4, "rows": [
        "....ooo.................", "...oMnMo................", "...onano................",
        "...oMnMo................", "....oooM................", ".......oM...............",
        "........oMa............."]},
      "headset": {"layer": "front", "dy": -1, "rows": [
        ".......onnnnnnnno.......", "......on........no......", ".....on..........no.....",
        "....oaao........oaao....", "...oabAAo......oAAbao...", "...oaaAAo......oAAaao...",
        "...oaaAAo......oAAaao...", "....oMoo........oooo....", ".....oMo................",
        "......oMo...............", ".......oMnno............"]},
      "pipe": {"layer": "back", "dy": -3, "rows": [
        "...................PP...", ".................PPpP....", "..................pp.....",
        "...................P....", "..................ooo...", ".................oMmMo...",
        ".................oMmMo...", ".................onnno...", ".................oMmMo...",
        ".................oMmMo...", ".................oMmMo...", ".................oMmMo...",
        ".................oMmMo...", ".................oMmMo..."]}
    },
    "emblems": {
      "gear": ["a.aa.a", ".aaaa.", "aaAAaa", "aaAAaa", ".aaaa.", "a.aa.a"],
      "bolt": ["...aa.", "..aa..", ".aaaa.", "..aa..", ".aa...", ".a...."],
      "flask": ["..ww..", "..ww..", "..ww..", ".waaw.", "waaaaw", "wwwwww"],
      "plate": ["......", "..wwww", ".wmmmM", "wmmmMn", "mmmMn.", "nnnn.."],
      "circuit": ["w.w.w.", "nnnnnn", "naaaan", "naaaan", "nnnnnn", ".w.w.w"],
      "rocket": ["..ww..", ".wwww.", ".waaw.", ".wwww.", "aw..wa", "..ll.."],
      "leaf": ["....aa", "..aaaa", ".aaaAa", ".aaAa.", ".aAa..", "a....."],
      "star": ["..aa..", "..aa..", "aaaaaa", ".aaaa.", ".a..a.", "a....a"]
    },
    "backdrops": {
      "dark": {"bg": "#262423", "edge": "#302e2c"},
      "grid": {"bg": "#18304d", "line": "#2a4d75"},
      "hazard": {"bg": "#24221f", "stripe": "#332e22", "band": ["#f0b429", "#1d1b18"]},
      "glow": {"bg": "#1c1b1a"},
      "night": {"bg": "#0e1322", "stars": [[2, 3], [20, 2], [5, 9], [18, 7], [22, 12], [1, 14], [14, 1], [8, 2]]}
    }
  };
  /*@end*/

  var SIZE = 24;

  // 32-bit FNV-1a over UTF-8 bytes, then mulberry32: identical in the Python port.
  function utf8(text) {
    var out = [];
    for (var i = 0; i < text.length; i++) {
      var c = text.charCodeAt(i);
      if (c >= 0xd800 && c <= 0xdbff && i + 1 < text.length) {
        var d = text.charCodeAt(i + 1);
        if (d >= 0xdc00 && d <= 0xdfff) { c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00); i++; }
      }
      if (c < 0x80) out.push(c);
      else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
      else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
      else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
    return out;
  }
  function hash(text) {
    var h = 0x811c9dc5, bytes = utf8(String(text));
    for (var i = 0; i < bytes.length; i++) { h ^= bytes[i]; h = Math.imul(h, 0x01000193) >>> 0; }
    return h >>> 0;
  }
  function rng(seed) {
    var a = seed >>> 0;
    return function () {
      a = (a + 0x6d2b79f5) >>> 0;
      var t = a;
      t = Math.imul(t ^ (t >>> 15), t | 1) >>> 0;
      t = (t ^ (t + (Math.imul(t ^ (t >>> 7), t | 61) >>> 0))) >>> 0;
      return ((t ^ (t >>> 14)) >>> 0) % 1000003;
    };
  }

  // Colours: integer channels; mixing rounds half up in both ports.
  function parse(hex) {
    var m = /^#?([0-9a-f]{6})$/i.exec(String(hex || ""));
    if (!m) return null;
    var n = parseInt(m[1], 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function hex(c) {
    var s = "#";
    for (var i = 0; i < 3; i++) s += (c[i] < 16 ? "0" : "") + c[i].toString(16);
    return s;
  }
  function mix(a, b, t) {
    return [0, 1, 2].map(function (i) { return Math.floor(a[i] + (b[i] - a[i]) * t + 0.5); });
  }
  function luma(c) { return (c[0] * 299 + c[1] * 587 + c[2] * 114) / 255000; }
  function dist(a, b) { return Math.abs(a[0] - b[0]) + Math.abs(a[1] - b[1]) + Math.abs(a[2] - b[2]); }
  var BLACK = [0, 0, 0], WHITE = [255, 255, 255];

  function isHex(v) { return typeof v === "string" && /^#[0-9a-fA-F]{6}$/.test(v); }

  function validate(avatar) {
    var errors = [];
    if (avatar === false || avatar == null) return errors;
    if (typeof avatar !== "object" || Array.isArray(avatar)) return ["avatar must be an object"];
    Object.keys(avatar).forEach(function (k) {
      var v = avatar[k];
      if (k === "accent") { if (!isHex(v)) errors.push('avatar.accent must be "#rrggbb"'); }
      else if (!PARTS.options[k]) errors.push("avatar: unknown field " + k);
      else if (PARTS.options[k].indexOf(v) < 0) errors.push("avatar." + k + " must be one of " + PARTS.options[k].join("|"));
    });
    return errors;
  }

  // The spec actually drawn. Each field draws its random number whether or not it is set, so setting one part
  // never changes the others. Name-based picks come from PARTS.picks where a field has one: parts added later
  // (the headset) are choosable but never drawn by default, so existing defaults stay put.
  function resolve(profile) {
    profile = profile || {};
    var name = String(profile.name || profile.display_name || "agent");
    var av = profile.avatar && typeof profile.avatar === "object" ? profile.avatar : {};
    var next = rng(hash(name));
    var out = {};
    PARTS.fields.forEach(function (f) {
      var list = PARTS.options[f], pool = PARTS.picks[f] || list, r = next();
      out[f] = list.indexOf(av[f]) >= 0 ? av[f] : pool[r % pool.length];
    });
    var colorPick = next(), accentPick = next();
    var suit = parse(isHex(profile.color) ? profile.color : null) || parse(PARTS.colors[colorPick % PARTS.colors.length]);
    out.color = hex(suit);
    var accent = isHex(av.accent) ? parse(av.accent) : null;
    if (!accent) {
      var n = PARTS.accents.length;
      for (var i = 0; i < n; i++) {
        var c = parse(PARTS.accents[(accentPick + i) % n]);
        if (dist(c, suit) >= 180) { accent = c; break; }
      }
      accent = accent || parse(PARTS.accents[accentPick % n]);
    }
    out.accent = hex(accent);
    return out;
  }

  function palette(spec) {
    var suit = parse(spec.color), accent = parse(spec.accent);
    var p = {};
    Object.keys(PARTS.fixed).forEach(function (k) { p[k] = PARTS.fixed[k]; });
    var dark = luma(suit) < 0.16;
    // A near-black suit gets a lighter rim so it still reads against the dark backdrops.
    p.o = dark ? hex(mix(suit, WHITE, 0.42)) : PARTS.fixed.o;
    p.s = hex(dark ? mix(suit, WHITE, 0.1) : suit);
    p.S = hex(dark ? mix(suit, WHITE, 0.04) : mix(suit, BLACK, 0.32));
    p.h = hex(mix(suit, WHITE, dark ? 0.26 : 0.38));
    p.a = hex(accent);
    p.A = hex(mix(accent, BLACK, 0.3));
    p.b = hex(mix(accent, WHITE, 0.4));
    p.g = hex(mix(accent, WHITE, 0.2));
    p.G = hex(mix(accent, WHITE, 0.72));
    p.V = hex(mix(accent, WHITE, 0.62));
    return p;
  }

  function blank() {
    var g = [];
    for (var y = 0; y < SIZE; y++) { g.push([]); for (var x = 0; x < SIZE; x++) g[y].push(null); }
    return g;
  }
  function stamp(grid, rows, x0, y0, mirror, pal) {
    for (var j = 0; j < rows.length; j++) {
      var row = rows[j];
      if (mirror) row = row + row.split("").reverse().join("");
      for (var i = 0; i < row.length; i++) {
        var ch = row.charAt(i), x = x0 + i, y = y0 + j;
        if (ch === "." || x < 0 || y < 0 || x >= SIZE || y >= SIZE) continue;
        grid[y][x] = pal[ch];
      }
    }
  }

  function backdrop(grid, spec, h) {
    var bd = PARTS.backdrops[spec.backdrop], x, y;
    for (y = 0; y < SIZE; y++) for (x = 0; x < SIZE; x++) grid[y][x] = bd.bg;
    if (spec.backdrop === "dark") {
      for (x = 0; x < SIZE; x++) { grid[0][x] = bd.edge; }
      for (y = 0; y < SIZE; y++) { grid[y][0] = bd.edge; }
    } else if (spec.backdrop === "grid") {
      for (y = 0; y < SIZE; y++) for (x = 0; x < SIZE; x++) if (x % 6 === 2 || y % 6 === 2) grid[y][x] = bd.line;
    } else if (spec.backdrop === "hazard") {
      for (y = 0; y < SIZE; y++) for (x = 0; x < SIZE; x++) {
        if ((x + y) % 8 < 3) grid[y][x] = bd.stripe;
        if (y < 2) grid[y][x] = bd.band[Math.floor((x + y) / 3) % 2];
      }
    } else if (spec.backdrop === "glow") {
      var suit = parse(spec.color), base = parse(bd.bg);
      for (y = 0; y < SIZE; y++) for (x = 0; x < SIZE; x++) {
        var d = Math.max(Math.abs(2 * x - 23), Math.abs(2 * y - 19)) >> 1;
        var t = d < 4 ? 0.34 : d < 7 ? 0.24 : d < 10 ? 0.14 : 0.06;
        grid[y][x] = hex(mix(base, suit, t));
      }
    } else if (spec.backdrop === "night") {
      var star = "#d8dcef";
      bd.stars.forEach(function (s, i) { if (((h >>> i) & 1) === 0 || i < 4) grid[s[1]][s[0]] = star; });
    }
  }

  function pixels(profile) {
    var spec = resolve(profile), pal = palette(spec), grid = blank();
    var base = PARTS.bases[spec.base];
    backdrop(grid, spec, hash(String((profile && (profile.name || profile.display_name)) || "agent")));
    var acc = spec.accessory !== "none" ? PARTS.accessories[spec.accessory] : null;
    if (acc && acc.layer === "back") stamp(grid, acc.rows, 0, base.top + acc.dy, false, pal);
    stamp(grid, base.rows, 0, 0, base.mirror, pal);
    if (spec.emblem !== "none") stamp(grid, PARTS.emblems[spec.emblem], base.chest[0], base.chest[1], false, pal);
    if (spec.helmet !== "none") {
      var hm = PARTS.helmets[spec.helmet];
      stamp(grid, hm.rows, hm.x, base.top + hm.dy, hm.mirror, pal);
    }
    if (spec.visor !== "none") {
      var vs = PARTS.visors[spec.visor];
      stamp(grid, vs.rows, vs.x, base.eye + vs.dy, vs.mirror, pal);
    }
    if (acc && acc.layer === "front") stamp(grid, acc.rows, 0, base.top + acc.dy, false, pal);
    return grid;
  }

  function esc(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  // One <path> per colour, horizontal runs merged; colours in order of first appearance.
  function svg(profile, size, opts) {
    size = size || 48;
    opts = opts || {};
    var grid = pixels(profile), order = [], runs = {};
    for (var y = 0; y < SIZE; y++) {
      var x = 0;
      while (x < SIZE) {
        var c = grid[y][x], w = 1;
        while (x + w < SIZE && grid[y][x + w] === c) w++;
        if (c) {
          if (!runs[c]) { runs[c] = ""; order.push(c); }
          runs[c] += "M" + x + " " + y + "h" + w + "v1h-" + w + "z";
        }
        x += w;
      }
    }
    var label = opts.title != null ? opts.title
      : ((profile && (profile.display_name || profile.name)) || "agent") + " avatar";
    var out = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="' + size + '" height="' + size +
      '" shape-rendering="crispEdges" role="img" aria-label="' + esc(label) + '">';
    order.forEach(function (c) { out += '<path fill="' + c + '" d="' + runs[c] + '"/>'; });
    return out + "</svg>";
  }

  function random(seed) {
    var next = rng(hash("random:" + seed)), out = {};
    PARTS.fields.forEach(function (f) { var l = PARTS.options[f]; out[f] = l[next() % l.length]; });
    if (next() % 3 === 0) out.accent = PARTS.accents[next() % PARTS.accents.length];
    return out;
  }

  var api = { PARTS: PARTS, SIZE: SIZE, svg: svg, resolve: resolve, pixels: pixels, random: random,
    validate: validate, hash: hash };
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.PogAvatar = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
