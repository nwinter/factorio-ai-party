#!/usr/bin/env python3
"""Agents' spoken lines cut off (viewer syndesis, shift14 23:04): python3 tools/stream/test_voicecut.py

- An aloud line is voiced whole up to fh say's own 500 characters (it was cut at a sentence near the 200 of chat
  lines: 46 of 126 voiced lines tonight); a chat line the caster picks still stops near 200.
- serve.py's AudioHub logs the page's playback reports and counts the clips that ended early in the last hour, by
  reason: cut, error, reload (the page loaded while one played), no_end (no end report), short_end (the page's own
  measure: played under its length); skips apart. The counter survives a service restart (the log).
- The page reports a load and its own measure (played, duration); the overlay's self-reload waits for a playing clip.
"""
import json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import caster  # noqa: E402
import serve  # noqa: E402

ok = 0


def check(cond, what):
    global ok
    assert cond, what
    ok += 1


# 1. The caps: Astra's 20:24:12 line (205 characters) and a 329-character one, voiced whole; a 600-character aloud line
# stops at a sentence near 500; a chat line (not aloud) still near 200.
astra = ("Sunward is nearly at Gleba. While Luna loads fresh science, I am laying the small foundation for its rocket "
         "defenses. The longer cold route needs those turrets and a more economical power system.")
long_line = astra + " " + ("Gleba packs go first, Fulgora red circuits after, and Nauvis gets both once the freighter "
                           "is back home on its regular loop.")
check(len(long_line) > 300, len(long_line))
voice, label, text = caster.talk_pick({"agent": "astra", "text": long_line, "aloud": True})
check(voice and label == "aloud" and text == long_line, text)
very = " ".join([astra] * 3)
_, _, text = caster.talk_pick({"agent": "astra", "text": very, "aloud": True})
check(len(text) <= 500 and text.endswith(".") and len(text) > 400, (len(text), text[-30:]))
_, _, text = caster.talk_pick({"agent": "astra", "text": long_line + " I will check the ship before the next launch window.", "aloud": False}, "plan")
check(len(text) <= 200, len(text))
# the picker passes the aloud cap on (chat_tick builds it from --aloud-max-chars)
p = caster.TalkPicker(gap=0, cooldown=0, stale=60, limit=200)
p.add(0.0, [{"agent": "astra", "text": long_line, "aloud": True, "t": 0.0, "seq": 1}])
m, label, text = p.next(1.0)
check(text == long_line, text)
p = caster.TalkPicker(gap=0, cooldown=0, stale=60, limit=200, aloud_limit=200)
p.add(0.0, [{"agent": "astra", "text": long_line, "aloud": True, "t": 0.0, "seq": 1}])
check(len(p.next(1.0)[2]) <= 200, "aloud_limit applies")

# 2. AudioHub: the clips that ended early, and why.
tmp = tempfile.mkdtemp(prefix="voicecut")
log = os.path.join(tmp, "audio-played.jsonl")
hub = serve.AudioHub(log)
T = 1_000_000.0


def push(agent, duration=10.0, channel="agent"):
    return hub.push({"channel": channel, "speaker": agent.capitalize(), "agent": agent, "text": "x", "duration": duration}, b"ID3", "audio/mpeg")["id"]


whole = push("astra")
hub.played({"id": whole, "state": "start", "duration": 10.0}, now=T)
hub.played({"id": whole, "state": "end", "played": 9.9, "duration": 10.0}, now=T + 10)
short = push("astra")
hub.played({"id": short, "state": "start", "duration": 10.0}, now=T + 20)
hub.played({"id": short, "state": "end", "played": 6.0, "duration": 10.0}, now=T + 26)
cut = push("rook", channel="caster")
hub.played({"id": cut, "state": "start", "duration": 8.0}, now=T + 30)
hub.played({"id": cut, "state": "cut", "played": 3.0, "duration": 8.0}, now=T + 33)
reload = push("sol")
hub.played({"id": reload, "state": "start", "duration": 12.0}, now=T + 40)
hub.played({"id": None, "state": "load"}, now=T + 44)
skipped = push("luna")
hub.played({"id": skipped, "state": "skip"}, now=T + 50)
lost = push("grok")
hub.played({"id": lost, "state": "start", "duration": 5.0}, now=T + 60)
hub.played({"id": None, "state": "noise"}, now=T + 80)  # any later report clears one past its length + 5 s
e = hub.early(T + 90)
check(e["played_last_hour"] == 5 and e["ended_early_last_hour"] == 4, e)
check(e["by_reason"] == {"short_end": 1, "cut": 1, "reload": 1, "no_end": 1}, e["by_reason"])
check(e["agent_ended_early_last_hour"] == 3 and e["agent_played_last_hour"] == 4, e)
check(e["skipped_last_hour"] == 1 and e["page_loads_last_hour"] == 1, e)
check(e["newest"][0]["speaker"] == "Grok" and e["newest"][0]["reason"] == "no_end" and e["newest"][0]["played"] is None, e["newest"])
r = next(x for x in e["newest"] if x["reason"] == "reload")
check(r["speaker"] == "Sol" and r["played"] == 4.0 and r["duration"] == 12.0, r)
check(e["line"] == "voice: 4 of 5 clips ended early in the last hour (cut 1, no_end 1, reload 1, short_end 1); agents 3 of 4", e["line"])
# the log holds every report's end, and a restart reads the last hour back
rows = [json.loads(line) for line in open(log)]
check(sum(1 for r in rows if r.get("ended")) == 6 and sum(1 for r in rows if r.get("state") == "load") == 1, len(rows))
check(next(r for r in rows if r.get("id") == short)["reason"] == "short_end", "short_end logged")
hub2 = serve.AudioHub(None)
hub2.log_path = log
hub2.WINDOW = 1e12  # (the rows' T is far in the past of the real clock)
hub2._reload_log()
check(hub2.early(T + 90)["ended_early_last_hour"] == 4, "kept across a restart")
# an hour later: none
check(hub.early(T + 90 + 3600)["ended_early_last_hour"] == 0, "the hour moves on")
# status carries the counter
st = hub.status()
check("voice" in st and "line" in st["voice"], st)

# 3. The page: a load report, its own measure, and the overlay's reload waiting for a playing clip.
js = open(os.path.join(HERE, "static", "audio.js")).read()
check('report(null, "load")' in js and "window.pogVoiceBusy" in js and "played:" in js, "audio.js reports")
ov = open(os.path.join(HERE, "static", "overlay.js")).read()
check("window.pogVoiceBusy()" in ov and "90000" in ov, "overlay.js waits for a playing clip")
print(f"voicecut: ok ({ok} checks)")
