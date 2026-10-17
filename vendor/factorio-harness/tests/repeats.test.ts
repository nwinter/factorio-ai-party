import { test } from 'node:test';
import assert from 'node:assert/strict';
import { trimRepeats, SHOWN_EVERY_MS, type ShownState } from '../host/repeats.js';

const reply = (result: Record<string, unknown>) => ({ ok: true, id: 'x', result });
const ORDERS = 'orders: paused (orders_resume)';
const LESSON = ['lesson #671 (astra): personal request maxima trash carried excess.'];

test('the orders and lessons lines show when changed and every 10 minutes, and are left out between', () => {
  let state: ShownState = {};
  const step = (result: Record<string, unknown>, now: number) => {
    const out = trimRepeats(reply(result), state, now);
    state = out.state;
    return (out.reply as { result: Record<string, unknown> }).result;
  };
  // first reply: both shown
  assert.deepEqual(step({ clock: 'game 1h', orders: ORDERS, lessons: LESSON }, 0), { clock: 'game 1h', orders: ORDERS, lessons: LESSON });
  // the same text a minute later: both left out, the rest kept
  assert.deepEqual(step({ clock: 'game 1h01m', orders: ORDERS, lessons: LESSON, built: 1 }, 60000), { clock: 'game 1h01m', built: 1 });
  // orders changed: shown; lessons the same: left out
  const changed = 'orders: rearm-ne runs (rearm)';
  assert.deepEqual(step({ orders: changed, lessons: LESSON }, 120000), { orders: changed });
  // 10 minutes after they were last shown: shown again though unchanged
  assert.deepEqual(step({ orders: changed, lessons: LESSON }, SHOWN_EVERY_MS), { lessons: LESSON });
  assert.deepEqual(step({ orders: changed, lessons: LESSON }, 120000 + SHOWN_EVERY_MS), { orders: changed });
  // a lesson set that differs is shown at once
  const two = [...LESSON, 'lesson #700 (sol): a hub request over its max is trash.'];
  assert.deepEqual(step({ lessons: two }, 120000 + SHOWN_EVERY_MS + 1000), { lessons: two });
});

test('the orders and lessons actions\' own replies, failures and other shapes are not touched', () => {
  const state: ShownState = { orders: { text: ORDERS, at: 0 }, lessons: { text: LESSON.join('\n'), at: 0 } };
  const own = reply({ orders: [{ name: 'rearm-ne', action: 'rearm' }], lessons: [{ id: 671, text: 'x' }] });
  const out = trimRepeats(own, state, 1000);
  assert.equal(out.reply, own); assert.equal(out.changed, false);
  const failed = { ok: false, error: { code: 'action_failed', message: 'no' } };
  assert.equal(trimRepeats(failed, state, 1000).reply, failed);
  // the input reply is never changed in place
  const shown = reply({ orders: ORDERS });
  trimRepeats(shown, state, 1000);
  assert.equal(shown.result.orders, ORDERS);
});
