-- Run from repository root: lua tests/d21_batch68.lua
-- d21 batch68 AD2 (viewer Aurora: "could installed blueprint areas show tested revision, required hookups and last check,
-- with failed or unverified hookups on every planet's map?"). libareas.lua: the library's remembered placements
-- (checks.lua placements), newest first, one per name and spot, with the entry's facts, the save placed, the newest
-- check over it, and hookups at the area's edge read a few areas a read.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={entity_status={no_power=1,low_power=2,working=3},wire_connector_id={pole_copper=5}}
game={tick=1000}
local force={name='player'}
local function ent(t,x,y,o) o=o or {}; o.valid=true; o.type=t; o.name=o.name or t; o.position={x=x,y=y}; o.force=force; return o end
-- the area (0,0)-(10,10)
local outside_belt=ent('transport-belt',11.5,5.5,{direction=4})
local list={
  ent('transport-belt',9.5,5.5,{direction=4,belt_neighbours={outputs={outside_belt},inputs={}}}),   -- out, joined
  ent('transport-belt',9.5,7.5,{direction=4,belt_neighbours={outputs={},inputs={}}}),               -- out, ends at the edge
  ent('transport-belt',0.5,2.5,{direction=4,belt_neighbours={outputs={},inputs={}}}),               -- in, nothing feeds it
  ent('transport-belt',5.5,5.5,{direction=4,belt_neighbours={outputs={},inputs={}}}),               -- inside only
  ent('inserter',0.5,8.5,{pickup_position={x=-0.5,y=8.5},drop_position={x=1.5,y=8.5},pickup_target=nil,drop_target={}}),
  ent('pipe',5.5,0.5,{fluidbox=setmetatable({[1]={name='water',amount=10},get_pipe_connections=function(i) return {{target_position={x=5.5,y=-0.5}},{target_position={x=5.5,y=1.5},target={}}} end},{__len=function() return 1 end})}),
  ent('assembling-machine',3.5,3.5,{status=1}),
  ent('entity-ghost',7.5,2.5),
  ent('electric-pole',2.5,9.5,{get_wire_connector=function() return {connections={{target={owner=ent('electric-pole',2.5,14.5)}},{target={owner=ent('electric-pole',6.5,9.5)}}}} end}),
}
local surface={name='aquilo',index=5,find_entities_filtered=function() return list end}
game.get_surface=function(i) return i==5 and surface or nil end
game.forces={player=force}
local st={checks={placements={['aq-cell']={{surface=5,box={l=0,t=0,r=10,b=10},tick=400,by='sol',count=9,saved_tick=300},
                                            {surface=5,box={l=0,t=0,r=10,b=10},tick=900,by='astra',count=9,saved_tick=300}},
                              ['old-one']={{surface=5,box={l=40,t=0,r=50,b=8},tick=500,by='luna',count=4}}}},
  bplibrary={entries={['aq-cell']={description='Aquilo heat cell',saved_tick=950,retired={by='sol',reason='leaks heat',replaced_by='aq-cell2',tick=990}}}}}
local L=dofile('mod/agent-harness_0.1.0/libareas.lua'){state=function() return st end,
  check_state=function(name,s,b) if name=='aq-cell' then return {id=3,name='aq check',state='fail',tick=950} end end}
local r=L.read({})
eq(r.placements,2,'one per name and spot'); eq(#r.areas,2)
local a=r.areas[1]
eq(a.name,'aq-cell'); eq(a.tick,900,'the newer paste on the same spot'); eq(a.by,'astra'); eq(a.surface,'aquilo')
eq(a.placed_save,300); eq(a.saved_tick,950,'saved again after it was placed')
eq(a.retired.replaced_by,'aq-cell2'); eq(a.check.state,'fail'); eq(a.description,'Aquilo heat cell')
local h=a.hookups
eq(h.b[3],1,'a belt out joined'); eq(h.b[4],1,'a belt out that ends'); eq(h.b[1],0); eq(h.b[2],1,'a belt in nothing feeds')
eq(h.i[2],1,'an inserter takes from nothing outside'); eq(h.i[3],0,'its drop is inside')
eq(h.p[1],0); eq(h.p[2],1,'one pipe connection open to the outside (the inner one is not counted)')
eq(h.e[1],1); eq(h.e[2],1,'the pole wired to one pole outside'); eq(h.e[3],1,'a machine with no power'); eq(h.g,1)
eq(#h.open,4,'at most MAX_OPEN open hookups'); eq(h.open[1][3],'belt out: ends at the edge'); eq(h.t,1000)
local b=r.areas[2]
eq(b.name,'old-one'); eq(b.deleted,true,'no library entry of that name now'); eq(b.placed_save,nil); eq(b.check,nil)
assert(b.hookups and b.hookups.t==1000,'the second area read in the same read (2 a read)')
-- the next read reads the areas read longest ago first, and keeps the others' hookups with their tick
game.tick=2000
r=L.read({hookups=1})
eq(r.hookups_read,1); eq(r.areas[1].hookups.t+r.areas[2].hookups.t,3000,'one area read again, the other kept')
-- an area over MAX_FIND of ours: not read, said
local many={} for i=1,L.MAX_FIND+1 do many[i]=ent('wall',1,1) end
surface.find_entities_filtered=function() return many end
game.tick=3000
r=L.read({hookups=4})
eq(r.areas[1].hookups.capped,L.MAX_FIND)
-- a placement on a surface deleted since: left out
st.checks.placements['gone-one']={{surface=9,box={l=0,t=0,r=4,b=4},tick=2500,by='sol',count=2}}
r=L.read({hookups=0})
eq(r.placements,2,'the deleted surface\'s placement is not an area')
print('d21_batch68 AD2 library areas: ok')
