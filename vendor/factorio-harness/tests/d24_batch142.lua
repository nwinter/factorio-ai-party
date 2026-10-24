-- d24 batch142. Run from the harness root: lua tests/d24_batch142.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- PN1 (Sol #2135, Luna #2136: Foobator asked for a calcite platform that unloads in batches by its schedule): a stop's
-- allow unloading. On a copy of world n (2.0.77, Petrel II at Nauvis) with it off the pad asking carbon took none of
-- the hub's 179, all above a finite max still went down, and drop still landed; platform_schedule sets it per stop and
-- every schedule read and drop forecast says it.
do
  defines={space_platform_state={waiting_at_station=4,on_the_path=3,no_schedule=1,paused=7},inventory={hub_main=1,hub_trash=2,cargo_landing_pad_main=1},
    wire_connector_id={circuit_red=1,circuit_green=2}}
  prototypes={space_location={nauvis={},gleba={}},item={calcite={stack_size=50},carbon={stack_size=50}}}
  game={tick=1000}
  local F=dofile('mod/agent-harness_0.1.0/freight.lua'){state=function() return {} end}
  -- the rule: off, the pads' ask counts for nothing; a finite max still sends down all above it; an infinite max keeps all
  local function secs(list) return {sections_count=#list,get_section=function(i) return list[i] end} end
  local keeps=F.hub_keeps_at(secs({{active=true,filters={{value={name='calcite'},min=0,max=10,import_from='nauvis'}}}}),'nauvis')
  eq((F.hub_gives(keeps,'carbon',179,50,true)),0,'pad ask with unloading off')
  eq((F.hub_gives(keeps,'carbon',179,50)),50,'pad ask with unloading on')
  eq((F.hub_gives(keeps,'calcite',49,0,true)),39,'finite max with unloading off')
  -- which record: the current one at that planet, else the first from the current one on, or the index given
  local recs={{station='nauvis',allows_unloading=false},{station='gleba'},{station='nauvis'}}
  local cur=2
  local pl={valid=true,name='Petrel II',index=5,state=4,space_location={name='gleba'},force={},paused=false}
  local sch={}
  setmetatable(sch,{__index=function(_,k) if k=='current' then return cur end end})
  sch.get_record_count=function() return #recs end
  sch.go_to_station=function(i) cur=i end
  sch.get_record=function(pos) return recs[pos.schedule_index] end
  local sets={}
  sch.set_allow_unloading=function(pos,v) assert(type(pos)=='table','record_position: table expected'); sets[#sets+1]=pos.schedule_index; recs[pos.schedule_index].allows_unloading=v end
  pl.get_schedule=function() return sch end
  setmetatable(pl,{__index=function(_,k) if k=='schedule' then return {current=cur,records=recs} end end})
  eq(F.no_unload(pl,'nauvis'),nil,'from stop 2 the first nauvis stop on is 3, which unloads')
  local i,line=F.no_unload(pl,'nauvis',1)
  eq(i,1); eq(line,'stop 1 (nauvis) has unloading off: its landing pads take nothing from the hub there; all above a finite max still goes down')
  cur=1
  eq((F.no_unload(pl,'nauvis')),1); eq(F.no_unload(pl,'gleba'),nil)
  -- platform_schedule: stops with unloading; one left out keeps what that station's first stop had before
  local p={force={platforms={pl}}}
  local space=dofile('mod/agent-harness_0.1.0/space.lua'){state=function() return {} end,integer=function(v,d) return v==nil and d or v end,
    freight=F}
  local r=space.platform_schedule(p,{platform='Petrel II',stops={{station='nauvis'},{station='gleba',unloading=false}},current=1})
  recs=pl.schedule.records
  eq(recs[1].allows_unloading,false,'kept off'); eq(recs[2].allows_unloading,false)
  eq(r.unloading[1],'stop 1 (nauvis): unloading off, kept from the schedule before this call (unloading: true turns it on)')
  eq(r.unloading[2],'stop 2 (gleba): unloading off')
  has(r.unloading_rule,'with unloading off at a stop the landing pads there take nothing from the hub')
  eq(r.schedule,'>nauvis [unloading off] | gleba [unloading off]')
  r=space.platform_schedule(p,{platform='Petrel II',stops={{station='nauvis',unloading=true},{station='gleba'}}})
  eq(recs,recs); recs=pl.schedule.records
  eq(recs[1].allows_unloading,true); eq(recs[2].allows_unloading,false); eq(r.unloading[1],'stop 2 (gleba): unloading off, kept from the schedule before this call (unloading: true turns it on)')
  -- stop N, unloading alone: set in place, the waits and the current stop kept
  recs[1].wait_conditions={{type='time',ticks=600}}
  cur=1
  r=space.platform_schedule(p,{platform='Petrel II',stop=1,unloading=false})
  eq(sets[#sets],1); eq(recs[1].allows_unloading,false); eq(cur,1); eq(recs[1].wait_conditions[1].ticks,600)
  eq(r.edited,'stop 1 (nauvis): unloading off (was on); its waits, the records and the current stop kept')
  eq(space.stops(pl)[1],'1 nauvis (flying to it; unloading off: the landing pads take nothing from the hub here, all above a finite max still goes down): time 10s')
  local ok,err=pcall(space.platform_schedule,p,{platform='Petrel II',unloading=false})
  assert(not ok and tostring(err):find('unloading goes with stop',1,true),tostring(err))
  ok,err=pcall(space.platform_schedule,p,{platform='Petrel II',stop=1,unloading='off'})
  assert(not ok and tostring(err):find('unloading must be true or false',1,true),tostring(err))
  -- the edit log's stop text carries it
  has(space.gate_texts(pl)[1],'nauvis: time 10s; unloading off')
  -- a misnamed field is refused with the name it takes
  local A=dofile('mod/agent-harness_0.1.0/argshapes.lua')()
  ok,err=pcall(A.check,'platform_schedule',{platform='Petrel II',stops={{station='nauvis',allows_unloading=false}}})
  assert(not ok and tostring(err):find('for allows_unloading: unloading',1,true),tostring(err))
  -- shipment {platform, ready}: stopped at nauvis with unloading off, the pad's ask takes nothing; the finite max does
  local force={}
  local padinv={count_empty_stacks=function() return 10 end,get_insertable_count=function() return 1000 end,get_contents=function() return {} end}
  setmetatable(padinv,{__len=function() return 80 end})
  local padsec={active=true,filters={{value={name='carbon'},min=50}}}
  local pad={valid=true,type='cargo-landing-pad',force=force,name='cargo-landing-pad',position={x=52,y=54},get_inventory=function() return padinv end,
    get_logistic_sections=function() return {sections_count=1,get_section=function() return padsec end} end}
  local nauvis_s={index=1,name='nauvis',find_entities_filtered=function(f) if type(f.type)=='table' then return {pad} end return {} end}
  game={tick=1000,planets={nauvis={surface=nauvis_s}}}
  local hubsec={active=true,filters={{value={name='calcite'},min=0,max=10,import_from='nauvis'}}}
  pl.force=force
  pl.hub={valid=true,get_logistic_sections=function() return secs({hubsec}) end}
  local S=dofile('mod/agent-harness_0.1.0/shipment.lua'){state=function() return {} end,freight=function() return F end,
    hub_counts=function() return {carbon=179,calcite=49} end,where=function() return {at='nauvis',stopped=true,text='at nauvis'} end,
    request_rows=function() return {} end,gate=function() return {lines={}} end,gate_row=function() return nil end,rocket=function() return nil end}
  r=S.read(p,{platform='Petrel II',ready=true})
  eq(r.down[1].item,'calcite'); eq(r.down[1].count,39); eq(r.down[2],nil)
  has(r.no_unload,'stop 1 (nauvis) has unloading off')
  local padline
  for _,l in ipairs(r.lines) do if l:find('landing pads on',1,true) then padline=l end end
  has(padline,'kept aboard: carbon: none of 179 (unloading off; the pads ask 50, hold 0)')
  has(padline,'; stop 1 (nauvis) has unloading off')
end
print('d24_batch142 PN1 unloading: ok')

-- PN2 (Astra #2134, Luna too: a dry run passed 17 settings at Nauvis (970,622); the live call placed 31 ghosts and
-- refused all 17, the chunk not visible): the dry run applies the live call's sight rule to each entry and to each
-- wire's other end, and counts those refusals apart (unseen).
do
  local dried=0
  local E=dofile('mod/agent-harness_0.1.0/entryset.lua'){check=function() end,position=function(v) return v end,reason=tostring,
    dry=function() dried=dried+1 end,
    seen=function(_,ctx,pos) eq(ctx.surface,'nauvis'); return pos.x<960 or string.format('(%g,%g) on nauvis is in chunk (%d,%d), which our force does not see now',pos.x,pos.y,math.floor(pos.x/32),math.floor(pos.y/32)) end}
  local entries={{name='assembling-machine-2',position={x=970.5,y=622.5},configure={recipe='iron-gear-wheel'},circuit={enable='iron-plate < 10'}},
    {name='medium-electric-pole',position={x=950.5,y=620.5},wires={{to={x=972.5,y=620.5},color='red'},{to={x=952.5,y=620.5},color='green'}}}}
  local rows,line,n,unseen=E.dry({},entries,{surface='nauvis'})
  eq(n,3); eq(unseen,3); eq(dried,1,'only the wire whose ends are seen is checked further')
  has(rows[1].configure,'(970.5,622.5) on nauvis is in chunk (30,19)'); has(rows[1].circuit,'which our force does not see now')
  has(rows[2].wires[1],'red to (972.5,620.5): (972.5,620.5) on nauvis is in chunk (30,19)'); eq(rows[2].wires[2],'green to (952.5,620.5): ok')
  has(line,'settings (dry run): 1 would be set, 3 refused (3 in chunks our force does not see now): entry 1 configure:')
end
print('d24_batch142 PN2 settings sight: ok')
