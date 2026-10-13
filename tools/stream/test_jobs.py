#!/usr/bin/env python3
"""Each card shows the agent's current job (shift05 07:57, viewer Joonazan: "Would also appreciate displaying the
current plan of each bot instead of the motto"): python3 tools/stream/test_jobs.py

1. model.notes_job: the first job-like sentence of notes.md "## Now", past the clock, deadline, position and warnings
   (shift05's own notes), trimmed for the card; None without a "## Now".
2. Snapshot agents carry job and job_from: the team plan's line for the agent first, else its notes job, else none (the
   page then shows the motto).
3. live.py reads notes.md again only when it changed.
4. push_live sends job to the site.
"""
import os, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "site"))
from model import Model, notes_job  # noqa: E402

ASTRA = """# Astra
## Now
Game16h40, deadline2026-10-13 10:56PDT (~2h57 remaining). Nauvis position69.86,64.58,8deaths, heavyarmor/flamer10ammo,SMG+yellow36,pistol30piercing. Main job Peregrine ferry aboveVulcanus plus east/south defense. Sol supplies platform rockets locally.
Defense: neweastflamers76.5,10 /76.5,50 fullcrude.

## Claims
- none
"""
HAIKU = """## Now
Deadline 10:56 PDT (2h58m left at game 16h39m). Goal: keep burners, furnaces and boilers fuelled; carry coal and ammo where teammates ask (astra offered help, no reply yet).
"""
GEMINI = """## Now
Shift 5 active (game 16h45m, deadline in 2h52m).
Current goal: Drive Physical Projectile Damage 4 (45%) to 100%, queue Weapon Shooting Speed 3 for Peregrine's 14 turrets, maintain military courier loop, and support inner defense forts.
"""
GROK = """## Now
Shift 5, deadline 2026-10-13 10:56 PDT. Deaths 3. Do NOT take walls from (65.5,-10.5): Astra reserved them for south forts. Returned 13; 9 were already in science.
"""


def notes():
    assert notes_job(ASTRA) == "Peregrine ferry aboveVulcanus plus east/south defense", notes_job(ASTRA)
    assert notes_job(HAIKU) == "Keep burners, furnaces and boilers fuelled", notes_job(HAIKU)
    g = notes_job(GEMINI)
    assert g.startswith("Drive Physical Projectile Damage 4") and g.endswith("…") and len(g) <= 90, g
    assert notes_job(GROK) == "Returned 13", notes_job(GROK)
    assert notes_job("# notes\nno sections") is None and notes_job("## Now\n\n## Log\n") is None


def snapshot():
    m = Model({"agents": {"astra": {"model": "gpt"}, "haiku": {"model": "claude-haiku"}, "sol": {"model": "x"}}})
    now = time.time()
    m.ingest({"agents": [{"name": "astra", "notes_job": "Peregrine ferry"}, {"name": "haiku", "notes_job": "Keep burners fuelled"},
                         {"name": "sol"}], "tick": 60}, now)
    m.board["plan"] = {"goals": "Survive the night", "doing": ["astra: south forts and the ferry (set by astra)"]}
    rows = {a["name"]: a for a in m.snapshot(now)["agents"]}
    assert (rows["astra"]["job"], rows["astra"]["job_from"]) == ("south forts and the ferry", "plan"), rows["astra"]
    assert (rows["haiku"]["job"], rows["haiku"]["job_from"]) == ("Keep burners fuelled", "notes"), rows["haiku"]
    assert rows["sol"]["job"] is None and rows["sol"]["job_from"] is None, rows["sol"]


def live_reads():
    from live import LiveSource as Live
    root = tempfile.mkdtemp()
    os.makedirs(os.path.join(root, "haiku"))
    path = os.path.join(root, "haiku", "notes.md")
    open(path, "w").write(HAIKU)
    fake = type("L", (), {"journals": root, "notes_cache": {}})()
    assert Live.notes_job(fake, "haiku") == "Keep burners, furnaces and boilers fuelled"
    assert Live.notes_job(fake, "nobody") is None
    open(path, "w").write("## Now\nGoal: carry coal north.\n")
    os.utime(path, (time.time() + 5, time.time() + 5))
    assert Live.notes_job(fake, "haiku") == "Carry coal north", fake.notes_cache


def site():
    import push_live
    assert "job" in push_live.AGENT_KEYS


def main():
    notes()
    snapshot()
    live_reads()
    site()
    print("jobs: ok (notes.md \"## Now\" job lines from shift05's notes; plan line first, then notes; read on change; "
          "sent to the site)")


if __name__ == "__main__":
    main()
