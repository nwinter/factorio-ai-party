// Single-line text that does not fit its box (agent cards' job and action lines, camera labels, the research card):
// the start shows most of the time; now and then the line pans smoothly to its end, holds, and pans back (Nick, d22
// 22:13: wrapped status lines are useless when nobody can scroll or hover). Shared by index.html and portrait.html,
// loaded before overlay.js; the timing and the turns are tested under node (tools/stream/test_marquee.py).
//
// A marquee is an outer box (overflow hidden, class "mq") holding one inline-block span (class "mq-in") with the
// text. Only a line wider than its box moves: a Web Animation of the span's transform (the compositor runs it, no
// per-frame script). The width is measured when the text changes and when either box resizes (ResizeObserver), never
// per frame. Lines take turns (pick): at most MAX_MOVING pan at once, starts GAP_S apart, the longest rested first,
// and each rests at its start at least HOLD_START_S (and at least as long as its pan takes) between pans. New text goes
// back to the start and rests again; a change in numbers only ("set 6 min ago" -> "set 7 min ago", a countdown)
// keeps its turn.
(function (root) {
  "use strict";
  const HOLD_START_S = 12;  // the least rest at the start between pans (longer for a long line: see timeline)
  const HOLD_END_S = 2.5;   // the end, before panning back
  const SPEED_EM = 3.5;     // reading pan in font sizes a second: 49 px/s at 14 px, 84 px/s at portrait's 24 px
  const BACK_X = 4;         // the way back runs this much faster, between BACK_MIN_S and BACK_MAX_S
  const BACK_MIN_S = 1, BACK_MAX_S = 3;
  const MAX_MOVING = 2;     // lines away from their start at once, page-wide
  const GAP_S = 4;          // between two pans' starts
  const MIN_OVER_PX = 2;    // overflow under this stays still (rounding)
  const FADE_EM = 1.5;      // the soft fade at the clipped right edge; the pan goes this much past the last letter

  // One pan of a line overPx wider than its box at fontPx: null when it fits, else the seconds of each phase, the
  // rest it needs before (rest), and the keyframes of the pan (x in px, offset 0..1 of `away`).
  function timeline(overPx, fontPx) {
    if (!(overPx >= MIN_OVER_PX)) return null;
    const font = fontPx > 0 ? fontPx : 14;
    const dist = Math.ceil(overPx + FADE_EM * font);
    const pan = dist / (SPEED_EM * font);
    const back = Math.min(BACK_MAX_S, Math.max(BACK_MIN_S, pan / BACK_X));
    const away = pan + HOLD_END_S + back;
    const rest = Math.max(HOLD_START_S, away); // a long line rests at its start at least as long as it is away
    const frames = [
      { offset: 0, x: 0 },
      { offset: pan / away, x: -dist },
      { offset: (pan + HOLD_END_S) / away, x: -dist },
      { offset: 1, x: 0 },
    ];
    return { dist, pan, holdEnd: HOLD_END_S, back, away, rest, frames };
  }

  // Where the text sits t seconds into a pan, linear between keyframes (for tests; the page eases both moves).
  function offsetAt(tl, t) {
    if (!tl || t <= 0 || t >= tl.away) return 0;
    const f = t / tl.away, k = tl.frames;
    for (let i = 1; i < k.length; i++) {
      if (f <= k[i].offset) return k[i - 1].x + (k[i].x - k[i - 1].x) * (f - k[i - 1].offset) / (k[i].offset - k[i - 1].offset);
    }
    return 0;
  }

  // Text that differs only in its numbers is the same line (ages, countdowns, counts): it keeps its turn.
  function resetKey(text) {
    return String(text == null ? "" : text).replace(/\d+(?:[.,:]\d+)*/g, "#").replace(/\s+/g, " ").trim();
  }

  // Whose turn it is at `now` (seconds): lines [{tl, restSince, moving}] -> the indices to start now (one at most).
  // At most MAX_MOVING away at once, a start GAP_S after the last (lastStart), the line that has rested longest first.
  function pick(lines, now, lastStart) {
    const moving = lines.filter((l) => l.moving).length;
    if (moving >= MAX_MOVING || now - lastStart < GAP_S) return [];
    const ready = lines.map((l, i) => i).filter((i) => {
      const l = lines[i];
      return l.tl && !l.moving && now - l.restSince >= l.tl.rest;
    }).sort((a, b) => lines[a].restSince - lines[b].restSince || a - b);
    return ready.slice(0, 1);
  }

  // ---------- the page ----------
  const live = new Set();
  let ro = null, timer = null, lastStart = -Infinity;
  const clock = () => (typeof performance !== "undefined" ? performance.now() : Date.now()) / 1000;

  function observer() {
    if (!ro && typeof ResizeObserver !== "undefined") {
      ro = new ResizeObserver((entries) => {
        const seen = new Set();
        for (const e of entries) {
          const outer = e.target._mqOuter || e.target;
          if (!seen.has(outer)) { seen.add(outer); measure(outer); }
        }
      });
    }
    return ro;
  }

  // An outer box with its text span: make("div", "model") -> <div class="model mq"><span class="mq-in"></span></div>
  function make(tag, cls) {
    const outer = document.createElement(tag);
    outer.className = (cls ? cls + " " : "") + "mq";
    const inner = document.createElement("span");
    inner.className = "mq-in";
    outer.appendChild(inner);
    outer._mq = inner;
    inner._mqOuter = outer;
    outer._mqs = { key: null, tl: null, restSince: clock(), anim: null };
    live.add(outer);
    const o = observer();
    if (o) { o.observe(outer); o.observe(inner); }
    if (!timer && typeof window !== "undefined") timer = setInterval(tick, 1000);
    return outer;
  }

  // Plain text into a marquee; returns whether it changed.
  function set(outer, text) {
    text = text == null ? "" : String(text);
    if (!outer._mq) { if (outer.textContent !== text) outer.textContent = text; return false; }
    if (outer._mq.textContent === text) return false;
    outer._mq.textContent = text;
    refresh(outer);
    return true;
  }

  function stop(st) {
    if (st.anim) { st.anim.cancel(); st.anim = null; st.restSince = clock(); }
  }

  // After the caller changed the span's content itself (outer._mq): new text goes back to its start and rests.
  function refresh(outer) {
    const st = outer._mqs;
    if (!st) return;
    const key = resetKey(outer._mq.textContent);
    if (key !== st.key) {
      st.key = key;
      stop(st);
      st.restSince = clock();
    }
    measure(outer);
  }

  function measure(outer) {
    const st = outer._mqs, inner = outer._mq;
    if (!st || !inner) return;
    const shown = outer.isConnected && inner.parentNode === outer && outer.clientWidth > 0;
    const font = shown ? parseFloat(getComputedStyle(outer).fontSize) || 14 : 14;
    st.tl = shown ? timeline(inner.offsetWidth - outer.clientWidth, font) : null;
    if (shown) live.add(outer); // back on the page (a wait line comes and goes; tick drops lines gone a while)
    outer.classList.toggle("mq-over", !!st.tl);
    if (!st.tl) stop(st); // fits now, or hidden
  }

  function start(outer) {
    const st = outer._mqs, tl = st.tl;
    if (typeof outer._mq.animate !== "function") return;
    const ease = "cubic-bezier(0.45, 0, 0.55, 1)";
    const anim = outer._mq.animate(tl.frames.map((k, i) => ({ offset: k.offset, transform: "translateX(" + k.x + "px)",
      easing: i === 0 || i === 2 ? ease : "linear" })), { duration: tl.away * 1000 });
    st.anim = anim;
    anim.onfinish = () => { if (st.anim === anim) { st.anim = null; st.restSince = clock(); } };
  }

  // Once a second: forget lines off the page for GONE_S (a replaced camera label, a card that went), then start
  // whoever's turn it is.
  const GONE_S = 120;
  function tick() {
    const now = clock(), outers = [];
    for (const outer of live) {
      const st = outer._mqs;
      if (outer.isConnected) { st.gone = 0; outers.push(outer); continue; }
      stop(st);
      if (!st.gone) st.gone = now;
      else if (now - st.gone > GONE_S) live.delete(outer);
    }
    const lines = outers.map((o) => ({ tl: o._mqs.tl, restSince: o._mqs.restSince, moving: !!o._mqs.anim }));
    for (const i of pick(lines, now, lastStart)) { start(outers[i]); lastStart = now; }
  }

  const api = { timeline, offsetAt, resetKey, pick, make, set, refresh, measure, tick,
    HOLD_START_S, HOLD_END_S, SPEED_EM, MAX_MOVING, GAP_S, FADE_EM };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.pogMarquee = api;
})(typeof window !== "undefined" ? window : this);
