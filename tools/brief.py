#!/usr/bin/env python3
"""The agents' brief: a small core (AGENTS.md) and the topic reference files (ref/TOPIC.md) of a workspace.

    python3 tools/brief.py write DIR PLAYER TIME_TEXT COOP TEAMMATE MATE_NOTES ROLE        # tools/new-run.sh
    python3 tools/brief.py team TEAM_FILE PLAYER MODEL      # the team section for POG_TEAM (stdout)
    python3 tools/brief.py harness DIR KIND                 # agent/harness-KIND.md into DIR/AGENTS.md (launch-agent.sh)
    python3 tools/brief.py sample KIND [DIR]                # an assembled core as a nine-agent Space Age launch writes
                                                              it for KIND, with its harness and full-tools paragraphs
    python3 tools/brief.py sizes                            # bytes of each harness kind's assembled core

The core is agent/PLAYBOOK.md, the team section (agent/team.md) or co-op (agent/coop.md), the index of topics and
commands (agent/ref/index.md) and the compaction instructions (agent/compact.md); tools/launch-agent.sh adds
agent/harness-KIND.md and tools/full_tools.py the "Your tools" paragraph before the compaction instructions. Every agent
reads the core at the start of every context window, so it stays under 20 KB (tools/test_brief.py); a command's
details go in its topic file, with one index entry in agent/ref/index.md (the topic's scope in a few words and the
command names; when to read each topic, the third line of its file, is in agent/ref/topics.tsv). The topic files are
agent/ref/*.md (Space Age worlds add agent/spaceage.md at the head of space-age); `./fh help TOPIC` prints one, and fh
names the topic of the call in an argument refusal (ref/commands.tsv, written here from the index).
"""
import json, os, re, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENT = os.path.join(ROOT, "agent")
REF = os.path.join(AGENT, "ref")
KINDS = ("claude", "codex", "grok", "agy", "muse")
LIMIT, FAIL = 20000, 22000     # the core's target and the size the test fails above


def index_text():
    return open(os.path.join(REF, "index.md")).read()


def index():
    """[(topic, scope, [commands])] from agent/ref/index.md, in its order; topic None for the core's own list."""
    out = []
    for item in re.split(r"\n- ", "\n" + index_text().split("\n- ", 1)[1]):
        item = " ".join(item.split())
        cut = next(i for i in range(len(item)) if item.startswith(": ", i) and item[:i].count("`") % 2 == 0)
        m = re.match(r"`([a-z-]+)`, (.*)", item[:cut])
        (topic, when), rest = (m.group(1), m.group(2)) if m else (None, ""), item[cut + 2:]
        out.append((topic, when, re.findall(r"`([^`]+)`", re.sub(r"\([^)]*\)", "", rest))))
    return out


def topics():
    return [t for t, _, _ in index() if t]


def commands():
    """{command: topic} for every command the index lists ("board plan" as board_plan; core commands map to "core")."""
    out = {}
    for topic, _, cmds in index():
        for c in cmds:
            name = c.replace("./", "").replace(" NAME", "").replace(" ", "_")
            if re.fullmatch(r"[a-z][a-z_]*", name):
                out.setdefault(name, topic or "core")
    return out


def team_text(team_file, me, model):
    """The team section: agent/team.md with the roster from TEAM_FILE ("name|model" per line)."""
    rows = [l.strip().split("|", 1) for l in open(team_file) if l.strip()]
    roster = "\n".join(f"- `{n}`: {m}" for n, m in rows if n != me)
    return (open(os.path.join(AGENT, "team.md")).read().replace("{{TEAM_SIZE}}", str(len(rows)))
            .replace("{{ROSTER}}", roster).replace("{{MODEL}}", model))


def voices():
    """The stream voices this machine can speak, nested under the "Voice:" item (tools/stream/voices.py: providers
    with a key, plus Aura-2; agent/voices.md without it)."""
    try:
        sys.path.insert(0, os.path.join(ROOT, "tools", "stream"))
        import voices as v
        text = v.catalog_markdown(v.available_providers()).rstrip("\n")
    except Exception:
        try:
            text = open(os.path.join(AGENT, "voices.md")).read().rstrip("\n")
        except OSError:
            return ""
    return "\n".join("  " + line for line in text.splitlines())


def fill(text, values):
    for k, v in values.items():
        text = text.replace("{{%s}}" % k, v)
    return text


def values(player, mate="", mate_notes="", role=""):
    sa = os.environ.get("POG_SPACE_AGE") == "1"
    return {"PLAYER": player, "TEAMMATE": mate, "TEAMMATE_NOTES": mate_notes, "ROLE": role,
            "ENEMIES": os.environ.get("POG_ENEMIES", "peaceful"), "SEED": os.environ.get("POG_SEED", "20261010"),
            "GOAL": "reaching the Shattered Planet, past the solar system's edge" if sa else "a rocket launch"}


def core(player, time_text, coop, mate="", mate_notes="", role=""):
    """AGENTS.md as tools/new-run.sh writes it: it ends with the compaction instructions (Claude Code reads a "Compact
    instructions" section, and every harness's summarizer sees the instructions file)."""
    text = open(os.path.join(AGENT, "PLAYBOOK.md")).read().replace("{{TIME}}", time_text) + coop
    if os.environ.get("POG_SPACE_AGE") == "1":
        text = text.replace("base game, default map", "Space Age (with Quality and Elevated Rails), default map")
    text = text.rstrip("\n") + "\n\n" + index_text().rstrip("\n")
    text += "\n\n## Compact instructions\n\n" + open(os.path.join(AGENT, "compact.md")).read()
    return fill(text, values(player, mate, mate_notes, role))


def whens():
    """{topic: when to read it} from agent/ref/topics.tsv (the index itself names each topic's scope in a few words)."""
    out = {}
    for line in open(os.path.join(REF, "topics.tsv")):
        if line.strip() and not line.startswith("#"):
            topic, when = line.rstrip("\n").split("\t", 1)
            out[topic] = when
    return out


def topic_files(player):
    """{topic: text} for ref/: each topic's file with a heading, when to read it (agent/ref/topics.tsv), and its facts."""
    out = {}
    when_of = whens()
    for topic, _, _ in index():
        if not topic:
            continue
        when = when_of[topic]
        body = open(os.path.join(REF, topic + ".md")).read().rstrip("\n")
        if topic == "space-age" and os.environ.get("POG_SPACE_AGE") == "1":
            sa = open(os.path.join(AGENT, "spaceage.md")).read().strip().split("\n", 1)[1].strip()
            body = sa + "\n\n" + body
        text = f"# {topic} (`./fh help {topic}`)\n\nRead it {when}.\n\n{body}\n"
        out[topic] = fill(text.replace("{{VOICES}}", voices() if "{{VOICES}}" in text else ""), values(player))
    return out


def write(d, player, time_text, coop, mate="", mate_notes="", role=""):
    open(os.path.join(d, "AGENTS.md"), "w").write(core(player, time_text, coop, mate, mate_notes, role))
    ref = os.path.join(d, "ref")
    os.makedirs(ref, exist_ok=True)
    for topic, text in topic_files(player).items():
        open(os.path.join(ref, topic + ".md"), "w").write(text)
    with open(os.path.join(ref, "commands.tsv"), "w") as f:
        for name, topic in sorted(commands().items()):
            f.write(f"{name}\t{topic}\n")


def harness_note(text, kind):
    """agent/harness-KIND.md before the compaction instructions (tools/launch-agent.sh)."""
    path = os.path.join(AGENT, f"harness-{kind}.md")
    if not os.path.exists(path):
        return text
    add = open(path).read().rstrip("\n") + "\n\n"
    i = text.find("## Compact instructions")
    return text[:i] + add + text[i:] if i >= 0 else text.rstrip("\n") + "\n\n" + add


RULES_START, RULES_END = "<!-- ground-rules -->", "<!-- /ground-rules -->"


def rules_note(text, lines):
    """(d20 batch50 E2) The team's ground rules (lines as the game gives them, e.g. "rule 8 (by astra): ...") in their own
    section before the compaction instructions, between RULES_START and RULES_END; a section already there is replaced,
    none with no rules. Codex re-injects only AGENTS.md after a compaction, so a Codex workspace carries them there
    (tools/launch-agent.sh; fh rewrites the section when the rules change, host/cli.ts noteRules)."""
    i, j = text.find(RULES_START), text.find(RULES_END)
    if i >= 0 and j > i:
        head = text[:i].rstrip("\n")
        if head.endswith("## The team's ground rules"):
            head = head[:-len("## The team's ground rules")].rstrip("\n")
        text = head + "\n\n" + text[j + len(RULES_END):].lstrip("\n")
    if not lines:
        return text
    add = ("## The team's ground rules\n" + RULES_START + "\n" + "".join(f"- {l}\n" for l in lines) + RULES_END + "\n\n")
    k = text.find("## Compact instructions")
    return text[:k] + add + text[k:] if k >= 0 else text.rstrip("\n") + "\n\n" + add


def sample(kind, d=None):
    """The core a nine-agent Space Age shift writes for KIND (POG_FULL_TOOLS=1): roster agent/team-nine.tsv."""
    sys.path.insert(0, os.path.join(ROOT, "tools"))
    import full_tools
    old = os.environ.get("POG_SPACE_AGE")
    os.environ["POG_SPACE_AGE"] = "1"
    try:
        rows = [l.rstrip("\n").split("\t") for l in open(os.path.join(AGENT, "team-nine.tsv")) if l.strip() and not l.startswith("#")]
        me = next((r for r in rows if r[1] == kind), rows[0])
        with tempfile.NamedTemporaryFile("w", suffix=".txt", dir=d) as f:
            f.write("".join(f"{r[0]}|{r[5]} ({r[6]})\n" for r in rows))
            f.flush()
            team = team_text(f.name, me[0], me[5])
        text = core(me[0], open(os.path.join(AGENT, "time-realtime.md")).read().rstrip("\n"), team)
        text = harness_note(text, kind)
        # (d19 batch41 C1) a team-tools with its README and a knowledge index, as shift41's
        with tempfile.TemporaryDirectory(dir=d) as shared:
            open(os.path.join(shared, "README.md"), "w").write("# Persistent team knowledge\n")
            open(os.path.join(shared, "knowledge-index39.md"), "w").write("# Team knowledge index\n")
            add = full_tools.paragraph(kind, me[0], shared).rstrip("\n") + "\n\n"
        i = text.find("## Compact instructions")
        return text[:i] + add + text[i:]
    finally:
        if old is None:
            os.environ.pop("POG_SPACE_AGE", None)
        else:
            os.environ["POG_SPACE_AGE"] = old


def main(argv):
    if len(argv) == 9 and argv[1] == "write":
        d, player, time_text, coop, mate, mate_notes, role = argv[2:]
        write(d, player, time_text, coop, mate, mate_notes, role)
        return 0
    if len(argv) == 4 and argv[1] == "harness":
        path = os.path.join(argv[2], "AGENTS.md")
        text = open(path).read()
        open(path, "w").write(harness_note(text, argv[3]))
        return 0
    if len(argv) == 3 and argv[1] == "rules":  # DIR: the rules fh filed (.ground_rules.json) into DIR/AGENTS.md
        path = os.path.join(argv[2], "AGENTS.md")
        try:
            lines = [l for l in json.load(open(os.path.join(argv[2], ".ground_rules.json"))).get("lines") or [] if isinstance(l, str)]
        except (OSError, ValueError, AttributeError):
            lines = []
        text = open(path).read()
        open(path, "w").write(rules_note(text, lines))
        print(len(lines))
        return 0
    if len(argv) == 5 and argv[1] == "team":
        sys.stdout.write(team_text(*argv[2:]))
        return 0
    if len(argv) in (3, 4) and argv[1] == "sample":
        sys.stdout.write(sample(argv[2], argv[3] if len(argv) == 4 else None))
        return 0
    if len(argv) == 2 and argv[1] == "sizes":
        for kind in KINDS:
            print(kind, len(sample(kind).encode()))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
