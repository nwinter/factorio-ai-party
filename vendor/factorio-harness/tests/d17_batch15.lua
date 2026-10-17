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
