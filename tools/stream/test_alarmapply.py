#!/usr/bin/env python3
"""Alarm gains written, read back and retried (d29 batch335 AQ, viewer Aurora site:5438: "AlarmQuiet.apply catches failed
OBS filter writes but caches the desired mode as applied, so recovery is never retried while that mode stays unchanged.
One source can fail while others work. Please retain failed writes as pending, retry with bounded backoff and expose
desired versus confirmed gain per source. Test failed hold and clear writes, including partial failure, then recovery
without an alarm change or restart. Verify actual filter state."): python3 tools/stream/test_alarmapply.py

A stand-in OBS keeps each filter's real enabled state and can fail a source's writes, accept a write without applying it,
or lack a filter. 1. a hold whose writes fail on one source: the others confirmed, that one pending with its error,
desired vs confirmed per filter, the gain not confirmed; 2. recovery without an alarm change: nothing tried before the
backoff, then written, read back and confirmed; 3. a clear whose writes all fail, then recover; 4. a write OBS accepts
but does not apply: the read-back keeps it pending, retried with a doubling backoff capped at RETRY_MAX_S; 5. a filter
changed by hand: found at the VERIFY_S read and put back; 6. a restart: every filter read and set at the first apply;
7. filters not set up yet: said once, tried again with backoff (not every tick); 8. the service's /state.json carries it
(replays.alarm).
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import alarmquiet as aq  # noqa: E402


class OBS:
    def __init__(self):
        self.state = {(s, f): False for s in aq.SOURCES for f in aq.FILTERS.values()}
        self.fail = set()      # sources whose writes raise
        self.ignore = set()    # sources whose writes are accepted and not applied
        self.missing = set()   # (source, filter) that do not exist
        self.writes, self.reads = [], []

    def call(self, req, data):
        key = (data["sourceName"], data["filterName"])
        if key in self.missing:
            raise RuntimeError("600: No filter was found by that name")
        if req == "SetSourceFilterEnabled":
            self.writes.append((key, data["filterEnabled"]))
            if key[0] in self.fail:
                raise RuntimeError("OBS websocket timeout")
            if key[0] not in self.ignore:
                self.state[key] = data["filterEnabled"]
            return {}
        if req == "GetSourceFilter":
            self.reads.append(key)
            return {"filterEnabled": self.state[key]}
        raise AssertionError(req)


def alarm(want):
    a = aq.AlarmQuiet(None, log=lambda *x: logs.append(" ".join(map(str, x))))
    a.want = want
    return a


logs = []
HOLD = "alarm hold"
BAD = "stream game clean"


def rows(a, now):
    return {(r["source"], r["filter"]): r for r in a.public(now)["filters"]}


def main():
    # 1. a hold, one source failing
    o, a = OBS(), alarm("none")
    a.apply(o.call, now=-5.0)  # every filter read and confirmed off
    assert a.public(-5.0)["confirmed"]
    a.want = "hold"  # an alarm holds; one source's writes fail
    o.fail.add(BAD)
    a.apply(o.call, now=0.0)
    p = a.public(0.0)
    assert not p["confirmed"] and p["pending"] == 1 and a.applied is None, p
    r = rows(a, 0.0)
    for src in aq.SOURCES:
        if src != BAD:
            assert r[(src, HOLD)]["confirmed"] is True and not r[(src, HOLD)]["pending"] and o.state[(src, HOLD)]
    bad = r[(BAD, HOLD)]
    assert bad["desired"] is True and bad["confirmed"] is False and bad["pending"] and bad["attempts"] == 1
    assert "timeout" in bad["error"] and bad["next_try_in"] == aq.RETRY_S
    assert r[(BAD, "alarm cue")]["confirmed"] is False and not r[(BAD, "alarm cue")]["pending"], "its cue filter is as wanted"
    print("1. a hold failing on one source: the others confirmed, that one pending with its error, desired vs confirmed shown: ok")

    # 2. recovery, no alarm change: nothing before the backoff, then written and confirmed
    n = len(o.writes)
    a.apply(o.call, now=1.0)
    assert len(o.writes) == n, "not before its backoff"
    o.fail.clear()
    a.apply(o.call, now=2.5)
    assert o.state[(BAD, HOLD)] is True and a.public(2.5)["confirmed"] and a.applied == "hold"
    assert rows(a, 2.5)[(BAD, HOLD)]["attempts"] == 0 and rows(a, 2.5)[(BAD, HOLD)]["error"] is None
    print("2. recovery without an alarm change or restart: retried after its backoff, read back, confirmed: ok")

    # 3. a clear whose writes all fail, then recover
    a.want = "none"
    o.fail.update(aq.SOURCES)
    a.apply(o.call, now=10.0)
    p = a.public(10.0)
    assert p["pending"] == len(aq.SOURCES) and not p["confirmed"] and all(o.state[(s, HOLD)] for s in aq.SOURCES), p
    o.fail.clear()
    a.apply(o.call, now=11.0)
    assert not a.public(11.0)["confirmed"], "still in its backoff"
    a.apply(o.call, now=12.1)
    assert a.public(12.1)["confirmed"] and not any(o.state.values()), o.state
    print("3. a clear failing on every source, then recovering: pending until confirmed, every filter off: ok")

    # 4. a write accepted but not applied: the read-back keeps it pending; backoff doubles, capped
    a.want = "hold"
    o.ignore.add(BAD)
    t, waits = 20.0, []
    for _ in range(12):
        a.apply(o.call, now=t)
        f = a.filters[(BAD, HOLD)]
        waits.append(f["next_try"] - t)
        t = f["next_try"]
    assert waits[:4] == [2.0, 4.0, 8.0, 16.0] and max(waits) == aq.RETRY_MAX_S, waits
    assert "reads it disabled after the write" in a.filters[(BAD, HOLD)]["error"]
    o.ignore.clear()
    a.apply(o.call, now=t)
    assert a.public(t)["confirmed"]
    print(f"4. a write OBS did not apply: pending on its read-back, retried after {waits[:5]}... s (at most {aq.RETRY_MAX_S:g}): ok")

    # 5. changed by hand: found at the next VERIFY_S read and put back
    o.state[("stream game audio", HOLD)] = False
    a.apply(o.call, now=t + 1)
    assert not o.state[("stream game audio", HOLD)], "not before VERIFY_S"
    a.apply(o.call, now=t + aq.VERIFY_S + 1)
    assert o.state[("stream game audio", HOLD)] and a.public(t + aq.VERIFY_S + 1)["confirmed"]
    print("5. a filter changed by hand: read again every VERIFY_S, put back: ok")

    # 6. a restart: a new instance reads and sets every filter at its first apply
    b = alarm("hold")
    o.state = {k: (not v) for k, v in o.state.items()}  # whatever OBS was left in
    b.apply(o.call, now=0.0)
    assert b.public(0.0)["confirmed"] and all(o.state[(s, HOLD)] and not o.state[(s, "alarm cue")] for s in aq.SOURCES)
    print("6. a restart: every filter set and read back at the first apply: ok")

    # 7. filters not set up: said once, retried with backoff
    o2, c = OBS(), alarm("hold")
    o2.missing = set(o2.state)
    logs.clear()
    for k in range(20):
        c.apply(o2.call, now=k * 0.5)
    assert len([l for l in logs if "no alarm gains in OBS yet" in l]) == 1, logs
    assert c.public(10.0)["pending"] == len(o2.state) and not any(o2.state.values())
    assert all(f["attempts"] == 3 for f in c.filters.values()), [f["attempts"] for f in c.filters.values()]  # 0, 2, 6 s
    print("7. filters not set up yet: said once, tried with backoff, nothing changed: ok")

    # 8. the service's /state.json: replays.alarm
    import replays as rp
    from segments import Segments
    from test_replayaudio import OBS as RO
    rpl = rp.Replays(Segments(spacing=0), obs=RO(), log=lambda *x: None, start=False, alarm=a)
    pub = rpl.public()["alarm"]
    assert pub["gain"] == "hold" and len(pub["filters"]) == len(aq.SOURCES) * 2
    assert {"source", "filter", "desired", "confirmed", "pending", "attempts", "next_try_in", "error", "checked_ago"} <= set(pub["filters"][0])
    print("8. /state.json: replays.alarm with each filter's desired and confirmed state, pending, attempts and last error: ok")
    print("test_alarmapply: all ok")


if __name__ == "__main__":
    main()
