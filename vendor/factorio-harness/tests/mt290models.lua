-- Trusted models: own teammates first, contacted rivals only.
local state={mt={teams={green={},yellow={},blue={}},first={}}}
local bots={{name='g1',index=1,force='green'},{name='g2',index=2,force='green'},{name='grok',index=3,force='yellow'},{name='muse',index=4,force='blue'}}
local current='green';game={tick=100,players={},get_surface=function() return nil end,get_player=function() return nil end}
local P=dofile('mod/agent-harness_0.1.0/profiles.lua'){state=function() return state end,bots=function() return bots end,is_bot=function() return true end,team_now=function() return current end,team_of=function(i) return bots[i].force end,active=function() return false end,director=function() return false end}
local function fail(fn) assert(not pcall(fn),'expected refusal') end
P.operator.mt_roster{agents={{name='g1',model='Grok 4.7'},{name='g2',model='Gemini 3.8 Flash'},{name='grok',model='Grok 4.7'},{name='muse',model='Muse Spark'}}}
P.handlers.profile({index=1,name='g1'},{display_name='Vector'});P.handlers.profile({index=3,name='grok'},{display_name='Hearth'})
local own=P.handlers.profiles().profiles;assert(#own==2 and own[1].model=='Grok 4.7' and own[2].model=='Gemini 3.8 Flash')
assert(P.handlers.profile({index=1,name='g1'},{}).model=='Grok 4.7')
fail(function() P.handlers.profile({index=1,name='g1'},{model='Fake'}) end)
fail(function() P.operator.mt_roster{agents={{name='g1',model='New Model'},{name='absent',model='Fake'}}} end)
assert(P.model('g1')=='Grok 4.7','failed update must be atomic')
fail(function() P.operator.mt_roster{agents={{name='g1',model='/Users/private'}}} end)
local D=dofile('mod/agent-harness_0.1.0/discovery.lua'){state=function() return state end,bots=function() return bots end,profile=P.get}
assert(#D.roster('green','green')==2 and #D.roster('green','yellow')==0 and #D.roster('green','blue')==0)
assert(D.project({profiles=own},'green').profiles[1].model=='Grok 4.7','own model may match an unknown rival ID')
assert(D.project({name='grok',model='Grok 4.7'},'green')==nil)
assert(D.project({name='g1',model='muse'},'green').model==nil,'untrusted model has no exemption')
local T=dofile('mod/agent-harness_0.1.0/pacts.lua'){state=function() return state end,team_now=function() return current end,who=function() return 'g1' end,roster=D.roster,fact=function() end}
fail(function() T.handlers.diplomacy(nil,{with='yellow'}) end);fail(function() T.handlers.pacts(nil,{}) end)
state.mt.first['chart green>yellow']=100
assert(#D.roster('green','yellow')==1 and #D.roster('yellow','green')==2 and #D.roster('blue','green')==0)
local peers=T.handlers.pacts(nil,{}).counterparties;assert(#peers==1 and peers[1].team=='yellow' and peers[1].agents[1].model=='Grok 4.7')
local sent=T.handlers.diplomacy_send(nil,{to='yellow',text='Trade copper for iron.'});assert(sent.message.identity.display_name=='Vector' and sent.message.identity.model=='Grok 4.7')
local read=T.handlers.diplomacy(nil,{with='yellow'});assert(read.agents[1].display_name=='Hearth' and #read.agents==1)
local v=T.view{a='green',b='yellow',id=1,status='active',terms={},proposed_by={tick=1}};assert(#v.parties==2 and #v.parties[1].agents==2 and v.parties[2].agents[1].model=='Grok 4.7')
for _,row in ipairs(D.roster('green','yellow')) do assert(not row.position and not row.last_said and not row.active) end
state.mt=nil;assert(P.handlers.profile({index=1,name='g1'},{}).model==nil)
print('mt290 models: authority, own-team reads, alias collision, pair-only disclosure, ordinary world: ok')
