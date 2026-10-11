"""Night lift: brighten the game captures in OBS when the game gets dark, without touching the game.

Factorio's night darkens what the director clients render (LuaSurface.darkness, ~0.85 at midnight), which on stream
reads as a black screen. The service reads darkness (read-only, harness.STREAM_LUA) and this worker ramps a colour
correction filter ("night lift") on the camera captures: more gamma, a little brightness, contrast and saturation as
it gets darker, back to neutral by day. Changes ramp slowly (no visible pumping) and are only sent when they move by a
noticeable step. The filter is created on each capture if missing; nothing else on the sources is changed.
"""
import threading, time, traceback

from obsws import OBS, OBSError

DEFAULTS = {
    "inputs": ["stream cam1", "stream cam2", "stream cam3"],  # tools/obs.py stream_scene's game captures
    "filter": "night lift",
    "start": 0.2,       # darkness where the lift begins
    "full": 0.75,       # darkness of full lift
    "gamma": 0.6,       # colour correction values at full lift (OBS: gamma > 0 brightens the midtones)
    "brightness": 0.03,
    "contrast": 0.12,
    "saturation": 0.15,
    "ramp": 0.04,       # lift change per second at most
    "step": 0.03,       # send when the lift moved this much
}


def lift_for(darkness, cfg=DEFAULTS):
    if darkness is None:
        return 0.0
    return max(0.0, min(1.0, (darkness - cfg["start"]) / (cfg["full"] - cfg["start"])))


def settings_for(lift, cfg=DEFAULTS):
    return {k: round(cfg[k] * lift, 3) for k in ("gamma", "brightness", "contrast", "saturation")}


class NightLift:
    def __init__(self, obs=None, log=print, start=True, **cfg):
        self.cfg = dict(DEFAULTS, **{k: v for k, v in cfg.items() if v is not None})
        self.obs = obs or OBS()
        self.log = log
        self.target = 0.0
        self.lift = None      # current (ramped) lift; None until the filters are known
        self.sent = None      # lift last sent
        self.kind = None
        self.ready = set()    # inputs that have the filter
        self.status = {"darkness": None, "lift": None, "sent": None, "error": None, "inputs": []}
        self.t = time.time()
        if start:
            threading.Thread(target=self.run, daemon=True).start()

    def set_darkness(self, darkness):
        self.status["darkness"] = darkness
        self.target = lift_for(darkness, self.cfg)

    def run(self):
        while True:
            try:
                self.work(time.time())
                self.status["error"] = None
            except (OSError, OBSError) as e:
                self.status["error"] = str(e)[:200]
                self.ready.clear()
                time.sleep(10)
            except Exception as e:
                self.status["error"] = f"{type(e).__name__}: {e}"[:200]
                traceback.print_exc()
                time.sleep(5)
            time.sleep(1.0)

    def ensure(self):
        o = self.obs
        if self.kind is None:
            try:
                kinds = o.call("GetSourceFilterKindList").get("sourceFilterKinds") or []
            except OBSError:
                kinds = []
            self.kind = "color_filter_v2" if "color_filter_v2" in kinds or not kinds else "color_filter"
        for name in self.cfg["inputs"]:
            if name in self.ready:
                continue
            try:
                filters = [f["filterName"] for f in o.call("GetSourceFilterList", {"sourceName": name})["filters"]]
            except OBSError:
                continue  # no such capture in this scene collection
            if self.cfg["filter"] not in filters:
                o.call("CreateSourceFilter", {"sourceName": name, "filterName": self.cfg["filter"],
                                              "filterKind": self.kind, "filterSettings": settings_for(0.0, self.cfg)})
                self.log(f"[nightlift] added {self.cfg['filter']!r} to {name!r}")
            self.ready.add(name)
        self.status["inputs"] = sorted(self.ready)

    def work(self, now):
        dt, self.t = max(0.0, now - self.t), now
        if len(self.ready) < len(self.cfg["inputs"]):
            self.ensure()
        if self.lift is None:
            self.lift = self.target  # start where it should be (a restart at night does not fade in from day)
        step = self.cfg["ramp"] * max(dt, 1.0)
        self.lift += max(-step, min(step, self.target - self.lift))
        self.status["lift"] = round(self.lift, 3)
        if self.sent is None or abs(self.lift - self.sent) >= self.cfg["step"] or (self.lift == self.target != self.sent):
            values = settings_for(self.lift, self.cfg)
            for name in sorted(self.ready):
                self.obs.call("SetSourceFilterSettings", {"sourceName": name, "filterName": self.cfg["filter"],
                                                          "filterSettings": values, "overlay": True})
            if self.ready:
                self.sent = self.lift
                self.status["sent"] = dict(values, lift=round(self.lift, 3))

    def public(self):
        return dict(self.status)


def main():
    """Try the lift on the box without a game at night: ramp to --darkness, hold, ramp back to day (or --leave)."""
    import argparse, json
    ap = argparse.ArgumentParser(description=main.__doc__)
    ap.add_argument("--darkness", type=float, default=0.85, help="pretend darkness (0 day .. 0.85 midnight)")
    ap.add_argument("--hold", type=float, default=15, help="seconds at that darkness")
    ap.add_argument("--leave", action="store_true", help="leave the lift on (the service resets it on its next poll)")
    ap.add_argument("--obs", default="127.0.0.1:4455")
    a = ap.parse_args()
    host, _, port = a.obs.partition(":")
    o = OBS(host, int(port or 4455))
    live = {r: o.call(r).get("outputActive") for r in ("GetStreamStatus", "GetRecordStatus")}
    print("outputs:", live, flush=True)
    n = NightLift(obs=o, start=False, ramp=0.25)  # a quicker ramp for the demo
    n.set_darkness(a.darkness)
    t0 = time.time()
    while time.time() - t0 < 6 + a.hold:
        n.work(time.time())
        time.sleep(1)
    print("at darkness", a.darkness, json.dumps(n.status["sent"]), flush=True)
    if not a.leave:
        n.set_darkness(0.0)
        for _ in range(8):
            n.work(time.time())
            time.sleep(1)
        print("back to day", json.dumps(n.status["sent"]), flush=True)


if __name__ == "__main__":
    main()
