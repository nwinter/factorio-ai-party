#!/usr/bin/env python3
"""A line that answers a viewer by name wakes no agent (viewers.py Relay.to_viewer; Nick d20 07:28: the host's "Caleb:
yeah I'm mostly along for the ride too, ..." went to Muse as "@muse Caleb: yeah ...", Muse being the agent his line two
minutes before went to): python3 tools/stream/test_viewer_reply.py

1. "Caleb: ...", "caleb, ..." from anyone, after Caleb wrote in chat: no agent, delivered as written; Clef is not asked.
2. A name no viewer used, a viewer last seen over VOICE_WINDOW ago, or an agent's name ("Muse: ...", "sonnet, ...") is
   routed as before.
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import viewers as V  # noqa: E402
from test_operator_viewers import ROSTER, NOW, FakeHarness, line, setup  # noqa: E402


def main():
    feed, relay, h, inbox = setup()
    feed.ingest([line(1, "Caleb", "@luna Isn't there a space age armor better than power armor?", NOW)], [], now=NOW)
    for k in range(5):
        relay.step(NOW + 2 * k)
    t = NOW + 120
    assert relay.to_viewer("Caleb: yeah I'm mostly along for the ride too", t)
    assert relay.to_viewer("caleb, good point", t)
    assert relay.unaddressed({"text": "Caleb: yeah"}, t) is False
    msg = {"text": "Caleb: yeah I'm mostly along for the ride too, almost all the harness changes are requested"}
    relay.asked["nickwinter"] = ("muse", t - 100)  # his last line went to Muse two minutes ago
    assert relay.address(msg, "nickwinter", t) == ([], []), relay.address(msg, "nickwinter", t)
    # routed as before
    for text in ("Muse: how could we end the biter problem?", "sonnet, did we stop making metallurgic science?",
                 "Note: the camera is great", "Kai: hi"):
        assert not relay.to_viewer(text, t), text
    assert not relay.to_viewer("Caleb: late reply", NOW + relay.VOICE_WINDOW + 10)
    assert relay.address({"text": "Muse: how could we end the biter problem?"}, "nickwinter", t)[0] == ["muse"]
    print("viewer reply: ok (\"Caleb: ...\" wakes no agent after Caleb wrote; agent names, unknown names and old "
          "viewers are routed as before)")


if __name__ == "__main__":
    main()
