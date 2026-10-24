#!/usr/bin/env python3
"""Candidate clips from an archive index, ranked, and the cut of the best (batch126 CI3; report-D section 5):

    python3 tools/archive/clips.py INDEX.json [--out DIR] [--top 30] [--cut 3] [--crf 21]

Writes into --out: candidates.json (every candidate, best first) and review.md (the list a person reviews: in, out,
score, why). With --cut N, the best N with footage are cut from the master as H.264 MP4 (browser-playable, +faststart,
1080p x264 veryfast at --crf, AAC 128k, at nice 19), each with its captions as a .vtt beside it.

A moment's score: weight(kind) x novelty x on-air factor + chat bonus + host bonus + edge bonus.
- weight: the kind's base (WEIGHTS), a battle's adds the director's battle score, a loss its building count.
- novelty: x1.25 for the first of its kind in the shift (a death: the agent's first), x0.8 for a repeat.
- on air: the share of the clip the program spent on a subject that fits the kind (an attack shot for a battle, the
  agent or an attack shot for a death, a segment shot for an arrival; any subject for kinds the overlay itself shows,
  like research cards); scaled 0.3 + 0.7 x share; 0 with no footage (a gap) and the candidate says so.
- chat: viewers' and agents' lines from 30 s before to 3 minutes after, against the shift's typical 3.5 minutes.
- host: the hosts called a death, loss, attack or headline, or an agent spoke a reaction, in the clip's minute.
- edge: the moment names the solar-system-edge (the run's frontier: a platform lost or arriving there).
Within 90 s only the best survives (one fight, one clip); the others are listed under it as `also`.
In and out: padding by kind (PAD), then the in point moves back to a voiced line's start when one is in progress (up
to 8 s) and the out point on to its end (up to 16 s: the hosts' reaction often lands last), so no clip starts or
stops mid-sentence. Lines that follow on (two hosts in turn, starting within a second of the out point) extend it
again, within those 8 or 16 s of the padded point; a line that would start in the clip's last 1.5 s and run past
it is left out by ending the clip just before it.
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import captions  # noqa: E402

WEIGHTS = {"platform_lost": 100, "maiden": 90, "death": 80, "replay": 55, "battle": 40, "arrival": 30,
           "platform_created": 40, "rocket": 35, "research": 30, "viewer_answer": 30, "segment": 22, "loss": 10,
           "platform_deleted": 15, "note": 6}
# seconds before and after the event
PAD = {"death": (12, 10), "battle": (5, 25), "maiden": (5, 25), "arrival": (10, 30), "platform_lost": (15, 30),
       "platform_created": (5, 20), "research": (5, 12), "rocket": (5, 12), "viewer_answer": (3, 40),
       "segment": (2, 40), "loss": (5, 20), "platform_deleted": (5, 15), "note": (5, 15)}
# on-air subjects that show each kind; None: any subject (the overlay shows it whatever the camera does)
FITS = {"battle": {"@attack", "@incoming"}, "loss": {"@attack", "@incoming"}, "death": {"@attack"},
        "arrival": {"@segment", "@platform"}, "maiden": {"@platform", "@segment"},
        "platform_lost": {"@platform", "@attack", "@replay", "@fallback"}, "platform_created": {"@segment", "@platform"},
        "replay": {"@replay"}, "segment": {"@segment"}}
HOST_EVENTS = {"death", "loss", "attack", "headline"}
NMS_S = 90
SNAP_IN, SNAP_OUT = 8, 16


def overlap(a0, a1, b0, b1):
    return max(0.0, min(a1, b1) - max(a0, b0))


def footage(index, t0, t1):
    """Seconds of [t0, t1] inside a recording."""
    return sum(overlap(t0, t1, m["t0"], m["t1"]) for m in index["media"])


def on_air_share(index, e, t0, t1):
    fits = FITS.get(e["kind"])
    agents = set(e.get("agents") or [])
    seen = 0.0
    for a, b, slot, subject, *_ in index["onair"]:
        if b <= t0 or a >= t1:
            continue
        if fits is None or subject in fits or subject in agents:
            seen += overlap(t0, t1, a, b)
    return seen / max(1.0, t1 - t0)


def snap(index, t_in, t_out):
    """Move the in point back to the start of a voiced line in progress, the out point on to the end of one."""
    lines = sorted((r["t"], r["t"] + r["dur"]) for r in index["lines"])
    new_out = t_out
    for a, b in lines:
        if a < new_out + 1.0 and new_out < b <= t_out + SNAP_OUT:
            new_out = b + 0.5
    for a, b in lines:  # a line that starts in the last 1.5 s and runs on: stop before it rather than in its first word
        if new_out - 1.5 < a < new_out < b:
            new_out = a - 0.1
            break
    new_in = t_in
    for a, b in reversed(lines):
        if a < new_in < b and a >= t_in - SNAP_IN:
            new_in = a - 0.3
    return new_in, new_out


def chat_rate(index):
    """The shift's median count of chat lines per 3.5 minutes (at least 1)."""
    s = index["shift"]
    n = max(1, int((s["end"] - s["start"]) // 210))
    bins = [0] * n
    for c in index["chat"]:
        k = int((c["t"] - s["start"]) // 210)
        if 0 <= k < n:
            bins[k] += 1
    bins.sort()
    return max(1, bins[n // 2])


def candidates(index):
    typical = chat_rate(index)
    seen_kinds, seen_agents = set(), set()
    out = []
    for e in index["events"]:
        kind = e["kind"]
        if kind not in WEIGHTS:
            continue
        why = []
        w = WEIGHTS[kind]
        if kind == "battle":
            w += 15 * (e.get("score") or 0)
            why.append(f"battle score {e.get('score')}")
        if kind == "loss":
            n = e.get("lost") or 0
            if n < 10:
                continue  # small losses: the battle around them is the moment
            w += min(40, n)
            why.append(f"{n} lost")
        key = (kind, tuple(e.get("agents") or ())) if kind == "death" else kind
        novelty = 1.25 if key not in seen_kinds else 0.8 if kind == "death" else 1.0
        if novelty > 1:
            why.append("the first death of " + ", ".join(e.get("agents") or ["?"]) if kind == "death"
                       else f"the shift's first {kind.replace('_', ' ')}")
        seen_kinds.add(key)
        seen_agents.update(e.get("agents") or [])
        before, after = PAD.get(kind, (5, 20))
        t = e["t"]
        t_in, t_out = t - before, (t + e["seconds"] + 2 if kind == "replay" else (e.get("cut_t") or t) + after)
        if kind == "replay":
            t_in = t - 2
        t_in, t_out = snap(index, t_in, t_out)
        have = footage(index, t_in, t_out)
        share = on_air_share(index, e, t_in, t_out)
        air = 0.0 if have < 0.5 * (t_out - t_in) else 0.3 + 0.7 * share
        if air == 0:
            why.append("no footage (a gap in the recording)")
        else:
            why.append(f"on air {round(share * 100)}% of the clip")
        chat = sum(1 for c in index["chat"] if t - 30 <= c["t"] <= t + 180)
        chat_bonus = min(20.0, 10.0 * max(0.0, chat / typical - 1))
        if chat_bonus >= 5:
            why.append(f"chat x{chat / typical:.1f} ({chat} lines)")
        host = [r for r in index["lines"] if t - 5 <= r["t"] <= t + 60 and
                (r.get("event") in HOST_EVENTS or r.get("label") == "reaction")]
        host_bonus = min(16, 8 * sum(1 for r in host if r.get("event")) + 5 * sum(1 for r in host if r.get("label")))
        if host_bonus:
            why.append(f"hosts or agents reacted ({len(host)} lines)")
        edge = 30 if "solar-system-edge" in (e.get("title") or "") else 0
        if edge:
            why.append("at the solar system's edge")
        score = round(w * novelty * air + (chat_bonus + host_bonus + edge) * (1 if air else 0), 1)
        out.append({"id": e["id"], "kind": kind, "title": e.get("title"), "t_event": t, "t_in": round(t_in, 1),
                    "t_out": round(t_out, 1), "seconds": round(t_out - t_in, 1), "score": score, "why": why,
                    "on_air_share": round(share, 2), "agents": e.get("agents") or [],
                    "replay_file": e.get("replay_file")})
    out.sort(key=lambda c: -c["score"])
    kept = []
    for c in out:  # one moment per 90 s: the best keeps the others as `also`
        near = next((k for k in kept if abs(k["t_event"] - c["t_event"]) <= NMS_S), None)
        if near:
            near.setdefault("also", []).append(c["id"])
            if c["kind"] == "replay" and c.get("replay_file") and not near.get("replay_file"):
                near["replay_file"] = c["replay_file"]
        else:
            kept.append(c)
    for c in kept:
        where = locate(index, c["t_in"])
        if where:
            c["file"], c["s_in"] = where
            c["s_out"] = round(c["s_in"] + c["seconds"], 2)
    return kept


def locate(index, t):
    for m in index["media"]:
        if m["t0"] <= t <= m["t1"]:
            return m["file"], round(t - m["t0"], 2)
    return None


def hms(s):
    s = int(s)
    return f"{s // 3600}:{s % 3600 // 60:02d}:{s % 60:02d}"


def review(index, cands, top):
    import datetime
    tz = datetime.timezone(datetime.timedelta(hours=-7))
    lines = [f"# {index['shift']['run']}: candidate clips ({len(cands)}, best {min(top, len(cands))} listed)", "",
             "| # | score | in (PDT) | file at | length | kind | moment | why |", "|---|---|---|---|---|---|---|---|"]
    for i, c in enumerate(cands[:top], 1):
        at = datetime.datetime.fromtimestamp(c["t_in"], tz).strftime("%H:%M:%S")
        lines.append(f"| {i} | {c['score']} | {at} | {hms(c['s_in']) if 's_in' in c else 'no footage'} | "
                     f"{c['seconds']:.0f} s | {c['kind']} | {(c['title'] or '').replace('|', '/')} | "
                     f"{'; '.join(c['why'])}{' (also ' + ', '.join(c['also']) + ')' if c.get('also') else ''} |")
    return "\n".join(lines) + "\n"


def cut_cmd(c, out, crf=21):
    """ffmpeg at low priority: input seek a little before (the masters have keyframes every 8 s; ffmpeg decodes from the
    one before and drops frames up to the point), re-encoded."""
    return ["nice", "-n", "19", "ffmpeg", "-nostdin", "-v", "error", "-y", "-ss", f"{c['s_in']:.2f}", "-i", c["file"],
            "-t", f"{c['seconds']:.2f}", "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "libx264", "-preset", "veryfast",
            "-crf", str(crf), "-pix_fmt", "yuv420p", "-profile:v", "high", "-c:a", "aac", "-b:a", "128k",
            "-movflags", "+faststart", str(out)]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("index")
    ap.add_argument("--out", default=".")
    ap.add_argument("--top", type=int, default=30)
    ap.add_argument("--cut", type=int, default=0)
    ap.add_argument("--crf", type=int, default=21)
    a = ap.parse_args()
    idx = json.load(open(a.index))
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    cands = candidates(idx)
    (out / "candidates.json").write_text(json.dumps(cands, indent=1, ensure_ascii=False))
    (out / "review.md").write_text(review(idx, cands, a.top))
    import time
    done = 0
    for c in cands:
        if done >= a.cut:
            break
        if "file" not in c or not os.path.exists(c["file"]):
            continue
        done += 1
        mp4 = out / f"{idx['shift']['run']}-{c['id']}.mp4"
        t = time.time()
        subprocess.run(cut_cmd(c, mp4, a.crf), check=True)
        took = time.time() - t
        (out / (mp4.stem + ".vtt")).write_text(captions.vtt(idx["lines"], 0, c["t_in"], c["t_out"]))
        print(f"{mp4.name}: {c['seconds']:.0f} s in {took:.1f} s ({c['seconds'] / took:.1f}x), "
              f"{mp4.stat().st_size / 1e6:.1f} MB, score {c['score']}")


if __name__ == "__main__":
    main()
