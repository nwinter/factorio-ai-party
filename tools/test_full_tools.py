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
import stat
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
        # every listed file the dump has (asteroids: Space Age dumps only)
        src = os.path.join(full_tools.KB, full_tools.kb_version())
        want = [n + ".json" for n in full_tools.GAMEDATA if os.path.exists(os.path.join(src, n + ".json"))]
        assert names == sorted(want) and "recipes.json" in names, names
        recipes = json.load(open(os.path.join(d, "gamedata", "recipes.json")))
        assert any(r["name"] == "electronic-circuit" for r in recipes)
        assert not os.access(os.path.join(d, "gamedata", "recipes.json"), os.W_OK) or os.geteuid() == 0
        text = open(os.path.join(d, "AGENTS.md")).read()
        assert text.count("## Your tools") == 1, text
        assert text.index("## Your tools") < text.index("## Compact instructions"), text
        assert "The Agent tool starts subagents" in text and "base-2.0.77" in text and "{{" not in text, text
        assert "<!-- harness -->" not in text and "codex:" not in text, text
        # Muse: its own team-tools folder, mirrored with the shared one both ways (newer wins, nothing deleted).
        shared = os.path.join(tmp, "run", "team-tools")
        open(os.path.join(shared, "haiku-circuit.py"), "w").write("print(1)\n")
        m = os.path.join(tmp, "run", "muse")
        os.makedirs(m)
        open(os.path.join(m, "AGENTS.md"), "w").write(AGENTS)
        full_tools.workspace(m, "muse")
        mine = os.path.join(m, "team-tools")
        assert os.path.isdir(mine) and not os.path.islink(mine), mine
        assert open(os.path.join(mine, "haiku-circuit.py")).read() == "print(1)\n"
        open(os.path.join(mine, "muse-circuit.py"), "w").write("print(2)\n")
        assert full_tools.sync(os.path.join(tmp, "run")) == ["muse: muse-circuit.py"]
        assert open(os.path.join(shared, "muse-circuit.py")).read() == "print(2)\n"
        later = os.path.getmtime(os.path.join(shared, "haiku-circuit.py")) + 10
        open(os.path.join(shared, "haiku-circuit.py"), "w").write("print(3)\n")
        os.utime(os.path.join(shared, "haiku-circuit.py"), (later, later))
        os.remove(os.path.join(mine, "muse-circuit.py"))
        assert sorted(full_tools.sync(os.path.join(tmp, "run"))) == ["muse: haiku-circuit.py", "muse: muse-circuit.py"]
        assert open(os.path.join(mine, "haiku-circuit.py")).read() == "print(3)\n"
        assert full_tools.sync(os.path.join(tmp, "run")) == []
        assert "kept in step with the shared one" in open(os.path.join(m, "AGENTS.md")).read()
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


def clones(d):
    """Whether the volume holding d clones files (APFS on macOS): one clone tried there."""
    a, b = os.path.join(d, ".clone-probe-a"), os.path.join(d, ".clone-probe-b")
    os.makedirs(d, exist_ok=True)
    open(a, "w").write("x")
    try:
        full_tools.clone_file(a, b)
        return True
    except OSError:
        return False
    finally:
        for p in (a, b):
            if os.path.lexists(p):
                os.remove(p)


def clone():
    """(d20 batch84 AT1) A carried file is a clone where the volume clones: same content, mode and mtime, and a
    write to the copy leaves the source as it was; where a clone fails it is a copy (shutil.copy2), the same way."""
    tmp = tempfile.mkdtemp()
    try:
        src = os.path.join(tmp, "src", "deploy.py")
        os.makedirs(os.path.dirname(src))
        open(src, "w").write("print('deploy')\n" * 1000)
        os.chmod(src, 0o751)
        os.utime(src, (1700000000, 1700000123.5))

        def same(dst):
            a, b = os.stat(src), os.stat(dst)
            assert open(dst).read() == open(src).read()
            assert stat.S_IMODE(b.st_mode) == stat.S_IMODE(a.st_mode) == 0o751, oct(b.st_mode)
            assert b.st_mtime == a.st_mtime == 1700000123.5, (a.st_mtime, b.st_mtime)
            with open(dst, "a") as f:
                f.write("changed\n")
            assert open(src).read() == "print('deploy')\n" * 1000, "a write to the copy reached the source"

        if full_tools._clonefile() and clones(tmp):
            how = {}
            full_tools.place_file(src, os.path.join(tmp, "cloned.py"), how)
            assert how == {"cloned": 1}, how
            same(os.path.join(tmp, "cloned.py"))
        else:
            print("clone: skipped (this volume or system does not clone files); the fallback is checked below")
        # the fallback: a clone that fails (another volume, not APFS) leaves a copy made by shutil.copy2
        real = full_tools.clone_file

        def fail(a, b):
            open(b, "w").write("partial")   # a failure that left a file behind is cleared first
            raise OSError(18, "Cross-device link")
        full_tools.clone_file = fail
        try:
            how = {}
            full_tools.place_file(src, os.path.join(tmp, "copied.py"), how)
            assert how == {"copied": 1}, how
            same(os.path.join(tmp, "copied.py"))
            dst = os.path.join(tmp, "tree")
            how = {}
            copied, _, _ = full_tools.copy_tree(os.path.dirname(src), dst, how=how)
            assert copied == ["deploy.py"] and how == {"copied": 1}, (copied, how)
        finally:
            full_tools.clone_file = real
    finally:
        shutil.rmtree(tmp)


def carry():
    """A later shift's tools/ and team-tools/ from the previous runs: shift01 had them, shift02's agents never
    launched (no folders), shift03 resumes shift02, and the new shift04 resumes shift03."""
    tmp = tempfile.mkdtemp()
    try:
        runs = os.path.join(tmp, "runs")

        def put(rel, text="x\n", mode=None):
            p = os.path.join(runs, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, "w").write(text)
            if mode:
                os.chmod(p, mode)
            return p

        put("shift01/opus/tools/deploy.py", "print('deploy')\n", 0o755)
        put("shift01/opus/tools/plans/east.md", "east\n")
        put("shift01/opus/tools/__pycache__/deploy.cpython-314.pyc")
        put("shift01/opus/tools/plans/old.pyc")
        put("shift01/opus/tools/.cache/x")
        put("shift01/opus/tools/.env")
        with open(put("shift01/opus/tools/big.jsonl"), "wb") as f:   # over 5 MB (sparse)
            f.truncate(full_tools.CARRY_MAX_BYTES + 1)
        put("shift01/opus/tools/small.jsonl", "y" * 100)
        os.symlink("../../luna/tools", os.path.join(runs, "shift01/opus/tools/luna"))
        os.symlink("/etc/hosts", os.path.join(runs, "shift01/opus/tools/hosts"))
        os.makedirs(os.path.join(runs, "shift01/luna/tools"))   # an agent with an empty tools/
        put("shift01/team-tools/belt.py", "print('belt')\n")
        put("shift01/muse/team-tools/muse-only.py", "print('m')\n")   # Muse's mirror, not yet shared
        put("shift01/muse/team-tools/belt.py", "print('older')\n")
        put("shift02/resumed-from", "shift01\n")
        put("shift02/opus/notes.md")   # a run whose launch failed: notes, no tools/
        put("shift03/resumed-from", "shift02\n")
        os.makedirs(os.path.join(runs, "shift03"), exist_ok=True)
        new = os.path.join(runs, "shift04")
        put("shift04/opus/tools/deploy.py", "mine\n")   # a relaunch: the new shift's file stays

        names = ["opus", "luna", "sol"]
        lines, files = full_tools.carry(new, os.path.join(runs, "shift03"), names, dry=True)
        assert not os.path.exists(os.path.join(new, "team-tools")), "the dry run copied"
        lines, files = full_tools.carry(new, os.path.join(runs, "shift03"), names)
        text = "\n".join(lines)
        made = "(2 cloned, 0 copied)" if full_tools._clonefile() and clones(runs) else "(0 cloned, 2 copied)"
        assert lines[0].startswith(f"carry opus tools/: 2 files (0.0 MB) from shift01 {made}; "), lines
        for want in ("skipped 1 already there: deploy.py", "skipped 1 over 5 MB: big.jsonl (5.0 MB)",
                     "skipped 4 cache: .cache/, __pycache__/, .env, plans/old.pyc", "skipped 2 symlink: luna/, hosts"):
            assert want in lines[0], (want, lines[0])
        assert lines[1] == "carry luna tools/: 0 files (0.0 MB) from shift01", lines
        assert lines[2] == "carry sol tools/: none in shift03, shift02, shift01", lines
        assert lines[3] == f"carry team-tools/: 2 files (0.0 MB) from shift01 {made}", text
        o = os.path.join(new, "opus", "tools")
        assert sorted(os.path.relpath(os.path.join(b, f), o) for b, _, fs in os.walk(o) for f in fs) == \
            ["deploy.py", "plans/east.md", "small.jsonl"]
        assert open(os.path.join(o, "deploy.py")).read() == "mine\n"
        assert open(os.path.join(o, "plans", "east.md")).read() == "east\n"
        assert open(os.path.join(new, "team-tools", "belt.py")).read() == "print('belt')\n"   # the shared copy first
        assert open(os.path.join(new, "team-tools", "muse-only.py")).read() == "print('m')\n"
        assert "opus tools/\tshift01\tplans/east.md" in files and "team-tools/\tshift01/muse\tmuse-only.py" in files
        # the executable bit stays: a fresh copy of shift01's deploy.py into an empty workspace
        lines, _ = full_tools.carry(os.path.join(runs, "shift05"), os.path.join(runs, "shift01"), ["opus"])
        assert os.access(os.path.join(runs, "shift05", "opus", "tools", "deploy.py"), os.X_OK), lines
        # the command line: start.log lines on stdout, the file list in RUN/carried-tools.txt
        r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "full_tools.py"), "carry",
                            os.path.join(runs, "shift06"), os.path.join(runs, "shift03"), "opus", "sol"],
                           capture_output=True, text=True, check=True)
        assert r.stdout.splitlines()[0].startswith("carry opus tools/: 3 files"), r.stdout
        listed = open(os.path.join(runs, "shift06", "carried-tools.txt")).read().splitlines()
        assert len(listed) == 5 and "opus tools/\tshift01\tdeploy.py" in listed, listed
        # a resumed-from loop or a missing run ends the walk
        put("shift07/resumed-from", "shift08\n")
        put("shift08/resumed-from", "shift07\n")
        assert [os.path.basename(r) for r in full_tools.chain(os.path.join(runs, "shift07"))] == ["shift07", "shift08"]
        put("shift09/resumed-from", "gone\n")
        assert full_tools.chain(os.path.join(runs, "shift09")) == [os.path.join(runs, "shift09")]
    finally:
        shutil.rmtree(tmp)
    print("carry: ok")


def paragraphs():
    for kind in ("claude", "codex", "grok", "agy", "muse"):
        p = full_tools.paragraph(kind)
        assert p.startswith("## Your tools") and "- \n" not in p, (kind, p)
        assert "Only `./fh` acts in the game" in p, p
        for word in (" should ", " must ", " try "):
            assert word not in p.lower(), (kind, word)
    print("paragraphs: ok")


def team_files():
    """(d19 batch41 C1) the paragraph names team-tools/README.md and the newest knowledge-index*.md when they exist, with
    each one's heading and the writer it names; nothing when neither is there."""
    with tempfile.TemporaryDirectory() as shared:
        assert full_tools.team_files(shared) == ""
        assert "{{TEAM_FILES}}" not in full_tools.paragraph("codex", None, shared)
        open(os.path.join(shared, "README.md"), "w").write("# Persistent team knowledge\n\nStart each shift with ...\n")
        old, new = os.path.join(shared, "knowledge-index39.md"), os.path.join(shared, "knowledge-index41.md")
        open(old, "w").write("# Team knowledge index\n")
        open(new, "w").write("# Knowledge index, shift 41\nWritten by astra.\n")
        os.utime(old, (1000, 1000))
        line = full_tools.team_files(shared)
        assert line == ('\n  It holds `README.md` ("Persistent team knowledge"; no writer named) and the newest knowledge index, '
                        '`knowledge-index41.md` ("Knowledge index, shift 41"; by astra).'), line
        p = full_tools.paragraph("claude", None, shared)
        assert "`team-tools/` holds the team's shared files" in p and "knowledge-index41.md" in p, p
        for word in (" should ", " must ", " read it", " start "):
            assert word not in line.lower(), word
    print("team files: ok")


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
            assert tomllib.loads(on)["agents"]["default_subagent_reasoning_effort"] == "medium", on
            assert "[agents]" not in texts["0"], texts["0"]
        except ImportError:
            pass
        # agent/subagents-off.txt: a listed agent gets multi_agent off even with full tools, and the -nosub paragraph line.
        off = os.path.join(tmp, "subagents-off.txt")
        open(off, "w").write("# test\nhaiku\n")
        shutil.rmtree(os.path.join(d, ".codex"), ignore_errors=True)
        subprocess.run([sys.executable, os.path.join(ROOT, "tools", "clean-profile.py"), "codex", d],
                       env=dict(os.environ, POG_FULL_TOOLS="1", POG_SUBAGENTS_OFF_FILE=off), check=True)
        listed = open(os.path.join(d, ".codex", "config.toml")).read()
        assert "multi_agent = false" in listed and 'web_search = "live"' in listed, listed
        saved, full_tools.SUBAGENTS_OFF = full_tools.SUBAGENTS_OFF, off
        try:
            nosub = full_tools.paragraph("codex", "haiku")
            # Codex 0.162.1 lists spawn_agent whatever features.multi_agent says, so the -nosub line names the tools
            # as off rather than leaving them out (d17).
            assert "Subagents (the multi-agent" not in nosub and "not to be called" in nosub and "view_image" in nosub, nosub
            assert "spawn_agent" in full_tools.paragraph("codex", "luna")
        finally:
            full_tools.SUBAGENTS_OFF = saved
        os.environ.pop("POG_TEAM", None)
        words = full_tools.grok_args(d)
        luna = os.path.join(tmp, "run", "luna")
        assert f"--allow 'Edit({tmp}/run/team-tools/**)'" in words, words
        assert f"--deny 'Read({luna}/journal.jsonl)'" in words and f"--deny 'Read({luna}/tools/**)'" in words, words
        assert "notes.md" not in words and "/haiku/" not in words.split("--sandbox")[0], words
        # Grok's kernel sandbox profile (subagents need a bare '*' allow, so the kernel holds the line instead).
        assert words.endswith(" --sandbox pog --allow '*'"), words
        import tomllib
        prof = tomllib.loads(open(os.path.join(d, ".grok-home", "sandbox.toml")).read())["profiles"]["pog"]
        assert prof["extends"] == "workspace" and os.path.join(tmp, "run", "team-tools") in prof["read_write"], prof
        assert os.path.join(luna, "journal.jsonl") in prof["deny"] and os.path.expanduser("~/.config/pog") in prof["deny"], prof
        assert os.path.join(luna, "notes.md") not in prof["deny"], prof
        os.environ["POG_GROK_SANDBOX"] = "0"
        try:
            assert "--sandbox" not in full_tools.grok_args(d)
        finally:
            os.environ.pop("POG_GROK_SANDBOX")
        def grok_env(full):
            return subprocess.run(["bash", "-c", f". '{ROOT}/tools/profile-flags.sh'; echo \"$grok_env\""],
                                  env=dict(os.environ, POG_FULL_TOOLS=full, POG_TEST="1"), capture_output=True, text=True,
                                  check=True).stdout
        assert "GROK_SUBAGENTS=0" in grok_env("0") and "GROK_WEB_FETCH" not in grok_env("0")
        assert "GROK_SUBAGENTS" not in grok_env("1") and "GROK_WEB_FETCH=1" in grok_env("1")
    finally:
        shutil.rmtree(tmp)
    print("codex and grok: ok")


def grok_hooks():
    """The run home's hook files are copies, never links: Grok's kernel sandbox refuses to start on a hook path with a
    symlink component (shake8). A link from an older launch is replaced without touching its target."""
    import importlib
    gh = importlib.import_module("grok-home")
    tmp = tempfile.mkdtemp()
    try:
        owner = os.path.join(tmp, "owner")
        os.makedirs(os.path.join(owner, "hooks"))
        real = os.path.join(tmp, "herdr-installed.json")
        open(real, "w").write('{"hooks": "v1"}')
        os.symlink(real, os.path.join(owner, "hooks", "herdr.json"))      # the owner's may itself be a link
        home = os.path.join(tmp, "run", "grok", ".grok-home")
        os.makedirs(os.path.join(home, "hooks"))
        stale = os.path.join(tmp, "stale.json")
        open(stale, "w").write("old")
        os.symlink(stale, os.path.join(home, "hooks", "herdr.json"))      # what earlier launches left
        gh.copy_hooks(home, owner)
        dst = os.path.join(home, "hooks", "herdr.json")
        assert not os.path.islink(dst) and os.path.isfile(dst), dst
        assert os.path.realpath(dst) == os.path.join(os.path.realpath(home), "hooks", "herdr.json"), os.path.realpath(dst)
        assert open(dst).read() == '{"hooks": "v1"}' and open(stale).read() == "old"
        assert not os.path.exists(dst + ".tmp")
        open(real, "w").write('{"hooks": "v2"}')                          # a relaunch takes the owner's current one
        gh.copy_hooks(home, owner)
        assert open(dst).read() == '{"hooks": "v2"}' and not os.path.islink(dst)
        empty = os.path.join(tmp, "nohooks")
        gh.copy_hooks(empty, os.path.join(tmp, "missing-owner"))          # no owner hook: nothing to copy
        assert os.listdir(os.path.join(empty, "hooks")) == []
        assert "os.symlink(herdr" not in open(os.path.join(ROOT, "tools", "grok-home.py")).read()
    finally:
        shutil.rmtree(tmp)
    print("grok hooks: ok")


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
    clone()
    carry()
    paragraphs()
    team_files()
    claude()
    codex_and_grok()
    grok_hooks()
    flags()
