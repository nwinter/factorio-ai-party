-- d24 batch135 PG1 (Sol #2103): gates {surface: nauvis, area} from Vulcanus read Vulcanus's foundry at the same
-- coordinates; the area is read on the surface named. danger with surface and no position, where the character stands
-- on another surface, is refused (it read the character's coordinates on the named surface).
-- Run from the harness root: lua tests/d24_batch135.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(f,x) local ok,err=pcall(f); assert(not ok,'did not fail'); has(err,x) end
game={tick=1000}
defines={entity_status={disabled_by_control_behavior=9}}
local force={name='player'}
local function gate(name,x,y,surface)
  return {valid=true,name=name,type='assembling-machine',position={x=x,y=y},force=force,surface=surface,status=1,
    get_control_behavior=function() return {circuit_condition={first_signal={type='virtual',name='signal-A'},comparator='>',constant=0}} end}
end
local nauvis,vulcanus={name='nauvis'},{name='vulcanus'}
local pad_decider=gate('decider-combinator',51.5,48,nauvis)
local foundry=gate('foundry',43.5,55.5,vulcanus)
nauvis.find_entities_filtered=function(f) assert(f.area); return {pad_decider} end
vulcanus.find_entities_filtered=function(f) assert(f.area); return {foundry} end
game.get_surface=function(n) return ({nauvis=nauvis,vulcanus=vulcanus})[n] end
local G=dofile('mod/agent-harness_0.1.0/gates.lua'){position=function(v) return {x=v.x,y=v.y} end,
  circuit_read=function() return {enable='signal-A > 0',enable_met=true} end}
local sol={force=force,surface=vulcanus}
local area={left_top={x=45,y=45},right_bottom={x=54,y=56}}
local r=G.read(sol,{surface='nauvis',area=area})
eq(r.surface,'nauvis','before: vulcanus'); eq(r.gates,1); has(r.lines[1],'decider-combinator (51.5,48)')
has(r.line,'1 gates on nauvis')
-- the same area without surface: yours
r=G.read(sol,{area=area})
eq(r.surface,'vulcanus'); has(r.lines[1],'foundry (43.5,55.5)')
fails(function() G.read(sol,{surface='nowhere',area=area}) end,'no surface nowhere')

-- danger: surface without position from another surface is refused; with position it reads there
local st={}
local D=dofile('mod/agent-harness_0.1.0/danger.lua'){state=function() return st end,position=function(v) return {x=v.x,y=v.y} end,
  avoid={structures=function() return {list={},uncharted=0,unread=0} end,reach=function() return 30 end,chunks_near=function() return {} end,seg_dist=function() return 99 end},
  surface=function(_,name) return game.get_surface(name) end}
nauvis.find_entities_filtered=function() return {} end
vulcanus.find_entities_filtered=function() return {} end
local char={valid=true,surface=vulcanus,position={x=10,y=20},health=250,max_health=250,get_inventory=function() return nil end}
local p={force=force,surface=vulcanus,character=char}
fails(function() D.read(p,{surface='nauvis'}) end,'danger with surface needs position there (your character stands on another surface)')
eq(D.read(p,{surface='nauvis',position={x=0,y=0}}).surface,'nauvis')
eq(D.read(p,{surface='vulcanus'}).surface,'vulcanus','your own surface: where you stand')
print('d24_batch135 PG1 reads on the surface named: ok')
