-- d16 batch6 (operator 09:45, agents' requests 06:20-09:37). Run from the harness root: lua tests/d16_batch6.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- A1 (Sol, Astra 06:21-09:37: Tern's endurance read 42 rockets while 344 more sat on about 310 belt tiles; 15 minutes
-- of needless rescue design): platform_endurance counts the stock in every place aboard (hub, turrets, belts with an
-- underground pair once, inserter hands, machines' outputs), says what moved between places since the leg began apart
-- from what was used, and grows the ingredient ceiling at the rate its ingredients are made aboard (Astra 07:51), with
-- the asteroid chunks collected.
do
  defines={flow_precision_index={ten_minutes=2,five_seconds=0},inventory={hub_main=1,turret_ammo=1,assembling_machine_input=2}}
  prototypes={item={rocket={type='ammo'},explosives={type='item'},['iron-plate']={type='item'},['metallic-asteroid-chunk']={type='item'}},
    fluid={},space_location={aquilo={solar_power_in_space=60},fulgora={solar_power_in_space=120}},
    space_connection={a={from={name='aquilo'},to={name='fulgora'},length=30000}}}
  game={tick=20*3600}
  local function inv(t) return {get_contents=function() local out={} for n,c in pairs(t) do out[#out+1]={name=n,count=c,quality='normal'} end table.sort(out,function(a,b) return a.name<b.name end) return out end} end
  local function line(t) local l={}; l.get_contents=function() return inv(t).get_contents() end; l.line_equals=function(o) return o==l end; return l end
  local hub_items={rocket=30,explosives=10,['iron-plate']=4}
  local hub=setmetatable({get_contents=function() return inv(hub_items).get_contents() end,count_empty_stacks=function() return 8 end},{__len=function() return 40 end})
  local turret={type='ammo-turret',get_inventory=function() return inv({rocket=12}) end}
  -- 344 rockets on belts: 86 belts of 4, and an underground pair whose output reports the input's buried lines too.
  local belts={}
  local belt_rockets=4
  for i=1,85 do belts[i]={type='transport-belt',get_max_transport_line_index=function() return 2 end,
    get_transport_line=function(k) return k==2 and line({rocket=belt_rockets}) or line({}) end} end
  local buried=line({rocket=4})
  local ug_in={type='underground-belt',valid=true,belt_to_ground_type='input',get_max_transport_line_index=function() return 4 end,
    get_transport_line=function(k) return k==4 and buried or line({}) end}
  local ug_out={type='underground-belt',valid=true,belt_to_ground_type='output',neighbours=ug_in,get_max_transport_line_index=function() return 4 end,
    get_transport_line=function(k) return k==4 and buried or line({}) end}
  belts[#belts+1]=ug_in; belts[#belts+1]=ug_out
  local hand={type='inserter',held_stack={valid_for_read=true,name='rocket',count=2}}
  -- rockets from 1 explosive and 2 iron plates a craft; the plates come from furnaces (no assembler of the plate)
  local maker={type='assembling-machine',get_recipe=function() return {name='rocket',products={{name='rocket',amount=1}},
    ingredients={{type='item',name='explosives',amount=1},{type='item',name='iron-plate',amount=2}}} end,
    get_inventory=function() return inv({}) end,get_output_inventory=function() return inv({rocket=1}) end,fluidbox={}}
  local surface={find_entities_filtered=function(f)
    if f.type=='ammo-turret' then return {turret} elseif f.type=='inserter' then return {hand} elseif f.type=='assembling-machine' then return {maker}
    elseif type(f.type)=='table' and f.type[1]=='transport-belt' then return belts
    elseif type(f.type)=='table' and f.type[1]=='assembling-machine' then return {maker} end
    return {} end}
  -- per minute over the window: made, used
  local items={rocket={6,10},explosives={3,0},['iron-plate']={20,0},['metallic-asteroid-chunk']={12,0}}
  local function stats(t) return {get_flow_count=function(a) local r=t[a.name]; return r and (a.category=='input' and r[1] or r[2])*10 or 0 end} end
  local force={get_item_production_statistics=function() return stats(items) end,get_fluid_production_statistics=function() return stats({}) end}
  local pl={name='Tern',surface=surface,force=force,hub={valid=true,get_inventory=function() return hub end},speed=25/60,space_connection={},
    schedule={current=2,records={{station='aquilo'},{station='fulgora'}}}}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return {} end}
  -- the leg began 12 minutes ago with 370 rockets in the hub and 4 on the belts: 340 were moved from the hub to belts since
  hub_items.rocket=370; belt_rockets=0
  local places0=F.places_snapshot(pl)
  hub_items.rocket=30; belt_rockets=4
  local segs={{kind='leg',from='aquilo',to='fulgora',start=8*3600,ammo0={rocket={made=0,used=0}},places0=places0}}
  local leg={from='aquilo',to='fulgora',left_km=15000}
  local E=dofile('mod/agent-harness_0.1.0/endurance.lua'){platform=function() return pl end,leg=function() return leg end,segments=function() return segs end,
    ammo_counts=function() return {rocket={made=72,used=120}} end,stock_places=F.stock_places,places_text=F.places_text,moved_text=F.moved_text}
  local r=E.read({},{platform='Tern'})
  local rk
  for _,x in ipairs(r.resources) do if x.name=='rocket' then rk=x end end
  eq(rk.stock,30+12+344+2+1,'hub, turrets, belts (the pair once), hands, the maker\'s output')
  eq(rk.by_place.belts,344); eq(rk.by_place.hub,30); eq(rk.by_place.turrets,12); eq(rk.by_place.hands,2); eq(rk.by_place.machines,1)
  has(rk.line,'rocket: 389 now (hub 30, turrets 12, belts 344, hands 2, machines 1), made 6/min, used 10/min (last 10 min, flying)')
  has(rk.line,'; since this leg began: hub -340, belts +340')
  -- the ceiling: 2 more now (4 plates, 2 a craft), growing with the plates made aboard (20/min: 10 rockets' worth) until the
  -- 10 explosives and the 3 made a minute bind
  local cap=rk.ingredient_limited
  eq(cap.more,2); eq(cap.item,'iron-plate'); eq(cap.ingredient_made_per_min,20); eq(cap.more_per_min,3.1)
  has(rk.line,'the ingredients aboard make at most 2 more now (iron-plate 4 aboard, 2 a craft; iron-plate made 20/min aboard), and about 3.1 more a minute at the rates its ingredients are made aboard now')
  -- made 6/min while the ceiling allows (10 explosives and 3 more a minute bind after about 3 min): 399 - 7t, gone at 57 min
  eq(rk.lasts_min,56.9)
  has(r.lines[3],'asteroid chunks collected: metallic-asteroid-chunk 12/min')
  eq(r.chunks_collected[1],'metallic-asteroid-chunk 12/min')
  prototypes,defines=nil,nil
end
print('d16_batch6 A1 endurance stock by place: ok')

-- A6 (Luna 07:50: a queued wait_until platform_arrived with no timeout timed out at 60 s with the ETA at 77 s): with no
-- timeout a platform wait goes on while its ETA is known, to the ETA plus a quarter and 10 s, at most 54000 ticks.
do
  game={tick=0}
  local W=dofile('mod/agent-harness_0.1.0/waiteta.lua'){state=function() return {} end,check=function() return false,'x' end}
  local st={}
  local players={[1]={index=1}}
  local arrived=false
  local factory=dofile('mod/agent-harness_0.1.0/scheduler.lua')
  local S=factory{state=function() return st end,player=function(i) return players[i] end,handlers={craft=function() return {} end},
    busy=function() return false end,stop=function() end,stop_index=function() end,validate_condition=function() end,
    wait_check=function(_,c,record)
      record.wait_estimates={{condition=c['until'],eta_s=77,line='ETA 77s'}}
      return arrived,arrived and 'Swift at nauvis' or 'Swift flying'
    end,
    extend_wait=function(step,c,started) return W.extend(step,c,started) end}
  local function run(n) for _=1,n do game.tick=game.tick+1; S.tick() end end
  S.handlers.queue_submit(players[1],{steps={{action='wait_until',args={['until']='platform_arrived',platform='Swift'}},{action='craft'}}})
  run(3700)
  local q=st.queues[1]
  assert(q.current and q.current.action=='wait_until','still waiting past the default 3600 ticks')
  has(q.current.extended,'no timeout given: extended to the ETA 77s')
  eq(q.current.until_tick>=3600+77*60,true)
  arrived=true; run(40)
  eq(q.current,nil); eq(q.history[1].result.outcome,'met')
  -- A timeout given is kept.
  arrived=false
  S.handlers.queue_submit(players[1],{steps={{action='wait_until',args={['until']='platform_arrived',platform='Swift',timeout=600}}}})
  run(700)
  eq(q.current,nil); eq(q.history[#q.history].result.outcome,'timed_out')
  -- Other conditions keep the default.
  eq(W.extend({wait_estimates={{eta_s=10}}},{['until']='item_count'},0),nil)
end
print('d16_batch6 A6 platform waits past the default timeout: ok')

-- B1 (Opus 06:33: wake only on named teammates; Sonnet 06:20: not on operator and automatic tells): wake_from and
-- wake_on_operator choose which tells and mentions end a sleep or a direct wait.
do
  game={tick=100}
  local st={mentions={[1]={list={},dropped=0}}}
  local B=dofile('mod/agent-harness_0.1.0/board.lua'){state=function() return st end}
  local box=st.mentions[1].list
  box[1]={tell=1,tick=10,from='sol',text='a'}
  box[2]={tell=2,tick=20,from='operator',text='live now'}
  box[3]={tell='reminder',tick=30,from='reminder #4',text='review'}
  eq(B.inbox_tick(1),30,'any tell ends a wait by default')
  local f=B.wake_filter({wake_on_operator=false})
  eq(B.inbox_tick(1,nil,f),10,'operator and reminder tells skipped')
  f=B.wake_filter({wake_from={'Astra','sol'}})
  eq(B.inbox_tick(1,nil,f),10)
  f=B.wake_filter({wake_from={'astra'}})
  eq(B.inbox_tick(1,nil,f),nil,'none from astra')
  f=B.wake_filter({wake_from='operator'})
  eq(B.inbox_tick(1,nil,f),20)
  eq(B.wake_filter({}),nil)
  assert(not pcall(B.wake_filter,{wake_from={}}),'1..16 names')
  assert(not pcall(B.wake_filter,{wake_on_operator='no'}))
end
print('d16_batch6 B1 who wakes a wait: ok')

-- B2 (Opus 06:33: a handoff waited a 6-minute round): queue_submit mode next runs a one-off step right after the active
-- step of a repeating plan, which goes on; the loop is kept and the step is not repeated.
do
  game={tick=0}
  local st={}
  local players={[1]={index=1}}
  local calls,active={},{}
  local handlers={walk=function(p,a) active[p.index]=game.tick+(a.ticks or 3); calls[#calls+1]='walk'; return {} end,
    craft=function() calls[#calls+1]='craft'; return {} end,give=function() calls[#calls+1]='give'; return {} end}
  local S=dofile('mod/agent-harness_0.1.0/scheduler.lua'){state=function() return st end,player=function(i) return players[i] end,handlers=handlers,
    busy=function(p,action) return action=='walk' and active[p.index]~=nil end,stop=function(p) active[p.index]=nil end,stop_index=function(i) active[i]=nil end,
    condition=function() return false end,validate_condition=function() end}
  local function run(n) for _=1,n do game.tick=game.tick+1; for i,e in pairs(active) do if game.tick>=e then active[i]=nil end end; S.tick() end end
  S.handlers.queue_repeat(players[1],{name='round',interval_ticks=600,steps={{action='walk',args={ticks=10}},{action='craft'}}})
  run(2); eq(calls[1],'walk')
  local out=S.handlers.queue_submit(players[1],{mode='next',steps={{action='give'}}})
  has(st.queues[1].submission,'new steps run once right after the active step')
  run(12)
  eq(table.concat(calls,','),'walk,give,craft','the walk goes on, then the one-off step, then the round')
  eq(st.queues[1].loop~=nil,true,'the loop is kept')
  run(700)
  eq(table.concat(calls,','),'walk,give,craft,walk,craft','the next round has no give')
end
print('d16_batch6 B2 queue_submit mode next: ok')

-- C3 found on the copy: a courier whose take place is never reached gave from the character's inventory anyway; now it
-- ends unreached with nothing given.
do
  game={tick=0}
  local api={distance=function(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end,request_path=function() end,
    navigate=function() return 'unreachable' end,stop_walking=function() end}
  local given=0
  api.visit=function() given=given+1; return {transferred=1} end
  local S=dofile('mod/agent-harness_0.1.0/stock.lua')(api)
  local p={position={x=0,y=0},reach_distance=10,can_reach_entity=function() return false end}
  local a1,a2={valid=true,position={x=50,y=0}},{valid=true,position={x=60,y=0}}
  local legs=S.start_legs(p,{{entity=a1,position=a1.position},{entity=a2,position=a2.position}},600,{legs={{},{}},item='iron-stick',rows={},items={}})
  local out
  for _=1,5 do out=S.tick(p,legs); if out then break end end
  eq(out,'unreached'); eq(given,0,'no give without the take')
end
print('d16_batch6 C3 courier take unreached: ok')

-- D3 (Luna 06:20: 23 nutrients reserved across 14 requesters, 245 short, 44 robots idle; chests full of seeds): a
-- network's reservations, read only, flagged when robots sit idle or a target has no room.
do
  defines={inventory={chest=1}}
  prototypes={item={nutrients={},seeds={}}}
  local function inv(t,free)
    return {get_item_count=function(n) return t[n] or 0 end,count_empty_stacks=function() return free end,can_insert=function() return free>0 end}
  end
  local provider={valid=true,name='passive-provider-chest',type='logistic-container',unit_number=1,position={x=0.5,y=0.5}}
  local full={valid=true,name='requester-chest',type='logistic-container',unit_number=2,position={x=10.5,y=0.5},get_inventory=function() return inv({nutrients=0,seeds=4800},0) end}
  local ok={valid=true,name='requester-chest',type='logistic-container',unit_number=3,position={x=20.5,y=0.5},get_inventory=function() return inv({nutrients=5},10) end}
  local robot={valid=true,robot_order_queue={{target_item={name='nutrients'},target_count=4,target=full}}}
  local ln={network_id=7,available_logistic_robots=44,all_logistic_robots=60,logistic_robots={robot},
    provider_points={{owner=provider,targeted_items_pickup={{name='nutrients',count=23}}}},storage_points={},
    requester_points={{owner=full,targeted_items_deliver={{name='nutrients',count=4}},filters={{name='nutrients',count=200}}},
      {owner=ok,targeted_items_deliver={},filters={{name='nutrients',count=50}}}}}
  local p={surface={name='gleba'},force={logistic_networks={gleba={ln}}}}
  local R=dofile('mod/agent-harness_0.1.0/reservations.lua'){}
  local r=R.read(p,{network=7,item='nutrients'})
  eq(r.reserved_for_pickup,23); eq(r.idle,44)
  eq(r.flags[1],'23 reserved for pickup while 44 of 60 logistic robots are idle')
  eq(r.flags[2],'1 robot order goes to a chest with no room for the item')
  eq(r.flags[3],'1 requester with deliveries on the way and no room for them')
  eq(r.pickups[1],'passive-provider-chest (0.5,0.5): nutrients 23 reserved for pickup')
  eq(r.requesters[1],'requester-chest (10.5,0.5): nutrients asks 200, holds 0, 4 on the way (no room for it: every slot taken); 0 free slots')
  eq(r.requesters[2],'requester-chest (20.5,0.5): nutrients asks 50, holds 5, 0 on the way; 10 free slots')
  eq(r.robots[1],'1 robot with 4 nutrients for requester-chest (10.5,0.5): its target has no room for it (every slot taken)')
  assert(not pcall(R.read,p,{network=8}),'no such network')
  prototypes,defines=nil,nil
end
print('d16_batch6 D3 reservations: ok')
