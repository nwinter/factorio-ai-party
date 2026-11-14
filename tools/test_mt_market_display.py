"""Display contract and privacy tests; no server, provider or broadcast."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent / 'mt'))
import public_race as race
from public_feed import project_feed
import public_stream as stream
import team_views
from test_mt_public import FakeOBS


class MarketDisplayTests(unittest.TestCase):
    def setUp(self):
        # (mt301) equal race standings: money must not break the tie
        self.teams = [race.project(t, {'now': 100, 'tick': 6000, 'research': {'done_count': 1}, 'space': {'rockets': 0}},
                                  [{'name': t + '1'}, {'name': t + '2'}], 100, None,
                                  {'milestones': 2, 'tick': 5000, 'reached': ['automation-science-pack', 'logistic-science-pack']})
                      for t in ('green', 'yellow', 'blue')]
        self.line = dict(kind='market', scope='market', system=True, agent='Trading Post', team='green',
                         to=['yellow'], source_seq=1, seq=10, tick=5900, text='green sells 20 iron-plate to yellow at 3; arrival in 90 seconds')
        self.marker = dict(id=1, **{'from': 'green'}, to='yellow', item='iron-plate', count=20,
                           x=-200.5, y=140, surface='nauvis', state='in_transit', arrival_tick=11300)
        self.price = dict(a='green', b='yellow', item='iron-plate', price=3, count=20, tick=5900, prints=1, thin=True)

    def feed(self, raw):
        return race.broadcast(project_feed(raw, self.teams), self.teams, 100)

    def test_system_facts_keep_global_order_and_pair_local_ids(self):
        lines = self.feed([dict(self.line, seq=11, team='blue'), self.line, self.line])
        self.assertEqual([v['id'] for v in lines], ['f:10', 'f:11'])
        self.assertEqual([v['source_seq'] for v in lines], [1, 1])
        r = race.Race()
        self.assertEqual(len(r.update(self.teams, 100, lines=lines)['feed']), 2)
        self.assertEqual(len(r.update(self.teams, 101, lines=lines)['feed']), 2)
        self.assertTrue(all(v['system'] and not v['reply'] for v in lines))

    def test_system_sender_cannot_bypass_scopes_or_privacy(self):
        bad = [dict(self.line, **v) for v in [dict(system=False), dict(agent='green1'), dict(scope='team-private'),
            dict(to=['green']), dict(to=['hidden']), dict(source_seq=True), dict(viewer=True), dict(source='site'),
            dict(text='multi-team /Users/private/token'), dict(kind='tell', to=['green2']), dict(seq=True)]]
        self.assertEqual(self.feed(bad), [])
        self.assertEqual(race.team_chat('green', [self.line], {'green1', 'green2'}), [])
        self.assertEqual(race.project_viewers([self.line], 100, {'green', 'yellow'}), [])
        ordinary = dict(self.line, kind='say', scope='team-private', agent='green1', to=[])
        self.assertEqual(self.feed([ordinary]), [])

    def test_market_event_recipients_and_legacy_fill(self):
        events = [self.line, dict(self.line, seq=11, event='embargo'),
                  dict(self.line, seq=12, event='coinage', to={}), dict(self.line, seq=13, event='raid', to=[])]
        lines = self.feed(events)
        self.assertEqual([v['event'] for v in lines], ['fill', 'embargo', 'coinage', 'raid'])
        self.assertEqual([v.get('to_team') for v in lines], ['yellow', 'yellow', None, None])
        self.assertEqual(len(race.Race().update(self.teams, 100, lines=lines)['feed']), 4)
        bad = [dict(self.line, event='wealth'), dict(self.line, event='coinage'), dict(self.line, event='raid'),
               dict(self.line, event='fill', to=[]), dict(self.line, event='embargo', to=[]), dict(self.line, event=None)]
        self.assertEqual(self.feed(bad), [])

    def test_marker_price_allowlist_no_wealth_and_no_pair_collisions(self):
        raw = dict(tick=6000, markers=[self.marker, dict(self.marker, **{'from': 'yellow'}, to='green'),
                                     dict(self.marker, **{'from': 'blue'})],
                   last_prices=[dict(self.price, wallet=10000, path='/Users/private')], teams={'wallet': 10000}, audit='PRIVATE')
        out = race.project_market(raw, self.teams)
        self.assertEqual(len(out['markers']), 3)
        self.assertEqual(out['last_prices'], [self.price])
        self.assertNotIn('wallet', json.dumps(out)); self.assertNotIn('PRIVATE', json.dumps(out))
        self.assertEqual(race.project_market(dict(raw, tick=4000), self.teams), {'markers': [], 'last_prices': []})
        self.assertEqual(race.project_market(None, self.teams), {'markers': [], 'last_prices': []})
        result = race.Race().update(copy.deepcopy(self.teams), 100)
        self.assertTrue(all(t['rank'] == 1 for t in result['teams']))

    def test_malformed_values_and_unknown_prototypes_are_rejected(self):
        markers = [dict(self.marker, **v) for v in [dict(x=float('nan')), dict(y=float('inf')), dict(count=-2),
            dict(id=True), dict(item='/Users/private'), dict(surface='private-platform-name'), dict(to='hidden'),
            dict(state='delivered'), dict(count=1.5), dict(x=1e20)]]
        prices = [dict(self.price, **v) for v in [dict(price=-1), dict(prints=True), dict(tick=7000),
            dict(item='multi-team'), dict(a='hidden'), dict(thin='yes')]]
        out = race.project_market(dict(tick=6000, markers=markers, last_prices=prices), self.teams)
        self.assertEqual(out, dict(tick=6000, markers=[], last_prices=[]))
        self.assertEqual(race.project_market(dict(tick=6000, markers=[dict(self.marker, item='mt-coin')]), self.teams)['markers'][0]['item'], 'coin')

    def test_coinage_wallets_are_bounded_and_do_not_change_ranking(self):
        raw=dict(tick=6000,wallets={'green':{'coinage':True,'wallet':10000,'reserved':3000,'orders':'PRIVATE'},
            'yellow':{'coinage':False,'wallet':20000,'reserved':0},'hidden':{'coinage':True,'wallet':1,'reserved':0}},audit='PRIVATE')
        out=race.project_market(raw,self.teams)
        self.assertEqual(out['wallets'],{'green':{'wallet':10000,'reserved':3000}})
        self.assertNotIn('PRIVATE',json.dumps(out));self.assertNotIn('yellow',out['wallets'])
        for bad in (-1,True,float('nan'),1.5,1e20):
            raw['wallets']['green']['wallet']=bad
            self.assertNotIn('wallets',race.project_market(raw,self.teams))
        raw['wallets']['green'].update(wallet=10,reserved=11)
        self.assertNotIn('wallets',race.project_market(raw,self.teams))
        raw['wallets']['green'].update(wallet=0,reserved=0)
        self.assertEqual(race.project_market(raw,self.teams)['wallets']['green']['wallet'],0)
        self.assertNotIn('wallets',race.project_market(dict(raw,tick=1),self.teams))
        teams=copy.deepcopy(self.teams);teams[0]['wallet']=100000
        self.assertEqual([t['rank'] for t in race.Race().update(teams,100)['teams']],[1,1,1])

    def test_last_print_count_determines_thin_label(self):
        out = race.project_market(dict(tick=6000, last_prices=[dict(self.price, prints=3)]), self.teams)
        self.assertFalse(out['last_prices'][0]['thin'])

    def test_freight_loss_and_platform_markers_need_no_eta(self):
        line=dict(self.line,event='shipment_loss',text='Shipment lost: buyer side; 400 coin paid to seller; cargo in a wreck.')
        lines=self.feed([line])
        self.assertEqual(len(lines),1)
        self.assertEqual(lines[0]['event'],'shipment_loss')
        self.assertEqual(len(race.Race().update(self.teams,100,lines=lines)['feed']),1)
        marker=dict(self.marker,surface='platform');marker.pop('arrival_tick')
        out=race.project_market(dict(tick=6000,markers=[marker],measurements=[{'PRIVATE':True}]),self.teams)
        self.assertEqual(out['markers'],[marker]);self.assertNotIn('PRIVATE',json.dumps(out))
        self.assertNotIn('arrival_tick',out['markers'][0])
        self.assertEqual(self.feed([dict(line,to=['hidden'])]),[])

    def test_operator_collector_discards_private_market_state(self):
        class Reader:
            def op(self, action, args=None, team=None):
                if action == 'mt_feed': return {'tick': 6000, 'lines': []}
                if action == 'mt_market': return {'markers': [], 'last_prices': [], 'teams': {'wallet': 10000}, 'audit': 'PRIVATE'}
                return {}
            def bots(self): return []
        with tempfile.TemporaryDirectory() as d:
            Path(d, 'teams.tsv').write_text('')
            view = team_views.collect(Reader(), d)
            self.assertEqual(view['market'], {'tick': 6000, 'markers': [], 'last_prices': []})
            self.assertNotIn('PRIVATE', json.dumps(view)); self.assertNotIn('wallet', json.dumps(view))
            with mock.patch.object(Reader, 'op', side_effect=RuntimeError('unsupported action')):
                self.assertEqual(team_views.collect(Reader(), d)['market'], {})

    def test_collector_uses_authoritative_coinage_for_selected_teams(self):
        class Reader:
            def op(self,action,args=None,team=None):
                if action=='mt_feed':return {'tick':6000,'lines':[]}
                if action=='mt_market':return {'teams':{
                    'green':{'rung':'coinage','wallet':10000,'reserved':3000,'orders':'PRIVATE'},
                    'yellow':{'rung':'swap','wallet':99999,'reserved':0},
                    'blue':{'rung':'coinage','wallet':88888,'reserved':0}},'audit':'PRIVATE'}
                return {}
            def bots(self):return []
        with tempfile.TemporaryDirectory() as d:
            Path(d,'teams.tsv').write_text('green\tg1\tagy\tagy\tflash\thigh\tGemini Flash\tfh\nyellow\ty1\tgrok\tgrok\tgrok\tlow\tGrok 4.7\tfh\n')
            Path(d,'green').mkdir();Path(d,'yellow').mkdir()
            view=team_views.collect(Reader(),d)
            self.assertEqual(view['market']['wallets'],{'green':{'coinage':True,'wallet':10000,'reserved':3000}})
            self.assertNotIn('PRIVATE',json.dumps(view))
            self.assertEqual(race.project_market(view['market'],self.teams)['wallets'],{'green':{'wallet':10000,'reserved':3000}})

    def test_repeated_capture_setup_releases_old_window_hook(self):
        obs = FakeOBS(); obs.inputs = [{'inputName': 'mt camera'}]
        with mock.patch.object(stream.time, 'sleep'):
            stream.setup_obs(obs, 'http://127.0.0.1:8790/', {})
        settings = [b['inputSettings'] for n, b in obs.calls if n == 'SetInputSettings' and b['inputName'] == 'mt camera']
        self.assertEqual(settings[0], {'window': ''})
        self.assertIn('factorio-mtcam.exe', settings[1]['window'])
        self.assertNotIn('StartStream', [n for n, _ in obs.calls])


if __name__ == '__main__': unittest.main()
