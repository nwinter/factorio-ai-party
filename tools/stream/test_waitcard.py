#!/usr/bin/env python3
"""Current wait cards, offline and deterministic: python3 tools/stream/test_waitcard.py."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import waitcard as w
from model import Model
from work import WorkFeed
from live import LiveSource
from selftest import FakeHarness

NOW = 1792069200.0
TICK = 600000


def facts(**kwargs):
    return dict({"until_tick": TICK + 36000, "idle_s": 300, "condition": "crafting_done",
                 "wait_estimates": [{"condition": "crafting_done", "eta_s": 120, "as_of_tick": TICK,
                                     "basis": "remaining hand crafting queue"}]}, **kwargs)


def req(action, args=None, id="x"):
    return {"event": "request", "request": {"id": id, "action": action, "args": args or {}}}


def reply(result, tick=TICK, id="x"):
    from datetime import datetime, timezone
    return {"at": datetime.fromtimestamp(NOW, timezone.utc).isoformat(), "event": "response",
            "response": {"id": id, "ok": True, "tick": tick, "result": result}}


def formatting():
    r = w.record(facts(), TICK, NOW, "sleep")
    assert w.line(r, TICK, NOW) == "waiting: crafting done, ~2 min (idle 5 min)"
    assert w.line(r, TICK + 5400, NOW + 30) == "waiting: crafting done, ~30 s (idle 5 min)"
    assert w.line(r, TICK, NOW + 30) == w.line(r, TICK, NOW)  # paused: game time and measured idle unchanged
    assert "checking" in w.line(r, TICK + 7200, NOW + 30)  # ETA passing is not a confirmed wake
    assert w.line(r, TICK, NOW + 46) is None
    assert w.line(r, r["until_tick"], NOW) is None
    for changes in ({"woke": "told"}, {"already_met": True}, {"repeat": True}, {"outcome": "timed_out"}):
        assert w.record(facts(**changes), TICK, NOW, "sleep") is None
    unknown = w.record(facts(wait_estimates=[{"condition": "platform_arrived Starling", "no_estimate": "not departed"}]), TICK, NOW, "sleep")
    assert w.line(unknown, TICK, NOW) == "waiting: platform arrived Starling, ETA unknown (idle 5 min)"
    plain = w.record({"until_tick": TICK + 3600, "idle_s": 0}, TICK, NOW, "sleep")
    assert w.line(plain, TICK, NOW) == "waiting: sleep, up to 1 min (idle 0 s)"
    any_wait = w.record(facts(wait_estimates=[{"condition": "crafting_done", "eta_s": 20}, {"condition": "alert", "no_estimate": "event"}]), TICK, NOW, "sleep")
    assert "crafting done or alert, ~20 s" in w.line(any_wait, TICK, NOW)
    long = w.record(facts(wait_estimates=[{"condition": "item_count\n" + "copper " * 100, "eta_s": 120}] * 8), TICK, NOW, "sleep")
    assert "\n" not in w.line(long, TICK, NOW) and len(w.line(long, TICK, NOW)) < 115


def feed():
    with tempfile.TemporaryDirectory() as root:
        path = Path(root, "astra", "journal.jsonl")
        path.parent.mkdir()
        path.write_text(json.dumps(req("sleep")) + "\n" + json.dumps(reply(facts(sleeping_s=600))) + "\n")
        feed = WorkFeed(root, ["astra"])
        feed.waits.status("astra", {"active": dict(facts(), kind="wait_until")}, TICK + 1, NOW)
        assert feed.poll() == []  # bootstrap recovers a current wait but replays no work
        assert feed.waits.current("astra", TICK + 1, NOW)["kind"] == "wait_until"  # startup keeps the fresh status
        feed.waits.status("astra", {"active": False}, TICK + 2, NOW)
        assert feed.waits.current("astra", TICK + 2, NOW)["kind"] == "sleep"
        end = json.dumps(reply(facts(slept_s=300, woke="told")))
        with path.open("a") as f:
            f.write('malformed\n[]\n' + end[:80])
        assert feed.poll() == []
        assert feed.waits.current("astra", TICK, NOW)
        with path.open("a") as f:
            f.write(end[80:] + "\n")
        feed.poll()
        assert feed.waits.current("astra", TICK, NOW) is None
        path.write_text(json.dumps(reply(facts(sleeping_s=600))) + "\n")  # truncated/replaced
        feed.poll()
        assert feed.waits.current("astra", TICK, NOW)
        feed.waits.status("astra", {"active": dict(facts(), kind="wait_until")}, TICK + 1, NOW)
        feed.waits.status("astra", {"active": False}, TICK + 2, NOW)
        assert feed.waits.current("astra", TICK + 2, NOW)["kind"] == "sleep"  # body and sleep independent
        feed.waits.ingest("astra", reply(facts(slept_s=300, woke="elapsed"), tick=TICK + 3))
        assert feed.waits.current("astra", TICK + 3, NOW) is None
        feed.waits.ingest("astra", req("status"))
        feed.waits.ingest("astra", reply({"active": dict(facts(), kind="wait_until")}, tick=TICK))
        assert feed.waits.current("astra", TICK + 3, NOW) is None  # older journal cannot resurrect a completed wait
        for i in range(200):
            feed.waits.ingest("astra", req("inspect", id=str(i)))
        assert len(feed.waits.requests["astra"]) == 128


def live_and_model():
    class WaitHarness(FakeHarness):
        def dispatch(self, action, *args, **kwargs):
            result, tick = super().dispatch(action, *args, **kwargs)
            if action == "status":
                result.update(tick=tick, active=False, queues={"body": {"active": {"action": "wait_until"}, "waiting": facts()}})
            return result, tick

    with patch("time.time", return_value=NOW):
        baseline = FakeHarness()
        LiveSource("test", {"agents": {"astra": {}}}, harness=baseline).observe()
        harness = WaitHarness()
        src = LiveSource("test", {"agents": {"astra": {}}}, harness=harness)
        obs = src.observe()
        assert baseline.calls == harness.calls  # exactly the existing RCON call count and actions
    assert obs["agents"][0]["wait"]["condition"] == "crafting_done"
    m = Model({"agents": {"astra": {}, "sol": {}}})
    obs["chat"] = [{"seq": 11, "tick": TICK - 60, "from": "astra", "aloud": True,
                    "text": "The gears are queued. I'm waiting for crafting to finish."},
                   {"seq": 12, "tick": TICK, "from": "sol", "text": "I'm waiting for coal."},
                   {"seq": 13, "tick": TICK, "from": "astra", "text": "The shuttle is waiting for cargo."}]
    m.ingest(obs, NOW)
    a = m.snapshot(NOW)["agents"][0]
    assert a["wait_line"] == "waiting: crafting done, ~2 min (idle 5 min)"
    assert a["wait_reason"] == "I'm waiting for crafting to finish."
    chat = list(m.chat)
    assert w.reason(chat, "astra", TICK, NOW + 301) is None
    assert w.reason(chat, "astra", TICK + 301 * 60, NOW) is None
    assert w.reason([dict(chat[0], viewer="v")], "astra", TICK, NOW) is None
    assert w.reason([dict(chat[0], text="You should wait for crafting.")], "astra", TICK, NOW) is None
    m.ingest({"agents": [{"name": "astra", "wait": None}]}, NOW + 1)
    a = m.snapshot(NOW + 1)["agents"][0]
    assert a["wait_line"] is None and a["wait_reason"] is None
    src.waits.status("astra", {"active": False, "queues": {"body": {"paused": True}}}, TICK + 1, NOW)
    assert src.waits.current("astra", TICK + 1, NOW) is None


def overlay():
    # Run the actual card renderer, including updates on the same DOM nodes.
    js = r'''
const fs = require('fs'), assert = require('assert');
const code = fs.readFileSync(process.argv[1], 'utf8');
function el(tag, cls='', text='') {
  const flags = new Set(cls.split(' '));
  return {tag, children: [], textContent: text, dataset: {}, style: {}, clientWidth: 80, scrollWidth: 90,
    classList: {toggle(k,v) {v ? flags.add(k) : flags.delete(k);}, add(k) {flags.add(k);}, remove(k) {flags.delete(k);}, contains(k) {return flags.has(k);}},
    append(...xs) {this.children.push(...xs);}, appendChild(x) {this.children.push(x);}, remove() {}};
}
const box=el('div'), $=()=>box, cards=new Map(); let researchCard=null;
const avatar=()=>el('img'), fillAvatar=()=>{}, applyPalette=()=>{}, clean=x=>x, humanItem=x=>x, shortNum=String;
const setText=(node,text)=>node.textContent=text, SLOT_LABEL={main:'main'};
const document={body:{dataset:{}}, createTextNode:x=>x};
eval(code.slice(code.indexOf('  function renderCards(s)'), code.indexOf('  function sparkPath')));
const a={name:'astra', display_name:'Astra Long Name', harness:'Codex', activity:'thinking',
         wait_line:'waiting: crafting done, ~2 min (idle 5 min)', location:'north'};
renderCards({agents:[a]});
const c=cards.get('astra');
assert.equal(c.waitLabel.textContent + c.waitTime.textContent,a.wait_line);
assert.equal(c.waitTime.textContent,', ~2 min (idle 5 min)');
assert(c.root.classList.contains('squeezed') && c.root.classList.contains('waiting'));
const before=c.root.children[1].children.length;
a.wait_line=null; a.activity='acting'; a.action='walking';
renderCards({agents:[a]});
assert.equal(c.txt.textContent,'walking'); assert(!c.root.classList.contains('waiting'));
assert.equal(c.root.children[1].children.length,before); // same three rows, no extra height
'''
    subprocess.run(["node", "-e", js, str(HERE / "static/overlay.js")], check=True)
    css = (HERE / "static/overlay.css").read_text()
    assert '.card.squeezed.waiting .doing .txt { flex: 1 1 0; }' in css
    assert '.card.waiting .doing .where { display: none; }' in css


if __name__ == "__main__":
    formatting()
    feed()
    live_and_model()
    overlay()
    print("wait cards: ok (restart, partial journal, wake/timeout, game-time ETA, measured idle, queue status, quotes, no extra RCON, overlay)")
