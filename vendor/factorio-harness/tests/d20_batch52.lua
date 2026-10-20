-- Run from repository root: lua tests/d20_batch52.lua
-- d20 batch52 K1-K3 (Astra #1352, Sol #882 and #1323).
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- K1 (Astra #1352: "queue_submit platform:Bastion wait_until ammo_below platform/area/count1 rejected remote lane
-- whitelist"): ammo_below on a platform's guns, all of them, at positions or in an area, saw naming the lowest turret;
-- the remote lanes take it as a wait and as a guard's when.
-- K2 (Sol #882: rocket_ready surface=nauvis from Aquilo read the character's surface): rocket_ready and rocket_parts
-- read the silo on the surface named, in a chunk our force has charted.
do
  defines={inventory={turret_ammo=7},rocket_silo_status={building_rocket=1,rocket_ready=9}}
  prototypes={item={['firearm-magazine']={}},quality={normal={}}}
  local function gun(x,y,n)
    local e={valid=true,name='gun-turret',type='ammo-turret',position={x=x,y=y}}
    e.get_inventory=function() return {get_item_count=function() return n end,get_contents=function() return n>0 and {{name='firearm-magazine',count=n}} or {} end} end
    return e
  end
  local guns={gun(-10,-6,40),gun(-2,-11,3),gun(8,4,0)}
  local deck={find_entities_filtered=function(f)
    eq(f.type,'ammo-turret')
    local out={}
    for _,e in ipairs(guns) do
      local ok=true
      if f.area then
        local a,b=f.area[1] or f.area.left_top,f.area[2] or f.area.right_bottom
        local ax,ay,bx,by=a.x or a[1],a.y or a[2],b.x or b[1],b.y or b[2]
        ok=e.position.x>=ax and e.position.x<=bx and e.position.y>=ay and e.position.y<=by
      end
      if ok then out[#out+1]=e end
    end
    return out
  end}
  local bastion={valid=true,name='Bastion',surface=deck}
  local silo={valid=true,name='rocket-silo',position={x=15.5,y=59.5},rocket_parts=37,rocket_silo_status=1,prototype={rocket_parts_required=50}}
  local charted={}
  local nauvis={name='nauvis',find_entities_filtered=function(f) eq(f.type,'rocket-silo'); return {silo} end}
  local aquilo={name='aquilo',find_entities_filtered=function() return {} end}
  game={tick=100,get_surface=function(n) return ({nauvis=nauvis,aquilo=aquilo})[n] end}
  local force={name='player',platforms={bastion},is_chunk_charted=function(s,c) return charted[s.name] end}
  local sol={position={x=0,y=0},surface=aquilo,force=force}
  local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){position=function(v) return v end,known=function() return true end}
  local function check(c) C.validate(c); return C.check(sol,c) end
  local met,saw=check({['until']='ammo_below',platform='Bastion',count=5})
  eq(met,true); eq(saw,'2 turrets below 5 (of 3 on Bastion; lowest gun-turret (8,4): no ammo)')
  met,saw=check({['until']='ammo_below',platform='Bastion',count=5,positions={{x=-10,y=-6}}})
  eq(met,false); eq(saw,'0 turrets below 5 (of 1 on Bastion; lowest gun-turret (-10,-6): 40 firearm-magazine)')
  met,saw=check({['until']='ammo_below',platform='Bastion',count=5,area={left_top={x=-12,y=-12},right_bottom={x=0,y=0}}})
  eq(met,true); eq(saw,'1 turrets below 5 (of 2 on Bastion; lowest gun-turret (-2,-11): 3 firearm-magazine)')
  fails(function() check({['until']='ammo_below',platform='Bastion',count=5,positions={{x=1,y=1}}}) end,'no ammo turret of ours at (1,1) on Bastion')
  fails(function() C.validate({['until']='ammo_below',platform='Bastion',count=5,radius=10}) end,'no position or radius')
  fails(function() C.validate({['until']='ammo_below',count=5,positions={{x=1,y=1}}}) end,'positions applies with platform')
  fails(function() check({['until']='ammo_below',platform='Kestrel',count=5}) end,'no platform of ours named Kestrel')
  -- K2: from Aquilo, the Nauvis silo by surface; uncharted there: refused; without surface: the character's own
  fails(function() check({['until']='rocket_parts',surface='nauvis',position={x=15.5,y=59.5},at_least=30}) end,'(15.5,59.5) on nauvis is not charted')
  charted.nauvis=true
  met,saw=check({['until']='rocket_parts',surface='nauvis',position={x=15.5,y=59.5},at_least=30})
  eq(met,true); has(saw,'rocket parts 37/50 (at least 30)')
  eq(check({['until']='rocket_ready',surface='nauvis',position={x=15.5,y=59.5}}),false)
  fails(function() check({['until']='rocket_ready',position={x=15.5,y=59.5}}) end,'no rocket silo of ours at (15.5,59.5) on aquilo')
  fails(function() C.validate({['until']='rocket_ready',surface='mars',position={x=1,y=1}}) end,'surface must be a surface name')
  -- the remote lanes: ammo_below with platform and the silo waits with surface, as steps and as guards
  local lanes=dofile('mod/agent-harness_0.1.0/queue_lanes.lua')
  local checked
  local function factory(api) checked=api.check_step; return {handlers={},schema={queue_submit={}}} end
  pcall(lanes,{scheduler={handlers={},schema={queue_submit={}}},base={player=function() end,busy=function() end},factory=factory,is_read=function() return false end})
  if checked then
    checked('wait_until',{['until']='ammo_below',platform='Bastion',count=1})
    checked('wait_until',{['until']='rocket_ready',surface='nauvis',position={x=15.5,y=59.5}})
    checked('wait_until',{['until']='all',conditions={{['until']='ammo_below',platform='Bastion',count=1},{['until']='platform_left',platform='Bastion'}}})
    fails(function() checked('wait_until',{['until']='ammo_below',count=1}) end,'ammo_below with platform')
    fails(function() checked('wait_until',{['until']='rocket_ready',position={x=15.5,y=59.5}}) end,'rocket_ready or rocket_parts with surface')
    print('d20_batch52 remote lane checks: ok')
  end
  defines,prototypes,game=nil,nil,nil
end
print('d20_batch52 K1 K2: ok')

-- K3 (Sol #1323: drop 1809, 725 foundation, read "landed" while Aquilo's pad held none before, at and 20 s after;
-- Kestrel IV's hub had died). 2.0.77 on the private copy, a hub killed at each cargo pod state: awaiting_launch,
-- ascending or surface_transition (the pod still on the platform's surface): the pod is gone 5-6 ticks later and the pad
-- gets nothing; descending (0, 1, 3, 10 and 30 ticks in) or parking: the pad gets all of it.
do
  defines={inventory={chest=1,cargo_landing_pad_main=1}}
  storage={}
  local pad_items={['space-platform-foundation']=50}
  local pad_e={valid=true,get_inventory=function() return {get_item_count=function(n) return pad_items[type(n)=='table' and n.name or n] or 0 end,
    get_contents=function() return {} end} end,get_logistic_sections=function() return {sections_count=0} end}
  local aquilo={name='aquilo',find_entities_filtered=function() return {} end}
  game={tick=1000,surfaces={aquilo=aquilo}}
  local D=dofile('mod/agent-harness_0.1.0/drops.lua'){state=function() return storage end,
    integer=function(v,d) return v==nil and d or v end,who=function(p) return p.name end,resolve=function(n) return n end}
  local sol={name='sol'}
  local function step(n) for _=1,n do game.tick=game.tick+1; D.tick(game.tick) end end
  local function drop(hub,pod)
    return D.record(sol,{pod=pod,hub=hub,platform='Kestrel IV',surface='aquilo',pad={x=0,y=0},pad_e=pad_e,sent={'space-platform-foundation*725'},
      items={{name='space-platform-foundation',quality='normal',count=725}}})
  end
  -- 1. the hub dies while the pod still rises on the platform's surface: lost
  local hub,pod={valid=true},{valid=true,surface={name='platform-4'},position={x=0,y=0}}
  local id=drop(hub,pod)
  step(30); hub.valid=false; step(6); pod.valid=false; step(60)
  local r=storage.drops.list[#storage.drops.list]
  eq(r.id,id); eq(r.state,'lost')
  has(r.note,'its platform Kestrel IV\'s hub was destroyed'); has(r.note,'before the pod left the platform\'s surface: it delivered nothing')
  local lines=D.lines(sol,{})
  has(lines[1],'drop #'..id..' from Kestrel IV to aquilo: lost:'); has(lines[1],'it held space-platform-foundation*725')
  eq(D.read(sol,{}).drops[1].state,'lost')
  -- 2. the hub dies once the pod comes down over Aquilo: it lands, and the pad gets it
  hub,pod={valid=true},{valid=true,surface={name='platform-4'},position={x=0,y=0}}
  id=drop(hub,pod)
  step(30); pod.surface={name='aquilo'}; pod.position={x=40,y=-60}; step(30); hub.valid=false; step(300)
  pad_items['space-platform-foundation']=775; pod.valid=false; step(60)
  r=storage.drops.list[#storage.drops.list]
  eq(r.id,id); eq(r.state,'landed'); eq(r.into,'cargo-landing-pad')
  -- 3. a hub that lives: landed as before (the pad's gain or not)
  hub,pod={valid=true},{valid=true,surface={name='aquilo'},position={x=1,y=1}}
  id=drop(hub,pod); step(30); pod.valid=false; step(60)
  eq(storage.drops.list[#storage.drops.list].state,'landed')
  -- 4. a pod_landed wait on a lost drop fails at once with the reason
  local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){position=function(v) return v end,known=function() return true end,
    drop_record=function(n) for _,x in ipairs(storage.drops.list) do if x.id==n then return x end end end}
  local lost_id=storage.drops.list[1].id
  fails(function() C.check({force={platforms={{valid=true,name='Kestrel IV'}}}},{['until']='pod_landed',platform='Kestrel IV',drop_id=lost_id},nil,{}) end,'drop #'..lost_id..' is lost: its platform Kestrel IV\'s hub was destroyed')
  defines,game,storage=nil,nil,nil
end
print('d20_batch52 K3: ok')
