"""Featured platform preference and operator CLI; no game/OBS calls.

python3 tools/stream/featured.py --run-dir runs/shift104 set Resolute --arrival shattered-planet --attempt-end
python3 tools/stream/featured.py --run-dir runs/shift104 set Resolute --at 2026-10-30T12:00:00Z
python3 tools/stream/featured.py --run-dir runs/shift104 clear
python3 tools/stream/featured.py --run-dir runs/shift104 status

The first matching end condition wins. attempt-end means a confirmed loss, a reversal of an observed leg,
or landing after observed flight. Missing telemetry alone never ends an attempt. State follows resumed-from;
clear/end records prevent an older preference resurfacing. The normal director still handles urgent coverage.
"""
import argparse
import copy
from datetime import datetime
import json
import math
from pathlib import Path
import tempfile
import time
import uuid

NAME = "director-featured.json"
MAIN_S, CONTEXT_S, AWAY_S = 180.0, 60.0, 90.0
AUTO_KM = 100_000
DEEP = {"solar-system-edge", "shattered-planet"}


def long_run(row, threshold=AUTO_KM):
    route = row.get("route_ids") or []
    if len(route) != 2 or not row.get("route"):
        return False
    return bool(DEEP.intersection(route) or (row.get("leg_km") or 0) >= threshold)


def distance_out(row):
    """Rank known deep connections by distance out, in either direction; generic long legs by progress."""
    route = row.get("route_ids") or []
    pct = max(0, min(100, (row.get("route") or {}).get("pct", 0))) / 100
    if row.get("leg_km") and row.get("leg_progress_km") is not None:
        pct = max(0, min(1, row["leg_progress_km"] / row["leg_km"]))
    depths = {"aquilo": 0, "solar-system-edge": 100_000, "shattered-planet": 4_100_000}
    if len(route) == 2 and all(n in depths for n in route):
        return depths[route[0]] * (1 - pct) + depths[route[1]] * pct
    return row.get("leg_progress_km") or (row.get("leg_km") or 0) * pct


def validate(data):
    if not isinstance(data, dict) or data.get("status") != "active":
        return None
    if not isinstance(data.get("name"), str) or not data["name"].strip() or not isinstance(data.get("id"), str):
        return None
    if type(data.get("created")) not in (int, float) or not math.isfinite(data["created"]):
        return None
    observed = data.get("observed", {})
    if not isinstance(observed, dict) or ("route" in observed and not (
            isinstance(observed["route"], list) and len(observed["route"]) == 2 and
            all(isinstance(n, str) for n in observed["route"]))):
        return None
    end = data.get("until")
    if not isinstance(end, dict) or not any(end.get(k) for k in ("arrival", "attempt_end", "at")):
        return None
    if "arrival" in end and (not isinstance(end["arrival"], str) or not end["arrival"].strip()):
        return None
    if "at" in end and (type(end["at"]) not in (int, float) or not math.isfinite(end["at"])):
        return None
    if "attempt_end" in end and not isinstance(end["attempt_end"], bool):
        return None
    return copy.deepcopy(data)


class Featured:
    def __init__(self, run_dir=None):
        self.path = Path(run_dir).resolve() / NAME if run_dir else None
        self.data = None
        self.stamp = object()
        self.loaded = False
        self.started = None
        self.away_until = 0
        self.current_id = None
        self.news_seen = set()
        self.repairs = set()

    @property
    def active(self):
        return self.data if (self.data or {}).get("status") == "active" else None

    def inherited(self):
        path, seen = self.path, set()
        while path and path not in seen:
            seen.add(path)
            if path.exists():
                return path
            try:
                parent = (path.parent / "resumed-from").read_text().strip()
            except OSError:
                break
            if not parent or "/" in parent or "\\" in parent or parent in (".", ".."):
                break
            path = path.parent.parent / parent / NAME
        return self.path

    def load(self):
        if not self.path:
            return
        path = self.path if self.loaded else self.inherited()
        try:
            stamp = path.stat().st_mtime_ns
        except OSError:
            stamp = None
        if self.loaded and stamp == self.stamp:
            return
        if self.loaded and stamp is None and self.active:
            self.finish("setting removed", time.time(), cleared=True)
            return
        try:
            data = json.loads(path.read_text()) if stamp is not None else None
        except (OSError, ValueError):
            data = None
        self.data = validate(data) or (data if isinstance(data, dict) and data.get("status") in ("ended", "cleared") else None)
        if stamp is not None and self.data is None:
            self.data = {"source": "operator", "status": "cleared", "reason": "invalid setting"}
        self.stamp, self.loaded = stamp, True
        if path != self.path and self.data is not None:
            self.save()  # carry to the new run once; later changes/clears are this run's own

    def save(self):
        if not self.path:
            return
        # Unique temporary names allow CLI edits while the service is reading. Readers see only whole records.
        with tempfile.NamedTemporaryFile(mode="w", dir=self.path.parent, prefix=NAME + ".", delete=False) as f:
            json.dump(self.data, f, indent=2)
            tmp = Path(f.name)
        tmp.replace(self.path)
        self.stamp, self.loaded = self.path.stat().st_mtime_ns, True

    def set(self, name, *, arrival=None, attempt_end=False, at=None, now=None):
        now = time.time() if now is None else now
        end = {k: v for k, v in dict(arrival=arrival, attempt_end=attempt_end, at=at).items() if v is not None and v is not False}
        data = dict(id=uuid.uuid4().hex, name=name.strip(), source="operator", status="active", until=end, created=now, observed={})
        if not validate(data) or (at is not None and at <= now):
            raise ValueError("give a platform and --arrival LOCATION, --attempt-end, or a future --at time")
        self.data = data
        self.save()

    def finish(self, reason, now, cleared=False):
        self.data = dict(self.data or {}, status="cleared" if cleared else "ended", ended=now, reason=reason)
        if cleared:
            self.data["source"] = "operator"  # an explicit clear suppresses automatic selection too
        elif self.data.get("source") == "auto" and self.data.get("name"):
            self.data.setdefault("auto_blocked", {})[self.data["name"]] = True
        self.save()
        print(f"[director] featured platform {self.data.get('name', '-')}: {reason}", flush=True)

    def automatic(self, snapshot, now, threshold=AUTO_KM):
        """One auto feature, furthest out. A turned-back attempt cannot immediately select its return leg."""
        data = self.data or {}
        if data and data.get("source") != "auto":
            if data.get("status") != "ended":
                return  # includes legacy active operator settings and explicit clear records
            # The operator's deadline/arrival/attempt has ended. Do not reselect that same ongoing attempt,
            # but allow other ships and future departures to qualify automatically.
            data = dict(data, source="auto", auto_blocked={**(data.get("auto_blocked") or {}), data.get("name"): True})
            self.data = data
            self.save()
        rows = (snapshot.get("space") or {}).get("platforms") or []
        blocked = dict(data.get("auto_blocked") or {})
        for row in rows:
            if not row.get("route") and row.get("where") not in (None, "", "in transit"):
                blocked.pop(row.get("name"), None)  # arrival permits a later, new departure
        candidates = [p for p in rows if p.get("name") not in blocked and long_run(p, threshold)
                      and not (p.get("route") or {}).get("turned_back")]
        if self.active and not any(p.get("name") == data["name"] for p in rows):
            return  # a missing read is not an ended leg
        row = max(candidates, key=lambda p: (distance_out(p), p["name"]), default=None)
        if row and (not self.active or row["name"] != data.get("name")):
            self.data = dict(id=uuid.uuid4().hex, name=row["name"], source="auto", status="active", created=now,
                             until={"attempt_end": True, "arrival": row["route_ids"][1]},
                             observed={"departed": True, "route": row["route_ids"]}, auto_blocked=blocked)
            self.save()
            print(f"[director] featured platform {row['name']}: auto long run", flush=True)
        elif blocked != data.get("auto_blocked", {}):
            self.data = dict(data, auto_blocked=blocked)
            self.save()

    def sync(self, snapshot, now):
        self.load()
        data = self.active
        if not data:
            return
        end, name = data["until"], data["name"].casefold()
        if end.get("at") is not None and now >= end["at"]:
            self.finish("time expired", now)
            return
        space = snapshot.get("space") or {}
        row = next((p for p in space.get("platforms") or [] if p.get("name", "").casefold() == name), None)
        if any(p.get("name", "").casefold() == name and p.get("t", now) >= data["created"] for p in space.get("lost") or []):
            self.finish("platform lost", now)
            return
        if not row:
            return
        from model import planet_label
        moving = bool(row.get("route")) or row.get("state") == "on_the_path"
        place = str(row.get("where") or "").casefold()
        stopped = not moving and place not in ("", "in transit")
        if end.get("arrival") and stopped and place == planet_label(end["arrival"]).casefold():
            self.finish("arrived at " + end["arrival"], now)
            return
        obs = data.setdefault("observed", {})
        route = row.get("route_ids")
        if end.get("attempt_end") and obs.get("departed"):
            old = obs.get("route")
            if stopped or (old and route == list(reversed(old))) or (row.get("route") or {}).get("turned_back"):
                self.finish("attempt ended: landed" if stopped else "attempt ended: turned back", now)
                return
        updated = dict(obs)
        if moving:
            updated["departed"] = True
        if isinstance(route, list) and len(route) == 2:
            updated["route"] = route
        if updated != obs:
            data["observed"] = updated
            self.save()

    def resolve(self, director):
        name = self.active and self.active["name"].casefold()
        return next((n for n, r in director.plat_rows.items() if n.casefold() == name and
                     (r.get("view") or {}).get("surface")), None)

    def prepare(self, d, snapshot, now):
        self.sync(snapshot, now)
        if d.cfg.get("auto_feature", True):
            self.automatic(snapshot, now, d.cfg.get("auto_feature_km", AUTO_KM))
        identity = self.active and self.active["id"]
        name = self.resolve(d)
        if identity != self.current_id or not name:
            self.started, self.away_until = None, 0
            self.current_id = identity
            self.news_seen.clear()
            self.repairs.clear()
            for t in d.state.values():
                if t and t.get("featured"):
                    t["until"] = 0
            for slot, p in list(d.send_pending.items()):
                if (p.get("target") or {}).get("featured"):
                    d.send_pending.pop(slot)
            if d.pending and (d.state.get(d.pending["slot"]) or {}).get("featured"):
                d.pending = None
            if d.inset and d.inset.get("why") == "featured":
                d.inset = None
        return name

    def news(self, d, snapshot, name, now):
        candidates = []
        danger = (d.plat_rows.get(name) or {}).get("danger") or {}
        if danger.get("kind") == "fire" and now - danger.get("last", 0) <= 30:
            candidates.append(("encounter", danger.get("last")))
        for w in snapshot.get("work") or []:
            if w.get("platform") == name and now - w.get("t", 0) <= 30 and any(
                    k in " ".join(str(w.get(field) or "") for field in ("kind", "action", "verb", "label")).lower()
                    for k in ("repair", "build", "construct")):
                candidates.append(("repair/build", w.get("id") or w.get("t")))
        for m in (snapshot.get("space") or {}).get("moments") or []:
            if (m.get("facts") or {}).get("platform") == name and now - m.get("t", 0) <= 30:
                candidates.append(("milestone", m.get("id") or m.get("t")))
        surface = ((d.plat_rows.get(name) or {}).get("view") or {}).get("surface")
        repairing = {a["name"] for a in snapshot.get("agents") or [] if a.get("alive") and
                     str(a.get("active") or "").split(":")[0] == "repair" and
                     (a.get("surface") == surface or (a.get("attention") or {}).get("platform") == name)}
        repair_started = bool(repairing - self.repairs)
        self.repairs = repairing
        fresh = [x for x in candidates if x not in self.news_seen]
        self.news_seen.update(candidates)
        return "repair" if repair_started else fresh[0][0] if fresh else None

    def shot(self, d, name, now, context=False):
        shot = d.platform_target(name, "featured", now + MAIN_S + CONTEXT_S, overview=True)
        if not shot:
            return None
        framing = "ship survey"
        shot["featured"] = self.active["id"]
        source = self.active.get("source", "operator")
        shot["platform"].update(framing=framing, source=source, label=f"Featured: {d.platform_label(name)} · {framing}")
        return shot

    @staticmethod
    def refresh(d, slot, old, shot, scores, now):
        # Refresh growing/repaired hulls without counting another cut. Keep the last acknowledged frame on failure.
        q = d.surveys.get(old.get("survey_key"))
        if old.get("survey") and shot.get("survey") and q and now < q.expires and all(
                old["survey"][k] == shot["survey"][k] for k in ("bow", "stern", "bounds", "frac", "surface")):
            old["platform"]["label"] = shot["platform"]["label"]
            old["survey"] = copy.deepcopy(shot["survey"])
            q.spec["details"] = copy.deepcopy(shot["survey"]["details"])
            return
        if old.get("pan") and old.get("pan") == shot.get("pan"):
            shot = dict(shot, position=old["position"])
        changed = any(old.get(k) != shot.get(k) for k in ("position", "surface", "zoom", "pan", "survey"))
        changed = changed or bool(shot.get("survey") and (q is None or now >= q.expires))
        if changed:
            target = dict(old, **shot)
            for key in ("survey_step", "move", "move_ok", "glide"):
                target.pop(key, None)
            if not shot.get("survey"):
                for key in ("survey", "survey_key", "survey_step", "move", "move_ok"):
                    target.pop(key, None)
            # Remove a previous pan when changing to a fixed defense view.
            if "pan" not in shot:
                target.pop("pan", None)
            d.apply(slot, target, "reframe", scores, now, quiet=True)
        else:
            old["platform"]["label"] = shot["platform"]["label"]

    def main(self, d, snapshot, scores, now, pinned, segment, attack):
        name = self.resolve(d)
        if not name:
            return False
        cur = d.state.get(d.onair) or {}
        urgent = ((cur.get("subject") == "@attack" and now < cur.get("until", 0)) or
                  now < cur.get("hold_until", 0) or
                  (cur.get("subject") in scores and d.fighting(cur["subject"], d.agents_now, now)))
        if pinned or segment or attack or urgent or d.hold_layout:
            self.started = None  # the next featured stint gets its full readable dwell after the interruption
            return False
        if d.pending and not (d.state.get(d.pending["slot"]) or {}).get("featured"):
            return False
        news = self.news(d, snapshot, name, now)
        if news:
            self.away_until = 0
        featured = cur.get("featured") == self.active["id"] and now < cur.get("until", 0)
        if featured and self.started is None:
            self.started = now
        # News can recall the ship from other coverage, but does not postpone its context shot indefinitely.
        age = now - self.started if self.started is not None else 0
        if self.started is not None and age >= MAIN_S + CONTEXT_S:
            self.started, self.away_until = None, now + AWAY_S
            cur["until"] = 0
        if now < self.away_until:
            return False
        if d.pending:
            return True
        shot = self.shot(d, name, now, context=age >= MAIN_S)
        if featured and cur.get("platform", {}).get("framing") == shot["platform"]["framing"]:
            self.refresh(d, d.slot(d.onair), cur, shot, scores, now)
            return True
        d.urgent(shot, f"featured platform {name}: {news or shot['platform']['framing']}", scores, now)
        return True

    def inset(self, d, scores, now):
        name = self.resolve(d)
        cur = d.state.get(d.onair) or {}
        if not name or d.hosting(now) or d.hold_layout or d.mode != "onecam":
            return
        if (cur.get("platform") or {}).get("name") == name or d.surface_platform(cur.get("surface")) == name:
            if d.inset and d.inset.get("why") == "featured":
                d.inset = None
            return
        if d.inset and d.inset.get("why") != "featured":
            return
        slot = d.slot(d.inset["slot"]) if d.inset else d.inset_free([
            s for s in d.standbys() if not (d.pending and s["slot"] == d.pending["slot"])])
        if not slot:
            return
        shot = self.shot(d, name, now)
        old = d.state.get(slot["slot"]) or {}
        if old.get("featured") != shot["featured"] or old.get("surface") != shot["surface"]:
            d.frame_on(slot, shot, f"featured platform {name}: inset", scores, now)
        else:
            self.refresh(d, slot, old, shot, scores, now)
            old["until"] = shot["until"]
        d.inset = dict(slot=slot["slot"], until=now + 30, why="featured", t=now)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--run-dir", required=True)
    sub = p.add_subparsers(dest="command", required=True)
    setp = sub.add_parser("set")
    setp.add_argument("name")
    setp.add_argument("--arrival")
    setp.add_argument("--attempt-end", action="store_true")
    setp.add_argument("--at", help="ISO timestamp with timezone, e.g. 2026-10-30T12:00:00Z")
    sub.add_parser("clear")
    sub.add_parser("auto", help="release the operator override and enable automatic long-run selection")
    sub.add_parser("status")
    a = p.parse_args(argv)
    f = Featured(a.run_dir)
    f.load()
    if a.command == "set":
        try:
            dt = datetime.fromisoformat(a.at.replace("Z", "+00:00")) if a.at else None
            if dt and dt.tzinfo is None:
                raise ValueError("--at needs a timezone")
            f.set(a.name, arrival=a.arrival, attempt_end=a.attempt_end, at=dt.timestamp() if dt else None)
        except ValueError as e:
            p.error(str(e))
    elif a.command == "clear":
        f.finish("cleared by operator", time.time(), cleared=True)
    elif a.command == "auto":
        f.data = {"source": "auto", "status": "ended", "reason": "automatic coverage enabled"}
        f.save()
    print(json.dumps(f.data, indent=2))


if __name__ == "__main__":
    main()
