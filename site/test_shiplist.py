#!/usr/bin/env python3
"""The live page's ship overview (d22 batch75 AK2, viewer Foobator, site:4034: "the ship overview only has a progress bar
for the first 2 that are in transit? can in transit be listed first and the rest have their planetary waiting time
displayed?"): python3 site/test_shiplist.py

push_live passes each platform's waited_s and waited_more (the stream service's game seconds at its planet; more: there
before the service first read it). static/live.js's spaceInset lists the platforms in transit first, each with its
progress bar, then the rest in the stream's order with "waiting 12 min" (or "12+ min", "1 h 5 min").
"""
import json, os, re, shutil, subprocess, sys, tempfile

SITE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SITE)
sys.dont_write_bytecode = True
import push_live  # noqa: E402

JS = r"""
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
const sp = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const start = src.indexOf('  // Space Age inset'), end = src.indexOf('  // ------------------------------------------------------------------ dashboard');
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => '&#' + c.charCodeAt(0) + ';');
const label = (s) => { s = String(s || '').replace(/[-_]/g, ' '); return s.charAt(0).toUpperCase() + s.slice(1); };
const spaceInset = new Function('esc', 'label', src.slice(start, end) + '; return spaceInset;')(esc, label);
process.stdout.write(spaceInset(sp));
"""


def main():
    now = 1792660000.0
    plats = [
        {"name": "Dock", "where": "Nauvis", "state": "no_schedule", "paused": False, "waited_s": 3900, "waited_more": True, "view": {}},
        {"name": "Ferry", "where": "Gleba", "state": "waiting_at_station", "paused": False, "waited_s": 725},
        {"name": "Cinder", "where": "Nauvis → Gleba", "route": {"from": "Nauvis", "to": "Gleba", "pct": 64}, "state": "on_the_path",
         "paused": False, "speed_kms": 31},
        {"name": "Fresh", "where": "Vulcanus", "state": "waiting_at_station", "paused": False, "waited_s": 20, "waited_more": True},
        {"name": "Asterion", "where": "Fulgora → Aquilo", "route": {"from": "Fulgora", "to": "Aquilo", "pct": 12}, "state": "on_the_path",
         "paused": False, "speed_kms": 40},
        {"name": "Just", "where": "Gleba", "state": "waiting_at_station", "paused": False, "waited_s": 30},
    ]
    out = push_live.public_space({"active": True, "rockets": 9, "planets": ["Nauvis"], "platforms": plats})
    assert out["platforms"][0] == {"name": "Dock", "where": "Nauvis", "state": "no_schedule", "paused": False, "waited_s": 3900,
                                   "waited_more": True}, out["platforms"][0]
    assert "waited_s" not in out["platforms"][2], out["platforms"][2]
    if not shutil.which("node"):
        print("ship list: push_live ok; page skipped (no node)")
        return
    with tempfile.TemporaryDirectory() as d:
        js, fx = os.path.join(d, "t.js"), os.path.join(d, "fx.json")
        open(js, "w").write(JS)
        json.dump(out, open(fx, "w"))
        r = subprocess.run(["node", js, os.path.join(SITE, "static", "live.js"), fx], capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, r.stderr
    html = r.stdout
    items = re.findall(r"<li><b>([^<]+)</b>(.*?)</li>", html)
    order = [n for n, _ in items]
    assert order == ["Cinder", "Asterion", "Dock", "Ferry", "Fresh", "Just"], order  # in transit first, then the stream's order
    by = dict(items)
    assert by["Cinder"].count('role="progressbar"') == 1 and by["Asterion"].count('role="progressbar"') == 1, by
    assert "waiting" not in by["Cinder"], by["Cinder"]
    assert "waiting 1 h 5+ min" in by["Dock"] and "No schedule" not in by["Dock"] and "no schedule" in by["Dock"], by["Dock"]
    assert "waiting 12 min" in by["Ferry"] and "progressbar" not in by["Ferry"], by["Ferry"]
    assert "waiting" not in by["Fresh"], by["Fresh"]  # at least under a minute: nothing to say
    assert "waiting under 1 min" in by["Just"], by["Just"]
    print("ship list: ok (in transit first with their bars, the rest with their waiting time at the planet)")


if __name__ == "__main__":
    main()
