#!/usr/bin/env python3
"""Push the stream service's state to the site's live API every few seconds (runs on the Mac). Stdlib only.

    python3 site/push_live.py                                   # serve.py on 127.0.0.1:8787, every 10 s
    python3 site/push_live.py --source http://127.0.0.1:8799/state.json --once --print

Reads tools/stream/serve.py's /state.json, keeps only the fields the live page shows (see docs/LIVE-API.md),
redacts e-mail addresses, local paths, key-like tokens and IP addresses from every string, and POSTs it to
API/v1/state with the publish token. The token comes from $POG_LIVE_TOKEN or site/worker/.secrets.json
(gitignored; never commit it).
"""
import argparse, json, os, re, sys, time, urllib.error, urllib.request
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
              "surface", "where", "on_platform", "travel")  # where the body is: the map lists agents off Nauvis at its edge
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


def scrub(v):
    if isinstance(v, str):
        return clean(v)
    if isinstance(v, list):
        return [scrub(x) for x in v]
    if isinstance(v, dict):
        return {k: scrub(x) for k, x in v.items()}
    return v


CAMERA_LABELS = ("attack", "work", "segment")  # what a camera shows when it is not just following an agent
PLATFORM_KEYS = ("name", "where", "route", "state", "paused", "speed_kms")
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


CLOUD_KEYS = ("surface", "label", "pollutant", "chunks", "max", "total", "age_s")
CLOUD_CELLS = 6000  # cells across all surfaces (about 14 bytes each; the state is at most 256 KB), most polluted kept


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
                        reached=[{"x": n.get("x"), "y": n.get("y")} for n in r.get("reached") or []][:20]))
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
LINKS = ("reply_to", "only_line", "only_to", "time", "none")  # viewer_replies.classify's link


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
        a = r.get("answers")
        if isinstance(a, dict) and a.get("name"):
            if hidden and hidden.hides(a.get("name"), a.get("text")):
                row["to"] = [n for n in row["to"] if n.lower() != str(a["name"]).lower()]
            else:
                row["answers"] = {"name": str(a["name"]), "text": str(a.get("text") or ""), "t": a.get("t"), "source": a.get("source")}
                if re.fullmatch(r"(site|yt):[\w.:-]{1,80}", str(a.get("id") or "")):  # (d20 batch65 AA2) the line the Operator named
                    row["answers"]["id"] = str(a["id"])
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
    if size() > REMINDER_BYTES:
        head, tail = out["jobs"][:REMINDERS_SHOWN], list(out["jobs"][REMINDERS_SHOWN:])
        drop = [i for i in reversed(range(len(tail))) if isinstance(tail[i], dict) and tail[i].get("done")] + \
            [i for i in reversed(range(len(tail))) if not (isinstance(tail[i], dict) and tail[i].get("done"))]
        gone = set()
        for i in drop:
            if size() <= REMINDER_BYTES:
                break
            gone.add(i)
            out["jobs"] = head + [j for k, j in enumerate(tail) if k not in gone]
        out.setdefault("total", len(rem["jobs"]))
    return out


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
RANK = {"D": 12, "R": 11, "O": 10, "A": 9, "S": 8, "M": 7, "E": 6, "L": 5, "I": 4, "B": 3, "T": 2, "P": 1}  # census.lua's


def coarser(g):
    """A grid at twice its cell: each new cell the most telling of the four it covers (census.lua RANK)."""
    c, c2 = g["cell"], g["cell"] * 2
    nx0, ny0 = (g["x0"] // c2) * c2, (g["y0"] // c2) * c2
    ox, oy = (g["x0"] - nx0) // c, (g["y0"] - ny0) // c
    cells = {}
    for j, row in enumerate(g["rows"]):
        for i, ch in enumerate(row):
            if ch == ".":
                continue
            k = ((i + ox) // 2, (j + oy) // 2)
            if k not in cells or RANK.get(ch, 0) > RANK.get(cells[k], 0):
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


def public_planets(maps):
    """The other planets' coarse maps (viewers craigNZ830 and Foobator, d15 07:05): planets [{surface, tick, buildings}]
    for all of them, and planet_map, one of them in turn each push (the page keeps the ones it has seen): one grid of
    at most 128x128 letters a push instead of all."""
    if not isinstance(maps, dict) or not maps:
        return None, None
    names = sorted(k for k, m in maps.items() if isinstance(m, dict) and isinstance(m.get("rows"), list))
    if not names:
        return None, None
    listing = [{"surface": n, "tick": maps[n].get("tick"), "buildings": maps[n].get("buildings")} for n in names]
    name = names[_planet_turn["i"] % len(names)]
    _planet_turn["i"] += 1
    m = maps[name]
    out = pack({k: m[k] for k in PLANET_MAP_KEYS if k in m} | {"surface": name})
    if isinstance(m.get("core"), dict) and isinstance(m["core"].get("rows"), list) and m["core"]["rows"]:
        out["core"] = fitted({k: m["core"][k] for k in CORE_KEYS if k in m["core"]})  # (AD1) its footprints, as Nauvis's core
    else:
        out.pop("core", None)
    return listing, out


def public_state(s):
    out = {k: s[k] for k in TOP_KEYS if k in s}
    planets, planet_map = public_planets(s.get("planet_maps"))
    if planets:
        out["planets"], out["planet_map"] = planets, planet_map
    if "basemap" in out:
        out["basemap"] = public_basemap(out["basemap"])
    if "board" in out:
        out["board"] = public_board(out["board"])
    if "reminders" in out:
        out["reminders"] = public_reminders(out["reminders"])
    out["agents"] = [{k: a[k] for k in AGENT_KEYS if k in a} for a in s.get("agents", [])]
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


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", default="http://127.0.0.1:8787/state.json", help="serve.py state URL")
    ap.add_argument("--api", default=CONFIG.get("live_api_url"), help="live API base URL (default from site/config.json)")
    ap.add_argument("--interval", type=float, default=10.0, help="seconds between pushes")
    ap.add_argument("--report", type=float, default=60.0, help="seconds between ok lines in the log")
    ap.add_argument("--once", action="store_true", help="push one snapshot and exit")
    ap.add_argument("--print", action="store_true", help="print the filtered JSON instead of pushing")
    a = ap.parse_args()
    tok = None if a.print else token()
    fails = 0
    # once a minute an ok line (shake3's push-live.log was empty: this printed only on failure, so a quiet log could
    # not tell pushes that went through from a process that never ran)
    window = {"ok": 0, "failed": 0, "bytes": 0, "tick": None, "agents": 0}
    next_report = time.time() + a.report
    if not a.print:
        print(f"[push] {time.strftime('%H:%M:%S')} start: {a.source} -> {a.api} every {a.interval:g} s", flush=True)
    while True:
        t0 = time.time()
        try:
            with urllib.request.urlopen(a.source, timeout=5) as r:
                state = with_terrain(public_state(json.load(r)), site_terrain(CONFIG.get("site_url")))
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
        if a.once:
            return 1 if fails else 0
        if not a.print and time.time() >= next_report:
            next_report = time.time() + a.report
            print(f"[push] {time.strftime('%H:%M:%S')} {'ok' if window['ok'] else 'NO PUSHES'}: {window['ok']} pushed, "
                  f"{window['failed']} failed in the last {a.report:g} s, {window['bytes'] // max(1, window['ok'])} bytes each, "
                  f"tick {window['tick']}, {window['agents']} agents, terrain frames {len(_terrain['rows'])}"
                  + (f" (index read failed: {_terrain['error']})" if _terrain["error"] else ""), flush=True)
            window = dict(window, ok=0, failed=0, bytes=0)
        time.sleep(max(1.0, a.interval - (time.time() - t0)))


if __name__ == "__main__":
    sys.exit(main())
