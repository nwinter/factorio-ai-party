-- ER358: the same directional distance and current-speed basis in arrival waits and platform rows.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(s and s:find(x,1,true),tostring(s)..' lacks '..x) end
defines={space_platform_state={on_the_path=1},rocket_silo_status={},entity_status={working=1}}
prototypes={space_connection={}}
game={tick=6000}
local st={freight={[1]={cruise=131.4/60,segs={{kind='leg',start=0,from='aquilo',to='solar-system-edge'}}}}}
local E=require('engine'){state=function() return st end}
local F=require('freight'){state=function() return st end,leg_speed=E.leg_speed}
local S=require('space'){state=function() return st end,freight=F}
local C=require('conditions'){platform_where=F.where}
local W=require('waiteta'){check=function(p,c) return C.check(p,c,true) end,before_departure=F.before_departure}
local pl={valid=true,index=1,name='Resolute',state=1,speed=40.5/60,distance=0.79,
  last_visited_space_location={name='aquilo'},space_connection={name='aq-edge',from={name='aquilo'},to={name='solar-system-edge'},length=100000},
  schedule={current=1,records={{station='aquilo'}}},surface={find_entities_filtered=function() return {} end}}
local p={force={platforms={pl}}}
local c={['until']='platform_arrived',platform='Resolute',location='aquilo'}
local function samples(first,last)
  st.engine={[1]={fluids={},samples={}}}
  for i=0,60 do st.engine[1].samples[#st.engine[1].samples+1]={game.tick-3600+i*60,first+(last-first)*i/60,{},{},{}} end
  pl.speed=last/60
end
samples(27.6,40.5)
local leg=F.leg(pl)
eq(leg.turned_back,true); eq(leg.left_km,79000)
assert(leg.eta_ticks/60<602,'past cruise remains a separately based freight projection')
local met,saw,r=W.check(p,c,{})
eq(met,false); has(saw,'79000 km left'); eq(r.eta_s,math.ceil(79000/40.5))
eq(r.leg_left_km,79000); eq(r.speed_kms,40.5); eq(r.heading_to,'aquilo')
eq(r.eta_uncertain,true); eq(r.speed_trend,'accelerating'); has(r.basis,'speed now 40.500'); has(r.line,'uncertain: accelerating')
has(r.basis,'assumes this speed is maintained')
local flight=S.flight(pl)
eq(flight.eta_s,r.eta_s); eq(flight.eta_basis,r.basis); eq(flight.leg_left_km,r.leg_left_km)
eq(flight.eta_min,32.5); eq(flight.eta_uncertain,true)
local scheduled=F.before_departure(pl,'aquilo'); eq(scheduled.eta_s,r.eta_s); has(scheduled.line,'uncertain: accelerating')
-- A normal leg at steady speed preserves distance / speed; no cruise substitution, no acceleration warning.
pl.schedule.records[1].station='solar-system-edge'; c.location='solar-system-edge'
samples(100,100)
met,saw,r=W.check(p,c,{})
eq(r.eta_s,210); eq(r.leg_left_km,21000); eq(r.speed_trend,'steady'); eq(r.eta_uncertain,false)
eq(S.flight(pl).eta_s,210)
-- The original connection can also be flown backwards without turning back on this leg.
pl.last_visited_space_location={name='solar-system-edge'}; pl.schedule.records[1].station='aquilo'; c.location='aquilo'
samples(70,40.5)
r=select(3,W.check(p,c,{})); eq(r.eta_s,math.ceil(79000/40.5)); has(r.basis,'uncertain: decelerating')
-- Zero/failed speed cannot inherit a past ETA, and paused waits remain unknown.
pl.speed=0; r=select(3,W.check(p,c,{})); eq(r.eta_s,nil); has(r.no_estimate,'speed is zero')
eq(S.flight(pl).eta_s,nil)
pl.speed=nil; eq(select(3,W.check(p,c,{})).eta_s,nil)
pl.speed=40.5/60; pl.paused=true; has(select(3,W.check(p,c,{})).no_estimate,'paused'); pl.paused=false
-- No/stale observations are explicit uncertainty, not an inferred acceleration.
st.engine={}; r=select(3,W.check(p,c,{})); eq(r.eta_uncertain,true); eq(r.speed_trend,'unknown')
has(r.basis,'no fresh speed comparison')
samples(27.6,40.5); game.tick=game.tick+180
r=select(3,W.check(p,c,{})); eq(r.speed_trend,'unknown')
print('arrival reversal: 79% turnback, normal leg, acceleration/deceleration, shared platform/wait ETA and unknown reads: ok')
