import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseLook } from '../host/look.js';

test('fh say --look forms: a platform, an agent, a spot, an area, a surface', () => {
  assert.deepEqual(parseLook('platform:Sunward'), { platform: 'Sunward' });
  assert.deepEqual(parseLook('agent:sol'), { agent: 'sol' });
  assert.deepEqual(parseLook('120,-40'), { position: { x: 120, y: -40 } });
  assert.deepEqual(parseLook('120, -40@vulcanus'), { position: { x: 120, y: -40 }, surface: 'vulcanus' });
  assert.deepEqual(parseLook('140,-20,100,-60'), { area: { left_top: { x: 100, y: -60 }, right_bottom: { x: 140, y: -20 } } });
  assert.throws(() => parseLook('the big furnace'), /--look must be/);
});
