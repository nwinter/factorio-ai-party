"""The operator inbox: agents' `operator {text}` requests (tells.lua, operator read `operator_requests`), appended by the
stream service to runs/RUN/operator-inbox.jsonl as {t, seq, agent, text}. live.py polls the read with the board reads;
a restarted service resumes after the last seq already in the file, and a new shift (runs/RUN/resumed-from) after the
last seq of the shifts before it, so nothing is written twice. The game keeps every request in the save, with its seq."""
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


def append(path, requests, since, now=None):
    """Append the requests after `since` ({seq, tick, from, text} from the read); returns the rows written."""
    rows = []
    for r in requests or []:
        if not isinstance(r, dict) or int(r.get("seq") or 0) <= since:
            continue
        rows.append({"t": round(now if now is not None else time.time(), 1), "seq": int(r["seq"]), "agent": r.get("from"),
                     "text": r.get("text", ""), "tick": r.get("tick")})
    if rows and path:
        with open(path, "a") as f:
            for row in rows:
                f.write(json.dumps(row) + "\n")
    return rows
