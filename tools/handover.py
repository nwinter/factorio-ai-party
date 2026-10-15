#!/usr/bin/env python3
"""Measured outcomes from an agent's own journal, for the shift handover and the post-compaction brief
(docs/studies/2026-10-13-agent-minds.md, fixes 8 and 12: routines outlived their reason because nobody measured them;
Sonnet's queue loop and Haiku's "top up boilers every 2-3 min" rode through 5 compactions; Muse's notes.md was 134 KB).

  tools/handover.py carry PREV_NOTES PREV_JOURNAL OUT_NOTES RUN PLAYER
      the new shift's notes.md: a "## Last shift, measured" section from the previous shift's journal (replacing the
      one before), then the previous notes, capped at NOTES_MAX characters (Log trimmed first; the full text goes to
      notes-archive.md beside OUT_NOTES)
  tools/handover.py stats JOURNAL [--since-min N]
      the measured lines (what the brief and the handover print)

Facts only, no advice: counts of what the agent did and what came of it (moved nothing, failed, stood).
"""
import gzip, json, os, re, sys, time
from collections import Counter

NOTES_MAX = 16000  # characters of a carried-over notes.md (others ran 6-17 KB; Muse's 134 KB was read whole each shift)
MEASURED = "## Last shift, measured"
READS = {"status", "observe", "inspect", "chat", "tells", "board", "board_plan", "board_events", "recipes",
         "technologies", "describe", "placements", "inventory", "queue_status", "profiles", "clock", "research_done",
         "defense", "scan", "map", "nearest", "craftable", "power", "grid", "rates", "bottleneck", "stock", "platforms",
         "blueprint_list", "blueprint_export", "screenshot", "where_is", "research_options", "labs", "flamers",
         "sleep_check", "votes", "players", "cameras"}
WAITS = {"sleep", "wait_ticks", "wait_until"}
TALK = {"say", "tell", "board_post", "board_update", "board_plan", "confess", "operator", "profile", "harness_request",
        "vote"}
IDLE_RE = re.compile(r"character idle (\d+)s of it")
JOB_RE = re.compile(r'"id": ?"job-(\d+)"')


def parse_at(s):
    import calendar
    try:
        return calendar.timegm(time.strptime(s[:19], "%Y-%m-%dT%H:%M:%S"))  # the journal's times are UTC
    except (TypeError, ValueError):
        return None


def norm_error(msg):
    m = re.sub(r"-?\d+(\.\d+)?", "N", str(msg or ""))
    return m[:70]


def journal_stats(path, since=None, max_bytes=60_000_000):
    """-> {span_s, actions, by_action, reads, waits, wait_s, idle_s, noop {action: n}, errors [(msg, n)],
    queue_jobs, queue_pending, first, last} for requests at or after `since` (epoch seconds)."""
    reqs, out = {}, {"actions": 0, "reads": 0, "talk": 0, "waits": 0, "wait_s": 0, "idle_s": 0, "by_action": Counter(),
                     "noop": Counter(), "errors": Counter(), "first": None, "last": None, "jobs": []}
    # tools/stop-team.sh gzips each journal and removes journal.jsonl before the next shift's tools/new-run.sh hands it
    # over (d15 trajectory analysis: every carried notes.md said "no requests in your journal"): the .gz is read then.
    gz = not os.path.exists(path) and os.path.exists(path + ".gz")
    try:
        size = os.path.getsize(path + ".gz" if gz else path)
        f = gzip.open(path + ".gz", "rt", errors="replace") if gz else open(path, errors="replace")
    except OSError:
        return None
    with f:
        if size > max_bytes and not gz:
            f.seek(size - max_bytes)
            f.readline()
        for line in f:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            t = parse_at(r.get("at"))
            if since and (t is None or t < since):
                continue
            if r.get("event") == "request":
                q = r.get("request") or {}
                a = q.get("action")
                # the gap since the previous request: a reply's "character idle Ns" covers it, at most (parallel and
                # long requests would count one stretch twice: Muse's summed to 643% of its shift)
                gap = (t - out["last"]) if (t is not None and out["last"] is not None) else 0
                reqs[q.get("id")] = (a, q.get("args") or {}, max(0.0, gap))
                out["first"] = out["first"] or t
                out["last"] = t
                if a in WAITS:
                    out["waits"] += 1
                    args = q.get("args") or {}
                    out["wait_s"] += float(args.get("seconds") or 0) or float(args.get("ticks") or 0) / 60
                elif a in READS:
                    out["reads"] += 1
                elif a in TALK:
                    out["talk"] += 1
                else:
                    out["actions"] += 1
                    out["by_action"][a] += 1
            elif r.get("event") == "response":
                p = r.get("response") or {}
                a, _args, gap = reqs.pop(p.get("id"), (None, {}, 0.0))
                res = p.get("result") if isinstance(p.get("result"), dict) else {}
                m = IDLE_RE.search(str(res.get("clock") or ""))
                if m:
                    out["idle_s"] += min(int(m.group(1)), gap)
                if not p.get("ok"):
                    out["errors"][f"{a}: {norm_error((p.get('error') or {}).get('message'))}"] += 1
                elif a in ("transfer", "feed", "collect") and (res.get("transferred") == 0
                                                                or ("transferred" not in res and res.get("moved") == 0 and not res.get("timed"))):
                    out["noop"][a] += 1
                if a in ("queue_status", "queue_submit", "queue_repeat", "queue_edit"):
                    ids = [int(x) for x in JOB_RE.findall(json.dumps(res.get("pending") or []))]
                    out["jobs"].append(min(ids) if ids else None)
    out["span_s"] = (out["last"] - out["first"]) if out["first"] and out["last"] else 0
    jobs = [j for j in out.pop("jobs") if j is not None]
    out["queue_jobs"] = (jobs[-1] - jobs[0]) if len(jobs) >= 2 else None  # jobs the queue got through (ids advance)
    out["errors"] = out["errors"].most_common(3)
    return out


def fmt_min(s):
    return f"{round(s / 60)} min"


def measured_lines(st, what="last shift"):
    """Facts, one per line: "- 412 game actions, 1,203 reads, 96 waits (2 h 10 min asked) in 3 h 55 min"."""
    if not st or not st["first"]:
        return [f"- no requests in your journal for the {what}"]
    lines = [f"- {st['actions']} world actions, {st['talk']} messages and board posts, {st['reads']} reads, "
             f"{st['waits']} waits ({fmt_min(st['wait_s'])} of waiting asked) over {fmt_min(st['span_s'])}"]
    if st["span_s"]:
        lines.append(f"- your character stood idle {fmt_min(st['idle_s'])} of it ({round(100 * st['idle_s'] / max(1, st['span_s']))}%"
                     " by the replies' clock lines)")
    top = ", ".join(f"{a} {n}" for a, n in st["by_action"].most_common(5))
    if top:
        lines.append(f"- most used: {top}")
    if st["noop"]:
        lines.append("- moved nothing: " + ", ".join(f"{a} x{n}" for a, n in st["noop"].most_common()))
    if st["queue_jobs"] is not None:
        lines.append(f"- your queue got through about {st['queue_jobs']} jobs")
    for msg, n in st["errors"]:
        lines.append(f"- failed x{n}: {msg}")
    return lines


def cap_notes(notes, cap=NOTES_MAX):
    """-> (notes no longer than cap, whether it was cut): the Log trimmed to its last 10 lines first, then each
    section cut from its end in proportion."""
    if len(notes) <= cap:
        return notes, False
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from context import trim_log
    notes = trim_log(notes)
    if len(notes) <= cap:
        return notes, True
    parts = re.split(r"(?m)^(?=## )", notes)
    budget = cap - 200
    total = sum(len(p) for p in parts)
    kept = [p if len(p) * budget // total >= len(p) else p[:max(200, len(p) * budget // total)].rstrip() + "\n[... cut]\n"
            for p in parts]
    return "".join(kept)[:cap], True


def strip_measured(notes):
    """notes.md without an earlier "## Last shift, measured" section (it is replaced at each shift)."""
    return re.sub(r"(?ms)^" + re.escape(MEASURED) + r".*?(?=^## |\Z)", "", notes)


def carry(prev_notes, prev_journal, out_notes, run, player):
    notes = open(prev_notes, errors="replace").read()
    notes = strip_measured(notes)
    # the previous carry-over line goes too: this one says where it comes from
    notes = re.sub(r"\A\(Carried over from the previous shift[^\n]*\)\n+", "", notes)
    capped, cut = cap_notes(notes)
    archive = os.path.join(os.path.dirname(out_notes), "notes-archive.md")
    if cut:
        with open(archive, "a") as f:
            f.write(f"\n\n# notes.md as run {run} left it (full, {len(notes)} characters)\n\n{notes}")
    st = journal_stats(prev_journal)
    head = [f"(Carried over from the previous shift, run {run}: its notes.md for {player}, as that shift left it"
            + (f"; it was {len(notes) // 1000} KB, cut to {NOTES_MAX // 1000} KB, the full text is in notes-archive.md"
               if cut else "") + ".)", "",
            f"{MEASURED} (from your journal, replaced each shift)", *measured_lines(st), ""]
    with open(out_notes, "w") as f:
        f.write("\n".join(head) + "\n" + capped)
    return cut


def main(argv):
    if argv[:1] == ["carry"] and len(argv) == 6:
        cut = carry(*argv[1:])
        print("cut" if cut else "ok")
    elif argv[:1] == ["stats"] and len(argv) >= 2:
        since = None
        if "--since-min" in argv:
            since = time.time() - 60 * float(argv[argv.index("--since-min") + 1])
        print("\n".join(measured_lines(journal_stats(argv[1], since))))
    else:
        print(__doc__, file=sys.stderr)
        return 64
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
