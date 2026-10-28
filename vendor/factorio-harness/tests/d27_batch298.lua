-- Run from repository root: lua tests/d27_batch298.lua
-- d27 batch298 FW (Sol #2652: Resolute, its thrusters' tanks level at 1138 fuel and 842 oxidizer, warned again and
-- again of a runout within a minute or two: its one maker of each makes 1500 a craft, so a minute's count was 13500 or
-- 15000 against 14400 used; over 180 s 43500 made, 43200 used; the 4800 and 4500 before its pumps went uncounted).
-- endurance.lua's fuel outlook: rates over the engine's longest sample wholly in the leg, a deficit within a batch a
-- maker over it is no deficit, what lasts is all of the fluid aboard, made in batches said; platalerts.lua: urgent at
-- once only while the stock falls, a fall counts past a batch a maker, and a stock's own fall past that runs it short.
-- The numbers are the iMac copy's (world n's _autosave6, Resolute flying aquilo->gleba->vulcanus->nauvis).
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end

-- Fluid boxes as 2.0.77 gives them: pipes and tanks in segments (an id, the segment's contents), the thrusters' boxes
-- beside a segment, a pump's and a maker's in none (get_fluid_segment_id errors).
local function boxes(list)
  local fb={}
  for i,b in ipairs(list) do fb[i]=b.fluid and {name=b.fluid,amount=b.amount} or nil end
  return setmetatable(fb,{__len=function() return #list end,__index=function(_,k)
    if k=='get_fluid_segment_id' then return function(i) assert(list[i].seg,'no segment'); return list[i].seg.id end end
    if k=='get_fluid_segment_contents' then return function(i) return list[i].seg.contents end end
    if k=='get_pipe_connections' then return function(i) return list[i].beside or {} end end
  end})
end
local function seg(id,name,n) return {id=id,contents={[name]=n}} end
local function pipe_in(sg) return {target=boxes({{seg=sg,fluid=next(sg.contents),amount=100}}),target_fluidbox_index=1} end

local DOWN_F,DOWN_O=seg(1,'thruster-fuel',2400),seg(2,'thruster-oxidizer',2000)
local UP_F,UP_O=seg(3,'thruster-fuel',4800),seg(4,'thruster-oxidizer',4500)
local function thruster(x,f,o)
  -- a thruster's box answers its pipes' segment id; that segment's contents leave the thruster's own tank out
  return {valid=true,type='thruster',name='thruster',position={x=x,y=370},quality={name='normal',default_multiplier=1},
    fluidbox=boxes({{fluid='thruster-fuel',amount=f,seg=DOWN_F},{fluid='thruster-oxidizer',amount=o,seg=DOWN_O}})}
end
local thrusters={thruster(-14,284.5,210.5),thruster(-5,284.5,210.5),thruster(5,284.5,210.5),thruster(14,284.5,210.5)}
-- a storage tank in the upstream segment: its 1000 are in the segment's 4800, counted once
local tank={valid=true,type='storage-tank',name='storage-tank',fluidbox=boxes({{fluid='thruster-fuel',amount=1000,seg=UP_F}})}
local function pump(x,name,up,down) return {valid=true,type='pump',name='pump',position={x=x,y=160},fluidbox=boxes({{fluid=name,amount=400,beside={pipe_in(down),pipe_in(up)}}})} end
local pumps={pump(-14.5,'thruster-fuel',UP_F,DOWN_F),pump(14.5,'thruster-oxidizer',UP_O,DOWN_O)}
local function maker(recipe,name,up,held)
  return {valid=true,type='assembling-machine',name='chemical-plant',crafting_speed=4.75,productivity_bonus=0,
    get_recipe=function() return {name=recipe,energy=10,products={{type='fluid',name=name,amount=1500}}} end,
    fluidbox=boxes({{fluid='water',amount=200},{fluid=name,amount=held,beside={pipe_in(up)}}})}
end
local makers={maker('advanced-thruster-fuel','thruster-fuel',UP_F,600),maker('advanced-thruster-oxidizer','thruster-oxidizer',UP_O,900)}
-- the rocket assemblers aboard: not found (the find is by the names that can craft chemistry)
local other={valid=true,type='assembling-machine',name='assembling-machine-3',get_recipe=function() error('not a fuel maker: never read') end}

local finds={}
local surface={find_entities_filtered=function(f)
  finds[#finds+1]=f
  if type(f.type)=='table' then local o={} for _,t in ipairs(thrusters) do o[#o+1]=t end o[#o+1]=tank return o end
  if f.name then
    local want={} for _,n in ipairs(f.name) do want[n]=true end
    local o={}
    for _,e in ipairs({makers[1],makers[2],pumps[1],pumps[2],other}) do if want[e.name] then o[#o+1]=e end end
    return o
  end
  return {}
end}
prototypes={get_recipe_filtered=function(f)
    local n=f[1].elem_filters[1].name
    return n=='thruster-fuel' and {['advanced-thruster-fuel']={category='chemistry'},['thruster-fuel']={category='chemistry'}} or {['advanced-thruster-oxidizer']={category='chemistry'}}
  end,
  get_entity_filtered=function(f)
    if f[1].filter=='crafting-category' then return {['chemical-plant']={}} end
    return {pump={}}
  end}
defines={flow_precision_index={one_minute=1}}
-- the statistics' last minute (the fallback): 13500 made, 14400 used, as Sol read it
local stats={get_flow_count=function(a) return a.category=='input' and 13500 or 14400 end}
local force={get_fluid_production_statistics=function() return stats end,recipes={['advanced-thruster-fuel']={productivity_bonus=0},['advanced-thruster-oxidizer']={productivity_bonus=0}}}
for _,m in ipairs(makers) do m.force=force end
local T0=1000000
local pl={index=7,name='Resolute',surface=surface,force=force,speed=150/60,space_connection={}}
local win60={seconds=60,fluids={['thruster-fuel']={used=14400,made=13500,tanks_first=1138,tanks_last=1138},['thruster-oxidizer']={used=14400,made=15000,tanks_first=842,tanks_last=842}}}
local win180={seconds=180,fluids={['thruster-fuel']={used=43200,made=43500,tanks_first=1138,tanks_last=1138},['thruster-oxidizer']={used=43200,made=43500,tanks_first=842,tanks_last=842}}}
local engine={windows={win60,win180}}
local st={}
local E=dofile('mod/agent-harness_0.1.0/endurance.lua'){state=function() return st end,
  leg=function() return {from='aquilo',to='vulcanus',left_km=60000} end,
  segments=function() return {{kind='leg',from='aquilo',to='vulcanus',start=T0}} end,
  engine=function() return engine end}

-- Sol's flight, 200 s into the leg: the 180 s sample is all in the leg; 43500 made against 43200 used: no shortage
do
  game={tick=T0+200*60}
  local o=E.fuel_outlook(pl)
  eq(o.short,nil,'no runout'); eq(o.window_s,180)
  local f,ox=o.rows[1],o.rows[2]
  eq(f.made_per_min,14500); eq(f.used_per_min,14400); eq(f.window_s,180)
  -- held: the thrusters and the storage tank, as before; aboard adds the pipes (both segments, each once), the pump's
  -- box and the maker's output: 1138 + 2400 + 4800 (the tank's 1000 in it) + 400 + 600
  eq(f.held,2138); eq(f.in_tanks,1000); eq(f.aboard,9338)
  eq(ox.held,842); eq(ox.aboard,842+2000+4500+400+900)
  eq(f.batch.size,1500); eq(f.batch.makers,1); eq(f.batch.craft_s,2.11); eq(f.batch.full_per_min,42750); eq(f.batch.share,34)
  eq(f.batch.step,1500); eq(f.batch.step_per_min,500)
  has(o.line,'thruster-fuel 2138 held (9338 aboard with the pipes, pumps and makers\' outputs), made 14500/min, used 14400/min over the last 180 s: lasts the leg '
    ..'(made in batches of 1500 by 1 chemical-plant: advanced-thruster-fuel, a craft each 2.11 s at full speed, 42750/min; 34% of that made over the last 180 s)')
  -- the makers and pumps are kept a minute: the next read finds only the thrusters and tanks
  local n=#finds
  E.fuel_outlook(pl)
  eq(#finds,n+1); eq(type(finds[#finds].type),'table')
  game.tick=game.tick+3600
  E.fuel_outlook(pl)
  eq(#finds,n+3,'found again after a minute')
end
print('d27_batch298 FW Sol\'s flight over 180 s: no runout: ok')

-- 100 s into the leg: the 180 s sample holds the stop; the 60 s one is all in the leg. 13500 made against 14400 used is
-- within a batch a maker over 60 s (1500/min): no deficit measured (main: "runs out in 1m18s")
do
  game={tick=T0+100*60}
  local o=E.fuel_outlook(pl)
  eq(o.short,nil); eq(o.window_s,60)
  local f=o.rows[1]
  eq(f.within_step,true); eq(f.lasts_min,nil); eq(f.batch.step_per_min,1500)
  has(o.line,'made 13500/min, used 14400/min over the last 60 s: used over made by 900/min, within a batch a maker over 60 s (1500/min): no deficit measured')
  -- in its first seconds (no sample all in the leg): the statistics' last minute, the same step
  game={tick=T0+30*60}
  o=E.fuel_outlook(pl)
  eq(o.short,nil); eq(o.window_s,60); eq(o.rows[1].within_step,true)
  has(o.line,'made 13500/min, used 14400/min: used over made by 900/min, within a batch a maker over 60 s (1500/min): no deficit measured')
  -- no batch landed in the window (the copy: its fuel maker stopped, 1 left, 183/min used): no step; the rates as read
  game={tick=T0+100*60}
  win60.fluids['thruster-fuel'].made=0; win60.fluids['thruster-fuel'].used=183
  o=E.fuel_outlook(pl)
  eq(o.rows[1].within_step,nil); eq(o.rows[1].lasts_min,51)
  has(o.line,'made 0/min, used 183/min over the last 60 s: lasts 51m00s, the leg 6m40s')
  -- batches landing but what is aboard lasts under 2 minutes even at a deficit within the step: short (an actual low)
  -- (the pipes empty: 2138 aboard, 1400/min within the 1500)
  win60.fluids['thruster-fuel'].made=13500; win60.fluids['thruster-fuel'].used=14900
  local keep=DOWN_F.contents['thruster-fuel']; DOWN_F.contents['thruster-fuel']=0
  local keep_up=UP_F.contents['thruster-fuel']; UP_F.contents['thruster-fuel']=0
  o=E.fuel_outlook(pl)
  eq(o.rows[1].aboard,2138); eq(o.short and o.short[1],'thruster-fuel'); eq(o.rows[1].lasts_min,1.5); eq(o.rows[1].within_step,nil)
  DOWN_F.contents['thruster-fuel'], UP_F.contents['thruster-fuel']=keep, keep_up
  win60.fluids['thruster-fuel'].used=14400
end
print('d27_batch298 FW a minute\'s count within a batch a maker: no deficit: ok')

-- A deficit past the step: 36000 made against 43200 over 180 s, 2400/min; the 9338 aboard last 3m53s, the leg 6m40s
do
  game={tick=T0+200*60}
  win180.fluids['thruster-fuel'].made=36000
  local o=E.fuel_outlook(pl)
  eq(o.short and o.short[1],'thruster-fuel'); eq(#o.short,1)
  eq(o.rows[1].lasts_min,3.9); eq(o.rows[1].within_step,nil)
  has(o.line,'made 12000/min, used 14400/min over the last 180 s: runs out in 3m53s, 2m47s before the leg ends')
  win180.fluids['thruster-fuel'].made=43500
end
print('d27_batch298 FW a deficit past the step: short: ok')

-- platalerts: the scans' stock is what is aboard; urgent at once only while it falls; a fall past a batch a maker
do
  game={tick=0}
  local P=dofile('mod/agent-harness_0.1.0/platalerts.lua'){state=function() return {} end}
  local r, dep
  local function fuel(aboard,lasts,short,extra)
    local row={name='thruster-fuel',held=1138,in_tanks=0,aboard=aboard,lasts_min=lasts,short=short,batch={step=1500}}
    for k,v in pairs(extra or {}) do row[k]=v end
    return row
  end
  local function scan(s,rows,left)
    game.tick=dep+s*60
    local short={}
    for _,row in ipairs(rows) do if row.short then short[#short+1]=row.name end end
    local f={rows=rows,short=#short>0 and short or nil,leg_left_min=left,since_departure_s=s}
    P.fuel_sample(r,f,'aquilo->vulcanus')
    P.fuel_slope(r,f)
    return f.short and {P.fuel_level(r,f)} or nil, f
  end
  -- a falling low level: urgent at once (no scan before: the rates' fall)
  r, dep = {}, 0
  local lv=scan(10,{fuel(1500,0.6,true)},6)
  eq(lv[1],'urgent'); eq(lv[2],'thruster-fuel lasts 0m36s at the rates now, under 2 minutes')
  eq(lv[3],'thruster-fuel held 1138 (storage tanks 0; aboard 1500), one scan so far')
  -- lower than the scan before: urgent
  lv=scan(20,{fuel(1300,0.5,true)},6)
  eq(lv[1],'urgent'); has(lv[2],'lasts 0m30s at the rates now')
  -- the same rates with the stock risen since the scan before (a batch landed) and above the first scan: not at once
  lv=scan(30,{fuel(2800,0.9,true)},6)
  eq(lv[1],'advisory'); eq(lv[2],'30 s into the leg, under 90')
  has(lv[3],'thruster-fuel held 1138 -> 1138 over the last 20 s (storage tanks 0 -> 0; aboard with the pipes, pumps and makers 1500 -> 2800)')
  -- Sol's level: the stock between 7671 and 8871 as each batch lands, the rates within the step: never short
  r, dep = {}, 0
  for s=0,400,10 do
    local res=scan(s,{fuel(s%30==0 and 8871 or (s%30==10 and 7971 or 7671),nil,false,{within_step=true})},20)
    eq(res,nil,'level at '..s..' s')
  end
  -- a fall too small for the rates' window (400/min within 500/min) but steady: past a batch a maker over the 300 s
  -- kept, 8400 -> 6400, it lasts 16 min against a 20 min leg: short, urgent
  r, dep = {}, 0
  local res, f
  for s=0,380,10 do
    res, f = scan(s,{fuel(9000-math.floor(400*s/60),nil,false,{within_step=true})},20)
    if s<=150 then eq(res,nil,'within a batch a maker so far, at '..s..' s') end
  end
  res, f = scan(390,{fuel(9000-2600,nil,false,{within_step=true})},20)
  eq(f.short[1],'thruster-fuel')
  eq(f.rows[1].slope,'thruster-fuel aboard fell 8400 -> 6400 in 300 s, more than a batch a maker (1500): at that fall it lasts 16.0 min, the leg 20.0')
  eq(res[1],'urgent'); eq(res[2],f.rows[1].slope)
  -- the same fall on a leg it lasts: not short
  r = {}
  for s=0,390,10 do res, f = scan(s,{fuel(9000-math.floor(400*s/60),nil,false,{within_step=true})},12) end
  eq(res,nil); eq(f.rows[1].slope,nil)
  -- a stock's fall within a batch a maker on two short scans is no fall (d20 batch60's rule, past the step now)
  r, dep = {}, 0
  for s=90,140,10 do scan(s,{fuel(31000,6,true)},9) end
  lv=scan(150,{fuel(30000,6,true)},9)
  eq(lv[1],'advisory'); eq(lv[2],'the stock did not fall between two windows')
  lv=scan(210,{fuel(28400,6,true)},9)
  eq(lv[1],'urgent'); eq(lv[2],'thruster-fuel short on the scans at +150 s and +210 s into the leg, aboard 30000 -> 28400')
  game=nil
end
print('d27_batch298 FW alerts: the stock aboard, falling, past a batch a maker: ok')
print('d27_batch298 FW: ok')
