#!/usr/bin/env python3
"""Replay viewer lines through Clef with other criteria, and print where its verdict changes.

  python3 tools/stream/clef_replay.py [LOG ...] [--logs DIR] [--since DATE] [--until DATE] [--all | --sample N]
                                      [--criteria FILE | --criteria rev:REV] [--before REV] [--batch N] [--jobs N]
                                      [--cache FILE]
  python3 tools/stream/clef_replay.py --all --since 2026-10-11 --before main
  python3 tools/stream/clef_replay.py --record   (the calibration lines, after a change to CLEF_CRITERIA)

d17 batch35 U1 (operator 15:05: Clef refused 13 viewer lines as injection since 10:51, nearly all plain game advice);
d27 batch264 CC (Nick 06:45: calibrate the injection label against everything Clef checked).
LOGs are viewers.py verdict logs (tools/stream/logs/viewers-*.jsonl; default every one in --logs, default
tools/stream/logs). A line in two logs (a restart) counts once. The lines go to the real @cf/cloudflare/clef-flash
with the working tree's CLEF_CRITERIA, or --criteria (a JSON object of label to description, a .py file holding a
CLEF_CRITERIA block such as viewers.py, or rev:REV for viewers.py at a git revision). They are asked --batch lines a
call (default 1, as live chat reaches Clef a line or a few at a time: in 37-line batches Clef held 345 of 5911 lines
as injection, and a sample of 40 of those it held that way it called fine one at a time), --jobs calls at once.
--all replays every line Clef checked; without it, the lines it held and the first --sample (20) it passed. Each
verdict is compared with the label the log recorded and, with --before REV, with REV's criteria replayed now (the
model's own drift apart from the prompt). Verdicts are cached by criteria, batch size and line in --cache (default
tools/stream/logs/clef-replay-cache.jsonl), so a rerun or a review pays only for new lines. Clef bills input only,
$0.038 per million tokens: 507 tokens a line under the d27 criteria (Clef's count), so 6000 lines cost about 12 cents.
Prints every flip both ways (id, time, name, before, after, text) and the counts by label.
"""
import argparse, collections, concurrent.futures, datetime, glob, hashlib, json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import viewers as V  # noqa: E402

LOGS = os.path.join(HERE, "logs")


def criteria_block(src):
    i = src.index("CLEF_CRITERIA = {")
    j = src.index("\n}\n", i) + 3
    ns = {}
    exec(src[i:j], ns)
    return ns["CLEF_CRITERIA"]


def criteria_at(rev):
    src = subprocess.run(["git", "show", f"{rev}:tools/stream/viewers.py"], capture_output=True, text=True,
                         cwd=ROOT, check=True).stdout
    return criteria_block(src)


def criteria_from(spec):
    """None: the working tree's; rev:REV; a .json file ({label: description}); a .py file with a CLEF_CRITERIA block."""
    if not spec:
        return dict(V.CLEF_CRITERIA)
    if spec.startswith("rev:"):
        return criteria_at(spec[4:])
    text = open(spec).read()
    c = json.loads(text) if spec.endswith(".json") else criteria_block(text)
    if not isinstance(c, dict) or not c or not all(isinstance(k, str) and isinstance(v, str) for k, v in c.items()):
        raise SystemExit(f"{spec}: criteria are an object of label to description")
    return c


def criteria_hash(c):
    return hashlib.sha256(json.dumps(c, sort_keys=True).encode()).hexdigest()[:16]


def when(text):
    """A date or date and time (2026-10-20, 2026-10-20T14:00, 2026-10-20 14:00) as a timestamp, local time."""
    for fmt in ("%Y-%m-%d", "%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M"):
        try:
            return datetime.datetime.strptime(text, fmt).timestamp()
        except ValueError:
            pass
    raise SystemExit(f"{text}: a date is YYYY-MM-DD or YYYY-MM-DDTHH:MM")


def logged_label(row):
    for r in row.get("reasons") or []:
        if r.startswith("clef:"):
            return r[5:]
    return row.get("label") or "fine"


def load_rows(paths=None, logs=LOGS, since=None, until=None):
    """Every line Clef checked in the logs, once each (the first log that has it), oldest first: {id, t, name, text,
    label, reasons}. since/until: timestamps."""
    paths = paths or sorted(glob.glob(os.path.join(logs, "viewers-*.jsonl")))
    rows = {}
    for path in paths:
        for line in open(path, errors="replace"):
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("checked") != "clef" or r.get("id") in rows:
                continue
            t = r.get("t") or 0
            if (since and t < since) or (until and t >= until):
                continue
            rows[r["id"]] = {"id": r["id"], "t": t, "name": r.get("name", ""), "text": r.get("text", ""),
                             "full": r.get("full"), "label": logged_label(r), "reasons": r.get("reasons") or []}
    return sorted(rows.values(), key=lambda r: r["t"])


def held(row):
    return row["label"] != "fine"


class Cache:
    """Verdicts by criteria hash and line id, appended to a JSON lines file."""

    def __init__(self, path):
        self.path, self.seen = path, {}
        if path and os.path.exists(path):
            for line in open(path):
                try:
                    r = json.loads(line)
                    self.seen[(r["criteria"], r["id"])] = r["verdict"]
                except (ValueError, KeyError):
                    continue

    def get(self, h, mid):
        return self.seen.get((h, mid))

    def put(self, h, verdicts):
        self.seen.update({(h, k): v for k, v in verdicts.items()})
        if self.path:
            os.makedirs(os.path.dirname(os.path.abspath(self.path)), exist_ok=True)
            with open(self.path, "a") as f:
                for k, v in verdicts.items():
                    f.write(json.dumps({"criteria": h, "id": k, "verdict": v}) + "\n")


def ask(clef, part, criteria, tries=3):
    """One Clef call for part, retried; every line 'unknown' after the last failure."""
    for attempt in range(tries):
        try:
            return clef.classify(part, criteria, per_call=len(part))
        except Exception as e:  # a failed call is retried, then the lines count as unknown
            if attempt == tries - 1:
                print(f"clef: {len(part)} line(s) failed: {e}", file=sys.stderr)
                return {r["id"]: "unknown" for r in part}
            time.sleep(2 * (attempt + 1))


def replay(clef, rows, criteria, cache=None, batch=1, jobs=1, progress=None):
    """{id: Clef's label} for rows under criteria, asked `batch` lines a call (default 1: live chat reaches Clef a line
    or a few at a time; in a 48-line batch Clef held a sample of 40 lines as injection that it called fine one at a
    time), `jobs` calls at once. Cached by criteria and batch size; cached lines are not asked again; 'unknown' kept
    out of the cache."""
    h = f"{criteria_hash(criteria)}:b{batch}"
    cache = cache or Cache(None)
    out = {r["id"]: cache.get(h, r["id"]) for r in rows}
    todo = [r for r in rows if out[r["id"]] in (None, "unknown")]
    parts = [todo[k:k + batch] for k in range(0, len(todo), batch)]
    done = 0
    with concurrent.futures.ThreadPoolExecutor(max(1, jobs)) as pool:
        for got in pool.map(lambda part: ask(clef, part, criteria), parts):
            out.update(got)
            cache.put(h, {m: v for m, v in got.items() if v != "unknown"})
            done += len(got)
            if progress and (done % 240 < len(got) or done == len(todo)):
                progress(done, len(todo))
    return out


def stamp(t):
    return datetime.datetime.fromtimestamp(t).strftime("%m-%d %H:%M") if t else "?"


def flips(rows, before, after):
    """Rows whose verdict changed, as (row, before, after); unknown on either side left out."""
    out = []
    for r in rows:
        b, a = before.get(r["id"]), after.get(r["id"])
        if b and a and b != a and "unknown" not in (b, a):
            out.append((r, b, a))
    return out


def report(rows, before, after, title, file=sys.stdout):
    """Every flip, held lines freed first, then lines newly held, then label changes among held; counts by label."""
    fl = flips(rows, before, after)
    groups = [("freed (held -> fine)", lambda b, a: b != "fine" and a == "fine"),
              ("newly held (fine -> held)", lambda b, a: b == "fine" and a != "fine"),
              ("held, another label", lambda b, a: b != "fine" and a != "fine")]
    print(f"## {title}: {len(fl)} of {len(rows)} lines changed", file=file)
    for name, test in groups:
        part = [x for x in fl if test(x[1], x[2])]
        print(f"\n### {name}: {len(part)}", file=file)
        for r, b, a in part:
            print(f"{stamp(r['t'])}\t{r['id']}\t{r['name']}\t{b} -> {a}\t{r['text']}", file=file)
    bc = collections.Counter(before.get(r["id"]) for r in rows)
    ac = collections.Counter(after.get(r["id"]) for r in rows)
    labels = sorted(set(bc) | set(ac), key=lambda x: (x != "fine", str(x)))
    print("\nlabel\tbefore\tafter", file=file)
    for lab in labels:
        print(f"{lab}\t{bc.get(lab, 0)}\t{ac.get(lab, 0)}", file=file)
    return fl


CALIBRATION = os.path.join(HERE, "clef_calibration.json")


def record(path, clef, criteria=None, cache=None):
    """The calibration lines (tools/stream/clef_calibration.json: {lines: [{id, name, text, want}]}) asked under the
    working tree's criteria (or those given); writes each verdict, the criteria hash and the tick of the recording back
    to the file. test_clef_calibration.py checks that the hash is the current criteria's and every verdict is its
    want: after a change to CLEF_CRITERIA, record again (--record) and read what moved."""
    data = json.load(open(path))
    criteria = criteria or dict(V.CLEF_CRITERIA)
    got = replay(clef, data["lines"], criteria, cache, jobs=4)
    for line in data["lines"]:
        line["verdict"] = got.get(line["id"]) or "unknown"
    data["criteria"] = criteria_hash(criteria)
    data["recorded"] = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    with open(path, "w") as f:
        json.dump(data, f, indent=1, ensure_ascii=False)
        f.write("\n")
    return [x for x in data["lines"] if x["verdict"] != x["want"]]  # known misses (known_miss) included


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log", nargs="*")
    ap.add_argument("--logs", default=LOGS)
    ap.add_argument("--since")
    ap.add_argument("--until")
    ap.add_argument("--all", action="store_true", help="every line Clef checked (default: held + --sample passed)")
    ap.add_argument("--sample", type=int, default=20)
    ap.add_argument("--criteria", help="the criteria to replay with (default: the working tree's viewers.py)")
    ap.add_argument("--before", help="also replay viewers.py at this git revision, e.g. main")
    ap.add_argument("--cache", default=os.path.join(LOGS, "clef-replay-cache.jsonl"))
    ap.add_argument("--batch", type=int, default=1, help="lines a Clef call (default 1, as live chat arrives; at most 48)")
    ap.add_argument("--jobs", type=int, default=6, help="Clef calls at once (default 6)")
    ap.add_argument("--record", nargs="?", const=CALIBRATION,
                    help="ask the calibration lines again under the criteria and write the verdicts (default file "
                         "tools/stream/clef_calibration.json)")
    a = ap.parse_args(argv)
    if a.record:
        miss = record(a.record, V.Clef(), criteria_from(a.criteria) if a.criteria else None, Cache(a.cache))
        for x in miss:
            print(f"{x['id']}\t{x['name']}\twant {x['want']}, Clef said {x['verdict']}\t{x['text']}")
        print(f"recorded {a.record}: {len(miss)} line(s) where Clef's verdict is not the one wanted")
        return
    rows = load_rows(a.log, a.logs, a.since and when(a.since), a.until and when(a.until))
    if not a.all:
        passed = [r for r in rows if not held(r)][:a.sample]
        rows = [r for r in rows if held(r)] + passed
    if not rows:
        raise SystemExit("no checked lines in those logs and dates")
    clef, cache = V.Clef(), Cache(a.cache)
    new = criteria_from(a.criteria)
    print(f"{len(rows)} lines; criteria {criteria_hash(new)}"
          + (f", before {a.before} {criteria_hash(criteria_at(a.before))}" if a.before else ""), file=sys.stderr)
    tick = lambda n, total: print(f"  {n}/{total}", file=sys.stderr)
    b, j = max(1, min(48, a.batch)), a.jobs
    after = replay(clef, rows, new, cache, b, j, progress=tick)
    logged = {r["id"]: r["label"] for r in rows}
    report(rows, logged, after, "the log's labels -> the new criteria")
    if a.before:
        old = replay(clef, rows, criteria_at(a.before), cache, b, j, progress=tick)
        print()
        report(rows, old, after, f"{a.before}'s criteria replayed now -> the new criteria")
        print()
        report(rows, logged, old, f"the log's labels -> {a.before}'s criteria replayed now (the model's drift)")
    unknown = sum(after.get(r["id"]) in (None, "unknown") for r in rows)
    if unknown:
        print(f"\n{unknown} lines without a verdict (failed calls); a rerun asks them again", file=sys.stderr)


if __name__ == "__main__":
    main()
