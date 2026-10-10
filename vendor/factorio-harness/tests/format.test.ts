import { test } from 'node:test';
import assert from 'node:assert/strict';
import { formatCompact } from '../host/format.js';

test('failures keep the error and request ID, with hostile strings escaped in tables', () => {
  const output = formatCompact({ok:false,id:'retry-id',error:{code:'action_failed',message:'bad thing'},truncated:true,entities:[
    {name:'belt',position:{x:1,y:2},extra:null},
    {name:'line\n | spoof',position:{x:3.456,y:4},enabled:7},
  ]});
  assert.match(output,/^error: code=action_failed message="bad thing"\nid: retry-id\n/);
  assert.match(output,/name \| position \| enabled/);
  assert.match(output,/belt \| 1,2 \| -/);
  assert.match(output,/"line\\n \| spoof" \| 3.46,4 \| 7/);
});
test('success drops the envelope and omits false, null, and empty fields', () => {
  assert.equal(formatCompact({ok:true,id:'x',tick:5,result:{a:[],b:{},c:false,d:null,e:0,f:'null',g:'42'}}),
    'tick: 5\ne: 0\nf: "null"\ng: "42"\n');
});
test('positions, item stacks, and scalar records render inline', () => {
  const output = formatCompact({player:{position:{x:1.234,y:-2},inventory:[{name:'wood',quality:'normal',count:3},{name:'gear',quality:'rare',count:1}]},
    robots:{available:4,total:5}});
  assert.match(output,/player: position=1.23,-2 inventory=\[wood\*3, gear@rare\*1\]/);
  assert.match(formatCompact({inventory:[{name:'wood',count:3},{name:'gear',count:1}]}),/^inventory: wood\*3 gear\*1\n$/);
  assert.match(output,/robots: available=4 total=5/);
});
test('literal dotted keys cannot overwrite nested column paths', () => {
  const output = formatCompact([{a:{b:1,c:[1]},'a.b':2},{a:{b:3,c:[2]},'a.b':4}]);
  assert.match(output,/a.b \| a.c \| "a.b"/);
  assert.match(output,/1 \| \[1\] \| 2/);
  assert.match(output,/3 \| \[2\] \| 4/);
});
test('arrays of records nested inside records keep every row', () => {
  const base = (x: number, extra: Record<string, unknown> = {}) => ({spawners:2,absorbing:0,position:{x,y:-27},distance:205,direction:'E',...extra});
  const table = formatCompact({enemies:{bases:2,next:'soon',list:[base(338,{cloud_gap:1}),base(400)]}});
  assert.match(table,/enemies:\n  bases: 2\n  next: soon\n  list\[2\]: spawners \| absorbing \| position \| distance \| direction \| cloud_gap\n/);
  assert.match(table,/2 \| 0 \| 400,-27 \| 205 \| E \| -/);
  const single = formatCompact({enemies:{bases:1,list:[base(338)]}});
  assert.match(single,/list\[1\]:\n    0: spawners=2 absorbing=0 position=338,-27 distance=205 direction=E/);
});
