-- d18 batch39. Run from the harness root: lua tests/d18_batch39.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- B1 (Astra 138h31: silo read ready and not launched, last launch 3 min ago, while shipment showed 1000 cryo launched 32 s
-- before; the journal: the silo read came 14 s before that launch). Both lines name the launch by its ledger id and tick,
-- and the silo line says the tick it was read.
do
  defines={rocket_silo_status={building_rocket=0,rocket_ready=7},inventory={cargo_unit=1},cargo_destination={invalid=0,orbit=1,station=2,surface=3,space_platform=4}}
  game={tick=1000}
  local st={}
  local S=dofile('mod/agent-harness_0.1.0/silo.lua'){state=function() return st end}
  local L=dofile('mod/agent-harness_0.1.0/ledger.lua'){state=function() return st end}
  local surface={name='aquilo'}
  local silo={valid=true,unit_number=77,name='rocket-silo',surface=surface,position={x=17.5,y=-13.5},rocket_silo_status=7,rocket_parts=0,
    prototype={rocket_parts_required=50}}
  local pod={get_inventory=function() return {get_contents=function() return {{name='cryogenic-science-pack',count=1000}} end} end,cargo_pod_destination={type=1}}
  local event={rocket_silo=silo,rocket={attached_cargo_pod=pod}}
  local id=L.on_launch(event)
  eq(id,1)
  event.harness_up=id
  game.tick=1600
  S.on_launch_ordered(event)
  game.tick=3520
  local r=S.rocket(silo)
  has(r.last,'last launch 32s ago (up #1, tick 1600)')
  eq(r.last_launch.up,1); eq(r.read_tick,3520)
  defines,game=nil,nil
end
print('d18_batch39 B1 silo and shipment name the same launch: ok')

-- B2 (Grok: the nutrient chamber at (7.5,24.5) at energy 0 with spoilage in its slots, status busy, the egg loop stalled):
-- a burner with nothing burning and only unusable fuel reads fuel_unusable; a stopped burner crafter is told once to its
-- builder (the burner alert), and again only after it ran.
do
  local B=dofile('mod/agent-harness_0.1.0/burnt.lua'){}
  local function stack(name,count,cat) return {valid_for_read=true,name=name,count=count,quality={name='normal'},prototype={fuel_category=cat,stack_size=200}} end
  local fuel={stack('spoilage',40,'chemical')}; fuel.is_empty=function() return #fuel==0 end
  local burnt={{valid_for_read=false}}
  local ch={name='biochamber',position={x=7.5,y=24.5},unit_number=55,valid=true,
    burner={remaining_burning_fuel=0,inventory=fuel,burnt_result_inventory=burnt,fuel_categories={nutrients=true}},
    prototype={burner_prototype={}},last_user={name='grok'},get_recipe=function() return {name='nutrients-from-bioflux'} end}
  local f=B.stuck(ch)
  assert(f and f.unusable,'unusable fuel')
  has(B.line(ch,f,'working'),'its fuel slot holds spoilage*40, which it does not burn (it burns nutrients): nothing burns, it has no energy (the game\'s status reads working)')
  -- nutrients there: it burns them, not stuck
  fuel[2]=stack('nutrients',5,'nutrients')
  eq(B.stuck(ch),nil); fuel[2]=nil
  -- the alert, once
  game={tick=600}
  local st,told={},{}
  local S=dofile('mod/agent-harness_0.1.0/seeds.lua'){state=function() return st end,crafters=function() return {ch} end,
    burnt_stuck=function(e) return B.stuck(e) end,burnt_line=function(e,x) return B.line(e,x) end,
    deliver=function(i,t) told[#told+1]=t.text end,index_of=function(n) return n=='grok' and 3 or nil end}
  local force,surface={name='player'},{name='gleba'}
  eq(S.burnt_check(force,surface),1)
  has(told[1],'burner alert: biochamber (7.5,24.5) on gleba making nutrients-from-bioflux stopped: its fuel slot holds spoilage*40')
  eq(S.burnt_check(force,surface),0,'told once')
  fuel[2]=stack('nutrients',5,'nutrients'); S.burnt_check(force,surface); fuel[2]=nil
  eq(S.burnt_check(force,surface),1,'again after it ran')
  game=nil
end
print('d18_batch39 B2 a burner stopped by its own spoilage: ok')
-- The runtime against a fake engine (as tests/d17_batch35.lua sets it up), for the calls below.
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},
  inventory={chest=1,character_main=1,character_guns=3,character_ammo=4},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
prototypes={item={['submachine-gun']={type='gun',attack_parameters={ammo_categories={'bullet'},range=18}},
  ['rocket-launcher']={type='gun',attack_parameters={ammo_categories={'rocket'},range=36}},
  ['firearm-magazine']={type='ammo',ammo_category={name='bullet'}},rocket={type='ammo',ammo_category={name='rocket'}},
  ['iron-plate']={type='item'}}}
local drawn={}
rendering={draw_text=function() local obj={valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',get_friend=function() return false end,get_cease_fire=function() return false end,chart=function() end,
  is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1}
local units=0
local function character(pos)
  units=units+1
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,max_health=250,
    prototype={collision_box={left_top={x=-0.2,y=-0.2},right_bottom={x=0.2,y=0.2}},collision_mask={layers={player=true}}},
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false},selected_gun_index=1}
  c.insert=function(s) return s.count end
  c.get_item_count=function() return 0 end
  c.can_reach_entity=function() return true end
  c.destroy=function() c.valid=false end
  return c
end
surface.find_non_colliding_position=function(_,origin) return origin end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end return {valid=true,name=args.name,position=args.position} end
surface.can_place_entity=function() return true end
surface.find_entities_filtered=function() return {} end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
local players={}
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
local function request(req)
  local ok,result=pcall(runtime.dispatch,req)
  if not ok then
    if req.bot then pcall(runtime.stop_player,runtime.bots.index_of(req.bot)) end
    error(result,0)
  end
  return result
end
local function as(name) return function(action,args) return request{action=action,args=args or {},bot=name} end end
local grok=as('grok')
runtime.operator.bot_create('grok')
local body=runtime.lookup(runtime.bots.index_of('grok')).character

-- C1 (Astra, about 30 times a shift with a local JSON projection): fields on platform, inspect and status.
do
  local full=grok('status',{})
  local r=grok('status',{fields={'surface','tick'}})
  eq(r.surface,full.surface); eq(r.fields,'surface, tick'); eq(r.last,nil)
  fails(function() grok('status',{fields='surface|bogus'}) end,"fields: bogus is never in this read's reply; its fields: ")
  -- rows: each keeps name and position; one level down
  local out=runtime.project({platforms={{name='Petrel',position={x=0,y=0},hub={cargo='iron-plate*5',slots=3},speed_kms=1},{name='Swiftlet',hub={cargo='none'}}},planet='gleba'},{'hub.cargo','planet'})
  eq(out.platforms[1].name,'Petrel'); eq(out.platforms[1].hub.cargo,'iron-plate*5'); eq(out.platforms[1].hub.slots,nil); eq(out.platforms[1].speed_kms,nil)
  eq(out.platforms[2].hub.cargo,'none'); eq(out.planet,'gleba')
  fails(function() runtime.project({platforms={{name='P',hub={}}}},{'circuits'}) end,'its fields and its platforms rows\' fields: hub, name, platforms')
end
print('d18_batch39 C1 fields on platform, inspect and status: ok')

-- C2 (Sol: a wrapper sampled every 1-2 min; dock bursts looked sustainable): platform_production {leg}: since the last
-- departure and the last full leg, from freight's samples at each segment's start and end.
do
  local saved_game,saved_protos=game,prototypes
  prototypes={item={['firearm-magazine']={type='ammo'}}}
  local fl={['thruster-fuel']={1000,0},['thruster-oxidizer']={1000,0}}
  local am={['firearm-magazine']={50,0}}
  local function stats(t) return {get_input_count=function(n) return (t[n] or {0,0})[1] end,get_output_count=function(n) return (t[n] or {0,0})[2] end} end
  local pl={index=4,name='Wayfarer',surface={},force={get_fluid_production_statistics=function() return stats(fl) end,get_item_production_statistics=function() return stats(am) end}}
  local st={}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return st end}
  game={tick=0}
  -- a leg from nauvis to gleba of 10 min with its samples, then a stop at gleba 5 min so far
  st.freight={[4]={segs={
    {kind='leg',from='nauvis',to='gleba',start=0,['end']=36000,fuel0={['thruster-fuel']={made=1000,used=0},['thruster-oxidizer']={made=1000,used=0}},ammo0={['firearm-magazine']={made=50,used=0}},
      fuel1={['thruster-fuel']={made=7000,used=9000},['thruster-oxidizer']={made=6000,used=9000}},ammo1={['firearm-magazine']={made=150,used=120}}},
    {kind='stop',at='gleba',start=36000,rockets={n=1,cargo={bioflux=500}},pods={received={n=1,cargo={['copper-ore']=500}}}}}}}
  game.tick=54000
  fl={['thruster-fuel']={10000,9000},['thruster-oxidizer']={9000,9000}}; am={['firearm-magazine']={200,120}}
  local d=F.leg_delta(pl)
  has(d.lines[1],'since it left nauvis (15m00s, ticks 0-54000): thruster-fuel made 9000, used 9000 (600/600 a minute, net +0 a minute)')
  has(d.lines[1],'firearm-magazine made 150, used 120 (10/8 a minute, net +2 a minute)')
  has(d.lines[1],'loaded bioflux 500'); has(d.lines[1],'dropped copper-ore 500')
  has(d.lines[2],'the last full leg nauvis->gleba (10m00s, ticks 0-36000): thruster-fuel made 6000, used 9000'); has(d.lines[2],'firearm-magazine made 100, used 120 (10/12 a minute, net -2 a minute)')
  has(d.lines[2],'thruster-oxidizer made 5000, used 9000 (500/900 a minute, net -400 a minute)')
  eq(d.last_leg.loaded.bioflux,nil,'no cargo on the leg alone')
  -- (live 23:09, Spindle after a drop) seg.pods holds last_tick, a number, beside its tallies; gone is not dropped
  local stop=st.freight[4].segs[2]
  stop.pods={received={n=1,cargo={['metallurgic-science-pack']=2000}},landed={n=1,cargo={calcite=1000}},gone={n=1,cargo={stone=7}},last_tick=53000}
  d=F.leg_delta(pl)
  has(d.lines[1],'dropped calcite 1000'); has(d.lines[1],'dropped metallurgic-science-pack 2000'); assert(not d.lines[1]:find('stone',1,true),d.lines[1])
  has(d.lines[1],'thruster-fuel made 9000')
  -- a cargo record past reading: fuel and ammunition still stand
  stop.rockets=setmetatable({},{__index=function() error('bad cargo') end})
  d=F.leg_delta(pl)
  has(d.lines[1],'thruster-fuel made 9000'); has(d.lines[1],'firearm-magazine made 150'); has(d.lines[1],'cargo not read: ')
  game,prototypes=saved_game,saved_protos
end
print('d18_batch39 C2 a whole leg\'s production: ok')

-- C3 (Sol: ~10 min and 6 dry runs on Wayfarer): belt_route's eject end: the belt tile where an inserter on foundation
-- picks and drops onto empty space off the hull, nearest to `to`.
do
  prototypes.entity=prototypes.entity or {}
  prototypes.entity.inserter={type='inserter',inserter_pickup_position={0,-1},inserter_drop_position={0,1.2}}
  local hull={get_tile=function(x,y) return {valid=true,name=y>=3 and 'empty-space' or 'space-platform-foundation'} end,
    can_place_entity=function(f) return math.floor(f.position.y)<3 end}
  local pp={surface=hull,force=force}
  local b,ej=runtime.eject_end(pp,{from={x=0,y=-10},to={x=4.5,y=1.5},eject=true})
  -- the inserter on the edge row (y 2), picking from y 1, dropping at y 3 (empty space)
  eq(ej.position.y,2.5); eq(ej.belt.y,1.5); eq(ej.drop.y,3.5); eq(b.to.x,ej.belt.x); eq(b.eject,nil)
  fails(function() runtime.eject_end(pp,{to={x=4.5,y=-40},eject=true}) end,'eject: no spot within 6 tiles of (4.5,-40)')
  fails(function() runtime.eject_end(pp,{to={x=0,y=0},eject='iron-chest'}) end,'is not an inserter')
end
print('d18_batch39 C3 belt_route ends where an inserter throws overboard: ok')

-- d22 batch90 AZ3 (the AU1 review's finding 6: refusals the harness's own wording invites), on this runtime.
do
  -- fields: a name an earlier reply of the read had (or its describe text names) is absent, not refused
  local out=runtime.project({platforms={{name='P',state='flying',eta_min=4,leg='nauvis->gleba'}}},{'state'},'platforms')
  eq(out.absent,nil)
  out=runtime.project({platforms={{name='P',state='waiting at gleba'}}},{'state','eta_min','leg'},'platforms')
  eq(out.platforms[1].state,'waiting at gleba'); eq(table.concat(out.absent,','),'eta_min,leg')
  fails(function() runtime.project({platforms={{name='P'}}},{'state','zzbogus'},'platforms') end,'fields: zzbogus is never in this read\'s reply')
  -- describe {action}: those entries; a name there is not: the closest real ones
  local d=grok('describe',{action={'nearest','scna'}})
  assert(d.actions.nearest and d.actions.nearest.surface,'nearest entry with surface'); eq(d.actions.scan,nil)
  has(table.concat(d.unknown.scna,','),'scan')
  -- an unknown action names the closest real ones
  fails(function() grok('techologies',{}) end,'unsupported action; closest: technologies')
  -- chat_ack {all: true}, reminders {id}, a doing line of 240
  eq(grok('chat_ack',{all=true}).unanswered,'none')
  local id=grok('reminder_add',{message='check the farm',every_ticks=36000}).added
  local r=grok('reminders',{id=id}); eq(r.count,1); eq(r.reminders[1].id,id)
  fails(function() grok('reminders',{id=999}) end,'no reminder #999')
  grok('board_plan',{doing=string.rep('d',240)})
  fails(function() grok('board_plan',{doing=string.rep('d',241)}) end,'doing')
  -- aliases: scan {centre}, inspect {at}, rates {items}; nearest {surface, count}
  has(grok('scan',{centre={x=0,y=0},radius=4}).corrected,'(centre is position)')
  local okr,rr=pcall(grok,'rates',{items='iron-plate'}); assert(okr or not tostring(rr):find('unknown argument',1,true),tostring(rr))
  game.forces.player.platforms=game.forces.player.platforms or {}
  local okn,nr=pcall(grok,'nearest',{surface='nauvis',name='iron-ore',count=2}); assert(okn,tostring(nr))
end
print('d18_batch39 d22 batch90 AZ3 fields absent, describe {action}, closest actions, aliases: ok')
