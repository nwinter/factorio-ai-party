-- Run from repository root: lua tests/pipes.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn);assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
defines={build_check_type={manual_ghost=1}}
-- Connection definitions as the runtime reports them: one position per facing.
local function rot(pos,d)
  local x,y=pos[1],pos[2]
  if d==4 then return {x=-y,y=x} elseif d==8 then return {x=-x,y=-y} elseif d==12 then return {x=y,y=-x} end
  return {x=x,y=y}
end
local function conn(direction,pos,extra)
  local c={direction=direction,connection_type='normal',flow_direction='input-output',positions={rot(pos,0),rot(pos,4),rot(pos,8),rot(pos,12)}}
  for k,v in pairs(extra or {}) do c[k]=v end
  return c
end
local function box(conns,extra) local b={pipe_connections=conns,volume=100}; for k,v in pairs(extra or {}) do b[k]=v end; return b end
prototypes={entity={
  pipe={name='pipe',type='pipe',fluidbox_prototypes={box{conn(0,{0,0}),conn(4,{0,0}),conn(8,{0,0}),conn(12,{0,0})}}},
  ['pipe-to-ground']={name='pipe-to-ground',type='pipe-to-ground',fluidbox_prototypes={box{conn(0,{0,0}),
    conn(8,{0,0},{connection_type='underground',max_underground_distance=10})}}},
  -- The pumpjack's output does not rotate with the body: explicit positions.
  pumpjack={name='pumpjack',type='mining-drill',fluidbox_prototypes={box({{direction=0,connection_type='normal',flow_direction='output',
    positions={{x=1,y=-1},{x=1,y=-1},{x=-1,y=1},{x=-1,y=1}}}},{filter={name='crude-oil'}})}},
  ['chemical-plant']={name='chemical-plant',type='assembling-machine',fluidbox_prototypes={
    box{conn(8,{-1,1},{flow_direction='input'})},box{conn(8,{1,1},{flow_direction='input'})},
    box{conn(0,{-1,-1},{flow_direction='output'})},box{conn(0,{1,-1},{flow_direction='output'})}}},
  ['transport-belt']={name='transport-belt',type='transport-belt'}}}
local function key(x,y) return math.floor(x)..','..math.floor(y) end
local mine={is_chunk_charted=function() return true end}
local blocked,world={},{}
local function covers(e,x,y)
  local b=e.bounding_box
  return x>=b.left_top.x and x<=b.right_bottom.x and y>=b.left_top.y and y<=b.right_bottom.y
end
local surface
surface={
  can_place_entity=function(a)
    if blocked[key(a.position.x,a.position.y)] then return false end
    for _,e in ipairs(world) do if covers(e,a.position.x,a.position.y) then return false end end
    return true
  end,
  find_entities_filtered=function(f)
    local out={}
    local function has(list,v) for _,n in ipairs(list) do if n==v then return true end end end
    for _,e in ipairs(world) do
      local ghost=e.type=='entity-ghost'
      local ok=true
      if f.name then ok=not ghost and has(f.name,e.name) end
      if f.ghost_name then ok=ghost and has(f.ghost_name,e.ghost_name) end
      if f.type then ok=ok and e.type==f.type end
      if f.position then ok=ok and covers(e,f.position.x,f.position.y) end
      if ok then out[#out+1]=e end
    end
    return out
  end}
local function place(name,x,y,d,extra)
  local w=name=='pumpjack' or name=='chemical-plant'
  local r=w and 1.3 or 0.3
  local e={valid=true,name=name,type=prototypes.entity[name].type,position={x=x,y=y},direction=d or 0,force=mine,surface=surface,
    prototype=prototypes.entity[name],bounding_box={left_top={x=x-r,y=y-r},right_bottom={x=x+r,y=y+r}}}
  if extra and extra.ghost then
    e.type,e.name,e.ghost_name,e.ghost_type,e.ghost_prototype,e.prototype='entity-ghost','entity-ghost',name,e.type,e.prototype,nil
  end
  for k,v in pairs(extra or {}) do if k~='ghost' then e[k]=v end end
  world[#world+1]=e; return e
end
local function reset() blocked,world={},{} end
local p={surface=surface,force=mine}
local P=dofile('mod/agent-harness_0.1.0/pipes.lua'){
  position=function(v) return {x=v.x,y=v.y} end,
  directions={north=0,east=4,south=8,west=12},
  chunk_of=function(pos) return {x=math.floor(pos.x/32),y=math.floor(pos.y/32)} end}
local function at(plan,x,y)
  for _,e in ipairs(plan.entities) do if e.position.x==x+0.5 and e.position.y==y+0.5 then return e end end
end
local function plain(plan,x,y) local e=at(plan,x,y); return e~=nil and e.name=='pipe' end
local function kinds(plan)
  local out={}
  for _,e in ipairs(plan.entities) do out[#out+1]=(e.name=='pipe' and 'p' or 'u')..'@'..e.position.x..','..e.position.y..(e.direction and ':'..e.direction or '') end
  return table.concat(out,' ')
end

-- Open ground: a straight line of plain pipe, both ends free.
local r=P.plan(p,{from={x=0.5,y=0.5},to={x=5.5,y=0.5}})
eq(r.route,'E6'); eq(r.tiles,6); eq(r.pipes,6); eq(r.items.pipe,6); eq(r.items['pipe-to-ground'],nil); eq(r.joins,nil)
-- A short wall is walked around without undergrounds, and never stepped on.
for y=-1,1 do blocked[key(3,y)]=true end
r=P.plan(p,{from={x=0,y=0},to={x=6,y=0},undergrounds=false})
eq(r.undergrounds,0); eq(r.tiles,11)
for _,e in ipairs(r.entities) do assert(not blocked[key(e.position.x,e.position.y)],'on the wall') end
-- A belt line too long to walk around is crossed underground: an entrance
-- open to the west before it, an exit open to the east after it.
reset()
for y=-40,40 do place('transport-belt',3.5,y+0.5,8) end
r=P.plan(p,{from={x=0,y=0},to={x=6,y=0}})
eq(r.undergrounds,1); eq(r.items['pipe-to-ground'],2)
eq(at(r,0,0).name,'pipe'); eq(at(r,6,0).name,'pipe'); eq(at(r,3,0),nil)
for _,e in ipairs(r.entities) do
  if e.name=='pipe-to-ground' then eq(e.direction,e.position.x<3 and 'west' or 'east') end
end
assert(r.route:find('uE',1,true),r.route)
fails(function() P.plan(p,{from={x=0,y=0},to={x=6,y=0},undergrounds=false}) end,'no route')
-- Underground pipes cannot pass beneath lava.
surface.get_tile=function(x) return {prototype={collision_mask={layers={lava_tile=x==2 or nil}}}} end
fails(function() P.plan(p,{from={x=0,y=0},to={x=6,y=0}}) end,'no route')
surface.get_tile=nil
-- The hop stays within the pipe-to-ground reach read from its fluid box.
reset()
for y=-40,40 do for x=1,10 do blocked[key(x,y)]=true end end
fails(function() P.plan(p,{from={x=-1,y=0},to={x=12,y=0}}) end,'no route')
for y=-40,40 do blocked[key(10,y)]=nil end
r=P.plan(p,{from={x=-1,y=0},to={x=12,y=0}}); eq(r.route,'E1 uE10 E2')

-- A foreign pipe beside the line: plain pipe never goes where it connects.
reset()
for x=2,4 do place('pipe',x+0.5,-0.5) end
r=P.plan(p,{from={x=0,y=0},to={x=6,y=0}})
for x=2,4 do eq(plain(r,x,0),false) end
-- Boxed in beside it, the line runs underground past it: pipe-to-ground ends
-- only connect on their open side, so they may sit next to the foreign pipe.
reset()
for x=1,5 do
  place('pipe',x+0.5,-0.5)
  for y=1,40 do blocked[key(x,y)]=true; blocked[key(x,-y-1)]=true end
end
r=P.plan(p,{from={x=0,y=0},to={x=6,y=0}})
eq(kinds(r),'p@0.5,0.5 u@1.5,0.5:west u@5.5,0.5:east p@6.5,0.5')
fails(function() P.plan(p,{from={x=0,y=0},to={x=6,y=0},undergrounds=false}) end,'no route')
-- An end at one pipe's connection joins that pipe only; boxed in, through an
-- underground end open toward it.
reset()
for x=1,5 do place('pipe',x+0.5,-0.5) end
r=P.plan(p,{from={x=2,y=0},to={x=2,y=8}})
eq(r.joins.from.name,'pipe'); eq(r.joins.from.position.y,-0.5); eq(r.route,'S9')
place('pipe',1.5,1.5); place('pipe',3.5,1.5)
r=P.plan(p,{from={x=2,y=0},to={x=2,y=8}})
eq(r.joins.from.name,'pipe'); eq(plain(r,2,1),false)
-- An end where two entities connect is refused rather than merged.
place('pipe',10.5,-0.5); place('pipe',11.5,0.5)
fails(function() P.plan(p,{from={x=10,y=0},to={x=10,y=8}}) end,'both pipe and pipe connect')
-- A hop never shares its axis with a foreign underground pair: ours would pair with theirs.
reset()
place('pipe-to-ground',2.5,0.5,12); place('pipe-to-ground',5.5,0.5,4)
-- Crossing it at right angles is fine, even with plain pipe over the span.
r=P.plan(p,{from={x=3,y=-4},to={x=3,y=4}})
eq(r.route,'S9')
for x=1,7 do for y=1,40 do blocked[key(x,y)]=true; blocked[key(x,-y)]=true end end
r=P.plan(p,{from={x=-1,y=0},to={x=8,y=0}})
for _,e in ipairs(r.entities) do assert(e.position.y~=0.5 or e.position.x<1 or e.position.x>7,'hopped along the foreign pair') end

-- Joining an existing pipe: the line ends on a free tile at one of its
-- connections and reports the join; the pipe itself is left alone.
reset()
local water=place('pipe',10.5,0.5,0)
r=P.plan(p,{from={x=0,y=0},to={x=10,y=0}})
eq(r.route,'E10'); eq(at(r,10,0),nil); eq(at(r,9,0).name,'pipe'); eq(r.joins.to.name,'pipe'); eq(r.joins.to.position.x,10.5)
-- Its other connection tiles are not used when another network also reaches them.
place('pipe',9.5,-0.5); place('pipe',9.5,1.5)
r=P.plan(p,{from={x=0,y=0},to={x=10,y=0}})
eq(at(r,11,0).name,'pipe'); eq(plain(r,10,-1),false); eq(plain(r,10,1),false); eq(plain(r,9,0),false)
-- A machine end: the free tile at its connection, or a pumpjack itself (one
-- connection). The fluid is checked against the other end.
reset()
place('pumpjack',20.5,0.5,0)
r=P.plan(p,{from={x=21,y=-2},to={x=21,y=-8}})
eq(r.route,'N7'); eq(r.joins.from.name,'pumpjack'); eq(r.joins.from.fluid,'crude-oil')
r=P.plan(p,{from={x=20.5,y=0.5},to={x=21,y=-8}})
eq(r.tiles,7); eq(r.joins.from.name,'pumpjack')
-- An east-facing pumpjack outputs east of its top-right tile.
reset()
place('pumpjack',20.5,0.5,4)
r=P.plan(p,{from={x=20.5,y=0.5},to={x=28,y=-1}})
eq(at(r,22,-1).name,'pipe')
place('pipe',30.5,-0.5,0,{fluidbox={{name='water',amount=100},get_pipe_connections=function()
  return {{flow_direction='input-output',connection_type='normal',position={x=30.5,y=-0.5},target_position={x=29.5,y=-0.5}}} end}})
fails(function() P.plan(p,{from={x=20.5,y=0.5},to={x=30,y=-1}}) end,'from carries crude-oil but to carries water')
-- A machine with several connections must be joined at a chosen tile, and
-- its other connections are avoided by the line.
reset()
place('chemical-plant',5.5,0.5,0)
fails(function() P.plan(p,{from={x=5.5,y=0.5},to={x=5,y=-8}}) end,'several or one-way')
r=P.plan(p,{from={x=4,y=-2},to={x=4,y=-8}})
eq(r.joins.from.name,'chemical-plant')
r=P.plan(p,{from={x=0,y=-2},to={x=10,y=-2}})
eq(at(r,4,-2),nil); eq(at(r,6,-2),nil)
-- Ghosts connect when built, so they count as connections too.
reset()
place('pipe',3.5,-0.5,0,{ghost=true})
r=P.plan(p,{from={x=0,y=0},to={x=6,y=0}})
eq(plain(r,3,0),false)
eq(P.plan(p,{from={x=3,y=-1},to={x=5,y=0}}).joins.from.name,'pipe(ghost)')
fails(function() P.plan(p,{from={x=0,y=0},to={x=0,y=0}}) end,'same tile')
fails(function() P.plan(p,{from={x=0,y=0},to={x=300,y=0}}) end,'within 200')
fails(function() P.plan(p,{from={x=0,y=0},to={x=5,y=0},pipe='transport-belt'}) end,'pipe entity')
for _,xy in ipairs{{2,-1},{4,-1},{3,-2},{3,0}} do blocked[key(xy[1],xy[2])]=true end
fails(function() P.plan(p,{from={x=3,y=-1},to={x=6,y=0}}) end,'holds pipe(ghost) but no tile')

-- scan fields=fluids: per fluidbox contents and connections, with the
-- entity joined at each. Built entities report through the engine.
reset()
local pj=place('pumpjack',20.5,0.5,0,{fluidbox={{name='crude-oil',amount=52.25},get_capacity=function() return 100 end,
  get_pipe_connections=function() return {{flow_direction='output',connection_type='normal',position={x=21.5,y=-0.5},target_position={x=21.5,y=-1.5},
    target={object_name='LuaFluidBox',owner={name='pipe',type='pipe'}}}} end}})
eq(P.fluids(pj),'crude-oil 52.3/100 out 21.5,-1.5=pipe')
-- An empty box fixed to one fluid by the recipe names it.
local cp=place('chemical-plant',30.5,0.5,0,{fluidbox={get_capacity=function() return 100 end,
  get_filter=function(i) return i==1 and {name='water'} or nil end,get_pipe_connections=function() return {} end}})
setmetatable(cp.fluidbox,{__len=function() return 2 end})
eq(P.fluids(cp),'empty (water only)/100 | empty/100')
-- Ghosts report from the prototype, and see ghosts they will connect to.
local g=place('chemical-plant',5.5,0.5,0,{ghost=true})
place('pipe',4.5,2.5,0,{ghost=true})
eq(P.fluids(g),'empty/100 in 4.5,2.5=pipe(ghost) | empty/100 in 6.5,2.5 | empty/100 out 4.5,-1.5 | empty/100 out 6.5,-1.5')
local u=place('pipe-to-ground',0.5,5.5,4,{ghost=true})
eq(P.fluids(u),'empty/100 io 1.5,5.5 io uW')
-- Pump-like summaries: where fluid enters and leaves.
local out={}
P.hint(place('pipe-to-ground',0.5,9.5,0),out)
eq(out.opens.y,8.5); eq(out.unpaired,true)
-- Segment extent: a straight 400-tile route gets one pump where the part
-- before it would pass 320 tiles; joined segments count toward the extent.
local line={}
for x=0,399 do line[#line+1]={name='pipe',position={x=x+0.5,y=0.5}} end
local plan=P.pump_plan(line,nil,nil,320)
eq(plan.extent,400); eq(#plan.pumps,1); eq(plan.pumps[1].position.x,319); eq(plan.pumps[1].position.y,0.5); eq(plan.pumps[1].direction,'east')
eq(P.pump_plan({table.unpack(line,1,300)},nil,nil,320).pumps,nil)
local joined=P.pump_plan({table.unpack(line,1,300)},{-100,0,-1,0},nil,320)
eq(joined.extent,400); eq(#joined.pumps,1); eq(joined.pumps[1].position.x,219)
-- An L-shape is measured by its longer side, as the engine does.
local ell={}
for x=0,199 do ell[#ell+1]={name='pipe',position={x=x+0.5,y=0.5}} end
for y=1,199 do ell[#ell+1]={name='pipe',position={x=199.5,y=y+0.5}} end
eq(P.pump_plan(ell,nil,nil,320).extent,200)
-- No straight run of plain pipe: the plan says so instead of guessing.
local hops={}
for x=0,330 do hops[#hops+1]={name='pipe-to-ground',direction='east',position={x=x+0.5,y=0.5}} end
assert(P.pump_plan(hops,nil,nil,320).unsplittable:find('no straight run',1,true))
eq(P.extent_limit(),320)
print('pipes: ok')
