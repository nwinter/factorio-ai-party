#!/usr/bin/env python3
"""Offline handovers: normal, gate wait, failed save/start, stale data and final end."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools" / "stream"))
from shift_phase import facts


class PhaseTest(unittest.TestCase):
    def test_records(self):
        with tempfile.TemporaryDirectory() as d:
            run = Path(d) / "shift149"
            run.mkdir()
            shift = {"start": 1000, "end": 2000, "next": None, "next_exact": True}
            (run / "stream.json").write_text(json.dumps({"shift": shift}))
            self.assertFalse(facts(run)["started"])
            (run / "start.log").write_text("10:00:00 started: 0/9 agents\n")
            self.assertFalse(facts(run)["started"])
            (run / "start.log").write_text("10:00:00 started: 9/9 agents; private account detail\n")
            self.assertTrue(facts(run)["started"])
            (run / "stopped.json").write_text(json.dumps({"via": "failed", "stop_utc": "2026-11-07T07:59:00Z"}))
            self.assertFalse(facts(run)["stopped"])
            self.assertEqual(facts(run)["save_state"], "failed")
            (run / "stopped.json").write_text(json.dumps({"via": "game.server_save", "stop_utc": "2026-11-07T08:01:00Z", "save": "private/path"}))
            result = facts(run)
            self.assertTrue(result["stopped"])
            self.assertEqual(result["number"], 149)
            self.assertNotIn("private", json.dumps(result))
            (run / "stopped.json").write_text('{"via":')  # incomplete write cannot end the run
            self.assertFalse(facts(run)["stopped"])

    def test_browser_phases_and_countdown(self):
        js = r"""
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const phase = require(process.argv[1]);
const old = {number:147,start:1000,end:2000,next:2210,next_exact:true,started:true,save_state:'unconfirmed'};
const op = (t,text) => ({op:true,t,text});
const begin = op(2430,'Shift 147 handover began; shift 148 is starting (usually about 8 minutes). Save and startup are not confirmed yet.');
const live = op(2710,'Shift 148 is live: 9 agents playing.');
const failed = op(2600,'The start of shift 148 has hit a problem; the operator is on it, and the stream stays off until it is fixed.');
const resolve = (sh,t,events=[]) => phase.resolve(sh,t,events);
assert.equal(resolve(old,1999).phase,'live');
// A merge wait can outlast both scheduled times, whether state is fresh or stale.
for(const t of [2000,2200,2429]) assert.equal(resolve(old,t).phase,'pending');
assert.match(phase.label(resolve(old,2429)),/Handover pending · overdue 7 min/);
assert.equal(resolve(old,2430,[begin]).phase,'starting');
assert.equal(resolve(old,2600,[begin,failed]).phase,'failed');
assert.equal(resolve(old,3000,[begin]).phase,'starting'); // never infer live from elapsed time
assert.equal(resolve(old,2710,[begin,live]).phase,'live');
assert.equal(resolve(old,2710,[begin,live]).number,148);
assert.equal(resolve(old,2710,[{...live,op:false}]).phase,'pending'); // viewer cannot confirm
assert.equal(resolve(old,1999,[live]).phase,'live'); // future notice ignored
assert.equal(resolve(old,2100,[op(1500,'Shift 147 is live: 9 agents playing.')]).phase,'pending');
const next = {number:148,start:2500,end:16900,next:17100,started:false};
assert.equal(resolve(next,2600,[begin]).phase,'starting');
assert.equal(resolve(next,20000,[begin]).phase,'starting'); // a stuck startup stays unconfirmed
assert.equal(resolve({...next,started:true},2700,[begin]).phase,'live');
assert.equal(resolve({...old,stopped:true,save_state:'confirmed'},2450).number,148);
const final = {...old,next:null};
assert.equal(resolve(final,2100).phase,'pending');
assert.match(phase.label(resolve(final,2100)),/Run end pending/);
assert.equal(resolve({...final,save_state:'failed'},3000).phase,'failed');
assert.equal(resolve({...final,stopped:true,save_state:'confirmed'},3000,[begin,live]).phase,'ended');
// Execute the actual countdown renderer, including a browser left open at the deadline.
const src = fs.readFileSync(process.argv[2],'utf8');
const part = src.slice(src.indexOf('  function clock(t)'),src.indexOf('  // ------------------------------------------------------------------ state polling'));
let badge, node={};
const ctx={window:{PogShiftPhase:phase},Date,offlineStatus:null,chatMsgs:[],demo:false,
  ago:n=>Math.round(n/60)+' min ago', $:()=>node,setBadge:(tone,text)=>{badge=text;}};
vm.createContext(ctx); vm.runInContext(part,ctx);
const before=ctx.shiftText(old,true,1900), delayed=ctx.shiftText(old,false,2429);
assert.match(before,/Planned end/); assert.match(before,/next planned start/);
assert.match(delayed,/Handover pending/); assert.doesNotMatch(delayed,/ended|any minute|starts at/);
ctx.chatMsgs=[begin]; assert.match(ctx.shiftText(old,false,2500),/Shift 148 starting/);
ctx.chatMsgs=[begin,failed]; assert.match(ctx.shiftText(old,true,2650),/Handover failed/);
ctx.chatMsgs=[begin,live]; assert.match(ctx.shiftText(old,true,2750),/Shift 148 live/);
ctx.offlineStatus={shift:{...final,stopped:true,save_state:'confirmed'}};
assert.match(ctx.shiftText(ctx.currentShift(final),false,3000),/Run ended · save confirmed/);
assert.equal(ctx.currentShift(next).number,148); // an older static receipt cannot replace a successor
console.log('normal, delayed, failed, stale, final, authenticated notices and countdown: ok');
"""
        subprocess.run(["node", "-e", js, str(ROOT / "tools/stream/static/shift-phase.js"),
                        str(ROOT / "site/static/live.js")], check=True)

    def test_final_recap_has_no_next_team_transition(self):
        from unittest.mock import patch
        from shift_recap_air import ShiftRecap
        from serve import AudioHub
        with tempfile.TemporaryDirectory() as d:
            run = Path(d) / "shift149"
            run.mkdir()
            config = {"shift": {"start": 1000, "end": 2000, "next": None}}
            recap = ShiftRecap(run, config, AudioHub())
            with patch.object(recap, "schedule"), patch("shift_recap_air.Player") as player:
                recap.step(1990)
                recap.step(2100)
                player.assert_not_called()

    def test_recap_endpoint_requires_the_same_stop_receipt(self):
        import shift_recap as recap
        with tempfile.TemporaryDirectory() as d:
            run = Path(d)
            (run / "stream.json").write_text(json.dumps({"shift": {"start": 1000, "end": 2000, "next": None}}))
            self.assertTrue(recap.gather(run, 2100)["partial"])
            for via, partial in (("failed", True), ("game.server_save", False)):
                (run / "stopped.json").write_text(json.dumps({"via": via, "stop_utc": "1970-01-01T00:35:00Z"}))
                self.assertEqual(recap.gather(run, 2100)["partial"], partial)
            self.assertTrue(recap.gather(run, 2000)["partial"])  # planned end precedes actual stop

    def test_build_publishes_final_receipt_and_shared_renderer(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            run = root / "runs" / "shift149"
            run.mkdir(parents=True)
            (run / "scores.jsonl").write_text(json.dumps({"t": "2026-11-06T23:58:00", "score": {"tick": 3600}}) + "\n")
            (run / "stream.json").write_text(json.dumps({"shift": {"start": 1000, "end": 2000, "next": None}}))
            (run / "stopped.json").write_text(json.dumps({"via": "game.server_save", "stop_utc": "2026-11-07T08:01:00Z"}))
            content = json.loads((ROOT / "site/content/site.json").read_text())
            content["run_start"] = "shift149"
            (root / "content.json").write_text(json.dumps(content))
            cmd = [sys.executable, str(ROOT / "site/build.py"), "--runs-dir", str(root / "runs"),
                   "--out", str(root / "dist"), "--content", str(root / "content.json")]
            built = subprocess.run(cmd, capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr + built.stdout)
            status = json.loads((root / "dist/live/status.json").read_text())
            self.assertTrue(status["shift"]["stopped"])
            self.assertIsNone(status["shift"]["next"])
            html = (root / "dist/index.html").read_text()
            self.assertLess(html.index('/static/shift-phase.js'), html.index('/static/live.js'))
            self.assertEqual((root / "dist/static/shift-phase.js").read_bytes(),
                             (ROOT / "tools/stream/static/shift-phase.js").read_bytes())
            sys.path.insert(0, str(ROOT / "site"))
            from push_live import public_state
            self.assertEqual(public_state({"shift": status["shift"]})["shift"], status["shift"])


if __name__ == "__main__":
    unittest.main()
