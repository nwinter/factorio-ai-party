-- d17 batch11 (operator 01:55, agents' requests at the 01:50 poll). Run from the harness root: lua tests/d17_batch11.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- A6 (Sol 01:50: a fixed request kept refilling the hub after the build): a hub section asking what the ghosts still
-- need, lowered as they are built, removed with the last.
do
  game={tick=0,forces={}}
  defines={inventory={hub_main=1}}
  prototypes={space_location={fulgora={}},item={}}
  local ghosts={}
  local belt={name='transport-belt',items_to_place_this={{name='transport-belt',count=1}}}
  for i=1,5 do ghosts[i]={type='entity-ghost',ghost_name='transport-belt',ghost_prototype=belt} end
  local sections={}
  local function section(group)
    local sec={group=group,slots={}}
    sec.filters_count=0
    sec.set_slot=function(i,f) sec.slots[i]=f; sec.filters_count=math.max(sec.filters_count,i) end
    sec.clear_slot=function(i) sec.slots[i]=nil end
    return sec
  end
  local secs={}
  secs.sections_count=0
  secs.get_section=function(i) return sections[i] end
  secs.add_section=function(g) sections[#sections+1]=section(g); secs.sections_count=#sections; return sections[#sections] end
  secs.remove_section=function(i) table.remove(sections,i); secs.sections_count=#sections end
  local hub={valid=true,get_logistic_sections=function() return secs end,get_inventory=function() return {get_item_count=function() return 0 end} end}
  local pl={valid=true,index=5,name='Meridian',hub=hub,space_location={name='fulgora'},surface={find_entities_filtered=function() return ghosts end}}
  local force={name='player',platforms={pl}}
  pl.force=force
  game.forces={player=force}
  local st={}
  local B=dofile('mod/agent-harness_0.1.0/platbom.lua'){platform=function() return pl end,state=function() return st end}
  local r=B.read({force=force},{platform='Meridian',request=true})
  eq(r.request,'set'); eq(#sections,1); eq(sections[1].group,'platform_bom: Meridian'); eq(sections[1].slots[1].min,5); eq(sections[1].slots[1].import_from,'fulgora')
  has(r.lines[1],'transport-belt: request 5 from fulgora (the ghosts need 5; the hub holds 0)')
  table.remove(ghosts); table.remove(ghosts)
  B.tick(600); eq(sections[1].slots[1].min,3,'lowered as ghosts are built')
  ghosts={}
  B.tick(1200); eq(#sections,0,'removed with the last ghost'); eq(next(st.bom_requests),nil)
  defines,prototypes=nil,nil
end
print('d17_batch11 A6 hub request kept to the ghosts: ok')
