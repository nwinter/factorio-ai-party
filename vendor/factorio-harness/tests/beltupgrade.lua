-- belt_upgrade (batch25 B1, Opus: straight lines over a curve broke a trunk): the line traced both ways, each tile
-- replaced at its own position and direction (an underground's input or output kept), by build with all.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
prototypes={entity={}}
for _,tier in ipairs({'','fast-','express-','turbo-'}) do
  for _,k in ipairs({'transport-belt','underground-belt','splitter'}) do
    prototypes.entity[tier..k]={name=tier..k,items_to_place_this={{name=tier..k}}}
  end
end
prototypes.entity['transport-belt'].next_upgrade=prototypes.entity['fast-transport-belt']
prototypes.entity['underground-belt'].next_upgrade=prototypes.entity['fast-underground-belt']
local n=0
local function belt(x,y,dir,kind,name)
  n=n+1
  kind=kind or 'transport-belt'
  local name2=name or kind
  return {valid=true,unit_number=n,type=kind,name=name2,position={x=x,y=y},direction=dir,prototype=prototypes.entity[name2],belt_neighbours={inputs={},outputs={}}}
end
-- east along y=0.5 from x=0.5 to 2.5, a curve at (3.5,0.5) turning south, then south to (3.5,2.5); an underground
-- pair (3.5,3.5) in, (3.5,6.5) out; one belt after it already turbo
local line={belt(0.5,0.5,4),belt(1.5,0.5,4),belt(2.5,0.5,4),belt(3.5,0.5,8),belt(3.5,1.5,8),belt(3.5,2.5,8),
  belt(3.5,3.5,8,'underground-belt'),belt(3.5,6.5,8,'underground-belt'),belt(3.5,7.5,8,'transport-belt','turbo-transport-belt')}
line[7].belt_to_ground_type='input'; line[8].belt_to_ground_type='output'; line[7].neighbours=line[8]; line[8].neighbours=line[7]
for i=1,#line-1 do
  if i~=7 then line[i].belt_neighbours.outputs={line[i+1]}; line[i+1].belt_neighbours.inputs={line[i]} end
end
local sent
local U=require('beltupgrade'){entity=function(_,a) for _,b in ipairs(line) do if b.position.x==a.position.x and b.position.y==a.position.y then return b end end error('nothing there') end,
  compass=function(d) return ({[0]='north',[4]='east',[8]='south',[12]='west'})[d] end,
  build=function(_,a) sent=a; return {built=#a.builds} end}
local r=U.handler({},{position={x=3.5,y=1.5}})
eq(r.tiles,9); eq(r.upgrades,8); eq(r.needs,'fast-transport-belt 6, fast-underground-belt 2')
eq(r.left[1],'turbo-transport-belt (3.5,7.5): no upgrade')
eq(#sent.builds,8); eq(sent.all,true)
eq(sent.builds[3].direction,4); eq(sent.builds[4].direction,8) -- the curve tile keeps its own direction
eq(sent.builds[7].item,'fast-underground-belt'); eq(sent.builds[7].type,'input'); eq(sent.builds[8].type,'output')
eq(r.rows[4],'transport-belt (3.5,0.5) facing south -> fast-transport-belt')
-- to: turbo; the tile already turbo is left
r=U.handler({},{position={x=0.5,y=0.5},to='turbo-transport-belt',dry_run=true})
eq(r.upgrades,8); eq(r.left[1],'turbo-transport-belt (3.5,7.5): already turbo-transport-belt'); eq(sent.dry_run,true)
eq(sent.builds[7].item,'turbo-underground-belt')
fails(function() U.handler({},{position={x=0.5,y=0.5},to='fast-inserter'}) end,'to: a transport belt name')
r=U.handler({},{position={x=0.5,y=0.5},tiles=3}); eq(r.tiles,3)
print('beltupgrade: ok')
