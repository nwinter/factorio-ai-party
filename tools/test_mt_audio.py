"""Caster input boundaries, freshness/pace and scene-local audio; no provider or game."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest import mock
import urllib.error
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent / 'mt'))
import public_audio
from public_audio import candidates, Picker, PublicAudio
from public_overlay import PublicOverlay
from obs_audio import setup_audio
from tools.test_mt_public import FakeOBS


def state(now=100):
    return dict(now=now, teams=[dict(team=t, stale=False, agents=[dict(name=t+'1', display_name='Vesper')])
                               for t in ('green', 'yellow')], events=[], feed=[],
                viewers=[dict(text='DO NOT SPEAK THIS VIEWER LINE', source='site')])


class AudioTests(unittest.TestCase):
    def test_only_public_roster_radio_and_events(self):
        s=state()
        radio=dict(id='f:1', team='green', kind='tell', name='green1', text='I will build power while you supply the labs.', at=100)
        s['feed']=[radio, dict(radio,id='f:2',name='outsider'), dict(radio,id='f:3',source='site'),
                   dict(radio,id='f:4',kind='viewer'), dict(radio,id='f:5',text='/Users/private/token'),
                   dict(radio,id='f:6',text='multi-team secret'), dict(radio,id='f:7',reply=True)]
        s['events']=[dict(id='contact1',team='green',other='yellow',kind='contact',text='First contact with Yellow',tick=6000,at=100)]
        c=candidates(s,100)
        self.assertEqual({x['id'] for x in c},{'feed:f:1','event:contact1'})
        self.assertIn('Vesper says',c[1]['text'])
        self.assertNotIn('VIEWER',json.dumps(c))
        s['teams'][0]['stale']=True
        self.assertEqual(candidates(s,100),[])

    def test_base_model_in_radio_and_fight_without_private_values(self):
        s=state();s['teams'][0]['agents'][0].update(model='Gemini 3.8 Flash',verb='fight',activity='acting')
        s['feed']=[dict(id='f:1',team='green',kind='tell',name='green1',text='Please bring copper for circuits.',at=100)]
        lines=candidates(s,100)
        self.assertTrue(all('Vesper · Gemini 3.8 Flash' in c['text'] for c in lines))
        s['teams'][0]['agents'][0]['model']='/Users/private/token'
        self.assertNotIn('/Users',json.dumps(candidates(s,100)))

    def test_market_authority_and_four_moments(self):
        s=state()
        for i,event in enumerate(('fill','embargo','coinage','raid')):
            s['feed'].append(dict(id=str(i), team='green',kind='market',name='Trading Post',system=True,
                                  source_seq=i+1,event=event,to_team='yellow' if i<2 else None,
                                  text='A trade fact appeared.',at=100))
        self.assertEqual(len(candidates(s,100)),4)
        for m in s['feed']:m['system']=False
        self.assertEqual(candidates(s,100),[])

    def test_milestones_fights_and_contact_pair_dedup(self):
        s=state();s['teams'][0]['agents'][0].update(verb='fight',activity='acting')
        for i,kind in enumerate(('contact','pact','rocket','death','platform_lost','research','build')):
            s['events'].append(dict(id=str(i),team='green',other='yellow',kind=kind,text='First thing happened',at=100,tick=6000))
        s['events'].append(dict(s['events'][0],id='mirror',team='yellow',other='green'))
        self.assertEqual(len(candidates(s,100)),8)
        self.assertEqual(candidates(s,121),[])
        s['now']=150;s['teams'][0]['agents'][0]['verb']=None
        self.assertEqual(candidates(s,150),[])

    def test_picker_no_startup_recap_bounded_radio_and_expiry(self):
        p=Picker();s=state()
        s['events']=[dict(id='old',team='green',kind='rocket',text='Rocket launched',at=100)]
        p.observe(s,100);self.assertIsNone(p.choose(100))
        radio=dict(id='new',team='green',kind='tell',name='green1',text='I will build power while you supply the labs.',at=101)
        s.update(now=101,feed=[radio]);p.observe(s,101)
        c=p.choose(101);self.assertEqual(c['kind'],'radio');p.sent(c,101,5)
        s['feed']=[dict(radio,id='next',text='Can you bring copper for the circuits?',at=110)];s['now']=110
        p.observe(s,110);self.assertIsNone(p.choose(125))
        s.update(now=151,feed=[]);p.observe(s,151);self.assertIsNone(p.choose(151))

    def test_worker_reads_snapshot_before_freshness_clock_and_pushes_exact_text(self):
        # A freshly computed snapshot is fractionally later than a clock read before it.
        # The real OBS fixture exposed that ordering: every snapshot looked future-dated.
        import itertools
        clock=iter(i/1000000 for i in itertools.count(100000000))
        calls=[]
        def snapshot():
            s=state(public_audio.time.time());calls.append(s['now'])
            if len(calls)>1:s['events']=[dict(id='new',team='green',kind='rocket',text='Rocket launched',at=s['now'])]
            return s
        with tempfile.TemporaryDirectory() as d, mock.patch.object(public_audio.time,'time',side_effect=lambda:next(clock)):
            a=PublicAudio(snapshot,d);a.hub.listeners=1
            a.stop=mock.Mock();a.stop.wait.side_effect=[False,False,True];a.stop.is_set.return_value=False
            tts=mock.Mock(backend='eleven-fast');tts.speak.return_value=(b'voice','audio/mpeg',2,1);tts.last_here.return_value={}
            with mock.patch.object(public_audio.voices,'TTS',return_value=tts):a.run()
            self.assertFalse(a.picker.initial)
            self.assertEqual(len(a.hub.order),1)
            self.assertEqual(tts.speak.call_args.kwargs,dict(caster='pbp',plain=True))
            self.assertEqual(tts.speak.call_args.args[0],'Green. Rocket launched.')

    def test_audio_routes_accept_receipts_not_speech_or_game_commands(self):
        with tempfile.TemporaryDirectory() as d:
            op=Path(d);td=op/'tree/runs/test/green';td.mkdir(parents=True)
            (td/'team.tsv').write_text('a\tagy\troute\tmodel\thigh\tFlash\tagy\n')
            (op/'streams.txt').write_text('green http://127.0.0.1:1/\n')
            service=PublicOverlay(op,op/'tree','test',port=0,camera=False)
            threading.Thread(target=service.http.serve_forever,daemon=True).start()
            url=f'http://127.0.0.1:{service.http.server_port}'
            try:
                clip=service.audio.hub.push(dict(channel='caster',text='Rocket launched',duration=2),b'fixture','audio/mpeg')
                with urllib.request.urlopen(url+clip['url']) as r:self.assertEqual(r.read(),b'fixture')
                for path in ('/audio','/say','/viewer_say','/camera'):
                    with self.assertRaises(urllib.error.HTTPError) as e:
                        urllib.request.urlopen(urllib.request.Request(url+path,data=b'{}'))
                    self.assertEqual(e.exception.code,404);e.exception.close()
                req=urllib.request.Request(url+'/audio/played',data=json.dumps(dict(id=clip['id'],state='start',capture=True,page='main')).encode())
                with urllib.request.urlopen(req) as r:self.assertEqual(r.status,200)
                self.assertEqual(len(service.audio.hub.status()['playing']),1)
            finally:service.close()

    def test_failed_cloud_voice_falls_back_to_normalized_local_voice(self):
        import itertools
        clock=itertools.count(100,2);calls=[]
        def snapshot():
            s=state(public_audio.time.time());calls.append(1)
            if len(calls)>1:s['events']=[dict(id='new',team='green',kind='rocket',text='Rocket launched',at=s['now'])]
            return s
        with tempfile.TemporaryDirectory() as d, mock.patch.object(public_audio.time,'time',side_effect=lambda:next(clock)):
            a=PublicAudio(snapshot,d);a.hub.listeners=1
            a.stop=mock.Mock();a.stop.wait.side_effect=[False,False,False,True];a.stop.is_set.return_value=False
            cloud=mock.Mock(backend='eleven-fast');cloud.speak.side_effect=RuntimeError('provider unavailable')
            local=mock.Mock(backend='say');local.speak.return_value=(b'local','audio/mpeg',2,1);local.last_here.return_value={'provider':'say'}
            with mock.patch.object(public_audio.voices,'TTS',side_effect=[cloud,local]), mock.patch.object(public_audio.voices,'normalize',return_value=(b'normalized','audio/mpeg')) as normalize:
                a.run()
            self.assertEqual(a.backend,'say');self.assertEqual(len(a.hub.order),1)
            normalize.assert_called_once_with(b'local','audio/mpeg',-18.0)
            self.assertEqual(json.loads((Path(d)/'caster.jsonl').read_text().splitlines()[0])['fallback'],'say')

    def test_mix_only_owns_test_scene_sources_and_ducks_under_caster(self):
        obs=FakeOBS();result=setup_audio(obs)
        self.assertFalse(result['game_audio']);self.assertFalse(result['viewer_speech'])
        for name,body in obs.calls:
            self.assertNotIn(name,('StartStream','StartRecord'))
            for key in ('inputName','sourceName','sidechain_source'):
                if key in body:self.assertTrue(body[key].startswith('mt '),body)
        sources=[b for n,b in obs.calls if n=='CreateInput']
        self.assertEqual([s['inputKind'] for s in sources],['ffmpeg_source'])
        filters=[b for n,b in obs.calls if n=='CreateSourceFilter']
        duck=next(f for f in filters if f['filterKind']=='compressor_filter')
        self.assertEqual(duck['filterSettings']['sidechain_source'],'mt overlay')
        self.assertEqual(duck['filterSettings']['ratio'],2.5)


if __name__=='__main__':unittest.main()
