#!/usr/bin/env python3
"""tools/archive/catalogue.py and clipmaker.py (the clip library, batch129) on the made-up shift of
tools/test_video_archive.py: python3 tools/test_clip_library.py

- voiced lines: a shift with no audio-played.jsonl takes the caster rows pushed to the page (Rook, Vale), marked;
  one whose audio-played.jsonl begins mid-shift takes them only before it;
- entries: id from the shift and the event, caption, planet, platform, agents, the voiced lines inside the clip;
  a recording with no fitted offset and a hidden viewer's chat on the full frame are flagged;
- the run's rank: the first death of an agent in the whole run gets the bonus, the next shift's does not;
- search by kind, agent, planet, platform, shift, time range and words; best N skips flagged entries and caps a shift;
- the clip maker: a range's id, the cut command (nice 19, CRF 23, the camera-hole crop), the full frame refused for a
  hidden chat, an upload's keys and public URL, the cache (no second encode), and the R2 budget.
No ffmpeg, no network: the encoder and uploader are stand-ins.
"""
import json
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "archive"))
import test_video_archive as tva  # noqa: E402
import archive_index as ai  # noqa: E402
import catalogue  # noqa: E402
import clipmaker  # noqa: E402
import clips  # noqa: E402

T0 = tva.T0


class Hidden:
    names = {"gone"}

    def hides(self, name, text):
        return name == "Gone"

    def __bool__(self):
        return True


def main():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        runs, logs, rec = tva.make(root)
        (runs / "sx").rename(runs / "shift07")
        cal = {"2026-10-20_17-00-30.mkv": {"offset": 8.5}}
        idx = ai.build("shift07", runs, logs, [rec], cal, probe=tva.probe, hidden=Hidden())

        # entries
        es = [catalogue.entry(idx, c, Hidden()) for c in clips.candidates(idx)]
        by = {e["id"]: e for e in es}
        assert "s07-platform_lost-001" in by and "s07-death-001" in by, list(by)
        lost, death = by["s07-platform_lost-001"], by["s07-death-001"]
        assert death["caption"] == "from shift 7, Oct 20" and death["when"] == "2026-10-20 18:30:00", death
        assert death["planet"] == "nauvis" and "opus" in death["agents"] and death["subjects"] == ["opus"], death
        assert death["lines"] and death["lines"][0]["who"] == "Rook", death["lines"]
        assert lost["platform"] == "Wren" and lost["planet"] == "space", lost
        assert any("offset not fitted" in f for f in lost["flags"]), lost["flags"]  # the second file has no fit
        assert death["flags"] == ["no footage"], death["flags"]  # 18:30 falls between the two files
        rocket = by["s07-rocket-001"]
        assert not rocket["flags"] and rocket["s_in"] == 81.5 and rocket["planet"] == "nauvis", rocket
        raw = ai.chat_rows([], [r for p in ai.log_files(logs, "viewers", T0, T0 + 3600) for r in ai.jsonl(p)],
                           T0, T0 + 3600, None)
        catalogue.hidden_chat_flags(es, raw, Hidden())
        assert death.get("hidden_chat") and "full frame" in death["flags"][1], death["flags"]
        assert not rocket.get("hidden_chat")

        # the run's rank: a second shift's death of the same agent gets no first-of-run bonus
        later = json.loads(json.dumps(death))
        later.update(id="s08-death-001", shift=8, t=death["t"] + 86400, t_in=death["t_in"] + 86400,
                     t_out=death["t_out"] + 86400, flags=[], why=["the first death of opus"])
        later.pop("hidden_chat")
        allx = es + [later]
        catalogue.run_rank(allx)
        assert death["rank"] == round(death["score"] * catalogue.RUN_FIRST, 1), death
        assert later["rank"] == later["score"] and "the run's first death (opus)" in death["why"], later
        assert not any(w.startswith("the first death of") for w in death["why"]), death["why"]

        # search
        def ids(**kw):
            return [e["id"] for e in catalogue.search(allx, **kw)]
        assert ids(kind="death") == ["s07-death-001", "s08-death-001"], ids(kind="death")
        assert ids(agent="Opus", shift=8) == ["s08-death-001"]
        assert ids(planet="space") == ["s07-platform_lost-001"], ids(planet="space")
        assert ids(platform="wren") == ["s07-platform_lost-001"]
        assert ids(text="opus down") == ["s07-death-001", "s08-death-001"], ids(text="opus down")
        assert ids(text="cue <here>") == ["s07-platform_lost-001"], ids(text="cue <here>")
        t_mid = catalogue.parse_time("2026-10-20 18:35")
        assert t_mid == T0 + 2100 and "s07-death-001" not in ids(t_from=t_mid, t_to=t_mid + 3600)
        assert ids(t_from=T0 + 86000) == ["s08-death-001"]
        top = catalogue.best(allx, n=10, per_shift=1)
        assert len(top) == 2 and {e["shift"] for e in top} == {7, 8} and not any(e["flags"] for e in top), top
        assert "s08-death-001" in [e["id"] for e in top]

        # an audio-played.jsonl that begins mid-shift (shift14): pushed rows before it, played rows after
        played = runs / "shift07" / "audio-played.jsonl"
        late = [r for r in ai.jsonl(played) if r["t"] > T0 + 2400]
        tva.jl(played, late)
        mixed = ai.build("shift07", runs, logs, [rec], cal, probe=tva.probe, hidden=Hidden())
        assert [(r["who"], bool(r.get("pushed"))) for r in mixed["lines"]] == [
            ("Rook", True), ("Vale", False), ("Sol", False)], mixed["lines"]
        assert catalogue.lines_from(mixed) == "both" and catalogue.lines_from(idx) == "played"
        # voiced lines without audio-played.jsonl: the caster rows pushed to the page
        played.unlink()
        bare = ai.build("shift07", runs, logs, [rec], cal, probe=tva.probe, hidden=Hidden())
        assert [(r["who"], r["dur"], r["pushed"]) for r in bare["lines"]] == [("Rook", 4.0, True),
                                                                               ("Vale", 12.0, True)], bare["lines"]
        assert bare["lines"][0]["t"] == T0 + 1800.3 and bare["lines"][0]["event"] == "death", bare["lines"][0]

        # the clip maker
        data = root / "data"
        (data / "shifts").mkdir(parents=True)
        (data / "shifts" / "shift07-index.json").write_text(json.dumps(idx))
        cat = {"shifts": [catalogue.shift_row(idx) | {"entries": len(es)}], "media": idx["media"], "entries": es}
        spec = clipmaker.spec_range(cat, T0 + 300, T0 + 350, "hole")
        assert spec["id"] == "s07-t180500-50s" and spec["s_in"] == 261.5, spec
        for bad in ((T0 + 1700, T0 + 1750), (T0 + 300, T0 + 1300)):
            try:
                clipmaker.spec_range(cat, *bad, "hole")
                raise AssertionError(f"range {bad} accepted")
            except SystemExit:
                pass
        for e, frame, why in ((dict(rocket, hidden_chat=True), "full", "--frame hole"), (death, "hole", "no footage")):
            try:
                clipmaker.spec_entry(e, frame)
                raise AssertionError(f"{e['id']} {frame} accepted")
            except SystemExit as x:
                assert why in str(x), x
        spec = clipmaker.spec_entry(rocket, "hole")
        cmd = clipmaker.cut_cmd(spec, "out.mp4")
        assert cmd[:3] == ["nice", "-n", "19"] and "crop=1208:1032:24:24" in cmd and cmd[cmd.index("-crf") + 1] == "23"
        assert "+faststart" in cmd and "crop" not in " ".join(clipmaker.cut_cmd(dict(spec, frame="full"), "o.mp4"))
        encodes, puts = [], []

        def runner(c, check):
            encodes.append(c)
            Path(c[-1]).write_bytes(b"x" * 5000)

        def putter(bucket, item):
            puts.append((bucket, item[1], item[2]))
            return item[1], 0, []
        out = clipmaker.make(spec, data, runner=runner, putter=putter, usage=lambda: 1e9)
        assert out["url"] == f"{clipmaker.PUBLIC}/clips/s07-rocket-001.mp4" and not out["cached"], out
        assert out["width"] == 1208 and out["height"] == 1032 and out["bytes"] == 5000, out
        assert [p[1] for p in puts] == ["clips/s07-rocket-001.mp4", "clips/s07-rocket-001.vtt",
                                        "clips/s07-rocket-001.json"], puts
        assert (data / "clips" / "s07-rocket-001.vtt").read_text().startswith("WEBVTT")
        meta = json.loads((data / "clips" / "s07-rocket-001.json").read_text())
        assert meta["caption"] == "from shift 7, Oct 20" and "file" not in meta, meta  # published: no local paths
        again = clipmaker.make(spec, data, runner=runner, putter=putter, usage=lambda: 1e9)
        assert again["cached"] and len(encodes) == 1, again
        moved = dict(spec, t_out=spec["t_out"] + 5, seconds=spec["seconds"] + 5)
        clipmaker.make(moved, data, runner=runner, putter=putter, usage=lambda: 1e9)
        assert len(encodes) == 2  # new in/out points: cut again
        try:
            clipmaker.make(clipmaker.spec_range(cat, T0 + 300, T0 + 350, "hole"), data, runner=runner,
                           putter=putter, usage=lambda: clipmaker.BUDGET_BYTES - 1000)
            raise AssertionError("over the R2 budget")
        except SystemExit as e:
            assert "would pass" in str(e), e
        assert clipmaker.SIZE_RE.search("bucket_size:            579 MB").group(1) == "579"
    print("clip library: ok (pushed lines, entries and flags, run rank, search, best, range ids, cut command, "
          "upload keys, cache, budget)")


if __name__ == "__main__":
    main()
