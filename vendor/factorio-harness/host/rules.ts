import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

// (d20 batch50 E2) Codex re-injects only AGENTS.md after a compaction: in a Codex workspace (.context-hooks says codex)
// the AGENTS.md section the launch wrote (tools/brief.py rules_note, between the ground-rules markers) is kept to the
// rules the last reply carried. Nothing changes elsewhere, or without the section.
export function rulesSection(dir: string, lines: string[]) {
  try {
    // (d27 batch275 HW) Claude Code too: it loads CLAUDE.md (a link to AGENTS.md) at the start and after each
    // compaction, as Codex does AGENTS.md; before this only Codex workspaces carried the section (shift86: "rule 27"
    // appears 0 times in Opus's and Sonnet's transcripts)
    const kind = readFileSync(join(dir, '.context-hooks'), 'utf8').split(/\s/)[0];
    if (kind !== 'codex' && kind !== 'claude') return;
    const path = join(dir, 'AGENTS.md'), text = readFileSync(path, 'utf8');
    const start = '<!-- ground-rules -->', end = '<!-- /ground-rules -->';
    const i = text.indexOf(start), j = text.indexOf(end);
    if (i < 0 || j < i) return;
    const body = lines.map(l => `- ${l}\n`).join('');
    const next = text.slice(0, i + start.length) + '\n' + body + text.slice(j);
    if (next !== text) writeFileSync(path, next);
  } catch { /* no marker or no AGENTS.md: nothing to keep */ }
}
