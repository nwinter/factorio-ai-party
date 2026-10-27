#!/usr/bin/env python3
"""The shift videos on YouTube made public as an archive (Nick d27 07:05): privacy, one playlist, the rotation.

  python3 tools/yt_archive.py plan [--refresh]     # what apply would change and its quota; with --refresh it reads
                                                   # YouTube's state first (a few units), else this tool's state file
  python3 tools/yt_archive.py apply [--refresh]    # make those changes, within today's quota, resumable
  python3 tools/yt_archive.py rotate [--dry-run]   # upload finished shifts not on YouTube yet, then apply
  python3 tools/yt_archive.py follow               # rotate after each "shiftN up" in the autopilot's log
  python3 tools/yt_archive.py quota                # today's ledger

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
tools/archive_upload.py --shifts N --limit 1 --privacy private, then apply (its description checked for the owner's
name before it leaves private; public when it is the latest, else unlisted; the previous latest unlisted), while
the day's quota has room for the upload and its follow-ups (thumbnail, playlist insert, the previous latest's
demotion) and the SSD keeps --keep-free-gb free after the copy and join (the R2 encode needs about 35 GB). Then apply.
"""
import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import time
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
SITE_VIDEOS = REPO / "site" / "content" / "videos.json"
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
# the stream owner's name (site/build.py _OWNER): never on a public page, so a description line naming it goes before
# the video leaves private (the site's own address does not count)
OWNER = re.compile(r"(?i)\bnick(?:\s*winter)?\b")
SITE_HOST = re.compile(r"(?i)[\w.-]*nickwinter\.net\S*")


class QuotaExceeded(Exception):
    pass


# ---------------------------------------------------------------- selection (pure)

def shift_n(run):
    return int(re.sub(r"\D", "", run))


def names_owner(text):
    return bool(OWNER.search(SITE_HOST.sub("", text or "")))


def scrub(description):
    """The description without the lines that name the owner (a chat bullet, a chapter line)."""
    return "\n".join(ln for ln in (description or "").split("\n") if not names_owner(ln))


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
    for r in order:  # first: the owner's name out of the description, while the video is still private
        if names_owner(videos[r].get("description")) and not (sv.get(r) or {}).get("scrubbed"):
            ops.append({"op": "videos.update.snippet", "run": r, "units": COST["videos.list"] + COST["videos.update"]})
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
    if op["op"] == "videos.update.snippet":
        r = client.call("videos.list", "GET", f"{yt.API}/videos?part=snippet&id={v['id']}")
        items = r.get("items") or [{"snippet": {"title": v.get("title"), "description": v.get("description"),
                                                "categoryId": "20"}}]
        sn = items[0]["snippet"]
        body = {k: sn[k] for k in ("title", "categoryId", "tags", "defaultLanguage", "defaultAudioLanguage") if k in sn}
        body["description"] = scrub(sn.get("description"))
        client.call("videos.update", "PUT", f"{yt.API}/videos?part=snippet", body={"id": v["id"], "snippet": body})
        cur["scrubbed"] = True
        return
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
    """site/content/videos.json: the videos YouTube shows (unlisted or public), as build.py reads them."""
    sv = state.get("videos", {})
    pl = (state.get("playlist") or {}).get("id")
    out = {}
    for run in sorted(videos, key=lambda r: videos[r]["shift"]):
        p = (sv.get(run) or {}).get("privacy")
        if p not in ("public", "unlisted"):
            continue
        v = videos[run]
        out[run] = {k: v[k] for k in ("id", "shift", "title", "uploaded", "timeline") if k in v}
        out[run]["description"] = scrub(v.get("description"))
        out[run]["chapters"] = [c for c in v.get("chapters") or [] if not names_owner(c.get("title"))]
        out[run].update(playlist=pl if (sv.get(run) or {}).get("item") else None, privacy=p)
    if Path(path).parent.is_dir():
        save(path, out)
    return out


# ---------------------------------------------------------------- commands

def describe(ops, videos):
    rows = []
    for op in ops:
        if op["op"] == "playlists.insert":
            rows.append(f"playlists.insert: create the public playlist {PLAYLIST!r}")
        elif op["op"] == "playlists.update":
            rows.append(f"playlists.update: make the playlist {PLAYLIST!r} public")
        elif op["op"] == "videos.update.snippet":
            rows.append(f"videos.list + videos.update (snippet): {op['run']} ({videos[op['run']]['id']}): the description "
                        f"without its {sum(names_owner(ln) for ln in videos[op['run']]['description'].split(chr(10)))} "
                        f"line(s) that name the stream owner")
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
            # and no video leaves private while its description still names the owner
            if op["op"] == "videos.update" and names_owner(videos[op["run"]].get("description")) \
                    and not state["videos"].get(op["run"], {}).get("scrubbed"):
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
        plan = shift_plan(n, a)
        if plan is None:
            print(f"shift{n:02d}: no recording to upload; skipped")
            continue
        free = ssd_free_gb(SSD)
        if free is not None and free - plan["need_gb"] < a.keep_free_gb:
            print(f"shift{n:02d}: needs {plan['need_gb']:.0f} GB on the SSD for the copy and join, {free:.0f} GB free "
                  f"(keep {a.keep_free_gb:.0f} GB): skipped")
            continue
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


def follow(a):
    """Rotate after each new "shiftN up" line in the autopilot's log, and once at each new Pacific day (the
    backlog's next share of the quota). Poll every --interval seconds."""
    state = load(a.state, {"videos": {}})
    last = state.get("follow", {}).get("up", 0)
    day = state.get("follow", {}).get("day")
    print(f"following {a.log} (last handled: shift{last} up, day {day})", flush=True)
    while True:
        ups = [int(m.group(2)) for m in map(UP_LINE.match, Path(a.log).read_text(errors="replace").splitlines()) if m] \
            if Path(a.log).exists() else []
        top = max(ups) if ups else 0
        today = pacific_day()
        if top > last or today != day:
            why = f"shift{top} up" if top > last else f"a new day ({today})"
            print(f"{datetime.datetime.now():%m-%d %H:%M:%S} rotate: {why}", flush=True)
            try:
                rotate(a)
            except SystemExit as e:
                print(f"rotate stopped: {e}", flush=True)
            state = load(a.state, {"videos": {}})
            last, day = max(top, last), today
            state["follow"] = {"up": last, "day": day}
            save(a.state, state)
        if a.once:
            return 0
        time.sleep(a.interval)


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
    ap.add_argument("cmd", choices=["plan", "apply", "rotate", "follow", "quota"])
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
    a = ap.parse_args(argv)
    if a.cmd == "plan":
        return apply(a, dry=True)
    if a.cmd == "apply":
        return apply(a)
    if a.cmd == "rotate":
        rotate(a)
        return 0
    if a.cmd == "follow":
        return follow(a)
    return quota(a)


if __name__ == "__main__":
    sys.exit(main())
