#!/usr/bin/env python3
"""Offline tests for the analyst's knowledge, history, MCP server and point checks (no game, no model).

  python3 tools/analyst/test_analyst.py
"""
import json, os, subprocess, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, "tools", "stream"))
sys.dont_write_bytecode = True
from kb import KB  # noqa: E402
import history as H  # noqa: E402


class KBTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.kb = KB()

    def test_counts(self):
        self.assertGreater(len(self.kb.recipes), 200)
        self.assertGreater(len(self.kb.techs), 190)

    def test_aliases(self):
        self.assertEqual(self.kb.resolve("green science"), "logistic-science-pack")
        self.assertEqual(self.kb.resolve("Electronic circuit"), "electronic-circuit")

    def test_ratio_green(self):
        need, raw, drills = self.kb.ratio("logistic-science-pack", 60)
        self.assertAlmostEqual(need["logistic-science-pack"]["machines"], 8.0)  # 6 s, speed 0.75
        self.assertAlmostEqual(raw["iron-ore"], 330)
        self.assertAlmostEqual(drills["iron-ore"], 11)

    def test_ratio_assembler1(self):
        need, _, _ = self.kb.ratio("automation-science-pack", 60, assembler="assembling-machine-1")
        self.assertAlmostEqual(need["automation-science-pack"]["machines"], 10.0)

    def test_trigger_tech(self):
        txt = self.kb.tech_text("oil-processing")
        self.assertIn("mine crude oil", txt)

    def test_path(self):
        order, total, secs, trig = self.kb.path("oil-processing")
        self.assertEqual(order[-1], "oil-processing")
        self.assertIn("fluid-handling", order)
        order2, _, _, _ = self.kb.path("oil-processing", done=order[:-1])
        self.assertEqual(order2, ["oil-processing"])

    def test_research_never_lost_note(self):
        self.assertIn("nothing is lost", self.kb.tech_text("automation"))


class HistoryTest(unittest.TestCase):
    def test_runs_load(self):
        s = H.load_runs()
        self.assertIn("shake1", s)
        self.assertIn("techs", H.at_text(s, 40))


class McpTest(unittest.TestCase):
    def test_protocol(self):
        msgs = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "kb_ratio", "arguments": {"item": "red science", "per_minute": 30}}},
                {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "game_snapshot", "arguments": {}}},
                {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "kb_path", "arguments": {"goal": "chemical science pack"}}}]
        env = dict(os.environ, ANALYST_REPLAY=os.path.join(REPO, "runs", "shake1"), ANALYST_AT="40")
        p = subprocess.run([sys.executable, os.path.join(HERE, "mcp_server.py")], input="\n".join(json.dumps(m) for m in msgs) + "\n",
                           capture_output=True, text=True, env=env, timeout=60)
        out = [json.loads(l) for l in p.stdout.splitlines()]
        self.assertEqual([o["id"] for o in out], [1, 2, 3, 4, 5])
        names = {t["name"] for t in out[1]["result"]["tools"]}
        self.assertTrue({"kb_ratio", "game_snapshot", "history_at"} <= names)
        self.assertIn("automation science pack", out[2]["result"]["content"][0]["text"])
        self.assertIn("0h38m", out[3]["result"]["content"][0]["text"])
        txt = out[4]["result"]["content"][0]["text"]
        self.assertIn("chemical-science-pack", txt)
        self.assertNotIn("automation-science-pack >", txt)  # done in shake1 by minute 40, so not needed again


class PointsTest(unittest.TestCase):
    def test_numbers_must_be_in_facts(self):
        import analyst
        ok = {"text": "Fifteen SPM at 40 minutes, shake1 had 11.", "facts": {"spm": 15, "minute": 40, "shake1_spm": 11}}
        bad = {"text": "They make 22 packs a minute.", "facts": {"spm": 15}}
        self.assertIsNone(analyst.point_problem(ok))
        self.assertIn("22", analyst.point_problem(bad))


class BoardTest(unittest.TestCase):
    def test_post_pick_use(self):
        from analyst_board import AnalystBoard, pick_point, point_facts
        b = AnalystBoard()
        b.post({"game_minute": 40, "headline": "h", "talking_points": [
            {"kind": "comparison", "topic": "pace", "text": "15 SPM; shake1 had 11.", "facts": {"spm": 15, "shake1": 11}, "priority": 3, "ttl_s": 300},
            {"kind": "explainer", "topic": "trig", "text": "Oil processing is a trigger tech.", "facts": {}, "priority": 1, "ttl_s": 300}]})
        view = b.public()
        p = pick_point(view)
        self.assertEqual(p["topic"], "pace")
        f = point_facts(p)
        self.assertIn("pace", f)  # eng/audio's check_line needs it for past-run comparisons
        b.mark_used(p["id"])
        self.assertEqual(pick_point(b.public())["topic"], "trig")
        b.post({"talking_points": [{"kind": "explainer", "topic": "trig", "text": "new", "facts": {}, "ttl_s": 300}]})
        self.assertEqual([x["text"] for x in b.public()["talking_points"]], ["new"])  # same topic replaced


if __name__ == "__main__":
    unittest.main(verbosity=1)
