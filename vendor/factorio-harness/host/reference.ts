/**
 * The agents' reference topics (pog tools/brief.py writes them into each workspace's ref/ and sets FH_REF_DIR in its
 * fh wrapper): `fh help TOPIC` prints ref/TOPIC.md, `fh help` lists the topics, and an argument refusal or an unknown
 * action names the topic that documents the call (ref/commands.tsv: command, tab, topic).
 */
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join } from 'node:path';

export function refDir(env: NodeJS.ProcessEnv = process.env): string | undefined {
  const dir = env.FH_REF_DIR;
  return dir && existsSync(dir) ? dir : undefined;
}

export function topicNames(dir: string): string[] {
  try { return readdirSync(dir).filter(f => /^[a-z][a-z-]*\.md$/.test(f)).map(f => f.slice(0, -3)).sort(); }
  catch { return []; }
}

/** ref/NAME.md, or undefined when NAME is no topic (an action's name, say). */
export function topicText(dir: string, name: string): string | undefined {
  if (!/^[a-z][a-z-]*$/.test(name)) return undefined;
  try { return readFileSync(join(dir, `${name}.md`), 'utf8'); } catch { return undefined; }
}

export function commandTopics(dir: string): Map<string, string> {
  const out = new Map<string, string>();
  try {
    for (const line of readFileSync(join(dir, 'commands.tsv'), 'utf8').split('\n')) {
      const [name, topic] = line.split('\t');
      if (name && topic) out.set(name, topic);
    }
  } catch { /* no index: no hints */ }
  return out;
}

/** The line `fh help` ends with: the topics there are. */
export function topicsLine(dir: string): string {
  const names = topicNames(dir);
  return names.length ? `\nReference topics (./fh help TOPIC prints one): ${names.join(', ')}\n` : '';
}

// What reads as a refusal of the call's form rather than of the game's state.
const ARGUMENT_ERROR = /^(unsupported action|unknown argument)|\b(unknown argument|must be|is required|requires|out of range|goes with|not both|must have)\b/;

function distance(a: string, b: string): number {
  let row = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    const next = [i];
    for (let j = 1; j <= b.length; j++) next[j] = Math.min(row[j]! + 1, next[j - 1]! + 1, row[j - 1]! + (a[i - 1] === b[j - 1] ? 0 : 1));
    row = next;
  }
  return row[b.length]!;
}

/** Similar command names: as fh help's unknown-action line finds them, or a typo of up to 2 letters. */
export function nearNames(names: string[], action: string): string[] {
  return names.filter(n => n.includes(action) || action.includes(n) || distance(n, action) <= 2
    || n.split('_').some(w => w.length > 2 && action.includes(w))).sort();
}

/**
 * Appends the topic that documents the call to an argument refusal's or an unknown action's message (a queue step's
 * refusal, `steps[3] (build): ...`, names that step's action's topic). Returns the hint added, or undefined.
 */
export function addReference(reply: { ok?: boolean; error?: { code?: string; message?: string } }, action: string,
  dir: string | undefined = refDir()): string | undefined {
  if (!dir || reply.ok !== false || !reply.error || typeof reply.error.message !== 'string') return undefined;
  const message = reply.error.message;
  if (!ARGUMENT_ERROR.test(message) || /\(reference: /.test(message)) return undefined;
  const topics = commandTopics(dir);
  const step = /^steps\[\d+\] \(([a-z_]+)\)/.exec(message);
  const name = step?.[1] ?? action;
  let hint: string;
  if (/^unsupported action/.test(message)) {
    const near = nearNames([...topics.keys()], name).slice(0, 6);
    const where = [...new Set(near.map(n => topics.get(n)).filter(t => t && t !== 'core'))];
    hint = near.length ? `similar: ${near.join(', ')}; reference: ${where.map(t => `./fh help ${t}`).join(', ') || 'AGENTS.md'}`
      : 'reference: ./fh help lists the topics';
  } else {
    const topic = topics.get(name);
    if (!topic) return undefined;
    hint = topic === 'core' ? 'reference: AGENTS.md' : `reference: ./fh help ${topic}`;
  }
  reply.error.message = `${message} (${hint})`;
  return hint;
}
