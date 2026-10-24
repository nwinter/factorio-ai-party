#!/usr/bin/env python3
"""A narrated camera tour for the stream (Nick, d23 10:28): a script of stops, each a camera shot with a caption and a
narration in one narrator voice, aired through the stream service. Stdlib only (+ ffmpeg for the clips' loudness).

  python3 tools/stream/tour.py prepare SCRIPT [--voice el-brian,oa-fable]   # render every narration clip first
  python3 tools/stream/tour.py dry-run SCRIPT [--from ID]                   # the timeline: no camera, no audio
  python3 tools/stream/tour.py run SCRIPT [--from ID]                       # on air
  python3 tools/stream/tour.py stop                                         # end a running tour (another terminal)

SCRIPT: JSON, a list of stops (or {"stops": [...]}); the fields are in tools/stream/tour-FORMAT.md. Each stop is a
shot (target: {surface, x, y, zoom} a planet spot, or {platform: NAME} a ship) with a caption and a narration in
one narrator voice; facts are for the operator and never aired.

prepare renders each narration with voices.TTS (the caster's TTS path; keys in ~/.config/pog/, never printed) into
SCRIPT_DIR/tour-clips/ with manifest.json ({voice, provider, clips: {id: {file, hash, duration}}}). A clip whose
narration and voice are unchanged is kept, so editing one stop re-renders one clip. All clips are in ONE voice: the
first of --voice whose provider renders every clip (a provider that fails mid-way hands the whole tour to the next).
The default narrator is a voice no host and no agent speaks in (checked against the stream state when it is up).

Timing (d23 batch128 CK1, Nick 17:30: "get the timing really tight between the shot durations and the measured voice
line durations"): a narrated stop lasts LEAD_S + its clip's measured length + TAIL_S (+ hold_s; at least
min_seconds); a stop without narration lasts its seconds. The run is one timeline on the clock: each stop is sent to
the service PREROLL_S ahead, its look with cut_at (a standby frames it then and the program cuts at that moment) and
its narration with at = the cut + LEAD_S (the page loads it then and starts it on its audio clock). The look's
`aired` (when the program showed it) against the cut asked for is the drift; later cuts are asked that much sooner.
When an agent's voiced line waits in the page's queue near a stop's end, the stop is held for its length (it plays
over the shot after the narration; --no-agent-gaps: no gap, the lines wait for the tour's end or expire).

The hosts stay quiet for the whole tour: run writes caster.py's hush file (logs/hosts-hush.json; caster.py
--hush-file) and removes it at the end. The director's own cuts wait while the look is on (lookcam.py). A stop whose
target is refused (unknown platform, uncharted ground) is skipped with a log line and the next takes its time. stop
(or Ctrl-C) ends the tour: the tour's look is cleared, a narration not played yet is taken back and the hush lifted.
Every stop is logged to tools/stream/logs/tour-<start>.jsonl with what aired when (epoch and local time; the cut
asked and aired, the narration planned and started), for the archive and clips.
"""
import argparse, base64, hashlib, json, os, signal, sys, time, urllib.error, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import tourlay  # noqa: E402

LOG_DIR = os.path.join(HERE, "logs")
HUSH_FILE = os.path.join(LOG_DIR, "hosts-hush.json")  # caster.py HUSH_FILE
RUN_FILE = os.path.join(LOG_DIR, "tour-run.json")  # {pid, script, started, stop}: the tour on air now
STOP_FILE = os.path.join(LOG_DIR, "tour-stop")  # `tour.py stop` writes it; a running tour ends at its next second
FEED = "http://127.0.0.1:8788"
# The narrator: no host (voices.ROLE_VOICES) and no agent on d23 speaks in these. el-brian (ElevenLabs Brian: deep,
# resonant, comforting) first, OpenAI fable (an expressive storyteller) when ElevenLabs is out.
VOICES = ["el-brian", "oa-fable"]
DIRECTION = ("A thoughtful documentary narrator looking back over a long story: measured, warm and unhurried, with a "
             "point of view; natural pauses between sentences; never a sportscaster.")
LEAD_S = 0.8  # the cut, then this long before the narration starts
TAIL_S = 1.5  # after the narration ends, this long before the next cut
MIN_STOP_S = 3.0  # no stop is shorter (a standby needs ~1.5 s to frame the next shot)
SILENT_S = 8.0  # a stop with no narration and no seconds
WORDS_PER_S = 2.5  # the timeline's estimate for a stop without a prepared clip (150 words a minute)
PREROLL_S = 4.0  # each stop goes to the service this long before its cut (the standby frames it, the page loads it)
MIN_PREROLL_S = 2.0  # a stop running late is still sent at least this long ahead
LOOK_MAX_S = 60.0  # lookcam.MAX_S
LOOK_RENEW_S = 20.0  # extend a look this long before it ends
LOOK_SPARE_S = 15.0  # a look runs this long past its stop's planned end (the next stop's look replaces it)
AIRED_WAIT_S = 3.0  # after the cut, wait at most this long for the snapshot's look.aired
START_WAIT_S = 5.0  # after the narration's moment, wait at most this long for the page's start report
DRIFT_MAX_S = 2.0  # a measured cut drift beyond this is not used
AGENT_GAP_MAX_S = 25.0  # the longest agent line a stop is held for


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


# ---- the script --------------------------------------------------------------------------------------------------
def load_script(path):
    with open(path) as f:
        data = json.load(f)
    stops = data.get("stops") if isinstance(data, dict) else data
    if not isinstance(stops, list):
        raise ValueError("expected a list of stops or {\"stops\": [...]}")
    return stops


def number(v):
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v != v or v in (float("inf"), float("-inf")):
        raise ValueError(f"not a finite number: {v!r}")
    return float(v)


def check_stop(stop):
    """-> (stop normalised, None) or (None, why it cannot air)."""
    if not isinstance(stop, dict):
        return None, "not an object"
    sid = str(stop.get("id") or "").strip()
    if not sid:
        return None, "no id"
    t = stop.get("target")
    if not isinstance(t, dict):
        return None, "no target"
    try:
        if t.get("platform"):
            target = {"platform": str(t["platform"]).strip()}
        else:
            if not str(t.get("surface") or "").strip():
                return None, "target has neither platform nor surface"
            target = {"surface": str(t["surface"]).strip(), "x": number(t.get("x")), "y": number(t.get("y"))}
            if t.get("zoom") is not None:
                target["zoom"] = number(t["zoom"])
        secs = number(stop.get("seconds")) if stop.get("seconds") is not None else None
        least = number(stop.get("min_seconds")) if stop.get("min_seconds") is not None else 0.0
        hold = number(stop.get("hold_s")) if stop.get("hold_s") is not None else 0.0
    except ValueError as x:
        return None, f"target, seconds, min_seconds or hold_s: {x}"
    return {"id": sid, "target": target, "seconds": max(0.0, secs) if secs is not None else None,
            "move": stop.get("move"),  # (CK2) checked by move_for in checked()
            "min_seconds": max(0.0, least), "hold_s": max(0.0, min(30.0, hold)),
            "caption": " ".join(str(stop.get("caption") or "").split())[:80],
            "narration": " ".join(str(stop.get("narration") or "").split())}, None


def move_for(stop, length):
    """(CK2) The stop's move as camerapath segments over a stop of `length` s (seconds from the cut), None for a still
    shot, or "pan" (a whole ship with no move: the director's bow-to-stern pan). ValueError says what is wrong."""
    import camerapath
    raw, t = stop.get("move"), stop["target"]
    if raw in (None, "hold"):
        return "pan" if raw is None and "platform" in t and "x" not in t else None
    moves = raw if isinstance(raw, list) else [raw]
    if not moves or len(moves) > 8:
        raise ValueError("move is one move or a list of 1..8")
    here = {"x": t["x"], "y": t["y"], "zoom": t.get("zoom", 0.75)} if "x" in t else None

    def when(v, what, default):
        if v is None:
            return default
        if v == "end":
            return length
        v = camerapath.number(v, what)
        return length + v if v < 0 else v
    free = [m for m in moves if m == "hold" or (isinstance(m, dict) and m.get("from_s") is None and m.get("to_s") is None)]
    share = length / len(moves) if len(free) == len(moves) else None
    segs, last_end = [], 0.0
    for i, m in enumerate(moves):
        what = f"move {i + 1}" if len(moves) > 1 else "move"
        if m == "hold":
            last_end = share * (i + 1) if share else last_end
            continue
        if not isinstance(m, dict):
            raise ValueError(f"{what}: an object with to, zoom or path (or \"hold\")")
        if "path" in m:
            if not isinstance(m["path"], list) or not m["path"]:
                raise ValueError(f"{what}: path is a list of points {{x, y, zoom}}")
            pts = ([here] if here else []) + m["path"]
        elif "to" in m or "zoom" in m:
            if not here:
                raise ValueError(f"{what}: a whole ship has no spot to move from: give target x, y or a path")
            to = dict(here, **(m.get("to") or {}))
            if "zoom" in m:
                to["zoom"] = m["zoom"]
            pts = [here, to]
        else:
            raise ValueError(f"{what}: give to {{x, y, zoom}}, zoom, or path [...]")
        full, prev = [], None
        for k, p in enumerate(pts):  # a point without zoom keeps the last one's
            if not isinstance(p, dict):
                raise ValueError(f"{what} point {k + 1}: an object {{x, y, zoom}}")
            q = dict(p)
            if q.get("zoom") is None:
                q["zoom"] = (prev or {}).get("zoom", 0.75)
            full.append(q)
            prev = q
        t0 = when(m.get("from_s"), f"{what} from_s", share * i if share else last_end)
        t1 = when(m.get("to_s"), f"{what} to_s", share * (i + 1) if share else length)
        segs.append({"pts": full, "t0": t0, "t1": t1, "ease": m.get("ease", "inout")})
        here, last_end = dict(full[-1]), t1
    if not segs:
        return None
    return camerapath.check({"segments": segs})


def checked(stops):
    """[(index, stop or None, why)] in script order; a repeated id is invalid."""
    out, seen = [], set()
    for i, raw in enumerate(stops):
        s, why = check_stop(raw)
        if s and s["id"] in seen:
            s, why = None, f"id {s['id']!r} repeated"
        if s:
            try:
                move_for(s, 60.0)
                s["marks"] = tourlay.check_marks(raw.get("marks") if isinstance(raw, dict) else None)
            except ValueError as x:
                s, why = None, str(x) if str(x).startswith(("move", "mark")) else f"move: {x}"
        if s:
            seen.add(s["id"])
        out.append((i, s, why))
    return out


def from_index(rows, start):
    """The rows from the stop with id `start` (None: all)."""
    if not start:
        return rows
    for k, (_, s, _) in enumerate(rows):
        if s and s["id"] == start:
            return rows[k:]
    raise SystemExit(f"no stop with id {start!r} (ids: {', '.join(s['id'] for _, s, _ in rows if s)})")


def target_text(t):
    if "platform" in t:
        return f"ship {t['platform']}"
    return f"{t['surface']} ({round(t['x'])}, {round(t['y'])})" + (f" zoom {t['zoom']:g}" if "zoom" in t else "")


def stop_length(stop, clip_s, lead=LEAD_S, tail=TAIL_S):
    """A narrated stop: lead + clip + tail + hold_s, at least min_seconds (its seconds are not used). clip_s None, no
    narration: its seconds (SILENT_S without). Never under MIN_STOP_S."""
    if clip_s:
        return max(MIN_STOP_S, stop["min_seconds"], lead + clip_s + tail + stop["hold_s"])
    return max(MIN_STOP_S, stop["min_seconds"], stop["seconds"] if stop["seconds"] is not None else SILENT_S)


# ---- clips -------------------------------------------------------------------------------------------------------
def clip_dir(script):
    return os.path.join(os.path.dirname(os.path.abspath(script)), "tour-clips")


def clip_hash(voice, text):
    return hashlib.sha1(json.dumps([voice, DIRECTION, text]).encode()).hexdigest()[:12]


def read_manifest(out):
    try:
        with open(os.path.join(out, "manifest.json")) as f:
            m = json.load(f)
        return m if isinstance(m, dict) and isinstance(m.get("clips"), dict) else None
    except (OSError, ValueError):
        return None


def clip_for(manifest, out, stop):
    """The prepared clip for this stop's narration ({file, hash, duration} with path) or None (missing, stale)."""
    if not manifest or not stop["narration"]:
        return None
    c = manifest["clips"].get(stop["id"])
    if not c or c.get("hash") != clip_hash(manifest.get("voice"), stop["narration"]):
        return None
    path = os.path.join(out, c["file"])
    return dict(c, path=path) if os.path.exists(path) else None


def voices_in_use(feed):
    """The agents' voices from the stream state ({voice: agent}); {} when the service is not up."""
    try:
        with urllib.request.urlopen(feed.rstrip("/") + "/state.json", timeout=3) as r:
            s = json.load(r)
    except Exception:
        return {}
    return {a.get("voice"): a.get("name") for a in s.get("agents") or [] if a.get("voice")}


def render_all(rows, out, voice, tts, manifest, speak=None):
    """Render every narration of `rows` in `voice` (kept clips stay). -> (clips {id: row}, error or None). `speak`
    (tests): text -> (audio, ctype, seconds, provider)."""
    import voices as V
    old = manifest.get("clips", {}) if manifest and manifest.get("voice") == voice else {}
    clips = {}
    for _, s, _ in rows:
        if not s or not s["narration"]:
            continue
        h = clip_hash(voice, s["narration"])
        name = f"{s['id']}-{h}.mp3"
        path = os.path.join(out, name)
        prev = old.get(s["id"])
        if prev and prev.get("hash") == h and os.path.exists(path):
            clips[s["id"]] = prev
            continue
        try:
            if speak:
                audio, ctype, dur, prov = speak(s["narration"])
            else:
                audio, ctype, dur, _ = tts.speak(s["narration"], voice, direction=DIRECTION)
                prov = tts.last_here().get("provider")
        except Exception as x:  # TTSError carries the provider's reply, never the key
            return clips, f"{s['id']}: {type(x).__name__}: {str(x)[:200]}"
        if ctype != "audio/mpeg":
            return clips, f"{s['id']}: {ctype} from {prov} (expected audio/mpeg)"
        with open(path + ".tmp", "wb") as f:
            f.write(audio)
        os.replace(path + ".tmp", path)
        clips[s["id"]] = {"file": name, "hash": h, "duration": round(float(dur or V.duration(audio)), 2),
                          "chars": len(s["narration"]), "provider": prov}
        log(f"[prepare] {s['id']}: {clips[s['id']]['duration']:.1f} s ({len(s['narration'].split())} words, {prov})")
    return clips, None


def prepare(a):
    import voices as V
    rows = checked(load_script(a.script))
    for i, s, why in rows:
        if not s:
            log(f"[prepare] stop {i + 1}: invalid ({why}); it will be skipped")
    out = a.out or clip_dir(a.script)
    os.makedirs(out, exist_ok=True)
    manifest = read_manifest(out)
    taken = voices_in_use(a.feed)
    hosts = {v for vs in V.ROLE_VOICES.values() for v in vs} | {V.OPERATOR_VOICE}
    errors = []
    for voice in [v.strip() for v in a.voice.split(",") if v.strip()]:
        if voice not in V.CATALOG:
            errors.append(f"{voice}: not a catalog voice")
            continue
        if voice in hosts or voice in taken:
            log(f"[prepare] {voice} is {'a host' if voice in hosts else taken[voice]}'s voice; the narrator needs its own")
            errors.append(f"{voice}: taken")
            continue
        prov = V.provider_of(voice)
        try:
            tts = V.TTS(prov)  # one provider: a failure raises (no stand-in voice mid-tour)
        except Exception as x:
            errors.append(f"{voice}: {type(x).__name__}: {str(x)[:160]}")
            log(f"[prepare] {voice} ({prov}) unavailable: {str(x)[:160]}")
            continue
        clips, err = render_all(rows, out, voice, tts, manifest)
        if err:
            errors.append(f"{voice}: {err}")
            log(f"[prepare] {voice} failed at {err}; the whole tour goes to the next voice")
            continue
        m = {"voice": voice, "provider": prov, "direction": DIRECTION, "script": os.path.abspath(a.script),
             "made": time.strftime("%Y-%m-%d %H:%M:%S"), "clips": clips}
        with open(os.path.join(out, "manifest.json"), "w") as f:
            json.dump(m, f, indent=1)
        total = sum(c["duration"] for c in clips.values())
        log(f"[prepare] {len(clips)} clips in {voice} ({prov}), {total / 60:.1f} min of narration, in {out}")
        print_timeline(rows, m, out)
        return 0
    log("[prepare] no voice rendered the whole tour: " + "; ".join(errors))
    return 1


# ---- the timeline ------------------------------------------------------------------------------------------------
def timeline(rows, manifest, out, lead=LEAD_S, tail=TAIL_S):
    """[(stop, seconds, clip seconds or None, estimated)] for the valid stops, and the invalid ones [(index, why)]."""
    plan, bad = [], []
    for i, s, why in rows:
        if not s:
            bad.append((i, why))
            continue
        c = clip_for(manifest, out, s)
        est = c is None and bool(s["narration"])
        clip_s = c["duration"] if c else (len(s["narration"].split()) / WORDS_PER_S if s["narration"] else None)
        plan.append((s, stop_length(s, clip_s, lead, tail), clip_s, est))
    return plan, bad


def view_frac():
    """The share of a client's width the on-air hole shows (cuts.view_frac of static/layout.json's main hole)."""
    try:
        with open(os.path.join(HERE, "static", "layout.json")) as f:
            _, _, w, h = json.load(f)["cams"]["main"]
        return round(min(1.0, (w / h) / (1920 / 1080)), 3)
    except (OSError, ValueError, KeyError, TypeError):
        return 1.0


def move_text(mv):
    """ "0.0-15.6 s (60, 40) z0.5 -> (90, 40) z0.8 inout; ..." """
    return "; ".join(f"{g['t0']:.1f}-{g['t1']:.1f} s " + " -> ".join(f"({p['x']:g}, {p['y']:g}) z{p['zoom']:g}"
                                                                    for p in g["pts"]) + f" {g['ease']}"
                     for g in mv["segments"])


def clock(sec):
    return f"{int(sec // 60):2d}:{int(sec % 60):02d}"


def print_timeline(rows, manifest, out, platforms=None, lead=LEAD_S, tail=TAIL_S):
    plan, bad = timeline(rows, manifest, out, lead, tail)
    t = 0.0
    print(f"each narrated stop: cut, {lead:g} s, the clip, {tail:g} s (+ hold_s), then the next cut")
    print(f"{'start':>6}  {'len':>5}  {'clip':>6}  id / target / caption")
    ignored = []
    for s, length, clip_s, est in plan:
        note = ""
        if "platform" in s["target"] and platforms is not None and \
                s["target"]["platform"].casefold() not in {p.casefold() for p in platforms}:
            note = "   [no such platform now: run would skip it]"
        if clip_s and s["seconds"] is not None and abs(s["seconds"] - length) >= 1:
            ignored.append(s["id"])
        clip = "-" if clip_s is None else f"{clip_s:5.1f}" + ("~" if est else "s")
        print(f"{clock(t)}  {length:5.1f}  {clip:>6}  {s['id']} / {target_text(s['target'])} / {s['caption']}{note}")
        mv = move_for(s, length)
        if isinstance(mv, dict):
            print(f"{'':22}move: {move_text(mv)}")
        if s.get("marks"):
            off = []
            if "x" in s["target"]:  # (a whole ship's frame is the director's: not known here)
                view = {"position": {"x": s["target"]["x"], "y": s["target"]["y"]},
                        "zoom": s["target"].get("zoom", 0.75)}
                if isinstance(mv, dict):
                    view["move"] = mv
                off = tourlay.offscreen(view, s["marks"], length, view_frac())
            print(f"{'':22}marks: " + ", ".join(f"{m['type']}" + (f" '{m['text']}'" if m.get("text") else "")
                                                for m in s["marks"])
                  + "".join(f"   [mark {i + 1} out of the frame at {t:g} s]" for i, t in off))
        t += length
    for i, why in bad:
        print(f"  skip  stop {i + 1}: {why}")
    if ignored:
        print(f"  note  seconds not used for {len(ignored)} narrated stop{'s' if len(ignored) != 1 else ''} "
              f"({', '.join(ignored[:6])}{', ...' if len(ignored) > 6 else ''}): the clip sets the length; "
              "min_seconds holds a stop longer")
    ests = sum(1 for p in plan if p[3])
    print(f"total {clock(t).strip()} ({len(plan)} stops" + (f", {len(bad)} invalid" if bad else "")
          + (f"; {ests} clip lengths estimated at {WORDS_PER_S:g} words/s: run prepare" if ests else "")
          + "; agent lines waiting at a stop's end add their length)")
    return t


def dry_run(a):
    rows = from_index(checked(load_script(a.script)), a.start)
    out = a.out or clip_dir(a.script)
    m = read_manifest(out)
    if m:
        print(f"clips: {m.get('voice')} ({m.get('provider')}), made {m.get('made')}")
    plats = platforms(a.feed)
    print_timeline(rows, m, out, plats, a.lead, a.tail)
    return 0


# ---- the service -------------------------------------------------------------------------------------------------
class Service:
    """The stream service's HTTP API (serve.py)."""
    def __init__(self, base):
        self.base = base.rstrip("/")

    def call(self, method, path, body=None, timeout=10):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method,
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.status, json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as x:
            raw = x.read()
            try:
                return x.code, json.loads(raw)
            except ValueError:
                return x.code, {"error": raw[:200].decode(errors="replace")}

    def state(self):
        return self.call("GET", "/state.json", timeout=5)[1]

    def audio_status(self):
        return self.call("GET", "/audio/status", timeout=5)[1]


def platforms(feed):
    """Our platforms' names from the stream state (cameras' platform rows), None when the service is not up."""
    try:
        s = Service(feed).state()
    except Exception:
        return None
    names = set()
    for p in ((s.get("space") or {}).get("platforms") or []):
        if isinstance(p, dict) and p.get("name"):
            names.add(p["name"])
    return names or None


class Tour:
    def __init__(self, svc, rows, manifest, out, log_path, hush_file=HUSH_FILE, stop_file=STOP_FILE,
                 clock=time.time, sleep=time.sleep, lead=LEAD_S, tail=TAIL_S, agent_gaps=True):
        self.svc, self.rows, self.manifest, self.out = svc, rows, manifest, out
        self.log_path, self.hush_file, self.stop_file = log_path, hush_file, stop_file
        self.now, self.sleep = clock, sleep
        self.lead, self.tail, self.agent_gaps = lead, tail, agent_gaps
        self.stopped = False
        self.drift = 0.0  # aired - cut_at asked, smoothed: later cuts are asked this much sooner
        self.cur = None  # the stop holding the camera: {id, look_until, need_until}
        self.scheduled = []  # narration clip ids sent with at (taken back at a stop)
        self.pending = None  # the last stop's log row, written when the next cut (or the end) is known

    def record(self, **kw):
        t = self.now()
        row = dict({"t": round(t, 2), "at": time.strftime("%H:%M:%S", time.localtime(t))}, **kw)
        with open(self.log_path, "a") as f:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")

    def hush(self, seconds):
        tmp = self.hush_file + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"until": round(self.now() + seconds, 1), "by": "tour", "reason": "narrated tour on air"}, f)
        os.replace(tmp, self.hush_file)

    def unhush(self):
        try:
            os.remove(self.hush_file)
        except FileNotFoundError:
            pass

    def want_stop(self):
        if self.stopped or os.path.exists(self.stop_file):
            self.stopped = True
        return self.stopped

    def look_body(self, s, cut_at, seconds, length=None):
        t = s["target"]
        body = {"seconds": max(1.0, min(LOOK_MAX_S, seconds)), "label": s["caption"] or None, "by": "tour",
                "cut_at": round(cut_at, 3), "id": s["id"]}
        mv = move_for(s, length if length is not None else seconds)
        if mv == "pan":
            body.update(move="pan", move_s=round(length if length is not None else seconds, 2))
        elif mv:
            body["move"] = mv
        if "platform" in t:
            body["platform"] = t["platform"]
        else:
            body.update(surface=t["surface"], x=t["x"], y=t["y"])
        if t.get("zoom") is not None:
            body["zoom"] = t["zoom"]
        return body

    def keep_look(self):
        """Extend the look on air (no chart read) when it would end before its stop does."""
        c = self.cur
        if not c or c["look_until"] >= c["need_until"] - 1 or c["look_until"] - self.now() > LOOK_RENEW_S:
            return
        secs = min(LOOK_MAX_S, c["need_until"] - self.now())
        code, r = self.svc.call("POST", "/look/extend", {"seconds": secs, "id": c["id"]})
        if code == 200:
            c["look_until"] = float(r.get("until") or self.now() + secs)
        else:
            log(f"[tour] {c['id']}: extending the look failed (HTTP {code}: {r.get('error')})")
            c["look_until"] = c["need_until"]  # once: the next stop's look comes anyway

    def wait_until(self, t):
        """Sleep to time t (the look kept on); False when the tour was stopped."""
        while self.now() < t:
            if self.want_stop():
                return False
            self.keep_look()
            self.sleep(min(0.5, max(0.01, t - self.now())))
        return not self.want_stop()

    def overlay(self, s, look, cut, end, length):
        """(CK3) The stop's marks (and CK4 captions, CK5 clip) for the page, with the view the look reply gave."""
        body = self.overlay_body(s, look, cut, end, length)
        if not body:
            return
        code, r = self.svc.call("POST", "/tour/overlay", body)
        if code != 200:
            log(f"[tour] {s['id']}: the overlay was refused (HTTP {code}: {(r or {}).get('error')})")

    def overlay_body(self, s, look, cut, end, length):
        if not s.get("marks"):
            return None
        view = {"surface": look.get("surface") or s["target"].get("surface"),
                "position": look.get("position") or {"x": s["target"].get("x"), "y": s["target"].get("y")},
                "zoom": look.get("zoom") or s["target"].get("zoom") or 0.75}
        if isinstance(look.get("move"), dict):
            view["move"] = look["move"]
        return {"id": s["id"], "cut": round(cut, 3), "until": round(end + LOOK_SPARE_S, 3), "length": round(length, 3),
                "view": view, "marks": s["marks"]}

    def narrate(self, s, clip, at):
        with open(clip["path"], "rb") as f:
            audio = f.read()
        meta = {"channel": "narrator", "speaker": "Narrator", "text": s["caption"] or "", "rank": "urgent",
                "duration": clip["duration"], "at": round(at, 3), "expires_in": 30, "tour": s["id"],
                "voice": self.manifest.get("voice"), "audio_b64": base64.b64encode(audio).decode(),
                "ctype": "audio/mpeg"}
        code, r = self.svc.call("POST", "/audio", meta)
        if code == 200 and r.get("id"):
            self.scheduled.append(r["id"])
            return r["id"]
        return None

    def aired(self, sid, until):
        """The snapshot's look.aired for stop sid (the program cut to it), waiting to `until`; None when not seen."""
        while True:
            try:
                lk = self.svc.state().get("look") or {}
            except Exception:
                lk = {}
            if lk.get("id") == sid and lk.get("aired"):
                return float(lk["aired"])
            if self.now() >= until or self.want_stop():
                return None
            self.keep_look()
            self.sleep(0.2)

    def started(self, cid, until):
        """The page's start of clip cid (started_at, on the service's clock), waiting to `until`; None when not seen."""
        while True:
            try:
                st = self.svc.audio_status()
            except Exception:
                st = {}
            p = next((p for p in st.get("playing") or [] if p.get("id") == cid), None)
            if p:
                return float(p.get("started") or self.now())
            if self.now() >= until or self.want_stop():
                return None
            self.keep_look()
            self.sleep(0.2)

    def agent_gap(self, narr_end):
        """The length of an agent's (or the operator's) voiced line waiting in the queue that will not have expired
        when the narration ends, at most AGENT_GAP_MAX_S; 0 when none."""
        if not self.agent_gaps:
            return 0.0, None
        try:
            q = self.svc.audio_status().get("queued") or []
        except Exception:
            return 0.0, None
        for c in q:
            if c.get("channel") in ("narrator", "control") or c.get("at") is not None or not c.get("duration"):
                continue
            if self.now() + float(c.get("expires_in") or 0) < narr_end + 0.5:
                continue
            return min(AGENT_GAP_MAX_S, float(c["duration"])), c.get("speaker")
        return 0.0, None

    def flush(self, ended):
        if self.pending:
            row, self.pending = self.pending, None
            row.update(ended=round(ended, 2), seconds=round(ended - row["cut"], 1), cut_short=self.stopped)
            self.record(**row)

    def run(self, rows):
        plan, _ = timeline(rows, self.manifest, self.out, self.lead, self.tail)
        lengths = {p[0]["id"]: p[1] for p in plan}
        left = sum(lengths.values())
        self.record(event="start", stops=[s["id"] for s, *_ in plan], planned_s=round(left),
                    voice=(self.manifest or {}).get("voice"), lead_s=self.lead, tail_s=self.tail)
        aired = skipped = 0
        T = self.now() + PREROLL_S  # the next cut
        try:
            for i, s, why in rows:
                if self.want_stop():
                    break
                if not s:
                    log(f"[tour] skip stop {i + 1}: invalid ({why})")
                    self.record(event="skipped", index=i, reason=why)
                    skipped += 1
                    continue
                clip = clip_for(self.manifest, self.out, s)
                length = lengths[s["id"]]
                if not self.wait_until(T - PREROLL_S):
                    break
                T = max(T, self.now() + MIN_PREROLL_S)
                cut, end = T, T + length
                narr_at = cut + self.lead if clip else None
                self.hush(left + 120)
                ask = cut - self.drift
                code, r = self.svc.call("POST", "/look", self.look_body(s, ask, end - cut + LOOK_SPARE_S, length))
                if code != 200:
                    why = (r or {}).get("error") or f"HTTP {code}"
                    log(f"[tour] skip {s['id']}: {target_text(s['target'])} refused ({why})")
                    self.record(event="skipped", id=s["id"], target=s["target"], reason=why)
                    skipped += 1
                    left -= length
                    continue  # the next stop takes this cut
                self.overlay(s, r, cut, end, length)
                cid = self.narrate(s, clip, narr_at) if clip else None
                if clip and not cid:
                    log(f"[tour] {s['id']}: the service refused the narration clip")
                if not self.wait_until(cut):
                    break
                self.flush(cut)
                self.cur = {"id": s["id"], "look_until": float(r.get("until") or end + LOOK_SPARE_S),
                            "need_until": end + LOOK_SPARE_S}
                t_air = self.aired(s["id"], cut + AIRED_WAIT_S)
                if t_air is not None and abs(t_air - ask) <= DRIFT_MAX_S:
                    self.drift = round(0.5 * self.drift + 0.5 * (t_air - ask), 3)
                t_narr = self.started(cid, narr_at + START_WAIT_S) if cid else None
                log(f"[tour] {s['id']}: {target_text(s['target'])} cut " +
                    (f"{t_air - cut:+.2f} s" if t_air is not None else "not seen") +
                    (f", narration {t_narr - cut:+.2f} s" if t_narr is not None else ", narration not seen" if cid else "")
                    + f"; {length:.1f} s: {s['caption']}")
                if cid and t_narr is None and not self.stopped:
                    log(f"[tour] {s['id']}: no page started the narration (is the overlay page listening?)")
                gap, who = 0.0, None
                if not self.wait_until(end - PREROLL_S):
                    self.pending = self.row(s, cut, ask, t_air, narr_at, t_narr, clip, gap, who)
                    break
                if clip and i < len(rows) - 1:
                    gap, who = self.agent_gap(narr_at + clip["duration"])
                    if gap:
                        log(f"[tour] {s['id']}: held {gap:.1f} s for {who}'s line waiting in the queue")
                        end += gap
                        self.cur["need_until"] = end + LOOK_SPARE_S
                self.pending = self.row(s, cut, ask, t_air, narr_at, t_narr, clip, gap, who)
                aired += 1
                left -= length
                T = end
            else:
                self.wait_until(T)
        finally:
            self.flush(self.now())
            self.finish()
            self.record(event="end", aired=aired, skipped=skipped, stopped=self.stopped, drift_s=self.drift)
            log(f"[tour] {'stopped' if self.stopped else 'done'}: {aired} stops aired, {skipped} skipped; log "
                f"{self.log_path}")
        return aired, skipped

    def row(self, s, cut, ask, t_air, narr_at, t_narr, clip, gap, who):
        return {"event": "aired", "id": s["id"], "target": s["target"], "caption": s["caption"], "cut": round(cut, 3),
                "cut_asked": round(ask, 3), "on_air": round(t_air, 3) if t_air is not None else None,
                "narration_at": round(narr_at, 3) if narr_at else None,
                "narration_start": round(t_narr, 3) if t_narr is not None else None,
                "clip_s": clip["duration"] if clip else None, "agent_gap_s": gap or None, "agent_gap_for": who}

    def release(self, kind):
        """Clear a hold of `kind` when it is still the tour's (an operator's own later hold stays)."""
        try:
            st = self.svc.state()
        except Exception:
            st = {}
        cur = st.get("look" if kind == "look" else "platform_hold") or {}
        if not cur or cur.get("by") != "tour":
            return
        self.svc.call("DELETE", "/" + kind)

    def finish(self):
        for cid in self.scheduled:  # a narration not played yet (or playing, at a stop) is taken back
            try:
                self.svc.call("POST", "/audio/cancel", {"id": cid}, timeout=3)
            except Exception:
                pass
        self.scheduled = []
        try:
            self.svc.call("DELETE", "/tour/overlay", timeout=3)
        except Exception:
            pass
        for kind in ("look", "platform"):
            try:
                self.release(kind)
            except Exception as x:
                log(f"[tour] clearing the {kind}: {type(x).__name__}: {x}")
        self.unhush()


def run(a):
    rows = from_index(checked(load_script(a.script)), a.start)
    out = a.out or clip_dir(a.script)
    m = read_manifest(out)
    missing = [s["id"] for _, s, _ in rows if s and s["narration"] and not clip_for(m, out, s)]
    if missing:
        log(f"[tour] no prepared clip for {', '.join(missing)}: run `tour.py prepare {a.script}` first")
        return 1
    svc = Service(a.feed)
    try:
        st = svc.audio_status()
    except Exception as x:
        log(f"[tour] the stream service at {a.feed} does not answer ({type(x).__name__}); not starting")
        return 1
    if not st.get("listeners"):
        log("[tour] no overlay page is listening for audio: the narration would not play; starting anyway")
    if "queued" not in st:
        log("[tour] the stream service is older than the tour (no /audio/status queued): restart it first")
        return 1
    try:
        with open(RUN_FILE) as f:
            other = json.load(f)
        os.kill(int(other["pid"]), 0)
        log(f"[tour] a tour is already running (pid {other['pid']}, {other.get('script')}); `tour.py stop` first")
        return 1
    except (OSError, ValueError, KeyError, TypeError):
        pass
    os.makedirs(LOG_DIR, exist_ok=True)
    try:
        os.remove(STOP_FILE)
    except FileNotFoundError:
        pass
    log_path = os.path.join(LOG_DIR, time.strftime("tour-%Y%m%d-%H%M%S.jsonl"))
    with open(RUN_FILE, "w") as f:
        json.dump({"pid": os.getpid(), "script": os.path.abspath(a.script), "started": time.time(), "log": log_path}, f)
    tour = Tour(svc, rows, m, out, log_path, lead=a.lead, tail=a.tail, agent_gaps=a.agent_gaps)
    signal.signal(signal.SIGTERM, lambda *_: setattr(tour, "stopped", True))
    log(f"[tour] {len([r for r in rows if r[1]])} stops in {m.get('voice')}; log {log_path}")
    try:
        tour.run(rows)
    except KeyboardInterrupt:
        log("[tour] interrupted")
    finally:
        for p in (RUN_FILE, STOP_FILE):
            try:
                os.remove(p)
            except FileNotFoundError:
                pass
    return 0


def stop(a):
    """End a running tour: it clears its holds and the hush at its next second. No tour running: clear them here."""
    try:
        with open(RUN_FILE) as f:
            pid = int(json.load(f)["pid"])
        os.kill(pid, 0)
    except (OSError, ValueError, KeyError, TypeError):
        pid = None
    if pid:
        open(STOP_FILE, "w").close()
        for _ in range(40):
            if not os.path.exists(RUN_FILE):
                log("[tour] stopped")
                return 0
            time.sleep(0.25)
        log(f"[tour] pid {pid} did not stop within 10 s; clearing the holds and the hush here")
    Tour(Service(a.feed), [], None, None, os.devnull).finish()
    for p in (RUN_FILE, STOP_FILE):
        try:
            os.remove(p)
        except FileNotFoundError:
            pass
    log("[tour] holds cleared, hosts unhushed")
    return 0


def parser():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("prepare", "dry-run", "run", "stop"):
        p = sub.add_parser(name)
        if name != "stop":
            p.add_argument("script")
            p.add_argument("--out", help="clip directory (default: SCRIPT_DIR/tour-clips)")
        if name in ("dry-run", "run"):
            p.add_argument("--from", dest="start", metavar="ID", help="start at this stop (resume)")
            p.add_argument("--lead", type=float, default=LEAD_S, help="seconds from the cut to the narration")
            p.add_argument("--tail", type=float, default=TAIL_S, help="seconds from the narration's end to the next cut")
        if name == "run":
            p.add_argument("--no-agent-gaps", dest="agent_gaps", action="store_false",
                           help="never hold a stop for an agent's line waiting in the queue")
        if name == "prepare":
            p.add_argument("--voice", default=",".join(VOICES),
                           help="narrator voices in order of preference (voices.CATALOG ids); the first that renders "
                                "every clip is used")
        p.add_argument("--feed", default=FEED, help="the stream service")
    return ap


def main(argv=None):
    a = parser().parse_args(argv)
    return {"prepare": prepare, "dry-run": dry_run, "run": run, "stop": stop}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
