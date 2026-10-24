// static/tourlay.js's geometry in Node (no DOM: it exports window.PogTourLay and draws nothing). The camera path agrees
// with camerapath.py (and cameras.lua) on the same points; world to screen in the 1208 x 1032 hole; marks' shapes,
// times and fades; the entry on now (the look's aired for its cut). test_tourlay.py runs it.
import fs from "node:fs";
import vm from "node:vm";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const ctx = vm.createContext({ window: {}, location: { search: "" }, URLSearchParams, Math });
vm.runInContext(fs.readFileSync(path.join(here, "static", "tourlay.js"), "utf8"), ctx);
const T = ctx.window.PogTourLay;
const near = (a, b, e = 1e-5) => Math.abs(a - b) < e;
const MOVE = { segments: [{ pts: [{ x: 0, y: 0, zoom: 0.5 }, { x: 40, y: 10, zoom: 0.8 }, { x: 60, y: -20, zoom: 0.8 }], t0: 1, t1: 11, ease: "inout" },
  { pts: [{ x: 60, y: -20, zoom: 0.8 }, { x: 60, y: -20, zoom: 1.6 }], t0: 12, t1: 16, ease: "out" }] };
const GAME = [[3.5, 10.262814, 3.528639, 0.562535], [6, 34.765184, 10.847659, 0.747669], [9, 55.609527, -12.231978, 0.8],
  [13, 60, -20, 1.043012], [16, 60, -20, 1.6]];
const W = 1208, H = 1032, v = { x: 100, y: 50, zoom: 1 };
const k = T.pxPerTile(W, H, 1);
const arrow = T.markGeom({ type: "arrow", at: { x: 100, y: 50 }, from: "nw", length: 110 }, 5, 20, W, H, v);
const circle = T.markGeom({ type: "circle", at: { x: 110, y: 50 }, radius: 6, from_s: 2, to_s: -3 }, 2.15, 20, W, H, v);
const s = { tour: [{ id: "a", cut: 100, until: 130, view: {} }, { id: "b", cut: 120, until: 150, view: {} }], look: { id: "b", aired: 120.2 } };
const checks = {
  "the camera path is camerapath.py's (and the game's)": GAME.every(([t, x, y, z]) => {
    const [gx, gy, gz] = T.moveAt(MOVE, t); return near(gx, x) && near(gy, y) && near(gz, z); }),
  "before, between and after segments": T.moveAt(MOVE, 0).join() === "0,0,0.5" && T.moveAt(MOVE, 11.5).join() === "60,-20,0.8"
    && T.moveAt(MOVE, 30).join() === "60,-20,1.6",
  "a tile is 32 * zoom * hole height / 1080 px in the 1208 x 1032 hole": near(k, 32 * 1032 / 1080),
  "the view's centre is the hole's centre; 10 tiles east is 10 tiles of px": (() => {
    const f = T.toScreen(W, H, v); const [x, y] = f({ x: 100, y: 50 }); const [x2] = f({ x: 110, y: 50 });
    return near(x, W / 2) && near(y, H / 2) && near(x2 - x, 10 * k); })(),
  "an arrow from the north-west: its tail up-left, its head 8 px off the spot": near(arrow.head[0], W / 2 - 8 / Math.SQRT2)
    && near(arrow.tail[0], W / 2 - 118 / Math.SQRT2) && near(arrow.tail[1], H / 2 - 118 / Math.SQRT2),
  "a circle's radius in tiles; it fades in over 0.3 s from its from_s": near(circle.r, 6 * k) && near(circle.opacity, 0.5),
  "a mark shows from from_s to to_s (negative: from the end)": T.markGeom({ type: "label", at: { x: 0, y: 0 }, text: "x", to_s: -3 }, 17.5, 20, W, H, v) === null
    && T.markGeom({ type: "label", at: { x: 0, y: 0 }, text: "x", from_s: 2 }, 1.9, 20, W, H, v) === null,
  "the entry on now: the newer one from its aired": T.active(s, 120.1).e.id === "a" && T.active(s, 120.3).e.id === "b"
    && near(T.active(s, 121).start, 120.2) && T.active(s, 151) === null,
  "a caption shows from its t0 to its t1 after the narration's moment": (() => {
    const e = { subs: [{ t0: 0, t1: 2.5, text: "one" }, { t0: 2.5, t1: 4, text: "two" }], subs_at: 100.8 };
    return T.captionAt(e, 100.7) === null && T.captionAt(e, 100.8).text === "one" && T.captionAt(e, 103.4).text === "two"
      && T.captionAt(e, 104.9) === null && T.captionAt({}, 101) === null; })(),
  "a moving view follows its move": (() => { const p = T.viewAt({ view: { move: MOVE } }, 100, 106); return near(p.x, 34.765184); })(),
};
let ok = true;
for (const [name, v2] of Object.entries(checks)) { console.log(`${v2 ? "PASS" : "FAIL"} ${name}`); ok &&= v2; }
process.exit(ok ? 0 : 1);
