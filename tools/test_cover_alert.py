#!/usr/bin/env python3
"""An agent that stays stopped on a provider error: bounded retries, a resume verified in its journal, its cover told
(d26 batch252 CA, viewer Aurora site:4965: "Sol stopped for about 30 minutes on a capacity error. Could recovery cover
this too, with bounded retries, verified model resumption and an alert to active cover if it stays blocked?").

Sol's d25-d26 night (Codex sessions, journals): five stops on "Selected model is at capacity. Please try a different
model.": 23:28-23:54 and 00:46-01:02 resumed by the operator by hand, 01:16-01:53 by the deadline prompt only (no
provider-stop rule ran then: tools/pane_resume.py's came at the next shift, 02:03), 02:40-02:51 and 07:08-07:18 by
pane_resume. All the while a background loop of Sol's made a platform_defense request every 20 s.

Fake panes (test_pane_resume_stop.py's), fixed epoch times in 2023 and TZ=UTC (no clock), temp run folders:
1. A turn shown with no request of its own is not a resume; the loop's platform_defense requests are not either. The
   cover hears it at 20 min, with the facts; no retry while the turn shows.
2. Two stops again, then the third message works: resumed on its tells request; the cover heard it at 20 min and hears
   it is back, once.
3. The cover: an active coverer of one of its claims first, then --lead, then the member with the latest request of
   its own; never the agent; an inactive coverer is skipped.
4. A purchase or credit screen: nothing pressed or typed (provider stop and rest paths), logged once.
5. Dry run: the alert is logged, no tell sent, persistent live state unchanged.
6. No cover and failed tells back off 5, 10, 20, then every 30 min, pending across restart; delivered alerts stay done.
7. Ordinary and firm rests are skipped; a failed log callback cannot lose a delivered alert.
"""
import json
import os
import sys
import tempfile
import time

os.environ["TZ"] = "UTC"
time.tzset()
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
os.environ["POG_TEST"] = "1"
os.environ["POG_REST_PUSH"] = "off"
import pane_resume as pr  # noqa: E402
import test_pane_resume_stop as fx  # noqa: E402  (its fake panes and run folder)
import idle_nudge  # noqa: E402

T0, IDLE, check = fx.T0, fx.IDLE, fx.check   # T0 is 22:13:20 UTC


def run_with(tmp, pane, told):
    run = fx.Run(tmp, [("sol", pane)])
    r = run.resumer(cover=lambda name, now: "astra", send=lambda to, text: told.append((to, text)))
    return run, r


def turn_shown():
    with tempfile.TemporaryDirectory() as tmp:
        sol, told = fx.Pane("codex", fx.SOL_STOP, react="show"), []
        run, r = run_with(tmp, sol, told)
        run.poll(r, T0, T0 + IDLE + 60)
        check([x["action"] for x in run.rows] == ["typed", "turn_running"] and "not counted as resumed" in run.rows[1]["line"],
              "a turn shown with no request of its own: not a resume")
        run.poll(r, T0 + IDLE + 120, T0 + 1140)
        check(len(sol.typed) == 1 and told == [], "no retry while the turn shows; the loop's platform_defense is no resume")
        run.poll(r, T0 + 1200, T0 + 1260)
        check(told == [("astra", "Operator (automatic, facts only): sol's pane has shown a provider error since 22:13 "
                        "(Selected model is at capacity. Please try a different model.); 1 resume tried (22:23); no request "
                        "of its own since 22:13 (its journal since holds only platform_defense requests); its pane shows a "
                        "turn running now.")], "the cover told at 20 min, facts only")
        run.poll(r, T0 + 1320, T0 + 3 * 3600)
        check(len(told) == 1, "told once an episode")


def resumed_on_third():
    with tempfile.TemporaryDirectory() as tmp:
        sol, told = fx.Pane("codex", fx.SOL_STOP, react="stop"), []
        run, r = run_with(tmp, sol, told)
        run.poll(r, T0, T0 + IDLE + 840)
        check(len(sol.typed) == 2 and len(told) == 1 and "2 resumes tried (22:23, 22:28)" in told[0][1],
              "two tries failed; the alert at 20 min names both")
        sol.react = "work"
        rows = run.poll(r, T0 + IDLE + 900, T0 + IDLE + 960)
        check([x["action"] for x in rows] == ["typed", "resumed"] and rows[1]["verified"] == "tells", "the third try: resumed on its tells request")
        check(told[1] == ("astra", "Operator (automatic, facts only): sol is back: a request of its own (tells) at 22:38, "
                                   "after a provider error on its pane from 22:13 (25 min; 3 resumes tried)."),
              "the cover hears it is back")
        run.poll(r, T0 + IDLE + 1020, T0 + 4 * 3600)
        check(len(told) == 2 and len(sol.typed) == 3, "once; nothing more typed")


def cover_choice():
    with tempfile.TemporaryDirectory() as tmp:
        now = T0 + 7200
        for name, ago in [("astra", 60), ("luna", 3000), ("haiku", 30), ("sol", 10)]:
            os.makedirs(os.path.join(tmp, name))
            with open(os.path.join(tmp, name, "journal.jsonl"), "w") as j:
                j.write(json.dumps({"event": "request", "at": fx.iso(now - ago), "request": {"action": "tells"}}) + "\n")
        n = idle_nudge.Nudger(["astra", "luna", "haiku", "sol"], run_dir=tmp, start=T0)
        claims = [{"id": 5, "kind": "claim", "owner": "sol", "status": "doing", "covers": [{"name": "luna"}, {"name": "astra"}]},
                  {"id": 6, "kind": "claim", "owner": "haiku", "status": "doing", "covers": [{"name": "sol"}]}]
        check(n.cover_for("sol", now, claims) == "astra", "cover: an active coverer of its claim (luna, idle 50 min, skipped)")
        check(n.cover_for("sol", now, []) == "haiku", "cover: no claim cover: the member with the latest request of its own")
        n.leads = ["luna", "astra"]
        check(n.cover_for("sol", now, []) == "astra", "cover: the first active --lead")
        n.leads = ["sol"]
        check(n.cover_for("sol", now, [{"owner": "sol", "status": "doing", "covers": [{"name": "sol"}]}]) == "haiku",
              "cover: never the agent itself (its own name as coverer or --lead skipped)")
        n.leads = []
        check(n.cover_for("haiku", now, claims) == "sol", "cover: haiku's coverer sol, active")


def purchase():
    with tempfile.TemporaryDirectory() as tmp:
        screen = fx.SOL_STOP + "\n\n  You're out of credits.\n  › 1. Buy more credits\n    2. Cancel"
        pane, told = fx.Pane("codex", screen), []
        run, r = run_with(tmp, pane, told)
        run.poll(r, T0, T0 + 3600)
        check(pane.typed == [] and pane.keys == [] and [x["action"] for x in run.rows][:1] == ["purchase_screen"]
              and sum(x["action"] == "purchase_screen" for x in run.rows) == 1,
              "a purchase screen under a stop: nothing pressed or typed, logged once")
    with tempfile.TemporaryDirectory() as tmp:
        pane = fx.Pane("claude", "  Add credits to keep going\n  › Purchase more usage\n")
        run = fx.Run(tmp, [("sol", pane)], rest_until=T0 + 60)
        run.poll(run.resumer(), T0 + 120, T0 + 3600)
        check(pane.typed == [] and pane.keys == [] and [x["action"] for x in run.rows] == ["purchase_screen"],
              "a purchase screen when a rest ends: nothing pressed or typed, logged once")


def dry_run():
    with tempfile.TemporaryDirectory() as tmp:
        sol, told = fx.Pane("codex", fx.SOL_STOP, react="stop"), []
        run = fx.Run(tmp, [("sol", sol)])
        r = run.resumer(dry=True, cover=lambda name, now: "astra", send=lambda to, text: told.append((to, text)))
        run.poll(r, T0, T0 + 1300)
        alert = [x for x in run.rows if x["action"] == "cover_alert"]
        check(told == [] and sol.typed == [] and len(alert) == 1 and alert[0]["dry_run"] and "dry run: would tell astra" in alert[0]["line"],
              "dry run: the alert logged, no tell sent, nothing typed")


def pending_alerts():
    """No cover and failed tells stay pending across polls and process restarts."""
    with tempfile.TemporaryDirectory() as tmp:
        sol, told, attempts = fx.Pane("codex", fx.SOL_STOP, react="show"), [], []
        run = fx.Run(tmp, [("sol", sol)])
        available, failure = False, "exception"

        def cover(name, now):
            attempts.append(now)
            return "astra" if available else None

        def send(to, text):
            if failure == "exception":
                raise OSError("test tell failure")
            if failure == "false":
                return False
            told.append((to, text))

        r = run.resumer(cover=cover, send=send)
        run.poll(r, T0, T0 + 1200)
        check("alert" not in r.stops["sol"]["logged"], "no cover leaves the alert pending")
        available = True
        r = run.resumer(cover=cover, send=send)
        check(r.stops["sol"]["seen"] == T0 and r.stops["sol"]["tries"] == 1,
              "restart restores the pending episode, original age and resume tries")
        run.poll(r, T0 + 1260, T0 + 1500)
        check(attempts == [T0 + 1200, T0 + 1500] and not told,
              "pending no-cover alert retries after five minutes; tell exception stays pending")
        failure = "false"
        r = run.resumer(cover=cover, send=send)
        run.poll(r, T0 + 1560, T0 + 2100)
        check(attempts[-1] == T0 + 2100 and len(attempts) == 3 and not told,
              "failed tell retries after ten minutes across restart; explicit False is failure")
        run.poll(r, T0 + 2160, T0 + 6900)
        check(attempts == [T0 + n for n in (1200, 1500, 2100, 3300, 5100, 6900)],
              "failed tells back off twenty minutes, then thirty minutes repeatedly")
        failure = None
        run.poll(r, T0 + 6960, T0 + 8700)
        check(len(told) == 1 and "alert" in r.stops["sol"]["logged"] and r.stops["sol"]["cover"] == "astra",
              "successful tell completes the pending alert")
        r = run.resumer(cover=cover, send=send)
        run.poll(r, T0 + 8760, T0 + 12000)
        check(len(told) == 1 and len(attempts) == 7 and len(sol.typed) == 1,
              "restart preserves delivery and resume state; neither tell nor prompt repeats")
        sent = [x for x in run.rows if x["action"] == "cover_alert" and x["sent"]]
        check(len(sent) == 1 and "told astra" in sent[0]["line"] and "accepted" not in sent[0]["text"],
              "the delivered alert records told, without claiming cover acceptance")


def resting_covers():
    with tempfile.TemporaryDirectory() as tmp:
        now = T0 + 1200
        for name in ("astra", "haiku", "sol"):
            os.makedirs(os.path.join(tmp, name))
            with open(os.path.join(tmp, name, "journal.jsonl"), "w") as f:
                f.write(json.dumps({"event": "request", "at": fx.iso(now - 30), "request": {"action": "tells"}}) + "\n")
        n = idle_nudge.Nudger(["astra", "haiku", "sol"], leads=["astra", "haiku"], run_dir=tmp, start=T0)
        claims = [{"owner": "sol", "status": "doing", "covers": [{"name": "astra"}, {"name": "haiku"}]}]
        rest = os.path.join(tmp, "astra", "resting.json")
        for firm, since in ((False, now - 10), (True, now - 60)):
            with open(rest, "w") as f:
                json.dump({"since": since, "until": now + 600, "firm": firm}, f)
            check(n.cover_for("sol", now, claims) == "haiku" and n.cover_for("sol", now, []) == "haiku",
                  f"resting claim coverer and lead skipped for next eligible recipient (firm={firm})")
        with open(os.path.join(tmp, "haiku", "resting.json"), "w") as f:
            json.dump({"since": now - 10, "until": now + 600, "firm": True}, f)
        check(n.cover_for("sol", now, claims) is None, "all eligible recipients resting: no cover")
        check(n.cover_for("sol", now + 600, claims) is None, "expired rests still require recent own activity")


def persisted_delivery():
    with tempfile.TemporaryDirectory() as tmp:
        sol, told = fx.Pane("codex", fx.SOL_STOP, react="show"), []
        run, r = run_with(tmp, sol, told)
        run.poll(r, T0, T0 + 1140)
        state = os.path.join(tmp, "pane-resume-state.json")
        with open(state, "rb") as f:
            before = f.read()
        dry = run.resumer(dry=True, cover=lambda name, now: "astra", send=lambda *args: told.append(args))
        rows = run.poll(dry, T0 + 1200, T0 + 1800)
        with open(state, "rb") as f:
            check(f.read() == before and not told and sum(x["action"] == "cover_alert" for x in rows) == 1,
                  "dry-run delivery is once in memory and leaves live pending state unchanged")

        def broken_log(row):
            raise OSError("test log failure")

        try:
            r.step(T0 + 1200, broken_log)
        except OSError:
            pass
        else:
            raise AssertionError("expected log failure")
        r = run.resumer(cover=lambda name, now: "astra", send=lambda *args: told.append(args))
        run.poll(r, T0 + 1260, T0 + 1800)
        check(len(told) == 1, "delivered state survives restart even when the log callback failed")
        run.fake.now = T0 + 1800
        run.fake.journal(sol, "tells")
        run.poll(r, T0 + 1860, T0 + 1860)
        r = run.resumer(cover=lambda name, now: "astra", send=lambda *args: told.append(args))
        check(not r.stops and len(told) == 2, "resumed episode removal persists; cover was told it is back once")


if __name__ == "__main__":
    turn_shown()
    resumed_on_third()
    cover_choice()
    purchase()
    dry_run()
    pending_alerts()
    resting_covers()
    persisted_delivery()
    print("test_cover_alert: all ok")
