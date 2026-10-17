#!/usr/bin/env python3
"""After a runtime deploy mid-shift: what each agent workspace of a run reads about its tools, written again from this
checkout and the running game (d17 lean A2; it replaces the operator's scratchpad refresh-ref.py).

    python3 tools/refresh_workspaces.py runs/RUN [--world n] [--describe FILE]

For each workspace (runs/RUN/AGENT with AGENTS.md and ref/):
- describe.json: the running runtime's describe, one action per line as tools/launch-agent.sh writes it
  (tools/describe-lines.py); read once from the game (`bin/fh call describe --format json` on --world, default n:
  one read of about 280 KB) or from FILE (a describe reply or its result, saved earlier);
- ref/: every topic file and commands.tsv, as tools/brief.py write makes them;
- AGENTS.md: its "## Reference topics" section (the command index) replaced by agent/ref/index.md; the rest of the
  core stays as the agent's launch wrote it (team, harness and tools paragraphs).

Space Age is read from the workspace's own AGENTS.md (its launch line). Each file is written whole and renamed into
place, so an agent reading it mid-write sees the old file or the new one. Prints one line per workspace and what
changed.
"""
import argparse, json, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.dont_write_bytecode = True
import brief  # noqa: E402
import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location("describe_lines", os.path.join(ROOT, "tools", "describe-lines.py"))
describe_lines = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(describe_lines)

SPACE_AGE_LINE = "Space Age (with Quality and Elevated Rails)"
INDEX_HEAD = "## Reference topics"


def put(path, text):
    """Write text to path whole (a temporary file renamed over it); -> True when it changed."""
    try:
        if open(path).read() == text:
            return False
    except OSError:
        pass
    temp = f"{path}.{os.getpid()}.tmp"
    with open(temp, "w") as f:
        f.write(text)
    os.replace(temp, path)
    return True


def with_index(core, index):
    """AGENTS.md text with its "## Reference topics" section (up to the next "## " heading) replaced by index."""
    start = core.find(INDEX_HEAD)
    if start < 0:
        return core
    end = core.find("\n## ", start + len(INDEX_HEAD))
    tail = core[end:] if end >= 0 else "\n"
    return core[:start] + index.rstrip("\n") + "\n" + tail


def workspaces(run):
    return sorted(os.path.join(run, n) for n in os.listdir(run)
                  if os.path.isfile(os.path.join(run, n, "AGENTS.md")) and os.path.isdir(os.path.join(run, n, "ref")))


def fetch_describe(world):
    env = {**os.environ, "POG_WORLD": world}
    env.pop("POG_FH_SOCKET", None)
    out = subprocess.run([os.path.join(ROOT, "bin", "fh"), "call", "describe", "--format", "json"], env=env,
                         capture_output=True, text=True, timeout=120)
    reply = json.loads(out.stdout)
    if not reply.get("ok", True) or "actions" not in reply.get("result", reply):
        raise SystemExit(f"describe failed: {out.stdout[:300]} {out.stderr[:300]}")
    return reply


def refresh(ws, describe_text):
    """-> the names of what changed in workspace ws."""
    changed = []
    agents = os.path.join(ws, "AGENTS.md")
    core = open(agents).read()
    space_age = SPACE_AGE_LINE in core
    old = os.environ.get("POG_SPACE_AGE")
    os.environ["POG_SPACE_AGE"] = "1" if space_age else "0"
    try:
        player = os.path.basename(ws)
        for topic, text in brief.topic_files(player).items():
            if put(os.path.join(ws, "ref", topic + ".md"), text):
                changed.append(f"ref/{topic}.md")
        tsv = "".join(f"{name}\t{topic}\n" for name, topic in sorted(brief.commands().items()))
        if put(os.path.join(ws, "ref", "commands.tsv"), tsv):
            changed.append("ref/commands.tsv")
        if put(agents, with_index(core, brief.index_text())):
            changed.append("AGENTS.md index")
    finally:
        if old is None:
            os.environ.pop("POG_SPACE_AGE", None)
        else:
            os.environ["POG_SPACE_AGE"] = old
    if describe_text is not None and put(os.path.join(ws, "describe.json"), describe_text):
        changed.append("describe.json")
    return changed


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("run", help="runs/RUN")
    ap.add_argument("--world", default="n")
    ap.add_argument("--describe", help="a saved describe reply (JSON) instead of reading the game")
    ap.add_argument("--no-describe", action="store_true", help="leave describe.json as it is")
    a = ap.parse_args(argv)
    run = os.path.join(ROOT, a.run) if not os.path.isabs(a.run) else a.run
    found = workspaces(run)
    if not found:
        raise SystemExit(f"no agent workspaces in {run}")
    text = None
    if not a.no_describe:
        reply = json.load(open(a.describe)) if a.describe else fetch_describe(a.world)
        text = describe_lines.lines(reply) + "\n"
    for ws in found:
        changed = refresh(ws, text)
        print(os.path.basename(ws) + ": " + (", ".join(changed) if changed else "unchanged"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
