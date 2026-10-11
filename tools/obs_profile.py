#!/usr/bin/env python3
"""The landscape stream's resolution, frame rate, encoder and bitrate in OBS's `pog` profile (docs/STREAM-1080P.md).

For the shift change, OBS CLOSED (OBS writes basic.ini on exit, so an edit made while it runs is lost):

  tools/.venv/bin/python tools/obs_profile.py show                 # read-only: the profile's video/output keys
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


def show(cp, enc_json):
    for sec, keys in (("Output", ["Mode"]), ("Video", ["BaseCX", "BaseCY", "OutputCX", "OutputCY", "ScaleType",
                                                        "FPSType", "FPSCommon"]),
                      ("SimpleOutput", ["StreamEncoder", "VBitrate", "ABitrate", "RecEncoder", "RecQuality"]),
                      ("AdvOut", ["Encoder", "Rescale", "TrackIndex", "RecEncoder"])):
        print(f"[{sec}] " + "  ".join(f"{k}={cp.get(sec, k, fallback='-')}" for k in keys))
    if enc_json is not None:
        print("streamEncoder.json", json.dumps({k: enc_json.get(k) for k in ("bitrate", "rate_control", "keyint_sec",
                                                                               "preset2", "profile") if k in enc_json}))


def run(a):
    from vertical import box
    host = os.environ.get("POG_WIN_HOST", "pogwin")
    if a.cmd != "show":
        r = box("ssh", 'tasklist /FI "IMAGENAME eq obs64.exe" /NH')
        if r.returncode or "obs64.exe" in r.stdout:
            raise SystemExit("OBS is running on the box (or tasklist failed): exit OBS first (File > Exit); OBS rewrites "
                             f"basic.ini when it exits. {r.stdout.strip()} {r.stderr.strip()}")
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
    ap.add_argument("cmd", choices=["show", "1080p", "720p"])
    ap.add_argument("--encoder", choices=sorted(ENCODERS), help="stream encoder (default: leave as is)")
    ap.add_argument("--bitrate", type=int, help="stream video Kbps, CBR (default: leave as is)")
    ap.add_argument("--fps", type=int, default=30, choices=[30, 60], help="frame rate (both canvases)")
    ap.add_argument("--dry-run", action="store_true")
    run(ap.parse_args())


if __name__ == "__main__":
    main()
