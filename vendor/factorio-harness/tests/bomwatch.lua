-- platform_bom request watch (batch27 A3, Sol: the keeper's 10 s rewrite launched a full stack after ghosts used hub
-- stock: 200 pipes, extra modules): a drop in what the hub holds of an item the section asks for lowers that request
-- by as much the same tick; the rewrite then counts the ghosts again in full.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or '')..' '..tostring(a)..' ~= '..tostring(b)) end
game={tick=0,forces={}}
defines={inventory={hub_main=1}}
prototypes={space_location={fulgora={}},item={['transport-belt']={}}}
local ghosts={}
local belt={name='transport-belt',items_to_place_this={{name='transport-belt',count=1}}}
for i=1,5 do ghosts[i]={type='entity-ghost',ghost_name='transport-belt',ghost_prototype=belt} end
local sections,writes={},0
local function section(group)
  local sec={group=group,slots={}}
  sec.filters_count=0
  sec.set_slot=function(i,f) writes=writes+1; sec.slots[i]=f; sec.filters_count=math.max(sec.filters_count,i) end
  sec.get_slot=function(i) return sec.slots[i] end
  sec.clear_slot=function(i) sec.slots[i]=nil end
  return sec
end
local secs={sections_count=0}
secs.get_section=function(i) return sections[i] end
secs.add_section=function(g) sections[#sections+1]=section(g); secs.sections_count=#sections; return sections[#sections] end
secs.remove_section=function(i) table.remove(sections,i); secs.sections_count=#sections end
local held=5
local hub={valid=true,get_logistic_sections=function() return secs end,
  get_inventory=function() return {get_item_count=function(n) return n=='transport-belt' and held or 0 end} end}
local pl={valid=true,index=5,name='Meridian',hub=hub,space_location={name='fulgora'},
  surface={find_entities_filtered=function(f) if f.type=='construction-robot' then return {} end return ghosts end}}
local force={name='player',platforms={pl}}
pl.force=force; game.forces={player=force}
local st={}
local B=dofile('mod/agent-harness_0.1.0/platbom.lua'){platform=function() return pl end,state=function() return st end}
B.read({force=force},{platform='Meridian',request=true})
local slot=sections[1].slots[1]
eq(slot.min,5,'the ghosts need 5')
-- nothing spent: nothing written
local before=writes
B.watch(); eq(writes,before,'no drop, no write')
-- the hub spends 3 on ghosts: the request goes to 2 the same tick, its other fields kept
held=2; B.watch()
eq(sections[1].slots[1].min,2,'lowered by what the hub spent'); eq(sections[1].slots[1].import_from,'fulgora')
-- stock arriving raises nothing
held=4; B.watch(); eq(sections[1].slots[1].min,2)
-- the ghosts built: the rewrite counts 2 left and says what the watch did
table.remove(ghosts); table.remove(ghosts); table.remove(ghosts)
local r=B.read({force=force},{platform='Meridian',request=true})
eq(sections[1].slots[1].min,2)
assert(r.lines[1]:find('lowered at once by 3 since the last rewrite as the hub spent it',1,true),r.lines[1])
-- a removed section: the watch writes nothing
for i=#ghosts,1,-1 do table.remove(ghosts) end
B.tick(600)
eq(#sections,0); held=0; B.watch()
print('bomwatch: ok')
