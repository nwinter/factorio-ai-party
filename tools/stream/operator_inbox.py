"""The operator inbox: agents' `operator {text}` requests (tells.lua, operator read `operator_requests`), appended by the
stream service to runs/RUN/operator-inbox.jsonl as {t, seq, agent, text}. live.py polls the read with the board reads;
a restarted service resumes after the last seq already in the file, so nothing is written twice."""
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
