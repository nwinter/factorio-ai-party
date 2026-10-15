-- Run with lua tests/rocketload.lua: a silo's rocket cargo in one call each (rocketload.lua; shift12 15:20).
-- load_silo (Sonnet: about 40 transfer and launch round trips a shift), preflight (Gemini), launch's min_cargo and
-- arrived guard and a queue dry run's silo cargo (Luna: a rocket_ready wait ran before an agricultural science
-- top-up and the queued launch went with the old cargo).
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text)
  local ok,err=pcall(fn)
  assert(not ok,'expected a failure: '..text)
  assert(tostring(err):find(text,1,true),'expected "'..text..'" in: '..tostring(err))
end
defines={inventory={rocket_silo_rocket=21,chest=1,assembling_machine_input=2},rocket_silo_status={building_rocket=0,rocket_ready=7}}
prototypes={item={['agricultural-science-pack']={weight=1000,stack_size=200},['space-platform-foundation']={weight=20000,stack_size=50},
  ['processing-unit']={weight=1000,stack_size=100},['iron-plate']={weight=1000,stack_size=100},['rocket-fuel']={weight=10000,stack_size=20}}}
game={tick=100}

-- Inventories: counts by item, slots by stack size.
local function key(name,q) return name..'@'..(q or 'normal') end
local function Inv(slots,items)
  local t={counts={},order={}}
  local function stack(name) return prototypes.item[name].stack_size end
  local function used()
    local n=0
    for k,c in pairs(t.counts) do n=n+math.ceil(c/stack(k:match('^(.-)@'))) end
    return n
  end
  function t.add(name,n,q)
    local k=key(name,q)
    if not t.counts[k] then t.order[#t.order+1]=k end
    t.counts[k]=(t.counts[k] or 0)+n
    if t.counts[k]==0 then t.counts[k]=nil end
  end
  function t.room(name,q)
    local held=t.counts[key(name,q)] or 0
    local part=held>0 and (math.ceil(held/stack(name))*stack(name)-held) or 0
    return (slots-used())*stack(name)+part
  end
  t.get_item_count=function(f) return t.counts[key(f.name,f.quality)] or 0 end
  t.get_contents=function()
    local out={}
    for _,k in ipairs(t.order) do if t.counts[k] then local n,q=k:match('^(.-)@(.*)$'); out[#out+1]={name=n,quality=q,count=t.counts[k]} end end
    return out
  end
  t.can_insert=function(f) return t.room(f.name,f.quality)>0 end
  t.used=used
  for _,it in ipairs(items or {}) do t.add(it[1],it[2],it[3]) end
  return setmetatable(t,{__len=function() return slots end,__index=function(_,i) if type(i)=='number' then return {valid_for_read=i<=used()} end end})
end
-- An item stack's quality is a LuaQualityPrototype in the game: userdata, not a table (Gemini 18:21: load_silo matched
-- no stack, held or in the chest, while it compared a table's name). The fake stacks carry userdata with a name.
local qualities={}
local function quality(q)
  if not qualities[q] then
    local u=io.tmpfile()
    debug.setmetatable(u,{__index={name=q}})
    qualities[q]=u
  end
  return qualities[q]
end
assert(type(quality('normal'))=='userdata' and quality('normal').name=='normal')
local function move_stacks(source,target,match,limit)
  local moved=0
  for _,k in ipairs(source.order) do
    local c=source.counts[k]
    if c and moved<limit then
      local name,q=k:match('^(.-)@(.*)$')
      if match({name=name,quality=quality(q)}) then
        local n=math.min(c,limit-moved,target.room(name,q))
        if n>0 then source.add(name,-n,q); target.add(name,n,q); moved=moved+n end
      end
    end
  end
  return moved,{}
end
local function grams(inv) local g=0; for k,c in pairs(inv.counts) do g=g+prototypes.item[k:match('^(.-)@')].weight*c end; return g end

local main=Inv(80,{{'agricultural-science-pack',300},{'iron-plate',50}})
local cargo=Inv(20)
local chestA=Inv(32,{{'agricultural-science-pack',500}})
local chestB=Inv(32,{{'agricultural-science-pack',400},{'space-platform-foundation',100}})
local surface={name='nauvis',planet={name='nauvis'}}
local silo={valid=true,name='rocket-silo',type='rocket-silo',position={x=65.5,y=14.5},rocket_silo_status=7,surface=surface,use_transitional_requests=false,unit_number=9}
silo.get_inventory=function(i) if i==21 and not silo.no_rocket then return cargo end end
local function chest(inv,x) local c={valid=true,name='iron-chest',type='container',position={x=x,y=10.5},force='us',surface=surface}; c.get_inventory=function(i) if i==1 then return inv end end; return c end
local cA,cB=chest(chestA,60.5),chest(chestB,61.5)
local p={position={x=62,y=12},force='us',surface=surface,reach_distance=10}
p.surface.find_entities_filtered=function(f) eq(f.force,'us'); assert(f.limit,'bounded'); return {cB,cA,silo} end
p.can_reach_entity=function(e) return e~=nil end
p.get_main_inventory=function() return main end
local launched,moved_hook
local pl={name='Sunward',valid=true,stopped=true}
local api
api={cargo={limits=function() return 1000000,20 end},reason=function(e) return tostring(e):gsub('^[^:]*:%d+: ','') end,
  reach_entity=function(_,pos)
    for _,e in ipairs({silo,cA,cB}) do if math.abs(e.position.x-pos.x)<0.6 and math.abs(e.position.y-pos.y)<0.6 then return e end end
    if pos.x>=61 and pos.x<=70 and pos.y>=10 and pos.y<=19 then return silo end
    error('entity not found at ('..pos.x..','..pos.y..')',0)
  end,
  remote_entity=function(_,a) return api.reach_entity(nil,a.position) end,
  platform=function(_,name) if name=='Sunward' then return pl end error('no platform named '..tostring(name),0) end,
  where=function(x) return x.stopped and {at='nauvis',stopped=true,text='at nauvis'} or {at='nauvis',stopped=false,text='at nauvis, on its path (not stopped)'} end,
  hub_counts=function() return {['agricultural-science-pack']=150} end,
  rocket=function(e) return {rocket=e.rocket_silo_status==7 and 'rocket built and ready' or 'building the rocket: parts 20/50',rocket_now=e.rocket_silo_status==7 and 'ready' or 'building the rocket: parts 20/50'} end,
  ingredients=function() return {'processing-unit','rocket-fuel'},'rocket-part' end,
  inventory_name=function(_,n) return ({cargo='rocket_silo_rocket',parts='assembling_machine_input'})[n] or n end,
  rocket_room=function(_,item) local each=prototypes.item[item].weight; return math.floor((1000000-grams(cargo))/each) end,
  rocket_weight=function() return string.format('%g/1000 kg',grams(cargo)/1000) end,
  move_stacks=move_stacks,give_sources=function() return {main} end,
  launch=function(_,a) launched=a; return {launched=true,to='platform '..a.platform} end,
  moved=function(_,s,stacks) moved_hook={silo=s,stacks=stacks} end}
local R=dofile('mod/agent-harness_0.1.0/rocketload.lua')(api)

-- 1. Item lists: a map (sorted by name), a list with quality, repeats adding up; the refusals.
local l=R.items({['iron-plate']=5,['agricultural-science-pack']=10})
eq(l[1].name,'agricultural-science-pack'); eq(l[2].count,5); eq(l[1].quality,'normal')
l=R.items({{item='iron-plate',count=2},{name='iron-plate',count=3},{item='iron-plate',count=1,quality='rare'}})
eq(#l,2); eq(l[1].count,5); eq(l[2].quality,'rare')
fails(function() R.items({}) end,'items needs 1..20 items')
fails(function() R.items({nope=1}) end,'items: unknown item nope')
fails(function() R.items({['iron-plate']=0}) end,'iron-plate count must be 1..100000')
fails(function() R.items('iron-plate') end,'items is {"item-name": count}')

-- 2. load_silo: from you first, then the chests in reach, nearest first; the reply per item.
local r=R.load(p,{position={x=65.5,y=14.5},items={['agricultural-science-pack']=1000}})
eq(r.silo,'rocket-silo at (65.5,14.5)'); eq(r.complete,true); eq(r.short,nil); eq(r.chests,2)
eq(r.loaded[1].item,'agricultural-science-pack'); eq(r.loaded[1].loaded,1000); eq(r.loaded[1].aboard,1000)
eq(r.loaded[1].from,'you 300, iron-chest (61.5,10.5) 400, iron-chest (60.5,10.5) 300')
eq(cargo.counts['agricultural-science-pack@normal'],1000); eq(chestA.counts['agricultural-science-pack@normal'],200)
eq(r.cargo,'agricultural-science-pack*1000'); eq(r.rocket_weight,'1000/1000 kg'); eq(r.slots,'5/20')
eq(moved_hook.stacks[1].count,1000)
-- Full by weight: nothing more fits; the row says why.
r=R.load(p,{position={x=65.5,y=14.5},items={['space-platform-foundation']=10}})
eq(r.complete,false); eq(r.loaded[1].loaded,0); eq(r.loaded[1].short,10)
eq(r.loaded[1].why,'weight: 0 fit under the lift (20 kg each; the rocket holds 1000/1000 kg)')
eq(r.short[1],'space-platform-foundation 10 short (weight: 0 fit under the lift (20 kg each; the rocket holds 1000/1000 kg))')
-- to_total: only the rest of each count goes in; a count already aboard moves nothing.
cargo.add('agricultural-science-pack',-400)
r=R.load(p,{position={x=65.5,y=14.5},items={['agricultural-science-pack']=600},to_total=true,chests=false})
eq(r.loaded[1].aboard_before,600); eq(r.loaded[1].loaded,0); eq(r.complete,true)
-- Short of what you and the chests hold.
r=R.load(p,{position={x=65.5,y=14.5},items={['agricultural-science-pack']=900},to_total=true})
eq(r.loaded[1].loaded,200); eq(r.loaded[1].short,100); eq(r.loaded[1].why,'you held 0; iron-chest (61.5,10.5) held 0; iron-chest (60.5,10.5) held 200')
-- from: only the chests given (after your inventory).
chestB.add('agricultural-science-pack',50); main.add('agricultural-science-pack',10)
r=R.load(p,{position={x=65.5,y=14.5},items={['agricultural-science-pack']=40},from={x=61.5,y=10.5}})
eq(r.loaded[1].from,'you 10, iron-chest (61.5,10.5) 30'); eq(r.chests,1)
fails(function() R.load(p,{position={x=65.5,y=14.5},items={['iron-plate']=1},from={x=1,y=1}}) end,'entity not found at (1,1)')

-- 3. launch=true: loaded and launched in one tick; the launch gets min_cargo and arrived; short: not launched.
cargo.counts={}; cargo.order={}
chestA.add('agricultural-science-pack',1000)
r=R.load(p,{position={x=65.5,y=14.5},items={['agricultural-science-pack']=1000},to_total=true,launch=true,platform='Sunward',
  min_cargo={['agricultural-science-pack']=1000},arrived=true})
eq(r.launch.launched,true); eq(launched.platform,'Sunward'); eq(launched.min_cargo['agricultural-science-pack'],1000); eq(launched.arrived,true)
eq(launched.position.x,65.5)
cargo.counts={}; cargo.order={}; launched=nil
chestA.counts={}; chestA.order={}; chestB.counts={}; chestB.order={}; main.counts={}; main.order={}
main.add('agricultural-science-pack',300)
fails(function() R.load(p,{position={x=65.5,y=14.5},items={['agricultural-science-pack']=1000},launch=true,platform='Sunward'}) end,
  'not launched: agricultural-science-pack 700 short (you held 300; iron-chest (61.5,10.5) held 0; iron-chest (60.5,10.5) held 0); what was loaded stays in the rocket (it holds agricultural-science-pack*300, 300/1000 kg)')
eq(launched,nil); eq(cargo.counts['agricultural-science-pack@normal'],300)
-- The launch refused after loading: said, the cargo stays.
local real_launch=api.launch
api.launch=function() error('launch refused at tick 100, nothing launched: platform Sunward has not arrived at nauvis',0) end
fails(function() R.load(p,{position={x=65.5,y=14.5},items={['agricultural-science-pack']=300},to_total=true,launch=true,platform='Sunward'}) end,
  'loaded, then the launch was refused: launch refused at tick 100, nothing launched: platform Sunward has not arrived at nauvis; the cargo stays in the rocket')
api.launch=real_launch
-- Arguments.
fails(function() R.load(p,{position={x=65.5,y=14.5},items={['iron-plate']=1},launch=true}) end,'launch needs platform=<name> (or orbit=true)')
fails(function() R.load(p,{position={x=65.5,y=14.5},items={['iron-plate']=1},platform='Sunward'}) end,'platform goes with launch=true')
fails(function() R.load(p,{position={x=65.5,y=14.5},items={['iron-plate']=1},to_total='yes'}) end,'to_total must be true or false')
-- Automatic requests on: the game takes no cargo by hand.
silo.use_transitional_requests=true
fails(function() R.load(p,{position={x=65.5,y=14.5},items={['iron-plate']=1}}) end,'has automatic requests on')
silo.use_transitional_requests=false
-- Not a silo.
fails(function() R.load(p,{position={x=60.5,y=10.5},items={['iron-plate']=1}}) end,'iron-chest at (60.5,10.5) is not a rocket silo')

-- 4. Waiting: no rocket yet, or launch=true before it is ready; ready() says when to run the call again.
silo.no_rocket=true
r=R.load(p,{position={x=65.5,y=14.5},items={['iron-plate']=1}})
eq(r.wait,true); eq(r.why,'no rocket to load yet')
eq(R.ready(p,{await_silo={position={x=65.5,y=14.5}}}),false)
silo.no_rocket=nil; silo.rocket_silo_status=0
eq(R.ready(p,{await_silo={position={x=65.5,y=14.5}}}),true,'loading needs the rocket only')
eq(R.ready(p,{await_silo={position={x=65.5,y=14.5},launch=true}}),false,'a launch waits for ready')
r=R.load(p,{position={x=65.5,y=14.5},items={['iron-plate']=1},launch=true,platform='Sunward'})
eq(r.wait,true); eq(r.why,'the rocket is not ready to launch yet'); eq(r.rocket,'building the rocket: parts 20/50')
silo.rocket_silo_status=7
eq(R.ready(p,{await_silo={position={x=65.5,y=14.5},launch=true}}),true)
eq(R.ready(p,{await_silo={position={x=1,y=1}}}),true,'a silo gone: run it again (it fails then)')

-- 5. The launch guard: min_cargo and arrived, read now.
cargo.counts={}; cargo.order={}; cargo.add('agricultural-science-pack',600)
fails(function() R.guard(p,{platform='Sunward',min_cargo={['agricultural-science-pack']=1000}},silo) end,
  'launch refused at tick 100, nothing launched: min_cargo not met: agricultural-science-pack 600 of 1000 (400 short); the rocket holds agricultural-science-pack*600')
cargo.add('agricultural-science-pack',400)
local g=R.guard(p,{platform='Sunward',min_cargo={['agricultural-science-pack']=1000},arrived=true},silo)
eq(g.tick,100); eq(g.lines[1],'min_cargo: agricultural-science-pack 1000 aboard (at least 1000)'); eq(g.lines[2],'arrived: platform Sunward stopped at nauvis')
pl.stopped=false
fails(function() R.guard(p,{platform='Sunward',arrived=true},silo) end,
  'launch refused at tick 100, nothing launched: platform Sunward has not arrived at nauvis (at nauvis, on its path (not stopped))')
pl.stopped=true
fails(function() R.guard(p,{arrived=true},silo) end,'arrived goes with platform=<name>')
eq(R.guard(p,{platform='Sunward'},silo),nil)

-- 6. preflight: the cargo against lift and slots, a list's lacks and what fits, the platform's requests from here.
cargo.counts={}; cargo.order={}; cargo.add('agricultural-science-pack',600); cargo.add('space-platform-foundation',10)
main.counts={}; main.order={}; main.add('agricultural-science-pack',120)
pl.hub={get_logistic_sections=function() return {sections_count=2,get_section=function(i)
  if i==1 then return {active=true,filters={{value={name='agricultural-science-pack',quality='normal'},min=1000,import_from={name='nauvis'}},
    {value='iron-plate',min=200,import_from='nauvis'},{value='processing-unit',min=50,import_from='vulcanus'}}} end
  return {active=false,filters={{value='rocket-fuel',min=100,import_from='nauvis'}}} end} end}
local f=R.preflight(p,{position={x=65.5,y=14.5},items={['agricultural-science-pack']=1000,['iron-plate']=10},platform='Sunward'})
eq(f.silo,'rocket-silo at (65.5,14.5) on nauvis'); eq(f.rocket_ready,true); eq(f.auto_requests,false)
eq(f.cargo.items,'agricultural-science-pack*600 space-platform-foundation*10'); eq(f.cargo.kg,800); eq(f.cargo.free_kg,200); eq(f.cargo.slots,'4/20'); eq(f.cargo.free_slots,16)
eq(f.cargo.rows[1].item,'agricultural-science-pack'); eq(f.cargo.rows[1].kg,600); eq(f.cargo.rows[2].each_kg,20)
eq(f.order[1].item,'agricultural-science-pack'); eq(f.order[1].lacks,400); eq(f.order[1].fits,200,'200 kg free at 1 kg each'); eq(f.order[1].you_hold,120)
eq(f.order[2].lacks,10); eq(f.order[2].fits,10)
eq(f.platform.arrived,true); eq(#f.platform.requests,2,'from nauvis, active sections only')
eq(f.platform.requests[1].item,'agricultural-science-pack'); eq(f.platform.requests[1].hub,150); eq(f.platform.requests[1].aboard,600); eq(f.platform.requests[1].lacks_after,250)
eq(f.platform.requests[2].item,'iron-plate'); eq(f.platform.requests[2].lacks_after,200)
eq(f.platform.not_requested,'space-platform-foundation*10')
eq(f.launch_now,'ok')
eq(f.line,'rocket-silo at (65.5,14.5) on nauvis: cargo agricultural-science-pack*600 space-platform-foundation*10, 800/1000 kg, 4/20 slots; the list lacks agricultural-science-pack 400 (200 fit), iron-plate 10 (10 fit); platform Sunward at nauvis; after this rocket its requests from nauvis lack agricultural-science-pack 250, iron-plate 200; launch now: ok')
-- Not ready, over the lift, the platform on its path: what launch would refuse now.
silo.rocket_silo_status=0; cargo.add('space-platform-foundation',20); pl.stopped=false
f=R.preflight(p,{position={x=65.5,y=14.5},platform='Sunward'})
eq(f.cargo.over_kg,200); eq(f.cargo.free_kg,0)
eq(f.launch_now,'refused: building the rocket: parts 20/50; overweight by 200 kg; platform Sunward is not stopped at nauvis')
silo.rocket_silo_status=7; pl.stopped=true; cargo.add('space-platform-foundation',-20)
-- No rocket yet.
silo.no_rocket=true
f=R.preflight(p,{position={x=65.5,y=14.5}})
eq(f.cargo.items,'no rocket to load yet'); eq(f.cargo.slots,'0/20')
silo.no_rocket=nil

-- 7. A queue dry run's silo cargo (Luna's race): a rocket_ready wait, then the launch with min_cargo, the top-up
-- after it: the launch would be refused; the top-up before it: it would go, and the cargo is the one it leaves.
cargo.counts={}; cargo.order={}; cargo.add('agricultural-science-pack',600)
main.counts={}; main.order={}; main.add('agricultural-science-pack',400)
chestA.counts={}; chestA.order={}; chestB.counts={}; chestB.order={}
local S={x=65.5,y=14.5}
local race={{action='wait_until',args={['until']='rocket_ready',position=S}},
  {action='launch',args={position=S,platform='Sunward',min_cargo={['agricultural-science-pack']=1000}},label='go'},
  {action='transfer',args={position=S,item='agricultural-science-pack',count=400,direction='to_entity',inventory='cargo'}}}
local sim=R.simulate(p,race)
eq(#sim.launches,1); eq(sim.launches[1].step,2); eq(sim.launches[1].label,'go')
eq(sim.launches[1].cargo,'agricultural-science-pack*600'); eq(sim.launches[1].kg,'600/1000 kg')
eq(sim.launches[1].min_cargo[1],'agricultural-science-pack 600 aboard (at least 1000)')
eq(sim.launches[1].would_refuse[1],'min_cargo not met: agricultural-science-pack 600 of 1000 (400 short)')
eq(sim.launches[1].platform_now,'Sunward at nauvis')
eq(sim.silos_after[1],'rocket-silo (65.5,14.5): agricultural-science-pack*1000','the refused launch leaves the cargo; the top-up after it adds')
local fixed={race[1],race[3],race[2]}
sim=R.simulate(p,fixed)
eq(sim.launches[1].step,3); eq(sim.launches[1].cargo,'agricultural-science-pack*1000'); eq(sim.launches[1].would_refuse,nil)
eq(sim.silos_after[1],'rocket-silo (65.5,14.5): empty','launched')
eq(main.counts['agricultural-science-pack@normal'],400,'a dry run moves nothing')
-- load_silo with launch, a chest take before it, a step whose moves are not counted, an inferred cargo inventory.
chestA.add('agricultural-science-pack',300)
sim=R.simulate(p,{{action='transfer',args={position={x=60.5,y=10.5},item='agricultural-science-pack',direction='to_player'}},
  {action='collect',args={position={x=1,y=1}}},
  {action='transfer',args={position=S,item='space-platform-foundation',count=5}},
  {action='load_silo',args={position=S,items={['agricultural-science-pack']=1000},to_total=true,chests=false,launch=true,platform='Sunward'}}})
eq(sim.launches[1].step,4); eq(sim.launches[1].cargo,'agricultural-science-pack*1000'); eq(sim.launches[1].would_refuse,nil)
eq(sim.notes[1],'step 2 (collect): the items it moves are not counted')
eq(sim.notes[2],'step 3 (transfer): no direction, and neither you nor rocket-silo (65.5,14.5) hold space-platform-foundation by then: transfer refuses it')
-- A load_silo short of its list: not launched.
sim=R.simulate(p,{{action='load_silo',args={position=S,items={['agricultural-science-pack']=2000},chests=false,launch=true,platform='Sunward'}}})
eq(sim.launches[1].would_refuse[1],'load_silo short of its list: not launched')
-- Over the lift and empty.
sim=R.simulate(p,{{action='transfer',args={position=S,item='agricultural-science-pack',count=400,direction='to_entity'}},
  {action='launch',args={position=S,platform='Sunward'}},{action='launch',args={position=S,platform='Sunward'}}})
eq(sim.launches[1].cargo,'agricultural-science-pack*1000','the weight caps what goes in')
eq(sim.launches[1].would_refuse,nil); eq(sim.launches[2].would_refuse[1],'empty (allow_empty=true launches it so)')
-- No silo there.
sim=R.simulate(p,{{action='launch',args={position={x=500,y=500},platform='Sunward'}}})
assert(sim.notes[1]:find('^step 1 %(launch%): not counted: entity not found'),sim.notes[1])
-- 8. Gemini 18:21 (shift13, 01:19 UTC): load_silo {items {advanced-circuit 711}, from the requester chest at
-- (-63.5,96.5), launch to Sunward} answered "you and the 1 chests read held only 0" while the chest held 2001: the
-- stacks' quality is userdata in the game. Replayed: the 711 go in (289 kg of science aboard: 1000 kg) and it launches.
prototypes.item['advanced-circuit']={weight=1000,stack_size=200}
prototypes.item['electromagnetic-science-pack']={weight=1000,stack_size=200}
cargo.counts={}; cargo.order={}; cargo.add('electromagnetic-science-pack',289)
main.counts={}; main.order={}
local reqinv=Inv(48,{{'advanced-circuit',2001}})
local requester={valid=true,name='requester-chest',type='logistic-container',position={x=-63.5,y=96.5},force='us',surface=surface}
requester.get_inventory=function(i) if i==1 then return reqinv end end
local kept_reach=api.reach_entity
api.reach_entity=function(pp,pos) if pos.x==-63.5 then return requester end return kept_reach(pp,pos) end
launched=nil
r=R.load(p,{position={x=65.5,y=14.5},items={['advanced-circuit']=711},from={{x=-63.5,y=96.5}},launch=true,platform='Sunward'})
eq(r.loaded[1].loaded,711); eq(r.loaded[1].from,'requester-chest (-63.5,96.5) 711'); eq(r.complete,true)
eq(reqinv.counts['advanced-circuit@normal'],1290); eq(r.rocket_weight,'1000/1000 kg'); eq(launched.platform,'Sunward')
api.reach_entity=kept_reach
-- Every chest kind in reach is read, nearest first, a landing pad too (its own inventory).
local asked_types
local kept_find=p.surface.find_entities_filtered
defines.inventory.cargo_landing_pad_main=50
local padinv=Inv(80,{{'advanced-circuit',40}})
local pad={valid=true,name='cargo-landing-pad',type='cargo-landing-pad',position={x=70,y=20},force='us',surface=surface}
pad.get_inventory=function(i) if i==50 then return padinv end end
p.surface.find_entities_filtered=function(f) asked_types=f.type; return {pad,requester,silo} end
cargo.counts={}; cargo.order={}
local seen={}
for _,t in ipairs(R.chests_in_reach(p,silo)) do seen[#seen+1]=t.name end
for _,t in ipairs({'container','logistic-container','linked-container','infinity-container','cargo-landing-pad'}) do
  local found=false
  for _,x in ipairs(asked_types) do found=found or x==t end
  assert(found,'chest kind asked: '..t)
end
eq(table.concat(seen,','),'cargo-landing-pad,requester-chest','nearest first: the pad (70,20) is nearer (62,12) than the requester')
r=R.load(p,{position={x=65.5,y=14.5},items={['advanced-circuit']=100}})
eq(r.loaded[1].from,'cargo-landing-pad (70,20) 40, requester-chest (-63.5,96.5) 60')
p.surface.find_entities_filtered=kept_find
print('rocketload ok')
