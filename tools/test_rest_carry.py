#!/usr/bin/env python3
"""A rest kept across the shift change (d24 batch172, viewer Aurora 16:05: Muse's rest until Sun 17:00, marked by hand
in shift69, was gone in shift70 because ai-usage read Muse's account stale; idle_nudge then nudged it every 20 min):
python3 tools/test_rest_carry.py

tools/quota_rest.py --at-limit RUN TEAM --carry PREV, across providers (claude, codex, grok, agy, muse):
1. carried: each agent's unexpired rest of the previous run (quota by hand, quota by --at-limit, pace) is written in
   the new run until the same time, with no reading, a stale one, or no brief at all; the start log says so;
2. not carried: a rest that ended at the change (until behind), one the agent ended with a request of its own;
3. a fresh reading with room ends a quota rest (the line says so); a pace rest is carried anyway; an account at its
   limit rests until the later of its reset and the carried rest;
4. the resume: while carried the card reads resting and idle_nudge sends nothing; when the rest ends the card reads
   active, the agent is nudged once (not again within 20 min), and its first request of its own ends a rest early;
5. start-team passes --carry with the previous run's directory, in the plan and the run.
No RCON, no live quota data: POG_REST_PUSH=off, the briefs are fixtures.
"""
import datetime
import json
import os
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.join(ROOT, "tools", "stream"))
os.environ["POG_REST_PUSH"] = "off"
import quota_rest  # noqa: E402
import pacing  # noqa: E402
import idle_nudge  # noqa: E402
from model import Model  # noqa: E402

TEAM = ("# name\tkind\troute\tmodel\n"
        "opus\tclaude\tclaude-b\topus\n"
        "astra\tcodex\tcodex\tgpt-6-astra\n"
        "grok\tgrok\t-\tgrok-4.7\n"
        "gemini\tagy\t-\tgemini-3.8-flash-high\n"
        "muse\tmuse\t-\tmuse-spark-1.3\n")
NAMES = ["opus", "astra", "grok", "gemini", "muse"]
PROFILES = {"opus": ("claude_account_b", "claude-b", ["5-hour session", "Weekly"]),
            "astra": ("codex_account_a", "codex", ["Codex · Weekly"]),
            "grok": ("grok_personal", "grok", ["Grok · Weekly"]),
            "gemini": ("agy_local", "agy", ["Gemini · 5-hour", "Gemini · Weekly"]),
            "muse": ("muse_local", "muse", ["Muse · 5-hour", "Muse · Weekly"])}


def brief(now, pct=None, stale=(), age=60, reset=86400):
    """A quota brief made `age` s ago: each profile's windows at pct[name] (default 40), stale ones marked."""
    pct = pct or {}
    out = []
    for name, (pid, cmd, labels) in PROFILES.items():
        out.append({"id": pid, "command": cmd, "stale": name in stale, "available": name not in stale,
                    "windows": [{"label": lb, "percent": pct.get(name, 40), "resets_at": now + reset} for lb in labels]})
    return {"generated_at": now - age, "profiles": out}


def rest(d, since, until, reason="quota"):
    os.makedirs(d, exist_ok=True)
    json.dump({"since": since, "until": until, "reason": reason, "sleep_s": int(until - since)},
              open(os.path.join(d, "resting.json"), "w"))


def request(d, at, action="status"):
    stamp = datetime.datetime.fromtimestamp(at, datetime.timezone.utc).isoformat().replace("+00:00", "Z")
    with open(os.path.join(d, "journal.jsonl"), "a") as f:
        f.write(json.dumps({"at": stamp, "event": "request", "request": {"action": action, "args": {}}},
                           separators=(",", ":")) + "\n")   # compact, as the journals are
    os.utime(os.path.join(d, "journal.jsonl"), (at, at))   # written at that time (pacing reads no older file)


def setup(root, now):
    prev, new = os.path.join(root, "shift69"), os.path.join(root, "shift70")
    for n in NAMES:
        os.makedirs(os.path.join(new, n))
    team = os.path.join(root, "team.tsv")
    open(team, "w").write(TEAM)
    return prev, new, team


def carry(new, team, prev, b, now, root):
    path = None
    if b is not None:
        path = os.path.join(root, "brief.json")
        json.dump(b, open(path, "w"))
    else:
        path = os.path.join(root, "no-brief.json")
    lines, ok = quota_rest.at_limit(new, team, path, now, False, prev)
    return lines, ok


def written(new, name):
    try:
        return json.load(open(os.path.join(new, name, "resting.json")))
    except OSError:
        return None


def carried():
    """1-3: what is carried, per provider."""
    now = time.time()
    sun = now + 27 * 3600
    with tempfile.TemporaryDirectory() as root:
        prev, new, team = setup(root, now)
        # every provider rests through the change; ai-usage reads all of them stale
        for i, n in enumerate(NAMES):
            rest(os.path.join(prev, n), now - 3600 * (i + 1), sun - 60 * i)
        lines, ok = carry(new, team, prev, brief(now, stale=NAMES), now, root)
        assert ok, lines
        for i, n in enumerate(NAMES):
            r = written(new, n)
            assert r and r["until"] == round(sun - 60 * i) and r["reason"] == "quota" and r["carried_from"] == "shift69", (n, r)
            assert pacing.resting(os.path.join(new, n), now + 60), n
        muse = [x for x in lines if x.startswith("quota rest: muse:")]
        assert len(muse) == 1 and "carried from shift69" in muse[0] and "no fresh reading of its account" in muse[0], lines
        assert lines[0].startswith("quota rests: no agent's account at its limit"), lines
    with tempfile.TemporaryDirectory() as root:
        prev, new, team = setup(root, now)
        for n in NAMES:
            rest(os.path.join(prev, n), now - 7200, sun)
        # no quota data at all: every rest carried
        lines, ok = carry(new, team, prev, None, now, root)
        assert all(written(new, n) for n in NAMES), lines
        assert lines[0].startswith("quota rests: none (no quota data saved in"), lines
    with tempfile.TemporaryDirectory() as root:
        prev, new, team = setup(root, now)
        rest(os.path.join(prev, "opus"), now - 7200, now - 5)            # ended at the change
        rest(os.path.join(prev, "astra"), now - 7200, sun)               # ended by a request of its own
        request(os.path.join(prev, "astra"), now - 600)
        rest(os.path.join(prev, "grok"), now - 7200, sun)                # a fresh reading with room: ended
        rest(os.path.join(prev, "gemini"), now - 600, now + 1200, "pace")  # a pace rest, with room: carried
        rest(os.path.join(prev, "muse"), now - 7200, now + 3600)         # at its limit, reset later than the rest
        lines, ok = carry(new, team, prev, brief(now, pct={"muse": 100}, reset=86400), now, root)
        assert written(new, "opus") is None and written(new, "astra") is None, lines
        assert written(new, "grok") is None
        g = [x for x in lines if x.startswith("quota rest: grok:")]
        assert g == ["quota rest: grok: shift69's rest until " + quota_rest.when(sun) + " (quota) not carried: a fresh "
                     "reading has room (Grok · Weekly 40%)"], lines
        gem = written(new, "gemini")
        assert gem and gem["reason"] == "pace" and gem["until"] == round(now + 1200) and gem["carried_from"] == "shift69", gem
        m = written(new, "muse")
        assert m and m["until"] == round(now + 86400) and "carried_from" not in m, m   # its reset, later
        # a stale reading never ends a rest; an old brief (over 30 min) is no fresh reading
    with tempfile.TemporaryDirectory() as root:
        prev, new, team = setup(root, now)
        rest(os.path.join(prev, "muse"), now - 7200, sun)
        rest(os.path.join(prev, "grok"), now - 7200, sun)
        lines, ok = carry(new, team, prev, brief(now, stale=["muse"], age=2400), now, root)
        assert written(new, "muse") and written(new, "grok"), lines
        # an account at its limit whose reset comes before the carried rest ends: the carried rest
        rest(os.path.join(prev, "grok"), now - 7200, sun)
        lines, ok = carry(new, team, prev, brief(now, pct={"grok": 100}, reset=3600), now, root)
        g = written(new, "grok")
        assert g["until"] == round(sun) and g["carried_from"] == "shift69", g
        assert any("resets sooner" in x for x in lines if x.startswith("quota rest: grok:")), lines
    # the CLI: --carry with a run name or path, a dry run writes nothing
    with tempfile.TemporaryDirectory() as root:
        prev, new, team = setup(root, now)
        rest(os.path.join(prev, "muse"), now - 7200, sun)
        import subprocess
        r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "quota_rest.py"), "--at-limit", new, team,
                            "--carry", prev, "--brief", os.path.join(root, "none.json"), "--dry-run"],
                           capture_output=True, text=True, timeout=60)
        assert r.returncode == 0 and "quota rest: muse would rest until" in r.stdout and "carried from shift69" in r.stdout, r
        assert written(new, "muse") is None
        r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "quota_rest.py"), "--at-limit", new, team,
                            "--carry", os.path.join(root, "nothere"), "--brief", os.path.join(root, "none.json")],
                           capture_output=True, text=True, timeout=60)
        assert "no previous run" in r.stdout, r.stdout
    print("carried: ok (every provider; ended, own request, fresh room, pace, limit, CLI)")


def resume():
    """4: the card and the idle nudge while carried, and when the rest ends."""
    now = time.time()
    with tempfile.TemporaryDirectory() as root:
        prev, new, team = setup(root, now)
        for n in NAMES:
            rest(os.path.join(prev, n), now - 7200, now + 1800)
        carry(new, team, prev, brief(now, stale=NAMES), now, root)
        for n in NAMES:
            d = os.path.join(new, n)
            nudger = idle_nudge.Nudger(members=[n], start=now - 3600, run_dir=new)
            row = {"name": n, "alive": True, "standing_s": 3000, "counted": {"text": "last 10 min: nothing"}}
            sent = []
            send = lambda to, text: sent.append((to, text)) or {"seq": len(sent)}  # noqa: E731
            # while carried: no nudge, the card says out of quota
            for t in range(0, 1800, 60):
                nudger.step({"agents": [dict(row, standing_s=3000 + t)]}, now + t, send, lambda e: None)
            assert sent == [], (n, sent)
            m = Model({"agents": {n: {"display_name": n.title()}}})
            r = pacing.resting(d, now + 60)
            m.ingest({"agents": [{"name": n, "alive": True, "position": {"x": 0, "y": 0}, "resting": r}]}, now=now + 60)
            card = next(a for a in m.snapshot(now + 60)["agents"] if a["name"] == n)
            assert card["activity"] == "resting" and card["action"].startswith("out of quota until"), card
            # the rest ends: nudged once, then not within 20 min
            for t in range(1800, 1800 + 19 * 60, 60):
                nudger.step({"agents": [dict(row, standing_s=3000 + t)]}, now + t + 1, send, lambda e: None)
            assert len(sent) == 1 and sent[0][0] == n, (n, sent)
            # it plays again: its first request of its own; the card reads active
            later = now + 1800 + 120
            request(d, later)
            m.ingest({"agents": [{"name": n, "alive": True, "position": {"x": 0, "y": 0}, "active": "walk",
                                  "resting": pacing.resting(d, later)}]}, now=later)
            card = next(a for a in m.snapshot(later)["agents"] if a["name"] == n)
            assert card["activity"] == "acting" and card["resting_until"] is None, card
        # a request of its own ends a carried rest before its time
        d = os.path.join(new, "muse")
        rest(os.path.join(prev, "muse"), now - 7200, now + 86400)
        os.remove(os.path.join(d, "resting.json"))
        os.remove(os.path.join(d, "journal.jsonl"))   # (the made-up request above lies after this rest's start)
        carry(new, team, prev, brief(now, stale=NAMES), now, root)
        since = written(new, "muse")["since"]   # written now (the clock's time, as aq.rest does)
        assert pacing.resting(d, since + 10)
        request(d, since + 20)
        assert pacing.resting(d, since + 30) is None
    print("resume: ok (no nudge while carried, one when it ends, card active, own request ends it)")


def start_team():
    """5: start-team hands the previous run to --at-limit in the plan and the run."""
    src = open(os.path.join(ROOT, "tools", "start-team.sh")).read()
    assert src.count('rest_carry=(); [ -n "${carry_from:-}" ] && rest_carry=(--carry "$carry_from")') == 2, "both steps"
    assert src.count('${rest_carry[@]+"${rest_carry[@]}"}') == 2
    assert src.index("carry_from=$prev_dir") < src.index("rest_carry=()")
    print("start-team: ok (--carry in the plan and the run)")


if __name__ == "__main__":
    carried()
    resume()
    start_team()
    print("test_rest_carry: ok")
