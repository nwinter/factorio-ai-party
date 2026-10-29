import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { actionHelp, describeLines } from '../host/format.js';
import { topicUnits, openTopic } from '../host/reference.js';

// (d28 batch317) progressive disclosure on the host: fh help TOPIC prints the head and the entries open for the team
// (ref/.units/TOPIC.json, written by pog tools/brief.py), fh help ACTION names a locked action's condition, and
// describe.json is written again after an unlock in the same one-action-per-line form as tools/describe-lines.py.
test('fh help TOPIC in a disclosure run: the open entries only, as they open', () => {
  const dir = mkdtempSync(join(tmpdir(), 'ref-'));
  mkdirSync(join(dir, '.units'));
  writeFileSync(join(dir, '.units', 'building.json'), JSON.stringify({head:'# building (`./fh help building`)\n\nRead it when.\n\n',
    items:[{id:'building#1', text:'- `build {item}`: places.\n'}, {id:'building#2', text:'- `belt_route {from, to}`: lays a belt.\n'}]}));
  const units = topicUnits(dir, 'building')!;
  assert.equal(openTopic(units, new Set(['building#2'])), '# building (`./fh help building`)\n\nRead it when.\n\n- `build {item}`: places.\n');
  assert.match(openTopic(units, new Set()), /belt_route/, 'nothing shut: everything');
  assert.match(openTopic(units, new Set(['building#1', 'building#2'])), /Nothing in this topic is open for your team yet/);
  assert.match(openTopic(units, new Set(['building#9'])), /build \{item\}[\s\S]*belt_route/, 'an id the runtime shuts that is not here changes nothing');
  assert.equal(topicUnits(dir, 'analysis'), undefined, 'a plain workspace: the file as it is');
  assert.equal(topicUnits(dir, '../x'), undefined);
});

test('fh help ACTION: a locked action says what opens it', () => {
  const describe = {actions:{build:{item:'x'}}, locked:{belt_route:'it opens when your team has placed 20 belts by hand'}};
  assert.equal(actionHelp(describe, 'belt_route'), 'belt_route is not available yet: it opens when your team has placed 20 belts by hand\n');
  assert.match(actionHelp(describe, 'nothing_like_it'), /^unknown action nothing_like_it/);
});

test('describe.json written by fh is what tools/describe-lines.py writes', () => {
  const result = {protocol:1, bundle:'B@d3', locked:{train:'it opens when your team has researched railway'},
    actions:{craft:{recipe:'recipe name', count:'1..1000'}, walk:{position:'{x,y}', note:'a "quoted" word, ünïcode'}}};
  const ts = describeLines(result);
  assert.match(ts, /"craft": \{"name": "craft", "args": \{"recipe": "recipe name", "count": "1\.\.1000"\}\}/);
  let py: string | undefined;
  try {
    py = execFileSync('python3', ['-c', 'import json,sys; sys.path.insert(0,sys.argv[1]); import importlib.util as u; s=u.spec_from_file_location("d",sys.argv[1]+"/describe-lines.py"); m=u.module_from_spec(s); s.loader.exec_module(m); print(m.lines(json.load(sys.stdin)))', join(process.cwd(), '..', '..', 'tools')], {input:JSON.stringify(result)}).toString();
  } catch { py = undefined; }
  if (py !== undefined) {
    // the same lines; Python escapes non-ASCII letters (ü), fh writes them as they are
    const norm = (s: string) => s.replace(/\\u([0-9a-f]{4})/g, (_, h) => String.fromCharCode(parseInt(h, 16))).trimEnd();
    assert.equal(norm(ts), norm(py));
  }
  assert.deepEqual(JSON.parse(ts).actions.walk, {name:'walk', args:result.actions.walk});
});
