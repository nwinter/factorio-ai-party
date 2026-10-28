#!/usr/bin/env python3
"""The camera test's samplers (d27 batch285 A): python3 tools/test_cam_sample.py

1. cam_sample ticks: one read a second at the due times, ticks_s from the previous row, an ALARM under the stop rule.
2. cam_sample latency: a client log's latency, join and leave lines at UTC (header local time minus the offset).
3. cam_sample merge: one row per tick second with the box, each process and each client's latency in effect.
4. tools/win/cam-sample.ps1 reads only: it writes its own two CSVs and stops, kills or removes nothing.
No network and no clock: a fake RCON and a fake clock.
"""
import csv, io, os, re, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import cam_sample as C  # noqa: E402


class FakeRcon:
    def __init__(self, clock, rates):
        self.clock, self.rates, self.cmds = clock, rates, []

    def command(self, cmd):
        self.cmds.append(cmd)
        t = self.clock.t - 1000.0
        tick, s = 5000, 0
        for r in self.rates:  # ticks gained in each whole second so far
            if s >= t:
                break
            tick += r * min(1, t - s)
            s += 1
        return f"{int(tick)}\n"


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t

    def sleep(self, d):
        self.t += d


def ticks():
    clock = Clock()
    rcon = FakeRcon(clock, [60, 60, 30, 60])
    buf, said = io.StringIO(), []
    C.ticks(rcon, 4, csv.writer(buf), alarm=40, clock=clock, sleep=clock.sleep, say=said.append)
    rows = list(csv.DictReader(io.StringIO(buf.getvalue())))
    assert [r["ticks_s"] for r in rows] == ["", "60.0", "60.0", "30.0", "60.0"], rows
    assert rows[0]["utc"] == "1970-01-01T00:16:40Z" and rows[4]["utc"] == "1970-01-01T00:16:44Z", rows
    assert rcon.cmds == ["/silent-command rcon.print(game.tick)"] * 5
    assert len(said) == 1 and said[0].startswith("ALARM 1970-01-01T00:16:43Z: 30.0 ticks/s"), said
    print("1. ticks: one read a second, the rate, the stop-rule alarm: ok")


LOG = """   0.001 2026-10-27 14:21:29; Factorio 2.0.77 (build 84539, win64, full, space-age)
   0.030 System info: [CPU: x, RAM: 28420/32597 MB]
  54.965 Info ClientMultiplayerManager.cpp:608: UpdateTick(73109133) changing state from(WaitingForCommandToStartSendingTickClosures) to(InGame)
  64.351 Info ClientSynchronizer.cpp:319: Latency changed to (14)
 560.717 Info GameActionHandler.cpp:4560: UpdateTick (73138601) processed PlayerJoinGame peerID(2) playerIndex(1) mode(connect)
 540.995 Info ClientSynchronizer.cpp:319: Latency changed to (199)
2076.966 Info ClientMultiplayerManager.cpp:874: Disconnect notification for peer (2)
"""


def latency():
    d = tempfile.mkdtemp()
    os.makedirs(os.path.join(d, "n-client-cam1"))
    p = os.path.join(d, "n-client-cam1", "factorio-current.log")
    open(p, "w").write(LOG)
    rows = C.latency_rows(p, -8)
    assert rows == [
        ("2026-10-27T22:22:23Z", "n-client-cam1", "in_game", "InGame"),
        ("2026-10-27T22:22:33Z", "n-client-cam1", "latency", "14"),
        ("2026-10-27T22:30:49Z", "n-client-cam1", "peer_joined", "2"),
        ("2026-10-27T22:30:29Z", "n-client-cam1", "latency", "199"),
        ("2026-10-27T22:56:05Z", "n-client-cam1", "peer_left", "2"),
    ], rows
    print("2. latency: client log lines at UTC: ok")


def merge():
    t = [{"utc": u, "ticks_s": s, "read_ms": "5"} for u, s in (("A1", ""), ("A2", "60.0"), ("A3", "41.0"))]
    box = [{"utc": "A2", "local": "x", "available_mb": "700", "pages_in_s": "201"}]
    proc = [{"utc": "A2", "process": "factorio", "pid": "1", "ws_mb": "1400", "private_mb": "1800", "faults_s": "9",
             "cpu_pct": "60", "gpu_dedicated_mb": "0", "gpu_shared_mb": "0", "gpu_3d_pct": "0"}]
    lat = [("A2", "n-client-cam1", "latency", "14"), ("A2", "n-client-cam1", "peer_left", "2"),
           ("A3", "n-client-cam1", "latency", "60")]
    rows = C.merge(t, box, proc, lat)
    assert [r["n-client-cam1_latency"] for r in rows] == ["", 14, 60], rows
    assert rows[1]["available_mb"] == "700" and rows[0]["available_mb"] == "" and rows[1]["factorio_ws_mb"] == "1400"
    assert "local" not in rows[0] and rows[2]["ticks_s"] == "41.0"
    print("3. merge: one row a second with the box, processes and latency: ok")


def ps1_reads_only():
    src = open(os.path.join(HERE, "win", "cam-sample.ps1")).read()
    code = "\n".join(l for l in src.splitlines() if not l.lstrip().startswith("#"))
    for verb in ("Stop-Process", "Remove-Item", "Stop-Service", "taskkill", "Set-ItemProperty", "Restart-", "Start-Process"):
        assert verb.lower() not in code.lower(), verb
    writes = [m.group(0) for m in re.finditer(r"(Set-Content|Add-Content|Out-File|New-Item)[^\n]*", code)]
    assert writes and all(re.search(r"\$(boxOut|procOut|Dir)\b", w) for w in writes), writes
    assert "-SampleInterval 1 -MaxSamples $Seconds" in code
    print("4. cam-sample.ps1 writes only its two CSVs: ok")


def main():
    ticks()
    latency()
    merge()
    ps1_reads_only()
    print("test_cam_sample: ok")


if __name__ == "__main__":
    main()
