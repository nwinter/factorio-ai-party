-- d24 batch162 QE1 (Sol #2213: on Asterion in flight platform_plan support true planned 11 tiles out to (29.5,-54.5),
-- footprint 1 and links 10, then 8 at x 18.5, for nothing of ours there): rockets in flight and laser beams are entities
-- of our force; support takes only what stands on the floor (ghosts and built entities, never a projectile, beam, cargo
-- pod or robot), and names the entity each planned tile is for (add_for, for_entities). Run: lua tests/d24_batch162.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) if a~=b then error((m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b),2) end end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
prototypes={entity={}}
local function box(x,y,w,h) return {left_top={x=x-w/2,y=y-h/2},right_bottom={x=x+w/2,y=y+h/2}} end
-- built floor x -2..7, y -2..1 round the hub; no tile ghosts
local built={}
for x=-2,7 do for y=-2,1 do built[#built+1]={position={x=x,y=y}} end end
local hub={valid=true,name='space-platform-hub',type='space-platform-hub',position={x=0,y=0},bounding_box=box(0,0,4,4),unit_number=1,prototype={selectable_in_game=true}}
local asm={valid=true,name='assembling-machine-3',type='assembling-machine',position={x=5.5,y=-0.5},bounding_box=box(5.5,-0.5,3,3),unit_number=2,prototype={selectable_in_game=true}}
-- a rocket in flight past the floor's north edge, and a laser beam: entities of ours too
local rocket={valid=true,name='rocket',type='projectile',position={x=5.3,y=-6.2},bounding_box=box(5.3,-6.2,0.2,0.2),unit_number=nil,prototype={selectable_in_game=false}}
local beam={valid=true,name='laser-beam',type='beam',position={x=2.1,y=-4.4},bounding_box=box(2.1,-4.4,0.4,0.4),prototype={selectable_in_game=false}}
local ents={hub,asm,rocket,beam}
local surface={
  find_tiles_filtered=function() return built end,
  find_entities_filtered=function(f)
    if f.type=='tile-ghost' then return {} end
    if f.type=='entity-ghost' then local o={} for _,e in ipairs(ents) do if e.type=='entity-ghost' then o[#o+1]=e end end return o end
    if f.type then return {} end
    return ents
  end}
local pl={name='Asterion',surface=surface,force='us',hub=hub}
local PP=require('platplan'){platform=function() return pl end,position=function(v) return v end}
local r=PP.read({},{platform='Asterion',support=true})
eq(r.chosen,2,'the rocket and the beam are not chosen')
eq(r.support.add,0,'no floor planned for a rocket or beam passing'); eq(r.support.footprints,0); eq(r.support.links,0)
eq(r.place_ghosts_entries,nil); eq(r.add_for,nil)
-- a chest ghost of ours north of the floor: its footprint and the link back, each named for it
local chest={valid=true,type='entity-ghost',ghost_name='iron-chest',ghost_type='container',name='entity-ghost',position={x=3.5,y=-5.5},bounding_box=box(3.5,-5.5,1,1),unit_number=77}
ents[#ents+1]=chest
r=PP.read({},{platform='Asterion',support=true})
eq(r.chosen,3); eq(r.support.add,4); eq(r.support.footprints,1); eq(r.support.links,3)
eq(#r.add_for,4); eq(#r.place_ghosts_entries,4)
for i,x in ipairs(r.add_for) do
  eq(x.position.x,r.place_ghosts_entries[i].position.x); eq(x.position.y,r.place_ghosts_entries[i].position.y)
  eq(x.entity.name,'ghost iron-chest'); eq(x.entity.unit_number,77); eq(x.entity.position.x,3.5)
end
eq(r.for_entities[1].name,'ghost iron-chest'); eq(r.for_entities[1].tiles,4); eq(r.for_entities[1].foot,1); eq(r.for_entities[1].link,3)
has(r.line,'the empty tiles are for (add_for, for_entities): ghost iron-chest #77 (3.5,-5.5): 4 (footprint 1, link 3)')
ents={hub,asm,rocket,beam}
-- salvage keeps no tile for a rocket over the floor
local rkt={valid=true,name='rocket',type='projectile',position={x=7.5,y=1.5},bounding_box=box(7.5,1.5,0.2,0.2),prototype={selectable_in_game=false}}
ents[#ents+1]=rkt
local taken=PP.salvage(surface,'us',hub,40)
local got=false
for _,t in ipairs(taken) do if t.x==7 and t.y==1 then got=true end end
assert(got,'the tile under a rocket passing is salvaged as any other')
print('d24_batch162 QE1 support takes what stands on the floor: ok')
