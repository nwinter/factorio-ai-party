-- d21 batch64 Z6 (#1655, Astra). Run from the harness root: lua tests/d21_batch64c.lua
-- A fusion reactor's neighbours (the prototype's neighbour points, plasma or coolant side), its most at its quality,
-- and fuel burnt measured over samples with coolant and plasma derived from it. Fake engine.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
game={tick=0}
defines={}
local function conn(cat,x,y,d) return {category='fusion-reactor-'..cat,location={position={x=x,y=y},direction=d},neighbour_category={'fusion-reactor-plasma','fusion-reactor-coolant'}} end
local nc={affected_by_direction=true,neighbour_search_distance=0.7,connections={conn('plasma',-1.5,-3,0),conn('plasma',1.5,-3,0),conn('coolant',3,-1.5,4),
  conn('coolant',3,1.5,4),conn('plasma',1.5,3,8),conn('plasma',-1.5,3,8),conn('coolant',-3,1.5,12),conn('coolant',-3,-1.5,12)}}
local scale={normal=1,legendary=2.5}
local proto={neighbour_bonus=1,neighbour_connectable=nc,get_fluid_usage_per_tick=function(q) return 4/60*scale[q and q.name or 'normal'] end,
  get_max_energy_usage=function() return 10e6/60 end}
prototypes={fluid={['fusion-plasma']={heat_capacity=25,default_temperature=1e6}}}
local all={}
local surface={find_entities_filtered=function(f)
  local out={}
  for _,e in ipairs(all) do if e.valid and e.type==f.type and math.abs(e.position.x-f.position.x)<=f.radius and math.abs(e.position.y-f.position.y)<=f.radius then out[#out+1]=e end end
  return out
end}
local units=0
local function reactor(x,y,dir,q)
  units=units+1
  local cell={valid_for_read=true,count=4,prototype={fuel_value=4e10}}
  local e={valid=true,type='fusion-reactor',name='fusion-reactor',unit_number=units,position={x=x,y=y},direction=dir or 0,surface=surface,prototype=proto,
    quality={name=q or 'normal'},status=1,burner={remaining_burning_fuel=4e10,inventory={cell,get_item_count=function() return cell.count end},
    currently_burning={name={name='fusion-power-cell'}}}}
  e.fluidbox={{name='fluoroketone-cold',amount=1000},{name='fusion-plasma',amount=3,temperature=2e6},get_connections=function() return {} end}
  all[#all+1]=e
  return e
end
local st={}
local F=require('fusion'){state=function() return st end}
-- a pair joined plasma to plasma (north, the second 6 tiles south), one joined only coolant side to coolant side,
-- one two tiles off its side (its points miss), and one turned east whose plasma side meets a north one's coolant side
local r1,r2=reactor(-150,0),reactor(-150,6)
local r3,r4=reactor(-135,-3),reactor(-129,-3)
local r5,r6=reactor(0,0),reactor(6,2)
local r7,r8=reactor(50,0),reactor(56,0,4,'legendary')
local a=F.read(r1)
eq(#a.neighbours,1); eq(a.neighbours[1].y,6); eq(a.neighbours[1].sides,'plasma-plasma'); eq(a.neighbour_bonus.at_full,1)
eq(a.max.coolant_per_s,4); eq(a.max.fuel_mw,100); eq(a.max.electric_mw,10); eq(a.max.plasma_mw_alone,100); eq(a.max.plasma_mw_with_neighbours,200)
eq(a.now.plasma.bonus_seen,1)
has(a.line,'fusion-reactor (-150,0): neighbour reactor (-150,6) (plasma-plasma), bonus 1 at full')
has(a.line,'no rates yet: sampling began at this read')
eq(F.read(r3).neighbours[1].sides,'coolant-coolant')
local off=F.read(r5)
eq(#off.neighbours,0); eq(off.neighbour_bonus.at_full,0)
has(off.line,'no neighbour reactor (none whose side points meet its own), bonus 0')
local turned=F.read(r7)
eq(turned.neighbours[1].sides,'coolant-plasma','the east one\'s plasma side meets the north one\'s coolant side')
local leg=F.read(r8)
eq(leg.max.quality,'legendary'); eq(leg.max.coolant_per_s,10); eq(leg.max.fuel_mw,250); eq(leg.max.electric_mw,10); eq(leg.max.plasma_mw_with_neighbours,500)
-- 30 s of samples: r1 burns 100 MW (its most), r2 20.7 MW; a cell put in r2 is not counted as burnt
for t=1,1800 do
  game.tick=t
  r1.burner.remaining_burning_fuel=r1.burner.remaining_burning_fuel-100e6/60
  r2.burner.remaining_burning_fuel=r2.burner.remaining_burning_fuel-20.7e6/60
  if t==900 then r2.burner.inventory[1].count=5 end
  F.tick(t)
end
a=F.read(r1)
eq(a.measured.fuel_mw,100); eq(a.measured.running_pct,100); eq(a.measured.coolant_per_s,4); eq(a.measured.plasma_per_s,4)
eq(a.measured.bonus_estimate,0.21); eq(a.measured.plasma_mw_estimate,120.7)
local b=F.read(r2)
eq(b.measured.fuel_mw,20.7); eq(b.measured.coolant_per_s,0.828); eq(b.measured.plasma_mw_estimate,41.4)
has(b.line,'measured over the last 30 s (rolling): 20.7 MW of fuel (21%), 0.828 coolant and plasma a second (derived), about 41.4 MW of plasma with the bonus its neighbours give now (estimate)')
-- (Z7) the window is the last 30 s; totals cover the stretch since sampling began, the refuel second a gap
eq(a.measured.window,'rolling: the last 30 s (31 samples 1 s apart)')
eq(a.totals.since_s,30); eq(a.totals.covered_s,30); eq(a.totals.running_s,30); eq(a.totals.fuel_mj,3000); eq(a.totals.fuel_mw_avg,100); eq(a.totals.gaps,0)
eq(b.totals.covered_s,29); eq(b.totals.gaps,1); eq(b.totals.gap_s,1); eq(b.totals.put_in_mj,40000-21); eq(b.totals.fuel_mj,600); eq(b.totals.fuel_mw_avg,20.7); eq(b.totals.running_pct,21)
has(b.line,'since sampling began 30 s ago: 600 MJ of fuel over 29 s covered (20.7 MW average, 21%), burning 29 s, 1 gap (1 s, cells put in); sampling ends 600 s from now unless read again')
eq(b.sampling.began_tick,0); eq(b.sampling.ends_tick,1800+36000)
-- 600 s on: the window still 30 s, the totals the whole run
for t=1801,1800+36000-60 do
  game.tick=t
  r2.burner.remaining_burning_fuel=r2.burner.remaining_burning_fuel-20.7e6/60
  F.tick(t)
end
b=F.read(r2)
eq(b.measured.over_s,30); eq(b.totals.since_s,629); eq(b.totals.covered_s,628); eq(b.totals.fuel_mw_avg,20.7)
-- (d20 batch71 AG3) the stretch ends 600 s after the last read; a read 6.5 s later begins a new one and gives the
-- ended one's totals frozen, expired, with its ended tick
local ended_at=b.sampling.ends_tick
for t=game.tick+1,ended_at+60 do game.tick=t; r2.burner.remaining_burning_fuel=r2.burner.remaining_burning_fuel-20.7e6/60; F.tick(t) end
eq(st.fusion.watch[r2.unit_number],nil,'sampling ended')
game.tick=ended_at+390
b=F.read(r2)
eq(b.totals,nil); eq(b.last_stretch.expired,true); eq(b.last_stretch.ended_tick,ended_at); eq(b.last_stretch.began_tick,0)
eq(b.last_stretch.fuel_mw_avg,20.7); eq(b.last_stretch.since_s,math.floor(ended_at/60+0.5)); eq(b.last_stretch.ended_s_ago,7)
has(b.last_stretch.note,'this read began a new stretch')
has(b.line,'the last stretch (expired: it ended 7 s ago at tick '..ended_at..'): ')
has(b.line,'(20.7 MW average, 21%)')
-- later reads in the new stretch still give it, until the new stretch ends and replaces it
for t=game.tick+1,game.tick+120 do game.tick=t; r2.burner.remaining_burning_fuel=r2.burner.remaining_burning_fuel-50e6/60; F.tick(t) end
b=F.read(r2)
eq(b.last_stretch.ended_tick,ended_at); eq(b.totals.fuel_mw_avg,50); has(b.last_stretch.note,'a new stretch began at tick '..(ended_at+390))
-- a reactor not read for 10 min is no longer sampled
game.tick=game.tick+36060-game.tick%60; F.tick(game.tick)
eq(st.fusion.watch[r5.unit_number],nil)
print('d21_batch64c Z6 fusion: ok')
