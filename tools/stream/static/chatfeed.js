// Tells in the chat feed (overlay.js renderChat): pure helpers, shared by index.html and portrait.html and tested
// under node (tools/stream/test_tells_feed.py).
(function (root) {
  "use strict";
  const BURST_GAP_S = 45; // a tell this soon after the previous one between the same two agents folds into it

  // The recipients and the words of a tell: model.py's to_shown/body, else parsed from "→ Astra: text" (a service
  // started before tells had their own lane).
  function tellParts(m) {
    if (m.body != null) return { to: m.to_shown || "team", body: m.body };
    const mm = /^→\s*([^:]+):\s*([\s\S]*)$/.exec(m.text || "");
    return mm ? { to: mm[1].trim(), body: mm[2] } : { to: "team", body: m.text || "" };
  }

  // Fold bursts: tells in time order -> groups {key, from, agent, to, body (the latest), count, t (the latest),
  // first_t, tick}. A group is one sender to the same recipients, each tell within BURST_GAP_S of the last.
  function foldTells(tells) {
    const out = [];
    const open = new Map(); // "from|to" -> group
    for (const m of [...tells].sort((a, b) => (a.t || 0) - (b.t || 0))) {
      const p = tellParts(m);
      const pair = (m.agent || m.from) + "|" + p.to;
      const g = open.get(pair);
      if (g && (m.t || 0) - g.t <= BURST_GAP_S) {
        g.count += 1;
        g.body = p.body;
        g.t = m.t || g.t;
        g.tick = m.tick;
        continue;
      }
      const ng = { key: "tg:" + String(m.seq ?? (m.t + m.from)), from: m.from, agent: m.agent, to: p.to, body: p.body,
        count: 1, t: m.t || 0, first_t: m.t || 0, tick: m.tick };
      open.set(pair, ng);
      out.push(ng);
    }
    return out;
  }

  const api = { foldTells, tellParts, BURST_GAP_S };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.pogChat = api;
})(typeof window !== "undefined" ? window : this);
