#!/usr/bin/env python3
"""The run's target (d27 batch277 RT): python3 tools/test_run_target.py

1. run_target.line: the line fh's status shows (factorio-harness host/target.ts writes the same), the time left at
   each read, passed, hard, no note; set/show/clear on a run folder; a time that does not parse is refused.
2. carry: PREV's target to NEXT at a shift change unless NEXT has its own; start-team calls it on a resume.
3. caster.facts_for: run_target on an opening, a segment and a paced beat, not on an attack.
"""
import io, json, os, sys, tempfile
from contextlib import redirect_stdout, redirect_stderr

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "stream"))
import run_target as R  # noqa: E402

AT = 1793429940.0  # 2026-10-30 23:59 PDT
LINE = "Target (Nick, soft): the Shattered Planet by Fri Oct 30 23:59 PDT, 81 h 30 m from now; the run's end is not fixed."


def cli(*argv):
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        code = R.main(list(argv))
    return code, out.getvalue().strip(), err.getvalue().strip()


def lines():
    assert R.epoch("2026-10-30 23:59 PDT") == AT, R.epoch("2026-10-30 23:59 PDT")
    assert R.epoch("2026-10-31T06:59:00Z") == AT and R.epoch("Friday night") is None
    t = {"goal": "the Shattered Planet", "at": "2026-10-30 23:59 PDT", "by": "Nick", "kind": "soft", "note": R.SOFT_NOTE}
    assert R.line(t, AT - (81 * 60 + 30) * 60) == LINE, R.line(t, AT - (81 * 60 + 30) * 60)
    assert R.line(t, AT - 45 * 60).endswith(", 45 m from now; the run's end is not fixed.")
    assert R.line(dict(t, kind="hard", note=None, by=None), AT + 130 * 60) == \
        "Target (hard): the Shattered Planet by Fri Oct 30 23:59 PDT, passed 2 h 10 m ago."
    d = tempfile.mkdtemp()
    run = os.path.join(d, "shift87")
    os.makedirs(run)
    assert cli("show", run)[1] == "no target set"
    code, _, err = cli("set", run, "--goal", "the Shattered Planet", "--at", "Friday night")
    assert code == 2 and "YYYY-MM-DD HH:MM ZONE" in err and not os.path.exists(os.path.join(run, R.NAME))
    code, out, _ = cli("set", run, "--goal", "the Shattered Planet", "--at", "2026-10-30 23:59 PDT", "--by", "Nick")
    assert code == 0 and out.startswith("Target (Nick, soft): the Shattered Planet by Fri Oct 30 23:59 PDT, "), out
    assert json.load(open(os.path.join(run, R.NAME))) == {"goal": "the Shattered Planet", "at": "2026-10-30 23:59 PDT",
                                                         "by": "Nick", "kind": "soft", "note": R.SOFT_NOTE}
    f = R.fact(run, AT - 3 * 3600)
    assert f == {"goal": "the Shattered Planet", "set_by": "Nick", "kind": "soft", "when": "Fri Oct 30 23:59 PDT",
                 "hours_left": 3.0, "note": R.SOFT_NOTE}, f
    assert R.fact(run, AT + 1800)["hours_past"] == 0.5
    print("1. the target line and fact, set and show: ok")
    return d, run


def carrying(d, run):
    nxt = os.path.join(d, "shift88")
    os.makedirs(nxt)
    assert R.carry(run, nxt) and R.read(nxt) == R.read(run)
    own = os.path.join(d, "shift89")
    os.makedirs(own)
    json.dump({"goal": "Aquilo", "at": "2026-10-29 12:00 PDT"}, open(os.path.join(own, R.NAME), "w"))
    assert not R.carry(run, own) and R.read(own)["goal"] == "Aquilo", "its own target stands"
    assert cli("clear", nxt)[0] == 0 and R.read(nxt) is None
    later = os.path.join(d, "shift90")
    os.makedirs(later)
    assert not R.carry(nxt, later) and R.read(later) is None, "cleared: the next shift has none"
    src = open(os.path.join(HERE, "start-team.sh")).read()
    assert 'python3 tools/run_target.py carry "$carry_from" "$rundir"' in src
    print("2. carried to the next shift unless it has its own; cleared stays cleared: ok")


def caster_facts(run):
    import caster
    s = {"agents": [], "game_time": "333h04m"}
    tf = R.fact(run)
    for kind, want in (("open", True), ("segment", True), ("research", True), ("attack", False), ("chat", False)):
        f = caster.facts_for({"kind": kind}, s, target=tf)
        assert ("run_target" in f) == want, (kind, f.get("run_target"))
    assert caster.facts_for({"kind": "open"}, s)["event"] == "open" and "run_target" not in caster.facts_for({"kind": "open"}, s)
    print("3. the casters: run_target on an opening, a segment and a paced beat, not on an attack: ok")


def main():
    d, run = lines()
    carrying(d, run)
    caster_facts(run)
    print("test_run_target: ok")


if __name__ == "__main__":
    main()
