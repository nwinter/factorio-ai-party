// (d29 batch336 FL6) the request's wall clock: fh puts `wall` (ms) in the envelope it sends over RCON itself, the same
// on a resend of the id; a transport that stamps it (the broker) gets none from fh.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Harness } from '../host/harness.js';
import { RconOutcomeUnknown } from '../host/rcon.js';

const body = (command: string) => JSON.parse(command.slice(command.indexOf('[[\n') + 3, command.lastIndexOf(']]')));

test('a direct send carries wall, the same on a resend of its id', async () => {
  const seen: string[] = [];
  let first = true;
  const h = new Harness({async command(c) {
    seen.push(c);
    if (first) { first = false; throw new RconOutcomeUnknown('the reply was lost'); }
    return JSON.stringify({id:body(c).id, ok:true, result:{}});
  }}, 1, undefined, 'haiku');
  const before = Date.now();
  await h.request('status', {}, 'w1');
  const walls = seen.map(c => body(c).wall);
  assert.equal(walls.length, 2);
  assert.ok(typeof walls[0] === 'number' && walls[0] >= before && walls[0] <= Date.now(), String(walls));
  assert.equal(walls[1], walls[0]);
});

test('a transport that stamps the wall clock gets none from fh', async () => {
  let command = '';
  const h = new Harness({stampsWall:true, async command(c) { command = c; return JSON.stringify({id:'w2', ok:true, result:{}}); }}, 1, undefined, 'haiku');
  await h.request('status', {}, 'w2');
  assert.equal(body(command).wall, undefined);
});
