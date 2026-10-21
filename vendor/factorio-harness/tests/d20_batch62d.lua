-- d20 batch62 X4 (Astra #1555). Run from the harness root: lua tests/d20_batch62d.lua
-- belt_flow {surface}: the belt there by remote view, as trace reads one: the line walked where the map is charted,
-- a point sampled only while its chunk is in sight (radar coverage). The reads of our entities that took no surface.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

local nauvis,aquilo={name='nauvis'},{name='aquilo'}
-- Nauvis: chunk column 0 in sight, column 1 charted only, column 2 uncharted
local sight={[0]=true}
local force={name='player',
  is_chunk_visible=function(s,c) return s==nauvis and sight[c.x]==true end,
  is_chunk_charted=function(s,c) return s==nauvis and c.x<=1 end}
game={tick=0,forces={player=force},get_surface=function(n) return ({nauvis=nauvis,aquilo=aquilo})[n] end}
local storage={}
local n=0
local function belt(x,y,dir)
  n=n+1
  local e={valid=true,unit_number=n,type='transport-belt',name='transport-belt',surface=nauvis,position={x=x,y=y},direction=dir,
    prototype={belt_speed=0.03125},belt_neighbours={inputs={},outputs={}}}
  -- one iron-plate a tile every 32 ticks on the left lane, a new id each time
  e.get_transport_line=function(k) return {get_detailed_contents=function()
    if k~=1 then return {} end
    local t=game.tick
    return {{unique_id=n*100000+e.unit_number*1000+math.floor(t/32),position=(t%32)/32,stack={valid_for_read=true,name='iron-plate'}}} end} end
  return e
end
-- a line east along y=0.5 from x=0.5 to x=70.5; a side belt at (20.5,-0.5) facing south joins at x=20.5
local line={}
for i=0,70 do line[i]=belt(i+0.5,0.5,4) end
for i=1,70 do line[i].belt_neighbours.inputs={line[i-1]}; line[i-1].belt_neighbours.outputs={line[i]} end
local side=belt(20.5,-0.5,8)
table.insert(line[20].belt_neighbours.inputs,side); side.belt_neighbours.outputs={line[20]}
local astra={index=2,force=force,surface=aquilo,position={x=10,y=0}}
local asked
local S=require('beltsample'){state=function() return storage end,
  remote_entity=function(q,a) eq(q.surface,nauvis,'the belt is read on nauvis'); for _,b in pairs(line) do if b.position.x==a.position[1] then return b end end error('no belt there') end,
  on_platform=function(q) return q end,
  on_surface=function(p,name) asked=name; return setmetatable({__remote=name},{__index=function(_,k) if k=='surface' then return game.get_surface(name) end return p[k] end}) end}
local r=S.handler(astra,{surface='nauvis',position={10.5,0.5},seconds=2})
eq(asked,'nauvis'); eq(r.surface,'nauvis')
has(r.note,'the belt line (0.5,0.5) to (63.5,0.5) (64 tiles, 1 merges) on nauvis')
has(r.note,'the line goes on uncharted (on at (64.5,0.5)): not walked')
-- column 1 comes into sight for the second half of the window: that point counts over those samples only
for t=1,140 do game.tick=t; if t==70 then sight[1]=true end; if t==71 then sight[1]=nil end; S.tick(t) end
r=S.handler(astra,{})
eq(r.done,true); eq(r.surface,'nauvis')
eq(r.points[1].out_of_sight,nil)
eq(r.points[2].out_of_sight,nil)
eq(r.points[3].out_of_sight,'out of sight (no radar coverage there): not sampled')
has(r.lines[1],'section (0.5,0.5) to (19.5,0.5) (20 tiles): left lane ')
has(r.lines[3],'section (20.5,0.5) to (63.5,0.5) (44 tiles): out of sight (no radar coverage there): not sampled')
eq(r.lines[#r.lines],'the line goes on uncharted (on at (64.5,0.5)): not walked')
-- in sight for part of the window: counted over the rest, said so
storage={}
game.tick=200
S.handler(astra,{surface='nauvis',position={10.5,0.5},seconds=2})
for t=201,340 do game.tick=t; sight[1]=t>=270 or nil; S.tick(t) end
r=S.handler(astra,{})
has(r.points[3].out_of_sight,'out of sight for ')
has(r.points[3].out_of_sight,' samples: counted over the rest')
-- refusals: surface goes with position; surface or platform
fails(function() S.handler(astra,{surface='nauvis'}) end,'surface and platform go with position (a belt there)')
fails(function() S.handler(astra,{surface='nauvis',platform='Kestrel',position={10.5,0.5}}) end,'give platform or surface, not both')
print('d20_batch62d belt_flow by remote view: ok')

-- The reads of our entities that take surface by remote view now (bots.lua's list, runtime.lua wraps them; pipe_gaps
-- and circuit_audit take it in their own handlers, belt_flow in beltsample.lua).
game=nil
local bots=dofile('mod/agent-harness_0.1.0/bots.lua')
local B=bots{state=function() return {} end}
local on={}
for _,name in ipairs(B.SURFACE_ACTIONS) do on[name]=true end
for _,name in ipairs({'heat_budget','ports','ingredient_gap','defense','flamers','cargo'}) do assert(on[name],name..' is not on SURFACE_ACTIONS') end
local src=io.open('mod/agent-harness_0.1.0/runtime.lua'):read('a')
has(src,"if a.surface~=nil then return handlers.pipe_gaps(M.on_surface(p,a.surface),M.without(a,'surface')) end")
has(src,"circuit_audit with surface needs area or positions there")
-- a remote proxy is never within 32 tiles of the character (heating.lua, ingredient_gap's seen)
has(io.open('mod/agent-harness_0.1.0/heating.lua'):read('a'),"or not (type(p)=='table' and rawget(p,'__remote')) and p.position")
print('d20_batch62d: ok')
