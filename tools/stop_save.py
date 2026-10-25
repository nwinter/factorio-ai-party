#!/usr/bin/env python3
"""Save a team world under its run's own name and record the stop: tools/stop_save.py --world n --run RUN [--run-dir DIR]

/server-save writes the save the server loaded. After a crash restart that was shift12r.zip, so saves\\shift12.zip kept
its 10:48 state and the 15:55 shift change resumed from it, 3 game hours back (operator 17:00). On 2.0.77
game.server_save(NAME) writes saves\\NAME.zip whatever save is loaded (checked on a private headless server, paused
too; /save NAME also works but fails while another save is being written). So the run's save is always its last state.

The world is paused first by stop-team, so the tick printed with the save is the save's tick. Waits until the file is
written (its time on the Windows box at or after the stop, its size steady) and writes RUN_DIR/stopped.json:
{run, world, tick, stop_utc (the Windows box's clock just before the save), save, save_utc, save_bytes, via, note?}.
tools/start-team.sh passes stop_utc and save to tools/win/resume-save.ps1 and checks the tick it resumes at.
When the named save does not appear, it falls back to /server-save (the old way) and says so in via and note; the next
shift then takes the newest save written after stop_utc.

  tools/stop_save.py --failed --world n --run RUN [--run-dir DIR]   (tools/stop-team.sh, when no save went through)
(d24 batch175 QR2) Neither this nor stop-team's /server-save went through (RCON down, the server hung): before, the world
was stopped unsaved and the next shift took the newest autosave, up to 18 game minutes older, without a word, and the
agents' board items, tells, reminders and watch results of those minutes were gone. This writes a stop record with no
save (via "failed", stop_utc by the Mac's clock a minute back), so tools/win/resume-save.ps1 takes only a save written
after it, and exits 3; stop-team then leaves the world running and exits 3, and tools/shift-change.sh starts no next
shift. A record of an earlier stop of this run that saved (a stop run again, its world already down) is kept: exit 0.
"""
import argparse
import base64
import datetime
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

FMT = "%Y-%m-%dT%H:%M:%S.%fZ"


def ps(command, host=None):
    """Runs one PowerShell command on the Windows box; its output, stripped."""
    host = host or os.environ.get("POG_WIN_HOST", "pogwin")
    enc = base64.b64encode(command.encode("utf-16-le")).decode()
    out = subprocess.run(["ssh", host, f"powershell -NoProfile -EncodedCommand {enc}"], capture_output=True, text=True,
                         timeout=60)
    return "\n".join(l for l in out.stdout.splitlines() if l.strip() and not l.startswith("** ")).strip()


def win_now():
    """The Windows box's UTC clock (the saves' times are on it), as stop_utc."""
    out = ps("[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')")
    return datetime.datetime.strptime(out.splitlines()[-1].strip()[:-1] + "000Z", FMT)


def save_info(world, name):
    """(utc, bytes) of saves\\NAME.zip on the Windows box, or None."""
    out = ps(f"$f = Get-Item 'D:\\pog\\inst\\{world}\\saves\\{name}.zip' -ErrorAction SilentlyContinue; "
             "if ($f) { $f.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ') + '|' + $f.Length } else { 'missing' }")
    line = out.splitlines()[-1].strip() if out else "missing"
    if line == "missing" or "|" not in line:
        return None
    t, n = line.split("|", 1)
    return datetime.datetime.strptime(t[:-1] + "000Z", FMT), int(n)


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}Z"


def stop_save(rcon, run, world, now=win_now, info=save_info, sleep=time.sleep, wait_s=120):
    """Saves under the run's name and returns the stop record (see the module doc). rcon: .command(str) -> str."""
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", run):
        raise SystemExit(f"run name {run!r}: letters, digits, _ . - only")
    try:
        t0, clock = now(), "windows"
    except Exception as e:  # noqa: BLE001 (the box's clock unreadable: the Mac's, a minute back for skew)
        t0 = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) - datetime.timedelta(minutes=1)
        clock = f"mac ({e})"
    rec = {"run": run, "world": world, "stop_utc": iso(t0), "clock": clock, "save": None}
    out = rcon.command(f"/silent-command game.server_save('{run}') rcon.print('tick ' .. game.tick)") or ""
    m = re.search(r"tick (\d+)", out)
    rec["tick"] = int(m.group(1)) if m else None
    if not m:
        rec["note"] = f"game.server_save gave no tick: {out.strip()[:200]}"
    last, waited, sent = None, 0, 1
    while m and waited <= wait_s:
        got = info(world, run)
        if got and got[0] >= t0 and last and got == last:
            rec.update(save=f"{run}.zip", save_utc=iso(got[0]), save_bytes=got[1], via="game.server_save")
            if sent > 1:
                rec["note"] = "game.server_save sent twice (the first wrote nothing within 30 s: another save running?)"
            return rec
        last = got if got and got[0] >= t0 else None
        # (a save asked for while another one is written fails: on 2.0.77 /save NAME said "Failed to save the map"
        # right after another save; once more after 30 s)
        if not last and waited >= 30 and sent == 1:
            rcon.command(f"/silent-command game.server_save('{run}')")
            sent = 2
        sleep(2)
        waited += 2
    # The named save did not appear: the old way, into the loaded save.
    rcon.command("/server-save")
    rec["via"] = "server-save"
    rec["note"] = (rec.get("note", "") + f"; {run}.zip not written within {wait_s} s: /server-save into the loaded save"
                   ).lstrip("; ")
    return rec


def failed_record(run_dir, run, world, now=None):
    """(record, kept): an earlier stop's record that saved (kept True), else a new one with no save, written."""
    path = os.path.join(run_dir, "stopped.json")
    try:
        old = json.load(open(path))
    except (OSError, ValueError):
        old = None
    if isinstance(old, dict) and (old.get("save") or old.get("via") == "server-save") and isinstance(old.get("tick"), int):
        return old, True
    t0 = (now or datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)) - datetime.timedelta(minutes=1)
    rec = {"run": run, "world": world, "stop_utc": iso(t0), "clock": "mac", "save": None, "tick": None, "via": "failed",
           "note": "neither game.server_save nor /server-save went through: no save of this stop; the world was left running"}
    os.makedirs(run_dir, exist_ok=True)
    with open(path, "w") as f:
        json.dump(rec, f, indent=1)
        f.write("\n")
    return rec, False


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--world", default="n")
    ap.add_argument("--run", required=True)
    ap.add_argument("--run-dir")
    ap.add_argument("--failed", action="store_true")
    a = ap.parse_args()
    if a.failed:
        rec, kept = failed_record(a.run_dir or os.path.join(os.path.dirname(HERE), "runs", a.run), a.run, a.world)
        print(("an earlier stop's record stands: " if kept else "no save: ") + json.dumps(rec))
        sys.exit(0 if kept else 3)
    import pog
    pw = open(os.path.expanduser(f"~/.config/pog/rcon-{a.world}.pw")).read().strip()
    rcon = pog.Rcon("127.0.0.1", pog.PORTS[a.world], pw)
    rec = stop_save(rcon, a.run, a.world)
    run_dir = a.run_dir or os.path.join(os.path.dirname(HERE), "runs", a.run)
    os.makedirs(run_dir, exist_ok=True)
    with open(os.path.join(run_dir, "stopped.json"), "w") as f:
        json.dump(rec, f, indent=1)
        f.write("\n")
    print(json.dumps(rec))
    # (a fallback to /server-save is not a failure: it saved; an exception, RCON down say, exits nonzero and stop-team
    # tries /server-save itself)


if __name__ == "__main__":
    main()
