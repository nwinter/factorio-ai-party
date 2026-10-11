#!/usr/bin/env python3
"""Logistics share of agent chat, and where logistics went instead (tells, board), per run and per window.

  tools/analysis/chat_logistics.py runs/shake6 [runs/shake7 ...] [--window 10] [--since-tick T] [--lines banter]

Chat comes from <run>/chat.jsonl (chat-full.jsonl for shake1), agents from <run>/team.txt; lines from people, the
server and viewers are left out. Tells, board posts/updates and says are counted from each agent's journal
(<run>/<agent>/journal.jsonl or .gz), so a run with tells shows how much coordination left the chat.

The classifier is the shake3 to shake6 studies' keyword count, verbatim (recovered from the study session; it
reproduces the published counts: shake3 505/28/14, shake4 hour 1 514/23/10, shake5 344/38/27): a line with
coordinates or two logistics words is logistics, one word is mixed, none is banter.
"""
import argparse, collections, glob, gzip, json, os, re, sys

sys.dont_write_bytecode = True

coord = re.compile(r'-?\d+(\.\d+)?\s*,\s*-?\d+(\.\d+)?|[xy]\s*=?\s*-?\d+(\.\d+)?\s*\.\.\s*-?\d+')
logi = re.compile(r'(\d+\s*(x\s*)?(iron|copper|coal|plates?|gears?|belts?|inserters?|circuits?|stone|steel|packs?|drills?|furnaces?|assemblers?|labs?|pipes?|magazines?|turrets?|engines?))|chest|feed|deliver|hand(ed)?\s|claim|board|#\d+|need\b|send|lane|belt|inserter|iron|copper|coal|plates?\b|furnace|drill|assembler|lab\b|labs\b|ammo|magazine', re.I)
tone = re.compile(r"\b(proud|great|nice|excellent|thanks?|thank you|love|oops|sorry|ugh|finally|fun|haha|lol|wow|yay|hooray|sadly|annoying|worried|happy|glad|crew|teamwork|good work|well done|awesome|beautiful|ouch|yikes|whew|phew|hate|addiction|respectable|joke|funny|brave|hero|cheers|congrats|celebrat|bravo|sweet|lovely|oh no|damn|darn|grr|alas)\b|[!?]{2,}|:\)", re.I)


def classify(text):
    n = len(logi.findall(text))
    if coord.search(text) or n >= 2:
        return 'logistics'
    return 'mixed' if n == 1 else 'banter'


def agents(run):
    path = os.path.join(run, 'team.txt')
    if os.path.exists(path):
        return {line.split('|')[0].strip() for line in open(path) if line.strip()}
    return {os.path.basename(d.rstrip('/')) for d in glob.glob(os.path.join(run, '*/')) if glob.glob(d + 'journal.jsonl*')}


def chat(run, names):
    for name in ('chat.jsonl', 'chat-full.jsonl'):
        path = os.path.join(run, name)
        if os.path.exists(path):
            rows = [json.loads(l) for l in open(path) if l.strip()]
            return [m for m in rows if m.get('from') in names and not m.get('viewer')]
    return []


def journal_counts(run):
    """Successful requests per action that carry coordination (tell, say, board_post, board_update, confess), and the
    tells themselves (they are in no chat log)."""
    counts, tells = collections.Counter(), []
    for agent_dir in glob.glob(os.path.join(run, '*/')):
        path = agent_dir + 'journal.jsonl.gz'
        if not os.path.exists(path):
            path = agent_dir + 'journal.jsonl'
        if not os.path.exists(path):
            continue
        reqs = {}
        with (gzip.open(path, 'rt') if path.endswith('.gz') else open(path)) as f:
            for line in f:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if d.get('event') == 'request':
                    reqs[d['request'].get('id')] = d['request']
                elif d.get('event') == 'response' and (d.get('response') or {}).get('ok'):
                    req = reqs.pop(d['response'].get('id'), None) or {}
                    action = req.get('action')
                    if action in ('tell', 'say', 'board_post', 'board_update', 'confess'):
                        counts[action] += 1
                    if action == 'tell':
                        tells.append({'tick': d['response'].get('tick') or 0, 'from': os.path.basename(agent_dir.rstrip('/')),
                                      'to': (req.get('args') or {}).get('to'), 'text': (req.get('args') or {}).get('text') or ''})
    return counts, tells


def row(msgs):
    c = collections.Counter(classify(m.get('text', '')) for m in msgs)
    n = len(msgs)
    share = f"{100 * c['logistics'] / n:.0f}%" if n else '-'
    toned = sum(1 for m in msgs if tone.search(m.get('text', '')))
    return f"{n:5d}  {c['logistics']:4d} / {c['mixed']:3d} / {c['banter']:3d}  {share:>4}  tone {100 * toned / n if n else 0:.0f}%"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('runs', nargs='+')
    ap.add_argument('--window', type=float, default=10, help='window in game minutes (default 10)')
    ap.add_argument('--since-tick', type=int, default=0, help='only messages at or after this tick (a resumed shift)')
    ap.add_argument('--lines', choices=('banter', 'mixed', 'logistics'), help='also print the lines of one class')
    a = ap.parse_args()
    for run in a.runs:
        names = agents(run)
        msgs = [m for m in chat(run, names) if (m.get('tick') or 0) >= a.since_tick]
        msgs.sort(key=lambda m: (m.get('tick') or 0, m.get('seq') or 0))
        print(f"{os.path.basename(run.rstrip('/'))}: {len(names)} agents")
        print("  minutes      msgs  logi / mix / ban  share")
        print(f"  all        {row(msgs)}")
        if msgs:
            t0, size = a.since_tick, a.window * 3600  # game minutes from tick 0 (or the shift start)
            bins = collections.defaultdict(list)
            for m in msgs:
                bins[int((m['tick'] - t0) // size)].append(m)
            for k in sorted(bins):
                print(f"  {k * a.window:4.0f}-{(k + 1) * a.window:<4.0f}m  {row(bins[k])}")
        counts, tells = journal_counts(run)
        tells = [t for t in tells if t['tick'] >= a.since_tick]
        if counts:
            print('  requests: ' + ', '.join(f"{k} {counts[k]}" for k in ('say', 'tell', 'board_post', 'board_update', 'confess')))
        if tells:
            print(f"  tells      {row(tells)}")
        if a.lines:
            for m in msgs:
                if classify(m.get('text', '')) == a.lines:
                    print(f"    #{m.get('seq')} {m.get('from')}: {m.get('text')}")
            for t in tells:
                if classify(t['text']) == a.lines:
                    print(f"    tell {t['from']} -> {t['to']}: {t['text']}")


if __name__ == '__main__':
    main()
