#!/usr/bin/env python3
"""Projects worked on and blocked on the site, with the blocker's reason (d22 batch75 AK11, viewer Foobator site:4284:
"can projects that are actively being worked on and blocked projects be easier to see on site? also, could you show
blocker reason?"): python3 site/test_projectstate.py

- the live page (static/live.js under test_sitechat.py's stub): each project's board status as a chip (doing green,
  blocked red, others grey), a focus chip, and under the title, before it is opened: the open items in its blocked_by,
  a focus's blocker, the newest note when blocked (with its game age) and the progress check's last state;
- a shift page (build.plan_html from a plan file planlog wrote, read by longrun.shift_plan): the status chip, the open
  blockers and the newest note, doing then blocked first.
"""
import json, os, re, shutil, subprocess, sys, tempfile, time

SITE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SITE)
sys.path.insert(0, SITE)
sys.path.insert(0, os.path.join(ROOT, "tools", "stream"))
sys.dont_write_bytecode = True


def check(name, ok, detail=""):
    if not ok:
        raise SystemExit(f"FAIL {name}: {detail}")


def projects():
    return [
        {"id": 2, "title": "Gleba breeder", "owner": "grok", "agent": "grok", "status": "doing", "progress": "2 of 5 steps", "done": 2, "total": 5,
         "state": "active", "check": {"state": "stalled: unchanged across 3 checks", "stalled": True, "checked_s": 30, "last_change_s": 900}},
        {"id": 5, "title": "Freighter", "owner": "sol", "agent": "sol", "status": "claimed", "progress": "3 of 8 steps", "done": 3, "total": 8, "state": "active",
         "focus": [{"agent": "sol", "step": "step 4 load cargo", "blocker": "no rocket fuel on Vulcanus"}]},
        {"id": 3, "title": "EM circuits", "owner": "luna", "agent": "luna", "status": "claimed", "progress": "0 of 3 steps", "done": 0, "total": 3, "state": "blocked",
         "blocked_by": [{"id": 7, "title": "Steel line", "status": "open", "owner": None}], "note": {"by": "luna", "text": "needs the steel line", "tick": 300000 - 36000}},
        {"id": 1, "title": "Uranium outpost", "owner": "muse", "agent": "muse", "status": "blocked", "progress": "1 of 4 steps", "done": 1, "total": 4, "state": "blocked",
         "note": {"by": "muse", "text": "Waiting on 200 steel at the outpost chest", "tick": 300000 - 216000},
         "check": {"state": "check failed", "error": "surface read failed", "checked_s": 12}},
    ]


def main():
    import test_sitechat
    if shutil.which("node"):
        s = json.load(open(os.path.join(SITE, "live", "state.example.json")))
        s["now"] = time.time()
        s["tick"] = 300000
        s["board"] = dict(s.get("board") or {}, available=True, projects=projects(), projects_total=4)
        with tempfile.TemporaryDirectory() as d:
            js, path = os.path.join(d, "chat.js"), os.path.join(d, "state.json")
            open(js, "w").write(test_sitechat.LIVE_CHAT_JS)
            json.dump(s, open(path, "w"))
            r = subprocess.run(["node", js, os.path.join(SITE, "static", "live.js"), path], capture_output=True, text=True, timeout=30)
        check("node", r.returncode == 0, r.stderr[-2000:])
        board = json.loads(r.stdout)["board"]
        heads = {m.group(1): m.group(2) for m in re.finditer(r'data-project="board:(\d+)"[^>]*><summary>(.*?)</summary>', board)}
        text = {k: re.sub(r"<[^>]+>", "|", v) for k, v in heads.items()}
        check("all four", sorted(heads) == ["1", "2", "3", "5"], sorted(heads))
        check("status chips", 'fx-chip fx-chip--green project-status">doing<' in heads["2"] and 'fx-chip fx-chip--red project-status">blocked<' in heads["1"]
              and 'fx-chip fx-chip--grey project-status">claimed<' in heads["3"], heads["2"][:400])
        check("focus chip", "Sol focus" in text["5"] or "sol focus" in text["5"].lower(), text["5"])
        check("open blocker", "Blocked by #7 Steel line (open, no owner)" in text["3"], text["3"])
        check("focus blocker", "focus blocker: no rocket fuel on Vulcanus" in text["5"], text["5"])
        check("newest note when blocked, its game age", "Marked blocked; newest note by" in text["1"] and "60 min ago" in text["1"]
              and "Waiting on 200 steel at the outpost chest" in text["1"], text["1"])
        check("progress check", "Progress check 30 s ago: stalled: unchanged across 3 checks; last board change 15 min ago" in text["2"]
              and "check failed (surface read failed)" in text["1"], (text["2"], text["1"]))
        check("in the summary, not only once opened", all("project-fact" in heads[k] for k in ("1", "2", "3", "5")))
    else:
        print("project state: live page skipped (no node)")

    # a shift page: plan.json (planlog) -> longrun.shift_plan -> build.plan_html
    import planlog, longrun, build
    items = [{"id": 1, "kind": "project", "title": "Uranium outpost", "status": "blocked", "owner": "muse", "progress": "1 of 4 steps", "updated_tick": 900,
              "notes": [{"by": "muse", "text": "Waiting on 200 steel", "tick": 800}]},
             {"id": 2, "kind": "project", "title": "Gleba breeder", "status": "doing", "owner": "grok", "progress": "2 of 5 steps", "updated_tick": 500},
             {"id": 3, "kind": "project", "title": "EM circuits", "status": "claimed", "owner": "luna", "progress": "0 of 3 steps", "updated_tick": 950, "blocked_by": [7]},
             {"id": 4, "kind": "project", "title": "Shipyard", "status": "open", "owner": "sonnet", "progress": "1 of 2 steps", "updated_tick": 990},
             {"id": 7, "kind": "task", "title": "Steel line", "status": "open", "updated_tick": 10}]
    with tempfile.TemporaryDirectory() as d:
        planlog.save(d, planlog.record({"goals": "Ship science"}, items, 0, 1000))
        p = longrun.shift_plan(os.path.join(d, planlog.NAME))
    html = build.plan_html(p)
    lis = re.findall(r"<li><b>([^<]+)</b>(.*?)</li>", html)
    check("shift page: doing, then blocked, first", [t for t, _ in lis][:3] == ["Gleba breeder", "EM circuits", "Uranium outpost"], [t for t, _ in lis])
    body = {t: b for t, b in lis}
    check("shift page: chips", 'fx-chip--green small">doing<' in body["Gleba breeder"] and 'fx-chip--red small">blocked<' in body["Uranium outpost"], body["Gleba breeder"])
    check("shift page: open blocker", "Blocked by #7 Steel line (open)" in body["EM circuits"], body["EM circuits"])
    check("shift page: newest note", "Marked blocked; newest note by muse: Waiting on 200 steel" in body["Uranium outpost"], body["Uranium outpost"])
    print("project state: ok (status chips, focus, and the blocker's reason under each project on the live page; chips, "
          "open blockers and the newest note on the shift page, doing and blocked first)")


if __name__ == "__main__":
    main()
