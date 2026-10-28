#!/usr/bin/env python3
"""(mt274, private: multi-team phase 1) A Space Age map for N teams, and its forces.

  python3 tools/mt/mt_map.py layout [--teams 4] [--distance 1300]                   # print the layout
  python3 tools/mt/mt_map.py create --dir DIR [--teams 4] [--distance D] [--seed S] [--docker NAME]
  python3 tools/mt/mt_map.py setup  --dir DIR --port P --password-file F            # forces, spawns, resources
  python3 tools/mt/mt_map.py assign --port P --password-file F --player NAME --team T
  python3 tools/mt/mt_map.py join   --dir DIR --port P --password-file F [--team T]        # macOS clients
  python3 tools/mt/mt_map.py chart-test --dir DIR --port P --password-file F [--seconds 60]
  python3 tools/mt/mt_map.py report --dir DIR --port P --password-file F [--corridor]
  python3 tools/mt/mt_map.py contacts --port P --password-file F

create writes DIR/layout.json and DIR/map-gen-settings.json and, with --docker, makes DIR/saves/mt.zip with the
headless build in DIR/factorio (factorio --create, mods from DIR/mods). Every start is a starting point (a biter-free
starting area with water and the game's starter ores, which setup then replaces). Natural ore and oil patches are
made less frequent (NATURAL), so the placed patches are most of what lies near the starts.

setup runs on a server with this branch's harness (fh deploy, and control.lua's on_chunk_charted from the mod
folder): mt_setup (one force per team, at war, chart not shared, a spawn per team on every planet), mt_generate round
each start and site, then mt_resources: the starts' natural resources cleared and the same primary patches placed for
each team (rotated with its bearing), and the shared patches between neighbouring starts (second) and in the middle
(third). Each team needs a LuaPlayer to chart: a client joins once as mt-TEAM and `assign` moves it in.
"""
import argparse, json, math, os, subprocess, sys, time, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
TEAMS = ["red", "blue", "green", "yellow", "orange", "purple", "cyan", "pink"]
PLANETS = ["vulcanus", "fulgora", "gleba", "aquilo"]
# natural patches: frequency x (size and richness unchanged)
NATURAL = {"iron-ore": 0.3, "copper-ore": 0.3, "coal": 0.3, "stone": 0.3, "crude-oil": 0.3}
# each team's own patches, in the team's frame: u away from the middle of the map, v across (tiles); r radius; amount
PRIMARY = [
    {"name": "iron-ore", "u": 70, "v": -45, "r": 18, "amount": 1_500_000},
    {"name": "copper-ore", "u": 70, "v": 45, "r": 16, "amount": 1_200_000},
    {"name": "coal", "u": -15, "v": -80, "r": 14, "amount": 1_000_000},
    {"name": "stone", "u": -15, "v": 80, "r": 11, "amount": 600_000},
    {"name": "crude-oil", "u": 140, "v": 0, "wells": 6, "amount": 3_600_000},
]
# shared sites: e along the line between the two starts, w toward the middle of the map
SECOND = [
    {"name": "iron-ore", "e": -40, "w": 0, "r": 20, "amount": 2_000_000},
    {"name": "copper-ore", "e": 40, "w": 0, "r": 18, "amount": 1_600_000},
    {"name": "coal", "e": 0, "w": -45, "r": 16, "amount": 1_200_000},
    {"name": "stone", "e": 0, "w": 45, "r": 12, "amount": 800_000},
    {"name": "crude-oil", "e": 0, "w": 0, "wells": 6, "amount": 4_800_000},
]
THIRD = [
    {"name": "iron-ore", "e": -55, "w": 0, "r": 24, "amount": 3_000_000},
    {"name": "copper-ore", "e": 55, "w": 0, "r": 22, "amount": 2_400_000},
    {"name": "coal", "e": 0, "w": -55, "r": 20, "amount": 2_000_000},
    {"name": "stone", "e": 0, "w": 55, "r": 14, "amount": 1_200_000},
    {"name": "crude-oil", "e": 0, "w": 0, "wells": 8, "amount": 6_400_000},
]
CLEAR_START, CLEAR_SECOND, CLEAR_THIRD = 320, 110, 130
# a patch moves to the nearest dry spot (water, a lake in the middle): at most this far (tiles)
SHIFT_START, SHIFT_SITE = 64, 288
# (mt274 tests, seed 274274, water and nests walked on a 32-tile grid) at 1000 tiles apart with the game's enemy settings
# every pair of starts had a path keeping 128 tiles from every nest, at 2000 still 96; at 1300 with enemy bases
# frequency 2 no pair had one keeping 96 tiles (3 of 6 pairs one keeping 64)
DISTANCE, ENEMY = 1300, (2.0, 1.0)
PLANET_RING = 600  # each team's spawn on the other planets: this far from (0,0), on the team's bearing


def layout(teams=4, distance=DISTANCE, planet_ring=PLANET_RING):
    """Starts on a ring round (0,0), neighbours `distance` apart; patches and sites in map coordinates."""
    assert 2 <= teams <= len(TEAMS)
    ring = distance / 2 / math.sin(math.pi / teams) if teams > 2 else distance / 2
    out = {"teams": [], "sites": [], "distance": distance, "ring": round(ring, 1), "patches": [], "clear": []}
    for i in range(teams):
        ang = 2 * math.pi * i / teams + math.pi / teams + (math.pi / 2 if teams == 2 else 0)
        ux, uy = math.cos(ang), math.sin(ang)
        sx, sy = round(ring * ux) + 0.5, round(ring * uy) + 0.5
        t = {"name": TEAMS[i], "bearing_deg": round(math.degrees(ang), 1), "spawns": {"nauvis": [sx, sy]}}
        for p in PLANETS:
            t["spawns"][p] = [round(planet_ring * ux) + 0.5, round(planet_ring * uy) + 0.5]
        out["teams"].append(t)
        out["clear"].append({"x": sx, "y": sy, "r": CLEAR_START})
        for q in PRIMARY:
            x = sx + q["u"] * ux - q["v"] * uy
            y = sy + q["u"] * uy + q["v"] * ux
            out["patches"].append(dict({k: v for k, v in q.items() if k not in ("u", "v")}, x=round(x) + 0.5, y=round(y) + 0.5,
                                       site="start " + TEAMS[i], max_shift=SHIFT_START))

    def site(name, cx, cy, ex, ey, kind, clear):
        n = math.hypot(ex, ey) or 1
        ex, ey = ex / n, ey / n
        wx, wy = -ey, ex
        if wx * -cx + wy * -cy < 0:  # w toward the middle
            wx, wy = -wx, -wy
        out["sites"].append({"name": name, "x": round(cx) + 0.5, "y": round(cy) + 0.5, "kind": kind})
        out["clear"].append({"x": round(cx) + 0.5, "y": round(cy) + 0.5, "r": clear})
        for q in kind == "second" and SECOND or THIRD:
            x = cx + q["e"] * ex + q["w"] * wx
            y = cy + q["e"] * ey + q["w"] * wy
            out["patches"].append(dict({k: v for k, v in q.items() if k not in ("e", "w")}, x=round(x) + 0.5, y=round(y) + 0.5, site=name,
                                       max_shift=SHIFT_SITE))

    ts = out["teams"]
    for i in range(teams if teams > 2 else 1):
        a, b = ts[i], ts[(i + 1) % teams]
        (ax, ay), (bx, by) = a["spawns"]["nauvis"], b["spawns"]["nauvis"]
        site(f"second {a['name']}-{b['name']}", (ax + bx) / 2, (ay + by) / 2, bx - ax, by - ay, "second", CLEAR_SECOND)
    if teams >= 3:
        site("third middle", 0, 0, 1, 0, "third", CLEAR_THIRD)
    else:
        (ax, ay), (bx, by) = ts[0]["spawns"]["nauvis"], ts[1]["spawns"]["nauvis"]
        px, py = -(by - ay) / distance, (bx - ax) / distance
        for k, sgn in (("north", 1), ("south", -1)):
            cx, cy = sgn * px * distance * 0.4, sgn * py * distance * 0.4
            out["sites"].append({"name": f"third {k}", "x": round(cx) + 0.5, "y": round(cy) + 0.5, "kind": "third"})
            out["clear"].append({"x": round(cx) + 0.5, "y": round(cy) + 0.5, "r": CLEAR_THIRD})
            for q in THIRD:
                x, y = cx + q["e"] * (bx - ax) / distance + q["w"] * px, cy + q["e"] * (by - ay) / distance + q["w"] * py
                out["patches"].append(dict({k2: v for k2, v in q.items() if k2 not in ("e", "w")}, x=round(x) + 0.5, y=round(y) + 0.5,
                                           site=f"third {k}", max_shift=SHIFT_SITE))
    return out


def map_gen_settings(lay, base, seed, enemy_frequency=1.0, enemy_size=1.0):
    mgs = json.loads(json.dumps(base))
    mgs = {k: v for k, v in mgs.items() if not k.startswith("_")}
    mgs["seed"] = seed
    mgs["starting_points"] = [{"x": t["spawns"]["nauvis"][0], "y": t["spawns"]["nauvis"][1]} for t in lay["teams"]]
    for name, f in NATURAL.items():
        c = mgs["autoplace_controls"].setdefault(name, {"frequency": 1, "size": 1, "richness": 1})
        c["frequency"] = f
    e = mgs["autoplace_controls"].setdefault("enemy-base", {"frequency": 1, "size": 1})
    e["frequency"], e["size"] = enemy_frequency, enemy_size
    return mgs


class Op:
    """Operator calls to the harness over RCON (remote.call dispatch, operator: true)."""

    def __init__(self, port, password, host="127.0.0.1", timeout=600):
        from pog import Rcon
        self.r = Rcon(host, port, password, timeout=timeout)

    def lua(self, cmd):
        return self.r.command(cmd)

    def call(self, action, args=None):
        req = json.dumps({"id": "mt-" + uuid.uuid4().hex, "action": action, "operator": True, "args": args or {}})
        t0 = time.time()
        out = self.r.command("/silent-command rcon.print(remote.call('agent_harness','dispatch'," + "[==[" + req + "]==]))")
        took = time.time() - t0
        try:
            r = json.loads(out)
        except ValueError:
            raise SystemExit(f"{action}: {out[:400]}")
        if not r.get("ok"):
            raise SystemExit(f"{action}: {r.get('error')}")
        return r["result"], took


def op_from(a):
    pw = open(a.password_file).read().strip()
    op = Op(a.port, pw, a.host)
    # the first command after a server starts can come back empty (docs/SETUP.md): read until a reply comes
    for _ in range(10):
        out = op.lua("/silent-command rcon.print('ready')")
        if out.strip() == "ready":
            break
        time.sleep(1)
    return op


def cmd_layout(a):
    print(json.dumps(layout(a.teams, a.distance, a.planet_ring), indent=1))


def cmd_create(a):
    os.makedirs(a.dir, exist_ok=True)
    lay = layout(a.teams, a.distance, a.planet_ring)
    lay["seed"] = a.seed
    base = json.load(open(os.path.join(a.dir, "factorio/data/map-gen-settings.example.json")))
    lay["enemy"] = {"frequency": a.enemy_frequency, "size": a.enemy_size}
    json.dump(map_gen_settings(lay, base, a.seed, a.enemy_frequency, a.enemy_size), open(os.path.join(a.dir, "map-gen-settings.json"), "w"), indent=1)
    json.dump(lay, open(os.path.join(a.dir, "layout.json"), "w"), indent=1)
    print("layout:", os.path.join(a.dir, "layout.json"))
    if a.docker:
        os.makedirs(os.path.join(a.dir, "saves"), exist_ok=True)
        os.makedirs(os.path.join(a.dir, "factorio/saves"), exist_ok=True)
        t0 = time.time()
        r = subprocess.run(["docker", "run", "--rm", "--platform", "linux/amd64", "--name", a.docker, "-v", f"{a.dir}:/pog",
                            "debian:bookworm-slim", "/pog/factorio/bin/x64/factorio", "--create", "/pog/saves/mt.zip",
                            "--map-gen-settings", "/pog/map-gen-settings.json", "--mod-directory", "/pog/mods"],
                           capture_output=True, text=True)
        tail = [l for l in r.stdout.splitlines() if "rror" in l or "Saving" in l or "finished" in l.lower()][-6:]
        print("\n".join(tail))
        print(f"create: {time.time() - t0:.1f} s, exit {r.returncode}")


def cmd_setup(a):
    lay = json.load(open(os.path.join(a.dir, "layout.json")))
    op = op_from(a)
    times = {}
    res, times["mt_setup"] = op.call("mt_setup", {"teams": [{"name": t["name"], "spawns": t["spawns"]} for t in lay["teams"]]})
    print("mt_setup", json.dumps(res))
    t0 = time.time()
    for c in lay["clear"]:
        # the chunks a patch may move into are made too (a chunk made later would bring its natural ore)
        reach = c["r"] + (SHIFT_START if c["r"] == CLEAR_START else SHIFT_SITE) + 32
        op.call("mt_generate", {"surface": "nauvis", "position": [c["x"], c["y"]], "radius": math.ceil(reach / 32)})
    times["generate nauvis"] = time.time() - t0
    res, times["mt_resources nauvis"] = op.call("mt_resources", {"surface": "nauvis", "clear": lay["clear"], "patches": lay["patches"]})
    starts = {t["name"]: t["spawns"]["nauvis"] for t in lay["teams"]}

    def near(p):
        d = sorted((math.dist(xy, (p["x"], p["y"])), n) for n, xy in starts.items())[:2]
        return ", ".join(f"{n} {v:.0f}" for v, n in d)
    short = [f"{p['site']} {p['name']} {p['amount']} ({p['tiles']} tiles) at ({p['x']},{p['y']})"
             + (f" moved {p['shifted']}" if p.get("shifted") else "") + (" NO DRY SPOT" if p.get("no_dry_spot") else "")
             + f"; nearest starts: {near(p)}" for p in res["placed"]]
    json.dump(res["placed"], open(os.path.join(a.dir, "placed.json"), "w"), indent=1)
    print("cleared", res["cleared"], "natural resource entities; placed", len(short), "patches")
    for line in short:
        print("  ", line)
    t0 = time.time()
    for p in PLANETS:
        for t in lay["teams"]:
            x, y = t["spawns"][p]
            op.call("mt_generate", {"surface": p, "position": [x, y], "radius": a.planet_chunks})
    times["generate planets"] = time.time() - t0
    print("times (s):", json.dumps({k: round(v, 1) for k, v in times.items()}))


def cmd_assign(a):
    res, _ = op_from(a).call("mt_assign", {"player": a.player, "team": a.team})
    print(json.dumps(res))


def cmd_report(a):
    lay = json.load(open(os.path.join(a.dir, "layout.json")))
    op = op_from(a)
    out = {}
    out["check"], _ = op.call("mt_check", {})
    sites = [{"name": s["name"], "x": s["x"], "y": s["y"], "r": 90 if s["kind"] == "second" else 110, "nest_r": 150} for s in lay["sites"]]
    out["survey nauvis"], _ = op.call("mt_survey", {"surface": "nauvis", "radius": 200, "nest_radius": 600, "sites": sites})
    for p in PLANETS:
        out["survey " + p], _ = op.call("mt_survey", {"surface": p, "radius": 150, "nest_radius": 400})
    if a.corridor:
        for m in a.margins:
            out[f"corridor {m}"], _ = op.call("mt_corridor", {"surface": "nauvis", "nest_margin": m, "margin": 300})
    print(json.dumps(out, indent=1))


MAC_APP = "/Users/owner/code/factorio-mac-2.0.77/factorio.app"
MT_DIR = "/Users/owner/pog-mt"  # the iMac server's folder (tools/mt/imac_mt.sh)


def ssh(host, cmd, check=True):
    r = subprocess.run(["ssh", "-o", "ConnectTimeout=10", "-o", "BatchMode=yes", host, cmd], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise SystemExit(f"ssh {host}: {cmd[:120]}: {r.stderr.strip()[:400]}")
    return r.stdout


def client_usage(host, pid):
    """RSS (MB) and CPU % of the client process, and the GPU's VRAM in use (MB, the AMD driver's PerformanceStatistics inUseVidMemoryBytes)."""
    ps = ssh(host, f"ps -o rss=,%cpu= -p {pid}", check=False).split()
    vram = ssh(host, "ioreg -r -d 1 -w 0 -c IOAccelerator | grep -o '\"inUseVidMemoryBytes\"=[0-9]*' | head -1", check=False)
    v = int(vram.split("=")[1]) // 2**20 if "=" in vram else None
    return {"rss_mb": int(ps[0]) // 1024 if ps else None, "cpu_pct": float(ps[1]) if len(ps) > 1 else None, "vram_used_mb": v}


def start_client(a, name):
    """One join's client on the iMac: its own write-data folder (config, the server's mods, player-data with the name),
    medium sprites, low video memory, no audio, connecting to the mt server there; started in the GUI session with
    `open -n -a` (ssh alone gets no window). Returns its PID, found by its own config path (pgrep -lf, then read)."""
    d = f"{a.mt_dir}/clients/{name}"
    cfg = (f"[path]\nread-data=__PATH__system-read-data__\nwrite-data={d}\n[other]\ncheck-updates=false\n"
           "show-tips-and-tricks=false\n[sound]\nmaster-muted=true\nmusic-volume=0\n[graphics]\nfull-screen=false\n"
           "graphics-quality=medium\nvideo-memory-usage=low\ntexture-streaming=true\n")
    ssh(a.client_host, f"mkdir -p '{d}/config' && rm -rf '{d}/mods' && cp -R '{a.mt_dir}/mods' '{d}/mods' && "
                       f"printf '{cfg}' > '{d}/config/config.ini' && printf '{{\"service-username\": \"{name}\"}}' > '{d}/player-data.json'")
    ssh(a.client_host, f"open -n -a '{a.client_app}' --args --config '{d}/config/config.ini' --mp-connect 127.0.0.1:{a.game_port} --disable-audio")
    for _ in range(20):
        rows = ssh(a.client_host, f"pgrep -lf '{d}/config/config.ini'", check=False).strip().splitlines()
        rows = [r for r in rows if "factorio" in r and f"{d}/config/config.ini" in r]
        if rows:
            return int(rows[0].split()[0])
        time.sleep(1)
    raise SystemExit(f"{name}: no client process found")


def stop_client(a, pid):
    """The client this started, by its PID: SIGTERM, then SIGKILL after 20 s."""
    ssh(a.client_host, f"kill {pid}", check=False)
    for _ in range(20):
        if ssh(a.client_host, f"kill -0 {pid} 2>/dev/null && echo up", check=False).strip() != "up":
            return
        time.sleep(1)
    ssh(a.client_host, f"kill -9 {pid}", check=False)


def cmd_join(a):
    """Per team, one client at a time: a client on the iMac joins the mt server as mt-TEAM, is moved into its force as
    a spectator (mt_assign), and quits. Prints the time to join and the client's RSS, CPU and the GPU's VRAM in use."""
    lay = json.load(open(os.path.join(a.dir, "layout.json")))
    op = op_from(a)
    base = client_usage(a.client_host, 1)
    print("before: VRAM in use", base["vram_used_mb"], "MB")
    for t in lay["teams"]:
        if a.team and t["name"] != a.team:
            continue
        name = "mt-" + t["name"]
        t0 = time.time()
        pid = start_client(a, name)
        joined, peak = False, None
        while time.time() - t0 < a.join_timeout:
            out = op.lua(f"/silent-command local p=game.get_player('{name}') rcon.print(p and p.connected and 'yes' or 'no')")
            u = client_usage(a.client_host, pid)
            if u["rss_mb"] and (not peak or u["rss_mb"] > peak["rss_mb"]):
                peak = u
            if out.strip() == "yes":
                joined = True
                break
            if u["rss_mb"] is None:
                break
            time.sleep(2)
        took = time.time() - t0
        if joined:
            res, _ = op.call("mt_assign", {"player": name, "team": t["name"]})
            now = client_usage(a.client_host, pid)
            print(f"{name}: joined after {took:.0f} s (pid {pid}); peak {json.dumps(peak)}; at join {json.dumps(now)};", json.dumps(res))
        else:
            print(f"{name}: no join within {took:.0f} s (pid {pid}); see {a.mt_dir}/clients/{name}/factorio-current.log")
        if not a.keep:
            stop_client(a, pid)
            print(f"{name}: client {pid} stopped")
        if not joined:
            break


def cmd_chart_test(a):
    """Per team: a radar and an electric-energy-interface (test entities) at its spawn; after --seconds of game time,
    the chunks the force charted round it; then both removed."""
    lay = json.load(open(os.path.join(a.dir, "layout.json")))
    op = op_from(a)
    for t in lay["teams"]:
        x, y = t["spawns"]["nauvis"]
        op.lua(f"/silent-command local s=game.surfaces.nauvis s.create_entity{{name='radar',position={{{x + 20},{y + 20}}},force='{t['name']}'}} "
               f"s.create_entity{{name='electric-energy-interface',position={{{x + 23},{y + 20}}},force='{t['name']}'}} "
               f"s.create_entity{{name='medium-electric-pole',position={{{x + 21.5},{y + 22.5}}},force='{t['name']}'}}")
    op.lua("/silent-command game.tick_paused=false")
    t0 = time.time()
    tick0 = int(op.lua("/silent-command rcon.print(game.tick)"))
    while int(op.lua("/silent-command rcon.print(game.tick)")) - tick0 < a.seconds * 60:
        time.sleep(2)
    res, _ = op.call("mt_check", {"chunks": 5})
    for row in res["teams"]:
        print(f"{row['team']}: players {row['players']}, charted round spawn {row['charted_round_spawn']}")
    print(f"({a.seconds} s of game time in {time.time() - t0:.0f} s)")
    for t in lay["teams"]:
        x, y = t["spawns"]["nauvis"]
        op.lua(f"/silent-command for _,e in ipairs(game.surfaces.nauvis.find_entities_filtered{{area={{{{{x + 15},{y + 15}}},{{{x + 30},{y + 30}}}}},"
               f"name={{'radar','electric-energy-interface','medium-electric-pole'}},force='{t['name']}'}}) do e.destroy() end")


def cmd_contacts(a):
    res, _ = op_from(a).call("mt_contacts", {})
    print(json.dumps(res, indent=1))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("layout", "create", "setup", "assign", "join", "chart-test", "report", "contacts"):
        p = sub.add_parser(name)
        p.add_argument("--teams", type=int, default=4)
        p.add_argument("--distance", type=float, default=DISTANCE)
        p.add_argument("--planet-ring", type=float, default=PLANET_RING)
        p.add_argument("--dir")
        p.add_argument("--seed", type=int, default=274274)
        p.add_argument("--docker")
        p.add_argument("--host", default="127.0.0.1")
        p.add_argument("--port", type=int, default=27274)
        p.add_argument("--password-file")
        p.add_argument("--player")
        p.add_argument("--team")
        p.add_argument("--planet-chunks", type=int, default=4)
        p.add_argument("--corridor", action="store_true")
        p.add_argument("--margins", type=int, nargs="*", default=[64, 96, 128])
        p.add_argument("--enemy-frequency", type=float, default=ENEMY[0])
        p.add_argument("--enemy-size", type=float, default=ENEMY[1])
        p.add_argument("--client-app", default=MAC_APP)
        p.add_argument("--client-host", default="imac.local")
        p.add_argument("--mt-dir", default=MT_DIR)
        p.add_argument("--keep", action="store_true", help="join: leave the client running")
        p.add_argument("--game-port", type=int, default=34475)
        p.add_argument("--join-timeout", type=int, default=240)
        p.add_argument("--seconds", type=int, default=60)
    a = ap.parse_args()
    {"layout": cmd_layout, "create": cmd_create, "setup": cmd_setup, "assign": cmd_assign, "join": cmd_join,
     "chart-test": cmd_chart_test, "report": cmd_report, "contacts": cmd_contacts}[a.cmd](a)


if __name__ == "__main__":
    main()
