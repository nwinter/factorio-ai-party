#!/usr/bin/env python3
"""Stage waits per batch (d28 batch322 UL, viewer Aurora site:5411: "Measure waits through intake, start, merge, deploy
and verification, then improve the slowest stage."): from the records already kept, for each batch whose task was
written in the window, the time it reached each stage and the wait between stages; then the medians and the slowest
stage, for the operator (who decides what to change).

  python3 tools/stage_times.py [--from 2026-10-26] [--to 2026-10-28] [--ops DIR] [--json] [--batches]

The stages and where each time comes from (Pacific):
- intake: the earliest ask: a site:NNNN message the task file names (its time in runs/*/operator-inbox.jsonl) or the
  asked date of an Updates row whose work names the batch; none for work the operator started on a finding;
- task: the task file's header, "(operator d28 16:20": that time on the day nearest the file's creation;
- first checkpoint: the earliest eng/<batch>-cpN ref's creation (its reflog), else that commit's date;
- merged: main's first-parent merge of any of the batch's checkpoint refs (the merge commit's date); the gate log
  (gate-queue.log, "HH:MM:SS gating REF") splits the wait into the queue before the gate took it and the gate run;
- deployed: for a batch whose merge changed the runtime (vendor/factorio-harness/mod), the first "Harness runtime
  deployed (SHA)" notice (site/content/operator-updates.json) whose SHA contains that merge; host and site changes go
  live at the merge (the operator's npm test, the hourly site refresh) and are counted apart;
- verified: the verified date of an Updates row whose work names the batch.
Each wait is from one stage to the next present one (a batch with no intake starts at its task). Medians are over the
batches that have both ends of that wait.
"""
import argparse, datetime, json, re, statistics, subprocess, sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "site"))
import updates  # noqa: E402  (PACIFIC, FMT, when)

OPS = Path.home() / "code" / "pog-operator"
STAGES = ("intake", "task", "checkpoint", "merged", "deployed", "verified")
WAITS = (("intake", "task"), ("task", "checkpoint"), ("checkpoint", "merged"), ("merged", "deployed"), ("deployed", "verified"))
HEADER = re.compile(r"\(operator d(\d+) (\d{1,2}):(\d{2})")
SITE_REF = re.compile(r"\bsite:(\d+)\b")
GATE = re.compile(r"^(\d{2}):(\d{2}):(\d{2}) gating (\S+)")
MERGE = re.compile(r"^Merge branch '(eng/d20-(batch\d+)-cp\d+)'")
DEPLOYED = re.compile(r"Harness runtime deployed \(([0-9a-f]{7,40})\)")


def local(epoch):
    """An epoch time as Pacific, naive (as the Updates file writes its times)."""
    return datetime.datetime.fromtimestamp(epoch, updates.PACIFIC).replace(tzinfo=None)


def nearest(h, m, ref):
    """h:m on the day before, of or after ref, whichever is nearest to ref."""
    days = [ref.replace(hour=h, minute=m, second=0, microsecond=0) + datetime.timedelta(days=d) for d in (-1, 0, 1)]
    return min(days, key=lambda t: abs(t - ref))


def task_time(text, created):
    """The task header's time, on the day nearest the file's creation (created when it has no header)."""
    m = HEADER.search(text.split("\n", 1)[0])
    return nearest(int(m.group(2)), int(m.group(3)), created) if m else created


def gate_starts(text, merged):
    """{ref: when the gate took it}: the gate log's 'HH:MM:SS gating REF' lines carry no date: each is placed on the day
    that puts it at or before the ref's merge (merged: {ref: datetime}); refs not merged are left out."""
    out = {}
    for line in text.splitlines():
        m = GATE.match(line)
        if not m or m.group(4) not in merged:
            continue
        end = merged[m.group(4)]
        t = end.replace(hour=int(m.group(1)), minute=int(m.group(2)), second=int(m.group(3)), microsecond=0)
        if t > end:
            t -= datetime.timedelta(days=1)
        out[m.group(4)] = max(out.get(m.group(4)) or t, t)  # the last gating before the merge (a retry after a conflict)
    return out


def minutes(a, b):
    return None if a is None or b is None else (b - a).total_seconds() / 60


def waits(st):
    """{(from, to): minutes} for one batch's stage times st: each wait from a stage to the next one present; deployed
    stands in for merged when the batch has no runtime part (host and site changes go live at the merge)."""
    out = {}
    for a, b in WAITS:
        if a == "intake" and st.get("intake") is None:
            continue
        if a == "deployed" and st.get("deployed") is None and st.get("runtime") is False:
            out[("merged", "verified")] = minutes(st.get("merged"), st.get("verified"))
            continue
        out[(a, b)] = minutes(st.get(a), st.get(b))
    if st.get("gate") and st.get("checkpoint") and st.get("merged"):
        out[("checkpoint", "gate")] = minutes(st["checkpoint"], st["gate"])
        out[("gate", "merged")] = minutes(st["gate"], st["merged"])
    return {k: v for k, v in out.items() if v is not None}


def summary(batches):
    """{(from, to): (median, 75th percentile, longest, count, total)} in minutes over the batches' waits; the gate's split
    comes as (checkpoint, gate) and (gate, merged)."""
    acc = {}
    for st in batches.values():
        for k, v in waits(st).items():
            acc.setdefault(k, []).append(v)
    return {k: (statistics.median(v), p75(v), max(v), len(v), sum(v)) for k, v in acc.items()}


def p75(v):
    v = sorted(v)
    return v[min(len(v) - 1, int(0.75 * len(v)))]


MIN_COUNT = 10  # a stage measured on fewer batches is shown but not ranked


def hm(mins):
    if mins is None:
        return "-"
    mins = int(round(mins))
    sign, mins = ("-" if mins < 0 else ""), abs(mins)
    return f"{sign}{mins // 1440}d{mins % 1440 // 60:02d}h" if mins >= 1440 else f"{sign}{mins // 60}h{mins % 60:02d}"


def report(batches, first, last):
    """The operator's section: the medians in stage order, the slowest stage, and what each count covers."""
    med = summary(batches)
    main = [k for k in list(WAITS) + [("merged", "verified")] if k in med]
    lines = [f"Stage waits, batches with a task written {first} to {last} ({len(batches)} batches); median, batches counted:"]
    for k in main:
        m, q, top, n, total = med[k]
        lines.append(f"  {k[0]} -> {k[1]}: median {hm(m)}, 75% within {hm(q)}, longest {hm(top)}, mean {hm(total / n)}, "
                     f"{total / 60:.0f} h in all ({n} batches)")
        if k == ("checkpoint", "merged") and ("checkpoint", "gate") in med:
            lines.append(f"    of which the queue before the gate took it: median {hm(med[('checkpoint', 'gate')][0])}, the gate run: "
                         f"median {hm(med[('gate', 'merged')][0])} ({med[('gate', 'merged')][3]} batches)")
    ranked = [k for k in main if med[k][3] >= MIN_COUNT]
    if ranked:
        slow = max(ranked, key=lambda k: med[k][0])
        lines.append(f"Slowest by median (stages with {MIN_COUNT}+ batches): {slow[0]} -> {slow[1]} ({hm(med[slow][0])} over "
                     f"{med[slow][3]} batches).")
        most = max(ranked, key=lambda k: med[k][4])
        lines.append(f"Most time in all: {most[0]} -> {most[1]} ({med[most][4] / 60:.0f} h over {med[most][3]} batches, "
                     f"mean {hm(med[most][4] / med[most][3])}).")
    few = [k for k in main if med[k][3] < MIN_COUNT]
    if few:
        lines.append("Too few batches to rank: " + ", ".join(f"{a} -> {b} ({med[(a, b)][3]})" for a, b in few) + ".")
    rt = sum(1 for st in batches.values() if st.get("runtime"))
    lines.append(f"Runtime batches (a deploy needed): {rt}; host or site only (live at the merge): "
                 f"{sum(1 for st in batches.values() if st.get('runtime') is False)}; not merged yet: "
                 f"{sum(1 for st in batches.values() if not st.get('merged'))}; with an intake: "
                 f"{sum(1 for st in batches.values() if st.get('intake'))}; verified: {sum(1 for st in batches.values() if st.get('verified'))}.")
    return lines


def table(batches):
    head = "batch      " + "  ".join(f"{s:<11}" for s in STAGES) + "  waits"
    out = [head]
    for b in sorted(batches, key=lambda b: int(b[5:])):
        st = batches[b]
        cells = "  ".join(f"{(st[s].strftime('%d %H:%M') if st.get(s) else '-'):<11}" for s in STAGES)
        w = waits(st)
        out.append(f"{b:<10} {cells}  " + ", ".join(f"{a[:4]}>{c[:4]} {hm(v)}" for (a, c), v in w.items()
                                                   if (a, c) not in (("checkpoint", "gate"), ("gate", "merged")))
                   + ("" if st.get("runtime") is not False else "  (no runtime part)"))
    return out


class Git:
    """The repository reads the stages need (a fake one in the tests)."""

    def __init__(self, repo):
        self.repo = str(repo)
        common = self._run("rev-parse", "--git-common-dir").strip()
        self.common = Path(common if Path(common).is_absolute() else Path(self.repo) / common)

    def _run(self, *a):
        return subprocess.run(["git", "-C", self.repo, *a], capture_output=True, text=True).stdout

    def cp_refs(self):
        """{batchNNN: {ref: created}} for every eng/d20-batchNNN-cpM ref: the first reflog line's time, else the commit's."""
        out = {}
        for line in self._run("for-each-ref", "--format=%(refname:short) %(creatordate:unix)", "refs/heads/eng/").splitlines():
            ref, _, t = line.partition(" ")
            m = re.fullmatch(r"eng/d20-(batch\d+)-cp\d+", ref)
            if not m:
                continue
            created = int(t)
            log = self.common / "logs" / "refs" / "heads" / ref
            if log.exists():
                first = log.read_text(errors="replace").split("\n", 1)[0].split("\t")[0].split()
                if len(first) >= 2 and first[-2].isdigit():
                    created = int(first[-2])
            out.setdefault(m.group(1), {})[ref] = local(created)
        return out

    def merges(self, since):
        """{ref: (merge sha, when)}: main's first-parent merges of checkpoint refs since the date."""
        out = {}
        for line in self._run("log", "main", "--first-parent", "--merges", f"--since={since}", "--format=%H %ct %s").splitlines():
            sha, t, subject = line.split(" ", 2)
            m = MERGE.match(subject)
            if m:
                out.setdefault(m.group(1), (sha, local(int(t))))
        return out

    def runtime(self, sha):
        """Whether the merge changed the runtime mod (its diff from main before it)."""
        return bool(self._run("diff", "--name-only", f"{sha}^1", sha, "--", "vendor/factorio-harness/mod").strip())

    def contains(self, sha, later):
        return subprocess.run(["git", "-C", self.repo, "merge-base", "--is-ancestor", sha, later], capture_output=True).returncode == 0


def site_times(runs_dir, ids):
    """{site:NNNN: when} from the operator inboxes (the first copy)."""
    out = {}
    for f in sorted(Path(runs_dir).glob("*/operator-inbox.jsonl")):
        for line in f.read_text(errors="replace").splitlines():
            if '"site:' not in line:
                continue
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if isinstance(r, dict) and r.get("id") in ids and r["id"] not in out and isinstance(r.get("t"), (int, float)):
                out[r["id"]] = local(r["t"])
    return out


def collect(ops, git, data, runs_dir, first, last):
    """{batchNNN: {stage: datetime, runtime: bool|None, gate: datetime}} for the batches whose task was written from first
    to last (dates, inclusive)."""
    tasks = {}
    for f in sorted(Path(ops).glob("task-d20-batch*.md")):
        m = re.fullmatch(r"task-d20-(batch\d+)\.md", f.name)
        if not m:
            continue
        stt = f.stat()
        created = local(getattr(stt, "st_birthtime", stt.st_mtime))
        text = f.read_text(errors="replace")
        t = task_time(text, created)
        if first <= t.date() <= last:
            tasks[m.group(1)] = (t, text)
    sites = site_times(runs_dir, {f"site:{n}" for _, text in tasks.values() for n in SITE_REF.findall(text)})
    rows = {}
    for u in data["updates"]:
        for b in set(updates.BATCH_ID.findall(str(u.get("work") or ""))):
            rows.setdefault(f"batch{b}", []).append(u)
    cps = git.cp_refs()
    merges = git.merges((first - datetime.timedelta(days=1)).isoformat())
    deploys = sorted((updates.when(n["t"]), DEPLOYED.search(n["text"]).group(1)) for n in data["notices"]
                     if n.get("kind") == "deploy" and DEPLOYED.search(n.get("text", "")))
    gate_log = Path(ops) / "gate-queue.log"
    merged_at = {ref: t for ref, (_, t) in merges.items()}
    gates = gate_starts(gate_log.read_text(errors="replace"), merged_at) if gate_log.exists() else {}
    out = {}
    for b, (t, text) in tasks.items():
        st = {"task": t}
        asks = [sites[f"site:{n}"] for n in SITE_REF.findall(text) if f"site:{n}" in sites]
        asks += [updates.when((u.get("dates") or {}).get("asked")) for u in rows.get(b, [])]
        asks = [a for a in asks if a and a <= t + datetime.timedelta(minutes=5)]
        st["intake"] = min(asks) if asks else None
        refs = cps.get(b) or {}
        st["checkpoint"] = min(refs.values()) if refs else None
        mine = sorted((merges[r][1], merges[r][0], r) for r in refs if r in merges)
        if mine:
            when_, sha, ref = mine[0]
            st["merged"], st["gate"] = when_, gates.get(ref)
            st["runtime"] = any(git.runtime(s) for _, s, _ in mine)
            if st["runtime"]:
                rt = next((s for _, s, _ in mine if git.runtime(s)))
                rt_at = next(w for w, s, _ in mine if s == rt)
                st["deployed"] = next((d for d, dsha in deploys if d >= rt_at and git.contains(rt, dsha)), None)
        ver = [updates.when((u.get("dates") or {}).get("verified")) for u in rows.get(b, [])]
        ver = [v for v in ver if v and (not st.get("merged") or v >= st["merged"])]  # a row of several batches: not before this one's merge
        st["verified"] = min(ver) if ver else None
        out[b] = st
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--from", dest="first", default="2026-10-26", help="first task date (YYYY-MM-DD)")
    ap.add_argument("--to", dest="last", default="2026-10-28", help="last task date (YYYY-MM-DD, inclusive)")
    ap.add_argument("--ops", default=str(OPS), help="the operator's folder (task files, gate-queue.log)")
    ap.add_argument("--repo", default=str(REPO))
    ap.add_argument("--updates", default=str(REPO / "site" / "content" / "operator-updates.json"))
    ap.add_argument("--runs", default=str(REPO / "runs"))
    ap.add_argument("--batches", action="store_true", help="also one line a batch")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    first, last = datetime.date.fromisoformat(args.first), datetime.date.fromisoformat(args.last)
    batches = collect(args.ops, Git(args.repo), updates.load(args.updates), args.runs, first, last)
    if args.json:
        print(json.dumps({b: {k: (v.strftime(updates.FMT) if isinstance(v, datetime.datetime) else v) for k, v in st.items()}
                          for b, st in batches.items()}, indent=1))
        return
    print("\n".join((table(batches) + [""] if args.batches else []) + report(batches, first, last)))


if __name__ == "__main__":
    main()
