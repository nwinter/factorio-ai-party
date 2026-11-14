-- mt302 (private: late-game forces on 2.1). Run from the harness root: lua mod/tests/mt302_test.lua
-- mt_force_move moves a force's entities on a surface and never a cargo pod: on 2.1.24 writing the force of a pod bound
-- for the ground crashes the server at the next ground landing on that surface (report-mt302).
local n=0
local function eq(a,b,m) n=n+1;assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) n=n+1;local good,err=pcall(fn);assert(not good and tostring(err):find(text,1,true),tostring(err)) end

local red,blue={name='red'},{name='blue'}
local writes={}
local function ent(type,x,y,force,opts)
  local e={valid=true,type=type,position={x=x,y=y},_force=force,_locked=opts and opts.locked}
  return setmetatable(e,{__index=function(t,k) if k=='force' then return rawget(t,'_force') end end,
    __newindex=function(t,k,v)
      if k=='force' then
        if rawget(t,'_locked') then error('cannot change force') end
        writes[#writes+1]=rawget(t,'type'); rawset(t,'_force',v)
      else rawset(t,k,v) end
    end})
end
local list={ent('assembling-machine',1,1,red),ent('cargo-pod',2,2,red),ent('character',3,3,red),
  ent('cargo-landing-pad',4,4,red),ent('gun-turret',50,50,red),ent('wall',5,5,red,{locked=true}),ent('inserter',6,6,blue),ent('space-platform-hub',7,7,red)}
local last_filter
local surface={name='nauvis',find_entities_filtered=function(f)
  last_filter=f
  local out={}
  for _,e in ipairs(list) do
    local inside=true
    if f.area then inside=e.position.x>=f.area[1][1] and e.position.x<=f.area[2][1] and e.position.y>=f.area[1][2] and e.position.y<=f.area[2][2] end
    if e._force==f.force and inside then out[#out+1]=e end
  end
  return out
end}
game={tick=500,forces={red=red,blue=blue},get_surface=function(name) return name=='nauvis' and surface or nil end}
local s={}
local M=dofile('mod/agent-harness_0.1.0/multiteam.lua'){state=function() return s end}

fails(function() M.operator.mt_force_move({from='red'}) end,'to: a force name')
fails(function() M.operator.mt_force_move({from='green',to='blue'}) end,'from: a force name')
fails(function() M.operator.mt_force_move({from='red',to='red'}) end,'the same force')
fails(function() M.operator.mt_force_move({from='red',to='blue',surface='vulcanus'}) end,'no surface vulcanus')
eq(#writes,0,'a refused call writes nothing')

-- an area (corners in either order, either form): the turret at 50,50 stays
local r=M.operator.mt_force_move({from='red',to='blue',area={{10,10},{0,0}},keep_pads=true})
eq(last_filter.area[1][1],0); eq(last_filter.area[2][2],10)
eq(r.moved,1,'the assembler'); eq(r.failed,1,'the wall refused'); eq(r.pods_kept,1); eq(r.characters_kept,1); eq(r.pads_kept,1); eq(r.hubs_kept,1)
eq(list[2]._force,red,'the pod keeps its force'); eq(list[3]._force,red,'the character too'); eq(list[4]._force,red,'and the pad, kept')
eq(list[5]._force,red,'outside the area'); eq(list[8]._force,red,'the hub stays')
for _,t in ipairs(writes) do assert(t~='cargo-pod','a cargo pod force was written') end

-- the whole surface, pads included
writes={}
r=M.operator.mt_force_move({from='red',to='blue'})
eq(r.moved,2,'the pad and the turret'); eq(r.pods_kept,1); eq(r.tick,500)
eq(list[4]._force,blue); eq(list[5]._force,blue); eq(list[2]._force,red,'the pod still keeps its force')
for _,t in ipairs(writes) do assert(t~='cargo-pod','a cargo pod force was written') end
eq(s.mt and next(s.mt) or nil,nil,'no state kept')
game=nil
print('mt302 mt_force_move: ok ('..n..' checks)')
