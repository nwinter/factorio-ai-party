#!/usr/bin/env python3
"""Measure pack value on a disposable 2.0.77 Space Age server.

Requires tests/private/science-value-probe_0.1.0 installed as a mod there.
Creates isolated test forces and a surface. Never run on an active game.
No arguments skips this optional engine check for the merge gate.
"""
import argparse
import json
from pathlib import Path
import time

from pog import PORTS, Rcon


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int)
    parser.add_argument('--password-file', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.port is None:
        print('SKIP: science value private-server check requires --port and --password-file')
        return 0
    if args.port in PORTS.values():
        parser.error('refusing an assigned pog server port; use a disposable localhost server')
    if args.password_file is None:
        parser.error('--password-file is required with --port')
    password = args.password_file.read_text().strip()

    def remote(method, options=None):
        options = ',helpers.json_to_table(' + json.dumps(json.dumps(options)) + ')' if options is not None else ''
        source = '/silent-command rcon.print(helpers.table_to_json(remote.call("science_value_probe",' + json.dumps(method) + options + ')))'
        c = Rcon('127.0.0.1', args.port, password, timeout=60)
        try:
            result = c.command(source).strip()
            try:
                return json.loads(result)
            except ValueError:
                raise AssertionError(result) from None
        finally:
            c.sock.close()

    results = {}
    cases = [('normal', {}, 1), ('uncommon', {'quality': 'uncommon'}, 2),
             ('legendary', {'quality': 'legendary', 'count': 2}, 6),
             ('half_used', {'count': 1, 'durability': 0.5}, 0.5),
             ('natural', {'natural': True}, 1)]
    for name, options, durability in cases:
        remote('setup', options)
        deadline = time.monotonic() + 150
        while True:
            rows = remote('results')
            if len(rows) == 5 and all('agricultural-science-pack' not in r['packs'] for r in rows):
                break
            assert time.monotonic() < deadline, (name, rows)
            time.sleep(0.5)
        count = options.get('count', 20)
        for r in rows:
            expected = count * durability * (1 - r['spoil'])
            actual = r['units']
            if name == 'natural':
                assert expected * 0.995 < actual < expected, (name, r, expected)
            else:
                assert abs(actual - expected) < 0.001, (name, r, expected)
            assert r['productivity'] == 0, r
            for item, stack in r['packs'].items():
                used = 200 - (stack['count'] - 1 + stack['durability'])
                assert abs(used - actual) < 1e-8, (name, item, used, actual)
        results[name] = rows
        print(name + ': ' + ', '.join(f"{r['spoil']:.0%} -> {r['units']:.9f} units" for r in rows), flush=True)
    if args.output:
        args.output.write_text(json.dumps(results, indent=2) + '\n')
    print('PASS: 25 private-engine science value cases; other science consumption matches research progress')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
