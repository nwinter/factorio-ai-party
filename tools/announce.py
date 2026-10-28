#!/usr/bin/env python3
"""The Operator's one-line announcement in the site chat, without the game (batch293, Nick d27 19:26: "announce shift
changes in the site chat as they happen"; at 19:23 the game box rebooted at the shift88 change and viewers saw the
stream stop with no word):

    python3 tools/announce.py say "The stream stops for a few minutes while the game machine restarts."
    python3 tools/announce.py stop --minutes 15 [--what "a restart of the game machine"]
    python3 tools/announce.py change-begin PREV NEXT        # tools/shift-change.sh, as a change begins
    python3 tools/announce.py change-live NEXT --agents K   # ... once NEXT's agents are up
    python3 tools/announce.py change-failed NEXT            # ... when NEXT's start failed or PREV's stop refused
    python3 tools/announce.py change-stalled NEXT           # ... when NEXT is not up past twice the usual change time
    python3 tools/announce.py usual                         # the usual change time in minutes (from the runs)
    any of them with --dry-run: the line, sent nowhere

The line goes to the live API's POST /v1/announce with the publish token (POG_LIVE_TOKEN, else
site/worker/.secrets.json's PUBLISH_TOKEN, as site/push_live.py): the Worker stores it as "Operator" on the viewers'
channel (never relayed into the game) and the live page shows it with an OPERATOR badge. A change event's line has a
cid made from the event and the run, so a second call for the same event is the first line again (one line per event).
Facts only: a line naming a path, a host, an address or an account is refused before it is sent. Exit 0 sent (or a
dry run), 1 not sent (the reason on stdout; tools/shift-change.sh goes on), 2 refused (a test run without
POG_ANNOUNCE_API, or the text). --log FILE appends "HH:MM:SS announce: ..." lines.
"""
import argparse
import calendar
import glob
import hashlib
import json
import os
import re
import statistics
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE_API = "https://player-of-games-live.your-subdomain.workers.dev"
USUAL_MIN = 8   # d27: the last agent up 6.3-6.6 min after the stop save (shift80-88), about a minute of stopping before it
# what a public line never names (task-common: no paths, hosts, addresses or accounts)
PRIVATE = re.compile(r"(?i)(/Users/|~/|\\|\bpogwin\b|\bimac\b|\.local\b|@|\b\d{1,3}(?:\.\d{1,3}){3}\b|codex-b|claude-b|"
                     r"claude-c|account-b|account B|account-c|dropbox|\bssh\b|\brcon\b|token|password)")


def shift_no(run):
    m = re.fullmatch(r"shift0*(\d+)", run or "")
    return int(m.group(1)) if m else None


def number(runs_dir, run, after=None):
    """The shift's number as the hosts and the agents count it (tools/shift_times.py: 1 + the resumed-from chain), from
    its run folder; for a NEXT not made yet, PREV's + 1 (after); else the number in its id (shiftN); else None."""
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import shift_times
        d = os.path.join(runs_dir, run)
        if os.path.isfile(os.path.join(d, "resumed-from")):
            return shift_times.shift_number(d)
        if after and os.path.isdir(os.path.join(runs_dir, after)):
            return shift_times.shift_number(os.path.join(runs_dir, after)) + 1
    except (ImportError, OSError, ValueError):
        pass
    n = shift_no(after)
    return n + 1 if n is not None and after else shift_no(run)


def usual_minutes(runs_dir, last=8):
    """The median of the last `last` changes: from the previous run's stop save (stopped.json stop_utc) to the last
    "agent ... in pane" line of the next run's start.log, plus a minute of stopping, rounded up; USUAL_MIN without
    any."""
    gaps = []
    for d in sorted(glob.glob(os.path.join(runs_dir, "shift*")), key=lambda p: shift_no(os.path.basename(p)) or -1):
        n = shift_no(os.path.basename(d))
        prev = os.path.join(runs_dir, f"shift{n - 1}") if n else None
        try:
            stop = json.load(open(os.path.join(prev, "stopped.json")))["stop_utc"]
            t0 = calendar.timegm(time.strptime(stop[:19], "%Y-%m-%dT%H:%M:%S"))   # UTC
            last_agent = [l for l in open(os.path.join(d, "start.log")) if re.match(r"\d\d:\d\d:\d\d agent \S+ .* in pane", l)][-1]
        except (OSError, ValueError, KeyError, IndexError, TypeError):
            continue
        hh, mm, ss = map(int, last_agent[:8].split(":"))
        lt = time.localtime(t0)
        t1 = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, hh, mm, ss, 0, 0, -1))
        if t1 < t0 - 3600:
            t1 += 86400   # past midnight
        if 0 < t1 - t0 < 3600:
            gaps.append(t1 - t0)
    gaps = gaps[-last:]
    if not gaps:
        return USUAL_MIN
    return int(-(-(statistics.median(gaps) + 60) // 60))


def lines(a, runs_dir):
    """(event key or None, the line)."""
    if a.cmd == "say":
        return None, a.text
    if a.cmd == "stop":
        what = a.what or "a planned restart"
        return None, f"The stream stops now for {what}; it should be back in about {a.minutes} minutes."
    k = number(runs_dir, a.next, getattr(a, "prev", None))
    nxt = f"shift {k}" if k is not None else "the next shift"
    if a.cmd == "change-begin":
        m = usual_minutes(runs_dir)
        n = number(runs_dir, a.prev)
        over = f"Shift {n} is over" if n is not None else "This shift is over"
        return f"begin:{a.next}", f"{over}; {nxt} starts in about {m} minutes."
    if a.cmd == "change-live":
        who = f": {a.agents} agent{'' if a.agents == 1 else 's'} playing" if a.agents > 0 else ""
        return f"live:{a.next}", f"{nxt[0].upper() + nxt[1:]} is live{who}."
    if a.cmd == "change-failed":
        return f"failed:{a.next}", f"The start of {nxt} has hit a problem; the operator is on it, and the stream stays off until it is fixed."
    if a.cmd == "change-stalled":
        return f"stalled:{a.next}", f"The start of {nxt} is taking longer than usual; the operator is on it."
    raise SystemExit(f"unknown command {a.cmd}")


def token():
    if os.environ.get("POG_LIVE_TOKEN"):
        return os.environ["POG_LIVE_TOKEN"]
    try:
        return json.load(open(os.path.join(ROOT, "site", "worker", ".secrets.json")))["PUBLISH_TOKEN"]
    except (OSError, ValueError, KeyError):
        return None


def post(api, tok, text, cid, timeout=10, tries=3):
    """(ok, detail)."""
    body = json.dumps({"text": text, **({"cid": cid} if cid else {})}).encode()
    err = ""
    for i in range(tries):
        req = urllib.request.Request(api.rstrip("/") + "/v1/announce", data=body, method="POST",
                                     headers={"Content-Type": "application/json", "Authorization": "Bearer " + tok,
                                              "User-Agent": "pog-announce"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                d = json.loads(r.read() or b"{}")
            m = d.get("message") or {}
            return True, f"seq {m.get('seq')}" + (", already posted" if d.get("repeat") else "")
        except urllib.error.HTTPError as e:
            err = f"HTTP {e.code}: {e.read()[:200].decode('utf-8', 'replace')}"
            if e.code < 500:
                break   # refused: trying again changes nothing
        except (urllib.error.URLError, OSError, ValueError) as e:
            err = str(getattr(e, "reason", e))
        if i + 1 < tries:
            time.sleep(float(os.environ.get("POG_ANNOUNCE_WAIT", "2")) * (i + 1))   # tests: 0
    return False, err


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--log")
    ap.add_argument("--runs", default=os.environ.get("POG_SC_RUNS") or os.path.join(ROOT, "runs"))
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("say").add_argument("text")
    st = sub.add_parser("stop")
    st.add_argument("--minutes", type=int, required=True)
    st.add_argument("--what")
    b = sub.add_parser("change-begin")
    b.add_argument("prev")
    b.add_argument("next")
    lv = sub.add_parser("change-live")
    lv.add_argument("next")
    lv.add_argument("--agents", type=int, required=True)
    for c in ("change-failed", "change-stalled"):
        sub.add_parser(c).add_argument("next")
    sub.add_parser("usual")
    a = ap.parse_args(argv)
    if not os.path.isdir(a.runs) and os.path.isdir(os.path.expanduser("~/code/player-of-games/runs")):
        a.runs = os.path.expanduser("~/code/player-of-games/runs")   # a worktree without the shifts
    if a.cmd == "usual":
        print(usual_minutes(a.runs))
        return 0

    def say(s):
        out = f"{time.strftime('%H:%M:%S')} announce: {s}"
        print(out, flush=True)
        if a.log:
            try:
                with open(a.log, "a") as f:
                    f.write(out + "\n")
            except OSError:
                pass

    key, text = lines(a, a.runs)
    text = " ".join(str(text).split())
    if not text:
        say("refused: an empty line")
        return 2
    m = PRIVATE.search(text)
    if m:
        say(f"refused: the line names {m.group(0)!r} (facts only, nothing private)")
        return 2
    if a.dry_run:
        say(f"would post: {text}")
        return 0
    api = os.environ.get("POG_ANNOUNCE_API")
    if os.environ.get("POG_TEST") == "1" and not api:
        say("refused: a test run (POG_TEST=1) posts only to POG_ANNOUNCE_API")
        return 2
    tok = token()
    if not tok:
        say("FAILED: no publish token (POG_LIVE_TOKEN or site/worker/.secrets.json)")
        return 1
    cid = hashlib.sha256(key.encode()).hexdigest()[:24] if key else None
    ok, detail = post(api or SITE_API, tok, text, cid)
    say(f"posted ({detail}): {text}" if ok else f"FAILED ({detail}): {text}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
