"""tools/expedition.py (d29 batch336 FL7): the expedition clock line the briefs carry beside the deadline paragraph."""
import json, os, sys, tempfile, time, unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import brief  # noqa: E402
import expedition  # noqa: E402

REPLY = {"ok": True, "tick": 81178855, "shift": 99, "expedition": {"tick": 81178855, "edge_to_shattered_km": 4000000, "platforms": [
    {"platform": "Resolute", "from": "aquilo", "to": "solar-system-edge", "progress": 0.25, "km_left": 4450000},
    {"platform": "Scout", "at": "solar-system-edge", "km_left": 4000000}]}}


class ExpeditionTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        os.environ["TZ"] = "America/Los_Angeles"; time.tzset()

    def test_line_with_target_and_platforms(self):
        at = expedition.run_target.epoch("2026-10-29 04:58 PDT")
        expedition.save(self.dir, REPLY, now=at)
        with open(os.path.join(self.dir, "target.json"), "w") as f:
            json.dump({"goal": "the Shattered Planet", "at": "2026-10-30 23:59 PDT", "by": "Nick", "kind": "soft"}, f)
        line = expedition.line(self.dir)
        self.assertEqual(line, "Expedition clock, read at this shift's start (Thu Oct 29 04:58 PDT): the world's game time is "
                         "375h49m; the run's target (Nick, soft): the Shattered Planet by Fri Oct 30 23:59 PDT, 43 h 1 m after that; "
                         "Resolute: on aquilo to solar-system-edge, 25% along, 4,450,000 km from the Shattered Planet by the edge; "
                         "Scout: stopped at solar-system-edge, 4,000,000 km from the Shattered Planet. `status` gives the target's time left now.")

    def test_no_platform_no_target(self):
        expedition.save(self.dir, {"expedition": {"tick": 216000, "edge_to_shattered_km": 4000000, "platforms": []}})
        line = expedition.line(self.dir)
        self.assertIn("the world's game time is 1h00m; no platform of ours is at the solar system edge, at the Shattered Planet or on a connection to either (solar-system-edge to shattered-planet: 4,000,000 km).", line)
        self.assertNotIn("status", line)

    def test_nothing_saved_no_line(self):
        self.assertIsNone(expedition.save(self.dir, {"ok": True}))
        self.assertEqual(expedition.line(self.dir), "")
        self.assertNotIn("{{EXPEDITION}}", brief.core("astra", "", ""))
        self.assertIn("Expedition clock", brief.core("astra", "", "", expedition="Expedition clock, read at ..."))

    def test_brief_puts_it_after_the_deadline_paragraph(self):
        text = brief.core("astra", "", "", expedition="Expedition clock X.")
        i, j = text.find("show what is still open."), text.find("Expedition clock X.")
        self.assertTrue(0 < i < j and j - i < 40, (i, j))


if __name__ == "__main__":
    unittest.main()
