#!/usr/bin/env python3
"""Push the stream service's state to the site's live API every few seconds (runs on the Mac). Stdlib only.

    python3 site/push_live.py                                   # serve.py on 127.0.0.1:8787, every 10 s
    python3 site/push_live.py --source http://127.0.0.1:8799/state.json --once --print

Reads tools/stream/serve.py's /state.json, keeps only the fields the live page shows (see docs/LIVE-API.md),
redacts e-mail addresses, local paths, key-like tokens and IP addresses from every string, and POSTs it to
API/v1/state with the publish token. The token comes from $POG_LIVE_TOKEN or site/worker/.secrets.json
(gitignored; never commit it).
"""
import argparse, fcntl, hashlib, json, os, re, sys, tempfile, time, urllib.error, urllib.request
from pathlib import Path

SITE = Path(__file__).resolve().parent
sys.path.insert(0, str(SITE))
sys.dont_write_bytecode = True
from build import clean, CONFIG, REPO  # noqa: E402  (same redaction rules as the static site)
import moderation  # noqa: E402  (site/moderation.py: viewer lines deleted on YouTube or listed by hand)
import terrain  # noqa: E402  (site/terrain.py: the map frames the site publishes under /live/terrain/)

AGENT_KEYS = ("name", "kind", "display_name", "color", "glyph", "motto", "profile_set", "model", "harness", "role",
              "alive", "activity", "action", "active", "position", "location", "last_said", "camera", "avatar",
              "combat", "died_at", "job", "job_from", "attention", "wait_line", "wait_reason",  # job_from: focus, plan (its team-plan line) or notes
              "job_label", "job_age_s", "job_tick",  # where the job comes from and its age (d20 batch54 N3)
              "surface", "where", "on_platform", "travel",  # where the body is: the map lists agents off Nauvis at its edge
              # (d20 batch70 AF3) its current work (watches, queue steps, standing order, repeating requests), its plan
              # line beside its focus, and stale flags on either (tools/stream/workcard.py)
              "work", "plan_line", "plan_line_label", "stale")
AGENT_WORK_BYTES = 12 * 1024  # the cards' work rows across every agent (state at most 256 KB; about 178 KB in shift53)
TOP_KEYS = ("now", "tick", "paused", "game_time", "title", "subtitle", "research", "production", "science", "alerts",
            "board", "basemap", "shift",
            "reminders",  # the team's reminder jobs (d15 batch5 group I): owner, message, next due, last result, states
            "chronicle",  # the agents' newest chronicle entries and the harness's events (fh chronicle; viewer Alex 22:24)
            "library")  # (d19 batch42 B4) the team's newest library entries, no strings (tools/stream/library.py): /blueprints/
ATTENTION_KEYS = ("kind", "text", "surface", "platform", "age_s", "dist", "far")
# What each agent carries, wears and builds (the harness's loadout read via serve.py; the agents page shows it)
LOADOUT_KEYS = ("health", "vehicle", "guns", "ammo", "selected_gun", "armor", "items", "item_kinds", "slots", "crafting",
                "building", "age_s")
CHAT_KEYS = ("seq", "tick", "from", "agent", "text", "t", "source")  # source: a relayed viewer's YouTube or site


def agent_work(agents, limit=AGENT_WORK_BYTES):
    """The cards' work rows within limit bytes: the last row of the agent with the most goes first."""
    size = lambda: sum(len(json.dumps(a.get("work") or [], ensure_ascii=False)) for a in agents)  # noqa: E731
    while size() > limit:
        a = max(agents, key=lambda a: len(a.get("work") or []))
        if not a.get("work"):
            break
        a["work"] = a["work"][:-1] or None
        a["work_cut"] = a.get("work_cut", 0) + 1
    return agents


def scrub(v):
    if isinstance(v, str):
        return clean(v)
    if isinstance(v, list):
        return [scrub(x) for x in v]
    if isinstance(v, dict):
        return {k: scrub(x) for k, x in v.items()}
    return v


CAMERA_LABELS = ("attack", "work", "segment")  # what a camera shows when it is not just following an agent
PLATFORM_KEYS = ("name", "where", "route", "state", "paused", "speed_kms",
                 "waited_s", "waited_more")  # (d22 batch75 AK2) game seconds at the planet it is at; more: at least that
FIGHT_RECENT_S = 120  # fights the map marks: reported in the last two minutes
WATCHING_STALE = 180  # a "watching now" reading older than this is unknown (caster.py WATCH_STALE)


def public_space(sp):
    """Space Age for the map's inset: planets reached, rockets, and each platform's place or route (every platform; no camera views,
    no moments: a few hundred bytes)."""
    if not sp or not sp.get("active"):
        return None
    return {"rockets": sp.get("rockets") or 0, "planets": sp.get("planets") or [], "summary": sp.get("summary"),
            "platforms": [{k: p[k] for k in PLATFORM_KEYS if p.get(k) is not None} for p in (sp.get("platforms") or [])]}


def public_fights(fights, now):
    """Fights still or lately reported (model.py `fights`): where, what, how long ago, and how many losses."""
    out = []
    for f in fights or []:
        p, age = f.get("position") or {}, now - (f.get("last") or 0)
        if age > FIGHT_RECENT_S or not isinstance(p.get("x"), (int, float)) or (p.get("surface") or "nauvis") != "nauvis":
            continue
        out.append({"kind": f.get("kind"), "text": f.get("text"), "position": {"x": round(p["x"], 1), "y": round(p["y"], 1)},
                    "extent": p.get("extent"), "age_s": round(age), "losses": len(f.get("losses") or [])})
    return out[-12:]


GROUP_KEYS = ("id", "surface", "size", "kinds", "state", "target_distance", "visible", "age_s", "label")
BIG_KEYS = ("id", "name", "surface", "speed", "closing", "nearest_distance", "eta_s", "label")
THREATS_MAX = 12  # groups and demolishers each (threat.lua keeps at most 12 demolishers)


def _xy(p):
    return {"x": round(p["x"]), "y": round(p["y"])} if isinstance(p, dict) and all(isinstance(p.get(k), (int, float)) for k in "xy") else None


def public_threats(incoming, big):
    """(d22 batch97 BG3) the enemy groups on their way (harness attack_groups_live via model.py `incoming`) and the
    demolishers near our buildings or agents (big_enemies_live, `big_enemies`), read every 2-10 s, for the live map's
    attacks layer: {incoming: [{id, surface, position, target, size, kinds, state, target_distance, visible, age_s,
    label}], big: [{id, name, surface, position, nearest {x, y, name}, speed, closing, nearest_distance, eta_s,
    label}]}, at most THREATS_MAX of each; None when there are none."""
    out = {}
    rows = []
    for g in incoming or []:
        if not isinstance(g, dict) or not _xy(g.get("position")):
            continue
        row = {k: g[k] for k in GROUP_KEYS if g.get(k) is not None}
        row["position"] = _xy(g["position"])
        if _xy(g.get("target")):
            row["target"] = _xy(g["target"])
        rows.append(row)
    if rows:
        out["incoming"] = rows[:THREATS_MAX]
    rows = []
    for e in big or []:
        if not isinstance(e, dict) or not _xy(e.get("position")):
            continue
        row = {k: e[k] for k in BIG_KEYS if e.get(k) is not None}
        row["position"] = _xy(e["position"])
        n = e.get("nearest")
        if _xy(n):
            row["nearest"] = dict(_xy(n), name=str(n.get("name") or ""))
        rows.append(row)
    if rows:
        out["big"] = rows[:THREATS_MAX]
    return out or None


VEHICLE_KEYS = ("unit_number", "name", "type", "surface", "age_s", "visible", "unseen", "driver", "remote", "sent_by",
                "sent_age_s", "route_targets")
VEHICLES_MAX = 64


def public_vehicles(v):
    """(d26 batch233 VM, viewer Aurora site:5019: "Could vehicle maps start with Spidertrons? ... Show ID, position age,
    controller and destination.") our vehicles where our force last saw them (model.vehicles_snapshot, from the census's
    vehicles read every 10 s): {rows: [{unit_number, name, type, surface, position, age_s (how old the position is),
    visible (its chunk in sight when read), unseen (never seen by the read: no position), driver (the agent in its driver
    seat, or "a player"), remote (the agent driving it by remote view), sent_by and sent_age_s (the agent that last sent
    it a route by remote view, and when), destination, route_targets}], total, read_age_s}, at most VEHICLES_MAX rows;
    None before a read or with none."""
    if not isinstance(v, dict) or not isinstance(v.get("rows"), list) or not v["rows"]:
        return None
    rows = []
    for r in v["rows"][:VEHICLES_MAX]:
        if not isinstance(r, dict) or not isinstance(r.get("unit_number"), int):
            continue
        row = {k: r[k] for k in VEHICLE_KEYS if r.get(k) is not None}
        for k in ("position", "destination", "remote_target"):
            p = r.get(k)
            if isinstance(p, dict) and all(isinstance(p.get(c), (int, float)) for c in "xy"):
                row[k] = {"x": round(p["x"], 1), "y": round(p["y"], 1)}
        rows.append(row)
    return {"rows": rows, "total": v.get("total") or len(rows), "read_age_s": v.get("read_age_s")} if rows else None


CLOUD_KEYS = ("surface", "label", "pollutant", "chunks", "max", "total", "age_s")
CLOUD_CELLS = 6000  # cells across all surfaces (about 14 bytes each; the state is at most 256 KB), most polluted kept


def public_nest(n):
    """A nest the cloud reached: where, and (d24 batch163, viewer Aurora 13:16) the game seconds since pollution was last
    there, whether it reaches it now, its status (alive, unknown) and game seconds since last in view, when the read has
    them."""
    out = {"x": n.get("x"), "y": n.get("y")}
    for k in ("ago_s", "reaches", "status", "seen_ago_s"):
        if n.get(k) is not None:
            out[k] = n[k]
    return out


def public_clouds(rows):
    """The map's pollution and spore layer (tools/stream/clouds.py): per surface its label, colour, the chunks
    [[cx, cy, amount]] and the nests it reached; past CLOUD_CELLS cells in all, the least polluted are left out."""
    rows = [r for r in rows or [] if isinstance(r, dict) and isinstance(r.get("cells"), list) and r["cells"]]
    keep = sorted(((c[2], i, j) for i, r in enumerate(rows) for j, c in enumerate(r["cells"])), reverse=True)[:CLOUD_CELLS]
    keep = {(i, j) for _, i, j in keep}
    out = []
    for i, r in enumerate(rows):
        col = r.get("color") or {}
        cells = [c for j, c in enumerate(r["cells"]) if (i, j) in keep]
        out.append(dict({k: r[k] for k in CLOUD_KEYS if r.get(k) is not None}, cells=cells,
                        color={k: col[k] for k in "rgba" if isinstance(col.get(k), (int, float))},
                        reached=[public_nest(n) for n in r.get("reached") or []][:20]))
    return out


YOUTUBE_MAX = 60       # YouTube lines in the state for the live page's chat pane (newest kept)
HIDDEN_EVERY = 60.0    # seconds between reads of the deletions and the hand-kept list
_hidden = {"t": None, "h": None}


def hidden_now(now=None):
    """moderation.Hidden for runs/*/viewer-deletions.jsonl and site/hidden-viewers.json, read at most every minute."""
    now = now or time.time()
    if _hidden["h"] is None or now - (_hidden["t"] or 0) >= HIDDEN_EVERY:
        try:
            _hidden["h"] = moderation.load(os.environ.get("POG_RUNS_DIR") or REPO / "runs",
                                           os.environ.get("POG_HIDDEN_VIEWERS") or SITE / "hidden-viewers.json")
        except OSError:
            _hidden["h"] = _hidden["h"] or moderation.Hidden()
        _hidden["t"] = now
    return _hidden["h"]


def public_youtube(viewers, hidden=None):
    """The YouTube lines of the stream service's viewer lane (tools/stream/viewers.py: only lines that passed its
    moderation, YouTube deletions it saw taken out), oldest first, the newest YOUTUBE_MAX: {id, name, text, t, staff?, host?}.
    Lines the site hides (a deletion from an earlier run, the hand-kept list) are left out. The live page joins them
    with the site's own comments in one time-ordered chat pane (Luna 13:54, a viewer's suggestion)."""
    rows = []
    for v in viewers or []:
        if not isinstance(v, dict) or v.get("source") != "youtube" or not v.get("text") or not isinstance(v.get("t"), (int, float)):
            continue
        if hidden and hidden.hides(v.get("name"), v.get("text")):
            continue
        row = {"id": str(v.get("id") or ""), "name": str(v.get("name") or "viewer"), "text": str(v["text"]), "t": round(v["t"], 1)}
        if v.get("staff"):
            row["staff"] = True
        if v.get("host"):
            row["host"] = True  # Nick's own channel (viewers.py names.HOST_YOUTUBE_CHANNEL): a HOST badge
        rows.append(row)
    rows.sort(key=lambda r: r["t"])
    return rows[-YOUTUBE_MAX:]


def public_haul(hauling):
    """(d17 batch35 D5, viewer Aurora 14:47) per agent its most repeated haul this shift and what feeds that destination
    without hands now (live.py's haul_feed read): {agent: {item, surface, to_name, times, items, feed}}."""
    out = {}
    feeds = (hauling or {}).get("feeds") or {}
    for r in (hauling or {}).get("rows") or []:
        top = r.get("top") or {}
        if not r.get("name") or (top.get("times") or 0) < 2:
            continue
        f = feeds.get(r["name"]) or {}
        row = {"item": top.get("item"), "surface": top.get("surface"), "to_name": top.get("to_name"),
               "times": top.get("times"), "items": top.get("items")}
        if f.get("item") == top.get("item") and f.get("line"):
            row["feed"] = clean(str(f["line"]))[:240]
        out[r["name"]] = row
    return out


def public_delivery(status, keep=150):
    """(d17 batch35 D1, viewer Aurora: four lines received and never relayed, no reason shown) each site line's delivery
    from the stream service's relay (viewers.py Feed.deliveries): {seq: {s: relayed|held|operator|not_relayed|expired (d20
    batch65 AA5: a line that waited too long for the service, or that no service ever read), to?, why?,
    to_all?: every recipient of a line to several agents, op?: 1 when it is in the operator's inbox too, lost?: 1 relayed
    with whom to lost at a stream service restart, at?: when it was sent, for a record read back after a restart}},
    the newest `keep`. YouTube lines are not keyed by a site seq and stay out."""
    out = {}
    for r in (status or {}).get("delivery") or []:
        i = str(r.get("id") or "")
        if not i.startswith("site:") or r.get("status") not in ("relayed", "held", "operator", "not_relayed", "expired"):
            continue
        row = {"s": r["status"]}
        if r.get("to"):
            row["to"] = str(r["to"])[:40]
        # (d19 batch42 A4) every agent the game took a group line for; (A3) in the operator's inbox too
        if r["status"] == "relayed" and isinstance(r.get("to_all"), list) and len(r["to_all"]) > 1:
            row["to_all"] = [str(n)[:40] for n in r["to_all"][:9]]
        if r.get("inbox"):
            row["op"] = 1
        if r.get("lost"):  # (d20 batch57 S5) relayed; whom to, lost at a stream service restart
            row["lost"] = 1
        if isinstance(r.get("sent_t"), (int, float)):  # restored from the relayed files: when it was sent
            row["at"] = round(r["sent_t"])
        if r.get("why"):  # (d19 batch43 A3) cut at a word end with "…" past 240 (it was cut mid-word at 120)
            why = str(r["why"])
            row["why"] = why if len(why) <= 240 else why[:239].rsplit(" ", 1)[0].rstrip(" ,;:") + "…"
        out[i[5:]] = row
    return dict(list(out.items())[-keep:])


REPLY_MAX = 40  # agents' replies to viewers in the state (newest kept); the live page's chat shows them
LINKS = ("reply_to", "name", "only_line", "only_to", "time", "none")  # name (AK6): the harness linked it by the name it says  # viewer_replies.classify's link


def public_replies(rows, hidden=None):
    """The agents' and the Operator's lines that answer a viewer or speak to the viewers (model.py viewer_replies,
    tools/stream/viewer_replies.py), oldest first, the newest REPLY_MAX: {seq, t, tick, by, text, kind, to, link?,
    answers?}.
    A reply to a line the site hides keeps its own words; that line and its viewer's name are left out."""
    out = []
    for r in rows or []:
        if not isinstance(r, dict) or not r.get("text") or not r.get("by") or not isinstance(r.get("t"), (int, float)):
            continue
        row = {"seq": r.get("seq"), "t": round(r["t"], 1), "tick": r.get("tick"), "by": str(r["by"]), "text": str(r["text"]),
               "kind": r.get("kind") or "reply", "to": [str(n) for n in r.get("to") or []]}
        if r.get("history"):  # (d19 batch42 A5) restored at a stream restart, with its own time
            row["history"] = True
        if r.get("link") in LINKS:  # (d20 batch57 S1) how its viewer line was found; "none": linked to no line
            row["link"] = r["link"]
        def answer(a):
            """A viewer line it answers, or None when the site hides that line (its viewer's name left out of `to`)."""
            if hidden and hidden.hides(a.get("name"), a.get("text")):
                row["to"] = [n for n in row["to"] if n.lower() != str(a["name"]).lower()]
                return None
            out = {"name": str(a["name"]), "text": str(a.get("text") or ""), "t": a.get("t"), "source": a.get("source")}
            # (d20 batch65 AA2) the line the Operator named; (d22 batch75 AK6) any line's own id where it was written
            if re.fullmatch(r"(site|yt):[\w.:=-]{1,110}", str(a.get("id") or "")):
                out["id"] = str(a["id"])
            return out
        a = r.get("answers")
        if isinstance(a, dict) and a.get("name"):
            a = answer(a)
            if a:
                row["answers"] = a
        also = [x for x in (answer(x) for x in (r.get("also") or [])[:7] if isinstance(x, dict) and x.get("name")) if x]
        if also:  # (AK6) the other lines one reply answers
            row["also"] = also
        p = r.get("part")  # (AA2) one of a split reply's parts: [k, n]
        if isinstance(p, list) and len(p) == 2 and all(isinstance(x, int) for x in p) and 1 <= p[0] <= p[1] and p[1] > 1:
            row["part"] = p
        out.append(row)
    out.sort(key=lambda r: r["t"])
    return out[-REPLY_MAX:]


BOARD_BYTES = 48 * 1024  # the board's share of the state (MAX_STATE_BYTES 256 KB in the worker)


def public_board(board):
    """The board as the stream service gives it, its projects' steps kept within BOARD_BYTES (d15: steps for the live
    page's projects): over it, the finished projects' steps go first, then the hidden ones' (they keep progress and next
    step), then the card's own are cut to their next 5."""
    if not isinstance(board, dict):
        return board
    b = dict(board)
    size = lambda: len(json.dumps(b, ensure_ascii=False))
    for key, keep in (("projects_done", 0), ("projects_more", 0), ("projects", 5)):
        if size() <= BOARD_BYTES:
            break
        rows = []
        for p in b.get(key) or []:
            p = dict(p)
            if p.get("steps"):
                steps = [x for x in p["steps"] if not x.get("done")][:keep] if keep else []
                p["steps"] = steps
                p["steps_cut"] = True
                if not steps:
                    del p["steps"]
            rows.append(p)
        if key in b:
            b[key] = rows
    # (d19 batch43 A2) still over: each item keeps its newest evidence line (whole) and says how many older it had
    if size() > BOARD_BYTES:
        for key in ("projects_done", "projects_more", "projects", "claims", "open_items", "doing_items"):
            if isinstance(b.get(key), list):
                b[key] = [newest_evidence(r) for r in b[key]]
    return b


def newest_evidence(row):
    """A row with only its newest evidence line, and evidence_more: how many older ones were left out."""
    ev = row.get("evidence") if isinstance(row, dict) else None
    if not isinstance(ev, list) or len(ev) <= 1:
        return row
    return dict(row, evidence=ev[-1:], evidence_more=len(ev) - 1)


def same_result(row, x):
    """A recipient's latest result is the job's last result: equal, or (tools/stream/model.py cuts a recipient's to
    LATEST_RESULT characters with "...") the last result's author's, and its start."""
    r, last = x.get("result"), row.get("last_result")
    return bool(r) and isinstance(last, str) and (r == last or (x.get("name") == row.get("result_by") and r.endswith("...")
                                                               and len(r) > 3 and last.startswith(r[:-3])))


RESULT_FIRST = 100  # characters of the first recipient's result kept when the results are left out


def latest_without_results(row, same_only):
    """A reminder job with its recipients' latest results left out (same_only: only those equal to its last result).
    (d24 batch150 PV1, viewer Aurora 07:31: reminder 42 read "no result given" in the collapsed view while both
    recipients had results) each row left out says so: result_omitted "same" (the job's last result, kept whole) or
    "size"; the job keeps results_given (how many recipients gave one) and result_first (the first: same, the job's last
    result; else its first RESULT_FIRST characters, shortened said)."""
    latest = row.get("latest") if isinstance(row, dict) else None
    if not isinstance(latest, list):
        return row
    cut = lambda x: isinstance(x, dict) and x.get("result") and (not same_only or same_result(row, x))  # noqa: E731
    if not any(cut(x) for x in latest):
        return row
    out = dict(row, latest=[dict(x, result=None, result_omitted="same" if same_result(row, x) else "size") if cut(x) else x
                            for x in latest])
    if "results_given" not in row:
        given = [x for x in latest if isinstance(x, dict) and (x.get("result") or x.get("result_omitted"))]
        out["results_given"] = len(given)
        first = given[0]
        text = first.get("result")
        if first.get("result_omitted") == "same" or same_result(row, first):
            out["result_first"] = {"name": first.get("name"), "agent": first.get("agent"), "same": True}
        elif text:
            out["result_first"] = {"name": first.get("name"), "agent": first.get("agent"), "text": text[:RESULT_FIRST - 3].rstrip() + "..."
                                   if len(text) > RESULT_FIRST else text, "shortened": len(text) > RESULT_FIRST}
    return out


REMINDER_BYTES = 24 * 1024  # the reminders' share of the state: results up to 1000 characters, evidence lines


REMINDERS_SHOWN = 12  # the panel's first view (live.js REM_SHOWN); "Show all" opens the rest


def public_reminders(rem):
    """(d19 batch43 A2) the reminder jobs with their results and evidence whole, within REMINDER_BYTES: over it, each
    job keeps its newest evidence line (evidence_more says how many older). (d20 batch65 AA4, viewer Aurora 08:56) The
    whole list rides along for the panel's "Show all" (25 jobs on world n at 09:10: 21 KB); still over, jobs past the
    first REMINDERS_SHOWN go, finished ones first, then the last; total keeps the count, and the page says how many
    were not sent."""
    if not isinstance(rem, dict) or not isinstance(rem.get("jobs"), list):
        return rem
    out = dict(rem)
    size = lambda: len(json.dumps(out, ensure_ascii=False))  # noqa: E731
    if size() > REMINDER_BYTES:
        out["jobs"] = [newest_evidence(j) for j in out["jobs"]]
    # (d20 batch70 AF2) still over: each recipient's latest result goes where it repeats the job's last result, then
    # every one (their state, ages and runs missed stay)
    for same_only in (True, False):
        if size() > REMINDER_BYTES:
            out["jobs"] = [latest_without_results(j, same_only) for j in out["jobs"]]
    if size() > REMINDER_BYTES:
        head, tail = out["jobs"][:REMINDERS_SHOWN], list(out["jobs"][REMINDERS_SHOWN:])
        # (d24 batch177) finished: done and off (an enabled job is active whatever its last run)
        fin = lambda j: isinstance(j, dict) and bool(j.get("done")) and not j.get("enabled")  # noqa: E731
        drop = [i for i in reversed(range(len(tail))) if fin(tail[i])] + [i for i in reversed(range(len(tail))) if not fin(tail[i])]
        gone = set()
        for i in drop:
            if size() <= REMINDER_BYTES:
                break
            gone.add(i)
            out["jobs"] = head + [j for k, j in enumerate(tail) if k not in gone]
        out.setdefault("total", len(rem["jobs"]))
    return out


# (d22 batch99 BI3, viewer Aurora site:4316: "Could the board show all tasks and reminders, with paging if needed?
# Hidden jobs and the nine omitted reminders make it hard to check what's actually finished.") The state keeps its
# first view (BOARD_BYTES, REMINDER_BYTES: 20 doing of 36, 19 reminders of 31 on world n at 16:20); every task,
# request, claim, project and reminder goes in a document of its own (serve.py /board.json -> worker /v1/board), sent
# when it changed and at most every BOARD_EVERY seconds, which the live page reads when a full list is opened.
BOARD_ALL_BYTES = 240 * 1024  # the worker takes 256 KB a document
BOARD_EVERY, BOARD_STALE = 30.0, 300.0  # seconds: at most this often when it changed; at least this often anyway


def public_board_all(doc, limit=BOARD_ALL_BYTES):
    """The full board document within `limit`: over it, each row keeps its newest evidence line, then the finished
    projects lose their steps, then the reminders their recipients' results, then the oldest tasks go (items_total
    keeps the count)."""
    if not isinstance(doc, dict):
        return doc
    out = dict(doc)
    size = lambda: len(json.dumps(out, ensure_ascii=False, separators=(",", ":")))  # noqa: E731
    if size() > limit:
        for key in ("items", "claims", "projects", "reminders"):
            out[key] = [newest_evidence(r) for r in out.get(key) or []]
    if size() > limit:
        out["projects"] = [dict(p, steps=None, steps_cut=True) if p.get("status") in ("done", "dropped") and p.get("steps")
                           else p for p in out.get("projects") or []]
    for same_only in (True, False):
        if size() > limit:
            out["reminders"] = [latest_without_results(j, same_only) for j in out.get("reminders") or []]
    while size() > limit and out.get("items"):
        out["items"] = out["items"][:max(0, len(out["items"]) - max(1, len(out["items"]) // 10))]
    return out


def board_url(source):
    """serve.py's /board.json beside its /state.json."""
    return re.sub(r"/state\.json$", "", source.rstrip("/")) + "/board.json"


PLANET_MAP_KEYS = ("surface", "tick", "cell", "x0", "y0", "w", "h", "rows", "buildings", "core")
CORE_KEYS = ("cell", "x0", "y0", "w", "h", "rows")
_RUN = re.compile(r"([^0-9])\1{2,}")


def pack(g):
    """A grid {cell, x0, y0, w, h, rows} with its rows run-length packed (d21 batch68 AD1, viewer Aurora: room in the
    state for each planet's dense core): three or more of a letter as the count and the letter ("....AAAA" ->
    "4.4A"), rle: 1; static/mapview.js unpacks it. Category and ore letters are never digits. Anything else as it is."""
    if not isinstance(g, dict) or not isinstance(g.get("rows"), list) or g.get("rle"):
        return g
    return dict(g, rows=[_RUN.sub(lambda m: f"{len(m.group(0))}{m.group(1)}", r) if isinstance(r, str) else r for r in g["rows"]], rle=1)


PLANET_CORE_BYTES = 12 * 1024  # (AD1) a planet's packed core a push at most; a bigger one is sent at twice the cell
RANK = {"D": 13, "W": 12, "R": 11, "O": 10, "A": 9, "S": 8, "M": 7, "E": 6, "L": 5, "I": 4, "B": 3, "T": 2, "P": 1}  # census.lua's


def coarser(g, rank=RANK):
    """A grid at twice its cell: each new cell the most telling of the four it covers (census.lua RANK, or rank)."""
    c, c2 = g["cell"], g["cell"] * 2
    nx0, ny0 = (g["x0"] // c2) * c2, (g["y0"] // c2) * c2
    ox, oy = (g["x0"] - nx0) // c, (g["y0"] - ny0) // c
    cells = {}
    for j, row in enumerate(g["rows"]):
        for i, ch in enumerate(row):
            if ch == ".":
                continue
            k = ((i + ox) // 2, (j + oy) // 2)
            if k not in cells or rank.get(ch, 0) > rank.get(cells[k], 0):
                cells[k] = ch
    w, h = (g.get("w", 0) + ox + 1) // 2, (len(g["rows"]) + oy + 1) // 2
    rows = ["".join(cells.get((i, j), ".") for i in range(w)).rstrip(".") for j in range(h)]
    return dict(g, cell=c2, x0=nx0, y0=ny0, w=w, h=h, rows=rows)


def fitted(core, limit=PLANET_CORE_BYTES):
    """core packed, at twice the cell until it fits limit bytes (at most 8 tiles a cell)."""
    out = pack(core)
    while len(json.dumps(out, separators=(",", ":"))) > limit and core["cell"] < 8:
        core = coarser(core)
        out = pack(core)
    return out


TERRAIN_GRID_KEYS = ("cell", "x0", "y0", "w", "h", "rows", "palette", "chunks", "tick", "oldest_tick", "t", "age_s")
TERRAIN_GRID_BYTES = 96 * 1024


def public_terrain_grid(g, limit=TERRAIN_GRID_BYTES):
    """(d22 batch75 AK9) the state's terrain_grid packed (pack), its palette checked; None when it has no rows or is
    over limit bytes packed (the map shows the frames alone)."""
    if not isinstance(g, dict) or not isinstance(g.get("rows"), list) or not g["rows"]:
        return None
    pal = [p for p in g.get("palette") or [] if isinstance(p, list) and len(p) == 3 and isinstance(p[0], str) and len(p[0]) == 1
           and not p[0].isdigit() and isinstance(p[1], str) and re.fullmatch(r"#[0-9a-f]{6}", p[1])]
    out = pack(dict({k: g[k] for k in TERRAIN_GRID_KEYS if k in g}, palette=pal))
    if len(json.dumps(out, separators=(",", ":"))) > limit:
        return None
    return out


def public_basemap(bm):
    """The basemap with its coarse grid, dense core and ore packed (pack)."""
    if not isinstance(bm, dict):
        return bm
    out = pack(bm)
    for k in ("core", "ore"):
        if isinstance(bm.get(k), dict):
            out[k] = pack(bm[k])
    return out
_planet_turn = {"i": 0}
PLANET_MAPS_BYTES = 24 * 1024  # (d22 batch75 AK1) the other planets' maps sent beside the one in turn, at most


def public_planet_map(m, name):
    out = pack({k: m[k] for k in PLANET_MAP_KEYS if k in m} | {"surface": name})
    if isinstance(m.get("core"), dict) and isinstance(m["core"].get("rows"), list) and m["core"]["rows"]:
        out["core"] = fitted({k: m["core"][k] for k in CORE_KEYS if k in m["core"]})  # (AD1) its footprints, as Nauvis's core
    else:
        out.pop("core", None)
    return out


def public_planets(maps, limit=PLANET_MAPS_BYTES):
    """The other planets' coarse maps (viewers craigNZ830 and Foobator, d15 07:05): planets [{surface, tick, buildings}]
    for all of them, planet_map, one of them in turn each push, and (d22 batch75 AK1, viewer Aurora: "Planet buttons
    and network layers disappear between refreshes") planet_maps {surface: map}, the others after it in turn while
    they fit limit bytes, so a page just loaded has every planet's buttons and map at once (packed, a planet's map is
    2-4 KB; the page keeps the ones it has seen)."""
    if not isinstance(maps, dict) or not maps:
        return None, None, None
    names = sorted(k for k, m in maps.items() if isinstance(m, dict) and isinstance(m.get("rows"), list))
    if not names:
        return None, None, None
    listing = [{"surface": n, "tick": maps[n].get("tick"), "buildings": maps[n].get("buildings")} for n in names]
    i = _planet_turn["i"] % len(names)
    _planet_turn["i"] += 1
    out = public_planet_map(maps[names[i]], names[i])
    others, room = {}, limit
    for name in names[i + 1:] + names[:i]:
        m = public_planet_map(maps[name], name)
        size = len(json.dumps(m, separators=(",", ":"))) + len(name) + 4
        if size > room:
            break
        others[name], room = m, room - size
    return listing, out, others or None


NET_MAP_BYTES = 20 * 1024  # (d21 batch68 AD3) a planet's networks map a push at most (one planet a push, in turn)
NET_GRID_BYTES = 6 * 1024  # its electric grid's share: a bigger one is sent at twice the cell (up to 32 tiles)
NET_LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"  # netmap.lua's, most poles first; '*' the others
NET_RANK = {c: len(NET_LETTERS) - i for i, c in enumerate(NET_LETTERS)}
_UNRUN = re.compile(r"(\d+)(\D)")
ELECTRIC_KEYS = ("cell", "x0", "y0", "w", "h", "rows", "rle", "nets", "poles", "more", "more_poles", "outside", "capped")
LOGISTIC_KEYS = ("id", "lr", "cr", "n", "ports", "odd", "robots")
_net_turn = {"i": 0}


def unpacked(g):
    """A grid's rows as one letter a cell (pack's runs spelt out)."""
    if not g.get("rle"):
        return g
    out = dict(g, rows=[_UNRUN.sub(lambda m: m.group(2) * int(m.group(1)), r) for r in g["rows"]])
    out.pop("rle", None)
    return out


def _trim_groups(text, keep):
    """A netmap item's groups ("kind,net,count,amount,unpowered,x0,y0,x1,y1[,x,y]...;...") with at most keep positions."""
    if not isinstance(text, str) or not text:
        return ""
    out = []
    for grp in text.split(";"):
        f = grp.split(",")
        out.append(",".join(f[:7] if len(f) <= 7 else f[:9 + 2 * keep]))
    return ";".join(out)


def public_net_map(m, limit=NET_MAP_BYTES):
    """A planet's networks map for the live page (netmap.lua via the stream service): electric {cell, x0, y0, w, h,
    rows (packed), nets "id,letter,poles;...", poles, more, more_poles, outside, capped} (the grid at twice the cell until
    it fits NET_GRID_BYTES: `cell_from` its own), logistic [{id, lr, cr, n, ports "x,y;...", odd, robots}], items [[name,
    sources, consumers]] (each group's positions cut to 1, then none, then items left out, those no consumer here takes
    first: `positions`, `left_out`), within limit bytes."""
    if not isinstance(m, dict) or not isinstance(m.get("surface"), str):
        return None
    out = {k: m[k] for k in ("surface", "tick", "age_s", "research", "items_capped", "ports_capped") if m.get(k) is not None}
    e = m.get("electric") if isinstance(m.get("electric"), dict) else {}
    el = {k: e[k] for k in ELECTRIC_KEYS if e.get(k) is not None}
    if isinstance(el.get("rows"), list) and el["rows"] and isinstance(el.get("cell"), int):
        g, cell0 = unpacked(el), el["cell"]
        packed = pack(g)
        while len(json.dumps(packed, separators=(",", ":"))) > NET_GRID_BYTES and g["cell"] < 32:
            g = coarser(g, NET_RANK)
            packed = pack(g)
        el = dict(packed, cell_from=cell0) if g["cell"] != cell0 else packed
    else:
        el.pop("rows", None)
    if not isinstance(el.get("nets"), str):
        el["nets"] = ""
    out["electric"] = el
    lg = m.get("logistic") if isinstance(m.get("logistic"), list) else []  # (table_to_json writes an empty list as {})
    out["logistic"] = [{k: n[k] for k in LOGISTIC_KEYS if n.get(k) is not None} for n in lg if isinstance(n, dict)]
    items = [i for i in (m.get("items") if isinstance(m.get("items"), list) else [])
             if isinstance(i, list) and len(i) == 3 and isinstance(i[0], str)]
    size = lambda x: len(json.dumps(x, separators=(",", ":")))
    room = limit - size(out) - 64
    keep = 4
    rows = items
    for keep in (4, 1, 0):
        rows = [[i[0], _trim_groups(i[1], keep), _trim_groups(i[2], keep)] for i in items]
        if size(rows) <= room:
            break
    if size(rows) > room:
        # left out first: items no consumer here takes, then the last by name
        order = sorted(range(len(rows)), key=lambda j: (bool(rows[j][2]), -j))
        left = set()
        total = size(rows)
        for j in order:
            if total <= room:
                break
            left.add(j)
            total -= size(rows[j]) + 1
        rows = [r for j, r in enumerate(rows) if j not in left]
        out["left_out"] = len(left)
    out["items"], out["positions"] = rows, keep
    return out


def public_net_maps(maps):
    """Every planet's networks map listed [{surface, tick}], and one of them in full each push, in turn (the page keeps
    the ones it has seen)."""
    if not isinstance(maps, dict) or not maps:
        return None, None
    names = sorted(k for k, m in maps.items() if isinstance(m, dict))
    if not names:
        return None, None
    name = names[_net_turn["i"] % len(names)]
    _net_turn["i"] += 1
    return [{"surface": n, "tick": maps[n].get("tick")} for n in names], public_net_map(dict(maps[name], surface=name))


LIBRARY_AREAS_BYTES = 16 * 1024  # (AD2) the placed library areas' share of a push; the oldest areas go first
AREA_KEYS = ("name", "surface", "box", "tick", "by", "entities", "description", "saved_tick", "placed_save", "deleted")
HOOK_KEYS = ("b", "p", "i", "e", "g", "n", "open", "t", "capped", "error", "too_big", "gone")


def public_library_areas(la):
    """The team library's placed areas for the live map (d21 batch68 AD2, viewer Aurora; libareas.lua via the stream
    service): {tick, age_s, placements, areas [{name, surface, box [l, t, r, b], tick (placed), by, entities,
    description, saved_tick (the entry's save now), placed_save (the save placed), deleted, retired {by, reason,
    replaced_by, tick}, check {id, name, state, tick}, hookups {b [in joined, in open, out joined, out open],
    p [joined, open], i [in joined, in open, out joined, out open], e [poles, wired out, no power, low power], g (ghosts), n (built),
    open [[x, y, what]], t}}]}, newest first, at most LIBRARY_AREAS_BYTES (the oldest areas left out: `left_out`)."""
    if not isinstance(la, dict) or not isinstance(la.get("areas"), list):
        return None
    rows = []
    for a in la["areas"]:
        if not isinstance(a, dict) or not isinstance(a.get("box"), list) or len(a["box"]) != 4:
            continue
        row = {k: a[k] for k in AREA_KEYS if a.get(k) is not None}
        if isinstance(a.get("retired"), dict):
            row["retired"] = {k: a["retired"][k] for k in ("by", "reason", "replaced_by", "tick") if a["retired"].get(k) is not None}
        if isinstance(a.get("check"), dict):
            row["check"] = {k: a["check"][k] for k in ("id", "name", "state", "tick") if a["check"].get(k) is not None}
        if isinstance(a.get("hookups"), dict):
            row["hookups"] = {k: a["hookups"][k] for k in HOOK_KEYS if a["hookups"].get(k) is not None}
            if not isinstance(row["hookups"].get("open"), list):  # table_to_json writes an empty table as {}
                row["hookups"]["open"] = []
        rows.append(row)
    out = {k: la[k] for k in ("tick", "age_s", "placements") if la.get(k) is not None}
    while rows and len(json.dumps(rows, separators=(",", ":"))) > LIBRARY_AREAS_BYTES:
        rows.pop()
    out["areas"] = rows
    if len(rows) < len(la["areas"]):
        out["left_out"] = len(la["areas"]) - len(rows)
    return out


def public_state(s):
    out = {k: s[k] for k in TOP_KEYS if k in s}
    planets, planet_map, others = public_planets(s.get("planet_maps"))
    if planets:
        out["planets"], out["planet_map"] = planets, planet_map
    if others:
        out["planet_maps"] = others
    if "basemap" in out:
        out["basemap"] = public_basemap(out["basemap"])
        # (d22 batch75 AK9) the charted ground under it (tools/stream/terrain_grid.py), packed; dropped past its byte cap
        tg = public_terrain_grid(s.get("terrain_grid"))
        if tg:
            out["basemap"] = dict(out["basemap"], terrain_grid=tg)
    areas = public_library_areas(s.get("library_areas"))
    if areas:
        out["library_areas"] = areas
    nets, net_map = public_net_maps(s.get("net_maps"))
    if nets:
        out["net_maps"], out["net_map"] = nets, net_map
    if "board" in out:
        out["board"] = public_board(out["board"])
    if "reminders" in out:
        out["reminders"] = public_reminders(out["reminders"])
    out["agents"] = [{k: a[k] for k in AGENT_KEYS if k in a} for a in s.get("agents", [])]
    agent_work(out["agents"])
    for a in out["agents"]:  # the map's line from the character to where it last looked or worked
        t = a.get("attention")
        if t:
            p = t.get("position") or {}
            a["attention"] = dict({k: t[k] for k in ATTENTION_KEYS if t.get(k) is not None},
                                  **({"position": {"x": round(p["x"], 1), "y": round(p["y"], 1)}} if "x" in p else {}))
    loadouts = s.get("loadouts") or {}
    hauls = public_haul(s.get("hauling"))
    for a in out["agents"]:
        lo = loadouts.get(a.get("name"))
        if isinstance(lo, dict) and lo.get("alive"):
            a["loadout"] = {k: lo[k] for k in LOADOUT_KEYS if lo.get(k) is not None}
        if hauls.get(a.get("name")):
            a["haul"] = hauls[a["name"]]
    out["chat"] = [{k: c[k] for k in CHAT_KEYS if k in c} for c in s.get("chat", [])[-40:]]
    out["cameras"] = {slot: dict({"agents": c.get("agents", []), "pair": c.get("pair", False), "since": c.get("since")},
                                 **{k: c[k] for k in CAMERA_LABELS if c.get(k)})
                      for slot, c in (s.get("cameras") or {}).items()}
    space = public_space(s.get("space"))
    if space:
        out["space"] = space
    if s.get("fights"):
        out["fights"] = public_fights(s["fights"], s.get("now") or time.time())
    if s.get("clouds"):
        out["clouds"] = public_clouds(s["clouds"])
    threats = public_threats(s.get("incoming"), s.get("big_enemies"))
    if threats:
        out["threats"] = threats
    vehicles = public_vehicles(s.get("vehicles"))
    if vehicles:
        out["vehicles"] = vehicles
    yt = public_youtube(s.get("viewers"), hidden_now())
    if yt:
        out["youtube_chat"] = yt
    vd = public_delivery(s.get("viewers_status"))
    if vd:
        out["viewer_delivery"] = vd
    # (d20 batch65 AA5) the site seq the stream service has read up to: a later line with no delivery is queued (the page
    # says so, and that the service is not running when this state is old)
    site = ((s.get("viewers_status") or {}).get("site") or {})
    if isinstance(site.get("after"), int) and not isinstance(site.get("after"), bool):
        out["viewer_read"] = {"after": site["after"]}
    vr = public_replies(s.get("viewer_replies"), hidden_now())
    if vr:
        out["viewer_replies"] = vr
    # The broadcast the stream service's YouTube chat bridge follows, so the live page embeds the current one.
    yt = ((s.get("viewers_status") or {}).get("youtube") or {})
    if re.fullmatch(r"[\w-]{11}", str(yt.get("video") or "")):
        out["stream"] = {"youtube_video_id": yt["video"]}
    # YouTube's "watching now" (viewers.py poll_watching, once a minute); left out when unknown or older than 3 minutes
    n, t = yt.get("watching"), yt.get("watching_t")
    if isinstance(n, int) and not isinstance(n, bool) and n >= 0 and isinstance(t, (int, float)) \
            and (s.get("now") or time.time()) - t <= WATCHING_STALE:
        out["watching"] = {"youtube": n, "t": round(t)}
    out["schema"] = 1
    return scrub(out)


TERRAIN_EVERY = 300.0  # seconds between reads of the site's terrain index
_terrain = {"t": None, "rows": [], "error": None}


def site_terrain(site_url, now=None, opener=urllib.request.urlopen):
    """basemap.terrain: the map frames the deployed site has (its /live/terrain/index.json, site/terrain.py), read at
    most every 5 minutes; the last list stays when a read fails (a 404: none published yet), and the push log's ok
    line says why. (d19 batch42 B3, viewer Aurora) The site's host answers urllib's own User-Agent with 403, so every
    read failed and the live map never had the frames: the read names itself, as the state push does."""
    now = time.time() if now is None else now
    if site_url and (_terrain["t"] is None or now - _terrain["t"] >= TERRAIN_EVERY):
        _terrain["t"] = now
        req = urllib.request.Request(site_url.rstrip("/") + terrain.URL + "index.json", headers={"User-Agent": "pog-push-live/1"})
        try:
            with opener(req, timeout=5) as r:
                _terrain["rows"], _terrain["error"] = terrain.live(json.load(r)), None
        except (urllib.error.URLError, OSError, ValueError) as e:
            _terrain["error"] = f"{type(e).__name__}: {e}"[:120]
    return _terrain["rows"]


CHART_EVERY = 60.0  # seconds between reads of the deployed chart's index (11 KB; batch241: was 300)
CHART_URL = "/live/chart/index.json"
_chart = {"t": None, "v": None, "tick": None, "surfaces": [], "complete": [], "error": None}


def site_chart(site_url, now=None, opener=urllib.request.urlopen):
    """(d22 batch97 BG3) the chart the deployed site has (site/build.py publishes runs/RUN/chart/out/ under /live/chart/):
    {v, tick, surfaces, complete} from its index.json (surfaces: those with cells; complete: those whose first pass is
    done, every charted chunk read; cp7), read at most every minute (site/chart_deploy.py deploys a changed chart within
    two); the last one stays when a read fails (a 404:
    none published yet). The page fetches the index again when v changes."""
    now = time.time() if now is None else now
    if site_url and (_chart["t"] is None or now - _chart["t"] >= CHART_EVERY):
        _chart["t"] = now
        req = urllib.request.Request(site_url.rstrip("/") + CHART_URL, headers={"User-Agent": "pog-push-live/1"})
        try:
            with opener(req, timeout=5) as r:
                idx = json.load(r)
            sf = idx.get("surfaces") if isinstance(idx, dict) else None
            if isinstance(idx.get("v"), int) and isinstance(sf, dict):
                _chart.update(v=idx["v"], tick=idx.get("tick") if isinstance(idx.get("tick"), int) else None,
                              surfaces=sorted(k for k, x in sf.items() if isinstance(x, dict) and x.get("cells")),
                              complete=sorted(k for k, x in sf.items() if isinstance(x, dict) and x.get("cells") and x.get("complete") is True),
                              error=None)
        except (urllib.error.URLError, OSError, ValueError, AttributeError) as e:
            _chart["error"] = f"{type(e).__name__}: {e}"[:120]
    return dict(v=_chart["v"], tick=_chart["tick"], surfaces=_chart["surfaces"], complete=_chart["complete"]) if _chart["v"] is not None else None


BASEMAP_CHARTED = ("rows", "core", "ore", "terrain_grid", "terrain")  # what the chart replaces on a charted Nauvis


def with_chart(state, chart):
    """The state with chart {v, tick, surfaces, complete}, and the coarse grids the published chart replaces taken out,
    only for the surfaces whose published chart is complete (cp7, viewer Aurora 21:36: a chart of six cells hid
    Nauvis's terrain and buildings elsewhere; the page draws these grids under the chart, showing where no cell is
    read): on Nauvis the basemap's rows, dense core, ore, charted ground and terrain frames (its box, nests, turrets
    and turret states stay); every other complete planet's coarse map (the planets listing stays). `saved` says how
    many bytes."""
    if not chart:
        return state
    size = lambda x: len(json.dumps(x, separators=(",", ":")))  # noqa: E731
    state["chart"] = dict(chart, saved=0)
    before = size(state)
    charted = set(chart.get("complete") or [])
    bm = state.get("basemap")
    if "nauvis" in charted and isinstance(bm, dict):
        core = bm.get("core") if isinstance(bm.get("core"), dict) else None
        out = {k: v for k, v in bm.items() if k not in BASEMAP_CHARTED}
        if core and all(isinstance(core.get(k), int) for k in ("cell", "x0", "y0", "w")):
            h = core.get("h") if isinstance(core.get("h"), int) else len(core.get("rows") or [])
            out["core_box"] = [core["x0"], core["y0"], core["x0"] + core["w"] * core["cell"], core["y0"] + h * core["cell"]]
        state["basemap"] = out
    if isinstance(state.get("planet_map"), dict) and state["planet_map"].get("surface") in charted:
        del state["planet_map"]
    if isinstance(state.get("planet_maps"), dict):
        left = {k: v for k, v in state["planet_maps"].items() if k not in charted}
        if left:
            state["planet_maps"] = left
        else:
            del state["planet_maps"]
    state["chart"]["saved"] = before - size(state)
    return state


def with_terrain(state, rows):
    """The state with basemap.terrain (only beside a basemap: the viewer draws frames under the buildings)."""
    if rows and isinstance(state.get("basemap"), dict):
        state["basemap"] = dict(state["basemap"], terrain=rows)
    return state


def token():
    t = os.environ.get("POG_LIVE_TOKEN")
    if t:
        return t
    p = SITE / "worker" / ".secrets.json"
    try:
        return json.loads(p.read_text())["PUBLISH_TOKEN"]
    except (OSError, KeyError, ValueError):
        sys.exit("no token: set POG_LIVE_TOKEN or create site/worker/.secrets.json (see site/README.md)")


# (d22 batch89 AY2) one pusher at a time: on d22 a copy started at 10:11 by hand kept pushing beside shift58's own,
# every state twice, from code loaded an hour before. A second copy finds the lock held and exits, saying which pid
# holds it; the lock goes with the process (flock), so a crash leaves nothing to clear. --once and --print take none.
LOCK = os.environ.get("POG_PUSH_LIVE_LOCK") or os.path.join(tempfile.gettempdir(), "pog-push-live.lock")


def take_lock(path=None):
    """(the open lock file, held while it stays open, None) or (None, what the holder wrote: "PID since HH:MM:SS")."""
    f = open(path or LOCK, "a+")
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        f.seek(0)
        held = f.read().strip()
        f.close()
        return None, held or "a pid it did not write"
    f.seek(0)
    f.truncate()
    f.write(f"{os.getpid()} since {time.strftime('%H:%M:%S')}\n")
    f.flush()
    return f, None


def push_board(a, tok, board, now=None):
    """(BI3) The full board document (serve.py /board.json) to the worker's /v1/board: when it changed and BOARD_EVERY
    seconds passed, or BOARD_STALE seconds passed; a worker without the route (404) is asked again in 10 minutes."""
    now = time.time() if now is None else now
    if now < board["off_until"] or now - board["at"] < BOARD_EVERY:
        return None
    try:
        with urllib.request.urlopen(board_url(a.source), timeout=5) as r:
            doc = json.load(r)
    except (urllib.error.URLError, OSError, ValueError):
        return None  # an older serve.py, or no board read yet: nothing to send
    if not isinstance(doc, dict):
        return None
    doc = public_board_all(doc)
    body = json.dumps(doc, ensure_ascii=False, separators=(",", ":")).encode()
    h = hashlib.sha1(json.dumps(dict(doc, tick=None), sort_keys=True).encode()).hexdigest()
    if h == board["hash"] and now - board["at"] < BOARD_STALE:
        return None
    if a.print:
        print(json.dumps({"board_document": doc}, indent=1))
    else:
        try:
            req = urllib.request.Request(a.api.rstrip("/") + "/v1/board", data=body, method="POST",
                                         headers={"Content-Type": "application/json", "Authorization": "Bearer " + tok,
                                                  "User-Agent": "pog-push-live/1"})
            with urllib.request.urlopen(req, timeout=10) as r:
                r.read()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                board["off_until"] = now + 600
                print(f"[push] {time.strftime('%H:%M:%S')} the worker has no /v1/board yet: asking again in 10 min", flush=True)
            else:
                print(f"[push] {time.strftime('%H:%M:%S')} board document failed: {e.code}", flush=True)
            board["at"] = now
            return None
        except (urllib.error.URLError, OSError) as e:
            print(f"[push] {time.strftime('%H:%M:%S')} board document failed: {type(e).__name__}: {e}", flush=True)
            board["at"] = now
            return None
    board.update(hash=h, at=now, bytes=len(body))
    return len(body)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", default="http://127.0.0.1:8787/state.json", help="serve.py state URL")
    ap.add_argument("--api", default=CONFIG.get("live_api_url"), help="live API base URL (default from site/config.json)")
    ap.add_argument("--interval", type=float, default=10.0, help="seconds between pushes")
    ap.add_argument("--report", type=float, default=60.0, help="seconds between ok lines in the log")
    ap.add_argument("--once", action="store_true", help="push one snapshot and exit")
    ap.add_argument("--print", action="store_true", help="print the filtered JSON instead of pushing")
    ap.add_argument("--lock", default=None, help=f"the one-pusher lock file (default {LOCK})")
    a = ap.parse_args()
    lock = None
    if not (a.print or a.once):
        lock, held = take_lock(a.lock)
        if not lock:
            print(f"[push] {time.strftime('%H:%M:%S')} another push_live.py holds {a.lock or LOCK} (pid {held}): "
                  "this one exits", flush=True)
            return 3
    tok = None if a.print else token()
    fails = 0
    # once a minute an ok line (shake3's push-live.log was empty: this printed only on failure, so a quiet log could
    # not tell pushes that went through from a process that never ran)
    window = {"ok": 0, "failed": 0, "bytes": 0, "tick": None, "agents": 0}
    board = {"hash": None, "at": 0.0, "bytes": 0, "off_until": 0.0}  # (BI3) the full board document's last push
    next_report = time.time() + a.report
    if not a.print:
        print(f"[push] {time.strftime('%H:%M:%S')} start: {a.source} -> {a.api} every {a.interval:g} s", flush=True)
    while True:
        t0 = time.time()
        try:
            with urllib.request.urlopen(a.source, timeout=5) as r:
                state = with_terrain(public_state(json.load(r)), site_terrain(CONFIG.get("site_url")))
                state = with_chart(state, site_chart(CONFIG.get("site_url")))
            body = json.dumps(state, separators=(",", ":")).encode()
            if a.print:
                print(json.dumps(state, indent=1))
            else:
                req = urllib.request.Request(a.api.rstrip("/") + "/v1/state", data=body, method="POST",
                                             headers={"Content-Type": "application/json",
                                                      "Authorization": "Bearer " + tok,
                                                      "User-Agent": "pog-push-live/1"})
                with urllib.request.urlopen(req, timeout=10) as r:
                    r.read()
                window.update(ok=window["ok"] + 1, bytes=window["bytes"] + len(body), tick=state.get("tick"),
                              agents=len(state.get("agents") or []))
                if fails:
                    print(f"[push] {time.strftime('%H:%M:%S')} ok again after {fails} failures", flush=True)
                fails = 0
        except (urllib.error.URLError, OSError, ValueError) as e:
            fails += 1
            window["failed"] += 1
            if fails in (1, 3) or fails % 30 == 0:
                print(f"[push] {time.strftime('%H:%M:%S')} failed ({fails}): {type(e).__name__}: {e}", flush=True)
        push_board(a, tok, board)
        if a.once:
            return 1 if fails else 0
        if not a.print and time.time() >= next_report:
            next_report = time.time() + a.report
            print(f"[push] {time.strftime('%H:%M:%S')} {'ok' if window['ok'] else 'NO PUSHES'}: {window['ok']} pushed, "
                  f"{window['failed']} failed in the last {a.report:g} s, {window['bytes'] // max(1, window['ok'])} bytes each, "
                  f"tick {window['tick']}, {window['agents']} agents, terrain frames {len(_terrain['rows'])}, "
                  f"board document {board['bytes']} bytes"
                  + (f" (index read failed: {_terrain['error']})" if _terrain["error"] else "")
                  + f", chart v{_chart['v']}" + (f" (index read failed: {_chart['error']})" if _chart["error"] else ""), flush=True)
            window = dict(window, ok=0, failed=0, bytes=0)
        time.sleep(max(1.0, a.interval - (time.time() - t0)))


if __name__ == "__main__":
    sys.exit(main())
