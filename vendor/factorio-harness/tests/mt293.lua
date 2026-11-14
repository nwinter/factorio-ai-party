-- Explicit diplomacy is contact-gated, pair-scoped, authenticated and rate-limited.
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,s) local ok,e=pcall(fn);assert(not ok and tostring(e):find(s,1,true),tostring(e)) end
game={tick=100}
local state={mt={teams={red={},blue={},green={}},first={}}}
local current,who='red','red1'
local facts={red={},blue={},green={}}
local P=dofile('mod/agent-harness_0.1.0/pacts.lua'){
 state=function() return state end,team_now=function() return current end,who=function() return who end,
 fact=function(t,text,wake) facts[t][#facts[t]+1]={text=text,wake=wake} end}
local H=P.handlers
local actions={};P.describe_into(actions);eq(actions.diplomacy_send,nil)
fails(function() H.diplomacy_send(nil,{to='blue',text='hello',from='green'}) end,'no contact')
state.mt.first['chart red>blue']=1
P.describe_into(actions);assert(actions.diplomacy and actions.diplomacy_send)
fails(function() H.diplomacy_send(nil,{to='green',text='hello'}) end,'no contact with green')
fails(function() H.diplomacy_send(nil,{to='blue',text='hello',from='green'}) end,'unknown argument from')
fails(function() H.pact_propose(nil,{with='blue',bogus=1}) end,'unknown argument bogus')
fails(function() H.diplomacy_send(nil,{to='blue',text=' '}) end,'not blank')
fails(function() H.diplomacy_send(nil,{to='blue',text=string.rep('x',501)}) end,'500 bytes')
local sent=H.diplomacy_send(nil,{to='blue',text=' Shall we end pact 10? '})
eq(sent.message.agent,'red1');eq(sent.message.from_team,'red');eq(sent.message.seq,1)
eq(sent.message.text,'Shall we end pact 10?')
eq(#facts.red,1);eq(#facts.blue,1);eq(#facts.green,0);eq(facts.blue[1].wake,true)
current,who='blue','blue2'
local read=H.diplomacy(nil,{with='red'});eq(#read.messages,1);eq(read.last_seq,1)
H.diplomacy_send(nil,{to='red',text='Agreed. End only pact 10; observe the notice.'})
current,who='red','red2'
read=H.diplomacy(nil,{with='blue',since=1});eq(#read.messages,1);eq(read.messages[1].agent,'blue2')
eq(#H.diplomacy(nil,{with='blue',since=2}).messages,0)
-- Green has contact too, but sees no Red/Blue traffic or cursor.
state.mt.first['chart green>red']=2;state.mt.first['chart green>blue']=3
current,who='green','green1'
eq(#H.diplomacy(nil,{with='red'}).messages,0);eq(H.diplomacy(nil,{with='red'}).last_seq,0)
eq(#H.diplomacy(nil,{with='blue'}).messages,0)
H.diplomacy_send(nil,{to='red',text='Separate conversation.'})
eq(#facts.blue,2);eq(#facts.green,1)
current,who='red','red1'
eq(#H.diplomacy(nil,{with='blue'}).messages,2)
for i=1,5 do H.diplomacy_send(nil,{to='blue',text='bounded '..i}) end
fails(function() H.diplomacy_send(nil,{to='green',text='over the team-wide limit'}) end,'rate limit')
-- A teammate shares the rate limit; a receiver can still answer.
who='red2';fails(function() H.diplomacy_send(nil,{to='blue',text='also limited'}) end,'rate limit')
current,who='blue','blue1';H.diplomacy_send(nil,{to='red',text='received'})
current,who='red','red1';game.tick=3700
H.diplomacy_send(nil,{to='blue',text='after the window'})
-- History and responses are bounded; cursors continue across retention.
for i=1,105 do game.tick=game.tick+3600;H.diplomacy_send(nil,{to='blue',text='retained '..i}) end
read=H.diplomacy(nil,{with='blue',limit=50});eq(#read.messages,50);assert(read.last_seq>100)
eq(#H.diplomacy(nil,{with='blue',limit=1}).messages,1)
fails(function() H.diplomacy(nil,{with='blue',limit=51}) end,'limit')
eq(#P.operator.mt_diplomacy({}).messages,100)
print('mt293 contact, pair privacy, sender identity, rate and retention: ok')
