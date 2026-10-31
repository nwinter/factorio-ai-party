// Service epoch for scheduling; the actual WebAudio cursor for narrated subtitles.
// Loaded on both overlays, including ?mute. Never persist offsets/cursors over reload.
(() => {
  let skew = 0, audioEnabled = false;
  const tracks = new Map();
  const clock = window.pogPlaybackClock = {
    now: () => Date.now() / 1000 + skew,
    observe(t) {
      if (typeof t !== "number" || !Number.isFinite(t)) return;
      skew = t - Date.now() / 1000;
    },
    enableAudio() { audioEnabled = true; },
    track(id, state) {
      if (id == null) return;
      tracks.set(id, state);
      if (tracks.size > 100) tracks.delete(tracks.keys().next().value);
    },
    untrack(id, state) {
      if (tracks.get(id) === state) tracks.delete(id);  // release decoded audio when this clip finishes
    },
    elapsed(id, at) {
      if (!audioEnabled) return clock.now() - at;  // muted preview
      const x = tracks.get(id);
      // An unloaded, skipped, cancelled or reloaded narration must not show phantom speech.
      if (!x || x.done || x.when == null) return null;
      const t = x.context.currentTime - x.when;
      return t >= 0 && t < x.length ? t : null;  // freezes with a suspended audio context
    }
  };
})();
