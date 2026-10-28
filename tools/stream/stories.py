"""Operation stories carried to their results (d28 batch312 B, viewer Aurora 10:48: "Could the existing director and hosts
carry a few operation stories through to their results? For a ship trial or delivery, use connected main/inset views,
briefly explain the question and real team handoff, then show the result as passed, failed or still pending. Revisit
the same repaired spot after its watch completes.").

A story is one agent's flight watching of one platform (the harness's bounded watch of a platform over its next flight;
status work rows, model.py Agent.watches). Agents replace a watch at every leg (Astra's Resolute watches d28 ended
"replaced by #N" every 5-13 min), so a replacement carries the story on; it ends when the newest watch ends otherwise
or none is left on the card. Followed from the facts the stream service already has:
- the question: the open board item it is for (its #id in the watch, else an item of the watch's setter whose title
  names the platform as a word, as model.owner_work matches them); the handoff: who asked for that item
  (requested_by) when another agent took it, and who set the watch when not its owner; without an item, what the watch
  measures;
- while it runs: the platform's losses (model.py loss alerts on that platform) and its arrival (model.py arrivals);
- the agent's own read of the watch (work.WatchReads, from its journal: lost_count and ended_by), waited for READ_WAIT
  after the card says the watch is done;
- the result: passed (the item marked done, or the watch ended at an arrival with nothing lost), failed (the item
  dropped, or lost during the watch: how many, from the agent's read, else the stream's loss alerts), else pending (why
  it ended). The rule is said with the verdict.
- the spot: the latest build on that platform (a work item with a position: batch312 A's close-up) from 30 minutes
  before the watch began to its end: the result beat goes back there.

Two beats per story, each once: "open" (the watch is armed or running; one already running more than OPEN_LATE when
the service started is followed but not opened on air) and "result". A platform has one story on air per REPEAT_S
(Sol's Lark ran a watch per 2-minute leg): the next ones are followed quietly, and only a failure among them airs. model.py raises each as a "story" alert for the
hosts (caster.py) and lists the beats waiting in the snapshot (`stories`) for the director (onecam.maybe_story: the ship
on the main camera, the agent in the inset). Kept in runs/RUN/stories.json, so a restart keeps a story going.
"""
import json, os, re, time

KINDS = ("flight_watch",)
OPEN_LATE = 600       # s: a watch running longer than this when first seen is followed, not opened on air
SPOT_BEFORE = 1800    # s: a build this long before the watch began is its repaired spot
KEEP = 40             # stories kept (the newest)
BEAT_KEEP = 900       # s: a beat not aired within this long is left out of the snapshot
REPEAT_S = 1800       # s: a platform's next story within this long of one opened on air is followed quietly (a failure airs)
READ_WAIT = 120       # s: a watch done on the card waits this long for the agent's read of it
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
    # one about the trial itself first ("Resolute V-N flight watch: ..."), then the latest updated
    trial = re.compile(r"\b(?:flight|watch|trial|test)\b")
    return max(mine, key=lambda it: (bool(trial.search(str(it.get("title") or "").lower())), it.get("updated_tick") or 0)) if mine else None


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


def verdict(s, names=None):
    """(verdict, text) of a closed story: passed, failed or pending, with the rule said. The board item's status first
    (done: passed; dropped: failed), then the agent's own read of the last watch (lost_count, ended_by), then what the
    stream service saw (losses on the platform during the story, an arrival)."""
    it = s.get("item") or {}
    rd = s.get("read") if (s.get("read") or {}).get("id") == s.get("watch") else None
    who = (names or {}).get(s["agent"], s["agent"])
    if it.get("status") == "done":
        return "passed", f"#{it['id']} marked done"
    if it.get("status") == "dropped":
        return "failed", f"#{it['id']} dropped"
    lost = rd.get("lost_count") if rd and isinstance(rd.get("lost_count"), int) else sum((s.get("losses") or {}).values())
    src = f" ({who}'s read of the watch)" if rd and isinstance(rd.get("lost_count"), int) else ""
    if lost:
        return "failed", f"{lost} lost during the watch{src}"
    ended = str((rd or {}).get("ended_by") or s.get("ended_by") or "")
    if ended.startswith("arrived"):
        return "passed", f"{ended}, nothing lost during the watch{src}"
    if s.get("arrived"):
        return "passed", f"arrived at {s['arrived']['planet']}, nothing lost during the watch"
    return "pending", (f"the watch ended ({ended})" if ended else "the watch ended") + ", no arrival seen and no loss count read"


class Stories:
    def __init__(self, path=None):
        self.path = path
        self.stories = {}  # story id -> story
        self.aired = {}    # platform -> when a story of it last opened on air (REPEAT_S)
        self.dirty = False
        if path:
            try:
                with open(path) as f:
                    data = json.load(f)
                self.stories = {s["id"]: s for s in data.get("stories") or [] if isinstance(s, dict) and s.get("id")}
                self.aired = {k: v for k, v in (data.get("aired") or {}).items() if isinstance(v, (int, float))}
            except (OSError, ValueError, TypeError, AttributeError):
                pass

    def save(self):
        if not (self.path and self.dirty):
            return
        rows = sorted(self.stories.values(), key=lambda s: s["opened_t"])[-KEEP:]
        self.stories = {s["id"]: s for s in rows}
        try:
            tmp = self.path + ".tmp"
            with open(tmp, "w") as f:
                json.dump({"stories": rows, "aired": self.aired}, f, ensure_ascii=False)
            os.replace(tmp, self.path)
            self.dirty = False
        except OSError:
            pass

    def open_for(self, agent, platform):
        return next((s for s in self.stories.values() if s["state"] == "open" and s["agent"] == agent and s["platform"] == platform), None)

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

    def on_read(self, r, now):
        """An agent's read of its flight watch (work.WatchReads): kept on that agent's open story of the platform."""
        s = self.open_for(r.get("agent"), r.get("platform"))
        if s:
            s["read"] = {k: r.get(k) for k in ("id", "ended_by", "lost_count", "line")}
            self.dirty = True

    def update(self, model, now):
        """Open, follow and close stories from the agents' watches; the beats it raises go to model.alert. A story is
        one agent's watching of one platform: a watch replaced by the next ("replaced by #N", the next leg) carries it
        on; it ends when the newest watch ends otherwise, or none is left on the card. A watch done on the card waits
        READ_WAIT for the agent's read of it."""
        items = model.board.get("items") or {}
        names = {n: (a.display_name or n) for n, a in model.agents.items()}
        seen = set()
        for n, ag in model.agents.items():
            rows = {}
            for w in ag.watches or []:
                if isinstance(w, dict) and w.get("kind") in KINDS and w.get("id") and w.get("scope"):
                    rows.setdefault(str(w["scope"]), []).append(w)
            for plat, ws in rows.items():
                w = max(ws, key=lambda x: int(re.sub(r"\D", "", str(x["id"])) or 0))  # the newest: the current leg
                seen.add((n, plat))
                state = w.get("state")
                s = self.open_for(n, plat)
                if s is None:
                    if state not in ("armed", "running"):
                        continue
                    it = item_for(w, n, items)
                    started = model.tick_time(w["start_tick"]) if isinstance(w.get("start_tick"), (int, float)) and model.tick else now
                    sid = f"{n}:{w['id']}"
                    s = {"id": sid, "kind": w["kind"], "watch": str(w["id"]), "watches": [str(w["id"])], "agent": n, "platform": plat,
                         "opened_t": round(now, 1), "losses": {}, "arrived": None, "state": "open", "beats": {},
                         "item": self.item_row(it), "handoff": handoff(it, names, n), "line": w.get("line"),
                         "late": state == "running" and now - started > OPEN_LATE,
                         "quiet": now - self.aired.get(plat, -1e9) < REPEAT_S}
                    self.stories[sid] = s
                    if not (s["late"] or s["quiet"]):
                        self.aired[plat] = round(now, 1)
                        s["beats"]["open"] = {"t": round(now, 1)}
                        self.raise_beat(model, s, "open", names)
                    self.dirty = True
                if str(w["id"]) != s["watch"]:  # the next leg's watch: the same story
                    s["watch"] = str(w["id"])
                    s["watches"] = (s.get("watches") or [])[-7:] + [s["watch"]]
                    s.pop("done_t", None)
                    self.dirty = True
                if state == "running" and not s.get("ran"):
                    s["ran"] = True
                    self.dirty = True
                it = items.get((s.get("item") or {}).get("id"))
                if it and it.get("status") != (s["item"] or {}).get("status"):
                    s["item"] = self.item_row(it)
                    self.dirty = True
                if state not in ("armed", "running"):
                    m = ENDED.search(str(w.get("line") or ""))
                    why = m.group(1) if m else str(state)
                    if why.startswith("replaced"):
                        continue  # its next leg's watch comes on the card
                    s.setdefault("done_t", round(now, 1))
                    rd = s.get("read") or {}
                    if rd.get("id") == s["watch"] or now - s["done_t"] >= READ_WAIT:
                        self.close(model, s, why, now, names)
        for s in list(self.stories.values()):
            if s["state"] == "open" and (s["agent"], s["platform"]) not in seen and s["agent"] in model.agents:
                rd = s.get("read") or {}
                why = rd.get("ended_by") if rd.get("id") == s["watch"] and rd.get("ended_by") else "it left the agent's card"
                if str(why).startswith("replaced") and now - s.setdefault("gone_t", round(now, 1)) < READ_WAIT:
                    continue  # read after its replacement: the next leg's watch comes on the card
                self.close(model, s, why, now, names)
            elif s["state"] == "open":
                s.pop("gone_t", None)
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
        s["verdict"], s["result"] = verdict(s, names)
        # a result goes on air for a story opened on air, or a quiet one that failed; a watch dropped before its
        # flight (never ran, nothing decided) has none
        if (s.get("ran") or s["verdict"] != "pending") and (not (s.get("quiet") or s.get("late")) or s["verdict"] == "failed"):
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
