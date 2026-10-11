#!/usr/bin/env python3
"""Offline checks for POG_FULL_TOOLS=1: python3 tools/test_full_tools.py

- workspace: tools/, team-tools -> ../team-tools, a read-only gamedata/ without the dump's map settings, and the
  "Your tools" paragraph once, before the compaction instructions, with the harness's line.
- claude: subagent, web and background-job tools allowed, team-tools writable, other workspaces' private files
  denied (their notes.md not), and the launch's --tools list only with the switch on.
- codex: live web search, multi_agent and team-tools writable only with the switch on. grok: subagents, workflows
  and web_fetch only with it; the allow and deny words.
- the paragraph names no strategy: no "should", "must" or "try".
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import full_tools  # noqa: E402

AGENTS = "# Playbook\n\nPlay.\n\n## Compact instructions\n\nKeep notes.\n"


def make_run():
    tmp = tempfile.mkdtemp()
    for ws in ("haiku", "luna"):
        os.makedirs(os.path.join(tmp, "run", ws))
        open(os.path.join(tmp, "run", ws, "AGENTS.md"), "w").write(AGENTS)
    return tmp


def workspace():
    tmp = make_run()
    try:
        d = os.path.join(tmp, "run", "haiku")
        for _ in range(2):   # a relaunch into the same workspace changes nothing
            full_tools.workspace(d, "claude")
        assert os.path.isdir(os.path.join(d, "tools"))
        assert os.readlink(os.path.join(d, "team-tools")) == "../team-tools"
        assert os.path.isdir(os.path.join(tmp, "run", "team-tools"))
        names = sorted(os.listdir(os.path.join(d, "gamedata")))
        assert names == sorted(n + ".json" for n in full_tools.GAMEDATA), names
        recipes = json.load(open(os.path.join(d, "gamedata", "recipes.json")))
        assert any(r["name"] == "electronic-circuit" for r in recipes)
        assert not os.access(os.path.join(d, "gamedata", "recipes.json"), os.W_OK) or os.geteuid() == 0
        text = open(os.path.join(d, "AGENTS.md")).read()
        assert text.count("## Your tools") == 1, text
        assert text.index("## Your tools") < text.index("## Compact instructions"), text
        assert "The Agent tool starts subagents" in text and "base-2.0.77" in text and "{{" not in text, text
        assert "<!-- harness -->" not in text and "codex:" not in text, text
        os.environ["POG_SPACE_AGE"] = "1"
        try:
            assert "space-age-2.0.77" in full_tools.paragraph("grok")
        finally:
            del os.environ["POG_SPACE_AGE"]
    finally:
        for root, dirs, _ in os.walk(tmp):
            for x in dirs:
                os.chmod(os.path.join(root, x), 0o755)
        shutil.rmtree(tmp)
    print("workspace: ok")


def paragraphs():
    for kind in ("claude", "codex", "grok", "agy", "muse"):
        p = full_tools.paragraph(kind)
        assert p.startswith("## Your tools") and "- \n" not in p, (kind, p)
        assert "Only `./fh` acts in the game" in p, p
        for word in (" should ", " must ", " try "):
            assert word not in p.lower(), (kind, word)
    print("paragraphs: ok")


def claude():
    tmp = make_run()
    try:
        d = os.path.join(tmp, "run", "haiku")
        team = os.path.join(tmp, "team.txt")
        open(team, "w").write("haiku|Haiku 5.5\nluna|Luna\nsol|Sol\n")
        os.environ["POG_TEAM"] = team
        os.makedirs(os.path.join(d, ".claude"))
        json.dump({"sandbox": {"enabled": True, "filesystem": {"denyRead": ["/x/.config/pog"]}},
                   "permissions": {"defaultMode": "dontAsk", "allow": ["Read", "Edit(/**)"], "deny": ["Read(~/.config/pog/**)"]}},
                  open(os.path.join(d, ".claude", "settings.json"), "w"))
        full_tools.claude(d)
        full_tools.claude(d)   # idempotent
        cfg = json.load(open(os.path.join(d, ".claude", "settings.json")))
        allow, deny = cfg["permissions"]["allow"], cfg["permissions"]["deny"]
        for t in full_tools.CLAUDE_EXTRA:
            assert allow.count(t) == 1, (t, allow)
        shared = os.path.join(tmp, "run", "team-tools")
        assert f"Edit(/{shared}/**)" in allow and f"Write({shared}/**)" in allow, allow
        luna, sol = os.path.join(tmp, "run", "luna"), os.path.join(tmp, "run", "sol")
        assert f"Read(/{luna}/journal.jsonl)" in deny and f"Read(/{sol}/*/**)" in deny, deny
        assert not any("haiku" in r for r in deny), deny          # its own workspace stays open
        assert not any(r.endswith("notes.md)") or r == f"Read(/{luna}/**)" for r in deny), deny
        assert deny.count(f"Edit(/{luna}/**)") == 1, deny
        fs = cfg["sandbox"]["filesystem"]
        assert fs["allowWrite"] == [shared], fs
        assert "/x/.config/pog" in fs["denyRead"] and os.path.join(luna, "tools") in fs["denyRead"], fs
        assert os.path.join(luna, "notes.md") not in fs["denyRead"], fs
    finally:
        os.environ.pop("POG_TEAM", None)
        shutil.rmtree(tmp)
    print("claude settings: ok")


def codex_and_grok():
    tmp = make_run()
    try:
        d = os.path.join(tmp, "run", "haiku")
        texts = {}
        for full in ("0", "1"):
            shutil.rmtree(os.path.join(d, ".codex"), ignore_errors=True)
            env = dict(os.environ, POG_FULL_TOOLS=full)
            subprocess.run([sys.executable, os.path.join(ROOT, "tools", "clean-profile.py"), "codex", d], env=env, check=True)
            texts[full] = open(os.path.join(d, ".codex", "config.toml")).read()
        assert "web_search" not in texts["0"] and "multi_agent = false" in texts["0"], texts["0"]
        assert "sandbox_workspace_write" not in texts["0"], texts["0"]
        on = texts["1"]
        assert 'web_search = "live"' in on and "multi_agent = true" in on, on
        assert on.index('web_search = "live"') < on.index("[features]"), on   # a top-level key, before any table
        assert json.dumps(os.path.join(tmp, "run", "team-tools")) in on.split("[sandbox_workspace_write]")[1], on
        try:
            import tomllib
            tomllib.loads(on)
        except ImportError:
            pass
        os.environ.pop("POG_TEAM", None)
        words = full_tools.grok_args(d)
        luna = os.path.join(tmp, "run", "luna")
        assert f"--allow 'Edit({tmp}/run/team-tools/**)'" in words, words
        assert f"--deny 'Read({luna}/journal.jsonl)'" in words and f"--deny 'Read({luna}/tools/**)'" in words, words
        assert "notes.md" not in words and "/haiku/" not in words, words
        def grok_env(full):
            return subprocess.run(["bash", "-c", f". '{ROOT}/tools/profile-flags.sh'; echo \"$grok_env\""],
                                  env=dict(os.environ, POG_FULL_TOOLS=full), capture_output=True, text=True,
                                  check=True).stdout
        assert "GROK_SUBAGENTS=0" in grok_env("0") and "GROK_WEB_FETCH" not in grok_env("0")
        assert "GROK_SUBAGENTS" not in grok_env("1") and "GROK_WEB_FETCH=1" in grok_env("1")
    finally:
        shutil.rmtree(tmp)
    print("codex and grok: ok")


def flags():
    def tools(full):
        env = dict(os.environ, POG_FULL_TOOLS=full)
        return subprocess.run(["bash", "-c", f". '{ROOT}/tools/profile-flags.sh'; echo \"$claude_flags\""], env=env,
                              capture_output=True, text=True, check=True).stdout.split("--tools ")[1].split()[0]
    assert tools("0") == "Bash,Read,Edit,Write,Grep,Glob", tools("0")
    assert tools("1") == "Bash,Read,Edit,Write,Grep,Glob," + ",".join(full_tools.CLAUDE_EXTRA), tools("1")
    print("claude flags: ok")


if __name__ == "__main__":
    workspace()
    paragraphs()
    claude()
    codex_and_grok()
    flags()
