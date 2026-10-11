#!/usr/bin/env python3
"""A past run as a pace baseline for the casters ("two technologies ahead of shake1 at this game time").

  python3 tools/stream/baseline.py ~/code/player-of-games/runs/shake1 [--name shake1]   # -> baselines/shake1.json

Reads the run's scores.jsonl (one score every ~2 minutes: tick, research_done, produced) and keeps, per sample, the
technology count and a few production totals, plus the first sample tick at which each technology was done.
"""
import argparse, json, os

HERE = os.path.dirname(os.path.abspath(__file__))
ITEMS = ("iron-plate", "copper-plate", "electronic-circuit", "automation-science-pack", "logistic-science-pack")


def build(run_dir, name):
    samples, first = [], {}
    for line in open(os.path.join(run_dir, "scores.jsonl")):
        if not line.strip():
            continue
        sc = json.loads(line).get("score") or {}
        tick = sc.get("tick")
        if tick is None:
            continue
        done = sc.get("research_done") or []
        for tech in done:
            first.setdefault(tech, tick)
        samples.append({"tick": tick, "techs": len(done),
                        "produced": {k: v for k, v in (sc.get("produced") or {}).items() if k in ITEMS}})
    samples.sort(key=lambda x: x["tick"])
    return {"name": name, "source": os.path.basename(os.path.normpath(run_dir)), "samples": samples,
            "first_done": dict(sorted(first.items(), key=lambda kv: kv[1]))}


class Baseline:
    """Pace facts against a stored run. Ticks are game ticks (60 a second)."""

    def __init__(self, path):
        d = json.load(open(path))
        self.name, self.samples, self.first = d["name"], d["samples"], d["first_done"]

    def at(self, tick):
        last = None
        for s in self.samples:
            if s["tick"] > tick:
                break
            last = s
        return last

    def minutes(self, tech):
        t = self.first.get(tech)
        return round(t / 3600) if t is not None else None

    def pace(self, tick, techs_now, produced_now=None, done_names=()):
        """Facts comparing now with the baseline at the same game time (None before its first sample)."""
        then = self.at(tick)
        if not then:
            return None
        f = {"compared_with": f"{self.name}, the team's previous run on the same map",
             "technologies_now": techs_now, f"{self.name}_technologies_at_same_time": then["techs"]}
        lead = techs_now - then["techs"]
        tech = lambda k: f"{k} technolog{'y' if k == 1 else 'ies'}"
        f["verdict"] = (f"{tech(lead)} ahead of {self.name} at the same game time" if lead > 0 else
                        f"{tech(-lead)} behind {self.name} at the same game time" if lead < 0 else
                        f"level with {self.name} at the same game time")
        for item in ("iron-plate", "electronic-circuit"):
            if produced_now and produced_now.get(item) and then["produced"].get(item):
                now_n, then_n = int(produced_now[item]), int(then["produced"][item])
                label = item.replace("-", " ") + "s"
                f[f"{label}_made_now"] = now_n
                f[f"{label}_made_by_{self.name}_at_same_time"] = then_n
                # the writers like to quote the gap; give it to them rather than let them do arithmetic
                f[f"{label}_gap"] = (f"{now_n - then_n} more than {self.name}" if now_n >= then_n
                                     else f"{then_n - now_n} fewer than {self.name}")
        nxt = [(t, k) for k, t in self.first.items() if t > tick and k not in done_names]
        if nxt:
            t, k = min(nxt)
            f[f"{self.name}_next_research"] = f"{k.replace('-', ' ')} at {round(t / 3600)} minutes"
        return f


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir")
    ap.add_argument("--name")
    a = ap.parse_args()
    name = a.name or os.path.basename(os.path.normpath(a.run_dir))
    out = os.path.join(HERE, "baselines", f"{name}.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    d = build(a.run_dir, name)
    json.dump(d, open(out, "w"), indent=1)
    print(out, len(d["samples"]), "samples,", len(d["first_done"]), "technologies")
