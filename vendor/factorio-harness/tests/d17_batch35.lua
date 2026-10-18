-- d17 batch35. Run from the harness root: lua tests/d17_batch35.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

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

-- Fake inventories: slots with swap_stack, as the engine's (a stack moves whole).
local function slot(name,count)
  local s={}
  function s._set(n,c) s.name,s.count,s.valid_for_read=n,c,n~=nil; s.prototype=n and prototypes.item[n] or nil end
  s._set(name,count)
  s.swap_stack=function(o) local n,c=s.name,s.count; s._set(o.name,o.count); o._set(n,c); return true end
  return s
end
local function inventory(list)
  local inv={}
  for i,v in ipairs(list) do inv[i]=slot(v[1],v[2]) end
  inv.get_item_count=function(q) local n=0; for i=1,#inv do if inv[i].valid_for_read and (q==nil or inv[i].name==(type(q)=='table' and q.name or q)) then n=n+inv[i].count end end; return n end
  inv.get_contents=function() local out={}; for i=1,#inv do if inv[i].valid_for_read then out[#out+1]={name=inv[i].name,count=inv[i].count} end end; return out end
  inv.find_item_stack=function(n) for i=1,#inv do if inv[i].valid_for_read and inv[i].name==n then return inv[i] end end end
  inv.is_empty=function() return inv.get_item_count()==0 end
  return inv
end
local guns,ammo,main
local function arm(ammo1,ammo2,mainlist)
  guns=inventory{{'submachine-gun',1},{'rocket-launcher',1},{}}
  ammo=inventory{ammo1,ammo2,{}}
  main=inventory(mainlist)
  body.get_inventory=function(i) return i==3 and guns or i==4 and ammo or main end
  body.get_main_inventory=function() return main end
end

-- A2 (Grok died at the north raft: rockets in the main inventory, the launcher's ammo slot empty, shoot said nothing).
do
  local A=require('ammoslots')()
  arm({'firearm-magazine',10},{},{{'iron-plate',50},{'rocket',20},{'firearm-magazine',5}})
  local p={get_inventory=body.get_inventory,get_main_inventory=body.get_main_inventory}
  local fit=A.carried_for(p,'rocket-launcher')
  eq(#fit,1); eq(fit[1].name,'rocket'); eq(fit[1].index,2)
  eq(A.load(p,2),'loaded rocket*20 from your main inventory into ammo slot 2 for rocket-launcher')
  eq(ammo[2].name,'rocket'); eq(ammo[2].count,20); eq(main[2].valid_for_read,false)
  local line,why=A.load(p,2); eq(line,nil); eq(why,'ammo slot 2 holds rocket*20')
  ammo[2]._set(nil,nil)
  line,why=A.load(p,2); eq(line,nil); eq(why,'gun slot 2 rocket-launcher: ammo slot 2 is empty and your main inventory holds no ammunition it fires')
  line,why=A.load(p,3); eq(why,'gun slot 3 holds no gun')
end
do
  -- shoot: the selected gun's empty slot is loaded first and said
  arm({'firearm-magazine',10},{},{{'rocket',20}})
  local r=grok('shoot',{position={x=10,y=0},gun_slot=2,ticks=120})
  eq(r.loaded,'loaded rocket*20 from your main inventory into ammo slot 2 for rocket-launcher')
  eq(r.gun.ammo,'rocket'); eq(r.gun.count,20); eq(r.no_compatible_ammo,nil)
  -- mid-fight: the launcher fires its last rocket while more are carried: loaded again and selected again
  ammo[2]._set(nil,nil); main[1]._set('rocket',7); body.selected_gun_index=1  -- (the game moved to the loaded gun)
  advance(10)
  eq(ammo[2].count,7); eq(body.selected_gun_index,2)
  -- dry: nothing carried fits it; said once in last_combat
  ammo[2]._set(nil,nil)
  advance(130)
  local lc=grok('status').last_combat
  has(lc.equipped,'loaded rocket*7 from your main inventory into ammo slot 2 for rocket-launcher'); eq(lc.reloads,1)
  has(lc.dry,'gun slot 2 ran dry at '); has(lc.dry,': gun slot 2 rocket-launcher: ammo slot 2 is empty and your main inventory holds no ammunition it fires')
  -- the selected gun empty with nothing it fires carried: why names it at the start
  arm({'firearm-magazine',10},{},{})
  r=grok('shoot',{position={x=10,y=0},gun_slot=2,ticks=60})
  eq(r.loaded,nil)
  has(r.no_compatible_ammo,'gun slot 2 (rocket-launcher) has nothing in ammo slot 2 and your main inventory holds no ammunition it fires; nothing fires from it; slot 1 submachine-gun has firearm-magazine*10 (gun_slot picks it)')
  advance(70)
  -- move_to combat: the selected gun's slot loaded at the start, and again mid-walk
  arm({'firearm-magazine',10},{},{{'rocket',20}})
  body.selected_gun_index=2
  local mv=grok('move_to',{position={x=60,y=0},combat=true,pathfind=false})
  has(mv.combat.equipped,'loaded rocket*20 from your main inventory into ammo slot 2 for rocket-launcher')
  ammo[2]._set(nil,nil); main[1]._set('rocket',3); body.selected_gun_index=1
  advance(10)
  eq(ammo[2].count,3); eq(body.selected_gun_index,2)
  grok('stop',{})
  -- kite loads the selected gun's slot too
  arm({},{},{{'firearm-magazine',30}})
  local K=require('kite'){position=function(v) return v end,distance=function() return 0 end,integer=function(v,d) return v or d end,
    visible=function() return true end,directions={},ammoslots=require('ammoslots')()}
  body.selected_gun_index=1
  local p={character=body,get_inventory=body.get_inventory,get_main_inventory=body.get_main_inventory}
  local plan=K.plan(p,{})
  has(plan.equipped,'firearm-magazine')
  ammo[1]._set(nil,nil); main[1]._set('firearm-magazine',12)
  K.load_selected(p,plan)
  eq(ammo[1].count,12); has(plan.equipped,'loaded firearm-magazine*12 from your main inventory into ammo slot 1 for submachine-gun')
end
print('d17_batch35 A2 shoot loads from the main inventory: ok')
