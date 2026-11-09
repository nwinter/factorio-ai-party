#!/usr/bin/env python3
"""Audit accounting: repeated blocks, fork copies, cumulative counters and Muse frames."""
import json
from pathlib import Path
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent / 'analysis'))
import token_efficiency as E


def main():
    at = '2026-10-30T12:00:00Z'
    with tempfile.TemporaryDirectory() as tmp:
        manifest = {}
        def write(name, parser, rows):
            p = Path(tmp) / name
            p.write_text(''.join(json.dumps(r) + '\n' for r in rows))
            manifest[str(p)] = [parser, parser]
        def claude(uid, output):
            return dict(type='assistant', uuid=uid, timestamp=at,
                        message=dict(id='m1', usage=dict(input_tokens=10, cache_creation_input_tokens=20,
                                     cache_read_input_tokens=70, output_tokens=output,
                                     output_tokens_details=dict(thinking_tokens=5))))
        write('claude', 'claude_line', [claude('u1', 10), claude('u2', 15)])
        write('fork', 'claude_line', [claude('u1', 10), claude('u2', 15)])
        record = dict(type='token_usage_record', timestamp=at, payload=dict(response_id='r1', usage=dict(
            input_tokens=100, cached_input_tokens=70, output_tokens=25, reasoning_output_tokens=10)))
        write('codex', 'codex_line', [record, record, dict(type='event_msg', timestamp=at, payload=dict(
            type='token_count', info=dict(total_token_usage=dict(input_tokens=999999, output_tokens=999999))))])
        muse = dict(recorded_at=at, id='muse1', payload=dict(event=dict(kind='model_completed', usage=dict(
            input_tokens=200, cached_tokens=150, output_tokens=50, reasoning_tokens=20))))
        summary = dict(recorded_at=at, id='muse2', payload=dict(event=dict(kind='context_compaction_installed',
                       summarizer_usage=dict(input_tokens=300, output_tokens=12))))
        write('muse', 'muse_line', [dict(retained_frame='frame', children=[dict(record_json=json.dumps(muse))]), muse, summary])
        write('agy', 'agy_line', [dict(type='PLANNER_RESPONSE', created_at=at, input_tokens=20,
                                      cache_read_tokens=80, output_tokens=30)])
        rows = E.audit(manifest, E.T.when('2026-10-30T00:00:00Z'), E.T.when('2026-10-31T00:00:00Z'))
        for parser, expected in [('claude_line', (100, 70, 15, 5)), ('codex_line', (100, 70, 25, 10)),
                                 ('muse_line', (200, 150, 50, 20)), ('agy_line', (100, 80, 30, 0))]:
            r = rows[parser]
            assert tuple(r[k] for k in ('input', 'cache_read', 'output', 'reasoning')) == expected, r
            assert r['calls'] == 1, r
            # Disjoint columns: uncached (including cache creation), cached, visible output, reasoning.
            assert (r['input'] - r['cache_read']) + r['cache_read'] + (r['output'] - r['reasoning']) + r['reasoning'] == r['input'] + r['output']
        assert rows['muse_line']['unpartitioned_compaction_input'] == 300
        assert rows['muse_line']['unpartitioned_compaction_output'] == 12
        assert rows['muse_line']['compactions'] == 1
    print('token efficiency accounting: passed')


if __name__ == '__main__':
    main()
