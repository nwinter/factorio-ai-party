#!/usr/bin/env python3
"""Offline checks for resuming a team world (tools/start-team.sh with POG_RESUME): python3 tools/test_resume.py

- team_bots: a resumed save keeps its bots and creates only the members it lacks; a fresh one creates all.
- new-run.sh: each workspace starts from the previous shift's notes.md, under a one-line header naming that shift.
- launch-agent.sh: the resume sentence is added to the prompt.
- start-team.sh: the dry run prints the plan (notes found or not, the resume check) and touches nothing.
"""
import json
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
        for f in ("new-run.sh",):
            shutil.copy(os.path.join(ROOT, "tools", f), os.path.join(tmp, "tools"))
        for f in os.listdir(os.path.join(ROOT, "agent")):
            if f.endswith(".md"):
                shutil.copy(os.path.join(ROOT, "agent", f), os.path.join(tmp, "agent"))
        prev = os.path.join(tmp, "runs", "shake4", "haiku")
        os.makedirs(prev)
        open(os.path.join(prev, "notes.md"), "w").write("# Notes (haiku, world n)\n\n## Now\nGoal: iron row at -40,12\n")
        env = dict(os.environ, POG_WS="haiku", POG_BOT="haiku", POG_RESUME="shake4",
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
        open(os.path.join(prev, "scores.jsonl"), "w").write(json.dumps({"score": {"tick": 236000}}) + "\n")
        team = os.path.join(tmp, "team.tsv")
        open(team, "w").write("haiku\tclaude\tclaude-b\thaiku\tlow\tHaiku 5.5\tClaude Code\n"
                              "luna\tcodex\tcodex-b\tgpt-6-luna\tlow\tLuna\tCodex\n")
        qb = os.path.join(tmp, "brief.json")   # quota: Gemini-style full window on Luna's route
        json.dump({"profiles": [{"id": "codex_account_b", "command": "codex-b", "windows": [
            {"label": "Codex · Weekly", "percent": 100, "resets_at": 4102444800}]}]}, open(qb, "w"))
        env = dict(os.environ, POG_DRY_RUN="1", POG_RESUME="shake4", POG_RESUME_DIR=prev, POG_TEAM_FILE=team,
                   POG_CASTER="0", POG_ANALYST="0", POG_QUOTA_BRIEF=qb)
        r = subprocess.run(["bash", os.path.join(ROOT, "tools", "start-team.sh"), "resume-dry-test", "10"], env=env,
                           capture_output=True, text=True, cwd=ROOT)
        assert r.returncode == 0, r.stderr
        out = r.stdout
        assert "resume-save.ps1 -Name n -From shake4 -Check" in out, out
        assert "last score tick 236000 (game 65m)" in out, out
        assert "bot haiku: kept if the save has it, else created; notes.md from" in out, out
        assert "bot luna: kept if the save has it, else created; fresh notes.md (none in shake4)" in out, out
        assert "prompt adds: This is a later shift" in out, out
        assert "WARNING quota codex_account_b (luna) Codex · Weekly: 100% used" in out, out
        assert "no ai-usage profile" in out and "(route claude-b)" in out, out
        assert "code ok: " in out or "WARNING code: " in out, out
        assert "5. agents launch; 6." in out, out   # POG_FULL_TOOLS unset
        r = subprocess.run(["bash", os.path.join(ROOT, "tools", "start-team.sh"), "resume-dry-test", "10"],
                           env=dict(env, POG_FULL_TOOLS="1"), capture_output=True, text=True, cwd=ROOT)
        assert "5. agents launch with full tools" in r.stdout, r.stdout
        assert not os.path.exists(os.path.join(ROOT, "runs", "resume-dry-test")), "the dry run made a run directory"
        r = subprocess.run(["bash", os.path.join(ROOT, "tools", "start-team.sh"), "shake4", "10"], env=env,
                           capture_output=True, text=True, cwd=ROOT)
        assert r.returncode != 0 and "needs a new run id" in r.stderr, r.stderr
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


if __name__ == "__main__":
    check()
    for script in ("start-team.sh", "new-run.sh", "launch-agent.sh", "stop-team.sh"):
        subprocess.run(["bash", "-n", os.path.join(ROOT, "tools", script)], check=True)
    bots()
    workspace()
    sentence()
    dry_run()
