"""The site's polls on the stream (d16 17:15): serve.py puts `poll` in the snapshot from RUN/polls.json (site/polls_relay.py
keeps it fresh): the open polls with their counts, for the hosts, and `strip`, what the overlay shows under the chat
panel. No game chat lines: those reach the agents.

The strip, while a poll is open: about 30 s every 10 minutes from the poll's opening (question, the top counts, "Vote
at factorio.nickwinter.net"); when it closes: its result for 60 s. Two open polls take turns window by window. Intro and
option details stay off the stream.
"""
import json
import os
import re

EVERY_S, SHOW_S, RESULT_S = 600, 30, 60
RECENT_CLOSE_S = 600     # a result shows only for a poll that closed in the last 10 minutes (not after a restart)
STALE_S = 300            # older poll data: nothing on screen
HOSTS_GAP_S = 20 * 60    # the hosts mention the poll at most once in 20 minutes
URL = "factorio.nickwinter.net"
MENTION = re.compile(r"\b(poll|vote|votes|voting)\b", re.I)


def site_host():
    try:
        with open(os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "site", "config.json")) as f:
            url = json.load(f).get("site_url") or ""
        return re.sub(r"^https?://", "", url).rstrip("/") or URL
    except (OSError, ValueError):
        return URL


def rows(p, n=3):
    """The options with the most votes first: [{label, n, viewers, agents}]."""
    vc = p.get("viewer_counts") or p.get("counts") or []
    ac = p.get("agent_counts") or []
    out = [{"label": o, "n": (p.get("counts") or [])[i] if i < len(p.get("counts") or []) else 0,
            "viewers": vc[i] if i < len(vc) else 0, "agents": ac[i] if i < len(ac) else 0} for i, o in enumerate(p.get("options") or [])]
    return sorted(out, key=lambda r: -r["n"])[:n]


class PollStrip:
    def __init__(self, path, url=None):
        self.path = path
        self.url = url or site_host()
        self.mtime, self.data = None, None
        self.was_open = set()     # poll ids open at the last step
        self.queue = []           # polls closed since, their results not shown yet
        self.result = None        # (poll, until): a result on screen

    def load(self):
        try:
            m = os.path.getmtime(self.path)
        except OSError:
            self.data = None
            return
        if m != self.mtime:
            try:
                with open(self.path) as f:
                    self.data = json.load(f)
                self.mtime = m
            except (OSError, ValueError):
                pass

    def step(self, now):
        """The snapshot's `poll`: {open: [...], strip: {...} | None}, or None without fresh poll data."""
        if self.path:
            self.load()
        d = self.data
        if not d or now - float(d.get("fetched") or 0) > STALE_S:
            return None
        open_now = [p for p in d.get("open") or [] if p.get("status") == "open" and float(p.get("closes") or 0) > now]
        ids = {p["id"] for p in open_now}
        # closed since the last step (the list moved it, or its time ran out before the next read): its result, in turn
        listed = {p["id"]: p for p in (d.get("open") or []) + (d.get("closed") or [])}
        self.queue += [listed[i] for i in sorted(self.was_open - ids) if i in listed
                       and now - float(listed[i].get("closes") or 0) < RECENT_CLOSE_S]
        self.was_open = ids
        if self.result and now >= self.result[1]:
            self.result = None
        if not self.result and self.queue:
            self.result = (self.queue.pop(0), now + RESULT_S)
        strip = None
        if self.result:
            p = self.result[0]
            strip = {"kind": "result", "id": p["id"], "question": p.get("question"), "rows": rows(p),
                     "total": p.get("total", 0), "viewer_total": p.get("viewer_total", 0), "agent_total": p.get("agent_total", 0),
                     "url": self.url}
        else:
            # windows of SHOW_S every EVERY_S from the first open poll's opening; polls take turns
            if open_now:
                first = min(float(p.get("opens") or now) for p in open_now)
                k, into = divmod(max(0.0, now - first), EVERY_S)
                if into < SHOW_S:
                    p = sorted(open_now, key=lambda x: x["id"])[int(k) % len(open_now)]
                    strip = {"kind": "open", "id": p["id"], "question": p.get("question"), "rows": rows(p),
                             "total": p.get("total", 0), "viewer_total": p.get("viewer_total", 0),
                             "agent_total": p.get("agent_total", 0), "url": self.url,
                             "left_min": round((float(p["closes"]) - now) / 60)}
        return {"open": [{"id": p["id"], "question": p.get("question"), "options": p.get("options"),
                          "counts": p.get("counts"), "viewer_counts": p.get("viewer_counts"), "agent_counts": p.get("agent_counts"),
                          "total": p.get("total", 0), "viewer_total": p.get("viewer_total", 0), "agent_total": p.get("agent_total", 0),
                          "closes": p.get("closes")} for p in open_now], "strip": strip}


def host_facts(s, last_said, now, url=URL):
    """The hosts' fact about the open poll, or None: none open, or they mentioned one less than 20 minutes ago."""
    open_polls = ((s or {}).get("poll") or {}).get("open") or []
    if not open_polls or now - (last_said or 0) < HOSTS_GAP_S:
        return None
    p = open_polls[0]
    votes = {o: {"votes": p["counts"][i], "from_viewers": (p.get("viewer_counts") or p["counts"])[i],
                 "from_agents": (p.get("agent_counts") or [0] * len(p["counts"]))[i]} for i, o in enumerate(p.get("options") or [])}
    return {"question": p.get("question"), "options": votes, "total_votes": p.get("total", 0),
            "closes_in_minutes": max(0, round((float(p.get("closes") or now) - now) / 60)),
            "where_viewers_vote": url,
            "how_to_call_it": "a poll is open on the stream's site, and the agents vote too, counted apart: you may "
                              "mention it once in this exchange (the question, where to vote, the leading answer); "
                              "you will not get it again for 20 minutes"}


def mentioned(lines):
    return any(MENTION.search(l or "") for l in lines)
