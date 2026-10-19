#!/usr/bin/env python3
"""The team's library entries saved since /blueprints/ was built (d19 batch42 B4, seq 870: Sol's lab-belt-four41, 173
entities, was in the team library and not on the site): tools/stream/library.py puts the newest 15 in the live state
(no strings), push_live keeps `library`, and the page lists the ones it does not have, or has older, with author and
time. python3 site/test_library_live.py"""
import json, os, shutil, subprocess, sys, tempfile

SITE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SITE)
sys.path.insert(0, os.path.join(os.path.dirname(SITE), "tools", "stream"))
import blueprints  # noqa: E402
import library  # noqa: E402
import push_live  # noqa: E402

FOUR = {"name": "lab-belt-four41", "author": "sol", "entities": 173, "footprint": "46x16", "surface": "nauvis",
        "saved_tick": 33373000, "counts": "fast-transport-belt*126 biolab*4", "uses": 0,
        "description": "Complete four-biolab example, two repeat cells, all 12 science belt ports. " * 5}


def main():
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "index.json")
        lib = library.Library(path)
        assert lib.public() is None
        old = [{"name": f"old{i}", "author": "astra", "saved_tick": 1000 + i, "entities": 3} for i in range(20)]
        json.dump({"written": "2026-10-19T12:51:56", "tick": 33373533, "entries": old + [FOUR, {"name": "../bad"}]}, open(path, "w"))
        pub = lib.public()
        assert pub["count"] == 21 and len(pub["entries"]) == library.NEWEST and pub["entries"][0]["name"] == "lab-belt-four41", pub
        e = pub["entries"][0]
        assert "string" not in e and "counts" not in e and e["author"] == "sol" and len(e["description"]) <= library.DESC_MAX, e
        state = push_live.public_state({"tick": 33380000, "now": 1792440000.0, "agents": [], "library": pub})
        assert state["library"]["entries"][0]["name"] == "lab-belt-four41"
    # the page: built with the API it has the live section and its script; without, neither
    esc = lambda s: str(s).replace("&", "&amp;").replace("<", "&lt;").replace('"', "&quot;")
    page = {"shift": 40, "id": "shift40", "written": "2026-10-19T11:50:00", "entries": [dict(old[0], string="0eNq")]}
    body, head = blueprints.build_page(page, lambda k: {"name": k}, lambda k, s: "", esc, lambda t: str(t), (), "https://api.example")
    assert 'id="bp-live" data-api="https://api.example" hidden' in body and 'data-saved="1000"' in body and "bp-live" in head
    body2, head2 = blueprints.build_page(page, lambda k: {"name": k}, lambda k, s: "", esc, lambda t: str(t), ())
    assert "bp-live" not in body2 and "bp-live" not in head2 and "built at each shift change" in body2
    if not shutil.which("node"):
        print("library live: page script skipped (no node)")
        return
    js = head.split("<script>")[-1].split("</script>")[0]
    stub = r"""
const li = [{ id: 'old0', getAttribute: (k) => k === 'data-saved' ? '1000' : null }];
const ul = { innerHTML: '' }, sec = { hidden: true, getAttribute: () => 'https://api.example/', querySelector: () => ul };
global.window = global;
global.document = { getElementById: (id) => id === 'bp-live' ? sec : null, querySelectorAll: () => li };
const STATE = JSON.parse(process.argv[2]);
global.fetch = (url) => Promise.resolve({ ok: url === 'https://api.example/v1/state', json: () => Promise.resolve({ state: STATE, age_s: 3 }) });
""" + js + r"""
setTimeout(() => process.stdout.write(JSON.stringify({ hidden: sec.hidden, html: ul.innerHTML })), 50);
"""
    st = {"tick": 33380000, "now": 1792440000.0, "library": {"entries": [
        {"name": "lab-belt-four41", "author": "sol", "saved_tick": 33373000, "entities": 173, "footprint": "46x16", "surface": "nauvis"},
        {"name": "old0", "author": "astra", "saved_tick": 1000, "entities": 3},
        {"name": "old1", "author": "astra", "saved_tick": 1001, "entities": 3}]}}
    with tempfile.TemporaryDirectory() as d:
        f = os.path.join(d, "t.js")
        open(f, "w").write(stub)
        out = json.loads(subprocess.run(["node", f, json.dumps(st)], capture_output=True, text=True, check=True, timeout=30).stdout)
    assert out["hidden"] is False and "lab-belt-four41" in out["html"] and "by sol" in out["html"] and "173 entities" in out["html"], out
    assert "old1" in out["html"] and "old0" not in out["html"], out  # on the page already, not newer: left out
    print("library live: ok (newest 15 in the state, no strings; the page lists the ones it lacks with author and time)")


if __name__ == "__main__":
    main()
