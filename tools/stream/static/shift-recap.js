// Full broadcast-canvas presentation of prepared records. No live game/media requests.
(() => {
  const el = (tag, cls, text) => {
    const node = document.createElement(tag);
    node.className = cls;
    if (text != null) node.textContent = text;
    return node;
  };
  let panel, key, video;
  function release() {
    if (video) { video.pause(); video.removeAttribute("src"); video.load(); video = null; }
  }
  function render(s) {
    const recap = s && s.shift_recap;
    // A finished narration may remain in the server's receipt state until the agents start.
    // That hold is not an on-air beat: restore the normal canvas while it lasts.
    const active = !!(recap && recap.active && !recap.holding);
    document.body.classList.toggle("recap-active", active);
    if (!panel) {
      const stage = document.getElementById("stage");
      if (!stage) return;
      panel = el("section", "shift-recap");
      panel.id = "shift-recap";
      panel.setAttribute("aria-label", "Recorded shift recap");
      panel.hidden = true;
      stage.appendChild(panel);
    }
    panel.hidden = !active;
    if (!active) { release(); panel.replaceChildren(); key = null; return; }
    const media = recap.media || null;
    // Elapsed time changes on service ticks; it must not recreate the image/video every tick.
    const next = JSON.stringify([recap.run, recap.phase, recap.id, recap.title, recap.text,
      recap.speaker, recap.time_label, media]);
    if (next === key) return;
    key = next;
    release();
    panel.replaceChildren();
    panel.classList.toggle("sr-neutral", !media);
    const header = el("header", "sr-head");
    header.append(el("div", "sr-kicker", `${recap.run || ""} · ${recap.phase === "transition" ? "SHIFT CHANGE" : "SHIFT RECAP"}`),
      el("h2", "sr-title", recap.title || "Shift recap"));
    panel.append(header);
    const figure = el("figure", "sr-media");
    if (media) {
      const node = el(media.kind === "video" ? "video" : "img", "sr-picture");
      const failed = () => { if (!node.isConnected) return; release(); figure.replaceChildren();
        panel.classList.add("sr-neutral"); label.textContent = "Recorded shift"; };
      node.addEventListener("error", failed, { once: true });
      if (media.kind === "video") {
        video = node;
        node.muted = true; node.autoplay = true; node.playsInline = true;
        node.addEventListener("loadedmetadata", () => {
          const offset = Math.max(0, Number(recap.elapsed || 0) + Number(media.offset || 0));
          if (Number.isFinite(node.duration)) node.currentTime = Math.min(offset, Math.max(0, node.duration - 0.1));
          const play = node.play(); if (play && play.catch) play.catch(failed);
        }, { once: true });
      } else {
        node.alt = `Recorded ${media.subject || "shift"} still`;
      }
      node.src = media.url;
      figure.append(node);
    }
    panel.append(figure);
    const caption = el("footer", "sr-caption");
    const meta = el("div", "sr-meta");
    meta.append(el("b", "sr-speaker", recap.speaker || "Rook & Vale"),
      el("span", "sr-time", recap.time_label || "Recorded shift"));
    const spoken = el("p", "sr-text", recap.text || "");
    const label = el("div", "sr-recorded", media ?
      `Recorded ${media.kind === "video" ? "clip" : "still"} · ${media.subject || "shift"} · ${media.recorded_time || ""} · Graphics copyright Wube Software` : "Recorded shift");
    caption.append(meta, spoken, label);
    panel.append(caption);
    // Long record quotes still fit without losing words; normal narrative uses the larger type.
    const fit = () => {
      if (!caption.isConnected || !caption.clientHeight) return;
      let size = parseFloat(getComputedStyle(spoken).fontSize);
      while (caption.scrollHeight > caption.clientHeight + 1 && size > 18) {
        spoken.style.fontSize = --size + "px";
      }
    };
    requestAnimationFrame(fit);
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(fit);
  }
  window.PogShiftRecap = { render };
})();
