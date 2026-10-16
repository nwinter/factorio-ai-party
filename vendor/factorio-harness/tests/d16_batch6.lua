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
