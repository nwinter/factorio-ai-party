#!/usr/bin/env python3
"""tools/win/resume-save.ps1 on the Windows box against a scratch instance: POG_WIN_TESTS=1 python3 tools/test_resume_save.py

Not offline: it needs the box (POG_WIN_HOST, default pogwin) and makes D:\\pog\\inst\\zz-resumetest (removed after), so it
runs only with POG_WIN_TESTS=1 and prints "skipped" otherwise or when the box is not reachable. Fake saves are small files whose times copy the crash-restart case of
shift12/13 (operator 17:00), relative to a stop time T:
- shift12.zip and shift13.zip at T-5h (a copy keeps its source's time: shift13 was copied from shift12's 10:48 save);
- shift12r.zip at T-4h (the crash restart's save) and shift13b.zip, its copy, with the same time;
- _autosave1..3 from T-1h to T-30m (the stale shift13 that ran from the 10:48 state), _autosave4 at T-2m.
Checks the old script's pick (shift13.zip: the trap) and the new one's in each case: an old stop-team's /server-save
into the loaded shift13b.zip, the new stop record (game.server_save into shift13.zip), a stop with no save after it,
an autosave 14 min after the stop save (accepted: autosaves every 15 minutes since d22 06:15), a world that ran on 20 min
after its stop (refused: -MaxGapMinutes 18), a crash with no stop record whose newest autosave is 14 min old, and the copy (-To) with its refusal when the target exists.
"""
import datetime
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import stop_save  # noqa: E402  (its ps() runs one PowerShell command on the box)

INST = "zz-resumetest"
DIR = f"D:\\pog\\inst\\{INST}"


def winps(*args, script=os.path.join(HERE, "win", "resume-save.ps1")):
    out = subprocess.run(["bash", os.path.join(HERE, "winps.sh"), script, *args], capture_output=True, text=True, cwd=ROOT,
                         timeout=120)
    return dict(l.split("=", 1) for l in out.stdout.splitlines() if "=" in l and not l.startswith("seen=")), out.stdout


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%S") + ".000Z"


def setup(files):
    """files: {name: utc datetime}; a fresh scratch instance with those saves and a mod list."""
    lines = [f"Remove-Item -Recurse -Force '{DIR}' -ErrorAction SilentlyContinue",
             f"New-Item -ItemType Directory -Force '{DIR}\\saves','{DIR}\\mods' | Out-Null",
             f"Set-Content -Encoding ascii '{DIR}\\mods\\mod-list.json' "
             "'{\"mods\":[{\"name\":\"base\",\"enabled\":true},{\"name\":\"space-age\",\"enabled\":true}]}'"]
    for name, t in files.items():
        p = f"{DIR}\\saves\\{name}"
        lines.append(f"Set-Content -Encoding ascii '{p}' '{name}'")
        lines.append(f"(Get-Item '{p}').LastWriteTimeUtc = [DateTime]::Parse('{iso(t)}', "
                     "[Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)")
    lines.append(f"(Get-ChildItem '{DIR}\\saves').Count")
    return stop_save.ps("; ".join(lines))


def main():
    if os.environ.get("POG_WIN_TESTS") != "1":
        print("skipped: POG_WIN_TESTS=1 runs it on the Windows box")
        return
    try:
        stop_save.ps("'ok'")
    except Exception as e:  # noqa: BLE001
        print(f"skipped: the Windows box is not reachable ({e})")
        return
    # The script before the 17:00 fix (the trap) and the 10-minute one before AJ1, pinned to their commits (main moves).
    old_script, ten_script = os.path.join(HERE, ".resume-save-old.ps1"), os.path.join(HERE, ".resume-save-ten.ps1")
    for path, rev in ((old_script, "6c637656"), (ten_script, "0b71cc61")):
        with open(path, "w") as f:
            f.write(subprocess.run(["git", "show", f"{rev}:tools/win/resume-save.ps1"], capture_output=True, text=True,
                                   cwd=ROOT, check=True).stdout)
    T = datetime.datetime(2026, 10, 15, 2, 55, 0)
    h, m = datetime.timedelta(hours=1), datetime.timedelta(minutes=1)
    crash = {"shift12.zip": T - 5 * h, "shift13.zip": T - 5 * h, "shift12r.zip": T - 4 * h, "shift13b.zip": T - 4 * h,
             "_autosave1.zip": T - h, "_autosave2.zip": T - 45 * m, "_autosave3.zip": T - 30 * m, "_autosave4.zip": T - 2 * m}
    try:
        # 1. An old stop-team: /server-save wrote the loaded shift13b.zip at the stop, and no stop record.
        files = dict(crash, **{"shift13b.zip": T})
        assert setup(files).endswith("8"), "setup"
        old, _ = winps("-Name", INST, "-From", "shift13", "-Check", script=old_script)
        assert old["save"] == "shift13.zip", old   # the trap: 5 hours back
        new, raw = winps("-Name", INST, "-From", "shift13", "-Check")
        assert new["save"] == "shift13b.zip" and "refuse" not in new, raw
        assert new["why"].startswith("the newest save (no stop record"), new
        print(f"old stop-team: the old script takes {old['save']}; the new one {new['save']} ({new['save_time']})")
        # 2. The new stop-team: game.server_save wrote shift13.zip at the stop; an autosave 20 s later.
        files = dict(crash, **{"shift13.zip": T + datetime.timedelta(seconds=3), "_autosave4.zip": T + datetime.timedelta(seconds=20)})
        setup(files)
        new, raw = winps("-Name", INST, "-From", "shift13", "-StopUtc", iso(T), "-StopSave", "shift13.zip", "-Check")
        assert new["save"] == "shift13.zip" and new["why"].startswith("the previous run's stop save"), raw
        assert new["stop_time"] == T.strftime("%Y-%m-%dT%H:%M:%SZ"), new
        # Without the save's name: the newest written after the stop.
        new, raw = winps("-Name", INST, "-From", "shift13", "-StopUtc", iso(T), "-Check")
        assert new["save"] == "_autosave4.zip", raw
        print("new stop-team: shift13.zip, the stop save")
        # 3. A stop with no save after it (the stop's save failed): refused, with the newest named.
        setup(crash)
        new, raw = winps("-Name", INST, "-From", "shift13", "-StopUtc", iso(T), "-StopSave", "shift13.zip", "-Check")
        assert "save" not in new and new["refuse"].startswith("no save written at or after the previous run's stop"), raw
        assert "_autosave4.zip" in new["refuse"], raw
        print(f"no save after the stop: refuse={new['refuse']}")
        # 4. An autosave 14 min after the stop save (15-minute autosaves, d22 06:15): the stop save, accepted; the old
        # script's 10 minutes refused it.
        files = dict(crash, **{"shift13.zip": T, "_autosave4.zip": T + 14 * m})
        setup(files)
        old, _ = winps("-Name", INST, "-From", "shift13", "-StopUtc", iso(T), "-StopSave", "shift13.zip", "-Check",
                       script=ten_script)
        assert "refuse" in old, old
        new, raw = winps("-Name", INST, "-From", "shift13", "-StopUtc", iso(T), "-StopSave", "shift13.zip", "-Check")
        assert new.get("save") == "shift13.zip" and "refuse" not in new, raw
        print("an autosave 14 min after the stop: shift13.zip (the old script refused it)")
        # The world ran on 20 min after its stop (autosaves after the stop save): refused.
        files = dict(crash, **{"shift13.zip": T, "_autosave4.zip": T + 20 * m})
        setup(files)
        new, raw = winps("-Name", INST, "-From", "shift13", "-StopUtc", iso(T), "-StopSave", "shift13.zip", "-Check")
        assert "older than the newest autosave _autosave4.zip" in new.get("refuse", ""), raw
        assert "by more than 18 min" in new["refuse"], raw
        print(f"ran on 20 min after the stop: refuse={new['refuse']}")
        # A crash (no stop record): the newest save, an autosave 14 min older than the crash, is taken.
        files = dict(crash, **{"_autosave4.zip": T - 14 * m})
        setup(files)
        new, raw = winps("-Name", INST, "-From", "shift13", "-Check")
        assert new.get("save") == "_autosave4.zip" and "refuse" not in new, raw
        print("a crash, newest autosave 14 min old: _autosave4.zip")
        # 5. The copy: shift14.zip from the stop save; a second copy is refused (the target exists).
        files = dict(crash, **{"shift13.zip": T + datetime.timedelta(seconds=3)})
        setup(files)
        new, raw = winps("-Name", INST, "-From", "shift13", "-To", "shift14", "-StopUtc", iso(T), "-StopSave", "shift13.zip")
        assert new.get("copied") == "shift14.zip" and new["save"] == "shift13.zip", raw
        assert stop_save.ps(f"Get-Content '{DIR}\\saves\\shift14.zip'") == "shift13.zip", "the copy holds shift13.zip"
        new, raw = winps("-Name", INST, "-From", "shift13", "-To", "shift14", "-StopUtc", iso(T), "-StopSave", "shift13.zip")
        assert "copied" not in new and "already exists" in raw, raw
        print("copy: shift14.zip from shift13.zip; again: refused (exists)")
    finally:
        stop_save.ps(f"Remove-Item -Recurse -Force '{DIR}' -ErrorAction SilentlyContinue")
        os.remove(old_script)
        os.remove(ten_script)
    print("resume-save on the box: ok")


if __name__ == "__main__":
    main()
