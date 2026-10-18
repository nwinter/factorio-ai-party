-- Run from repository root: lua tests/turrettour.lua
-- rearm over a radius, an area or the whole surface (Opus, shift12 13:50): every turret that takes the ammo and holds
-- under `below` rounds, in clusters walked nearest first. refuel, feed and rearm that find nothing in their radius name
-- the nearest match outside it, types takes entity names, and a feed gives only what it names (Grok, shift12 13:50).
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0,east=4},
  inventory={chest=1,character_ammo=4,turret_ammo=7,fuel=2,furnace_source=3,furnace_result=5,artillery_turret_ammo=8},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
local drawn={}
rendering={draw_text=function() local obj={id=#drawn+1,valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,
  get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1}
-- Inventories with counts by item.
local function inv(items)
  local o={valid=true}
  o.get_item_count=function(q)
    if q==nil then local n=0; for _,c in pairs(items) do n=n+c end; return n end
    return items[type(q)=='table' and q.name or q] or 0
  end
  o.get_contents=function() local l={}; for k,c in pairs(items) do if c>0 then l[#l+1]={name=k,count=c,quality='normal'} end end; return l end
  o.items=items
  return o
end
local units=0
local function character(pos)
  units=units+1
  local main=inv({})
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  c.main=main
  c.insert=function(st) main.items[st.name]=(main.items[st.name] or 0)+st.count; return st.count end
  c.get_main_inventory=function() return main end
  c.get_item_count=function(n) return main.items[n] or 0 end
  c.get_inventory=function(id) if id==defines.inventory.character_ammo then return inv({}) end end
  c.can_reach_entity=function() return false end
  c.destroy=function() c.valid=false end
  c.prototype={collision_mask={layers={player=true}}}
  return c
end
surface.find_non_colliding_position=function(_,origin) return origin end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end return {valid=true,name=args.name,position=args.position} end
surface.can_place_entity=function() return true end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
-- The world's entities and a find over them: force, type, name, position+radius, area.
local ents={}
local function any(list,v) if type(list)=='string' then return list==v end for _,x in ipairs(list) do if x==v then return true end end return false end
surface.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(ents) do
    local ok=e.valid
    if ok and f.force then ok=e.force==f.force end
    if ok and f.type then ok=any(f.type,e.type) end
    if ok and f.name then ok=any(f.name,e.name) end
    if ok and f.position and f.radius then local dx,dy=e.position.x-f.position.x,e.position.y-f.position.y; ok=dx*dx+dy*dy<=f.radius*f.radius end
    if ok and f.area then
      local lt,rb=f.area[1] or f.area.left_top,f.area[2] or f.area.right_bottom
      ok=e.position.x>=(lt.x or lt[1]) and e.position.x<=(rb.x or rb[1]) and e.position.y>=(lt.y or lt[2]) and e.position.y<=(rb.y or rb[2])
    end
    if ok then out[#out+1]=e end
  end
  return out
end
local gun={type='ammo-turret',attack_parameters={ammo_categories={'bullet'}},automated_ammo_count=10,get_inventory_size=function() return 1 end}
local launcher={type='ammo-turret',attack_parameters={ammo_categories={'rocket'}},automated_ammo_count=10,get_inventory_size=function() return 1 end}
prototypes={item={['firearm-magazine']={name='firearm-magazine',type='ammo',order='a',ammo_category={name='bullet'},stack_size=200},
    ['piercing-rounds-magazine']={name='piercing-rounds-magazine',type='ammo',order='b',ammo_category={name='bullet'},stack_size=200},
    rocket={name='rocket',type='ammo',order='c',ammo_category={name='rocket'},stack_size=200},
    coal={name='coal',fuel_value=4000000,fuel_category='chemical',stack_size=50},['copper-ore']={name='copper-ore',stack_size=50}},
  entity={['gun-turret']={name='gun-turret',type='ammo-turret'},['rocket-turret']={name='rocket-turret',type='ammo-turret'},
    ['stone-furnace']={name='stone-furnace',type='furnace'},inserter={name='inserter',type='inserter'}},
  recipe={['copper-plate']={name='copper-plate',category='smelting',ingredients={{type='item',name='copper-ore',amount=1}}}}}
prototypes.get_item_filtered=function(f)
  local out={}
  for name,it in pairs(prototypes.item) do if it.type==f[1].type then out[name]=it end end
  return out
end
prototypes.get_entity_filtered=function(f)
  local out={}
  for name,e in pairs(prototypes.entity) do if e.type==f[1].type then out[name]=e end end
  return out
end
local function turret(x,y,items,proto,name)
  local e={valid=true,name=name or 'gun-turret',type='ammo-turret',position={x=x,y=y},force=force,unit_number=#ents+1000,prototype=proto or gun,surface=surface}
  local i=inv(items or {})
  e.get_inventory=function(id) eq(id,defines.inventory.turret_ammo); return i end
  ents[#ents+1]=e
  return e
end
local function furnace(x,y,fuel,ore)
  local e={valid=true,name='stone-furnace',type='furnace',position={x=x,y=y},force=force,unit_number=#ents+1000,prototype={crafting_categories={smelting=true}},surface=surface}
  local f,src=inv({coal=fuel or 0}),inv({['copper-ore']=ore or 0})
  e.fuel=f
  e.get_fuel_inventory=function() return f end
  e.get_inventory=function(id) if id==defines.inventory.fuel then return f elseif id==defines.inventory.furnace_source then return src end return inv({}) end
  e.get_recipe=function() return prototypes.recipe['copper-plate'] end
  ents[#ents+1]=e
  return e
end
local players={}
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function request(req)
  local ok,result=pcall(runtime.dispatch,req)
  if not ok then
    local who=req.bot and runtime.bots.index_of(req.bot)
    if type(who)=='number' then pcall(runtime.stop_player,who) end
    error(result,0)
  end
  return result
end
local function as(name) return function(action,args) return request{action=action,args=args or {},bot=name} end end
runtime.operator.bot_create('opus'); runtime.operator.bot_create('grok')
local opus,grok=as('opus'),as('grok')
local function body(name) return runtime.lookup(runtime.bots.index_of(name)).character end
body('opus').position={x=0,y=0}; body('grok').position={x=0,y=0}
body('opus').main.items['firearm-magazine']=500
body('grok').main.items.coal=200; body('grok').main.items['copper-ore']=30
local function active(name) return storage.agent_harness.active[runtime.bots.index_of(name)] end

-- Three clusters of gun turrets under 5 rounds, a full one, and a rocket turret (it takes other ammo).
local a1=turret(20,0); local a2=turret(24,2,{['piercing-rounds-magazine']=3}); turret(22,6,{['firearm-magazine']=12})
turret(21,-4,{},launcher,'rocket-turret')
local b1=turret(-60,0,{['firearm-magazine']=1}); local b2=turret(-62,3)
local c1=turret(200,200)
-- The whole surface: the nearest cluster first, then from where it ends; inside one, nearest first.
-- Without ammo each turret gets its own type (A3): the piercing one and the rocket turret are left out, none held.
local own=opus('rearm',{surface=true,below=5,count=10})
eq(own.places,4)
eq(own.none_held,'2 turrets left out, none of their ammo carried: rocket-turret (21,-4) is empty; gun-turret (24,2) wants piercing-rounds-magazine')
eq(own.ammo_each,'each turret its own ammo: 4 firearm-magazine')
opus('stop',{})
local r=opus('rearm',{surface=true,below=5,count=10,ammo='firearm-magazine'})
eq(r.places,5); eq(r.below,5); eq(r.count,10)
eq(#r.clusters,3); eq(r.clusters[1],'2 turrets around (22,1), 20 tiles from you, holding 0-3 rounds')
eq(r.clusters[2],'2 turrets around (-61,2), 84 tiles on from the cluster before, holding 0-1 rounds')
eq(r.other_ammo,'1 turret there takes other ammo than firearm-magazine')
local order={}
for i,t in ipairs(active('opus').targets) do order[i]=t.entity end
eq(order[1],a1); eq(order[2],a2); eq(order[3],b1); eq(order[4],b2); eq(order[5],c1)
-- An area: only what is inside it.
r=opus('rearm',{area={left_top={x=-70,y=-10},right_bottom={x=-50,y=10}},below=5,ammo='firearm-magazine'})
eq(r.places,2); eq(active('opus').targets[1].entity,b1)
-- A radius: the same, clustered.
r=opus('rearm',{radius=30,below=5,ammo='firearm-magazine'})
eq(r.places,2); eq(active('opus').targets[1].entity,a1)
-- batch28 C3 (Haiku): a tour's end gives a line per turret; stopped before any visit, each says not reached
opus('stop',{})
local tl=storage.agent_harness.last[runtime.bots.index_of('opus')].turret_lines
eq(#tl,2); assert(tl[1]:find('^gun%-turret %(.-%): not reached %(the tour ended '),tl[1])
-- below defaults to count: the turret with 12 rounds is under 20.
r=opus('rearm',{radius=30,count=20,ammo='firearm-magazine'})
eq(r.places,3); eq(r.below,20)
-- Nothing in the radius: why, and the nearest one outside it.
r=opus('rearm',{radius=10,below=5,ammo='firearm-magazine'})
eq(r.places,0); eq(r.nothing,'no turret there that takes firearm-magazine holds under 5 rounds')
eq(r.nearest_outside,'nearest turret under 5 firearm-magazine outside it: gun-turret at (20,0), 20 tiles from you')
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
advance(1)
local last=storage.agent_harness.last[runtime.bots.index_of('opus')]
eq(last.outcome,'nothing_to_do'); eq(last.nearest_outside,r.nearest_outside)
eq(last.why,'no turret there that takes firearm-magazine holds under 5 rounds; '..r.nearest_outside)
-- Only one of radius, area or surface; surface is your own.
local ok,err=pcall(opus,'rearm',{radius=10,surface=true}); assert(not ok and tostring(err):find('give one of radius, area or surface',1,true),tostring(err))
ok,err=pcall(opus,'rearm',{surface='vulcanus'}); assert(not ok and tostring(err):find('a rearm walks, so only your own',1,true),tostring(err))

-- refuel with nothing below count in the radius (Grok: 48 tiles from furnaces out of fuel, places 0 and no hint).
local f1=furnace(30,0,0,0); furnace(2,1,10,0)
r=grok('refuel',{radius=10,fuel='coal',count=10})
eq(r.places,0); eq(r.nothing,'the 1 burner in radius 10 that burn coal hold 10 coal or more')
eq(r.nearest_outside,'nearest burner below 10 coal outside it: stone-furnace at (30,0), 30 tiles from you')
-- types takes entity names too (Grok's types stone-furnace found nothing: its type is furnace).
r=grok('refuel',{radius=40,fuel='coal',count=10,types={'stone-furnace'}})
eq(r.places,1); eq(active('grok').targets[1].entity,f1)
eq(r.types_note,'types takes entity types: stone-furnace is an entity name (its type: furnace); taken as a name')
-- inserter is both a name and a type: a type.
r=grok('refuel',{radius=40,fuel='coal',count=10,types={'inserter'}})
eq(r.places,0); eq(r.types_note,nil)

-- feed with fuel=coal gives only coal (Grok: the copper ore it held went in first).
-- The furnace at (2,1) holds 10 coal and no ore: without that rule it wanted copper ore, which grok holds.
r=grok('feed',{radius=40,fuel='coal',fuel_count=10})
eq(r.places,1); eq(active('grok').targets[1].entity,f1)
-- Nothing in the radius wants what grok holds: why, and the nearest one outside it.
r=grok('feed',{radius=5,fuel='coal',fuel_count=10})
eq(r.places,0); eq(r.nothing,'nothing in radius 5 wants what you hold (1 machine of those kinds there)')
eq(r.nearest_outside,'nearest machine that wants what you hold outside it: stone-furnace at (30,0), 30 tiles from you')

-- Haiku, shift13: position with radius (the radius round that point; a call with both was refused and areas were made
-- by hand); below on every form; a tour's default ticks by its length (surface tours of 520 and 820 tiles ended
-- timed_out at 60 s); a turret whose slot holds other ammo is left out (three walks to one gave nothing).
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
r=opus('rearm',{position={x=-61,y=1},radius=10,below=5})
eq(r.places,2); eq(active('opus').targets[1].entity,b1); eq(active('opus').targets[2].entity,b2)
-- 64 tiles at 9 tiles/s is under a minute: the 60 s floor.
eq(r.ticks,3600); eq(active('opus').until_tick,game.tick+3600)
eq(r.ticks_note,'the default for this tour: 64 tiles from you through 2 turrets at your running speed (9.0 tiles/s), half again for turns, 1 s a turret and 10 s; at least 60 s')
-- Nothing in that radius: inside is measured from the centre, the nearest outside it from the character.
r=opus('rearm',{position={x=-61,y=1},radius=1,below=5})
eq(r.places,0); has(r.nearest_outside,'gun-turret at (20,0), 20 tiles from you')
local ok2,err2=pcall(opus,'rearm',{position={x=0,y=0},area={left_top={x=-1,y=-1},right_bottom={x=1,y=1}}})
assert(not ok2 and tostring(err2):find('position goes with radius (its centre), or alone (the turret there)',1,true),tostring(err2))
-- The whole surface: 440 tiles through 5 turrets.
local function route_len()
  local at,len={x=0,y=0},0
  for _,t in ipairs(active('opus').targets) do local q=t.entity.position; len=len+((q.x-at.x)^2+(q.y-at.y)^2)^0.5; at=q end
  return len
end
r=opus('rearm',{surface=true,below=5,ammo='firearm-magazine'})
eq(r.places,5); eq(r.ticks,math.ceil(route_len()*1.5/0.15)+60*5+600); assert(r.ticks>3600,r.ticks)
eq(active('opus').until_tick,game.tick+r.ticks)
-- ticks given: as given.
r=opus('rearm',{surface=true,below=5,ticks=1200})
eq(r.ticks,nil); eq(r.ticks_note,nil); eq(active('opus').until_tick,game.tick+1200)
-- A tour over 10 minutes long: cut to 36000.
local far=turret(5000,0)
r=opus('rearm',{surface=true,below=5})
eq(r.ticks,36000); has(r.ticks_note,'; cut to 10 min')
far.valid=false
-- A turret under below whose slot holds other ammo, with no room for the call's: left out, and named.
local full=turret(26,-3,{['piercing-rounds-magazine']=2})
full.get_inventory(defines.inventory.turret_ammo).can_insert=function(st) eq(st.name,'firearm-magazine'); return false end
r=opus('rearm',{radius=40,below=5,ammo='firearm-magazine'})
eq(r.places,2)
for _,t in ipairs(active('opus').targets) do assert(t.entity~=full,'left out') end
eq(r.no_room,'1 turret under 5 rounds with no room for firearm-magazine (its ammo slots hold other ammo): gun-turret (26,-3) holds piercing-rounds-magazine*2')
r=opus('rearm',{position={x=26,y=-3},radius=2,below=5,ammo='firearm-magazine'})
eq(r.places,0); eq(r.nothing,'no turret there that takes firearm-magazine holds under 5 rounds with room for it'); has(r.no_room,'gun-turret (26,-3)')
full.valid=false
-- below on the in-reach and positions forms: a turret holding below or more is left as it is.
r=opus('rearm',{positions={{x=22,y=6}},below=10})
eq(r.moved,0); eq(r.below,10); eq(r.held_enough,'1 turret holds 10 rounds or more: gun-turret (22,6) 12')
eq(r.nothing,'no turret there holds under 10 rounds')
-- position alone: the turret there.
r=opus('rearm',{position={x=22,y=6},below=10})
eq(r.held_enough,'1 turret holds 10 rounds or more: gun-turret (22,6) 12')
-- Only the one under below goes on to the transfer (out of reach here: with walk: false the call fails naming it alone).
ok2,err2=pcall(opus,'rearm',{positions={{x=22,y=6},{x=20,y=0}},below=10,walk=false})
assert(not ok2 and tostring(err2):find('the first (20,0): entity is out of reach',1,true) and not tostring(err2):find('(22,6)',1,true),tostring(err2))
-- By default (autowalk.lua) the one out of reach is walked to, as the radius tour walks; the one holding enough is left.
r=opus('rearm',{positions={{x=22,y=6},{x=20,y=0}},below=10})
eq(r.places,1); eq(r.held_enough,'1 turret holds 10 rounds or more: gun-turret (22,6) 12'); has(r.walking,'gun-turret (20,0) is ')
has(r.walking,': walking into reach first (walk: false refuses instead)')
eq(active('opus').kind,'gather'); eq(active('opus').targets[1].entity.position.x,20)
opus('stop',{})
ok2,err2=pcall(opus,'rearm',{positions={{x=22,y=6}},ticks=60,walk=false})
assert(not ok2 and tostring(err2):find('ticks applies with radius, area, surface or walk',1,true),tostring(err2))
-- (d17 batch32 A2, Haiku: a gun on piercing rounds took +0 firearm magazines and the walk read topped_up) the positions
-- walk skips a turret whose slots hold other ammo with no room, and a ghost, names them first, and serves the rest.
do
  local pierce=turret(28,8,{['piercing-rounds-magazine']=8})
  pierce.get_inventory(defines.inventory.turret_ammo).can_insert=function() return false end
  local ghost={valid=true,name='entity-ghost',type='entity-ghost',ghost_name='gun-turret',position={x=30,y=-6},force=force,unit_number=#ents+1000,surface=surface}
  ents[#ents+1]=ghost
  r=opus('rearm',{positions={{x=28,y=8},{x=20,y=0},{x=30,y=-6}},ammo='firearm-magazine',count=10,types={'ammo-turret','entity-ghost'}})
  eq(r.places,1); eq(active('opus').targets[1].entity,a1)
  eq(r.turrets_skipped,'2 of 3 turrets skipped: gun-turret (28,8): holds piercing-rounds-magazine*8, no room for firearm-magazine; entity-ghost (30,-6): a ghost (not built: nothing to load)')
  eq(active('opus').turrets_skipped,r.turrets_skipped)
  opus('stop',{})
  -- every one skipped: nothing walks, and the reply says why
  r=opus('rearm',{positions={{x=28,y=8}},ammo='firearm-magazine',count=10})
  eq(r.moved,0); eq(r.turrets_skipped,'1 of 1 turret skipped: gun-turret (28,8): holds piercing-rounds-magazine*8, no room for firearm-magazine')
  eq(active('opus'),nil)
end
print('turrettour: ok')
