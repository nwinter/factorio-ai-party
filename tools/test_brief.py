#!/usr/bin/env python3
"""The agents' brief (tools/brief.py): python3 tools/test_brief.py

1. Size: the assembled core (AGENTS.md as a nine-agent Space Age shift writes it, with the harness and "Your tools"
   paragraphs) of every harness kind stays under 20 KB; the test fails above 22 KB, and agy's under its 24000-byte cut.
   A new feature adds a line to a topic file (agent/ref/TOPIC.md) and one index entry (agent/ref/index.md).
2. The index: every topic it lists has a file and every file is listed; each command it lists is named in its topic
   file; every action a topic file or the core documents (by the newest runs/*/*/describe.json, when there is one) has
   an index entry or is one of the core's own commands.
3. write: AGENTS.md (ending with the compaction instructions, no placeholder left), ref/TOPIC.md for every topic with
   its heading, ref/commands.tsv naming each command's topic; Space Age puts agent/spaceage.md at the head of
   ref/space-age.md.
"""
import glob, json, os, re, sys, tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
import brief  # noqa: E402

# The commands the core itself documents (agent/PLAYBOOK.md, agent/team.md): no index entry needed.
CORE = {"observe", "map", "scan", "nearest", "status", "rates", "recipes", "technologies", "describe", "bottleneck",
        "say", "chat", "tell", "board", "board_post", "board_update", "board_plan", "sleep", "wait_until", "wait_ticks",
        "queue_submit", "queue_resume", "screenshot", "advance", "walk", "build", "mine", "move_to", "transfer",
        "collect", "feed", "craft", "research", "harness_request",
        "dry_run"}   # dry_run: the argument the topic files name (the action of that name is the same check)


def sizes():
    for kind in brief.KINDS:
        n = len(brief.sample(kind).encode())
        assert n <= brief.FAIL, f"{kind}: the core is {n} bytes, over {brief.FAIL}: move detail to a topic file"
        if n > brief.LIMIT:
            print(f"warning: {kind}: the core is {n} bytes, over the {brief.LIMIT} target")
        if kind == "agy":
            assert n <= 24000, f"agy: {n} bytes, over agy's 24000-byte cut"
        print(f"{kind}: {n} bytes")


def index():
    topics = brief.topics()
    files = sorted(os.path.basename(p)[:-3] for p in glob.glob(os.path.join(brief.REF, "*.md")) if not p.endswith("index.md"))
    assert sorted(topics) == files, (topics, files)
    for topic, when, cmds in brief.index():
        if not topic:
            continue
        assert when, topic
        text = open(os.path.join(brief.REF, topic + ".md")).read()
        if topic == "space-age":
            text += open(os.path.join(brief.AGENT, "spaceage.md")).read()
        for c in cmds:
            word = c.replace("./fh ", "").split()[0]
            assert re.search(r"(?<![\w-])" + re.escape(word) + r"(?![\w-])", text), f"{topic}: index names {c}, the file does not"
    print(f"index: {len(topics)} topics, {len(brief.commands())} commands")
    found = sorted(glob.glob(os.path.join(brief.ROOT, "runs", "*", "*", "describe.json")), key=os.path.getmtime)
    if not found:
        print("documented actions: skipped (no runs/*/*/describe.json)")
        return
    actions = set(json.load(open(found[-1])).get("actions", {}))
    listed = set(brief.commands())
    docs = "".join(open(p).read() for p in glob.glob(os.path.join(brief.REF, "*.md")) if not p.endswith("index.md"))
    missing = sorted(a for a in actions - listed - CORE if re.search(r"`(\./fh call |\./fh )?" + a + r"\b", docs))
    assert not missing, f"documented in a topic file but not in agent/ref/index.md: {missing}"
    print(f"documented actions: ok ({found[-1].split('/runs/')[1]})")


def write():
    with tempfile.TemporaryDirectory() as d:
        old = os.environ.get("POG_SPACE_AGE")
        os.environ["POG_SPACE_AGE"] = "1"
        try:
            brief.write(d, "opus", "Real time.", brief.team_text(*team(d)), "", "", "")
        finally:
            os.environ.pop("POG_SPACE_AGE") if old is None else os.environ.__setitem__("POG_SPACE_AGE", old)
        core = open(os.path.join(d, "AGENTS.md")).read()
        assert "{{" not in core and core.index("## Reference topics") < core.index("## Compact instructions"), core[-300:]
        assert "Space Age (with Quality and Elevated Rails)" in core and "Shattered Planet" in core
        for topic in brief.topics():
            text = open(os.path.join(d, "ref", topic + ".md")).read()
            assert text.startswith(f"# {topic} (`./fh help {topic}`)\n\nRead it ") and "{{" not in text, text[:200]
        sa = open(os.path.join(d, "ref", "space-age.md")).read()
        assert "This world runs Space Age" in sa and "## Space Age" not in sa
        tsv = dict(l.rstrip("\n").split("\t") for l in open(os.path.join(d, "ref", "commands.tsv")))
        assert tsv["transfer"] == "moving-items" and tsv["blueprint_save"] == "building" and tsv["plan_run"] == "waits-queues"
    print("write: ok")


def team(d):
    path = os.path.join(d, "team.txt")
    open(path, "w").write("opus|Claude Opus 5.5 (Claude Code)\nsol|GPT-6.1 Sol (Codex)\n")
    return path, "opus", "Claude Opus 5.5"


if __name__ == "__main__":
    sizes()
    index()
    write()
    print("all passed")
