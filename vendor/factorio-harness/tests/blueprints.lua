-- Run with lua tests/blueprints.lua. Engine integration additionally validates
-- Factorio's own blueprint/cursor behavior; these tests focus on policy edges.
local destroyed, captured, built = 0,0,0
local sources, exports = {},{}
local function stack(data)
  local s={_data=data or {}}
  local methods={}
  setmetatable(s,{__index=function(t,k)
    if methods[k] then return methods[k] end
    if k=='valid_for_read' then return t._data.kind~=nil end
    if k=='is_blueprint' then return t._data.kind=='blueprint' end
    if k=='is_blueprint_book' then return t._data.kind=='book' end
    return t._data[k]
  end,__newindex=function(t,k,v) t._data[k]=v end})
  function methods.import_stack(value) s._data=sources[value] or {}; return sources[value] and 0 or 1 end
  function methods.export_stack() exports[#exports+1]=s._data; local key='export'..#exports; sources[key]=s._data; return key end
  function methods.set_stack() s._data={kind='blueprint'} end
  function methods.is_blueprint_setup() return true end
  function methods.get_blueprint_entity_count() return #(s._data.entities or {}) end
  function methods.get_blueprint_entities() return s._data.entities end
  function methods.get_blueprint_tiles() return s._data.tiles end
  function methods.set_blueprint_entities(entities) s._data.entities=entities end
  function methods.set_blueprint_tiles(tiles) s._data.tiles=tiles end
  function methods.get_inventory() return s._data.inventory end
  function methods.create_blueprint(args)
    captured=captured+1
    -- _G.capture_world (the library tests): the world's entities in the area, numbered, with their wires.
    if _G.capture_world then s._data.entities,_G.mapping=_G.capture_world(args.area); return _G.mapping end
    s._data.entities={{name='chest',position={x=(args.area.left_top.x+args.area.right_bottom.x)/2,y=(args.area.left_top.y+args.area.right_bottom.y)/2}}}
    return s._data.mapping or _G.mapping or {}
  end
  function methods.swap_stack(other)
    assert(not rawget(other,'_book_slot'), 'moving a nested book entry invalidates its slot')
    s._data,other._data=other._data,s._data; return true
  end
  return s
end
storage={agent_harness={}}
defines={inventory={item_main=1},build_mode={normal=0},input_action=setmetatable({},{__index=function(_,k)return k end})}
game={create_inventory=function()
  return {[1]=stack(),destroy=function()destroyed=destroyed+1 end}
end}
prototypes={entity={chest={selection_box={left_top={x=-0.5,y=-0.5},right_bottom={x=0.5,y=0.5}}}}}
local p={index=1,position={x=0,y=0},cursor_stack=stack()}
p.force={name='player',is_chunk_charted=function(_,c)return not (c.x==1 and c.y==1) end}
p.surface={find_entities_filtered=function()return {} end}
p.build_from_cursor=function(args)built=built+1; p.last_build=args end
-- The inserter-target check (targets.lua, tested in tests/targets.lua): a stub
-- here, so a paste's wiring to it can be seen.
local targets_stub={check=function() return nil end}
-- The turret ammo requests (turretammo.lua, tested in tests/turretammo.lua): a stub here too.
local ammo_stub={check=function() end,request=function() return nil,'not a turret' end,add=function(rows,c) rows[#rows+1]=c end}
local H=dofile('mod/agent-harness_0.1.0/blueprints.lua'){
  targets=targets_stub,turretammo=ammo_stub,
  position=function(v)assert(type(v)=='table' and type(v.x)=='number' and type(v.y)=='number');return v end,
  visible=function(player,v)return (v.x-player.position.x)^2+(v.y-player.position.y)^2<=32*32 end,
  own_platform=function(player) local pl=player.surface.platform; return pl~=nil and pl.force==player.force end,
  real=function(player) if type(player)=='table' and rawget(player,'__platform') then return rawget(player,'__player') end return player end,
  placewhy=dofile('mod/agent-harness_0.1.0/placewhy.lua'){filters=function(e) return {filters=e._filters or {}} end},
  blocked=function(_,proto,pos) return string.format('placement blocked by big-rock (%g,%g)',pos.x,pos.y) end,
}
local box={left_top={x=-2,y=-2},right_bottom={x=2,y=2}}
local function fails(fn,pattern)
  local ok,err=pcall(fn); assert(not ok,'expected rejection'); assert(tostring(err):find(pattern),tostring(err))
end

-- Invalid/hidden requests must fail before snapshotting any world state.
fails(function()H.copy(p,{area={left_top={x=40,y=40},right_bottom={x=42,y=42}}})end,'uncharted')
assert(captured==0)
p.permission_group={allows_action=function()return false end}
fails(function()H.copy(p,{area=box})end,'permission')
assert(captured==0)
p.permission_group=nil

-- A failed import always destroys temporary metadata inventory.
local before=destroyed
fails(function()H.blueprint_import(p,{blueprint='bad'})end,'import failed')
assert(destroyed==before+1)

-- Cut marks only captured friendly entities, and never directly removes them.
local marks=0
mapping={{valid=true,force=p.force,order_deconstruction=function()marks=marks+1;return true end},
  {valid=true,force={name='enemy'},order_deconstruction=function()error('enemy mutation')end}}
local cut=H.cut(p,{area=box})
assert(cut.marked==1 and marks==1 and cut.tiles_marked==false)
assert(H.blueprint_export(p,{}).entities==1)

-- Occupied cursor is never destroyed or silently replaced.
p.cursor_stack._data={kind='item',name='iron-plate'}
fails(function()H.paste(p,{position={x=4,y=0}})end,'cursor must be empty')
assert(p.cursor_stack.name=='iron-plate' and built==0)
p.cursor_stack._data={}

-- Engine placement gets rotation and mirror flags, and restores an empty cursor.
local paste=H.paste(p,{position={x=4,y=0},direction='east',flip_horizontal=true})
assert(built==1 and p.last_build.direction==4 and p.last_build.flip_horizontal)
assert(not p.cursor_stack.valid_for_read and paste.count==0)
assert(paste.expected==1 and paste.reason, 'a short paste explains itself')
p.build_from_cursor=function()error('blocked callback')end
fails(function()H.paste(p,{position={x=4,y=0}})end,'blocked callback')
assert(not p.cursor_stack.valid_for_read)
p.build_from_cursor=function(args)built=built+1;p.last_build=args end

-- Nested books are validated and selected by explicit inventory slot path.
local leaf={kind='blueprint',entities={{name='chest',position={x=0,y=0}}}}
local nested_leaf=stack(leaf); rawset(nested_leaf,'_book_slot',true)
sources.book={kind='book',active_index=2,inventory={stack(),stack({kind='book',active_index=1,inventory={nested_leaf}})}}
assert(H.blueprint_import(p,{blueprint='book',slot='book'}).kind=='book')
assert(H.blueprint_export(p,{slot='book'}).kind=='book')
local inspection=H.blueprint_export(p,{slot='book',book_path={2,1},layout=true})
assert(inspection.layout[1].name=='chest' and inspection.layout[1].position.x==0)
assert(inspection.coordinates:find('snap'))
H.paste(p,{slot='book',book_path={2,1},position={x=4,y=0}})
fails(function()H.paste(p,{slot='book',book_path={1},position={x=4,y=0}})end,'empty')
assert(H.blueprint_delete(p,{slot='book'}).deleted)
-- Native capture returns world coordinates, even far from the spawn origin.
p.position={x=1000,y=1000}
H.copy(p,{area={left_top={x=998,y=998},right_bottom={x=1002,y=1002}},slot='distant'})
H.paste(p,{position={x=1004,y=1000},slot='distant'})
assert(p.last_build.position.x==1004)
p.position={x=0,y=0}

-- Harness request #144: deconstruct marks platform foundation tiles as a
-- player's planner does (LuaTile.order_deconstruction), and reports what the
-- engine accepted and refused. A fake platform: a 4x4 foundation (x,y -2..1)
-- with empty space beside it, the hub on the middle four tiles, a chest on
-- one tile and a ghost on another.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
prototypes.tile={['space-platform-foundation']={name='space-platform-foundation',mineable_properties={minable=true}},
  ['empty-space']={name='empty-space',mineable_properties={minable=false}}}
local tile_calls,tile_queries={},0
local function tile(name,x,y)
  local t={name=name,position={x=x,y=y},valid=true,marked=false,prototype=prototypes.tile[name]}
  t.to_be_deconstructed=function(force) assert(force==p.force); return t.marked end
  t.order_deconstruction=function(force,who)
    assert(force==p.force and who==p,'tile marks name the force and the real player')
    tile_calls[#tile_calls+1]=t
    if t.explode then error('engine error') end
    if t.refuse or t.under then return nil end
    t.marked=true; return {name='deconstructible-tile-proxy'}
  end
  t.cancel_deconstruction=function(force,who) assert(force==p.force and who==p); t.marked=false end
  return t
end
local ptiles,at={},{}
for x=-2,1 do for y=-2,1 do local t=tile('space-platform-foundation',x,y); ptiles[#ptiles+1]=t; at[x..','..y]=t end end
for y=-2,1 do ptiles[#ptiles+1]=tile('empty-space',2,y) end
local chest_marks=0
local hub={valid=true,name='space-platform-hub',type='space-platform-hub',force=p.force,minable=false,
  bounding_box={left_top={x=-1,y=-1},right_bottom={x=1,y=1}},to_be_deconstructed=function() return false end}
local chest={valid=true,name='chest',type='container',force=p.force,minable=true,marked=false,
  bounding_box={left_top={x=1.15,y=-1.85},right_bottom={x=1.85,y=-1.15}}}
chest.to_be_deconstructed=function() return chest.marked end
chest.order_deconstruction=function() chest_marks=chest_marks+1; chest.marked=true; return true end
chest.cancel_deconstruction=function() chest.marked=false end
local ghost={valid=true,name='entity-ghost',type='entity-ghost',force=p.force,minable=false,
  bounding_box={left_top={x=-1.85,y=1.15},right_bottom={x=-1.15,y=1.85}},to_be_deconstructed=function() return false end}
local ps={platform={force=p.force}}
ps.find_entities_filtered=function() return {hub,chest,ghost} end
ps.find_tiles_filtered=function(f)
  tile_queries=tile_queries+1
  assert(f.limit and f.limit<=20000,'tile queries are bounded')
  local list=type(f.name)=='string' and {f.name} or f.name
  assert(type(list)=='table' and #list>0,'tile queries are filtered by name')
  local names={}; for _,n in ipairs(list) do names[n]=true end
  local out={}
  for _,t in ipairs(ptiles) do
    local x,y=t.position.x,t.position.y
    if names[t.name] and x>=f.area.left_top.x and x<f.area.right_bottom.x and y>=f.area.left_top.y and y<f.area.right_bottom.y then out[#out+1]=t end
    if #out>=f.limit then break end
  end
  return out
end
local pp=setmetatable({__platform='alpha',__player=p},{__index=function(_,k)
  if k=='surface' then return ps elseif k=='position' then return {x=0,y=0} end return p[k] end})
local parea={left_top={x=-3,y=-3},right_bottom={x=3,y=3}}

-- Without tiles, entity deconstruction is unchanged and no tile is touched.
local plain=H.deconstruct(pp,{area=parea})
eq(plain.changed,1,'the chest is marked'); eq(chest_marks,1); eq(plain.tiles,false); eq(tile_queries,0,'no tile query without tiles')
chest.marked=false; chest_marks=0

-- tiles=true marks every minable tile in the area; empty space is never selected.
for _,k in ipairs({'-1,-1','-1,0','0,-1','0,0'}) do at[k].under=true end -- the engine refuses tiles under the hub
at['1,1'].refuse=true; at['-2,-2'].explode=true
local r=H.deconstruct(pp,{area=parea,tiles=true})
eq(r.tiles,true); eq(r.mode,'mark')
eq(r.changed,0,'tiles alone leave entities alone'); eq(chest_marks,0)
eq(r.tiles_marked,10); eq(r.tiles_refused,6); eq(r.tiles_already,0)
eq(r.refused.under_entity,4); eq(r.refused.engine,1); eq(r.refused.error,1); eq(r.refused.not_minable,nil)
eq(r.tiles_blocked,1,'the marked tile under the unmarked chest'); assert(r.note and r.note:find('chest'),tostring(r.note))
for _,t in ipairs(tile_calls) do eq(t.name,'space-platform-foundation') end
eq(at['-2,1'].marked,true,'a ghost does not block its tile')
eq(at['1,-2'].marked,true,'the engine accepted the tile under the chest')

-- A second pass counts the marks already there; named tiles work the same.
tile_calls={}
local again=H.deconstruct(pp,{area=parea,tiles={'space-platform-foundation'}})
eq(again.tiles_marked,0); eq(again.tiles_already,10); eq(again.tiles_refused,6)
-- Named tiles that cannot be mined are refused without asking the engine.
tile_calls={}
local void=H.deconstruct(pp,{area=parea,tiles={'empty-space'}})
eq(void.tiles_marked,0); eq(void.tiles_refused,4); eq(void.refused.not_minable,4); eq(#tile_calls,0)
fails(function() H.deconstruct(pp,{area=parea,tiles={'no-such-tile'}}) end,'unknown tile no%-such%-tile')
fails(function() H.deconstruct(pp,{area=parea,tiles='yes'}) end,'tiles requires true or')
fails(function() H.deconstruct(pp,{area=parea,tiles={}}) end,'tiles requires true or')

-- With tiles, entities are marked only when entity filters name them.
local both=H.deconstruct(pp,{area=parea,tiles=true,entity_names={'chest'}})
eq(both.changed,1); eq(chest.marked,true); eq(both.tiles_already,10)
eq(both.tiles_blocked,0,'a marked chest blocks nothing')

-- Cancelling with tiles clears the tile marks only; without, entities as before.
local undone=H.cancel_deconstruction(pp,{area=parea,tiles=true})
eq(undone.mode,'cancel'); eq(undone.tiles_cancelled,10); eq(undone.changed,0); eq(chest.marked,true)
for _,t in ipairs(ptiles) do eq(t.marked,false) end
local undone_entities=H.cancel_deconstruction(pp,{area=parea})
eq(undone_entities.changed,1); eq(chest.marked,false); eq(undone_entities.tiles,false)

-- Our tile ghosts of the named tiles go, as a planner over them removes them
-- (Grok, shift10 06:20: tiles ["landfill"] marked 0 where landfill was planned
-- over water; only an unfiltered deconstruct removed the 41 ghosts).
prototypes.tile.landfill={name='landfill',mineable_properties={minable=true}}
local function tghost(name,x,y,force)
  local g={valid=true,name='tile-ghost',type='tile-ghost',ghost_name=name,force=force or p.force,position={x=x,y=y}}
  g.order_deconstruction=function(f,who) assert(f==p.force and who==p,'ghost removal names the force and the real player'); g.valid=false; return true end
  return g
end
local tghosts={tghost('landfill',-2.5,2.5),tghost('landfill',-1.5,2.5),tghost('space-platform-foundation',0.5,2.5)}
local find_entities=ps.find_entities_filtered
ps.find_entities_filtered=function(f)
  if f.type=='tile-ghost' then
    assert(f.force==p.force and f.limit,'our tile ghosts, bounded')
    local out={}; for _,g in ipairs(tghosts) do if g.valid then out[#out+1]=g end end; return out
  end
  return find_entities(f)
end
local lf=H.deconstruct(pp,{area=parea,tiles={'landfill'}})
eq(lf.tile_ghosts_removed,2); eq(lf.tiles_marked,0); eq(tghosts[3].valid,true,'another tile\'s ghost stays')
eq(H.cancel_deconstruction(pp,{area=parea,tiles={'landfill'}}).tile_ghosts_removed,nil,'cancelling leaves ghosts alone')
-- tiles=true: the ghosts of every minable tile.
local all=H.deconstruct(pp,{area=parea,tiles=true})
eq(all.tile_ghosts_removed,1); eq(tghosts[3].valid,false)
H.cancel_deconstruction(pp,{area=parea,tiles=true})
ps.find_entities_filtered=find_entities

-- The area is capped as for entities, and so is the tile count.
fails(function() H.deconstruct(pp,{area={left_top={x=-200,y=-200},right_bottom={x=100,y=100}},tiles=true}) end,'at most 256')
local bounded=ps.find_tiles_filtered
ps.find_tiles_filtered=function(f) local out={}; for i=1,f.limit do out[i]=tile('space-platform-foundation',0,0) end; return out end
fails(function() H.deconstruct(pp,{area=parea,tiles=true}) end,'area tile limit')
ps.find_tiles_filtered=bounded
-- Off a platform, tiles still need charted chunks.
fails(function() H.deconstruct(p,{area={left_top={x=40,y=40},right_bottom={x=42,y=42}},tiles=true}) end,'uncharted')

-- A short paste says, per blueprint entity, why it is not there (Astra,
-- shift06 14:26: a 50-entity Sunward paste returned count 0, existing 37 and
-- nothing about the other 13). A platform: foundation from y=-2 down, empty
-- space above. The game shifts the paste to (10,0) though it was asked for
-- (10.9,0.2): the shift is read from what stands where the layout says.
local ground,space={layers={ground_tile=true}},{layers={empty_space=true}}
prototypes.tile['space-platform-foundation'].collision_mask=ground
prototypes.tile['empty-space'].collision_mask=space
prototypes.entity['asteroid-collector']={name='asteroid-collector',tile_width=3,tile_height=3,
  selection_box={left_top={x=-1.5,y=-1.5},right_bottom={x=1.5,y=1.5}},
  tile_buildability_rules={{area={left_top={x=-1.4,y=-0.4},right_bottom={x=1.4,y=1.4}},required_tiles=ground,colliding_tiles=space},
    {area={left_top={x=-1.4,y=-4.4},right_bottom={x=1.4,y=-0.6}},required_tiles=space,colliding_tiles=ground}}}
prototypes.entity['assembling-machine-1']={name='assembling-machine-1',tile_width=3,tile_height=3,
  selection_box={left_top={x=-1.5,y=-1.5},right_bottom={x=1.5,y=1.5}}}
defines.build_check_type={manual_ghost=2}
local world,unit={},100
local function put(name,x,y,extra)
  unit=unit+1
  local e={valid=true,name=name,type='container',position={x=x,y=y},force=p.force,unit_number=unit}
  for k,v in pairs(extra or {}) do e[k]=v end
  world[#world+1]=e
  return e
end
local function ghost(name,x,y,extra)
  return put('entity-ghost',x,y,{type='entity-ghost',ghost_name=name,_filters=extra and extra._filters})
end
-- From before: the assembler built with another recipe, a collector ghost with no filter, a stray chest.
put('assembling-machine-1',6.5,1.5,{type='assembling-machine',get_recipe=function() return {name='iron-gear-wheel'} end})
ghost('asteroid-collector',3.5,-1.5,{_filters={}})
put('chest',12.5,3.5)
local s2={platform={force=p.force}}
s2.get_tile=function(_,y) local name=y>=-2 and 'space-platform-foundation' or 'empty-space'; return {name=name,prototype=prototypes.tile[name]} end
s2.find_entities_filtered=function(f)
  local types=type(f.type)=='table' and f.type or f.type and {f.type}
  local out={}
  for _,e in ipairs(world) do
    local ok=e.valid and e.position.x>=f.area.left_top.x and e.position.x<=f.area.right_bottom.x
      and e.position.y>=f.area.left_top.y and e.position.y<=f.area.right_bottom.y
    if ok and types then ok=false; for _,t in ipairs(types) do if e.type==t then ok=true end end end
    if ok then out[#out+1]=e end
  end
  return out
end
s2.can_place_entity=function(a) eq(a.build_check_type,2); return not (a.position.x==8.5 and a.position.y==2.5) end
local bp={kind='blueprint',entities={
  {name='asteroid-collector',position={x=0.5,y=-1.5},chunk_filter={{index=1,name='metallic-asteroid-chunk'}}}, -- placed
  {name='asteroid-collector',position={x=4.5,y=0.5}},                -- its front on foundation: tile rule 2
  {name='assembling-machine-1',position={x=-3.5,y=1.5},recipe='copper-cable'}, -- there, other recipe
  {name='chest',position={x=-1.5,y=2.5}},                             -- a rock in the way
  {name='chest',position={x=1.5,y=2.5}},                              -- placed
  {name='asteroid-collector',position={x=-6.5,y=-1.5},chunk_filter={{index=1,name='metallic-asteroid-chunk'}}}}} -- an old ghost, no filter
sources.sunward=bp
local accept={['10.5,-1.5']=true,['11.5,2.5']=true}
local stack_build=function(args)
  for _,e in ipairs(bp.entities) do
    local x,y=10+e.position.x,0+e.position.y
    if accept[x..','..y] then ghost(e.name,x,y) end
  end
  eq(args.surface,s2)
end
H.blueprint_import(p,{blueprint='sunward',slot='sunward'})
local pp2=setmetatable({__platform='Sunward',__player=p},{__index=function(_,k)
  if k=='surface' then return s2 elseif k=='position' then return {x=0,y=0} end return p[k] end})
local make=game.create_inventory
game.create_inventory=function() local inv=make(); rawset(inv[1],'build_blueprint',stack_build); return inv end
local r2=H.paste(pp2,{slot='sunward',position={x=10.9,y=0.2}})
game.create_inventory=make
eq(r2.count,2,'two new ghosts'); eq(r2.expected,6); eq(r2.existing_entities,1); eq(r2.existing_ghosts,1)
eq(r2.not_placed_count,2); eq(#r2.not_placed,2)
eq(r2.inserters_without_target,nil,'no inserter in it')
-- A paste hands its new inserter ghosts to the target check and lists what it finds.
do
  local seen
  targets_stub.check=function(list,max) seen=list; eq(max,16); return {{name='inserter',position={x=20.5,y=0.5},missing='no drop target'}},nil end
  sources.lone={kind='blueprint',entities={{name='chest',position={x=0.5,y=0.5}}}}
  H.blueprint_import(p,{blueprint='lone',slot='lone'})
  local build=function() ghost('inserter',20.5,0.5).ghost_type='inserter'; ghost('chest',21.5,0.5).ghost_type='container' end
  game.create_inventory=function() local inv=make(); rawset(inv[1],'build_blueprint',build); return inv end
  local r=H.paste(pp2,{slot='lone',position={x=20.5,y=0.5}})
  game.create_inventory=make
  eq(#seen,1,'the inserter ghost only'); eq(seen[1].ghost_type,'inserter'); eq(r.inserters_without_target[1].missing,'no drop target')
  targets_stub.check=function() return nil end
  eq(r.ammo_requests,nil,'no turret ghost')
end
-- A paste asks for ammo on each new turret ghost, with the call's ammo (Astra, shift10: turrets rebuilt empty);
-- a bad ammo argument fails the paste before anything is placed.
do
  local asked={}
  ammo_stub.request=function(e,what) asked[#asked+1]={e=e,what=what}
    if e.ghost_type=='ammo-turret' then return {name='firearm-magazine',count=what and what.count or 10,network_holds=40} end
    return nil,'not a turret' end
  sources.guns={kind='blueprint',entities={{name='chest',position={x=0.5,y=0.5}}}}
  H.blueprint_import(p,{blueprint='guns',slot='guns'})
  local build=function()
    ghost('gun-turret',30,0).ghost_type='ammo-turret'; ghost('gun-turret',31,1).ghost_type='ammo-turret'; ghost('chest',29.5,0.5).ghost_type='container'
  end
  game.create_inventory=function() local inv=make(); rawset(inv[1],'build_blueprint',build); return inv end
  local r=H.paste(pp2,{slot='guns',position={x=30,y=0},ammo={count=20}})
  eq(#asked,3,'every new ghost is offered'); eq(asked[1].what.count,20)
  eq(#r.ammo_requests,2); eq(r.ammo_requests[1].count,20)
  ammo_stub.check=function(what) assert(what==nil or what=='firearm-magazine','ammo: not an ammo item: '..tostring(what)) end
  local placed=#asked
  local ok,err=pcall(H.paste,pp2,{slot='guns',position={x=40,y=0},ammo='iron-plate'})
  assert(not ok and tostring(err):find('not an ammo item: iron-plate',1,true),tostring(err)); eq(#asked,placed,'nothing placed')
  game.create_inventory=make
  ammo_stub.check=function() end; ammo_stub.request=function() return nil,'not a turret' end
end
local np={}
for _,row in ipairs(r2.not_placed) do np[row.position.x..','..row.position.y]=row end
local rule=np['14.5,0.5']
assert(rule and rule.name=='asteroid-collector' and rule.direction=='north','the collector at its real spot, not the asked-for shift')
assert(rule.reason:find('breaks its tile rule 2 facing north: tiles x 13..15, y %-4..%-1 need empty_space and must not be ground_tile; 6 of 12 do not'),rule.reason)
eq(np['8.5,2.5'].reason,'placement blocked by big-rock (8.5,2.5)')
eq(r2.settings_differ_count,2)
local sd={}
for _,row in ipairs(r2.settings_differ) do sd[row.name]=row end
eq(sd['assembling-machine-1'].differs[1],'recipe iron-gear-wheel, blueprint copper-cable')
eq(sd['assembling-machine-1'].fix,'configure {position={x=6.5,y=1.5}, recipe=copper-cable}')
eq(sd['asteroid-collector'].differs[1],'filters none, blueprint metallic-asteroid-chunk'); eq(sd['asteroid-collector'].ghost,true)
assert(sd['asteroid-collector'].fix:find('filters=[metallic-asteroid-chunk]',1,true) and sd['asteroid-collector'].fix:find('a ghost',1,true))
assert(r2.reason:find('2 already there from before (1 built, 1 ghosts)',1,true) and r2.reason:find('2 not placed: not_placed says why',1,true)
  and r2.reason:find('settings_differ',1,true),r2.reason)

-- Modules: counted from the blueprint's 2.0 item requests against the module inventory.
local W=dofile('mod/agent-harness_0.1.0/placewhy.lua'){}
prototypes.item={['speed-module']={type='module'},['iron-plate']={type='item'}}
local am={valid=true,type='assembling-machine',position={x=1.5,y=1.5},get_recipe=function() return {name='copper-cable'} end,
  get_module_inventory=function() return {get_contents=function() return {{name='speed-module',count=1,quality='normal'}} end} end}
local d=W.settings_diff(am,{name='assembling-machine-2',recipe='copper-cable',items={{id={name='speed-module'},items={in_inventory={{inventory=4,stack=0},{inventory=4,stack=1}}}},
  {id={name='iron-plate'},items={in_inventory={{inventory=2,stack=0,count=5}}}}}})
eq(d.differs[1],'modules speed-module*1, blueprint speed-module*2'); assert(d.fix:find('transfer',1,true),d.fix)
eq(W.settings_diff(am,{recipe='copper-cable'}),nil,'the same settings: nothing to say')
eq(W.tile_rules(s2,prototypes.entity.chest,{x=0,y=0},0),nil)

-- Forced paste (Astra 18:51: a Sunward paste made 0 ghosts when one entity collided; place_ghosts one by one lost
-- the blueprint's wires). The mode goes to the engine as a player's shift-paste (ctrl+shift: superforced).
defines.build_mode={normal=0,forced=1,superforced=2}
p.build_from_cursor=function(args) built=built+1; p.last_build=args end
H.paste(p,{position={x=4,y=0},mode='forced'}); eq(p.last_build.build_mode,1)
H.paste(p,{position={x=4,y=0},mode='superforced'}); eq(p.last_build.build_mode,2)
H.paste(p,{position={x=4,y=0}}); eq(p.last_build.build_mode,0,'normal by default')
fails(function() H.paste(p,{position={x=4,y=0},mode='shift'}) end,'paste mode must be normal, forced or superforced')
-- On a platform: three wired chests, the third where a rock stands. The engine places ghosts where they fit, marks
-- the rock, and connects one of the two wires between the placed ghosts; the harness connects the other and counts
-- the wire to the unplaced chest apart.
local w3,links={},{}
local function connector(e,id)
  local c={owner=e,id=id}
  c.is_connected_to=function(o) return links[e.unit_number..':'..id..'-'..o.owner.unit_number..':'..o.id]==true end
  c.connect_to=function(o,reach)
    eq(reach,false,'no reach check, as a paste')
    links[e.unit_number..':'..id..'-'..o.owner.unit_number..':'..o.id]=true
    links[o.owner.unit_number..':'..o.id..'-'..e.unit_number..':'..id]=true
    return true
  end
  return c
end
local function wghost(name,x,y)
  unit=unit+1
  local e={valid=true,name='entity-ghost',type='entity-ghost',ghost_name=name,position={x=x,y=y},force=p.force,unit_number=unit}
  local cs={}
  e.get_wire_connector=function(id,make) assert(make==true); cs[id]=cs[id] or connector(e,id); return cs[id] end
  w3[#w3+1]=e
  return e
end
local rock={valid=true,name='big-rock',type='simple-entity',position={x=22.5,y=0.5},force={name='neutral'},marked=false}
local old_rock={valid=true,name='huge-rock',type='simple-entity',position={x=24.5,y=3.5},force={name='neutral'},marked=true}
w3[#w3+1]=rock; w3[#w3+1]=old_rock
local s3={platform={force=p.force}}
s3.get_tile=function() return {name='space-platform-foundation',prototype=prototypes.tile['space-platform-foundation']} end
s3.find_entities_filtered=function(f)
  local types=type(f.type)=='table' and f.type or f.type and {f.type}
  local out={}
  for _,e in ipairs(w3) do
    local ok=e.valid and e.position.x>=f.area.left_top.x and e.position.x<=f.area.right_bottom.x
      and e.position.y>=f.area.left_top.y and e.position.y<=f.area.right_bottom.y
    if ok and f.force then ok=e.force==f.force end
    if ok and f.to_be_deconstructed~=nil then ok=e.marked==f.to_be_deconstructed end
    if ok and types then ok=false; for _,t in ipairs(types) do if e.type==t then ok=true end end end
    if ok then out[#out+1]=e end
  end
  return out
end
s3.can_place_entity=function(a) return not (a.position.x==22.5 and a.position.y==0.5) end
sources.audit={kind='blueprint',entities={
  {entity_number=1,name='chest',position={x=-2.5,y=0.5},wires={{1,1,2,1},{1,2,2,2}}},
  {entity_number=2,name='chest',position={x=0.5,y=0.5},wires={{2,1,1,1},{2,2,1,2},{2,1,3,1}}},
  {entity_number=3,name='chest',position={x=2.5,y=0.5},wires={{3,1,2,1}}}}}
H.blueprint_import(p,{blueprint='audit',slot='ferry-module-audit-north'})
local seen_mode
local forced_build=function(args)
  seen_mode=args.build_mode; eq(args.surface,s3)
  local g1,g2=wghost('chest',17.5,0.5),wghost('chest',20.5,0.5)
  g1.get_wire_connector(2,true).connect_to(g2.get_wire_connector(2,true),false)  -- the engine's own wire
  rock.marked=true
end
game.create_inventory=function() local inv=make(); rawset(inv[1],'build_blueprint',forced_build); return inv end
local pp3=setmetatable({__platform='Sunward',__player=p},{__index=function(_,k)
  if k=='surface' then return s3 elseif k=='position' then return {x=0,y=0} end return p[k] end})
local r3=H.paste(pp3,{slot='ferry-module-audit-north',position={x=20,y=0},mode='forced'})
game.create_inventory=make
eq(seen_mode,1,'build_blueprint gets the mode on a platform'); eq(r3.mode,'forced')
eq(r3.count,2); eq(r3.not_placed_count,1); eq(r3.not_placed[1].reason,'placement blocked by big-rock (22.5,0.5)')
eq(r3.marked_for_deconstruction,1,'the rock this paste marked, not the one marked before'); eq(r3.marked_by_name['big-rock'],1)
eq(r3.wires.in_blueprint,3); eq(r3.wires.added,1); eq(r3.wires.connected,1); eq(r3.wires.end_not_placed,1); eq(r3.wires.failed,0)
eq(r3.wires.ends_not_placed[1],'chest #3')
assert(w3[3].get_wire_connector(1,true).is_connected_to(w3[4].get_wire_connector(1,true)),'the red wire between the ghosts')
-- A paste with no wires reports none; a normal paste reports no marks.
eq(r2.wires,nil); eq(r2.marked_for_deconstruction,nil); eq(r2.mode,nil)

-- Hub anchoring (Astra 18:55: a 33-entity paste placed 0, a 22-entity one landed at another offset). The game puts
-- the blueprint's center at the paste position; this blueprint's hub is off its center: the hub's 8x8 at x -4..4,
-- a chest out to x 11, so the center is (3.5,0). Pasted with position (0,0) its hub lands at (-3.5,0) and collides
-- with the platform's hub: nothing. Anchored, the paste goes to (3.5,0) and the hub lands on the platform's hub.
prototypes.entity['space-platform-hub']={name='space-platform-hub',tile_width=8,tile_height=8,
  selection_box={left_top={x=-4,y=-4},right_bottom={x=4,y=4}}}
local w4={}
local phub={valid=true,name='space-platform-hub',type='space-platform-hub',position={x=0,y=0},force=p.force,unit_number=900}
w4[1]=phub
local s4={platform={force=p.force,hub=phub}}
s4.get_tile=s3.get_tile
s4.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(w4) do
    local ok=e.valid and e.position.x>=f.area.left_top.x and e.position.x<=f.area.right_bottom.x
      and e.position.y>=f.area.left_top.y and e.position.y<=f.area.right_bottom.y
    if ok and f.type then ok=false; for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do if e.type==t then ok=true end end end
    if ok and f.to_be_deconstructed~=nil then ok=false end
    if ok then out[#out+1]=e end
  end
  return out
end
s4.can_place_entity=function() return true end
sources.offhub={kind='blueprint',entities={{entity_number=1,name='space-platform-hub',position={x=0,y=0}},
  {entity_number=2,name='chest',position={x=10.5,y=0.5}}}}
H.blueprint_import(p,{blueprint='offhub',slot='offhub'})
local asked
local hub_build=function(args)
  asked=args.position
  local hx=args.position.x+(0-3.5)
  if math.abs(hx)>0.01 or math.abs(args.position.y)>0.01 then return end  -- the hub collides: all or nothing
  unit=unit+1
  w4[#w4+1]={valid=true,name='entity-ghost',type='entity-ghost',ghost_name='chest',position={x=args.position.x+7,y=0.5},force=p.force,unit_number=unit}
end
game.create_inventory=function() local inv=make(); rawset(inv[1],'build_blueprint',hub_build); return inv end
local pp4=setmetatable({__platform='Sunward',__player=p},{__index=function(_,k)
  if k=='surface' then return s4 elseif k=='position' then return {x=0,y=0} end return p[k] end})
local off=H.paste(pp4,{slot='offhub',position={x=0,y=0},anchor='center'})
eq(asked.x,0); eq(off.count,0,'the old way: the hub collides, nothing placed'); eq(off.anchor,nil)
local r4=H.paste(pp4,{slot='offhub'})
eq(asked.x,3.5); eq(asked.y,0); eq(r4.count,1); eq(w4[#w4].position.x,10.5)
eq(r4.anchor.by,'hub'); eq(r4.anchor.aligned,true); eq(r4.anchor.hub.x,0); eq(r4.anchor.hub_landed.x,0)
eq(r4.anchor.paste_position.x,3.5); eq(r4.origin_at.x,0); eq(r4.center_at.x,3.5); eq(r4.center_at.y,0)
eq(r4.existing_entities,1,'the platform\'s hub stands where the blueprint\'s goes'); eq(r4.not_placed_count,0)
-- position names where the blueprint's hub goes (hub at 0,0 is what agents pass)
local r5=H.paste(pp4,{slot='offhub',position={x=0,y=0}}); eq(asked.x,3.5); eq(r5.anchor.aligned,true)
-- turned east, the hub's offset from the center turns too
H.paste(pp4,{slot='offhub',direction='east'}); eq(asked.x,0); eq(math.abs(asked.y),3.5)
game.create_inventory=make
fails(function() H.paste(p,{slot='offhub',position={x=0,y=0},anchor='hub'}) end,'anchor hub works on a platform')
fails(function() H.paste(pp4,{slot='ferry-module-audit-north',anchor='hub'}) end,'holds no space%-platform%-hub')
fails(function() H.paste(pp4,{slot='offhub',anchor='middle'}) end,'anchor must be hub, center or saved')
fails(function() H.paste(p,{slot='offhub'}) end,'position is required')
-- A paste dry run's plan (H.plan): where each blueprint entity and tile would land; nothing is placed. The
-- center is the middle of the box around every entity's tiles and every tile, here (0,0.5); the layout shifts by
-- whole tiles onto the grid.
sources.plan={kind='blueprint',entities={{entity_number=1,name='assembling-machine-1',position={x=-1.5,y=0.5}},
  {entity_number=2,name='chest',position={x=2.5,y=0.5},direction=4}},tiles={{name='landfill',position={x=-3,y=-1}}}}
H.blueprint_import(p,{blueprint='plan',slot='plan'})
local before_plan=built
local pl=H.plan(p,{slot='plan',position={x=10.3,y=5.2}})
eq(built,before_plan,'a plan places nothing')
eq(pl.entities[1].position.x,8.5); eq(pl.entities[1].position.y,5.5); eq(pl.entities[2].position.x,12.5); eq(pl.entities[2].direction,4)
eq(pl.tiles[1].position.x,7.5); eq(pl.tiles[1].position.y,4.5); eq(pl.origin_at.x,10); eq(pl.origin_at.y,5); eq(pl.center_at.y,5.5)
eq(pl.mode,'normal'); eq(pl.slot,'plan')
-- Turned east: offsets turn a quarter clockwise and directions with them.
pl=H.plan(p,{slot='plan',position={x=10.3,y=5.2},direction='east'})
eq(pl.entities[1].position.x,10.5); eq(pl.entities[1].position.y,3.5); eq(pl.entities[2].position.x,10.5); eq(pl.entities[2].position.y,7.5)
eq(pl.entities[2].direction,8)
-- The number inspect prints turns it the same (friction1300); a diagonal does not turn a blueprint.
pl=H.plan(p,{slot='plan',position={x=10.3,y=5.2},direction=4})
eq(pl.entities[1].position.x,10.5); eq(pl.entities[2].direction,8)
fails(function() H.plan(p,{slot='plan',position={x=10.3,y=5.2},direction=2}) end,'blueprint direction must be north, east, south, or west %(or 0, 4, 8, 12%)')
-- Flipped: positions and directions mirror before the turn.
pl=H.plan(p,{slot='plan',position={x=10.3,y=5.2},flip_horizontal=true})
eq(pl.entities[1].position.x,11.5); eq(pl.entities[2].position.x,7.5); eq(pl.entities[2].direction,12)
-- On a platform a blueprint with a hub is planned by its hub, as the paste places it.
local hp=H.plan(pp4,{slot='offhub'})
eq(hp.anchor.by,'hub'); eq(hp.entities[1].position.x,0); eq(hp.entities[1].position.y,0); eq(hp.entities[2].position.x,10.5)
fails(function() H.plan(p,{slot='plan'}) end,'position is required')
fails(function() H.plan(pp4,{slot='offhub',flip_horizontal=true}) end,'flips are not supported')

-- The team library (operator 00:50): blueprint_save captures our entities by area or positions into a named entry in
-- storage; blueprint_list lists it; blueprint_place, paste and plan take name; delete and rename: the author any time,
-- anyone after 24 game hours unused; the operator read gives the strings changed since a revision.
do
  game.tick=1000
  local world={}
  for i,x in ipairs({1.5,3.5,5.5}) do
    world[i]={valid=true,name='chest',unit_number=10+i,position={x=x,y=1.5},force=p.force,
      bounding_box={left_top={x=x-0.5,y=1},right_bottom={x=x+0.5,y=2}}}
  end
  -- Chests 1-2 and 2-3 joined by a red wire.
  _G.capture_world=function(area)
    local list,map={},{}
    for _,e in ipairs(world) do
      if e.position.x>area.left_top.x and e.position.x<area.right_bottom.x then
        list[#list+1]={entity_number=#list+1,name=e.name,position={x=e.position.x,y=e.position.y}}; map[#list]=e
      end
    end
    for i,b in ipairs(list) do
      if list[i+1] then b.wires={{i,1,i+1,1}} end
    end
    return list,map
  end
  local L=dofile('mod/agent-harness_0.1.0/blueprints.lua'){
    position=function(v) assert(type(v)=='table' and type(v.x)=='number' and type(v.y)=='number'); return v end,
    own_platform=function() return false end, real=function(pl) return pl end,
    placewhy=dofile('mod/agent-harness_0.1.0/placewhy.lua'){filters=function() return {filters={}} end},
    blocked=function() return 'blocked' end,
    who=function(pl) return pl.name end,
    entity=function(_,args)
      for _,e in ipairs(world) do if e.position.x==args.position.x and e.position.y==args.position.y then return e end end
      error('entity not found',0)
    end}
  p.name='sol'
  local luna={index=2,name='luna',force=p.force,surface=p.surface,position=p.position}
  local area={left_top={x=0,y=0},right_bottom={x=8,y=4}}
  local s=L.blueprint_save(p,{name='chest-row',area=area,description='three chests,\n wired',anchor={x=1.5,y=1.5}})
  eq(s.name,'chest-row'); eq(s.author,'sol'); eq(s.entities,3); eq(s.footprint,'5x1'); eq(s.counts,'chest*3'); eq(s.anchor,true)
  eq(s.last_used,'never'); eq(s.replaced,nil)
  local lib=storage.agent_harness.bplibrary
  eq(lib.entries['chest-row'].description,'three chests, wired')
  eq(lib.entries['chest-row'].anchor.x,-2.5); eq(lib.entries['chest-row'].anchor.y,-0.5)
  -- By positions: only those entities, renumbered, with the wires between them.
  local pair=L.blueprint_save(luna,{name='pair',positions={{x=3.5,y=1.5},{x=5.5,y=1.5}}})
  eq(pair.entities,2); eq(pair.author,'luna')
  local saved=sources[lib.entries.pair.string].entities
  eq(saved[1].entity_number,1); eq(saved[2].entity_number,2); eq(saved[1].wires[1][1],1); eq(saved[1].wires[1][3],2); eq(saved[2].wires,nil)
  local ends=L.blueprint_save(luna,{name='ends',positions={{x=1.5,y=1.5},{x=5.5,y=1.5}}})
  eq(ends.entities,2); eq(sources[lib.entries.ends.string].entities[1].wires,nil)
  -- The list: the team's entries beside your own slots.
  local list=L.blueprint_list(p,{})
  eq(#list.library,3); eq(list.library[1].name,'chest-row'); eq(list.library[2].name,'ends'); eq(list.library_limit,64)
  eq(list.library[1].description,'three chests, wired'); assert(list.slots,'slots are listed too')
  eq(L.blueprint_list(p,{name='chest-row'}).anchor.x,-2.5)
  -- Placed by name: the saved anchor lands at position; the use is recorded.
  game.tick=2000
  local placed=L.blueprint_place(p,{name='chest-row',position={x=10.5,y=10.5}})
  eq(placed.name,'chest-row'); eq(placed.slot,nil); eq(placed.anchor.by,'saved')
  eq(p.last_build.position.x,12.5); eq(p.last_build.position.y,10.5)
  eq(lib.entries['chest-row'].uses,1); eq(lib.entries['chest-row'].last_user,'sol')
  local planned=L.plan(p,{name='chest-row',position={x=10.5,y=10.5}})
  eq(planned.name,'chest-row'); eq(planned.anchor.anchor_landed.x,10.5); eq(planned.anchor.anchor_landed.y,10.5); eq(planned.anchor.aligned,true)
  eq(L.plan(p,{name='chest-row',position={x=10.5,y=10.5},anchor='center'}).anchor,nil)
  fails(function() L.plan(p,{name='pair',position={x=0,y=0},anchor='saved'}) end,'saved with an anchor')
  fails(function() L.plan(p,{name='chest-row',position={x=0,y=0},flip_horizontal=true}) end,'flips do not go with the saved anchor')
  fails(function() L.blueprint_place(p,{name='nope',position={x=0,y=0}}) end,'no library entry nope; entries: chest%-row, ends, pair')
  fails(function() L.blueprint_place(p,{name='pair',slot='x',position={x=0,y=0}}) end,'give name')
  -- Another agent changes an entry only after 24 game hours unused.
  fails(function() L.blueprint_delete(luna,{name='chest-row'}) end,"chest%-row is sol's entry; another agent may delete it after 24 game hours unused %(last used 0m ago%)")
  fails(function() L.blueprint_save(p,{name='pair',area=area}) end,"pair is luna's entry; another agent may replace it")
  fails(function() L.blueprint_rename(p,{name='ends',new_name='e2'}) end,'may rename it')
  eq(L.blueprint_rename(luna,{name='ends',new_name='end-pair'}).was,'ends'); eq(lib.entries.ends,nil); eq(lib.entries['end-pair'].name,'end-pair')
  fails(function() L.blueprint_rename(luna,{name='end-pair',new_name='pair'}) end,'has an entry pair already')
  eq(L.blueprint_save(p,{name='chest-row',area=area}).replaced,'sol')
  game.tick=2000+24*60*60*60
  eq(L.blueprint_delete(p,{name='pair'}).deleted,true); eq(lib.entries.pair,nil)
  -- The operator read: every entry, and the strings changed since a revision.
  local r=L.operator.blueprint_library({})
  eq(#r.entries,2); assert(r.entries[1].string and r.entries[2].string,'all strings')
  eq(r.revision,lib.revision)
  local later=L.operator.blueprint_library({since=r.revision})
  eq(later.entries[1].string,nil); eq(later.entries[1].name,'chest-row')
  -- Refusals: a bad name, both or neither of area and positions, an anchor outside, the limit.
  fails(function() L.blueprint_save(p,{name='bad name',area=area}) end,'name must be')
  fails(function() L.blueprint_save(p,{name='x',area=area,positions={{x=1.5,y=1.5}}}) end,'give area or positions')
  fails(function() L.blueprint_save(p,{name='x'}) end,'give area or positions')
  fails(function() L.blueprint_save(p,{name='x',area=area,anchor={x=20,y=1}}) end,'anchor must lie in the saved area')
  for i=1,62 do L.blueprint_save(p,{name='e'..i,area=area}) end
  fails(function() L.blueprint_save(p,{name='e63',area=area}) end,'holds 64 entries')
  _G.capture_world=nil; p.name=nil
end
print('blueprint policy tests passed')
