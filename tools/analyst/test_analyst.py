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


class SpaceAgeKBTest(unittest.TestCase):
    def test_space_age_facts(self):
        k = KB("space-age-2.0.77")
        self.assertEqual(k.default_machine("electronics"), "assembling-machine-2")  # circuits moved category
        self.assertIn("gravity is 0", k.recipe_text("space-science-pack"))
        self.assertNotIn("hand-craftable", k.recipe_text("space-science-pack"))
        self.assertIn("build an asteroid collector", k.tech_text("space-science-pack"))
        self.assertEqual(k.entities["rocket-silo"]["rocket_parts_required"], 50)


class HistoryTest(unittest.TestCase):
    def test_runs_load(self):
        s = H.load_runs()
        self.assertIn("shake1", s)
        self.assertIn("techs", H.at_text(s, 40))

    def test_shifts_are_one_series(self):
        """A resumed run (runs/RUN/resumed-from) continues its world: one series under the first shift's name, and a
        live shift excludes its earlier shifts from the benchmarks."""
        import tempfile
        tmp = tempfile.mkdtemp()
        def run(name, ticks, prev=None):
            os.makedirs(os.path.join(tmp, name))
            with open(os.path.join(tmp, name, "scores.jsonl"), "w") as f:
                for t in ticks:
                    f.write(json.dumps({"world": "n", "score": {"tick": t, "research_done": ["automation"] * (t > 0)}}) + "\n")
            if prev:
                open(os.path.join(tmp, name, "resumed-from"), "w").write(prev + "\n")
        run("w1", [3600, 7200]); run("w2", [7200, 10800, 14400], "w1"); run("w3", [18000], "w2"); run("other", [3600])
        roots = H.ROOTS
        H.ROOTS = [tmp]
        try:
            s = H.load_runs()
            self.assertEqual(sorted(s), ["other", "w1"])
            self.assertEqual([r["tick"] for r in s["w1"]], [3600, 7200, 10800, 14400, 18000])
            self.assertIn("shifts w1 + w2 + w3", H.label("w1"))
            self.assertEqual(sorted(H.load_runs(exclude=os.path.join(tmp, "w3"))), ["other"])
            open(os.path.join(tmp, "w3", "start.log"), "w").write("05:18:52 world n: resumed at tick 15000 (game 4m)\n")
            w = H.world_text(os.path.join(tmp, "w3"))
            self.assertIn("resumed shift", w)
            self.assertIn("save at game minute 4.", w)           # the resume tick, not the first score row (minute 5)
            self.assertIn("w1 game minutes 0 to 2,", w)
            self.assertIn("automation 1", w)                     # the world's own milestones, all shifts
            self.assertIsNone(H.world_text(os.path.join(tmp, "w1")))
        finally:
            H.ROOTS = roots

    def test_test_runs_are_named_and_not_benchmarks(self):
        """shake4 mistake 8: 'co-op' aired from coop1 comparisons nobody had introduced."""
        for name, text in H.LABELS.items():
            self.assertTrue(text.startswith("say: "), name)
        self.assertIn("two-agent co-op test", H.label("2026-10-10-coop1"))
        s = H.load_runs(teams_only=True)
        self.assertIn("shake1", s)
        self.assertFalse([k for k in s if k.startswith("2026-10-10-")])


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
        lvl = {"text": "Logistics 2 comes next; two assembling machine 2s and automation-2 are done.", "facts": {}}
        self.assertIsNone(analyst.point_problem(lvl))       # level names are names, not figures
        self.assertIn("3", analyst.point_problem({"text": "Logistics 2 needs 3 more minutes.", "facts": {}}))

    def test_test_run_comparisons_dropped(self):
        import analyst
        for t in ("Science is 13.7. Coop1 had 13.6 here.", "This team is at 14.3, close to the co-op run's 13.5.",
                  "Nineteen in the co-op!", "Turns1 had 17.5."):
            self.assertIn("co-op test", analyst.point_problem({"text": t, "facts": {"a": 13.7, "b": 13.6, "c": 14.3, "d": 13.5, "e": 17.5}}), t)
        self.assertIsNone(analyst.point_problem({"text": "Luna and Sol co-operate on the trunk belt.", "facts": {}}))
        self.assertIsNone(analyst.point_problem({"text": "Good co-op play: Luna staged plates for Astra.", "facts": {}}))

    def test_game_minute_is_a_fact(self):
        import analyst
        reply = {"talking_points": [
            {"text": "At minute 20 they make 7.9 packs a minute.", "facts": {"spm": 7.9}},
            {"text": "Green science usually comes around minute 28.", "facts": {}}]}
        reply, dropped = analyst.clean_reply(reply, minute=19)
        self.assertEqual([p["facts"].get("game_minute") for p in reply["talking_points"]], [20])
        self.assertIn("28", dropped[0]["why"])  # a forecast minute still needs its own fact
        reply = {"judgement": {"pace": "behind", "text": "Only 25 technologies are done at 2h11.", "facts": {"techs": 25}},
                 "talking_points": [{"text": "Blue usually starts by 3h05.", "facts": {}}]}
        reply, dropped = analyst.clean_reply(reply, minute=131)
        self.assertEqual(reply["judgement"]["facts"].get("game_time"), "2h11")  # the game clock, a resumed shift
        self.assertEqual(len(dropped), 1)                                      # another clock time is a claim


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
