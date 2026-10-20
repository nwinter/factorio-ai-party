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

  // A line's age: wall time, or game time when that says older. serve.py stamps the chat it reads at a restart with
  // the restart time (shift01 16:31: twelve-minute-old answers pinned again).
  function ageOf(s, m) {
    const wall = (s.now || 0) - (m.t || 0);
    const game = s.tick != null && m.tick != null ? (s.tick - m.tick) / 60 : -Infinity;
    return Math.max(wall, game);
  }

  // Words for matching an answer with the question it answers: 4+ letters, not the common ones, compared on their
  // first 5 letters ("brightness" ~ "bright").
  const STOP = new Set(("that this with your have what will from they them their there when where which would could " +
    "should about just also than then into only some more most very well were been being does doing over here").split(" "));
  function words(text, skip) {
    const out = new Set();
    for (const w of String(text || "").toLowerCase().match(/[a-z0-9']{4,}/g) || []) {
      if (!STOP.has(w) && !skip.has(w)) out.add(w.slice(0, 5));
    }
    return out;
  }
  const overlap = (a, b) => { let n = 0; for (const w of a) if (b.has(w)) n++; return n; };
  // the relay's "@astra " address before a viewer's words (viewers.py Relay.line), and its cut-off "…"
  const bare = (text) => String(text || "").replace(/^@\S+\s+/, "").replace(/…$/, "").trim();
  const seqOf = (m) => (typeof m.seq === "number" ? m.seq : null);

  // The viewer line an answer answers. The agents saw the viewer lines relayed into the game chat (lane "viewer",
  // from "viewer NAME"), so those count first: among that viewer's lines before the answer in the last 10 minutes,
  // those addressed to the answering agent ("@sol ..."; any, if none is), the most recent unless an earlier one shares
  // at least two more words with the answer (shift01 16:32: both pins showed Joonazan's latest line under answers to
  // two earlier questions; shift05 09:38: Sol answered "@sol what is your long term plan with vulkanus" in 5 s, but
  // "vulkanus" shares no word with "Vulcanus" and an older line shared one, so the older line was pinned again).
  // Without game copies, the viewer's lane lines the same way.
  function questionFor(s, m, copies, viewers) {
    const before = (c) => (seqOf(c) != null && seqOf(m) != null ? c.seq < m.seq
      : c.tick != null && m.tick != null ? c.tick <= m.tick : (c.t || 0) <= (m.t || 0) + 2);
    const recent = (c) => (c.tick != null && m.tick != null ? (m.tick - c.tick) / 60 : (m.t || 0) - (c.t || 0)) <= ANSWER_WINDOW_S;
    const names = [...new Set(copies.map((c) => c.vname).concat(viewers.map((v) => v.name)))];
    const lineFor = (c) => {
      const body = bare(c.text).toLowerCase();
      // the same line in the viewers lane (its YT/SITE badge and key), else the game copy itself
      const v = [...viewers].reverse().find((v) => {
        const t = bare(v.text).toLowerCase();  // the viewer's own "@sol " too
        return v.name === c.vname && body && (t.startsWith(body) || body.startsWith(t));
      });
      return v || { id: "c" + String(c.seq ?? c.tick), name: c.vname, text: bare(c.text), t: c.t, source: "youtube" };
    };
    // (d20 batch57 S1, viewer Aurora) a say with reply_to names its line: that one, or no pin when it is not in the
    // snapshot (never another line of the same viewer by name)
    if (typeof m.reply_to === "number") {
      const c = copies.find((c) => seqOf(c) === m.reply_to);
      return c ? lineFor(c) : null;
    }
    const name = names.find((n) => answersViewer(m.text, n));
    if (!name) return null;
    const skip = new Set(viewerShortNames(name));
    const aw = words(m.text, skip);
    const agent = String(m.agent || "").toLowerCase();
    const atAgent = (text) => !!agent && new RegExp("(^|\\s)@" + esc(agent) + "\\b").test(String(text || "").toLowerCase());
    // the Operator's answer to a question asked elsewhere (YouTube, relayed by the owner) attaches only to a line to
    // the Operator or one sharing two words with it (d17 16:05; viewer_replies.py classify does the same)
    const operator = agent === "operator" || /^(server|operator)$/i.test(String(m.from || ""));
    const best = (rows, text, mine) => {
      const own = rows.filter(mine);
      const pool = own.length ? own : rows;  // oldest first
      if (!pool.length) return null;
      let pick = pool[pool.length - 1], score = overlap(aw, words(text(pick), skip));
      for (const r of pool) { const sc = overlap(aw, words(text(r), skip)); if (sc >= score + 2) { pick = r; score = sc; } }
      if (operator && !own.length && score < 2) return null;
      return pick;
    };
    const cs = copies.filter((c) => c.vname === name && before(c) && recent(c));
    const lane = viewers.filter((v) => v.name === name);
    if (cs.length) {
      const c = best(cs, (r) => bare(r.text), (r) => atAgent(r.text));
      return c && lineFor(c);
    }
    return best(lane.filter((v) => (v.t || 0) <= (m.t || 0) + 2 && (m.t || 0) - (v.t || 0) <= ANSWER_WINDOW_S), (r) => r.text,
      (r) => r.to === agent || (r.to_all || []).includes(agent) || atAgent(r.text));
  }

  // s: the snapshot (now, tick, chat, viewers). -> [{key, kind: "qa"|"viewer"|"operator", v (the viewer line), answers
  // (agent lines, qa only), m (operator only), t (pinned since), keys (the feed keys of the pinned lines)}], newest
  // first. Two answers to one question share its pin.
  function viewerPins(s) {
    const now = s.now || 0;
    const chat = (s.chat || []).filter(Boolean);
    const viewers = (s.viewers || []).filter((v) => v && v.name && v.text).sort((a, b) => (a.t || 0) - (b.t || 0));
    const copies = chat.filter((m) => m.viewer || m.lane === "viewer")
      .map((m) => ({ ...m, vname: String(m.from || "").replace(/^viewer\s+/i, "").replace(/\s*\(host\)$/, "") }));
    const fresh = (m) => ageOf(s, m) < PIN_S && (m.t || 0) <= now + 5;
    const answers = chat.filter((m) => !m.tell && !m.viewer && m.agent && fresh(m)
      && !["viewer", "log", "notice", "operator"].includes(m.lane));
    const byQ = new Map();
    for (const m of answers) {
      const q = questionFor(s, m, copies, viewers);
      if (!q) continue;
      const k = viewerKey(q);
      const p = byQ.get(k) || { key: "qa:" + k, kind: "qa", v: q, answers: [], t: 0, keys: [k] };
      p.answers.push(m);
      p.keys.push(talkKey(m));
      p.t = Math.max(p.t, now - ageOf(s, m));
      byQ.set(k, p);
    }
    for (const p of byQ.values()) p.answers.sort((a, b) => (a.t || 0) - (b.t || 0));
    const pins = [...byQ.values()];
    for (const v of viewers) {
      if (now - (v.t || 0) < PIN_S && (v.t || 0) <= now + 5 && !byQ.has(viewerKey(v))) {
        pins.push({ key: "pv:" + viewerKey(v), kind: "viewer", v, t: v.t || now, keys: [viewerKey(v)] });
      }
    }
    for (const m of chat) {
      if (m.lane === "operator" && fresh(m)) {
        pins.push({ key: "op:" + talkKey(m), kind: "operator", m, t: now - ageOf(s, m), keys: [talkKey(m)] });
      }
    }
    return pins.sort((a, b) => b.t - a.t).slice(0, PIN_MAX);
  }

  // What became of a viewer's line in the game (viewers.py Relay: delivery, to, to_all), for the viewer to see
  // (shift01 16:34, craigNZ830: "they are not being taged for agent"): "→ Astra" or "→ Astra, Sol" (delivered and
  // addressed), "→ team" (delivered to no one agent), "queued" (waits out the viewer's own gap after their last), "not sent:
  // too soon" (more than three waiting), "not sent: chat busy" (waited too long behind others); nothing for chatter or before the relay acts.
  function deliveryLabel(v, agents) {
    if (!v || v.chatter) return "";
    const shown = (n) => { const a = (agents || []).find((x) => x.name === n); return (a && a.display_name) || n; };
    // a line to the operator ("Operator, ..."): the operator's inbox, and the agents it names too
    const op = v.operator ? ["operator"] : [];
    if (v.delivery === "sent" || v.relayed) {
      const to = op.concat((v.to_all || (v.to ? [v.to] : [])).map(shown));
      return "→ " + (to.length ? to.join(", ") : "team");
    }
    if (v.operator) return "→ operator";
    if (v.delivery === "waiting") return "queued";  // waits out the viewer's own gap, then goes
    if (v.delivery === "too_soon") return "not sent: too soon";
    if (v.delivery === "busy") return "not sent: chat busy";
    return "";
  }

  const api = { foldTells, tellParts, BURST_GAP_S, viewerPins, viewerShortNames, answersViewer, PIN_S, PIN_MAX,
    deliveryLabel };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.pogChat = api;
})(typeof window !== "undefined" ? window : this);
