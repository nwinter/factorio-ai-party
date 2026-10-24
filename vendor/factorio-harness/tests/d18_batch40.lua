-- d18 batch40 (the 21:20 poll; eng/d18-batch40). Run from the harness root: lua tests/d18_batch40.lua
-- The runtime scaffold is tests/d17_batch16_rt.lua's.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function contains(s,x) assert(tostring(s):find(x,1,true),tostring(s).." lacks "..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
local function has(list,text)
  for _,line in ipairs(list or {}) do if line:find(text,1,true) then return line end end
  return nil
end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
local drawn={}
rendering={draw_text=function(t) local obj={id=#drawn+1,valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',get_friend=function() return false end,get_cease_fire=function() return false end,chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1}
local units=0
local function character(pos)
  local items={}
  units=units+1
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,max_health=250,
    prototype={collision_box={left_top={x=-0.2,y=-0.2},right_bottom={x=0.2,y=0.2}},collision_mask={layers={player=true}}},
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  local inv={get_item_count=function(q) return items[type(q)=='table' and q.name or q] or 0 end,find_item_stack=function() return nil end,
    get_contents=function() return {} end}
  c.items=items
  c.insert=function(s) items[s.name]=(items[s.name] or 0)+s.count; return s.count end
  c.get_main_inventory=function() return inv end
  c.get_item_count=function(n) return items[n] or 0 end
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
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character({x=5,y=5})
local director={index=2,name='pog-director',valid=true,connected=true,controller_type=2,physical_controller_type=2,force=force,surface=surface,position={x=50,y=50}}
local players={nick,director}
for _,pl in ipairs(players) do pl.print=function() end end
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  -- As the engine: a bot's index is no player index.
  get_player=function(i) assert(type(i)=='string' or i<=65536,'Given player value is too big'); if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
local function jump(n) tick=tick+n; game.tick=tick end
-- As control.lua does: a failed request stops its player unless the runtime
-- marked it passive.
local function request(req)
  local ok,result=pcall(runtime.dispatch,req)
  if not ok then
    local who=req.player or (req.bot==nil and 1 or nil)
    if req.bot then who=runtime.bots.index_of(req.bot) end
    if type(who)=='number' then pcall(runtime.stop_player,who) end
    error(result,0)
  end
  return result
end
local function as(name) return function(action,args) return request{action=action,args=args or {},bot=name} end end
local astra,sol,grok=as('astra'),as('sol'),as('grok')
local function op(action,args) return request{action=action,args=args or {},operator=true} end
runtime.operator.bot_create('astra'); runtime.operator.bot_create('sol'); runtime.operator.bot_create('grok')

-- A1 (Sol 21:21: Wayfarer lost 27 structures to its own bow railguns; the platform alert said "28 destroyed ... by 1
-- small-oxide-asteroid"): our own turrets' kills per turret, apart from the enemies', in losses, the urgent alert and
-- platform_defense; one tell to the platform's listeners on the first.
do
  local wayfarer={valid=true,name='Wayfarer',index=7}
  local psurf={name='platform-7',index=7,platform=wayfarer}
  local function rail(x,y) return {valid=true,name='railgun-turret',type='ammo-turret',force=force,position={x=x,y=y}} end
  local bow,port=rail(-0.5,-21.5),rail(9.5,-21.5)
  local rock={valid=true,name='small-oxide-asteroid',force={name='enemy'},position={x=4,y=-40}}
  local si=runtime.bots.index_of('sol')
  local told={}
  local was_deliver,was_listeners=runtime.board.deliver,runtime.platalerts.listeners
  runtime.board.deliver=function(index,t) told[#told+1]={index=index,t=t} end
  runtime.platalerts.listeners=function(pl) eq(pl,wayfarer); return {{name='sol',index=si}} end
  local function died(x,y,cause,killer)
    runtime.on_event{name=11,tick=tick,entity={valid=true,name='transport-belt',type='transport-belt',position={x=x,y=y},force=force,surface=psurf},cause=cause,force=killer}
  end
  for k=1,20 do died(k-10.5,-28.5,bow,force) end
  for k=1,7 do died(k+0.5,-29.5,port,force) end
  died(4.5,-30.5,rock,{name='enemy'})
  runtime.board.deliver,runtime.platalerts.listeners=was_deliver,was_listeners
  local i=storage.agent_harness.losses[#storage.agent_harness.losses]
  eq(i.platform,'Wayfarer'); eq(i.total,28); eq(#i.own_by,2); eq(i.own_by[1].n,20); eq(i.own_by[2].n,7)
  -- the tell: once, on the first
  eq(#told,1); eq(told[1].index,si); eq(told[1].t.wake,true)
  eq(told[1].t.text,string.format('platform Wayfarer: our own railgun-turret at (-0.5,-21.5) destroyed transport-belt at (-9.5,-28.5) (loss #%d)',i.id))
  -- the urgent alert
  local gp=runtime.lookup(si)
  local base=runtime.urgent.base(gp,nil)
  jump(2)
  local old_hears=runtime.platalerts.hears
  runtime.platalerts.hears=function() return true end
  base.hub={}
  local line=runtime.urgent.check(gp,base)
  runtime.platalerts.hears=old_hears
  assert(line and line:find('platform Wayfarer lost buildings',1,true),tostring(line))
  assert(line:find(': 28 destroyed (28 transport-belt): 27 destroyed by our own railgun-turret at (-0.5,-21.5): 20, railgun-turret at (9.5,-21.5): 7; 1 by enemies (1 small-oxide-asteroid)',1,true),line)
  -- the losses line: our own first when they destroyed more, each turret with its count
  local found
  for _,l in ipairs(sol('status').alerts.latest or {}) do if l:find('on platform Wayfarer',1,true) then found=l end end
  assert(found and found:find('by friendly fire: 20 railgun-turret at (-0.5,-21.5), 7 railgun-turret at (9.5,-21.5), 1 small-oxide-asteroid',1,true),tostring(found))
end
print('d18_batch40 A1 our own railguns\' kills in losses, the urgent alert and the tell: ok')

-- A1 platform_defense: per turret, what it destroyed of ours, with its line of fire.
do
  defines.inventory.turret_ammo=1
  local t={valid=true,type='ammo-turret',name='railgun-turret',position={x=-0.5,y=-21.5},bounding_box={left_top={x=-2,y=-23},right_bottom={x=1,y=-20}},
    get_inventory=function() return {get_contents=function() return {{name='railgun-ammo',count=10}} end} end,
    prototype={attack_parameters={range=40,min_range=0}}}
  local s={find_entities_filtered=function(f) if f.type=='asteroid-collector' or f.type=='inserter' then return {} end return {t} end,
    find_tiles_filtered=function() return {} end}
  game.tick=6000
  local D=dofile('mod/agent-harness_0.1.0/platdefense.lua'){platform=function() return {name='Wayfarer',surface=s,force='f'} end,
    fireline={arc=function(n) return n=='railgun-turret' and {arc=0.2} or nil end,of=function(e) return {line='railgun-turret (-0.5,-21.5) facing south: its shots cross 3 transport-belt',hit=3} end},
    own_losses=function(name) eq(name,'Wayfarer'); return {{name='railgun-turret',x=-0.5,y=-21.5,n=20,loss=2413,last_tick=5400},{name='railgun-turret',x=9.5,y=-21.5,n=7,loss=2413,last_tick=5400}} end}
  local r=D.read({},{platform='Wayfarer'})
  local own,fire
  for _,l in ipairs(r.lines) do if l:find('^destroyed by our own') then own=l end; if l:find('^line of fire') then fire=l end end
  eq(own,'destroyed by our own turrets (the loss incidents kept, apart from asteroid hits): railgun-turret at (-0.5,-21.5): 20 (loss #2413, 10s ago); railgun-turret at (9.5,-21.5): 7 (loss #2413, 10s ago)')
  contains(fire,'its shots cross 3 transport-belt; it engages every asteroid; it destroyed 20 of ours (loss incidents kept)')
  eq(r.turrets[1].destroyed_ours,20); eq(#r.destroyed_by_ours,2); eq(r.destroyed_by_ours[2].destroyed,7)
end
print('d18_batch40 A1 platform_defense: ok')

-- A2 (Astra: about 10 reads of Wayfarer's bow said "no roboport's construction area covers it"): on a space platform the
-- hub builds; ghosts, place_ghosts' robot preview and construction_robots give what holds a ghost there.
do
  prototypes={tile={['space-platform-foundation']={items_to_place_this={{name='space-platform-foundation',count=1}}}},
    entity={['railgun-turret']={items_to_place_this={{name='railgun-turret',count=1}}},['transport-belt']={items_to_place_this={{name='transport-belt',count=1}}}}}
  local hold={['transport-belt']=12}
  local asks={}
  local hub={valid=true,get_item_count=function(n) return hold[n] or 0 end,
    get_logistic_sections=function() return {sections_count=1,get_section=function() return {active=true,filters=asks} end} end}
  local empty={}  -- tiles of empty space: 'x,y' -> a foundation ghost there or not
  local surf={name='platform-7',platform={name='Wayfarer',hub=hub},
    get_tile=function(x,y) local k=x..','..y; return {name=empty[k]~=nil and 'empty-space' or 'space-platform-foundation'} end,
    count_entities_filtered=function(f) return empty[f.area[1][1]..','..f.area[1][2]] and 1 or 0 end,
    find_logistic_networks_by_construction_area=function() return {} end}
  local GL=dofile('mod/agent-harness_0.1.0/ghostlist.lua'){position=function(v) return v end,integer=function(v,d) return v or d end,
    distance=function(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end}
  local function ghost(name,x,y,w)
    return {valid=true,type='entity-ghost',ghost_name=name,position={x=x,y=y},force='player',ghost_prototype=prototypes.entity[name],
      bounding_box={left_top={x=x-w/2,y=y-w/2},right_bottom={x=x+w/2,y=y+w/2}}}
  end
  -- the hub holds it, on foundation
  local v,info=GL.platform_blocker(surf,ghost('transport-belt',3.5,-26.5,1),'transport-belt',1)
  eq(v,'the hub holds 12 transport-belt'); eq(info.hub_holds,12)
  -- the hub holds none; requested or not
  v,info=GL.platform_blocker(surf,ghost('railgun-turret',-10,-41,4),'railgun-turret',1)
  eq(v,'the hub holds no railgun-turret; no request of the hub asks for it'); eq(info.hub_requests,0)
  asks[1]={value={name='railgun-turret'},min=2}
  v=GL.platform_blocker(surf,ghost('railgun-turret',-10,-41,4),'railgun-turret',1)
  eq(v,'the hub holds no railgun-turret; its requests ask for 2 (filled from a planet the platform stops at)')
  -- over empty space: a foundation ghost there first, or none
  empty['-12,-43']=true; empty['-11,-43']=false
  v,info=GL.platform_blocker(surf,ghost('railgun-turret',-10,-41,4),'railgun-turret',1)
  contains(v,'no foundation under 1 of its tiles and no foundation ghost there: the hub does not build it until foundation is placed; the hub holds no railgun-turret')
  eq(info.no_foundation,1)
  empty['-11,-43']=true
  v,info=GL.platform_blocker(surf,ghost('railgun-turret',-10,-41,4),'railgun-turret',1)
  contains(v,'waits for foundation: 2 space-platform-foundation ghosts under it, built first'); eq(info.foundation_ghosts,2)
  -- off a platform: nil (the networks' verdict stands)
  eq(GL.platform_blocker({name='nauvis'},ghost('transport-belt',0,0,1),'transport-belt',1),nil)
  -- place_ghosts' robot preview
  local RT=dofile('mod/agent-harness_0.1.0/robottrips.lua'){}
  local force={logistic_networks={},worker_robots_storage_bonus=0,find_logistic_network_by_position=function() return nil end}
  local lines=RT.preview(surf,force,{{kind='construct',pos={x=3.5,y=-26.5},item='transport-belt',count=1},{kind='construct',pos={x=4.5,y=-26.5},item='bulk-inserter',count=1}})
  local all=table.concat(lines or {},' | ')
  contains(all,'1 transport-belt ghost near (3.5,-26.5): on a space platform the hub builds it from its inventory (no roboport); the hub holds 12 transport-belt')
  contains(all,'1 bulk-inserter ghost near (4.5,-26.5): on a space platform the hub builds it from its inventory (no roboport); the hub holds no bulk-inserter')
  assert(not all:find('roboport\'s construction area',1,true) and not all:find('no logistic network covers',1,true),all)
  -- construction_robots there
  local R=dofile('mod/agent-harness_0.1.0/robots.lua'){position=function(v) return v end}
  fails(function() R.read({surface=surf,position={x=0,y=0},force=force},{}) end,
    'platform Wayfarer (surface platform-7) has no roboport or construction robot: its hub builds ghosts from its own inventory; ghosts {surface: "platform-7"} gives what holds each')
  prototypes=nil
end
print('d18_batch40 A2 platform ghosts: the hub, its requests, the foundation: ok')

-- A3 (Astra, twice from Aquilo: rates' help says surface= and rates refused it): rates takes surface by remote view; no
-- action's help names a remote-view argument (surface=, platform=) its schema refuses, and every action the describe help
-- lists as taking surface= or platform= takes it.
do
  force.platforms=force.platforms or {}
  force.get_item_production_statistics=function() return {get_flow_count=function() return 0 end} end
  defines.flow_precision_index.ten_minutes=2
  prototypes=prototypes or {}; prototypes.recipe={['iron-gear-wheel']={products={{name='iron-gear-wheel'}}}}; prototypes.item={['iron-gear-wheel']={}}
  local r=astra('rates',{recipe='iron-gear-wheel',surface='nauvis'})
  eq(r.surface,'nauvis'); eq(r.machines,0)
  local d=request{action='describe',args={},bot='astra'}
  assert(d.actions.rates.surface,'rates takes surface')
  local bad={}
  local function takes(name,key) return d.actions[name][key]~=nil end
  for _,name in ipairs(runtime.bots.SURFACE_ACTIONS) do if d.actions[name] and not takes(name,'surface') then bad[#bad+1]='surface: '..name end end
  for _,name in ipairs(runtime.bots.PLATFORM_ACTIONS) do if d.actions[name] and not takes(name,'platform') then bad[#bad+1]='platform: '..name end end
  for name,schema in pairs(d.actions) do
    for key,text in pairs(schema) do
      if type(text)=='string' then
        for _,w in ipairs({'surface','platform'}) do
          if (text:find('('..w..'=',1,true) or text:find(' '..w..'= ',1,true)) and not schema[w] then bad[#bad+1]=name..'.'..key..' names '..w..'=' end
        end
      end
    end
  end
  eq(#bad,0,table.concat(bad,'; '))
  prototypes=nil
end
print('d18_batch40 A3 rates surface, help against schema: ok')
