// Prepared cards only: no game queries. Both aspect ratios use the main camera's box.
(() => {
  const el = (tag, cls, text) => {
    const node = document.createElement(tag);
    node.className = cls;
    if (text != null) node.textContent = text;
    return node;
  };
  let panel, key;
  function render(s) {
    const recap = s && s.shift_recap;
    if (!panel) {
      const camera = document.getElementById("cam-main");
      if (!camera) return;
      panel = el("section", "shift-recap");
      panel.setAttribute("aria-label", "Recorded shift recap");
      camera.appendChild(panel);
    }
    panel.hidden = !recap || !recap.active;
    if (panel.hidden) { key = null; return; }
    const next = JSON.stringify(recap);
    if (next === key) return;
    key = next;
    panel.replaceChildren();
    panel.append(el("div", "sr-kicker", `${recap.run} · ${recap.phase === "transition" ? "SHIFT CHANGE" : "SHIFT RECAP"}`));
    panel.append(el("h2", "sr-title", recap.title));
    if (recap.still) {
      const figure = el("figure", "sr-still");
      const img = el("img", "");
      img.src = recap.still.url;
      img.alt = recap.still.caption;
      figure.append(img, el("figcaption", "", recap.still.caption));
      panel.append(figure);
    }
    const spoken = el("p", "sr-text");
    if (recap.speaker) spoken.append(el("b", "sr-speaker", recap.speaker + "  "));
    spoken.append(document.createTextNode(recap.text || ""));
    panel.append(spoken);
    const sources = (recap.sources || []).map(r => `${r.game_time ? "Game " + r.game_time : r.wall_time} · ${r.source}:${r.row}`);
    if (sources.length) panel.append(el("p", "sr-source", sources.join(" / ")));
    if (recap.phase !== "transition" && recap.timeline && recap.timeline.length) {
      const list = el("ol", "sr-timeline");
      // Latest three turns are readable at either canvas size; the offline sheet keeps all entries.
      for (const row of recap.timeline.slice(-3)) {
        const li = el("li", "");
        li.append(el("time", "", row.game_time ? "Game " + row.game_time : row.wall_time),
                  el("span", "", row.text));
        list.append(li);
      }
      panel.append(list);
    }
    if (recap.holding) panel.append(el("p", "sr-holding", "The recap is complete. Waiting for the next team to finish starting."));
  }
  window.PogShiftRecap = { render };
})();
