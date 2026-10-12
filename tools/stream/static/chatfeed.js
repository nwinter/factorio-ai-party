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

  // Viewer Q&A pins (shift01 16:09: Astra's "Yes, Craig, ..." scrolled away under tells within seconds). A viewer's
  // line, or a viewer's line with an agent's answer to it, stays pinned above the feed for PIN_S; at most PIN_MAX,
  // newest first. An answer names the viewer the way caster.py's answers_viewer does (viewer_short_names):
  // "@craigNZ830", or a short form longer than 3 letters ("Craig"), within ANSWER_WINDOW_S of the viewer's line.
  const PIN_S = 25, PIN_MAX = 2, ANSWER_WINDOW_S = 600;
  const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

  function viewerShortNames(name) {
    name = String(name || "");
    const out = [name.toLowerCase(), name.replace(/[\d_]+$/, "").toLowerCase()];
    const m = /^[A-Za-z][a-z]+/.exec(name); // the leading word, up to a capital, digit or separator
    if (m) out.push(m[0].toLowerCase());
    return out.filter((k, i) => k && out.indexOf(k) === i);
  }

  function answersViewer(text, name) {
    const low = String(text || "").toLowerCase();
    if (new RegExp("@" + esc(String(name || "").toLowerCase()) + "\\b").test(low)) return true;
    return viewerShortNames(name).some((k) => k.length > 3 && new RegExp("\\b" + esc(k) + "\\b").test(low));
  }

  // The keys overlay.js renderChat gives these lines in the feed (a pinned line leaves the feed while pinned).
  const viewerKey = (v) => "v:" + String(v.id || v.seq);
  const talkKey = (m) => String(m.seq ?? m.tick + m.from + m.text);

  // s: the snapshot (now, chat, viewers). -> [{key, kind: "qa"|"viewer", v, m (the answer, qa only), t (pinned
  // since), vkey, mkey}], newest first.
  function viewerPins(s) {
    const now = s.now || 0;
    const viewers = (s.viewers || []).filter((v) => v && v.name && v.text).sort((a, b) => (a.t || 0) - (b.t || 0));
    const answers = (s.chat || []).filter((m) => m && !m.tell && !m.viewer && m.lane !== "viewer" && m.lane !== "log"
      && m.lane !== "notice" && m.agent && now - (m.t || 0) < PIN_S && (m.t || 0) <= now + 5);
    const pins = [], paired = new Set();
    for (const m of answers) {
      let q = null; // the latest line before the answer from a viewer it names
      for (const v of viewers) {
        if ((v.t || 0) <= (m.t || 0) + 2 && (m.t || 0) - (v.t || 0) <= ANSWER_WINDOW_S && answersViewer(m.text, v.name)) q = v;
      }
      if (!q) continue;
      paired.add(viewerKey(q));
      pins.push({ key: "qa:" + talkKey(m), kind: "qa", v: q, m, t: m.t || now, vkey: viewerKey(q), mkey: talkKey(m) });
    }
    for (const v of viewers) {
      if (now - (v.t || 0) < PIN_S && (v.t || 0) <= now + 5 && !paired.has(viewerKey(v))) {
        pins.push({ key: "pv:" + viewerKey(v), kind: "viewer", v, t: v.t || now, vkey: viewerKey(v), mkey: null });
      }
    }
    return pins.sort((a, b) => b.t - a.t).slice(0, PIN_MAX);
  }

  const api = { foldTells, tellParts, BURST_GAP_S, viewerPins, viewerShortNames, answersViewer, PIN_S, PIN_MAX };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.pogChat = api;
})(typeof window !== "undefined" ? window : this);
