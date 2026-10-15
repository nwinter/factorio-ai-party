#!/usr/bin/env python3
"""Optional check on a disposable 2.0.77 server with drill-sites-probe installed.

Creates a test force and surface; never use an assigned/live world. No arguments
skip for the merge gate. The probe checks engine placement and mining-area sums.
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
        print('SKIP: drill sites engine check requires --port and --password-file')
        return 0
    if args.port in PORTS.values() or args.password_file is None:
        parser.error('requires a disposable localhost port and --password-file; assigned pog ports refused')
    password = args.password_file.read_text().strip()

    def call(method, options=None):
        opt = ',helpers.json_to_table(' + json.dumps(json.dumps(options)) + ')' if options else ''
        source = '/silent-command rcon.print(helpers.table_to_json(remote.call("drill_sites_probe",' + json.dumps(method) + opt + ')))'
        connection = Rcon('127.0.0.1', args.port, password, timeout=60)
        try:
            result = connection.command(source).strip()
            try:
                lines = result.splitlines()
                out = json.loads(lines[-1])
                if len(lines) > 1:
                    out['profiler'] = '; '.join(lines[:-1])
                return out
            except ValueError:
                raise AssertionError(result) from None
        finally:
            connection.sock.close()

    # A fresh private save requires the console's one-time achievements opt-in.
    c = Rcon('127.0.0.1', args.port, password, timeout=60)
    try:
        c.command('/silent-command rcon.print("private probe")')
        c.command('/silent-command rcon.print("private probe")')
    finally:
        c.sock.close()
    rows = []
    for drill, quality in [('burner-mining-drill', 'normal'), ('electric-mining-drill', 'normal'), ('big-mining-drill', 'rare')]:
        call('setup', {'drill': drill, 'quality': quality})
        time.sleep(2)
        row = call('run')
        assert row['version'] == '2.0.77', row['version']
        rows.append(row)
        print(drill, row['profiler'], len(row['view']['sites']), 'sites')
    if args.output:
        args.output.write_text(json.dumps(rows, indent=2) + '\n')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
