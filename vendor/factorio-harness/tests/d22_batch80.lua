-- Run with lua tests/d22_batch80.lua. d22 batch80 AP1 (Astra #1851): a whole platform in one library blueprint
-- (blueprint_save {name, platform} without area, or an area over 256 tiles or 4096 entities on it), its foundation
-- tiles added to the engine's export, a paste refused past its limits, and blueprint_export in pages.
local function eq(a,b,m) if a~=b then error((m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b),2) end end
local function fails(fn,pattern)
  local ok,err=pcall(fn); assert(not ok,'expected rejection'); assert(tostring(err):find(pattern,1,true),tostring(err))
end
-- The world: our entities and the foundation, by position.
local world,tiles_at={},{}
local exports=0
helpers={encode_string=function(s) return 'E'..s end,decode_string=function(s) return s:sub(1,1)=='E' and s:sub(2) or nil end}
local function inside(pos,area) return pos.x>=area.left_top.x and pos.x<area.right_bottom.x and pos.y>=area.left_top.y and pos.y<area.right_bottom.y end
local function stack()
  local s={_data={}}
  local m={}
  function m.set_stack() s._data={kind='blueprint'} end
  function m.create_blueprint(args)
    local map={}
    if args.include_entities==false then
      local list={}
      if args.always_include_tiles then for _,t in ipairs(tiles_at) do if inside(t.position,args.area) then list[#list+1]={name=t.name,position={x=t.position.x,y=t.position.y}} end end end
      s._data.tiles=list
      return map
    end
    local list={}
    for _,e in ipairs(world) do
      if inside(e.position,args.area) then
        list[#list+1]={entity_number=#list+1,name=e.name,position={x=e.position.x,y=e.position.y},wires=e.wires}
        map[#list]=e
      end
    end
    s._data.entities=list
    return map
  end
  function m.get_blueprint_entities() return s._data.entities end
  function m.get_blueprint_tiles() return s._data.tiles end
  function m.set_blueprint_entities(list) s._data.entities=list; s._data.set=(s._data.set or 0)+1 end
  function m.export_stack()
    exports=exports+1
    local names={}
    for i,e in ipairs(s._data.entities or {}) do names[i]=string.format('{"entity_number":%d,"name":"%s","position":{"x":%g,"y":%g}}',e.entity_number,e.name,e.position.x,e.position.y) end
    return '0'..helpers.encode_string('{"blueprint":{"description":"'..tostring(s._data.blueprint_description)..'","entities":['..table.concat(names,',')..
      '],"item":"blueprint","label":"'..tostring(s._data.label)..'","version":1}}\n')
  end
  setmetatable(s,{__index=function(t,k)
    if m[k] then return m[k] end
    if k=='valid_for_read' then return t._data.kind~=nil end
    if k=='is_blueprint' then return t._data.kind=='blueprint' end
    return t._data[k]
  end,__newindex=function(t,k,v) t._data[k]=v end})
  return s
end
local destroyed=0
game={tick=100,create_inventory=function(n) local inv={destroy=function() destroyed=destroyed+1 end}; for i=1,n do inv[i]=stack() end; return inv end}
storage={agent_harness={}}
defines={inventory={item_main=1},build_mode={normal=0,forced=1,superforced=2},direction={north=0,east=4,south=8,west=12},input_action=setmetatable({},{__index=function(_,k) return k end})}
prototypes={entity={}}
local force={name='player',is_chunk_charted=function() return true end}
local function surface(name,platform)
  local s={name=name,platform=platform}
  function s.get_chunks()
    local seen,list={},{}
    for _,t in ipairs(tiles_at) do
      local cx,cy=math.floor(t.position.x/32),math.floor(t.position.y/32)
      local k=cx..','..cy
      if not seen[k] then seen[k]=true; list[#list+1]={x=cx,y=cy,area={left_top={x=cx*32,y=cy*32},right_bottom={x=cx*32+32,y=cy*32+32}}} end
    end
    local i=0
    return function() i=i+1; return list[i] end
  end
  function s.count_tiles_filtered(f)
    local n=0
    for _,t in ipairs(tiles_at) do if t.name==f.name and inside(t.position,f.area) then n=n+1; if f.limit and n>=f.limit then break end end end
    return n
  end
  function s.find_tiles_filtered(f)
    local list={}
    for _,t in ipairs(tiles_at) do if t.name==f.name and inside(t.position,f.area) then list[#list+1]=t; if f.limit and #list>=f.limit then break end end end
    return list
  end
  function s.find_entities_filtered(f)
    local list={}
    for _,e in ipairs(world) do if inside(e.position,f.area) then list[#list+1]=e; if f.limit and #list>=f.limit then break end end end
    return list
  end
  function s.count_entities_filtered() return 0 end
  return s
end
local platform={name='Asterion',force=force}
local ship=surface('platform-7',platform)
local nauvis=surface('nauvis',nil)
local p={index=1,name='astra',force=force,surface=ship,position={x=0,y=0}}
local planet={index=2,name='sol',force=force,surface=nauvis,position={x=0,y=0}}
local H=dofile('mod/agent-harness_0.1.0/blueprints.lua'){
  position=function(v) assert(type(v)=='table' and type(v.x)=='number' and type(v.y)=='number'); return v end,
  own_platform=function(pl) local x=pl.surface.platform; return x~=nil and x.force==pl.force end,
  real=function(pl) return pl end, who=function(pl) return pl.name end,
  integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(type(v)=='number' and v>=lo and v<=hi,name..' out of range'); return v end,
  placewhy=dofile('mod/agent-harness_0.1.0/placewhy.lua'){filters=function() return {filters={}} end},
  blocked=function() return 'blocked' end}

-- A hull 30 wide, x -15..15, y -40..260: 9000 foundation tiles and 5000 entities, the hub at 0,0, two wired.
for y=-40,259 do for x=-15,14 do tiles_at[#tiles_at+1]={name='space-platform-foundation',position={x=x,y=y}} end end
world[1]={name='space-platform-hub',type='space-platform-hub',valid=true,position={x=0,y=0}}
for i=2,5000 do
  local x,y=-14.5+(i%29),-39.5+math.floor(i/29)*1.5
  world[i]={name=i%2==0 and 'inserter' or 'transport-belt',type='inserter',valid=true,position={x=x,y=y}}
end
world[2].wires={{2,1,3,1}}; world[3].wires={{3,1,2,1}}

-- The whole platform: no area.
local s=H.blueprint_save(p,{name='Asterion-whole',description='the  hull,\n whole'})
eq(s.entities,5000,'every entity'); eq(s.tiles,9000,'its foundation'); eq(s.whole,true); eq(s.platform,'Asterion')
assert(s.note:find('the whole platform: 5000 entities, 9000 tiles, 1 wire',1,true),s.note)
assert(s.note:find('blueprint_place refuses it',1,true),s.note)
eq(exports,1,'one export of the entities')
local e=storage.agent_harness.bplibrary.entries['Asterion-whole']
eq(e.big,true); eq(e.labelled,true); eq(e.description,'the hull, whole')
local json=helpers.decode_string(e.string:sub(2))
assert(json:find('"label":"Asterion-whole"',1,true),'the label is in the string')
assert(json:find('"description":"the hull, whole"',1,true),'the description is in the string')
assert(json:find('"tiles":[{"position":{"x":-15,"y":-40},"name":"space-platform-foundation"}',1,true),'the tiles follow the entities')
local _,n=json:gsub('"name":"space%-platform%-foundation"','')
eq(n,9000,'every tile in the JSON')
assert(json:sub(-2)=='}}','the JSON closes')
eq(destroyed,1,'the two-stack inventory is destroyed')

-- Its export: the stored string in pages of 262144 bytes; the pages make the string.
assert(#e.string>262144,'long enough to page: '..#e.string)
local x1=H.blueprint_export(p,{name='Asterion-whole'})
eq(x1.whole,true); eq(x1.entities,5000); eq(x1.blueprint_bytes,#e.string); eq(x1.next_from,262145)
assert(x1.blueprint_page:find('bytes 1-262144 of',1,true),x1.blueprint_page)
local text,x,pages=x1.blueprint,x1,1
while x.next_from do
  x=H.blueprint_export(p,{name='Asterion-whole',from=x.next_from}); text=text..x.blueprint; pages=pages+1
  eq(#x.blueprint<=262144,true,'a page at most 262144 bytes')
end
assert(x.blueprint_page:find('; the last',1,true),x.blueprint_page)
eq(pages,math.ceil(#e.string/262144))
eq(text,e.string,'the pages make the string')
eq(exports,1,'an export by name exports nothing again')
-- A paste or a layout of it is refused, naming the limits and the export.
fails(function() H.blueprint_place(p,{name='Asterion-whole',position={x=0,y=0}}) end,'holds 5000 entities and 9000 tiles')
fails(function() H.blueprint_export(p,{name='Asterion-whole',layout=true}) end,'blueprint_export {name} gives its string')
-- Listed as any entry.
local list=H.blueprint_list(p,{})
eq(list.library[1].name,'Asterion-whole'); eq(list.library[1].entities,5000)

-- tiles: false: the entities alone.
local nt=H.blueprint_save(p,{name='Asterion-ents',tiles=false})
eq(nt.tiles,nil); eq(storage.agent_harness.bplibrary.entries['Asterion-ents'].tiles,0)
assert(not helpers.decode_string(storage.agent_harness.bplibrary.entries['Asterion-ents'].string:sub(2)):find('"tiles"',1,true))

-- Astra's area (-58,-49)..(58,234), over 256 tiles high: clipped to the platform, the whole of it here; tiles only
-- with tiles: true, as an area's save.
local a=H.blueprint_save(p,{name='Asterion-hull',area={left_top={x=-58,y=-49},right_bottom={x=58,y=234}}})
eq(a.whole,nil); eq(a.entities,5000); eq(a.tiles,nil)
assert(a.note:find('the area on the platform',1,true),a.note)
-- An area without the hub: rebased on an even shift about its centre, entities and tiles alike.
local b=H.blueprint_save(p,{name='Asterion-aft',area={left_top={x=-30,y=100},right_bottom={x=30,y=400}},tiles=true})
local be=storage.agent_harness.bplibrary.entries['Asterion-aft']
local bj=helpers.decode_string(be.string:sub(2))
-- the box is clipped to the foundation's chunks (y 100..288): centre 194, the shift 0,194 (even)
eq(be.captured.right_bottom.y,288)
assert(bj:find('"tiles":[{"position":{"x":-15,"y":-94},',1,true),'tiles shifted by the area\'s origin: '..bj:sub(-200))
eq(b.tiles,30*160)
-- An area under 256 holding over 4096 entities goes the same way.
local c=H.blueprint_save(p,{name='Asterion-fore',area={left_top={x=-15,y=-40},right_bottom={x=15,y=200}}})
assert(c.entities>4096 and c.note:find('the area on the platform',1,true),c.note)
-- A small platform's whole: under the paste limits, not big; its export is the stored string, whole.
local small_world,small_tiles=world,tiles_at
world={world[1],{name='inserter',type='inserter',valid=true,position={x=1.5,y=1.5}},{name='inserter',type='inserter',valid=true,position={x=2.5,y=1.5}}}; tiles_at={}
for y=-5,4 do for x=-5,4 do tiles_at[#tiles_at+1]={name='space-platform-foundation',position={x=x,y=y}} end end
local sm=H.blueprint_save(p,{name='Spindle-whole'})
eq(sm.entities,3); eq(sm.tiles,100); assert(not sm.note:find('refuses',1,true),sm.note)
-- (the paste limits, not the tile planner's 16384)
assert(s.note:find("over a paste's 4096 entities, 8192 tiles",1,true),s.note)
local se=storage.agent_harness.bplibrary.entries['Spindle-whole']
eq(se.big,nil)
local sx=H.blueprint_export(p,{name='Spindle-whole'})
eq(sx.blueprint,se.string); eq(sx.next_from,nil); eq(sx.blueprint_page,nil)
world,tiles_at=small_world,small_tiles

-- On a planet an area or positions is still needed; a slot capture over 256 on a platform names the library save.
fails(function() H.blueprint_save(planet,{name='x'}) end,'give area or positions')
fails(function() H.blueprint_save(planet,{name='x',area={left_top={x=0,y=0},right_bottom={x=10,y=300}}}) end,'at most 256 by 256')
fails(function() H.blueprint_capture(p,{area={left_top={x=-58,y=-49},right_bottom={x=58,y=234}}}) end,'blueprint_save {name, platform} without area saves the whole platform')
-- from on an ordinary entry's export is refused.
storage.agent_harness.bplibrary.entries.plain={name='plain',author='sol',string='x',entities=1,tiles=0,counts={},footprint={w=1,h=1},saved_tick=0,uses=0}
fails(function() H.blueprint_export(p,{name='plain',from=2}) end,'this one comes whole')
print('d22_batch80 ok')
