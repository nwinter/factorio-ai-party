#!/usr/bin/env python3
"""Avatar renderer checks: python3 tools/stream/test_avatar.py

- The Python port (avatar.py) and the JS module (static/avatar.js, run under node) give identical SVG for a few
  hundred profiles: random specs, partial and invalid specs, no colour, near-black and near-white colours, unicode
  names.
- The harness (vendor/factorio-harness/.../profiles.lua) accepts exactly the part names the renderers know.
- Every spec draws a full 24x24 picture (no transparent pixel) and defaults are stable per name.
"""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import avatar  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(HERE))
LUA = os.path.join(ROOT, "vendor/factorio-harness/mod/agent-harness_0.1.0/profiles.lua")


def cases():
    out = []
    colors = [None, "#9977ff", "#ffcb45", "#1a1a1a", "#000000", "#ffffff", "#F4F4F0", "#4285F4", "bogus"]
    names = ["astra", "sol", "luna", "opus", "sonnet", "haiku", "grok", "gemini", "muse", "Grok the Unyielding",
             "👩‍🚀 nova", "ñandú", "", "x" * 40]
    for i, n in enumerate(names):
        out.append({"name": n, "color": colors[i % len(colors)]})
        out.append({"display_name": n or "shown", "color": colors[(i + 3) % len(colors)]})
    for i in range(240):
        out.append({"name": "agent%d" % i, "color": colors[i % len(colors)], "avatar": avatar.random(i)})
    out.append({"name": "p", "avatar": {"base": "biter"}})
    out.append({"name": "p", "avatar": {"base": "dragon", "visor": 3, "accent": "red"}})
    out.append({"name": "p", "avatar": {"accent": "#ABCDEF"}})
    out.append({"name": "p", "avatar": "robot"})
    out.append({"name": "a&b<c>\"d", "display_name": "a&b<c>\"d"})
    return out


def node_render(items):
    js = os.path.join(HERE, "static", "avatar.js")
    script = ("const A=require(%s);let s='';process.stdin.on('data',d=>s+=d);process.stdin.on('end',()=>{"
              "const items=JSON.parse(s);process.stdout.write(JSON.stringify({svg:items.map(p=>A.svg(p,40)),"
              "spec:items.map(p=>A.resolve(p)),random:[0,1,2,3,99].map(A.random),"
              "validate:items.map(p=>A.validate(p.avatar))}));});") % json.dumps(js)
    r = subprocess.run(["node", "-e", script], input=json.dumps(items), capture_output=True, text=True, check=True)
    return json.loads(r.stdout)


def lua_parts():
    text = open(LUA, encoding="utf-8").read()
    block = text[text.index("local AVATAR = {"): text.index("local AVATAR_KEYS")]
    return {k: re.findall(r"'([a-z]+)'", v) for k, v in re.findall(r"(\w+)=\{([^}]*)\}", block)}


def main():
    items = cases()
    js = node_render(items)
    bad = 0
    for i, p in enumerate(items):
        py = avatar.svg(p, 40)
        if py != js["svg"][i]:
            bad += 1
            if bad < 4:
                print("SVG differs for", json.dumps(p, ensure_ascii=False))
        if avatar.resolve(p) != js["spec"][i]:
            bad += 1
            print("spec differs for", json.dumps(p, ensure_ascii=False), avatar.resolve(p), js["spec"][i])
        if avatar.validate(p.get("avatar")) != js["validate"][i]:
            bad += 1
            print("validate differs for", p.get("avatar"))
        grid = avatar.pixels(p)
        assert len(grid) == 24 and all(len(r) == 24 and all(r) for r in grid), "holes in %r" % p
    assert [avatar.random(s) for s in [0, 1, 2, 3, 99]] == js["random"], "random() differs"
    assert bad == 0, "%d mismatches between avatar.py and avatar.js" % bad

    assert lua_parts() == avatar.PARTS["options"], "profiles.lua AVATAR lists differ from avatar.js PARTS"
    for spec in (avatar.random(i) for i in range(50)):
        assert avatar.validate(spec) == [], spec

    # Defaults: stable per name, colour respected, setting one part keeps the others.
    a = avatar.resolve({"name": "opus", "color": "#d97757"})
    assert a == avatar.resolve({"name": "opus", "color": "#d97757"}) and a["color"] == "#d97757"
    b = avatar.resolve({"name": "opus", "color": "#d97757", "avatar": {"visor": "mono"}})
    assert b["visor"] == "mono" and all(a[k] == b[k] for k in a if k != "visor")
    assert avatar.resolve({"name": "sonnet"})["color"] in avatar.PARTS["colors"]
    print("avatar: ok (%d profiles, JS and Python identical)" % len(items))


if __name__ == "__main__":
    main()
