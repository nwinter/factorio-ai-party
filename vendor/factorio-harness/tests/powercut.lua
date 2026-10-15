-- Run from repository root: lua tests/powercut.lua
-- A pole's death that splits its electric network or leaves machines with no pole (powercut.lua, round2120a; Opus,
-- shift14: a small pole at (78.5,-182.5) cut 20 drills and the uranium line twice, found only by tracing).
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
defines={wire_connector_id={pole_copper=5,circuit_red=1,circuit_green=2},flow_precision_index={five_seconds=0}}
game={tick=1000}
local S={}
local pc=dofile('mod/agent-harness_0.1.0/powercut.lua'){state=function() return S end}
local force={name='player'}
local ents={}
local surface={name='nauvis'}
surface.find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(ents) do
    local ok=e.valid
    if ok and f.force then ok=e.force==f.force end
    if ok and f.name then ok=e.name==f.name end
    if ok and f.area then ok=e.position.x>=f.area[1][1] and e.position.x<=f.area[2][1] and e.position.y>=f.area[1][2] and e.position.y<=f.area[2][2] end
    if ok and f.position then ok=math.abs(e.position.x-f.position.x)<=(f.radius or 0.5) and math.abs(e.position.y-f.position.y)<=(f.radius or 0.5) end
    if ok then out[#out+1]=e end
  end
  return out
end
game.get_surface=function() return surface end
-- Each network's 5 s production, J a tick, by name.
local made={}
local function stats_of(e)
  return {output_counts=made[e.electric_network_id] or {},get_flow_count=function(f)
    eq(f.category,'output'); return (made[e.electric_network_id] or {})[f.name] or 0 end}
end
local units=0
local function entity(t)
  units=units+1
  t.valid=true; t.unit_number=units; t.force=force; t.surface=surface
  setmetatable(t,{__index=function(_,k) if k=='electric_network_statistics' then return stats_of(t) end end})
  ents[#ents+1]=t
  return t
end
local function pole(x,y,net)
  local p=entity({name='small-electric-pole',type='electric-pole',position={x=x,y=y},electric_network_id=net,quality='normal',
    prototype={get_supply_area_distance=function() return 2.5 end}})
  p.wires={[defines.wire_connector_id.pole_copper]={connections={}},[defines.wire_connector_id.circuit_red]={connections={}},[defines.wire_connector_id.circuit_green]={connections={}}}
  p.get_wire_connector=function(id) return p.wires[id] end
  return p
end
local function wire(a,b,id)
  id=id or defines.wire_connector_id.pole_copper
  table.insert(a.wires[id].connections,{target={owner=b}})
  table.insert(b.wires[id].connections,{target={owner=a}})
end
local function drill(x,y,net)
  return entity({name='electric-mining-drill',type='mining-drill',position={x=x,y=y},electric_network_id=net,prototype={electric_energy_source_prototype={}}})
end
local function run(n) for _=1,n do game.tick=game.tick+1; pc.tick(game.tick) end end
local function kill(e,by)
  pc.on_died(e,by)
  e.valid=false
  for _,c in pairs(e.wires or {}) do
    for _,w in ipairs(c.connections) do
      local o=w.target.owner
      for _,oc in pairs(o.wires) do for i=#oc.connections,1,-1 do if oc.connections[i].target.owner==e then table.remove(oc.connections,i) end end end
    end
  end
end

-- A line of poles from a steam engine's side to a mine: the middle one dies, the mine's side has no power.
local p1,p2,p3,p4,p5=pole(0,0,57),pole(7,0,57),pole(14,0,57),pole(21,0,57),pole(28,0,57)
wire(p1,p2); wire(p2,p3); wire(p3,p4); wire(p4,p5)
local d1,d2,d3=drill(21,2,57),drill(28,2,57),drill(29,-2,57)
local inserter=entity({name='inserter',type='inserter',position={x=27,y=1},electric_network_id=57,prototype={electric_energy_source_prototype={}}})
local engine=entity({name='steam-engine',type='generator',position={x=0,y=2},electric_network_id=57,prototype={electric_energy_source_prototype={}}})
made[57]={['steam-engine']=1000}
kill(p3,'big-biter')
eq(#S.powercut.jobs,1)
-- The engine splits it: the far side is network 212 now, with nothing making power.
for _,e in ipairs({p4,p5,d1,d2,d3,inserter}) do e.electric_network_id=212 end
run(329); eq(#S.powercut.cuts,0,'not before 5.5 s')
run(10)
eq(#S.powercut.jobs,0); eq(#S.powercut.cuts,1)
local cut=S.powercut.cuts[1]
eq(pc.line(cut,'nauvis'),'power cut #1: small-electric-pole (14,0) destroyed by big-biter 5s ago: split electric network #57 in 2: #57 has power (60 kW); #212 has no power (2 poles, (21,0)-(28,0)): 3 electric-mining-drill, 1 inserter; no ghost of the pole there')
-- Told once to each agent, in team.alerts; status alerts has it too.
local h={}
eq(pc.lines({surface=surface},h)[1],pc.line(cut,'nauvis')); eq(pc.lines({surface=surface},h),nil)
eq(pc.since(0,'nauvis')[1],pc.line(cut,'nauvis'))
-- On another surface it names the surface.
has(pc.line(cut,'vulcanus'),'power cut #1 on nauvis: ')
-- Rebuilt: the parts are one network again.
for _,e in ipairs({p4,p5,d1,d2,d3,inserter}) do e.electric_network_id=57 end
has(pc.line(cut,'nauvis'),'; joined again since (rebuilt or wired)')

-- A leaf pole that alone reached two drills: they have no network now.
local q1,q2=pole(100,0,60),pole(107,0,60)
wire(q1,q2)
local e1,e2=drill(108,1,60),drill(106,-2,60)
made[60]={['solar-panel']=500}
kill(q2,'small-spitter')
e1.electric_network_id=nil; e2.electric_network_id=nil
-- A ghost of it stands there.
entity({name='entity-ghost',type='entity-ghost',ghost_name='small-electric-pole',position={x=107,y=0}})
run(400)
eq(#S.powercut.cuts,2)
eq(pc.line(S.powercut.cuts[2],'nauvis'),'power cut #2: small-electric-pole (107,0) destroyed by small-spitter 6s ago: 2 machines no other pole reaches have no power (106,-2)-(108,1): 2 electric-mining-drill; a ghost of the pole stands there')
-- An agent told before hears only the new one.
eq(#pc.lines({surface=surface},h),1)
-- Wired again: joined.
e1.electric_network_id=60; e2.electric_network_id=60
has(pc.line(S.powercut.cuts[2],'nauvis'),'; joined again since (rebuilt or wired)')

-- A pole in a loop: its neighbours stay one network, no alert.
local r1,r2,r3,r4=pole(200,0,70),pole(207,0,70),pole(207,7,70),pole(200,7,70)
wire(r1,r2); wire(r2,r3); wire(r3,r4); wire(r4,r1)
kill(r2,'big-biter')
run(400)
eq(#S.powercut.cuts,2,'no split')
-- Split with power on both sides: no alert either.
local s1,s2,s3=pole(300,0,80),pole(307,0,80),pole(314,0,80)
wire(s1,s2); wire(s2,s3)
drill(314,2,80)
kill(s2,'big-biter')
s3.electric_network_id=81; made[80]={generator=100}; made[81]={['solar-panel']=200}
run(400)
eq(#S.powercut.cuts,2,'each part has power')
-- Two poles of one raid cutting the same part: one alert, both poles.
local u1,u2,u3,u4=pole(400,0,90),pole(407,0,90),pole(414,0,90),pole(421,0,90)
wire(u1,u2); wire(u2,u3); wire(u3,u4)
local m4=drill(421,2,90)
made[90]={['steam-engine']=1000}
kill(u2,'big-biter'); kill(u3,'big-biter')
u4.electric_network_id=91; m4.electric_network_id=91
run(400)
eq(#S.powercut.cuts,3)
has(pc.line(S.powercut.cuts[3],'nauvis'),'small-electric-pole (407,0) destroyed by big-biter')
has(pc.line(S.powercut.cuts[3],'nauvis'),' (with small-electric-pole (414,0))')
has(pc.line(S.powercut.cuts[3],'nauvis'),'#91 has no power (1 pole, around (421,0)): 1 electric-mining-drill')
-- A new reader hears only the cuts of the last 5 minutes.
game.tick=game.tick+18001
eq(pc.lines({surface=surface},{}),nil)

-- A pole of a network that made no power in the 5 s before (a part cut off already) is not checked.
local z1,z2,z3=pole(450,0,93),pole(457,0,93),pole(464,0,93)
wire(z1,z2); wire(z2,z3); drill(464,2,93)
kill(z2,'big-biter')
eq(#S.powercut.jobs,0,'no power to lose')
-- A fault drops the job and is counted; the tick goes on.
local bad=pole(500,0,95); local bad2=pole(507,0,95); local bad3=pole(493,0,95)
wire(bad,bad2); wire(bad,bad3)
drill(500,1,95)
made[95]={generator=100}
kill(bad,'x')
S.powercut.jobs[1].neighbours={'not an entity'}
run(340)
eq(#S.powercut.jobs,0); eq(S.powercut.errors.count,1)

-- A pole's copper neighbours, as scan rows give them.
local w1,w2,w3=pole(600,0,99),pole(607,0,99),pole(600,7,99)
wire(w1,w2); wire(w1,w3); wire(w1,w2,defines.wire_connector_id.circuit_red)
eq(pc.copper_line(w1),'(607,0) (600,7)'); eq(pc.copper_line(pole(700,0,100)),'none')
print('powercut: ok')
