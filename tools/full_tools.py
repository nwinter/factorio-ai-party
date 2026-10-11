#!/usr/bin/env python3
"""Full engineer tools for a game workspace, behind POG_FULL_TOOLS=1 (docs/TOOLS-NOTES.md):
tools/full_tools.py workspace DIR KIND | claude DIR | grok-args DIR | paragraph KIND

  workspace: DIR/tools/ (the agent's own scripts), DIR/team-tools -> ../team-tools (shared with the run's other
             agents), DIR/gamedata/ (a read-only copy of the prototype dump in tools/analyst/kb: recipes, items,
             entities, fluids, technologies, locations) and the "Your tools" paragraph for KIND in AGENTS.md.
  claude:    merges into DIR/.claude/settings.json: subagents, web search and fetch, background-job tools allowed;
             the sandbox may write team-tools; other agents' workspaces are unreadable except their notes.md.

  grok-args: Grok Build's --allow/--deny words for the same two things.

Codex and Grok switches live where their clean profiles are written (tools/clean-profile.py, tools/grok-home.py,
tools/profile-flags.sh); agy and Muse Code already have their subagent and web tools.
No tool here reads or writes the game: only ./fh acts in it.
"""
import json
import os
import shutil
import stat
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KB = os.path.join(ROOT, "tools", "analyst", "kb")
# Prototype facts only: settings.json is the map settings of the world the dump came from, not this world's.
GAMEDATA = ["recipes", "items", "entities", "fluids", "technologies", "locations"]
# Claude Code tools on top of the game set (Bash, Read, Edit, Write, Grep, Glob); the --tools list is in
# tools/profile-flags.sh ($claude_tools_full).
CLAUDE_EXTRA = ["Agent", "WebSearch", "WebFetch", "TaskStop", "Monitor"]
# What in another agent's workspace is theirs (its notes.md is readable to teammates, agent/team.md): every folder,
# and these top-level files. The sandbox takes literal paths, so the folders are listed too.
PRIVATE_FILES = ["journal.jsonl", "context.log", "describe.json", "grok-start.log", ".agy-loop.sh", ".muse-run.sh",
                 ".grok-run.sh"]
PRIVATE_DIRS = ["tools", "shots", ".claude", ".codex", ".grok-home", ".muse"]


def on():
    return os.environ.get("POG_FULL_TOOLS") == "1"


def kb_version():
    return os.environ.get("POG_KB") or ("space-age-2.0.77" if os.environ.get("POG_SPACE_AGE") == "1" else "base-2.0.77")


def paragraph(kind):
    """The "Your tools" text for AGENTS.md: what the agent has, not what to do with it."""
    text = open(os.path.join(ROOT, "agent", "full-tools.md")).read()
    lines = {}
    for line in text.split("<!-- harness -->", 1)[1].strip().splitlines():
        k, _, v = line.partition(":")
        lines[k.strip()] = v.strip()
    return text.split("<!-- harness -->", 1)[0].replace("{{HARNESS}}", lines.get(kind, "")).replace(
        "{{KB}}", kb_version()).rstrip("\n").replace("\n\n\n", "\n\n") + "\n"


def workspace(d, kind):
    os.makedirs(os.path.join(d, "tools"), exist_ok=True)
    shared = os.path.join(os.path.dirname(d), "team-tools")
    os.makedirs(shared, exist_ok=True)
    link = os.path.join(d, "team-tools")
    if not os.path.lexists(link):
        os.symlink("../team-tools", link)
    data = os.path.join(d, "gamedata")
    if os.path.isdir(data):   # a relaunch into the same workspace: make it writable again to refresh it
        for f in os.listdir(data):
            os.chmod(os.path.join(data, f), 0o644)
        os.chmod(data, 0o755)
    os.makedirs(data, exist_ok=True)
    src = os.path.join(KB, kb_version())
    for name in GAMEDATA:
        if os.path.exists(os.path.join(src, name + ".json")):
            shutil.copyfile(os.path.join(src, name + ".json"), os.path.join(data, name + ".json"))
    for f in os.listdir(data):
        os.chmod(os.path.join(data, f), stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH)
    os.chmod(data, 0o555)
    path = os.path.join(d, "AGENTS.md")
    text = open(path).read()
    if "## Your tools" not in text:
        add = paragraph(kind).rstrip("\n") + "\n\n"
        i = text.find("## Compact instructions")
        text = text[:i] + add + text[i:] if i >= 0 else text.rstrip("\n") + "\n\n" + add
        open(path, "w").write(text)


def others(d):
    """The other workspaces of this run: sibling folders, plus the team file's names (POG_TEAM) not yet created."""
    run, me = os.path.dirname(d), os.path.basename(d)
    names = {n for n in os.listdir(run) if os.path.isdir(os.path.join(run, n)) and not n.startswith(".")}
    team = os.environ.get("POG_TEAM")
    if team and os.path.exists(team):
        names |= {l.split("|", 1)[0].strip() for l in open(team) if l.strip()}
    return [os.path.join(run, n) for n in sorted(names - {me, "team-tools"})]


def claude(d):
    path = os.path.join(d, ".claude", "settings.json")
    cfg = json.load(open(path))
    perms = cfg.setdefault("permissions", {})
    allow = perms.setdefault("allow", [])
    allow += [t for t in CLAUDE_EXTRA if t not in allow]
    shared = os.path.join(os.path.dirname(d), "team-tools")
    # Absolute paths: Claude Code reads "//path" (a single "/" is relative to the workspace), Grok Build "/path".
    for tool in ("Edit", "Write"):
        for p in ("/" + shared, shared):
            if f"{tool}({p}/**)" not in allow:
                allow.append(f"{tool}({p}/**)")
    # Other agents' workspaces: notes.md stays readable (agent/team.md), the rest is theirs. The Read rules cover
    # Read, Grep and Glob (deny wins over allow, so they name what is private rather than the whole folder); the
    # sandbox's denyRead covers Bash. Grok reads the same rules but runs unsandboxed.
    deny = perms.setdefault("deny", [])
    for o in others(d):
        for p in ("/" + o, o):
            for rule in [f"Read({p}/{s})" for s in PRIVATE_FILES] + [f"Read({p}/*/**)", f"Edit({p}/**)"]:
                if rule not in deny:
                    deny.append(rule)
    sandbox = cfg.get("sandbox")
    if sandbox is not None:
        fs = sandbox.setdefault("filesystem", {})
        if shared not in fs.setdefault("allowWrite", []):
            fs["allowWrite"].append(shared)
        dr = fs.setdefault("denyRead", [])
        for o in others(d):
            for sub in PRIVATE_FILES + PRIVATE_DIRS:
                if os.path.join(o, sub) not in dr:
                    dr.append(os.path.join(o, sub))
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)


def grok_args(d):
    """Grok Build's --allow/--deny words: team-tools writable, other workspaces' private files unreadable. Grok runs
    without a sandbox; its deny rules also cover paths that shell commands such as cat touch (docs
    22-permissions-and-safety.md), enforced by Grok rather than the kernel."""
    shared = os.path.join(os.path.dirname(d), "team-tools")
    words = [f"--allow 'Edit({shared}/**)'", f"--allow 'Write({shared}/**)'"]
    for o in others(d):
        words += [f"--deny 'Read({o}/{s})'" for s in PRIVATE_FILES]
        words += [f"--deny 'Read({o}/{s}/**)'" for s in PRIVATE_DIRS]
    return " ".join(words)


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "workspace":
        workspace(sys.argv[2], sys.argv[3])
    elif cmd == "claude":
        claude(sys.argv[2])
    elif cmd == "grok-args":
        print(grok_args(sys.argv[2]))
    elif cmd == "paragraph":
        print(paragraph(sys.argv[2]), end="")
    else:
        sys.exit(f"unknown command {cmd}")
