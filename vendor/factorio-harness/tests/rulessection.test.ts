import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { rulesSection } from '../host/rules.js';

// (d20 batch50 E2) Codex re-injects only AGENTS.md after a compaction: fh keeps that file's ground-rules section (written at
// launch by tools/brief.py rules) to the rules the last reply carried; other harnesses' AGENTS.md is left alone.
const AGENTS = '# Brief\n\n## The team\'s ground rules\n<!-- ground-rules -->\n- rule 1 (by sol): old\n<!-- /ground-rules -->\n\n## Compact instructions\nkeep\n';
test('a Codex workspace keeps its AGENTS.md ground rules current', () => {
  const dir = mkdtempSync(join(tmpdir(), 'rules-'));
  try {
    writeFileSync(join(dir, 'AGENTS.md'), AGENTS);
    writeFileSync(join(dir, '.context-hooks'), 'codex gpt-6-astra 140000\n');
    rulesSection(dir, ['rule 1 (by sol): old', 'rule 8 (by astra): Use big mining drills by default for new ore outposts.']);
    const text = readFileSync(join(dir, 'AGENTS.md'), 'utf8');
    assert.match(text, /<!-- ground-rules -->\n- rule 1 \(by sol\): old\n- rule 8 \(by astra\): Use big mining drills[^\n]*\n<!-- \/ground-rules -->\n\n## Compact instructions\nkeep\n$/);
    rulesSection(dir, []);
    assert.match(readFileSync(join(dir, 'AGENTS.md'), 'utf8'), /<!-- ground-rules -->\n<!-- \/ground-rules -->/);
    // a Claude workspace (CLAUDE.md is AGENTS.md there) and a file without the section stay as they are
    writeFileSync(join(dir, 'AGENTS.md'), AGENTS);
    writeFileSync(join(dir, '.context-hooks'), 'claude haiku 140000\n');
    rulesSection(dir, ['rule 8 (by astra): x']);
    assert.equal(readFileSync(join(dir, 'AGENTS.md'), 'utf8'), AGENTS);
    writeFileSync(join(dir, 'AGENTS.md'), '# Brief\n');
    writeFileSync(join(dir, '.context-hooks'), 'codex gpt-6-astra 140000\n');
    rulesSection(dir, ['rule 8 (by astra): x']);
    assert.equal(readFileSync(join(dir, 'AGENTS.md'), 'utf8'), '# Brief\n');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
