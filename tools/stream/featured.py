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
        data = dict(id=uuid.uuid4().hex, name=name.strip(), status="active", until=end, created=now, observed={})
        if not validate(data) or (at is not None and at <= now):
            raise ValueError("give a platform and --arrival LOCATION, --attempt-end, or a future --at time")
        self.data = data
        self.save()

    def finish(self, reason, now, cleared=False):
        self.data = dict(self.data or {}, status="cleared" if cleared else "ended", ended=now, reason=reason)
        self.save()
        print(f"[director] featured platform {self.data.get('name', '-')}: {reason}", flush=True)

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
        shot = d.platform_target(name, "featured", now + MAIN_S + CONTEXT_S)
        if not shot:
            return None
        detail = None if context else d.bow_defense(name)
        framing = "whole ship" if not detail else "bow defense"
        if detail:
            shot.pop("pan", None)
            shot.update(position=detail["position"], zoom=detail["zoom"], exact_zoom=True)
        shot["featured"] = self.active["id"]
        shot["platform"].update(framing=framing, label=f"Featured: {d.platform_label(name)} · {framing}")
        return shot

    @staticmethod
    def refresh(d, slot, old, shot, scores, now):
        # Refresh growing/repaired hulls without counting another cut. Keep the last acknowledged frame on failure.
        if old.get("pan") and old.get("pan") == shot.get("pan"):
            shot = dict(shot, position=old["position"])
        changed = any(old.get(k) != shot.get(k) for k in ("position", "surface", "zoom", "pan"))
        if changed:
            target = dict(old, **shot)
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
        if news and featured:
            self.started = now
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
    print(json.dumps(f.data, indent=2))


if __name__ == "__main__":
    main()
