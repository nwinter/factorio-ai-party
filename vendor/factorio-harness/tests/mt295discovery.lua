local state={mt={teams={green={},yellow={},blue={}},first={}}}
local bots={{name='gemini',index=1,force='green'},{name='grok',index=2,force='yellow'},{name='muse',index=3,force='blue'}}
local names={'Forge','Rivet','Nova'}
local D=dofile('mod/agent-harness_0.1.0/discovery.lua'){
 state=function() return state end,bots=function() return bots end,profile=function(i) return {display_name=names[i]} end}
local original={force='green',team='green',entities={{force='green',name='furnace'},{force='yellow',position={x=9,y=8}}},
 alerts={'team green built a furnace','Blue is ahead'},scores={green=7,yellow=12},text='green-wire and red-wire',
 profiles={{name='gemini',color='#3cb44b',glyph='G'}},chat={{from='gemini',text='Mine iron.'}}}
local out=D.project(original,'green')
assert(out.force==nil and out.team=='ours' and #out.entities==1 and out.entities[1].force==nil)
assert(#out.alerts==1 and out.alerts[1]=='team ours built a furnace' and out.scores.yellow==nil)
assert(out.text=='green-wire and red-wire' and out.profiles[1].color=='#3cb44b' and out.chat[1].text=='Mine iron.')
assert(original.force=='green' and #original.entities==2,'projection must not alter stored facts')
assert(D.project({name='grok',position={x=12,y=9}},'green')==nil,'unknown identity must not leave coordinates')
assert(D.project({from='Nova',text='I am at 120,30'},'green')==nil,'unknown display name row is private')
names[2]='forge'
assert(D.project({from='Forge',text='My own chosen name.'},'green').from=='Forge','a hidden alias collision cannot suppress own speech')
assert(D.project({force='yellow',from='Forge',text='Unknown force row.'},'green')==nil)
names[2]='Rivet'
assert(not D.viewer('green','Guest','Nice furnace!'),'viewer input disabled before contact')
state.mt.first['chart yellow>green']=100
assert(D.open('green') and D.known('green','yellow') and not D.known('green','blue'))
out=D.project(original,'green');assert(out.force=='green' and #out.entities==2 and out.entities[2].force=='yellow')
assert(not D.viewer('green','Guest','Yellow, tell Rivet about the furnace.'))
assert(not D.viewer('green','Blue fan','Nice furnace!'))
assert(not D.viewer('green','Guest','Nova is building rockets.'))
assert(not D.viewer('green','Guest','There is another team to the north.'))
assert(not D.viewer('blue','Guest','Yellow, look out!'),'contact reveals nothing to a third party')
assert(D.project('a platform of force blue','green')==nil)
state.mt.first['shot green>blue']=200
assert(not D.viewer('green','Guest','Nova and Blue are building rockets.'))
assert(D.project({viewer=true,text='Historic viewer spoiler'},'green')==nil)
assert(D.project('viewer Guest: Historic spoiler','green')==nil)
-- The save can retain an unlaunched, undiscovered Red force. Red wires and
-- green's own wire colour must survive before/after contact without exposing it.
state.mt.teams.red={}
local circuit={wires={red={{entity='constant-combinator',position={x=1,y=2}}},green={{entity='requester-chest'}}},
 networks={red={id=1,signals={{name='iron-plate',count=20}}},green={id=2,signals={}}},
 settings={input_networks='red',output_networks='green'}}
for _,first in ipairs{{},state.mt.first} do
 state.mt.first=first
 local read=D.project({circuit=circuit,force='red',position={x=9,y=9}},'green')
 assert(read==nil,'a circuit field cannot exempt foreign ownership')
 read=D.project({circuit=circuit,notes={red='red'},text='team red is nearby'},'green')
 assert(read.circuit.wires.red[1].entity=='constant-combinator' and read.circuit.wires.green)
 assert(read.circuit.networks.red.signals[1].count==20 and read.circuit.networks.green)
 assert(read.circuit.settings.input_networks=='red' and read.circuit.settings.output_networks=='green')
 assert(read.notes.red==nil and read.text==nil,'arbitrary force colour hints remain private')
 assert(D.project({viewer=true,circuit=circuit},'green')==nil)
end
state.mt=nil;assert(D.project(original,'player')==original and D.viewer('player','Blue fan','Other teams'))
print('mt295 discovery: metadata, rows, aliases, pair-only reveal, no viewer input, ordinary world unchanged: ok')
