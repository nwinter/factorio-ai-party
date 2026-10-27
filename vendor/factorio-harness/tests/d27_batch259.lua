-- d27 batch259. Run from the harness root: lua tests/d27_batch259.lua
-- CB (Astra #2483): a dry run's cargo bays follow the chains of bays to the hub (Kestrel II's (-2,54) and (-6,58)
-- "joined nothing" against 24 built bays from the hub at (0,0); built, the hub went 539 -> 579).
-- PL (Astra #2484): pod_landed takes location, the planet the pods land on (700 magazines dropped on Fulgora met a
-- wait for 2200 meant for Aquilo).
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,x) local ok,err=pcall(fn); assert(not ok,'expected a failure: '..x); has(err,x) end

-- ---- CB ----------------------------------------------------------------------------------------------------------
do
  defines={inventory={hub_main=1,cargo_landing_pad_main=2}}
  local function box(x0,y0,x1,y1) return {left_top={x=x0,y=y0},right_bottom={x=x1,y=y1}} end
  local seq=0
  -- a surface whose find honours the area, the types and ghost_type, as the game's (boxes a little inside the tiles)
  local function surface(hub_slots)
    local s={list={},finds=0}
    local hub={valid=true,type='space-platform-hub',name='space-platform-hub',position={x=0,y=0},bounding_box=box(-3.9,-3.9,3.9,3.9),unit_number=1,
      get_inventory=function() local inv={} for i=1,hub_slots do inv[i]=true end return inv end,prototype={get_inventory_size=function() return 59 end}}
    s.list[1]=hub
    function s.bay(x,y,ghost)
      seq=seq+1
      local e={valid=true,position={x=x,y=y},bounding_box=box(x-1.9,y-1.9,x+1.9,y+1.9),unit_number=100+seq}
      if ghost then e.type,e.name,e.ghost_name,e.ghost_type='entity-ghost','entity-ghost','cargo-bay','cargo-bay'
      else e.type,e.name='cargo-bay','cargo-bay' end
      s.list[#s.list+1]=e
      return e
    end
    function s.find_entities_filtered(f)
      s.finds=s.finds+1
      local a,out=f.area,{}
      for _,e in ipairs(s.list) do
        local b=e.bounding_box
        local inside=b.left_top.x<a[2][1] and b.right_bottom.x>a[1][1] and b.left_top.y<a[2][2] and b.right_bottom.y>a[1][2]
        local kind=false
        if f.ghost_type then kind=e.ghost_type==f.ghost_type
        else for _,t in ipairs(f.type) do if t==e.type then kind=true end end end
        if inside and kind and #out<(f.limit or 1e9) then out[#out+1]=e end
      end
      return out
    end
    return s
  end
  local D=dofile('mod/agent-harness_0.1.0/dryrun.lua'){placewhy={box_at=function(b,pos) return box(pos.x+b.left_top.x,pos.y+b.left_top.y,pos.x+b.right_bottom.x,pos.y+b.right_bottom.y) end}}
  local proto={type='cargo-bay',collision_box=box(-1.9,-1.9,1.9,1.9)}
  local function plan(...) local out={} for _,p in ipairs({...}) do out[#out+1]={proto=proto,name='cargo-bay',pos={x=p[1],y=p[2]}} end return out end

  -- Kestrel II at tick 68004291 (the d26 save): 24 built bays in two columns from the hub to y=54, (-2,38) missing;
  -- 539 slots = 59 + 24 x 20. On main: "(-2,54) joins nothing ... no hub or landing pad within 16 tiles".
  local s=surface(539)
  for y=6,54,4 do s.bay(-6,y) end
  for y=6,50,4 do if y~=38 then s.bay(-2,y) end end
  local lines=D.cargo_bays(s,{},plan({-2,54},{-6,58}))
  -- (either neighbour: the game's find order gave (-2,50))
  assert(lines[1]=='cargo-bay (-2,54) joins space-platform-hub (0,0) through cargo-bay (-2,50)' or
    lines[1]=='cargo-bay (-2,54) joins space-platform-hub (0,0) through cargo-bay (-6,54)',lines[1])
  eq(lines[2],'cargo-bay (-6,58) joins space-platform-hub (0,0) through cargo-bay (-6,54)')
  eq(lines[3],'space-platform-hub (0,0): 539 slots now (59 its own, 24 built bays joined), 579 after the 2 planned bays joining it (20 a bay, as read from it)')
  eq(#lines,3)

  -- the game's rule (2.0.77, a test platform): an edge shared by any overlap joins; a corner alone does not
  s=surface(59)
  lines=D.cargo_bays(s,{},plan({4,6}))
  eq(lines[1],'cargo-bay (4,6) joins space-platform-hub (0,0) (touching it)', 'half off the edge')
  lines=D.cargo_bays(s,{},plan({6,6}))
  eq(lines[1],'cargo-bay (6,6) joins nothing: it touches no hub, landing pad or bay joined to one, edge to edge; it meets space-platform-hub (0,0) at a corner only, which joins nothing')
  eq(lines[2],nil,'no slot line when nothing joins')

  -- a planned bay that bridges to a built bay joined to nothing: both add slots (the game: 79 -> 119)
  s=surface(79)
  s.bay(-2,6); s.bay(-2,14)
  lines=D.cargo_bays(s,{},plan({-2,10}))
  eq(lines[1],'cargo-bay (-2,10) joins space-platform-hub (0,0) through cargo-bay (-2,6)')
  eq(lines[2],'cargo-bay (-2,14) (built, joined to nothing now) joins space-platform-hub (0,0) through cargo-bay (-2,10) once the plan is built')
  eq(lines[3],'space-platform-hub (0,0): 79 slots now (59 its own, 1 built bay joined), 119 after the 1 planned bay and 1 built bay joining it (20 a bay, as read from it)')

  -- a ghost in the gap joins nothing until built (the game: still 79), and a plan through it says so
  s=surface(79)
  s.bay(-2,6); s.bay(-2,10,true)
  lines=D.cargo_bays(s,{},plan({-2,14}))
  eq(lines[1],'cargo-bay (-2,14) joins space-platform-hub (0,0) through ghost cargo-bay (-2,10) once the ghost bays on the way are built')
  eq(lines[2],'space-platform-hub (0,0): 79 slots now (59 its own, 1 built bay joined), 99 after the 1 planned bay joining it (20 a bay, as read from it)')

  -- far from any hub, no chain: said as such
  s=surface(59)
  lines=D.cargo_bays(s,{},plan({-2,90}))
  eq(lines[1],'cargo-bay (-2,90) joins nothing: it touches no hub, landing pad or bay joined to one, edge to edge; no chain of bays from it reaches a hub or landing pad')

  -- a chain longer than the reads: the plan is not called joined to nothing, nor counted
  s=surface(59+20*200)
  for y=6,802,4 do s.bay(-2,y) end
  lines=D.cargo_bays(s,{},plan({-2,806}))
  has(lines[1],'cargo-bay (-2,806) joins nothing'); has(lines[1],'none found along its chains within 160 hubs, pads and bays read (the reads stop there)')
  assert(s.finds<=2*161+2,'finds '..s.finds)

  -- on 132 bays, a bay planned beside the hub reads its chains once each (two finds an entity)
  s=surface(59+20*132)
  for x=-22,22,4 do for y=6,46,4 do s.bay(x,y) end end
  lines=D.cargo_bays(s,{},plan({-2,-6}))
  eq(lines[2],'space-platform-hub (0,0): 2699 slots now (59 its own, 132 built bays joined), 2719 after the 1 planned bay joining it (20 a bay, as read from it)')
  eq(s.finds,2*(1+133+1),'one find of the area, then one a planned bay, hub and bay')
  defines=nil
end
print('d27_batch259 CB cargo bays along the chains: ok')

-- ---- PL ----------------------------------------------------------------------------------------------------------
game={tick=69300000,planets={nauvis={},fulgora={},aquilo={}}}
prototypes={item={['uranium-rounds-magazine']={}},quality={normal={}},space_location={nauvis={},fulgora={},aquilo={}}}
local state={}
local podlog=dofile('mod/agent-harness_0.1.0/podlog.lua'){state=function() return state end}
local function journey(planet,r) state.podlog=state.podlog or {seq=0,by={},open={},delivered_since=0}; local l=state.podlog.by[planet] or {}; state.podlog.by[planet]=l
  state.podlog.seq=state.podlog.seq+1; r.id=state.podlog.seq; l[#l+1]=r end
-- Kestrel II: 700 down on Fulgora at 69269968 (the stale cap), then 1500 on Aquilo
journey('fulgora',{platform='Kestrel II',sent=69269968,landed=69270800,delivered=69270880,dest='cargo-landing-pad (5,5)',items={['uranium-rounds-magazine']=700}})
journey('aquilo',{platform='Kestrel II',sent=69280000,landed=69280900,delivered=69280980,dest='cargo-landing-pad (17,-13)',items={['uranium-rounds-magazine']=1500}})
journey('aquilo',{platform='Kestrel II',sent=69290000,landed=69290900,dest='cargo-landing-pad (17,-13)',items={['uranium-rounds-magazine']=400}})
do
  local r=podlog.landed_from('Kestrel II',69260000,'uranium-rounds-magazine',nil,'aquilo')
  eq(r.pods,1); eq(r.items,1500); eq(r.landing,1,'landed on Aquilo, cargo not delivered'); eq(r.elsewhere.fulgora,1)
  r=podlog.landed_from('Kestrel II',69260000,'uranium-rounds-magazine')
  eq(r.items,2200,'every planet without location, as before'); eq(r.elsewhere,nil)
end
local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){position=function(v) return v end,known=function() return true end,
  receipts=function() return {} end,pods_landed=function(name,since,item,q,planet) return podlog.landed_from(name,since,item,q,planet) end}
local p={force={platforms={{valid=true,name='Kestrel II'}}}}
do
  local c={['until']='pod_landed',platform='Kestrel II',item='uranium-rounds-magazine',at_least=2200,since_tick=69260000,location='aquilo'}
  C.validate(c)
  local met,saw=C.check(p,c,nil,{})
  eq(met,false,'the Fulgora pod does not meet a wait scoped to Aquilo')
  eq(saw,'1 pod from Kestrel II landed on aquilo and delivered since tick 69260000 with 1500 uranium-rounds-magazine (the last delivered at tick 69280980, cargo-landing-pad (17,-13) on aquilo); 1 more landed, cargo not delivered yet; not counted, landed elsewhere: 1 on fulgora')
  c.location=nil
  met,saw=C.check(p,c,nil,{})
  eq(met,true,'without location every planet counts, as before'); has(saw,'with 2200 uranium-rounds-magazine')
  c.location='fulgora'; c.at_least=700
  eq((C.check(p,c,nil,{})),true,'scoped to Fulgora')
  fails(function() C.validate({['until']='pod_landed',platform='Kestrel II',location='mars'}) end,'pod_landed location is a planet name')
  fails(function() C.validate({['until']='pod_landed',platform='Kestrel II',last_drop=true,location='aquilo'}) end,'no location')
  -- the fallback (freight's receipts, a runtime without the ledger) filters by the stop the pod left
  local F=dofile('mod/agent-harness_0.1.0/conditions.lua'){position=function(v) return v end,known=function() return true end,
    receipts=function() return {{kind='pad',cargo={['uranium-rounds-magazine']=700},stop='fulgora',where='pad F'},
      {kind='pad',cargo={['uranium-rounds-magazine']=1500},stop='aquilo',where='pad A'}} end}
  met,saw=F.check(p,{['until']='pod_landed',platform='Kestrel II',item='uranium-rounds-magazine',at_least=2200,location='aquilo'},nil,{})
  eq(met,false); has(saw,'1 pod from Kestrel II landed on aquilo since the wait began'); has(saw,'with 1500 uranium-rounds-magazine')
  -- the wait line names the planet
  local W=dofile('mod/agent-harness_0.1.0/waiteta.lua'){}
  local row=W.estimate({},{['until']='pod_landed',platform='Kestrel II',item='uranium-rounds-magazine',since_tick=69260000,location='aquilo'},false,{},{})
  eq(row.condition,'pod_landed uranium-rounds-magazine landed from Kestrel II on aquilo since tick 69260000')
end
print('d27_batch259 PL pod_landed location: ok')
