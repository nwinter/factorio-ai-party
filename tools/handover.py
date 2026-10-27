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
# (d27 batch275 HW: Opus's carry-over said "15435 world actions", 15429 of them chat_ack; Muse's 58 were ghosts and
# alerts_digest reads) what the runtime counts as reads and talk (idle.lua M.request: runtime.lua is_read, the board's,
# players', votes' and owed's handlers, reminder_* and queue_*), read from the harness source; the sets above if not
MOD = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "vendor", "factorio-harness", "mod",
                   "agent-harness_0.1.0")
_KINDS = None


def runtime_kinds():
    """-> (reads, talk): action names from the harness source (cached), each empty when it cannot be read."""
    global _KINDS
    if _KINDS is None:
        reads, talk = set(), set()
        try:
            src = open(os.path.join(MOD, "runtime.lua"), errors="replace").read()
            m = re.search(r"(?m)^local reads=\{([^}]*)\}", src)
            if m:
                reads |= set(re.findall(r"([A-Za-z_]+)=true", m.group(1)))
            reads |= set(re.findall(r"(?m)^reads\.([A-Za-z_]+)=true", src))
            for mod in ("board", "players", "votes", "owed"):
                text = open(os.path.join(MOD, mod + ".lua"), errors="replace").read()
                talk |= {a or b for a, b in re.findall(r"handlers\.([a-z_]+) ?=|function M\.handlers\.([a-z_]+)", text)}
        except OSError:
            pass
        _KINDS = (reads, talk)
    return _KINDS


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
                     "noop": Counter(), "errors": Counter(), "first": None, "last": None, "jobs": [], "gap": (0, None, None)}
    last_action = None
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
                rt_reads, rt_talk = runtime_kinds()
                if a in WAITS:
                    out["waits"] += 1
                    args = q.get("args") or {}
                    out["wait_s"] += float(args.get("seconds") or 0) or float(args.get("ticks") or 0) / 60
                elif a in TALK or a in rt_talk or str(a).startswith("reminder_"):
                    out["talk"] += 1
                elif a in READS or a in rt_reads or str(a).startswith("queue_"):
                    out["reads"] += 1
                else:
                    out["actions"] += 1
                    out["by_action"][a] += 1
                    # (d27 batch275 HW) the longest stretch with no world action, from the first request on
                    start = last_action if last_action is not None else out["first"]
                    if t is not None and start is not None and t - start > out["gap"][0]:
                        out["gap"] = (t - start, start, t)
                    last_action = t
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
    start = last_action if last_action is not None else out["first"]
    if out["last"] is not None and start is not None and out["last"] - start > out["gap"][0]:
        out["gap"] = (out["last"] - start, start, out["last"])
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
    gap, g0, g1 = st.get("gap") or (0, None, None)
    if gap >= 1800:
        hm = lambda t: time.strftime("%H:%M", time.gmtime(t))
        lines.append(f"- longest stretch with no world action: {fmt_min(gap)} ({hm(g0)}-{hm(g1)} UTC"
                     + (", to your last request" if g1 == st["last"] and st["by_action"] and g0 != st["first"] else "") + ")")
    top = ", ".join(f"{a} {n}" for a, n in st["by_action"].most_common(5))
    if top:
        lines.append(f"- most used: {top}")
    if st["noop"]:
        lines.append("- moved nothing: " + ", ".join(f"{a} x{n}" for a, n in st["noop"].most_common()))
    if st["queue_jobs"] is not None and st["queue_jobs"] > 0:
        lines.append(f"- your queue got through about {st['queue_jobs']} jobs")
    for msg, n in st["errors"]:
        lines.append(f"- failed x{n}: {msg}")
    return lines


# (d19 batch41 C3, viewer Aurora: a shortened handoff should keep the team's current decisions, open commitments and
# the next live check) sections kept whole when the notes are cut, by words in their headings
KEEP_WORDS = ("now", "agreement", "decision", "commitment", "open board", "claim", "next check", "live check")


def cap_notes(notes, cap=NOTES_MAX, trimmed=None):
    """-> (notes no longer than cap, whether it was cut). The Log is trimmed to its last 10 lines first; then the
    sections whose headings name current state, decisions, commitments, claims or the next check stay whole, and the
    others (lessons, milestones, narrative) are cut oldest first: in file order, each from its end down to its heading,
    until it fits; only when those alone do not fit are the kept ones cut too, in proportion. `trimmed` (a list) gets a
    phrase for each part cut."""
    trimmed = [] if trimmed is None else trimmed
    if len(notes) <= cap:
        return notes, False
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from context import trim_log
    before = notes
    notes = trim_log(notes)
    if notes != before:
        m = re.search(r"\[(\d+) older Log lines left out", notes)
        trimmed.append(f"Log: {m.group(1) if m else 'older'} older lines")
    if len(notes) <= cap:
        return notes, True
    parts = re.split(r"(?m)^(?=## )", notes)

    def name(p):
        return p.split("\n", 1)[0][3:].strip() if p.startswith("## ") else "the top"

    # the first section of each kind (Muse's notes held three Now sections, the current one first): later ones of the
    # same kind are older material
    first = {}
    for k, p in enumerate(parts):
        w = p.startswith("## ") and next((w for w in KEEP_WORDS if w in name(p).lower()), None)
        if w and w not in first:
            first[w] = k
    keep_at = set(first.values())

    def kept(p):
        return parts.index(p) in keep_at

    budget = cap - 300
    excess = len("".join(parts)) - budget
    out = list(parts)
    # the others, oldest (first in the file) first: each cut from its end down to its heading line
    for k, p in enumerate(parts):
        if excess <= 0:
            break
        if kept(p) or (not p.startswith("## ") and len(p) < 500):
            continue
        head = p.split("\n", 1)[0] + "\n"
        mark = len(f"\n[... {len(p)} characters cut]\n")
        n = min(excess + mark + 2, len(p) - len(head))
        if n <= mark:
            continue
        cut_text = p[:len(p) - n].rstrip() + f"\n[... {n} characters cut]\n"
        out[k] = cut_text
        excess -= len(p) - len(cut_text)
        trimmed.append(f"{name(p)}: {n} of {len(p)} characters" + (" (all but its heading)" if len(p) - n <= len(head) else " from its end"))
    if excess <= 0:
        return "".join(out)[:cap], True
    # the kept sections alone are over: those cut too, in proportion
    total = sum(len(p) for p in out)
    final = []
    for p in out:
        n = len(p) * budget // total
        if n >= len(p):
            final.append(p)
        else:
            n = max(200, n)
            final.append(p[:n].rstrip() + "\n[... cut]\n")
            trimmed.append(f"{name(p)}: {len(p) - n} of {len(p)} characters from its end")
    return "".join(final)[:cap], True


def strip_measured(notes):
    """notes.md without an earlier "## Last shift, measured" section (it is replaced at each shift)."""
    return re.sub(r"(?ms)^" + re.escape(MEASURED) + r".*?(?=^## |\Z)", "", notes)


NOW_FILE = ".now-history.json"  # beside notes.md: the ## Now section's hash and the shifts it has stayed the same


def now_section(notes):
    """The text of the first section whose heading names now ("## Now"), whitespace folded, or None."""
    for p in re.split(r"(?m)^(?=## )", notes):
        if p.startswith("## ") and "now" in p.split("\n", 1)[0].lower():
            return " ".join(p.split("\n", 1)[1].split()) if "\n" in p else ""
    return None


def now_history(prev_notes, notes, out_notes, run):
    """(d27 batch275 HW, Sonnet's ## Now read "shift 80 ... Doing: paper design for Loom" at the end of shifts 80 to 86)
    -> a measured line when the ## Now section had the same text at the end of 2 or more shifts in a row, else None;
    keeps NOW_FILE beside out_notes for the next handover."""
    import hashlib
    text = now_section(notes)
    if text is None:
        return None
    h = hashlib.sha256(text.encode()).hexdigest()[:16]
    try:
        old = json.load(open(os.path.join(os.path.dirname(prev_notes), NOW_FILE)))
    except (OSError, ValueError):
        old = {}
    same = old.get("hash") == h
    rec = {"hash": h, "since": old.get("since", run) if same else run, "shifts": (old.get("shifts", 1) + 1) if same else 1}
    try:
        with open(os.path.join(os.path.dirname(out_notes), NOW_FILE), "w") as f:
            json.dump(rec, f)
    except OSError:
        pass
    if rec["shifts"] < 2:
        return None
    return (f"- your notes' ## Now section had the same text at the end of the last {rec['shifts']} shifts "
            f"({rec['since']} to {run})")


def carry(prev_notes, prev_journal, out_notes, run, player):
    notes = open(prev_notes, errors="replace").read()
    notes = strip_measured(notes)
    # the previous carry-over line goes too: this one says where it comes from
    notes = re.sub(r"\A\(Carried over from the previous shift[^\n]*\)\n+", "", notes)
    trimmed = []
    capped, cut = cap_notes(notes, trimmed=trimmed)
    archive = os.path.join(os.path.dirname(out_notes), "notes-archive.md")
    if cut:
        with open(archive, "a") as f:
            f.write(f"\n\n# notes.md as run {run} left it (full, {len(notes)} characters)\n\n{notes}")
    st = journal_stats(prev_journal)
    now_line = now_history(prev_notes, notes, out_notes, run)
    head = [f"(Carried over from the previous shift, run {run}: its notes.md for {player}, as that shift left it"
            + (f"; it was {len(notes) // 1000} KB, cut to {NOTES_MAX // 1000} KB, the full text is in notes-archive.md"
               if cut else "") + ".)",
            *([f"(Trimmed: {'; '.join(trimmed[:5])}" + (f"; and {len(trimmed) - 5} more older sections cut" if len(trimmed) > 5 else "")
               + ". Kept whole: the sections on now, claims, agreements and decisions, commitments and open board items,"
               " and the next check.)"] if trimmed else []), "",
            f"{MEASURED} (from your journal, replaced each shift)", *measured_lines(st), *([now_line] if now_line else []), ""]
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
