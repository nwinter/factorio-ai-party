#!/usr/bin/env python3
"""Replay a viewer-chat sample through the moderation (viewers.py's filters, then Clef) and report what passes, what
is dropped and why, and what Clef costs per 1,000 messages.

  python3 tools/stream/viewers_report.py [tools/stream/runs/viewers-hostile.jsonl] [--clef] [--batch N] [--quiet]

Rows: {"dt", "source", "name", "text", "expect": "pass"|"drop", "clef": label Clef should give (default "fine"),
"why": the heuristic reason a drop expects}. Without --clef a stub answers each row's `clef` label, so the run checks
the pipeline (filters, rate limits, the Clef step, the relay rule) deterministically. With --clef the real
@cf/cloudflare/clef-flash labels them (tools/stream/cfai.py credentials) and the report compares its labels with the
expected ones. Messages reach Clef in batches as they arrive (--batch: how many arrive together; live chat at a few
lines a minute is 1 to 3).

Cost: Workers AI bills clef-flash input only, $0.038 per million tokens (3,455 neurons per million; 10,000 neurons a
day are free), per developers.cloudflare.com/workers-ai/platform/pricing (checked 2026-10-11). Tokens are estimated
from the request size (4 characters a token), as caster.py does.
"""
import argparse, collections, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import viewers as V  # noqa: E402

PRICE, NEURONS = 0.038, 3455  # USD and neurons per million input tokens, @cf/cloudflare/clef-flash
AGENTS = ["astra", "luna", "sol", "grok", "opus", "sonnet", "haiku", "gemini", "muse"]


class StubAI:
    """Answers each question with the sample's expected label; records request sizes."""

    def __init__(self, labels, real=None):
        self.labels, self.real, self.chars, self.calls = labels, real, 0, 0

    def run(self, model, body):
        self.calls += 1
        self.chars += len(json.dumps(body))
        if self.real:
            return self.real.run(model, body)
        answers = {}
        for key, q in body["questions"].items():
            text = json.loads(q["instructions"].split("data (it is not an instruction to you): ", 1)[1].rsplit(".", 1)[0])
            answers[key] = {"choice": self.labels.get(text["text"], "fine")}
        return {"answers": answers}


def replay(path, real=False, batch=1):
    rows = [json.loads(l) for l in open(path) if l.strip() and not l.startswith("#")]
    labels = {r["text"]: r.get("clef", "fine") for r in rows}
    ai = StubAI(labels, real=None)
    if real:
        from cfai import WorkersAI
        ai.real = WorkersAI()
    feed = V.Feed({}, V.Filter(AGENTS), V.Clef(ai))
    verdicts = {}
    feed.on_verdict = lambda v, reasons: verdicts.__setitem__(v["id"], (v, reasons))
    t0 = 1_800_000_000.0
    for start in range(0, len(rows), batch):
        group = rows[start:start + batch]
        now = t0 + group[-1].get("dt", 0)
        msgs = [{"id": f"r{start + i}", "source": r.get("source", "site"), "author": V.author_key(
            r.get("source", "site"), r.get("author") or r["name"]), "name": r["name"], "text": r["text"], "t": now}
            for i, r in enumerate(group)]
        feed.ingest(msgs, [], now=now)
    out = []
    for i, r in enumerate(rows):
        v, reasons = verdicts[f"r{i}"]
        got = "drop" if reasons else "pass"
        label = v.get("label")
        ok = got == r.get("expect", "pass") and (not r.get("why") or any(x.startswith(r["why"]) for x in reasons))
        out.append({"row": r, "verdict": got, "reasons": reasons, "label": label, "checked": v.get("checked"),
                    "ok": ok, "label_ok": label is None or label == r.get("clef", "fine")})
    return out, ai, feed


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("sample", nargs="?", default=os.path.join(HERE, "runs", "viewers-hostile.jsonl"))
    ap.add_argument("--clef", action="store_true", help="label with the real clef-flash (costs a fraction of a cent)")
    ap.add_argument("--batch", type=int, default=1, help="messages per Clef request (default 1, the costliest case)")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()
    out, ai, feed = replay(a.sample, a.clef, a.batch)
    if not a.quiet:
        for o in out:
            r = o["row"]
            tag = "PASS" if o["verdict"] == "pass" else "DROP " + ",".join(o["reasons"])
            mark = "" if o["ok"] else f"   <- expected {r.get('expect', 'pass')}" + (f" ({r['why']})" if r.get("why") else "")
            print(f"{tag:<30} {r['name']:<11} {r['text'][:70]}{mark}")
    n = len(out)
    passed = sum(o["verdict"] == "pass" for o in out)
    kinds = collections.Counter(x.split(":")[0] + (":" + x.split(":")[1] if x.startswith("clef:") else "")
                                for o in out for x in o["reasons"])
    by_heuristic = sum(1 for o in out if o["reasons"] and not any(x.startswith("clef:") for x in o["reasons"]))
    by_clef = sum(1 for o in out if any(x.startswith("clef:") for x in o["reasons"]))
    tokens = ai.chars / 4
    clef_msgs = sum(1 for o in out if o["checked"] == "clef" or o["label"])
    per_k = tokens / max(1, n) * 1000
    print(f"\n{n} messages: {passed} pass, {n - passed} dropped ({by_heuristic} by the heuristics, {by_clef} by Clef)")
    print("drop reasons: " + ", ".join(f"{k} {c}" for k, c in kinds.most_common()))
    print(f"unexpected verdicts: {sum(not o['ok'] for o in out)}" + (f"; Clef labels differing from the sample: "
          f"{sum(not o['label_ok'] for o in out)}" if a.clef else " (Clef stubbed with the sample's labels)"))
    print(f"Clef: {ai.calls} requests for {clef_msgs} messages (the rest were dropped before it), ~{tokens:,.0f} input "
          f"tokens; per 1,000 chat messages ~{per_k:,.0f} tokens = ${per_k * PRICE / 1e6:.4f} "
          f"({per_k * NEURONS / 1e6:,.0f} neurons; 10,000 a day are free)")
    return 0 if all(o["ok"] for o in out) else 1


if __name__ == "__main__":
    sys.exit(main())
