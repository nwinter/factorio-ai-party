-- Run from repository root: lua tests/d23_batch123.lua
-- (d23 batch123 CF1, viewer Aurora 09:44: "Luna's focus still shows the removed mash prerequisite. Could plan or dependency
-- changes flag stale focus/blocker text and prompt a refresh?") A step edited or removed, a link taken out or a title
-- changed marks the focus and team-plan lines that name what it took away: shown where they show, with the change and
-- when; the change's reply lists them; each one's agent hears it once.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14,
  on_built_entity=15,on_player_mined_entity=16,on_robot_mined_entity=17,on_player_fast_transferred=18,on_gui_opened=19,on_gui_closed=20},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
rendering={draw_text=function() return {valid=true,destroy=function() end} end,get_object_by_id=function() return nil end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surfaces={}
local function character(surface,pos)
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+#surfaces,health=250,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  local inv={get_item_count=function() return 0 end,find_item_stack=function() return nil end,get_contents=function() return {} end}
  c.insert=function(s) return s.count end
  c.get_main_inventory=function() return inv end
  c.get_item_count=function() return 0 end
  c.can_reach_entity=function() return true end
  c.destroy=function() c.valid=false end
  return c
end
local function new_surface(name,index,extra)
  local s={name=name,index=index,valid=true}
  for k,v in pairs(extra) do s[k]=v end
  s.find_non_colliding_position=function(_,origin) return origin end
  s.create_entity=function(args) if args.name=='character' then return character(s,args.position) end return {valid=true,name=args.name,position=args.position} end
  s.can_place_entity=function() return true end
  s.find_entities_filtered=function() return {} end
  s.count_entities_filtered=function() return 0 end
  s.get_total_pollution=function() return 0 end; s.get_chunks=function() return function() end end; s.get_pollution=function() return 0 end
  s.request_path=function() return 1 end
  surfaces[name]=s; surfaces[index]=s
  return s
end
local nauvis=new_surface('nauvis',1,{planet={name='nauvis'}})
local vulcanus=new_surface('vulcanus',2,{planet={name='vulcanus'}})
new_surface('platform-1',3,{platform={name='Peregrine'}})
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=nauvis,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character(nauvis,{x=5,y=5})
local director={index=2,name='pog-director',valid=true,connected=true,controller_type=2,physical_controller_type=2,force=force,surface=nauvis,position={x=50,y=50}}
local players={nick,director}
for _,pl in ipairs(players) do pl.print=function() end end
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) assert(type(i)=='string' or i<=65536,'Given player value is too big'); if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function(n) return surfaces[n] end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function jump(n) tick=tick+n; game.tick=tick end
local function as(name) return function(action,args) return runtime.dispatch{action=action,args=args or {},bot=name} end end
local astra,sol,luna,opus=as('astra'),as('sol'),as('luna'),as('opus')
local names={'astra','sol','luna','opus','kai','grok','mira'}
for _,n in ipairs(names) do runtime.operator.bot_create(n) end
astra('profile',{display_name='Astra',glyph='A',color='#9977ff'})
sol('profile',{display_name='Sol',glyph='S',color='#ffcb45'})
local muse=as('muse')
runtime.operator.bot_create('muse')
local printed={}
nick.print=function(l) printed[#printed+1]=l end
local function op(action,args) return runtime.dispatch{action=action,args=args,operator=true} end
local function has(s,part) assert(type(s)=='string' and s:find(part,1,true),tostring(s)..' lacks '..part) end
-- Luna's case (shift63 16:04-16:10): her focus on #1052 step 8 named the approved mash site; Astra rewrote step 8.
local old8='Verify measured ingredient surplus and an approved safe supplied mash site; build one bounded upstream cell only if both pass, otherwise hold expansion.'
local pj=luna('board_post',{kind='project',title='Fresh agricultural science',steps={'source proof','ghost survey',old8}}).item
local t=astra('board_post',{kind='task',title='Scale fresh agricultural science',parent=pj.id}).item
luna('board_focus',{id=pj.id,step='3: Verify sustained ingredient headroom and Sonnet-approved mash site; otherwise hold.',
  blocker='No safe supplied mash footprint approved.',verify='Revisit build only after site owner approval.'})
luna('board_plan',{doing='#'..pj.id..' hold expansion until an approved mash site exists'})
sol('board_focus',{id=t.id,blocker='waiting on the rail'})
jump(600)
local new8='Increase net egg capacity now using a supplied breeder upgrade, then raise AG load with stock stops.'
local r=astra('board_update',{id=pj.id,edit_step={n=3,text=new8}})
eq(#r.stale,2,'the focus and the plan line')
has(r.stale[1],"luna's focus on #"..pj.id..' marked stale 0s ago: step 3 of #'..pj.id..' edited by astra (was: "Verify measured')
has(r.stale[1],'this text names approved, hold, ingredient, mash, otherwise, site, verify, safe, build')
has(r.stale[2],"luna's team-plan line marked stale 0s ago: step 3 of #"..pj.id..' edited by astra')
has(r.stale[2],'this text names approved, expansion, hold, mash, site')
-- where it shows: her status, the focus read's rows, the plan
jump(120)
local st=luna('status')
has(st.focus,'blocker: No safe supplied mash footprint approved.; next verification: Revisit build only after site owner approval.; marked stale 2s ago: step 3 of #'..pj.id)
local fr=astra('board_focus',{agent='luna'})
has(fr.rows[1].stale,'marked stale 2s ago: step 3'); eq(fr.rows[1].stale_tick,tick-120)
local pv=astra('board_plan',{})
has(pv.plan.doing[1],'[marked stale 2s ago: step 3 of #'..pj.id)
-- Sol's focus on the task names none of it: unmarked
eq(runtime.progress.focus_row('sol').stale,nil)
-- Luna hears it once (her status reply above carried it in her team alerts), Astra (who made it) does not
local function alerts(who)
  local got={}
  for _,l in ipairs(runtime.progress.lines({index=0,name=who},{}) or {}) do got[#got+1]=l end
  return got
end
local la={}
for _,l in ipairs((st.team or {}).alerts or {}) do if l:find('marked stale',1,true) then la[#la+1]=l end end
eq(#la,2); has(la[1],'your focus on #'..pj.id..' is marked stale'); has(la[1],'the mark stays until board_focus {id} sets a focus')
has(la[2],'your team-plan line is marked stale'); has(la[2],'the mark stays until board_plan {doing} sets the line')
for _,l in ipairs((luna('status').team or {}).alerts or {}) do assert(not l:find('marked stale',1,true),l) end
eq(#alerts('astra'),0)
-- a new focus and a new line end the marks
luna('board_focus',{id=pj.id,step=3})
eq(runtime.progress.focus_row('luna').stale,nil)
luna('board_plan',{doing='#'..pj.id..' egg capacity first'})
eq(astra('board_plan',{}).plan.doing[1],'luna: #'..pj.id..' egg capacity first')
-- a dependency taken out: a blocker naming #id is marked; a removed focused step is marked by its number
local dep=astra('board_post',{kind='task',title='Mash cell scaffold'}).item
local t2=sol('board_post',{kind='task',title='Bioflux line',blocked_by=dep.id}).item
sol('board_focus',{id=t2.id,blocker='#'..dep.id..' first'})
r=sol('board_update',{id=t2.id,blocked_by={}})
eq(#r.stale,1); has(r.stale[1],'your focus on #'..t2.id..' marked stale 0s ago: #'..dep.id..' taken out of the blocked_by of #'..t2.id..' by sol (was: "Mash cell scaffold"); this text names #'..dep.id)
eq(#alerts('sol'),0,'the one who made the change reads it in the reply')
r=astra('board_update',{id=pj.id,remove_step=3})
has(r.stale[1],"luna's focus on #"..pj.id..' marked stale 0s ago: step 3 of #'..pj.id..' removed by astra (was: "'..new8..'"); this text names step 3')
-- an edit that leaves the words: no mark
luna('board_focus',{id=pj.id,step=1,blocker='source proof pending'})
r=luna('board_update',{id=pj.id,edit_step={n=1,text='source proof, pending the clean window'}})
eq(r.stale,nil)

-- (d23 batch123 CF2, viewer Aurora 09:45: "Could measurement watches flag module or feed edits during a test and mark the
-- sample as mixed?") An edit inside what a running watch measures splits its window: the read before kept, the watch
-- started again from the edit to its end tick, its owner told once; an edit elsewhere leaves it.
do
  local world={}
  local function ent(name,typ,x,y,extra)
    local e={valid=true,name=name,type=typ,position={x=x,y=y},unit_number=9000+#world,force=force,surface=nauvis,quality={name='normal'},
      bounding_box={left_top={x=x-1,y=y-1},right_bottom={x=x+1,y=y+1}}}
    for k,v in pairs(extra or {}) do e[k]=v end
    world[#world+1]=e
    return e
  end
  nauvis.find_entities_filtered=function(f)
    local out={}
    for _,e in ipairs(world) do
      if e.valid then
        local q=f.position and {x=f.position.x or f.position[1],y=f.position.y or f.position[2]}
        local ok=true
        if q and f.radius then ok=((e.position.x-q.x)^2+(e.position.y-q.y)^2)^0.5<=f.radius
        elseif q then ok=q.x>=e.bounding_box.left_top.x and q.x<=e.bounding_box.right_bottom.x and q.y>=e.bounding_box.left_top.y and q.y<=e.bounding_box.right_bottom.y end
        if f.name and f.name~=e.name then ok=false end
        if ok then out[#out+1]=e end
      end
    end
    return out
  end
  local t1=ent('gun-turret','ammo-turret',10,10,{kills=0,damage_dealt=0})
  local t2=ent('gun-turret','ammo-turret',14,10,{kills=0,damage_dealt=0})
  local function advance(n) for _=1,n do jump(1); runtime.tick{tick=tick} end end
  local ai=runtime.bots.index_of('astra')
  local S=storage.agent_harness
  eq(runtime.mixed.edit(t1,'configure by sol'),0,'no watch running: nothing')
  local r=astra('turret_tally',{positions={{x=10,y=10},{x=14,y=10}},seconds=60})
  eq(r.watching,true)
  local job=S.turret_tally[ai]; eq(job.call.action,'turret_tally'); eq(job.call.args.seconds,60)
  local start=job.start
  advance(600); t1.kills=3; t1.damage_dealt=40; advance(300)
  -- an inserter feeding t1, far from the other: built by Sol's call (the harness build) splits it
  local feeder=ent('inserter','inserter',10,12.2,{drop_position={x=10,y=10.6},pickup_position={x=10,y=13.2}})
  local edit_tick=tick
  eq(runtime.mixed.edit(feeder,'built by sol'),1)
  local new=S.turret_tally[ai]
  assert(new~=job,'started again'); eq(new.start,edit_tick); eq(new.until_tick,job.until_tick); eq(new.call.args.seconds,60,'the first arguments')
  eq(new.mixed.parts[1].from_tick,start); eq(new.mixed.parts[1].to_tick,edit_tick)
  has(new.mixed.parts[1].line,'watching 2 turrets for 15s of 60s: 1 with a change in kills or damage dealt, 1 without; kills +3')
  has(new.mixed.edits[1].text,'built by sol on inserter (10,12.2)'); eq(new.mixed.edits[1].how,'feeds what it measures')
  has(new.mixed.line,'mixed: 1 edit during the window, the first at tick '..edit_tick..' (built by sol on inserter (10,12.2), feeds what it measures); the read up to tick '..edit_tick..' is kept apart (mixed.parts); this window runs from tick '..edit_tick)
  -- the read carries it; the status work row too; astra hears it once
  local rd=astra('turret_tally',{})
  eq(rd.mixed.line,new.mixed.line); eq(rd.mixed.parts[1].to_tick,edit_tick); has(rd.line,'watching 2 turrets for 0s of 45s')
  local function alerts(who)
    local got={}
    for _,l in ipairs(runtime.mixed.lines({index=0,name=who},{}) or {}) do got[#got+1]=l end
    return got
  end
  local al={}
  for _,l in ipairs((rd.team or {}).alerts or {}) do if l:find('mixed',1,true) then al[#al+1]=l end end
  eq(#al,1); has(al[1],'your turret_tally watch (started tick '..start..'): mixed: 1 edit'); eq(#alerts('astra'),0,'once')
  local w=runtime.measures.list(ai)[1]; has(w.line,'; mixed: 1 edit'); has(w.mixed,'mixed: 1 edit')
  -- elsewhere: an inserter dropping into nothing it measures, an enemy's death, the same change seen twice
  local far=ent('inserter','inserter',30,30,{drop_position={x=30,y=31},pickup_position={x=30,y=29}})
  eq(runtime.mixed.edit(far,'built by sol'),0)
  eq(runtime.mixed.edit(feeder,'built by sol'),0,'the call and its event split once')
  local bug=ent('small-biter','unit',10,10,{force={name='enemy'}})
  runtime.on_event{name=defines.events.on_entity_died,entity=bug,tick=tick}
  eq(S.turret_tally[ai],new)
  -- a measured turret destroyed (the event): the new start is refused (it is gone), so the watch ends at the edit
  advance(120)
  t2.valid_before=true
  runtime.on_event{name=defines.events.on_entity_died,entity=t2,tick=tick}
  local after=S.turret_tally[ai]
  eq(after,new,'not started again'); eq(after.until_tick,tick); eq(after.mixed.ended,'gun-turret (14,10) it measured is gone')
  has(after.mixed.edits[2].text,'destroyed on gun-turret (14,10)'); eq(after.mixed.edits[2].how,'what it measures')
  t2.valid=false
  advance(2)
  local fin=astra('turret_tally',{})
  eq(fin.done,true); has(fin.mixed.line,'mixed: 2 edits during the window'); has(fin.mixed.line,'the watch ended at the edit (gun-turret (14,10) it measured is gone): its final is the part before it')
end

-- (d23 batch123 CF3, viewer Aurora 09:47: "Could disabling a freight request or retiring a route flag any essential supply
-- left without an active delivery path, naming the missing link and owner? Please test the bioflux case.")
do
  local function sec(filters,active) return {active=active~=false,filters=filters} end
  defines.logistic_member_index={space_platform_hub_requester=3}
  local function hub(unit,sections)
    return {valid=true,unit_number=unit,get_logistic_sections=function() return {sections_count=#sections,get_section=function(i) return sections[i] end} end,
      -- the game's compiled requests: the active sections' items, no import planet
      get_logistic_point=function(i) assert(i==3)
        local fl={}
        for _,x in ipairs(sections) do if x.active then for _,f in ipairs(x.filters) do fl[#fl+1]={name=f.value.name,count=f.min} end end end
        return {filters=fl} end}
  end
  local function plat(name,stops,h) local recs={}; for i,s in ipairs(stops) do recs[i]={station=s} end; return {valid=true,name=name,hub=h,schedule={records=recs}} end
  local mv_bio=sec({{value={name='bioflux'},min=200,import_from={name='gleba'}},{value={name='agricultural-science-pack'},min=1000,import_from={name='gleba'}}})
  local mv=plat('Meridian-V',{'gleba','nauvis'},hub(501,{mv_bio}))
  local other=plat('Sunward',{'nauvis','vulcanus'},hub(502,{sec({{value={name='tungsten-plate'},min=100,import_from={name='vulcanus'}}})}))
  local nauvis_pad=sec({{value={name='bioflux'},min=100},{value={name='agricultural-science-pack'},min=500},{value={name='tungsten-plate'},min=50}})
  local asks={nauvis={sec=nauvis_pad},gleba={sec=sec({})},vulcanus={sec=sec({})}}
  local frc={platforms={mv,other},get_item_production_statistics=function() return {get_flow_count=function(f) return f.name=='bioflux' and 1212 or 0 end} end}
  game.planets={nauvis={surface={name='nauvis'}},gleba={surface={name='gleba'}},vulcanus={surface={name='vulcanus'}}}
  local edits={['req:900']={{by='luna',tick=100}},['req:501']={{by='sol',tick=200}},['plat:Meridian-V']={{by='sol',tick=150,key='schedule stops'}}}
  local told={}
  local FP=dofile('mod/agent-harness_0.1.0/freightpath.lua'){
    pads=function(planet) local a={}; local x=asks[planet].sec; if x.active then for _,f in ipairs(x.filters) do a[f.value.name]=f.min end end; return a,{bioflux=planet=='nauvis' and 40 or 0} end,
    census_typed=function(_,s) return s.name=='nauvis' and {{valid=true,unit_number=900}} or {} end,
    owner=function(scope,key,t) local l=edits[scope]; local e=l and l[#l]; return e and e.tick<t and e or nil end,
    who=function(p) return p.name end,index_of=function(n) return n=='luna' and 7 or n=='sol' and 8 or nil end,
    deliver=function(i,t) told[#told+1]={i,t} end}
  local ALL={bioflux=true,['agricultural-science-pack']=true,['tungsten-plate']=true}
  local function paths() return FP.paths(FP.snapshot(frc,ALL)) end
  local P=paths()
  eq(#P['bioflux|nauvis'],1); eq(P['bioflux|nauvis'][1].platform,'Meridian-V'); eq(#P['tungsten-plate|nauvis'],1)
  eq(P['bioflux|gleba'],nil,'gleba asks none')
  -- the bioflux case: Nauvis's pad section is turned off by Astra
  local me={name='astra',force=frc}
  local before=FP.snapshot(frc,ALL)
  eq(FP.before(me,'platform_schedule',{platform='x'}),nil,'no such platform')
  eq(FP.before(me,'platform_schedule',{platform='Meridian-V'}).focus['agricultural-science-pack'],true,'what its hub asks')
  nauvis_pad.active=false
  local out={}
  FP.after(me,'requests',{},out,before)
  eq(#out.supply_left,3,'bioflux, the science and tungsten lost their pull at nauvis')
  eq(out.supply_left[2],"bioflux to nauvis: no active delivery path left; it had Meridian-V from gleba; nauvis's landing pad no longer requests bioflux (set last by luna at tick 100); nauvis used 1212 in the last 10 minutes; nauvis holds 40 in its landing pad")
  eq(#told,1); eq(told[1][1],7); has(told[1][2].text,"astra's requests left supply without an active delivery path: agricultural-science-pack to nauvis")
  eq(out.supply_left_told[1],'luna')
  nauvis_pad.active=true
  -- Meridian-V's hub stops asking bioflux from gleba (Sol set it last; Sol makes the change: no tell)
  told={}
  before=FP.before({name='sol',force=frc},'requests',{platform='Meridian-V',set={}})
  eq(before.focus['tungsten-plate'],nil)
  mv_bio.filters[1].min=0
  out={}
  FP.after({name='sol',force=frc},'requests',{},out,before)
  eq(#out.supply_left,1)
  eq(out.supply_left[1],"bioflux to nauvis: no active delivery path left; it had Meridian-V from gleba; Meridian-V's hub no longer requests bioflux from gleba (set last by sol at tick 200); nauvis used 1212 in the last 10 minutes; nauvis holds 40 in its landing pad")
  eq(#told,0,'the one who set it made the change')
  mv_bio.filters[1].min=200
  -- a second platform carrying bioflux from gleba: dropping Meridian-V's nauvis stop leaves a path, so no line for it
  local twin=plat('Twin',{'gleba','nauvis'},hub(503,{sec({{value={name='bioflux'},min=50,import_from={name='gleba'}}})}))
  frc.platforms={mv,other,twin}
  before=FP.snapshot(frc,ALL)
  mv.schedule={records={{station='gleba'}}}
  out={}
  FP.after(me,'platform_schedule',{},out,before)
  eq(#out.supply_left,1); has(out.supply_left[1],"agricultural-science-pack to nauvis: no active delivery path left; it had Meridian-V from gleba; Meridian-V's schedule no longer stops at nauvis (set last by sol at tick 150)")
  -- a read or a chest's requests: nothing read
  eq(FP.before(me,'requests',{platform='Meridian-V'}),nil); eq(FP.before(me,'requests',{set={},dry_run=true}),nil)
  -- a platform deleted
  mv.schedule={records={{station='gleba'},{station='nauvis'}}}
  before=FP.snapshot(frc,ALL)
  mv.scheduled_for_deletion=120
  out={}
  FP.after(me,'platform_delete',{},out,before)
  has(out.supply_left[1],'agricultural-science-pack to nauvis: no active delivery path left; it had Meridian-V from gleba; Meridian-V is gone (deleted) (no earlier editor recorded)')
end

-- (d23 batch123 CF4, operator 10:25: Sol's observe scans of Asterion, 96 ms a call on world n) a scan lists 256 rows a
-- call in reading order, page continues; the inventory field reads only the inventories an entity's type takes, the
-- same text as before.
do
  local chests={}
  local function chest(x,y,n)
    local inv={valid=true,get_contents=function() return n>0 and {{name='iron-plate',count=n,quality='normal'}} or {} end}
    local e={valid=true,name='wooden-chest',type='container',position={x=x,y=y},unit_number=7000+#chests,force=force,surface=nauvis,
      get_inventory=function(i) if i==defines.inventory.chest then return inv end end}
    chests[#chests+1]=e
    return e
  end
  defines.inventory.chest=defines.inventory.chest or 1
  for i=1,300 do chest(100+(i-1)%20+0.5,100+math.floor((i-1)/20)+0.5,i%7) end
  local saved=nauvis.find_entities_filtered
  nauvis.find_entities_filtered=function(f) if f.area then return chests end return {} end
  local area={left_top={x=99,y=99},right_bottom={x=121,y=116}}
  local r1=astra('scan',{area=area,fields='inventory',limit=1024})
  eq(#r1.entities,256); eq(r1.page,1); eq(r1.pages,2); eq(r1.rows,'1..256 of 300'); eq(r1.total,300)
  eq(r1.more.rows,44); eq(r1.more.next.page,2); has(r1.more.line,'rows 1..256 of the 300 kept are listed (256 a call, reading order); page 2 lists the next')
  eq(r1.entities[1].position.y,100.5); eq(r1.entities[1].inventory,'iron-plate*1'); eq(r1.entities[7].inventory,'empty')
  local r2=astra('scan',{area=area,fields='inventory',limit=1024,page=2})
  eq(#r2.entities,44); eq(r2.more,nil); eq(r2.rows,'257..300 of 300'); eq(r2.entities[44].position.x,119.5); eq(r2.entities[44].position.y,114.5)
  local r3=astra('scan',{area=area,limit=100})
  eq(#r3.entities,100); eq(r3.page,nil,'one page: as before'); eq(r3.truncated,true)
  local ok,err=pcall(astra,'scan',{area=area,page=3,limit=1024})
  assert(not ok and tostring(err):find('page 3: this scan keeps 300 rows, 2 pages of 256',1,true),tostring(err))
  nauvis.find_entities_filtered=saved
end
print('d23_batch123: ok')
