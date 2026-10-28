-- d27 batch287. Run from the harness root: lua tests/d27_batch287.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path

-- BT (Astra #2631: Resolute's full BOM kept a turbo belt tail of 6 from an earlier tail while its ghosts asked 753;
-- rockets went with 6 and 8 belts, not 50): a tail never becomes the ceiling. Demand grows: back to a full rocket, or to
-- the user's own minimum payload; demand shrinks: it tails again; a value found on a slot the keeper had not written is
-- kept; a record from before the fix that tails goes back to a full rocket.
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function world()
  game={tick=0,forces={}}
  defines={inventory={hub_main=1}}
  -- a full rocket: 50 belts, 20 pipes by weight (rocket_lift_weight 1000 kg by default)
  prototypes={space_location={vulcanus={},nauvis={}},quality={normal={}},
    item={['turbo-transport-belt']={weight=20000},pipe={weight=50000}}}
  local w={ghosts={},sections={},held={}}
  function w.ghost(name,n) for _=1,n do
    w.ghosts[#w.ghosts+1]={type='entity-ghost',ghost_name=name,ghost_prototype={name=name,items_to_place_this={{name=name,count=1}}},quality={name='normal'}} end end
  function w.build(name,n) for i=#w.ghosts,1,-1 do if n>0 and w.ghosts[i].ghost_name==name then table.remove(w.ghosts,i); n=n-1 end end end
  local function section(group)
    local sec={group=group,slots={},filters_count=0,active=true}
    sec.set_slot=function(i,f) sec.slots[i]=f; sec.filters_count=math.max(sec.filters_count,i) end
    sec.get_slot=function(i) return sec.slots[i] end
    sec.clear_slot=function(i) sec.slots[i]=nil end
    return sec
  end
  local secs={sections_count=0}
  secs.get_section=function(i) return w.sections[i] end
  secs.add_section=function(g) w.sections[#w.sections+1]=section(g); secs.sections_count=#w.sections; return w.sections[#w.sections] end
  secs.remove_section=function(i) table.remove(w.sections,i); secs.sections_count=#w.sections end
  local inv={get_item_count=function(q) return w.held[type(q)=='table' and q.name or q] or 0 end}
  local hub={valid=true,get_logistic_sections=function() return secs end,get_inventory=function() return inv end}
  local surface={find_entities_filtered=function(f)
    local want={}
    for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do want[t]=true end
    local out={}
    for _,g in ipairs(w.ghosts) do if want[g.type] then out[#out+1]=g end end
    return out
  end,count_entities_filtered=function() return 0 end}
  local pl={valid=true,index=7,name='Resolute',hub=hub,space_location={name='nauvis'},surface=surface}
  local force={name='player',platforms={pl}}
  pl.force=force; game.forces={player=force}; game.surfaces={}
  w.st={}
  w.B=dofile('mod/agent-harness_0.1.0/platbom.lua'){platform=function() return pl end,state=function() return w.st end,
    cargo={limits=function() return 1000000,20 end,weigh=function() return {total_kg=1,fewest=1} end}}
  w.force=force
  function w.slot(name)
    for _,f in pairs(w.sections[1] and w.sections[1].slots or {}) do if f.value.name==name then return f end end
  end
  function w.request(a)
    a.platform='Resolute'; a.request=true
    return w.B.read({force=force},a)
  end
  return w
end

do
  local w=world()
  local belt='turbo-transport-belt'
  -- the tail: 56 asked, the hub holds 50: 6 still to come, the minimum payload 6 (of a full rocket, 50)
  w.ghost(belt,56); w.held[belt]=50
  local r=w.request{import_from='vulcanus',tail=true}
  eq(w.slot(belt).minimum_delivery_count,6,'tailed to what is still to come')
  assert(r.lines[1]:find('(tail: 6 of the 50 a full rocket takes',1,true),r.lines[1])
  -- 697 more ghosts (753 in all): the next rewrite goes back to a full rocket
  w.ghost(belt,697)
  w.B.tick(600)
  eq(w.slot(belt).min,753)
  eq(w.slot(belt).minimum_delivery_count,nil,'a full rocket (the game\'s default) again, not the tail of 6')
  eq(w.st.bom_requests[7].min_payload,nil,'the tail was not adopted as the user\'s own')
  -- demand shrinks: it tails again
  w.build(belt,700); w.held[belt]=45
  w.B.tick(1200)
  eq(w.slot(belt).minimum_delivery_count,8,'53 asked, 45 held: 8')
  w.B.tick(1800)
  eq(w.slot(belt).minimum_delivery_count,8,'kept while what is still to come is 8')
  w.ghost(belt,100)
  w.B.tick(2400)
  eq(w.slot(belt).minimum_delivery_count,nil,'grows again: a full rocket again')
  game,defines,prototypes=nil,nil,nil
  print('d27_batch287 BT tail back to a full rocket: ok')
end

do
  -- the user's own ceiling below a full rocket (min_payload 20 of 50) is kept: tails below it, back to it
  local w=world()
  local belt='turbo-transport-belt'
  w.ghost(belt,30); w.held[belt]=25
  w.request{import_from='vulcanus',tail=true,min_payload={[belt]=20}}
  eq(w.slot(belt).minimum_delivery_count,5,'tailed below the user\'s 20')
  w.ghost(belt,300)
  w.B.tick(600)
  eq(w.slot(belt).minimum_delivery_count,20,'back to the user\'s 20')
  -- a min_payload changed on the slot (min_payload action, as in batch21 A2) is adopted as the user's, and kept
  w.slot(belt).minimum_delivery_count=12
  w.B.tick(1200)
  eq(w.slot(belt).minimum_delivery_count,12)
  eq(w.st.bom_requests[7].min_payload[belt..'@normal'],12,'adopted')
  w.build(belt,327); w.held[belt]=0
  w.B.tick(1800)
  eq(w.slot(belt).minimum_delivery_count,3,'3 left: tails below 12')
  w.ghost(belt,40)
  w.B.tick(2400)
  eq(w.slot(belt).minimum_delivery_count,12,'back to the adopted 12')
  game,defines,prototypes=nil,nil,nil
  print('d27_batch287 BT the user\'s ceiling kept: ok')
end

do
  -- a value found on a slot the keeper had not written yet is the ceiling (batch12 A0); a later request keeps it
  local w=world()
  w.ghost('pipe',100)
  w.request{import_from='vulcanus',tail=true}
  local f=w.slot('pipe')
  -- the keeper's own write first; then a record carried over a re-request with a slot it never wrote
  w.st.bom_requests[7].written['pipe@normal']=nil
  f.minimum_delivery_count=7
  w.B.tick(600)
  eq(w.slot('pipe').minimum_delivery_count,7,'found on the slot: kept')
  w.B.tick(1200)
  eq(w.slot('pipe').minimum_delivery_count,7,'kept through the next rewrite (its ceiling)')
  -- a record from before the fix (no ceiling kept), tailing, a slot at its own tail of 16: a full rocket
  w.held.pipe=0
  local rec=w.st.bom_requests[7]
  rec.ceiling=nil; rec.written['pipe@normal']=16; w.slot('pipe').minimum_delivery_count=16
  w.B.tick(1800)
  eq(w.slot('pipe').minimum_delivery_count,nil,'pre-fix record: a full rocket (20 pipes), the stale 16 dropped')
  -- the hold (batch281) still holds through the rewrites
  w.request{hold={'pipe'}}
  eq(w.slot('pipe'),nil)
  eq(w.st.bom_requests[7].import_from,'vulcanus')
  game,defines,prototypes=nil,nil,nil
  print('d27_batch287 BT a slot\'s own value, a pre-fix record, the hold: ok')
end
