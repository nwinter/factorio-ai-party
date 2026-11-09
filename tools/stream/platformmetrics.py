"""One bounded platform read per 20 wall seconds, prioritizing the active featured ship.

Rates compare matching legs and counter identities. They are per wall minute, including slow UPS; the first
sample, a pause, reversal, arrival, counter reset, missing read or changed turret roster has no invented rate.
"""
import copy
import math

EVERY = 20.0
MAX_AGE = 45.0


def number(n):
    return type(n) in (int, float) and math.isfinite(n)


def selected(snapshot):
    air = snapshot.get("onair") or {}
    if air.get("host") or snapshot.get("hostview") or snapshot.get("show") or (snapshot.get("replay") or {}).get("playing"):
        return None
    main = (snapshot.get("cameras") or {}).get("main") or {}
    if main.get("map"):
        return None
    surface = (main.get("frame") or {}).get("surface")
    rows = (snapshot.get("space") or {}).get("platforms") or []
    if surface:
        return next((p for p in rows if (p.get("view") or {}).get("surface") == surface), None)
    name = (main.get("ship") or {}).get("name") or (main.get("platform") or {}).get("name")
    if not name:
        return None
    return next((p for p in (snapshot.get("space") or {}).get("platforms") or []
                 if str(p.get("name", "")).casefold() == str(name or "").casefold()), None)


def view_area(snapshot, row):
    """The acknowledged main frame, using the director's 1080p/32-px tile geometry and on-air crop."""
    main = (snapshot.get("cameras") or {}).get("main") or {}
    fr = main.get("frame") or {}
    pos, zoom = fr.get("position"), fr.get("zoom")
    if fr.get("surface") != (row.get("view") or {}).get("surface") or not isinstance(pos, dict):
        return None
    if not all(number(x) for x in (pos.get("x"), pos.get("y"), zoom)) or zoom <= 0:
        return None
    frac = fr.get("frac", 1)
    if not number(frac) or not 0 < frac <= 1:
        return None
    hw, hh = 1920 / (64 * zoom) * frac, 1080 / (64 * zoom)
    if max(hw, hh) > 256:
        return None
    return [[pos["x"] - hw, pos["y"] - hh], [pos["x"] + hw, pos["y"] + hh]]


def leg_key(raw):
    l = raw.get("leg") or {}
    return (raw.get("surface"), l.get("connection"), l.get("from"), l.get("to"), l.get("back"),
            l.get("start_tick"), raw.get("at"))


def delta(now, old):
    return now - old if number(now) and number(old) and now >= old else None


def card(raw, old, seconds):
    out = {k: copy.deepcopy(raw[k]) for k in ("platform", "tick", "leg", "at", "speed_kms", "asteroids", "turrets",
           "repair_packs", "fuel", "losses_leg", "paused", "platform_paused") if raw.get(k) is not None}
    out["ammo"] = [{k: v for k, v in r.items() if k in ("name", "hub", "turrets")} for r in raw.get("ammo") or []]
    if (not old or leg_key(raw) != leg_key(old) or not number(seconds) or seconds <= 0
            or raw.get("paused") or old.get("paused")):
        return out
    ticks = delta(raw.get("tick"), old.get("tick"))
    if not ticks:
        return out
    out["window_s"] = round(seconds, 1)
    per_min = 60 / seconds
    for source, dest in (("hits_total", "hits_min"), ("damage_total", "damage_taken")):
        d = delta(raw.get(source), old.get(source))
        if d is not None:
            out[dest] = round(d * per_min if dest.endswith("_min") else d, 1)
    tallies, before = raw.get("tallies"), old.get("tallies")
    if (isinstance(tallies, dict) and isinstance(before, dict) and isinstance(tallies.get("units"), list)
            and tallies["units"] == before.get("units")):
        for source, dest in (("kills", "kills_min"), ("damage", "damage_dealt_min")):
            change = delta(tallies.get(source), before.get(source))
            if change is not None:
                out[dest] = round(change * per_min, 1)
    previous = {r["name"]: r for r in old.get("ammo") or []}
    for r, shown in zip(raw.get("ammo") or [], out["ammo"]):
        p = previous.get(r["name"], {})
        made, used = delta(r.get("made"), p.get("made")), delta(r.get("used"), p.get("used"))
        if made is not None and used is not None:
            shown.update(made_min=round(made * per_min, 1), used_min=round(used * per_min, 1),
                         net_min=round((made - used) * per_min, 1))
            # This is the measured hub + loaded-gun buffer, not endurance or a promise that ammo can reach a gun.
            if used > made and number(r.get("hub")) and number(r.get("turrets")):
                shown["buffer_min"] = round((r["hub"] + r["turrets"]) / ((used - made) * per_min), 1)
    l, speed = raw.get("leg") or {}, raw.get("speed_kms")
    if number(l.get("left_km")) and number(speed) and speed > 0 and not raw.get("platform_paused"):
        out["eta_wall_s"] = math.ceil(l["left_km"] / speed * 60 / (ticks / seconds))
    return out


class Metrics:
    def __init__(self):
        self.next_read = 0
        self.ships = {}

    def mission_sample(self, snapshot, now):
        """Existing offscreen featured cache for speech; never selects the overlay card or reads the game."""
        featured = snapshot.get("featured_platform") or {}
        if featured.get("status") != "active" or snapshot.get("paused"):
            return None
        state = self.ships.get(featured.get("name")) or {}
        value, seen = state.get("value"), state.get("seen")
        if not value or seen is None or not 0 <= now - seen <= MAX_AGE:
            return None
        result = copy.deepcopy(value)
        result.pop("asteroids", None)
        result.update(sample_t=seen, age_s=now - seen)
        return result

    def step(self, snapshot, read, now, supported=True):
        if not supported:
            self.ships.clear()
            return None
        # Observe all routes even off camera, so a reversal and return cannot reuse an earlier leg.
        rows = (snapshot.get("space") or {}).get("platforms") or []
        self.ships = {p["name"]: self.ships.get(p["name"], {}) for p in rows}
        for p in rows:
            state = self.ships[p["name"]]
            observed = (p["name"], tuple(p.get("route_ids") or []), bool(p.get("route")))
            if state.get("observed") != observed:
                state.clear()
                state["observed"] = observed
        row = selected(snapshot)
        featured = snapshot.get("featured_platform") or {}
        target = next((p for p in rows if featured.get("status") == "active" and
                       p["name"] == featured.get("name")), None) or row
        if snapshot.get("paused"):
            # Invalidate every ship, including offscreen baselines. Cached facts may still expire normally.
            for state in self.ships.values():
                raw = state.pop("previous", None)
                if raw:
                    state["value"] = card(raw, None, 0)
        elif target and now >= self.next_read:
            self.next_read = now + EVERY  # one global budget, including camera switches and failures
            state = self.ships[target["name"]]
            args = {"platform": target["name"]}
            area = view_area(snapshot, target) if row == target else None
            if area:
                args["area"] = area
            try:
                raw, _ = read("platform_metrics", args)
                if raw.get("platform") != target["name"] or not number(raw.get("tick")):
                    raise ValueError("platform_metrics returned a different platform or no tick")
                if not area:
                    raw = dict(raw)
                    raw.pop("asteroids", None)
                state["value"] = card(raw, state.get("previous"), now - state.get("seen", now))
                state.update(previous=raw, seen=now)
            except Exception:
                state.pop("previous", None)
                state.pop("value", None)
                raise
        # Collection can follow an offscreen attempt; publication still follows the acknowledged main camera.
        if not row:
            return None
        state = self.ships[row["name"]]
        value, seen = state.get("value"), state.get("seen", now)
        if value is None or now - seen > MAX_AGE:
            return None
        result = dict(value, sample_t=seen, age_s=max(0, round(now - seen)), featured=
                      featured.get("status") == "active" and featured.get("name") == row["name"])
        if snapshot.get("paused"):
            result["paused"] = True
            for key in ("window_s", "eta_wall_s", "kills_min", "hits_min", "damage_taken", "damage_dealt_min"):
                result.pop(key, None)
            result["ammo"] = [{k: v for k, v in r.items() if k in ("name", "hub", "turrets")} for r in result.get("ammo") or []]
        if not view_area(snapshot, row):
            result.pop("asteroids", None)
        return result
