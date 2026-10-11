import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseDeadline, deadlineText } from '../host/deadline.js';

test('deadline.txt lines parse with zone abbreviations, offsets, or local time', () => {
  assert.equal(parseDeadline('2026-10-10 22:48 PDT\n'), Date.UTC(2026,9,11,5,48));
  assert.equal(parseDeadline('2026-10-10 22:48 PST'), Date.UTC(2026,9,11,6,48));
  assert.equal(parseDeadline('2026-10-10T22:48:30+02:00'), Date.UTC(2026,9,10,20,48,30));
  assert.equal(parseDeadline('2026-10-10 22:48 UTC'), Date.UTC(2026,9,10,22,48));
  assert.equal(parseDeadline('2026-10-10 22:48'), new Date(2026,9,10,22,48).getTime());
  assert.equal(parseDeadline('soon'), undefined);
});
test('time left reads in minutes, hours, or as passed', () => {
  const at = Date.UTC(2026,9,11,5,48);
  assert.equal(deadlineText(at, at - 23*60000 - 30000), 'deadline in 23m');
  assert.equal(deadlineText(at, at - 65*60000), 'deadline in 1h05m');
  assert.equal(deadlineText(at, at - 40000), 'deadline in 40s');
  assert.equal(deadlineText(at, at + 4*60000), 'deadline passed 4m ago');
});
