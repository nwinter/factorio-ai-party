-- d25 batch212 QX1 (Sol #2372: trial190's whole-trip uranium magazine use could not be exact from hub deltas or
-- uptime, which missed ticks at the departure and the turnaround). Run from the harness root: lua tests/d25_batch212.lua.
-- Each flight_watch window gives the ammunition used by item and quality from the platform's item production
-- statistics read at its own start and end ticks; a mixed part keeps its own; the whole watch across splits; a
-- replacement chain from the first watch's start with the gap between two watches; the departure and the arrival named
-- by the samples around them, with what was used in those ticks.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) if a~=b then error((m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b),2) end end
local function has(s,x) assert(type(s)=='string' and s:find(x,1,true),tostring(s)..'\n  lacks: '..x) end
defines={inventory={turret_ammo=1,hub_main=1},space_platform_state={on_the_path=1,waiting_at_station=2}}
prototypes={item={['repair-pack']={type='repair-tool'},['uranium-rounds-magazine']={type='ammo'}},
  quality={normal={level=0},uncommon={level=1},rare={level=2},epic={level=3},legendary={level=5},['quality-unknown']={level=0,hidden=true}}}
-- the platform's consumed counts since the game began: cnt[item][quality]
local cnt={}
local function add(name,q,n) cnt[name]=cnt[name] or {}; cnt[name][q]=(cnt[name][q] or 0)+n end
local stats={get_output_count=function(x)
  if type(x)=='string' then return (cnt[x] or {}).normal or 0 end
  return (cnt[x.name] or {})[x.quality] or 0
end}
local force={name='player',get_item_production_statistics=function() return stats end}
local t={valid=true,name='gun-turret',type='ammo-turret',unit_number=7,position={x=1,y=2}}
t.get_inventory=function() return {get_item_count=function() return 10 end,[1]={valid_for_read=true,name='uranium-rounds-magazine'}} end
local surface={index=9,name='platform-1',find_entities_filtered=function(f) if f.type=='ammo-turret' then return {t} end return {} end}
local pl={valid=true,index=1,name='Asterion',surface=surface,force=force,hub={get_inventory=function() return {get_contents=function() return {} end} end}}
local function stop_at(loc) pl.state, pl.space_connection, pl.space_location = 2, nil, {name=loc} end
local function fly(from,to) pl.state, pl.space_connection, pl.space_location = 1, {from={name=from},to={name=to}}, nil end
stop_at('aquilo')
force.platforms={pl}
game={tick=1000,forces={player=force}}
local p={name='sol',force=force,index=1}
local st={}
local F=dofile('mod/agent-harness_0.1.0/flightwatch.lua'){state=function() return st end,who=function(q) return q.name end,
  platform=function(q,name) assert(name=='Asterion','no platform '..tostring(name)); return pl end,
  hits=function() return {hits=0,damage=0,entities={},by={}} end}
local X=dofile('mod/agent-harness_0.1.0/mixed.lua'){state=function() return st end,flight_rebase=function(w,tick) return F.rebase(w,tick) end}
-- each tick: firing uses 1 normal uranium magazine a tick, and a rare explosive rocket every 100th tick; hist the
-- counts after each tick
local firing=false
local hist={}
local function snap(k) hist[k]={u=(cnt['uranium-rounds-magazine'] or {}).normal or 0,r=(cnt['explosive-rocket'] or {}).rare or 0} end
snap(game.tick)
local function run(to)
  while game.tick<to do
    game.tick=game.tick+1
    if firing then add('uranium-rounds-magazine','normal',1); if game.tick%100==0 then add('explosive-rocket','rare',1) end end
    snap(game.tick)
    if F.due(game.tick) then F.tick(game.tick) end
  end
end
local function used(u,item,q) return ((u.used or {})[item] or {})[q or 'normal'] end
local function check(u,a,b,m)
  eq(u.from_tick,a,m..' from'); eq(u.to_tick,b,m..' to'); eq(u.ticks,b-a,m..' ticks')
  eq(used(u,'uranium-rounds-magazine') or 0,hist[b].u-hist[a].u,m..' uranium'); eq(used(u,'explosive-rocket','rare') or 0,hist[b].r-hist[a].r,m..' rare rockets')
  eq(u.total,(hist[b].u-hist[a].u)+(hist[b].r-hist[a].r),m..' total')
end
-- turrets fire at aquilo before the departure (the ticks before the watch began are in none of its counts)
add('uranium-rounds-magazine','normal',500); snap(game.tick)
firing=true
local a=F.call(p,{platform='Asterion',from='departure',minutes=60}).watch
eq(a.state,'armed')
run(1250)
local w=st.flightwatch.list[1]
assert(w.ammo_stopped,'an armed watch reads while stopped')
-- it leaves at 1263, between two samples
run(1262); fly('aquilo','solar-system-edge'); run(1400)
eq(w.state,'watching'); assert(w.start>1263 and w.start<=1263+60,'begun at the first sample that read it flying: '..w.start)
local began=w.start
local stopped=began-60   -- its last sample while stopped
-- an edit aboard at 3337 splits the window (mixed.lua): the part keeps its own ammunition
run(3337)
eq(X.edit({described=true,surface=9,name='gun-turret',type='ammo-turret',unit_number=99,position={x=3,y=3},box={2,2,4,4},force='player'},'built by sol'),1)
eq(w.start,3337); eq(w.began,began)
local part=w.mixed.parts[1]
check(part.ammunition,began,3337,'the mixed part')
eq(part.repair_packs_used,0,'the part keeps its repair packs')
-- it reaches the edge at 6010, between two samples; the watch ends at the sample that reads it arrived
run(6009); stop_at('solar-system-edge'); run(6070)
eq(w.state,'done'); has(w.why,'arrived at solar-system-edge')
local ended=w.ended
assert(ended>=6010 and ended<6070,tostring(ended))
local r=F.call(p,{id=a.id}).watch
check(r.ammunition,3337,ended,'the window after the split')
check(r.ammunition_watch,began,ended,'the whole watch')
eq(r.ammunition_watch.total,part.ammunition.total+r.ammunition.total,'the whole is its parts')
has(r.line,'; ammunition used uranium-rounds-magazine '..(hist[ended].u-hist[3337].u)..', explosive-rocket '..(hist[ended].r-hist[3337].r)..' (rare '..(hist[ended].r-hist[3337].r)..')')
has(r.line,'(since the watch began at tick '..began..', across its splits: uranium-rounds-magazine '..(hist[ended].u-hist[began].u))
-- the boundaries: the departure between the last stopped sample and the first flying one, the arrival likewise
local dep,arr=r.ammunition_boundaries[1],r.ammunition_boundaries[2]
eq(dep.what,'departure'); check(dep,stopped,began,'the departure'); assert(stopped<1263 and began>1263)
has(dep.line,'left between tick '..stopped..' (the last sample that read it stopped) and tick '..began..' (the first that read it flying): uranium-rounds-magazine '..(began-stopped))
has(dep.line,'before this watch began, in no count')
eq(arr.what,'arrival'); eq(arr.counted,'ammunition'); check(arr,ended-60,ended,'the arrival')
has(arr.line,'arrived between tick '..(ended-60)..' (the last sample that read it flying) and tick '..ended)
-- the turnaround: the return leg's watch, replace: true after #a was read; the chain counts from #a's start, the gap
-- named
run(ended+39)
local b=F.call(p,{platform='Asterion',replace=true,minutes=60})
local wb=st.flightwatch.list[2]
eq(wb.chain.first,a.id); eq(wb.chain.ids[1],a.id)
run(6200); fly('solar-system-edge','aquilo'); run(8000)
-- an end by its time limit is exact; here it ends at its arrival
run(9000); stop_at('aquilo'); run(9100)
eq(wb.state,'done')
local rb=F.call(p,{id=b.watch.id}).watch
local bstart,bend=wb.start,wb.ended
eq(bstart,ended+39)
check(rb.ammunition,bstart,bend,'the return window')
check(rb.ammunition_chain,began,bend,'the chain')
eq(rb.ammunition_chain.watches[1],a.id); eq(rb.ammunition_chain.watches[2],b.watch.id)
local gap
for _,x in ipairs(rb.ammunition_boundaries) do if x.what=='between' then gap=x end end
check(gap,ended,bstart,'the gap'); eq(gap.after,a.id); eq(gap.before,b.watch.id)
has(gap.line,"between #"..a.id.."'s end at tick "..ended.." and #"..b.watch.id.."'s start at tick "..bstart..': uranium-rounds-magazine 39 used in those 39 ticks, in neither watch, counted in ammunition_chain')
eq(rb.ammunition_boundaries[1].what,'departure','the chain names its first watch\'s departure'); eq(rb.ammunition_boundaries[1].watch,a.id)
-- exact: the parts, the gap and the return window are the chain, which is the counts from #a's begin to #b's end
eq(part.ammunition.total+r.ammunition.total+gap.total+rb.ammunition.total,rb.ammunition_chain.total,'parts + gap + window')
eq(rb.ammunition_chain.total,(hist[bend].u-hist[began].u)+(hist[bend].r-hist[began].r))
has(rb.line,'; since #'..a.id..' began at tick '..began..' (watches #'..a.id..', #'..b.watch.id..'): uranium-rounds-magazine '..(hist[bend].u-hist[began].u))
-- team.alerts names each end's use
local h={}
local lines=F.lines(p,h)
has(lines[#lines],'; ammunition used uranium-rounds-magazine '..(hist[bend].u-hist[bstart].u))
print('d25_batch212 QX1 windows, parts, chain and boundaries: ok')

-- other qualities by name, a from-now watch begun in flight, a watch kept from before, the platform gone
do
  st={}
  game.tick=20000; snap(game.tick)
  fly('aquilo','vulcanus')
  add('uranium-rounds-magazine','legendary',7); add('railgun-ammo','epic',2); snap(game.tick)
  local c=F.call(p,{platform='Asterion',minutes=10}).watch
  local wc=st.flightwatch.list[1]
  add('uranium-rounds-magazine','legendary',3); add('railgun-ammo','epic',1); add('firearm-magazine','normal',4)
  run(20100)
  local rc=F.call(p,{id=c.id}).watch
  eq(used(rc.ammunition,'uranium-rounds-magazine','legendary'),3); eq(used(rc.ammunition,'railgun-ammo','epic'),1); eq(used(rc.ammunition,'firearm-magazine'),4)
  has(rc.line,'uranium-rounds-magazine '..(hist[20100].u-hist[20000].u+3)..' (normal '..(hist[20100].u-hist[20000].u)..', legendary 3), firearm-magazine 4, explosive-rocket '..(hist[20100].r-hist[20000].r)..' (rare '..(hist[20100].r-hist[20000].r)..'), railgun-ammo 1 (epic 1)')
  eq(rc.ammunition_boundaries[1].what,'start'); has(rc.ammunition_boundaries[1].line,'began at tick 20000 while it flew: what was used before then is in no count')
  -- kept from before this: no read, named
  wc.ammo0, wc.ammo_began, wc.ammo_last = nil, nil, nil
  rc=F.call(p,{id=c.id}).watch
  eq(rc.ammunition,nil); has(rc.line,'; ammunition used ? (this watch began before ammunition was read)')
  -- a replace of a watch kept from before: no chain, said
  local d=F.call(p,{platform='Asterion',replace=true})
  eq(d.watch.ammunition_chain_note,'#'..c.id..' began before ammunition was read: no ammunition chain')
  -- the platform gone: the last sample's read ends it
  local wd=st.flightwatch.list[2]
  run(20200)
  local last=wd.ammo_last.tick
  pl.valid=false; force.platforms={}
  run(20300)
  eq(wd.state,'done'); eq(wd.ammo1.tick,last)
  pl.valid=true; force.platforms={pl}
end
print('d25_batch212 QX1 qualities, a start in flight, watches kept from before: ok')

-- a replace while the old watch runs: it ends at the call's tick and the new one begins there, a gap of 0 ticks; a
-- third replace carries the chain on
do
  st={}
  game.tick=30000; snap(game.tick)
  fly('aquilo','solar-system-edge'); firing=true
  local w1=F.call(p,{platform='Asterion'}).watch
  run(30500)
  local w2=F.call(p,{platform='Asterion',replace=true}).watch
  run(31000)
  local w3=F.call(p,{platform='Asterion',replace=true}).watch
  run(31500)
  local r3=F.call(p,{id=w3.id}).watch
  check(r3.ammunition_chain,30000,31500,'a chain of three')
  eq(#r3.ammunition_chain.watches,3); eq(r3.ammunition_chain.first,w1.id)
  local gaps=0
  for _,x in ipairs(r3.ammunition_boundaries) do if x.what=='between' then gaps=gaps+1; eq(x.ticks,0); eq(x.total,0) end end
  eq(gaps,2)
  check(r3.ammunition,31000,31500,'the third window')
  local r1=F.call(p,{id=w1.id}).watch
  check(r1.ammunition,30000,30500,'the first, ended by the replace')
end
print('d25_batch212 QX1 a replace while watching: ok')
