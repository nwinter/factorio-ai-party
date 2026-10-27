-- d27 batch281. Run from the harness root: lua tests/d27_batch281.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path

-- BH (Astra #2604: Resolute's 24 beacons, 11.52 MW, staged before fusion; a beacon slot cleared by hand in the managed
-- platform_bom section came back with the next rewrite): hold keeps items out of the section through the rewrites; its
-- ghosts stay; the read says them apart in requests_check; hold: false asks them again.
do
  game={tick=0,forces={}}
  defines={inventory={hub_main=1}}
  prototypes={space_location={vulcanus={},nauvis={}},item={beacon={},['speed-module-3']={},accumulator={}},quality={normal={},rare={},epic={}}}
  local ghosts={}
  local function ghost(name,q) local proto={name=name,items_to_place_this={{name=name,count=1}}}
    ghosts[#ghosts+1]={type='entity-ghost',ghost_name=name,ghost_prototype=proto,quality={name=q or 'normal'}} end
  for _=1,24 do ghost('beacon') end
  ghost('beacon','rare')
  for _=1,3 do ghost('accumulator','epic') end
  local sections={}
  local function section(group)
    local sec={group=group,slots={},filters_count=0,active=true}
    sec.set_slot=function(i,f) sec.slots[i]=f; sec.filters_count=math.max(sec.filters_count,i) end
    sec.get_slot=function(i) return sec.slots[i] end
    sec.clear_slot=function(i) sec.slots[i]=nil end
    -- filters as the game gives them (what asks() reads)
    return setmetatable(sec,{__index=function(_,k) if k=='filters' then local out={}; for _,f in pairs(sec.slots) do out[#out+1]=f end; return out end end})
  end
  local secs={sections_count=0}
  secs.get_section=function(i) return sections[i] end
  secs.add_section=function(g) sections[#sections+1]=section(g); secs.sections_count=#sections; return sections[#sections] end
  secs.remove_section=function(i) table.remove(sections,i); secs.sections_count=#sections end
  local inv={get_item_count=function() return 0 end}
  local hub={valid=true,get_logistic_sections=function() return secs end,get_inventory=function() return inv end}
  local surface={find_entities_filtered=function(f)
    local want={}
    for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do want[t]=true end
    local out={}
    for _,g in ipairs(ghosts) do if want[g.type] then out[#out+1]=g end end
    return out
  end,count_entities_filtered=function() return 0 end}
  local pl={valid=true,index=7,name='Resolute',hub=hub,space_location={name='nauvis'},surface=surface}
  local force={name='player',platforms={pl}}
  pl.force=force; game.forces={player=force}; game.surfaces={}
  local st={}
  local api={platform=function() return pl end,state=function() return st end,
    cargo={limits=function() return 1000000,20 end,weigh=function() return {total_kg=1,fewest=1} end}}
  local B=dofile('mod/agent-harness_0.1.0/platbom.lua')(api)
  local function slots()
    local out={}
    for _,f in pairs(sections[1] and sections[1].slots or {}) do
      local k=f.value.name..(f.value.quality~='normal' and '@'..f.value.quality or '')
      out[k]=f.min
    end
    return out
  end
  local area={left_top={x=-20,y=-61},right_bottom={x=20,y=0}}
  B.read({force=force},{platform='Resolute',request=true,import_from='vulcanus',area=area,tail=true})
  assert(slots().beacon==24 and slots()['beacon@rare']==1 and slots()['accumulator@epic']==3,'all asked before the hold')
  -- the hold: a call with hold alone keeps the request's area, import_from and tail
  local r=B.read({force=force},{platform='Resolute',request=true,hold={'beacon'}})
  local s=slots()
  assert(s.beacon==nil and s['beacon@rare']==nil and s['accumulator@epic']==3,'beacon (every quality) asked none of')
  assert(st.bom_requests[7].import_from=='vulcanus' and #st.bom_requests[7].areas==1 and st.bom_requests[7].tail,'area, import_from and tail kept')
  assert(r.hold[1]=='beacon' and #r.hold==1,tostring(r.hold and r.hold[1]))
  local l=table.concat(r.lines,'\n')
  assert(l:find('beacon: held, not asked (the ghosts need 24; the hub holds 0)',1,true),l)
  assert(l:find('beacon@rare: held, not asked (the ghosts need 1',1,true),l)
  assert(r.note:find('held items (hold) are asked none of',1,true),r.note)
  -- a slot written by hand for it is cleared again by the rewrite; the hold stays through rewrites; the ghosts stay
  sections[1].set_slot(9,{value={type='item',name='beacon',quality='normal',comparator='='},min=24,import_from='vulcanus'})
  B.tick(600); B.tick(1200)
  assert(slots().beacon==nil and slots()['accumulator@epic']==3,'kept out through the rewrites')
  eq=function(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
  eq(#ghosts,28)
  -- the read: held items are not unrequested, and are said apart
  local rd=B.read({force=force},{platform='Resolute'})
  assert(rd.unrequested==nil,tostring(rd.unrequested and rd.unrequested[1]))
  eq(rd.requests_check,"every item the ghosts still need has an active hub request; 2 held by the platform_bom request's hold, not asked: beacon 24, beacon@rare 1")
  assert(rd.hold[1]=='beacon')
  local bl
  for _,x in ipairs(rd.lines) do if x:find('^beacon:') then bl=x end end
  assert(bl and bl:find("(the hub asks none) (held by the platform_bom request's hold)",1,true),tostring(bl))
  -- every item held: the section goes, the hold and request stay
  B.read({force=force},{platform='Resolute',request=true,hold={'beacon','accumulator@epic'}})
  eq(#sections,0)
  B.tick(1800)
  assert(st.bom_requests[7] and st.bom_requests[7].hold.beacon,'the request and its hold stay while held ghosts are open')
  -- item@quality: only that quality is held
  B.read({force=force},{platform='Resolute',request=true,hold={'beacon@rare'}})
  s=slots()
  assert(s.beacon==24 and s['beacon@rare']==nil and s['accumulator@epic']==3,'only beacon@rare held')
  -- hold: false asks them all again
  r=B.read({force=force},{platform='Resolute',request=true,hold=false})
  s=slots()
  assert(s.beacon==24 and s['beacon@rare']==1 and r.hold==nil and st.bom_requests[7].hold==nil,'cleared')
  eq(st.bom_requests[7].import_from,'vulcanus')
  -- a later request call without hold keeps it; refusals
  B.read({force=force},{platform='Resolute',request=true,hold={'beacon'}})
  B.read({force=force},{platform='Resolute',request=true,import_from='vulcanus',area=area,tail=true})
  assert(st.bom_requests[7].hold.beacon and slots().beacon==nil,'kept by a call that does not name it')
  local ok,err=pcall(B.read,{force=force},{platform='Resolute',request=true,hold={'beecon'}})
  assert(not ok and tostring(err):find('hold: unknown item beecon',1,true),tostring(err))
  ok,err=pcall(B.read,{force=force},{platform='Resolute',request=true,hold={'beacon@shiny'}})
  assert(not ok and tostring(err):find('hold: unknown quality shiny',1,true),tostring(err))
  ok,err=pcall(B.read,{force=force},{platform='Resolute',hold={'beacon'}})
  assert(not ok and tostring(err):find('hold goes with request: true',1,true),tostring(err))
  ok,err=pcall(B.read,{force=force},{platform='Resolute',request=true,hold={beacon=true}})
  assert(not ok and tostring(err):find('hold is a list',1,true),tostring(err))
  -- the last ghost built: the request and its hold go
  for i=#ghosts,1,-1 do ghosts[i]=nil end
  B.tick(2400)
  eq(st.bom_requests[7],nil)
  game,defines,prototypes=nil,nil,nil
  print('d27_batch281 BH platform_bom hold: ok')
end
