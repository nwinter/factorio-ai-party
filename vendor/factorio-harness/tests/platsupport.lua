-- platform_plan support (batch26 C3, Sol: 1,619 foundation ghosts trimmed by hand over 32 launches): the foundation the
-- chosen entities need (footprints, underground spans, the fewest tiles joining them to the hub's floor), holes left
-- open, and the foundation tile ghosts that would go as deconstruct areas; entity ghosts not chosen on them named.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
prototypes={entity={['underground-belt']={max_underground_distance=5}}}
local function box(x,y,w,h) return {left_top={x=x-w/2,y=y-h/2},right_bottom={x=x+w/2,y=y+h/2}} end
local function ghost(name,t,x,y,w,h,dir,extra)
  local g={valid=true,type='entity-ghost',ghost_name=name,ghost_type=t,position={x=x,y=y},direction=dir or 0,bounding_box=box(x,y,w,h)}
  for k,v in pairs(extra or {}) do g[k]=v end
  return g
end
-- built floor x -2..7, y -2..1 round the hub; a blanket of tile ghosts x -2..9, y 2..7 and a far patch x 20..21, y 0..1
local built,tile_ghosts={},{}
for x=-2,7 do for y=-2,1 do built[#built+1]={position={x=x,y=y}} end end
for x=-2,9 do for y=2,7 do tile_ghosts[#tile_ghosts+1]={valid=true,type='tile-ghost',ghost_name='space-platform-foundation',position={x=x+0.5,y=y+0.5}} end end
for x=20,21 do for y=0,1 do tile_ghosts[#tile_ghosts+1]={valid=true,type='tile-ghost',ghost_name='space-platform-foundation',position={x=x+0.5,y=y+0.5}} end end
-- an assembler ghost on x 4..6, y 4..6; an underground belt pair ghost (0,5) -> (3,5) east, its span x 1..2; a chest ghost not
-- chosen at (8,7)
local asm=ghost('assembling-machine-2','assembling-machine',5.5,5.5,3,3)
local ug_in=ghost('underground-belt','underground-belt',0.5,5.5,1,1,4,{belt_to_ground_type='input'})
local ug_out=ghost('underground-belt','underground-belt',3.5,5.5,1,1,4,{belt_to_ground_type='output'})
local chest=ghost('iron-chest','container',8.5,7.5,1,1)
local hub={valid=true,name='space-platform-hub',type='space-platform-hub',position={x=0,y=0},bounding_box=box(0,0,4,4)}
local ents={hub,asm,ug_in,ug_out,chest}
local function near(e,q,r) return math.abs(e.position.x-q.x)<=r and math.abs(e.position.y-q.y)<=r end
local surface={
  find_tiles_filtered=function() return built end,
  find_entities_filtered=function(f)
    if f.type=='tile-ghost' then return tile_ghosts end
    if f.type=='entity-ghost' then return {asm,ug_in,ug_out,chest} end
    if type(f.type)=='table' then return {} end
    local out={}
    for _,e in ipairs(ents) do
      if f.position and near(e,f.position,f.radius or 0) then out[#out+1]=e
      elseif f.area and e.position.x>f.area[1][1] and e.position.x<f.area[2][1] and e.position.y>f.area[1][2] and e.position.y<f.area[2][2] then out[#out+1]=e
      elseif not f.position and not f.area then out[#out+1]=e end
    end
    return out
  end}
local pl={name='Sol',surface=surface,force='us',hub=hub}
local PP=require('platplan'){platform=function() return pl end,position=function(v) return v end}
-- every entity: the hub (on built floor), the assembler's 9 tiles, the pair's 2 ends and 2 span tiles, the chest, two
-- link tiles (y 2 and 3 in one column) joining x 0..6, y 4..6 to the hub's floor and two joining the chest to the assembler
local r=PP.read({},{platform='Sol',support=true})
eq(r.chosen,5)
eq(r.support.tile_ghosts,76); eq(r.support.footprints,9+2+1); eq(r.support.tunnels,2); eq(r.support.links,4)
eq(r.support.keep,9+2+2+1+4); eq(r.support.add,0); eq(r.support.remove,76-18); eq(r.support.strands,0)
assert(r.line:find('of 76 foundation tile ghosts 18 stay',1,true),r.line)
assert(r.line:find('holes are left open',1,true),r.line)
-- no area holds a kept tile, and the far patch goes as one rectangle
local kept={}
for x=4,6 do for y=4,6 do kept[x..','..y]=true end end
for x=0,3 do kept[x..',5']=true end
kept['8,7']=true
local covered=0
for _,ar in ipairs(r.remove_areas) do
  for x=ar.left_top.x,ar.right_bottom.x-1 do for y=ar.left_top.y,ar.right_bottom.y-1 do
    assert(not kept[x..','..y],'a kept tile in a remove area: '..x..','..y); covered=covered+1
  end end
  if ar.left_top.x==20 then eq(ar.right_bottom.x,22); eq(ar.left_top.y,0); eq(ar.right_bottom.y,2) end
end
eq(covered,58)
-- the assembler only: the pair's tiles go too, and the pair's ghosts and the chest stand on tiles that would go
r=PP.read({},{platform='Sol',support={positions={{x=5.5,y=5.5}}}})
eq(r.chosen,1); eq(r.support.footprints,9); eq(r.support.tunnels,0); eq(r.support.links,2); eq(r.support.keep,11)
eq(r.support.strands,3)
assert(r.line:find('3 entity ghosts not chosen stand on tiles that would go: underground-belt (0.5,5.5)',1,true),r.line)
-- an entity standing over empty space with no tile ghost under it: the empty tiles come back as place_ghosts entries
local lone=ghost('iron-chest','container',30.5,30.5,1,1)
ents[#ents+1]=lone
r=PP.read({},{platform='Sol',support={positions={{x=30.5,y=30.5}}}})
eq(r.support.footprints,1); eq(r.support.add,r.support.footprints+r.support.links-r.support.keep)
eq(r.place_ghosts_entries[1].name,'space-platform-foundation')
assert(r.support.links>0,'the lone chest is joined to the hub')
table.remove(ents)
-- names narrows the choice; nothing chosen and a bad shape refused
r=PP.read({},{platform='Sol',support={names={'iron-chest'}}})
eq(r.chosen,1); eq(r.support.strands,3)
fails(function() PP.read({},{platform='Sol',support={positions={{x=50,y=50}}}}) end,'nothing of ours at (50,50)')
fails(function() PP.read({},{platform='Sol',support={}}) end,'support is true')
-- salvage's rectangles still come from the shared helper
local rects=PP.rects({{x=0,y=0},{x=1,y=0},{x=0,y=1},{x=1,y=1},{x=5,y=1}})
eq(#rects,2); eq(rects[1].right_bottom.x,2); eq(rects[1].right_bottom.y,2)
print('platsupport: ok')
