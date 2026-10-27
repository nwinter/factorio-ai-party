-- d27 batch280 CS (Astra #2600): an Aquilo railgun-turret batch asked a 48-slot requester for 930 tungsten-plate, 1588
-- superconductor, 620 carbon-fiber and 3400 quantum-processor (68 slots) and waited for each; the queue dry run passed
-- and the plan stalled at 1500 quantum-processor. On a copy (2.0.77) those four requests filled the empty requester in
-- 19 s (930, 1400, 621, 1500: every slot) and nothing more came; each quality takes slots of its own; robots fill only
-- under the bar. The queue dry run now says what the waits at a requester need at once against its slots
-- (stageslots.lua), and a submit refuses waits that can never all be met.
-- Run from the harness root: lua tests/d27_batch280.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..'\n  lacks: '..part) end
local function none(s,part) assert(not (type(s)=='string' and s:find(part,1,true)),tostring(s)..'\n  has: '..part) end

defines={inventory={chest=1}}
prototypes={item={['tungsten-plate']={stack_size=50},superconductor={stack_size=200},['carbon-fiber']={stack_size=100},
  ['quantum-processor']={stack_size=100},['iron-plate']={stack_size=100}},quality={normal={},rare={}}}
local force={name='player'}
local surface={name='aquilo'}
local ents={}
surface.find_entities_filtered=function(f)
  local out={}
  local types={}
  if type(f.type)=='table' then for _,t in ipairs(f.type) do types[t]=true end else types[f.type]=true end
  for _,e in ipairs(ents) do
    local a=f.area
    if types[e.type] and e.position.x>=a[1][1] and e.position.x<=a[2][1] and e.position.y>=a[1][2] and e.position.y<=a[2][2] then out[#out+1]=e end
  end
  return out
end
game={tick=0,get_surface=function() return surface end}
local p={index=1,surface=surface,force=force}

-- Astra's requester: 48 slots, its bar off (49), one manual section, trash unrequested off
local sections,held,bar,trash={},{},49,false
local pt={get_section=function(i) return sections[i] end}
setmetatable(pt,{__index=function(_,k) if k=='sections_count' then return #sections elseif k=='trash_not_requested' then return trash end end})
local inv=setmetatable({get_bar=function() return bar end,get_contents=function() return held end},{__len=function() return 48 end})
local req={valid=true,unit_number=7,name='requester-chest',type='logistic-container',position={x=-60.5,y=12.5},force=force,surface=surface,
  prototype={logistic_mode='requester'},get_requester_point=function() return pt end,get_inventory=function() return inv end}
ents[1]=req
local function reset() sections={{active=true,is_manual=true,group='',filters={}}}; held={}; bar=49; trash=false; ents={req} end

local SS=dofile('mod/agent-harness_0.1.0/stageslots.lua'){}
local R={x=-60.5,y=12.5}
local function wait(item,n,q) return {action='wait_until',args={['until']='item_count',positions={R},item=item,at_least=n,quality=q,timeout=54000}} end
local astra={
  {action='requests',args={position=R,clear_all=true}},
  {action='requests',args={position=R,set={{item='tungsten-plate',min=930},{item='superconductor',min=1588},{item='carbon-fiber',min=620},{item='quantum-processor',min=3400}}}},
  wait('tungsten-plate',930),wait('superconductor',1588),wait('carbon-fiber',620),wait('quantum-processor',3400),
}

-- Astra's plan: the four waits need 68 slots at once (19 + 8 + 7 + 34), nothing takes from the chest: refused
do
  reset()
  local lines,refused=SS.check(p,astra)
  eq(#refused,1,'one refusal, at the wait where the waits first outgrow the slots')
  eq(#lines,2,'the requests said once, the refusal once')
  has(refused[1],'step 6 (wait_until item_count quantum-processor at requester-chest (-60.5,12.5)): the waits there need 68 of its 48 slots at once (620 carbon-fiber 7, 3400 quantum-processor 34, 1588 superconductor 8, 930 tungsten-plate 19): nothing takes from it between them, so they can never all be met')
  has(refused[1],'Refused: fewer at once (clear requests and set the next after a wait), or another chest')
  -- the first wait: its requests already ask 68 (said), its own items fit
  has(lines[1],'step 3 (wait_until item_count tungsten-plate at requester-chest (-60.5,12.5)): its requests then ask 68 of its 48 slots')
  has(lines[1],'robots bring them in any order, and this wait can stall once its slots are full')
  print('CS Astra\'s plan: 68 of 48 slots at once, refused: ok')
end

-- an inserter taking from the chest: the items may go as they arrive (sequential): said, not refused; held by the plan
-- first with the hold condition (as assembler_batch holds its input): refused again
do
  reset()
  local ins={valid=true,unit_number=8,name='bulk-inserter',type='inserter',position={x=-60.5,y=11.5},force=force,pickup_target=req,
    get_control_behavior=function() return nil end}
  ents[2]=ins
  local lines,refused=SS.check(p,astra)
  eq(refused,nil)
  has(lines[#lines],'bulk-inserter (-60.5,11.5) takes from it: they fit only if taken out as they arrive (sequential)')
  local plan={{action='circuit_set',args={position={x=-60.5,y=11.5},logistic='tungsten-plate < -2147483648'}}}
  for _,st in ipairs(astra) do plan[#plan+1]=st end
  lines,refused=SS.check(p,plan)
  has(refused[1],'step 7 (wait_until item_count quantum-processor')
  -- held by its own condition now (the hold), and let go in the plan before the waits: may take
  ins.get_control_behavior=function() return {connect_to_logistic_network=true,logistic_condition={first_signal={type='item',name='tungsten-plate'},comparator='<',constant=-2147483648}} end
  lines,refused=SS.check(p,astra)
  has(refused[1],'can never all be met')
  plan[1]={action='circuit_set',args={position={x=-60.5,y=11.5},logistic=false}}
  lines,refused=SS.check(p,plan)
  eq(refused,nil)
  print('CS takers: sequential said, held ones refused: ok')
end

-- staged one after another: the requests cleared and the next set after a wait; what was waited for stays in the chest
-- (nothing takes it): 930 tungsten (19) then 2000 quantum (20) fit, then 3400 quantum (34) with the tungsten does not
do
  reset()
  local plan={
    {action='requests',args={position=R,set={{item='tungsten-plate',min=930}}}},wait('tungsten-plate',930),
    {action='requests',args={position=R,clear_all=true}},
    {action='requests',args={position=R,set={{item='quantum-processor',min=2000}}}},wait('quantum-processor',2000)}
  local lines,refused=SS.check(p,plan)
  eq(refused,nil)
  has(lines[2],'step 5 (wait_until item_count quantum-processor at requester-chest (-60.5,12.5)): the requests there ask 20 of its 48 slots (2000 quantum-processor 20)')
  plan[4].args.set[1].min=3400; plan[5]=wait('quantum-processor',3400)
  lines,refused=SS.check(p,plan)
  has(refused[1],'need 53 of its 48 slots at once (3400 quantum-processor 34, 930 tungsten-plate 19)')
  -- a step that takes from the chest between (a transfer out): the waits before it no longer count
  table.insert(plan,3,{action='transfer',args={position=R,direction='to_player',item='tungsten-plate',count=930}})
  lines,refused=SS.check(p,plan)
  eq(refused,nil)
  has(lines[#lines],'step 3 (transfer) takes from it')
  print('CS sequential staging: ok')
end

-- each quality its own slots; the bar; what the chest holds unrequested stays (trash unrequested off) and goes (on)
do
  reset()
  local plan={{action='requests',args={position=R,set={{item='quantum-processor',min=2500},{item='quantum-processor',min=2500,quality='rare'}}}},
    {action='wait_until',args={['until']='all',conditions={wait('quantum-processor',2500).args,wait('quantum-processor',2500,'rare').args}}}}
  local lines,refused=SS.check(p,plan)
  has(refused[1],'need 50 of its 48 slots at once (2500 quantum-processor 25, 2500 quantum-processor@rare 25)')
  reset(); bar=11
  plan={{action='requests',args={position=R,set={{item='quantum-processor',min=2000}}}},wait('quantum-processor',2000)}
  lines,refused=SS.check(p,plan)
  has(refused[1],'need 20 of its 10 slots (its bar at 10 of 48) at once')
  reset()
  held={{name='iron-plate',quality='normal',count=3000},{name='quantum-processor',quality='normal',count=300}}
  lines,refused=SS.check(p,plan)
  has(refused[1],'need 50 of its 48 slots at once (2000 quantum-processor 20, and 30 slots of what it holds that stays (3000 iron-plate))')
  trash=true
  lines,refused=SS.check(p,plan)
  eq(refused,nil); has(lines[1],'the requests there ask 20 of its 48 slots')
  -- the plan switches trash unrequested off first (as assembler_batch does): it stays
  table.insert(plan,1,{action='requests',args={position=R,trash_unrequested=false}})
  lines,refused=SS.check(p,plan)
  has(refused[1],'need 50 of its 48 slots')
  print('CS quality, bar, held items, trash unrequested: ok')
end

-- the chest's own requests (no requests step in the plan), sections summed and an inactive one left out; a section
-- index step is not followed; a plan with no wait at a requester is not read
do
  reset()
  sections={{active=true,is_manual=true,group='',filters={{value={type='item',name='quantum-processor',quality='normal'},min=3000}}},
    {active=true,is_manual=true,group='',filters={{value={type='item',name='quantum-processor',quality='normal'},min=1000}}},
    {active=false,is_manual=true,group='',filters={{value={type='item',name='tungsten-plate',quality='normal'},min=5000}}}}
  local lines,refused=SS.check(p,{wait('quantum-processor',4000)})
  eq(refused,nil); has(lines[1],'the requests there ask 40 of its 48 slots (4000 quantum-processor 40)')
  lines,refused=SS.check(p,{{action='requests',args={position=R,section=3,active=true}},wait('quantum-processor',4000)})
  has(lines[1],'requester-chest (-60.5,12.5): step 1 (requests with section, add_section, remove_section or group) is not followed')
  eq(#lines,1); eq(refused,nil)
  eq(SS.check(p,{{action='requests',args={position=R,set={{item='quantum-processor',min=9000}}}},{action='wait_until',args={['until']='tick_at_least',tick=60}}}),nil)
  -- a wait for an item the chest's requests do not name: not staging, not read
  eq(SS.check(p,{wait('iron-plate',9000)}),nil)
  print('CS the chest\'s own sections, a section step, plans with no staging: ok')
end

-- through queue_submit: the dry run gives staging and staging_refused, nothing queued; a submit is refused
do
  reset()
  local state={}
  local players={[1]=p}
  local S=dofile('mod/agent-harness_0.1.0/scheduler.lua'){
    state=function() return state end,player=function(i) return players[i] end,
    handlers={requests=function() return {} end},
    busy=function() return false end,stop=function() end,stop_index=function() end,validate_condition=function() end,
    staging=function(pl,items) return SS.check(pl,items) end,
  }
  local r=S.handlers.queue_submit(p,{steps=astra,dry_run=true})
  eq(r.queued,false); eq(#r.staging_refused,1)
  has(r.staging[#r.staging],'68 of its 48 slots at once')
  local ok,err=pcall(S.handlers.queue_submit,p,{steps=astra})
  assert(not ok); has(tostring(err),'can never all be met')
  eq(#((state.queues or {})[1] or {pending={}}).pending,0,'nothing queued')
  -- a plan that fits goes in
  r=S.handlers.queue_submit(p,{steps={astra[1],{action='requests',args={position=R,set={{item='tungsten-plate',min=930}}}},wait('tungsten-plate',930)}})
  eq(#state.queues[1].pending,3)
  print('CS queue_submit dry run and submit: ok')
end
game=nil
print('d27_batch280 CS: ok')
