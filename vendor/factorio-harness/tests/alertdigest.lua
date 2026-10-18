-- alerts_digest (batch26 B1, Luna: repeated attack and group alerts flooded status): one line per surface and place,
-- each incident once, since a tick or the agent's last read; status's count of places with news.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
game={tick=100000}
local st={}
st.damage={['nauvis:2,3']={id=7,at={x=70,y=100},surface='nauvis',first=99000,last=99800,hits=12,kinds={['big-spitter']=3},entities={['gun-turret']=8,['stone-wall']=4}},
  ['nauvis:2,4']={id=8,at={x=75,y=110},surface='nauvis',first=99500,last=99900,hits=2,kinds={['big-biter']=1},entities={['gun-turret']=2}},
  ['vulcanus:0,0']={id=5,at={x=5,y=5},surface='vulcanus',first=50000,last=50100,hits=1,kinds={},entities={pipe=1}}}
st.losses={{id=3,surface='nauvis',box={68,98,72,102},first=99700,last=99750,names={['gun-turret']=1},total=1}}
st.attack_groups={{tick=99600,size=8,kinds='6 big-spitter, 2 big-biter',position={x=200,y=120},target={x=72,y=104},surface='nauvis'}}
local D=require('alertdigest'){state=function() return st end}
local p={index=1}
eq(D.count(p),1)
local r=D.read(p,{})
eq(r.places,1); eq(r.since,100000-36000); eq(r.next_since,100000)
eq(r.lines[1],'nauvis near (96,96), last 1s ago: attack #7 #8: 14 hits by 3 big-spitter, 1 big-biter on 10 gun-turret, 4 stone-wall; 1 lost (1 gun-turret); a group of 8 (6 big-spitter, 2 big-biter) gathered at (200,120) heading here 6s ago')
-- the mark moved: nothing new
eq(D.count(p),0); eq(D.read(p,{}).places,0)
-- a new hit: only that place
game.tick=100600; st.damage['nauvis:2,3'].last=100500
eq(D.count(p),1); r=D.read(p,{since=100000}); eq(r.places,1)
-- since given: the mark stays
eq(D.count(p),1)
r=D.read(p,{since=0,surface='vulcanus'}); eq(r.places,1); eq(r.rows[1].surface,'vulcanus')
fails(function() D.read(p,{since=-1}) end,'since: a game tick')
print('alertdigest: ok')
