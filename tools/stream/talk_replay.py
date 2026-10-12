#!/usr/bin/env python3
"""Replay a run's chat through the caster's agent-line selection (caster.TalkPicker), offline: no model, no TTS.

    python3 tools/stream/talk_replay.py runs/shift01 --minutes 55 [--samples 10]

Before: what the run's caster.log aired (host lines, agent voice lines). After: the agent lines TalkPicker would voice
(clip length estimated at 15 characters a second, as the caster does), and the host lines left once the hosts yield
(caster.Caster.yield_beat): a host exchange of a beat below --yield-prio that starts within --yield seconds of an
agent line ending becomes a two-line reaction to it for --react of the agent lines, else stays quiet. The longer gaps
while agents are talkative (--talk-gap) are not modelled, so the after count of host lines is an upper bound."""
import argparse, json, os, random, re, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True

import caster  # noqa: E402

HOST = re.compile(r"^(\d\d:\d\d:\d\d) \[(Rook|Vale)\] \(([\w-]+)")
VOICE = re.compile(r"^(\d\d:\d\d:\d\d) \[voice:")


def clock(day, hms):
    return time.mktime(time.strptime(f"{day} {hms}", "%Y-%m-%d %H:%M:%S"))


def chat_rows(path):
    out = []
    for line in open(path):
        r = json.loads(line)
        if r.get("from") and r.get("text") and not r.get("tell"):
            t = time.mktime(time.strptime(r["logged_at"][:19], "%Y-%m-%dT%H:%M:%S"))
            out.append({"seq": r.get("seq"), "agent": r["from"], "text": r["text"], "aloud": bool(r.get("aloud")),
                        "t": t})
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run", help="the run's directory (chat.jsonl, caster.log)")
    ap.add_argument("--minutes", type=float, default=55)
    ap.add_argument("--samples", type=int, default=10)
    ap.add_argument("--agent-gap", type=float, default=12)
    ap.add_argument("--agent-cooldown", type=float, default=50)
    ap.add_argument("--chat-stale", type=float, default=30)
    ap.add_argument("--yield", dest="yield_s", type=float, default=30)
    ap.add_argument("--yield-prio", type=int, default=7)
    ap.add_argument("--react", type=float, default=0.5)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    rng = random.Random(a.seed)
    chat = chat_rows(os.path.join(a.run, "chat.jsonl"))
    log = open(os.path.join(a.run, "caster.log")).read().splitlines()
    day = time.strftime("%Y-%m-%d", time.localtime(chat[0]["t"]))
    start = clock(day, log[0][:8])
    end = start + a.minutes * 60
    hosts, voiced_before = [], 0
    for line in log:
        if not line[:2].isdigit() or clock(day, line[:8]) > end:
            continue
        m = HOST.match(line)
        if m:
            hosts.append((clock(day, m.group(1)), m.group(3).split("/")[0]))
        voiced_before += bool(VOICE.match(line))
    chat = [m for m in chat if start <= m["t"] <= end]

    p = caster.TalkPicker(a.agent_gap, a.agent_cooldown, a.chat_stale)
    decisions, aired, busy = [], [], 0.0
    i, now = 0, start
    while now <= end + a.chat_stale:
        new = []
        while i < len(chat) and chat[i]["t"] <= now:
            new.append(chat[i])
            i += 1
        decisions += p.add(now, new)
        if now >= busy:
            pick = p.next(now)
            if pick:
                m, label, text = pick
                p.aired_now(now, m, text)
                dur = len(text) / 15.0
                aired.append((now, now + dur + 1.5, m["agent"], label, text))
                busy = now + dur + 1.5
        now += 1.0

    # hosts yield: exchanges (lines sharing a timestamp) of low beats right after an agent line
    exchanges = {}
    for t, kind in hosts:
        exchanges.setdefault(t, []).append(kind)
    kept, reacted = 0, 0
    used = set()
    for t, kinds in sorted(exchanges.items()):
        prio = caster.PRIORITY.get(kinds[0], 1)
        after = [x for x in aired if x[1] <= t < x[1] + a.yield_s]
        if prio < a.yield_prio and after:
            x = after[-1]
            if x[0] not in used:
                used.add(x[0])
                if rng.random() < a.react:
                    reacted += 2
            continue
        kept += len(kinds)
    hosts_after = kept + reacted

    by = {}
    for d in decisions:
        by[d["label"]] = by.get(d["label"], 0) + 1
    print(f"window: {time.strftime('%H:%M', time.localtime(start))}-{time.strftime('%H:%M', time.localtime(end))}, "
          f"{len(chat)} chat lines ({sum(m['aloud'] for m in chat)} aloud)")
    print(f"before: {len(hosts)} host lines, {voiced_before} agent lines "
          f"({100 * voiced_before / max(1, voiced_before + len(hosts)):.0f}% agents)")
    print(f"after:  {hosts_after} host lines at most ({kept} kept, {reacted} reacting), {len(aired)} agent lines "
          f"({100 * len(aired) / max(1, len(aired) + hosts_after):.0f}% agents)")
    print("judged: " + ", ".join(f"{k} {v}" for k, v in sorted(by.items(), key=lambda kv: -kv[1])))
    waits = sum(1 for d in decisions if d["voiced"]) - len(aired)
    print(f"good lines not aired (gap, cooldown or stale): {waits}")
    per = {}
    for x in aired:
        per[x[2]] = per.get(x[2], 0) + 1
    print("per agent: " + ", ".join(f"{k} {v}" for k, v in sorted(per.items(), key=lambda kv: -kv[1])))
    new_only = [x for x in aired if x[3] != "aloud"]
    step = max(1, len(new_only) // max(1, a.samples))
    print(f"\n{a.samples} lines voiced now that were not before:")
    for x in new_only[::step][:a.samples]:
        print(f"  {time.strftime('%H:%M:%S', time.localtime(x[0]))} {x[2]} ({x[3]}): {x[4]}")


if __name__ == "__main__":
    main()
