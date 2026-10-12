#!/usr/bin/env python3
"""The homepage is the live show, and the live payload stays small: python3 site/test_live.py

- push_live.public_state keeps a compact Space Age block (platforms' place or route, no camera views or moments),
  the fights reported in the last two minutes on Nauvis, and each camera's fight / work / segment label;
- the built homepage carries the live app and links to the rest of the site; /about/ has the old homepage, /live/
  still works; check.py passes.
"""
import json, os, subprocess, sys, tempfile, time

SITE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SITE)
import push_live  # noqa: E402


def payload_tests():
    now = time.time()
    s = json.load(open(os.path.join(SITE, "live", "state.example.json")))
    s["now"] = now
    s["space"] = {"active": True, "rockets": 3, "planets": ["Nauvis"], "summary": "1 platform", "moments": [{"id": "m"}] * 8,
                  "platforms": [{"name": "Solstice", "where": "Nauvis → Vulcanus", "route": {"from": "Nauvis", "to": "Vulcanus", "pct": 42},
                                 "state": "on_the_path", "speed_kms": 72, "paused": False,
                                 "view": {"surface": "platform-1", "hub": {"x": 0, "y": 0}, "bounds": {}}}]}
    s["fights"] = [{"key": "area:-48,16", "kind": "attack", "text": "Base under attack near (-48, 16)", "first": now - 30,
                    "last": now - 5, "losses": [now - 10], "position": {"x": -48, "y": 16, "extent": 32.0, "surface": "nauvis"}},
                   {"key": "area:9,9", "kind": "attack", "text": "old", "first": now - 900, "last": now - 600, "losses": [],
                    "position": {"x": 9, "y": 9, "surface": "nauvis"}},
                   {"key": "attack:sol", "kind": "attack", "text": "on a platform", "first": now, "last": now, "losses": [],
                    "position": {"x": 1, "y": 1, "surface": "platform-1"}}]
    s["cameras"] = {"main": {"agents": [], "pair": False, "since": now, "attack": "Base under attack", "zoom": 1.2, "player": 3},
                    "cam3": {"agents": ["sol"], "pair": False, "since": now, "work": "Sol building on Solstice (from the ground)"}}
    out = push_live.public_state(s)
    assert out["space"] == {"rockets": 3, "planets": ["Nauvis"], "summary": "1 platform", "platforms": [
        {"name": "Solstice", "where": "Nauvis → Vulcanus", "route": {"from": "Nauvis", "to": "Vulcanus", "pct": 42},
         "state": "on_the_path", "paused": False, "speed_kms": 72}]}, out["space"]
    assert [(f["text"], f["age_s"], f["losses"], f["extent"]) for f in out["fights"]] == [
        ("Base under attack near (-48, 16)", 5, 1, 32.0)], out["fights"]  # recent, on Nauvis only
    assert out["cameras"]["main"] == {"agents": [], "pair": False, "since": now, "attack": "Base under attack"}
    assert out["cameras"]["cam3"]["work"].startswith("Sol building")
    size = len(json.dumps(out["space"]) + json.dumps(out["fights"]) + json.dumps(out["cameras"]))
    assert size < 1500, size  # the map's additions stay a small part of a ~16 KB push
    s["shift"] = {"start": 1, "end": 2, "next": 3, "next_exact": False}
    assert push_live.public_state(s)["shift"] == s["shift"]  # the offline state's "next shift" line
    s2 = dict(s, space={"active": False})
    s2.pop("fights")
    out2 = push_live.public_state(s2)
    assert "space" not in out2 and "fights" not in out2


def build_tests():
    with tempfile.TemporaryDirectory() as d:
        subprocess.run([sys.executable, os.path.join(SITE, "build.py"), "--out", d], check=True, capture_output=True)
        r = subprocess.run([sys.executable, os.path.join(SITE, "check.py"), d], capture_output=True, text=True)
        assert r.returncode == 0, r.stdout
        home = open(os.path.join(d, "index.html")).read()
        assert 'id="live-app"' in home and "/static/live.js" in home and "/static/avatar.js" in home
        assert home.index('id="live-app"') < home.index('class="home-more"'), "the live show comes first"
        for href in ("/about/", "/experiments/", "/runs/", "/studies/"):
            assert f'href="{href}"' in home, href
        about = open(os.path.join(d, "about", "index.html")).read()
        assert "Fair-play rules" in about and 'id="team"' in about
        assert 'id="live-app"' in open(os.path.join(d, "live", "index.html")).read()


def main():
    payload_tests()
    build_tests()
    print("site live: ok (compact space, fights and camera labels; homepage is the live show; about and /live/ kept)")


if __name__ == "__main__":
    main()
