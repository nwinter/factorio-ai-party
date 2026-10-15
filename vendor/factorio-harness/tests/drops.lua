-- Run with lua tests/drops.lua: where drops landed (drops.lua).
-- Astra, shift06 14:55: a drop from Sunward to Vulcanus near (14,134)
-- "succeeded" and Sol found nothing within 16 tiles after 90 s; the pod had
-- landed as a cargo-pod-container at (0,129), with another drop's barrels at
-- (5,131). The drop's pod is followed down; the sender and `to` teammates
-- hear where it landed in their team block; the drops read lists them.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
defines={inventory={chest=1}}
storage={}
local containers={}
local vulcanus={name='vulcanus'}
vulcanus.find_entities_filtered=function(f)
  eq(f.name,'cargo-pod-container')
  local out={}
  for _,e in ipairs(containers) do
    if e.valid and (e.position.x-f.position.x)^2+(e.position.y-f.position.y)^2<=f.radius^2 then out[#out+1]=e end
  end
  return out
end
game={tick=1000,surfaces={vulcanus=vulcanus}}
local function container(x,y,list)
  local e={valid=true,name='cargo-pod-container',position={x=x,y=y},unit_number=#containers+500}
  e.get_inventory=function(i) eq(i,1); return {get_contents=function() return list end} end
  containers[#containers+1]=e
  return e
end
local roster={astra='astra',sol='sol',luna='luna'}
local D=dofile('mod/agent-harness_0.1.0/drops.lua'){
  state=function() return storage end,
  integer=function(v,d,lo,hi,name) v=v==nil and d or v; assert(type(v)=='number' and v>=lo and v<=hi,name..' out of range'); return v end,
  who=function(p) return p.name end,
  resolve=function(name) local n=roster[name:lower()]; if not n then error('unknown agent '..name,0) end return n end}
local astra,sol,luna={name='astra'},{name='sol'},{name='luna'}
local ha,hs,hl={},{},{}
local function step(ticks) for _=1,ticks do game.tick=game.tick+1; D.tick(game.tick) end end

-- 1. `to` names teammates as the board knows them; unknown names fail.
eq(D.recipients(nil)[1],nil); eq(D.recipients('Sol')[1],'sol'); eq(#D.recipients({'sol','luna'}),2)
fails(function() D.recipients('nobody') end,'unknown agent nobody')

-- 2. The drop: its pod on the platform, then descending over Vulcanus.
local pod={valid=true,surface={name='platform-3'},position={x=0,y=0}}
local id=D.record(astra,{pod=pod,platform='Sunward',surface='vulcanus',near={x=14,y=134},
  sent={'processing-unit*50','roboport*3','logistic-robot*50'},to={'sol'}})
eq(id,1)
eq(#D.lines(astra,ha),0,'the sender\'s own drop reply says it already')
local l=D.lines(sol,hs)
eq(#l,1); assert(l[1]:find('drop #1 from Sunward to vulcanus: still descending',1,true) and l[1]:find('aimed near (14,134)',1,true),l[1])
eq(#D.lines(sol,hs),0,'told once'); eq(#D.lines(luna,hl),0,'not named: not told')
step(30); pod.surface={name='vulcanus'}; pod.position={x=4.2,y=130.6}; step(30)
eq(storage.drops.list[1].last.surface,'vulcanus'); eq(storage.drops.list[1].last.position.x,4.2)
step(300)
l=D.lines(astra,ha); eq(#l,1); assert(l[1]:find('still descending',1,true),l[1])

-- 3. It lands: the pod is gone; of the containers near its last sighting, the
-- one holding what was sent (the barrels of another drop lie nearer).
container(5,131,{{name='water-barrel',count=20,quality='normal'}})
local mine=container(0,129,{{name='processing-unit',count=50,quality='normal'},{name='roboport',count=3,quality='normal'},
  {name='logistic-robot',count=50,quality='normal'}})
pod.valid=false; step(15)
local r=storage.drops.list[1]
eq(r.state,'landed'); eq(r.at.x,0); eq(r.at.y,129); eq(r.container,mine)
l=D.lines(astra,ha); eq(#l,1)
eq(l[1],'drop #1 landed at (0,129) on vulcanus: cargo-pod-container with processing-unit*50 roboport*3 logistic-robot*50 (take them with transfer; it vanishes when empty)'
  ..'; other cargo pod containers within 8 tiles: (5,131) holds water-barrel*20')
eq(#D.lines(sol,hs),1,'Sol is told too'); eq(#D.lines(sol,hs),0); eq(#D.lines(astra,ha),0)

-- 4. A second drop into the landing pad; a third whose container cannot be
-- found (emptied already): said so after 10 s.
D.record(astra,{pod={valid=false},platform='Sunward',surface='vulcanus',pad={x=9,y=9},sent={'coal*5'}})
local lost={valid=true,surface={name='vulcanus'},position={x=60,y=60}}
D.record(astra,{pod=lost,platform='Sunward',surface='vulcanus',near={x=60,y=60},sent={'stone*10'}})
step(15); lost.valid=false; step(15)
eq(storage.drops.list[2].state,'landed'); eq(storage.drops.list[3].state,'descending','waiting for its container')
step(600)
eq(storage.drops.list[3].state,'landed')
l=D.lines(astra,ha); eq(#l,2)
eq(l[1],'drop #2 from Sunward landed in the landing pad at (9,9) on vulcanus: coal*5')
assert(l[2]:find('drop #3 from Sunward to vulcanus: no cargo pod container within 24 tiles of (60,60)',1,true) and l[2]:find('it held stone*10',1,true),l[2])

-- 5. The drops read: newest first, each container as it is now.
mine.get_inventory=function() return {get_contents=function() return {{name='roboport',count=3,quality='normal'}} end} end
local rows=D.read(sol,{}).drops
eq(#rows,3); eq(rows[1].id,3); eq(rows[3].id,1); eq(rows[3].to[1],'sol'); eq(rows[3].aimed_near.x,14)
eq(rows[3].container.position.y,129); eq(rows[3].container.holds[1],'roboport*3'); eq(rows[3].landed_in,'cargo-pod-container')
eq(rows[2].landed_in,'cargo-landing-pad'); assert(rows[1].note:find('no cargo pod container',1,true))
mine.valid=false
assert(D.read(sol,{limit=3}).drops[3].container.gone:find('vanishes when empty',1,true))
eq(#D.read(sol,{limit=1}).drops,1)
fails(function() D.read(sol,{limit=99}) end,'limit out of range')

-- 5b. Sonnet, shift14 22:50: "landed at (12,153)" sent a transfer to (12.5,153.5); the container stood at
-- (11.5,152.5) and another at (13.5,153.5). Positions as they stand, the other containers near it named.
do
  local p2={valid=true,surface={name='vulcanus'},position={x=11,y=150}}
  D.record(sol,{pod=p2,platform='Sunward',surface='vulcanus',near={x=12,y=150},sent={'advanced-circuit*2000'}})
  step(15)
  container(13.5,153.5,{{name='advanced-circuit',count=55,quality='normal'}})
  container(11.5,152.5,{{name='advanced-circuit',count=1945,quality='normal'}})
  p2.valid=false; step(15)
  local got
  for _,line in ipairs(D.lines(sol,hs)) do if line:find('advanced%-circuit%*1945') then got=line end end
  eq(got,'drop #4 landed at (11.5,152.5) on vulcanus: cargo-pod-container with advanced-circuit*1945 (take them with transfer; it vanishes when empty)'
    ..'; other cargo pod containers within 8 tiles: (13.5,153.5) holds advanced-circuit*55')
  local row=D.read(sol,{limit=1}).drops[1]
  eq(row.at.x,11.5); eq(row.nearby[1].position.x,13.5); eq(row.nearby[1].holds[1],'advanced-circuit*55')
end

-- 6. Only the last 20 are kept, and a reader's told marks follow them.
for _=1,25 do D.record(luna,{pod={valid=false},platform='Sunward',surface='vulcanus',pad={x=9,y=9},sent={'coal*1'}}) end
eq(#storage.drops.list,20); eq(storage.drops.list[1].id,10)
step(15)
for _=1,5 do eq(#D.lines(luna,hl),4,'four a reply; the rest wait for the next') end
eq(#D.lines(luna,hl),0)
D.lines(astra,ha); eq(ha.drops,nil,'astra\'s drops are gone from the list')
print('drops: ok')
