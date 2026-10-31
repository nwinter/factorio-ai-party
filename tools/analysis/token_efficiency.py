#!/usr/bin/env python3
"""Offline audit of an explicit transcript manifest; never contacts a client or game.

Manifest: {absolute_path: [group, parser_name]} (parsers from stream/tokens.py).
Usage: python3 tools/analysis/token_efficiency.py MANIFEST --since ISO --until ISO
Counts model responses, not user turns. Byte indicators are not billed token shares.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'stream'))
import tokens as T

MEMORY = re.compile(r'notes\.md|AGENTS\.md|CLAUDE\.md|history|journal\.jsonl|compactions\.md', re.I)
READ = re.compile(r'\b(cat|head|tail|sed|rg|grep|Read|read_file|read_text_file|view_file)\b')
WAIT = re.compile(r'\b(sleep|wait|idle)\b')


def text(value):
    if isinstance(value, str):
        try:
            obj = json.loads(value)
            if isinstance(obj, dict) and 'output' in obj:
                return text(obj['output'])
        except ValueError:
            pass
        return value
    if isinstance(value, list):
        return '\n'.join(text(v) for v in value)
    if isinstance(value, dict):
        return text(value.get('text', value.get('output', '')))
    return ''


def records(path):
    # Muse's retained transactions wrap records; count each child once, not the wrapper.
    with open(path, 'rb') as f:
        for line in f:
            try:
                r = json.loads(line)
                if r.get('retained_frame'):
                    for c in r.get('children', []):
                        yield json.loads(c['record_json'])
                else:
                    yield r
            except (ValueError, KeyError):
                continue


def audit(manifest, since, until):
    groups = collections.defaultdict(collections.Counter)
    usage, seen_records = {}, set()
    for path, (group, parser) in manifest.items():
        g = groups[group]
        commands, repeated_reads, prompts, outputs = {}, set(), set(), set()
        last_command = ''
        g['files'] += 1
        for r in records(path):
            t = T.when(r.get('timestamp') or r.get('created_at') or r.get('recorded_at') or r.get('ts'))
            if t is None or not since <= t < until:
                continue
            p, m = r.get('payload') or {}, r.get('message') or {}
            ev = p.get('event') or {}
            # Claude fork copies can repeat UUIDs across files/profiles.
            identity = r.get('uuid') or (r.get('id') if parser == 'muse_line' else None)
            if identity:
                if (parser, identity) in seen_records:
                    continue
                seen_records.add((parser, identity))
            u = None
            key = None
            if parser == 'claude_line' and r.get('type') == 'assistant' and m.get('model') != '<synthetic>':
                u = m.get('usage')
                key = ('claude', m.get('id') or r.get('uuid'))
            elif parser == 'codex_line' and r.get('type') == 'token_usage_record':
                u = p.get('usage')
                key = ('codex', p.get('response_id'))
            if u:
                # Streaming blocks sometimes revise usage. Keep component maxima for one response.
                acc = T.blank()
                getattr(T, parser)(json.dumps(r).encode(), acc, {})
                old = usage.get(key, (group, T.blank()))[1]
                usage[key] = (group, {k: max(old[k], acc[k]) for k in T.FIELDS})
            elif parser not in ('claude_line', 'codex_line'):
                acc = T.blank()
                getattr(T, parser)(json.dumps(r).encode(), acc, {})
                if ev.get('kind') == 'context_compaction_installed':
                    # Muse exposes summary totals without cache/reasoning partitions.
                    g['unpartitioned_compaction_input'] += acc['input']
                    g['unpartitioned_compaction_output'] += acc['output']
                    acc['input'] = acc['output'] = 0
                for k in T.FIELDS:
                    g[k] += acc[k]
                if '/subagent/' in path or '/subagents/' in path:
                    g['subagent_calls'] += acc['calls']
                    g['subagent_input'] += acc['input']
                if parser == 'grok_line' and r.get('msg') == 'shell.turn.inference_done':
                    g['inference_retries'] += max(0, (r.get('ctx') or {}).get('attempts', 1) - 1)
            if ev.get('kind') == 'memory_reminder_child_session_linked':
                g['reminder_children'] += 1
            if r.get('type') == 'compacted' or (r.get('type') == 'system' and r.get('subtype') == 'compact_boundary'):
                g['compactions'] += 1
            calls, replies, user = [], [], None
            if parser == 'claude_line':
                content = m.get('content')
                if r.get('type') == 'user' and isinstance(content, str) and not r.get('isMeta'):
                    user = content
                for c in content if isinstance(content, list) else []:
                    if c.get('type') == 'tool_use':
                        calls.append((c.get('id'), c.get('name', '') + ' ' + json.dumps(c.get('input'))))
                    elif c.get('type') == 'tool_result':
                        replies.append((c.get('tool_use_id'), text(c.get('content'))))
            elif parser == 'codex_line' and r.get('type') == 'response_item':
                if p.get('type') in ('custom_tool_call', 'function_call'):
                    calls.append((p.get('call_id'), str(p.get('input') or p.get('arguments') or '')))
                elif p.get('type') in ('custom_tool_call_output', 'function_call_output'):
                    replies.append((p.get('call_id'), text(p.get('output'))))
                elif p.get('type') == 'message' and p.get('role') == 'user':
                    user = text(p.get('content'))
            elif parser == 'agy_line':
                if r.get('type') == 'USER_INPUT':
                    user = r.get('content', '')
                if r.get('type') == 'PLANNER_RESPONSE':
                    calls.extend((f"{r.get('step_index', t)}:{c.get('id', i)}", json.dumps(c))
                                 for i, c in enumerate(r.get('tool_calls', [])))
                if r.get('type') == 'GENERIC':
                    replies.append((None, r.get('content', '')))
            elif parser == 'grok_updates_line':
                update = (r.get('params') or {}).get('update') or {}
                if update.get('rawInput'):
                    calls.append((update.get('toolCallId'), json.dumps(update['rawInput'])))
                if update.get('rawOutput'):
                    replies.append((update.get('toolCallId'), text(update['rawOutput'].get('output_for_prompt'))))
            elif parser == 'muse_line':
                if ev.get('kind') == 'assistant_tool_calls_committed':
                    calls.extend((x.get('call_id'), x.get('name', '') + ' ' + str(x.get('args', '')))
                                 for x in ev.get('tool_calls', []))
                if ev.get('kind') == 'tool_result_batch_committed':
                    replies.extend((x.get('tool_call_id'), text(x.get('text'))) for x in ev.get('results', []))
                if ev.get('kind') == 'started' and ev.get('prompt'):
                    user = ev['prompt']
            for cid, command in calls:
                if commands.get(cid) == command:
                    continue
                commands[cid] = last_command = command
                g['tool_calls'] += 1
                if READ.search(command) and MEMORY.search(command):
                    g['memory_reads'] += 1
                    # Filename-class heuristic: may include partial reads or another agent's notes.
                    targets = set(m.group(0).lower() for m in MEMORY.finditer(command))
                    if targets & repeated_reads:
                        g['repeat_memory_reads'] += 1
                    repeated_reads.update(targets)
                if WAIT.search(command):
                    g['wait_calls'] += 1
            if user:
                g['user_prompts'] += 1
                g['prompt_bytes'] += len(user.encode())
                digest = hashlib.sha256(user.encode()).hexdigest()
                if digest in prompts:
                    g['duplicate_prompt_bytes'] += len(user.encode())
                prompts.add(digest)
                if 'notes.md' in user and ('Re-read notes.md' in user or 'read it and deadline.txt first' in user):
                    g['reread_prompts'] += 1
                launch = ('Read AGENTS.md in this directory; it has your instructions, interface, rules, and deadline. '
                          'Then play Factorio until the deadline in deadline.txt, keeping notes.md current, '
                          'and finish with the final summary it asks for.')
                if launch in user:
                    g['launch_prefixes'] += 1
                    g['launch_prefix_bytes'] += len(launch.encode())
            for cid, reply in replies:
                # Duplicate serialization of a result is not another model-visible result.
                identity = (cid if cid is not None else r.get('step_index', t),
                            hashlib.sha256(reply.encode()).hexdigest())
                if not reply or identity in outputs:
                    continue
                outputs.add(identity)
                size = len(reply.encode())
                g['results'] += 1
                g['result_bytes'] += size
                if size > 10000:
                    g['large_results'] += 1
                    g['large_result_bytes'] += size
                command = commands.get(cid, last_command if parser == 'agy_line' else '')
                if READ.search(command) and MEMORY.search(command):
                    g['memory_result_bytes'] += size
                if re.search(r'(?:exit_code|exit code)["\s:]+[1-9]|"is_error":\s*true|^error:', reply, re.M):
                    g['error_results'] += 1
                else:
                    g['nonerror_results'] += 1
    for group, acc in usage.values():
        for k in T.FIELDS:
            groups[group][k] += acc[k]
    return dict(groups)


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('manifest')
    ap.add_argument('--since', required=True)
    ap.add_argument('--until', required=True)
    a = ap.parse_args()
    print(json.dumps(audit(json.load(open(a.manifest)), T.when(a.since), T.when(a.until)), indent=2, sort_keys=True))
