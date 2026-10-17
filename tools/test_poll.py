#!/usr/bin/env python3
"""tools/poll.py, the operator's poll CLI, against a fake API: python3 tools/test_poll.py

create from --file (the first poll, kept as tools/polls/first-poll.json) and from flags, with the token; list shows the
counts together and apart (viewers, agents); voters prints the log with the replaced votes; close; a refusal exits.
"""
import contextlib
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import poll  # noqa: E402

FIRST = os.path.join(HERE, "polls", "first-poll.json")
P = {"id": 1, "question": "Q?", "intro": "", "options": ["A", "B"], "details": ["", ""], "counts": [3, 1], "total": 4,
     "viewer_counts": [2, 1], "viewer_total": 3, "agent_counts": [1, 0], "agent_total": 1, "opens": 0, "closes": 4e9,
     "created_by": "operator", "status": "open", "left_s": 3 * 3600 + 5 * 60, "comments": []}


def run(argv, replies):
    calls = []

    def fetch(method, url, body=None, tok=None):
        calls.append((method, url, body, tok))
        return replies.pop(0)
    out = io.StringIO()
    code = 0
    with contextlib.redirect_stdout(out):
        try:
            poll.main(["--api", "https://api.test"] + argv, fetch=fetch)
        except SystemExit as e:
            code = e.code
    return calls, out.getvalue(), code


def main():
    os.environ["POG_LIVE_TOKEN"] = "t" * 20
    first = json.load(open(FIRST))
    # the first poll as given, every option with its details
    assert first["hours"] == 12 and len(first["options"]) == 5 and all(o["details"] for o in first["options"])
    calls, out, code = run(["create", "--file", FIRST], [(200, {"ok": True, "poll": P})])
    assert code == 0 and calls == [("POST", "https://api.test/v1/polls", first, "t" * 20)], calls
    assert "opened:" in out and "3 h 05 min left" in out, out
    calls, out, _ = run(["create", "--question", "Trains or belts?", "--option", "Trains", "--option", "Belts", "--hours", "6"],
                        [(200, {"ok": True, "poll": P})])
    assert calls[0][2] == {"question": "Trains or belts?", "options": ["Trains", "Belts"], "hours": 6.0}, calls
    _, _, code = run(["create", "--question", "One?", "--option", "only"], [])
    assert code and "two options" in str(code)
    calls, out, _ = run(["list"], [(200, {"open": [P], "closed": []})])
    assert calls[0][:2] == ("GET", "https://api.test/v1/polls") and calls[0][3] is None  # public: no token
    assert "0. A: 3 (viewers 2, agents 1)" in out and "4 votes (3 viewers, 1 agents)" in out, out
    votes = [{"id": 1, "t": 1792200000, "voter": "ab12", "name": "fan", "option": 0, "choice": "A", "comment": "", "current": 0, "hidden": 0, "agent": False},
             {"id": 2, "t": 1792200060, "voter": "ab12", "name": "fan", "option": 1, "choice": "B", "comment": "changed", "current": 1, "hidden": 0, "agent": False},
             {"id": 3, "t": 1792200090, "voter": "agent:grok", "name": "Grok", "option": 0, "choice": "A", "comment": "", "current": 1, "hidden": 0, "agent": True}]
    calls, out, _ = run(["voters", "1"], [(200, {"poll": P, "votes": votes})])
    assert calls[0][1] == "https://api.test/v1/polls/1/voters" and calls[0][3] == "t" * 20
    assert "fan [ab12]: 0. A (replaced)" in out and "B | changed" in out and "AI Grok [agent:grok]" in out, out
    calls, out, _ = run(["close", "1"], [(200, {"ok": True, "poll": dict(P, status="closed", left_s=0)})])
    assert calls[0][:2] == ("POST", "https://api.test/v1/polls/1/close") and "[closed" in out
    _, _, code = run(["close", "9"], [(404, {"error": "no such poll"})])
    assert "404: no such poll" in str(code)
    calls, out, _ = run(["hide-comment", "2"], [(200, {"ok": True})])
    assert calls[0][2] == {"action": "hide_comment", "id": 2}
    calls, out, _ = run(["ideas"], [(200, {"ideas": [{"id": 4, "t": 1792200000, "name": "idea fan", "question": "Trains?",
                                                      "options": ["yes", "no"], "hours": 6}], "last_id": 4})])
    assert "idea 4" in out and "Trains? | yes / no | 6 h" in out, out
    print("poll.py: ok (create from the file and from flags, list with viewers and agents apart, voters, close, ideas)")


if __name__ == "__main__":
    main()
