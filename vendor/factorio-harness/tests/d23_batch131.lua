-- d23 batch131 CN1 (Astra #2088): a platform turned back mid-connection reads as heading back, with the km left to
-- the end it flies to, its ETA and its fuel trend on that leg. Run from the harness root: lua tests/d23_batch131.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

do
  defines={space_platform_state={on_the_path=9},inventory={hub_main=1,hub_trash=2}}
  local edge_sp={name='solar-system-edge-shattered-planet',from={name='solar-system-edge'},to={name='shattered-planet'},length=4000000}
  prototypes={space_connection={aq={from={name='aquilo'},to={name='solar-system-edge'},length=100000},sp=edge_sp,
    fa={from={name='fulgora'},to={name='aquilo'},length=30000}}}
  game={tick=54027024}
  local st={}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return st end}
  -- Asterion: out from the edge toward the Shattered Planet, 5552 km along, when its hit guard sets Aquilo
  local pl={valid=true,index=7,name='Asterion',state=9,paused=false,space_connection=edge_sp,distance=5552/4000000,speed=13.8/60,
    last_visited_space_location={name='solar-system-edge'},
    schedule={current=2,records={{station='shattered-planet',wait_conditions={}},{station='aquilo',wait_conditions={{type='time',ticks=600}}}}}}
  local l=F.leg(pl)
  eq(l.to,'solar-system-edge','heading back to the edge'); eq(l.from,'shattered-planet'); eq(l.back,true); eq(l.turned_back,true)
  eq(math.floor(l.left_km+0.5),5552,'the km back to the edge: progress x length')
  eq(math.floor(l.eta_ticks/60+0.5),math.floor(5552/13.8+0.5))
  local w=F.where(pl)
  eq(w.text,'flying back to solar-system-edge, 5552 km left (turned back on solar-system-edge->shattered-planet)')
  -- the ETA at Aquilo: the rest of this leg, then edge->aquilo at its speed (not the 4M km on and a full return)
  local r=F.before_departure(pl,'aquilo')
  assert(math.abs(r.eta_s-(5552+100000)/13.8)<=2,'the rest of the leg and edge->aquilo, got '..tostring(r.eta_s))
  has(r.line,'flying shattered-planet->solar-system-edge: 5552 km left'); has(r.line,'solar-system-edge->aquilo 100000 km')
  local W=dofile('mod/agent-harness_0.1.0/waiteta.lua'){before_departure=function(a,b) return F.before_departure(a,b) end}
  local row=W.estimate({},{['until']='platform_arrived',platform='Asterion',location='aquilo'},false,{platform=pl,leg=F.leg(pl)},{})
  eq(row.eta_s,r.eta_s)
  -- further back: 3388 km, then 797 km
  pl.distance=3388/4000000; eq(math.floor(F.leg(pl).left_km+0.5),3388)
  pl.distance=797/4000000; eq(math.floor(F.leg(pl).left_km+0.5),797)
  -- outward again (the schedule's stop is the far end): on to the Shattered Planet, not turned back
  pl.schedule.current=1; pl.distance=0.5
  l=F.leg(pl); eq(l.to,'shattered-planet'); eq(l.back,false); eq(l.turned_back,nil); eq(math.floor(l.left_km+0.5),2000000)
  -- a stop that no way reaches: the way distance moved since the last read decides (not while paused)
  pl.schedule={current=1,records={{station='nowhere'}}}
  pl.index=9; pl.distance=0.4; l=F.leg(pl)
  eq(l.to,'shattered-planet','one read, nothing moved: the end it did not come from')
  pl.distance=0.39; l=F.leg(pl); eq(l.to,'solar-system-edge','distance shrinking: back')
  pl.paused=true; pl.distance=0.38; l=F.leg(pl); eq(l.to,'shattered-planet','paused: a drift back is not a heading')
  -- a ferry flying a connection backwards from where it started (fulgora->aquilo flown aquilo->fulgora): not turned back
  local ferry={valid=true,index=8,name='Kestrel',state=9,paused=false,space_connection=prototypes.space_connection.fa,distance=0.25,speed=2,
    last_visited_space_location={name='aquilo'},schedule={current=1,records={{station='fulgora'}}}}
  l=F.leg(ferry); eq(l.to,'fulgora'); eq(l.turned_back,nil); eq(math.floor(l.left_km+0.5),7500)
  has(F.where(ferry).text,'flying aquilo->fulgora 75%')
end
print('d23_batch131 CN1 turned back mid-connection: freight leg, where, ETA: ok')

-- the fuel trend and the slow line name the leg as flown: a turn back starts a new trend
do
  local A=dofile('mod/agent-harness_0.1.0/platalerts.lua')
  assert(type(A)=='function')
  local src=io.open('mod/agent-harness_0.1.0/platalerts.lua'):read('a')
  has(src,'M.fuel_sample(r, sc.fuel, leg_name(pl)'); has(src,'leg=leg_name(pl)}')
  local rt=io.open('mod/agent-harness_0.1.0/runtime.lua'):read('a')
  has(rt,"M.platalerts=require('platalerts'){state=state,leg=function(pl) return M.freight.leg(pl) end,")
end
print('d23_batch131 CN1 platalerts names the leg as flown: ok')
