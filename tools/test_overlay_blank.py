#!/usr/bin/env python3
"""The overlay checks' item 3 of batch349 cp2 (viewer Aurora site:5516): python3 tools/test_overlay_blank.py

With the real service handler and a stub OBS (as tools/test_overlay_check.py):
- a disabled scene item: start and watch read it each pass (tools/obs.py enable-overlay), switch it on and say so;
- a page connected but blank (no render report): counts as not connected; start runs the recovery round
  ("connected but drew nothing"), watch after BLANK_S s of nothing drawn ("connected but has drawn nothing");
  status and the health line say "overlay NOT drawing";
- a failed round stays in the health line (the watch state's failed) until a round works.
"""
import json, os, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import overlay_check  # noqa: E402
import shift_change  # noqa: E402
import test_overlay_check as T  # noqa: E402


def main():
    with tempfile.TemporaryDirectory() as d:
        log, off, state = os.path.join(d, "obs.log"), os.path.join(d, "item-off"), os.path.join(d, "state.json")
        mode = {"draws_after": None}  # the command after which a page that draws connects
        stub = os.path.join(d, "obs")
        open(stub, "w").write(f"#!{sys.executable}\nimport os, sys\nopen({log!r}, 'a').write(' '.join(sys.argv[1:]) + '\\n')\n"
                              f"if sys.argv[1:] == ['enable-overlay']:\n"
                              f"    if os.path.exists({off!r}):\n        os.remove({off!r}); print('stream overlay: was off in stream, enabled (item 5)')\n"
                              f"    else:\n        print('stream overlay: on in stream (item 5)')\n"
                              f"else:\n    print('stream overlay: ok')\n")
        os.chmod(stub, 0o755)
        srv, audio = T.service()
        port = srv.server_address[1]
        url = f"http://127.0.0.1:{port}"
        pages = []

        def calls():
            return open(log).read().splitlines() if os.path.exists(log) else []

        def follow():  # a page that draws comes back after the command mode names
            seen = 0
            while True:
                c = calls()
                if len(c) > seen:
                    seen = len(c)
                    if mode["draws_after"] and c[-1] == mode["draws_after"]:
                        time.sleep(0.3)
                        pages.append(T.Page(port))
                time.sleep(0.05)
        threading.Thread(target=follow, daemon=True).start()
        env = dict(os.environ, POG_OC_OBS=stub, POG_OC_SLEEP="0.1", POG_TEST="1")

        def cli(*args):
            return subprocess.run([sys.executable, os.path.join(HERE, "overlay_check.py"), *args, "--service", url, "--state", state],
                                  capture_output=True, text=True, env=env, timeout=60)

        # 1. a disabled scene item: start switches it on and says so, then goes on as before
        open(off, "w").close()
        t0 = time.time()
        threading.Timer(0.3, lambda: pages.append(T.Page(port))).start()
        r = cli("start", "--since", str(t0), "--wait", "3")
        assert r.returncode == 0 and r.stdout.startswith("overlay: the scene item was off: enabled (stream overlay: was off in stream, enabled (item 5))"), r.stdout
        assert "overlay: connected 0 s after the reload" in r.stdout and not os.path.exists(off), r.stdout
        # watch: each pass reads it; off again: switched on, said, exit 1 for that pass
        open(off, "w").close()
        r = cli("watch")
        assert r.returncode == 1 and "OVERLAY: the scene item was off: enabled" in r.stdout, r.stdout
        r = cli("watch")
        assert r.returncode == 0 and not r.stdout, r.stdout
        for p in pages:
            p.close()
        pages.clear()

        # 2. a page connected but blank: start runs the round; a page that draws comes after the reload
        t1 = time.time() + 0.01
        threading.Timer(0.3, lambda: pages.append(T.Page(port, draws=False))).start()
        mode["draws_after"] = "reload-overlay"
        r = cli("start", "--since", str(t1), "--wait", "1")
        assert r.returncode == 0 and ("overlay: connected but drew nothing 1 s after the reload; toggled the source: not connected in 1 s; "
                                      "reloaded the page (refreshnocache): connected") in r.stdout, r.stdout
        for p in pages:
            p.close()
        pages.clear()
        mode["draws_after"] = None
        # watch: blank for BLANK_S s: the round; none brings it back: the failure kept for the health line
        blank = T.Page(port, draws=False)
        st = overlay_check.read(url)
        assert overlay_check.blank_for(st) is None, "connected under BLANK_S s: still loading"
        m = st["pages"]["main"]
        m["connected"] -= 61  # as if it connected 61 s ago (its stream still fresh), the earlier pages' renders before it
        m["rendered"] = (m.get("rendered") or 0) - 61
        assert overlay_check.blank_for(st) >= 60 and not overlay_check.live(st)
        import types
        a = types.SimpleNamespace(service=url, stale=120, wait=0.5, again=600, state=state, world=None)
        os.environ.update(POG_OC_OBS=stub, POG_OC_SLEEP="0.1")
        rc = overlay_check.watch_overlay(a, st)
        assert rc == 1 and json.load(open(state))["failed"].endswith("toggled the source again: not connected in 0.5 s"), open(state).read()
        os.environ["POG_OC_STATE"] = state
        line = shift_change.overlay_status(url + "/state.json")
        assert "the last recovery FAILED:" in line and "connected but has drawn nothing for" in line, line
        # status and the health line on a blank page: NOT drawing (bad)
        assert overlay_check.blank_for(overlay_check.read(url)) is None  # (live: still under 60 s)
        blank.close()
        # a round that works clears the failure
        mode["draws_after"] = "toggle-overlay"
        st = overlay_check.read(url)
        st["pages"]["main"]["connected"] -= 200
        st["pages"]["main"]["rendered"] = (st["pages"]["main"].get("rendered") or 0) - 200
        a.again = 0
        assert overlay_check.watch_overlay(a, st) == 0
        assert json.load(open(state))["failed"] is None
        assert "recovery FAILED" not in shift_change.overlay_status(url + "/state.json")
        print("overlay blank and disabled: the item switched on and said; a connected blank page recovered by start and watch; "
              "a failed round kept in the health line until one works: ok")


if __name__ == "__main__":
    main()
