-- Run from the harness root: lua tests/d28_batch303.lua
-- d28 batch303 RQ (Sol #2665, 03:56: "inspect's recipe only reports the bare recipe name; the full JSON of the Needle
-- crusher (-6,0.5) has no recipe_quality despite an active legendary recipe. Compact N/V reads led two agents to
-- mistakenly diagnose normal plastic."). A crafting machine's recipe quality, apart from its own quality: inspect (full,
-- positions, compact, area rows), scan (recipe, status, output), the rate line and bottleneck. Cases: a legendary recipe
-- in a normal machine, a normal recipe in a legendary machine, furnaces (running, idle), ghosts.
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
local force={name='player',inserter_stack_size_bonus=2,bulk_inserter_capacity_bonus=11,chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
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
defines.entity_status={working=1,item_ingredient_shortage=2}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function jump(n) tick=tick+n; game.tick=tick end
local function as(name) return function(action,args) return runtime.dispatch{action=action,args=args or {},bot=name} end end
local function has(s,part) assert(type(s)=="string" and s:find(part,1,true),tostring(s).." lacks "..part) end
local function lacks(s,part) assert(not tostring(s):find(part,1,true),tostring(s).." has "..part) end
local Q={normal={name='normal'},rare={name='rare'},epic={name='epic'},legendary={name='legendary'}}
local function R(name,energy,ings,prods) return {name=name,energy=energy or 0.5,category='crafting',ingredients=ings or {{type='item',name='iron-plate',amount=2}},
  products=prods or {{type='item',name=name,amount=1}},prototype={maximum_productivity=3},productivity_bonus=0} end
local gear,plate=R('iron-gear-wheel'),R('iron-plate',3.2,{{type='item',name='iron-ore',amount=1}})
force.recipes={['iron-gear-wheel']=gear,['iron-plate']=plate}
local function inv(list) return {valid=true,get_contents=function() return list end,is_empty=function() return #list==0 end,count_empty_stacks=function() return 1 end,
  get_item_count=function() return 0 end} end
local function machine(name,typ,x,quality,recipe,rq,extra)
  local e={valid=true,name=name,type=typ,position={x=x,y=0.5},unit_number=math.floor(x*10),force=force,surface=nauvis,quality=Q[quality],status=1,health=350,max_health=350,
    crafting_speed=0.75,productivity_bonus=0,prototype={effect_receiver={base_effect={}}},effects={},
    get_recipe=function() return recipe,recipe and Q[rq] or nil end,get_inventory=function() return inv({}) end,
    get_fluid_contents=function() return {} end}
  for k,v in pairs(extra or {}) do e[k]=v end
  return e
end
-- a legendary recipe in a normal machine (Sol's Needle crusher: normal, oxide-asteroid-reprocessing legendary)
local a=machine('assembling-machine-2','assembling-machine',1.5,'normal',gear,'legendary')
-- a normal recipe in a legendary machine
local b=machine('assembling-machine-2','assembling-machine',4.5,'legendary',gear,'normal')
-- a furnace on rare ore; an idle furnace whose last was legendary (previous_recipe {name, quality}: prototypes)
local f=machine('stone-furnace','furnace',7.5,'normal',plate,'rare')
local idle=machine('stone-furnace','furnace',9.5,'legendary',nil,nil,{previous_recipe={name={name='iron-plate',object_name='LuaRecipePrototype'},quality=Q.legendary}})
-- an assembling machine's ghost, legendary, its recipe epic; a chest's ghost (get_recipe refused)
local g=machine('entity-ghost','entity-ghost',12.5,'legendary',gear,'epic',{ghost_name='assembling-machine-2',ghost_type='assembling-machine',
  ghost_prototype={crafting_categories={crafting=true}},health=false,status=false})
local cg=machine('entity-ghost','entity-ghost',14.5,'normal',nil,nil,{ghost_name='wooden-chest',ghost_type='container',get_recipe=function() error('not a crafting machine') end,health=false,status=false})

-- the shared read: name, quality (normal too), previous (an idle furnace, asked)
do
  local function rq(e,prev) local x,y,z=runtime.recipe_quality_of(e,prev); return tostring(x)..' '..tostring(y)..' '..tostring(z) end
  eq(rq(a),'iron-gear-wheel legendary nil'); eq(rq(b),'iron-gear-wheel normal nil'); eq(rq(f),'iron-plate rare nil')
  eq(rq(idle),'nil nil nil','not asked for the last'); eq(rq(idle,true),'iron-plate legendary true')
  eq(rq(g),'iron-gear-wheel epic nil'); eq(rq(cg,true),'nil nil nil')
  eq(rq(machine('assembling-machine-2','assembling-machine',0,'normal',gear,nil)),'iron-gear-wheel normal nil','no quality read: normal')
  eq(runtime.recipe_label('x','legendary'),'legendary x'); eq(runtime.recipe_label('x','normal'),'x'); eq(runtime.recipe_label('x','normal',true),'normal x')
  print('d28_batch303 RQ recipe and its quality, apart from the machine\'s: ok')
end

-- the rate (inspect's rate, platform_bom, ...): recipe_quality, and its line opens with a recipe not normal
do
  local ra=runtime.craftrate.machine(a)
  eq(ra.recipe,'iron-gear-wheel'); eq(ra.recipe_quality,'legendary')
  has(ra.line,'legendary recipe (takes legendary ingredients, makes legendary products): 90 crafts/min')
  local rb=runtime.craftrate.machine(b)
  eq(rb.recipe_quality,'normal'); lacks(rb.line,'recipe ('); lacks(rb.line,'legendary')
  eq(runtime.craftrate.machine(idle).recipe_quality,'legendary','an idle furnace: its last recipe\'s')
  f.effects={quality=0.5}
  has(runtime.craftrate.machine(f).line,'rare recipe (takes rare ingredients, makes rare products or better at its quality chance): ')
  f.effects={}
  print('d28_batch303 RQ rate line names the recipe quality: ok')
end

-- inspect (compact and full, by positions) and scan, through dispatch
runtime.operator.bot_create('sol')
local sol=as('sol')
do
  local list={a,b,f,idle,g,cg}
  nauvis.find_entities_filtered=function(fl)
    local out={}
    for _,e in ipairs(list) do
      local pos=fl.position
      if fl.area or (pos and math.abs(e.position.x-pos.x)<=(fl.radius or 0.5) and math.abs(e.position.y-pos.y)<=(fl.radius or 0.5)) then out[#out+1]=e end
    end
    return out
  end
  local r=sol('inspect',{positions={a.position,b.position,f.position,idle.position,g.position,cg.position},compact=true})
  eq(r.lines[1],'assembling-machine-2 (1.5,0.5): working; health 350/350; recipe legendary iron-gear-wheel')
  eq(r.lines[2],'legendary assembling-machine-2 (4.5,0.5): working; health 350/350; recipe normal iron-gear-wheel','the machine\'s quality named: the recipe\'s too')
  eq(r.lines[3],'stone-furnace (7.5,0.5): working; health 350/350; recipe rare iron-plate')
  eq(r.lines[4],'legendary stone-furnace (9.5,0.5): working; health 350/350; last recipe legendary iron-plate')
  eq(r.lines[5],'ghost of legendary assembling-machine-2 (12.5,0.5): recipe epic iron-gear-wheel')
  eq(r.lines[6],'ghost of wooden-chest (14.5,0.5)')
  local function full(e) return sol('inspect',{position=e.position}) end
  local x=full(a); eq(x.recipe,'iron-gear-wheel'); eq(x.recipe_quality,'legendary'); eq(x.quality,'normal')
  x=full(b); eq(x.recipe_quality,'normal'); eq(x.quality,'legendary')
  x=full(f); eq(x.recipe,'iron-plate'); eq(x.recipe_quality,'rare')
  x=full(idle); eq(x.recipe,false); eq(x.recipe_quality,nil); eq(x.previous_recipe,'iron-plate'); eq(x.previous_recipe_quality,'legendary')
  x=full(g); eq(x.recipe,'iron-gear-wheel'); eq(x.recipe_quality,'epic'); eq(x.quality,'legendary')
  x=full(cg); eq(x.recipe,nil); eq(x.recipe_quality,nil)
  -- area rows
  local rows=sol('inspect',{area={left_top={x=0,y=0},right_bottom={x=16,y=1}}}).entities
  local by={}
  for _,e in ipairs(rows) do by[e.position.x]=e end
  eq(by[1.5].recipe_quality,'legendary'); eq(by[4.5].recipe_quality,'normal'); eq(by[4.5].quality,'legendary')
  print('d28_batch303 RQ inspect: compact, full, positions, area rows, ghosts, furnaces: ok')
  -- scan: recipe_quality beside recipe, status or output; not with other fields
  local function scan(fields)
    local out={}
    for _,e in ipairs(sol('scan',{area={left_top={x=0,y=0},right_bottom={x=16,y=1}},fields=fields}).entities) do out[e.position.x]=e end
    return out
  end
  for _,fields in ipairs({'recipe','status','output','status|output'}) do
    local s=scan(fields)
    eq(s[1.5].recipe_quality,'legendary',fields); eq(s[1.5].quality,nil,fields)
    eq(s[4.5].recipe_quality,'normal',fields); eq(s[4.5].quality,'legendary',fields)
    eq(s[7.5].recipe_quality,'rare',fields); eq(s[9.5].recipe_quality,nil,fields..': an idle furnace has none now')
    eq(s[12.5].recipe_quality,'epic',fields); eq(s[14.5].recipe_quality,nil,fields)
  end
  eq(scan('recipe')[1.5].recipe,'iron-gear-wheel')
  eq(scan('hp')[1.5].recipe_quality,nil,'not asked')
  print('d28_batch303 RQ scan recipe, status and output: ok')
end

-- bottleneck: a recipe at another quality is its own group, its ingredients counted at that quality (2.0.77:
-- get_item_count(name) counts normal only, and a legendary recipe takes legendary only)
do
  local a2=machine('assembling-machine-2','assembling-machine',2.5,'normal',gear,'normal')
  local held={['iron-plate@legendary']=2}
  a.status=2; a2.status=2
  local function input() return {valid=true,get_contents=function() return {} end,is_empty=function() return true end,
    get_item_count=function(x) if type(x)=='table' then return held[x.name..'@'..(x.quality or 'normal')] or 0 end return held[x..'@normal'] or 0 end} end
  a.get_inventory=input; a2.get_inventory=input
  nauvis.find_entities_filtered=function(fl)
    for _,t in ipairs(type(fl.type)=='table' and fl.type or {fl.type}) do if t=='assembling-machine' then return {a,a2} end end
    return {}
  end
  local by={}
  for _,x in ipairs(sol('bottleneck',{area={left_top={x=0,y=0},right_bottom={x=16,y=1}}}).groups) do by[x.machines]=x end
  local leg,norm=by['assembling-machine-2 legendary iron-gear-wheel x1'],by['assembling-machine-2 iron-gear-wheel x1']
  assert(leg and norm,'one group each')
  eq(leg.short,nil,'2 legendary plates held: one craft\'s worth at its quality'); eq(norm.short,'iron-plate (1)')
  print('d28_batch303 RQ bottleneck groups by recipe quality and counts at it: ok')
end
