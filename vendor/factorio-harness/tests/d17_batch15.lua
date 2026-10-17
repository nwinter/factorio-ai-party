-- d17 batch15 contracts.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end

-- A2 (Grok ~6x): the items that spoil into an item are found from the prototypes.
do
  _G.prototypes={item={['copper-bacteria']={spoil_result={name='copper-ore'}},['iron-bacteria']={spoil_result={name='iron-ore'}},['copper-ore']={},['bioflux']={spoil_result={name='spoilage'}}}}
  local S=dofile('mod/agent-harness_0.1.0/supply.lua'){}
  local src=S.spoil_sources('copper-ore')
  eq(#src,1); eq(src[1],'copper-bacteria')
  eq(#S.spoil_sources('steel-plate'),0)
  prototypes=nil
  print('d17_batch15 A2 spoil sources: ok')
end

-- Group B: a request turning delivered, a spill and a hub_full gate appearing are one fact line each, to the loader
-- and those the platform's alerts go to; nothing repeats.
do
  game={tick=600,forces={player={platforms={{valid=true,index=13,name='Swift',hub={valid=true}}}}}}
  _G.prototypes={item={}}
  local st={}
  local S=dofile('mod/agent-harness_0.1.0/shipment.lua'){state=function() return st end,last_to=function() return {by='sonnet'} end,
    hears=function(p,name) return p.index==2 and name=='Swift' end,who=function(p) return p.name end}
  local rows
  S.platform=function() return {},rows end
  rows={{direction='up',planet='gleba',item='agricultural-science-pack',state='waiting',gate='the platform is not stopped at gleba',min=500,hub=0}}
  S.tick()
  rows={{direction='up',planet='gleba',item='agricultural-science-pack',state='waiting',gate='hub_full: Swift asks ...',min=500,hub=0}}
  game.tick=1200; S.tick()
  rows={{direction='up',planet='gleba',item='agricultural-science-pack',state='delivered',min=500,hub=512},
    {direction='down',planet='nauvis',item='iron-plate',state='spilled',count=40,at={'cargo-pod-container (3,4) on nauvis'}}}
  game.tick=1800; S.tick(); S.tick()
  eq(#st.shipment.events,3)
  local loader=S.lines({index=1,name='sonnet'},{})
  eq(#loader,3,'the loader hears all three')
  assert(loader[1]:find('waits: hub_full',1,true),loader[1])
  assert(loader[2]:find('from gleba delivered to Swift (the hub holds 512 of 500 asked)',1,true),loader[2])
  assert(loader[3]:find('40 iron-plate from Swift landed with no pad on nauvis',1,true),loader[3])
  local h={}
  eq(#S.lines({index=2,name='astra'},h),3,'one the alerts go to hears them')
  eq(S.lines({index=2,name='astra'},h),nil,'once')
  eq(S.lines({index=3,name='luna'},{}),nil,'others do not')
  game=nil; prototypes=nil
  print('d17_batch15 B shipment fact lines: ok')
end

-- Group C: an owned item unchanged across 2 checks is stalled; an owner in a wait is waiting; progress resets it.
do
  game={tick=0,get_surface=function() return nil end}
  _G.prototypes={item={['iron-plate']={}}}
  local st={}
  local items={[5]={id=5,kind='task',title='Iron for Swift',status='doing',owner='opus',notes={},created_tick=0,updated_tick=0,needs={{name='iron-plate',count=500}}}}
  local total,waiting=100,nil
  local P=dofile('mod/agent-harness_0.1.0/progress.lua'){state=function() return st end,items=function() return items end,
    owner_surface=function() return 'nauvis' end,total=function() return total end,since_request=function() return 600,1 end,
    waiting=function() return waiting end,who=function(p) return p.name end,QUIET=72000,PROJECT_QUIET=108000}
  P.tick()                                         -- the first check
  game.tick=36000; P.tick()
  eq(st.progress.items[5].state,'unchanged since the last check')
  waiting='sleep'; game.tick=72000; P.tick()
  assert(st.progress.items[5].state:find('^waiting'),st.progress.items[5].state)
  waiting=nil; game.tick=108000; P.tick()
  assert(st.progress.items[5].state:find('^stalled: unchanged across 2 checks'),st.progress.items[5].state)
  local r=P.read({},{})
  assert(r.lines[1]:find('anyone may take it once opus has made no request for 20 min',1,true),r.lines[1])
  total=600; game.tick=144000; P.tick()
  eq(st.progress.items[5].state,'progress')
  local l=P.lines({name='opus'},{})
  assert(l[#l]:find('progress seen: iron-plate on nauvis reached 600 (it needs 500; 100 at the check before)',1,true),l[#l])
  assert(l[#l]:find('no next action or blocker written on it (board_update {id: 5, note} writes one)',1,true),l[#l])
  game=nil; prototypes=nil
  print('d17_batch15 C board progress: ok')
end

-- Astra 09:20: a coming stop's landing pads asking what the hub holds for a later stop's pads, per stop in order.
do
  game={tick=0}
  _G.prototypes={item={}}
  local pl={name='Swift',force='player',schedule={current=2,records={{station='nauvis'},{station='gleba'},{station='aquilo'}}}}
  local S=dofile('mod/agent-harness_0.1.0/shipment.lua'){state=function() return {} end,where=function() return {leg={from='nauvis',to='gleba'}} end,
    hub_counts=function() return {['processing-unit']=500,['iron-plate']=50} end,
    pads=function(planet) if planet=='gleba' then return {['processing-unit']=500},{} elseif planet=='aquilo' then return {['processing-unit']=400,['iron-plate']=10},{} end return {},{} end}
  local c=S.conflicts(pl)
  eq(#c,1,'iron plates are asked at one stop only')
  assert(c[1]:find('the hub holds 500 processing-unit; stop 2 gleba: its pads ask 500 (hold 0), 500 go down there, 0 left aboard; stop 3 aquilo: its pads ask 400 (hold 0), 0 go down there, 0 left aboard',1,true),c[1])
  game=nil; prototypes=nil
  print('d17_batch15 B cargo conflict across stops: ok')
end
