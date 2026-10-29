#!/usr/bin/env python3
"""Stage waits per batch (d28 batch322 UL, viewer Aurora site:5411: "Measure waits through intake, start, merge, deploy
and verification, then improve the slowest stage."): python3 tools/test_stage_times.py

Checks, on temp files and a fake repository (no clock, no live data):
- the task header's time lands on the day nearest the file's creation (across midnight too);
- the gate log's dateless 'gating' lines land at or before their ref's merge, the last one before it kept;
- one batch's stages: intake from the site message its task names, or an Updates row's asked date; first checkpoint
  from the earliest ref; merged from main's merge; deployed at the first runtime deploy containing the merge; verified
  from the row; a host-only batch is live at its merge (merged -> verified), a row's verified date before the batch's
  merge is not taken, an ask after the task is not its intake;
- the waits, the medians, 75th percentiles and the slowest stage ranked only over stages with 10+ batches.
"""
import datetime, json, os, sys, tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools"))
import stage_times as st  # noqa: E402

T = datetime.datetime.strptime


def at(s):
    return T(s, "%Y-%m-%d %H:%M")


class FakeGit:
    def __init__(self, cps, merges, runtime, contains):
        self._cps, self._merges, self._runtime, self._contains = cps, merges, runtime, contains

    def cp_refs(self):
        return self._cps

    def merges(self, since):
        return self._merges

    def runtime(self, sha):
        return sha in self._runtime

    def contains(self, sha, later):
        return (sha, later) in self._contains


def main():
    # the header's time on the nearest day
    assert st.task_time("# Task: batch322 (operator d28 16:20; read ...)\n", at("2026-10-28 16:17")) == at("2026-10-28 16:20")
    assert st.task_time("# Task: b (operator d28 00:02; ...)\n", at("2026-10-27 23:58")) == at("2026-10-28 00:02")
    assert st.task_time("# no header\n", at("2026-10-27 23:58")) == at("2026-10-27 23:58")

    # gate starts: dated by the merge, the last before it
    log = "23:50:00 gating eng/d20-batch1-cp1\neng/d20-batch1-cp1 CONFLICT: x\n00:10:00 gating eng/d20-batch1-cp1\n" \
          "eng/d20-batch1-cp1 merged abc\n00:20:00 queue empty\n09:00:00 gating eng/d20-batch9-cp1\n"
    g = st.gate_starts(log, {"eng/d20-batch1-cp1": at("2026-10-28 00:25")})
    assert g == {"eng/d20-batch1-cp1": at("2026-10-28 00:10")}, g

    with tempfile.TemporaryDirectory() as d:
        ops, runs = Path(d) / "ops", Path(d) / "runs" / "shift94"
        ops.mkdir()
        runs.mkdir(parents=True)
        (ops / "task-d20-batch500.md").write_text("# Task: batch500 (operator d28 10:00; read ...)\n## X (viewer Aurora, site:7001)\n")
        (ops / "task-d20-batch501.md").write_text("# Task: batch501 (operator d28 11:00; read ...)\n")
        (ops / "task-d20-batch502.md").write_text("# Task: batch502 (operator d28 12:00; read ...)\n")
        (ops / "task-d20-batch400.md").write_text("# Task: batch400 (operator d20 12:00; read ...)\n")  # outside the window
        (ops / "notes.md").write_text("not a task\n")
        now = datetime.datetime(2026, 10, 28, 10, 0).timestamp()
        for f in ops.iterdir():
            os.utime(f, (now, now))
        old = datetime.datetime(2026, 10, 20, 12, 0).timestamp()
        os.utime(ops / "task-d20-batch400.md", (old, old))
        (ops / "gate-queue.log").write_text("10:50:00 gating eng/d20-batch500-cp1\neng/d20-batch500-cp1 merged m500\n")
        (runs / "operator-inbox.jsonl").write_text(json.dumps({"id": "site:7001", "t": at("2026-10-28 09:40").timestamp(), "text": "ask"}) + "\n")
        data = {"updates": [
            {"id": "a", "title": "A", "status": "verified", "work": "batch500", "dates": {"asked": "2026-10-28 09:50", "verified": "2026-10-28 12:30"}},
            {"id": "b", "title": "B", "status": "verified", "work": "batch501, batch999", "dates": {"asked": "2026-10-28 11:30", "verified": "2026-10-28 11:40"}},
        ], "notices": [
            {"t": "2026-10-28 11:05", "kind": "deploy", "text": "Harness runtime deployed (aaaa111)."},
            {"t": "2026-10-28 12:00", "kind": "deploy", "text": "Harness runtime deployed (bbbb222)."},
        ]}
        git = FakeGit(
            cps={"batch500": {"eng/d20-batch500-cp1": at("2026-10-28 10:30"), "eng/d20-batch500-cp2": at("2026-10-28 11:30")},
                 "batch501": {"eng/d20-batch501-cp1": at("2026-10-28 11:20")}},
            merges={"eng/d20-batch500-cp1": ("m500", at("2026-10-28 11:00")), "eng/d20-batch501-cp1": ("m501", at("2026-10-28 11:45"))},
            runtime={"m500"}, contains={("m500", "bbbb222")})
        b = st.collect(ops, git, data, Path(d) / "runs", datetime.date(2026, 10, 26), datetime.date(2026, 10, 28))
        assert sorted(b) == ["batch500", "batch501", "batch502"], sorted(b)
        x = b["batch500"]
        assert (x["intake"], x["task"], x["checkpoint"], x["merged"], x["gate"]) == (
            at("2026-10-28 09:40"), at("2026-10-28 10:00"), at("2026-10-28 10:30"), at("2026-10-28 11:00"), at("2026-10-28 10:50")), x
        assert x["runtime"] is True and x["deployed"] == at("2026-10-28 12:00") and x["verified"] == at("2026-10-28 12:30"), x
        w = st.waits(x)
        assert w == {("intake", "task"): 20, ("task", "checkpoint"): 30, ("checkpoint", "merged"): 30, ("merged", "deployed"): 60,
                     ("deployed", "verified"): 30, ("checkpoint", "gate"): 20, ("gate", "merged"): 10}, w
        y = b["batch501"]
        assert y["intake"] is None, "an ask after the task is not its intake"
        assert y["runtime"] is False and y.get("deployed") is None and y["verified"] is None, "verified before the merge is not taken"
        assert st.waits(y) == {("task", "checkpoint"): 20, ("checkpoint", "merged"): 25}, st.waits(y)
        z = b["batch502"]
        assert z["checkpoint"] is None and st.waits(z) == {}, z
        y2 = dict(y, verified=at("2026-10-28 13:45"))
        assert st.waits(y2)[("merged", "verified")] == 120, st.waits(y2)

        # the summary and the slowest stage: only stages with 10+ batches ranked
        many = {f"batch{i}": {"task": at("2026-10-28 10:00"), "checkpoint": at("2026-10-28 10:00") + datetime.timedelta(minutes=30 + i),
                              "merged": at("2026-10-28 12:00")} for i in range(10)}
        many["batch99"] = dict(x)
        lines = st.report(many, datetime.date(2026, 10, 26), datetime.date(2026, 10, 28))
        text = "\n".join(lines)
        assert "  task -> checkpoint: median 0h34, 75% within 0h37, longest 0h39, mean 0h34, 6 h in all (11 batches)" in text, text
        assert "  checkpoint -> merged: median 1h25, 75% within 1h28, longest 1h30, mean 1h20, 15 h in all (11 batches)" in text, text
        assert "Most time in all: checkpoint -> merged (15 h over 11 batches, mean 1h20)." in text, text
        assert "    of which the queue before the gate took it: median 0h20, the gate run: median 0h10 (1 batches)" in text, text
        assert "Slowest by median (stages with 10+ batches): checkpoint -> merged (1h25 over 11 batches)." in text, text
        assert "Too few batches to rank: intake -> task (1), merged -> deployed (1), deployed -> verified (1)." in text, text
        assert st.hm(3 * 1440 + 12 * 60 + 5) == "3d12h" and st.hm(65) == "1h05" and st.hm(None) == "-"
    print("ok: task times, gate starts, stages and waits per batch, medians and the slowest stage")


if __name__ == "__main__":
    main()
