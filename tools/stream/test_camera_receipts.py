#!/usr/bin/env python3
"""Camera acknowledgement and compositor readiness, entirely with stubs."""
import copy
from director import Director
from onecam import OneCam
from test_onecam import agent, snap
from cuts import Cuts
from test_cuts import FakeOBS, HostOBS, LAYOUT


def shot(name):
    return dict(subject=name, agents=[name], follow=name, zoom=0.8, since=10)


def sends():
    for slot in ({'slot': 'main', 'player': 3},
                 {'slot': 'cam2', 'player': 3, 'panel': 1, 'rect': [0, 0, .3, .3]}):
        calls, replies = [], [{'ok': True}, {'ok': False}, {'ok': True, 'result': {'ok': False}}, {'ok': True}]
        def send(body):
            calls.append(body)
            return replies.pop(0)
        d = Director([slot], send, None)
        assert d.apply(slot, shot('luna'), 'initial', {}, 10)
        old = copy.deepcopy(d.state)
        assert not d.apply(slot, shot('sol'), 'switch', {}, 20)
        assert d.state == old and d.last_cut == 10
        assert d.requested[slot['slot']]['subject'] == 'sol'
        assert not d.apply(slot, shot('sol'), 'switch', {}, 20.1)
        assert len(calls) == 2
        d.retry_sends(20.5)
        assert d.state == old and d.send_pending[slot['slot']]['retry_at'] == 21.5
        d.retry_sends(21.5)
        assert d.state[slot['slot']]['subject'] == 'sol' and not d.send_pending
        assert d.on_air[slot['slot']] is None
    d = Director([slot], lambda b: (_ for _ in ()).throw(OSError('offline')), None)
    for t in range(100):
        d.apply(slot, shot('sol'), 'switch', {}, t, quiet=True)
    assert d.state[slot['slot']] is None and d.send_pending[slot['slot']]['retry_at'] <= 107
    # OneCam must stop before retarget records an on-air cut, including its first failed send.
    d = OneCam([{'slot': 'main', 'player': 3}], lambda b: {'ok': False}, None, trio=False)
    d.step(snap([agent('luna', 0, 0)]), 100)
    assert not d.cuts and d.state['main'] is None
    d.sender = lambda b: {'ok': True}
    d.step(snap([agent('luna', 0, 0)]), 101)
    assert d.state['main']['subject'] == 'luna'
    d = OneCam([{'slot': 'main', 'player': 3}, {'slot': 'cam2', 'player': 4}],
               lambda b: {'ok': False}, None, trio=False)
    d.step(snap([agent('luna', 0, 0)]), 100)
    d.sender = lambda b: {'ok': True}
    d.retry_sends(110)
    assert d.state['cam2']['framed'] == 110 and not d.ready('cam2', 110)
    assert d.ready('cam2', 112)


def frames():
    o = FakeOBS()
    c = Cuts(o, LAYOUT, start=False, vertical=None, log=lambda x: None)
    c.set({'onair': 'main', 'inset': None})
    c.work(10)
    old = copy.deepcopy((o.scenes, o.transforms, c.applied))
    o.sizes[o.ids['stream cam2']] = (0, 0)
    c.set({'onair': 'cam2', 'inset': None})
    c.work(11)
    assert (o.scenes, o.transforms, c.applied) == old
    assert c.public()['requested']['onair'] == 'cam2'
    assert c.public()['acknowledged']['onair'] == 'cam2'
    assert c.public()['on_air']['onair'] == 'main'
    n = len(o.calls)
    c.set({'onair': 'cam2', 'inset': None, 'frames': {'main': {'label': 'new ship progress'}}})
    c.work(11.1)
    assert len(o.calls) == n
    o.sizes[o.ids['stream cam2']] = (2880, 1620)
    c.work(11.5)  # no set(), no layout change
    assert c.applied['onair'] == 'cam2'
    assert o.scenes['stream'][-2] == 'stream cam2'
    assert o.tf('stream cam2')['cropLeft'] == 492
    n = len(o.calls)
    c.set({'onair': 'cam2', 'inset': None, 'frames': {'main': {'label': 'latest ship progress'}}})
    c.work(12)
    assert len(o.calls) == n and c.applied['frames']['main']['label'] == 'latest ship progress'
    # A newly visible panel, trio tile and host obey the same readiness gate.
    for want, src in [({'onair': 'cam2', 'inset': 'cam3'}, 'stream cam3'),
                      ({'onair': 'cam2', 'layout': 'trio', 'tiles': {'main': 'cam2', 'cam2': 'main', 'cam3': 'cam3'}}, 'stream cam3')]:
        old = copy.deepcopy((o.scenes, o.transforms, c.applied))
        o.sizes[o.ids[src]] = (0, 0)
        c.set(want); c.work(20)
        assert (o.scenes, o.transforms, c.applied) == old
        o.sizes[o.ids[src]] = (1920, 1080)
        c.work(21)
        assert c.applied == want
    o = HostOBS(); c = Cuts(o, LAYOUT, start=False, vertical=None, log=lambda x: None)
    c.set({'onair': 'main'}); c.work(10)
    o.sizes[o.ids['stream host']] = (0, 0)
    c.set({'onair': 'main', 'host': True}); c.work(11)
    assert not o.enabled['stream host'] and not c.applied.get('host')
    o.sizes[o.ids['stream host']] = (1920, 1080)
    c.work(12)
    assert o.enabled['stream host'] and o.tf('stream host')['cropLeft'] == 328
    # Failed panel send blocks a ready capture too.
    c.set({'onair': 'main', 'inset': 'cam3', 'cameras': {'cam3': {'pending': True}}})
    c.work(13)
    assert not c.applied.get('inset')
    c.set({'onair': 'main', 'inset': 'cam3', 'cameras': {'cam3': {'pending': False, 'shot': None}}})
    c.work(14)
    assert not c.applied.get('inset'), 'positive capture dimensions alone are not a camera acknowledgement'


if __name__ == '__main__':
    sends(); frames()
    print('camera receipts: ok (failed main/panel sends, capped retry, unchanged 0x0-to-ready, last valid frame)')
