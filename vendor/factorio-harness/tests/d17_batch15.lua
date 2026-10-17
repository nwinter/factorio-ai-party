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

-- Group D: a lesson shown before a call, then that agent's failure it names within 30 min: did not prevent; none: not.
do
  game={tick=1000}
  local st={}
  local items={[9]={id=9,kind='lesson',status='open',title='Load fresh packs first',failure='load_silo short',keys={action='load_silo'},impact=3,verify_count=2,last_verified=1000,created_tick=0},
    [10]={id=10,kind='lesson',status='open',title='Hub full stalls builds',failure='construct hub_full',keys={entity='space-platform-hub'},created_tick=0}}
  local L=dofile('mod/agent-harness_0.1.0/lessonbook.lua'){state=function() return st end,items=function() return items end,stale=12*216000,
    active=function(i) return i.status=='open' end,who=function(p) return p.name end}
  local n,why=L.score(items[9])
  eq(n,3*2+1+2+3); assert(why:find('impact 3, applies to 1 key, verified 2 times',1,true),why)
  L.surfaced(1,{items[9],items[10]},'load_silo')
  game.tick=2000; L.failed(1,'load_silo','short: calcite 100 short (what you and the chests held)')
  L.failed(2,'construct','hub_full')
  game.tick=1000+L.WINDOW+1; L.tick()
  local r=L.review({},{})
  eq(r.counts.repeat_,1); eq(r.counts.no_repeat,1)
  -- ground rules: at most 8, each from lessons
  for k=1,8 do L.rule_add({name='astra'},{text='rule '..k,lessons={9}}) end
  local ok,err=pcall(L.rule_add,{name='astra'},{text='ninth',lessons={9}})
  assert(not ok and tostring(err):find('at most 8 ground rules',1,true),tostring(err))
  L.rule_retire({name='sol'},{id=3})
  eq(#L.rule_lines(),7)
  game=nil
  print('d17_batch15 D lessons scored and followed: ok')
end

-- board_focus (Sol 09:37 for Foobator): one line; a focused step not done across 2 checks is flagged; done clears it.
do
  game={tick=0,get_surface=function() return nil end}
  _G.prototypes={item={}}
  local st={}
  local items={[7]={id=7,kind='project',title='Aquilo heat',status='doing',owner='sol',notes={},created_tick=0,updated_tick=0,
    steps={{n=1,text='foundation',done_by='sol',done_tick=0},{n=2,text='heat pipes to the chest row'}}}}
  local P=dofile('mod/agent-harness_0.1.0/progress.lua'){state=function() return st end,items=function() return items end,
    owner_surface=function() return 'aquilo' end,total=function() return 0 end,since_request=function() return 60,3 end,
    waiting=function() return nil end,who=function(p) return p.name end,agents=function() return {{name='sol',index=3},{name='astra',index=1}} end,QUIET=72000,PROJECT_QUIET=108000}
  local r=P.focus({name='sol'},{id=7,step=2,blocker='no heat pipes in the hub',verify='inspect the chest row temperature'})
  assert(r.focus:find('sol focus (set 0s ago): #7 Aquilo heat; step 2 heat pipes to the chest row; blocker: no heat pipes in the hub; next verification: inspect the chest row temperature',1,true),r.focus)
  eq(P.focus({name='astra'},{agent='sol'}).focus[1],r.focus,'a teammate reads it')
  P.tick(); game.tick=36000; P.tick(); game.tick=72000; P.tick()
  assert(P.focus_line('sol'):find('the focused step shows no completion across 2 checks',1,true),P.focus_line('sol'))
  assert(P.read({},{}).lines[1]:find('the focused step 2 shows no completion across 2 checks',1,true),P.read({},{}).lines[1])
  items[7].steps[2].done_by='sol'; items[7].steps[2].done_tick=72000
  game.tick=108000; P.tick()
  assert(not P.focus_line('sol'):find('no completion',1,true),P.focus_line('sol'))
  game=nil; prototypes=nil
  print('d17_batch15 board_focus: ok')
end
