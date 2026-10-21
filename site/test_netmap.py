#!/usr/bin/env python3
"""Each planet's electric and logistic networks and an item's sources and consumers on the live map (d21 batch68 AD3,
viewer Aurora 13:03: "Could maps show logistic/power network IDs and coverage, plus a selected item's source-to-consumer
blockers?"): python3 site/test_netmap.py

push_live.public_net_map: the stream's net map shaped for the site (known keys only; an empty table read as {} made a
list), the electric grid at twice the cell until it fits NET_GRID_BYTES, items' positions cut to 1 then none, then items
left out (those no consumer takes first) until it fits; public_net_maps lists every planet and sends one a push in turn.
static/mapview.js under node: parseNet() reads the strings, itemFacts() names each group and its gaps (outside every
logistic network, no source of it in the consumer's network or on the planet, no consumer in the source's network, on
no electric network), netHit() the networks under a tile, remember() keeps each planet's map, and scene() draws the
layers and the picked item.
"""
import json, os, shutil, subprocess, sys, tempfile

SITE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SITE)
sys.dont_write_bytecode = True
import push_live  # noqa: E402

JS = r"""
const fx = JSON.parse(require('fs').readFileSync(process.argv[3], 'utf8'));
global.window = global;
require(process.argv[2]);
const M = global.PogMap;
const out = {};
const data = M.unpackData({ net_maps: { gleba: fx.net } });
const net = M.parseNet(data.net_maps.gleba);
out.nets = net.nets; out.grid = net.grid.rows; out.logistic = net.logistic; out.names = net.names;
out.gear = M.itemFacts(net, 'iron-gear-wheel');
out.plate = M.itemFacts(net, 'iron-plate');
out.none = M.itemFacts(net, 'nothing');
out.hit = M.netHit({ net: net }, -2.5, -2.5, { power: true, robots: true });
out.hitConstruction = M.netHit({ net: net }, 10, 50, { power: true, robots: true });
out.hitOff = M.netHit({ net: net }, -2.5, -2.5, { power: false, robots: false });
const memo = {};
M.remember(memo, { net_maps: { gleba: Object.assign({}, fx.net, { tick: 500 }) } });
const kept = M.remember(memo, { net_maps: { aquilo: { tick: 9, electric: {}, logistic: [], items: [] } } });
const older = M.remember(memo, { net_maps: { gleba: Object.assign({}, fx.net, { tick: 400 }) } });
out.kept = Object.keys(kept.net_maps).sort(); out.keptTick = older.net_maps.gleba.tick;
const d = M.prepare({ surface: 'gleba', planets: { gleba: { tick: 1, cell: 8, x0: 0, y0: 0, w: 2, h: 1, rows: ['AA'] } }, net_maps: data.net_maps });
const sc = M.scene(d, { cx: 10, cy: 10, span: 120 }, 400, 400, Object.assign({}, M.DEFAULT_ON, { power: true, robots: true, item: 'iron-gear-wheel' }));
out.scene = { power: !!sc.power, robots: sc.robots.map((n) => n.ports.length), item: sc.item.map((m) => [m.role, m.gap, m.one]),
  hits: sc.hits.filter((h) => /Source of|Consumer of|Roboport at/.test(h.text)).length };
const off = M.scene(d, { cx: 10, cy: 10, span: 120 }, 400, 400, M.DEFAULT_ON);
out.off = { power: !!off.power, robots: off.robots.length, item: off.item.length };
process.stdout.write(JSON.stringify(out));
"""


def check(name, ok, detail=""):
    if not ok:
        raise SystemExit(f"FAIL {name}: {detail}")


NET = {"surface": "gleba", "tick": 1000, "census": 900, "done_tick": 1100, "research": "automation", "junk": 1,
       "electric": {"poles": 5, "nets": "7,A,3;9,B,1", "cell": 1, "x0": -3, "y0": -3, "w": 20, "h": 3, "rle": 1,
                    "rows": ["19A", "3ABB14A", ""], "outside": 1, "x": 2},
       "logistic": [{"id": 243, "lr": 25, "cr": 55, "n": 3, "ports": "10,10;60,10", "odd": "90,10,30,60", "robots": "40,5,10,10", "y": 1}],
       "items": [["iron-gear-wheel", "A,243,1,0,0,10,10", "Q,0,1,50,0,150,20;A,7,2,0,1,-40,0,-38,0,-40,0,-38,0"],
                 ["iron-plate", "A,243,2,0,0,20,10,24,10,20,10,24,10;S,243,1,100,0,12,12", "A,243,1,0,0,10,10"],
                 ["stone", "S,0,1,10,0,5,5", ""], "broken"]}


def main():
    pub = push_live.public_net_map(NET)
    check("known keys", "junk" not in pub and "x" not in pub["electric"] and "y" not in pub["logistic"][0] and pub["positions"] == 4, pub)
    check("items as read", [i[0] for i in pub["items"]] == ["iron-gear-wheel", "iron-plate", "stone"] and pub["items"][1] == NET["items"][1], pub["items"])
    check("grid as packed", pub["electric"]["rows"] == ["19A", "3ABB14A", ""] and pub["electric"]["rle"] == 1 and "cell_from" not in pub["electric"], pub["electric"])
    empty = push_live.public_net_map({"surface": "aquilo", "tick": 5, "electric": {"nets": {}, "poles": 0}, "logistic": {}, "items": {}})
    check("empty tables read as {}", empty["logistic"] == [] and empty["items"] == [] and empty["electric"]["nets"] == "", empty)
    check("not a map", push_live.public_net_map(None) is None and push_live.public_net_map({"tick": 1}) is None)
    # an electric grid over its share: twice the cell, the network with more poles where two meet
    big = dict(NET, electric=dict(NET["electric"], cell=1, x0=0, y0=0, w=600, h=600, rle=0,
                                  rows=[("AB" * 300) if j % 2 else ("BA" * 300) for j in range(600)]))
    g = push_live.public_net_map(big)["electric"]
    check("coarser grid", g["cell"] > 1 and g["cell_from"] == 1 and len(json.dumps(g, separators=(",", ":"))) <= push_live.NET_GRID_BYTES
          and set("".join(push_live.unpacked(g)["rows"])) <= {"A", "."}, (g["cell"], len(json.dumps(g))))
    # items over the budget: positions cut, then items left out, those no consumer takes first
    many = [[f"item-{i:03d}", ";".join(f"A,243,9,0,0,{i},0,{i + 9},9,{i},0,{i + 1},1,{i + 2},2,{i + 3},3" for _ in range(3)),
             "" if i % 2 else f"Q,0,3,10,0,{i},5,{i + 2},5,{i},5"] for i in range(400)]
    trimmed = push_live.public_net_map(dict(NET, items=many), limit=12 * 1024)
    check("within the limit", len(json.dumps(trimmed, separators=(",", ":"))) <= 12 * 1024, len(json.dumps(trimmed)))
    check("positions cut to none", trimmed["positions"] == 0 and all(len(gr.split(",")) == 9 for i in trimmed["items"] for gr in i[1].split(";") if gr), trimmed["items"][0])
    left = set(i[0] for i in many) - set(i[0] for i in trimmed["items"])
    odd_left = sum(1 for n in left if int(n[-3:]) % 2 == 1)
    check("items left out, those no consumer takes first", trimmed["left_out"] == len(left) > 0
          and (odd_left == len(left) or odd_left == 200), (len(left), odd_left))
    one = push_live.public_net_map(dict(NET, items=many[:40]), limit=12 * 1024)
    check("cut to one position first", one["positions"] in (1, 4) and "left_out" not in one, one["positions"])
    # one planet a push, in turn, every planet listed
    push_live._net_turn["i"] = 0
    maps = {"gleba": NET, "aquilo": dict(NET, surface="aquilo", tick=5)}
    l1, m1 = push_live.public_net_maps(maps)
    l2, m2 = push_live.public_net_maps(maps)
    check("listing", l1 == [{"surface": "aquilo", "tick": 5}, {"surface": "gleba", "tick": 1000}], l1)
    check("in turn", m1["surface"] == "aquilo" and m2["surface"] == "gleba", (m1["surface"], m2["surface"]))
    st = push_live.public_state({"net_maps": maps})
    check("public state", isinstance(st.get("net_maps"), list) and st["net_map"]["surface"] in ("aquilo", "gleba"), st.keys())
    check("none", push_live.public_net_maps(None) == (None, None) and "net_map" not in push_live.public_state({}))

    if not shutil.which("node"):
        print("net map: push_live ok; mapview skipped (no node)")
        return
    with tempfile.TemporaryDirectory() as d:
        fx = os.path.join(d, "fx.json")
        json.dump({"net": pub}, open(fx, "w"))
        js = os.path.join(d, "t.js")
        open(js, "w").write(JS)
        r = subprocess.run(["node", js, os.path.join(SITE, "static", "mapview.js"), fx], capture_output=True, text=True, timeout=30)
        check("node", r.returncode == 0, r.stderr)
        o = json.loads(r.stdout)
    check("networks", o["nets"] == [{"id": 7, "letter": "A", "poles": 3}, {"id": 9, "letter": "B", "poles": 1}], o["nets"])
    check("grid unpacked", o["grid"][1] == "AAABB" + "A" * 14, o["grid"])
    lg = o["logistic"][0]
    check("roboports with radii", lg["id"] == 243 and lg["ports"] == [[10, 10, 25, 55], [60, 10, 25, 55], [90, 10, 30, 60]] and lg["robots"] == [40, 5, 10, 10], lg)
    check("names", o["names"] == ["iron-gear-wheel", "iron-plate", "stone"], o["names"])
    gear = o["gear"]
    texts = [m["text"] for m in gear["marks"]]
    check("source in words", texts[0] == "Source of iron-gear-wheel: 1 crafter making it · logistic network #243 · at (10, 10) · gap: no consumer of it in network #243", texts)
    check("consumer outside", texts[1] == "Consumer of iron-gear-wheel: 1 requester chest asking for 50 · its spot outside every logistic network · at (150, 20) · gap: outside every logistic network", texts)
    check("consumer in another network, unpowered", texts[2] == "Consumer of iron-gear-wheel: 2 crafters whose recipe takes it · logistic network #7 · in x -40..-38, y 0..0 · gap: no source of it in network #7; 1 on no electric network", texts)
    check("gear lines", gear["lines"][0] == "iron-gear-wheel: 1 source in 1 group, 3 consumers in 2 groups" and gear["gaps"] == 3, gear["lines"])
    plate = o["plate"]
    check("no gap", plate["gaps"] == 0 and plate["lines"][-1] == "every source and consumer shares a logistic network with the other side", plate["lines"])
    check("unknown item", o["none"] is None)
    check("hover: networks under a tile", o["hit"]["text"] == "Electric network #7: 3 poles · Logistic area of logistic network #243: 3 roboports, logistic robots 40 (5 idle), construction robots 10 (10 idle)", o["hit"])
    check("hover: construction area only", o["hitConstruction"]["text"].startswith("Construction area only of logistic network #243"), o["hitConstruction"])
    check("hover: layers off", o["hitOff"] is None)
    check("kept a planet each, the newer", o["kept"] == ["aquilo", "gleba"] and o["keptTick"] == 500, (o["kept"], o["keptTick"]))
    sc = o["scene"]
    check("scene", sc["power"] and sc["robots"] == [3] and sc["item"] == [["s", True, True], ["c", True, True], ["c", True, False]] and sc["hits"] >= 4, sc)
    check("layers off by default", o["off"] == {"power": False, "robots": 0, "item": 0}, o["off"])
    print("net map: ok (networks, coverage, an item's sources and consumers with their gaps, kept a planet each)")


if __name__ == "__main__":
    main()
