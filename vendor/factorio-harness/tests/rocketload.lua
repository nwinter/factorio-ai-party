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
defines={inventory={rocket_silo_rocket=21,chest=1,assembling_machine_input=2,hub_main=3,hub_trash=4},rocket_silo_status={building_rocket=0,rocket_ready=7}}
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
-- up_to (Sonnet 07:50): what is aboard goes; the short row is listed, not an error. None of the list aboard: refused.
r=R.load(p,{position={x=65.5,y=14.5},items={['agricultural-science-pack']=1000},to_total=true,up_to=true,launch=true,platform='Sunward'})
eq(r.launch.launched,true); eq(r.short,nil); eq(r.complete,false)
eq(r.up_to_short[1],'agricultural-science-pack 700 short (you held 0; iron-chest (61.5,10.5) held 0; iron-chest (60.5,10.5) held 0)')
cargo.counts={}; cargo.order={}; launched=nil
fails(function() R.load(p,{position={x=65.5,y=14.5},items={['agricultural-science-pack']=10},up_to=true,launch=true,platform='Sunward'}) end,
  'not launched (up_to): none of the list is aboard')
eq(launched,nil)
fails(function() R.load(p,{position={x=65.5,y=14.5},items={['agricultural-science-pack']=10},up_to='yes'}) end,'up_to must be true or false')
cargo.add('agricultural-science-pack',300)
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
  return {active=false,filters={{value='rocket-fuel',min=100,import_from='nauvis'}}} end} end,
  get_inventory=function(id) if id==3 then return Inv(20,{{'agricultural-science-pack',150}}) end end}
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
eq(f.line,'rocket-silo at (65.5,14.5) on nauvis: rocket built and ready; cargo agricultural-science-pack*600 space-platform-foundation*10, 800/1000 kg, 4/20 slots; manifest 1010 kg, 6 slots; cargo after filling it 1210/1000 kg, 7/20 slots; the list lacks agricultural-science-pack 400 (200 fit), iron-plate 10 (10 fit); platform Sunward at nauvis; arrived; requests from nauvis: agricultural-science-pack lacks 850 (rocket 600, lacks_after 250), iron-plate lacks 200 (rocket 0, lacks_after 200); launch now: ok')
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
-- Rockets on their way to the platform, its ammo over the last leg and the hub slots chunks take (Astra, shift14 22:50:
-- reconciled by hand before each launch).
api.incoming=function(x) assert(x==pl); return {rockets=2,cargo='firearm-magazine*40',lines={'a rocket from nauvis launched 3s ago: firearm-magazine*20 (rising over nauvis)','a rocket from nauvis launched 20s ago: firearm-magazine*20 (coming down onto the platform)'}} end
api.ammo=function() return {'firearm-magazine: made 42/min, used 38/min over the last 10 min; hub 544, turrets 191'} end
api.hub_chunks=function() return 'asteroid chunks take 22 of 99 slots (carbonic 9, metallic 9, oxide 4)' end
f=R.preflight(p,{position={x=65.5,y=14.5},platform='Sunward'})
eq(f.platform.incoming_cargo,'2 rockets on the way: firearm-magazine*40'); eq(#f.platform.incoming,2)
eq(f.platform.ammo_rates[1],'firearm-magazine: made 42/min, used 38/min over the last 10 min; hub 544, turrets 191')
eq(f.platform.hub_chunks,'asteroid chunks take 22 of 99 slots (carbonic 9, metallic 9, oxide 4)')
assert(f.line:find('platform Sunward at nauvis; arrived; requests from nauvis:',1,true),f.line)
assert(f.line:find('2 rockets on the way: firearm-magazine*40',1,true),f.line)
eq(f.platform.requests[1].lacks_after,250, 'incoming cargo remains separate from this rocket')
api.incoming=function() return {rockets=1,cargo='empty',lines={'a rocket from nauvis launched 3s ago: empty (rising over nauvis)'}} end
eq(R.preflight(p,{position={x=65.5,y=14.5},platform='Sunward'}).platform.incoming_cargo,'1 rocket on the way: empty')
api.incoming=function() return nil end; api.ammo=function() error('no stats') end
f=R.preflight(p,{position={x=65.5,y=14.5},platform='Sunward'})
eq(f.platform.incoming,nil); eq(f.platform.ammo_rates,nil,'a failing read is left out')
assert(not f.line:find('on the way',1,true),f.line)
api.incoming,api.ammo,api.hub_chunks=nil,nil,nil

-- 6b. Dispatch: route direction, current-speed ETA, a departure not yet timed, and requests before arrival.
local saved_where, saved_force = api.where, p.force
local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return {} end}
api.where=F.where
defines.space_platform_state={on_the_path=3}
pl.space_connection={from={name='nauvis'},to={name='gleba'},length=15000}
pl.distance=0.27; pl.speed=0.05; pl.schedule={current=1,records={{station='nauvis'}}}; pl.state=3
api.incoming=function() return {rockets=1,cargo='agricultural-science-pack*1000',lines={'a rocket from nauvis: agricultural-science-pack*1000'}} end
api.ammo=function() return {'firearm-magazine: made 42/min, used 38/min'} end
api.hub_chunks=function() return 'asteroid chunks take 22 of 99 slots' end
f=R.preflight(p,{position=silo.position,platform='Sunward'})
eq(f.platform.eta_s,1350); eq(f.platform.eta_to,'nauvis'); eq(f.platform.from,'gleba'); eq(f.platform.to,'nauvis')
-- Freshness reads the rocket now and the hub at the current leg's ETA.
do
  local seen = {}
  api.fresh_inv=function(_,inv,_,eta)
    seen[#seen+1]={inventory=inv,eta=eta}
    return {inv==cargo and 'rocket value now' or 'hub value at arrival'}
  end
  local value=R.preflight(p,{position=silo.position,platform='Sunward'})
  eq(seen[1].inventory,cargo); eq(seen[1].eta,nil); eq(seen[2].eta,81000)
  eq(value.cargo.freshness[1],'rocket value now'); eq(value.platform.freshness[1],'hub value at arrival')
  assert(value.line:find('rocket value now',1,true) and value.line:find('hub value at arrival',1,true))
  seen={};pl.speed=0
  R.preflight(p,{position=silo.position,platform='Sunward'})
  eq(seen[2].eta,nil,'no invented arrival value when the current speed is zero')
  pl.speed=.05;api.fresh_inv=nil
end
eq(f.platform.headed_here,true); eq(f.platform.arrived,false); eq(math.floor(f.platform.distance_left_km+0.5),4050)
eq(f.platform.speed_km_s,3); assert(f.platform.eta_basis:find('60 ticks',1,true))
eq(f.platform.requests[1].lacks_after,250,'same shortfall while approaching, incoming cargo reported separately')
eq(f.platform.incoming_cargo,'1 rocket on the way: agricultural-science-pack*1000')
assert(f.platform.ammo_rates[1]:find('made 42/min',1,true)); assert(f.platform.hub_chunks:find('22 of 99',1,true))
assert(f.line:find('ETA to nauvis',1,true) and f.line:find('1 rocket on the way:',1,true),f.line)
api.incoming,api.ammo,api.hub_chunks=nil,nil,nil
pl.schedule.records[1].station='gleba'
f=R.preflight(p,{position=silo.position,platform='Sunward'})
eq(f.platform.eta_s,3650); eq(f.platform.eta_to,'gleba'); eq(f.platform.headed_here,false)
assert(f.platform.arrival_unknown:find('nauvis',1,true),'other endpoint ETA is not arrival here')
pl.speed=0
f=R.preflight(p,{position=silo.position,platform='Sunward'})
eq(f.platform.eta_s,nil); assert(f.platform.eta_unknown:find('zero',1,true))
pl.space_connection=nil; pl.space_location={name='gleba'}; pl.state=5
pl.schedule={current=1,records={{station='gleba'},{station='nauvis'}}}
f=R.preflight(p,{position=silo.position,platform='Sunward'})
eq(f.platform.next_stop,'nauvis'); eq(f.platform.eta_s,nil); eq(f.platform.headed_here,true)
assert(f.platform.eta_unknown:find('departure time',1,true))
-- No platform: arrived first, then the incoming ship; unrelated and paused departures excluded.
local arrived={valid=true,name='Arrived',space_location={name='nauvis'},hub=pl.hub}
local unrelated={valid=true,name='Elsewhere',space_location={name='vulcanus'}}
p.force={platforms={pl,unrelated,arrived}}
f=R.preflight(p,{position=silo.position})
eq(#f.platforms,2); eq(f.platforms[1].name,'Arrived'); eq(f.platforms[1].eta_s,0); eq(f.platforms[2].name,'Sunward')
eq(f.platforms[1].requests[1].lacks,850); eq(f.platforms[1].requests[1].lacks_after,250)
pl.paused=true
f=R.preflight(p,{position=silo.position}); eq(#f.platforms,1)
pl.paused=false
-- Qualities, section multipliers, fulfilled requests and the hub trash inventory.
local old_hub=pl.hub
local hubmain=Inv(20,{{'agricultural-science-pack',1000},{'iron-plate',2,'rare'}})
local hubtrash=Inv(20,{{'iron-plate',3,'rare'}})
pl.hub={get_inventory=function(id) return id==3 and hubmain or hubtrash end,
  get_logistic_sections=function() return {sections_count=3,get_section=function(i)
    if i==1 then return {multiplier=2,filters={{value={name='iron-plate',quality='rare'},min=10,import_from='nauvis'}}} end
    if i==2 then return {filters={{value={name='agricultural-science-pack'},min=1000,import_from='nauvis'}}} end
    return {multiplier=0,filters={{value='processing-unit',min=100,import_from='nauvis'}}}
  end} end}
cargo.add('iron-plate',4); cargo.add('iron-plate',6,'rare')
f=R.preflight(p,{position=silo.position})
local asks=f.platforms[2].requests
eq(#asks,1,'fulfilled and disabled requests omitted'); eq(asks[1].min,20); eq(asks[1].hub,5)
eq(asks[1].aboard,6); eq(asks[1].lacks_after,9)
assert(f.platforms[2].not_requested:find('iron-plate*4',1,true),'normal cargo does not cover rare request')
pl.name='Sunward\nSecond line'
f=R.preflight(p,{position=silo.position}); assert(not f.line:find('[\r\n]')); assert(not f.platforms[2].line:find('[\r\n]'))
pl.name='Sunward'; pl.hub=old_hub; cargo.add('iron-plate',-4); cargo.add('iron-plate',-6,'rare')
-- No position: all indexed visible silos, nearest first, current contents, no discovery scan.
local old_remote, old_rocket = api.remote_entity, api.rocket
local far=setmetatable({position={x=150,y=150},unit_number=10},{__index=silo})
local hidden=setmetatable({position={x=400,y=400},unit_number=11},{__index=silo})
api.silos=function() return {far,hidden,silo},80 end
p.force.is_chunk_visible=function(_,c) return c.x<10 end
api.remote_entity=function(_,a) for _,e in ipairs({silo,far,hidden}) do if a.position==e.position then return e end end end
api.rocket=function(e) return {rocket='rocket built and ready',built_parts='50/50',next_parts='10/50'} end
local extra_reads={incoming=0,ammo=0,chunks=0}
api.incoming=function() extra_reads.incoming=extra_reads.incoming+1; return {rockets=1,cargo='agricultural-science-pack*1000',lines={'incoming rocket'}} end
api.ammo=function() extra_reads.ammo=extra_reads.ammo+1; return {'ammo rate'} end
api.hub_chunks=function() extra_reads.chunks=extra_reads.chunks+1; return 'chunk slots' end
f=R.preflight(p,{platform='Sunward'})
eq(#f.silos,2); eq(f.silos[1].position.x,65.5); eq(f.silos[2].position.x,150)
eq(f.silos[1].rocket_ready,true); eq(f.silos[1].built_parts,'50/50'); eq(f.silos[1].next_parts,'10/50')
eq(f.silos[1].cargo.kg,800); eq(f.silos[1].platform.requests[1].lacks_after,250); eq(f.silos_as_of,80)
eq(extra_reads.incoming,1); eq(extra_reads.ammo,1); eq(extra_reads.chunks,1)
for _,row in ipairs(f.silos) do eq(row.platform.incoming_cargo,'1 rocket on the way: agricultural-science-pack*1000'); eq(row.platform.ammo_rates[1],'ammo rate'); eq(row.platform.hub_chunks,'chunk slots') end
f=R.preflight(p,{})
eq(#f.silos[1].platforms,2); eq(extra_reads.ammo,1,'platform discovery does not read named diagnostics')
eq(f.silos[1].platforms[1].incoming,nil)
api.incoming,api.ammo,api.hub_chunks=nil,nil,nil
api.silos=function() return {} end
f=R.preflight(p,{})
eq(f.silos_pending,true); eq(#f.silos,0); eq(#f.platforms,2); assert(f.line:find('discovery pending',1,true))
api.silos=function() return {},90 end
f=R.preflight(p,{}); eq(f.silos_pending,nil); eq(f.silos_as_of,90)
api.remote_entity=old_remote; api.rocket=old_rocket; api.where=saved_where; p.force=saved_force
pl.space_location=nil; pl.schedule=nil; pl.state=nil; pl.paused=nil

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

-- 9. walk with from (Luna, shift14 21:20: 930 agricultural science packs from a provider 64 tiles from the silo took
-- four walks and several calls): one tour between the chest and the silo, as many trips as the load takes. The
-- tour is replayed here stop by stop as stock.lua walks it (each stop in reach on arrival).
-- A stop that holds (out.wait: the tour waits at the silo) is visited again 30 ticks later; on_wait(action, n) may
-- change the world, and returning true ends the replay with 'holding'.
local function tour(w,on_wait)
  local action=w.fields
  action.targets={}
  for i,e in ipairs(w.entities) do action.targets[i]={entity=e,position=e.position} end
  local i,stops,waits=1,{},0
  while action.targets[i] do
    local e=action.targets[i].entity
    stops[#stops+1]=e.name
    local out=R.walk_visit(p,action,e)
    if out.wait then
      waits=waits+1; game.tick=game.tick+30; stops[#stops]=nil
      if not on_wait or on_wait(action,waits) or waits>50 then return 'holding',action,stops end
    else i=i+1 end
    if out.stop then return out.stop,action,stops end
  end
  return 'ran out',action,stops
end
local provinv=Inv(48,{{'agricultural-science-pack',930}})
local provider={valid=true,name='passive-provider-chest',type='logistic-container',position={x=129.5,y=14.5},force='us',surface=surface}
provider.get_inventory=function(i) if i==1 then return provinv end end
api.sight_entity=function(_,pos) if pos.x==129.5 then return provider end return api.reach_entity(nil,pos) end
local takes={}
api.take=function(_,e,item,q,count)
  local inv=e.get_inventory(1)
  local n=math.min(count,inv.get_item_count{name=item,quality=q},main.room(item,q))
  inv.add(item,-n,q); main.add(item,n,q); takes[#takes+1]=n
  return {transferred=n,inventory_full=n<count and inv.get_item_count{name=item,quality=q}>0 or nil}
end
local kept_can=p.can_reach_entity
p.can_reach_entity=function(e) return e~=provider end
cargo.counts={}; cargo.order={}
main=Inv(2,{}); launched=nil
silo.rocket_silo_status=7
local w=R.walk_start(p,{position=S,items={['agricultural-science-pack']=930},from={x=129.5,y=14.5},walk=true,launch=true,platform='Sunward'})
eq(w.reply.op,'load_silo'); eq(w.reply.needs,'agricultural-science-pack 930 (you hold 0)')
eq(w.reply.chests,'passive-provider-chest (129.5,14.5) holds 930 agricultural-science-pack'); eq(w.reply.trip,'1 chest, then the silo')
eq(#w.entities,2); eq(w.entities[1],provider); eq(w.entities[2],silo)
local outcome,act,stops=tour(w)
eq(outcome,'launched'); eq(act.trips,3); eq(table.concat(takes,','),'400,400,130')
eq(table.concat(stops,','),'passive-provider-chest,rocket-silo,passive-provider-chest,rocket-silo,passive-provider-chest,rocket-silo')
eq(act.loaded,930); eq(act.taken,930); eq(cargo.counts['agricultural-science-pack@normal'],930); eq(provinv.counts['agricultural-science-pack@normal'],nil)
eq(launched.platform,'Sunward'); eq(act.rows[2].loaded,400); eq(act.rows[1].full,true)
local last={}
R.walk_last(act,last)
eq(last.trips,3); eq(last.loaded,930); eq(last.taken_items['agricultural-science-pack'],930); eq(#last.stops,6); eq(last.launch.launched,true)
-- What you hold counts: only the rest is taken. to_total: the count is what the rocket should hold.
cargo.counts={}; cargo.order={}; cargo.add('agricultural-science-pack',100)
provinv.add('agricultural-science-pack',500); main=Inv(4,{{'agricultural-science-pack',50}}); takes={}
w=R.walk_start(p,{position=S,items={['agricultural-science-pack']=300},to_total=true,from={x=129.5,y=14.5},walk=true})
eq(w.reply.needs,'agricultural-science-pack 200 (you hold 50)')
outcome,act=tour(w)
eq(outcome,'loaded'); eq(takes[1],150); eq(cargo.counts['agricultural-science-pack@normal'],300); eq(act.trips,1)
-- Held already: the silo only.
cargo.counts={}; cargo.order={}; main=Inv(4,{{'agricultural-science-pack',100}})
w=R.walk_start(p,{position=S,items={['agricultural-science-pack']=100},from={x=129.5,y=14.5},walk=true})
eq(#w.entities,1); eq(w.entities[1],silo)
-- Launch with the rocket not ready at the silo (Astra 06:23: the walking load put cargo in a rocket not yet ready, and
-- the silo's automatic requests took it out): the tour holds at the silo and loads nothing; once the rocket is ready
-- it loads and launches in that tick.
cargo.counts={}; cargo.order={}; main=Inv(4,{}); launched=nil
silo.rocket_silo_status=0
w=R.walk_start(p,{position=S,items={['agricultural-science-pack']=100},from={x=129.5,y=14.5},walk=true,launch=true,platform='Sunward'})
outcome,act=tour(w,function(action,n) return n>=3 end)
eq(outcome,'holding'); eq(launched,nil); eq(cargo.counts['agricultural-science-pack@normal'],nil,'nothing loaded before ready')
eq(main.counts['agricultural-science-pack@normal'],100)
eq(act.why,'waiting at the silo for the rocket to be ready (building the rocket: parts 20/50); nothing loaded yet')
eq(act.rows[#act.rows].why,'the rocket is not ready to launch yet: waiting at the silo, nothing loaded')
local hold_last={}; R.walk_last(act,hold_last); assert(hold_last.silo_wait and hold_last.silo_wait.gives_up_tick,'last.silo_wait while holding')
outcome,act=tour(w,function(action,n) if n==2 then silo.rocket_silo_status=7 end end)
eq(outcome,'launched'); eq(launched.platform,'Sunward'); eq(cargo.counts['agricultural-science-pack@normal'],100); eq(act.why,nil)
silo.rocket_silo_status=7
-- The chest runs out: short, naming what the rocket still needs and what the chest holds.
cargo.counts={}; cargo.order={}; main=Inv(4,{})
provinv.counts={}; provinv.order={}; provinv.add('agricultural-science-pack',120)
w=R.walk_start(p,{position=S,items={['agricultural-science-pack']=200},from={x=129.5,y=14.5},walk=true})
outcome,act=tour(w)
eq(outcome,'short'); eq(cargo.counts['agricultural-science-pack@normal'],120)
eq(act.why,'the rocket still needs agricultural-science-pack 80 (you hold 0): the chests in from hold no more of it (passive-provider-chest (129.5,14.5) holds 0 agricultural-science-pack)')
-- Nothing in the chest, nothing held: refused before any walk.
fails(function() R.walk_start(p,{position=S,items={['agricultural-science-pack']=10},from={x=129.5,y=14.5},walk=true}) end,
  'nothing walked: the rocket still needs agricultural-science-pack 10 (you hold 0) and the chests in from hold none of it (passive-provider-chest (129.5,14.5) holds 0 agricultural-science-pack)')
-- Full by weight: only what fits under the lift is taken (100 of 500), then short at the silo, no more trips; full
-- before any walk: refused.
cargo.counts={}; cargo.order={}; cargo.add('space-platform-foundation',45); main=Inv(10,{}); takes={}
provinv.add('agricultural-science-pack',500)
w=R.walk_start(p,{position=S,items={['agricultural-science-pack']=500},from={x=129.5,y=14.5},walk=true})
outcome,act=tour(w)
eq(outcome,'short'); eq(act.loaded,100); eq(act.trips,1); eq(takes[1],100); eq(provinv.counts['agricultural-science-pack@normal'],400)
eq(act.why,'the rocket still needs agricultural-science-pack 400 (you hold 0): none of it fits under the rocket\'s lift (it holds 1000/1000 kg)')
fails(function() R.walk_start(p,{position=S,items={['agricultural-science-pack']=5},from={x=129.5,y=14.5},walk=true}) end,
  'nothing walked: the rocket still needs agricultural-science-pack 5 (you hold 0) and none of it fits under its lift (it holds 1000/1000 kg)')
provinv.counts={}; provinv.order={}
-- No rocket at the silo on arrival: the tour waits there for one, as the load without walk does; what was taken stays
-- with you meanwhile.
cargo.counts={}; cargo.order={}; main=Inv(4,{}); silo.no_rocket=true; provinv.add('agricultural-science-pack',50)
w=R.walk_start(p,{position=S,items={['agricultural-science-pack']=50},from={x=129.5,y=14.5},walk=true})
outcome,act=tour(w,function(action,n) if n==2 then silo.no_rocket=nil end end)
eq(outcome,'loaded'); eq(cargo.counts['agricultural-science-pack@normal'],50)
silo.no_rocket=nil
-- up_to (Sonnet 07:50): short by weight, the walking load ends loaded and launches with what is aboard.
cargo.counts={}; cargo.order={}; cargo.add('space-platform-foundation',45); main=Inv(10,{}); takes={}; launched=nil
provinv.counts={}; provinv.order={}; provinv.add('agricultural-science-pack',500)
w=R.walk_start(p,{position=S,items={['agricultural-science-pack']=500},from={x=129.5,y=14.5},walk=true,up_to=true,launch=true,platform='Sunward'})
outcome,act=tour(w)
eq(outcome,'launched'); eq(act.loaded,100); eq(launched.platform,'Sunward')
eq(act.why,'up_to: the rocket still lacks agricultural-science-pack 400 (you hold 0): none of it fits under the rocket\'s lift (it holds 1000/1000 kg)')
provinv.counts={}; provinv.order={}
-- All in reach: nil (the load as without walk). The arguments.
p.can_reach_entity=kept_can
eq(R.walk_start(p,{position=S,items={['agricultural-science-pack']=1},from={x=129.5,y=14.5},walk=true}),nil)
fails(function() R.walk_start(p,{position=S,items={['agricultural-science-pack']=1},walk=true}) end,'walk goes with from')
fails(function() R.walk_start(p,{position=S,items={['agricultural-science-pack']=1},from={x=129.5,y=14.5},walk=true,chests=false}) end,'chests does not go with it')
fails(function() R.load(p,{position=S,items={['agricultural-science-pack']=1},avoid_enemies=false}) end,'avoid_enemies goes with walk=true')
print('rocketload ok')

-- Manifest: remote chest counts, qualities, duplicates, unrelated cargo and combined limits.
do
  local remote=api.remote_entity
  api.remote_entity=function(_,a) if a.position.x==60.5 then return cA elseif a.position.x==61.5 then return cB else return silo end end
  cargo.counts={};cargo.order={};chestA.counts={};chestA.order={};chestB.counts={};chestB.order={};main.counts={};main.order={}
  cargo.add('iron-plate',10); cargo.add('rocket-fuel',20)
  chestA.add('iron-plate',50); chestA.add('iron-plate',200,'rare'); chestB.add('iron-plate',20)
  main.add('iron-plate',5)
  local r=R.preflight(p,{position=S,items={['iron-plate']=100},from={cA.position,cA.position,cB.position}})
  eq(#r.from,2); eq(r.order[1].from_held,70); eq(r.order[1].from_short,20); eq(r.order[1].short,15)
  eq(r.manifest.kg,100);eq(r.manifest.slots,1);eq(r.manifest.after_kg,300);eq(r.manifest.after_slots,2);eq(r.manifest.fits,true)
  eq(chestA.get_item_count{name='iron-plate',quality='normal'},50,'read moves nothing')
  r=R.preflight(p,{position=S,items={{name='iron-plate',count=250,quality='rare'}},from=cA.position})
  eq(r.order[1].from_held,200);eq(r.order[1].short,50);eq(r.manifest.slots,3)
  r=R.preflight(p,{position=S,items={['iron-plate']=500,['agricultural-science-pack']=500}})
  eq(r.manifest.after_kg,1200);eq(r.manifest.fits,false,'items separately fit but together exceed lift')
  local limits=api.cargo.limits;api.cargo.limits=function() return 100000000,2 end
  r=R.preflight(p,{position=S,items={['iron-plate']=201}})
  eq(r.manifest.after_slots,4);eq(r.manifest.fits,false,'slots include unrelated cargo')
  api.cargo.limits=limits;api.remote_entity=remote
end

-- Slow part deliveries grow the idle window; polling alone never extends it.
do
  local oldtick,oldparts,oldstate,oldrocket=game.tick,silo.rocket_parts,silo.rocket_silo_status,silo.no_rocket
  game.tick=100;silo.rocket_parts=45;silo.rocket_silo_status=0;silo.no_rocket=true
  local w=R.wait_fields(silo,3600);w.position={x=65.5,y=14.5};w.launch=true
  local action={await_silo=w,until_tick=3700}
  eq(R.wait_report(action).parts_per_min,nil)
  game.tick=3100;silo.rocket_parts=46;eq(R.ready(p,action),false)
  eq(action.until_tick,12100);eq(R.wait_report(action).idle_window_s,150)
  eq(R.wait_report(action).parts_per_min,1.2)
  game.tick=7100;eq(R.ready(p,action),false);eq(action.until_tick,12100,'no part, no extension')
  game.tick=9100;silo.rocket_parts=47;R.ready(p,action)
  eq(action.until_tick,27100);eq(R.wait_report(action).parts_per_min,0.8)
  game.tick=10000;silo.rocket_parts=48;R.ready(p,action)
  eq(w.idle_ticks,18000,'a fast part does not erase the slow cadence')
  game.tick=w.give_up-5;silo.rocket_parts=49;R.ready(p,action)
  eq(action.until_tick,w.give_up,'absolute cap never moves');eq(w.give_up,216100)
  silo.rocket_parts=0;game.tick=game.tick+1;R.ready(p,action)
  eq(R.wait_report(action).parts_added,4,'counter rollover is not negative production and keeps the measured rate')
  assert(R.wait_report(action).parts_per_min>0,'rocket completion retains the rate')
  game.tick,silo.rocket_parts,silo.rocket_silo_status,silo.no_rocket=oldtick,oldparts,oldstate,oldrocket
end
