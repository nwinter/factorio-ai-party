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
    env = cfg.setdefault("env", {})
    # Long timed actions and wait_until need more than the 2-minute default Bash timeout.
    env.update({"BASH_DEFAULT_TIMEOUT_MS": "300000", "BASH_MAX_TIMEOUT_MS": "960000",
                "ENABLE_CLAUDEAI_MCP_SERVERS": "false", "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "0",
                "CLAUDE_CODE_ENABLE_CFC": "0"})
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)


def codex(d):
    path = os.path.join(d, ".codex", "config.toml")
    text = open(path).read() if os.path.exists(path) else ""
    if "# clean-profile" in text:
        return
    # Top-level keys first: tools/context.py writes only top-level keys, so the table can follow.
    text += ('# clean-profile: no personal developer instructions or multi-agent roles; readable reasoning summaries\n'
             'developer_instructions = ""\n'
             'model_reasoning_summary = "concise"\n'
             '[features]\n'
             'multi_agent = false\n')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


if __name__ == "__main__":
    kind, d = sys.argv[1], sys.argv[2]
    {"claude": claude, "codex": codex}[kind](d)
