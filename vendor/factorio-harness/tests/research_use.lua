-- Research/use facts: no entity queries, full loadouts, per-planet census counts, live engine vehicle counters.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local n=0
local function eq(a,b) n=n+1; assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,part) n=n+1; assert(s:find(part,1,true),s..' lacks '..part) end
local function no(s,part) n=n+1; assert(not s:find(part,1,true),s..' contains '..part) end
local function no_scan() error('no surface/entity scans in research/use facts') end
game={tick=6000,surfaces={{find_entities_filtered=no_scan,count_entities_filtered=no_scan}}}
prototypes={item={},entity={}}
local force={name='player',technologies={},recipes={}}
local function item(name,kind,entity_type)
  local p={name=name,type=kind or 'item'}; prototypes.item[name]=p
  if entity_type then p.place_result={name=name,type=entity_type}; prototypes.entity[name]=p.place_result end
  return p
end
local function unlock(tech,name,done)
  force.technologies[tech]={researched=done,prototype={effects={{type='unlock-recipe',recipe='make-'..name}}}}
  force.recipes['make-'..name]={products={{type='item',name=name}}}
end
item('light-armor','armor'); item('modular-armor','armor'); item('power-armor-mk2','armor'); item('mech-armor','armor')
item('energy-shield-equipment').place_as_equipment_result={name='energy-shield-equipment'}
item('energy-shield-mk2-equipment').place_as_equipment_result={name='energy-shield-mk2-equipment'}
item('pistol','gun'); item('submachine-gun','gun'); item('firearm-magazine','ammo'); item('piercing-rounds-magazine','ammo')
item('iron-plate')
unlock('power-armor-mk2','power-armor-mk2',true); unlock('mech-armor','mech-armor',false)
unlock('shield-mk2','energy-shield-mk2-equipment',true); unlock('military','submachine-gun',true)
unlock('military-2','piercing-rounds-magazine',true)
for _,name in ipairs{'stone-furnace','steel-furnace','electric-furnace'} do item(name,'item','furnace') end
for _,name in ipairs{'burner-mining-drill','electric-mining-drill','big-mining-drill'} do item(name,'item','mining-drill') end
for _,name in ipairs{'transport-belt','fast-transport-belt','express-transport-belt','turbo-transport-belt'} do item(name,'item','transport-belt') end
for _,name in ipairs{'assembling-machine-1','assembling-machine-2','assembling-machine-3'} do item(name,'item','assembling-machine') end
unlock('advanced-material-processing-2','electric-furnace',true)
unlock('big-mining-drill','big-mining-drill',true); unlock('logistics-2','fast-transport-belt',true)
unlock('automation-3','assembling-machine-3',true)
item('car','item','car'); item('tank','item','car'); item('spidertron','item','spider-vehicle')
unlock('automobilism','car',true); unlock('tank','tank',true); unlock('spidertron','spidertron',false)
local calls={}
force.get_entity_count=function(name) calls[#calls+1]=name; return name=='car' and 2 or 0 end
local rows={}
for i=1,7 do rows[i]={alive=true,armor_known=true,equipment_known=true,guns_known=true,ammo_known=true,
  armor={name=i==7 and 'light-armor' or 'modular-armor',equipment={{name='energy-shield-equipment',count=2}}},
  guns={{name='pistol',count=1},false},ammo={{name='firearm-magazine',count=10}},carried={
    {name='iron-plate',count=10000},{name='power-armor-mk2',count=1,quality='rare'},
    {name='submachine-gun',count=1},{name='piercing-rounds-magazine',count=20}}} end
rows[#rows+1]={alive=false}
local counts={[1]={surface='nauvis',entities={['stone-furnace']=140,['steel-furnace']=60,['electric-mining-drill']=30}},
  [2]={surface='fulgora',entities={['electric-furnace']=12,['fast-transport-belt']=50,['assembling-machine-3']=3}}}
local asof=3000
local R=require('research_use'){loadout=function(f) eq(f,force); return {agents=rows,force_unknown=1} end,
  buildings=function(f) eq(f,force); return counts,asof end}
local lines=R.lines(force)
eq(#lines,2); has(lines[1],'7 bodies, 1 without body'); has(lines[1],'1 agents with unknown force')
has(lines[1],'armor researched: power-armor-mk2'); no(lines[1],'mech-armor')
has(lines[1],'worn: light-armor x1, modular-armor x6'); has(lines[1],'fitted in armor: energy-shield-equipment x14')
has(lines[1],'equipment researched: energy-shield-mk2-equipment'); has(lines[1],'gun researched: submachine-gun')
has(lines[1],'gun slots: pistol x7'); has(lines[1],'carried gun: submachine-gun x7')
has(lines[1],'ammo slots: firearm-magazine x70'); has(lines[1],'carried ammo: piercing-rounds-magazine x140')
has(lines[1],'carried armor: power-armor-mk2 x7'); no(lines[1],'iron-plate')
has(lines[2],'census 50s old'); has(lines[2],'stone-furnace 140, steel-furnace 60, electric-furnace 0')
has(lines[2],'fulgora: stone-furnace 0, steel-furnace 0, electric-furnace 12')
has(lines[2],'burner-mining-drill 0, electric-mining-drill 30, big-mining-drill 0')
has(lines[2],'transport-belt 0, fast-transport-belt 50, express-transport-belt 0, turbo-transport-belt 0')
has(lines[2],'assembling-machine-1 0, assembling-machine-2 0, assembling-machine-3 3')
has(lines[2],'vehicles researched / built (force engine counts now): car 2, tank 0'); no(lines[2],'spidertron')
eq(#calls,2); eq(calls[1],'car'); eq(calls[2],'tank')
for _,line in ipairs(lines) do no(line,'\n'); for _,word in ipairs{'consider','should','recommend','replace','upgrade'} do no(line,word) end end
-- Cached prototype mapping must still observe newly finished research, and never invent zero from missing data.
force.technologies.spidertron.researched=true; force.technologies['mech-armor'].researched=true
lines=R.lines(force); has(lines[1],'mech-armor, power-armor-mk2'); has(lines[2],'spidertron 0')
counts=nil; lines=R.lines(force); has(lines[2],'planet counts unknown'); no(lines[2],'stone-furnace 0')
rows={{alive=true,carried=nil}}; lines=R.lines(force)
has(lines[1],'worn: unknown; 1 unread agent inventories'); has(lines[1],'carried ammo: unknown')
force.get_entity_count=function() error('counter unavailable') end
has(R.lines(force)[2],'car unknown')
local unavailable=require('research_use'){loadout=function() error('no loadout') end,buildings=function() end}
has(unavailable.lines(force)[1],'loadout unavailable'); has(unavailable.lines(force)[1],'power-armor-mk2')
-- Every force uses its own research and counts, including after another force populated the mapping.
local other={name='other',technologies={},recipes={},get_entity_count=no_scan}
local otherR=require('research_use'){loadout=function(f) eq(f,other); return {agents={}} end,buildings=no_scan}
lines=otherR.lines(other); has(lines[1],'armor researched: none'); has(lines[2],'no researched successor')
eq(lines[2]:find('census',1,true),nil)
-- The actual census collects different planets and zero rows in its existing walk, never platform entities/ghosts.
defines={entity_status={}}
local surfaces={{index=1,name='gleba'},{index=2,name='fulgora'},{index=3,name='empty-planet'},
  {index=4,name='platform-1',platform={}}}
for _,s in ipairs(surfaces) do s.find_entities_filtered=no_scan; s.count_entities_filtered=no_scan end
game.surfaces=surfaces; game.forces={player=force}; game.get_surface=function(i) return surfaces[i] end
local function entity(name)
  return {valid=true,name=name,type=prototypes.entity[name].type,get_recipe=function() end,status=0}
end
local entities={{entity('stone-furnace'),entity('steel-furnace'),{valid=true,type='entity-ghost',name='entity-ghost'}},
  {entity('electric-furnace'),entity('fast-transport-belt')},{},{entity('electric-furnace')}}
local st,seen,walks={},{},0
local C=require('census'){state=function() return st end,walk={every=function() return 1 end,due=function() return true end,
  start=function() return {} end,band=function(_,s) walks=walks+1;if not seen[s.index] then seen[s.index]=true;return entities[s.index] end end}}
C.tick(10000)
for tick=10001,10030 do
  C.tick(tick)
  if st.census.job.stage~='walk' then break end
end
eq(C.buildings(force),nil);eq(walks,8)
st.census.job.stage='done';C.tick(10031)
local built,at=C.buildings(force)
eq(at,10000);eq(built[1].entities['stone-furnace'],1);eq(built[1].entities['electric-furnace'],nil)
eq(built[2].entities['electric-furnace'],1);eq(built[2].entities['fast-transport-belt'],1)
eq(next(built[3].entities),nil);eq(built[4],nil);eq(built[1].entities['entity-ghost'],nil)
print('research_use: '..n..' assertions passed')
