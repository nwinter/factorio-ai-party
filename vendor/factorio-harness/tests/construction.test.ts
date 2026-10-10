import { test } from 'node:test';
import { execFileSync } from 'node:child_process';
test('continuous construction validates, walks while placing, resumes, and detects obstructions', () => {
  execFileSync('lua', ['tests/construction.lua'], {stdio:'pipe'});
});
