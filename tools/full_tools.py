#!/usr/bin/env python3
"""Full engineer tools for a game workspace, behind POG_FULL_TOOLS=1 (docs/TOOLS-NOTES.md):
tools/full_tools.py workspace DIR KIND | claude DIR | grok-args DIR | paragraph KIND

  workspace: DIR/tools/ (the agent's own scripts), DIR/team-tools -> ../team-tools (shared with the run's other
             agents), DIR/gamedata/ (a read-only copy of the prototype dump in tools/analyst/kb: recipes, items,
             entities, fluids, technologies, locations, qualities, and asteroids from a Space Age dump) and the "Your tools"
             paragraph for KIND in AGENTS.md.
  claude:    merges into DIR/.claude/settings.json: subagents, web search and fetch, background-job tools allowed;
             the sandbox may write team-tools; other agents' workspaces are unreadable except their notes.md.

  grok-args: Grok Build's --allow/--deny words for the same two things, and its kernel sandbox profile.
  sync:      tools/full_tools.py sync RUN_DIR [SECONDS]: mirror Muse's own team-tools folder with the shared one.
  carry:     tools/full_tools.py carry [--dry-run] RUN_DIR PREV_DIR NAME...: a later shift (tools/start-team.sh,
             POG_RESUME) starts with each agent's tools/ and the run's team-tools/ from the previous shift that had
             them, up the resumed-from chain; files over 5 MB, caches, dotfiles and symlinks stay behind. Each file is
             a clone on APFS (macOS clonefile: no new blocks until one side is written), else a copy (shutil.copy2).

Codex and Grok switches live where their clean profiles are written (tools/clean-profile.py, tools/grok-home.py,
tools/profile-flags.sh); agy and Muse Code already have their subagent and web tools.
No tool here reads or writes the game: only ./fh acts in it.
"""
import ctypes
import ctypes.util
import errno
import glob
import json
import os
import re
import shutil
import stat
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KB = os.path.join(ROOT, "tools", "analyst", "kb")
# Prototype facts only: settings.json is the map settings of the world the dump came from, not this world's.
# asteroids: Space Age dumps only (each route's and orbit's asteroid spawns, the asteroids' health and resistances).
GAMEDATA = ["recipes", "items", "entities", "fluids", "technologies", "locations", "asteroids", "qualities"]
# Claude Code tools on top of the game set (Bash, Read, Edit, Write, Grep, Glob); the --tools list is in
# tools/profile-flags.sh ($claude_tools_full).
CLAUDE_EXTRA = ["Agent", "WebSearch", "WebFetch", "TaskStop", "Monitor"]
# What in another agent's workspace is theirs (its notes.md is readable to teammates, agent/team.md): every folder,
# and these top-level files. The sandbox takes literal paths, so the folders are listed too.
PRIVATE_FILES = ["journal.jsonl", "context.log", "describe.json", "grok-start.log", ".agy-loop.sh", ".muse-run.sh",
                 ".grok-run.sh"]
PRIVATE_DIRS = ["tools", "shots", ".claude", ".codex", ".grok-home", ".muse"]
# smoke-ft: Muse's sandbox refused writes through the team-tools symlink ("path escapes workspace"; the profile
# setting for an extra writable folder is undocumented). Its team-tools is a real folder that `sync` mirrors.
MIRRORED = {"muse"}
# Agents whose subagents are off (one name per line; codex only so far: tools/clean-profile.py turns multi_agent off and
# the "Your tools" paragraph uses the harness's "-nosub" line). 2026-10-15: Astra's four subagents used 104M of
# its 153M input tokens in shift18, and personal Codex would have run out that night (operator default, 15:30).
SUBAGENTS_OFF = os.environ.get("POG_SUBAGENTS_OFF_FILE") or os.path.join(ROOT, "agent", "subagents-off.txt")


def subagents_off():
    try:
        return {l.split("#")[0].strip() for l in open(SUBAGENTS_OFF)} - {""}
    except OSError:
        return set()


def sync_pair(a, b):
    """Copy each file that is missing or older on one side from the other (by mtime); never deletes. Returns the
    copied paths, relative to the folders."""
    copied = []
    names = set()
    for top in (a, b):
        for base, dirs, files in os.walk(top):
            dirs[:] = [x for x in dirs if not x.startswith(".")]
            names |= {os.path.relpath(os.path.join(base, f), top) for f in files if not f.startswith(".")}
    for rel in sorted(names):
        pa, pb = os.path.join(a, rel), os.path.join(b, rel)
        ta = os.path.getmtime(pa) if os.path.isfile(pa) else None
        tb = os.path.getmtime(pb) if os.path.isfile(pb) else None
        if ta is not None and (tb is None or ta > tb + 0.5):
            src, dst = pa, pb
        elif tb is not None and (ta is None or tb > ta + 0.5):
            src, dst = pb, pa
        else:
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)
        copied.append(rel)
    return copied


def sync(run):
    """Mirror each workspace's real team-tools folder (MIRRORED harnesses) with the run's shared one."""
    shared, out = os.path.join(run, "team-tools"), []
    for ws in sorted(glob.glob(os.path.join(run, "*", "team-tools"))):
        if os.path.isdir(ws) and not os.path.islink(ws):
            out += [f"{os.path.basename(os.path.dirname(ws))}: {r}" for r in sync_pair(shared, ws)]
    return out


# carry: agents' own folders go forward from shift to shift (Opus, 2026-10-13 22:59: "copied by hand every shift").
CARRY_MAX_BYTES = 5 * 1024 * 1024
CARRY_HOPS = 5   # as tools/start-team.sh's notes walk
CACHE_DIRS = {"__pycache__", "node_modules", "venv"}   # and every dot folder (.venv, .pytest_cache, .cache, ...)
CACHE_EXT = (".pyc", ".pyo")


def chain(prev):
    """PREV and the runs before it, by each run's resumed-from (siblings in the same runs folder)."""
    out = [prev]
    while len(out) <= CARRY_HOPS:
        f = os.path.join(out[-1], "resumed-from")
        if not os.path.isfile(f):
            break
        up = open(f).readline().strip()
        d = os.path.join(os.path.dirname(out[-1]), up)
        if not up or not os.path.isdir(d) or d in out:
            break
        out.append(d)
    return out


# (d20 batch84 AT1, Disk Space Scout: runs/ 15.1 GiB, Sol's tools/ 223 MB copied every shift) macOS clonefile(2):
# the new file shares the source's blocks until either is written. None off macOS or where libSystem lacks it.
_CLONEFILE = None


def _clonefile():
    global _CLONEFILE
    if _CLONEFILE is None:
        fn = False
        if sys.platform == "darwin":
            try:
                lib = ctypes.CDLL(ctypes.util.find_library("System") or "/usr/lib/libSystem.B.dylib", use_errno=True)
                fn = lib.clonefile
                fn.argtypes, fn.restype = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32], ctypes.c_int
            except (OSError, AttributeError):
                fn = False
        _CLONEFILE = fn
    return _CLONEFILE or None


CLONE_NOFOLLOW = 0x0001


def clone_file(src, dst):
    """Clone src to dst (a new path) with clonefile, then its mode and times as shutil.copy2 sets them. Raises OSError
    when the clone fails (another volume, a file system without clones, not macOS)."""
    fn = _clonefile()
    if not fn:
        raise OSError(errno.ENOTSUP, "clonefile is not available here")
    if fn(os.fsencode(src), os.fsencode(dst), CLONE_NOFOLLOW) != 0:
        e = ctypes.get_errno()
        raise OSError(e, os.strerror(e), dst)
    shutil.copystat(src, dst)


def place_file(src, dst, how):
    """A clone of src at dst, else a copy (shutil.copy2: mode and mtime kept); counts each in how."""
    try:
        clone_file(src, dst)
        how["cloned"] = how.get("cloned", 0) + 1
    except OSError:
        if os.path.lexists(dst):   # a clone that failed after creating dst
            os.remove(dst)
        shutil.copy2(src, dst)
        how["copied"] = how.get("copied", 0) + 1


def copy_tree(src, dst, dry=False, how=None):
    """Copy src into dst without replacing files dst has, each file a clone where the volume clones (how counts
    cloned and copied). Returns (copied paths, bytes, skipped {reason: [paths]})."""
    how = {} if how is None else how
    copied, size, skipped = [], 0, {}
    for base, dirs, files in os.walk(src):
        keep = []
        for x in sorted(dirs):
            rel = os.path.relpath(os.path.join(base, x), src)
            if os.path.islink(os.path.join(base, x)):
                skipped.setdefault("symlink", []).append(rel + "/")
            elif x.startswith(".") or x in CACHE_DIRS:
                skipped.setdefault("cache", []).append(rel + "/")
            else:
                keep.append(x)
        dirs[:] = keep
        for f in sorted(files):
            p = os.path.join(base, f)
            rel = os.path.relpath(p, src)
            if os.path.islink(p):
                skipped.setdefault("symlink", []).append(rel)
            elif f.startswith(".") or f.endswith(CACHE_EXT):
                skipped.setdefault("cache", []).append(rel)
            elif not os.path.isfile(p):
                skipped.setdefault("not a file", []).append(rel)
            elif os.path.getsize(p) > CARRY_MAX_BYTES:
                skipped.setdefault("over 5 MB", []).append(f"{rel} ({os.path.getsize(p) / 1048576:.1f} MB)")
            elif os.path.lexists(os.path.join(dst, rel)):
                skipped.setdefault("already there", []).append(rel)
            else:
                if not dry:
                    os.makedirs(os.path.dirname(os.path.join(dst, rel)), exist_ok=True)
                    place_file(p, os.path.join(dst, rel), how)   # keeps the mode (executable scripts) and mtime
                copied.append(rel)
                size += os.path.getsize(p)
    return copied, size, skipped


def carry(run, prev, names, dry=False):
    """Copy each agent's tools/ and the shared team-tools/ from the newest run up PREV's resumed-from chain that has the
    folder (a shift whose agents never launched has none). Returns (start.log lines, copied paths)."""
    runs = chain(prev)
    lines, listing = [], []

    def one(label, rel_src, dst, extra=()):
        for r in runs:
            if os.path.isdir(os.path.join(r, rel_src)):
                break
        else:
            lines.append(f"carry {label}: none in {', '.join(os.path.basename(r) for r in runs)}")
            return
        how = {}
        copied, size, skipped = copy_tree(os.path.join(r, rel_src), dst, dry, how)
        listing.extend(f"{label}\t{os.path.basename(r)}\t{p}" for p in copied)
        for e in extra:   # Muse's own mirrored team-tools folder in that run: what the 5 s mirror had not yet shared
            c, s, k = copy_tree(os.path.join(r, e), dst, dry, how)
            copied += c
            size += s
            listing.extend(f"{label}\t{os.path.basename(r)}/{os.path.dirname(e)}\t{p}" for p in c)
            for why, ps in k.items():
                if why != "already there":
                    skipped.setdefault(why, []).extend(ps)
        skip = "; ".join(f"skipped {len(ps)} {why}: {', '.join(ps[:6])}{' ...' if len(ps) > 6 else ''}"
                         for why, ps in sorted(skipped.items()))
        n = len(copied)
        made = (f" ({how.get('cloned', 0)} cloned, {how.get('copied', 0)} copied)" if n and not dry else "")
        lines.append(f"carry {label}: {n} file{'' if n == 1 else 's'} ({size / 1048576:.1f} MB) from {os.path.basename(r)}"
                     + made + (f"; {skip}" if skip else ""))

    for name in names:
        one(f"{name} tools/", os.path.join(name, "tools"), os.path.join(run, name, "tools"))
    for r in runs:   # the run that has team-tools/ also holds any mirrored copies
        if os.path.isdir(os.path.join(r, "team-tools")):
            mirrors = [os.path.relpath(m, r) for m in sorted(glob.glob(os.path.join(r, "*", "team-tools")))
                       if os.path.isdir(m) and not os.path.islink(m)]
            break
    else:
        mirrors = []
    one("team-tools/", "team-tools", os.path.join(run, "team-tools"), mirrors)
    return lines, listing


def on():
    return os.environ.get("POG_FULL_TOOLS") == "1"


def kb_version():
    return os.environ.get("POG_KB") or ("space-age-2.0.77" if os.environ.get("POG_SPACE_AGE") == "1" else "base-2.0.77")


def heading(path):
    """A file's first Markdown heading, else its first line, at most 80 characters."""
    try:
        lines = [l.strip() for l in open(path, errors="replace").read(4000).splitlines() if l.strip()]
    except OSError:
        return ""
    first = next((l for l in lines if l.startswith("#")), lines[0] if lines else "")
    return first.lstrip("#").strip()[:80]


def writer(path):
    """The writer a file names in its first 5 lines ("Written by X", "Author: X", "By X"), else None."""
    try:
        head = "\n".join(open(path, errors="replace").read(4000).splitlines()[:5])
    except OSError:
        return None
    m = re.search(r"(?i)\b(?:written by|author:|authors?:|by)\s+([A-Za-z][\w-]*)", head)
    return m.group(1) if m else None


def team_files(shared):
    """(d19 batch41 C1, Astra seq 866, Sol seq 867: handoff links to the team's knowledge files were forgotten) the facts
    AGENTS.md gives on team-tools/README.md and the newest knowledge-index*.md (by last change) when they exist: what each
    is (its heading) and who wrote it (as the file says; the harness records no writer)."""
    if not shared or not os.path.isdir(shared):
        return ""
    names = ["README.md"] if os.path.isfile(os.path.join(shared, "README.md")) else []
    idx = sorted(glob.glob(os.path.join(shared, "knowledge-index*.md")), key=lambda p: (os.path.getmtime(p), p))
    if idx:
        names.append(os.path.basename(idx[-1]))
    parts = []
    for n in names:
        p = os.path.join(shared, n)
        h, w = heading(p), writer(p)
        what = "; ".join(x for x in (f'"{h}"' if h else "", f"by {w}" if w else "no writer named") if x)
        parts.append(("the newest knowledge index, " if n != "README.md" else "") + f"`{n}` ({what})")
    if not parts:
        return ""
    return "\n  It holds " + " and ".join(parts) + "."


def paragraph(kind, name=None, shared=None):
    """The "Your tools" text for AGENTS.md: what the agent has, not what to do with it. shared: the run's team-tools."""
    text = open(os.path.join(ROOT, "agent", "full-tools.md")).read()
    lines = {}
    for line in text.split("<!-- harness -->", 1)[1].strip().splitlines():
        k, _, v = line.partition(":")
        lines[k.strip()] = v.strip()
    line = lines.get(kind + "-nosub", lines.get(kind, "")) if name in subagents_off() else lines.get(kind, "")
    return text.split("<!-- harness -->", 1)[0].replace("{{HARNESS}}", line).replace("{{TEAM_FILES}}", team_files(shared)).replace(
        "{{KB}}", kb_version()).rstrip("\n").replace("\n\n\n", "\n\n") + "\n"


def workspace(d, kind):
    os.makedirs(os.path.join(d, "tools"), exist_ok=True)
    shared = os.path.join(os.path.dirname(d), "team-tools")
    os.makedirs(shared, exist_ok=True)
    link = os.path.join(d, "team-tools")
    if kind in MIRRORED:
        # A real folder, mirrored with the shared one by `sync` (tools/start-team.sh and smoke-launch.sh run it).
        if os.path.islink(link):
            os.remove(link)
        os.makedirs(link, exist_ok=True)
        sync_pair(shared, link)
    elif not os.path.lexists(link):
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
        add = paragraph(kind, os.path.basename(os.path.abspath(d)), shared).rstrip("\n") + "\n\n"
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
    return " ".join(words) + grok_sandbox(d)


SANDBOX_PROFILE = "pog"


def grok_sandbox(d):
    """smoke-ft: under dontAsk, Grok denied spawn_subagent and `cp` ("prompt policy"): no allow rule names the subagent
    tool (Grok's rule tool names are Bash, Read, Edit, Write, Grep, Glob, MCPTool, WebFetch, WebSearch), only a bare
    `*`. So Grok runs in its kernel sandbox (Seatbelt; docs 18-sandbox.md), a custom profile in the run home's
    sandbox.toml, and `*` is allowed inside it, as Claude Code's sandbox auto-allows its commands:
    - writes: the workspace (the profile's base), team-tools, the owner's ~/.grok (login refresh, sessions);
    - kernel-denied reads and writes: ~/.config/pog, ~/.ssh, runs' key copies (all but this run's own when fh reads
      it), and teammates' private files. These also hold for bin/fh run directly and for subagents.
    POG_GROK_SANDBOX=0 keeps the allowlist (no subagents) instead. Returns the extra flag words."""
    if os.environ.get("POG_GROK_SANDBOX", "1") == "0":
        return ""
    run = os.path.dirname(os.path.abspath(d))
    root = os.path.dirname(os.path.dirname(run))
    home = os.path.expanduser("~")
    deny = [os.path.join(home, ".config", "pog"), os.path.join(home, ".ssh")]
    deny += [p for p in (os.path.realpath(os.path.join(home, ".ssh")),) if p not in deny]
    for k in sorted(glob.glob(os.path.join(root, "runs", "*", ".keys"))):
        if os.environ.get("POG_BROKER") == "1" or os.path.dirname(k) != run:
            deny.append(k)
    for o in others(d):
        deny += [os.path.join(o, s) for s in PRIVATE_FILES + PRIVATE_DIRS]
    rw = [os.path.join(run, "team-tools"), os.path.join(home, ".grok")]
    text = (f"# Written by tools/full_tools.py (POG_FULL_TOOLS=1) for this workspace's Grok.\n"
            f"[profiles.{SANDBOX_PROFILE}]\nextends = \"workspace\"\n"
            f"read_write = {json.dumps(rw)}\ndeny = {json.dumps(deny)}\n")
    gh = os.path.join(d, ".grok-home")
    os.makedirs(gh, mode=0o700, exist_ok=True)
    with open(os.path.join(gh, "sandbox.toml"), "w") as f:
        f.write(text)
    return f" --sandbox {SANDBOX_PROFILE} --allow '*'"


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "workspace":
        workspace(sys.argv[2], sys.argv[3])
    elif cmd == "claude":
        claude(sys.argv[2])
    elif cmd == "grok-args":
        print(grok_args(sys.argv[2]))
    elif cmd == "sync":   # sync RUN_DIR [SECONDS]: once, or every SECONDS until killed
        import time
        while True:
            for line in sync(sys.argv[2]):
                print(time.strftime("%H:%M:%S"), line, flush=True)
            if len(sys.argv) < 4:
                break
            time.sleep(float(sys.argv[3]))
    elif cmd == "carry":   # carry [--dry-run] RUN_DIR PREV_DIR NAME...: lines for start.log; the file list beside them
        args = sys.argv[2:]
        dry = args[:1] == ["--dry-run"]
        run_dir, prev_dir, *who = args[1:] if dry else args
        out, files = carry(run_dir, prev_dir, who, dry)
        if files and not dry:
            with open(os.path.join(run_dir, "carried-tools.txt"), "a") as f:
                f.write("".join(l + "\n" for l in files))
        print("\n".join(out))
    elif cmd == "paragraph":
        print(paragraph(sys.argv[2]), end="")
    else:
        sys.exit(f"unknown command {cmd}")
