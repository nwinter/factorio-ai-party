#!/usr/bin/env python3
"""Operator-only YouTube broadcast insert + bind, dry-run by default; never goes live.

  python3 tools/mt/public_broadcast.py streams
  python3 tools/mt/public_broadcast.py create --title 'Factorio team tests' \
      --start 2026-11-09T05:00:00Z --stream-id ID --receipt /ABS/PATH/broadcast.json
  # Repeat with --execute to create it, after reviewing the requests.

Reuses yt_upload's OAuth token with youtube scope. Receipt permits a failed bind
to be retried without creating another broadcast. No ingest keys are printed.
"""
import argparse
import datetime
import json
from pathlib import Path
import sys
import urllib.parse

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from yt_upload import Api, API


def broadcast_body(title, start, privacy='unlisted'):
    instant = datetime.datetime.fromisoformat(start.replace('Z', '+00:00'))
    if instant.utcoffset() is None:
        raise ValueError('--start requires a timezone (for example Z)')
    return {'snippet': {'title': title, 'scheduledStartTime': instant.isoformat(),
                        'description': 'Team tests: AI teams play Factorio 2.1: Space Age. Moderated site and YouTube chat reaches every team. Watch at https://factorio.nickwinter.net/live/'},
            'status': {'privacyStatus': privacy, 'selfDeclaredMadeForKids': False},
            'contentDetails': {'enableAutoStart': False, 'enableAutoStop': False,
                               'enableDvr': True, 'recordFromStart': True,
                               'monitorStream': {'enableMonitorStream': True, 'broadcastStreamDelayMs': 0}}}


def create(api, body, stream_id, receipt):
    saved = json.loads(receipt.read_text()) if receipt.exists() else {}
    if saved and (saved.get('stream_id') != stream_id or saved.get('request') != body):
        raise ValueError('receipt belongs to different broadcast settings; use a new receipt path')
    bid = saved.get('id')
    if not bid:
        result = api.call('POST', API + '/liveBroadcasts?part=snippet,status,contentDetails', body=body)
        bid = result.get('id') or ('DRY_RUN_BROADCAST_ID' if api.dry else None)
        if not bid:
            raise RuntimeError('insert returned no broadcast ID; inspect channel before retrying')
        saved = {'id': bid, 'stream_id': stream_id, 'request': body, 'bound': False}
        if not api.dry:
            receipt.parent.mkdir(parents=True, exist_ok=True)
            receipt.write_text(json.dumps(saved, indent=2) + '\n')
    if not saved.get('bound'):
        params = urllib.parse.urlencode({'id': bid, 'part': 'id,contentDetails,status', 'streamId': stream_id})
        api.call('POST', API + '/liveBroadcasts/bind?' + params)
        saved['bound'] = True
        if not api.dry:
            receipt.write_text(json.dumps(saved, indent=2) + '\n')
    print(f'https://www.youtube.com/watch?v={bid}')
    print('Bound, auto-start OFF, auto-stop OFF. OBS streaming and broadcast transition remain operator actions.')
    return saved


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='command', required=True)
    sub.add_parser('streams', help='list existing stream IDs/titles/status, without ingest secrets')
    p = sub.add_parser('create')
    p.add_argument('--title', required=True)
    p.add_argument('--start', required=True)
    p.add_argument('--stream-id', required=True)
    p.add_argument('--receipt', type=Path, required=True)
    p.add_argument('--execute', action='store_true')
    # Nick d39: test videos are unlisted so they stay out of the channel feed
    p.add_argument('--privacy', choices=('unlisted', 'public', 'private'), default='unlisted')
    args = ap.parse_args()
    if args.command == 'streams':
        api, token = Api(False), ''
        while True:
            q = urllib.parse.urlencode({'part': 'id,snippet,status', 'mine': 'true', 'maxResults': 50, 'pageToken': token})
            reply = api.call('GET', API + '/liveStreams?' + q)
            for item in reply.get('items', []):
                print(item['id'], item.get('snippet', {}).get('title'), item.get('status', {}).get('streamStatus'))
            token = reply.get('nextPageToken')
            if not token:
                break
    else:
        create(Api(not args.execute), broadcast_body(args.title, args.start, args.privacy), args.stream_id, args.receipt)


if __name__ == '__main__':
    main()
