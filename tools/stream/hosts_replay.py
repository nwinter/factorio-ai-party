#!/usr/bin/env python3
"""(d23 batch130) Replays a day's caster and analyst logs through the hosts' gates: the beat mix before and after the
ArrivalGate (hoststory.py, CM1), every chronicle arrival through the same gate, and the analyst beats (CM2) that
would have aired at one per ANALYST_EVERY seconds.

  python3 tools/stream/hosts_replay.py [--day 20261023] [--logs tools/stream/logs] [--runs runs]

Read only. The logs carry an arrival's platform, planets and game time but not its leg or cargo: those come from the
shift's chronicle (runs/shiftNN/chronicle.jsonl), the leg from the platform_left before the platform_arrived, the
cargo from the rockets sent to the platform at the planet it left (what model.py reads from the hub is not logged).
The goals are the story memo's (cut at 260 characters) as the beat saw them.
"""
import argparse, glob, json, os, re, sys
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import caster, hoststory  # noqa: E402

GAME_TIME = re.compile(r"(\d+)h(\d+)m")
STACK = re.compile(r"([a-z0-9][\w-]*)(?:@[\w-]+)?\*(\d+)")


def game_min(text):
    m = GAME_TIME.search(str(text or ""))
    return int(m[1]) * 60 + int(m[2]) if m else None


def exchanges(path):
    """[(t, kind, facts)] one per exchange (its first line carries the facts)."""
    out, seen = [], {}
    for line in open(path):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if r.get("type") != "caster" or r.get("exchange") is None:
            continue
        key = (r["exchange"], r.get("event"))
        if key in seen:
            if r.get("facts") and not out[seen[key]][2]:
                out[seen[key]] = (out[seen[key]][0], out[seen[key]][1], r["facts"])
            continue
        seen[key] = len(out)
        out.append((float(r["exchange"]), r.get("event"), r.get("facts") or {}))
    return out


class Chronicle:
    """A shift's platform legs and rockets, for an arrival's leg minutes and science or egg cargo."""

    def __init__(self, path):
        self.arrived, self.left, self.rockets = defaultdict(list), defaultdict(list), defaultdict(list)
        try:
            rows = [json.loads(x) for x in open(path)]
        except (OSError, ValueError):
            rows = []
        for r in rows:
            k = r.get("kind")
            if k == "platform_arrived":
                self.arrived[r["platform"]].append(r)
            elif k == "platform_left":
                self.left[r["platform"]].append(r)
            elif k == "rocket" and str(r.get("to") or "").startswith("platform "):
                self.rockets[r["to"][9:]].append(r)

    def arrivals(self):
        return sorted((r for rs in self.arrived.values() for r in rs), key=lambda r: r["tick"])

    def leg(self, name, tick):
        """(left row, leg minutes) for the platform's arrival at tick."""
        before = [r for r in self.left[name] if r["tick"] < tick]
        if not before:
            return None, None
        r = max(before, key=lambda r: r["tick"])
        return r, round((tick - r["tick"]) / 3600)

    def cargo(self, name, left):
        """Science and eggs sent up to the platform while it stopped at the planet it left."""
        if not left:
            return None
        stops = [r["tick"] for r in self.arrived[name] if r["tick"] < left["tick"] and r.get("at") == left.get("at")]
        start = max(stops) if stops else left["tick"] - 3600 * 30
        got = Counter()
        for r in self.rockets[name]:
            if start <= r["tick"] <= left["tick"]:
                for n, c in STACK.findall(str(r.get("cargo") or "")):
                    if re.search(r"science-pack$|egg$", n):
                        got[n] += int(c)
        return ", ".join(f"{c} {n.replace('-', ' ')}" for n, c in got.most_common()) or None

    def find(self, name, planet, minute):
        """The platform_arrived row for a logged arrival (same platform and planet, within 3 game minutes)."""
        best = None
        for r in self.arrived.get(name) or []:
            if str(r.get("at")) != str(planet).lower():
                continue
            d = abs(game_min(r.get("game_time")) - minute) if minute is not None else 0
            if d <= 3 and (best is None or d < best[0]):
                best = (d, r)
        return best[1] if best else None


def been_before(chrons, runs, num, platform, planet):
    """The platform stopped at the planet in an earlier shift's chronicle."""
    if not (num and platform and planet):
        return False
    for n in range(int(num) - 1, max(0, int(num) - 4), -1):
        ch = chrons.setdefault(str(n), Chronicle(os.path.join(runs, f"shift{n}", "chronicle.jsonl")))
        if any(str(r.get("at")) == str(planet).lower().replace(" ", "-") for r in ch.arrived.get(platform) or []):
            return True
    return False


def arrival_facts(kind, facts, chron):
    f = dict((facts.get("arrival") if kind == "arrival" else facts.get("headline")) or {})
    if kind == "arrival" and f.get("platform") and chron:
        row = chron.find(f["platform"], f.get("planet"), game_min(f.get("game_time") or facts.get("game_time")))
        if row:
            left, mins = chron.leg(f["platform"], row["tick"])
            f["leg_minutes"] = mins
            f["carrying"] = chron.cargo(f["platform"], left)
    return f


def rules(why):
    out = []
    for part in (why or "").split("; "):
        out.append("first route" if part.startswith("the first platform") else "cargo" if part.startswith("it brings")
                   else "goals" if part.startswith("the team's goals") else "long leg" if part.startswith("it ends")
                   else part)
    return out


def analyst_points(paths):
    """[(t, id, priority, ttl, text)] from the analyst's cycle logs (each cycle's talking points)."""
    out = []
    for path in paths:
        for line in open(path):
            try:
                reply = json.loads(line).get("reply") or {}
            except ValueError:
                continue
            t = reply.get("t")
            for i, p in enumerate(reply.get("talking_points") or []):
                if t and isinstance(p, dict):
                    out.append((float(t), f"{t}:{i}", int(p.get("priority") or 2), float(p.get("ttl_s") or 400),
                                p.get("topic"), p.get("text")))
    return sorted(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--day", default="20261023")
    ap.add_argument("--logs", default=os.path.join(HERE, "logs"))
    ap.add_argument("--runs", default=os.path.join(HERE, "..", "..", "runs"))
    a = ap.parse_args()
    logs = sorted(glob.glob(os.path.join(a.logs, f"caster-{a.day}-*.jsonl")))
    if not logs:
        print(f"no caster logs for {a.day} in {a.logs}")
        return
    gates, chrons = {}, {}
    before, after, why_n = Counter(), Counter(), Counter()
    slots = []  # (t, kind kept or None for a freed slot)
    per_shift = defaultdict(lambda: [Counter(), Counter()])
    repeats, firsts = Counter(), Counter()
    for path in logs:
        prev_t = None
        for t, kind, facts in exchanges(path):
            shift = (facts.get("shift") or {}).get("this_shift") or "?"
            num = re.sub(r"\D", "", shift)
            if num and num not in chrons:
                chrons[num] = Chronicle(os.path.join(a.runs, f"shift{num}", "chronicle.jsonl"))
            gate = gates.setdefault(shift, hoststory.ArrivalGate(None))
            before[kind] += 1
            per_shift[shift][0][kind] += 1
            if kind == "space":
                firsts[(facts.get("headline") or {}).get("headline")] += 1
            keep = True
            hd = facts.get("headline") or {}
            if kind == "space" and hd.get("headline") in ("orbit", "platform_arrival") and \
                    been_before(chrons, a.runs, num, hd.get("platform"), hd.get("planet")):
                # model.py now reads where each platform has been from earlier shifts: a repeat is an arrival
                kind = "arrival"
                facts = dict(facts, arrival=hd, game_time=hd.get("game_time") or facts.get("game_time"))
                repeats[shift] += 1
            if kind in ("arrival", "space") and facts:
                e = {"kind": kind, "text": facts.get("text") or facts.get("what_happened"),
                     "facts": arrival_facts(kind, facts, chrons.get(num))}
                s = {"board": {"plan": {"goals": (facts.get("story") or {}).get("goals")}}}
                out = gate.admit(e, s, t)
                keep = bool(out)
                if out and kind == "arrival":
                    why_n.update(rules(out[0].get("why_it_matters")))
            if keep:
                after[kind] += 1
                per_shift[shift][1][kind] += 1
            if prev_t is not None and t - prev_t > 150:
                slots.append((prev_t + 90, None))  # a quiet stretch: the caster would have spoken a filler here
            slots.append((t, kind if keep else None))
            prev_t = t

    def mix(c):
        n = sum(c.values()) or 1
        return ", ".join(f"{k} {v} ({100 * v // n}%)" for k, v in c.most_common(10))

    print(f"caster logs {a.day}: {len(logs)} files")
    print(f"before: {sum(before.values())} exchanges: {mix(before)}")
    print(f"after:  {sum(after.values())} exchanges: {mix(after)}")
    print(f"space beats by headline: " + ", ".join(f"{k} {v}" for k, v in firsts.most_common())
          + f"; repeats of an earlier shift's visit, now arrivals: {sum(repeats.values())}")
    print(f"logged arrivals kept {after['arrival']} of {before['arrival']}; reasons (an arrival may have several): "
          + ", ".join(f"{k} {v}" for k, v in why_n.most_common()))
    for shift, (b, x) in sorted(per_shift.items()):
        print(f"  {shift}: arrivals {b['arrival']} -> {x['arrival']}, all beats {sum(b.values())} -> {sum(x.values())}")

    # every arrival in the chronicles, through a fresh gate per shift (goals: none known here)
    for num, chron in sorted(chrons.items()):
        g, n, kept, reasons = hoststory.ArrivalGate(None), 0, 0, Counter()
        for r in chron.arrivals():
            left, mins = chron.leg(r["platform"], r["tick"])
            if not left:
                continue
            n += 1
            f = {"platform": r["platform"], "planet": caster.planet_label(r["at"]),
                 "came_from": caster.planet_label(left.get("at")), "leg_minutes": mins,
                 "carrying": chron.cargo(r["platform"], left)}
            out = g.admit({"kind": "arrival", "text": "", "facts": f}, {}, 0)
            if out:
                kept += 1
                reasons.update(rules(out[0]["why_it_matters"]))
        print(f"chronicle shift{num}: {kept} of {n} arrivals would speak; " + ", ".join(f"{k} {v}" for k, v in reasons.most_common()))

    # CM2: analyst points as beats at priority 5, one per ANALYST_EVERY seconds
    an = analyst_points(sorted(glob.glob(os.path.join(a.logs, f"analyst-{a.day}-*.jsonl"))))
    if an:
        aired_t, last, aired, topics = {}, -1e9, 0, Counter()
        for t, kind in sorted(slots):
            if kind is not None and caster.PRIORITY.get(kind, 2) >= caster.PRIORITY["analyst"]:
                continue
            if t - last < caster.ANALYST_EVERY:
                continue
            fresh = [p for p in an if p[0] <= t < p[0] + p[3] and p[2] >= caster.ANALYST_MIN_PRIORITY
                     and t - aired_t.get(p[4], -1e9) >= caster.ANALYST_TOPIC_GAP]
            if not fresh:
                continue
            p = max(fresh, key=lambda p: (p[2], p[0]))
            aired_t[p[4]] = t
            last, aired = t, aired + 1
            topics[p[2]] += 1
        print(f"analyst: {len(an)} points logged; {aired} analyst beats would have aired (by priority: "
              + ", ".join(f"p{k} {v}" for k, v in sorted(topics.items())) + ")")


if __name__ == "__main__":
    main()
