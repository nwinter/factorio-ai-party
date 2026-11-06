#!/usr/bin/env python3
"""Anchored recap selection, actual preparation metadata and narration receipt lifetime."""
import copy
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import shift_recap as R
import shift_recap_detail as D
import shift_recap_visuals as V
from test_recap_capture import manifest, state
from test_shift_recap import RecapTest, T0


def detail_manifest():
    m = manifest()
    m['lines'] = [dict(m['lines'][0], text='Asterion front-right turret at (24, -12).')]
    m['stills'] = [
        {'asset': 'a'*24+'.png', 't': 1000, 'platform': 'Asterion',
         'view': {'box': [-10,-10,20,20], 'px': [1280,720], 'kind': 'world'}},
        {'asset': 'b'*24+'.png', 't': 990, 'platform': 'Asterion',
         'view': {'box': [-30,-16.875,60,33.75], 'px': [1280,720], 'kind': 'world'}},
        {'asset': 'c'*24+'.png', 't': 1010, 'platform': 'Asterion',
         'view': {'box': [-30,-16.875,60,33.75], 'px': [1280,720], 'kind': 'world'}}]
    return m


class DetailTest(unittest.TestCase):
    def test_target_beats_nearer_ship_centre_and_preserves_crop(self):
        m = V.bind(detail_manifest()); v = m['visuals']['ship']; media = v['media']
        self.assertEqual(media['asset'], 'b'*24+'.png')
        self.assertEqual(media['detail']['timing'], 'before record')
        self.assertRegex(media['recorded_time'], r'^\d{4}-\d{2}-\d{2} ')
        a = media['detail']; x,y,w,h = a['crop']; px,py = a['point']; rx,ry = a['radius']
        self.assertTrue(x <= px-rx < px+rx <= x+w)
        self.assertTrue(y <= py-ry < py+ry <= y+h)
        self.assertGreater(x, 640, 'crop must move to the front-right target')
        for elapsed in (0, 2, 120, 500):
            self.assertEqual(V.public(m, m['lines'][0], 'recap', elapsed=elapsed)['media']['detail'], a)

    def test_before_after_and_missing_detail_fallback(self):
        for phase, asset in [('before','b'), ('after','c')]:
            m = detail_manifest(); m['lines'][0]['text'] += ' '+phase+' the record.'
            self.assertEqual(V.bind(m)['visuals']['ship']['media']['asset'], asset*24+'.png')
        for change in ('outside', 'unknown', 'map', 'old', 'edge', 'surface', 'zoom'):
            m = detail_manifest(); m['stills'] = m['stills'][1:2]; row=m['stills'][0]
            if change == 'outside': row['view']['box']=[-10,-10,20,20]
            if change == 'unknown': row.pop('view')
            if change == 'map': row['view']['kind']='map'
            if change == 'old': row['t']=600; m['evidence']['start']=500
            if change == 'edge': m['lines'][0]['text']='Asterion turret at (29,-12).'
            if change == 'surface': row.update(surface='platform-16'); row['view']['surface']='nauvis'
            if change == 'zoom': row['view']['box']=[-3000,-3000,6000,6000]
            v=V.bind(m)['visuals']['ship']
            self.assertNotIn('detail',v['media'],change)
            self.assertIn('FALLBACK',v['fallback'],change)
        m['stills']=[]
        public=V.public(V.bind(m),m['lines'][0],'recap')
        self.assertIsNone(public['media']); self.assertIn('OVERVIEW FALLBACK',public['fallback'])

    def test_target_record_time_wins_over_later_background(self):
        m=detail_manifest()
        m['evidence']['rows']=[{'id':'target','t':1000,'text':'Asterion front-right turret at (24,-12)'},
                               {'id':'background','t':1080,'text':'platform Asterion arrived at Nauvis'}]
        m['lines'][0]['sources']=['target','background']
        v=V.bind(m)['visuals']['ship']
        self.assertEqual(v['binding']['record_t'],1000)
        self.assertEqual(v['media']['detail']['delta_seconds'],-10)
        m['lines'][0]['text']+=' after the record.'
        m['stills']=m['stills'][1:2]
        self.assertIn('FALLBACK',V.bind(m)['visuals']['ship']['fallback'])

    def test_cited_coordinates_and_ambiguous_positions(self):
        line={'text':'Asterion front-right turret'}
        self.assertEqual(D.target(line,[{'text':'front-right turret at (24,-12)'}])['position'],[24,-12])
        self.assertIsNone(D.target(line,[{'text':'front-right turret at (24,-12) or (2,3)'}])['position'])
        self.assertIsNone(D.target({'text':'Asterion has arrived'},[]))

    def test_capture_metadata_survives_preparation_and_legacy_refresh(self):
        s=state(); shot=s['camera_states']['main']['on_air']
        shot.update(position={'x':0,'y':0},game_zoom=1)
        frame={'position':{'x':0,'y':0},'zoom':1,'surface':'platform-16'}
        s['cuts']['on_air']['frames']['main']['frame']=frame
        receipt={'on_air':shot,'frame':s['cuts']['on_air']['frames']['main']}
        view=D.capture_view(receipt,[1280,720]); self.assertEqual(view['box'],[-30,-16.875,60,33.75])
        for field,value in [('follow','rook'),('move',{'segments':[]}),('glide',1),('map',True)]:
            bad=copy.deepcopy(receipt); bad['on_air'][field]=value
            self.assertIsNone(D.capture_view(bad,[1280,720]))
        with tempfile.TemporaryDirectory() as temp:
            run=Path(temp); out=run/'out'; (run/'frame.png').write_bytes(b'\x89PNG\r\n\x1a\nfixture')
            row={'path':'frame.png','t':990,'platform':'Asterion','surface':'platform-16','px':[1280,720],
                 'receipt':receipt,'after_receipt':receipt,'capture_finished':991}
            R.save_json(run/'recap-media.json',[row])
            prepared=R.stills(run,1100,out)[0]
            for key in ('px','receipt','after_receipt','capture_finished'): self.assertEqual(prepared[key],row[key])
            self.assertEqual(V.media_record(prepared)['view']['box'],view['box'])


class DetailLifetimeTest(RecapTest):
    # Reuse the real prepared-audio fixture; inherited tests are already covered elsewhere.
    def test_detail_held_through_delayed_audio_and_manifest_refresh(self):
        m=self.prepare(); first=m['lines'][0]
        first.update(title='Asterion turret',text='Asterion turret at (24,-12).')
        # Text changes invalidate prepared audio; keep original validated speech and put anchor in title.
        original=self.prepare()['lines'][0]
        first.update(text=original['text'], title='Asterion front-right turret at (24,-12)')
        first['sources']=[]
        stamp=m['through']
        m['stills']=[dict(detail_manifest()['stills'][1],t=stamp)]
        R.save_json(self.out/'manifest.json',m)
        from shift_recap_air import Player
        audio=self.audio(); p=Player(self.run,self.old,audio); started=p.step(T0)
        self.assertIsNotNone(started['media']['detail'])
        cid=p.current['clip']; audio.played(dict(id=cid,state='start',session='capture',duration=4),now=T0+2)
        m['stills']=[]; R.save_json(self.out/'manifest.json',m)
        for now in (T0+40,T0+150): self.assertEqual(p.step(now)['media'],started['media'])
        audio.played(dict(id=cid,state='end',session='capture',duration=4,played=4,audible=True),now=T0+151)
        self.assertNotEqual(p.step(T0+152)['id'],started['id'])


if __name__ == '__main__':
    # Only our additional lifetime test; don't duplicate the base suite at the operator gate.
    suite=unittest.defaultTestLoader.loadTestsFromTestCase(DetailTest)
    suite.addTest(DetailLifetimeTest('test_detail_held_through_delayed_audio_and_manifest_refresh'))
    result=unittest.TextTestRunner().run(suite)
    sys.exit(not result.wasSuccessful())
