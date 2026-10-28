-- Run from repository root: lua tests/d28_batch305c.lua
-- (d28 batch305 NR) cp3: the carry across shifts. The store lives in harness storage (plain data), so a route kept in
-- one shift serves the next: shift_start names the shift (routes asked from then on say it), a new runtime (a deploy,
-- the next shift's load) reads the same routes, and the reuse reads them again first as always. Wiring: the runtime's
-- module, events, shift_start and the drive's last; control.lua forwards the robot, script, nest and tile events.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function read(p) local f=assert(io.open(p)); local s=f:read('a'); f:close(); return s end
storage={}
local function state() return storage end
defines={events={on_built_entity=6,on_robot_built_entity=14,script_raised_set_tiles=98}}
local player={name='player'}
game={tick=50000,forces={player=player}}
local units={}
game.get_entity_by_unit_number=function(u) return units[u] end
local tiles={}
local function paint(name,x1,y1,x2,y2) for x=x1,x2 do for y=y1,y2 do tiles[x..','..y]=name end end end
local surface={name='nauvis',index=1}
surface.get_tile=function(x,y)
  local name=tiles[math.floor(x)..','..math.floor(y)] or 'grass-1'
  local w=name=='water'
  return {valid=true,name=name,collides_with=function(l) return w and (l=='water_tile' or l=='player' or l=='doodad') or false end,
    prototype={collision_mask={layers=w and {player=true,water_tile=true} or {}}}}
end
surface.find_entities_filtered=function() return {} end
local requests={}
surface.request_path=function(r) requests[#requests+1]=r; return 900+#requests end
local function position(q) return {x=q.x or q[1],y=q.y or q[2]} end
local function load_runtime()
  local S=dofile('mod/agent-harness_0.1.0/sharedroutes.lua'){state=state}
  local P=dofile('mod/agent-harness_0.1.0/spiderpath.lua'){state=state,routes=S}
  local R=dofile('mod/agent-harness_0.1.0/spiderroute.lua'){state=state,position=position,who=function(x) return x.name end,path=P}
  return S,P,R
end
local route={}
local sd={valid=true,name='spidertron',unit_number=8101,position={x=0.5,y=0.5},surface=surface,force=player}
local spider=setmetatable({},{__index=function(_,k)
  if k=='autopilot_destinations' then return route end
  if k=='autopilot_destination' then return route[1] end
  return sd[k]
end,__newindex=function(_,k,v) if k=='autopilot_destination' then route={}; if v then route[1]=v end else sd[k]=v end end})
sd.get_spider_legs=function() return {{prototype={collision_mask={layers={player=true,rail=true}}}}} end
sd.add_autopilot_destination=function(q) route[#route+1]={x=q.x or q[1],y=q.y or q[2]} end
units[8101]=spider
paint('water',10,-40,40,40)
local around={}
for _,q in ipairs({{0.5,0.5},{0.5,-45.5},{30.5,-45.5},{60.5,-45.5},{60.5,0.5}}) do around[#around+1]={position={x=q[1],y=q[2]}} end

-- shift 89: sol's go_to asks the pathfinder; the path is kept, naming the shift
local S,P,R=load_runtime()
eq(S.shift_start(89).routes,0)
R.set(spider,{go_to={x=60.5,y=0.5}},'sol')
P.on_path({id=901,path=around},function(rec,plan,sp,pts,notes) R.routed(rec,plan,sp,pts,notes) end)
local kept=storage.sharedroutes.routes[1]
eq(kept.shift,89); eq(kept.by,'sol')

-- between shifts: the world is saved and loaded, a new runtime deployed (a new module instance on the same storage);
-- shift 90 starts with the route kept
game.tick=50000+3600*5
S,P,R=load_runtime()
eq(S.shift_start(90).routes,1)
route={}; sd.position={x=1.5,y=0.5}
local out=R.set(spider,{go_to={x=60.5,y=0.5}},'astra')
eq(#requests,1,'no path asked in shift 90')
eq(out.shared_route,'reused route 1 (checked at tick 68000): asked by sol at tick 50000 (5m00s ago, shift 89); its '..#kept.legs..' legs unchanged')
-- read again first in the new shift as always: a tile changed between shifts makes that leg stale
route={}
paint('water',45,-46,45,-46)
out=R.set(spider,{go_to={x=60.5,y=0.5}},'astra')
eq(#requests,2); has(out.shared_route,'was grass-1, now water')
-- the routes read names the shift
local lst=S.list(surface,{x=0,y=0})
has(lst.routes_here[1],'asked by sol at tick 50000 (5m00s ago, shift 89)')
-- a store of another version (a later runtime that changed its form) starts empty, its count of ids kept
storage.sharedroutes.v=0
eq(S.summary().routes,0); eq(storage.sharedroutes.seq,1)
print('d28_batch305c carry across shifts: ok')

-- wiring
local rt=read('mod/agent-harness_0.1.0/runtime.lua')
has(rt,"M.sharedroutes=require('sharedroutes'){state=state}")
has(rt,"M.spiderpath=require('spiderpath'){state=state,routes=M.sharedroutes}")
has(rt,"M.vehicles=require('vehicles'){routes=M.sharedroutes,")
has(rt,"if M.sharedroutes.events[event.name] then")
has(rt,"pcall(M.sharedroutes.shift_start,n)")
has(rt,"last.shared_route=nav.shared")
local control=read('mod/agent-harness_0.1.0/control.lua')
for _,n in ipairs({'on_robot_built_entity','script_raised_built','script_raised_revive','script_raised_destroy','on_biter_base_built',
  'on_player_built_tile','on_robot_built_tile','on_player_mined_tile','on_robot_mined_tile','script_raised_set_tiles'}) do has(control,"'"..n.."'") end
-- every event the store marks from is one control.lua forwards
local src=read('mod/agent-harness_0.1.0/sharedroutes.lua')
local list=src:match("for _, n in ipairs%(%{('on_built_entity'.-)%}%) do")
assert(list,'the event list')
local n=0
for name in list:gmatch("'([%w_]+)'") do n=n+1; has(control,"'"..name.."'") end
eq(n,14)
print('d28_batch305c wiring: ok')
