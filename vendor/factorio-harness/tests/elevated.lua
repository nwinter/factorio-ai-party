-- Run from repository root: lua tests/elevated.lua
-- rail_route level elevated (d20 batch61 W1, Sol #1491: Fulgora island links) against a fake engine. What it stands
-- for was read from 2.0.77 on the private copy (Fulgora, x=-175 from y=194 to y=312: 86 tiles of oil ocean, 25 deep):
-- a ramp is 16 tiles, cardinal, its ground end 8 behind its position; a support stands on a rail joint and carries
-- elevated rail lying wholly within 11 tiles of it (a ramp's elevated end: 9); deep oil ocean takes a support once
-- Rail support foundations is researched. There the plan was 2 ramps, 43 elevated straight rails and 4 supports with
-- the research (the game built all 49 from their ghosts), 2 supports without it (the 15 rails over the deep part
-- stayed ghosts, as the plan's unsupported span said).
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(text,part) assert(text and tostring(text):find(part,1,true),tostring(text)..' lacks '..part) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
defines={build_check_type={manual_ghost=1}}
local function rails_item(n) return {items_to_place_this={{name='rail',count=n}}} end
prototypes={entity={['straight-rail']=rails_item(1),['half-diagonal-rail']=rails_item(2),['curved-rail-a']=rails_item(3),['curved-rail-b']=rails_item(3),
  ['elevated-straight-rail']=rails_item(1),['elevated-half-diagonal-rail']=rails_item(2),['elevated-curved-rail-a']=rails_item(3),['elevated-curved-rail-b']=rails_item(3),
  ['rail-ramp']={items_to_place_this={{name='rail-ramp',count=1}}},
  ['rail-support']={items_to_place_this={{name='rail-support',count=1}},collision_mask={layers={rail_support=true,object=true,rail=true}}}},item={}}
local dirs={north=0,northnortheast=1,northeast=2,eastnortheast=3,east=4,eastsoutheast=5,southeast=6,southsoutheast=7,south=8,
  southsouthwest=9,southwest=10,westsouthwest=11,west=12,westnorthwest=13,northwest=14,northnorthwest=15}
local R=dofile('mod/agent-harness_0.1.0/rails.lua'){position=function(v) return {x=v.x,y=v.y} end,directions=dirs,
  chunk_of=function(pos) return {x=math.floor(pos.x/32),y=math.floor(pos.y/32)} end,
  ramp_why=function(p,pos,d) return 'its footprint holds fulgoran-ruin-small (1,2)' end}

-- The world: deep oil ocean in a band of y, rocks (no ramp) in a box, our rails.
local deep,rocks,ours,researched={},nil,{},false
local function in_deep(x,y) return deep.y0 and y>=deep.y0 and y<deep.y1 end
local surface={}
function surface.can_place_entity(a)
  local x,y=a.position.x,a.position.y
  if a.name=='rail-support' then
    -- its box (1.39 each way) on deep oil ocean: refused without the research
    if not researched and deep.y0 and y+1.39>deep.y0 and y-1.39<deep.y1 then return false end
    return true
  elseif a.name=='rail-ramp' then
    return not (rocks and x>=rocks.x0 and x<=rocks.x1 and y>=rocks.y0 and y<=rocks.y1)
  end
  return true
end
function surface.count_tiles_filtered(f)
  if f.name=='oil-ocean-deep' and deep.y0 and f.area.right_bottom.y>deep.y0 and f.area.left_top.y<deep.y1 then return 1 end
  return 0
end
function surface.find_tiles_filtered() return {} end
local function inside(e,area) return e.position.x>=area.left_top.x and e.position.x<=area.right_bottom.x and e.position.y>=area.left_top.y and e.position.y<=area.right_bottom.y end
function surface.find_entities_filtered(f)
  local out={}
  local t=f.type or f.ghost_type
  local want
  if type(t)=='table' then want={} for _,x in ipairs(t) do want[x]=true end elseif type(t)=='string' then want={[t]=true} end
  local nm=f.name or f.ghost_name
  if not want and not nm then return out end
  local ghost=f.ghost_type~=nil or f.ghost_name~=nil
  for _,e in ipairs(ours) do
    local ok=(e.ghost==true)==ghost and (not want or want[e.name]) and (not nm or e.name==nm)
    if ok and f.area then ok=inside(e,f.area) end
    if ok and f.position then local r=(f.radius or 0)+0.01; ok=math.abs(e.position.x-f.position.x)<=r and math.abs(e.position.y-f.position.y)<=r end
    if ok then out[#out+1]=e end
  end
  return out
end
local force={is_chunk_charted=function() return true end,technologies=setmetatable({},{__index=function(_,k)
  if k=='elevated-rail' then return {researched=true} end
  if k=='rail-support-foundations' then return {researched=researched} end
end})}
local p={surface=surface,force=force}
local function reset() deep,rocks,ours,researched={},nil,{},false end
local function rail(name,x,y,d,ghost)
  local e={valid=true,name=name,ghost_name=ghost and name or nil,type=name,position={x=x,y=y},direction=d,ghost=ghost}
  ours[#ours+1]=e; return e
end

-- Every elevated piece lies within reach of one support or a ramp's elevated end, measured along the track.
local function carried(r)
  local anchors={}
  for _,e in ipairs(r.entities) do
    if e.name=='rail-support' then anchors[#anchors+1]={x=e.position.x,y=e.position.y,reach=R.SUPPORT_REACH} end
  end
  for _,ramp in ipairs(r.out.ramps or {}) do anchors[#anchors+1]={x=ramp.elevated_end.x,y=ramp.elevated_end.y,reach=R.RAMP_REACH} end
  local s,joints={0},{{x=r.out.start.position.x,y=r.out.start.position.y}}
  for _,e in ipairs(r.entities) do
    if e.name:find('^elevated%-') then
      local ends=R.ends_of(e.name,e.position,dirs[e.direction])
      local last=joints[#joints]
      local nx=ends[1].x==last.x and ends[1].y==last.y and ends[2] or ends[1]
      joints[#joints+1]={x=nx.x,y=nx.y}
      s[#s+1]=s[#s]+((nx.x-last.x)^2+(nx.y-last.y)^2)^0.5
    end
  end
  local where={}
  for i,j in ipairs(joints) do where[j.x..','..j.y]=i end
  local bad={}
  for i=1,#joints-1 do
    local ok=false
    for _,a in ipairs(anchors) do
      local k=where[a.x..','..a.y]
      if k and math.abs(s[i]-s[k])<=a.reach and math.abs(s[i+1]-s[k])<=a.reach then ok=true end
    end
    if not ok then bad[#bad+1]=i end
  end
  return bad,#joints-1
end

-- The private copy's line: x=-175, from y=194 south to y=312, ramps on the land at both ends.
reset()
local r=R.plan(p,{from={x=-175,y=194},to={x=-175,y=312},level='elevated'})
eq(r.out.level,'elevated'); eq(r.out.route,'S86'); eq(r.out.pieces['elevated-straight-rail'],43); eq(r.out.pieces['straight-rail'],nil)
eq(#r.out.ramps,2)
local up,down=r.out.ramps[1],r.out.ramps[2]
eq(up.role,'up at from'); eq(up.rises_toward,'south'); eq(up.position.y,202); eq(up.ground_end.y,194); eq(up.elevated_end.y,210)
eq(down.role,'down at to'); eq(down.rises_toward,'north'); eq(down.position.y,304); eq(down.ground_end.y,312); eq(down.elevated_end.y,296)
eq(r.out.start.position.y,210); eq(r.out['end'].position.y,296)
eq(r.out.items.rail,43); eq(r.out.items['rail-ramp'],2)
-- Placed in order: the ramps, the supports, then the rails (a hand build needs the support first).
eq(r.entities[1].name,'rail-ramp'); eq(r.entities[1].direction,'south'); eq(r.entities[2].name,'rail-ramp'); eq(r.entities[2].direction,'north')
eq(r.entities[3].name,'rail-support')
-- No deep oil: supports every 20 tiles of track at most (the game carried 20, not 22), every rail carried.
eq(r.out.supports.count,4); eq(r.out.items['rail-support'],4); assert(r.out.supports.widest<=20,r.out.supports.widest)
local bad,n=carried(r); eq(#bad,0,'pieces not carried'); eq(n,43)
eq(r.out.unsupported,nil)
-- A support stands on a joint, facing the rail (8 directions).
for _,e in ipairs(r.entities) do if e.name=='rail-support' then eq(e.position.x,-175); eq(e.position.y%2,0); eq(e.direction,'north') end end
has(r.out.research.elevated_rail,'researched')

-- Deep oil ocean from y=258 to y=289 (as at x=-175): no support there without the research; the span is named, why
-- and how long, and its rails stay ghosts in the game.
reset(); deep={y0=258,y1=289}
r=R.plan(p,{from={x=-175,y=194},to={x=-175,y=312},level='elevated'})
eq(r.out.supports.count,2); eq(r.out.supports.widest,20)  -- between the two before the deep span, not across it
eq(#r.out.unsupported,1)
local gap=r.out.unsupported[1]
eq(gap.from.y,258); eq(gap.to.y,288); eq(gap.tiles,30); eq(gap.pieces,15)
has(gap.why,'oil-ocean-deep (the game takes rail supports there once Rail support foundations is researched)')
has(r.out.unsupported_note,'within 11 tiles of one rail support')
eq(r.out.research.rail_support_foundations,'not researched')
bad=carried(r); eq(#bad,15,'the deep span is the only one not carried')
-- With the research: supports over the deep part too, nothing unsupported.
researched=true
r=R.plan(p,{from={x=-175,y=194},to={x=-175,y=312},level='elevated'})
eq(r.out.supports.count,4); eq(r.out.unsupported,nil); eq(#carried(r),0)
eq(r.out.research.rail_support_foundations,'researched')

-- elevated=true is level elevated; ground stays the default (no ramps, ground pieces).
reset()
r=R.plan(p,{from={x=-175,y=194},to={x=-175,y=312},elevated=true})
eq(r.out.level,'elevated')
r=R.plan(p,{from={x=-175,y=194},to={x=-175,y=312}})
eq(r.out.level,nil); eq(r.out.ramps,nil); eq(r.out.supports,nil)
for name in pairs(r.out.pieces) do assert(not name:find('elevated',1,true),name) end

-- A turn: curves and half-diagonals, elevated, every piece joined and carried; the ramps point along the way.
reset()
r=R.plan(p,{from={x=1,y=0},to={x=121,y=-120},level='elevated'})
local curves=(r.out.pieces['elevated-curved-rail-a'] or 0)+(r.out.pieces['elevated-curved-rail-b'] or 0)
assert(curves>=4,'a turn of 90 degrees takes four curves: '..curves)
for name in pairs(r.out.pieces) do assert(name:find('^elevated%-'),name) end
eq(#carried(r),0,'curved pieces carried')
eq(r.out.ramps[1].rises_toward=='north' or r.out.ramps[1].rises_toward=='east',true)
local prev
for _,e in ipairs(r.entities) do
  if e.name:find('^elevated%-') then
    local ends=R.ends_of(e.name,e.position,dirs[e.direction])
    if prev then
      local ok=false
      for _,a in ipairs(prev) do for _,b in ipairs(ends) do if a.x==b.x and a.y==b.y and a.d==R.opposite(b.d) then ok=true end end end
      assert(ok,'piece '..e.name..' at '..e.position.x..','..e.position.y..' does not join the one before')
    end
    prev=ends
  end
end

-- from near a free end of our ground rail heading north: the ramp continues it (its ground end on that end).
reset()
rail('straight-rail',1,1,0)  -- ends (1,0) heading north and (1,2) heading south
r=R.plan(p,{from={x=1,y=0},to={x=1,y=-100},level='elevated'})
eq(r.out.ramps[1].ground_end.y,0); eq(r.out.ramps[1].rises_toward,'north'); eq(r.out.ramps[1].joins.rail,'straight-rail')
-- from near a free end of our elevated rail: no ramp up, the line goes on from it.
reset()
rail('elevated-straight-rail',1,1,0)
r=R.plan(p,{from={x=1,y=0},to={x=1,y=-100},level='elevated'})
eq(#r.out.ramps,1); eq(r.out.ramps[1].role,'down at to'); eq(r.out.extends.rail,'elevated-straight-rail')
-- Starting from elevated rail of unknown support, the first support comes within reach of its end.
assert(r.entities[2].name=='rail-support' and r.entities[2].position.y>=-10,r.entities[2].position.y)
-- to near the elevated end of our ramp: joined there, no ramp down.
reset()
rail('rail-ramp',1,-108,8)  -- rises south: ground end (1,-116), elevated end (1,-100)
r=R.plan(p,{from={x=1,y=0},to={x=1,y=-100},level='elevated'})
eq(#r.out.ramps,1); eq(r.out.ramps[1].role,'up at from'); eq(r.out.joins.rail,'rail-ramp')

-- No ramp fits at from: each heading tried, with the game's reason.
reset(); rocks={x0=-20,x1=20,y0=-20,y1=20}
fails(function() R.plan(p,{from={x=1,y=0},to={x=1,y=-100},level='elevated'}) end,'no rail ramp fits at from (1,0)')
fails(function() R.plan(p,{from={x=1,y=0},to={x=1,y=-100},level='elevated'}) end,'its footprint holds fulgoran-ruin-small')
-- from_direction and to_direction fix the ramps (cardinal only).
reset()
r=R.plan(p,{from={x=1,y=0},to={x=101,y=-100},level='elevated',from_direction='north',to_direction='east'})
eq(r.out.ramps[1].rises_toward,'north'); eq(r.out.ramps[2].rises_toward,'west')
fails(function() R.plan(p,{from={x=1,y=0},to={x=1,y=-100},level='elevated',to_direction='northeast'}) end,'to_direction')
fails(function() R.plan(p,{from={x=1,y=0},to={x=1,y=-100},level='bridge'}) end,'level is ground (the default) or elevated')
fails(function() R.plan(p,{from={x=1,y=0},to={x=1,y=-100},level='elevated',signals=30}) end,'signals: rail_route places rail signals on ground rails only')
fails(function() R.plan(p,{from={x=1,y=0},to={x=1,y=-100},level='ground',elevated=true}) end,'level and elevated differ')
-- (W2) A real call places at most ELEVATED_PER_CALL pieces and stops on its own support; the next call from there
-- (next_call) starts carried by it; the last one lays the ramp down. Together they lay what one plan would.
reset()
local whole=R.plan(p,{from={x=-175,y=194},to={x=-175,y=312},level='elevated'})
eq(#whole.entities,49); eq(whole.out.per_call.pieces,R.per_call(whole.out.cost.placement_checks)); eq(whole.out.per_call.calls,3)
local args,calls,laid={from={x=-175,y=194},to={x=-175,y=312},level='elevated'},0,{}
while args and calls<6 do
  calls=calls+1
  local plan=R.plan(p,args)
  local part,capped=R.cut(plan,args)
  part=part or plan.entities
  assert(#part<=plan.out.per_call.pieces,#part)
  if calls>1 then has(plan.out.supports.at_start,'carries the line on'); eq(plan.out.ramps[1].role,'down at to') end
  for _,e in ipairs(part) do
    rail(e.name,e.position.x,e.position.y,dirs[e.direction],true)
    laid[#laid+1]=e
  end
  if capped then
    eq(part[#part].name:find('^elevated%-')~=nil,true)
    local last=R.ends_of(part[#part].name,part[#part].position,dirs[part[#part].direction])
    local cf=capped.continue_from.position
    assert((last[1].x==cf.x and last[1].y==cf.y) or (last[2].x==cf.x and last[2].y==cf.y),'stops on its last rail\'s end')
    local on_support=false
    for _,e in ipairs(part) do if e.name=='rail-support' and e.position.x==cf.x and e.position.y==cf.y then on_support=true end end
    assert(on_support,'stops on one of its own supports')
    eq(capped.next_call.from.y,cf.y); eq(capped.next_call.to.y,312); eq(capped.pieces_left,#plan.entities-#part)
    has(capped.note,'stops on its own elevated end at (-175,')
    eq(capped.items.rail+(capped.items['rail-ramp'] or 0)+(capped.items['rail-support'] or 0)>0,true)
  end
  args=capped and capped.next_call
end
eq(calls,3)
local by={}
for _,e in ipairs(laid) do by[e.name]=(by[e.name] or 0)+1 end
eq(by['rail-ramp'],2); eq(by['elevated-straight-rail'],43); eq(by['rail-support'],4)
-- A route that fits takes one call: no cut.
reset()
r=R.plan(p,{from={x=-175,y=194},to={x=-175,y=240},level='elevated'})
eq(R.cut(r,{}),nil); eq(r.out.per_call.calls,1)

-- (cp3) Curves: a turn across a deep band (y 40..60 here). The unsupported span is the one over the band; with the
-- research every piece is carried. Supports on joints of odd headings face heading mod 8. Chained calls on the
-- turn stop on supports at curve and half-diagonal joints and lay the whole route, as on the copy: (-122,281) to
-- (-21,338) running down south, 5 calls, the game built all 31; without the research 4 calls and 5 half-diagonals
-- over the deep part stayed ghosts.
reset(); deep={y0=40,y1=60}
r=R.plan(p,{from={x=1,y=0},to={x=101,y=100},level='elevated',from_direction='east',to_direction='south'})
assert((r.out.pieces['elevated-curved-rail-a'] or 0)+(r.out.pieces['elevated-curved-rail-b'] or 0)>=4,'a turn')
eq(#r.out.unsupported,1)
local g=r.out.unsupported[1]
assert(g.from.y>=30 and g.to.y<=70,'the span is the deep band: '..g.from.y..'..'..g.to.y)
local bad2=carried(r)
assert(#bad2>0 and #bad2==g.pieces,'the span\'s pieces, no others: '..#bad2..' vs '..g.pieces)
researched=true
r=R.plan(p,{from={x=1,y=0},to={x=101,y=100},level='elevated',from_direction='east',to_direction='south'})
eq(r.out.unsupported,nil); eq(#carried(r),0)
local odd=0
for _,e in ipairs(r.entities) do if e.name=='rail-support' then assert(dirs[e.direction]<8,e.direction); odd=odd+1 end end
assert(odd>=4)
reset()
args,calls,laid={from={x=1,y=0},to={x=101,y=100},level='elevated',from_direction='east',to_direction='south'},0,{}
local cut_headings={}
while args and calls<12 do
  calls=calls+1
  local plan=R.plan(p,args)
  local part,capped=R.cut(plan,args)
  for _,e in ipairs(part or plan.entities) do rail(e.name,e.position.x,e.position.y,dirs[e.direction],true); laid[#laid+1]=e end
  if capped then cut_headings[#cut_headings+1]=capped.continue_from.heading end
  args=capped and capped.next_call
end
assert(calls>=2,'more than one call')
by={}
for _,e in ipairs(laid) do by[e.name]=(by[e.name] or 0)+1 end
eq(by['rail-ramp'],2)
local curves2=(by['elevated-curved-rail-a'] or 0)+(by['elevated-curved-rail-b'] or 0)
assert(curves2>=4,'the chained calls lay the turn: '..curves2)

-- The schema names the new arguments.
assert(R.schema.rail_route.level and R.schema.rail_route.elevated and R.schema.rail_route.to_direction)
print('elevated ok')
