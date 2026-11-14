"""Restartable YouTube rollover; preserve privacy and recover ambiguous insert replies.

12 hours is an archive/DVR boundary, not a documented forced live cutoff. Rotate
at 11 hours by policy. Never create repeatedly on API/ingest errors or revocation.
"""
import datetime
import json
import time
import urllib.error
import urllib.request
from urllib.parse import urlencode

from public_broadcast import broadcast_body
from run_state import write, read, alert
from yt_upload import API, access_token


class RequestRejected(RuntimeError):
    """No broadcast was inserted: request was unsent or explicitly rejected."""


class LiveAPI:
    """Short deadline; no blind retry of inserts. Controller owns retry/backoff."""
    def call(self, method, url, body=None):
        try:
            token = access_token()
        except (Exception, SystemExit) as e:
            # Token acquisition precedes the API request, so retrying cannot
            # duplicate a broadcast. Do not expose credential-bearing errors.
            raise RequestRejected('YouTube authorization unavailable') from e
        req = urllib.request.Request(url, method=method,
            headers={'Authorization':'Bearer '+token, 'Content-Type':'application/json'},
            data=json.dumps(body).encode() if body is not None else None)
        try:
            with urllib.request.urlopen(req, timeout=20) as response:
                return json.load(response)
        except urllib.error.HTTPError as e:
            # No credential-bearing request or arbitrary provider payload in logs.
            e.close()
            if e.code in (401, 403, 429):
                raise RequestRejected(f'YouTube HTTP {e.code}') from e
            raise RuntimeError(f'YouTube HTTP {e.code}') from e


class Rotation:
    def __init__(self, op, api, privacy, stop, transition, get_broadcast, interval=11*3600):
        self.op, self.api, self.privacy, self.stop = op, api, privacy, stop
        self.transition, self.broadcast = transition, get_broadcast
        if not 300 <= interval <= 11.5*3600:
            raise ValueError('rotation interval must be 300..41400 seconds')
        self.interval = interval
        self.path = op/'broadcast-rotation.json'

    def advance(self, receipt, live_at, now=None):
        now = time.time() if now is None else now
        pending = read(self.path, {})
        current = self.broadcast(self.api, receipt)
        status = current['status']['lifeCycleStatus']
        if status == 'revoked':
            raise RuntimeError('broadcast revoked; operator must review channel restrictions')
        # An earlier completion may have been observed before our local commit.
        if not pending or pending.get('phase') == 'committed':
            if status != 'complete' and now-live_at < self.interval:
                if status != 'live':
                    raise RuntimeError('broadcast is not live: '+status)
                return receipt, live_at, False
            number = int(pending.get('number', 0))+1
            marker = f'mt-{self.op.parent.name}-{receipt["id"]}-{number}'
            title = receipt['request']['snippet']['title'].split(' [mt-')[0]
            start = datetime.datetime.fromtimestamp(now, datetime.timezone.utc).isoformat()
            body = broadcast_body((title+' ['+marker+']')[:100], start, self.privacy)
            body['snippet']['description'] += '\nRollover receipt: '+marker
            pending = dict(phase='planned', number=number, old=receipt, body=body,
                           marker=marker, planned=now, attempted=False)
            write(self.path, pending)
            alert(self.op, 'broadcast-rotation', 'Preparing same-privacy replacement for '+receipt['id'])
        elif pending['old']['id'] != receipt['id']:
            # Commit was interrupted after publishing the new broadcast receipt.
            if pending.get('new',{}).get('id') == receipt['id']:
                pending['phase'] = 'committed'
                write(self.path, pending)
                return receipt, pending['live_at'], True
            raise RuntimeError('rotation receipt belongs to a different broadcast')

        if not pending.get('new'):
            if pending['attempted']:
                # An insert can succeed while its response is lost. Find its unique
                # description marker before doing anything else; never blind-insert.
                found, token = [], ''
                for _ in range(20):
                    q=urlencode({'part':'id,snippet,status,contentDetails','mine':'true',
                                 'broadcastStatus':'all','maxResults':50,'pageToken':token})
                    result=self.api.call('GET', API+'/liveBroadcasts?'+q)
                    found.extend(b for b in result.get('items',[]) if
                                 '\nRollover receipt: '+pending['marker'] in b.get('snippet',{}).get('description',''))
                    token=result.get('nextPageToken','')
                    if not token:
                        break
                if len(found) != 1:
                    raise RuntimeError('ambiguous broadcast insert; reconciliation found '+str(len(found))+' matches; operator review required before another insert')
                bid=found[0]['id']
            else:
                # A rejected request may wait hours for quota/auth to recover.
                # YouTube requires a future start time; refresh only while we
                # know no insertion has succeeded, retaining the unique marker.
                pending['body']['snippet']['scheduledStartTime'] = (
                    datetime.datetime.fromtimestamp(now+60, datetime.timezone.utc).isoformat())
                pending['attempted']=True
                write(self.path,pending)
                try:
                    result=self.api.call('POST', API+'/liveBroadcasts?part=snippet,status,contentDetails', body=pending['body'])
                except RequestRejected:
                    pending['attempted']=False
                    write(self.path,pending)
                    raise
                bid=result['id']
            pending['new']=dict(id=bid, stream_id=receipt['stream_id'], request=pending['body'],
                                bound=False, session_privacy=self.privacy)
            write(self.path,pending)
        new=pending['new']
        q=urlencode({'id':new['id'],'part':'status,contentDetails'})
        row=self.api.call('GET',API+'/liveBroadcasts?'+q)['items'][0]
        if row['status']['privacyStatus'] != self.privacy:
            raise RuntimeError('replacement privacy changed; refusing rollover')
        binding=row['contentDetails'].get('boundStreamId')
        if binding and binding != receipt['stream_id']:
            raise RuntimeError('replacement binding changed')
        if not binding:
            q=urlencode({'id':new['id'],'part':'id,contentDetails,status','streamId':receipt['stream_id']})
            self.api.call('POST',API+'/liveBroadcasts/bind?'+q)
        new['bound']=True
        write(self.path,pending)
        # Keep OBS ingest running. The API permits reusable streams; the old
        # broadcast must end before the replacement transitions to testing/live.
        if status != 'complete':
            self.transition(self.api,receipt,'complete',self.stop)
        phase=self.broadcast(self.api,new)['status']['lifeCycleStatus']
        if phase in ('created','ready'):
            self.transition(self.api,new,'testing',self.stop)
        self.transition(self.api,new,'live',self.stop)
        pending.update(live_at=now,phase='live')
        write(self.path,pending)
        write(self.op/'broadcast.json',new)
        pending['phase']='committed'
        write(self.path,pending)
        alert(self.op,'broadcast-rotated','https://www.youtube.com/watch?v='+new['id'])
        return new, now, True
