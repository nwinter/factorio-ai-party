#!/usr/bin/env python3
"""Offline scene-order regression: subset cuts, restarts, panels/inset/host, and read-only diagnosis."""
import itertools
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parent))
from cuts import Cuts, order
from scene_order import overlay_ids, raise_overlays, report, read_program, line
from test_cuts import FakeOBS, LAYOUT


class SceneOrderTest(unittest.TestCase):
    def test_arbitrary_capture_slots_overlay_is_last(self):
        for ids in itertools.permutations(range(5)):
            items = [(i, k) for k, i in enumerate(ids)]
            for front in ((1, 2), (2, 1)):
                after = order(items, [1, 2], front, overlays=[4])
                self.assertEqual(after[-1], 4)
                self.assertEqual([i for i in after if i in (1, 2)], list(reversed(front)))
                self.assertEqual([i for i in after if i in (0, 3)], [i for i in ids if i in (0, 3)])
                self.assertEqual(sorted(after), list(range(5)))

    def test_count_switch_alone_does_not_break_correct_order(self):
        # Pre-fix algorithm: permutation within existing slots cannot cross an unrelated overlay.
        items = [(i, i) for i in range(6)]  # background, host, three cams, overlay
        for cams in ([2], [2, 3, 4]):
            for front in itertools.permutations(cams):
                old = order(items, cams, front)
                self.assertEqual(old[-1], 5)
        # It DOES preserve an already corrupt camera slot above the overlay.
        self.assertEqual(order([(i, i) for i in range(6)], [2, 5], [2, 5])[-1], 2)

    def test_restart_one_three_inset_trio_host_and_unmanaged_capture(self):
        obs = FakeOBS(vertical=True)
        obs.scenes['stream'] = ['stream background', 'stream host', 'stream cam3', 'stream cam2',
                                'stream overlay', 'stream game audio', 'stream cam1', 'extra game capture']
        obs.scenes['V'] = ['vertical background', 'vertical overlay', 'stream cam3', 'stream cam2', 'stream cam1']
        for name in ('stream host', 'stream game audio', 'extra game capture'):
            obs.ids[name] = max(obs.ids.values()) + 1
        # FakeOBS doesn't need enable state for placement, but records it for the assertions.
        original = obs.call
        enabled = []
        def call(req, data=None):
            if req == 'SetSceneItemEnabled': enabled.append(data); return {}
            return original(req, data)
        obs.call = call
        for slots, sources, program in [
            (['main'], ['stream cam1'], {'onair': 'main'}),
            (['main', 'cam2', 'cam3'], ['stream cam1', 'stream cam2', 'stream cam3'], {'onair': 'cam2', 'inset': 'cam3'}),
            (['main', 'cam2', 'cam3'], ['stream cam1', 'stream cam2', 'stream cam3'],
             {'onair': 'main', 'layout': 'trio', 'tiles': {'main': 'main', 'cam2': 'cam2', 'cam3': 'cam3'}}),
            (['main'], ['stream cam1'], {'onair': 'main', 'host': True}),
        ]:
            cuts = Cuts(obs, LAYOUT, slots=slots, sources=sources, start=False, log=lambda *a: None)
            cuts.set(program); cuts.work()
            self.assertEqual(obs.scenes['stream'][-1], 'stream overlay')
            self.assertEqual(obs.scenes['V'][-1], 'vertical overlay')
            self.assertEqual(obs.scenes['stream'][0], 'stream background')
        self.assertTrue(enabled)
        self.assertFalse(any(x['sceneItemId'] == obs.ids['stream overlay'] for x in enabled))

    def test_capture_appended_during_apply_gets_below_final_pin(self):
        obs = FakeOBS()
        original = obs.call
        added = False
        def call(req, data=None):
            nonlocal added
            if req == 'SetSceneItemTransform' and not added:
                added = True
                obs.ids['late capture'] = max(obs.ids.values()) + 1
                obs.scenes['stream'].append('late capture')
            return original(req, data)
        obs.call = call
        cuts = Cuts(obs, LAYOUT, start=False, vertical=None, log=lambda *a: None)
        cuts.set({'onair': 'main'}); cuts.work()
        self.assertTrue(added)
        self.assertEqual(obs.scenes['stream'][-1], 'stream overlay')
        self.assertEqual(obs.scenes['stream'][-2], 'late capture')

    def test_strict_enabled_check_and_read_only_program_selection(self):
        items = [dict(sceneItemId=i, sceneItemIndex=k, sourceName=n, sceneItemEnabled=on)
                 for k, (i, n, on) in enumerate([(1, 'background', True), (5, 'stream overlay', True),
                                               (6, 'audio only', True), (7, 'cam1', True)])]
        bad = report(items, 'stream')
        self.assertFalse(bad['ok']); self.assertIn('cam1', line(bad)[0]); self.assertIn('audio only', line(bad)[0])
        items[-1]['sceneItemEnabled'] = False; items[-2]['sceneItemEnabled'] = False
        self.assertTrue(report(items, 'stream')['ok'])
        items[1]['sceneItemEnabled'] = False
        self.assertEqual(report(items, 'stream')['reason'], 'disabled')
        self.assertEqual(report(items[:1], 'stream')['reason'], 'missing')
        calls = []
        def call(req, data=None):
            calls.append((req, data))
            if req == 'GetCurrentProgramScene': return {'currentProgramSceneName': 'actual program'}
            self.assertEqual(req, 'GetSceneItemList'); self.assertEqual(data, {'sceneName': 'actual program'})
            return {'sceneItems': items}
        self.assertEqual(read_program(call)['scene'], 'actual program')
        self.assertEqual([x[0] for x in calls], ['GetCurrentProgramScene', 'GetSceneItemList'])

    def test_pin_uses_indices_and_is_idempotent(self):
        items = [dict(sceneItemId=i, sceneItemIndex=k, sourceName=n) for k, (i, n) in enumerate(
            [(1, 'background'), (5, 'stream overlay'), (7, 'game'), (6, 'audio')])]
        writes = []
        def setter(iid, idx):
            writes.append((iid, idx)); item = next(x for x in items if x['sceneItemId'] == iid)
            items.remove(item); items.insert(idx, item)
            for k, x in enumerate(items): x['sceneItemIndex'] = k
        raise_overlays(list(reversed(items)), setter)
        self.assertEqual(writes, [(5, 3)])
        self.assertTrue(report(items, 'stream')['ok'])
        raise_overlays(items, setter)
        self.assertEqual(writes, [(5, 3)])


if __name__ == '__main__':
    unittest.main()
