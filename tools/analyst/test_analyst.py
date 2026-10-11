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


class YoungGameTest(unittest.TestCase):
    def test_rates_before_minute_ten(self):
        import game as G
        snap = {"tick": 8 * 3600, "items": {"iron-plate": {"total": 400, "m10": 400, "used10": 80, "h1": 400}}}
        it = G.young_game(snap)["items"]["iron-plate"]
        self.assertAlmostEqual(it["m10"] / 10, 50)      # 400 plates in 8 minutes, not 40 a minute
        self.assertAlmostEqual(it["h1"] / 60, 50)
        old = {"tick": 30 * 3600, "items": {"iron-plate": {"total": 900, "m10": 300, "h1": 900}}}
        it = G.young_game(old)["items"]["iron-plate"]
        self.assertEqual(it["m10"], 300)                 # the ten-minute window is full
        self.assertAlmostEqual(it["h1"] / 60, 30)


class ViewerQuestionsTest(unittest.TestCase):
    def test_is_question(self):
        from analyst_board import is_question
        for t in ("how many labs do they have?", "what's next after oil", "Rook, why is copper short", "is this space age?"):
            self.assertTrue(is_question(t), t)
        for t in ("lol", "go astra go", "this base is tidy", "??"):
            self.assertFalse(is_question(t), t)

    def test_picker_rate_and_staleness(self):
        from analyst_board import QuestionPicker
        p = QuestionPicker(every=150, max_age=60, retry=20)
        lane = [{"id": 1, "text": "how many labs do they have?", "t": 1000},
                {"id": 2, "text": "what comes after green science?", "t": 1040},
                {"id": 3, "text": "astra mine the rocks now?", "t": 1041, "order": True},
                {"id": 4, "text": "nice", "t": 1042}]
        self.assertEqual(p.pick(lane, 1050)["id"], 2)       # newest question, orders and comments ignored
        p.skipped(1060)
        self.assertIsNone(p.pick(lane, 1070))               # retry hold
        self.assertIsNone(p.pick(lane, 1081))               # id 1 is now 81 s old: stale
        lane.append({"id": 5, "text": "why is power low?", "t": 1100})
        self.assertEqual(p.pick(lane, 1101)["id"], 5)
        p.answered(1110)
        lane.append({"id": 6, "text": "who is winning?", "t": 1200})
        self.assertIsNone(p.pick(lane, 1201))               # one answer per 150 s
        lane.append({"id": 7, "text": "who builds the rocket?", "t": 1250})
        self.assertEqual(p.pick(lane, 1261)["id"], 7)

    def test_answer_checks_and_board(self):
        import analyst
        from analyst_board import AnalystBoard, questions_on
        v = {"id": "m1", "name": "fan", "text": "how many labs?", "t": 1000}
        self.assertIsNone(analyst.answer_problem({"question": "How many labs?", "answer": "They have 6 labs."}, v, 1010, 60))
        self.assertIn("skipped", analyst.answer_problem({"skip": "off-topic"}, v, 1010, 60))
        self.assertIn("stale", analyst.answer_problem({"question": "q", "answer": "a"}, v, 1200, 60))
        self.assertIn("Reply with ONLY a JSON object", analyst.viewer_system())
        b = AnalystBoard()
        b.answer({"msg_id": "m1", "viewer": "fan", "question": "How many labs?", "answer": "They have 6 labs."})
        self.assertEqual(b.public()["answers"][0]["viewer"], "fan")  # offered before the first cycle too
        b.post({"talking_points": [], "viewer_questions": {"on": True}})
        self.assertTrue(questions_on(b.public()))
        self.assertEqual(b.public(now=__import__("time").time() + 200)["answers"], [])  # expired


if __name__ == "__main__":
    unittest.main(verbosity=1)
