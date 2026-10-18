-- d17 batch21 (operator 17:00: the agents' 16:50 poll). Run from the harness root: lua tests/d17_batch21.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end

-- A2 (Astra): the platform_bom keeper adopts a minimum payload changed on its slot; tail: no more than what is to come.
do
  game={tick=0,forces={}}
  defines={inventory={hub_main=1}}
  prototypes={space_location={fulgora={}},item={crusher={}}}
  local ghosts={}
  local crusher={name='crusher',items_to_place_this={{name='crusher',count=1}}}
  for i=1,12 do ghosts[i]={type='entity-ghost',ghost_name='crusher',ghost_prototype=crusher} end
  local sections={}
  local function section(group)
    local sec={group=group,slots={},is_manual=true,filters_count=0}
    sec.set_slot=function(i,f) sec.slots[i]=f; sec.filters_count=math.max(sec.filters_count,i) end
    sec.get_slot=function(i) return sec.slots[i] end
    sec.clear_slot=function(i) sec.slots[i]=nil end
    return sec
  end
  local secs={sections_count=0}
  secs.get_section=function(i) return sections[i] end
  secs.add_section=function(g) sections[#sections+1]=section(g); secs.sections_count=#sections; return sections[#sections] end
  secs.remove_section=function(i) table.remove(sections,i); secs.sections_count=#sections end
  local held=0
  local hub={valid=true,get_logistic_sections=function() return secs end,get_inventory=function() return {get_item_count=function() return held end} end}
  local pl={valid=true,index=5,name='Kestrel',hub=hub,space_location={name='fulgora'},surface={find_entities_filtered=function() return ghosts end}}
  local force={name='player',platforms={pl}}
  pl.force=force; game.forces={player=force}
  local st={}
  local B=dofile('mod/agent-harness_0.1.0/platbom.lua'){platform=function() return pl end,state=function() return st end}
  B.read({force=force},{platform='Kestrel',request=true,min_payload={crusher=10}})
  eq(sections[1].slots[1].minimum_delivery_count,10)
  -- min_payload (or requests) sets 9 on the slot: the keeper keeps 9
  sections[1].slots[1].minimum_delivery_count=9
  B.tick(600); B.tick(1200)
  eq(sections[1].slots[1].minimum_delivery_count,9)
  local r
  -- tail: 12 asked, the hub holds 10: 2 to come, the payload 2
  held=10
  r=B.read({force=force},{platform='Kestrel',request=true,tail=true})
  eq(sections[1].slots[1].minimum_delivery_count,2)
  has(r.lines[1],'custom minimum payload 2 (tail: 2 of the 9 set, what is still to come)')
  has(r.lines[1],'(adopted from the slot, changed by requests or min_payload: 9)')
  defines,prototypes=nil,nil
end
print('d17_batch21 A2 platform_bom keeps a changed min payload: ok')

-- A3 (Grok): a walking load whose rocket launches by another hand gives what it took and did not load back to the
-- chests it took from, the latest first, as the tour's next stops; the reply says what went back and where.
do
  game={tick=1000}
  prototypes={item={['agricultural-science-pack']={weight=1000}}}
  defines={inventory={rocket_silo_rocket=1},rocket_silo_status={rocket_ready=13}}
  local silo={valid=true,name='rocket-silo',type='rocket-silo',position={x=65.5,y=14.5},unit_number=9}
  local c1={valid=true,name='passive-provider-chest',position={x=14.5,y=28.5}}
  local c2={valid=true,name='passive-provider-chest',position={x=20.5,y=28.5}}
  local held=16
  local gave={}
  local launched
  local R=dofile('mod/agent-harness_0.1.0/rocketload.lua'){last_launch=function() return launched end,
    held=function() return held end,
    give=function(_,e,item,_,n) gave[#gave+1]=e.name..'@'..e.position.x..' '..item..' '..n; held=held-n; return {transferred=n} end,
    rocket_weight=function() return '0/1000 kg' end}
  local action={silo=silo,started_tick=500,goals={{name='agricultural-science-pack',quality='normal',target=500}},rows={},trips=1,items={['agricultural-science-pack']=366},load={},
    loaded_items={['agricultural-science-pack']=350},targets={{entity=c1},{entity=silo},{entity=c1},{entity=silo}},index=2,
    sources={{entity=c1,name='agricultural-science-pack',quality='normal',n=350},{entity=c2,name='agricultural-science-pack',quality='normal',n=16}}}
  launched={tick=900,by='astra',cargo='agricultural-science-pack 350'}
  local out=R.walk_visit({},action,silo)
  eq(out.stop,nil); eq(#action.targets,3); eq(action.targets[3].entity,c2)
  -- at the chest: the 16 taken from it and not loaded go back
  R.walk_visit({},action,c2)
  eq(gave[1],'passive-provider-chest@20.5 agricultural-science-pack 16'); eq(held,0)
  local last={}
  R.walk_last(action,last)
  eq(last.returned,'agricultural-science-pack 16 to passive-provider-chest (20.5,28.5)'); eq(last.kept,nil)
  has(action.why,'what it took and did not load goes back to the chests it came from')
  defines,prototypes=nil,nil
end
print('d17_batch21 A3 a load cut by a launch gives back: ok')
