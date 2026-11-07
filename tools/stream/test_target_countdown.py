#!/usr/bin/env python3
"""File-only countdown, wall-clock transition and edits/clears; fully offline."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from target_countdown import facts
import run_target


class CountdownTest(unittest.TestCase):
    def test_file_lifecycle_and_timezone(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp)
            path = run / 'target.json'
            self.assertIsNone(facts(run))
            target = {'goal': 'as far toward the Shattered Planet as Asterion can fly',
                      'at': '2026-11-07 07:00 PST', 'note': 'private operator note', 'by': 'private'}
            path.write_text(json.dumps(target))
            result = facts(run)
            self.assertEqual(result, {'goal': target['goal'], 'at': target['at'], 'at_epoch': 1794063600.0})
            target.update(goal='  Another ship / another destination  ', at='2026-11-08T01:00:00+02:00')
            path.write_text(json.dumps(target))
            self.assertEqual(facts(run)['goal'], target['goal'].strip())
            self.assertEqual(facts(run)['at_epoch'], run_target.epoch('2026-11-07 23:00 UTC'))
            successor = run / 'next'
            successor.mkdir()
            self.assertTrue(run_target.carry(run, successor))
            self.assertEqual(facts(successor), facts(run))
            path.unlink()
            self.assertIsNone(facts(run))
            for bad in ('null', '[]', '{', '{"goal":""}', '{"goal":"x","at":"garbage"}',
                        '{"goal":"x","at":"2026-99-07 07:00 PST"}',
                        '{"goal":"x","at":{}}', '{"goal":null,"at":"2026-11-07 07:00 PST"}'):
                path.write_text(bad)
                self.assertIsNone(facts(run), bad)

    def test_shared_browser_clock(self):
        js = r"""
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const src = fs.readFileSync(process.argv[1], 'utf8');
let now = 1000000, timer, cleared;
class Element {
  constructor() { this.children=[]; this.hidden=true; }
  appendChild(n) { this.children.push(n); }
  get firstChild() { return this.children[0]; }
  get lastChild() { return this.children[this.children.length-1]; }
  set textContent(v) { this.children=[]; this.text=v; }
  get textContent() { return this.children.length ? this.children.map(n=>n.textContent).join(' ') : this.text; }
  removeAttribute(k) { delete this[k]; }
}
const ctx={module:{exports:{}},Date:{now:()=>now},Number,document:{createElement:()=>new Element()},
  setInterval:(f,ms)=>{assert.equal(ms,1000);timer=f;return 42;},clearInterval:id=>{cleared=id;}};
vm.runInNewContext(src,ctx);
const api=ctx.module.exports, node=new Element(), widget=api.create(node);
let target={goal:'A changing destination',at:'2026-11-07 07:00 PST',at_epoch:1000+5*3600+12*60};
assert.equal(api.label(target,1000),'Final push in 5 h 12 min');
assert.equal(api.label(target,target.at_epoch-1),'Final push in < 1 min');
assert.equal(api.label(target,target.at_epoch),'Final push under way · 0 min elapsed');
assert.equal(api.label(target,target.at_epoch+3660),'Final push under way · 1 h 1 min elapsed');
for(const bad of [null,{}, {...target,at_epoch:'1000'}, {...target,at_epoch:Infinity}, {...target,goal:' '}])
  assert.equal(api.label(bad,1000),'');
widget.update(target); assert.equal(node.hidden,false); assert.match(node.textContent,/A changing destination/);
// Real timer path, no further SSE/poll frame, crosses the target second.
target={...target,at_epoch:1001}; widget.update(target);
now+=1000; timer(); assert.match(node.textContent,/under way · 0 min elapsed/);
now+=61000; timer(); assert.match(node.textContent,/1 min elapsed/);
// A fresh changed goal/time is rendered as plain text, never HTML.
widget.update({...target,goal:'<img src=x onerror=alert(1)>',at_epoch:2000});
assert.equal(node.lastChild.textContent,'<img src=x onerror=alert(1)>');
assert.match(node.firstChild.textContent,/Final push in/);
widget.update(null); assert.equal(node.hidden,true); assert.equal(node.textContent,'');
widget.update(target); now+=91000; timer(); assert.equal(node.hidden,true,'disconnect expires');
widget.update(target,91); assert.equal(node.hidden,true,'stale API response cannot renew clock');
widget.update(target,1); assert.equal(node.hidden,false);
widget.update(undefined); assert.equal(node.hidden,true,'old/missing snapshot clears');
widget.destroy(); assert.equal(cleared,42);
console.log('shared countdown: transition, autonomous ticking, edits, clears, stale data, text safety: ok');
"""
        subprocess.run(['node', '-e', js, str(HERE / 'static/target-countdown.js')], check=True)


if __name__ == '__main__':
    unittest.main()
