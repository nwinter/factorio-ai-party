#!/usr/bin/env python3
"""Shift recovery: an interrupted start, a refused deploy and a failed save leave every agent's notes, tools, rest and
the world's state the same for the next good start: python3 tools/test_shift_recovery.py

d24 batch175 QR2, viewer Aurora 17:02: "Beyond quota rests, could shift recovery tests cover interrupted starts and
failed saves, including each engineer's notes and unread test results?"

What a shift change carries (tools/shift-change.sh -> tools/stop-team.sh PREV, tools/start-team.sh NEXT with
POG_RESUME=PREV):
- in the save (stop_save.py: saves\\PREV.zip and PREV/stopped.json; resume-save.ps1 picks it, resume_guard.py checks its
  tick): the board (tasks, requests, claims, projects and their steps, the plan), reminders and who acknowledged them,
  tells (unread until chat_ack or a tells read), each agent's chat read point (unread until a chat read), watches and
  their results, the blueprint library, rests pushed to the runtime, bots;
- on files, per agent: notes.md (tools/new-run.sh: tools/handover.py carry, with a "## Last shift, measured" section
  from that run's journal), tools/ (tools/full_tools.py carry), resting.json (tools/quota_rest.py --carry); the run's
  team-tools/ (full_tools.py carry); the switches (tools/shift_change.py switches).

Checks (files and stubs only; nothing touches a world):
1. a start that died before it made the agents' workspaces (killed, or a refused deploy: start-team exits after the save
   copy and resumed-from): the next start, resuming that run, gives every agent its notes (with that shift's measured
   section), tools/, team-tools/ and rest from the run before; resume_guard takes that run's last tick (it was unknown,
   and a save 3 game hours back was taken).
2. a start killed while it launched the agents: one workspace made (its notes as carried, the launcher's describe and
   ground_rules in its journal), its tools/ and team-tools/ cut short mid-copy: the next start gives that agent the run
   before's notes (not a copy whose measured section says "no requests") and the whole tools/; the agents it had not
   reached get their notes (they started with empty ones).
3. an agent that played in the start cut short (a request of its own, notes edited) starts from that run's notes.
4. a failed save: stop_save.py --failed writes a stop record with no save (exit 3) and keeps an earlier stop's record
   that saved (exit 0); stop-team.sh with both saves failing leaves the world running (no stop-world) and exits 3, its
   journals still gzipped; shift-change.sh on that exit closes no pane and starts no next shift.
"""
import gzip
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import full_tools  # noqa: E402
import quota_rest  # noqa: E402
import resume_guard  # noqa: E402
import stop_save  # noqa: E402

NAMES = ["luna", "sol", "astra"]
STOP_TICK = 58_450_000
NOW = time.time()
TOOLS = {"luna": ["a.py", "b.py", "plans/c.md"], "sol": ["route.py"], "astra": ["ship.lua"]}


def put(path, text="x\n", mtime=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    if mtime is not None:
        os.utime(path, (mtime, mtime))
    return path


def journal_lines(name, actions, at=NOW - 3600):
    out = []
    for i, a in enumerate(actions):
        t = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(at + 60 * i)) + ".000Z"
        out.append(json.dumps({"at": t, "event": "request", "request": {"id": f"r{i}", "action": a, "bot": name, "args": {}}},
                              separators=(",", ":")))
        out.append(json.dumps({"at": t, "event": "response", "response": {"id": f"r{i}", "ok": True, "tick": 1}},
                              separators=(",", ":")))
    return "\n".join(out) + "\n"


def notes(name, run):
    return (f"(Carried over from the previous shift, run shift69: its notes.md for {name}, as that shift left it.)\n\n"
            "## Last shift, measured (from your journal, replaced each shift)\n- shift69's numbers\n\n"
            f"# Notes ({name}, world n)\n\n## Now\nGoal: {name} goal in {run}\n\n## Open board items\n- #2186 blocked\n")


def root_copy(tmp):
    """A checkout copy with what tools/new-run.sh runs (as tools/test_resume.py's workspace check)."""
    for d in ("tools", "agent", "bin"):
        os.makedirs(os.path.join(tmp, d))
    for f in ("new-run.sh", "brief.py", "full_tools.py", "handover.py"):
        shutil.copy(os.path.join(ROOT, "tools", f), os.path.join(tmp, "tools"))
    for f in os.listdir(os.path.join(ROOT, "agent")):
        if f.endswith(".md"):
            shutil.copy(os.path.join(ROOT, "agent", f), os.path.join(tmp, "agent"))
    shutil.copytree(os.path.join(ROOT, "agent", "ref"), os.path.join(tmp, "agent", "ref"))
    return os.path.join(tmp, "runs")


def shift70(runs):
    """The last shift that played: notes, journals (gzipped by stop-team), tools/, team-tools/, Astra's rest, the stop."""
    prev = os.path.join(runs, "shift70")
    for n in NAMES:
        d = os.path.join(prev, n)
        put(os.path.join(d, "deadline.txt"), "2026-10-24 17:40 PDT\n", NOW - 4 * 3600)
        put(os.path.join(d, "notes.md"), notes(n, "shift70"), NOW - 600)
        with gzip.open(os.path.join(d, "journal.jsonl.gz"), "wt") as f:
            f.write(journal_lines(n, ["describe", "ground_rules", "status", "observe", "build", "say"]))
        for rel in TOOLS[n]:
            put(os.path.join(d, "tools", rel), f"{n} {rel}\n")
    put(os.path.join(prev, "team-tools", "belt.py"), "belt\n")
    put(os.path.join(prev, "team-tools", "shift67-em-blueprint-set.md"), "set\n")
    json.dump({"since": NOW - 3600, "until": NOW + 86400, "reason": "quota", "sleep_s": 600},
              open(os.path.join(prev, "astra", "resting.json"), "w"))
    json.dump({"run": "shift70", "world": "n", "tick": STOP_TICK, "save": "shift70.zip", "via": "game.server_save",
               "stop_utc": "2026-10-25T00:40:00.000Z"}, open(os.path.join(prev, "stopped.json"), "w"))
    put(os.path.join(prev, "scores.jsonl"), json.dumps({"score": {"tick": STOP_TICK - 100}}) + "\n")
    return prev


def cut_short(runs, name="shift71"):
    """A start of shift71 resuming shift70 that died after its run directory was made (start.log, switches, resumed-from:
    start-team writes resumed-from right after the save copy, then deploys)."""
    d = os.path.join(runs, name)
    put(os.path.join(d, "start.log"), "17:40:01 world n: resuming run shift70\n17:40:30 runtime deployed from abc: refused\n")
    put(os.path.join(d, "switches.env"), "POG_SPACE_AGE=1\nPOG_CAMS=1\n")
    put(os.path.join(d, "resumed-from"), "shift70\n")
    return d


def new_run(root, run, resume, name):
    # start-team's POG_RESUME_DIR: the resumed run, or the next one up its resumed-from chain when it has no notes at all
    resume_dir = os.path.join(root, "runs", resume)
    if not any(os.path.isfile(os.path.join(resume_dir, n, "notes.md")) for n in NAMES) \
            and os.path.isfile(os.path.join(resume_dir, "resumed-from")):
        resume_dir = os.path.join(root, "runs", open(os.path.join(resume_dir, "resumed-from")).readline().strip())
    env = {k: v for k, v in os.environ.items() if not k.startswith("POG_")}
    env.update(POG_WS=name, POG_BOT=name, POG_RESUME=resume, POG_RESUME_DIR=resume_dir)
    out = subprocess.run(["bash", os.path.join(root, "tools", "new-run.sh"), run, "n", name, "240"], env=env,
                         capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    return open(os.path.join(out.stdout.strip(), "notes.md")).read()


def files(d):
    return sorted(os.path.relpath(os.path.join(b, f), d) for b, _, fs in os.walk(d) for f in fs)


def next_start(root, runs, cut, want_notes):
    """shift72 resuming the cut-short run: each agent's notes, tools/, team-tools/, rest, and the guard's tick."""
    for n in NAMES:
        text = new_run(root, "shift72", os.path.basename(cut), n)
        src = want_notes.get(n, "shift70")
        assert text.startswith(f"(Carried over from the previous shift, run {src}: its notes.md for {n}"), (n, text[:200])
        assert f"Goal: {n} goal in {src}" in text, (n, text)
        assert text.count(full_tools_measured()) == 1 and "no requests in your journal" not in text, (n, text)
        assert "world actions" in text and "shift69's numbers" not in text, (n, text)
    new = os.path.join(runs, "shift72")
    lines, _ = full_tools.carry(new, cut, NAMES)
    for n in NAMES:
        assert files(os.path.join(new, n, "tools")) == sorted(TOOLS[n]), (n, lines)
    assert files(os.path.join(new, "team-tools")) == ["belt.py", "shift67-em-blueprint-set.md"], lines
    rest = quota_rest.previous(cut, "astra", NOW)
    assert rest and rest["until"] == NOW + 86400, rest
    assert quota_rest.previous(cut, "sol", NOW) is None
    tick, source = resume_guard.previous(cut)
    assert tick == STOP_TICK and "shift70" in source, (tick, source)
    ok, line = resume_guard.check(STOP_TICK - 3 * 216000, tick, source, "_autosave1.zip")
    assert not ok and "went back 3h00m" in line, line
    return lines


def full_tools_measured():
    import handover
    return handover.MEASURED


def before_workspaces():
    tmp = tempfile.mkdtemp(prefix="shiftrecovery")
    try:
        runs = root_copy(tmp)
        shift70(runs)
        cut = cut_short(runs)
        next_start(tmp, runs, cut, {})
    finally:
        shutil.rmtree(tmp)
    print("a start that died before the workspaces (killed, a refused deploy): notes, tools, rests and tick from shift70")


def mid_launch():
    tmp = tempfile.mkdtemp(prefix="shiftrecovery")
    try:
        runs = root_copy(tmp)
        shift70(runs)
        cut = cut_short(runs)
        # Luna's workspace made (its notes carried from shift70), the launcher's describe and ground_rules journaled
        new_run(tmp, "shift71", "shift70", "luna")
        put(os.path.join(cut, "luna", "journal.jsonl"), journal_lines("luna", ["describe", "ground_rules"], NOW - 60))
        put(os.path.join(cut, "luna", "tools", "a.py"), "luna a.py\n")   # the carry cut short
        put(os.path.join(cut, "team-tools", "belt.py"), "belt\n")
        lines = next_start(tmp, runs, cut, {})
        assert any(l.startswith("carry luna tools/: 3 files") and "from shift71, shift70 (shift71: not played there)" in l
                   for l in lines), lines
    finally:
        shutil.rmtree(tmp)
    print("a start killed while launching the agents: every agent's notes and the whole tools/ from shift70")


def played_cut_short():
    tmp = tempfile.mkdtemp(prefix="shiftrecovery")
    try:
        runs = root_copy(tmp)
        shift70(runs)
        cut = cut_short(runs)
        new_run(tmp, "shift71", "shift70", "luna")
        d = os.path.join(cut, "luna")
        put(os.path.join(d, "journal.jsonl"), journal_lines("luna", ["describe", "ground_rules", "status", "build"], NOW - 300))
        text = open(os.path.join(d, "notes.md")).read().replace("goal in shift70", "goal in shift71")
        put(os.path.join(d, "notes.md"), text, NOW - 120)
        os.utime(os.path.join(d, "deadline.txt"), (NOW - 400, NOW - 400))
        for rel in TOOLS["luna"]:
            put(os.path.join(d, "tools", rel), f"luna {rel}\n")
        next_start(tmp, runs, cut, {"luna": "shift71"})
        assert full_tools.played(cut, "luna") and not full_tools.played(cut, "sol")
    finally:
        shutil.rmtree(tmp)
    print("an agent that played in the start cut short: its notes from that run")


STOP_ROOT_STUBS = {
    # pog.py: pause and save fail (RCON down); stop_save.py's own import of it gives no Rcon
    "tools/pog.py": "import sys\nif __name__ == '__main__':\n    sys.exit('ConnectionRefusedError: [Errno 61]')\n",
    "tools/console_audit.py": "",
    "tools/bplibrary.py": "",
    "tools/winps.sh": "#!/usr/bin/env bash\necho \"winps $*\" >> \"$STUB_LOG\"\n",
}


def failed_save():
    tmp = tempfile.mkdtemp(prefix="shiftrecovery")
    try:
        # stop_save.py --failed: a record with no save; an earlier stop's record that saved stands
        rd = os.path.join(tmp, "runs", "shift70")
        rec, kept = stop_save.failed_record(rd, "shift70", "n")
        assert not kept and rec["save"] is None and rec["via"] == "failed" and rec["tick"] is None, rec
        assert resume_guard.own(rd) == (None, None)   # no tick from it: the guard reads the scores
        good = {"run": "shift70", "world": "n", "tick": STOP_TICK, "save": "shift70.zip", "via": "game.server_save"}
        json.dump(good, open(os.path.join(rd, "stopped.json"), "w"))
        assert stop_save.failed_record(rd, "shift70", "n") == (good, True)
        # stop-team.sh with both saves failing, in a checkout copy with stubs for the world
        for rel, body in STOP_ROOT_STUBS.items():
            put(os.path.join(tmp, rel), body)
        os.chmod(os.path.join(tmp, "tools", "winps.sh"), 0o755)
        for f in ("stop-team.sh", "stop_save.py"):
            shutil.copy(os.path.join(ROOT, "tools", f), os.path.join(tmp, "tools"))
        world, log = "zz-recovery-test", os.path.join(tmp, "calls.log")   # no RCON password for it: stop_save fails
        env = {k: v for k, v in os.environ.items() if not k.startswith("POG_")}
        env.update(POG_STOP_WORLD="1", STUB_LOG=log)
        run = "shift71"
        rd = os.path.join(tmp, "runs", run)
        put(os.path.join(rd, "luna", "journal.jsonl"), journal_lines("luna", ["status"]))
        put(os.path.join(rd, "luna", "notes.md"), notes("luna", run))
        open(log, "w").close()
        r = subprocess.run(["bash", os.path.join(tmp, "tools", "stop-team.sh"), run, world], env=env, capture_output=True,
                           text=True, timeout=120)
        assert r.returncode == 3, (r.returncode, r.stdout, r.stderr)
        assert "NOT saved (save FAILED; the world is left running, paused)" in r.stderr, r.stderr
        assert "stop-world" not in open(log).read(), open(log).read()   # the world keeps its state
        rec = json.load(open(os.path.join(rd, "stopped.json")))
        assert rec["via"] == "failed" and rec["save"] is None, rec
        assert os.path.exists(os.path.join(rd, "luna", "journal.jsonl.gz")) and "goal in shift71" in open(
            os.path.join(rd, "luna", "notes.md")).read()
        # the same stop again once the world is down, with the first stop's record (it saved): as before, the world stopped
        json.dump(dict(good, run=run), open(os.path.join(rd, "stopped.json"), "w"))
        open(log, "w").close()
        r = subprocess.run(["bash", os.path.join(tmp, "tools", "stop-team.sh"), run, world], env=env, capture_output=True,
                           text=True, timeout=120)
        assert r.returncode == 0 and "stop-world.ps1 -Name " + world in open(log).read(), (r.returncode, r.stderr)
        assert json.load(open(os.path.join(rd, "stopped.json")))["save"] == "shift70.zip"
    finally:
        shutil.rmtree(tmp)
    # shift-change.sh: stop-team's exit 3 refuses the change before any pane is closed or start-team runs
    import test_shift_change as tsc
    tmp, runs, bin_, state = tsc.setup()
    try:
        p = os.path.join(bin_, "stop-team")
        open(p, "w").write(tsc.STUB + 'exit "${STOP_EXIT:-0}"\n')
        log = os.path.join(runs, "shake11", "start.log")   # no broker sockets here (as test_shift_change's change)
        open(log, "w").write(open(log).read().replace("RCON broker: on", "RCON broker: off"))
        r, calls = tsc.run(tmp, runs, bin_, state, "shake11", "shake12", "240", "--no-stream", STOP_EXIT="3")
        assert r.returncode == 2 and "refused: shake11's stop save failed (stop-team exit 3" in r.stderr, r.stdout + r.stderr
        assert "stop-team shake11" in calls and "herdr" not in calls and not tsc.started(calls, "start-team"), calls
        assert "obs-restart" not in calls and "site-refresh" not in calls, calls
        assert not os.path.exists(os.path.join(runs, ".shift-change.lock"))
        # another stop-team failure is as before: the change goes on
        r, calls = tsc.run(tmp, runs, bin_, state, "shake11", "shake13", "240", "--no-stream", STOP_EXIT="1")
        assert r.returncode == 0 and "stop-team shake11 exited 1 (going on" in r.stdout and tsc.started(calls, "start-team"), \
            r.stdout + r.stderr
    finally:
        shutil.rmtree(tmp)
    print("a failed save: a stop record with no save, the world left running, no next shift")


if __name__ == "__main__":
    before_workspaces()
    mid_launch()
    played_cut_short()
    failed_save()
    print("test_shift_recovery: ok")
