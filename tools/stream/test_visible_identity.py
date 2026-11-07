#!/usr/bin/env python3
"""OBS readback, partial apply, current camera surfaces and fail-closed public frames; no services."""
import copy
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch

from cuts import Cuts, VERIFY_EVERY, VERIFY_TTL
from obsws import OBSError
from platformmetrics import selected
from test_cuts import HostOBS, LAYOUT

STATES = []


def record(label, cuts):
    STATES.append((label, snapshot(cuts)))


class OBS(HostOBS):
    def __init__(self, vertical=False):
        super().__init__()
        if vertical:
            self.vertical = True
            self.scenes['V'] = ['stream background', 'stream cam1', 'stream cam2', 'stream cam3', 'stream overlay']
            self.scenes['V'][-1] = 'vertical overlay'
            self.ids['vertical overlay'] = 100
        self.program = 'stream'
        self.vertical_program = 'stream vertical'
        self.fail_index = None
        self.moves = 0
        self.fail_read = False
        self.during_write = None

    def call(self, req, d=None):
        if req == 'CallVendorRequest':
            self.calls.append(req)
            assert d['requestType'] == 'current_scene'
            return {'responseData': {'scene': self.vertical_program, 'success': True}}
        if req == 'GetCurrentProgramScene':
            self.calls.append(req)
            if self.fail_read:
                raise OBSError('readback disconnected')
            return {'currentProgramSceneName': self.program}
        if req.startswith('Set') and self.during_write:
            self.during_write()
        if req == 'SetSceneItemIndex':
            self.moves += 1
            if self.fail_index == self.moves:
                super().call(req, d)  # OBS moved it, but the reply/remaining target writes fail.
                raise OBSError('disconnected after partial reorder')
        return super().call(req, d)


def ship(name, surface, sent=1):
    return dict(agents=[], subject='@platform', position=dict(x=0, y=0), surface=surface,
                zoom=.5, game_zoom=.5, sent=sent, since=sent,
                platform=dict(name=name, why='featured', label='Featured: '+name+' · guns in action'))


def program(onair='main', surface='platform-1', name='Asterion', sent=1):
    # Use the real director's public camera serialization (batch428), not hand-built label objects.
    from onecam import OneCam
    from test_platformcam import plat, snap, VIEW
    slots = [dict(slot=s, player=i+1) for i, s in enumerate(('main', 'cam2', 'cam3'))]
    d = OneCam(slots, lambda b: {'ok': True}, None, auto_feature=False, trio=False)
    ships = [plat('Asterion', view=dict(VIEW, surface='platform-1')),
             plat('Resolute', view=dict(VIEW, surface='platform-2'))]
    d.watch_platforms(snap([], ships), 1000)
    d.state = {'main': ship('Asterion', 'platform-1'), 'cam2': ship('Resolute', 'platform-2'), 'cam3': None}
    d.state[onair] = ship(name, surface, sent)
    d.onair = onair
    p = d.program()
    p.update(cameras={s: dict(pending=False, shot=t) for s,t in d.state.items()}, frames=d.public(1000))
    return p


def snapshot(cuts):
    public = cuts.public()
    aired = public.get('on_air') or {}
    return dict(cameras=aired.get('frames') or {}, cuts=public, program=aired,
                space={'platforms': [dict(name=n, view={'surface':s}) for n,s in
                                     [('Asterion','platform-1'),('Resolute','platform-2')]]})


class VisibleIdentity(unittest.TestCase):
    def make(self, vertical=False):
        o = OBS(vertical)
        c = Cuts(o, LAYOUT, start=False, vertical=None if not vertical else __import__('cuts').VERTICAL, log=lambda *a: None)
        self.assertIsNone(c.public()['on_air'])
        c.set(program()); c.work(100)
        self.assertEqual(selected(snapshot(c))['name'], 'Asterion')
        return o, c

    def test_partial_reorder_invalidates_before_first_write_and_recovers(self):
        o,c = self.make(vertical=True)
        before = copy.deepcopy(o.scenes)
        record('confirmed-asterion', c)
        o.moves = 0
        o.fail_index = 1
        o.during_write = lambda: self.assertIsNone(c.public()['on_air'])
        c.set(program('cam2', 'platform-2', 'Resolute'))
        with self.assertRaisesRegex(OBSError, 'partial reorder'):
            c.work(101)
        self.assertNotEqual(o.scenes, before, 'failure must occur after a real scene mutation')
        self.assertEqual(o.scenes['stream'][-2], 'stream cam2')
        self.assertEqual(o.scenes['V'][-2], 'stream cam1')
        self.assertIsNone(c.public()['on_air'])
        self.assertIsNone(selected(snapshot(c)))
        record('partial-reorder-unknown', c)
        o.fail_index = None
        c.work(102)
        self.assertEqual(selected(snapshot(c))['name'], 'Resolute')
        record('recovered-resolute', c)

    def test_periodic_read_only_check_drift_repair_and_backoff(self):
        o,c = self.make()
        n = len(o.calls)
        c.work(104.9)
        self.assertEqual(len(o.calls), n)
        c.work(105)
        self.assertEqual(o.calls[n:], ['GetCurrentProgramScene', 'GetSceneItemList'])
        items = o.scenes['stream']
        items.remove('stream cam2'); items.insert(items.index('stream overlay'), 'stream cam2')
        c.work(110)
        self.assertIsNone(c.public()['on_air'])
        self.assertIsNone(selected(snapshot(c)))
        record('external-drift-unknown', c)
        c.work(110.1)
        self.assertEqual(selected(snapshot(c))['name'], 'Asterion')
        self.assertEqual(o.scenes['stream'][-2], 'stream cam1')
        record('external-drift-recovered', c)
        o.fail_read = True
        c.work(115.1)
        self.assertIsNone(c.public()['on_air'])
        o.fail_read = False
        c.work(116)
        self.assertTrue(c.public()['confirmed'])
        o,c = self.make(vertical=True)
        n = len(o.calls)
        c.work(105)
        self.assertEqual(o.calls[n:], ['GetCurrentProgramScene', 'GetSceneItemList',
                                      'CallVendorRequest', 'GetSceneItemList'])

    def test_same_source_changed_surface_and_pending_send_hide_old_identity(self):
        o,c = self.make()
        p = program(surface='platform-2', name='Resolute')  # same source AND send timestamp
        c.set(p)
        self.assertIsNone(c.public()['on_air'], 'camera already moved; old OBS receipt cannot name it')
        record('same-source-new-surface-unknown', c)
        c.work(101)
        self.assertEqual(selected(snapshot(c))['name'], 'Resolute')
        record('same-source-new-surface-confirmed', c)
        p['cameras']['main']['pending'] = True
        c.set(p); c.work(102)
        self.assertIsNone(c.public()['on_air'])
        p['cameras']['main']['pending'] = False
        c.set(p); c.work(103)
        self.assertEqual(selected(snapshot(c))['name'], 'Resolute')
        # An old frame attached to a new acknowledged camera must not publish either name.
        p['frames'] = program()['frames']
        c.set(p); c.work(104)
        self.assertIsNone(c.public()['on_air'])

    def test_transform_enable_capture_loss_program_scene_and_portrait_drift(self):
        for drift in ('transform', 'disable', 'zero', 'scene', 'portrait', 'portrait-scene', 'cover'):
            with self.subTest(drift=drift):
                o,c = self.make(vertical=True)
                if drift == 'transform':
                    o.transforms[('stream', o.ids['stream cam1'])]['cropLeft'] = 0
                elif drift == 'disable': o.enabled['stream cam1'] = False
                elif drift == 'zero': o.sizes[o.ids['stream cam1']] = (0,0)
                elif drift == 'scene': o.program = 'another scene'
                elif drift == 'portrait-scene': o.vertical_program = 'another-uuid'
                elif drift == 'portrait': o.scenes['V'][-3],o.scenes['V'][-2] = o.scenes['V'][-2],o.scenes['V'][-3]
                else:
                    o.ids['unexpected capture'] = 101
                    o.scenes['stream'].insert(-1, 'unexpected capture')
                c.work(105)
                self.assertIsNone(c.public()['on_air'])
                if drift in ('transform', 'disable', 'portrait'):
                    c.work(106)
                    self.assertTrue(c.public()['confirmed'], c.status)
                elif drift == 'scene':
                    c.work(106)
                    self.assertEqual(o.program, 'another scene', 'readback cannot commandeer program selection')
                    self.assertIsNone(c.public()['on_air'])
                    o.program = 'stream'; c.work(107)
                    self.assertTrue(c.public()['confirmed'])
                elif drift == 'portrait-scene':
                    c.work(106)
                    self.assertEqual(o.vertical_program, 'another-uuid')
                    self.assertIsNone(c.public()['on_air'])
                    o.vertical_program = 'stream vertical'; c.work(107)
                    self.assertTrue(c.public()['confirmed'])

    def test_receipt_expiry_and_restart(self):
        o,c = self.make()
        with patch('cuts.time.time', return_value=c.verified_at + VERIFY_TTL + .01):
            self.assertIsNone(c.public()['on_air'])
        replacement = Cuts(o, LAYOUT, start=False, vertical=None, log=lambda *a: None)
        replacement.set(program())
        self.assertIsNone(replacement.public()['on_air'])
        replacement.work(200)
        self.assertTrue(replacement.public()['confirmed'])


if __name__ == '__main__':
    result = unittest.main(exit=False).result
    if result.wasSuccessful() and os.environ.get('POG_IDENTITY_STATES'):
        Path(os.environ['POG_IDENTITY_STATES']).write_text(json.dumps(STATES, indent=2))
    raise SystemExit(not result.wasSuccessful())
