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
from build import clean, CONFIG  # noqa: E402  (same redaction rules as the static site)

AGENT_KEYS = ("name", "kind", "display_name", "color", "glyph", "motto", "profile_set", "model", "harness", "role",
              "alive", "activity", "action", "active", "position", "location", "last_said", "camera", "avatar",
              "combat", "died_at", "job", "attention",
              "surface", "where", "on_platform", "travel")  # where the body is: the map lists agents off Nauvis at its edge
TOP_KEYS = ("now", "tick", "paused", "game_time", "title", "subtitle", "research", "production", "science", "alerts",
            "board", "basemap", "shift")
ATTENTION_KEYS = ("kind", "text", "surface", "platform", "age_s", "dist", "far")
CHAT_KEYS = ("seq", "tick", "from", "agent", "text", "t")


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


def public_space(sp):
    """Space Age for the map's inset: planets reached, rockets, and each platform's place or route (no camera views,
    no moments: a few hundred bytes)."""
    if not sp or not sp.get("active"):
        return None
    return {"rockets": sp.get("rockets") or 0, "planets": sp.get("planets") or [], "summary": sp.get("summary"),
            "platforms": [{k: p[k] for k in PLATFORM_KEYS if p.get(k) is not None} for p in (sp.get("platforms") or [])[:6]]}


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


def public_state(s):
    out = {k: s[k] for k in TOP_KEYS if k in s}
    out["agents"] = [{k: a[k] for k in AGENT_KEYS if k in a} for a in s.get("agents", [])]
    for a in out["agents"]:  # the map's line from the character to where it last looked or worked
        t = a.get("attention")
        if t:
            p = t.get("position") or {}
            a["attention"] = dict({k: t[k] for k in ATTENTION_KEYS if t.get(k) is not None},
                                  **({"position": {"x": round(p["x"], 1), "y": round(p["y"], 1)}} if "x" in p else {}))
    out["chat"] = [{k: c[k] for k in CHAT_KEYS if k in c} for c in s.get("chat", [])[-40:]]
    out["cameras"] = {slot: dict({"agents": c.get("agents", []), "pair": c.get("pair", False), "since": c.get("since")},
                                 **{k: c[k] for k in CAMERA_LABELS if c.get(k)})
                      for slot, c in (s.get("cameras") or {}).items()}
    space = public_space(s.get("space"))
    if space:
        out["space"] = space
    if s.get("fights"):
        out["fights"] = public_fights(s["fights"], s.get("now") or time.time())
    # The broadcast the stream service's YouTube chat bridge follows, so the live page embeds the current one.
    yt = ((s.get("viewers_status") or {}).get("youtube") or {})
    if re.fullmatch(r"[\w-]{11}", str(yt.get("video") or "")):
        out["stream"] = {"youtube_video_id": yt["video"]}
    out["schema"] = 1
    return scrub(out)


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
                state = public_state(json.load(r))
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
                  f"tick {window['tick']}, {window['agents']} agents", flush=True)
            window = dict(window, ok=0, failed=0, bytes=0)
        time.sleep(max(1.0, a.interval - (time.time() - t0)))


if __name__ == "__main__":
    sys.exit(main())
