#!/usr/bin/env python3
"""A camera test's Mac side (d27 batch285 A: three camera clients slowed world n while pogwin's RAM was full).
Read only: one game.tick read a second; it never starts or stops a client.

  python3 tools/cam_sample.py ticks --world n --seconds 1920 --out ticks.csv
      game.tick once a second (one /silent-command, well under 1 ms in the game). Rows: utc, tick, ticks_s (since the
      previous row), read_ms (the RCON round trip). A second under --alarm ticks/s (default 40) prints an ALARM line:
      the test's stop rule.
  python3 tools/cam_sample.py latency LOG... --out latency.csv [--utc-offset -8]
      each client log's "Latency changed to (N)" lines (the client's latency window, in ticks) and its joins and
      disconnects. A log's times are its header's local time plus the line's seconds; --utc-offset is pogwin's clock
      against UTC (-8: it reads PST all year, an hour behind PDT, d27). Rows: utc, client, event, value.
  python3 tools/cam_sample.py merge --ticks T.csv --box B.csv [--proc P.csv] [--latency L.csv] --out merged.csv
      one row per UTC second: ticks_s, the box's columns (tools/win/cam-sample.ps1), each process's working set,
      faults and GPU memory (columns NAME_ws_mb ...), and each client's latency in effect that second.
"""
import argparse, csv, datetime as dt, os, re, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

UTC = dt.timezone.utc
HEADER = re.compile(r"^\s*[\d.]+ (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d); Factorio")
LINE = re.compile(r"^\s*([\d.]+) (.*)$")
EVENTS = [
    (re.compile(r"Latency changed to \((\d+)\)"), "latency"),
    (re.compile(r"changing state from\(\w+\) to\((InGame)\)"), "in_game"),
    (re.compile(r"Disconnect notification for peer \((\d+)\)"), "peer_left"),
    (re.compile(r"processed PlayerJoinGame peerID\((\d+)\)"), "peer_joined"),
]


def utc_text(t):
    return dt.datetime.fromtimestamp(t, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def ticks(rcon, seconds, out, alarm=40.0, clock=time.time, sleep=time.sleep, say=print):
    """One game.tick read a second for `seconds` s, appended to `out` (a CSV writer) as it goes."""
    out.writerow(["utc", "tick", "ticks_s", "read_ms"])
    prev = None
    start = clock()
    for i in range(seconds + 1):
        due = start + i
        if clock() < due:
            sleep(due - clock())
        t0 = clock()
        tick = int(str(rcon.command("/silent-command rcon.print(game.tick)")).strip())
        t1 = clock()
        rate = "" if prev is None else round((tick - prev[1]) / (t0 - prev[0]), 1)
        out.writerow([utc_text(t0), tick, rate, round(1000 * (t1 - t0))])
        if rate != "" and rate < alarm:
            say(f"ALARM {utc_text(t0)}: {rate} ticks/s (under {alarm:g})")
        prev = (t0, tick)


def latency_rows(path, utc_offset):
    """(utc, client, event, value) from one Factorio client log; client is the instance folder (n-client-cam1)."""
    client = os.path.basename(os.path.dirname(os.path.abspath(path))) or path
    rows, base = [], None
    for line in open(path, errors="replace"):
        if base is None:
            m = HEADER.match(line)
            if m:
                local = dt.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
                base = (local - dt.timedelta(hours=utc_offset)).replace(tzinfo=UTC).timestamp()
            continue
        m = LINE.match(line)
        if not m:
            continue
        for rx, event in EVENTS:
            e = rx.search(m.group(2))
            if e:
                rows.append((utc_text(base + float(m.group(1))), client, event, e.group(1)))
                break
    return rows


def read_csv(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def merge(ticks_rows, box_rows, proc_rows=(), latency=()):
    """One dict per UTC second present in the ticks file, with the other files' values for that second."""
    box = {r["utc"]: r for r in box_rows}
    procs = {}
    for r in proc_rows:
        procs.setdefault(r["utc"], {})[r["process"]] = r
    names = sorted({r["process"] for r in proc_rows})
    clients = sorted({c for _, c, e, _ in latency if e == "latency"})
    lat = sorted((u, c, int(v)) for u, c, e, v in latency if e == "latency")
    box_cols = [k for k in (box_rows[0].keys() if box_rows else []) if k not in ("utc", "local")]
    out, current, j = [], {}, 0
    for r in ticks_rows:
        u = r["utc"]
        while j < len(lat) and lat[j][0] <= u:
            current[lat[j][1]] = lat[j][2]
            j += 1
        row = {"utc": u, "ticks_s": r["ticks_s"], "read_ms": r["read_ms"]}
        b = box.get(u, {})
        for k in box_cols:
            row[k] = b.get(k, "")
        p = procs.get(u, {})
        for n in names:
            for k in ("ws_mb", "private_mb", "faults_s", "gpu_dedicated_mb", "gpu_shared_mb"):
                row[f"{n}_{k}"] = p.get(n, {}).get(k, "")
        for c in clients:
            row[f"{c}_latency"] = current.get(c, "")
        out.append(row)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("ticks")
    t.add_argument("--world", default="n")
    t.add_argument("--seconds", type=int, default=1920)
    t.add_argument("--alarm", type=float, default=40)
    t.add_argument("--out", required=True)
    la = sub.add_parser("latency")
    la.add_argument("logs", nargs="+")
    la.add_argument("--utc-offset", type=float, default=-8)
    la.add_argument("--out", required=True)
    m = sub.add_parser("merge")
    for k in ("ticks", "box", "out"):
        m.add_argument(f"--{k}", required=True)
    m.add_argument("--proc")
    m.add_argument("--latency")
    a = ap.parse_args()
    if a.cmd == "ticks":
        import pog
        pw = open(os.path.expanduser(f"~/.config/pog/rcon-{a.world}.pw")).read().strip()
        rcon = pog.Rcon(getattr(pog, "HOSTS", {}).get(a.world, "127.0.0.1"), pog.PORTS[a.world], pw, timeout=10)
        with open(a.out, "w", newline="", buffering=1) as f:
            ticks(rcon, a.seconds, csv.writer(f), a.alarm)
    elif a.cmd == "latency":
        with open(a.out, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["utc", "client", "event", "value"])
            for p in a.logs:
                w.writerows(latency_rows(p, a.utc_offset))
    else:
        lat = [(r["utc"], r["client"], r["event"], r["value"]) for r in read_csv(a.latency)] if a.latency else []
        rows = merge(read_csv(a.ticks), read_csv(a.box), read_csv(a.proc) if a.proc else [], lat)
        with open(a.out, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()) if rows else ["utc"])
            w.writeheader()
            w.writerows(rows)
        print(f"{len(rows)} seconds -> {a.out}")


if __name__ == "__main__":
    main()
