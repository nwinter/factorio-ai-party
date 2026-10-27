#!/usr/bin/env python3
"""The private copy on the iMac (d27 batch279 IM): python3 tools/test_imac_copy.py

1. bin/fh and tools/pog.py: world `imac` is imac.local:27400 with ~/.config/pog/rcon-imac.pw; POG_RCON_HOST overrides
   the host; the other worlds stay on the tunnel (127.0.0.1).
2. tools/imac-copy.sh (a fake ssh): status says who holds the copy; start is refused while another holder's server
   runs, naming the holder; stop is refused for someone else without --force; a start needs a holder name; a start
   from imac:PATH copies that save on the iMac (no scp of a save).
3. tools/copy_bench.py reads the harness tick average and its own timing lines as the server logs them.
No network: ssh, scp and node are stubs on PATH.
"""
import json, os, re, stat, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)


def stub(d, name, body):
    p = os.path.join(d, name)
    with open(p, "w") as f:
        f.write("#!/bin/bash\n" + body + "\n")
    os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)


def env_with(d, **kw):
    return dict(os.environ, PATH=d + os.pathsep + os.environ["PATH"], **kw)


def worlds():
    d = tempfile.mkdtemp()
    stub(d, "node", 'echo "$FACTORIO_RCON_HOST $FACTORIO_RCON_PORT $FACTORIO_RCON_PASSWORD_FILE"')
    fh = os.path.join(ROOT, "bin", "fh")
    run = lambda **kw: subprocess.run([fh, "status"], env=env_with(d, **kw), capture_output=True, text=True).stdout.split()
    got = run(POG_WORLD="imac")
    assert got[:2] == ["imac.local", "27400"] and got[2].endswith("/.config/pog/rcon-imac.pw"), got
    assert run(POG_WORLD="imac", POG_RCON_HOST="<lan-ip>")[:2] == ["<lan-ip>", "27400"]
    assert run(POG_WORLD="n")[:2] == ["127.0.0.1", "27025"]
    assert run(POG_WORLD="b205", POG_RCON_PORT="27205")[:2] == ["127.0.0.1", "27205"]
    import pog
    assert pog.PORTS["imac"] == 27400 and pog.HOSTS == {"imac": "imac.local"}
    src = open(os.path.join(HERE, "pog.py")).read()
    assert 'Rcon(os.environ.get("POG_RCON_HOST") or HOSTS.get(a.world, "127.0.0.1"), port, pw)' in src
    print("1. world imac: imac.local:27400; the others on the tunnel: ok")


def script():
    d = tempfile.mkdtemp()
    held = json.dumps({"holder": "d20-mt274/batch278", "started": "2026-10-27 12:40:00 PDT", "pid": 4242,
                       "save": "world n _autosave9.zip", "checkout": "/x", "rcon": "imac.local:27400"})
    # a fake ssh: holder.json is there and pid 4242 runs; any other command is logged and succeeds
    log = os.path.join(d, "ssh.log")
    stub(d, "ssh", f'''args="$*"; echo "$args" >> {log}
case "$args" in
  *"cat '/Users/owner/pog-copy/holder.json'"*) [ -f {d}/free ] || echo '{held}' ;;
  *"kill -0 4242"*) exit 0 ;;
  *"kill -0 5151"*) exit 1 ;;
  *"for f in"*) echo /Applications/x/factorio ;;
  *nohup*) echo 5151 ;;
  *"cat > "*) cat > /dev/null ;;
esac''')
    stub(d, "rsync", f'echo "rsync $*" >> {log}')
    stub(d, "scp", f'echo "scp $*" >> {log}')
    stub(d, "python3", f'case "$*" in *pog.py*) echo "pog.py $*" >> {log}; exit 1 ;; esac; exec /usr/bin/env -u PATH {sys.executable} "$@"')
    sh = os.path.join(HERE, "imac-copy.sh")
    run = lambda *a: subprocess.run([sh, *a], env=env_with(d), capture_output=True, text=True)
    r = run("status")
    assert "held by d20-mt274/batch278 since 2026-10-27 12:40:00 PDT (save world n _autosave9.zip; pid 4242 running)" in r.stdout, r
    r = run("start", "d20-b205/batch279")
    assert r.returncode == 3 and "refused: imac.local's copy is held by d20-mt274/batch278" in r.stderr and \
        "one copy at a time per machine" in r.stderr, r
    assert "nohup" not in open(log).read(), "nothing started"
    r = run("stop", "d20-b205/batch279")
    assert r.returncode == 3 and "refused: held by d20-mt274/batch278, not d20-b205/batch279" in r.stderr, r
    assert "kill 4242" not in open(log).read() and "/quit" not in open(log).read()
    r = run("start")
    assert r.returncode != 0 and "usage: tools/imac-copy.sh start HOLDER" in r.stderr, r
    open(os.path.join(d, "free"), "w").close()
    assert run("status").stdout.strip() == "free: no copy running on imac.local"
    open(log, "w").close()
    r = run("start", "d20-b205/batch279", "imac:/Users/owner/pog-copy/ref/x.zip")
    sent = open(log).read()
    assert "cp '/Users/owner/pog-copy/ref/x.zip' '/Users/owner/pog-copy/saves/copy.zip'" in sent, sent
    assert not re.search(r"scp .*copy\.zip", sent) and "--start-server '/Users/owner/pog-copy/saves/copy.zip'" in sent, sent
    assert r.returncode == 1 and "the server exited" in r.stderr, r
    src = open(sh).read()
    assert "pkill" not in src and "killall" not in src and 'remote "kill $pid"' in src, "its own PID only"
    print("2. imac-copy.sh: who holds it; a second holder refused; stop only by its holder: ok")


def bench():
    import copy_bench as B
    line = ("  12.345 Script @__agent-harness__/runtime.lua:20601: agent-harness tick average over 600 ticks (9 bots, "
            "2 active actions): Duration: 0.412345ms")
    m = B.TICK_AVG.search(line)
    assert m and m.group(1) == "600" and float(m.group(2)) == 0.412345
    m = B.MARK.search("  80.1 Script @__level__/command-ran:1: COPYBENCH labs_nauvis 2 Duration: 21.5ms")
    assert m and m.groups() == ("labs_nauvis", "2", "21.5")
    print("3. copy_bench reads the tick average and its own timing lines: ok")


def main():
    worlds()
    script()
    bench()
    print("test_imac_copy: ok")


if __name__ == "__main__":
    main()
