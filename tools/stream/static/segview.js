// When the stream page shows a segment's card (overlay.js renderSegment). Shared by index.html and portrait.html,
// and tested under node (tools/stream/test_replay_pages.py).
(function (root) {
  "use strict";
  // A replay's card is the "coming up" note for the 2.5 s before the program cuts to the replay scene (segments.py
  // STARTING_S, the segment's "starting" state). While it is live the replay scene and its banner (replay.html) are
  // on air; on the stream page the card would wait there for the whole replay and greet the cut back to "stream"
  // (shake10: up a long time, "kinda confusing").
  // now (server seconds, snapshot.now): a card is never shown past its last moment (cardUntil) plus GRACE_S, whatever
  // the state says.
  const STARTING_S = 2.5, GRACE_S = 1.5;
  function cardVisible(seg, now) {
    if (!seg || seg.state === "ended") return false;
    if (now != null && seg.ends != null && now > cardUntil(seg) + GRACE_S) return false;
    if (seg.type === "attack_replay") return seg.state === "starting";
    return true;
  }
  // The card's last moment (server seconds): a replay's "coming up" card goes when the replay scene cuts in, any other
  // card at the segment's end. The card's time bar runs from seg.started to here.
  function cardUntil(seg) {
    if (!seg) return 0;
    return seg.type === "attack_replay" ? seg.started + STARTING_S : seg.ends;
  }
  // The "Research complete" lower third (model.py research_news): the newest technology finished under RESEARCH_S
  // ago -> {key, label, unlocks: "A, B, C +2 more" or ""}, or null.
  const RESEARCH_S = 8;
  function researchCard(news) {
    const n = (news || []).filter((x) => x && x.age_s != null && x.age_s < RESEARCH_S).slice(-1)[0];
    if (!n) return null;
    const shown = (n.unlocks || []).slice(0, 3);
    const more = (n.unlocks || []).length - shown.length + (n.more || 0);
    return { key: n.name, label: n.label || n.name, unlocks: shown.join(", ") + (more > 0 ? (shown.length ? " " : "") + "+" + more + " more" : "") };
  }
  const api = { cardVisible, cardUntil, researchCard, RESEARCH_S, GRACE_S };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.pogSeg = api;
})(typeof window !== "undefined" ? window : this);
