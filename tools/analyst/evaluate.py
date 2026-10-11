"""The analyst check: viewer questions answered by the analyst (with tools) and by the hosts' writer (without).

Run through the analyst entry point, which runs outside the sandbox so `claude -p` and Workers AI are reachable:

  python3 tools/stream/analyst.py --eval                        # both, 30 questions, results to tools/analyst/eval/
  python3 tools/stream/analyst.py --eval --eval-only analyst --eval-ids 1,2,3
  python3 tools/stream/analyst.py --eval-grade tools/analyst/eval/results-....json   # re-grade a results file

The analyst gets the same read-only MCP tools as on air, with the game set to the questions' replay (shake2 at
minute 50). The hosts' writer is the caster's default line model (Gemma 4 26B on Workers AI) with the colour
caster's persona and the small facts snapshot the hosts get today (game time, research, technologies done, top
production), asked to answer from what it knows. Grading: every regex group in `check` must match the answer and no
`reject` pattern may (questions.json); the gold answer is kept next to each result for a human read.
"""
import json, os, re, sys, threading, time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, "tools", "stream"))
QUESTIONS = os.path.join(HERE, "eval", "questions.json")

ANSWER_SYSTEM = """You are the analyst behind the hosts of a livestream of AI agents playing Factorio 2.0.77 (base \
game; Space Age questions are about the expansion). A viewer asked a question in chat. Answer it for the hosts in at \
most three short spoken sentences, exact and plain. Use your read-only tools: kb_* for exact recipes, technologies, \
ratios and stats of this version (do no arithmetic in your head: use kb_output, kb_ratio, kb_research_time, \
kb_path), game_* for the current game, history_* for past runs, notes for pacing, biters, Space Age. Questions about \
"the team" or "right now" are about the current game in game_snapshot; past runs are in history_at. Speak as on a \
live broadcast: do not mention tools, lookups, snapshots or replays, and leave out anything you could not check. \
Answer what was asked; add at most one supporting figure, and only one you read from a tool result or the game \
snapshot this turn, quoted as it appears (do not restate a total as a per-colour rate). Reply with the answer only."""

HOST_PROMPT = ("{persona} You are casting a livestream of AI agents playing Factorio together. A viewer asks a "
               "question in chat. Answer it on air in one or two short sentences, from what you know about Factorio "
               "and the facts below. Spoken English, no lists, no emoji.")


def load():
    with open(QUESTIONS) as f:
        return json.load(f)


def grade(q, answer):
    a = (answer or "").lower()
    missing = [c for c in q.get("check", []) if not re.search(c, a, re.I)]
    rejected = [r for r in q.get("reject", []) if re.search(r, a, re.I)]
    return not missing and not rejected, missing, rejected


def host_facts(spec):
    """What the hosts' writer sees today (caster.facts_for, 'lull' event) for the replay moment."""
    import game as G
    snap = G.ReplayGame(os.path.join(REPO, spec["replay"]), spec["at"]).snapshot()
    from caster import spoken_time
    prod = sorted(((n, v["m10"] / 10) for n, v in snap["items"].items() if v.get("m10")), key=lambda kv: -kv[1])[:4]
    f = {"event": "viewer_question", "game_time": spoken_time(G.game_time(snap["tick"])), "team_size": 9,
         "researching": {"tech": (snap.get("research") or "").replace("-", " ")},
         "technologies_done": len(snap.get("done") or []),
         "production_per_minute": {n.replace("-", " "): round(r) for n, r in prod}}
    return f


def ask_host(q, facts, ai, model):
    from caster import CASTERS, MODEL_ARGS
    system = HOST_PROMPT.format(persona=CASTERS["color"]["persona"])
    user = f"Facts:\n{json.dumps(facts, ensure_ascii=False)}\nViewer question: {q['q']}\nYour answer on air:"
    t0 = time.time()
    out = ai.run(model, dict({"messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
                              "max_tokens": 120, "temperature": 0.7}, **MODEL_ARGS.get(model, {})), timeout=30)
    text = out.get("response") if isinstance(out, dict) else str(out)
    if text is None and isinstance(out, dict) and out.get("choices"):
        text = out["choices"][0]["message"].get("content")
    return (text or "").strip(), time.time() - t0


def ask_analyst(q, a, run_claude):
    t0 = time.time()
    onair = getattr(a, "eval_onair", None)  # (system, user-prompt fn, reply-to-text fn): the on-air viewer path
    if onair:
        text, meta = run_claude(a, onair[1](q["q"]), system=onair[0])
        text = onair[2](text)
    else:
        text, meta = run_claude(a, q["q"], system=ANSWER_SYSTEM)
    return text.strip(), time.time() - t0, meta


def run(a, run_claude):
    spec = load()
    qs = spec["questions"]
    if a.eval_ids:
        ids = {int(x) for x in a.eval_ids.split(",")}
        qs = [q for q in qs if q["id"] in ids]
    a.replay, a.at = os.path.join(REPO, spec["replay"]), spec["at"]
    results = {q["id"]: {"id": q["id"], "kind": q["kind"], "q": q["q"], "gold": q["gold"]} for q in qs}
    lock = threading.Lock()
    if a.eval_only in (None, "host"):
        from cfai import WorkersAI
        ai = WorkersAI()
        facts = host_facts(spec)
        model = a.host_model
        for q in qs:
            try:
                text, dt = ask_host(q, facts, ai, model)
            except Exception as e:
                text, dt = f"ERROR {type(e).__name__}: {e}", None
            ok, miss, rej = grade(q, text)
            results[q["id"]]["host"] = {"answer": text, "seconds": round(dt, 2) if dt else None, "correct": ok,
                                        "missing": miss, "rejected": rej, "model": model}
            print(f"host    {q['id']:2d} {'OK ' if ok else 'BAD'} {dt or 0:5.1f}s  {text[:110]}", flush=True)

    if a.eval_only in (None, "analyst"):
        def one(q):
            try:
                text, dt, meta = ask_analyst(q, a, run_claude)
            except Exception as e:
                text, dt, meta = f"ERROR {type(e).__name__}: {e}", None, {}
            ok, miss, rej = grade(q, text)
            with lock:
                results[q["id"]]["analyst"] = {"answer": text, "seconds": round(dt, 1) if dt else None, "correct": ok,
                                               "missing": miss, "rejected": rej, "turns": meta.get("turns"),
                                               "cost_usd": meta.get("cost_usd"), "model": a.model}
                print(f"analyst {q['id']:2d} {'OK ' if ok else 'BAD'} {dt or 0:5.1f}s  {text[:110]}", flush=True)
        with ThreadPoolExecutor(max_workers=a.eval_parallel) as ex:
            list(ex.map(one, qs))
    out = {"t": time.strftime("%Y-%m-%d %H:%M:%S"), "replay": spec["replay"], "at": spec["at"],
           "results": [results[k] for k in sorted(results)]}
    out["summary"] = summary(out["results"])
    path = os.path.join(HERE, "eval", time.strftime("results-%Y%m%d-%H%M%S.json"))
    with open(path, "w") as f:
        json.dump(out, f, indent=1, ensure_ascii=False)
    print(json.dumps(out["summary"], indent=1))
    print("results:", os.path.relpath(path, REPO))
    return out


def summary(results):
    s = {}
    for who in ("analyst", "host", "relay"):
        rs = [r[who] for r in results if who in r]
        if not rs:
            continue
        secs = sorted(x["seconds"] for x in rs if x.get("seconds"))
        kinds = {}
        for r in results:
            if who in r:
                k = "state" if r["kind"] == "state" else "knowledge"
                kinds.setdefault(k, [0, 0])
                kinds[k][0] += r[who]["correct"]
                kinds[k][1] += 1
        s[who] = {"correct": sum(x["correct"] for x in rs), "of": len(rs),
                  "by_kind": {k: f"{v[0]}/{v[1]}" for k, v in kinds.items()},
                  "median_s": secs[len(secs) // 2] if secs else None, "max_s": secs[-1] if secs else None,
                  "cost_usd": round(sum(x.get("cost_usd") or 0 for x in rs), 3) or None}
    return s


def relay(a, path):
    """Third condition: the hosts' writer answers with the analyst's answer in its facts, under the caster's own
    fact-only RULES (how the broadcast uses the analyst). Adds `relay` to each result in the file."""
    from caster import CASTERS, MODEL_ARGS, RULES
    from cfai import WorkersAI
    with open(path) as f:
        out = json.load(f)
    spec = load()
    qs = {q["id"]: q for q in spec["questions"]}
    facts = host_facts(spec)
    ai = WorkersAI()
    system = (CASTERS["color"]["persona"] + " You are casting a livestream of AI agents playing Factorio together. "
              + RULES + " A viewer asked a question; the analyst's answer is in the facts. Answer the viewer on air.")
    for r in out["results"]:
        if "analyst" not in r:
            continue
        f = dict(facts, viewer_question=r["q"], analyst_answer=r["analyst"]["answer"])
        user = f"Facts (the only things you may state):\n{json.dumps(f, ensure_ascii=False)}\nSay your line now. Reply with the line only."
        t0 = time.time()
        try:
            res = ai.run(a.host_model, dict({"messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
                                             "max_tokens": 100, "temperature": 0.7}, **MODEL_ARGS.get(a.host_model, {})), timeout=30)
            text = res.get("response") if isinstance(res, dict) else str(res)
            if not text and isinstance(res, dict) and res.get("choices"):
                text = res["choices"][0]["message"].get("content")
            if not isinstance(text, str):
                text = json.dumps(text) if text else ""
            if not text:
                print("   raw:", json.dumps(res)[:400])
        except Exception as e:
            text = f"ERROR {type(e).__name__}: {e}"
        dt = time.time() - t0
        ok, miss, rej = grade(qs[r["id"]], text)
        r["relay"] = {"answer": text.strip(), "seconds": round(dt, 2), "correct": ok, "missing": miss, "rejected": rej,
                      "model": a.host_model}
        print(f"relay   {r['id']:2d} {'OK ' if ok else 'BAD'} {dt:5.1f}s  {text.strip()[:110]}", flush=True)
    out["summary"] = summary(out["results"])
    with open(path, "w") as f:
        json.dump(out, f, indent=1, ensure_ascii=False)
    print(json.dumps(out["summary"], indent=1))


def regrade(path):
    with open(path) as f:
        out = json.load(f)
    qs = {q["id"]: q for q in load()["questions"]}
    for r in out["results"]:
        for who in ("analyst", "host", "relay"):
            if who in r:
                ok, miss, rej = grade(qs[r["id"]], r[who]["answer"])
                r[who].update(correct=ok, missing=miss, rejected=rej)
    out["summary"] = summary(out["results"])
    with open(path, "w") as f:
        json.dump(out, f, indent=1, ensure_ascii=False)
    print(json.dumps(out["summary"], indent=1))
