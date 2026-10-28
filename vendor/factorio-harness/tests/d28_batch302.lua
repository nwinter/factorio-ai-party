-- Run from repository root: lua tests/d28_batch302.lua
-- d28 batch302 FC (Astra #2656: Resolute has 129 ammo turrets, 32 of them railguns; flight watch 1520 read 128 and 31,
-- the railgun at (18.5,380.5) left out by a cap of 128 that nothing said). flightwatch.lua: every ammo turret aboard up
-- to 1024, counted at each find (turrets_total, turrets_read), any left out said in its lines; a sample reads 256 a
-- tick and the rest on the ticks after; a watch running at the deploy adds the ones the old cap left out at its next
-- find, each from that read, the others keeping theirs. conditions.lua's ammo_below guard covers the 129th.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
defines={inventory={turret_ammo=1,hub_main=1},space_platform_state={on_the_path=1,waiting_at_station=2,paused=3}}
prototypes={item={['repair-pack']={type='repair-tool'},['firearm-magazine']={type='ammo'},['railgun-ammo']={type='ammo'}}}
local reads={}   -- ammo inventory reads by tick
local uid=0
local function turret(x,y,n,rail)
  uid=uid+1
  local t={valid=true,name=rail and 'railgun-turret' or 'gun-turret',type='ammo-turret',unit_number=1000+uid,position={x=x,y=y},count=n,
    ammo=rail and 'railgun-ammo' or 'firearm-magazine'}
  if rail then t.electric_buffer_size, t.energy = 1e7, 1e7 end
  t.get_inventory=function() reads[game.tick]=(reads[game.tick] or 0)+1; return {get_item_count=function() return t.count end,[1]={valid_for_read=t.count>0,name=t.ammo}} end
  return t
end
local turrets={}
-- Resolute's mix: 97 gun turrets, then 32 railguns, the last at (18.5,380.5)
local function resolute(n_guns,n_rails)
  turrets={}
  for i=1,n_guns do turrets[#turrets+1]=turret(-40+i%40,360+math.floor(i/40),10) end
  for i=1,n_rails-1 do turrets[#turrets+1]=turret(-30+2*i,378.5,10,true) end
  turrets[#turrets+1]=turret(18.5,380.5,10,true)
  return turrets[#turrets]
end
local conn={from={name='gleba'},to={name='aquilo'}}
local surface={name='platform-22',find_entities_filtered=function(f)
  local o={} for _,t in ipairs(turrets) do if t.valid and (not f.type or f.type==t.type) then o[#o+1]=t end end return o end}
local force={name='player',get_item_production_statistics=function() return {get_output_count=function() return 0 end} end}
local pl={valid=true,index=22,name='Resolute',surface=surface,force=force,state=2,space_connection=nil,space_location={name='gleba'},
  hub={get_inventory=function() return {get_contents=function() return {} end} end}}
force.platforms={[22]=pl}
game={tick=1000,forces={player=force}}
local p={name='astra',force=force,index=1}
local st={}
local F=dofile('mod/agent-harness_0.1.0/flightwatch.lua'){state=function() return st end,who=function(q) return q.name end,
  platform=function(q,name) assert(name==pl.name,'no platform '..tostring(name)); return pl end,
  fuel_outlook=function() return {rows={}} end,
  hits=function() return {hits=0,damage=0,entities={},by={}} end,
  losses=function() return {},0 end,
  leg=function(q) local c=q.space_connection; if not c then return nil end; return {from=c.from.name,to=c.to.name} end}
local function run(to) while game.tick<to do game.tick=game.tick+1; if F.due(game.tick) then F.tick(game.tick) end end end
local function depart() pl.state, pl.space_connection, pl.space_location = 1, conn, nil end
local function stop_at(name) pl.state, pl.space_connection, pl.space_location = 2, nil, {name=name} end
local function last_event() return st.flightwatch.events[#st.flightwatch.events].text end
local function fresh() st={}; stop_at('gleba'); reads={} end

-- 1. 129 ammo turrets, 32 railguns: all read, said so, the 129th railgun among them
local tail=resolute(97,32)
local r=F.call(p,{platform='Resolute',from='departure',minutes=10})
run(game.tick+120); depart(); run(game.tick+120)
local w=st.flightwatch.list[1]
eq(w.state,'watching'); eq(#w.turrets,129); eq(w.total,129); eq(w.capped,nil)
assert(last_event():find('began: it left for gleba%->aquilo; watching 129 ammo turrets %(32 railguns, all 129 aboard%)$'),last_event())
local rails=0 for _,t in ipairs(w.turrets) do if t.buffer then rails=rails+1 end end
eq(rails,32)
assert(w.by_unit[tail.unit_number],'the railgun at (18.5,380.5) is read')
-- one tick a sample (under PAGE)
local ticks=0 for tk,n in pairs(reads) do if tk>w.start then ticks=ticks+1; eq(n,129,'one sample reads all 129 on its tick') end end
assert(ticks>=1)
tail.energy=0; run(game.tick+180)
local x=F.call(p,{id=w.id}).watch
eq(x.turrets_total,129); eq(x.turrets_read,129); eq(x.turrets_left_out,nil); eq(x.turrets_capped,nil)
eq(x.turrets_count_line,'129 ammo turrets (32 railguns, all 129 aboard)')
local seen=false
for _,rg in ipairs(x.railguns or {}) do if rg.unit_number==tail.unit_number then seen=true; assert(rg.below_samples>=2,rg.below_samples) end end
assert(seen,'the 129th, a railgun read below a shot\'s energy, is in the read')
stop_at('aquilo'); run(game.tick+120); eq(w.state,'done')
assert(last_event():find('none of 129 ammo turrets read empty;'),last_event())
assert(not last_event():find('not read'),last_event())

-- 2. 300 ammo turrets: a sample reads 256 on its tick and 44 on the next; each turret once a second; an empty run on
-- the 300th counted
fresh(); local last300=resolute(268,32); last300.electric_buffer_size=nil; last300.energy=nil
F.call(p,{platform='Resolute',from='departure',minutes=10})
run(game.tick+120); depart(); run(game.tick+60)
w=st.flightwatch.list[1]
eq(w.state,'watching'); eq(#w.turrets,300); eq(w.total,300)
reads={}
run(game.tick+600)
local per={}
for tk,n in pairs(reads) do per[#per+1]={tk,n} end
table.sort(per,function(a,b) return a[1]<b[1] end)
local sum=0
for i,rw in ipairs(per) do
  sum=sum+rw[2]
  if rw[2]==256 then eq(per[i+1] and per[i+1][1],rw[1]+1,'the next page on the next tick'); eq(per[i+1][2],44) end
  assert(rw[2]==256 or rw[2]==44,'a tick reads a page: '..rw[2])
end
eq(sum,3000,'10 samples of 300 turrets in 600 ticks, each read once a second')
last300.count=0
run(game.tick+300)
local t300=w.turrets[w.by_unit[last300.unit_number]]
eq(t300.runs,1); assert(t300.empty_samples>=4,t300.empty_samples); eq(t300.empty_ticks,t300.empty_samples*60,'its ticks from its own samples')
x=F.call(p,{id=w.id}).watch
eq(x.turrets_total,300); eq(x.turrets_read,300); eq(x.turrets[1].unit_number,last300.unit_number,'the empty one first')
stop_at('aquilo'); run(game.tick+120); eq(w.state,'done'); eq(w.page,nil)
assert(last_event():find('1 of 300 ammo turrets read empty'),last_event())

-- 3. over the cap (here 200): the rest said in the start, the end and the read
fresh(); resolute(268,32)
F.MAX_TURRETS=200
r=F.call(p,{platform='Resolute'})
assert(r.line:find('watching 200 ammo turrets %(%d+ railguns%) %(100 more aboard not read: a watch reads at most 200; 300 at the last find%)'),r.line)
x=F.call(p,{id=r.watch.id}).watch
eq(x.turrets_total,300); eq(x.turrets_read,200); eq(x.turrets_left_out,100); eq(x.turrets_capped,200)
F.MAX_TURRETS=1024

-- 4. a watch running at the deploy (its cap 128 then): the 129th is read from its next find (within a minute), from
-- that read; the 128 keep their baselines and samples
fresh(); tail=resolute(97,32)
F.MAX_TURRETS=128
F.call(p,{platform='Resolute',from='departure',minutes=10})
run(game.tick+120); depart(); run(game.tick+60)
w=st.flightwatch.list[1]
eq(#w.turrets,128); eq(w.capped,true); eq(w.by_unit[tail.unit_number],nil,'the old cap left the tail railgun out')
turrets[1].count=3; run(game.tick+600)
local t1=w.turrets[w.by_unit[turrets[1].unit_number]]
eq(t1.first,10); eq(t1.min,3); local samples=w.samples
F.MAX_TURRETS=1024   -- the deploy
local deploy=game.tick
run(w.refound+F.REFIND+1)
eq(#w.turrets,129); eq(w.capped,nil); eq(w.total,129)
local tt=w.turrets[w.by_unit[tail.unit_number]]
eq(tt.uncapped,true); assert(tt.added>deploy and tt.added<=deploy+F.REFIND,'within a minute of the deploy'); eq(tt.first,10)
eq(t1.first,10,'the others keep their baseline'); eq(t1.min,3); assert(w.samples>samples)
x=F.call(p,{id=w.id}).watch
eq(x.turrets_read,129); eq(x.turrets_left_out,nil)
F.SHOW=200; x=F.call(p,{id=w.id}).watch; F.SHOW=24
local found=false
for i,row in ipairs(x.turrets) do
  if row.unit_number==tail.unit_number then found=true; eq(row.uncapped,true); assert(x.lines[i]:find('an earlier cap of the watch left it out until then',1,true),x.lines[i]) end
end
assert(found)

-- 5. a guard (ammo_below on the platform) sees the 129th: only it low, the condition holds and names it
do
  local ents={}
  for i=1,128 do ents[i]={valid=true,type='ammo-turret',name='gun-turret',position={x=i,y=0},n=50} end
  ents[129]={valid=true,type='ammo-turret',name='railgun-turret',position={x=18.5,y=380.5},n=3}
  for _,e in ipairs(ents) do
    local inv={valid=true}
    inv.get_item_count=function() return e.n end
    inv.get_contents=function() return e.n>0 and {{name=e.name=='railgun-turret' and 'railgun-ammo' or 'firearm-magazine',count=e.n}} or {} end
    e.get_inventory=function() return inv end
  end
  local s={index=22,name='platform-22'}
  s.count_entities_filtered=function(f) local n=0 for _,e in ipairs(ents) do if e.type==f.type then n=n+1 end end return n end
  s.find_entities_filtered=function(f) local o={} for _,e in ipairs(ents) do if e.type==f.type then o[#o+1]=e end if f.limit and #o>=f.limit then break end end return o end
  local rq={valid=true,name='Resolute',surface=s}
  local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){position=function(q) return {x=q.x or q[1],y=q.y or q[2]} end}
  local c={['until']='ammo_below',platform='Resolute',count=10}
  C.validate(c)
  local met,saw=C.check({force={index=1,platforms={rq}}},c)
  eq(met,true); eq(saw,'1 turrets below 10 (of 129 on Resolute; lowest railgun-turret (18.5,380.5): 3 railgun-ammo)')
end
print('d28_batch302: ok')
