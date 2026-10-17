#!/usr/bin/env python3
"""tools/refresh_workspaces.py: python3 tools/test_refresh_workspaces.py

A run with two workspaces (one Space Age, one not) launched from an older brief: after a refresh from a saved describe,
describe.json has one action per line (as tools/describe-lines.py writes it), ref/ is what tools/brief.py write makes
for that workspace, AGENTS.md has the current index in place of the old one and the rest unchanged; a second refresh
changes nothing. No game, no clock.
"""
import io, json, os, sys, tempfile
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
import brief  # noqa: E402
import refresh_workspaces as rw  # noqa: E402

failures = []


def check(cond, what):
    if not cond:
        failures.append(what)


def run(argv):
    out = io.StringIO()
    with redirect_stdout(out):
        rw.main(argv)
    return out.getvalue()


with tempfile.TemporaryDirectory() as d:
    run_dir = os.path.join(d, "shift99")
    head = {"sa": "# You are playing Factorio\n\nA world: Space Age (with Quality and Elevated Rails), default map.\n\n",
            "base": "# You are playing Factorio\n\nA world: base game, default map.\n\n"}
    tail = "\n## Your tools\n\nteam-tools/ and tools/.\n\n## Compact instructions\n\nKeep the plan.\n"
    old_index = "## Reference topics\n\n- `building`, when you build: `build`.\n"
    for name, kind in (("astra", "sa"), ("haiku", "base")):
        ws = os.path.join(run_dir, name)
        os.makedirs(os.path.join(ws, "ref"))
        open(os.path.join(ws, "AGENTS.md"), "w").write(head[kind] + "## Team\n\nNine of you.\n\n" + old_index + tail)
        open(os.path.join(ws, "ref", "building.md"), "w").write("stale\n")
        open(os.path.join(ws, "describe.json"), "w").write('{"actions": {}}')
    os.makedirs(os.path.join(run_dir, "basemap"))   # not a workspace
    saved = os.path.join(d, "describe-reply.json")
    json.dump({"ok": True, "result": {"protocol": 1, "bundle": "abc", "actions": {"build": {"position": "{x,y}"},
                                                                                 "craft": {"recipe": "name"}}}},
              open(saved, "w"))

    out = run([run_dir, "--describe", saved])
    check(out.startswith("astra: ") and "\nhaiku: " in out and "basemap" not in out, f"one line per workspace: {out!r}")
    check("describe.json" in out and "AGENTS.md index" in out and "ref/building.md" in out, f"what changed: {out!r}")
    for name, kind in (("astra", "sa"), ("haiku", "base")):
        ws = os.path.join(run_dir, name)
        lines = open(os.path.join(ws, "describe.json")).read().split("\n")
        check(any(l.startswith('    "build": {"name": "build", "args": ') for l in lines), f"{name}: one action per line")
        check(json.loads("\n".join(lines))["actions"]["craft"]["args"] == {"recipe": "name"}, f"{name}: valid JSON")
        os.environ["POG_SPACE_AGE"] = "1" if kind == "sa" else "0"
        want = brief.topic_files(name)
        os.environ.pop("POG_SPACE_AGE")
        for topic, text in want.items():
            check(open(os.path.join(ws, "ref", topic + ".md")).read() == text, f"{name}: ref/{topic}.md as brief writes it")
        tsv = open(os.path.join(ws, "ref", "commands.tsv")).read()
        check(tsv == "".join(f"{c}\t{t}\n" for c, t in sorted(brief.commands().items())), f"{name}: commands.tsv")
        core = open(os.path.join(ws, "AGENTS.md")).read()
        check(old_index not in core and brief.index_text().rstrip("\n") in core, f"{name}: the current index")
        check(core.startswith(head[kind] + "## Team\n\nNine of you.\n\n## Reference topics") and core.endswith(tail),
              f"{name}: the rest of AGENTS.md kept")
    sa_ref = open(os.path.join(run_dir, "astra", "ref", "space-age.md")).read()
    base_ref = open(os.path.join(run_dir, "haiku", "ref", "space-age.md")).read()
    check(len(sa_ref) > len(base_ref), "Space Age read from the workspace's AGENTS.md: agent/spaceage.md heads its topic")
    check("POG_SPACE_AGE" not in os.environ, "the environment is left as it was")

    again = run([run_dir, "--describe", saved])
    check(again == "astra: unchanged\nhaiku: unchanged\n", f"a second refresh changes nothing: {again!r}")
    check(not [f for f in os.listdir(os.path.join(run_dir, "astra")) if f.endswith(".tmp")], "no temporary file left")

if failures:
    print("FAIL\n" + "\n".join(failures))
    sys.exit(1)
print("refresh_workspaces: ok")
