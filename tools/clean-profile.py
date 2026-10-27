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
    # Shake3: the route attached its git status and recent commits at start and after each compaction.
    cfg["includeGitInstructions"] = False
    # (d27 batch275 HW) Claude Code's auto memory is the route's memory for the repository root: every Claude agent loaded
    # its 10 KB index of the harness engineers' and operator's notes at the start and after each compaction (Haiku 14
    # times in shift86), and could write there; notes.md is the agents' memory. Off, by setting and by environment.
    cfg["autoMemoryEnabled"] = False
    # (d27 batch275 HW) thinking is kept in the transcript as a summary (all 1,086 thinking blocks of Opus, Sonnet and
    # Haiku in shifts 80-86 were empty), as Codex keeps its reasoning summaries, for the shift studies.
    cfg["showThinkingSummaries"] = True
    env = cfg.setdefault("env", {})
    # Long timed actions, wait_until and fh sleep need more than the 2-minute default Bash timeout. A 900 s
    # `fh sleep` may take up to 1135 s of real time on a slow server (cli.ts: seconds x 1.25 + 10); past the timeout
    # Claude Code moves the call to the background, where it outlives the turn (sleep study, shake6 Opus at 300 s).
    env.update({"BASH_DEFAULT_TIMEOUT_MS": "1200000", "BASH_MAX_TIMEOUT_MS": "1200000",
                "ENABLE_CLAUDEAI_MCP_SERVERS": "false", "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "0",
                "CLAUDE_CODE_ENABLE_CFC": "0", "CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING": "1",
                # "The user hasn't heard from you in a while" (shake3: Opus 36, Sonnet 29); also on the launch line.
                "CLAUDE_CODE_SILENT_TURN_REMINDER": "0", "CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS": "1",
                "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"})
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
    # POG_FULL_TOOLS=1 (tools/full_tools.py): live web search, the multi-agent tools (spawn_agent and the rest) and the
    # run's shared team-tools folder writable; view_image is on either way.
    full = os.environ.get("POG_FULL_TOOLS") == "1"
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from full_tools import subagents_off
    sub = full and os.path.basename(os.path.abspath(d)) not in subagents_off()   # agent/subagents-off.txt
    text += ('# clean-profile: no personal developer instructions, skills, plugins or multi-agent roles; readable '
             'reasoning summaries\n'
             'developer_instructions = ""\n'
             'model_reasoning_summary = "concise"\n'
             + ('web_search = "live"\n' if full else '') +
             '[features]\n'
             f'multi_agent = {"true" if sub else "false"}\n'
             'skip_host_skill_discovery = true\n'
             'skill_search = false\n'
             'plugins = false\n'
             'apps = false\n'
             'browser_use = false\n'
             'in_app_browser = false\n'
             'computer_use = false\n'
             # Shake3 still had <multi_agent_role> (2,400 characters) and its <multi_agent_mode> revocation with
             # multi_agent_v2 = false. Probes: the feature's empty hint texts remove both; enabled and
             # usage_hint_enabled alone do not.
             '[features.multi_agent_v2]\n'
             'enabled = false\n'
             'usage_hint_enabled = false\n'
             'root_agent_usage_hint_text = ""\n'
             'multi_agent_mode_hint_text = ""\n'
             # Shake3 still had the 5.4K-character <skills_instructions> block (the owner's ~/.agents/skills and the
             # route's .system skills): the [skills] table turns off the list and the bundled skills.
             '[skills]\n'
             'include_instructions = false\n'
             '[skills.bundled]\n'
             'enabled = false\n')
    if full:
        shared = os.path.join(os.path.dirname(os.path.abspath(d)), "team-tools")
        text += f'[sandbox_workspace_write]\nnetwork_access = true\nwritable_roots = [{json.dumps(shared)}]\n'
        # smoke-ft: Luna's subagent ran no command and answered "describe.json was not present" with 18 output tokens
        # and no reasoning. Subagents get their own effort (codex-cli 0.162.1 [agents]), medium unless set.
        effort = os.environ.get("POG_SUBAGENT_EFFORT", "medium")
        text += f'[agents]\ndefault_subagent_reasoning_effort = {json.dumps(effort)}\n'
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def muse(d):
    """Print the `-c hooks={}` launch option: none of the owner's Muse hooks from ~/.config/muse/settings.json.

    Round 3 kept its `herdr-session record muse` hooks (SessionStart, Stop) and dropped `native-agent-tooling context
    muse`; shake3 still ran the herdr ones, which only record the session for the owner's resume tools (Herdr has no
    Muse agent kind; the supervisor types into the pane). The workspace's .muse/hooks.json (tools/context.py) is a
    separate file and still loads."""
    print("-c 'hooks={}'")


if __name__ == "__main__":
    kind, d = sys.argv[1], sys.argv[2]
    {"claude": claude, "codex": codex, "muse": muse}[kind](d)
