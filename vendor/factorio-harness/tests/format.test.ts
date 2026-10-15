import { test } from 'node:test';
import assert from 'node:assert/strict';
import { formatCompact, actionHelp, paginate, finalLine } from '../host/format.js';

test('fh help ACTION: one action in about 1 KB; an unknown name lists the actions it resembles', () => {
  const describe = {actions:{craft:{recipe:'recipe name', count:'1..1000 (default 1)', returns:'queued, '+'x'.repeat(400), note:'n'},
    craftable:{recipes:'x'}, move_to:{position:'{x,y}', tolerance:'0.25..10', ticks:'1..36000'.repeat(40)}}};
  const craft = actionHelp(describe, 'craft');
  assert.match(craft, /^craft: fh call craft --args '\{\.\.\.\}'\n  count: 1\.\.1000 \(default 1\)\n  recipe: recipe name\nreturns: queued, x+\.\.\.\nnote: n\n$/);
  assert.ok(Buffer.byteLength(craft) <= 1100);
  const move = actionHelp(describe, 'move_to');
  assert.match(move, /^move_to: .*\n  position: \{x,y\}\n/);
  const ticks = move.split('\n').find(l => l.startsWith('  ticks: ')) ?? '';
  assert.ok(ticks.endsWith('...') && ticks.length <= 160, ticks);
  assert.equal(actionHelp(describe, 'craftt'), 'unknown action craftt; did you mean: craft (3 actions: fh help ACTION)\n');
  assert.ok(Buffer.byteLength(actionHelp(describe, 'craft', 200)) <= 260);
  // The runtime's examples (Luna, shift11: fh help launch / transfer): first, whole, keys sorted as the runtime writes calls.
  const launch = {actions:{launch:{position:'{x,y} of the silo', platform:'platform name', note:'n'.repeat(300),
    examples:[{position:{y:14.5, x:65.5}, platform:'Sunward'}]}}};
  const help = actionHelp(launch, 'launch', 300);
  assert.match(help, /^launch: fh call launch --args '\{\.\.\.\}'\nexample: fh call launch --args '\{"platform":"Sunward","position":\{"x":65\.5,"y":14\.5\}\}'\n/);
  assert.ok(!help.includes('[object Object]'));
});
test("a reply's lines (inspect compact) print one to a line, unquoted (Muse, shift13)", () => {
  const out = formatCompact({ok:true, id:'x', result:{lines:['gun-turret (57,-182): working; health 400/400; ammo: firearm-magazine*10',
    '(5,5): entity not found at (5,5)'], count:2}});
  assert.equal(out, 'lines[2]:\n  gun-turret (57,-182): working; health 400/400; ammo: firearm-magazine*10\n  (5,5): entity not found at (5,5)\ncount: 2\n');
  // Other string lists stay inline.
  assert.equal(formatCompact({ok:true, id:'x', result:{clusters:['a b', 'c d']}}), 'clusters: ["a b", "c d"]\n');
});
test('long compact replies come in pages; the final error:/warning: line stays last', () => {
  assert.deepEqual(paginate('short\n'), {shown:'short\n'});
  const lines = Array.from({length:600}, (_, i) => `row ${i}: ${'z'.repeat(40)}`);
  const { shown, rest } = paginate(lines.join('\n') + '\nwarning: not done: 3\n');
  assert.ok(Buffer.byteLength(shown) < 8400, String(Buffer.byteLength(shown)));
  assert.match(shown, /^row 0: /);
  assert.match(shown, /\n\[\d+ more lines, \d+ KB: \.\/fh more\]\nwarning: not done: 3\n$/);
  assert.ok(rest && rest.endsWith('row 599: ' + 'z'.repeat(40) + '\nwarning: not done: 3\n'));
  const firstRest = rest!.split('\n')[0] ?? '';
  assert.ok(shown.includes('\n' + (lines[lines.indexOf(firstRest) - 1] ?? 'missing') + '\n'), 'pages meet at a line');
});
test('corrected calls, empty moves and repeats reach the final warning line', () => {
  const out = formatCompact({ok:true,id:'x',result:{transferred:0,corrected:'craft {"recipe":"pipe"} (item is recipe)',
    nothing_moved:'chest at (1,1) holds no pipe',repeated:'transfer 3 times in 7 min with nothing moved'}});
  assert.match(out, /\nwarning: corrected: .*; nothing moved: chest at \(1,1\) holds no pipe; repeated: transfer 3 times/);
});
test('circuit_set: an entity a condition keeps off ends on the warning line (friction2: Opus)', () => {
  const reply = {ok:true,id:'x',result:{entity:'inserter',circuit:{enable:'production-science-pack < 1000',enable_met:true,disabled:true},
    stays_disabled:'inserter (75.5,-1.5): its logistic condition production-science-pack < 100 is not met (network 8: production-science-pack 101) (not set by this call)'}};
  assert.match(formatCompact(reply), /\nwarning: stays disabled: inserter \(75\.5,-1\.5\): its logistic condition production-science-pack < 100 is not met .*\n$/);
  assert.equal(finalLine(reply)?.startsWith('warning: stays disabled: inserter (75.5,-1.5)'), true);
  // round1950a (Astra 21:00): a circuit condition with no wire is ignored by the game, said on the warning line.
  const ignored = {ok:true, result:{entity:'fast-inserter',
    condition_ignored:'fast-inserter (-65.5,95.5): its circuit condition electromagnetic-science-pack < 0 is ignored: no red or green wire connects it, and the game counts a circuit condition only with a circuit connection'}};
  assert.match(formatCompact(ignored), /\nwarning: condition ignored: fast-inserter \(-65\.5,95\.5\): its circuit condition .* is ignored: no red or green wire connects it/);
});
test('a count of 0 is no warning line: a tile deconstruct that refused nothing (platformtiles2)', () => {
  const none = {ok:true,id:'x',result:{mode:'mark',tiles:true,tiles_marked:1,tiles_refused:0}};
  assert.doesNotMatch(formatCompact(none), /warning:/);
  assert.match(formatCompact(none), /tiles_refused: 0/);
  const some = {ok:true,id:'x',result:{mode:'mark',tiles:true,tiles_marked:1,tiles_refused:2}};
  assert.equal(finalLine(some), 'warning: tiles refused: 2');
});
test('a build or ghosts that close the character in end on the warning line (friction2: Gemini)', () => {
  const built = {ok:true,id:'x',result:{built:2,closed_in:'the character is closed in now where it stands (-57,71.5): the last gap out was where accumulator (-60,71) now stands'}};
  assert.match(formatCompact(built), /\nwarning: closed in: the character is closed in now where it stands \(-57,71\.5\)/);
  const ghosts = {ok:true,id:'x',result:{placed:8,closes_in:'once built, these ghosts close the character in where it stands (30.5,108.5)'}};
  assert.equal(finalLine(ghosts), 'warning: closes in: once built, these ghosts close the character in where it stands (30.5,108.5)');
});

test('failures keep the error and request ID, with hostile strings escaped in tables', () => {
  const output = formatCompact({ok:false,id:'retry-id',error:{code:'action_failed',message:'bad thing'},truncated:true,entities:[
    {name:'belt',position:{x:1,y:2},extra:null},
    {name:'line\n | spoof',position:{x:3.456,y:4},enabled:7},
  ]});
  assert.match(output,/^id: retry-id\n/);
  assert.match(output,/\nerror: action_failed: bad thing\n$/);
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
test('the last line names a failure, or what a partial success left undone', () => {
  const failed = formatCompact({ok:false,id:'r1',tick:9,error:{code:'craft_refused',message:'not crafted: 75\nheld by our factory',recovery:'force=true'},result:{short:'wood short 18 (held 2)',stock:['x']}});
  assert.equal(failed.trimEnd().split('\n').at(-1),'error: craft_refused: not crafted: 75 held by our factory; recovery: force=true; short: wood short 18 (held 2)');
  assert.doesNotMatch(failed,/error_result:\n  short/);
  const partial = formatCompact({ok:true,tick:3,result:{started:{gear:5},errors:{boiler:'missing stone-furnace'},short:{boiler:'stone short 5'},clock:'game 1m',chat:{unread:1}}});
  const lines = partial.trimEnd().split('\n');
  assert.equal(lines.at(-1),'warning: not done: boiler="missing stone-furnace"; short: boiler="stone short 5"');
  assert.equal(lines.at(-2),'chat: unread=1');
  const waiting = formatCompact({ok:true,result:{accepted:{awaiting_craft:{item:'lab',held:0,need:1,crafting:1}},completion:{outcome:'fed'}}});
  assert.match(waiting,/\nwarning: awaiting_craft: item=lab held=0 need=1 crafting=1\n$/);
  assert.doesNotMatch(formatCompact({ok:true,result:{transferred:5,clock:'c'}}),/warning/);
});
test('arrays of records nested inside records keep every row', () => {
  const base = (x: number, extra: Record<string, unknown> = {}) => ({spawners:2,absorbing:0,position:{x,y:-27},distance:205,direction:'E',...extra});
  const table = formatCompact({enemies:{bases:2,next:'soon',list:[base(338,{cloud_gap:1}),base(400)]}});
  assert.match(table,/enemies:\n  bases: 2\n  next: soon\n  list\[2\]: spawners \| absorbing \| position \| distance \| direction \| cloud_gap\n/);
  assert.match(table,/2 \| 0 \| 400,-27 \| 205 \| E \| -/);
  const single = formatCompact({enemies:{bases:1,list:[base(338)]}});
  assert.match(single,/list\[1\]:\n    0: spawners=2 absorbing=0 position=338,-27 distance=205 direction=E/);
});
test('full status: the teammates line follows the clock line', () => {
  const output = formatCompact({ok:true,id:'s',result:{teammates:'Sol on Vulcanus; Astra 110 tiles N',alive:true,clock:'game 1m',tick:5}});
  assert.equal(output,'alive: true\nclock: "game 1m"\nteammates: "Sol on Vulcanus; Astra 110 tiles N"\ntick: 5\n');
});
test('a transfer over several targets closes with its tally, before the team and clock lines', () => {
  const tally = 'moved 10 iron-plate; 2 of 3 targets touched; short: 1 failed (entity is out of reach)';
  const output = formatCompact({ok:true,id:'t',result:{tally,clock:'game 1m',transferred:10,team:{alerts:['x']},
    entities:[{position:{x:2,y:0},transferred:5},{position:{x:8,y:0},transferred:5}]}});
  assert.equal(output,'transferred: 10\nentities[2]: position | transferred\n  2,0 | 5\n  8,0 | 5\n'+
    `tally: "${tally}"\nclock: "game 1m"\nteam: alerts=[x]\n`);
  // The warning line stays last.
  assert.match(formatCompact({ok:true,id:'t',result:{tally:'moved nothing; 0 of 2 targets touched',nothing_moved:'none of 2 targets'}}),
    /tally: "moved nothing; 0 of 2 targets touched"\nwarning: nothing moved: none of 2 targets\n$/);
});
test('an item move ends with the inventory line after the move, after the team and clock lines (Muse 06:27)', () => {
  const output = formatCompact({ok:true,id:'t',result:{inv:'free 18/20; held: iron-plate 100',moved:50,transferred:50,
    clock:'game 1m',tally:'moved 50 iron-plate; 2 of 2 targets touched',team:{alerts:['x']}}});
  assert.equal(output,'moved: 50\ntransferred: 50\ntally: "moved 50 iron-plate; 2 of 2 targets touched"\nclock: "game 1m"\n'+
    'team: alerts=[x]\ninv: "free 18/20; held: iron-plate 100"\n');
  // A move that runs over ticks: moved 0, timed, and the line; the warning line still comes last.
  assert.match(formatCompact({ok:true,id:'t',result:{until_tick:90,moved:0,timed:'moves until tick 90',inv:'free 18/20',nothing_moved:'x'}}),
    /until_tick: 90\nmoved: 0\ntimed: "moves until tick 90"\ninv: "free 18\/20"\nwarning: nothing moved: x\n$/);
});
test('the standing orders line follows the clock line (and comes before teammates)', () => {
  const line = 'orders: restock-ammo running (3 turrets below 20), step 2/5';
  assert.equal(formatCompact({ok:true,id:'s',result:{orders:line,built:1,clock:'game 1m'}}),`built: 1\nclock: "game 1m"\norders: "${line}"\n`);
  assert.equal(formatCompact({ok:true,id:'s',result:{teammates:'Sol 5 tiles E',orders:line,clock:'game 1m',tick:5}}),
    `clock: "game 1m"\norders: "${line}"\nteammates: "Sol 5 tiles E"\ntick: 5\n`);
});

test('build dry-run pockets appear on the final warning line', () => {
  const reply = {ok:true,result:{dry_run:true,pockets:[{area:{left_top:{x:1,y:1},right_bottom:{x:4,y:7}},
    planned_boundary:[{index:1,name:'accumulator',position:{x:3,y:0},tiles:'2,-1..3,0'}]}]}};
  assert.match(finalLine(reply) ?? '', /warning: walkable pockets:.*accumulator/);
  assert.match(finalLine(reply) ?? '', /2,-1\.\.3,0/);
});
