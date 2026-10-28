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
        assert "You play in a team of 2 AI agents" in text and "share this world" not in text, text[:800]
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
        assert cfg["sandbox"]["network"]["deniedDomains"] == ["factorio.nickwinter.net", "github.com"], cfg
        full_tools.web_block(tmp)
        assert len(json.load(open(os.path.join(tmp, ".claude", "settings.json")))["permissions"]["deny"]) == 4, "twice: no duplicates"
        assert "agy: search_web, read_url_content and browser_subagent on" in full_tools.web_state(tmp, "agy")
        assert open(os.path.join(tmp, ".web-state")).read().startswith("agy: ")
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


if __name__ == "__main__":
    brief_and_new_run()
    claude_settings()
    grok_sandbox()
    dry_run()
    team_files()
    web_block()
    launch_tree()
