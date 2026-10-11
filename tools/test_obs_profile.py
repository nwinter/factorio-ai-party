#!/usr/bin/env python3
"""Offline check for tools/obs_profile.py with stand-in ssh/scp: refuses while OBS runs, keeps case, BOM and every
other key, changes only the video/encoder keys, backs up first, and handles Simple and Advanced output modes.
python3 tools/test_obs_profile.py"""
import json, os, sys, tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import obs_profile as op  # noqa: E402

SIMPLE = """[General]
Name=pog

[Video]
BaseCX=1920
BaseCY=1080
OutputCX=1280
OutputCY=720
FPSType=0
FPSCommon=30
ScaleType=bicubic

[Output]
Mode=Simple

[SimpleOutput]
FilePath=D:\\pog\\recordings
VBitrate=6000
StreamEncoder=qsv
RecEncoder=qsv_hevc
ABitrate=160
"""


def stub(d, boxdir, state):
    bindir = os.path.join(d, "bin")
    os.makedirs(bindir, exist_ok=True)
    open(os.path.join(bindir, "ssh"), "w").write(f"""#!/bin/sh
cmd="$2"
echo "$cmd" >> {d}/ssh.log
case "$cmd" in
  tasklist*) if [ "$(cat {state})" = 1 ]; then echo "obs64.exe 99 Console"; else echo "INFO: No tasks"; fi;;
  *basic.ini.pog-*) cp {boxdir}/basic.ini {boxdir}/basic.ini.bak-copy;;
  *streamEncoder.json.pog-*) cp {boxdir}/streamEncoder.json {boxdir}/streamEncoder.json.bak-copy;;
esac
""")
    open(os.path.join(bindir, "scp"), "w").write(f"""#!/bin/sh
src="$2"; dst="$3"
case "$src" in pogwin:*) b=$(basename "$src"); [ -f {boxdir}/$b ] || exit 1; cp {boxdir}/$b "$dst";;
  *) cp "$src" {boxdir}/$(basename "$dst");; esac
""")
    os.chmod(os.path.join(bindir, "ssh"), 0o755), os.chmod(os.path.join(bindir, "scp"), 0o755)
    return bindir


def args(cmd, **kw):
    return type("A", (), dict(dict(cmd=cmd, encoder=None, bitrate=None, fps=30, dry_run=False), **kw))


def main():
    # plan() alone, Simple mode
    cp = op.read_ini(SIMPLE)
    changes, js = op.plan(cp, None, "1080p", "nvenc", 12000)
    assert js is None
    assert [(k, b, a) for _, k, b, a in changes] == [("OutputCX", "1280", "1920"), ("OutputCY", "720", "1080"),
                                                    ("StreamEncoder", "qsv", "nvenc"), ("VBitrate", "6000", "12000")]
    text = op.write_ini(cp)
    assert "OutputCX=1920" in text and "BaseCX=1920" in text and "RecEncoder=qsv_hevc" in text  # case, other keys
    assert "FilePath=D:\\pog\\recordings" in text and " = " not in text
    assert op.plan(op.read_ini(text), None, "1080p", "nvenc", 12000)[0] == []  # idempotent
    # Advanced mode: encoder id and streamEncoder.json
    adv = op.read_ini(SIMPLE.replace("Mode=Simple", "Mode=Advanced") + "\n[AdvOut]\nEncoder=obs_qsv11_v2\nRescale=true\n")
    changes, js = op.plan(adv, {"bitrate": 6000, "preset2": "p5"}, "1080p", "nvenc", 12000)
    assert adv.get("AdvOut", "Encoder") == "obs_nvenc_h264_tex" and adv.get("AdvOut", "Rescale") == "false"
    assert js == {"bitrate": 12000, "preset2": "p5", "rate_control": "CBR", "keyint_sec": 2}, js

    # run() over stand-in ssh/scp
    with tempfile.TemporaryDirectory() as d:
        boxdir = os.path.join(d, "box")
        os.makedirs(boxdir)
        open(os.path.join(boxdir, "basic.ini"), "wb").write(b"\xef\xbb\xbf" + SIMPLE.encode())
        state = os.path.join(d, "obs")
        open(state, "w").write("1")
        bindir = stub(d, boxdir, state)
        old = os.environ["PATH"]
        os.environ["PATH"] = bindir + os.pathsep + old
        try:
            op.run(args("show"))  # read-only works while OBS runs
            try:
                op.run(args("1080p", encoder="nvenc", bitrate=12000))
                raise AssertionError("OBS running: must refuse")
            except SystemExit as e:
                assert "OBS is running" in str(e)
            open(state, "w").write("0")
            op.run(args("1080p", encoder="nvenc", bitrate=12000, dry_run=True))
            assert b"OutputCX=1280" in open(os.path.join(boxdir, "basic.ini"), "rb").read()  # dry run wrote nothing
            op.run(args("1080p", encoder="nvenc", bitrate=12000))
        finally:
            os.environ["PATH"] = old
        raw = open(os.path.join(boxdir, "basic.ini"), "rb").read()
        assert raw.startswith(b"\xef\xbb\xbf") and b"OutputCX=1920" in raw and b"StreamEncoder=nvenc" in raw
        assert b"VBitrate=12000" in raw and b"RecEncoder=qsv_hevc" in raw
        assert os.path.exists(os.path.join(boxdir, "basic.ini.bak-copy"))
        assert not os.path.exists(os.path.join(boxdir, "service.json"))  # never fetched or written
    print("obs_profile: ok")


if __name__ == "__main__":
    main()
