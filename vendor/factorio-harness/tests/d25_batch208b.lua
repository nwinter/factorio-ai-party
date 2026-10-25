-- Run from repository root: lua tests/d25_batch208b.lua
-- d25 batch208 QU2 (Astra #2357: a place_ghosts dry run passed configure {storage_filter, bar} on storage chests; the
-- build placed the chests and refused both, "configure sets bar and storage_filter in separate calls"): a storage
-- chest's filter and bar go in one configure call; build and place_ghosts (and their dry runs) check an entry's
-- configure settings as configure does, before anything is placed; a dry run checks the bar and storage filter on what
-- the call leaves there (a ghost holds no items); a setting refused after placing names the entity placed without it.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14,
  on_built_entity=15,on_player_mined_entity=16,on_robot_mined_entity=17,on_player_fast_transferred=18,on_gui_opened=19,on_gui_closed=20},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
rendering={draw_text=function() return {valid=true,destroy=function() end} end,get_object_by_id=function() return nil end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surfaces={}
local function character(surface,pos)
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+#surfaces,health=250,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  local inv={get_item_count=function() return 0 end,find_item_stack=function() return nil end,get_contents=function() return {} end}
  c.insert=function(s) return s.count end
  c.get_main_inventory=function() return inv end
  c.get_item_count=function() return 0 end
  c.can_reach_entity=function() return true end
  c.destroy=function() c.valid=false end
  return c
end
local function new_surface(name,index,extra)
  local s={name=name,index=index,valid=true}
  for k,v in pairs(extra) do s[k]=v end
  s.find_non_colliding_position=function(_,origin) return origin end
  s.create_entity=function(args) if args.name=='character' then return character(s,args.position) end return {valid=true,name=args.name,position=args.position} end
  s.can_place_entity=function() return true end
  s.find_entities_filtered=function() return {} end
  s.count_entities_filtered=function() return 0 end
  s.get_total_pollution=function() return 0 end; s.get_chunks=function() return function() end end; s.get_pollution=function() return 0 end
  s.request_path=function() return 1 end
  surfaces[name]=s; surfaces[index]=s
  return s
end
local nauvis=new_surface('nauvis',1,{planet={name='nauvis'}})
local vulcanus=new_surface('vulcanus',2,{planet={name='vulcanus'}})
new_surface('platform-1',3,{platform={name='Peregrine'}})
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=nauvis,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character(nauvis,{x=5,y=5})
local director={index=2,name='pog-director',valid=true,connected=true,controller_type=2,physical_controller_type=2,force=force,surface=nauvis,position={x=50,y=50}}
local players={nick,director}
for _,pl in ipairs(players) do pl.print=function() end end
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) assert(type(i)=='string' or i<=65536,'Given player value is too big'); if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function(n) return surfaces[n] end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function jump(n) tick=tick+n; game.tick=tick end
local function as(name) return function(action,args) return runtime.dispatch{action=action,args=args or {},bot=name} end end
local astra,sol,luna,opus=as('astra'),as('sol'),as('luna'),as('opus')
local names={'astra','sol','luna','opus','kai','grok','mira'}
for _,n in ipairs(names) do runtime.operator.bot_create(n) end
local function has(s,part) assert(type(s)=="string" and s:find(part,1,true),tostring(s).." lacks "..part) end
local function refused(fn) local ok,err=pcall(fn); assert(not ok,"should be refused"); return tostring(err) end
local function sizes(n) return function() return n end end
prototypes={item={['iron-plate']={name='iron-plate'},['storage-chest']={name='storage-chest'}},quality={normal={name='normal'}},recipe={['iron-gear-wheel']={name='iron-gear-wheel'}},
  entity={['storage-chest']={name='storage-chest',type='logistic-container',logistic_mode='storage',get_inventory_size=sizes(48)},
    ['wooden-chest']={name='wooden-chest',type='container',get_inventory_size=sizes(16)},
    ['assembling-machine-2']={name='assembling-machine-2',type='assembling-machine',get_inventory_size=sizes(0)}}}
defines.inventory.chest=1
-- configure takes a storage chest's filter with its bar (one of CONFIGURE_TOGETHER); with a recipe still not
runtime.configure_together({storage_filter='iron-plate',bar=10})
runtime.configure_together({filters={'iron-plate'},bar=10})
has(refused(function() runtime.configure_together({storage_filter='iron-plate',recipe='iron-gear-wheel'}) end),'configure sets recipe and storage_filter in separate calls')
-- an entry's configure: refused before anything is placed, the live call and its dry run alike (entryset.check)
local function chest(cfg) return {{name='storage-chest',position={x=0.5,y=0.5},configure=cfg}} end
runtime.entryset.check(chest({storage_filter='iron-plate',bar=10}),{})
local e=refused(function() runtime.entryset.check(chest({storage_filter='iron-plate',recipe='iron-gear-wheel'}),{}) end)
has(e,'entry 1 configure: configure sets recipe and storage_filter in separate calls'); has(e,'nothing placed')
-- the dry run's check on what the call leaves: a ghost (place_ghosts) holds no items, so no bar; a built chest takes it
local p=game.players[1]
local function dry(entry,cfg,ctx) local a={} for k,v in pairs(cfg) do a[k]=v end a.position=entry.position return runtime.settings_dry(p,entry,'configure',a,ctx) end
local ent={name='storage-chest',position={x=0.5,y=0.5}}
has(refused(function() dry(ent,{storage_filter='iron-plate',bar=10},{ghosts=true}) end),'bar: ghost of storage-chest (0.5,0.5) holds no items: the bar is set on the built chest')
dry(ent,{storage_filter='iron-plate',bar=10},{})
dry(ent,{storage_filter='iron-plate'},{ghosts=true})
has(refused(function() dry(ent,{bar=49},{}) end),'bar (usable slots 0..48, or false for none)')
dry(ent,{bar=false},{})
has(refused(function() dry({name='wooden-chest',position={x=2.5,y=0.5}},{storage_filter='iron-plate'},{}) end),'wooden-chest (2.5,0.5) is not a storage chest')
has(refused(function() dry(ent,{storage_filter='no-such-item'},{}) end),'storage_filter: unknown item no-such-item')
has(refused(function() dry({name='assembling-machine-2',position={x=4.5,y=4.5}},{bar=3},{}) end),'bar: assembling-machine-2 (4.5,4.5) has no inventory with a bar')
has(refused(function() dry(ent,{storage_filter='iron-plate',recipe='iron-gear-wheel'},{}) end),'in separate calls')
-- a hand build's rows: a setting refused after placing names the entity (the call's item) placed without it
local batch={rows={},set=0,failed={},wires={}}
local call=runtime.scheduler_api.handlers.configure
runtime.scheduler_api.handlers.configure=function() error('bar (usable slots 0..48, or false for none) out of range: a whole number 0..48, got 100; nothing changed',0) end
runtime.entryset.built(p,{position={x=0.5,y=0.5},configure={bar=100}},2,batch,'storage-chest')
runtime.scheduler_api.handlers.configure=call
local out=runtime.entryset.built_result(p,batch,{},true)
has(out.settings_line,'entry 2 configure: bar (usable slots 0..48, or false for none) out of range')
has(out.settings_line,'(storage-chest at (0.5,0.5) is placed without it)')
assert(out.settings_refused==1 and out.settings[1].placed_without[1]=='configure','refused counted, row marked')
has(out.summary,'1 of 1 settings refused; the entities stand placed without them: entry 2 configure')
print('d25_batch208b QU2 configure settings on build and place_ghosts: ok')
