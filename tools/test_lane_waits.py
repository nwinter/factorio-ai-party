#!/usr/bin/env python3
"""The remote and platform lanes' wait conditions, docs against code (d27 batch289, Astra #2634: platform_ready was in
the docs' lane sentence and missing from the lane's check): python3 tools/test_lane_waits.py

1. Every wait_until condition whose own text in agent/ref/waits-queues.md says it runs in the remote or platform lanes
   is one queue_lanes.lua's lane check takes.
2. The lane's refusal message names every condition the check takes (so a refused agent reads the real list).
3. platform_built and platform_ready name their lanes in their own text.
Text only: no game, no Lua.
"""
import os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANES = os.path.join(ROOT, "vendor", "factorio-harness", "mod", "agent-harness_0.1.0", "queue_lanes.lua")
CONDITIONS = os.path.join(ROOT, "vendor", "factorio-harness", "mod", "agent-harness_0.1.0", "conditions.lua")
DOC = os.path.join(ROOT, "agent", "ref", "waits-queues.md")


def names():
    """Every wait_until condition name (conditions.lua NAMES) and platform_damage, platform_hit's other name."""
    src = open(CONDITIONS).read()
    return set(re.search(r"local NAMES='([^']+)'", src).group(1).split("|")) | {"platform_damage"}


def lane_code():
    """(names the lane check takes, the names its refusal message gives)."""
    src = open(LANES).read()
    fn = src[src.index("local WAITS="):src.index("assert(remote_ok(a),")]
    took = set(re.findall(r"\b([a-z_]+)=true", re.search(r"local WAITS=\{([^}]*)\}", fn).group(1)))
    took |= set(re.findall(r"\b([a-z_]+)=true", re.search(r"local SURFACE_WAITS=\{([^}]*)\}", fn).group(1)))
    body = fn[fn.index("local function remote_ok"):]
    took |= set(re.findall(r"c\['until'\]=='([a-z_]+)'", body))
    msg = re.search(r"assert\(remote_ok\(a\),\s*'([^']+)'", src).group(1)
    return took, set(re.findall(r"[a-z_]+", msg)) & names()


def doc_lanes():
    """{condition: its own text} in the wait_until paragraph, and the set of those whose text names a lane."""
    doc = open(DOC).read()
    para = doc[doc.index("- `wait_until {until"):doc.index("- `./fh sleep SECONDS")]
    rx = re.compile(r"`(%s)`" % "|".join(sorted(names(), key=len, reverse=True)))
    marks = [(m.start(), m.group(1)) for m in rx.finditer(para)]
    text = {}
    for i, (at, n) in enumerate(marks):
        end = marks[i + 1][0] if i + 1 < len(marks) else len(para)
        text[n] = text.get(n, "") + para[at:end]
    lane = {n for n, t in text.items() if re.search(r"remote and platform lanes|remote lane|platform lane", t)}
    return text, lane


def main():
    took, said = lane_code()
    text, lane = doc_lanes()
    assert "platform_ready" in took and "platform_built" in took, took
    missing = sorted(lane - took - {"all", "any"})
    assert not missing, f"documented for the lanes but refused there: {missing}"
    print("1. every condition documented for the lanes is taken there: ok")
    unsaid = sorted(took - said)
    assert not unsaid, f"the lane takes them but its refusal message does not say: {unsaid}"
    print("2. the refusal message names every condition the lane takes: ok")
    for n in ("platform_built", "platform_ready"):
        assert n in lane, (n, text.get(n))
    print("3. platform_built and platform_ready name their lanes: ok")
    print("test_lane_waits: ok")


if __name__ == "__main__":
    main()
