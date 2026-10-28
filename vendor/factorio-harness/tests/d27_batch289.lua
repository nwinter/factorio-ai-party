-- Run from repository root: lua tests/d27_batch289.lua
-- d27 batch289 (Astra #2634, 17:13: "queue_submit lane platform:Resolute with wait_until until platform_ready (with
-- platform and area) was rejected by the remote condition allowlist"). platform_ready runs in the remote lane and the
-- platform lanes as a direct wait_until takes it; on the whole platform it counts entity ghosts too (platform_built the
-- foundation only), and saw says the ghosts it counted.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) if a~=b then error((m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b),2) end end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
game={tick=1000}
-- Resolute: entity ghosts in the fusion bay (area 0,0..10,10) and elsewhere, tile ghosts elsewhere
local ghosts={bay=2,other_ents=3,tiles=4}
local function inside(ar) return ar[1][1]>=0 and ar[2][1]<=10 and ar[1][2]>=0 and ar[2][2]<=10 end
local surface={valid=true,name='platform-3',count_entities_filtered=function(f)
  local ar=f.area and {{f.area[1].x or f.area[1][1] or f.area.left_top.x,f.area[1].y or f.area[1][2] or f.area.left_top.y},
    {f.area[2].x or f.area[2][1] or f.area.right_bottom.x,f.area[2].y or f.area[2][2] or f.area.right_bottom.y}} or nil
  if f.type=='entity-ghost' then
    if ar then return inside(ar) and ghosts.bay or 0 end
    return ghosts.bay+ghosts.other_ents
  end
  if f.type=='tile-ghost' then return ar and 0 or ghosts.tiles end
  return 0
end}
local force={name='player'}
local pl={valid=true,index=3,name='Resolute',force=force,surface=surface}
force.platforms={pl}
local p={index=1,name='astra',force=force,valid=true}
local C=require('conditions'){position=function(v) return {x=v.x or v[1],y=v.y or v[2]} end,known=function() return true end}

-- 1. The check: platform_ready with area counts that part's ghosts; on the whole platform entity and tile ghosts;
-- entities=false the foundation only; platform_built unchanged.
do
  local bay={['until']='platform_ready',platform='Resolute',area={{0,0},{10,10}}}
  C.validate(bay)
  local met,saw=C.check(p,bay)
  eq(met,false); eq(saw,'platform Resolute, the part asked: 2 entity ghosts, 0 tile ghosts left')
  met,saw=C.check(p,{['until']='platform_ready',platform='Resolute'})
  eq(met,false); eq(saw,'platform Resolute: 4 tile ghosts left, 5 entity ghosts')
  met,saw=C.check(p,{['until']='platform_ready',platform='Resolute',entities=false})
  eq(saw,'platform Resolute: 4 tile ghosts left','entities=false: the foundation only')
  met,saw=C.check(p,{['until']='platform_built',platform='Resolute'})
  eq(saw,'platform Resolute: 4 tile ghosts left','platform_built as before')
  ghosts.bay=0
  eq((C.check(p,bay)),true,'the bay built: met while ghosts remain elsewhere')
  ghosts.tiles=0
  met,saw=C.check(p,{['until']='platform_ready',platform='Resolute'})
  eq(met,false); eq(saw,'platform Resolute: 0 tile ghosts left, 3 entity ghosts')
  eq((C.check(p,{['until']='platform_built',platform='Resolute'})),true,'the foundation done: platform_built met')
  ghosts.bay,ghosts.tiles=2,4
end
print('d27_batch289 platform_ready check: ok')

-- 2. The lanes: platform_ready queued in lane platform:Resolute and the remote lane, not met then met; refused without
-- platform as a direct wait_until is.
do
  local s={active={}}
  local base={state=function() return s end,player=function() return p end,handlers={},busy=function() return false end,
    stop=function() end,stop_index=function() end,direct_action=function() return nil end,
    condition=function(q,c) return C.check(q,c) end,validate_condition=function(c) C.validate(c) end}
  local make=require('scheduler')
  local body=make(base)
  local q=require('queue_lanes'){scheduler=body,factory=make,base=base,is_read=function() return false end}
  local h=q.handlers
  local function tick(n) for _=1,n or 1 do game.tick=game.tick+1; q.tick() end end
  local step={action='wait_until',args={['until']='platform_ready',platform='Resolute',area={{0,0},{10,10}},timeout=3600}}
  for _,lane in ipairs({'platform:Resolute','remote'}) do
    ghosts.bay=2
    local r=h.queue_submit(p,{lane=lane,steps={step}})
    eq(r.state,'running',lane..': accepted')
    tick(30)
    local st=h.queue_status(p,{lane=lane})
    assert(st.active and st.active.action=='wait_until',lane..': the wait runs')
    assert(tostring(st.waiting and st.waiting.saw):find('the part asked: 2 entity ghosts, 0 tile ghosts left',1,true),lane..': saw '..tostring(st.waiting and st.waiting.saw))
    ghosts.bay=0
    tick(120)
    st=h.queue_status(p,{lane=lane,history='all'})
    assert(not st.active,lane..': met, done')
    local last=st.history[#st.history]
    eq(last.action,'wait_until',lane); eq(last.ok,true,lane)
    fails(function() h.queue_submit(p,{lane=lane,steps={{action='wait_until',args={['until']='platform_ready',area={{0,0},{1,1}}}}}}) end,
      'platform_ready requires platform')
  end
end
print('d27_batch289 platform_ready in the lanes: ok')
