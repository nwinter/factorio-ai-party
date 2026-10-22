#!/usr/bin/env python3
"""site/push_live.py's one-pusher lock (d22 batch89 AY2): python3 site/test_push_lock.py

A second push_live.py finds the lock held, says which pid holds it in its log and exits (3) before reading the token
or pushing; once the holder exits the lock is free again (flock goes with the process); --print takes no lock."""
import os, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import push_live  # noqa: E402


def main():
    with tempfile.TemporaryDirectory() as d:
        lock = os.path.join(d, "push.lock")
        holder = subprocess.Popen([sys.executable, "-c", "import sys, time; sys.path.insert(0, sys.argv[1]); import push_live; "
                                   "f, _ = push_live.take_lock(sys.argv[2]); print('held', flush=True); time.sleep(30)", HERE, lock],
                                  stdout=subprocess.PIPE, text=True)
        try:
            assert holder.stdout.readline().strip() == "held"
            r = subprocess.run([sys.executable, os.path.join(HERE, "push_live.py"), "--lock", lock, "--source", "http://127.0.0.1:9/x",
                                "--api", "http://127.0.0.1:9"], capture_output=True, text=True, timeout=30)
            assert r.returncode == 3, (r.returncode, r.stdout, r.stderr)
            assert f"another push_live.py holds {lock} (pid {holder.pid} since " in r.stdout and "this one exits" in r.stdout, r.stdout
            f, held = push_live.take_lock(lock)
            assert f is None and held.startswith(f"{holder.pid} since "), held
        finally:
            holder.kill()
            holder.wait()
        f, held = push_live.take_lock(lock)
        assert f is not None and held is None, "free once the holder is gone"
        assert open(lock).read().startswith(f"{os.getpid()} since ")
        f.close()
    print("push_live lock: ok (a second copy exits and names the holder; free after it exits)")


if __name__ == "__main__":
    main()
