"""Operation stories carried to their results (d28 batch312 B, viewer Aurora 10:48: "Could the existing director and hosts
carry a few operation stories through to their results? For a ship trial or delivery, use connected main/inset views,
briefly explain the question and real team handoff, then show the result as passed, failed or still pending. Revisit
the same repaired spot after its watch completes.").

A story is an agent's flight watch (the harness's bounded watch of a platform over its next flight; status work rows,
model.py Agent.watches), followed from the facts the stream service already has:
- the question: the open board item it is for (its #id in the watch, else an item of the watch's setter whose title
  names the platform as a word, as model.owner_work matches them); the handoff: who asked for that item
  (requested_by) when another agent took it, and who set the watch when not its owner; without an item, what the watch
  measures;
- while it runs: the platform's losses (model.py loss alerts on that platform) and its arrival (model.py arrivals);
- the result, when the watch ends (its row says "ended (why)") or leaves the card (read or dropped): passed (the item
  marked done, or the platform arrived with nothing lost during the watch), failed (the item dropped, or something lost
  during the watch: how many), else pending (why it ended, the result not read). The rule is said with the verdict.
- the spot: the latest build on that platform (a work item with a position: batch312 A's close-up) from 30 minutes
  before the watch began to its end: the result beat goes back there.

Two beats per story, each once: "open" (the watch is armed or running; one already running more than OPEN_LATE when
the service started is followed but not opened on air) and "result". model.py raises each as a "story" alert for the
hosts (caster.py) and lists the beats waiting in the snapshot (`stories`) for the director (onecam.maybe_story: the ship
on the main camera, the agent in the inset). Kept in runs/RUN/stories.json, so a restart keeps a story going.
"""
import json, os, re, time

KINDS = ("flight_watch",)
OPEN_LATE = 600       # s: a watch running longer than this when first seen is followed, not opened on air
SPOT_BEFORE = 1800    # s: a build this long before the watch began is its repaired spot
KEEP = 40             # stories kept (the newest)
BEAT_KEEP = 900       # s: a beat not aired within this long is left out of the snapshot
ENDED = re.compile(r"ended \(([^)]*)\)")
BUILDS = {"place_ghosts", "paste", "blueprint_place", "deconstruct", "cancel_deconstruction", "remove_ghosts"}


def item_for(watch, agent, items):
    """The open board item a watch is for: its #id named in the watch's scope or line, else one of the setter's items
    (owner or agent) whose title names the watch's platform as a word, the most recently updated. Or None."""
    text = " ".join(str(watch.get(k) or "") for k in ("scope", "reason", "line"))
    for m in re.finditer(r"#(\d+)", text):
        it = items.get(int(m.group(1)))
        if it:
            return it
    plat = str(watch.get("scope") or "").strip()
    if len(plat) < 3:
        return None
    pat = re.compile(r"\b" + re.escape(plat.lower()) + r"\b")
    mine = [it for it in items.values() if agent in (it.get("owner"), it.get("agent")) and pat.search(str(it.get("title") or "").lower())
            and it.get("status") not in ("done", "dropped")]
    return max(mine, key=lambda it: it.get("updated_tick") or 0) if mine else None


def handoff(it, names, setter):
    """The team's handoff on the item, from the board: 'asked by Sol, taken by Astra' when another agent asked for it,
    and 'the watch set by Luna' when the watch's setter is not its owner; or None."""
    if not it:
        return None
    owner = it.get("owner") or it.get("agent")
    by = it.get("requested_by")
    parts = []
    if by and owner and by != owner:
        parts.append(f"asked by {names.get(by, by)}, taken by {names.get(owner, owner)}")
    if owner and setter != owner:
        parts.append(f"{names.get(owner, owner)}'s item, the watch set by {names.get(setter, setter)}")
    return "; ".join(parts) or None


def verdict(s):
    """(verdict, text) of a closed story: passed, failed or pending, with the rule said."""
    it = s.get("item") or {}
    lost = sum((s.get("losses") or {}).values())
    arrived = s.get("arrived")
    if it.get("status") == "done":
        return "passed", f"#{it['id']} marked done"
    if it.get("status") == "dropped":
        return "failed", f"#{it['id']} dropped"
    if lost:
        return "failed", f"{lost} lost during the watch"
    if arrived:
        return "passed", f"arrived at {arrived['planet']} with nothing lost during the watch"
    why = s.get("ended_by")
    return "pending", (f"the watch ended ({why})" if why else "the watch ended") + ", no arrival seen and the result not read yet"


class Stories:
    def __init__(self, path=None):
        self.path = path
        self.stories = {}  # watch id -> story
        self.dirty = False
        if path:
            try:
                with open(path) as f:
                    data = json.load(f)
                self.stories = {s["id"]: s for s in data.get("stories") or [] if isinstance(s, dict) and s.get("id")}
            except (OSError, ValueError, TypeError):
                pass

    def save(self):
        if not (self.path and self.dirty):
            return
        rows = sorted(self.stories.values(), key=lambda s: s["opened_t"])[-KEEP:]
        self.stories = {s["id"]: s for s in rows}
        try:
            tmp = self.path + ".tmp"
            with open(tmp, "w") as f:
                json.dump({"stories": rows}, f, ensure_ascii=False)
            os.replace(tmp, self.path)
            self.dirty = False
        except OSError:
            pass

    def on_loss(self, platform, key, total, now):
        """A loss on a platform (model.py loss alerts, re-reported with a growing total): counted on its open stories."""
        for s in self.stories.values():
            if s["state"] == "open" and s["platform"] == platform and now >= s["opened_t"]:
                if total > s["losses"].get(key, 0):
                    s["losses"][key] = total
                    self.dirty = True

    def on_arrival(self, platform, planet, now):
        for s in self.stories.values():
            if s["state"] == "open" and s["platform"] == platform and s.get("ran"):
                s["arrived"] = {"planet": planet, "t": round(now, 1)}
                self.dirty = True

    def update(self, model, now):
        """Open, follow and close stories from the agents' watches; the beats it raises go to model.alert."""
        items = model.board.get("items") or {}
        names = {n: (a.display_name or n) for n, a in model.agents.items()}
        seen = set()
        for n, ag in model.agents.items():
            for w in ag.watches or []:
                if not isinstance(w, dict) or w.get("kind") not in KINDS or not w.get("id"):
                    continue
                wid = f"{n}:{w['id']}"
                seen.add(wid)
                s = self.stories.get(wid)
                state = w.get("state")
                if s is None:
                    if state not in ("armed", "running"):
                        continue
                    it = item_for(w, n, items)
                    started = model.tick_time(w["start_tick"]) if isinstance(w.get("start_tick"), (int, float)) and model.tick else now
                    s = {"id": wid, "kind": w["kind"], "watch": str(w["id"]), "agent": n, "platform": str(w.get("scope") or ""),
                         "opened_t": round(now, 1), "losses": {}, "arrived": None, "state": "open", "beats": {},
                         "item": self.item_row(it), "handoff": handoff(it, names, n), "line": w.get("line"),
                         "late": state == "running" and now - started > OPEN_LATE}
                    if not s["late"]:
                        s["beats"]["open"] = {"t": round(now, 1)}
                        self.raise_beat(model, s, "open", names)
                    self.stories[wid] = s
                    self.dirty = True
                if s["state"] != "open":
                    continue
                if state == "running" and not s.get("ran"):
                    s["ran"] = True
                    self.dirty = True
                it = items.get((s.get("item") or {}).get("id"))
                if it and it.get("status") != (s["item"] or {}).get("status"):
                    s["item"] = self.item_row(it)
                    self.dirty = True
                if state not in ("armed", "running"):
                    m = ENDED.search(str(w.get("line") or ""))
                    self.close(model, s, m.group(1) if m else state, now, names)
        for wid, s in list(self.stories.items()):
            if s["state"] == "open" and wid not in seen and wid.split(":", 1)[0] in model.agents:
                self.close(model, s, "left the agent's card (read or dropped)", now, names)
        self.save()

    @staticmethod
    def item_row(it):
        return {k: it.get(k) for k in ("id", "title", "status", "owner", "requested_by")} if it else None

    def close(self, model, s, why, now, names):
        s.update(state="closed", closed_t=round(now, 1), ended_by=why)
        it = (model.board.get("items") or {}).get((s.get("item") or {}).get("id"))
        if it:
            s["item"] = self.item_row(it)
        s["spot"] = self.spot(model, s, now)
        s["verdict"], s["result"] = verdict(s)
        if s.get("ran") or s["verdict"] != "pending":  # a watch dropped before its flight: no result to show
            s["beats"]["result"] = {"t": round(now, 1)}
            self.raise_beat(model, s, "result", names)
        self.dirty = True

    @staticmethod
    def spot(model, s, now):
        """The latest build on the story's platform from SPOT_BEFORE before it opened to now, with a position."""
        best = None
        for w in list(model.work):
            if w.get("platform") == s["platform"] and w.get("action") in BUILDS and isinstance(w.get("position"), dict) \
                    and s["opened_t"] - SPOT_BEFORE <= w["t"] <= now and (best is None or w["t"] > best["t"]):
                best = w
        return {k: best.get(k) for k in ("agent", "action", "verb", "position", "extent", "what", "t")} if best else None

    def caption(self, s, beat, names):
        who = names.get(s["agent"], s["agent"])
        it = s.get("item")
        q = f"#{it['id']} {it['title']}" if it else f"what {s['platform']} loses and uses over its next flight"
        if beat == "open":
            return (f"{who} set a flight watch on {s['platform']} · the question: {q}"
                    + (f" · {s['handoff']}" if s.get("handoff") else ""))
        word = {"passed": "Passed", "failed": "Failed", "pending": "Still pending"}[s["verdict"]]
        return f"{s['platform']} flight watch · {word}: {s['result']}" + (f" · the work {who}'s team did there" if s.get("spot") else "")

    def raise_beat(self, model, s, beat, names):
        title = self.caption(s, beat, names)
        facts = {"story": "a ship trial (flight watch)", "beat": beat, "platform": s["platform"], "set_by": names.get(s["agent"], s["agent"]),
                 "question": (f"#{s['item']['id']}: {s['item']['title']}" if s.get("item") else None),
                 "handoff": s.get("handoff")}
        if beat == "result":
            facts.update(result=s["verdict"], why=s["result"], lost_during_watch=sum(s["losses"].values()),
                         arrived_at=(s.get("arrived") or {}).get("planet"), ended=s.get("ended_by"),
                         item_status=(s.get("item") or {}).get("status"),
                         revisits=("the spot where " + names.get(s["spot"]["agent"], s["spot"]["agent"]) + " last built on it")
                         if s.get("spot") else None)
        model.alert("story", title, key=f"story:{s['id']}:{beat}", ttl=120, agent=s["agent"],
                    facts={k: v for k, v in facts.items() if v not in (None, "", [])})
        s["beats"][beat]["caption"] = title

    def public(self, now, names=None):
        """The beats waiting for the director, oldest first: [{key, beat, platform, agent, caption, t, spot?}]."""
        out = []
        for s in self.stories.values():
            for beat in ("open", "result"):
                b = s["beats"].get(beat)
                if b and now - b["t"] < BEAT_KEEP:
                    row = {"key": f"{s['id']}:{beat}", "beat": beat, "platform": s["platform"], "agent": s["agent"],
                           "caption": b.get("caption") or "", "t": b["t"]}
                    if beat == "result" and s.get("spot"):
                        row["spot"] = s["spot"]
                    if beat == "result":
                        row["verdict"] = s["verdict"]
                    out.append(row)
        return sorted(out, key=lambda r: r["t"])
