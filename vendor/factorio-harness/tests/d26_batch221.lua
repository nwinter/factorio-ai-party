-- Run with lua tests/d26_batch221.lua: d26 batch221 QAF1 (Sol #2401). supply's belt_lines joined the belt tiles
-- holding the item into groups and gave each one's tiles, items and box only; the groups move as items move, so a later
-- read could not sum the same tiles. belt_positions gives every tile of each listed group from the same scan, with the
-- tick; belt_tiles reads fixed tiles again at one tick, zeros included.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={inventory={chest=1},flow_precision_index={ten_minutes=3}}
prototypes={item={explosives={type='item'},coal={type='item'}},fluid={water={}},entity={},recipe={}}
local surface={name='nauvis',index=1}
local world={}
local finds=0
-- belts: position, explosives held; a splitter's position is its centre
local function belt(x,y,n,kind,dir)
  local e={valid=true,name=kind or 'transport-belt',type=kind or 'transport-belt',position={x=x,y=y},direction=dir or 4,surface=surface,unit_number=#world+1}
  e.get_item_count=function(id) eq(id,'explosives','a belt read by the item\'s name'); return e.n end
  e.n=n
  world[#world+1]=e
  return e
end
-- Group A: a row of 12 tiles east from (10.5,-4.5), 5 each; group B: 3 tiles down at (40.5,0.5), 2 each; an empty
-- belt between A and a lone tile; a splitter of 4 at (30,8.5); a belt of another force.
local A={}
for i=0,11 do A[#A+1]=belt(10.5+i,-4.5,5) end
local gap=belt(22.5,-4.5,0)
local lone=belt(23.5,-4.5,1)
local B={belt(40.5,0.5,2,nil,8),belt(40.5,1.5,2,nil,8),belt(40.5,2.5,2,nil,8)}
local sp=belt(30,8.5,4,'splitter',0)
local theirs=belt(41.5,0.5,9); theirs.force='enemy'
local function finder(f)
  finds=finds+1
  local types={}
  for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do types[t]=true end
  local out={}
  for _,e in ipairs(world) do
    local p=e.position
    local ok=types[e.type] and e.valid and (e.force or 'player')==(f.force and 'player' or e.force)
    if ok and f.area then ok=p.x>=f.area[1][1] and p.x<=f.area[2][1] and p.y>=f.area[1][2] and p.y<=f.area[2][2] end
    if ok and f.position then ok=(p.x-f.position.x)^2+(p.y-f.position.y)^2<=f.radius^2 end
    if ok then out[#out+1]=e end
  end
  return out
end
surface.find_entities_filtered=finder
surface.count_entities_filtered=function(f) return #finder(f) end
local force={name='player',logistic_networks={},current_research=nil,get_item_production_statistics=function()
  return {get_flow_count=function() return 0 end} end}
game={tick=1000,get_surface=function() return surface end}
local S=dofile('mod/agent-harness_0.1.0/supply.lua'){status_name=function(e) return e.status end,
  position=function(v) return {x=v.x,y=v.y} end,
  integer=function(v,d) return v==nil and d or v end}
local p={surface=surface,force=force,position={x=0,y=0}}

-- 1. belt_positions: each listed group's tiles from the same scan, in belt_lines' order, with the tick.
local r=S.supply(p,{item='explosives',belt_positions=true})
eq(r.belt_lines[1]:sub(1,46),'60 on 12 belt tiles (10.5,-4.5)-(21.5,-4.5); m')
local bp=r.belt_positions
assert(bp,'belt_positions in the reply')
eq(bp.snapshot_tick,1000); eq(bp.max_positions,1000)
eq(#bp.groups,4,'A, B, the splitter, the lone tile')
local g=bp.groups[1]
eq(g.items,60); eq(g.tiles,12); eq(g.box,'(10.5,-4.5)-(21.5,-4.5)')
eq(g.positions,'(10.5,-4.5) 5, (11.5,-4.5) 5, (12.5,-4.5) 5, (13.5,-4.5) 5, (14.5,-4.5) 5, (15.5,-4.5) 5, (16.5,-4.5) 5, (17.5,-4.5) 5, (18.5,-4.5) 5, (19.5,-4.5) 5, (20.5,-4.5) 5, (21.5,-4.5) 5')
eq(g.positions_not_listed,nil)
-- group i is belt_lines[i]: the most items first (B 6, the splitter 4, the lone tile 1)
eq(bp.groups[2].items,6); eq(bp.groups[2].positions,'(40.5,0.5) 2, (40.5,1.5) 2, (40.5,2.5) 2')
assert(r.belt_lines[2]:find('^6 on 3 belt tiles'),r.belt_lines[2])
eq(bp.groups[3].items,4); eq(bp.groups[3].positions,'(30.0,8.5) 4')
eq(bp.groups[4].items,1); eq(bp.groups[4].positions,'(23.5,-4.5) 1')
assert(bp.note:find('positions_not_listed',1,true))
-- without belt_positions the reply has none (and the plain read keeps its own reuse)
game.tick=1001
eq(S.supply(p,{item='explosives'}).belt_positions,nil)
-- reused within 10 s: the snapshot keeps its tick
game.tick=1100
local again=S.supply(p,{item='explosives',belt_positions=true})
eq(again.belt_positions.snapshot_tick,1000); assert(again.as_of:find('reused',1,true),again.as_of)

-- 2. belt_tiles: the same tiles later, at one tick, zeros included; items moved on.
game.tick=2000
for _,e in ipairs(A) do e.n=0 end
A[1].n=3; A[12].n=8
-- group 1's positions text as it came, then the empty belt, no belt, a tile listed twice, the splitter's centre and
-- another force's belt
local list=g.positions..', (22.5,-4.5) 0, (99.5,99.5), ( 10.5 , -4.5 ), (30.0,8.5) 4, (41.5,0.5)'
finds=0
local t=S.supply(p,{item='explosives',belt_tiles=list})
eq(t.snapshot_tick,2000); eq(t.tiles,16); eq(t.total,3+8+4); eq(t.belt_tiles,14); eq(t.duplicates,1)
eq(t.positions,'(10.5,-4.5) 3, (11.5,-4.5) 0, (12.5,-4.5) 0, (13.5,-4.5) 0, (14.5,-4.5) 0, (15.5,-4.5) 0, (16.5,-4.5) 0, (17.5,-4.5) 0, (18.5,-4.5) 0, (19.5,-4.5) 0, (20.5,-4.5) 0, (21.5,-4.5) 8, (22.5,-4.5) 0, (99.5,99.5) 0, (30.0,8.5) 4, (41.5,0.5) 0')
eq(t.no_belt,'2 of the positions have no belt of ours (count 0): (99.5,99.5), (41.5,0.5)')
assert(finds<=4,'one find per chunk with tiles asked: '..finds)
assert(t.where==nil and t.makers==nil,'belt_tiles reads those tiles alone')
-- a list of [x,y] or {x,y} works too
eq(S.supply(p,{item='explosives',belt_tiles={{21.5,-4.5},{x=10.5,y=-4.5}}}).total,11)

-- 3. Refusals: past the cap, a fluid, with near, not true.
local big={}
for i=1,1001 do big[i]={i+0.5,0.5} end
local ok,err=pcall(S.supply,p,{item='explosives',belt_tiles=big}); assert(not ok and err:find('1..1000',1,true),err)
ok,err=pcall(S.supply,p,{item='explosives',belt_tiles={}}); assert(not ok and err:find('1..1000',1,true),err)
ok,err=pcall(S.supply,p,{item='explosives',belt_tiles='21.5,-4.5'}); assert(not ok and err:find('1..1000',1,true),err)
ok,err=pcall(S.supply,p,{item='explosives',belt_tiles={{1}}}); assert(not ok and err:find('belt_tiles[1]',1,true),err)
ok,err=pcall(S.supply,p,{item='explosives',belt_tiles={{1,1}},near={x=0,y=0}}); assert(not ok and err:find('no near',1,true),err)
ok,err=pcall(S.supply,p,{item='water',belt_tiles={{1,1}}}); assert(not ok and err:find('belts carry items',1,true),err)
ok,err=pcall(S.supply,p,{item='water',belt_positions=true}); assert(not ok and err:find('belts carry items',1,true),err)
ok,err=pcall(S.supply,p,{item='explosives',belt_positions=1}); assert(not ok and err:find('belt_positions is true',1,true),err)

-- 4. The cap: 1000 positions over all groups; past it a group lists its first ones by rows and counts the rest.
local spots={}
for i=1,1100 do spots[i]={i+0.5,0.5,1,4,'transport-belt'} end
for i=1,30 do spots[#spots+1]={i+0.5,5.5,2,4,'transport-belt'} end
local gs=S.belt_groups({belt_spots=spots})
local out=S.belt_positions(gs)
local function count(text) local n=0 for _ in text:gmatch('%(') do n=n+1 end return n end
eq(out.groups[1].tiles,1100); eq(count(out.groups[1].positions),1000); eq(out.groups[1].positions_not_listed,100)
eq(out.groups[2].tiles,30); eq(out.groups[2].positions,''); eq(out.groups[2].positions_not_listed,30)
eq(out.complete,true)
-- the schema names both
assert(S.schema.supply.belt_positions and S.schema.supply.belt_tiles,'schema')
print('d26_batch221 QAF1: ok')
