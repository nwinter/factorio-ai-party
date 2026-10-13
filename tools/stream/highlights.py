"""Camera highlights (operator task 2026-10-13 13:00, after Nick 12:58: "Do we have a good way to show the
actions/attentions the agents are taking/paying to things live in the camera, as opposed to just attention on the
map?").

Each agent's latest attention point (attention.py; model.py keeps it: its last request that names a place) becomes a
highlight drawn in the game for the director camera clients only (the harness's operator `highlights`,
highlights.lua): a ring in the agent's colour on the spot, sized to the area, a dashed line from its character when the
spot is off to the side, and a label ("Sol · placing gun turret ghosts"). Agents never see them; nothing in the game
changes.

Highlights.step(snapshot, now), once per ticker beat (1 s): the set is the agents' attention rows under WINDOW seconds
old that have a position, newest first, at most MAX_ITEMS. It goes out as one operator dispatch when it changed, and
again every REFRESH seconds while it stands (each object lives TTL_S, so a stalled service leaves nothing behind);
never twice within MIN_GAP. A set that empties is cleared once. A runtime that refuses the call (older than
highlights.lua) turns sending off after FAIL_LIMIT refusals in a row.
"""
import json

import attention

WINDOW = 20.0     # seconds: an attention point older than this is no longer drawn
MAX_ITEMS = 12    # the harness's cap
MIN_GAP = 0.5     # seconds between calls (at most ~2/s)
TTL_S = 6.0       # seconds each drawn object lives in the game
REFRESH = 4.0     # seconds: an unchanged set is sent again before it expires
FAIL_LIMIT = 3


def rgb(color):
    """"#ffcb45", [255, 203, 69] or {r, g, b} (0..1 or 0..255) -> {r, g, b} in 0..1, or None."""
    if isinstance(color, str) and len(color) == 7 and color.startswith("#"):
        try:
            return {k: round(int(color[i:i + 2], 16) / 255, 3) for k, i in (("r", 1), ("g", 3), ("b", 5))}
        except ValueError:
            return None
    if isinstance(color, (list, tuple)) and len(color) >= 3:
        color = {"r": color[0], "g": color[1], "b": color[2]}
    if isinstance(color, dict) and all(isinstance(color.get(k), (int, float)) for k in "rgb"):
        scale = 255.0 if max(color[k] for k in "rgb") > 1 else 1.0
        return {k: round(max(0.0, min(1.0, color[k] / scale)), 3) for k in "rgb"}
    return None


def items(snapshot):
    """The highlight set from a snapshot: [{agent, position, surface, label, extent?, color?}], newest first."""
    rows = []
    for ag in snapshot.get("agents") or []:
        a = ag.get("attention")
        p = (a or {}).get("position")
        if not a or not isinstance(p, dict) or (a.get("age_s") or 0) > WINDOW:
            continue
        who = ag.get("display_name") or ag["name"]
        it = {"agent": ag["name"], "position": {"x": round(float(p["x"]), 2), "y": round(float(p["y"]), 2)},
              "surface": a.get("surface") or "nauvis", "label": f"{who} · {attention.head(a)}"[:80]}
        if a.get("extent"):
            it["extent"] = min(200.0, round(float(a["extent"]), 1))
        c = rgb(ag.get("color"))
        if c:
            it["color"] = c
        rows.append((a.get("age_s") or 0, it))
    rows.sort(key=lambda r: r[0])
    return [it for _, it in rows[:MAX_ITEMS]]


class Highlights:
    def __init__(self, send, ttl_s=TTL_S, refresh=REFRESH, min_gap=MIN_GAP):
        self.send, self.ttl_s, self.refresh, self.min_gap = send, ttl_s, refresh, min_gap
        self.key = None          # the set last drawn
        self.sent_t = float("-inf")
        self.drawn = False       # something of ours may be on screen
        self.fails, self.off, self.last_error = 0, False, None
        self.count = 0

    def step(self, snapshot, now):
        """Send the set if it changed or needs a refresh; returns the body sent, or None."""
        if self.off or now - self.sent_t < self.min_gap:
            return None
        its = items(snapshot)
        key = json.dumps(its, sort_keys=True)
        if not its:
            if not self.drawn:
                return None
            body = {"clear": True}
        elif key == self.key and now - self.sent_t < self.refresh:
            return None
        else:
            body = {"items": its, "ttl": int(self.ttl_s * 60)}
        try:
            reply = self.send(body)
        except Exception as e:  # the RCON link: try again on the next beat
            reply = {"ok": False, "error": {"message": f"{type(e).__name__}: {e}"}}
        self.sent_t = now
        if isinstance(reply, dict) and reply.get("ok") is not False:
            self.fails, self.last_error = 0, None
            self.key, self.drawn, self.count = key, bool(its), len(its)
        else:
            self.fails += 1
            self.last_error = (reply or {}).get("error") if isinstance(reply, dict) else str(reply)
            if self.fails >= FAIL_LIMIT:
                self.off = True
        return body

    def public(self):
        """snapshot `highlights`: whether it draws, how many items are up, the last error."""
        return {"on": not self.off, "items": self.count if self.drawn else 0, "error": self.last_error}
