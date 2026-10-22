#!/usr/bin/env python3
"""Kill a player's agy turn that grows past a memory cap: tools/agy_memguard.py [--cap-gb 4] [--every 3] [--log PATH]

d22 09:27 (Disk Space Scout): one agy turn of Gemini's (runs/shift57/gemini, pid 91272) grew about 12 GiB a minute
to 21 GiB and filled the Mac's swap. agy has no memory setting. The cause: agy runs `git ls-files --others
--exclude-standard` at a fresh session, and runs/ (645,583 untracked files) was not ignored (.gitignore has runs/
since d22). This watches every process descended from a run's loop, a "bash .../runs/RUN/NAME/.agy-loop.sh" ancestor
(agy and whatever it starts; only those: the owner's own agy sessions are left alone). When one's physical footprint
(resident plus compressed: top's MEM, proc_pid_rusage ri_phys_footprint) passes the cap, it sends TERM, then KILL
after --grace s. The loop goes on to its next turn as after a timeout. Each kill is logged (--log, else stdout) and
to the workspace's context.log (event agy-memguard), so the run analysis sees it.

One per Mac: the guard holds a lock file (--lock, default /tmp/pog-agy-memguard.lock, holding its pid and log); a
second one exits at once. tools/start-team.sh starts it when the team has an agy agent and leaves it running across
shifts. --check: exit 0 and say so when a guard runs (the lock, or a guard started by hand before the lock), else 1.
--once: one pass and exit (tests). --root DIR: only loops under DIR (tests: never the real players).
"""
import argparse, ctypes, fcntl, json, os, re, signal, subprocess, sys, time

LOCK = os.environ.get("POG_MEMGUARD_LOCK", "/tmp/pog-agy-memguard.lock")
LOOP_RE = re.compile(r"(?:\S*/)?bash\s+(/\S*/runs/[^/\s]+/[^/\s]+)/\.agy-loop\.sh\s*$")


def footprint(pid):
    """The process's physical footprint in bytes (top's MEM; rusage_info_v4.ri_phys_footprint, the field after
    ri_resident_size), or None. Resident size leaves out compressed memory, where agy's growth went (Disk Space Scout,
    16:28Z: 21 GiB footprint, 20 of it compressed)."""
    try:
        libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    except OSError:
        return None
    buf = ctypes.create_string_buffer(1024)
    if libc.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(4), ctypes.byref(buf)) != 0:
        return None
    return int.from_bytes(buf.raw[72:80], "little")


def table():
    """{pid: (ppid, rss bytes, command line)} of every process (ps)."""
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,rss=,command="], capture_output=True, text=True).stdout
    rows = {}
    for line in out.splitlines():
        m = re.match(r"\s*(\d+)\s+(\d+)\s+(\d+)\s+(.*)", line)
        if m:
            rows[int(m[1])] = (int(m[2]), int(m[3]) * 1024, m[4])
    return rows


def loop_of(pid, rows):
    """The workspace of the .agy-loop.sh this process descends from (the process itself is not a loop), or None. Only
    a command line that is the loop itself counts ("bash /…/runs/RUN/NAME/.agy-loop.sh"); the path as text in another
    command line (an editor, a grep) does not."""
    if pid in rows and LOOP_RE.match(rows[pid][2]):
        return None  # the loop (or its subshell): never killed
    seen = 0
    pid = rows[pid][0] if pid in rows else None
    while pid in rows and seen < 32:
        ppid, _, cmd = rows[pid]
        m = LOOP_RE.match(cmd)
        if m:
            return m[1]
        pid, seen = ppid, seen + 1
    return None


def over_cap(rows, cap, root=None, me=None, size=footprint):
    """[(pid, bytes, workspace)] of loop descendants whose footprint (else rss) passes cap bytes."""
    out = []
    for pid, (_, rss, _) in sorted(rows.items()):
        if pid == me:
            continue
        ws = loop_of(pid, rows)
        if not ws or (root and not os.path.realpath(ws).startswith(os.path.realpath(root) + os.sep)):
            continue
        fp = size(pid) or rss
        if fp > cap:
            out.append((pid, fp, ws))
    return out


def stop(pid, grace, say, kill=os.kill, sleep=time.sleep):
    """TERM, then KILL when it is still there after grace seconds. -> "TERM" or "KILL" (what ended it), None if gone."""
    try:
        kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return None
    for _ in range(max(1, int(grace / 0.25))):
        sleep(0.25)
        try:
            kill(pid, 0)
        except ProcessLookupError:
            return "TERM"
    try:
        kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        return "TERM"
    say(f"pid {pid}: KILL")
    return "KILL"


def guard_pass(cap_gb, grace, say, root=None, rows=None, size=footprint):
    cap = int(cap_gb * 2**30)
    for pid, fp, ws in over_cap(rows if rows is not None else table(), cap, root, os.getpid(), size):
        gb = fp / 2**30
        say(f"pid {pid} {gb:.1f} GiB > {cap_gb} GiB in {ws}: TERM")
        how = stop(pid, grace, say)
        try:
            with open(os.path.join(ws, "context.log"), "a") as f:
                f.write(json.dumps({"time": time.strftime("%Y-%m-%d %H:%M:%S"), "event": "agy-memguard", "pid": pid,
                                    "footprint_gb": round(gb, 1), "cap_gb": cap_gb, "ended_by": how}) + "\n")
        except OSError:
            pass


def running(lock=LOCK, rows=None):
    """(pid, log) of a guard running on this Mac, else None: the lock's holder, or a guard started by hand before the
    lock (its command line; not one with --check or --once)."""
    try:
        fd = os.open(lock, os.O_RDONLY)
    except OSError:
        fd = None
    if fd is not None:
        try:
            fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            rec = (os.read(fd, 4096).decode(errors="replace").split("\n", 1) + [""])[:2]
            os.close(fd)
            return (int(rec[0]) if rec[0].strip().isdigit() else None), rec[1].strip()
        os.close(fd)
    for pid, (_, _, cmd) in (rows if rows is not None else table()).items():
        if pid != os.getpid() and re.search(r"python\S*\s+\S*agy_memguard\.py", cmd, re.I) and \
                not re.search(r"\s--(check|once)\b", cmd):
            return pid, "(started by hand, no lock)"
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cap-gb", type=float, default=4.0)
    ap.add_argument("--every", type=float, default=3.0)
    ap.add_argument("--grace", type=float, default=5.0, help="seconds between TERM and KILL")
    ap.add_argument("--log", help="append the log here (start-team: runs/RUN/agy-memguard.log); else stdout")
    ap.add_argument("--lock", default=LOCK)
    ap.add_argument("--root", help="only loops under this directory")
    ap.add_argument("--once", action="store_true", help="one pass, no lock (tests)")
    ap.add_argument("--check", action="store_true", help="exit 0 when a guard runs on this Mac, else 1")
    a = ap.parse_args()
    if a.check:
        r = running(a.lock)
        print(f"agy memory guard running: pid {r[0]}, log {r[1] or '?'}" if r else "agy memory guard not running")
        sys.exit(0 if r else 1)
    out = open(a.log, "a") if a.log else sys.stdout

    def say(text):
        out.write(f"{time.strftime('%H:%M:%S')} {text}\n")
        out.flush()

    if a.once:
        guard_pass(a.cap_gb, a.grace, say, a.root)
        return
    fd = os.open(a.lock, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("agy memory guard already running (lock " + a.lock + ")")
        return
    os.ftruncate(fd, 0)
    os.write(fd, f"{os.getpid()}\n{os.path.abspath(a.log) if a.log else 'stdout'}\n".encode())
    say(f"agy_memguard: cap {a.cap_gb} GiB, every {a.every} s, pid {os.getpid()}")
    while True:
        try:
            guard_pass(a.cap_gb, a.grace, say, a.root)
        except Exception as e:  # noqa: BLE001  (one bad pass must not end the guard)
            say(f"pass failed: {e}")
        time.sleep(a.every)


if __name__ == "__main__":
    main()
