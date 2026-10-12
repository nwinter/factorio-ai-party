#!/usr/bin/env python3
"""An agent's answer to a viewer is recognised by the viewer's short name and voiced: python3 tools/stream/test_viewer_answer.py

shift01 16:09: craigNZ830 asked "Will they make a proper big base in the end??"; Astra answered "Yes, Craig—the base is
growing north now..." in plain chat. The hosts matched only the whole handle, judged the line logistics, and it stayed
text on the overlay.
"""
import inspect, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import caster

assert caster.viewer_short_names("craigNZ830") == ["craignz830", "craignz", "craig"]
assert caster.viewer_short_names("noscopersscope3718") == ["noscopersscope3718", "noscopersscope"]
assert caster.viewer_short_names("Al") == ["al"]

cls = next(c for _, c in inspect.getmembers(caster, inspect.isclass) if hasattr(c, "answers_viewer") and hasattr(c, "diff"))
d = cls.__new__(cls)
d.recent_viewers = {"craignz830": {"name": "craigNZ830", "text": "Will they make a proper big base in the end??", "t": 100.0}}
assert cls.answers_viewer(d, "Yes, Craig—the base is growing north now.", 200.0)["name"] == "craigNZ830"
assert cls.answers_viewer(d, "@craigNZ830 yes", 200.0)
assert not cls.answers_viewer(d, "Craigslist furnaces are done", 200.0)
assert not cls.answers_viewer(d, "Yes, Craig", 100.0 + 601)  # older than 10 minutes
d.recent_viewers = {"al": {"name": "Al", "text": "hi", "t": 100.0}}
assert not cls.answers_viewer(d, "all furnaces are lit", 200.0)  # a 3-letter-or-shorter name needs its @

# the chat event for an answer is marked aloud, so talk_pick voices it whatever its kind
voice, label, _ = caster.talk_pick({"text": "Yes, Craig, forty-eight furnaces now.", "agent": "astra", "aloud": True})
assert voice and label == "aloud"
print("viewer answers: ok (short names, @, stale, short handles; an answer is voiced like --aloud)")
