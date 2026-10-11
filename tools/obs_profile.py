#!/usr/bin/env python3
"""The landscape stream's resolution, frame rate, encoder and bitrate in OBS's `pog` profile (docs/STREAM-1080P.md).

For the shift change, OBS CLOSED (OBS writes basic.ini on exit, so an edit made while it runs is lost):

  tools/.venv/bin/python tools/obs_profile.py show                 # read-only: the profile's video/output keys
  tools/.venv/bin/python tools/obs_profile.py advanced [--dry-run] # Simple -> Advanced output, keyframes every 2 s,
                                                                   # recording and replay buffer carried over
  tools/.venv/bin/python tools/obs_profile.py backups | rollback STAMP
  tools/.venv/bin/python tools/obs_profile.py 1080p --dry-run      # before/after of every key it would change
  tools/.venv/bin/python tools/obs_profile.py 1080p [--encoder nvenc|qsv] [--bitrate 12000] [--fps 30]
  tools/.venv/bin/python tools/obs_profile.py 720p                 # back to today's 1280x720 output, same encoder

Copies basic.ini (and, in Advanced output mode, streamEncoder.json) from the box over scp, edits them, keeps dated
copies on the box (*.pog-YYYYMMDD-HHMMSS) and copies them back. It never touches service.json: the stream stays on the
Custom RTMPS service (docs/SETUP.md: OBS 32.2.2's built-in YouTube service crashed OBS at stream start). The vertical
canvas shares the frame rate; its encoder and bitrate are `tools/vertical.py settings`.
"""
import argparse, configparser, io, json, os, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

PROFILE_ON_BOX = "C:/Users/player/AppData/Roaming/obs-studio/basic/profiles/pog"
# Simple output mode stores a short name, Advanced mode the encoder id (obs-qsv11: obs_qsv11_v2; OBS 30.2+ native
# NVENC: obs_nvenc_h264_tex). The dry run prints the current value: check it reads like these before writing.
ENCODERS = {"nvenc": ("nvenc", "obs_nvenc_h264_tex"), "qsv": ("qsv", "obs_qsv11_v2")}


def read_ini(text):
    cp = configparser.ConfigParser(interpolation=None, strict=False)
    cp.optionxform = str  # OBS's keys are case-sensitive (BaseCX, VBitrate)
    cp.read_string(text)
    return cp


def write_ini(cp):
    buf = io.StringIO()
    cp.write(buf, space_around_delimiters=False)  # OBS writes key=value
    return buf.getvalue()


def plan(cp, enc_json, preset, encoder=None, bitrate=None, fps=30):
    """-> (changes [(where, key, before, after)], new streamEncoder.json dict or None)."""
    out_w, out_h = (1920, 1080) if preset == "1080p" else (1280, 720)
    want = [("Video", "BaseCX", "1920"), ("Video", "BaseCY", "1080"),  # the overlay page and layout.json are 1920x1080
            ("Video", "OutputCX", str(out_w)), ("Video", "OutputCY", str(out_h)),
            ("Video", "FPSType", "0"), ("Video", "FPSCommon", str(fps))]
    mode = cp.get("Output", "Mode", fallback="Simple")
    new_json = None
    if mode == "Simple":
        if encoder:
            want.append(("SimpleOutput", "StreamEncoder", ENCODERS[encoder][0]))
        if bitrate:
            want.append(("SimpleOutput", "VBitrate", str(bitrate)))
    else:
        if encoder:
            want.append(("AdvOut", "Encoder", ENCODERS[encoder][1]))
        want.append(("AdvOut", "Rescale", "false"))  # scaling is the Video section's job
        new_json = dict(enc_json or {})
        if bitrate:
            new_json.update(bitrate=bitrate)
        new_json.update(rate_control="CBR", keyint_sec=2)
    changes = []
    for sec, key, val in want:
        before = cp.get(sec, key, fallback=None)
        if before != val:
            changes.append((f"basic.ini [{sec}]", key, before, val))
            if not cp.has_section(sec):
                cp.add_section(sec)
            cp.set(sec, key, val)
    if new_json is not None:
        for k, v in new_json.items():
            if (enc_json or {}).get(k) != v:
                changes.append(("streamEncoder.json", k, (enc_json or {}).get(k), v))
    return changes, new_json


# ---- Simple -> Advanced output (YouTube: keyframes every 4 s or less; Simple mode has no keyframe setting) --------
# shake7: Studio reported the horizontal feed's keyframe frequency 7.9 s (error) with Simple mode, QSV, keyint 0 (auto).
# Advanced mode reads the stream encoder's settings from streamEncoder.json (keyint_sec there) and the recording's from
# recordEncoder.json, both in the profile folder (OBS 32 frontend/utility/AdvancedOutput.cpp). Everything Simple mode
# did is carried over, from frontend/utility/SimpleOutput.cpp:
#   - stream: StreamEncoder (short name) -> AdvOut Encoder (id), CBR at VBitrate, preset QSVPreset/NVENCPreset2,
#     audio on mixer track 1 at ABitrate;
#   - recording: FilePath, RecFormat2, FileNameWithoutSpace, MuxerCustom -> AdvOut Rec*; RecQuality "Stream" shares
#     the stream encoder (AdvOut RecEncoder=none, RecAudioEncoder=none); "Small"/"HQ" use RecEncoder with CQP
#     CalcCRF(23 or 16) (minus up to 10 below a 2000 px diagonal) and the RecTracks mixes;
#   - replay buffer: RecRB, RecRBTime, RecRBSize -> AdvOut; RecRBPrefix/RecRBSuffix stay in [SimpleOutput], where
#     AdvancedOutput.cpp reads them too. It records with the recording encoder (the stream's when RecEncoder=none).
# Never touched: service.json (Custom RTMPS), [Video] AutoRemux, filename formatting, reconnect, delay.
SIMPLE_VIDEO = {"qsv": "obs_qsv11_v2", "qsv_hevc": "obs_qsv11_hevc", "qsv_av1": "obs_qsv11_av1",
                "nvenc": "obs_nvenc_h264_tex", "nvenc_hevc": "obs_nvenc_hevc_tex", "nvenc_av1": "obs_nvenc_av1_tex",
                "x264": "obs_x264", "x264_lowcpu": "obs_x264"}
SIMPLE_AUDIO = {"aac": "ffmpeg_aac", "opus": "ffmpeg_opus"}
EXPECT = {"RecFormat2": "mkv", "FilePath": "D:\\pog\\recordings", "RecRB": "true", "RecRBTime": "45", "RecRBSize": "512",
          "RecRBPrefix": "Replay", "ABitrate": "160"}  # what the operator said Simple mode does (2026-10-11)


def calc_crf(crf, out_w, out_h):
    """SimpleOutput.cpp CalcCRF (non-x264): lower the quality number below a 2000 px output diagonal."""
    cross = (out_w * out_w + out_h * out_h) ** 0.5
    return crf - int((1.0 - min(2000.0, cross) / 2000.0) * 10.0)


def to_advanced(cp, keyint=2, bitrate=None):
    """Plan Simple -> Advanced -> (changes, streamEncoder.json, recordEncoder.json or None, warnings)."""
    if cp.get("Output", "Mode", fallback="Simple") != "Simple":
        raise SystemExit("the profile is already in Advanced output mode: use `1080p`/`720p`, or `rollback`")
    so = lambda k, d=None: cp.get("SimpleOutput", k, fallback=d)  # noqa: E731
    warn = [f"[SimpleOutput] {k}={so(k)!r}, expected {v!r}" for k, v in EXPECT.items() if so(k) != v]
    senc = so("StreamEncoder", "x264")
    if senc not in SIMPLE_VIDEO:
        raise SystemExit(f"unknown Simple stream encoder {senc!r}: not converted")
    stream_json = {"rate_control": "CBR", "bitrate": int(bitrate or so("VBitrate", "2500")), "keyint_sec": keyint}
    preset = so("QSVPreset") if senc.startswith("qsv") else so("NVENCPreset2") if senc.startswith("nvenc") else None
    if preset:
        stream_json["preset" if senc.startswith("qsv") else "preset2"] = preset
    aenc = SIMPLE_AUDIO.get(so("StreamAudioEncoder", "aac"), "ffmpeg_aac")
    want = [("Output", "Mode", "Advanced"),
            ("AdvOut", "Encoder", SIMPLE_VIDEO[senc]), ("AdvOut", "ApplyServiceSettings", "true"),
            ("AdvOut", "Rescale", "false"), ("AdvOut", "TrackIndex", "1"), ("AdvOut", "AudioEncoder", aenc),
            ("AdvOut", "Track1Bitrate", so("ABitrate", "160")),
            ("AdvOut", "RecType", "Standard"), ("AdvOut", "RecFilePath", so("FilePath", "")),
            ("AdvOut", "RecFormat2", so("RecFormat2", "mkv")),
            ("AdvOut", "RecFileNameWithoutSpace", so("FileNameWithoutSpace", "false")),
            ("AdvOut", "RecRB", so("RecRB", "false")), ("AdvOut", "RecRBTime", so("RecRBTime", "20")),
            ("AdvOut", "RecRBSize", so("RecRBSize", "512")),
            ("AdvOut", "VodTrackEnabled", so("VodTrackEnabled", "false"))]
    if so("MuxerCustom"):
        want.append(("AdvOut", "RecMuxerCustom", so("MuxerCustom")))
    record_json = None
    quality = so("RecQuality", "Stream")
    if quality == "Stream":
        want += [("AdvOut", "RecEncoder", "none"), ("AdvOut", "RecAudioEncoder", "none"), ("AdvOut", "RecTracks", "1")]
    else:
        renc = so("RecEncoder", senc)
        if renc not in SIMPLE_VIDEO or renc.startswith("x264") or quality == "Lossless":
            raise SystemExit(f"Simple recording {quality!r} with {renc!r}: not converted (only Small/HQ on QSV/NVENC)")
        out_w = int(cp.get("Video", "OutputCX", fallback="1920"))
        out_h = int(cp.get("Video", "OutputCY", fallback="1080"))
        # Simple mode uses ICQ on QSV where the GPU offers it; CQP at the same number always works
        record_json = {"rate_control": "CQP", "cqp": calc_crf(16 if quality == "HQ" else 23, out_w, out_h), "profile": "high"}
        want += [("AdvOut", "RecEncoder", SIMPLE_VIDEO[renc]),
                 ("AdvOut", "RecAudioEncoder", SIMPLE_AUDIO.get(so("RecAudioEncoder", "aac"), "ffmpeg_aac")),
                 ("AdvOut", "RecTracks", so("RecTracks", "1"))]
        tracks = int(so("RecTracks", "1"))
        for i in range(6):
            if tracks & (1 << i):
                want.append(("AdvOut", f"Track{i + 1}Bitrate", so("ABitrate", "160")))
    changes = []
    for sec, key, val in want:
        before = cp.get(sec, key, fallback=None)
        if before != val:
            changes.append((f"basic.ini [{sec}]", key, before, val))
            if not cp.has_section(sec):
                cp.add_section(sec)
            cp.set(sec, key, val)
    for name, js in (("streamEncoder.json", stream_json), ("recordEncoder.json", record_json)):
        for k, v in (js or {}).items():
            changes.append((name, k, None, v))
    return changes, stream_json, record_json, warn


def show(cp, enc_json):
    for sec, keys in (("Output", ["Mode"]), ("Video", ["BaseCX", "BaseCY", "OutputCX", "OutputCY", "ScaleType",
                                                        "FPSType", "FPSCommon", "AutoRemux"]),
                      ("SimpleOutput", ["StreamEncoder", "VBitrate", "ABitrate", "QSVPreset", "RecQuality", "RecEncoder",
                                        "FilePath", "RecFormat2", "RecRB", "RecRBTime", "RecRBSize", "RecRBPrefix"]),
                      ("AdvOut", ["Encoder", "Rescale", "TrackIndex", "Track1Bitrate", "RecEncoder", "RecFilePath",
                                  "RecFormat2", "RecRB", "RecRBTime", "RecRBSize"])):
        print(f"[{sec}] " + "  ".join(f"{k}={cp.get(sec, k, fallback='-')}" for k in keys))
    if enc_json is not None:
        print("streamEncoder.json", json.dumps({k: enc_json.get(k) for k in ("bitrate", "rate_control", "keyint_sec",
                                                                               "preset2", "profile") if k in enc_json}))


PROFILE_FILES = ("basic.ini", "streamEncoder.json", "recordEncoder.json")


def backup_all(box, stamp):
    """Dated copies of the profile files on the box; a file that does not exist gets NAME.pog-STAMP.absent, so a
    rollback deletes what the change created."""
    win = PROFILE_ON_BOX.replace("/", "\\")
    for name in PROFILE_FILES:
        f = f"{win}\\{name}"
        r = box("ssh", f'if exist "{f}" (copy /Y "{f}" "{f}.pog-{stamp}") else (type nul > "{f}.pog-{stamp}.absent")')
        if r.returncode:
            raise SystemExit(f"could not back up {name} on the box: {r.stdout} {r.stderr}")
    return [f"{n}.pog-{stamp}" for n in PROFILE_FILES]


def rollback(box, stamp):
    win = PROFILE_ON_BOX.replace("/", "\\")
    r = box("ssh", f'if exist "{win}\\basic.ini.pog-{stamp}" (echo found)')
    if "found" not in r.stdout:
        raise SystemExit(f"no backup basic.ini.pog-{stamp} in {PROFILE_ON_BOX}: see `obs_profile.py backups`")
    for name in PROFILE_FILES:
        f = f"{win}\\{name}"
        r = box("ssh", f'if exist "{f}.pog-{stamp}" (copy /Y "{f}.pog-{stamp}" "{f}" && echo restored) '
                       f'else if exist "{f}.pog-{stamp}.absent" ((if exist "{f}" del "{f}") & echo removed)')
        print(f"{name}: {(r.stdout.strip().splitlines() or ['unchanged'])[-1]}")
        if r.returncode:
            raise SystemExit(f"rollback of {name} failed: {r.stdout} {r.stderr}")


def run(a):
    from vertical import box
    host = os.environ.get("POG_WIN_HOST", "pogwin")
    if a.cmd == "backups":
        r = box("ssh", f'dir /b /o:d "{PROFILE_ON_BOX.replace("/", chr(92))}\\*.pog-*"')
        stamps = sorted({line.split(".pog-")[1].split(".")[0] for line in r.stdout.splitlines() if ".pog-" in line})
        print("\n".join(stamps) or "no backups")
        return
    if a.cmd != "show":
        r = box("ssh", 'tasklist /FI "IMAGENAME eq obs64.exe" /NH')
        if r.returncode or "obs64.exe" in r.stdout:
            raise SystemExit("OBS is running on the box (or tasklist failed): exit OBS first (File > Exit); OBS rewrites "
                             f"basic.ini when it exits. {r.stdout.strip()} {r.stderr.strip()}")
    if a.cmd == "rollback":
        return rollback(box, a.stamp)
    tmp = tempfile.mkdtemp()
    ini_local, json_local = os.path.join(tmp, "basic.ini"), os.path.join(tmp, "streamEncoder.json")
    r = box("scp", "-q", f"{host}:{PROFILE_ON_BOX}/basic.ini", ini_local)
    if r.returncode:
        raise SystemExit(f"could not copy {PROFILE_ON_BOX}/basic.ini: {r.stderr.strip()}")
    raw = open(ini_local, "rb").read()
    bom = raw.startswith(b"\xef\xbb\xbf")
    cp = read_ini(raw.decode("utf-8-sig"))
    enc_json = None
    if cp.get("Output", "Mode", fallback="Simple") != "Simple":
        r = box("scp", "-q", f"{host}:{PROFILE_ON_BOX}/streamEncoder.json", json_local)
        enc_json = json.loads(open(json_local, encoding="utf-8-sig").read()) if r.returncode == 0 else {}
    if a.cmd == "show":
        return show(cp, enc_json)
    if a.cmd == "advanced":
        changes, stream_json, record_json, warn = to_advanced(cp, a.keyint, a.bitrate)
        for where, key, before, after in changes:
            print(f"{where} {key}: {before} -> {after}")
        for w in warn:
            print("CHECK:", w)
        print("[SimpleOutput] RecRBPrefix/RecRBSuffix stay (the replay buffer reads them in Advanced mode too); "
              f"[Video] AutoRemux stays {cp.get('Video', 'AutoRemux', fallback='false (unset)')}; service.json untouched")
        if a.dry_run:
            print("dry run: nothing written")
            return
        stamp = time.strftime("%Y%m%d-%H%M%S")
        saved = backup_all(box, stamp)
        files = [("basic.ini", (b"\xef\xbb\xbf" if bom else b"") + write_ini(cp).encode("utf-8")),
                 ("streamEncoder.json", json.dumps(stream_json).encode())]
        if record_json:
            files.append(("recordEncoder.json", json.dumps(record_json).encode()))
        for name, data in files:
            local = os.path.join(tmp, name)
            open(local, "wb").write(data)
            r = box("scp", "-q", local, f"{host}:{PROFILE_ON_BOX}/{name}")
            if r.returncode:
                raise SystemExit(f"copy of {name} failed: {r.stderr.strip()}; undo: obs_profile.py rollback {stamp}")
        print(f"written ({', '.join(n for n, _ in files)}); backups {', '.join(saved)}")
        print(f"undo (OBS closed): tools/.venv/bin/python tools/obs_profile.py rollback {stamp}")
        return
    changes, new_json = plan(cp, enc_json, a.cmd, a.encoder, a.bitrate, a.fps)
    for where, key, before, after in changes:
        print(f"{where} {key}: {before} -> {after}")
    if not changes:
        print("nothing to change")
        return
    if a.dry_run:
        print("dry run: nothing written")
        return
    stamp = time.strftime("%Y%m%d-%H%M%S")
    win = PROFILE_ON_BOX.replace("/", "\\")
    names = ["basic.ini"] + (["streamEncoder.json"] if new_json is not None and enc_json else [])
    for name in names:
        r = box("ssh", f'copy /Y "{win}\\{name}" "{win}\\{name}.pog-{stamp}"')
        if r.returncode:
            raise SystemExit(f"could not back up {name} on the box: {r.stdout} {r.stderr}")
    with open(ini_local, "wb") as f:
        f.write((b"\xef\xbb\xbf" if bom else b"") + write_ini(cp).encode("utf-8"))
    uploads = [(ini_local, "basic.ini")]
    if new_json is not None:
        with open(json_local, "w", encoding="utf-8") as f:
            json.dump(new_json, f)
        uploads.append((json_local, "streamEncoder.json"))
    for local, name in uploads:
        r = box("scp", "-q", local, f"{host}:{PROFILE_ON_BOX}/{name}")
        if r.returncode:
            raise SystemExit(f"copy back of {name} failed: {r.stderr.strip()}; compare with {name}.pog-{stamp}")
    print(f"written; previous copies: {', '.join(n + '.pog-' + stamp for n in names)} in {PROFILE_ON_BOX}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["show", "advanced", "1080p", "720p", "backups", "rollback"])
    ap.add_argument("stamp", nargs="?", help="rollback: the YYYYMMDD-HHMMSS of the backup (see `backups`)")
    ap.add_argument("--keyint", type=int, default=2, help="advanced: seconds between keyframes (YouTube: 4 or less)")
    ap.add_argument("--encoder", choices=sorted(ENCODERS), help="stream encoder (default: leave as is)")
    ap.add_argument("--bitrate", type=int, help="stream video Kbps, CBR (default: leave as is)")
    ap.add_argument("--fps", type=int, default=30, choices=[30, 60], help="frame rate (both canvases)")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    if a.cmd == "rollback" and not a.stamp:
        ap.error("rollback needs the backup's stamp (obs_profile.py backups lists them)")
    run(a)


if __name__ == "__main__":
    main()
