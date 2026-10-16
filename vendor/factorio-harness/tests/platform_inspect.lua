-- Run from repository root: lua tests/platform_inspect.lua
-- inspect and configure on a space platform by name (platform=), through the
-- runtime against a fake engine: a paste of a whitelist inserter waits on a
-- full hub (request #2: Starling's collector arm).
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11},shooting={not_shooting=0,shooting_enemies=1},
  controllers={character=1,remote=27,spectator=2},direction={north=0,east=4,south=8,west=12},
  inventory={chest=1,hub_main=21,asteroid_collector_output=22,asteroid_collector_arm=23},build_mode={normal=1},
  build_check_type={manual=1,manual_ghost=2},flow_precision_index={five_seconds=0,one_minute=1},
  entity_status={working=1,waiting_for_source_items=2,full_output=3,marked_for_deconstruction=62},
  space_platform_state={waiting_at_station=6,paused=7}}
rendering={draw_text=function() return {valid=true,destroy=function() end} end,get_object_by_id=function() return nil end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
prototypes={entity={},item={['oxide-asteroid-chunk']={name='oxide-asteroid-chunk'},inserter={name='inserter'}},recipe={},
  asteroid_chunk={['metallic-asteroid-chunk']={},['carbonic-asteroid-chunk']={},['oxide-asteroid-chunk']={}}}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,
  get_spawn_position=function() return {x=0,y=0} end,recipes={}}
local surface={name='nauvis',index=1}
local function stack(name,count) return {name=name,count=count,valid_for_read=count>0,quality={name='normal'}} end
local function inv(list,size)
  local t={valid=true}
  for i=1,size do t[i]=list[i] or stack(nil,0) end
  t.get_contents=function() local o={}; for i=1,size do local s=t[i]; if s.valid_for_read then o[#o+1]={name=s.name,count=s.count,quality='normal'} end end; return o end
  t.get_item_count=function(q)
    local n,ql=type(q)=='table' and q.name or q,type(q)=='table' and q.quality or 'normal'
    local c=0
    for i=1,size do if t[i].valid_for_read and t[i].name==n and t[i].quality.name==ql then c=c+t[i].count end end
    return c
  end
  t.count_empty_stacks=function() local c=0; for i=1,size do if not t[i].valid_for_read then c=c+1 end end; return c end
  t.is_empty=function() return t.count_empty_stacks()==size end
  return t
end
-- The platform: hub at 0,0 (full), collector, the inserter between them
-- marked for deconstruction, and the pasted whitelist inserter's ghost on it.
local psurf={name='platform-1',index=2}
local hub_inv=inv({stack('iron-plate',100),stack('carbon',50)},2)
local hub={valid=true,name='space-platform-hub',type='space-platform-hub',position={x=0,y=0},force=force,surface=psurf,direction=0,
  bounding_box={left_top={x=-2,y=-2},right_bottom={x=2,y=2}},get_inventory=function(i) if i==21 then return hub_inv end end,
  get_fluid_contents=function() return {} end}
local out_inv=inv({stack('metallic-asteroid-chunk',9),stack('carbonic-asteroid-chunk',8),stack('oxide-asteroid-chunk',3)},5)
local collector={valid=true,name='asteroid-collector',type='asteroid-collector',position={x=-2.5,y=-6.5},force=force,surface=psurf,direction=0,
  bounding_box={left_top={x=-4,y=-8},right_bottom={x=-1,y=-5.5}},get_inventory=function(i) if i==22 then return out_inv end end,
  get_fluid_contents=function() return {} end}
local filters={}
local ins={valid=true,name='inserter',type='inserter',position={x=-2.5,y=-4.5},force=force,surface=psurf,direction=0,status=62,
  bounding_box={left_top={x=-3,y=-5},right_bottom={x=-2,y=-4}},pickup_position={x=-2.5,y=-5.5},drop_position={x=-2.5,y=-3.5},
  filter_slot_count=5,use_filters=false,inserter_filter_mode='whitelist',held_stack=stack(nil,0),pickup_target=collector,drop_target=hub,
  get_filter=function(i) return filters[i] end,set_filter=function(i,f) filters[i]=f and {name=f} or nil end,
  to_be_deconstructed=function() return true end,to_be_upgraded=function() return false end,
  get_inventory=function() return nil end,get_fluid_contents=function() return {} end}
local ghost={valid=true,name='entity-ghost',type='entity-ghost',ghost_name='inserter',ghost_type='inserter',position={x=-2.5,y=-4.5},force=force,surface=psurf,direction=0,
  bounding_box=ins.bounding_box,filter_slot_count=5,inserter_filter_mode='whitelist',use_filters=true,
  get_filter=function(i) if i==1 then return {name='oxide-asteroid-chunk',quality='normal'} end end,
  ghost_prototype={items_to_place_this={{name='inserter',count=1}}},get_inventory=function() return nil end,get_fluid_contents=function() return {} end}
local on_platform={hub,collector,ins,ghost}
local function inside(e,pos) local b=e.bounding_box; return pos.x>=b.left_top.x and pos.x<=b.right_bottom.x and pos.y>=b.left_top.y and pos.y<=b.right_bottom.y end
local function types(f,e)
  if f.type==nil then return true end
  if type(f.type)=='string' then return e.type==f.type end
  for _,t in ipairs(f.type) do if e.type==t then return true end end
  return false
end
psurf.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(on_platform) do
    local ok=types(f,e) and (f.name==nil or e.name==f.name) and (f.force==nil or e.force==f.force)
    if ok and f.to_be_deconstructed then ok=e.to_be_deconstructed and e.to_be_deconstructed() end
    if ok and f.position then
      local d=((e.position.x-f.position.x)^2+(e.position.y-f.position.y)^2)^0.5
      ok=f.radius and d<=f.radius or (not f.radius and inside(e,f.position))
    end
    if ok and f.area then local a=f.area; ok=e.position.x>=a.left_top.x and e.position.x<=a.right_bottom.x and e.position.y>=a.left_top.y and e.position.y<=a.right_bottom.y end
    if ok then out[#out+1]=e end
    if f.limit and #out>=f.limit then break end
  end
  return out
end
psurf.count_entities_filtered=function(f) local g={}; for k,v in pairs(f) do if k~='limit' then g[k]=v end end; return #psurf.find_entities_filtered(g) end
local platform={valid=true,name='Starling',index=1,force=force,surface=psurf,hub=hub,state=6,space_location={name='nauvis'}}
psurf.platform=platform
hub.get_logistic_sections=function() return nil end
force.platforms={platform}
-- Nauvis, where the bot stands.
local function character(pos)
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=100,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  local main=inv({},10)
  c.get_main_inventory=function() return main end
  c.get_item_count=function() return 0 end
  c.insert=function(s) return s.count end
  c.can_reach_entity=function(e) return e.surface==surface end
  c.destroy=function() c.valid=false end
  return c
end
surface.find_entities_filtered=function() return {} end
surface.count_entities_filtered=function() return 0 end
surface.find_non_colliding_position=function() return {x=3,y=0} end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=50,y=50},chat_color={r=1,g=1,b=1}}
nick.character=character({x=50,y=50})
nick.print=function() end
local players={nick}
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function bot(action,args) return runtime.dispatch{action=action,args=args,bot='astra'} end
runtime.operator.bot_create('astra')

-- The inserter: status by name, its (empty) filters and mode, what it holds,
-- where it picks up and drops, the deconstruction mark, the ghost replacing
-- it with its whitelist, and why the hub is not getting on with it.
local r=bot('inspect',{platform='Starling',position={x=-2.5,y=-4.5}})
eq(r.name,'inserter'); eq(r.status_name,'marked_for_deconstruction')
eq(#r.filters,0); eq(r.use_filters,false); eq(r.filter_mode,'whitelist'); eq(r.held,'nothing')
eq(r.pickup_target,'asteroid-collector (-2.5,-6.5)'); eq(r.drop_target,'space-platform-hub (0,0)')
eq(r.marked_for_deconstruction,true); eq(r.marked_for_upgrade,nil)
eq(#r.ghosts_here,1); eq(r.ghosts_here[1].name,'inserter'); eq(r.ghosts_here[1].filters[1],'oxide-asteroid-chunk'); eq(r.ghosts_here[1].filter_mode,'whitelist')
eq(r.construction_blocked[1],'hub full: 0 of 2 slots free; 1 of our entities marked for deconstruction wait for room (1 inserter; removed entities and their contents go to the hub)')
eq(r.construction_blocked[2],'ghosts wait for items the hub lacks: inserter (ghosts need 1, hub has 0)')
-- Off the platform the same position is on Nauvis: nothing there.
fails(function() bot('inspect',{position={x=-2.5,y=-4.5}}) end,'entity not found at (-2.5,-4.5): nothing within 3 tiles')
fails(function() bot('inspect',{platform='Kestrel',position={x=-2.5,y=-4.5}}) end,'no platform named Kestrel; platforms: Starling')
-- The ghost by name; the collector's output; the hub's slots.
eq(bot('inspect',{platform='Starling',position={x=-2.5,y=-4.5},name='entity-ghost'}).ghost_name,'inserter')
local c=bot('inspect',{platform='Starling',position={x=-2.5,y=-6.5}})
eq(c.inventories.asteroid_collector_output[3].name,'oxide-asteroid-chunk'); eq(c.inventories.asteroid_collector_output[3].count,3)
eq(c.construction_blocked,nil)
local h=bot('inspect',{platform='Starling',position={x=0,y=0}})
eq(h.hub_slots,'0 of 2 free'); eq(#h.construction_blocked,2)
-- The hub shows the platform's flight (space.lua flight): speed, and the next stop while waiting here.
platform.speed=0; platform.schedule={current=1,records={{station='nauvis'},{station='vulcanus'}}}
h=bot('inspect',{platform='Starling',position={x=0,y=0}})
eq(h.flight.speed_kms,0); eq(h.flight.next_stop,'vulcanus'); eq(h.flight.leg,nil)
platform.speed=nil; platform.schedule=nil
-- Anywhere on the platform is in sight, beyond the 32 tiles of a character.
collector.position={x=-2.5,y=-60.5}; collector.bounding_box={left_top={x=-4,y=-62},right_bottom={x=-1,y=-59}}
eq(bot('inspect',{platform='Starling',position={x=-2.5,y=-60.5}}).name,'asteroid-collector')
collector.position={x=-2.5,y=-6.5}; collector.bounding_box={left_top={x=-4,y=-8},right_bottom={x=-1,y=-5.5}}
-- A held stack.
ins.held_stack=stack('oxide-asteroid-chunk',3)
eq(bot('inspect',{platform='Starling',position={x=-2.5,y=-4.5}}).held,'3 oxide-asteroid-chunk')

-- configure on the platform: inserter filters through remote view.
local cf=bot('configure',{platform='Starling',position={x=-2.5,y=-4.5},filters={'oxide-asteroid-chunk'},filter_mode='whitelist'})
eq(cf.filters[1],'oxide-asteroid-chunk'); eq(filters[1].name,'oxide-asteroid-chunk'); eq(ins.use_filters,true)
eq(bot('inspect',{platform='Starling',position={x=-2.5,y=-4.5}}).filters[1],'oxide-asteroid-chunk')

-- platforms: hub slots on every row; one platform by name says what holds up building.
local all=bot('platforms',{})
eq(all.platforms[1].hub_slots,'0 of 2 free'); eq(all.platforms[1].construction_blocked,nil)
local one=bot('platforms',{platform='Starling'}).platforms[1]
eq(#one.construction_blocked,2)
-- Room in the hub and the item there: nothing blocks.
hub_inv[2]=stack(nil,0); hub_inv[1]=stack('inserter',1)
eq(bot('platforms',{platform='Starling'}).platforms[1].construction_blocked,nil)
eq(bot('platforms',{}).platforms[1].hub_slots,'1 of 2 free')
-- Tile ghosts the foundation rules hold back (request #3): foundation fills
-- x -8..3, y 0..12 but for an empty channel along y=8 (x -8..-2) open to the
-- west and a pocket at (-8,3),(-7,3). A ghost at the channel's mouth would
-- split the empty space round it (platformtiles2: the hub looks at a tile's 8
-- neighbours), the channel left a hole with no ghosts: it stays unbuilt. A
-- pocket all under ghosts, a ghost on the open edge: fine. A ghost with no
-- foundation round it: not.
local empty={}
for x=-8,-2 do empty[x..',8']=true end
empty['-8,3']=true; empty['-7,3']=true
local gets=0
psurf.get_tile=function(x,y)
  gets=gets+1
  local f=x>=-8 and x<=3 and y>=0 and y<=12 and not empty[x..','..y]
  return {name=f and 'space-platform-foundation' or 'empty-space'}
end
local function tile_ghost(x,y)
  return {valid=true,name='tile-ghost',type='tile-ghost',ghost_name='space-platform-foundation',position={x=x+0.5,y=y+0.5},force=force,surface=psurf,
    bounding_box={left_top={x=x,y=y},right_bottom={x=x+1,y=y+1}},ghost_prototype={items_to_place_this={{name='space-platform-foundation',count=1}}},
    get_inventory=function() return nil end,get_fluid_contents=function() return {} end}
end
on_platform={hub,collector,ins,ghost,tile_ghost(-8,8),tile_ghost(20,20),tile_ghost(4,5),tile_ghost(-8,3),tile_ghost(-7,3)}
hub_inv[2]=stack('space-platform-foundation',9)
local blocked=bot('platforms',{platform='Starling'}).platforms[1].construction_blocked
eq(#blocked,3,'hub full and two tile ghosts')
eq(blocked[1],'hub full: 0 of 2 slots free; 1 of our entities marked for deconstruction wait for room (1 inserter; removed entities and their contents go to the hub)')
eq(blocked[2],'tile ghost (-7.5,8.5) space-platform-foundation: building it would split the empty space beside it: (-6.5,8.5) and (-8.5,8.5) meet only through it (the hub builds no foundation that splits empty space, even when each side stays open); on one side a hole of 6 empty tiles with no ghost: (-6.5,8.5), (-5.5,8.5), (-4.5,8.5), (-3.5,8.5), ...')
eq(blocked[3],'tile ghost (20.5,20.5) space-platform-foundation: no foundation among the 8 tiles round it')
assert(gets<4000,gets)
-- inspect on the tile ghost says the same.
local tg=bot('inspect',{platform='Starling',position={x=-7.5,y=8.5}})
eq(tg.ghost_name,'space-platform-foundation'); eq(tg.construction_blocked[2],blocked[2])
eq(tg.tile_wait,'waits: '..blocked[2])
-- Ghosts on the rest of the channel: nothing is held back by it.
for x=-7,-2 do on_platform[#on_platform+1]=tile_ghost(x,8) end
hub_inv[2]=stack('space-platform-foundation',20)
blocked=bot('platforms',{platform='Starling'}).platforms[1].construction_blocked
eq(#blocked,2,table.concat(blocked,' | ')); eq(blocked[2]:find('(20.5,20.5)',1,true)~=nil,true)
-- The hub's foundation at the ghosts' quality: an uncommon ghost lacks it.
local q=tile_ghost(5,5); q.quality={name='uncommon'}; on_platform[#on_platform+1]=q
blocked=bot('platforms',{platform='Starling'}).platforms[1].construction_blocked
eq(blocked[2],'ghosts wait for items the hub lacks: space-platform-foundation@uncommon (ghosts need 1, hub has 0)')
-- A ghost in the 82 tiles south of a thruster.
local thruster={valid=true,name='thruster',type='thruster',position={x=1,y=-3},force=force,surface=psurf,
  bounding_box={left_top={x=-1,y=-5},right_bottom={x=3,y=-1}}}
on_platform[#on_platform+1]=thruster; on_platform[#on_platform+1]=tile_ghost(1,13)
blocked=bot('platforms',{platform='Starling'}).platforms[1].construction_blocked
local south
for _,line in ipairs(blocked) do if line=='tile ghost (1.5,13.5) space-platform-foundation: in the 82 tiles south of the thruster at (1,-3), where no foundation is built' then south=true end end
assert(south,table.concat(blocked,' | '))
-- An inserter with nothing to drop into: the tile its items land on.
ins.drop_target=nil
local lone=bot('inspect',{platform='Starling',position={x=-2.5,y=-4.5}})
eq(lone.drop_target,nil); eq(lone.drop_tile,'empty-space'); eq(lone.drop_note,'drops into empty space: items it moves are thrown overboard')
ins.drop_target=hub
-- Repair on a platform is the game's (shift05 08:03: Astra's hub at 637/1000):
-- inspect of the hub lists what is damaged and its repair packs, a damaged
-- entity says how it gets repaired, and repair refuses platform targets.
hub.health,hub.max_health=637,1000
collector.health,collector.max_health=50,200
local hh=bot('inspect',{platform='Starling',position={x=0,y=0}})
eq(hh.repair_packs,'none'); eq(hh.damaged[1],'asteroid-collector (-2.5,-6.5) 50/200'); eq(hh.damaged[2],'space-platform-hub (0,0) 637/1000')
assert(hh.repair:find('repair packs from the hub, one entity at a time',1,true),hh.repair)
eq(bot('inspect',{platform='Starling',position={x=-2.5,y=-4.5}}).repair,nil,'not damaged: no note')
fails(function() bot('repair',{platform='Starling',position={x=0,y=0}}) end,'repair cannot reach a space platform: the game repairs platform entities itself with repair packs from the hub')
eq(bot('platforms',{platform='Starling'}).platforms[1].damaged[2],'space-platform-hub (0,0) 637/1000')
hub.health,hub.max_health,collector.health,collector.max_health=nil,nil,nil,nil
-- flush reaches the platform the same way (the collector has no fluidbox).
fails(function() bot('flush',{platform='Starling',position={x=-2.5,y=-6.5}}) end,'asteroid-collector has no fluidbox')
-- Asteroid collector filters (shift05 10:37: Astra could not see the chunk
-- filters a paste had set): get_filter gives a chunk prototype (a LuaObject
-- that errors on keys it lacks), shown by name with the slot count and what
-- the arms hold; configure sets them by chunk name, here through remote view.
local function chunk(n) return setmetatable({},{__index=function(_,k) if k=='name' then return n end error("LuaAsteroidChunkPrototype doesn't contain key "..k,2) end}) end
-- As the game: filter_slot_count reads 0 until a filter is set (then the
-- highest slot set; shift06 11:57), get_filter fails past that count, and
-- set_filter fails past the collector's 2 slots.
local cfilters={}
setmetatable(collector,{__index=function(_,k)
  if k=='filter_slot_count' then local n=0; for i=1,2 do if cfilters[i] then n=i end end; return n end
end})
collector.get_filter=function(i) if i>collector.filter_slot_count then error('Index out of range',2) end return cfilters[i] end
collector.set_filter=function(i,f)
  if i>2 then error('Index out of range: 2 filter slots',2) end
  assert(f==nil or prototypes.asteroid_chunk[f],'bad chunk'); cfilters[i]=f and chunk(f) or nil
end
local arm_inv=inv({stack('carbonic-asteroid-chunk',1)},2)
collector.get_inventory=function(i) if i==22 then return out_inv end if i==23 then return arm_inv end end
-- A new collector: no filters, the count reads 0; inspect still shows the filter list.
local ci=bot('inspect',{platform='Starling',position={x=-2.5,y=-6.5}})
eq(#ci.filters,0); eq(ci.filter_slots,0); eq(ci.filter_mode,nil)
eq(ci.arm[1].name,'carbonic-asteroid-chunk'); eq(ci.inventories.asteroid_collector_output[1].name,'metallic-asteroid-chunk')
assert(ci.collector_note:find('no whitelist/blacklist mode',1,true),ci.collector_note)
-- configure on it works (Astra's case): the count is not trusted.
local cc=bot('configure',{platform='Starling',position={x=-2.5,y=-6.5},filters={'carbonic-asteroid-chunk'}})
eq(cc.filters[1],'carbonic-asteroid-chunk'); eq(#cc.filters,1); eq(cc.filter_slots,1); eq(cc.not_set,nil)
-- A chunk prototype from get_filter is shown by name.
local cr=bot('inspect',{platform='Starling',position={x=-2.5,y=-6.5}})
eq(cr.filters[1],'carbonic-asteroid-chunk'); eq(cr.filter_slots,1)
cc=bot('configure',{platform='Starling',position={x=-2.5,y=-6.5},filters={'oxide-asteroid-chunk','carbonic-asteroid-chunk'}})
eq(cc.filters[1],'oxide-asteroid-chunk'); eq(cc.filters[2],'carbonic-asteroid-chunk'); eq(cc.filter_slots,2)
-- Past the collector's slots the game refuses; what it said, and the slots set before are put back.
fails(function() bot('configure',{platform='Starling',position={x=-2.5,y=-6.5},filters={'metallic-asteroid-chunk','metallic-asteroid-chunk','oxide-asteroid-chunk'}}) end,
  'the game refused oxide-asteroid-chunk in filter slot 3: ')
fails(function() bot('configure',{platform='Starling',position={x=-2.5,y=-6.5},filters={'metallic-asteroid-chunk','metallic-asteroid-chunk','oxide-asteroid-chunk'}}) end,
  'Index out of range: 2 filter slots (slots 1..2 are as they were)')
eq(cfilters[1].name,'oxide-asteroid-chunk'); eq(cfilters[2].name,'carbonic-asteroid-chunk')
fails(function() bot('configure',{platform='Starling',position={x=-2.5,y=-6.5},filters={'iron-plate'}}) end,'unknown asteroid chunk iron-plate; chunks: carbonic-asteroid-chunk, metallic-asteroid-chunk, oxide-asteroid-chunk')
fails(function() bot('configure',{platform='Starling',position={x=-2.5,y=-6.5},filters={'oxide-asteroid-chunk'},filter_mode='blacklist'}) end,'asteroid collectors have no filter mode')
eq(cfilters[1].name,'oxide-asteroid-chunk','a refused configure changes nothing')
-- One filter after two: slot 2 is cleared.
eq(#bot('configure',{platform='Starling',position={x=-2.5,y=-6.5},filters={'metallic-asteroid-chunk'}}).filters,1); eq(cfilters[2],nil)
-- [] clears every slot; the count reads 0 again.
cc=bot('configure',{platform='Starling',position={x=-2.5,y=-6.5},filters={}})
eq(#cc.filters,0); eq(cc.filter_slots,0); eq(cfilters[1],nil)
-- Past a cap the count says "at least" and how many of how many were counted (Astra, d15 15:11: Aegis's 924 tile
-- ghosts read 466 under one 500 cap for both kinds).
do
  local caps=runtime.space.GHOST_CAP
  runtime.space.GHOST_CAP={['entity-ghost']=2000,['tile-ghost']=3}
  blocked=bot('platforms',{platform='Starling'}).platforms[1].construction_blocked
  local line
  for _,l in ipairs(blocked) do if l:find('ghost count capped',1,true) then line=l end end
  eq(line,'ghost count capped (the first 3 of 13 tile-ghosts counted): the counted ghosts need inserter at least 1, hub has 1, space-platform-foundation at least 3, hub has 20')
  hub_inv[2]=stack('space-platform-foundation',1)
  for _,l in ipairs(bot('platforms',{platform='Starling'}).platforms[1].construction_blocked) do if l:find('ghosts wait for items',1,true) then line=l end end
  assert(line:find('space-platform-foundation (ghosts need at least 3, hub has 1)',1,true) and line:find('(the first 3 of 13 tile-ghosts counted)',1,true),line)
  hub_inv[2]=stack('space-platform-foundation',20)
  runtime.space.GHOST_CAP=caps
  blocked=bot('platforms',{platform='Starling'}).platforms[1].construction_blocked
  for _,l in ipairs(blocked) do assert(not l:find('at least',1,true),l) end
end
setmetatable(collector,nil)
-- describe lists platform on both.
local d=runtime.dispatch{action='describe',args={},bot='astra'}
assert(d.actions.inspect.platform and d.actions.configure.platform)
print('platform_inspect: ok')
