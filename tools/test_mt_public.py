#!/usr/bin/env python3
"""Offline regressions for public stream safety, projection, camera and UDP transport."""
import json
from pathlib import Path
import socket
import struct
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
import urllib.error
import urllib.request

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools/mt'))
import public_overlay as overlay
import public_stream as stream
import public_broadcast as broadcast
from udp_bridge import Bridge, frames


class FakeOBS:
    def __init__(self, live=False, recording=False):
        self.live, self.recording = live, recording
        self.scene, self.calls, self.inputs, self.items = 'stream', [], [], []

    def call(self, name, body=None):
        body = body or {}
        self.calls.append((name, body))
        if name == 'GetStreamStatus': return {'outputActive': self.live}
        if name == 'GetRecordStatus': return {'outputActive': self.recording}
        if name == 'GetCurrentProgramScene': return {'currentProgramSceneName': self.scene}
        if name == 'GetSceneList': return {'scenes': [{'sceneName': 'stream'}]}
        if name == 'GetInputList': return {'inputs': self.inputs}
        if name == 'GetSceneItemList': return {'sceneItems': self.items}
        if name == 'GetSceneItemId': return {'sceneItemId': len(self.calls)}
        if name == 'SetCurrentProgramScene': self.scene = body['sceneName']
        if name == 'StartRecord': self.recording = True
        if name == 'StopRecord': self.recording = False; return {'outputPath': 'recording.mkv'}
        return {}


class PublicTest(unittest.TestCase):
    def test_framing(self):
        wire = b'\x00\x03abc\x00\x00\x00\x02xy'
        buf, got = b'', []
        for byte in wire:
            packets, buf = frames(buf + bytes([byte]))
            got += packets
        self.assertEqual(got, [b'abc', b'', b'xy'])
        self.assertEqual(buf, b'')

    def test_udp_roundtrip(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
            udp.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 262144)
            udp.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 262144)
            udp.bind(('127.0.0.1', 0))
            udp.settimeout(5)
            def echo():
                for _ in range(3):
                    msg, addr = udp.recvfrom(65535)
                    udp.sendto(msg, addr)
            worker = threading.Thread(target=echo)
            worker.start()
            bridge = Bridge(0, udp.getsockname())
            bridge.start()
            try:
                with socket.create_connection(bridge.server_address, timeout=5) as tcp:
                    for packet in (b'test', b'', b'x' * 60000):
                        wire = struct.pack('!H', len(packet)) + packet
                        tcp.sendall(wire[:1]); tcp.sendall(wire[1:])
                        buf = b''
                        while len(buf) < len(wire):
                            chunk = tcp.recv(65536)
                            self.assertTrue(chunk, 'bridge closed before full datagram')
                            buf += chunk
                        self.assertEqual(frames(buf), ([packet], b''))
            finally:
                bridge.shutdown(); bridge.server_close(); worker.join(5)

    def test_public_projection(self):
        state = {'now': 100, 'errors': {'password': 'SECRET'}, 'tokens': {'account': 'SECRET'},
                 'operator_requests': ['SECRET'], 'agents': [{'name': 'a', 'display_name': '<b>A</b>', 'path': 'SECRET'}],
                 'research': {'progress': .4, 'done_count': 3}, 'chat': [{'from': 'a', 'text': '<script>hi</script>'}]}
        row = overlay.project('green', state, [{'name': 'a', 'model': 'Flash', 'harness': 'native'}], 110)
        self.assertNotIn('SECRET', json.dumps(row))
        self.assertFalse(row['stale'])
        self.assertTrue(overlay.project('green', state, [], 126)['stale'])
        self.assertTrue(overlay.project('green', dict(state, poll_ok=1), [], 110)['stale'])
        self.assertEqual(row['chat'][0]['name'], 'a')
        html = (ROOT / 'tools/mt/public-overlay.html').read_text()
        self.assertNotIn('innerHTML', html)

    def test_feeds(self):
        with tempfile.TemporaryDirectory() as d:
            op = Path(d)
            path = op / 'streams.txt'
            path.write_text('green http://127.0.0.1:8791/\nyellow http://127.0.0.1:8792/\n')
            self.assertEqual(overlay.feeds(op)[0], ('green', 'http://127.0.0.1:8791/state.json'))
            for bad in ('green http://evil.test:8791/', 'green http://127.0.0.1:8791/\ngreen http://127.0.0.1:8792/'):
                path.write_text(bad)
                with self.assertRaises(ValueError): overlay.feeds(op)

    def test_public_launch_dry_run(self):
        env = {k: v for k, v in os.environ.items() if not k.startswith(('POG_', 'FH_', 'FACTORIO_RCON_'))}
        with tempfile.TemporaryDirectory() as d:
            brief = Path(d) / 'quota.json'
            brief.write_text('{"agents": []}')
            env.update(POG_TEST='1', POG_DRY_RUN='1', POG_MT_PUBLIC='1', POG_MT_STREAM='0',
                       POG_QUOTA_BRIEF=str(brief), POG_MT_TREE='/tmp/mt288-dry',
                       PATH=str(Path(sys.executable).parent) + ':' + os.environ['PATH'])
            result = subprocess.run(['bash', str(ROOT / 'tools/mt/start-mt.sh'), 'p288dry', '25'],
                                    cwd=ROOT, env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('public staging: team feeds on 8791', result.stdout)
        self.assertIn('recording ON, streaming OFF', result.stdout)
        self.assertIn('viewer chat through the team services', result.stdout)
        self.assertFalse((ROOT / 'runs/p288dry/op').exists())

    def test_camera_chart_and_index(self):
        class Harness:
            team = 'green'
            charted = False
            calls = []
            def lua(self, lua):
                if 'get_player' in lua: return {'index': 7}
                return {'center': True, 'charted': 4 if self.charted else 0, 'chunks': 4}
            def camera(self, body): self.calls.append(body); return {'ok': True}
        h = Harness()
        state = {'basemap': {'core': {'x0': 100, 'y0': 200, 'w': 20, 'h': 10, 'cell': 2}}}
        with self.assertRaises(ValueError): overlay.cut(h, state)
        self.assertEqual(h.calls, [])
        h.charted = True
        self.assertEqual(overlay.cut(h, state)['team'], 'green')
        self.assertEqual(h.calls[0]['player'], 7)
        self.assertEqual(h.calls[0]['position'], {'x': 120, 'y': 210})

    def test_obs_isolated_and_record_owned(self):
        obs, receipt = FakeOBS(), {}
        stream.setup_obs(obs, 'http://127.0.0.1:8790/', receipt)
        self.assertTrue(obs.recording)
        self.assertEqual(obs.scene, 'mt-stream')
        stream.restore_obs(obs, receipt)
        self.assertEqual(obs.scene, 'stream')
        self.assertFalse(obs.recording)
        self.assertFalse(receipt['recording_active'])
        for name, body in obs.calls:
            self.assertNotIn(name, ('StartStream', 'SetStreamServiceSettings', 'RemoveInput', 'RemoveScene'))
            if name.startswith('SetSceneItem'):
                self.assertEqual(body['sceneName'], 'mt-stream')
        obs, receipt = FakeOBS(recording=True), {}
        stream.setup_obs(obs, 'http://127.0.0.1:8790/', receipt)
        stream.restore_obs(obs, receipt)
        self.assertTrue(obs.recording)

    def test_obs_live_refused_before_mutation(self):
        obs = FakeOBS(live=True)
        with self.assertRaises(RuntimeError): stream.setup_obs(obs, 'url', {})
        self.assertEqual([c[0] for c in obs.calls], ['GetStreamStatus'])

    def test_record_start_is_asynchronous(self):
        class DelayedOBS(FakeOBS):
            waiting = 2
            def call(self, name, body=None):
                result = super().call(name, body)
                if name == 'GetRecordStatus' and self.recording and self.waiting:
                    self.waiting -= 1
                    return {'outputActive': False}
                return result
        obs, receipt = DelayedOBS(), {}
        with mock.patch.object(stream.time, 'sleep') as sleep:
            stream.setup_obs(obs, 'http://127.0.0.1:8790/', receipt)
        self.assertEqual(sleep.call_count, 2)
        self.assertTrue(receipt['record_started'])

    def test_record_stop_is_asynchronous(self):
        class DelayedOBS(FakeOBS):
            stopping = 0
            def call(self, name, body=None):
                result = super().call(name, body)
                if name == 'StopRecord': self.stopping = 2
                if name == 'GetRecordStatus' and self.stopping:
                    self.stopping -= 1
                    return {'outputActive': True}
                return result
        obs = DelayedOBS(recording=True)
        receipt = {'record_started': True, 'previous_scene': 'stream'}
        with mock.patch.object(stream.time, 'sleep') as sleep:
            stream.restore_obs(obs, receipt)
        self.assertEqual(sleep.call_count, 2)
        self.assertFalse(receipt['recording_active'])

    def test_overlay_uses_filtered_feed_only(self):
        source = (ROOT / 'tools/mt/public_overlay.py').read_text()
        self.assertNotIn('YouTubeChat(', source)
        self.assertNotIn('Feed(', source)
        out = overlay.audience({'green': {'viewers': [{'id': 'site:8', 'name': 'Guest', 'text': 'How are the furnaces?', 'source': 'site', 't': 99}] }}, {'green': []}, 100)
        self.assertEqual(out['viewers'][0]['text'], 'How are the furnaces?')

    def test_broadcast_resume_bind(self):
        class Api:
            dry = False
            fail = True
            calls = []
            def call(self, method, url, body=None):
                self.calls.append((method, url, body))
                if '/bind?' in url and self.fail: raise RuntimeError('failed bind')
                return {'id': 'testid'}
        with tempfile.TemporaryDirectory() as d:
            receipt = Path(d) / 'broadcast.json'
            body = broadcast.broadcast_body('Test', '2026-11-09T05:00:00Z')
            self.assertFalse(body['contentDetails']['enableAutoStop'])
            self.assertEqual(body['status']['privacyStatus'], 'unlisted')
            self.assertFalse(body['contentDetails']['enableAutoStart'])
            api = Api()
            with self.assertRaises(RuntimeError): broadcast.create(api, body, 'sid', receipt)
            api.fail = False
            broadcast.create(api, body, 'sid', receipt)
            self.assertEqual(len([c for c in api.calls if '/liveBroadcasts?' in c[1]]), 1)
            self.assertEqual(len([c for c in api.calls if '/bind?' in c[1]]), 2)
            self.assertTrue(json.loads(receipt.read_text())['bound'])

    def test_http_read_only(self):
        with tempfile.TemporaryDirectory() as d:
            op, tree = Path(d), Path(d) / 'tree'
            td = tree / 'runs/test/green'
            td.mkdir(parents=True)
            (td / 'team.tsv').write_text('a\tagy\troute\tmodel\thigh\tFlash\tagy\n')
            (op / 'streams.txt').write_text('green http://127.0.0.1:1/\n')
            service = overlay.PublicOverlay(op, tree, 'test', port=0, camera=False)
            threading.Thread(target=service.http.serve_forever, daemon=True).start()
            url = f'http://127.0.0.1:{service.http.server_port}'
            try:
                with urllib.request.urlopen(url + '/state.json') as r: self.assertEqual(json.load(r)['viewers'], [])
                for method in ('POST', 'PUT', 'DELETE'):
                    with self.assertRaises(urllib.error.HTTPError) as e:
                        urllib.request.urlopen(urllib.request.Request(url + '/say', data=b'{}', method=method))
                    self.assertEqual(e.exception.code, 501)
                    e.exception.close()
                with self.assertRaises(urllib.error.HTTPError) as e: urllib.request.urlopen(url + '/../../task-common.md')
                e.exception.close()
            finally:
                service.close()


if __name__ == '__main__':
    unittest.main()
