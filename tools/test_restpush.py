#!/usr/bin/env python3
"""A rest pushed to the runtime (d20 batch50 B1, viewer Aurora): python3 tools/test_restpush.py

tools/agy-quota.py writes DIR/resting.json before the loop sleeps; it also sends the rest to the world its ./fh names as
an operator `rest` request (rests.lua: the teammates line and tell replies say "resting until HH:MM (pace|quota)"), and
`done` when the next turn starts. No ./fh with a world and bot, or POG_REST_PUSH=off: nothing is sent; a failed send is
a context.log line. No RCON here: send_operator is replaced.
"""
import importlib.util
import json
import os
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location("agy_quota", os.path.join(ROOT, "tools", "agy-quota.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

FH = '''#!/usr/bin/env bash
export POG_WORLD=n POG_FH_SOCKET="/x/runs/shift45/.sock/gemini.sock"
exec "/x/bin/fh" "$@" --bot gemini --journal "/x/runs/shift45/gemini/journal.jsonl"
'''


def main():
    os.environ.pop("POG_REST_PUSH", None)
    sent = []
    m.send_operator = lambda world, req: sent.append((world, req)) or {"agent": req["args"]["agent"]}
    with tempfile.TemporaryDirectory() as d:
        # no ./fh: the file only
        m.rest(d, 300, "pace", used=50.0)
        assert os.path.exists(os.path.join(d, "resting.json")) and sent == [], sent
        open(os.path.join(d, "fh"), "w").write(FH)
        json.dump({"tick": 1, "at": 0, "speed": 48.46}, open(os.path.join(d, ".fh-pace.json"), "w"))
        m.rest(d, 300, "pace", used=50.0)
        row = json.load(open(os.path.join(d, "resting.json")))
        (world, req), = sent
        a = req["args"]
        assert world == "n" and req["operator"] is True and req["action"] == "rest", req
        assert a == {"agent": "gemini", "until_clock": time.strftime("%H:%M", time.localtime(row["until"])), "until_s": 300,
                     "reason": "pace", "ticks_per_s": 48.46}, a
        # the next turn: done
        line = m.woke(d)
        assert line.startswith("You rested") and sent[-1][1]["args"] == {"agent": "gemini", "done": True}, sent[-1]
        # a stale speed (over 10 min old) is left out: the runtime takes 60
        old = time.time() - 900
        os.utime(os.path.join(d, ".fh-pace.json"), (old, old))
        m.rest(d, 3600, "quota", resets="09:10:00")
        assert "ticks_per_s" not in sent[-1][1]["args"] and sent[-1][1]["args"]["reason"] == "quota", sent[-1]
        # a failed send: a context.log line, the loop goes on
        def boom(world, req):
            raise ConnectionRefusedError(61, "Connection refused")
        m.send_operator = boom
        m.woke(d)
        ev = [json.loads(x) for x in open(os.path.join(d, "context.log"))]
        assert ev[-1]["event"] == "rest-push-failed" and ev[-1]["done"] is True and "refused" in ev[-1]["error"], ev[-1]
        # off
        m.send_operator = lambda world, req: sent.append((world, req))
        n = len(sent)
        os.environ["POG_REST_PUSH"] = "off"
        m.rest(d, 300, "pace")
        assert len(sent) == n
        os.environ.pop("POG_REST_PUSH")
    print("rest push: ok (the rest and its end go to the runtime as operator requests; none without ./fh or when off)")


if __name__ == "__main__":
    main()
