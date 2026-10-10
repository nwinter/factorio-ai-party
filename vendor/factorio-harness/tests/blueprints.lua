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
print('blueprint policy tests passed')
