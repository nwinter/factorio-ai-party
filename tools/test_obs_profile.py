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
    advanced_tests()
    print("obs_profile: ok")


# The pog profile as the operator described it (2026-10-11): Simple, QSV 6 Mbps, recording shares the stream encoder
# into D:\pog\recordings as mkv, replay buffer 45 s / 512 MB "Replay", audio 160 kbps
POG_SIMPLE = SIMPLE.replace("RecEncoder=qsv_hevc\n", "") + """RecFormat2=mkv
RecQuality=Stream
RecRB=true
RecRBTime=45
RecRBSize=512
RecRBPrefix=Replay
QSVPreset=balanced
StreamAudioEncoder=aac
"""

PY_SSH = r'''#!/usr/bin/env python3
# stand-in for ssh to the box: cmd's if exist / copy / del / dir / type nul on BOX (a folder), names by basename
import os, re, shutil, sys
box, state = os.environ["FAKEBOX"], os.environ["FAKESTATE"]
cmd = sys.argv[-1]
open(os.path.join(box, "..", "ssh.log"), "a").write(cmd + "\n")
p = lambda w: os.path.join(box, w.replace("\\", "/").rsplit("/", 1)[-1])
def run(c):
    c = c.strip()
    m = re.match(r'if exist "([^"]+)" \((.*)\) else (.*)$', c) or re.match(r'if exist "([^"]+)" \((.*)\)()$', c)
    if m:
        return run(m.group(2)) if os.path.exists(p(m.group(1))) else (run(m.group(3).strip()[1:-1] if m.group(3).strip().startswith("(") else m.group(3)) if m.group(3) else None)
    for part in [x for x in re.split(r" && | & ", c) if x]:
        part = part.strip().strip("()")
        if part.startswith("copy /Y"):
            a, b = re.findall(r'"([^"]+)"', part); shutil.copy(p(a), p(b))
        elif part.startswith("type nul >"):
            open(p(re.findall(r'"([^"]+)"', part)[0]), "w").close()
        elif part.startswith("if exist"):
            f = re.findall(r'"([^"]+)"', part)[0]
            if os.path.exists(p(f)) and " del " in part: os.remove(p(f))
        elif part.startswith("del"):
            f = p(re.findall(r'"([^"]+)"', part)[0]); os.path.exists(f) and os.remove(f)
        elif part.startswith("echo"):
            print(part[5:])
if cmd.startswith("tasklist"):
    print("obs64.exe 99 Console" if open(state).read().strip() == "1" else "INFO: No tasks")
elif cmd.startswith("dir /b"):
    print("\n".join(sorted(f for f in os.listdir(box) if ".pog-" in f)))
else:
    run(cmd)
'''


def advanced_tests():
    import time
    # plan alone: every Simple behaviour has an Advanced key
    cp = op.read_ini(POG_SIMPLE)
    changes, sj, rj, warn = op.to_advanced(cp)
    assert warn == [], warn
    adv = dict(cp.items("AdvOut"))
    assert cp.get("Output", "Mode") == "Advanced"
    assert adv["Encoder"] == "obs_qsv11_v2" and adv["TrackIndex"] == "1" and adv["Track1Bitrate"] == "160"
    assert adv["AudioEncoder"] == "ffmpeg_aac" and adv["RecType"] == "Standard"
    assert adv["RecFilePath"] == "D:\\pog\\recordings" and adv["RecFormat2"] == "mkv"
    assert adv["RecRB"] == "true" and adv["RecRBTime"] == "45" and adv["RecRBSize"] == "512"
    assert adv["RecEncoder"] == "none" and adv["RecAudioEncoder"] == "none"  # Stream quality: one shared encode
    assert cp.get("SimpleOutput", "RecRBPrefix") == "Replay"  # read from SimpleOutput in Advanced mode too
    assert sj == {"rate_control": "CBR", "bitrate": 6000, "keyint_sec": 2, "preset": "balanced"} and rj is None, sj
    assert not cp.has_option("Video", "AutoRemux")  # untouched
    # HQ recording on its own encoder: CQP 16 lowered by CalcCRF at 1280x720 (diagonal 1469 px -> -2)
    hq = op.read_ini(POG_SIMPLE.replace("RecQuality=Stream", "RecQuality=HQ\nRecEncoder=qsv_hevc\nRecTracks=1"))
    _, _, rj, _ = op.to_advanced(hq)
    assert hq.get("AdvOut", "RecEncoder") == "obs_qsv11_hevc" and rj == {"rate_control": "CQP", "cqp": 14, "profile": "high"}, rj
    assert op.calc_crf(23, 1920, 1080) == 23 and op.calc_crf(23, 1280, 720) == 21
    warn = op.to_advanced(op.read_ini(POG_SIMPLE.replace("RecRBTime=45", "RecRBTime=20")))[3]
    assert warn == ["[SimpleOutput] RecRBTime='20', expected '45'"], warn
    try:
        op.to_advanced(op.read_ini(POG_SIMPLE.replace("Mode=Simple", "Mode=Advanced")))
        raise AssertionError("already Advanced: must refuse")
    except SystemExit:
        pass

    # run() advanced + rollback over the stand-in box
    with tempfile.TemporaryDirectory() as d:
        boxdir, bindir = os.path.join(d, "box"), os.path.join(d, "bin")
        os.makedirs(boxdir), os.makedirs(bindir)
        orig = b"\xef\xbb\xbf" + POG_SIMPLE.encode()
        open(os.path.join(boxdir, "basic.ini"), "wb").write(orig)
        open(os.path.join(boxdir, "recordEncoder.json"), "w").write('{"old": 1}')  # a stale one from the GUI
        state = os.path.join(d, "obs")
        open(state, "w").write("0")
        open(os.path.join(bindir, "ssh"), "w").write(PY_SSH)
        open(os.path.join(bindir, "scp"), "w").write(f"""#!/bin/sh
src="$2"; dst="$3"
case "$src" in pogwin:*) b=$(basename "$src"); [ -f {boxdir}/$b ] || exit 1; cp {boxdir}/$b "$dst";;
  *) cp "$src" {boxdir}/$(basename "$dst");; esac
""")
        os.chmod(os.path.join(bindir, "ssh"), 0o755), os.chmod(os.path.join(bindir, "scp"), 0o755)
        old = dict(os.environ)
        os.environ.update(PATH=bindir + os.pathsep + old["PATH"], FAKEBOX=boxdir, FAKESTATE=state)
        try:
            op.run(args("advanced", keyint=2, dry_run=True))
            assert open(os.path.join(boxdir, "basic.ini"), "rb").read() == orig
            op.run(args("advanced", keyint=2))
            raw = open(os.path.join(boxdir, "basic.ini"), "rb").read()
            assert raw.startswith(b"\xef\xbb\xbf") and b"Mode=Advanced" in raw and b"RecRBPrefix=Replay" in raw
            assert json.load(open(os.path.join(boxdir, "streamEncoder.json")))["keyint_sec"] == 2
            stamps = [f.split(".pog-")[1] for f in os.listdir(boxdir) if f.startswith("basic.ini.pog-")]
            assert len(stamps) == 1
            stamp = stamps[0]
            assert os.path.exists(os.path.join(boxdir, f"streamEncoder.json.pog-{stamp}.absent"))  # did not exist
            assert open(os.path.join(boxdir, f"recordEncoder.json.pog-{stamp}")).read() == '{"old": 1}'
            assert not os.path.exists(os.path.join(boxdir, "service.json"))
            open(state, "w").write("1")
            try:
                op.run(args("rollback", stamp=stamp))
                raise AssertionError("OBS running: rollback must refuse")
            except SystemExit as e:
                assert "OBS is running" in str(e)
            open(state, "w").write("0")
            op.run(args("rollback", stamp=stamp))
        finally:
            os.environ.clear()
            os.environ.update(old)
        assert open(os.path.join(boxdir, "basic.ini"), "rb").read() == orig  # byte for byte
        assert not os.path.exists(os.path.join(boxdir, "streamEncoder.json"))  # created by the change: removed
        assert open(os.path.join(boxdir, "recordEncoder.json")).read() == '{"old": 1}'


if __name__ == "__main__":
    main()
