-- Run from the harness root: lua tests/d17_batch19.lua
-- d17 batch19 module contracts (the runtime ones are in tests/d17_batch19_rt.lua).
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..'\n  lacks: '..part) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path

-- A3 (Astra: Swiftlet's 34 efficiency and 2 speed modules were in no BOM line; a manager restart sent duplicate
-- hardware): module requests on ghosts and on built machines' proxies count, and what construction robots carry (taken
-- from the hub for ghosts not built yet) is not asked again.
do
  game={tick=0,forces={},surfaces={}}
  defines={inventory={hub_main=1,robot_cargo=2,cargo_unit=3}}
  prototypes={space_location={nauvis={}},item={}}
  local furnace={name='electric-furnace',items_to_place_this={{name='electric-furnace',count=1}}}
  local fast={name='fast-inserter',items_to_place_this={{name='fast-inserter',count=1}}}
  local ents={
    {type='entity-ghost',ghost_name='electric-furnace',ghost_prototype=furnace,item_requests={{name='efficiency-module',count=2}}},
    {type='entity-ghost',ghost_name='electric-furnace',ghost_prototype=furnace,
      insert_plan={{id={name='efficiency-module'},items={in_inventory={{inventory=4,stack=0,count=1},{inventory=4,stack=1,count=1}}}}}},
    {type='item-request-proxy',item_requests={{name={name='speed-module'},count=2}}},   -- a built crusher's modules
  }
  for i=1,6 do ents[#ents+1]={type='entity-ghost',ghost_name='fast-inserter',ghost_prototype=fast} end
  local robots={{type='construction-robot',get_inventory=function() return {get_contents=function() return {{name='fast-inserter',count=2}} end} end}}
  local function find(f)
    local want={}
    for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do want[t]=true end
    local out={}
    for _,e in ipairs(ents) do if want[e.type] then out[#out+1]=e end end
    if want['construction-robot'] then for _,r in ipairs(robots) do out[#out+1]=r end end
    return out
  end
  local sections={}
  local secs={sections_count=0}
  secs.get_section=function(i) return sections[i] end
  secs.add_section=function(g)
    local sec={group=g,slots={},filters_count=0}
    sec.set_slot=function(i,x) sec.slots[i]=x; sec.filters_count=math.max(sec.filters_count,i) end
    sec.clear_slot=function(i) sec.slots[i]=nil end
    sections[#sections+1]=sec; secs.sections_count=#sections; return sec
  end
  secs.remove_section=function(i) table.remove(sections,i); secs.sections_count=#sections end
  local held={['fast-inserter']=4}
  local hub={valid=true,get_logistic_sections=function() return secs end,
    get_inventory=function() return {get_item_count=function(n) return held[n] or 0 end} end}
  local pl={valid=true,index=7,name='Swiftlet',hub=hub,space_location={name='nauvis'},surface={find_entities_filtered=find,count_entities_filtered=function() return 0 end}}
  local force={name='player',platforms={pl}}
  pl.force=force
  game.forces={player=force}
  local st={}
  local B=dofile('mod/agent-harness_0.1.0/platbom.lua'){platform=function() return pl end,state=function() return st end,
    cargo={limits=function() return 1000000,40 end,weigh=function() return {total_kg=1,fewest=1} end}}
  -- the read: modules counted, robots' cargo taken off what is still to send
  local r=B.read({force=force},{platform='Swiftlet'})
  local row={}
  for _,x in ipairs(r.items) do row[x.item]=x end
  eq(row['efficiency-module'].ghosts_need,4); eq(row['efficiency-module'].requests,4)
  eq(row['speed-module'].ghosts_need,2)
  eq(row['fast-inserter'].in_robots,2); eq(row['fast-inserter'].remaining,0,'6 needed: 4 in the hub, 2 in robots')
  local line
  for _,l in ipairs(r.lines) do if l:find('^fast%-inserter') then line=l end end
  has(line,'fast-inserter: ghosts need 6 (0 built); hub holds 4, construction robots carry 2; covered')
  -- the request manager: what robots carry is not asked again; modules are asked
  r=B.read({force=force},{platform='Swiftlet',request=true})
  local slot={}
  for _,f in pairs(sections[1].slots) do slot[f.value.name]=f.min end
  eq(slot['fast-inserter'],4,'6 the ghosts need less 2 in robots'); eq(slot['efficiency-module'],4); eq(slot['speed-module'],2)
  for _,l in ipairs(r.lines) do if l:find('^fast%-inserter') then line=l end end
  has(line,'fast-inserter: request 4 from nauvis (the ghosts need 6, construction robots carry 2; the hub holds 4)')
  -- the ghosts built, the crusher's modules still asked: the section stays for them
  for i=#ents,1,-1 do if ents[i].type=='entity-ghost' then table.remove(ents,i) end end
  robots={}
  B.tick(600)
  eq(#sections,1); slot={}
  for _,f in pairs(sections[1].slots) do slot[f.value.name]=f.min end
  eq(slot['speed-module'],2); eq(slot['fast-inserter'],nil)
  ents={}
  B.tick(1200); eq(#sections,0,'removed with the last request')
  defines,prototypes=nil,nil
end
print('d17_batch19 A3 platform_bom counts module requests and what robots carry: ok')
