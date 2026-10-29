"""The operator inbox: agents' `operator {text}` requests (tells.lua, operator read `operator_requests`), appended by the
stream service to runs/RUN/operator-inbox.jsonl as {t, seq, agent, text}. live.py polls the read with the board reads;
a restarted service resumes after the last seq already in the file, and a new shift (runs/RUN/resumed-from) after the
last seq of the shifts before it, so nothing is written twice. The game keeps every request in the save, with its seq.
(d28 batch323 DR) Every inbox writer appends through write_rows (flushed and fsynced) and by id or seq, so a retry
writes a row once."""
import json
import os
import time

NAME = "operator-inbox.jsonl"


def path_for(run_dir):
    return os.path.join(run_dir, NAME) if run_dir else None


def last_seq(path):
    """The highest seq in the file (0 when there is none)."""
    seq = 0
    try:
        with open(path) as f:
            for line in f:
                try:
                    seq = max(seq, int(json.loads(line).get("seq") or 0))
                except (ValueError, AttributeError):
                    continue
    except OSError:
        pass
    return seq


def start_seq(path):
    """Where the service starts reading: the file's last seq; for a file without requests (a new shift), the last seq
    of the shift it resumed from (runs/RUN/resumed-from), and so on back (shift03 to 05 each wrote the earlier shifts'
    requests again: a new folder started at 0 and the save still holds them all)."""
    seen = set()
    while path and path not in seen:
        seen.add(path)
        seq = last_seq(path)
        if seq:
            return seq
        run_dir = os.path.dirname(path)
        try:
            with open(os.path.join(run_dir, "resumed-from")) as f:
                parent = f.read().strip()
        except OSError:
            return 0
        if not parent or os.sep in parent or parent in (".", ".."):
            return 0
        path = os.path.join(os.path.dirname(run_dir), parent, NAME)
    return 0


def write_rows(path, rows):
    """(d28 batch323 DR, viewer Aurora 16:19: "Could delivery receipts require a successful durable inbox write?") Append
    JSON rows to a JSONL file durably: one write of whole lines, then fsync; an OSError on any failure, and the caller
    reports nothing delivered. A file whose last line was cut off (a failed write before) gets its newline first, so
    the cut line spoils no other."""
    data = "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows).encode()
    if not data:
        return
    fd = os.open(path, os.O_RDWR | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        end = os.lseek(fd, 0, os.SEEK_END)
        if end and os.pread(fd, 1, end - 1) != b"\n":
            data = b"\n" + data
        view = memoryview(data)
        while view:
            n = os.write(fd, view)
            view = view[n:]
        os.fsync(fd)
    finally:
        os.close(fd)


def values_in(path, key):
    """(batch323) The set of row[key] values in a JSONL file (empty when there is none): what a retry by id finds."""
    out = set()
    try:
        with open(path, errors="replace") as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if isinstance(r, dict) and r.get(key) is not None:
                    out.add(r[key])
    except OSError:
        pass
    return out


def tail_keys(path, n):
    """(batch323) key_of of the last n rows of a file (a cut last line is skipped)."""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 65536))
            lines = f.read().decode(errors="replace").splitlines()[-n:]
    except OSError:
        return set()
    out = set()
    for line in lines:
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if isinstance(r, dict):
            out.add(key_of(r))
    return out


def key_of(r):
    return (r.get("seq"), r.get("tick"), r.get("agent"), r.get("text"))


def append(path, requests, since, now=None):
    """Append the requests after `since` ({seq, tick, from, text} from the read); returns the rows written."""
    rows = []
    for r in requests or []:
        if not isinstance(r, dict) or int(r.get("seq") or 0) <= since:
            continue
        rows.append({"t": round(now if now is not None else time.time(), 1), "seq": int(r["seq"]), "agent": r.get("from"),
                     "text": r.get("text", ""), "tick": r.get("tick")})
    if rows and path:
        # (batch323) durable, and once: a failed write is retried by the caller with the same requests (the cursor did
        # not move), and whatever of it landed is at the file's end: those rows are not written again
        write_rows(path, [r for r in rows if key_of(r) not in tail_keys(path, len(rows) + 1)])
    return rows
