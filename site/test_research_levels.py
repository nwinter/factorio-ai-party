#!/usr/bin/env python3
"""The research card lists the repeating research levels (d20 batch57 S4, viewer Foobator 18:25): python3 site/test_research_levels.py

static/live.js under node (test_sitechat.py's stub page): state.research.repeating (tools/stream/model.py
repeating_levels) becomes "Repeating research", a line saying the numbers are the level reached and the tech tree shows
the next, and one row per technology in the state's order: its name, the level, and for the one being researched "
researching N: P%". Without it the card is as before.
(d23 batch119 CB1, viewer Aurora site:4386) The header above it shows the state's label, which names an infinite
technology by the level under way (model.research_label: "Rocket fuel productivity 11", the row's "researching 11"),
and the long run's shift pages say the same at a shift's end from the score's `infinite` (longrun.in_progress).
"""
import json, os, re, shutil, subprocess, tempfile

SITE = os.path.dirname(os.path.abspath(__file__))


def render(research):
    import test_sitechat
    js = test_sitechat.LIVE_CHAT_JS.replace("out.board = (kids['#cb-board'] || {}).innerHTML;",
                                            "out.board = (kids['#cb-board'] || {}).innerHTML; out.research = (kids['#cb-research'] || {}).innerHTML;")
    assert "out.research" in js
    s = json.load(open(os.path.join(SITE, "live", "state.example.json")))
    s["now"] = 1792070000.0
    s["research"] = research
    with tempfile.TemporaryDirectory() as d:
        jp, sp = os.path.join(d, "t.js"), os.path.join(d, "s.json")
        open(jp, "w").write(js)
        json.dump(s, open(sp, "w"))
        r = subprocess.run(["node", jp, os.path.join(SITE, "static", "live.js"), sp], capture_output=True, text=True, timeout=30)
        assert r.returncode == 0, r.stderr
        return json.loads(r.stdout)["research"]


def longrun_levels():
    import longrun
    inf = {"mining-productivity-3": 14, "asteroid-productivity": 10}
    assert longrun.in_progress("mining-productivity-3", inf) == "Mining productivity 17"
    assert longrun.in_progress("asteroid-productivity", inf) == "Asteroid productivity 11"
    assert longrun.in_progress("mining-productivity-3", {}) == "Mining productivity 3"  # its first level
    assert longrun.in_progress("planet-discovery-gleba", inf) == "Planet discovery: Gleba"
    assert longrun.in_progress(None, inf) is None


def main():
    longrun_levels()
    if not shutil.which("node"):
        print("research levels: skipped (no node)")
        return
    base = {"current": "rocket-fuel-productivity", "label": "Rocket fuel productivity 11", "progress": 0.052, "done_count": 230, "recent": []}
    reps = [{"name": "mining-productivity-3", "label": "Mining productivity", "level": 14, "next": 15},
            {"name": "physical-projectile-damage-7", "label": "Physical projectile damage", "level": 10, "next": 11},
            {"name": "rocket-fuel-productivity", "label": "Rocket fuel productivity", "level": 10, "next": 11, "researching": True, "progress": 0.052},
            {"name": "artillery-shell-damage-1", "label": "Artillery shell damage", "level": 1, "next": 2}]
    html = render(dict(base, repeating=reps))
    text = re.sub(r"<[^>]+>", "|", html)
    assert "<h4>Repeating research</h4>" in html and "Level reached (the tech tree shows the next level)." in html, html
    rows = re.findall(r"<li[^>]*>(.*?)</li>", html.split('class="research-levels"', 1)[1])
    plain = [re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", r)).strip() for r in rows]
    assert plain == ["Mining productivity 14", "Physical projectile damage 10", "Rocket fuel productivity 10 researching 11: 5%",
                     "Artillery shell damage 1"], plain
    assert 'class="is-researching"' in html and text
    assert "<strong>Rocket fuel productivity 11</strong>" in html.split('class="research-levels"', 1)[0], html
    before = render(base)
    assert "Repeating research" not in before and "technologies done" in before
    print("research levels: ok (repeating research on the research card: level reached, the one being researched with its progress; the header and the long run by level)")


if __name__ == "__main__":
    main()
