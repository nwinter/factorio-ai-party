#!/usr/bin/env python3
"""(mt277, private) The multi-team launch (tools/mt/start-mt.sh, part D):
- brief: a team's section names only its roster and says nothing of other players; Space Age goal and map line; the
  usage.md path from runs/RUN/TEAM/NAME;
- new-run: a team's workspace runs/RUN/TEAM/NAME with its broker socket in runs/RUN/TEAM/.sock;
- claude_settings: other teams' folders and op/ denied, its own team and the run it resumes readable;
- grok sandbox: other teams' folders and every team's keys denied;
- start-mt.sh's dry run: one team file per team, refusals of a bad teams file;
- the team files in agent/mt.
"""
import json, os, re, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import testsafe  # noqa: E402

OTHERS = ("astra", "sol", "terra", "opus", "sonnet", "argon", "gemini", "grok", "muse")


def copy_brief_tree(tmp):
    for d in ("tools", "agent"):
        os.makedirs(os.path.join(tmp, d))
    for f in ("new-run.sh", "brief.py"):
        shutil.copy(os.path.join(ROOT, "tools", f), os.path.join(tmp, "tools"))
    for f in os.listdir(os.path.join(ROOT, "agent")):
        if f.endswith(".md"):
            shutil.copy(os.path.join(ROOT, "agent", f), os.path.join(tmp, "agent"))
    shutil.copytree(os.path.join(ROOT, "agent", "ref"), os.path.join(tmp, "agent", "ref"))


def mt_env():
    """The brief texts tools/mt/start-mt.sh exports (read from it, so the test follows the script)."""
    text = open(os.path.join(ROOT, "tools", "mt", "start-mt.sh")).read()
    out = {}
    for k in ("POG_TEAM_LINE", "POG_GOAL", "POG_MAP_TEXT"):
        v = re.search(rf"^export {k}=(.*)$", text, re.M).group(1)
        out[k] = v[2:-1].replace("\\n", "\n") if v.startswith("$'") else v.strip("'\"")
    return out


def brief_and_new_run():
    tmp = tempfile.mkdtemp()
    try:
        copy_brief_tree(tmp)
        team = os.path.join(tmp, "team.txt")
        open(team, "w").write("haiku|Claude Haiku 5.5 (Claude Code)\nopus|Claude Opus 5.5 (Claude Code)\n")
        env = testsafe.env(POG_WS="haiku", POG_BOT="haiku", POG_BROKER="1", POG_SPACE_AGE="1", POG_TEAM=team,
                           POG_MODEL="Claude Haiku 5.5 (Claude Code)", POG_SEED="274274", POG_ENEMIES="normal", **mt_env())
        out = subprocess.run(["bash", os.path.join(tmp, "tools", "new-run.sh"), "mt9/blue", "imac2", "haiku", "30"],
                             env=env, capture_output=True, text=True, check=True).stdout.strip()
        assert out == os.path.join(tmp, "runs", "mt9", "blue", "haiku"), out
        fh = open(os.path.join(out, "fh")).read()
        sock = os.path.join(tmp, "runs", "mt9", "blue", ".sock", "haiku.sock")
        assert f'POG_FH_SOCKET="{sock}"' in fh and "POG_WORLD=imac2" in fh and "RCON_PASSWORD" not in fh, fh
        text = open(os.path.join(out, "AGENTS.md")).read()
        assert "You play cooperatively with 2 AI agents in all" in text and "share this world" not in text, text[:800]
        assert "- `opus`: Claude Opus 5.5 (Claude Code)" in text and "- `haiku`" not in text
        assert "a space platform of the team's reaching the solar system's edge, as soon as you can" in text
        assert "Space Age (with Quality and Elevated Rails), map settings\nmade for this run, normal enemies, seed 274274" in text, text[:400]
        assert "default map" not in text and "Shattered" not in text
        # PLAYBOOK's docs path from one folder deeper
        assert "`../../../../vendor/factorio-harness/docs/usage.md`" in text, re.findall(r"`[./]*vendor[^`]*`", text)
        # no word of a multi-team run or of other teams in anything the agent reads at launch
        words = re.compile(r"multi-?team|other teams?\b|\bopponents?\b|\brivals?\b|enem(y|ies) team|\bteam (red|blue|green|yellow)\b|\b(red|blue|green|yellow) team\b", re.I)
        for root, _, files in os.walk(out):
            for f in files:
                if f.endswith(".md"):
                    hit = words.search(open(os.path.join(root, f)).read())
                    assert not hit, (f, hit.group(0))
        # a one-team run is as before
        env1 = {k: v for k, v in env.items() if k not in mt_env()}
        out1 = subprocess.run(["bash", os.path.join(tmp, "tools", "new-run.sh"), "plain", "n", "haiku", "30"],
                              env=env1, capture_output=True, text=True, check=True).stdout.strip()
        t1 = open(os.path.join(out1, "AGENTS.md")).read()
        assert "2 AI agents share this world as one team" in t1 and "`../../../vendor/factorio-harness/docs/usage.md`" in t1
        assert "Shattered Planet" in t1 and "default map" in t1
    finally:
        shutil.rmtree(tmp)
    print("brief and new-run: ok")


def claude_settings():
    text = open(os.path.join(ROOT, "tools", "launch-agent.sh")).read()
    start = text.index("claude_settings() {")
    end = text.index("\nEOS\n}\n", start) + len("\nEOS\n}\n")
    body = text[start:end]
    tmp = tempfile.mkdtemp()
    try:
        runs = os.path.join(tmp, "runs")
        for d in ("shift91", "mt8/blue/haiku", "mt8/red/astra", "mt9/blue/haiku", "mt9/red", "mt9/op", "mt9/green/.keys"):
            os.makedirs(os.path.join(runs, d))
        open(os.path.join(runs, "mt9", "resumed-from"), "w").write("mt8\n")
        ws = os.path.join(runs, "mt9", "blue", "haiku")
        script = f'root={tmp!r} run=mt9/blue dir={ws!r} allow=\'"Read"\'\n{body}\nclaude_settings\n'
        subprocess.run(["bash", "-c", script], env=dict(os.environ, POG_BROKER="1", POG_BOT="haiku", POG_DENY_READ="/x/mt277 /x/op"), check=True)
        cfg = json.load(open(os.path.join(ws, ".claude", "settings.json")))
        assert "/x/mt277" in cfg["sandbox"]["filesystem"]["denyRead"] and "Read(//x/op/**)" in cfg["permissions"]["deny"], cfg
        deny_read, deny = cfg["sandbox"]["filesystem"]["denyRead"], cfg["permissions"]["deny"]
        for d in ("shift91", "mt9/red", "mt9/op", "mt9/green", "mt8/red", "mt9/green/.keys"):
            p = os.path.join(runs, d)
            assert p in deny_read and f"Read({p}/**)" in deny and f"Read(/{p}/**)" in deny, (d, deny_read)
        for d in ("mt9", "mt9/blue", "mt8", "mt8/blue"):
            p = os.path.join(runs, d)
            assert p not in deny_read and not any(f"({p}/**)" in x or f"(/{p}/**)" in x for x in deny), (d, deny_read)
        assert cfg["sandbox"]["network"]["allowUnixSockets"] == [os.path.join(runs, "mt9", "blue", ".sock", "haiku.sock")]
        # a one-team run: as before (the whole other run denied, its own folder readable)
        ws1 = os.path.join(runs, "shift91", "luna")
        os.makedirs(ws1)
        script = f'root={tmp!r} run=shift91 dir={ws1!r} allow=\'"Read"\'\n{body}\nclaude_settings\n'
        subprocess.run(["bash", "-c", script], env=dict(os.environ, POG_BROKER="1", POG_BOT="luna"), check=True)
        dr1 = json.load(open(os.path.join(ws1, ".claude", "settings.json")))["sandbox"]["filesystem"]["denyRead"]
        assert os.path.join(runs, "mt9") in dr1 and os.path.join(runs, "shift91") not in dr1, dr1
        assert 'label=${run//\\//-}' in text and 'name="pog-${POG_WS:-$world}-$label"' in text
        # POG_READ_SCOPE=1: the settings name only this tree's shared folders and this part (here and in the run it
        # resumes); no other part, run or POG_DENY_READ path (Claude Code shows the model these lists)
        for d in ("tools", "agent"):
            os.makedirs(os.path.join(tmp, d))
        allow = '"Read", "Grep", "Glob", "Edit(/**)", "Bash(./fh:*)"'
        script = f'root={tmp!r} run=mt9/blue dir={ws!r} allow={allow!r}\n{body}\nclaude_settings\n'
        subprocess.run(["bash", "-c", script], env=dict(os.environ, POG_BROKER="1", POG_BOT="haiku", POG_DENY_READ="/x/mt277 /x/op",
                                                     POG_READ_SCOPE="1"), check=True)
        raw = open(os.path.join(ws, ".claude", "settings.json")).read()
        cfg = json.loads(raw)
        fs, perms = cfg["sandbox"]["filesystem"], cfg["permissions"]
        home = os.path.expanduser("~")
        assert fs["denyRead"][:2] == [f"{home}/.config/pog", f"{home}/code"], fs
        want = [os.path.join(tmp, "agent"), os.path.join(tmp, "tools"), os.path.join(runs, "mt9", "blue"), os.path.join(runs, "mt8", "blue")]
        assert fs["allowRead"] == want, fs
        assert perms["allow"] == [f"Read(/{p}/**)" for p in want] + ["Edit(/**)", "Bash(./fh:*)"], perms["allow"]
        assert not any(w in raw for w in ("/red", "/green", "/op", "mt277", "shift91")), raw
        assert perms["deny"] == ["Read(~/.config/pog/**)", f"Read({home}/.config/pog/**)", "Edit(~/.config/pog/**)", f"Edit({home}/.config/pog/**)"], perms
        # Grok Build's allowlist (nosandbox) keeps the bare Read
        subprocess.run(["bash", "-c", script.replace("\nclaude_settings\n", "\nclaude_settings nosandbox\n")],
                       env=dict(os.environ, POG_BROKER="1", POG_BOT="haiku", POG_READ_SCOPE="1"), check=True)
        assert json.load(open(os.path.join(ws, ".claude", "settings.json")))["permissions"]["allow"][0] == "Read"
    finally:
        shutil.rmtree(tmp)
    print("claude settings: ok")


def grok_sandbox():
    import full_tools
    tmp = tempfile.mkdtemp()
    old = (full_tools.ROOT, dict(os.environ))
    try:
        full_tools.ROOT = tmp
        runs = os.path.join(tmp, "runs")
        for d in ("mt9/blue/grok", "mt9/blue/.keys", "mt9/red/.keys", "mt9/op", "shift91/.keys"):
            os.makedirs(os.path.join(runs, d))
        ws = os.path.join(runs, "mt9", "blue", "grok")
        os.environ.update(POG_BROKER="1", POG_GROK_SANDBOX="1", POG_DENY_READ="/x/op /x/mt276")
        os.environ.pop("POG_TEAM", None)
        full_tools.grok_sandbox(ws)
        toml = open(os.path.join(ws, ".grok-home", "sandbox.toml")).read()
        deny = json.loads(re.search(r"^deny = (.*)$", toml, re.M).group(1))
        for d in ("mt9/red", "mt9/op", "mt9/blue/.keys", "mt9/red/.keys", "shift91/.keys"):
            assert os.path.join(runs, d) in deny, (d, deny)
        assert os.path.join(runs, "mt9", "blue") not in deny and "/x/op" in deny and "/x/mt276" in deny, deny
    finally:
        full_tools.ROOT = old[0]
        os.environ.clear(); os.environ.update(old[1])
        shutil.rmtree(tmp)
    print("grok sandbox: ok")


def dry_run():
    tmp = tempfile.mkdtemp()
    try:
        qb = os.path.join(tmp, "brief.json")
        json.dump({"agents": []}, open(qb, "w"))
        env = testsafe.env(POG_DRY_RUN="1", POG_QUOTA_BRIEF=qb)
        sh = os.path.join(ROOT, "tools", "mt", "start-mt.sh")
        out = subprocess.run(["bash", sh, "mt9", "30", "agent/mt/teams-four.tsv"], env=env, capture_output=True, text=True, cwd=ROOT)
        assert out.returncode == 0, out.stderr
        for team, names in (("red", "astra sol terra"), ("blue", "opus sonnet haiku"), ("green", "argon gemini gemini2"),
                            ("yellow", "grok muse grok2")):
            assert re.search(rf"2\. team {team} \(force {team}\): {names} -> /\S+/runs/mt9/{team}/<name>", out.stdout), out.stdout
        assert "not asked: POG_TEST=1" in out.stdout and "web blocked: factorio.nickwinter.net youtube.com" in out.stdout, out.stdout
        assert f"reads denied: {ROOT} /Users/owner/code/pog-operator" in out.stdout, out.stdout
        out = subprocess.run(["bash", sh, "mt9", "30", "agent/mt/teams-four.tsv"], env=dict(env, POG_MT_TEAMS="blue,green"),
                             capture_output=True, text=True, cwd=ROOT)
        assert "team blue" in out.stdout and "team green" in out.stdout and "team red" not in out.stdout, out.stdout
        fresh = os.path.join(tmp, "baseline.zip")
        open(fresh, "wb").close()
        out = subprocess.run(["bash", sh, "mt9", "25"], env=dict(env, POG_MT_FRESH="1", POG_MT_FRESH_SAVE=fresh),
                             capture_output=True, text=True, cwd=ROOT)
        assert out.returncode == 0 and fresh in out.stdout, out.stderr
        assert all(f"team {t}" in out.stdout for t in ("green", "yellow", "blue")), out.stdout
        assert "team red" not in out.stdout and "claude-b" not in out.stdout, out.stdout
        out = subprocess.run(["bash", sh, "mt9", "25"], env=dict(env, POG_MT_FRESH="1", POG_RESUME="old"),
                             capture_output=True, text=True, cwd=ROOT)
        assert out.returncode == 64 and "conflicts" in out.stderr, out.stderr
        bad = os.path.join(tmp, "bad.tsv")
        open(bad, "w").write("red\tastra\tcodex\tcodex\tgpt-6-astra\tlow\tGPT-6 Astra\tCodex\nblue\tastra\tclaude\tx\ty\tlow\tL\tH\n")
        out = subprocess.run(["bash", sh, "mt9", "30", bad], env=env, capture_output=True, text=True, cwd=ROOT)
        assert out.returncode == 1 and "a name in two lines: astra" in out.stderr, out.stderr
        out = subprocess.run(["bash", sh, "a/b", "30"], env=env, capture_output=True, text=True, cwd=ROOT)
        assert out.returncode == 64, out.stderr
    finally:
        shutil.rmtree(tmp)
    print("dry run: ok")


def team_files():
    seen = {}
    for f in ("teams-four.tsv", "teams-smoke.tsv"):
        rows = [l.rstrip("\n").split("\t") for l in open(os.path.join(ROOT, "agent", "mt", f)) if l.strip() and not l.startswith("#")]
        assert all(len(r) == 8 for r in rows), f
        assert {r[0] for r in rows} == {"red", "blue", "green", "yellow"}, f
        assert all(r[2] in ("codex", "claude", "grok", "agy", "muse") for r in rows), f
        assert all(re.fullmatch(r"[a-z][a-z0-9_-]{0,15}", r[1]) for r in rows), f   # tools/fh_broker.py's bot names
        seen[f] = rows
    assert len(seen["teams-four.tsv"]) == 12 and len(seen["teams-smoke.tsv"]) == 4
    rows = [l.rstrip("\n").split("\t") for l in open(os.path.join(ROOT, "agent", "mt", "teams-test.tsv"))
            if l.strip() and not l.startswith("#")]
    assert len(rows) == 6 and len({r[0] for r in rows}) == 3
    assert [(r[1], r[2], r[3], r[4], r[5]) for r in rows[::2]] == [
        ("gemini", "agy", "agy", "gemini-3.8-flash-high", "-"),
        ("grok", "grok", "grok", "grok-4.7", "low"),
        ("muse", "muse", "muse", "muse-spark-1.3", "low")]
    # team_bots with a force: one table argument (control.lua's remote bot_create passes one), a mismatch named
    import team_bots

    class Rcon:
        def __init__(self, force):
            self.sent, self.force = [], force

        def command(self, cmd):
            self.sent.append(cmd)
            if '"bots"' in cmd:
                made = [{"name": "astra", "force": self.force, "alive": True}] if len(self.sent) > 1 else []
                return json.dumps({"ok": True, "tick": 1, "bots": made})
            return json.dumps({"ok": True, "tick": 1, "bot": {"name": "astra"}})
    r = Rcon("red")
    assert team_bots.ensure(r, ["astra"], "red")[-1].startswith("astra created"), r.sent
    assert 'remote.call("agent_harness","bot_create",{name="astra",force="red"})' in r.sent[1], r.sent
    r = Rcon("player")
    assert team_bots.ensure(r, ["astra"], "red")[-1] == "astra FORCE MISMATCH: wanted red, the bots row says player"
    print("team files: ok")


def web_block():
    import full_tools
    tmp = tempfile.mkdtemp()
    old = dict(os.environ)
    try:
        os.environ["POG_WEB_BLOCK"] = "factorio.nickwinter.net github.com"
        os.makedirs(os.path.join(tmp, ".claude"))
        json.dump({"sandbox": {"network": {}}, "permissions": {"deny": ["Read(x)"]}}, open(os.path.join(tmp, ".claude", "settings.json"), "w"))
        full_tools.web_block(tmp)
        cfg = json.load(open(os.path.join(tmp, ".claude", "settings.json")))
        assert cfg["permissions"]["deny"] == ["Read(x)", "WebSearch", "WebFetch(domain:factorio.nickwinter.net)", "WebFetch(domain:github.com)"], cfg
        # no allowed host for the shell: no host list in the sandbox (Claude Code shows it to the model)
        assert "deniedDomains" not in cfg["sandbox"]["network"], cfg
        json.dump({"sandbox": {"network": {"allowedDomains": ["pypi.org"]}}}, open(os.path.join(tmp, ".claude", "settings.json"), "w"))
        full_tools.web_block(tmp)
        net = json.load(open(os.path.join(tmp, ".claude", "settings.json")))["sandbox"]["network"]
        assert net["deniedDomains"] == ["factorio.nickwinter.net", "github.com"], net
        json.dump({"sandbox": {"network": {}}, "permissions": {"deny": ["Read(x)"]}}, open(os.path.join(tmp, ".claude", "settings.json"), "w"))
        full_tools.web_block(tmp)
        full_tools.web_block(tmp)
        assert len(json.load(open(os.path.join(tmp, ".claude", "settings.json")))["permissions"]["deny"]) == 4, "twice: no duplicates"
        assert "agy: search_web, read_url_content and browser_subagent off" in full_tools.web_state(tmp, "agy")
        assert full_tools.agy_agent(tmp) == "--agent main"
        md = open(os.path.join(tmp, ".agents", "agents", "main", "agent.md")).read()
        assert "tools:\n  - ask_question\n" in md and "run_command" in md and "search_web" not in md and "read_url" not in md, md
        assert json.loads(full_tools.AGY_WEB_OFF) == {"permissions": {"deny": ["read_url(*)", "execute_url(*)"]}}
        # POG_SHELL_NET=socket: Codex's profile allows the one socket, first line default_permissions, the proxy on
        import tomllib
        os.makedirs(os.path.join(tmp, ".codex"))
        open(os.path.join(tmp, ".codex", "config.toml"), "w").write('web_search = "disabled"\n[features]\nplugins = false\n[skills]\ninclude_instructions = false\n')
        full_tools.codex_socket_only(tmp, "/r/red/.sock/astra.sock")
        full_tools.codex_socket_only(tmp, "/r/red/.sock/astra.sock")   # twice: once
        raw = open(os.path.join(tmp, ".codex", "config.toml")).read()
        cfg = tomllib.loads(raw)
        assert cfg["default_permissions"] == "pog_socket" and cfg["features"] == {"network_proxy": True, "plugins": False}, cfg
        assert cfg["permissions"]["pog_socket"] == {"extends": ":workspace", "network": {"enabled": True, "unix_sockets": {"/r/red/.sock/astra.sock": "allow"}}}
        assert raw.count("default_permissions") == 1 and cfg["skills"] == {"include_instructions": False}
        os.environ["POG_SHELL_NET"] = "socket"
        assert "codex: web_search disabled; shell network: the broker socket only" in full_tools.web_state(tmp, "codex")
        del os.environ["POG_SHELL_NET"]
        la = open(os.path.join(ROOT, "tools", "launch-agent.sh")).read()
        assert '--dangerously-skip-permissions $agy_web --print-timeout' in la and 'codex-socket-only "$dir"' in la
        assert 'full_tools.py" agy-agent "$dir"' in la
        assert open(os.path.join(tmp, ".web-state")).read().startswith("codex: ")   # the last web_state call's
        assert full_tools.web_state(tmp, "codex").startswith("codex: web_search disabled; shell network open")
        # Codex's profile: search disabled (it takes an allowlist only), whatever POG_FULL_TOOLS says
        for full in ("0", "1"):
            d = os.path.join(tmp, "codex" + full)
            os.makedirs(d)
            subprocess.run([sys.executable, os.path.join(ROOT, "tools", "clean-profile.py"), "codex", d],
                           env=dict(os.environ, POG_FULL_TOOLS=full), check=True, capture_output=True)
            text = "".join(open(os.path.join(r, f)).read() for r, _, fs in os.walk(d) for f in fs if f.endswith(".toml"))
            assert 'web_search = "disabled"' in text and "live" not in text, text[:300]
        # Claude Code's tools and Grok's fetch (tools/profile-flags.sh)
        for env, want in (({}, True), ({"POG_WEB_BLOCK": "x.org"}, False)):
            base = {k: v for k, v in os.environ.items() if k != "POG_WEB_BLOCK"}
            out = subprocess.run(["bash", "-c", f'. {ROOT}/tools/profile-flags.sh; echo "$claude_tools|$grok_env"'],
                                 env=dict(base, POG_FULL_TOOLS="1", **env), capture_output=True, text=True, check=True).stdout
            assert ("WebSearch" in out.split("|")[0]) == want and ("GROK_WEB_FETCH=1" in out) == want and "WebFetch" in out, out
        assert "[toolset.web_search]\\nexcluded_domains = [" in open(os.path.join(ROOT, "tools", "grok-home.py")).read()
        la = open(os.path.join(ROOT, "tools", "launch-agent.sh")).read()
        assert la.count('full_tools.py" web-block "$dir"') == 2 and 'full_tools.py" muse-web-off' in la and 'full_tools.py" web-state' in la
    finally:
        os.environ.clear(); os.environ.update(old)
        shutil.rmtree(tmp)
    print("web block: ok")


def launch_tree():
    sh = os.path.join(ROOT, "tools", "mt", "launch-tree.sh")
    tmp = tempfile.mkdtemp()
    try:
        tree = os.path.join(tmp, "tree")
        r = subprocess.run(["bash", sh, os.path.join(ROOT, "x")], capture_output=True, text=True)
        assert r.returncode == 64, r.stderr
        os.makedirs(os.path.join(tmp, "other"))
        r = subprocess.run(["bash", sh, os.path.join(tmp, "other")], capture_output=True, text=True)
        assert r.returncode == 1 and "not a launch tree" in r.stderr, r.stderr
        out = subprocess.run(["bash", sh, tree], capture_output=True, text=True, check=True).stdout.strip()
        assert out == tree
        for gone in ("tools/mt", "agent/mt", "vendor/factorio-harness/mod", ".git", "tools/test_mt_launch.py", "tools/public_export.py"):
            assert not os.path.exists(os.path.join(tree, gone)), gone
        for kept in ("bin/fh", "tools/launch-agent.sh", "tools/new-run.sh", "agent/PLAYBOOK.md", "vendor/factorio-harness/dist/host/cli.js",
                     "vendor/factorio-harness/docs/usage.md", "tools/sleepcap/run"):
            assert os.path.exists(os.path.join(tree, kept)), kept
        r = subprocess.run(["bash", sh, "--scan", tree], capture_output=True, text=True)
        assert r.returncode == 0 and "clean" in r.stdout, r.stdout
        # a run's folder survives an update; a word naming the mode is found
        os.makedirs(os.path.join(tree, "runs", "r1", "red"))
        open(os.path.join(tree, "agent", "extra.md"), "w").write("the Multi-Team run\n")
        r = subprocess.run(["bash", sh, "--scan", tree], capture_output=True, text=True)
        assert r.returncode == 1 and "agent/extra.md" in r.stdout, r.stdout
        subprocess.run(["bash", sh, tree], capture_output=True, text=True, check=True)
        assert os.path.isdir(os.path.join(tree, "runs", "r1", "red")) and not os.path.exists(os.path.join(tree, "agent", "extra.md"))
    finally:
        shutil.rmtree(tmp)
    print("launch tree: ok")


def team_views():
    """F: reads as a team's force (pog.for_force, the stream harness's team field) and the operator's page per team."""
    import pog
    sys.path.insert(0, os.path.join(ROOT, "tools", "stream"))
    import harness
    assert pog.for_force(pog.SCORE_LUA, None) == pog.SCORE_LUA == pog.for_force(pog.SCORE_LUA, "player")
    red = pog.for_force(pog.SCORE_LUA + pog.CENSUS_FN + ' find{force = "player"}', "red")
    assert "game.forces.player" not in red and 'game.forces["red"]' in red and 'force = "red"' in red, red[-200:]
    assert 'operator = true, team = "red",' in red
    try:
        pog.for_force("x", 'red"..os')
        raise AssertionError("a force name with quotes must be refused")
    except ValueError:
        pass

    class R:
        sent = []

        def command(self, cmd):
            self.sent.append(cmd)
            return json.dumps({"ok": True, "tick": 5, "result": {}})
    h = harness.Harness.__new__(harness.Harness)
    h.world, h.team, h.lock, h.rcon = "imac2", "blue", __import__("threading").Lock(), R()
    h.operator_read("tells", {"since": 0})
    assert '"team": "blue"' in R.sent[-1], R.sent[-1]
    h.team = None
    h.operator_read("tells", {"since": 0})
    assert '"team"' not in R.sent[-1], R.sent[-1]
    assert harness.Harness.__init__.__code__.co_varnames[:3] == ("self", "world", "team")
    # the page: one column per team, its agents' force checked
    sys.path.insert(0, os.path.join(ROOT, "tools", "mt"))
    import team_views as tv
    tmp = tempfile.mkdtemp()
    try:
        op = os.path.join(tmp, "op")
        os.makedirs(os.path.join(op, "red"))
        os.makedirs(os.path.join(op, "blue"))
        open(os.path.join(op, "streams.txt"), "w").write("red http://127.0.0.1:8791/\n")
        open(os.path.join(op, "teams.tsv"), "w").write("# t\nred\tastra\tcodex\nblue\thaiku\tclaude\ngreen\tgemini\tagy\n")
        open(os.path.join(op, "red", "chat.jsonl"), "w").write(json.dumps({"from": "astra", "message": "iron <b>"}) + "\n")

        class Fake:
            def bots(self):
                return [{"name": "astra", "force": "red", "alive": True, "position": {"x": 1, "y": 2}},
                        {"name": "haiku", "force": "player", "alive": True, "position": {"x": 3, "y": 4}}]

            def op(self, action, args=None, team=None):
                return {"mt_contacts": {"contacts": []}, "board": {"items": [{"id": 1, "status": "open", "title": f"{team} item"}]},
                        "tells": {"tells": [{"from": "x", "to": ["y"], "text": "t"}]}}[action]

            def score(self, force):
                return {"tick": 9, "research_done": ["automation"], "entities": {"stone-furnace": 2}, "produced": {}}
        view = tv.collect(Fake(), op)
        assert [c["team"] for c in view["teams"]] == ["red", "blue"]
        assert view["teams"][0]["board"][0]["title"] == "red item" and view["teams"][1]["board"][0]["title"] == "blue item"
        text = tv.page(view)
        assert 'href="http://127.0.0.1:8791/">stream</a>' in text and text.count(">stream</a>") == 1
        assert "iron &lt;b&gt;" in text and "<b>force player</b>" in text and text.count("<section>") == 2, text[:300]
    finally:
        shutil.rmtree(tmp)
    # the camera's copy: a shot's folder name is the workspace, found in RUN/TEAM/WS (or RUN/WS), the one with ./shot
    import imac_cam
    tmp = tempfile.mkdtemp()
    try:
        for d in ("r/red/astra", "r/blue/haiku", "r/op"):
            os.makedirs(os.path.join(tmp, d))
        for d in ("r/red/astra", "r/blue/haiku"):
            open(os.path.join(tmp, d, "shot"), "w").close()
        assert imac_cam.workspace(os.path.join(tmp, "r"), "haiku") == os.path.join(tmp, "r", "blue", "haiku")
        assert imac_cam.workspace(os.path.join(tmp, "r"), "op") is None and imac_cam.workspace(os.path.join(tmp, "r"), "luna") is None
    finally:
        shutil.rmtree(tmp)
    print("team views: ok")


def client_mod():
    """mt282: the human clients' mod: six files, no harness module, no private name; a tampered copy fails the scan."""
    import zipfile
    tmp = tempfile.mkdtemp()
    try:
        r = subprocess.run([os.path.join(ROOT, "tools", "mt", "client_mod.sh"), tmp], capture_output=True, text=True)
        assert r.returncode == 0 and "scan: clean (6 files" in r.stdout, r.stdout + r.stderr
        z = zipfile.ZipFile(os.path.join(tmp, "agent-harness_0.1.0.zip"))
        names = sorted(n for n in z.namelist() if not n.endswith("/"))
        assert names == ["agent-harness_0.1.0/" + f for f in ("avatar_parts.lua", "control.lua", "data.lua", "graphics/avatar-parts.png",
                                                             "info.json", "runtime.lua")], names
        info = json.loads(z.read("agent-harness_0.1.0/info.json"))
        assert "? squeak-through-2" in info["dependencies"] and "base >= 2.1.24" in info["dependencies"] and info["factorio_version"] == "2.1", info
        assert b"--" not in z.read("agent-harness_0.1.0/control.lua").split(b"\n")[0], "comments dropped"
        bad = os.path.join(tmp, "bad.zip")
        with zipfile.ZipFile(bad, "w") as out:
            for n in z.namelist():
                data = z.read(n)
                if n.endswith("control.lua"):
                    data += b"\n-- multiteam\n"
                out.writestr(n, data)
        r = subprocess.run([os.path.join(ROOT, "tools", "mt", "client_mod.sh"), "--scan", bad], capture_output=True, text=True)
        assert r.returncode == 1 and "private names" in r.stdout, r.stdout
    finally:
        shutil.rmtree(tmp)
    print("client mod: ok")


def netgate():
    """mt284 X: the run's network gate: an allowlist match, a refused CONNECT (403, logged with its User-Agent), the
    config per Grok, Muse or agy agent, .web-state."""
    import socket, time
    sys.path.insert(0, os.path.join(ROOT, "tools", "mt"))
    import netgate as ng, full_tools
    assert ng.allowed("api.x.ai", ["api.x.ai"]) and ng.allowed("a.b.x.ai", ["*.x.ai"]) and not ng.allowed("factorio.nickwinter.net", ["*.x.ai"])
    tmp = tempfile.mkdtemp()
    try:
        tf = os.path.join(tmp, "team.tsv")
        open(tf, "w").write("# name\tkind\nastra\tcodex\tx\ngrok\tgrok\tx\nmuse\tmuse\tx\n")
        agents = full_tools.netgate_config([tf], os.path.join(tmp, "g.json"), os.path.join(tmp, "g.tsv"), base=18151)
        assert list(agents) == ["grok", "muse"] and agents["grok"]["port"] == 18151 and "api.x.ai" in agents["grok"]["allow"], agents
        log = os.path.join(tmp, "g.jsonl")
        p = subprocess.Popen([sys.executable, os.path.join(ROOT, "tools", "mt", "netgate.py"), os.path.join(tmp, "g.json"), log])
        try:
            for _ in range(50):
                try:
                    c = socket.create_connection(("127.0.0.1", 18151), timeout=1)
                    break
                except OSError:
                    time.sleep(0.1)
            c.sendall(b"CONNECT factorio.nickwinter.net:443 HTTP/1.1\r\nHost: factorio.nickwinter.net:443\r\nUser-Agent: curl/8.7.1\r\n\r\n")
            reply = c.recv(200)
            assert reply.startswith(b"HTTP/1.1 403"), reply
            time.sleep(0.2)
            rows = [json.loads(l) for l in open(log)]
            ref = [r for r in rows if r.get("passed") is False]
            assert ref and ref[0]["agent"] == "grok" and ref[0]["host"] == "factorio.nickwinter.net" and ref[0]["user_agent"] == "curl/8.7.1", rows
        finally:
            p.terminate()
        os.environ["POG_PROXY"] = "http://127.0.0.1:18151"
        assert "shell network through the run's gate" in full_tools.web_state(tmp, "grok")
        del os.environ["POG_PROXY"]
    finally:
        shutil.rmtree(tmp)
    print("netgate: ok")


if __name__ == "__main__":
    brief_and_new_run()
    claude_settings()
    grok_sandbox()
    dry_run()
    team_files()
    web_block()
    launch_tree()
    team_views()

    client_mod()

    netgate()
