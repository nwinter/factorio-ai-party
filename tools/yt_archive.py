#!/usr/bin/env python3
"""The shift videos on YouTube made public as an archive (Nick d27 07:05): privacy, one playlist, the rotation.

  python3 tools/yt_archive.py plan [--refresh]     # what apply would change and its quota; with --refresh it reads
                                                   # YouTube's state first (a few units), else this tool's state file
  python3 tools/yt_archive.py apply [--refresh]    # make those changes, within today's quota, resumable
  python3 tools/yt_archive.py rotate [--dry-run]   # upload finished shifts not on YouTube yet, then apply
  python3 tools/yt_archive.py follow               # rotate after each "shiftN up" in the autopilot's log
  python3 tools/yt_archive.py follow --start       # the follower in the background, unless one runs (start-team)
  python3 tools/yt_archive.py follow --check | --stop
  python3 tools/yt_archive.py quota                # today's ledger
  python3 tools/yt_archive.py titles [--shifts 85-94] [--apply]  # (d29 batch338) the videos whose title differs from
                                                   # runs/RUN/video/video.json's, old -> new and the units; --apply
                                                   # sets them on YouTube (each video's description, tags and
                                                   # category as YouTube has them) and in the manifest

The rule (selection): every shift video is unlisted and in one public playlist in shift order. Three are public:
shift 1, shift 63 (the edge victory) and the latest shift with a video. The latest slot rotates: a newer shift's
video goes up public and the one before it goes back to unlisted.

Videos: the manifests tools/archive_upload.py writes (--manifest, video-work/videos-private.json) and the shift 63
test upload (--extra, video-work/videos-test.json). State (--state, video-work/yt-archive-state.json): each video's
privacy and status as last read or set, the playlist id and each video's playlist item. --refresh reads them from
YouTube: playlists.list, videos.list (50 ids a call) and playlistItems.list, 1 unit a call.

apply's order: the playlist (created public if missing), the public ones, the demotions, the rest private to
unlisted (shift order), then playlist inserts in shift order (each at its place: snippet.position = the number of
items of earlier shifts), a video only once it is no longer private. Each change is written to the state file as it
succeeds, so a stopped run goes on where it stopped.

Quota (YouTube Data API, per Pacific day; video-work/yt-quota.json counts what this tool spent): videos.update,
playlistItems.insert, playlists.insert and thumbnails.set 50 units each, a list call 1, of the default 10,000 a day.
An upload (videos.insert): docs/VIDEOS.md found it in a separate bucket of 100 uploads a day (2026-10-08; 41 uploads
went up on 2026-10-24 alone); --upload-units 1600 budgets the older figure of 1,600 units instead. A change that would
take the day past --daily minus --margin waits for the next day; a quotaExceeded reply marks the day spent.

rotate: the finished shifts with no video, the newest first, then the rest oldest first, each through
tools/archive_upload.py --shifts N --limit 1 --privacy private, then apply (public when it is the latest, else
unlisted; the previous latest unlisted), while
the day's quota has room for the upload and its follow-ups (thumbnail, playlist insert, the previous latest's
demotion) and the SSD keeps --keep-free-gb free after the copy and join (the R2 encode needs about 35 GB). Then apply.

follow (d28 batch315): one follower per Mac, across shifts. The d27 rotation was a one-shot `rotate` (pid 85368, from
pog-d20-b207): it ended at 11:35 when the day's quota was spent, as rotate does, and the follower meant to come after
it was never started, so shifts 86-93 waited. tools/start-team.sh now runs `follow --start` at every shift start: it
starts a follower when video-work/yt-follow.pid names no live one (after a reboot, a kill or a crash) and leaves a
running one alone; tools/stop-team.sh never stops it (an upload can take an hour). It runs the main checkout's tools
with its state in video-work, and:
- writes the site's list to video-work/videos-site.json, never into a checkout (tools/site-refresh.sh names that file
  for the build in its clean copy of main);
- starts no rotate and no upload while the checkout it runs from has MERGE_HEAD (the gate merges and tests there): it
  waits up to --merge-wait seconds before each, then tries again at the next poll;
- outlives a failed rotate (an error, a stopped upload): the error goes to its log, and the same rotate is tried again
  --retry seconds later;
- runs itself again (same pid) when yt_archive.py or yt_upload.py changes on disk, so a merged fix takes effect
  without a restart.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import traceback
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
sys.path.insert(0, str(HERE))
import yt_upload as yt  # noqa: E402

PDT = datetime.timezone(datetime.timedelta(hours=-7))  # pacific_day() without a tz database
OPERATOR = Path.home() / "code" / "pog-operator"
WORK = OPERATOR / "video-work"
MANIFEST = WORK / "videos-private.json"
EXTRA = WORK / "videos-test.json"
STATE = WORK / "yt-archive-state.json"
LEDGER = WORK / "yt-quota.json"
AUTOPILOT_LOG = OPERATOR / "autopilot.log"
SITE_VIDEOS = WORK / "videos-site.json"  # (batch315) outside any checkout; tools/site-refresh.sh names it for the build
FOLLOW_PID = WORK / "yt-follow.pid"
FOLLOW_LOG = WORK / "yt-follow.log"
RUNS = Path(os.environ.get("POG_SITE_RUNS") or Path.home() / "code" / "player-of-games" / "runs")
SSD = Path("/Volumes/Extreme SSD")
PLAYLIST = yt.PLAYLIST
PLAYLIST_ABOUT = ("Every shift of the Factorio AI Party in order: nine AI agents from five labs build one Factorio: "
                  "Space Age factory together, live, by the same rules as a human player. https://factorio.nickwinter.net")
FIXED_PUBLIC = (1, 63)  # the first shift and the edge victory
COST = {"videos.list": 1, "playlists.list": 1, "playlistItems.list": 1, "playlists.insert": 50, "videos.update": 50,
        "playlistItems.insert": 50, "thumbnails.set": 50, "playlists.update": 50}
DAILY, MARGIN, UPLOADS_A_DAY = 10_000, 200, 100
# status fields videos.update keeps only when sent (the rest are read-only or reset)
STATUS_KEEP = ("embeddable", "license", "publicStatsViewable", "selfDeclaredMadeForKids", "containsSyntheticMedia")
UP_LINE = re.compile(r"^(\d\d-\d\d \d\d:\d\d:\d\d) shift(\d+) up\b")


class QuotaExceeded(Exception):
    pass


class Busy(Exception):
    """A merge in the checkout the tool runs from outlasted --merge-wait: the rotate stops, follow tries again."""


# ---------------------------------------------------------------- selection (pure)

def shift_n(run):
    return int(re.sub(r"\D", "", run))


def public_shifts(shifts, fixed=FIXED_PUBLIC):
    """The shifts whose video is public: the fixed ones that have a video, and the latest with a video."""
    have = set(shifts)
    return {n for n in fixed if n in have} | ({max(have)} if have else set())


def desired(videos, fixed=FIXED_PUBLIC):
    """{run: "public" | "unlisted"} for every video."""
    pub = public_shifts([v["shift"] for v in videos.values()], fixed)
    return {run: "public" if v["shift"] in pub else "unlisted" for run, v in videos.items()}


def upload_privacy(n, have, fixed=FIXED_PUBLIC):
    """A new upload's privacy at insert: public when it is fixed or becomes the latest, else unlisted."""
    return "public" if n in fixed or not have or n > max(have) else "unlisted"


def plan_ops(videos, state, fixed=FIXED_PUBLIC):
    """The changes, in apply's order: [{op, run, privacy?, units}]. state: {playlist: {id}, videos: {run: {privacy,
    item}}}; a video with no state counts as private and out of the playlist (archive_upload's uploads)."""
    want = desired(videos, fixed)
    sv = state.get("videos", {})
    cur = {run: (sv.get(run) or {}).get("privacy", "private") for run in videos}
    order = sorted(videos, key=lambda r: videos[r]["shift"])
    ops = []
    pl = state.get("playlist") or {}
    if not pl.get("id"):
        ops.append({"op": "playlists.insert", "run": None, "units": COST["playlists.insert"]})
    elif pl.get("privacy") not in (None, "public"):
        ops.append({"op": "playlists.update", "run": None, "units": COST["playlists.update"]})
    promote = [r for r in order if want[r] == "public" and cur[r] != "public"]
    demote = [r for r in order if want[r] != "public" and cur[r] == "public"]
    rest = [r for r in order if want[r] == "unlisted" and cur[r] == "private"]
    for r in promote + demote + rest:
        ops.append({"op": "videos.update", "run": r, "privacy": want[r], "units": COST["videos.update"]})
    for r in order:
        if not (sv.get(r) or {}).get("item"):
            ops.append({"op": "playlistItems.insert", "run": r, "units": COST["playlistItems.insert"]})
    return ops


def position(n, items_shifts):
    """Where shift n goes in the playlist (shift order): the number of items of earlier shifts."""
    return sum(1 for s in items_shifts if s < n)


def within(ops, spent, daily=DAILY, margin=MARGIN):
    """(now, later): the ops that fit today in order; once one does not fit, it and the rest wait (order matters:
    a playlist insert needs its video unlisted first)."""
    room = daily - margin - spent
    now = []
    for i, op in enumerate(ops):
        if op["units"] > room:
            return now, ops[i:]
        room -= op["units"]
        now.append(op)
    return now, []


def upload_order(finished, have):
    """The shifts to upload: the newest finished shift first when it has no video, then the rest oldest first."""
    todo = sorted(n for n in finished if n not in have)
    if todo and todo[-1] == max(finished):
        return [todo[-1]] + todo[:-1]
    return todo


def upload_units(n, have, upload_cost, fixed=FIXED_PUBLIC):
    """Units one upload takes with its follow-ups: the upload (private), its thumbnail, its own privacy, its playlist
    insert, and the previous latest's demotion when this one becomes the latest."""
    demote = 1 if have and n > max(have) and max(have) not in fixed else 0
    return upload_cost + COST["thumbnails.set"] + COST["playlistItems.insert"] + (1 + demote) * COST["videos.update"]


def backlog_days(backlog, have, upload_cost, spent_today=0, new_today=0, new_per_day=6, daily=DAILY, margin=MARGIN,
                 uploads_a_day=UPLOADS_A_DAY):
    """Days (today is day 1) until every shift in `backlog` is up, oldest first, when the rotation comes first: each
    day's new shifts (new_today today, new_per_day after) are uploaded as the new latest (upload, thumbnail, its
    privacy, playlist insert, the previous latest's demotion). A backlog shift goes unlisted under a newer latest
    (upload, thumbnail, its privacy, playlist insert). Returns (days or None when a day's quota never fits one, [[day, [shifts]]])."""
    todo = sorted(n for n in backlog if n not in set(have))
    new_cost = upload_cost + COST["thumbnails.set"] + COST["playlistItems.insert"] + 2 * COST["videos.update"]
    old_cost = upload_cost + COST["thumbnails.set"] + COST["playlistItems.insert"] + COST["videos.update"]
    plan, day, spent, new = [], 0, spent_today, new_today
    while todo:
        day += 1
        room, count, done = daily - margin - spent, 0, []
        for _ in range(new):
            if new_cost <= room and count < uploads_a_day:
                room -= new_cost
                count += 1
        while todo and count < uploads_a_day and old_cost <= room:
            room -= old_cost
            count += 1
            done.append(todo.pop(0))
        plan.append([day, done])
        if not done and spent == 0:
            return None, plan
        spent, new = 0, new_per_day
    return day, plan


def reserve_units(now=None, shift_hours=4.1, upload_cost=0):
    """Units held back from the backlog for today's later shift ends (each a new latest: its upload with
    follow-ups), one per shift_hours left before midnight Pacific, rounded up."""
    try:
        from zoneinfo import ZoneInfo
        now = (now or datetime.datetime.now(datetime.timezone.utc)).astimezone(ZoneInfo("America/Los_Angeles"))
    except Exception:  # noqa: BLE001
        now = (now or datetime.datetime.now(datetime.timezone.utc)).astimezone(PDT)
    left = (24 - now.hour - now.minute / 60) / shift_hours
    return -int(-left // 1) * (upload_cost + COST["thumbnails.set"] + COST["playlistItems.insert"] + 2 * COST["videos.update"])


# ---------------------------------------------------------------- files

def load(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return {} if default is None else default


def save(path, data, private=False):
    path = Path(path)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=1, ensure_ascii=False) + "\n")
    if private:
        os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def all_videos(manifests):
    """{run: row} from the manifests (later ones fill gaps); rows need an id and a shift."""
    out = {}
    for m in manifests:
        for run, v in load(m).items():
            if isinstance(v, dict) and v.get("id") and run not in out:
                out[run] = dict(v, shift=int(v.get("shift") or shift_n(run)))
    return out


def pacific_day(now=None):
    try:
        from zoneinfo import ZoneInfo
        tz = ZoneInfo("America/Los_Angeles")
    except Exception:  # noqa: BLE001  (no tz database: PDT)
        tz = PDT
    return (now or datetime.datetime.now(datetime.timezone.utc)).astimezone(tz).date().isoformat()


class Ledger:
    """Units and uploads spent per Pacific day by this tool (the quota resets at midnight Pacific)."""

    def __init__(self, path, day=None):
        self.path, self.day = Path(path), day or pacific_day()
        self.data = load(path)
        self.today = self.data.setdefault(self.day, {"units": 0, "uploads": 0, "exhausted": False, "ops": []})

    def spend(self, op, run, units, upload=False):
        self.today["units"] += units
        self.today["uploads"] += 1 if upload else 0
        self.today["ops"].append([datetime.datetime.now().isoformat(timespec="seconds"), op, run, units])
        self.write()

    def exhaust(self):
        self.today["exhausted"] = True
        self.write()

    def write(self):
        if self.path.parent.is_dir():
            save(self.path, self.data)


# ---------------------------------------------------------------- YouTube

class Client:
    """yt_upload's Api with the units counted in the ledger and quotaExceeded raised."""

    def __init__(self, ledger, dry=False):
        self.api, self.ledger, self.dry = yt.Api(dry), ledger, dry

    def call(self, name, method, url, body=None):
        if self.ledger.today.get("exhausted"):
            raise QuotaExceeded("the day's quota is spent (yt-quota.json)")
        try:
            out = self.api.call(method, url, body=body, quota=COST[name])
        except SystemExit as e:
            if "quotaExceeded" in str(e) or "dailyLimitExceeded" in str(e):
                self.ledger.exhaust()
                raise QuotaExceeded(str(e)[:200])
            raise
        if not self.dry:
            self.ledger.spend(name, None, COST[name])
        return out


def refresh(client, videos, state, title=PLAYLIST):
    """state from YouTube: the playlist (by title), each video's status, each playlist item."""
    pl = None
    page = ""
    while True:
        r = client.call("playlists.list", "GET", f"{yt.API}/playlists?part=snippet,status&mine=true&maxResults=50{page}")
        pl = pl or next((p for p in r.get("items", []) if p["snippet"]["title"] == title), None)
        if pl or not r.get("nextPageToken"):
            break
        page = "&pageToken=" + r["nextPageToken"]
    state["playlist"] = {"id": pl["id"], "title": title, "privacy": pl.get("status", {}).get("privacyStatus")} if pl else {}
    sv = state.setdefault("videos", {})
    by_id = {v["id"]: run for run, v in videos.items()}
    ids = sorted(by_id)
    for i in range(0, len(ids), 50):
        r = client.call("videos.list", "GET", f"{yt.API}/videos?part=status&id={','.join(ids[i:i + 50])}&maxResults=50")
        seen = set()
        for item in r.get("items", []):
            run = by_id[item["id"]]
            seen.add(item["id"])
            st = item.get("status", {})
            sv.setdefault(run, {}).update(id=item["id"], privacy=st.get("privacyStatus"), status=st)
        for vid in ids[i:i + 50]:
            if vid not in seen and not client.dry:
                sv.setdefault(by_id[vid], {}).update(id=vid, privacy="missing")
    for v in sv.values():
        v.pop("item", None)
    if pl:
        page = ""
        while True:
            r = client.call("playlistItems.list", "GET",
                            f"{yt.API}/playlistItems?part=snippet&playlistId={pl['id']}&maxResults=50{page}")
            for it in r.get("items", []):
                vid = it["snippet"]["resourceId"].get("videoId")
                if vid in by_id:
                    sv.setdefault(by_id[vid], {})["item"] = it["id"]
            if not r.get("nextPageToken"):
                break
            page = "&pageToken=" + r["nextPageToken"]
    state["refreshed"] = datetime.datetime.now().isoformat(timespec="seconds")
    return state


def do_op(client, op, videos, state):
    sv = state.setdefault("videos", {})
    if op["op"] == "playlists.insert":
        r = client.call("playlists.insert", "POST", f"{yt.API}/playlists?part=snippet,status",
                        body={"snippet": {"title": PLAYLIST, "description": PLAYLIST_ABOUT, "defaultLanguage": "en"},
                              "status": {"privacyStatus": "public"}})
        state["playlist"] = {"id": r.get("id", "PLAYLIST_ID"), "title": PLAYLIST, "privacy": "public"}
        return
    if op["op"] == "playlists.update":
        client.call("playlists.update", "PUT", f"{yt.API}/playlists?part=snippet,status",
                    body={"id": state["playlist"]["id"], "snippet": {"title": PLAYLIST, "description": PLAYLIST_ABOUT},
                          "status": {"privacyStatus": "public"}})
        state["playlist"]["privacy"] = "public"
        return
    run = op["run"]
    v = videos[run]
    cur = sv.setdefault(run, {"id": v["id"]})
    if op["op"] == "videos.update":
        status = {k: cur["status"][k] for k in STATUS_KEEP if k in (cur.get("status") or {})}
        status.setdefault("selfDeclaredMadeForKids", False)
        status["privacyStatus"] = op["privacy"]
        client.call("videos.update", "PUT", f"{yt.API}/videos?part=status", body={"id": v["id"], "status": status})
        cur.update(privacy=op["privacy"], status=dict(cur.get("status") or {}, **status))
    elif op["op"] == "playlistItems.insert":
        placed = [videos[r]["shift"] for r, x in sv.items() if x.get("item") and r in videos]
        body = {"snippet": {"playlistId": state["playlist"]["id"], "position": position(v["shift"], placed),
                            "resourceId": {"kind": "youtube#video", "videoId": v["id"]}}}
        r = client.call("playlistItems.insert", "POST", f"{yt.API}/playlistItems?part=snippet", body=body)
        cur["item"] = r.get("id", "ITEM_ID")


def site_videos(videos, state, path=SITE_VIDEOS):
    """The site's list (video-work/videos-site.json; tools/site-refresh.sh names it for site/build.py --videos): the videos
    YouTube shows (unlisted or public)."""
    sv = state.get("videos", {})
    pl = (state.get("playlist") or {}).get("id")
    out = {}
    for run in sorted(videos, key=lambda r: videos[r]["shift"]):
        p = (sv.get(run) or {}).get("privacy")
        if p not in ("public", "unlisted"):
            continue
        v = videos[run]
        out[run] = {k: v[k] for k in ("id", "shift", "title", "uploaded", "timeline", "description") if k in v}
        out[run]["chapters"] = list(v.get("chapters") or [])
        out[run].update(playlist=pl if (sv.get(run) or {}).get("item") else None, privacy=p)
    if Path(path).parent.is_dir():
        save(path, out)
    return out


# ---------------------------------------------------------------- titles (d29 batch338 VT)

# the snippet fields videos.update writes: a field left out of a snippet update is cleared (YouTube Data API,
# videos.update), so each is sent back as videos.list read it, the title changed
SNIPPET_KEEP = ("title", "description", "tags", "categoryId", "defaultLanguage", "defaultAudioLanguage")


def title_changes(videos, runs_dir, shifts=None):
    """[(run, title now, new title)]: the videos whose runs/RUN/video/video.json title (tools/shift_video.py --titles
    --write) differs from the manifest's, in shift order; shifts: only those numbers."""
    out = []
    for run in sorted(videos, key=lambda r: videos[r]["shift"]):
        if shifts and videos[run]["shift"] not in shifts:
            continue
        new = load(Path(runs_dir) / run / "video" / "video.json").get("title")
        if new and new != videos[run].get("title"):
            out.append((run, videos[run].get("title"), new))
    return out


def title_units(n):
    """A videos.list call (1 unit) for each 50 videos and a videos.update (50) for each."""
    return -(-n // 50) * COST["videos.list"] + n * COST["videos.update"]


def titles(a, dry=True):
    """Set the new titles on YouTube: videos.list part=snippet for the current snippets, then videos.update part=snippet
    with only the title changed (the description keeps its chapters); each done one written to its manifest at once,
    then the site's list. All of them or none within today's room (--daily less --margin less what is spent)."""
    videos = all_videos([a.manifest, a.extra])
    first, _, last = (a.shifts or "").partition("-")
    shifts = set(range(int(first), int(last or first) + 1)) if first else None
    changes = title_changes(videos, a.runs_dir, shifts)
    ledger = Ledger(a.ledger)
    units = title_units(len(changes))
    for run, old, new in changes:
        print(f"{run} ({videos[run]['id']}): {old}\n  -> {new}")
    room = a.daily - a.margin - ledger.today["units"]
    print(f"{len(changes)} titles; quota: {units} units ({ledger.today['units']} spent today by this tool, "
          f"{room} room today)")
    if dry or not changes:
        return 0
    if ledger.today.get("exhausted") or units > room:
        print("not today: the titles wait for a day with room (Pacific)")
        return 1
    client = Client(ledger)
    state = load(a.state, {"videos": {}})
    done = 0
    try:
        for i in range(0, len(changes), 50):
            part = changes[i:i + 50]
            r = client.call("videos.list", "GET", f"{yt.API}/videos?part=snippet&id=" + ",".join(videos[x[0]]["id"] for x in part))
            got = {it.get("id"): it.get("snippet") or {} for it in r.get("items", [])}
            for run, _, new in part:
                vid = videos[run]["id"]
                if vid not in got:
                    print(f"  {run} ({vid}): not on YouTube, left out")
                    continue
                snippet = {k: got[vid][k] for k in SNIPPET_KEEP if k in got[vid]}
                snippet["title"] = new
                client.call("videos.update", "PUT", f"{yt.API}/videos?part=snippet", body={"id": vid, "snippet": snippet})
                for path in (a.manifest, a.extra):
                    m = load(path)
                    if run in m:
                        m[run]["title"] = new
                        save(path, m)
                        break
                videos[run]["title"] = new
                done += 1
                print(f"  done: {run}", flush=True)
    except QuotaExceeded as e:
        print(f"quota exceeded after {done} titles: {e}; run it again tomorrow (Pacific)")
    finally:
        site = site_videos(videos, state, a.site_videos)
        print(f"{a.site_videos}: {len(site)} videos the site can show")
    print(f"done {done} of {len(changes)} titles; quota spent today by this tool: {ledger.today['units']}")
    return 0


# ---------------------------------------------------------------- commands

def describe(ops, videos):
    rows = []
    for op in ops:
        if op["op"] == "playlists.insert":
            rows.append(f"playlists.insert: create the public playlist {PLAYLIST!r}")
        elif op["op"] == "playlists.update":
            rows.append(f"playlists.update: make the playlist {PLAYLIST!r} public")
        elif op["op"] == "videos.update":
            rows.append(f"videos.update: {op['run']} ({videos[op['run']]['id']}) -> {op['privacy']}")
        else:
            rows.append(f"playlistItems.insert: {op['run']} ({videos[op['run']]['id']}) into the playlist")
    return rows


def apply(a, dry=False):
    videos = all_videos([a.manifest, a.extra])
    state = load(a.state, {"videos": {}})
    ledger = Ledger(a.ledger)
    client = Client(ledger, dry=dry)
    need_refresh = a.refresh or not state.get("refreshed")
    try:
        if need_refresh:
            if dry and not a.refresh:
                print("(no state file yet: --refresh reads YouTube's state; until then every video counts as private "
                      "and out of the playlist)")
            else:
                refresh(Client(ledger, dry=False), videos, state)
                save(a.state, state)
    except QuotaExceeded as e:
        print(f"quota: {e}")
        return 1
    gone = [r for r, x in state.get("videos", {}).items() if x.get("privacy") == "missing" and r in videos]
    if gone:
        print(f"not on YouTube any more (left out): {', '.join(sorted(gone))}")
        videos = {r: v for r, v in videos.items() if r not in gone}
    ops = plan_ops(videos, state)
    now, later = within(ops, ledger.today["units"], a.daily, a.margin)
    if ledger.today.get("exhausted"):
        now, later = [], ops
    pub = sorted(public_shifts([v["shift"] for v in videos.values()]))
    cur_pub = sorted(videos[r]["shift"] for r, x in state.get("videos", {}).items() if x.get("privacy") == "public" and r in videos)
    print(f"{len(videos)} videos (shifts {min(v['shift'] for v in videos.values())}-{max(v['shift'] for v in videos.values())});"
          f" public now: {cur_pub or 'none'}; public by the rule: {pub}; playlist: "
          f"{(state.get('playlist') or {}).get('id') or 'none yet'}")
    counts = {}
    for op in ops:
        key = op["op"] + (f" -> {op['privacy']}" if op.get("privacy") else "")
        counts[key] = counts.get(key, 0) + 1
    print("changes: " + (", ".join(f"{n} {k}" for k, n in counts.items()) or "none"))
    print(f"quota today ({ledger.day} Pacific): {ledger.today['units']} spent by this tool; these changes take "
          f"{sum(o['units'] for o in now)} now" + (f", {sum(o['units'] for o in later)} more wait for later days "
                                                   f"({len(later)} changes)" if later else ""))
    if dry:
        for row in describe(now, videos):
            print("  " + row)
        for row in describe(later, videos):
            print("  (later) " + row)
        return 0
    done = 0
    try:
        for op in now:
            # a playlist insert only once its video is no longer private
            if op["op"] == "playlistItems.insert" and state["videos"].get(op["run"], {}).get("privacy") == "private":
                continue
            do_op(client, op, videos, state)
            save(a.state, state)
            done += 1
            print(f"  done: {describe([op], videos)[0]}", flush=True)
    except QuotaExceeded as e:
        print(f"quota exceeded after {done} changes: {e}; the rest waits for tomorrow (Pacific)")
    finally:
        save(a.state, state)
        site = site_videos(videos, state, a.site_videos)
        print(f"{a.site_videos}: {len(site)} videos the site can show")
    print(f"done {done} of {len(ops)} changes; quota spent today by this tool: {ledger.today['units']}")
    return 0


def finished_shifts(runs_dir):
    """Shift numbers whose folder holds a shift that has ended."""
    import shift_video as sv
    out = []
    for d in Path(runs_dir).glob("shift[0-9]*"):
        try:
            _, _, running = sv.shift_window(d)
        except SystemExit:
            continue
        if not running:
            out.append(shift_n(d.name))
    return sorted(out)


def ssd_free_gb(path):
    try:
        return shutil.disk_usage(path).free / 1e9
    except OSError:
        return None


def rotate_lock(path):
    """One rotate at a time (follow's and one started by hand would upload the same shift): a file with the pid; one
    whose pid is gone is taken over. Returns the holder's pid when another rotate runs, else None (the lock is ours)."""
    path = Path(path)
    try:
        holder = int(path.read_text().strip() or 0)
    except (OSError, ValueError):
        holder = 0
    if holder and holder != os.getpid():
        try:
            os.kill(holder, 0)
            return holder
        except ProcessLookupError:
            pass
        except PermissionError:
            return holder
    if path.parent.is_dir():
        path.write_text(str(os.getpid()))
    return None


def merging(repo=REPO):
    """True while repo's working tree is mid-merge (MERGE_HEAD): the gate merges a branch in the main checkout, runs the
    tests, then commits or aborts, so its tools are not main's until then."""
    git = Path(repo) / ".git"
    if git.is_file():  # a worktree: "gitdir: PATH"
        try:
            git = (Path(repo) / git.read_text().split("gitdir:", 1)[1].strip()).resolve()
        except (OSError, IndexError):
            return False
    return (git / "MERGE_HEAD").exists()


def merge_wait(repo=REPO, wait=1800, step=15, sleep=time.sleep):
    """Return once repo has no merge under way; Busy when one lasts past wait seconds."""
    waited = 0
    while merging(repo):
        if waited >= wait:
            raise Busy(f"a merge in {repo} for {waited} s")
        if waited == 0:
            print(f"waiting for the merge in {repo} to end (up to {wait} s)", flush=True)
        sleep(step)
        waited += step


def rotate(a):
    if not a.dry_run:
        holder = rotate_lock(Path(a.state).with_name("yt-rotate.lock"))
        if holder:
            print(f"another rotate runs (pid {holder}): nothing done")
            return 0
        try:
            return _rotate(a)
        finally:
            Path(a.state).with_name("yt-rotate.lock").unlink(missing_ok=True)
    return _rotate(a)


def _rotate(a):
    videos = all_videos([a.manifest, a.extra])
    have = {v["shift"] for v in videos.values()}
    known = {n for n in finished_shifts(a.runs_dir) if n >= a.from_shift}
    order = upload_order(known, have)
    ledger = Ledger(a.ledger)  # read again after each upload: apply() writes the same file
    print(f"finished shifts with no video: {order or 'none'} (upload order); quota today: {ledger.today['units']} units, "
          f"{ledger.today['uploads']} uploads by this tool")
    uploaded, sim = 0, 0  # sim: what the dry run's uploads would have spent
    for n in order:
        ledger = Ledger(a.ledger)
        units = upload_units(n, have, a.upload_units)
        room = a.daily - a.margin - ledger.today["units"] - sim
        if have and n < max(have):  # the backlog leaves room for today's later shift ends
            room -= reserve_units(upload_cost=a.upload_units)
        if ledger.today.get("exhausted") or units > room or ledger.today["uploads"] >= UPLOADS_A_DAY:
            print(f"shift{n:02d}: waits for tomorrow (needs {units} units, {room} left today)")
            break
        priv = upload_privacy(n, have)  # what apply makes it once its description is checked
        cmd = [sys.executable, str(HERE / "archive_upload.py"), "--shifts", str(n), "--limit", "1", "--privacy", "private",
               "--manifest", str(a.manifest), "--runs-dir", str(a.runs_dir)]
        if a.dry_run:
            print(f"shift{n:02d}: would upload private, then {priv} ({units} units with its follow-ups): " + " ".join(cmd[1:]))
            have.add(n)
            sim += units
            continue
        merge_wait(REPO, a.merge_wait)  # archive_upload.py and shift_video.py run from this checkout
        plan = shift_plan(n, a)
        if plan is None:
            print(f"shift{n:02d}: no recording to upload; skipped")
            continue
        free = ssd_free_gb(SSD)
        if free is not None and free - plan["need_gb"] < a.keep_free_gb:
            print(f"shift{n:02d}: needs {plan['need_gb']:.0f} GB on the SSD for the copy and join, {free:.0f} GB free "
                  f"(keep {a.keep_free_gb:.0f} GB): skipped")
            continue
        merge_wait(REPO, a.merge_wait)
        print(f"shift{n:02d}: uploading private (then {priv}): {' '.join(cmd[1:])}", flush=True)
        r = subprocess.run(cmd)
        vid = (load(a.manifest).get(f"shift{n:02d}") or {}).get("id")
        if r.returncode != 0 or not vid:
            print(f"shift{n:02d}: the upload did not finish (exit {r.returncode}); rotate again to resume")
            break
        up = load(Path(a.runs_dir) / f"shift{n:02d}" / "video" / "upload.json")
        ledger.spend("videos.insert", f"shift{n:02d}", a.upload_units, upload=True)
        if up.get("thumbnail_set"):
            ledger.spend("thumbnails.set", f"shift{n:02d}", COST["thumbnails.set"])
        state = load(a.state, {"videos": {}})
        state.setdefault("videos", {})[f"shift{n:02d}"] = {"id": vid, "privacy": "private",
                                                           "status": {"privacyStatus": "private", "embeddable": True,
                                                                      "license": "youtube", "selfDeclaredMadeForKids": False}}
        save(a.state, state)
        have.add(n)
        uploaded += 1
        apply(argparse.Namespace(**dict(vars(a), refresh=False)))  # the demotion and the playlist insert right away
    if not a.dry_run:
        apply(argparse.Namespace(**dict(vars(a), refresh=False)))
    return uploaded


def shift_plan(n, a):
    """archive_upload's plan for one shift (None: no recording) with the GB the copy and join need on the SSD."""
    out = subprocess.run([sys.executable, str(HERE / "archive_upload.py"), "--dry-run", "--shifts", str(n), "--runs-dir",
                          str(a.runs_dir), "--manifest", str(a.manifest)], capture_output=True, text=True, timeout=900)
    row = next((ln for ln in out.stdout.splitlines() if ln.startswith(f"| shift{n:02d}")), "")
    cells = [c.strip() for c in row.strip("|").split("|")]
    if len(cells) < 8 or cells[5] in ("", "uploaded") or cells[5].startswith("skip"):
        return None
    action = cells[5]
    size = float(cells[6].split()[0]) if cells[6] else 0.0
    box = sum(float(m) for m in re.findall(r"\(box, ([\d.]+) GB", cells[2]))
    return {"action": action, "size_gb": size, "need_gb": box + (size if action == "join" else 0)}


def code_stamp():
    """yt_archive.py and yt_upload.py as on disk: follow runs itself again when they change (a merged fix)."""
    h = hashlib.sha1()
    for f in ("yt_archive.py", "yt_upload.py"):
        try:
            h.update((HERE / f).read_bytes())
        except OSError:
            pass
    return h.hexdigest()


def follower_pid(pid_file=FOLLOW_PID):
    """The live follower's pid from its pid file, else None (a pid gone or reused by another command)."""
    try:
        pid = int(Path(pid_file).read_text().strip())
    except (OSError, ValueError):
        return None
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return None
    except PermissionError:
        pass
    cmd = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout
    return pid if "yt_archive.py" in cmd and " follow" in cmd else None


def follow(a, sleep=time.sleep, clock=time.time):
    """Rotate after each new "shiftN up" line in the autopilot's log, and once at each new Pacific day (the
    backlog's next share of the quota). Poll every --interval seconds."""
    other = follower_pid(a.pid_file)
    if other and other != os.getpid():
        print(f"another follower runs (pid {other}): not started", flush=True)
        return 0
    if Path(a.pid_file).parent.is_dir():
        Path(a.pid_file).write_text(str(os.getpid()))
    stamp = code_stamp()
    state = load(a.state, {"videos": {}})
    last = state.get("follow", {}).get("up", 0)
    day = state.get("follow", {}).get("day")
    retry_at = 0
    print(f"{datetime.datetime.now():%m-%d %H:%M:%S} following {a.log} (pid {os.getpid()}, code {stamp[:8]}, from "
          f"{REPO}; last handled: shift{last} up, day {day})", flush=True)
    while True:
        try:
            ups = [int(m.group(2)) for m in map(UP_LINE.match, Path(a.log).read_text(errors="replace").splitlines()) if m] \
                if Path(a.log).exists() else []
            top = max(ups) if ups else 0
            today = pacific_day()
            if (top > last or today != day) and clock() >= retry_at and not merging(REPO):
                why = f"shift{top} up" if top > last else f"a new day ({today})"
                print(f"{datetime.datetime.now():%m-%d %H:%M:%S} rotate: {why}", flush=True)
                rotate(a)
                state = load(a.state, {"videos": {}})
                last, day = max(top, last), today
                state["follow"] = {"up": last, "day": day, "at": datetime.datetime.now().isoformat(timespec="seconds")}
                save(a.state, state)
        except (Exception, SystemExit) as e:  # noqa: BLE001  (one bad rotate must not end the follower)
            if not isinstance(e, (Busy, SystemExit)):
                traceback.print_exc()
            retry_at = clock() + a.retry
            print(f"{datetime.datetime.now():%m-%d %H:%M:%S} rotate stopped: {e or type(e).__name__}; "
                  f"tried again in {a.retry} s", flush=True)
        if a.once:
            return 0
        if code_stamp() != stamp and not merging(REPO):
            print(f"{datetime.datetime.now():%m-%d %H:%M:%S} yt_archive.py or yt_upload.py changed: running again",
                  flush=True)
            os.execv(sys.executable, [sys.executable, "-u", str(Path(__file__).resolve())] + a.argv)
        sleep(a.interval)


def follow_args(a):
    """follow's command line with a's paths and limits (follow --start passes them on)."""
    out = ["follow"]
    for k in ("manifest", "extra", "state", "ledger", "site_videos", "runs_dir", "daily", "margin", "upload_units",
              "from_shift", "keep_free_gb", "log", "interval", "retry", "merge_wait", "pid_file"):
        out += ["--" + k.replace("_", "-"), str(getattr(a, k))]
    return out


def follow_start(a):
    """The follower in the background (its own session: a shift's stop and a closed terminal leave it), unless the pid
    file names a live one."""
    pid = follower_pid(a.pid_file)
    if pid:
        print(f"youtube follower running (pid {pid}): kept; log {a.follow_log}")
        return 0
    if not Path(a.pid_file).parent.is_dir():
        print(f"youtube follower: no folder {Path(a.pid_file).parent}: not started")
        return 1
    with open(a.follow_log, "a") as log:
        p = subprocess.Popen([sys.executable, "-u", str(Path(__file__).resolve())] + follow_args(a), cwd=str(REPO),
                             stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    Path(a.pid_file).write_text(str(p.pid))
    print(f"youtube follower started: pid {p.pid}, every {a.interval} s; log {a.follow_log}")
    return 0


def follow_cmd(a):
    if os.environ.get("POG_TEST") == "1" and Path(a.pid_file) == FOLLOW_PID and (a.start or a.check or a.stop):
        print("POG_TEST=1: no YouTube follower from the live video-work (pass --pid-file)")  # start-team's test runs
        return 0
    if a.start:
        return follow_start(a)
    pid = follower_pid(a.pid_file)
    if a.check:
        print(f"youtube follower running (pid {pid}, log {a.follow_log})" if pid else "youtube follower: not running")
        return 0 if pid else 1
    if a.stop:
        if pid:
            os.kill(pid, 15)
        print(f"stopped the youtube follower (pid {pid})" if pid else "no youtube follower running")
        return 0
    a.argv = follow_args(a)
    return follow(a)


def quota(a):
    led = Ledger(a.ledger)
    t = led.today
    print(f"{led.day} (Pacific): {t['units']} units and {t['uploads']} uploads by this tool"
          f"{', exhausted' if t.get('exhausted') else ''}; {len(t['ops'])} calls")
    kinds = {}
    for _, op, _, u in t["ops"]:
        k = kinds.setdefault(op, [0, 0])
        k[0] += 1
        k[1] += u
    for op, (n, u) in sorted(kinds.items()):
        print(f"  {op}: {n} calls, {u} units")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["plan", "apply", "rotate", "follow", "quota", "titles"])
    ap.add_argument("--shifts", help="titles: FIRST-LAST, the shift numbers to retitle (default every video)")
    ap.add_argument("--apply", action="store_true", help="titles: set them on YouTube (default: list them)")
    ap.add_argument("--refresh", action="store_true", help="read YouTube's state first (a few units)")
    ap.add_argument("--dry-run", action="store_true", help="rotate: list the uploads, upload nothing")
    ap.add_argument("--manifest", default=str(MANIFEST))
    ap.add_argument("--extra", default=str(EXTRA))
    ap.add_argument("--state", default=str(STATE))
    ap.add_argument("--ledger", default=str(LEDGER))
    ap.add_argument("--site-videos", default=str(SITE_VIDEOS))
    ap.add_argument("--runs-dir", default=str(RUNS))
    ap.add_argument("--daily", type=int, default=DAILY)
    ap.add_argument("--margin", type=int, default=MARGIN, help="units left unspent each day (reads, other tools)")
    ap.add_argument("--upload-units", type=int, default=0,
                    help="units an upload takes of the daily 10,000 (0: the uploads bucket, docs/VIDEOS.md; 1600: the old figure)")
    ap.add_argument("--from-shift", type=int, default=70, help="rotate: the first shift it may upload")
    ap.add_argument("--keep-free-gb", type=float, default=35.0)
    ap.add_argument("--log", default=str(AUTOPILOT_LOG))
    ap.add_argument("--interval", type=int, default=120)
    ap.add_argument("--once", action="store_true", help="follow: one check, then exit")
    ap.add_argument("--retry", type=int, default=1800, help="follow: seconds before a failed rotate is tried again")
    ap.add_argument("--merge-wait", type=int, default=1800,
                    help="rotate: seconds to wait for a merge in this checkout before an upload, then stop (Busy)")
    ap.add_argument("--pid-file", default=str(FOLLOW_PID))
    ap.add_argument("--follow-log", default=str(FOLLOW_LOG))
    ap.add_argument("--start", action="store_true", help="follow: start it in the background unless one runs")
    ap.add_argument("--check", action="store_true", help="follow: is one running (exit 1 when not)")
    ap.add_argument("--stop", action="store_true", help="follow: stop the running one")
    a = ap.parse_args(argv)
    if a.cmd == "plan":
        return apply(a, dry=True)
    if a.cmd == "apply":
        return apply(a)
    if a.cmd == "rotate":
        rotate(a)
        return 0
    if a.cmd == "follow":
        return follow_cmd(a)
    if a.cmd == "titles":
        return titles(a, dry=not a.apply)
    return quota(a)


if __name__ == "__main__":
    sys.exit(main())
