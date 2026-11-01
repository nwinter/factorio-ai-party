#!/usr/bin/env python3
"""Footage admission, transactional prep, camera fallback and operator-only OBS guard."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parent))
import recap_footage as F
import recap_audio_guard as G
import shift_recap_camera as C
import shift_recap_visuals as V
from test_shift_recap_visuals import fixture


class FootageTest(unittest.TestCase):
    def test_oversized_legacy_video_is_rejected_before_loading(self):
        import shift_recap_media as M
        from shift_recap_air import ShiftRecap
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);(root/'assets').mkdir()
            name='c'*24+'.webm'
            with (root/'assets'/name).open('wb') as f:f.truncate(V.MAX_CLIP_BYTES+1)
            m=fixture();m['stills']=[{'asset':name,'surface':'nauvis','t':165,'duration':12}]
            checked=M.checked(m,root)
            self.assertIn('16 MiB',checked['media_errors'][0]['error'])
            service=ShiftRecap.__new__(ShiftRecap);service.player=None;service.root=root
            self.assertIsNone(service.asset(name))

    def test_clip_preference_interval_and_still_is_never_on_air(self):
        m = fixture()
        clip = {'asset': 'c'*24+'.webm', 'surface':'nauvis', 't':165, 'duration':12}
        m['stills'].append(clip)
        bound = V.bind(m)
        self.assertEqual(V.public(bound,m['lines'][1],'recap')['media']['kind'],'video')
        for change in ({'duration':0}, {'duration':float('nan')}, {'duration':1000}, {'t':171}, {'t':140}):
            x=copy.deepcopy(m);x['stills'][-1].update(change)
            p=V.public(V.bind(x),x['lines'][1],'recap')
            self.assertIsNone(p['media']);self.assertEqual(p['subject']['name'],'nauvis')

    def test_prep_dry_run_bounds_no_audio_and_failure_preserves_index(self):
        with tempfile.TemporaryDirectory() as d:
            run=Path(d);(run/'stream.json').write_text(json.dumps({'shift':{'start':100,'end':200}}))
            src=run/'source.mkv';src.write_bytes(b'fixture')
            row={'source':str(src),'offset':0,'duration':12,'t':110,'subject':'Lark','subject_type':'platform',
                 'crop':[24,144,1208,864], 'coverage':{'reviewed':True,'start':100,'end':130,
                  'evidence':'verified camera interval','clock_anchor':'explicit UTC recording receipt'}}
            jobs=F.plan({'clips':[row]},run)
            self.assertFalse((run/'recap-clips').exists(),'plan does not create files')
            cmd=jobs[0]['command'];self.assertIn('-an',cmd);self.assertIn('-n',cmd)
            for change in ({'duration':21},{'t':99},{'coverage':{}},{'crop':[0,0,0,1]}):
                with self.assertRaises(ValueError):F.plan({'clips':[dict(row,**change)]},run)
            old='[{"path":"stills/retained.jpg"}]';(run/'recap-media.json').write_text(old)
            def failed(*a,**k):raise subprocess.CalledProcessError(1,a[0])
            with self.assertRaises(subprocess.CalledProcessError):F.apply(jobs,run,execute=failed)
            self.assertEqual((run/'recap-media.json').read_text(),old)
            self.assertEqual(list((run/'recap-clips').glob('*.tmp')),[])
            def execute(cmd,**kw):
                if cmd[0]=='ffprobe':return subprocess.CompletedProcess(cmd,0,stdout=json.dumps({'streams':[{'codec_type':'video'}],'format':{'duration':12}}))
                if cmd[-1].endswith('.tmp'):Path(cmd[-1]).write_bytes(b'clip')
                return subprocess.CompletedProcess(cmd,0)
            F.apply(jobs,run,execute=execute)
            catalog=json.loads((run/'recap-media.json').read_text());self.assertEqual(len(catalog),2)
            F.apply(jobs,run,execute=execute)
            self.assertEqual(len(json.loads((run/'recap-media.json').read_text())),2)

    def test_subject_cues_need_existing_locations_and_end_immediately(self):
        recap={'active':True,'run':'shift1','id':'a','phase':'recap','subject':{'name':'Lark','type':'platform'}}
        snap={'agents':[],'space':{'platforms':[{'name':'Lark','view':{'surface':'platform-7','hub':{'x':2,'y':3}}}]}}
        shot=C.cue(recap,snap,100,.65)
        self.assertEqual(shot['surface'],'platform-7');self.assertIn('shift-recap',shot['id'])
        self.assertIsNone(C.cue(dict(recap,holding=True),snap,100))
        self.assertTrue(C.cue(recap,{},100)['hold_current'])
        recap['subject']={'name':'nauvis','type':'surface'}
        snap['agents']=[{'name':'astra','position':{'x':1,'y':2,'surface':'nauvis'}}]
        self.assertEqual(C.cue(recap,snap,100)['follow'],'astra')
        self.assertIsNone(C.on_air(recap,snap)['live']['subject'],'request is not an on-air receipt')
        snap['cuts']={'connected':True,'on_air':{'frames':{'main':{'client':'main','surface':'nauvis'}},'cameras':{'main':{'pending':False}}}}
        self.assertEqual(C.on_air(recap,snap)['live']['subject'],'nauvis')
        snap['cuts']['on_air']['cameras']['main']['pending']=True
        self.assertIsNone(C.on_air(recap,snap)['live']['subject'])

    def test_real_director_takes_surface_cue_and_releases_it(self):
        from test_onecam import world, agent, snap
        director, sent = world()
        team = [dict(agent('luna',0,0,5),surface='nauvis'),dict(agent('sol',400,0,1),surface='vulcanus')]
        state = snap(team)
        for now in range(1000,1003):director.step(state,now)
        recap={'active':True,'run':'shift1','id':'a','phase':'recap','subject':{'name':'vulcanus','type':'surface'}}
        for now in (1010,1012):director.step(state,now,C.cue(recap,state,now))
        self.assertEqual(director.public(1012)['main']['agents'],['sol'])
        self.assertTrue(any(b.get('follow')=='sol' for b in sent))
        for now in range(1013,1045):director.step(state,now,C.cue(None,state,now))
        self.assertEqual(director.public(1045)['main']['agents'],['luna'])

    def test_unresolved_recap_keeps_camera_past_quiet_tour_and_hold_deadlines(self):
        from test_onecam import world, agent, snap
        director, sent = world()
        state = snap([dict(agent('luna',0,0,5),surface='nauvis')])
        for now in range(1000,1003): director.step(state,now)
        recap={'active':True,'run':'shift1','id':'unknown','phase':'recap'}
        original = director.state[director.onair].copy()
        before = len(sent)
        for now in range(1003,1200): director.step(state,now,C.cue(recap,state,now))
        self.assertEqual(director.state[director.onair], original)
        self.assertEqual(len(sent), before)


class OBSStub:
    def __init__(self):
        self.mutes={'stream overlay':False,'game':False,'clean':False,'already muted':True};self.calls=[];self.fail=False
    def call(self,req,data=None,**kwargs):
        self.calls.append((req,data));name=(data or {}).get('inputName')
        if req=='GetInputList':return {'inputs':[{'inputName':n} for n in self.mutes]}
        if req=='GetSourceActive':return {'videoActive':True}
        if req=='GetInputAudioTracks':return {'inputAudioTracks':{'1':name!='clean','2':name=='clean'}}
        if req=='GetInputMute':return {'inputMuted':self.mutes[name]}
        if req=='SetInputMute':
            if self.fail:raise RuntimeError('stub disconnect')
            self.mutes[name]=data['inputMuted'];return {}
        raise AssertionError(req)


class GuardTest(unittest.TestCase):
    def test_dry_run_apply_restore_and_failure_receipt(self):
        with tempfile.TemporaryDirectory() as d:
            obs=OBSStub();path=Path(d)/'undo.json';guard=G.Guard(obs,path)
            self.assertEqual(guard.plan(),[{'inputName':'game','inputMuted':False}])
            self.assertFalse(path.exists());self.assertFalse(any(r.startswith('Set') for r,_ in obs.calls))
            guard.enter();self.assertTrue(obs.mutes['game']);self.assertFalse(obs.mutes['clean']);self.assertFalse(obs.mutes['stream overlay'])
            with self.assertRaises(ValueError):guard.enter()
            guard.restore();self.assertFalse(obs.mutes['game']);self.assertTrue(obs.mutes['already muted']);self.assertFalse(path.exists())
            obs.fail=True
            with self.assertRaises(RuntimeError):guard.enter()
            self.assertTrue(path.exists(),'partial failure retains undo')
            obs.fail=False;guard.restore()
            self.assertTrue(G.active({'shift_recap':{'active':True}}))
            self.assertFalse(G.active({'shift_recap':{'active':True,'holding':True}}))
            self.assertFalse(G.active({}))


if __name__=='__main__':unittest.main()
