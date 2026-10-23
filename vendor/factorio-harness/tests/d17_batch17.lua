-- Run from the harness root: lua tests/d17_batch17.lua
-- d17 batch17 module contracts (the runtime ones are in tests/d17_batch17_rt.lua).
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..'\n  lacks: '..part) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path

-- A1: what goes up beside a load: cargo aboard not in the list, and automatic requests on.
do
  defines={inventory={rocket_silo_rocket=21}}
  prototypes={item={['gun-turret']={weight=20000,stack_size=50},['solid-fuel']={weight=1000,stack_size=50},['iron-plate']={weight=1000,stack_size=100}}}
  game={tick=0}
  local cargo={get_contents=function() return {{name='gun-turret',quality='normal',count=1},{name='solid-fuel',quality='normal',count=10}} end}
  local silo={valid=true,use_transitional_requests=true,get_inventory=function(i) if i==21 then return cargo end end}
  local R=dofile('mod/agent-harness_0.1.0/rocketload.lua'){}
  local up=R.goes_up_with(silo,{{name='solid-fuel',quality='normal',count=10}})
  eq(up.foreign,'gun-turret 1')
  has(up.auto_requests,'automatic requests are on')
  has(up.line,'aboard and not in this load, goes up with it: gun-turret 1; automatic requests are on')
  silo.use_transitional_requests=false
  up=R.goes_up_with(silo,{{name='gun-turret',count=1},{name='solid-fuel',count=10}})
  eq(up.line,nil,'nothing foreign, requests off')
end
print('d17_batch17 A1 what goes up with a load: ok')

-- A4 (Sol 10:56: salvage on Meridian took 26 tiles under underground pipe spans and cut propulsion): salvage keeps
-- every tile an underground belt or pipe-to-ground span passes under, paired as the floor plan pairs them.
do
  game={tick=0}
  prototypes={entity={['pipe-to-ground']={fluidbox_prototypes={{pipe_connections={{},{max_underground_distance=10}}}}},
    ['underground-belt']={max_underground_distance=5}}}
  local tiles={}
  for x=0,9 do for y=0,9 do tiles[#tiles+1]={position={x=x,y=y}} end end
  local function ent(t,name,x,y,dir,io) return {valid=true,type=t,name=name,position={x=x,y=y},direction=dir,belt_to_ground_type=io,
    bounding_box={left_top={x=x-.4,y=y-.4},right_bottom={x=x+.4,y=y+.4}}} end
  -- a pipe tunnel along the edge column x=9, from (9.5,0.5) south to (9.5,6.5); each faces its pipe, outward
  local ents={ent('pipe-to-ground','pipe-to-ground',9.5,0.5,0),ent('pipe-to-ground','pipe-to-ground',9.5,6.5,8)}
  local s={find_tiles_filtered=function() return tiles end,find_entities_filtered=function(f)
    if f.type=='tile-ghost' then return {} end
    if type(f.type)=='table' then local out={} for _,e in ipairs(ents) do for _,t in ipairs(f.type) do if e.type==t then out[#out+1]=e end end end return out end
    return ents
  end}
  local PP=dofile('mod/agent-harness_0.1.0/platplan.lua'){}
  local taken=PP.salvage(s,{},{position={x=0.5,y=0.5},valid=true},100)
  assert(#taken>0,'some tiles go')
  for _,t in ipairs(taken) do assert(not (t.x==9 and t.y>=1 and t.y<=5),'a tile under the pipe span was taken: ('..t.x..','..t.y..')') end
  for _,t in ipairs(taken) do assert(not (t.x==9 and (t.y==0 or t.y==6)),'an endpoint tile was taken') end
end
print('d17_batch17 A4 salvage keeps tiles under underground pipe spans: ok')

-- A5 (Astra, board #842: Swift's reserve tanks had no departure guard): wait_until fluid_count and circuit_signal on a
-- platform, and platform_schedule's conditions in the forms circuit_set takes.
do
  defines={wire_connector_id={circuit_red=1,circuit_green=2},inventory={hub_main=1}}
  prototypes={item={['iron-plate']={}},fluid={['thruster-fuel']={},water={}},virtual_signal={['signal-A']={}}}
  game={tick=0}
  local tanks={{type='storage-tank',get_fluid_count=function(f) return f=='thruster-fuel' and 6000 or 0 end},{type='storage-tank',get_fluid_count=function(f) return f=='thruster-fuel' and 5000 or 0 end}}
  local red={get_signal=function(s) return s.name=='thruster-fuel' and 11000 or 0 end}
  local hub={valid=true,get_circuit_network=function(id) return id==1 and red or nil end}
  local swift={valid=true,name='Swift',hub=hub,surface={find_entities_filtered=function(f) assert(type(f.type)=='table'); return tanks end}}
  local p={force={platforms={swift}}}
  local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){}
  C.validate({['until']='fluid_count',platform='Swift',fluid='thruster-fuel',at_least=10000})
  local met,saw=C.check(p,{['until']='fluid_count',platform='Swift',fluid='thruster-fuel',at_least=10000})
  eq(met,true); has(saw,"thruster-fuel 11000 on Swift: tanks 11000 (2)")
  -- batch28 A4 (Sol: full propellant in pipes and thrusters, and a tank gate would wait forever): every fluidbox counts
  tanks[3]={type='pipe',get_fluid_count=function(f) return f=='thruster-fuel' and 100 or 0 end}
  tanks[4]={type='thruster',get_fluid_count=function(f) return f=='thruster-fuel' and 1000 or 0 end}
  met,saw=C.check(p,{['until']='fluid_count',platform='Swift',fluid='thruster-fuel',at_least=12000})
  eq(met,true); has(saw,'thruster-fuel 12100 on Swift: tanks 11000 (2), pipes 100 (1), thrusters 1000 (1)')
  tanks[3],tanks[4]=nil,nil
  met=C.check(p,{['until']='fluid_count',platform='Swift',fluid='thruster-fuel',at_least=12000})
  eq(met,false)
  met,saw=C.check(p,{['until']='circuit_signal',platform='Swift',signal='thruster-fuel',at_least=10000})
  eq(met,true); has(saw,"thruster-fuel 11000 on Swift's hub (red)")
  assert(not pcall(C.validate,{['until']='fluid_count',platform='Swift',fluid='iron-plate',at_least=1}),'a fluid name')
  assert(not pcall(C.validate,{['until']='circuit_signal',platform='Swift',signal='nonsense',at_least=1}),'a known signal')
  hub.get_circuit_network=function() return nil end
  met,saw=C.check(p,{['until']='circuit_signal',platform='Swift',signal='thruster-fuel',at_least=1})
  -- (d22 batch118 CA1: as the game reads an unwired hub, every signal 0)
  eq(met,false); has(saw,"Swift's hub has no red or green wire: thruster-fuel reads 0 there, as the game's own circuit conditions read an unwired hub (never met while it has none)")
end
print('d17_batch17 A5 fluid_count and circuit_signal waits: ok')

-- A6 (Gemini 10:56): platform_bom {surface}: every platform's active requests importing from that planet, short ones.
do
  defines={inventory={hub_main=1}}
  prototypes={space_location={gleba={},nauvis={}},item={}}
  local function hub(held, filters)
    return {valid=true,get_inventory=function() return {get_item_count=function(n) n=type(n)=='table' and n.name or n; return held[n] or 0 end} end,
      get_logistic_sections=function() return {sections_count=1,get_section=function() return {active=true,filters=filters} end} end}
  end
  local swift={valid=true,name='Swift',space_location={name='nauvis'},hub=hub({['agricultural-science-pack']=120},{
    {value={name='agricultural-science-pack'},min=500,import_from={name='gleba'}},{value={name='bioflux'},min=40,import_from='gleba'},
    {value={name='processing-unit'},min=50,import_from={name='nauvis'}}})}
  local wren={valid=true,name='Wren',space_location={name='gleba'},hub=hub({bioflux=40},{{value={name='bioflux'},min=40,import_from={name='gleba'}}})}
  local B=dofile('mod/agent-harness_0.1.0/platbom.lua'){}
  local r=B.read({force={platforms={swift,wren}}},{surface='gleba'})
  eq(#r.requests,3,'nauvis requests left out')
  eq(r.lines[1],'Swift (at nauvis) lacks from gleba: agricultural-science-pack 380 (asks 500, holds 120), bioflux 40 (asks 40, holds 0)')
  eq(#r.lines,1,'Wren holds what it asks')
  assert(not pcall(B.read,{force={platforms={}}},{surface='nowhere'}),'a planet')
end
print('d17_batch17 A6 platform_bom by surface: ok')

-- B1 (Haiku: a rearm walked into attack #5203 at the guns it went to): an attack that starts at a tour's stop while the
-- walk is under way holds the walk short until the attack has had no hit for 30 s, then it goes on; said in held_short.
do
  game={tick=0}
  local function distance(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end
  local function integer(v,d) return v or d end
  local f={is_chunk_visible=function() return true end}
  local p={force=f,position={x=0,y=0},reach_distance=10}
  p.can_reach_entity=function(e) return distance(p.position,e.position)<=10 end
  local turret={valid=true,type='ammo-turret',name='gun-turret',force=f,position={x=76,y=-191}}
  local attack
  local stopped,navs=0,0
  local S=dofile('mod/agent-harness_0.1.0/stock.lua'){distance=distance,integer=integer,
    goal_inside=function() return nil end,
    goal_check=function(_,_,to) if attack and (attack.only==nil or attack.only==to.x) then return attack end end,goal_text=function(_,to) return 'place' end,
    visit=function() return {transferred=10} end,
    request_path=function(_,nav) nav.requested=true end,navigate=function() navs=navs+1 end,stop_walking=function() stopped=stopped+1 end}
  -- (batch35 A3: a rearm skips such a stop and goes on; a feed holds short, as below)
  local action=S.start_tour(p,'feed',{turret},3600,{avoid_mode={}})
  local function step() game.tick=game.tick+1; return S.tick(p,action) end
  step(); assert(action.nav and action.nav.requested,'walking')
  -- the attack starts at the guns while the walk is under way
  attack={m={attack=true,name='attack #5203',x=70,y=-185}}
  for _=1,61 do step() end
  assert(action.holding,'held')
  has(action.held_short,'the stop (76,-191) is in attack #5203 at (70,-185), under attack now; the walk goes on when it has had no hit for 30 s')
  eq(stopped,1,'stopped walking once')
  local before=navs
  for _=1,30 do step() end
  eq(navs,before,'no walking while held')
  -- the attack over: the walk goes on (a new path)
  attack=nil
  for _=1,61 do step() end
  eq(action.holding,nil); eq(action.held_short,nil)
  p.position={x=74,y=-188}
  local r
  for _=1,5 do r=step(); if r then break end end
  eq(r,'topped_up')
  -- (batch35 A3, Haiku) a rearm skips the stop under attack, names it, and goes on to the next
  local turret2={valid=true,type='ammo-turret',name='gun-turret',force=f,position={x=300,y=0}}  -- (the tour goes nearest first)
  p.position={x=0,y=0}; attack=nil; stopped=0
  action=S.start_tour(p,'rearm',{turret,turret2},3600,{avoid_mode={}})
  step()
  attack={m={attack=true,name='attack #5203',x=70,y=-185},only=76}
  for _=1,61 do step() end
  eq(action.holding,nil); eq(action.index,2); eq(action.unreached,1); eq(stopped,1)
  has(action.skipped_attack[1],'place')
  has(action.first_unreached,'(76,-191): place (skipped; unsafe_goal: "moving" walks there)')
  -- unsafe_goal "moving": a stop whose only threats move is walked to
  attack=nil
  action=S.start_tour(p,'rearm',{turret},3600,{avoid_mode={},unsafe_goal='moving'})
  step()
  attack={m={attack=true,name='attack #5203',x=70,y=-185},moving_only=true}
  for _=1,61 do step() end
  eq(action.index,1); eq(action.skipped_attack,nil); eq(action.holding,nil)
  -- one a worm holds is left out on arrival at the leg, "moving" or not
  attack={m={name='big-worm-turret',x=80,y=-190},moving_only=false}
  action=S.start_tour(p,'rearm',{turret},3600,{avoid_mode={},unsafe_goal='moving'})
  step(); eq(action.unreached,1); has(action.first_unreached,'unsafe_goal: true walks there')
end
print('d17_batch17 B1 a tour holds short of a live attack at its stop: ok')

-- B2 (Haiku ~6x: turrets in solar-panel pockets said only "no path request found a way"): an unreachable stop names
-- the fewest of our entities to mine for a way, as move_to does.
do
  game={tick=0}
  local function distance(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end
  local f={is_chunk_visible=function() return true end}
  local p={force=f,position={x=120,y=-80},reach_distance=10}
  p.can_reach_entity=function(e) return distance(p.position,e.position)<=10 end
  local turret={valid=true,type='ammo-turret',name='gun-turret',force=f,position={x=143,y=-85}}
  local asked
  local S=dofile('mod/agent-harness_0.1.0/stock.lua'){distance=distance,integer=function(v,d) return v or d end,
    request_path=function(_,nav) nav.requested=true end,
    navigate=function(_,nav) nav.why='no path request found a way for the character to (143,-85), nor to anywhere within 4 tiles of it'; nav.reachable={x=139.5,y=-80.5}; return 'unreachable' end,
    stop_walking=function() end,
    corridor=function(_,from,goal,near) asked={from=from,goal=goal,near=near}
      return {mine={{name='solar-panel',position={x=141,y=-82}},{name='solar-panel',position={x=141,y=-85}}},from={x=139.5,y=-80.5},to={x=141.6,y=-85}} end}
  local action=S.start_tour(p,'rearm',{turret},3600,{})
  local r
  for _=1,3 do game.tick=game.tick+1; r=S.tick(p,action); if r then break end end
  has(action.first_unreached,'(143,-85): unreachable: no path request found a way')
  has(action.first_unreached,'mining solar-panel (141,-82) and solar-panel (141,-85) opens a way from (139.5,-80.5) to (141.6,-85.0)')
  eq(asked.from.x,139.5,'from the nearest reachable point')
  eq(#action.mine_for_a_way,2)
end
print('d17_batch17 B2 an unreachable tour stop names what to mine: ok')

-- C1 (Opus, every shift: a 2-tile gap at (422.5,-249) idled 10 drills unnoticed): a long belt or pipe line cut is a
-- team alert naming the cut tiles; a short one is not; one rebuilt is gone; a second death beside it joins it.
do
  game={tick=100}
  local st={}
  local L=dofile('mod/agent-harness_0.1.0/linecut.lua'){state=function() return st end}
  local function belt(y) local b={valid=true,type='transport-belt',name='transport-belt',position={x=422.5,y=y},unit_number=1000+y*-1,
    get_max_transport_line_index=function() return 2 end,get_transport_line=function() return {get_contents=function() return {{name='iron-ore',count=4}} end} end}
    return b end
  local line={}
  for y=-235,-262,-1 do line[#line+1]=belt(y+0.5) end
  for i,b in ipairs(line) do b.belt_neighbours={inputs={line[i-1]},outputs={line[i+1]}} end
  local built={}
  for _,b in ipairs(line) do built[b.position.y]=true end
  local surface={name='nauvis',find_entities_filtered=function(f) if built[f.position[2]] then return {{valid=true}} end return {} end}
  game.get_surface=function() return surface end
  for _,b in ipairs(line) do b.surface=surface; b.force={name='player'}; b.last_user={name='opus'} end
  local gap=line[15]   -- (422.5,-248.5)
  L.note({entity=gap,tick=100,cause={valid=true,name='big-biter'}}); built[gap.position.y]=nil
  L.note({entity=line[16],tick=101,cause={valid=true,name='big-biter'}}); built[line[16].position.y]=nil
  eq(#st.linecut.cuts,1,'the second death joins the cut')
  game.tick=101+1800
  local gs=L.alert_groups({name='player'})
  eq(#gs,1)
  has(gs[1].line,'belt line cut at (422.5,-248.5), (422.5,-249.5): 2 tiles gone (2 by big-biter), 30s ago, none rebuilt')
  has(gs[1].line,'the line runs 14 tiles to (422.5,-234.5) on one side, 13 tiles to (422.5,-261.5) on the other; it carried iron-ore')
  eq(gs[1].by.opus,1,'who built it hears it')
  -- rebuilt: gone
  built[gap.position.y]=true; built[line[16].position.y]=true
  eq(#L.alert_groups({name='player'}),0)
  -- a short line: no alert
  local a,b,c=belt(0.5),belt(1.5),belt(2.5)
  a.belt_neighbours={inputs={},outputs={b}}; b.belt_neighbours={inputs={a},outputs={c}}; c.belt_neighbours={inputs={b},outputs={}}
  for _,x in ipairs({a,b,c}) do x.surface=surface; x.force={name='player'} end
  L.note({entity=b,tick=200})
  eq(#st.linecut.cuts,0,'3 tiles is no long line')
end
do
  game={tick=10}
  local st={}
  local L=dofile('mod/agent-harness_0.1.0/linecut.lua'){state=function() return st end}
  local surface={name='nauvis',find_entities_filtered=function() return {} end}
  game.get_surface=function() return surface end
  local pipes={}
  for i=1,12 do pipes[i]={valid=true,type='pipe',name='pipe',position={x=-200.5+i,y=-300.5},unit_number=2000+i,surface=surface,force={name='player'},
    fluidbox={{name='crude-oil',amount=50}}} end
  for i,pp in ipairs(pipes) do pp.neighbours={{pipes[i-1],pipes[i+1]}} end
  L.note({entity=pipes[6],tick=10})
  game.tick=70
  local gs=L.alert_groups({name='player'})
  eq(#gs,1)
  has(gs[1].line,'pipe line cut at (-194.5,-300.5): 1 tile gone, 1s ago, none rebuilt; the line runs 5 tiles to (-199.5,-300.5) on one side, 6 tiles to (-188.5,-300.5) on the other; it carried crude-oil')
end
print('d17_batch17 C1 a long belt line cut is a team alert: ok')

-- C2 (Luna, shift29: paged 109 requester chests to find 5 spoilage-only blockers): logistics_audit ranks a network's
-- requesters by what keeps them short, with the network's free stock and the provider robots would take it from.
do
  defines={inventory={chest=1}}
  game={tick=40000}
  local function inv(contents,slots)
    local used=0
    for _,c in ipairs(contents) do used=used+math.ceil(c.count/50) end
    local t={get_contents=function() return contents end,count_empty_stacks=function() return slots-used end,
      can_insert=function(x) return used<slots end}
    return setmetatable(t,{__len=function() return slots end})
  end
  local units=0
  local function chest(x,y,contents,slots)
    units=units+1
    local i=inv(contents,slots)
    local e={valid=true,type='logistic-container',name='requester-chest',unit_number=units,position={x=x,y=y},
      get_inventory=function() return i end}
    e.get_item_count=function(q) local n=0 for _,c in ipairs(contents) do if c.name==q.name then n=n+c.count end end return n end
    return e
  end
  local function point(e,filters,coming) return {owner=e,filters=filters,targeted_items_deliver=coming or {}} end
  local provider=chest(10.5,0.5,{{name='nutrients',quality='normal',count=400}},48); provider.name='passive-provider-chest'
  local full=chest(74.5,62.5,{{name='spoilage',quality='normal',count=2400}},48)
  local rotten=chest(4.5,10.5,{{name='spoilage',quality='normal',count=100},{name='nutrients',quality='normal',count=10}},48)
  local waiting=chest(-6.5,26.5,{},48)
  local unsent=chest(20.5,0.5,{},48)
  local short=chest(15.5,53.5,{},48)
  local done=chest(0.5,0.5,{{name='nutrients',quality='normal',count=10}},48)
  local ch={owner={valid=true,type='character'},filters={{name='iron-plate',count=100}}}
  local ln={network_id=98,requester_points={
    point(short,{{name='processing-unit',quality='normal',count=20}}),
    point(waiting,{{name='iron-bacteria',quality='normal',count=3}},{{name='iron-bacteria',quality='normal',count=3}}),
    point(unsent,{{name='nutrients',quality='normal',count=10}}),
    point(full,{{name='yumako-mash',quality='normal',count=60},{name='nutrients',quality='normal',count=10}}),
    point(rotten,{{name='nutrients',quality='normal',count=60}},{{name='nutrients',quality='normal',count=20}}),
    point(done,{{name='nutrients',quality='normal',count=10}}),ch},
    get_supply_counts=function(q) local name=type(q)=='table' and q.name or q
      if name=='nutrients' then return {['passive-provider']=400} end return {} end,
    select_pickup_point=function(f) if f.name.name=='nutrients' then return {owner=provider} end end}
  local surface={name='gleba',find_logistic_network_by_position=function() return ln end}
  local st={networks={waiting={[waiting.unit_number..'|iron-bacteria|normal']=40000-24000}, unfilled={[short.unit_number..'|processing-unit|normal']=40000-7200}}}
  local L=dofile('mod/agent-harness_0.1.0/logaudit.lua'){state=function() return st end}
  local p={force={},surface=surface,position={x=0,y=0}}
  local r=L.read(p,{})
  eq(r.looked,6,'the character is left out'); eq(r.blocked,4); eq(r.coming,1); eq(r.filled,1)
  local order={}
  for i,x in ipairs(r.requesters) do order[i]=x.block end
  eq(table.concat(order,' '),'full_unrequested waiting not_sent shortage')
  has(r.lines[1],'requester-chest (74.5,62.5), 97 tiles: every slot taken, by items it does not request (48 of 48 slots: spoilage 2400 (spoiled, not requested)); asks yumako-mash 60 (has 0, no room, none free in the network); nutrients 10 (has 0, no room, 400 free in the network, robots take it from passive-provider-chest (10.5,0.5), 89 tiles (holds 400))')
  has(r.lines[2],'deliveries on the way 5+ min; asks iron-bacteria 3 (has 0, 3 on the way for 6m40s, none free in the network)')
  has(r.lines[3],'free in the network, nothing on the way; asks nutrients 10 (has 0, 400 free in the network, robots take it from passive-provider-chest (10.5,0.5), 10 tiles (holds 400))')
  has(r.lines[4],'short in the network; asks processing-unit 20 (has 0, short 2m00s, none free in the network)')
  has(r.summary,'logistic network #98 on gleba: 6 requesters looked at; 4 blocked: 1 full_unrequested, 1 waiting, 1 not_sent, 1 shortage; 1 under their count with deliveries on the way under 5 min; 1 filled; 1 more hold spoilage they do not request, with room left: (4.5,10.5) spoilage 100')
  eq(r.requesters[1].asks[2].from.distance,89)
  -- (d17 batch34 B3) far: asks served from over that many tiles away
  local rf=L.read(p,{far=50})
  has(rf.far[1],'requester-chest (74.5,62.5) asks nutrients (0 on the way, 10 short): robots would take it from passive-provider-chest (10.5,0.5), 89 tiles away')
  eq(#rf.far,1); has(rf.summary,'1 ask served from over 50 tiles away (far)')
  eq(r.far,nil)
  -- by id, and a missing id names the ids there
  p.force={logistic_networks={gleba={ln}}}
  eq(L.read(p,{network=98}).network,98)
  local ok,err=pcall(L.read,p,{network=7})
  assert(not ok and tostring(err):find('no logistic network #7 of ours on gleba (there: #98)',1,true),tostring(err))
end
print('d17_batch17 C2 logistics_audit ranks requesters by what blocks them: ok')

-- C1 addition (Sonnet 12:20: a medium-electric-pole on a belt row's tile cut 6 coal drills for an hour; the drills
-- said only waiting_for_space): a build that leaves a belt facing into another entity, with the line going on past it,
-- is a team alert naming that entity; a cut tile something stands on names it; belt text and belt_gaps name it.
do
  game={tick=1000}
  local player={name='player'}
  local ents={}
  local function box(x,y,w) return {left_top={x=x-w,y=y-w},right_bottom={x=x+w,y=y+w}} end
  local surface
  local function add(e) e.valid=true; e.surface=surface; e.force=e.force or player; e.bounding_box=box(e.position.x,e.position.y,e.w or 0.4); ents[#ents+1]=e; return e end
  local function belt(x,y,dir,items)
    return add({type='transport-belt',name='transport-belt',position={x=x,y=y},direction=dir,belt_neighbours={inputs={},outputs={}},
      get_max_transport_line_index=function() return 1 end,get_transport_line=function() return {get_contents=function() return items or {} end} end})
  end
  surface={name='vulcanus',find_entities_filtered=function(f)
    local out={}
    local area=f.area
    if f.position then local q=f.position; local x,y=q.x or q[1],q.y or q[2]; area={{x-0.01,y-0.01},{x+0.01,y+0.01}} end
    for _,e in ipairs(ents) do
      local ok=e.valid
      if ok and area then local a,b=area[1],area[2]; local bb=e.bounding_box
        ok=bb.left_top.x<b[1] and bb.right_bottom.x>a[1] and bb.left_top.y<b[2] and bb.right_bottom.y>a[2] end
      if ok and f.type then local any=false; for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do if e.type==t then any=true end end; ok=any end
      if ok and f.force then ok=e.force.name==(type(f.force)=='table' and f.force.name or f.force) end
      if ok then out[#out+1]=e; if f.limit and #out>=f.limit then break end end
    end
    return out
  end}
  game.get_surface=function() return surface end
  game.forces={player=player}
  local row={}
  for x=359.5,354.5,-1 do row[#row+1]=belt(x,95.5,12,{{name='coal',count=7}}) end
  local pole=add({type='electric-pole',name='medium-electric-pole',position={x=353.5,y=95.5},w=0.15,last_user={name='sonnet'}})
  local after={}
  for x=352.5,349.5,-1 do after[#after+1]=belt(x,95.5,12) end
  for i,b in ipairs(row) do b.belt_neighbours={inputs={row[i-1]},outputs={row[i+1]}} end
  for i,b in ipairs(after) do b.belt_neighbours={inputs={after[i-1]},outputs={after[i+1]}} end
  add({type='resource',name='coal',position={x=353.5,y=95.5},w=0.5,force={name='neutral'}})
  local st={}
  local L=dofile('mod/agent-harness_0.1.0/linecut.lua'){state=function() return st end}
  eq(L.blocker(surface,{x=353.5,y=95.5}),pole,'the pole, not the ore under it')
  L.built({entity=after[1]})
  eq(#st.linecut.blocked,1)
  L.built({entity=row[6]})
  eq(#st.linecut.blocked,1,'kept once')
  eq(#L.alert_groups(player),0,'not before 30 s')
  game.tick=1000+3600
  local gs=L.alert_groups(player)
  eq(#gs,1); eq(gs[1].kind,'line_cut'); eq(gs[1].by.sonnet,1)
  eq(gs[1].line,"belt line blocked at (353.5,95.5): medium-electric-pole (353.5,95.5) stands where the belt's next tile should be (placed by sonnet); the belt runs 6 tiles from (359.5,95.5) to (354.5,95.5) and stops there, holding coal 42; the line goes on from (352.5,95.5), 4 tiles to (349.5,95.5); seen 1m ago")
  -- the pole moved and a belt there: gone
  pole.valid=false
  local bridge=belt(353.5,95.5,12)
  eq(#L.alert_groups(player),0); eq(#st.linecut.blocked,0)
  -- an inserter at a belt's end moves the items on; a belt past it facing back is another line: neither kept
  bridge.valid=false
  local ins=add({type='inserter',name='inserter',position={x=353.5,y=95.5},w=0.15})
  L.built({entity=ins}); eq(#st.linecut.blocked,0,'inserter')
  ins.valid=false; pole.valid=true
  for _,b in ipairs(after) do b.direction=4 end
  L.built({entity=pole}); eq(#st.linecut.blocked,0,'facing back')
  for _,b in ipairs(after) do b.direction=12 end
  L.built({entity=pole}); eq(#st.linecut.blocked,1,'the pole built last finds it too')
  -- a cut tile a pole stands on names it
  st.linecut.cuts={{id=99,kind='belt',surface='vulcanus',force='player',tick=game.tick,first=game.tick,tiles={{x=353.5,y=95.5,name='transport-belt'}},
    causes={},placers={},a={n=5,last={x=358.5,y=95.5}},b={n=4,last={x=349.5,y=95.5}},carried={'coal'}}}
  local cut
  for _,g in ipairs(L.alert_groups(player)) do if g.key=='line_cut|99' then cut=g end end
  has(cut.line,'1 tile gone, 0s ago, none rebuilt (medium-electric-pole (353.5,95.5) stands on (353.5,95.5) (placed by sonnet))')
  -- belt_gaps: a missing tile names what stands there
  local G=dofile('mod/agent-harness_0.1.0/beltgaps.lua'){state=function() return st end,position=function(q) return q end,
    blocker=function(s,q) return L.blocker(s,q) end,blocker_text=function(e,w) return L.blocker_text(e,w) end}
  player.is_chunk_visible=function() return true end
  local p={force=player,surface=surface,position={x=355,y=95}}
  local r=G.read(p,{from={x=359.5,y=95.5},to={x=349.5,y=95.5}})
  eq(#r.missing,1); eq(r.missing[1].blocked_by.name,'medium-electric-pole')
  eq(r.missing[1].line,'medium-electric-pole (353.5,95.5) stands on (353.5,95.5) (placed by sonnet)')
end
print('d17_batch17 C1 a belt line blocked by an entity on its tile is named: ok')
