#!/usr/bin/env python3
"""Recap speech ownership and audible receipts. Offline; no game, TTS, capture or live service."""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from serve import AudioHub
from playback_memory import PlaybackMemory
import hourly
import tour


class RecapSpeechTest(unittest.TestCase):
    def setUp(self):
        self.now = 1000.0
        self.clock = patch('time.time', side_effect=lambda: self.now)
        self.clock.start()
        self.addCleanup(self.clock.stop)
        self.audio = AudioHub(require_capture=True)
        self.report(None, 'load')

    def push(self, channel='agent', **kw):
        return self.audio.push(dict(channel=channel, duration=4, expires_in=60, **kw), b'audio', 'audio/mpeg')

    def report(self, clip, state, **kw):
        self.audio.played(dict(id=clip['id'] if clip else None, state=state, capture=True,
                               page='main', session='capture', attempt=(clip or {}).get('attempt', 0), **kw))

    def test_entry_pending_playing_urgent_and_timed_all_held_before_first_line(self):
        playing = self.push('operator')
        loading = self.push()
        urgent = self.push('caster', rank='urgent')
        timed = self.push('narrator', at=self.now + 5)
        self.report(playing, 'start', duration=4)
        self.audio.acquire_speech('recap')
        self.assertEqual(set(self.audio.held), {c['id'] for c in (playing, loading, urgent, timed)})
        self.assertFalse(self.audio.pending())
        later = self.push('agent')
        self.assertIn(later['id'], self.audio.held)
        line = self.push('caster', segment={'id': 'recap'})
        seq, events = self.audio.subscription()
        self.assertEqual(events[0]['speech_owner'], 'recap')
        self.assertEqual([c['id'] for c in events[1:]], [line['id']])
        self.assertEqual([c['id'] for c in self.audio.wait(0, 0)[1] if c.get('channel') != 'control'], [line['id']])

    def test_release_resumes_same_ids_once_with_bounded_expiry_and_receipt_fence(self):
        op = self.push('operator')
        stale = self.push('caster')
        self.report(op, 'start', duration=4)
        old = dict(op)
        self.audio.acquire_speech('recap')
        self.report(op, 'held', played=1, duration=4, audible=False)
        self.now += 90
        self.audio.release_speech('recap')
        resumed = self.audio.pending()
        self.assertEqual([c['id'] for c in resumed], [op['id']])
        self.assertEqual(op['expires'], 1150)
        self.assertEqual(op['attempt'], 1)
        self.assertIn(stale['id'], self.audio.skipped)
        self.report(old, 'end', played=4, duration=4, audible=True)
        self.assertNotIn(op['id'], self.audio.completed)
        self.report(op, 'start', duration=4)
        self.report(op, 'end', played=4, duration=4, audible=True)
        self.assertIn(op['id'], self.audio.completed)
        self.audio.acquire_speech('next')
        self.audio.release_speech('next')
        self.assertNotIn(op['id'], self.audio.held)
        self.assertFalse(self.audio.pending())

    def test_reload_and_reconnect_keep_hold_and_only_final_audible_end_completes(self):
        op = self.push('operator')
        self.audio.acquire_speech('recap')
        line = self.push('caster', segment={'id': 'recap'}, recap={'line': 'one'})
        self.report(line, 'start', duration=4)
        self.report(None, 'load')
        self.assertIn(line['id'], self.audio.skipped)
        self.assertNotIn(line['id'], self.audio.completed)
        for _ in range(2):
            self.assertEqual(self.audio.subscription()[1], [self.audio.ownership()])
        self.assertIn(op['id'], self.audio.held)
        self.assertEqual(self.audio.speech_owner, 'recap')

    def test_cancelled_tour_and_recap_are_not_resurrected_by_late_hold_receipts(self):
        narration = self.push('narrator', at=1002, segment={'id': 'tour'})
        self.audio.acquire_speech('recap')
        self.assertTrue(self.audio.cancel(narration['id']))
        self.report(narration, 'held', played=0)
        line = self.push('caster', segment={'id': 'recap'}, recap={'line': 'one'})
        self.report(line, 'held', played=0)
        self.audio.stop_segment('recap')
        self.audio.release_speech('recap')
        self.assertFalse(self.audio.pending())

    def test_no_zero_missing_muted_or_partial_receipt_counts_as_heard(self):
        for fields in ({'played': 0, 'audible': True}, {'audible': True}, {'played': 4},
                       {'played': 4, 'audible': False}, {'played': 2, 'audible': True}):
            c = self.push()
            self.report(c, 'start', duration=4)
            self.now += 4
            self.report(c, 'end', duration=4, **fields)
            self.assertNotIn(c['id'], self.audio.completed, fields)
        c = self.push()
        self.report(c, 'start', duration=4)
        self.report(c, 'end', played=4, duration=4, audible=True)
        self.assertEqual(self.audio.speech()['whole_30m'], 1)

    def test_memory_keeps_held_line_unheard_and_deduplicates_resumed_receipt(self):
        memory = PlaybackMemory()
        gid = memory.generated([('Sol', 'Still relevant')], {}, {}, 'voice')
        c = self.push()
        memory.queued(gid, 0, c)
        self.report(c, 'start', duration=4)
        self.audio.acquire_speech('recap')
        self.report(c, 'held', played=1, duration=4)
        self.now += 90
        self.assertEqual(memory.receipts(self.audio.status()), [])
        self.assertEqual(memory.groups[gid]['lines'][0]['state'], 'queued')
        self.audio.release_speech('recap')
        self.report(c, 'start', duration=4)
        self.report(c, 'end', played=4, duration=4, audible=True)
        self.assertEqual(memory.receipts(self.audio.status()), [(gid, 0)])
        self.assertEqual(memory.receipts(self.audio.status()), [])

    def test_hourly_blocks_and_interrupts_recap_but_releases_after_last_line(self):
        s = {'shift_recap': {'active': True}, 'speech_owner': 'recap'}
        self.assertEqual(hourly.blocked(s, self.now), 'shift recap owns speech')
        with tempfile.TemporaryDirectory() as d:
            svc = type('Service', (), {'state': lambda _: s})()
            a = hourly.Airing(svc, out=d, clock=lambda: self.now)
            self.assertEqual(a.interrupt(), 'shift recap owns speech')
        self.assertIsNone(hourly.blocked({'shift_recap': {'active': True, 'holding': True}}, self.now))

    def test_tour_requires_completed_audible_receipt(self):
        t = tour.Tour.__new__(tour.Tour)
        rows = [{'id': 'c', 'state': 'start'}, {'id': 'c', 'state': 'end', 'completed': False}]
        t.narrated, t.aired_ids = {'c': 'stop'}, []
        t.svc = type('Service', (), {'audio_status': lambda _: {'receipts': rows}})()
        t.collect_heard()
        self.assertEqual(t.aired_ids, [])
        rows.append({'id': 'c', 'completed': True, 'audible': True})
        t.collect_heard(); t.collect_heard()
        self.assertEqual(t.aired_ids, ['stop'])

    def test_expired_held_host_continuation_is_not_regenerated(self):
        memory = PlaybackMemory()
        gid = memory.generated([('Rook', 'Heard'), ('Vale', 'Stale continuation')], {}, {}, 'writer')
        a, b = self.push('caster'), self.push('caster')
        memory.queued(gid, 0, a); memory.queued(gid, 1, b)
        self.report(a, 'start', duration=4)
        self.report(a, 'end', played=4, duration=4, audible=True)
        self.audio.acquire_speech('recap')
        self.now += 90
        self.audio.release_speech('recap')
        memory.receipts(self.audio.status())
        self.assertEqual(memory.groups[gid]['lines'][1]['state'], 'cancelled')
        self.assertIsNone(memory.unfinished())

    def test_hold_extension_is_capped_across_repeated_claims(self):
        c = self.push('operator')
        self.audio.acquire_speech('one')
        self.now += 90
        self.audio.release_speech('one')
        self.audio.acquire_speech('two')
        self.now += 100
        self.audio.release_speech('two')
        self.assertEqual(c['hold_extension'], 120)
        self.assertIn(c['id'], self.audio.skipped)


if __name__ == '__main__':
    unittest.main()
