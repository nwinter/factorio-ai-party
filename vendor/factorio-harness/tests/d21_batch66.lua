-- d21 batch66. Run from the harness root: lua tests/d21_batch66.lua
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..'\n  lacks: '..part) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path

-- AB1 (Sol #1591): Solstice's ghosts needed asteroid-collector@uncommon 1, solar-panel@epic 1 and @rare 2; platform_bom
-- counted collector 1 and solar 3 at normal, took the hub's 6 normal panels as covering them, and its request section
-- never asked the qualities. Every count is by item and quality; a slot an item at a quality.
do
  game={tick=0,forces={},surfaces={}}
  defines={inventory={hub_main=1,robot_cargo=2,cargo_unit=3}}
  prototypes={space_location={nauvis={}},item={['solar-panel']={weight=20000},['asteroid-collector']={weight=100000},['speed-module']={weight=20000}},
    quality={normal={},uncommon={},rare={},epic={},legendary={}}}
  local solar={name='solar-panel',items_to_place_this={{name='solar-panel',count=1}}}
  local collector={name='asteroid-collector',items_to_place_this={{name='asteroid-collector',count=1}}}
  local ents={
    {type='entity-ghost',ghost_name='asteroid-collector',ghost_prototype=collector,quality={name='uncommon'}},
    {type='entity-ghost',ghost_name='solar-panel',ghost_prototype=solar,quality={name='epic'}},
    {type='entity-ghost',ghost_name='solar-panel',ghost_prototype=solar,quality={name='rare'}},
    {type='entity-ghost',ghost_name='solar-panel',ghost_prototype=solar,quality={name='rare'}},
    -- a built machine's module request at rare
    {type='item-request-proxy',item_requests={{name='speed-module',quality='rare',count=2}}},
  }
  local robots={}
  local function find(f)
    local want={}
    for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do want[t]=true end
    local out={}
    for _,e in ipairs(ents) do if want[e.type] then out[#out+1]=e end end
    if want['construction-robot'] then for _,r in ipairs(robots) do out[#out+1]=r end end
    return out
  end
  -- the hub: 6 normal panels, 1 rare; get_item_count{name, quality} at that quality, a name alone every quality
  local held={['solar-panel@normal']=6,['solar-panel@rare']=1}
  local inv={get_item_count=function(w)
    if type(w)=='table' then return held[w.name..'@'..(w.quality or 'normal')] or 0 end
    local n=0 for k,c in pairs(held) do if k:match('^(.*)@')==w then n=n+c end end return n end}
  local sections={}
  local secs={sections_count=0}
  secs.get_section=function(i) return sections[i] end
  secs.add_section=function(g)
    local sec={group=g,slots={},filters_count=0,active=true}
    sec.set_slot=function(i,x) sec.slots[i]=x; sec.filters_count=math.max(sec.filters_count,i) end
    sec.clear_slot=function(i) sec.slots[i]=nil end
    sec.get_slot=function(i) return sec.slots[i] end
    sec.filters=sec.slots
    sections[#sections+1]=sec; secs.sections_count=#sections; return sec
  end
  secs.remove_section=function(i) table.remove(sections,i); secs.sections_count=#sections end
  local hub={valid=true,get_logistic_sections=function() return secs end,get_inventory=function() return inv end}
  local built={['solar-panel@rare']=5,['solar-panel@normal']=40}
  local pl={valid=true,index=9,name='Solstice',hub=hub,space_location={name='nauvis'},surface={find_entities_filtered=find,
    count_entities_filtered=function(f) return built[f.name..'@'..(f.quality or 'normal')] or 0 end}}
  local force={name='player',platforms={pl}}
  pl.force=force
  game.forces={player=force}
  local st={}
  local B=dofile('mod/agent-harness_0.1.0/platbom.lua'){platform=function() return pl end,state=function() return st end,
    cargo={limits=function() return 1000000,40 end,weigh=function(rest) B_rest=rest; return {total_kg=1,fewest=1} end}}

  -- the read: a row an item at a quality
  local r=B.read({force=force},{platform='Solstice'})
  local row={}
  for _,x in ipairs(r.items) do row[x.key]=x end
  eq(row['asteroid-collector'],nil,'no normal collector row')
  eq(row['asteroid-collector@uncommon'].ghosts_need,1); eq(row['asteroid-collector@uncommon'].quality,'uncommon'); eq(row['asteroid-collector@uncommon'].item,'asteroid-collector')
  eq(row['solar-panel'],nil,'no normal solar row: the hub\'s normal panels cover no ghost')
  eq(row['solar-panel@epic'].ghosts_need,1); eq(row['solar-panel@epic'].hub,0); eq(row['solar-panel@epic'].remaining,1,'6 normal panels do not cover an epic ghost')
  eq(row['solar-panel@epic'].hub_other_quality,7)
  eq(row['solar-panel@rare'].ghosts_need,2); eq(row['solar-panel@rare'].hub,1); eq(row['solar-panel@rare'].remaining,1); eq(row['solar-panel@rare'].built,5,'built at that quality')
  eq(row['speed-module@rare'].requests,2)
  local text=table.concat(r.lines,'\n')
  has(text,'solar-panel@epic: ghosts need 1 (0 built); hub holds 0 (and 7 at other qualities, which do not build these); 1 to send (the hub asks none)')
  has(text,'solar-panel@rare: ghosts need 2 (5 built); hub holds 1 (and 6 at other qualities, which do not build these); 1 to send')
  has(r.requests_check,'4 items the ghosts still need have no active hub request')
  local q={}
  for _,x in ipairs(B_rest) do q[x.name..'@'..x.quality]=x.count end
  eq(q['solar-panel@epic'],1,'to send at its quality'); eq(q['solar-panel@rare'],1); eq(q['asteroid-collector@uncommon'],1)

  -- the request section: one slot an item at a quality (comparator =), the hub's stock at that quality only
  r=B.read({force=force},{platform='Solstice',request=true})
  eq(r.request,'set')
  local sec=sections[1]
  local slot={}
  for i=1,sec.filters_count do local f=sec.slots[i]; if f then slot[f.value.name..'@'..f.value.quality]=f; eq(f.value.comparator,'=') end end
  eq(slot['solar-panel@normal'],nil,'no normal panel asked')
  eq(slot['solar-panel@epic'].min,1); eq(slot['solar-panel@rare'].min,2); eq(slot['asteroid-collector@uncommon'].min,1); eq(slot['speed-module@rare'].min,2)
  text=table.concat(r.lines,'\n')
  has(text,'solar-panel@epic: request 1 from nauvis (the ghosts need 1; the hub holds 0)')
  has(text,'solar-panel@rare: request 2 from nauvis (the ghosts need 2; the hub holds 1)')
  -- the read sees the section's asks by quality
  r=B.read({force=force},{platform='Solstice'})
  row={}
  for _,x in ipairs(r.items) do row[x.key]=x end
  eq(row['solar-panel@epic'].asks,1); eq(row['solar-panel@rare'].asks,2)
  eq(r.requests_check,'every item the ghosts still need has an active hub request')

  -- the rewrite keeps each item and quality in its slot; one built drops out where it stands
  local rare_slot
  for i=1,sec.filters_count do local f=sec.slots[i]; if f and f.value.name=='solar-panel' and f.value.quality=='rare' then rare_slot=i end end
  table.remove(ents,2)   -- the epic panel built
  B.tick(600)
  local names={}
  for i=1,sec.filters_count do local f=sec.slots[i]; if f then names[f.value.name..'@'..f.value.quality]=i end end
  eq(names['solar-panel@epic'],nil,'the epic slot cleared'); eq(names['solar-panel@rare'],rare_slot,'the rare slot where it was')

  -- the watch lowers a slot by what the hub spent at that quality, not at another
  held['solar-panel@normal']=0
  B.watch()
  eq(sec.slots[names['solar-panel@rare']].min,2,'normal panels spent: the rare request stands')
  held['solar-panel@rare']=0
  B.watch()
  eq(sec.slots[names['solar-panel@rare']].min,1,'a rare panel spent: lowered by 1')

  -- min_payload by item@quality, or by item for every quality
  r=B.read({force=force},{platform='Solstice',request=true,min_payload={['solar-panel@rare']=1,['asteroid-collector']=1}})
  for i=1,sec.filters_count do local f=sec.slots[i]; if f then names[f.value.name..'@'..f.value.quality]=f end end
  eq(names['solar-panel@rare'].minimum_delivery_count,1); eq(names['asteroid-collector@uncommon'].minimum_delivery_count,1)
  local ok,err=pcall(B.read,{force=force},{platform='Solstice',request=true,min_payload={['solar-panel@shiny']=1}})
  assert(not ok); has(err,'min_payload: unknown quality shiny')

  -- surface: the hub's asks by quality, held at that quality
  sections[1].slots={{value={type='item',name='solar-panel',quality='epic',comparator='='},min=1,import_from='nauvis'}}
  sections[1].filters=sections[1].slots
  r=B.from_surface({force=force},'nauvis')
  eq(r.requests[1].quality,'epic'); eq(r.requests[1].holds,0)
  has(r.lines[1],'solar-panel@epic 1 (asks 1, holds 0)')
  print('d21_batch66 AB1 platform_bom by item and quality: ok')
end
