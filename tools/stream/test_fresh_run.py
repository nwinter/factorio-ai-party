#!/usr/bin/env python3
"""A fresh run reads as a first attempt (task-hosts5 item 2), no network: python3 tools/stream/test_fresh_run.py

What the hosts are sent on the first shift of a new run, with caster.py's default arguments (the system prompt, the
facts and rules of each kind of beat, the cards on screen, the "previously on"), names no earlier run: no run id from
runs/ (shakeN, coop1, baseline1, turns1, smoke-..., sapilot) and no pace comparison. The same beats with a --baseline
do name one, so the check would catch a default that brought it back.
"""
import json, os, re, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import caster  # noqa: E402

FAILS = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f"  {detail}"))
    if not ok:
        FAILS.append(name)


# Run ids before the public run: the known families, and whatever runs/ holds in this checkout.
PATTERNS = [r"shake\s?\d+", r"(?:2026-10-10-)?(?:baseline|coop|turns)\d\w*", r"smoke-[\w-]+", r"sapilot",
            r"sa-(?:flight|smoke|travel)", r"live-check-[\w-]+"]
try:
    PATTERNS += [re.escape(d) for d in os.listdir(os.path.join(ROOT, "runs")) if not d.startswith((".", "_"))
                 and not d.endswith(".out") and len(d) > 3]
except OSError:
    pass
PRIOR = re.compile(r"(?<![\w-])(?:" + "|".join(PATTERNS) + r")(?![\w-])", re.I)
HISTORY = re.compile(r"\b(?:earlier|previous|last|other|prior) (?:run|attempt)s?\b|\bpace comparison\b", re.I)


def prior_ids(text):
    return sorted({m.group(0) for m in PRIOR.finditer(text)})


check("the run-id check finds ids", prior_ids("as in shake12 and 2026-10-10-coop1, smoke-l4h, sapilot, Shake 5")
      == ["2026-10-10-coop1", "Shake 5", "sapilot", "shake12", "smoke-l4h"], prior_ids("shake12 coop1"))
check("the run-id check leaves words alone", not prior_ids("it turns out the baseline of a co-op smoke test"))

NOW = time.time()
SNAP = {
    "tick": 60 * 60 * 25, "subtitle": "nine AI models, one factory",
    "agents": [{"name": n, "display_name": n.capitalize(), "model": f"model {n}", "role": "Builder"}
               for n in ("astra", "luna", "sol", "opus", "sonnet", "haiku", "gemini", "grok", "muse")],
    "research": {"current": {"name": "logistics", "progress": 0.4}, "done_count": 6,
                 "recent": [{"name": "automation", "label": "Automation"},
                            {"name": "electronics", "label": "Electronics"}]},
    "score": {"spm": 12, "rockets": 0},
    "production": [{"item": "iron-plate", "total": 2400}, {"item": "automation-science-pack", "total": 120}],
}
EVENTS = [
    {"kind": "open", "text": "the hosts come on", "prio": 6},
    {"kind": "research", "text": "Research complete: Automation", "prio": 7},
    {"kind": "research", "text": "Research complete: Logistics", "prio": 7},
    {"kind": "attack", "text": "Base under attack: gun turret hit 4 times", "prio": 9},
    {"kind": "death", "text": "Sol died", "agent": "sol", "prio": 9},
    {"kind": "lull", "prio": 3},
] + [{"kind": "segment", "prio": 7, "segment": {"type": t, "title": title, "started": NOW, "ends": NOW + 30,
                                                "facts": facts}}
     for t, title, facts in [
         ("research", "Research", {"researching": "Logistics", "opens_up": ["Splitters", "Underground belts"]}),
         ("recap", "Last 20 minutes", {"minutes": 20, "attacks": 3, "research_done": ["Automation"]}),
         ("attack_replay", "Replay: the north wall", {"lost": ["gun turret"]}),
         ("production", "Production", {"iron-plate": 80}),
         ("spotlight", "Spotlight: Sol", {"agent": "Sol", "doing": "smelting"}),
         ("space", "The way to space", {"stage": "Red science"}),
     ]]


class Capture(caster.LLMWriter):
    """The OpenRouter writer with the call replaced: keeps what would be sent, answers with one plain line."""

    def __init__(self):
        super().__init__("or", "capture")
        self.sent = []

    def complete(self, system, user, max_tokens=80):
        self.sent.append(system + "\n" + user)
        return "Rook: The factory keeps humming.\nVale: Six technologies in and counting."


def sent_by(extra_args, run_dir):
    tmp = tempfile.mkdtemp(prefix="fresh-run-")
    a = caster.parser().parse_args(["--writer", "template", "--dry-run", "--classifier", "heuristic", "--log-dir",
                                    tmp, "--run-dir", run_dir, "--urgent-model", ""] + extra_args)
    c = caster.Caster(a)
    c.writer = w = Capture()
    c.speak_lines = lambda *x, **k: None
    c.live_segment = lambda *x, **k: None
    for e in EVENTS:
        c.say_exchange(dict(e, t=NOW), SNAP, "pbp", 2)
    return a, w.sent, c


fresh = tempfile.mkdtemp(prefix="pub-")
open(os.path.join(fresh, "start.log"), "w").write("08:00:00 world n: new instance\n")
a, sent, c = sent_by([], fresh)
check("defaults: no pace baseline (base game or Space Age)", not a.baseline and not a.space_baseline,
      (a.baseline, a.space_baseline))
check("a fresh run is no later shift and has no 'previously on'",
      caster.read_shift(fresh) is None and caster.previous_shift(fresh) is None)
check("every beat reached the writer", len(sent) >= len(EVENTS), len(sent))
blob = "\n".join(sent)
check("the hosts are sent no earlier run's id", not prior_ids(blob), prior_ids(blob))
check("nor told about earlier runs or pace comparisons", not HISTORY.findall(blob), sorted(set(HISTORY.findall(blob))))
check("the show notes name no earlier run", not prior_ids(caster.SHOW + caster.SHOW_SPACE)
      and not HISTORY.findall(caster.SHOW + caster.SHOW_SPACE))
check("no host line may bring one up without pace facts", caster.check_line(
    "Better than the last run already.", {"event": "lull"}, [], []) == "compares with the previous run without pace facts")

# the same beats against a stored run: the check sees it (so a baseline default coming back fails the test above)
base = os.path.join(HERE, "baselines", "shake1.json")
if os.path.exists(base):
    _, sent_b, _ = sent_by(["--baseline", base], fresh)
    check("with --baseline the run is named (the check above would see it)", prior_ids("\n".join(sent_b)),
          "no id found with a baseline")

# a later shift of the public run: "previously on" comes from its own chain only
root = tempfile.mkdtemp(prefix="chain-")
for name, rows in (("pub1", [(0, []), (36000, ["automation"])]), ("shake12", [(0, []), (9, ["rocket-silo"])])):
    os.makedirs(os.path.join(root, name))
    with open(os.path.join(root, name, "scores.jsonl"), "w") as f:
        for tick, done in rows:
            f.write(json.dumps({"score": {"tick": tick, "research_done": done, "entities": {}}}) + "\n")
os.makedirs(os.path.join(root, "pub2"))
open(os.path.join(root, "pub2", "resumed-from"), "w").write("pub1\n")
prev = caster.previous_shift(os.path.join(root, "pub2"))
check("a later shift's 'previously on' is its own chain's last shift", prev and prev["last_researched"] == ["Automation"]
      and not prior_ids(json.dumps(prev)), prev)

# the analyst (its talking points reach the hosts and the overlay's analyst card)
os.environ.pop("POG_ANALYST_PAST_RUNS", None)
sys.path.insert(0, os.path.join(ROOT, "tools", "analyst"))
import analyst  # noqa: E402
ANALYST_HISTORY = re.compile(HISTORY.pattern + r"|\bpast (?:team )?runs?\b|history_(?:at|when|runs|milestones|study)",
                             re.I)
for v in ("base-2.0.77", "space-age-2.0.77"):
    sp = analyst.system_prompt(v)
    check(f"analyst prompt ({v}): no run id, no past runs or their tools", not prior_ids(sp)
          and not ANALYST_HISTORY.findall(sp), (prior_ids(sp), ANALYST_HISTORY.findall(sp)))
    check(f"analyst prompt ({v}) with --past-runs has them (so the check sees them)",
          ANALYST_HISTORY.findall(analyst.system_prompt(v, past=True)))
vs = analyst.viewer_system() + analyst.viewer_system(on_air=False)
check("analyst viewer answers: no run id, no past runs", not prior_ids(vs) and not ANALYST_HISTORY.findall(vs),
      (prior_ids(vs), ANALYST_HISTORY.findall(vs)))
notes = os.path.join(ROOT, "tools", "analyst", "notes")
for n in sorted(os.listdir(notes)):
    if n.endswith(".md") and n not in ("README.md", "past-runs.md"):
        t = open(os.path.join(notes, n)).read()
        check(f"analyst note {n}: no run id", not prior_ids(t), prior_ids(t))

print(f"\n{len(FAILS)} failed" if FAILS else "\nall passed")
sys.exit(1 if FAILS else 0)
