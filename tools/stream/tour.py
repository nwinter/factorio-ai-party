#!/usr/bin/env python3
"""A narrated camera tour for the stream (Nick, d23 10:28): a script of stops, each a camera shot with a caption and a
narration in one narrator voice, aired through the stream service. Stdlib only (+ ffmpeg for the clips' loudness).

  python3 tools/stream/tour.py prepare SCRIPT [--voice el-brian,oa-fable]   # render every narration clip first
  python3 tools/stream/tour.py dry-run SCRIPT [--from ID]                   # the timeline: no camera, no audio
  python3 tools/stream/tour.py run SCRIPT [--from ID]                       # on air
  python3 tools/stream/tour.py stop                                         # end a running tour (another terminal)

SCRIPT: JSON, a list of stops (or {"stops": [...]}), each {id, target, seconds, caption, narration, facts}; target is
{surface, x, y, zoom} (a planet spot: POST /look, chart-checked by the service) or {platform: NAME} (a ship: POST
/platform). facts are for the operator and never aired.

prepare renders each narration with voices.TTS (the caster's TTS path; keys in ~/.config/pog/, never printed) into
SCRIPT_DIR/tour-clips/ with manifest.json ({voice, provider, clips: {id: {file, hash, duration}}}). A clip whose
narration and voice are unchanged is kept, so editing one stop re-renders one clip. All clips are in ONE voice: the
first of --voice whose provider renders every clip (a provider that fails mid-way hands the whole tour to the next).
The default narrator is a voice no host and no agent speaks in (checked against the stream state when it is up).

run: a stop lasts max(its seconds, its clip + 2 s), timed from the narration's start on the page (or from the shot
when no page reports). For each stop the camera goes to the target (a /look is renewed before its 60 s limit; a
/platform is asked for the stop's length), the caption is the shot's label and the narration's caption line, and the
clip goes to POST /audio as channel "narrator", rank "urgent" (the page plays one clip at a time and an urgent clip
goes next, so an agent's aloud line waits for the narrator and never talks over it). The hosts stay quiet for the
whole tour: run writes caster.py's hush file (logs/hosts-hush.json; caster.py --hush-file) and removes it at the end.
The director's own cuts wait while a look or platform hold is on (lookcam.py). A stop whose target is invalid or
refused (unknown platform, uncharted ground) is skipped with a log line. stop (or Ctrl-C) ends the tour: the holds the
tour set are cleared and the hush lifted. Every stop is logged to tools/stream/logs/tour-<start>.jsonl with what aired
when (epoch and local time), for the archive and clips.
"""
import argparse, base64, hashlib, json, os, signal, sys, time, urllib.error, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True

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
TAIL_S = 2.0  # a stop lasts at least its clip and this
WORDS_PER_S = 2.5  # the timeline's estimate for a stop without a prepared clip (150 words a minute)
LOOK_MAX_S = 60.0  # lookcam.MAX_S
LOOK_RENEW_S = 20.0  # renew a look this long before it ends
SETTLE_S = 8.0  # wait at most this long for the shot to be on air before the narration
START_WAIT_S = 30.0  # wait at most this long for the page to start the narration clip


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
        secs = number(stop.get("seconds") if stop.get("seconds") is not None else 0)
    except ValueError as x:
        return None, f"target or seconds: {x}"
    return {"id": sid, "target": target, "seconds": max(0.0, secs),
            "caption": " ".join(str(stop.get("caption") or "").split())[:80],
            "narration": " ".join(str(stop.get("narration") or "").split())}, None


def checked(stops):
    """[(index, stop or None, why)] in script order; a repeated id is invalid."""
    out, seen = [], set()
    for i, raw in enumerate(stops):
        s, why = check_stop(raw)
        if s and s["id"] in seen:
            s, why = None, f"id {s['id']!r} repeated"
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


def stop_length(stop, clip_s):
    """max(seconds, clip + TAIL_S); clip_s None: no clip (a silent stop is just its seconds)."""
    return max(stop["seconds"], (clip_s + TAIL_S) if clip_s else 0.0)


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
def timeline(rows, manifest, out):
    """[(stop, seconds, clip seconds or None, estimated)] for the valid stops, and the invalid ones [(index, why)]."""
    plan, bad = [], []
    for i, s, why in rows:
        if not s:
            bad.append((i, why))
            continue
        c = clip_for(manifest, out, s)
        est = c is None and bool(s["narration"])
        clip_s = c["duration"] if c else (len(s["narration"].split()) / WORDS_PER_S if s["narration"] else None)
        plan.append((s, stop_length(s, clip_s), clip_s, est))
    return plan, bad


def clock(sec):
    return f"{int(sec // 60):2d}:{int(sec % 60):02d}"


def print_timeline(rows, manifest, out, platforms=None):
    plan, bad = timeline(rows, manifest, out)
    t = 0.0
    print(f"{'start':>6}  {'len':>5}  {'clip':>6}  id / target / caption")
    for s, length, clip_s, est in plan:
        note = ""
        if "platform" in s["target"] and platforms is not None and \
                s["target"]["platform"].casefold() not in {p.casefold() for p in platforms}:
            note = "   [no such platform now: run would skip it]"
        clip = "-" if clip_s is None else f"{clip_s:5.1f}" + ("~" if est else "s")
        print(f"{clock(t)}  {length:5.0f}  {clip:>6}  {s['id']} / {target_text(s['target'])} / {s['caption']}{note}")
        t += length
    for i, why in bad:
        print(f"  skip  stop {i + 1}: {why}")
    ests = sum(1 for p in plan if p[3])
    print(f"total {clock(t).strip()} ({len(plan)} stops" + (f", {len(bad)} invalid" if bad else "")
          + (f"; {ests} clip lengths estimated at {WORDS_PER_S:g} words/s: run prepare" if ests else "") + ")")
    return t


def dry_run(a):
    rows = from_index(checked(load_script(a.script)), a.start)
    out = a.out or clip_dir(a.script)
    m = read_manifest(out)
    if m:
        print(f"clips: {m.get('voice')} ({m.get('provider')}), made {m.get('made')}")
    plats = platforms(a.feed)
    print_timeline(rows, m, out, plats)
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
                 clock=time.time, sleep=time.sleep):
        self.svc, self.rows, self.manifest, self.out = svc, rows, manifest, out
        self.log_path, self.hush_file, self.stop_file = log_path, hush_file, stop_file
        self.now, self.sleep = clock, sleep
        self.held = None  # "look" or "platform": the hold this tour set last
        self.stopped = False

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

    def look(self, s, seconds):
        t = s["target"]
        body = {"surface": t["surface"], "x": t["x"], "y": t["y"], "seconds": max(1.0, min(LOOK_MAX_S, seconds)),
                "label": s["caption"] or None, "by": "tour"}
        if "zoom" in t:
            body["zoom"] = t["zoom"]
        return self.svc.call("POST", "/look", body)

    def shoot(self, s, length):
        """Point the camera on air at the stop's target. -> (ok, reply)."""
        if "platform" in s["target"]:
            code, r = self.svc.call("POST", "/platform", {"name": s["target"]["platform"], "seconds": length + 30,
                                                          "label": s["caption"] or None, "by": "tour"})
            kind = "platform"
        else:
            code, r = self.look(s, length + 10)
            kind = "look"
        if code != 200:
            return False, dict(r if isinstance(r, dict) else {}, code=code)
        if self.held and self.held != kind:  # the previous stop's hold of the other kind goes (a look outranks a
            self.release(self.held)          # platform hold, which would come back when the look ends)
        self.held = kind
        return True, r

    def release(self, kind):
        """Clear a hold of `kind` when it is still the tour's (an operator's own later hold stays)."""
        try:
            st = self.svc.state()
        except Exception:
            st = {}
        cur = st.get("look" if kind == "look" else "platform_hold") or {}
        if cur and cur.get("by") != "tour":
            return
        self.svc.call("DELETE", "/" + kind)

    def on_air(self, s):
        """Wait (at most SETTLE_S) for the shot to be the program; -> seconds waited, or None when not seen."""
        t0 = self.now()
        while self.now() - t0 < SETTLE_S:
            try:
                o = (self.svc.state().get("onair") or {})
            except Exception:
                o = {}
            if "platform" in s["target"]:
                if ((o.get("platform") or {}).get("name") or "").casefold() == s["target"]["platform"].casefold():
                    return self.now() - t0
            elif o.get("look"):
                return self.now() - t0
            self.sleep(0.5)
        return None

    def narrate(self, s, clip):
        with open(clip["path"], "rb") as f:
            audio = f.read()
        meta = {"channel": "narrator", "speaker": "Narrator", "text": s["caption"] or "", "rank": "urgent",
                "duration": clip["duration"], "expires_in": 300, "tour": s["id"], "voice": self.manifest.get("voice"),
                "audio_b64": base64.b64encode(audio).decode(), "ctype": "audio/mpeg"}
        code, r = self.svc.call("POST", "/audio", meta)
        return r.get("id") if code == 200 else None

    def started(self, cid):
        """Wait (at most START_WAIT_S) for the page to start the clip; -> the time it started, or None."""
        t0 = self.now()
        while self.now() - t0 < START_WAIT_S and not self.want_stop():
            try:
                if any(p.get("id") == cid for p in self.svc.audio_status().get("playing") or []):
                    return self.now()
            except Exception:
                pass
            self.sleep(0.25)
        return None

    def air(self, s, remaining_s):
        """One stop on air. -> True when it aired, False when skipped."""
        clip = clip_for(self.manifest, self.out, s)
        length = stop_length(s, clip["duration"] if clip else None)
        self.hush(remaining_s + 120)
        t0 = self.now()
        ok, r = self.shoot(s, length)
        if not ok:
            why = r.get("error") or f"HTTP {r.get('code')}"
            log(f"[tour] skip {s['id']}: {target_text(s['target'])} refused ({why})")
            self.record(event="skipped", id=s["id"], target=s["target"], reason=why)
            return False
        settle = self.on_air(s)
        t_air = self.now()
        log(f"[tour] {s['id']}: {target_text(s['target'])} on air" + ("" if settle is not None else " (not seen on the "
            "program yet)") + f"; {length:.0f} s: {s['caption']}")
        cid = self.narrate(s, clip) if clip else None
        if clip and not cid:
            log(f"[tour] {s['id']}: the service refused the narration clip")
        t_narr = self.started(cid) if cid else None
        if cid and t_narr is None and not self.stopped:
            log(f"[tour] {s['id']}: no page started the narration within {START_WAIT_S:g} s (is the overlay page "
                "listening?); timing from the post")
        base = t_narr if t_narr is not None else t_air
        end = max(t_air + s["seconds"], base + (clip["duration"] + TAIL_S if clip else 0))
        look_until = t0 + min(LOOK_MAX_S, length + 10)
        while self.now() < end and not self.want_stop():
            # renew only a look that would end before the stop (each POST /look is one chart read on the game)
            if self.held == "look" and look_until < end and look_until - self.now() < LOOK_RENEW_S:
                secs = min(LOOK_MAX_S, end - self.now() + 10)
                code, _ = self.look(s, secs)
                if code == 200:
                    look_until = self.now() + secs
                else:
                    log(f"[tour] {s['id']}: renewing the look failed (HTTP {code})")
            self.sleep(min(1.0, max(0.05, end - self.now())))
        self.record(event="aired", id=s["id"], target=s["target"], caption=s["caption"], started=round(t0, 2),
                    on_air=round(t_air, 2), narration_start=round(t_narr, 2) if t_narr else None,
                    clip_s=clip["duration"] if clip else None, ended=round(self.now(), 2),
                    seconds=round(self.now() - t0, 1), cut_short=self.stopped)
        return True

    def run(self, rows):
        plan, _ = timeline(rows, self.manifest, self.out)
        left = sum(p[1] for p in plan)
        self.record(event="start", stops=[s["id"] for s, *_ in plan], planned_s=round(left),
                    voice=(self.manifest or {}).get("voice"))
        aired = skipped = 0
        try:
            for i, s, why in rows:
                if self.want_stop():
                    break
                if not s:
                    log(f"[tour] skip stop {i + 1}: invalid ({why})")
                    self.record(event="skipped", index=i, reason=why)
                    skipped += 1
                    continue
                length = next(p[1] for p in plan if p[0]["id"] == s["id"])
                if self.air(s, left):
                    aired += 1
                else:
                    skipped += 1
                left -= length
        finally:
            self.finish()
            self.record(event="end", aired=aired, skipped=skipped, stopped=self.stopped)
            log(f"[tour] {'stopped' if self.stopped else 'done'}: {aired} stops aired, {skipped} skipped; log "
                f"{self.log_path}")
        return aired, skipped

    def finish(self):
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
    tour = Tour(svc, rows, m, out, log_path)
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
