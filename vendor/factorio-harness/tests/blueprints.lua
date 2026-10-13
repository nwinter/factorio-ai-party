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
local H=dofile('mod/agent-harness_0.1.0/blueprints.lua'){
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
print('blueprint policy tests passed')
