#!/usr/bin/env python3
"""(mt277, private: part F) The camera client of the iMac's mt server, which renders the agents' ./shot.

  tools/mt/imac_cam.py start          a client on the iMac joins the mt server as pog-cam1 (the harness takes the
                                      pog-cam names as directors: a spectator in the player force, its name hidden,
                                      out of the chat audience); waits for the join; prints its PID
  tools/mt/imac_cam.py stop           that client, by the PID start wrote on the iMac
  tools/mt/imac_cam.py status
  tools/mt/imac_cam.py sync RUN_ID [--tree DIR]   copy its screenshots into the agents' shots/ folders until stopped

A bot has no client of its own, so the screenshot action has the first connected director render the frame into that
client's script-output/pog/WS/; sync moves each file to TREE/runs/RUN/TEAM/WS/shots/, where ./shot waits for it (as
tools/shot-sync.sh does from pogwin). The client is mt_map.py's join client (its own write-data folder under the mt
server's clients/, medium sprites, low video memory, no audio): about 5 GB of RAM and 1.4 GB of video memory on the
iMac (mt275), and a window in the iMac's session.
"""
import argparse, glob, os, shlex, subprocess, sys, time, types

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "tools"))
import mt_map  # noqa: E402
import pog  # noqa: E402

HOST, NAME, GAME_PORT, WORLD = "imac.local", "pog-cam1", 34475, "imac2"
TREE = "/Users/owner/code/personal/player-of-games/worktrees/pog-p"
CLIENT_DIR = f"{mt_map.MT_DIR}/clients/{NAME}"
PID_FILE = f"{CLIENT_DIR}/pid"


def args():
    return types.SimpleNamespace(mt_dir=mt_map.MT_DIR, client_host=HOST, client_app=mt_map.MAC_APP, game_port=GAME_PORT)


def rcon():
    pw = open(os.path.expanduser(f"~/.config/pog/rcon-{WORLD}.pw")).read().strip()
    return pog.Rcon(pog.HOSTS[WORLD], pog.PORTS[WORLD], pw, timeout=10)


def connected(r):
    out = r.command(f"/silent-command local p=game.get_player('{NAME}') rcon.print(p and p.connected and 'yes' or 'no')")
    return out.strip() == "yes"


def running_pid():
    pid = mt_map.ssh(HOST, f"cat {shlex.quote(PID_FILE)} 2>/dev/null", check=False).strip()
    if not pid.isdigit():
        return None
    # the PID still this client's (its own config path in the command line), never another Factorio
    cmd = mt_map.ssh(HOST, f"ps -o command= -p {pid}", check=False)
    return int(pid) if f"{CLIENT_DIR}/config/config.ini" in cmd else None


def start(timeout=240):
    if running_pid():
        print(f"{NAME}: already running (pid {running_pid()})")
        return
    t0 = time.time()
    pid = mt_map.start_client(args(), NAME)
    mt_map.ssh(HOST, f"echo {pid} > {shlex.quote(PID_FILE)}")
    r = rcon()
    while time.time() - t0 < timeout:
        if connected(r):
            u = mt_map.client_usage(HOST, pid)
            print(f"{NAME}: joined after {time.time() - t0:.0f} s (pid {pid}); {u}")
            return
        if not running_pid():
            raise SystemExit(f"{NAME}: the client exited; see {CLIENT_DIR}/factorio-current.log on the iMac")
        time.sleep(2)
    raise SystemExit(f"{NAME}: no join within {timeout} s (pid {pid} left running; tools/mt/imac_cam.py stop)")


def stop():
    pid = running_pid()
    if not pid:
        print(f"{NAME}: not running")
        return
    mt_map.stop_client(args(), pid)
    mt_map.ssh(HOST, f"rm -f {shlex.quote(PID_FILE)}", check=False)
    print(f"{NAME}: stopped pid {pid}")


def workspace(rundir, ws):
    """The workspace named WS in a run in parts (RUN/TEAM/WS), or a one-part run (RUN/WS); None if none."""
    hits = [d for d in glob.glob(os.path.join(rundir, "*", ws)) + [os.path.join(rundir, ws)] if os.path.isfile(os.path.join(d, "shot"))]
    return hits[0] if len(hits) == 1 else None


def sync(run, tree, every=1.0, once=False):
    """Each screenshot listed on two passes in a row (Factorio writes it a tick after the request) is copied into its
    workspace's shots/ and removed from the client's folder."""
    rundir = os.path.join(tree, "runs", run)
    remote = f"{CLIENT_DIR}/script-output/pog"
    print(f"[cam-sync] {time.strftime('%H:%M:%S')} start: {rundir} <- {HOST}:{remote}", flush=True)
    prev, skipped = set(), set()
    while True:
        out = subprocess.run(["ssh", "-o", "ConnectTimeout=10", "-o", "BatchMode=yes", HOST,
                              f"find {shlex.quote(remote)} -name '*.png' -type f 2>/dev/null"], capture_output=True, text=True).stdout
        now = {l for l in out.splitlines() if l.endswith(".png")}
        for path in sorted(now & prev):
            ws = os.path.basename(os.path.dirname(path))
            d = workspace(rundir, ws)
            if not d:
                if path not in skipped:
                    print(f"[cam-sync] {time.strftime('%H:%M:%S')} {path}: no workspace {ws} in {rundir}", flush=True)
                    skipped.add(path)
                continue
            os.makedirs(os.path.join(d, "shots"), exist_ok=True)
            dest = os.path.join(d, "shots", os.path.basename(path))
            if subprocess.run(["scp", "-q", "-o", "BatchMode=yes", f"{HOST}:{path}", dest + ".part"]).returncode == 0:
                os.replace(dest + ".part", dest)
                mt_map.ssh(HOST, f"rm -f {shlex.quote(path)}", check=False)
                print(f"[cam-sync] {time.strftime('%H:%M:%S')} {ws}: {os.path.basename(path)}", flush=True)
        prev = now
        if once:
            return
        time.sleep(every)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["start", "stop", "status", "sync"])
    ap.add_argument("run", nargs="?")
    ap.add_argument("--tree", default=TREE)
    a = ap.parse_args()
    if a.cmd == "start":
        start()
    elif a.cmd == "stop":
        stop()
    elif a.cmd == "status":
        pid = running_pid()
        print(f"{NAME}: {'running, pid ' + str(pid) if pid else 'not running'}")
    else:
        if not a.run:
            raise SystemExit("sync RUN_ID")
        sync(a.run, a.tree)


if __name__ == "__main__":
    main()
