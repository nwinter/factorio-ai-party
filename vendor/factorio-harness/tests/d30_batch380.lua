-- Run from the harness root: lua tests/d30_batch380.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,t) assert(s:find(t,1,true),s..' lacks '..t) end
defines={events={},controllers={},direction={north=0,east=4,south=8,west=12},inventory={},
  build_check_type={manual=0,manual_ghost=1},flow_precision_index={five_seconds=0,one_minute=1}}
storage={agent_harness={}}
game={tick=0}
prototypes={entity={},item={},tile={}}
for _,name in ipairs({'transport-belt','underground-belt','fast-underground-belt','pipe-to-ground'}) do
  local kind=name=='fast-underground-belt' and 'underground-belt' or name
  local pr={name=name,type=kind,max_underground_distance=5,tile_width=1,tile_height=1,
    collision_box={left_top={x=-.4,y=-.4},right_bottom={x=.4,y=.4}},collision_mask={layers={object=true}},
    items_to_place_this={{name=name,count=1}}}
  prototypes.entity[name]=pr; prototypes.item[name]={name=name,place_result=pr}
end
local f={name='player',is_chunk_charted=function() return true end}
local built,reads,terrain,charted={},0,{},true
local s={name='test',index=1}
s.find_entities_filtered=function(filter)
  reads=reads+1
  local out={}
  for _,e in ipairs(built) do
    local yes=e.force==f
    if filter.name then yes=yes and e.name==filter.name end
    if filter.ghost_name then yes=yes and e.ghost_name==filter.ghost_name end
    if filter.position then yes=yes and e.position.x==filter.position.x and e.position.y==filter.position.y end
    if filter.area then
      local a,b=filter.area.left_top,filter.area.right_bottom
      yes=yes and e.position.x>=a.x and e.position.x<=b.x and e.position.y>=a.y and e.position.y<=b.y
    end
    if yes then out[#out+1]=e end
  end
  return out
end
s.get_tile=function(x,y)
  local n=terrain[math.floor(x)..','..math.floor(y)] or 'grass-1'
  return {name=n,valid=true,prototype={collision_mask={layers=n=='lava' and {lava_tile=true} or n=='empty-space' and {empty_space=true} or {}}}}
end
s.count_entities_filtered=function() return 0 end
s.can_place_entity=function() return true end
local p={index=1,surface=s,force=f,position={x=0,y=0},get_main_inventory=function() return nil end}
local U=require('undergroundplan'){charted=function(_,pos) return charted or pos.x<2 end}
local function rec(x,y,kind,dir,name)
  name=name or 'underground-belt'
  return {index=1,name=name,pos={x=x+.5,y=y+.5},proto=prototypes.entity[name],dir=dir or 4,ug_type=kind,status='ok'}
end
local function check(list,details)
  for i,r in ipairs(list) do r.index=i end
  return U.check(p,list,details)
end
local function existing(x,y,kind,dir,name,ghost)
  name=name or 'underground-belt'
  local e={valid=true,name=ghost and 'entity-ghost' or name,type=ghost and 'entity-ghost' or 'underground-belt',
    ghost_name=ghost and name or nil,position={x=x+.5,y=y+.5},direction=dir or 4,belt_to_ground_type=kind,force=f}
  built[#built+1]=e; return e
end
-- Correct flow in all four headings, and no output rows for ordinary pairs.
for _,d in ipairs({{0,0,-5},{4,5,0},{8,0,5},{12,-5,0}}) do
  local o=check({rec(0,0,'input',d[1]),rec(d[2],d[3],'output',d[1])})
  eq(o.paired,2); eq(o.unpaired,0); eq(o.rows,nil)
end
local o=check({rec(0,0),rec(5,0)})
eq(o.unpaired,2); has(o.rows[1].line,'input (0.5,0.5): unpaired')
eq(check({rec(0,0,'input'),rec(6,0,'output')}).unpaired,2)
-- A new request end intercepts a pair from another route in the same batch.
o=check({rec(0,0,'input'),rec(5,0,'output'),rec(3,0,'input')},true)
eq(o.unpaired,1); eq(o.paired,2); eq(o.rows[2].partner.index,3)
has(o.rows[1].line,'(3.5,0.5) does not pair back')
-- Existing built ends and ghosts outside the request are both named.
for _,ghost in ipairs({false,true}) do
  built={}; existing(3,0,'output',4,nil,ghost)
  o=check({rec(0,0,'input'),rec(5,0,'output')})
  eq(o.external,1); eq(o.unpaired,1)
  has(o.rows[1].line,ghost and 'ghost outside request' or 'built outside request')
  has(o.rows[1].line,'(0.5,0.5)'); has(o.rows[1].line,'(3.5,0.5)')
end
-- Other tiers, perpendicular ends and other forces do not intercept.
built={}; existing(2,0,'output',4,'fast-underground-belt'); existing(3,0,'input',0)
existing(4,0,'output').force={name='other'}
eq(check({rec(0,0,'input'),rec(5,0,'output')}).paired,2)
built={}
o=check({rec(0,0,'output',12),rec(5,0,'output',4)})
eq(o.flow_mismatch,2); eq(o.paired,0); has(o.rows[1].line,'do not carry flow in the same direction')
-- Blocked/refused entries never supply a partner.
for _,field in ipairs({'status','refused'}) do
  local b=rec(5,0,'output'); b[field]=field=='status' and 'blocked' or true
  eq(check({rec(0,0,'input'),b}).unpaired,1)
end
for _,tile in ipairs({'lava','empty-space'}) do
  terrain={['2,0']=tile}; o=check({rec(0,0,'input'),rec(5,0,'output')})
  eq(o.unpaired,2); has(o.rows[1].line,'cannot pass under '..tile..' at (2.5,0.5)')
end
terrain={}; charted=false
o=check({rec(0,0,'input')}); has(o.rows[1].line,'uncharted tile')
charted=true
-- Existing requested ends retain their actual type when type was omitted.
built={}; existing(5,0,'output')
local b=rec(5,0); b.status='exists'
eq(check({rec(0,0,'input'),b}).paired,2)
built={}; reads=0
eq(check({rec(0,0,nil,4,'transport-belt')}),nil); eq(reads,0)
-- 50 ends: two local finds per end, no surface-wide bounding rectangle.
local fifty={}
for i=0,24 do fifty[#fifty+1]=rec(0,i*3,'input'); fifty[#fifty+1]=rec(5,i*3,'output') end
reads=0; eq(check(fifty).paired,50); eq(reads,100)

-- Exercise the real runtime conversion and dry-run checker with a saved route
-- plan. The route suite separately exercises the planner around obstacles.
local R=require('runtime')
R.dryrun=require('dryrun'){charted=function() return true end,own_platform=function() return false end,
  placewhy=require('placewhy'){},placement_error=function() return 'blocked' end}
local entries={{name='underground-belt',position={x=.5,y=.5},direction='east',type='input'},
  {name='underground-belt',position={x=5.5,y=.5},direction='east',type='output',line='return'}}
R.route_repair=function() return {entities=entries,items={['underground-belt']=2}} end
R.belt_nests=function() end; R.route_feeders=function() end
local h=R.scheduler_api.handlers
local result=h.dry_run(p,{action='belt_route',args={from={x=0,y=0},to={x=5,y=0},details=true}})
eq(result.entities[1].type,'input'); eq(result.entities[2].type,'output')
eq(result.entities[1].index,nil); eq(result.entities[2].line,nil)
eq(#result.entity_checks,2); eq(result.undergrounds.paired,2)
-- The exact returned entries pass the strict place_ghosts entry validator and
-- the actual dry_run handler unchanged, including output surface flow.
R.entryset.check(result.entities,{ghosts=true,force=f})
local again=h.dry_run(p,{action='place_ghosts',args={entities=result.entities,details=true}})
eq(again.undergrounds.paired,2); eq(again.undergrounds.unpaired,0)
eq(again.belts[1].index,2)
result.entities[2].type=nil
local broken=h.dry_run(p,{action='place_ghosts',args={entities=result.entities}})
eq(broken.undergrounds.unpaired,2); has(broken.summary,'2 unpaired')
print('d30_batch380: route entries round-trip; underground pairing diagnostics pass')
