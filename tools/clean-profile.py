#!/usr/bin/env python3
"""Keep the owner's personal CLI setup out of a game workspace: tools/clean-profile.py KIND DIR

Shake1 agents loaded personal skills, MCP connectors, plugins (one of them a guardrail hook that blocked a
queue_repeat), an output style and developer instructions addressed to the owner
(docs/studies/shake1-transcripts.md, 4.8). Each harness gets workspace-level overrides; nothing global changes.

  claude: merges into DIR/.claude/settings.json (run after tools/context.py setup, which also merges there)
  codex:  appends to DIR/.codex/config.toml (written by tools/context.py setup)
"""
import json
import os
import sys

HOME = os.path.expanduser("~")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLAUDE_PROFILES = [os.path.join(HOME, ".claude"), os.path.join(HOME, ".profiles/claude/account-b")]


def skill_names(skills_dir):
    names = set()
    if not os.path.isdir(skills_dir):
        return names
    for entry in os.listdir(skills_dir):
        md = os.path.join(skills_dir, entry, "SKILL.md")
        if not os.path.isfile(md):
            continue
        names.add(entry)
        for line in open(md, errors="replace").read().split("\n---", 1)[0].splitlines():
            if line.startswith("name:"):
                names.add(line.split(":", 1)[1].strip().strip("'\""))
    return names


def claude(d):
    path = os.path.join(d, ".claude", "settings.json")
    cfg = json.load(open(path)) if os.path.exists(path) else {}
    plugins, skills = {}, {}
    for prof in CLAUDE_PROFILES:
        try:
            user = json.load(open(os.path.join(prof, "settings.json")))
        except (OSError, ValueError):
            continue
        for name in user.get("enabledPlugins") or {}:
            plugins[name] = False
        for name in skill_names(os.path.join(prof, "skills")):
            skills[name] = "off"
    cfg.update({
        "outputStyle": "default",
        "disableClaudeAiConnectors": True,
        "disableBundledSkills": True,
        "enabledPlugins": plugins,
        "skillOverrides": skills,
    })
    # The launcher now passes --setting-sources project,local, so the route's user settings (hooks, plugins) no
    # longer load; keep the thinking behaviour they gave shake1 and shake2 so runs stay comparable.
    cfg["alwaysThinkingEnabled"] = True
    env = cfg.setdefault("env", {})
    # Long timed actions and wait_until need more than the 2-minute default Bash timeout.
    env.update({"BASH_DEFAULT_TIMEOUT_MS": "300000", "BASH_MAX_TIMEOUT_MS": "960000",
                "ENABLE_CLAUDEAI_MCP_SERVERS": "false", "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "0",
                "CLAUDE_CODE_ENABLE_CFC": "0", "CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING": "1"})
    # dontAsk denied loops over ./fh with shell variables (shake2: Haiku lost ~17 minutes); tools/permit.py approves
    # commands made only of game programs, loops and workspace redirects.
    permit = {"type": "command", "command": "python3 " + os.path.join(ROOT, "tools", "permit.py"), "timeout": 10}
    pre = cfg.setdefault("hooks", {}).setdefault("PreToolUse", [])
    if not any(permit["command"] == h.get("command") for g in pre for h in g.get("hooks", [])):
        pre.append({"matcher": "Bash", "hooks": [permit]})
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)


def codex(d):
    path = os.path.join(d, ".codex", "config.toml")
    text = open(path).read() if os.path.exists(path) else ""
    if "# clean-profile" in text:
        return
    # Top-level keys first: tools/context.py writes only top-level keys, so the table can follow.
    # Shake2 still showed the owner's skills list (rooted at ~/.agents/skills, plus OpenAI's bundled plugin skills) and
    # a multi-agent role block in every request: turn off host skill discovery, plugins, apps and browser/computer use
    # (feature names from `codex features list`, codex-cli 0.162.1).
    text += ('# clean-profile: no personal developer instructions, skills, plugins or multi-agent roles; readable '
             'reasoning summaries\n'
             'developer_instructions = ""\n'
             'model_reasoning_summary = "concise"\n'
             '[features]\n'
             'multi_agent = false\n'
             'multi_agent_v2 = false\n'
             'skip_host_skill_discovery = true\n'
             'skill_search = false\n'
             'plugins = false\n'
             'apps = false\n'
             'browser_use = false\n'
             'in_app_browser = false\n'
             'computer_use = false\n')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def muse(d):
    """Print a `-c hooks=...` launch option: the owner's Muse hooks without the personal tooling-context hook.

    ~/.config/muse/settings.json has SessionStart hooks `herdr-session record muse` (lets Herdr and so the supervisor
    see Muse's state) and `native-agent-tooling context muse` (injects the owner's shared tooling rules; shake2).
    The workspace's own .muse/hooks.json (tools/context.py) is a separate file and stays as it is."""
    import shlex
    try:
        hooks = json.load(open(os.path.join(HOME, ".config", "muse", "settings.json"))).get("hooks") or {}
    except (OSError, ValueError):
        return
    kept = {}
    for event, groups in hooks.items():
        out = []
        for g in groups:
            hs = [dict(h, command=h.get("command", "").replace("$HOME", HOME)) for h in g.get("hooks", [])
                  if "native-agent-tooling" not in h.get("command", "")]
            if hs:
                out.append(dict(g, hooks=hs))
        if out:
            kept[event] = out
    if kept != hooks:
        print("-c " + shlex.quote("hooks=" + json.dumps(kept, separators=(",", ":"))))


if __name__ == "__main__":
    kind, d = sys.argv[1], sys.argv[2]
    {"claude": claude, "codex": codex, "muse": muse}[kind](d)
