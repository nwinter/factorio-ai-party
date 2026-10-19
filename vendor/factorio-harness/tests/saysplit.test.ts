import { test } from 'node:test';
import assert from 'node:assert/strict';
import { splitSay, overLimit, SAY_BYTES } from '../host/saysplit.js';

const bytes = (s: string) => Buffer.byteLength(s, 'utf8');
// Muse's reply to a viewer, shift39 (cut at 500 bytes mid-word: "After that, prod")
const LONG = '@Foobator The quality loop is the next step. The recyclers feed the assemblers through one belt, and the '
  + 'second line takes their uncommon output to a chest. I am rebuilding the feeder first and output should roughly '
  + 'double. After that, production modules go into the assemblers that make the gears, because they are the slowest '
  + 'step. The chest at the end fills in about twenty minutes now. Sol is bringing more quality modules from Vulcanus '
  + 'later tonight, and I will put them where the yield is lowest. If the second recycler keeps jamming on scrap I '
  + 'will split its input. I can show it on the stream when it runs, and I will say here when it does.';

test('a say within 500 bytes is one part, newlines read as spaces', () => {
  assert.deepEqual(splitSay('taking copper'), ['taking copper']);
  assert.deepEqual(splitSay('one\ntwo\r\nthree'), ['one two three']);
  const exact = 'x'.repeat(SAY_BYTES);
  assert.deepEqual(splitSay(exact), [exact]);
});

test('a long say splits at sentence ends into numbered parts that repeat the @address, none cut mid-word', () => {
  assert(bytes(LONG) > SAY_BYTES);
  const parts = splitSay(LONG);
  assert.equal(parts.length, 2);
  parts.forEach((p, i) => {
    assert(bytes(p) <= SAY_BYTES, `part ${i + 1} is ${bytes(p)} bytes`);
    assert(p.startsWith(`@Foobator (${i + 1}/2) `), p);
    assert.match(p, /[.!?]$/);
  });
  // every word is posted, in order
  const joined = parts.map(p => p.replace(/^@Foobator \(\d\/\d\) /, '')).join(' ');
  assert.equal(joined, LONG.replace(/^@Foobator /, ''));
});

test('several leading addresses go on each part; a line without one is numbered only', () => {
  const parts = splitSay('@sol, @luna: ' + LONG.slice(10));
  assert(parts.every(p => p.startsWith('@sol, @luna: (')));
  const plain = splitSay(LONG.slice(10) + ' ' + LONG.slice(10));
  assert.equal(plain.length, 3);
  assert(plain[0]!.startsWith('(1/3) The quality loop'));
  assert(plain.every(p => bytes(p) <= SAY_BYTES));
});

test('a sentence longer than a part splits at word ends; multibyte text stays whole characters', () => {
  const run = Array.from({ length: 120 }, (_, i) => `word${i}`).join(' ') + '.';
  const parts = splitSay(run);
  assert(parts.length >= 2);
  for (const p of parts) {
    assert(bytes(p) <= SAY_BYTES);
    assert.match(p, /^\(\d\/\d\) word\d+/);
    assert.match(p, /word\d+\.?$/);
  }
  const accents = splitSay('é'.repeat(400));
  assert(accents.length === 2 && accents.every(p => bytes(p) <= SAY_BYTES && !p.includes('�')));
  assert.equal(accents.map(p => p.replace(/^\(\d\/\d\) /, '')).join(''), 'é'.repeat(400));
});

test('overLimit: a confession or chronicle text past what the runtime keeps, counted as the runtime counts it', () => {
  assert.equal(overLimit('confess', {text: 'x'.repeat(300)}), undefined);
  assert.equal(overLimit('confess', {text: '  ' + 'x'.repeat(300) + '\n'}), undefined);
  assert.match(overLimit('confess', {text: 'é'.repeat(151)}) ?? '', /confess text is 302 bytes; the limit is 300/);
  assert.match(overLimit('chronicle', {text: 'ok', title: 't'.repeat(81)}) ?? '', /chronicle title is 81 bytes; the limit is 80/);
  assert.equal(overLimit('say', {text: 'x'.repeat(900)}), undefined);
});
