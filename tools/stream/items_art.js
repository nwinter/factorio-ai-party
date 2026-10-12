#!/usr/bin/env node
// Draws the item icon templates for tools/stream/static/items.js and writes them between its /*@items*/ markers.
//   node tools/stream/items_art.js          rewrite the JSON block in items.js
//   node tools/stream/items_art.js --print  print the templates as text instead
//   node tools/stream/items_art.js --json   print the data as JSON (test_items.py compares it with items.js)
// Each template is a 16x16 grid of palette letters. Shapes are filled and shaded here (light from the top left),
// then outlined; small details are placed by hand. Letters:
//   o d m l h   item colour c   (outline, dark, mid, light, highlight)
//   O D M L H   second colour c2
//   p q r s t   third colour c3
//   k X x y w   fixed greys, dark to light;  a b e  fixed glass (edge, fill, shine)
"use strict";
const fs = require("fs");
const path = require("path");

const N = 16;
const C = "odmlh", C2 = "ODMLH", C3 = "pqrst", GREY = "kXxyw", GLASS = "abbew";

// ---------- drawing primitives (pixel centres at x+0.5, y+0.5) ----------
const canvas = () => Array.from({ length: N }, () => Array(N).fill("."));
const circle = (cx, cy, r) => (x, y) => (x - cx) ** 2 + (y - cy) ** 2 <= r * r;
const ellipse = (cx, cy, rx, ry) => (x, y) => ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1;
const rect = (x0, y0, x1, y1) => (x, y) => x >= x0 && x < x1 + 1 && y >= y0 && y < y1 + 1; // inclusive pixels
function poly(pts) {
  return (x, y) => {
    let inside = false;
    for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
      const [xi, yi] = pts[i], [xj, yj] = pts[j];
      if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
    }
    return inside;
  };
}
function seg(pts, w) {
  return (x, y) => {
    for (let i = 0; i + 1 < pts.length; i++) {
      const [ax, ay] = pts[i], [bx, by] = pts[i + 1];
      const dx = bx - ax, dy = by - ay, L = dx * dx + dy * dy;
      const t = Math.max(0, Math.min(1, ((x - ax) * dx + (y - ay) * dy) / L));
      if (Math.hypot(x - ax - t * dx, y - ay - t * dy) <= w / 2) return true;
    }
    return false;
  };
}
const and = (...ps) => (x, y) => ps.every((p) => p(x, y));
const or = (...ps) => (x, y) => ps.some((p) => p(x, y));
const not = (p) => (x, y) => !p(x, y);
const mask = (pred) => Array.from({ length: N }, (_, y) => Array.from({ length: N }, (_, x) => pred(x + 0.5, y + 0.5)));

function bbox(m) {
  let x0 = N, y0 = N, x1 = -1, y1 = -1;
  for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) if (m[y][x]) {
    x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x); y1 = Math.max(y1, y);
  }
  return { x0, y0, x1, y1, cx: (x0 + x1 + 1) / 2, cy: (y0 + y1 + 1) / 2, hw: (x1 - x0 + 1) / 2, hh: (y1 - y0 + 1) / 2 };
}
const isEdge = (m, x, y) => [[1, 0], [-1, 0], [0, 1], [0, -1]].some(([dx, dy]) => !(m[y + dy] && m[y + dy][x + dx]));

// shade: "ball" (diagonal light), "cylx"/"cyly" (cylinder along x/y), or a number 0..4 for one flat shade.
function fill(cv, pred, ramp, shade = "ball", outline = true) {
  const m = mask(pred), b = bbox(m);
  for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
    if (!m[y][x]) continue;
    let i;
    if (outline && isEdge(m, x, y)) i = 0;
    else if (typeof shade === "number") i = shade;
    else if (shade === "ball") {
      const t = ((x + 0.5 - b.cx) / b.hw + (y + 0.5 - b.cy) / b.hh) / 2;
      i = t < -0.42 ? 4 : t < -0.12 ? 3 : t < 0.26 ? 2 : 1;
    } else {
      const v = shade === "cylx" ? (y + 0.5 - b.cy) / b.hh : (x + 0.5 - b.cx) / b.hw;
      i = v < -0.62 ? 3 : v < -0.25 ? 4 : v < 0.3 ? 2 : 1;
    }
    cv[y][x] = ramp[i];
  }
}
function outline(cv, pred, letter) {
  const m = mask(pred);
  for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) if (m[y][x] && isEdge(m, x, y)) cv[y][x] = letter;
}
// Overlay hand-placed rows at (x0, y0); "." leaves the pixel alone.
function paint(cv, x0, y0, rows) {
  rows.forEach((row, j) => [...row].forEach((ch, i) => { if (ch !== "." && cv[y0 + j] && x0 + i < N) cv[y0 + j][x0 + i] = ch; }));
}
const dots = (cv, list) => list.forEach(([x, y, ch]) => { cv[y][x] = ch; });

// Iso box: front face [x0..x1] x [y0..y1], top and right faces receding k pixels up-right.
function box(cv, x0, y0, x1, y1, k, ramp, faces = [3, 2, 1]) {
  const top = poly([[x0, y0], [x0 + k, y0 - k], [x1 + 1 + k, y0 - k], [x1 + 1, y0]]);
  const right = poly([[x1 + 1, y0], [x1 + 1 + k, y0 - k], [x1 + 1 + k, y1 + 1 - k], [x1 + 1, y1 + 1]]);
  const front = rect(x0, y0, x1, y1);
  fill(cv, top, ramp, faces[0], false);
  fill(cv, front, ramp, faces[1], false);
  fill(cv, right, ramp, faces[2], false);
  outline(cv, or(top, front, right), ramp[0]);
  return { top, front, right, all: or(top, front, right) };
}

// ---------- templates ----------
const T = {};

T.ore = (() => {
  const cv = canvas();
  const back = poly([[4.5, 3], [9, 1.5], [13, 3.5], [13, 8.5], [8, 9.5], [4, 7]]);
  const left = poly([[0.5, 9], [4, 6], [8.5, 7], [9.5, 11.5], [7.5, 15], [1.5, 15], [0.2, 12]]);
  const right = poly([[8, 9.5], [11.5, 7], [15.8, 9], [15.8, 13.5], [12.5, 15.5], [8.2, 14.5]]);
  fill(cv, back, C); fill(cv, left, C); fill(cv, right, C);
  dots(cv, [[7, 4, "M"], [10, 5, "O"], [11, 6, "M"], [3, 10, "M"], [5, 12, "O"], [6, 9, "L"], [12, 11, "M"], [13, 12, "O"], [10, 12, "L"]]);
  return cv;
})();

T.plate = (() => {
  const cv = canvas();
  const plate = (ox, oy) => {
    const top = poly([[ox + 3, oy], [ox + 13, oy], [ox + 10, oy + 4], [ox, oy + 4]]);
    const front = rect(ox, oy + 4, ox + 9, oy + 5);
    const side = poly([[ox + 10, oy + 4], [ox + 13, oy], [ox + 13, oy + 2], [ox + 10, oy + 6]]);
    fill(cv, top, C, 3, false); fill(cv, front, C, 1, false); fill(cv, side, C, 1, false);
    outline(cv, or(top, front, side), "o");
    dots(cv, [[ox + 4, oy + 1, "h"], [ox + 5, oy + 1, "h"], [ox + 6, oy + 1, "h"], [ox + 3, oy + 2, "h"]]);
  };
  plate(1, 8);
  plate(2, 3);
  return cv;
})();

T.brick = (() => {
  const cv = canvas();
  box(cv, 5, 6, 14, 9, 2, C);
  box(cv, 1, 10, 10, 13, 2, C);
  dots(cv, [[3, 9, "h"], [4, 9, "h"], [7, 5, "h"], [8, 5, "h"]]);
  return cv;
})();

T.gear = (() => {
  const cv = canvas();
  const g = (x, y) => {
    const dx = x - 8, dy = y - 8, r = Math.hypot(dx, dy), a = Math.atan2(dy, dx) + Math.PI / 8;
    const R = Math.cos(8 * a) > -0.1 ? 7.6 : 5.6;
    return r <= R && r >= 2.3;
  };
  fill(cv, g, C);
  fill(cv, and(circle(8, 8, 4.3), not(circle(8, 8, 2.3))), C, "ball", false);
  outline(cv, and(circle(8, 8, 4.4), not(circle(8, 8, 3.4))), "d");
  return cv;
})();

T.cable = (() => {
  const cv = canvas();
  // a hank of wire: a ring of strands with the loose end leaving at the top right
  fill(cv, and(ellipse(7.5, 8.5, 7, 6.2), not(ellipse(7.5, 8.5, 2.8, 2.2))), C);
  outline(cv, and(ellipse(7.5, 8.5, 5.6, 4.9), not(ellipse(7.5, 8.5, 4.7, 4))), "d");
  outline(cv, and(ellipse(7.5, 8.5, 4.2, 3.5), not(ellipse(7.5, 8.5, 3.3, 2.6))), "d");
  fill(cv, seg([[11, 3.4], [15, 0.6]], 2.4), C, 3, false);
  dots(cv, [[3, 5, "h"], [4, 4, "h"], [5, 3, "h"], [2, 7, "l"], [6, 3, "l"], [11, 3, "o"], [12, 2, "l"], [15, 1, "o"]]);
  return cv;
})();

T.board = (() => {
  const cv = canvas();
  fill(cv, rect(1, 3, 14, 13), C, 2);
  outline(cv, rect(2, 4, 13, 12), "d");
  fill(cv, rect(2, 4, 13, 4), C, 3, false);
  fill(cv, rect(2, 4, 2, 12), C, 3, false);
  paint(cv, 3, 5, [
    "s.s.s..s..",
    ".......q..",
    "r.kkkkk.r.",
    "rykXXXky.r",
    "..kXxXk..r",
    "rykXXXky..",
    "..kkkkk.s.",
    "s.....s.s.",
  ]);
  return cv;
})();

T.board2 = (() => {
  const cv = canvas();
  fill(cv, rect(1, 2, 14, 14), C, 2);
  outline(cv, rect(2, 3, 13, 13), "d");
  fill(cv, rect(2, 3, 13, 3), C, 3, false);
  fill(cv, rect(2, 3, 2, 13), C, 3, false);
  paint(cv, 3, 4, [
    ".y.y.y.y..",
    "ykkkkkkkky",
    ".kXXXXXXk.",
    "ykXxxxxXky",
    ".kXxwxxXk.",
    "ykXxxxxXky",
    ".kXXXXXXk.",
    "ykkkkkkkky",
    ".y.y.y.y..",
  ]);
  return cv;
})();

T.pipe = (() => {
  const cv = canvas();
  fill(cv, rect(2, 5, 13, 10), C, "cylx");
  fill(cv, rect(0, 3, 3, 12), C, "cylx");
  fill(cv, rect(12, 3, 15, 12), C, "cylx");
  dots(cv, [[1, 4, "x"], [1, 11, "x"], [14, 4, "x"], [14, 11, "x"]]);
  return cv;
})();

T.belt = (() => {
  const cv = canvas();
  const surf = poly([[4, 3], [16, 3], [12, 10], [0, 10]]);
  fill(cv, surf, GREY, 1, false);
  fill(cv, rect(0, 10, 11, 12), C, 2, false);
  fill(cv, rect(0, 12, 11, 12), C, 1, false);
  fill(cv, poly([[12, 10], [16, 3], [16, 6], [12, 13]]), C, 1, false);
  fill(cv, poly([[4, 2], [16, 2], [15.4, 3.2], [3.4, 3.2]]), C, 3, false);
  outline(cv, or(surf, rect(0, 10, 11, 12), poly([[12, 10], [16, 3], [16, 6], [12, 13]]), poly([[4, 2], [16, 2], [15.4, 3.2], [3.4, 3.2]])), "o");
  paint(cv, 2, 4, [
    "..y...y...y.",
    "..xy..xy..xy",
    ".xy..xy..xy.",
    "xy..xy..xy..",
    "x...x...x...",
  ]);
  return cv;
})();

T.inserter = (() => {
  const cv = canvas();
  box(cv, 2, 12, 10, 14, 2, GREY, [3, 2, 1]);
  fill(cv, seg([[6, 12], [4.4, 4.4]], 4), C);
  fill(cv, seg([[4.4, 4], [12.2, 4]], 4), C);
  fill(cv, circle(4.6, 4.2, 1.6), GREY, 1);
  fill(cv, circle(6, 11.6, 1.6), GREY, 1);
  paint(cv, 11, 6, [
    "kXXk",
    "kyyk",
    "k..k",
    "X..X",
  ]);
  return cv;
})();

T.flask = (() => {
  const cv = canvas();
  const body = or(circle(8, 10.4, 5.2), rect(6, 2, 9, 7));
  fill(cv, body, GLASS, 2);
  fill(cv, and(circle(8, 10.4, 4.2), (x, y) => y > 8.5), C, "ball", false);
  fill(cv, rect(5, 1, 10, 2), GREY, "cylx");
  dots(cv, [[5, 9, "e"], [5, 10, "w"], [4, 11, "e"], [7, 4, "e"], [7, 5, "e"]]);
  return cv;
})();

T.cone = (() => {
  const cv = canvas();
  const body = or(poly([[6, 5], [10, 5], [14.8, 14.6], [1.2, 14.6]]), rect(6, 2, 9, 6));
  fill(cv, body, GLASS, 2);
  fill(cv, poly([[4.6, 9.4], [11.4, 9.4], [13.6, 13.6], [2.4, 13.6]]), C, "ball", false);
  fill(cv, rect(5, 1, 10, 2), GREY, "cylx");
  dots(cv, [[7, 4, "e"], [7, 5, "e"], [6, 7, "w"], [5, 9, "e"]]);
  return cv;
})();

T.vial = (() => {
  const cv = canvas();
  const body = or(rect(5, 3, 10, 12), circle(7.95, 12.4, 3), rect(4, 3, 11, 3));
  fill(cv, body, GLASS, 2);
  fill(cv, and(or(rect(6, 7, 9, 12), circle(7.95, 12.4, 2)), (x, y) => y > 7), C, "cylx", false);
  fill(cv, rect(4, 0, 11, 2), GREY, "cylx");
  fill(cv, rect(6, 7, 9, 7), C, 3, false);
  dots(cv, [[6, 4, "w"], [6, 5, "e"], [6, 9, "h"], [6, 10, "h"]]);
  return cv;
})();

T.bar = (() => {
  const cv = canvas();
  const b = box(cv, 1, 8, 11, 12, 4, C);
  dots(cv, [[4, 6, "h"], [5, 6, "h"], [6, 6, "h"], [7, 6, "h"], [3, 7, "h"]]);
  return cv;
})();

T.beam = (() => {
  const cv = canvas();
  // an I-beam seen end-on, receding up-right
  const prof = (x, y) => rect(1, 7, 8, 8)(x, y) || rect(3, 9, 6, 11)(x, y) || rect(1, 12, 8, 13)(x, y);
  const depth = (x, y) => { for (let k = 1; k <= 6; k++) if (prof(x - k, y + k)) return true; return false; };
  fill(cv, depth, C, 1, false);
  fill(cv, (x, y) => depth(x, y) && !depth(x, y - 1) && !prof(x, y - 1), C, 3, false);
  fill(cv, prof, C, 4, false);
  outline(cv, or(prof, depth), "o");
  outline(cv, prof, "d");
  return cv;
})();

T.powder = (() => {
  const cv = canvas();
  fill(cv, and(ellipse(8, 15, 7.6, 10), (x, y) => y < 14.9), C);
  fill(cv, and(ellipse(8, 15, 7.6, 10), (x, y) => y >= 13), C, 1, false);
  outline(cv, and(ellipse(8, 15, 7.6, 10), (x, y) => y < 14.9), "o");
  dots(cv, [[6, 7, "h"], [9, 8, "h"], [4, 10, "h"], [11, 11, "l"], [7, 11, "l"], [12, 9, "l"], [5, 13, "m"], [9, 13, "m"]]);
  return cv;
})();

T.drop = (() => {
  const cv = canvas();
  fill(cv, or(circle(8, 10.2, 5.2), poly([[8, 0.8], [3.6, 8.4], [12.4, 8.4]])), C);
  dots(cv, [[5, 9, "h"], [5, 10, "h"], [6, 8, "h"], [5, 11, "l"]]);
  return cv;
})();

T.gas = (() => {
  const cv = canvas();
  fill(cv, circle(11, 5.4, 3.6), C);
  fill(cv, circle(12, 12.2, 2.8), C);
  fill(cv, circle(6, 10, 4.8), C);
  dots(cv, [[4, 8, "h"], [5, 7, "h"], [10, 4, "h"], [11, 11, "h"]]);
  return cv;
})();

T.battery = (() => {
  const cv = canvas();
  fill(cv, rect(6, 1, 9, 3), GREY, "cyly");
  fill(cv, rect(3, 3, 12, 14), C, "cyly");
  fill(cv, rect(3, 10, 12, 12), C2, "cyly");
  outline(cv, rect(3, 3, 12, 14), "o");
  paint(cv, 6, 4, [
    "..h.",
    ".hh.",
    "hhhh",
    ".hh.",
    ".h..",
  ]);
  return cv;
})();

T.engine = (() => {
  const cv = canvas();
  box(cv, 1, 8, 10, 14, 3, C);
  fill(cv, rect(3, 3, 5, 7), C2, "cyly");
  fill(cv, rect(7, 3, 9, 7), C2, "cyly");
  fill(cv, seg([[11, 11], [14.5, 11], [14.5, 4]], 2.6), C3);
  paint(cv, 2, 10, [
    "dddddddd",
    "........",
    "dddddddd",
  ]);
  return cv;
})();

T.rocket = (() => {
  const cv = canvas();
  fill(cv, poly([[4, 11], [2, 15], [6, 13]]), C2, "ball");
  fill(cv, poly([[12, 11], [14, 15], [10, 13]]), C2, "ball");
  fill(cv, or(rect(5, 6, 10, 14), ellipse(8, 6.5, 3, 6)), C, "cyly");
  fill(cv, and(ellipse(8, 6.5, 3, 6), (x, y) => y < 3.6), C2, "cyly");
  outline(cv, or(rect(5, 6, 10, 14), ellipse(8, 6.5, 3, 6)), "o");
  fill(cv, circle(8, 7.2, 1.6), C3, "ball");
  fill(cv, rect(6, 11, 9, 11), C2, 2, false);
  return cv;
})();

T.lattice = (() => {
  const cv = canvas();
  box(cv, 1, 6, 10, 15, 4, C);
  const holes = (x, y) => x >= 2 && x <= 9 && y >= 7 && y <= 14 && (x - 2) % 3 !== 2 && (y - 7) % 3 !== 2;
  for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) if (holes(x, y)) cv[y][x] = (x - 2) % 3 === 0 && (y - 7) % 3 === 0 ? "o" : "D";
  for (let j = 0; j < 4; j++) for (let i = 0; i < 4; i++) if ((i + j) % 2 === 0) cv[5 - Math.floor(j / 1)][2 + i * 2 + j] = cv[5 - j][2 + i * 2 + j] === "." ? "." : "D";
  for (let j = 0; j < 4; j++) cv[8 + j * 2][12 + (j % 2)] = "D";
  return cv;
})();

T.canister = (() => {
  const cv = canvas();
  const body = or(rect(4, 3, 11, 13), ellipse(7.95, 3, 4, 1.6), ellipse(7.95, 13.4, 4, 1.6));
  fill(cv, body, C, "cyly");
  fill(cv, rect(4, 6, 11, 7), C2, "cyly", false);
  fill(cv, rect(6, 0, 9, 1), GREY, "cyly");
  outline(cv, body, "o");
  paint(cv, 6, 9, [".hh.", "hhhh", ".h.."]);
  return cv;
})();

T.block = (() => {
  const cv = canvas();
  box(cv, 2, 6, 10, 14, 4, C);
  dots(cv, [[6, 4, "h"], [7, 4, "h"], [8, 3, "h"], [5, 9, "l"], [8, 12, "d"], [12, 8, "o"]]);
  return cv;
})();

T.log = (() => {
  const cv = canvas();
  fill(cv, rect(4, 5, 14, 12), C, "cylx");
  fill(cv, ellipse(4.5, 8.5, 3.6, 4.2), C2, "ball");
  outline(cv, ellipse(4.5, 8.5, 2, 2.4), "D");
  dots(cv, [[4, 8, "D"], [9, 6, "d"], [10, 6, "d"], [12, 10, "d"], [13, 10, "d"]]);
  return cv;
})();

T.crate = (() => {
  const cv = canvas();
  box(cv, 1, 6, 11, 15, 4, C);
  paint(cv, 1, 6, [
    "ooooooooooo",
    "o.........o",
    "oo.......do",
    "o.o.....d.o",
    "o..o...d..o",
    "o...o.d...o",
    "o....d....o",
    "o...d.o...o",
    "ooooooooooo",
  ]);
  return cv;
})();

T.furnace = (() => {
  const cv = canvas();
  box(cv, 1, 6, 11, 15, 3, C);
  fill(cv, or(rect(4, 10, 8, 14), circle(6.5, 10.5, 2.5)), GREY, 0, false);
  fill(cv, and(or(rect(5, 11, 7, 14), circle(6.5, 11, 1.6)), (x, y) => y > 11.5), C2, "ball", false);
  dots(cv, [[6, 13, "h"], [5, 14, "H"], [6, 14, "L"], [7, 14, "H"]]);
  paint(cv, 2, 7, ["d...d...d", ".........", "...d...d.", "........."]);
  paint(cv, 12, 5, ["d", ".", ".", "d"]);
  return cv;
})();

T.drill = (() => {
  const cv = canvas();
  fill(cv, poly([[4.5, 11], [10.5, 11], [7.5, 15.8]]), C2, "cyly");
  box(cv, 1, 5, 10, 11, 3, C);
  fill(cv, rect(11, 0, 13, 5), C3, "cyly");
  paint(cv, 2, 7, ["kkkkkkkk", "kXXXXXXk", "kkkkkkkk"]);
  return cv;
})();

T.assembler = (() => {
  const cv = canvas();
  box(cv, 1, 4, 12, 15, 3, C);
  const gear = (x, y) => {
    const dx = x - 6.5, dy = y - 10, r = Math.hypot(dx, dy), a = Math.atan2(dy, dx) + Math.PI / 6;
    return r <= (Math.cos(6 * a) > -0.2 ? 4.6 : 3.4) && r >= 1.5;
  };
  fill(cv, gear, GREY, 3, false);
  fill(cv, and(gear, (x, y) => x + y > 17.5), GREY, 2, false);
  outline(cv, gear, "X");
  dots(cv, [[2, 5, "h"], [3, 5, "h"], [11, 14, "d"]]);
  return cv;
})();

T.pole = (() => {
  const cv = canvas();
  fill(cv, rect(6, 2, 9, 15), C, "cyly");
  fill(cv, rect(2, 4, 13, 6), C, "cylx");
  fill(cv, rect(1, 2, 3, 4), C2, "ball");
  fill(cv, rect(12, 2, 14, 4), C2, "ball");
  return cv;
})();

T.lab = (() => {
  const cv = canvas();
  box(cv, 1, 10, 12, 15, 2, C);
  fill(cv, and(circle(7.5, 8.5, 5.6), (x, y) => y < 11), GLASS, 2);
  fill(cv, and(circle(7.5, 8.5, 4.4), (x, y) => y < 10 && y > 6), C2, "ball", false);
  dots(cv, [[5, 5, "w"], [4, 6, "e"], [3, 8, "e"]]);
  return cv;
})();

T.magazine = (() => {
  const cv = canvas();
  for (const x of [4, 7, 10]) {
    fill(cv, or(rect(x, 3, x + 2, 7), circle(x + 1.5, 3, 1.5)), C2, "cyly");
  }
  box(cv, 2, 7, 12, 14, 2, C);
  paint(cv, 3, 9, ["ddddddddd", ".........", "ddddddddd"]);
  return cv;
})();

T.wall = (() => {
  const cv = canvas();
  box(cv, 0, 6, 11, 14, 4, C);
  paint(cv, 1, 7, [
    "...o.....o.",
    "oooooooooo.",
    "o.....o....",
    "oooooooooo.",
    "...o.....o.",
    "oooooooooo.",
    "o.....o....",
  ]);
  paint(cv, 12, 4, ["o", ".", "o", "o", ".", "o", "o"]);
  dots(cv, [[3, 4, "h"], [4, 3, "h"], [5, 3, "h"]]);
  return cv;
})();

T.frame = (() => {
  const cv = canvas();
  fill(cv, seg([[1.5, 8], [14.5, 8]], 2.4), GREY, 2);
  fill(cv, ellipse(2.5, 8, 2.2, 3.4), C2, "ball");
  fill(cv, ellipse(13.5, 8, 2.2, 3.4), C2, "ball");
  fill(cv, ellipse(8, 8.5, 4.6, 5.6), C);
  fill(cv, ellipse(8, 6.6, 2.4, 1.8), GREY, 0, false);
  fill(cv, ellipse(8.4, 6.6, 1.3, 0.9), C3, 3, false);
  paint(cv, 5, 11, ["dddddd", ".d..d."]);
  return cv;
})();

T.satellite = (() => {
  const cv = canvas();
  const panel = (x0, x1) => {
    fill(cv, rect(x0, 5, x1, 11), C2, 2);
    for (let y = 6; y <= 10; y++) for (let x = x0 + 1; x < x1; x++) if ((x - x0) % 2 === 0 || y === 8) cv[y][x] = "D";
    dots(cv, [[x0 + 1, 6, "L"]]);
  };
  fill(cv, rect(0, 8, 15, 8), GREY, 1);
  panel(0, 4);
  panel(11, 15);
  box(cv, 5, 6, 9, 12, 1, C);
  fill(cv, seg([[8, 5], [9.5, 1.5]], 1), GREY, 3, false);
  fill(cv, and(circle(10.5, 2.5, 2.2), (x, y) => x + y > 12.6), C, 3);
  dots(cv, [[6, 8, "h"], [6, 9, "l"]]);
  return cv;
})();

// ---------- items ----------
// c, c2, c3: colours for the three ramps; color: signature colour (matches overlay.js's table where it had one).
const GROUPS = [
  ["Raw resources", {
    "iron-ore": { label: "Iron ore", t: "ore", c: "#6f8ba6", c2: "#b9d0e0", color: "#7d97b0" },
    "copper-ore": { label: "Copper ore", t: "ore", c: "#c06a3c", c2: "#5fc2a4", color: "#c8784a" },
    "stone": { label: "Stone", t: "ore", c: "#a48e6c", c2: "#d8c8a8", color: "#b5a27a" },
    "coal": { label: "Coal", t: "ore", c: "#2c2b2b", c2: "#a8a49e", color: "#8d8d8d" },
    "uranium-ore": { label: "Uranium ore", t: "ore", c: "#4c9c34", c2: "#a6ff6a", color: "#7ddc4c" },
    "wood": { label: "Wood", t: "log", c: "#7a4f2a", c2: "#d9b07a" },
    "crude-oil": { label: "Crude oil", t: "drop", c: "#2e2620", color: "#8c7a6a" },
    "water": { label: "Water", t: "drop", c: "#3b8fe0" },
  }],
  ["Intermediates", {
    "iron-plate": { label: "Iron plate", t: "plate", c: "#9fb0c0", color: "#9fb3c8" },
    "copper-plate": { label: "Copper plate", t: "plate", c: "#d77e4a", color: "#e0895a" },
    "steel-plate": { label: "Steel", t: "beam", c: "#bcc6d2", color: "#c7ccd6" },
    "stone-brick": { label: "Stone brick", t: "brick", c: "#b49c76", color: "#c9b48a" },
    "iron-gear-wheel": { label: "Gear", t: "gear", c: "#a3adb8", color: "#a9b6c4" },
    "copper-cable": { label: "Copper cable", t: "cable", c: "#dd844c", color: "#e6965f" },
    "electronic-circuit": { label: "Green circuit", t: "board", c: "#3f9a3e", c3: "#e6c25a", color: "#5fd068" },
    "advanced-circuit": { label: "Red circuit", t: "board", c: "#b8372f", c3: "#e6c25a", color: "#ef5b5b" },
    "processing-unit": { label: "Blue circuit", t: "board2", c: "#2f62c4", color: "#5a8cff" },
    "plastic-bar": { label: "Plastic", t: "bar", c: "#e6e6e6", color: "#e8e8e8" },
    "sulfur": { label: "Sulfur", t: "powder", c: "#e0cb36", color: "#e8e05a" },
    "battery": { label: "Battery", t: "battery", c: "#5b6a78", c2: "#d4553a", color: "#b0c8a0" },
    "engine-unit": { label: "Engine", t: "engine", c: "#8e98a2", c2: "#c9733a", c3: "#6b7680", color: "#c4a383" },
    "electric-engine-unit": { label: "Electric engine", t: "engine", c: "#4f86a8", c2: "#d48a4a", c3: "#3a5c78", color: "#7fc0e0" },
    "solid-fuel": { label: "Solid fuel", t: "block", c: "#6e6258", color: "#9a9a9a" },
  }],
  ["Logistics", {
    "pipe": { label: "Pipe", t: "pipe", c: "#8d97a3" },
    "transport-belt": { label: "Belt", t: "belt", c: "#e3b22c", color: "#f2c230" },
    "fast-transport-belt": { label: "Fast belt", t: "belt", c: "#d9433a" },
    "express-transport-belt": { label: "Express belt", t: "belt", c: "#3a95dd" },
    "burner-inserter": { label: "Burner inserter", t: "inserter", c: "#8c6a4c" },
    "inserter": { label: "Inserter", t: "inserter", c: "#e3b22c", color: "#e8b04a" },
    "long-handed-inserter": { label: "Long inserter", t: "inserter", c: "#d9433a" },
    "fast-inserter": { label: "Fast inserter", t: "inserter", c: "#3a95dd" },
  }],
  ["Science", {
    "automation-science-pack": { label: "Red science", t: "flask", c: "#e0403a", color: "#f05454" },
    "logistic-science-pack": { label: "Green science", t: "flask", c: "#3fbf52", color: "#4cc764" },
    "military-science-pack": { label: "Military sci.", t: "cone", c: "#454b54", color: "#9aa0a6" },
    "chemical-science-pack": { label: "Blue science", t: "cone", c: "#3a8ef0", color: "#4aa3ff" },
    "production-science-pack": { label: "Purple sci.", t: "vial", c: "#9e55e0", color: "#b06cf0" },
    "utility-science-pack": { label: "Yellow sci.", t: "vial", c: "#ecc731", color: "#f5d142" },
    "space-science-pack": { label: "Space sci.", t: "flask", c: "#e8eef4", color: "#f0f0f0" },
    "metallurgic-science-pack": { label: "Metallurgic sci.", t: "cone", c: "#e0802c", color: "#f0943c" },
    "electromagnetic-science-pack": { label: "Electromag. sci.", t: "vial", c: "#d0409a", color: "#e45cb0" },
    "agricultural-science-pack": { label: "Agricultural sci.", t: "flask", c: "#9cc23a", color: "#b0d44c" },
    "cryogenic-science-pack": { label: "Cryogenic sci.", t: "cone", c: "#3a5ee0", color: "#5a7cf0" },
    "promethium-science-pack": { label: "Promethium sci.", t: "vial", c: "#5a2e78", color: "#8a5aa8" },
  }],
  ["Oil and fluids", {
    "petroleum-gas": { label: "Petroleum gas", t: "gas", c: "#9a6cc0" },
    "heavy-oil": { label: "Heavy oil", t: "drop", c: "#c4561f" },
    "light-oil": { label: "Light oil", t: "drop", c: "#e6a81e" },
    "lubricant": { label: "Lubricant", t: "drop", c: "#4caa3a" },
    "sulfuric-acid": { label: "Sulfuric acid", t: "drop", c: "#c6d43a" },
  }],
  ["Rocket", {
    "low-density-structure": { label: "Low density structure", t: "lattice", c: "#c4884a", c2: "#5b4636", color: "#d0a070" },
    "rocket-fuel": { label: "Rocket fuel", t: "canister", c: "#d9532c", c2: "#8d97a3", color: "#f08a3a" },
    "rocket-part": { label: "Rocket part", t: "rocket", c: "#d6dce2", c2: "#d9432f", c3: "#4aa3ff", color: "#e8e8e8" },
    "flying-robot-frame": { label: "Robot frame", t: "frame", c: "#9aa8b6", c2: "#5e6a76", c3: "#4aa3ff", color: "#9fb0c0" },
    "satellite": { label: "Satellite", t: "satellite", c: "#d8dee6", c2: "#3a6ab8", color: "#d8e0e8" },
  }],
  ["Buildings and ammo", {
    "stone-furnace": { label: "Stone furnace", t: "furnace", c: "#a8926e", c2: "#ff9a2e" },
    "burner-mining-drill": { label: "Burner drill", t: "drill", c: "#8a7560", c2: "#9aa3ad", c3: "#4a4442" },
    "electric-mining-drill": { label: "Electric drill", t: "drill", c: "#5f8a6a", c2: "#9aa3ad", c3: "#3e5c78" },
    "assembling-machine-1": { label: "Assembler 1", t: "assembler", c: "#9a9a86" },
    "assembling-machine-2": { label: "Assembler 2", t: "assembler", c: "#4f86b8" },
    "assembling-machine-3": { label: "Assembler 3", t: "assembler", c: "#8cae3c" },
    "small-electric-pole": { label: "Small pole", t: "pole", c: "#8a5a32", c2: "#dd844c" },
    "lab": { label: "Lab", t: "lab", c: "#8d97a3", c2: "#4aa3ff" },
    "firearm-magazine": { label: "Magazine", t: "magazine", c: "#c9a43a", c2: "#e6b25a", color: "#e3c25a" },
    "piercing-rounds-magazine": { label: "Piercing ammo", t: "magazine", c: "#b4453a", c2: "#d98a4a", color: "#e07a5a" },
    "stone-wall": { label: "Wall", t: "wall", c: "#aaa494", color: "#b8b0a0" },
  }],
];

const data = {
  size: N,
  letters: { c: C, c2: C2, c3: C3 },
  fixed: { k: "#1c1c1e", X: "#3e3f42", x: "#6c6e72", y: "#a8abb0", w: "#f2f4f6", a: "#5f7c88", b: "#b4ccd4", e: "#e2f0f4" },
  templates: {},
  groups: GROUPS.map(([name, items]) => ({ name, items: Object.keys(items) })),
  items: {},
  fallback: { t: "crate", colors: ["#a4743f", "#8c8f4a", "#5f8f8a", "#8a6a9a", "#9a6050", "#6a7fa0"] },
};
for (const k of Object.keys(T)) data.templates[k] = T[k].map((r) => r.join(""));
for (const [, items] of GROUPS) Object.assign(data.items, items);
for (const [k, it] of Object.entries(data.items)) if (!data.templates[it.t]) throw new Error(k + ": no template " + it.t);

if (process.argv.includes("--print")) {
  for (const [k, rows] of Object.entries(data.templates)) console.log(k + "\n" + rows.join("\n") + "\n");
} else if (process.argv.includes("--json")) {
  process.stdout.write(JSON.stringify(data));
} else {
  const file = path.join(__dirname, "static", "items.js");
  const src = fs.readFileSync(file, "utf8");
  const a = src.indexOf("/*@items*/"), b = src.indexOf("/*@end*/");
  const body = "/*@items*/\n  var ITEMS = " + JSON.stringify(data, null, 1).replace(/\n/g, "\n  ") + ";\n  ";
  fs.writeFileSync(file, src.slice(0, a) + body + src.slice(b));
  console.log("items.js:", Object.keys(data.items).length, "items,", Object.keys(data.templates).length, "templates");
}
