#!/usr/bin/env python3
"""Offline checks for resuming a team world (tools/start-team.sh with POG_RESUME): python3 tools/test_resume.py

- team_bots: a resumed save keeps its bots and creates only the members it lacks; a fresh one creates all.
- new-run.sh: each workspace starts from the previous shift's notes.md, under a one-line header naming that shift.
- launch-agent.sh: the resume sentence is added to the prompt.
- start-team.sh: the dry run prints the plan (notes found or not, tools to carry, the resume check, the previous run's
  stop record) and touches nothing.
- stop_save.py: the run's own save by game.server_save and its stop record; /server-save when that save never appears.
- resume_guard.py: the tick resumed at against the previous run's last; refused when it went back (operator 17:00:
  after a crash restart under shift12r the 15:55 change took shift12.zip from 10:48, 3 game hours back).
  (tools/win/resume-save.ps1 itself is checked on the Windows box: tools/test_resume_save.py.)
"""
import json
import testsafe  # noqa: E402  (d24 batch186: what a test runs a repo script with)
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import team_bots  # noqa: E402


class FakeRcon:
    def __init__(self, bots):
        self.bots, self.sent = bots, []

    def command(self, cmd):
        self.sent.append(cmd)
        if '"bots"' in cmd:
            return json.dumps({"ok": True, "tick": 216000, "bots": self.bots})
        return json.dumps({"ok": True, "tick": 216000, "bot": {"name": cmd.split('"')[-2]}})


def bots():
    r = FakeRcon([{"name": "haiku", "index": 1000001, "alive": True, "position": {"x": -40.2, "y": 12.7}},
                  {"name": "sol", "index": 1000002, "alive": False, "dead_until_tick": 216300}])
    lines = team_bots.ensure(r, ["haiku", "luna"])
    assert lines[0] == "haiku kept (alive, at -40,13)", lines
    assert lines[1].startswith("luna created"), lines
    assert lines[2] == "not in the team (left as they are): sol", lines
    created = [c for c in r.sent if "bot_create" in c]
    assert len(created) == 1 and '"luna"' in created[0], r.sent
    fresh = FakeRcon({})  # an empty Lua table comes back as {}
    assert [l.split()[1] for l in team_bots.ensure(fresh, ["haiku", "luna"])] == ["created", "created"]
    try:
        team_bots.existing(type("R", (), {"command": lambda self, c: '{"ok":false,"error":{"message":"x"}}'})())
        raise AssertionError("an operator failure must stop the start")
    except SystemExit:
        pass
    print("team_bots: ok")


def workspace():
    tmp = tempfile.mkdtemp()
    try:
        for d in ("tools", "agent", "bin"):
            os.makedirs(os.path.join(tmp, d))
        for f in ("new-run.sh", "brief.py"):
            shutil.copy(os.path.join(ROOT, "tools", f), os.path.join(tmp, "tools"))
        for f in os.listdir(os.path.join(ROOT, "agent")):
            if f.endswith(".md"):
                shutil.copy(os.path.join(ROOT, "agent", f), os.path.join(tmp, "agent"))
        shutil.copytree(os.path.join(ROOT, "agent", "ref"), os.path.join(tmp, "agent", "ref"))
        prev = os.path.join(tmp, "runs", "shake4", "haiku")
        os.makedirs(prev)
        open(os.path.join(prev, "notes.md"), "w").write("# Notes (haiku, world n)\n\n## Now\nGoal: iron row at -40,12\n")
        env = testsafe.env(POG_WS="haiku", POG_BOT="haiku", POG_RESUME="shake4",
                   POG_RESUME_DIR=os.path.join(tmp, "runs", "shake4"))
        out = subprocess.run(["bash", os.path.join(tmp, "tools", "new-run.sh"), "shake5", "n", "haiku", "10"], env=env,
                             capture_output=True, text=True, check=True).stdout.strip()
        notes = open(os.path.join(out, "notes.md")).read().splitlines()
        assert notes[0] == "(Carried over from the previous shift, run shake4: its notes.md for haiku, as that shift left it.)", notes[0]
        assert notes[2] == "# Notes (haiku, world n)" and "Goal: iron row at -40,12" in notes, notes
        # A member new to the world starts with the usual empty notes.
        env.update(POG_WS="luna", POG_BOT="luna")
        out = subprocess.run(["bash", os.path.join(tmp, "tools", "new-run.sh"), "shake5", "n", "luna", "10"], env=env,
                             capture_output=True, text=True, check=True).stdout.strip()
        assert open(os.path.join(out, "notes.md")).read().startswith("# Notes (luna, world n)")
    finally:
        shutil.rmtree(tmp)
    print("new-run notes: ok")


def sentence():
    s = subprocess.run(["bash", os.path.join(ROOT, "tools", "launch-agent.sh"), "--resume-sentence"], capture_output=True,
                       text=True, check=True).stdout.strip()
    assert s.startswith("This is a later shift of the same world") and "notes.md" in s, s
    print("resume sentence: ok")


def dry_run():
    tmp = tempfile.mkdtemp()
    try:
        prev = os.path.join(tmp, "shake4")
        os.makedirs(os.path.join(prev, "haiku"))
        open(os.path.join(prev, "haiku", "notes.md"), "w").write("a\nb\n")
        os.makedirs(os.path.join(prev, "haiku", "tools"))
        open(os.path.join(prev, "haiku", "tools", "belt.py"), "w").write("print(1)\n")
        open(os.path.join(prev, "scores.jsonl"), "w").write(json.dumps({"score": {"tick": 236000}}) + "\n")
        team = os.path.join(tmp, "team.tsv")
        open(team, "w").write("haiku\tclaude\tclaude-b\thaiku\tlow\tHaiku 5.5\tClaude Code\n"
                              "luna\tcodex\tcodex-b\tgpt-6-luna\tlow\tLuna\tCodex\n")
        qb = os.path.join(tmp, "brief.json")   # quota: Gemini-style full window on Luna's route
        json.dump({"profiles": [{"id": "codex_account_b", "command": "codex-b", "windows": [
            {"label": "Codex · Weekly", "percent": 100, "resets_at": 4102444800}]}]}, open(qb, "w"))
        env = testsafe.env(POG_DRY_RUN="1", POG_RESUME="shake4", POG_RESUME_DIR=prev, POG_TEAM_FILE=team,
                   POG_CASTER="0", POG_ANALYST="0", POG_QUOTA_BRIEF=qb,
                   POG_QUOTA_BURN=os.path.join(tmp, "no-burn.tsv"))   # no rates: a full window warns all the same
        r = subprocess.run(["bash", os.path.join(ROOT, "tools", "start-team.sh"), "resume-dry-test", "10"], env=env,
                           capture_output=True, text=True, cwd=ROOT)
        assert r.returncode == 0, r.stderr
        out = r.stdout
        assert "resume-save.ps1 -Name n -From shake4 -Check" in out, out
        assert "last score tick 236000 (game 65m)" in out, out
        assert "bot haiku: kept if the save has it, else created; notes.md from" in out, out
        assert "bot luna: kept if the save has it, else created; fresh notes.md (none in shake4)" in out, out
        assert "prompt adds: This is a later shift" in out, out
        assert "3b. carry haiku tools/: 1 file (0.0 MB) from shake4" in out, out
        assert "3b. carry luna tools/: none in shake4" in out and "3b. carry team-tools/: none in shake4" in out, out
        assert "WARNING quota codex_account_b (luna) Codex · Weekly: 100% used" in out, out
        assert "no ai-usage profile" in out and "(route claude-b)" in out, out
        assert "code ok: " in out or "WARNING code: " in out, out
        assert "agy memory guard" not in out, out  # no agy agent in the team (tools/test_agy_memguard.py)
        # (batch290) the public push loop: one per Mac; a test run's check refuses the live paths (tools/test_public_push.py)
        assert "4e. public repo push loop (one per Mac, across shifts): POG_TEST=1: no public push without" in out, out
        assert "5. agents launch; 6." in out, out   # POG_FULL_TOOLS unset
        r = subprocess.run(["bash", os.path.join(ROOT, "tools", "start-team.sh"), "resume-dry-test", "10"],
                           env=dict(env, POG_FULL_TOOLS="1"), capture_output=True, text=True, cwd=ROOT)
        assert "5. agents launch with full tools" in r.stdout, r.stdout
        assert "4b. RCON broker" not in r.stdout, r.stdout
        r = subprocess.run(["bash", os.path.join(ROOT, "tools", "start-team.sh"), "resume-dry-test", "10"],
                           env=dict(env, POG_PUBLIC_HOURLY="0"), capture_output=True, text=True, cwd=ROOT)
        assert r.returncode == 0 and "4e. public repo push" not in r.stdout, r.stdout
        r = subprocess.run(["bash", os.path.join(ROOT, "tools", "start-team.sh"), "resume-dry-test", "10"],
                           env=dict(env, POG_BROKER="1"), capture_output=True, text=True, cwd=ROOT)
        assert "4b. RCON broker (POG_BROKER=1): sockets runs/resume-dry-test/.sock/NAME.sock for haiku luna" in r.stdout, r.stdout
        assert "player votes" not in out, out   # POG_PLAYERS unset
        r = subprocess.run(["bash", os.path.join(ROOT, "tools", "start-team.sh"), "resume-dry-test", "10"],
                           env=dict(env, POG_PLAYERS="1"), capture_output=True, text=True, cwd=ROOT)
        assert ", player votes, recording" in r.stdout, r.stdout
        assert not os.path.exists(os.path.join(ROOT, "runs", "resume-dry-test")), "the dry run made a run directory"
        r = subprocess.run(["bash", os.path.join(ROOT, "tools", "start-team.sh"), "shake4", "10"], env=env,
                           capture_output=True, text=True, cwd=ROOT)
        assert r.returncode != 0 and "needs a new run id" in r.stderr, r.stderr
        # The previous run's stop record goes to resume-save; without one, the newest save is taken.
        assert "no stop record in " + prev + " (stopped.json): resume-save takes the newest save" in out, out
        json.dump({"run": "shake4", "world": "n", "stop_utc": "2026-10-15T02:55:00.123Z", "save": "shake4.zip",
                   "tick": 236100, "via": "game.server_save"}, open(os.path.join(prev, "stopped.json"), "w"))
        r = subprocess.run(["bash", os.path.join(ROOT, "tools", "start-team.sh"), "resume-dry-test", "10"], env=env,
                           capture_output=True, text=True, cwd=ROOT)
        assert ("stop record " + prev + "/stopped.json: tick 236100, save shake4.zip at 2026-10-15T02:55:00.123Z: resume-save "
                "gets -StopUtc 2026-10-15T02:55:00.123Z -StopSave shake4.zip") in r.stdout, r.stdout
    finally:
        shutil.rmtree(tmp)
    print("start-team dry run: ok")


def check():
    import resume_check
    s = "This is a later shift."
    prev = {"tick": 216000, "research_done": ["automation", "logistics", "electronics"], "entities": {"stone-furnace": 40}}
    now = {"tick": 214000, "research_done": ["automation", "logistics", "electronics"], "entities": {"stone-furnace": 40}}
    ws = {"haiku": ("(Carried over from the previous shift, run shake4: ...)\n\n# Notes\nGoal: x\n", "# Notes\nGoal: x\n"),
          "luna": ("# Notes (luna, world n)\n", None)}
    bots = {"haiku": {"alive": True, "position": {"x": 1, "y": 2}}, "luna": {"alive": True, "position": {"x": 3, "y": 4}}}
    lines, problems = resume_check.compare(prev, now, None, bots, ["haiku", "luna"], ws, s, s + "\n")
    assert problems == [], problems
    assert any("notes.md carried over (2 lines)" in l for l in lines) and any("fresh notes.md" in l for l in lines), lines
    fresh = {"tick": 600, "research_done": [], "entities": {}}
    _, problems = resume_check.compare(prev, fresh, None, {"haiku": bots["haiku"]}, ["haiku", "luna"],
                                       {"haiku": ("# Notes\n", "# Notes\nGoal: x\n")}, s, "")
    text = " | ".join(problems)
    for want in ("first game minute", "technologies done", "buildings", "bot luna: missing", "haiku: notes.md is not",
                 "resume sentence"):
        assert want in text, (want, text)
    print("resume_check compare: ok")


class SaveRcon:
    def __init__(self, reply="tick 9800000\n"):
        self.sent, self.reply = [], reply

    def command(self, cmd):
        self.sent.append(cmd)
        return self.reply if "server_save" in cmd else "Saving the map"


def stop_save_record():
    import datetime
    import stop_save
    t0 = datetime.datetime(2026, 10, 15, 2, 55, 0)
    s3 = t0 + datetime.timedelta(seconds=3)
    looks = iter([None, (s3, 1000), (s3, 10232571), (s3, 10232571)])   # not yet, still writing, written, steady
    r = SaveRcon()
    rec = stop_save.stop_save(r, "shift13", "n", now=lambda: t0, info=lambda w, n: next(looks), sleep=lambda s: None)
    assert r.sent == ["/silent-command game.server_save('shift13') rcon.print('tick ' .. game.tick)"], r.sent
    assert rec == {"run": "shift13", "world": "n", "stop_utc": "2026-10-15T02:55:00.000Z", "clock": "windows",
                   "save": "shift13.zip", "tick": 9800000, "save_utc": "2026-10-15T02:55:03.000Z", "save_bytes": 10232571,
                   "via": "game.server_save"}, rec
    # An older shift13.zip (the stale copy) never counts: the named save does not appear, so /server-save.
    r = SaveRcon()
    rec = stop_save.stop_save(r, "shift13", "n", now=lambda: t0, info=lambda w, n: (t0 - datetime.timedelta(hours=8), 9044085),
                              sleep=lambda s: None, wait_s=6)
    assert r.sent[-1] == "/server-save" and rec["save"] is None and rec["via"] == "server-save", rec
    assert rec["tick"] == 9800000 and "shift13.zip not written within 6 s" in rec["note"], rec
    # Nothing written within 30 s (an autosave running): sent once more, then written.
    looks = iter([None] * 17 + [(s3 + datetime.timedelta(seconds=40), 10232571)] * 2)
    r = SaveRcon()
    rec = stop_save.stop_save(r, "shift13", "n", now=lambda: t0, info=lambda w, n: next(looks), sleep=lambda s: None)
    assert r.sent[1] == "/silent-command game.server_save('shift13')" and len(r.sent) == 2, r.sent
    assert rec["save"] == "shift13.zip" and "sent twice" in rec["note"], rec
    # The box's clock unreadable: the Mac's, a minute back.
    def boom():
        raise OSError("ssh: no route")
    rec = stop_save.stop_save(SaveRcon(), "shift13", "n", now=boom, info=lambda w, n: None, sleep=lambda s: None, wait_s=0)
    assert rec["clock"].startswith("mac (ssh: no route)"), rec
    try:
        stop_save.stop_save(SaveRcon(), "shift13'); game.print('x", "n")
        raise AssertionError("a run name with quotes must be refused")
    except SystemExit:
        pass
    print("stop_save: ok")


def guard():
    import resume_guard
    tmp = tempfile.mkdtemp()
    try:
        assert resume_guard.previous(tmp)[0] is None
        open(os.path.join(tmp, "scores.jsonl"), "w").write(
            "\n".join(json.dumps({"score": {"tick": t}}) for t in (9700000, 9790000)) + "\nnot json\n")
        assert resume_guard.previous(tmp) == (9790000, "its last score in scores.jsonl")
        json.dump({"tick": 9800000, "save": "shift13.zip"}, open(os.path.join(tmp, "stopped.json"), "w"))
        tick, source = resume_guard.previous(tmp)
        assert (tick, source) == (9800000, "stopped.json: its stop save shift13.zip"), source
        # The 15:55 change: shift13 started from the 10:48 save, 3 game hours behind shift12r's stop.
        ok, line = resume_guard.check(9800000 - 3 * 216000, tick, source, "shift13.zip")
        assert not ok and "the world went back 3h00m of game time, more than 18m: an old save; refusing" in line, line
        assert line.startswith("resumed at tick 9152000 (game 42h22m) from shift13.zip; the previous run's last tick 9800000"), line
        # The stop save itself, or an autosave a few minutes older: on.
        assert resume_guard.check(9800000, tick, source)[0] and resume_guard.check(9800000 - 6 * 3600, tick, source)[0]
        # d22 06:15, autosaves every 15 minutes: a crash restart's autosave 14 game minutes behind is on, 20 refused.
        assert resume_guard.check(9800000 - 14 * 3600, tick, source)[0]
        ok, line = resume_guard.check(9800000 - 20 * 3600, tick, source, "_autosave3.zip")
        assert not ok and "went back 20m of game time, more than 18m" in line, line
        assert resume_guard.SLACK == 18 * 3600
        assert resume_guard.check(9800000 + 120, tick, source)[1].endswith(": +120 ticks")
        assert resume_guard.check(5, None, "no stopped.json")[0]
        r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "resume_guard.py"), tmp, "9152000"], capture_output=True,
                           text=True)
        assert r.returncode == 1 and "went back 3h00m" in r.stdout, r.stdout
        r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "resume_guard.py"), tmp, "9800010", "shift13.zip"],
                           capture_output=True, text=True)
        assert r.returncode == 0 and r.stdout.strip().endswith("+10 ticks"), r.stdout
        env = {k: v for k, v in os.environ.items() if k != "POG_RESUME_TICK_SLACK"}
        for behind, code in ((14, 0), (20, 1)):  # the script's default slack, 18 game minutes
            r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "resume_guard.py"), tmp,
                                str(9800000 - behind * 3600), "_autosave3.zip"], capture_output=True, text=True, env=env)
            assert r.returncode == code, (behind, r.stdout)
    finally:
        shutil.rmtree(tmp)
    print("resume_guard: ok")


if __name__ == "__main__":
    stop_save_record()
    guard()
    check()
    for script in ("start-team.sh", "new-run.sh", "launch-agent.sh", "stop-team.sh"):
        subprocess.run(["bash", "-n", os.path.join(ROOT, "tools", script)], check=True)
    bots()
    workspace()
    sentence()
    dry_run()
