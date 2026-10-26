-- d26 batch249 (the batch227 review's R5 and R11): refusals that say what was wrong and what is accepted, through the
-- runtime against a fake engine. Run from the harness root: lua tests/d26_batch249b.lua
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok,'expected a refusal: '..text); assert(tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11},shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27},
  direction={north=0},inventory={chest=1},build_mode={normal=1},flow_precision_index={five_seconds=0,one_minute=1}}
local p={index=1,name='luna',valid=true,connected=true,controller_type=1,physical_controller_type=1,character={valid=true},position={x=0,y=0},cheat_mode=false,driving=false}
local charted={}
p.force={name='player',platforms={},is_chunk_visible=function() return false end,
  is_chunk_charted=function(s,c) return charted[s.name]~=false end,get_spawn_position=function() return {x=0,y=0} end}
local nauvis={name='nauvis',index=1,valid=true,planet={name='nauvis'}}
local gleba={name='gleba',index=4,valid=true,planet={name='gleba'}}
local asterion={name='platform-16',index=20,valid=true}
p.surface=nauvis
p.character.surface=nauvis
p.character.prototype={collision_mask={layers={player=true}},crafting_categories={crafting=true}}
p.can_reach_entity=function() return true end
p.create_local_flying_text=function() end
p.get_main_inventory=function() return {get_item_count=function() return 0 end,get_contents=function() return {} end} end
for _,s in ipairs({nauvis,gleba,asterion}) do
  s.find_entities_filtered=function() return {} end; s.count_entities_filtered=function() return 0 end
  s.get_total_pollution=function() return 0 end; s.get_chunks=function() return function() end end; s.get_pollution=function() return 0 end
  s.request_path=function() return 1 end
end
asterion.platform={name='Asterion',force=p.force,valid=true}
p.force.platforms={{name='Asterion',valid=true,surface=asterion,force=p.force}}
local surfaces={nauvis=nauvis,gleba=gleba,['platform-16']=asterion}
local pollution_stats={input_counts={},output_counts={},get_flow_count=function() return 0 end}
game={tick=0,surfaces=surfaces,get_surface=function(n) return surfaces[n] end,get_player=function(i) if i==1 or i=='luna' then return p end end,
  forces={player=p.force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
    get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  players={p},connected_players={p},get_pollution_statistics=function() return pollution_stats end,print=function() end}
prototypes={quality={normal={level=0},uncommon={level=1},rare={level=2},epic={level=3},legendary={level=5},['quality-unknown']={level=0}},
  item={['electronic-circuit']={type='item'},['artillery-targeting-remote']={type='capsule'},['iron-plate']={type='item'},
    ['asteroid-collector']={type='item'},crusher={type='item'}},
  recipe={['electronic-circuit']={products={{type='item',name='electronic-circuit'}}},['laser-turret']={products={{type='item',name='laser-turret'}}},
    ['electric-mining-drill']={products={{type='item',name='electric-mining-drill'}}}},
  technology={['laser-turret']={effects={{type='unlock-recipe',recipe='laser-turret'}}}},
  entity={['underground-belt']={},['fast-underground-belt']={},['requester-chest']={}}}
p.force.recipes={['electronic-circuit']={name='electronic-circuit',enabled=true,category='crafting'},['laser-turret']={name='laser-turret',enabled=false,category='crafting'}}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function call(action,args) return runtime.dispatch{action=action,args=args,player=1} end

-- R11: craft's "recipe is unavailable" says why: a quality in the name, no such recipe, not unlocked.
fails(function() call('craft',{recipe='electronic-circuit@rare'}) end,
  'recipe is unavailable: "electronic-circuit@rare": a recipe name holds no quality; hand crafting makes normal quality only (recipe "electronic-circuit")')
fails(function() call('craft',{recipe='artillery-targeting-remote'}) end,
  'recipe is unavailable: no recipe is named artillery-targeting-remote; no recipe makes the item artillery-targeting-remote')
fails(function() call('craft',{recipe='electric-mining'}) end,'recipe is unavailable: no recipe is named electric-mining; nearest names: electric-mining-drill')
fails(function() call('craft',{recipe='laser-turret'}) end,'recipe is unavailable: laser-turret is not unlocked yet; research laser-turret unlocks it')
print('d26_batch249b R11 craft refusals: ok')

-- R11: an unknown observe scope lists the scopes, and names the action of that name.
fails(function() call('observe',{scope='research'}) end,'unknown observe scope "research"; scope is one of: agriculture, belt_gaps, bottleneck, craftable,')
fails(function() call('observe',{scope='research'}) end,'; research is an action of its own (research {})')
fails(function() call('observe',{scope='platform'}) end,'; observe {platform: NAME} reads a platform')
print('d26_batch249b R11 observe scopes: ok')

-- R11: losses {surface} with a platform's name names its surface; a name that is no surface lists the planets.
fails(function() call('losses',{surface='Asterion'}) end,'unknown surface Asterion; Asterion is a platform (its surface: platform-16): surface="platform-16" names its surface')
fails(function() call('losses',{surface='mars'}) end,'unknown surface mars; surfaces: gleba, nauvis, or a platform\'s')
print('d26_batch249b R11 losses surface: ok')

-- R11: stock's items take name@quality as stock {item} does; an unknown quality is refused naming the qualities.
do
  local seen={}
  local kept=runtime.stock_one
  runtime.stock_one=function(_,a) seen[#seen+1]=a; return {total=a.quality=='legendary' and 3 or 9,line=a.item..' '..tostring(a.quality)} end
  local r=call('stock',{items={'asteroid-collector@legendary','iron-plate'}})
  eq(seen[1].item,'asteroid-collector'); eq(seen[1].quality,'legendary'); eq(r.rows[1].item,'asteroid-collector@legendary'); eq(r.rows[1].total,3)
  eq(seen[2].item,'iron-plate'); eq(seen[2].quality,nil)
  fails(function() call('stock',{items={'iron-plate@shiny'}}) end,'items[1].item iron-plate@shiny: no quality named shiny (qualities: normal, uncommon, rare, epic, legendary)')
  fails(function() call('stock',{items={'iron-gear@rare'}}) end,'items: unknown item iron-gear@rare (an item name, or name@quality)')
  runtime.stock_one=kept
end
fails(function() call('observe',{scope='stock',item='crusher',quality='all'}) end,
  'quality all: no quality of that name; quality is one of normal, uncommon, rare, epic, legendary')
print('d26_batch249b R11 stock items and quality: ok')

-- R11: inspect {area, name} takes names joined by commas as the list; an unknown one names the forms.
do
  p.force.is_chunk_visible=function() return true end
  -- (an empty area: the read's own answer, naming both names)
  fails(function() call('inspect',{area={left_top={x=0,y=0},right_bottom={x=8,y=8}},name='underground-belt, fast-underground-belt'}) end,
    'no underground-belt, fast-underground-belt of ours with its centre in (0,0)-(8,8)')
  fails(function() call('inspect',{area={left_top={x=0,y=0},right_bottom={x=8,y=8}},name='underground-belt,turbo-belt'}) end,
    'unknown entity name turbo-belt (name: an entity name, a list of them, or names joined by commas)')
  p.force.is_chunk_visible=function() return false end
end
print('d26_batch249b R11 inspect names joined by commas: ok')

-- R5: a position named on the wrong planet: never charted there, and what of ours stands at that point on another.
do
  charted.gleba=false
  local chest={valid=true,name='requester-chest',type='logistic-container',position={x=-269.5,y=486.5},force=p.force}
  nauvis.find_entities_filtered=function(f)
    if f.position and f.force==p.force and math.abs(f.position.x+269.5)<0.5 and math.abs(f.position.y-486.5)<0.5 then return {chest} end
    return {}
  end
  local text=runtime.ground_state({surface=gleba,force=p.force,position={x=0,y=0}},{x=-269.5,y=486.5})
  eq(text,'chunk (-9,15) was never charted on gleba; at (-269.5,486.5) ours stand on another planet: requester-chest on nauvis (surface: "nauvis")')
  -- the inspect that named gleba (Luna's, 14 times over shifts 71-80)
  fails(function() call('inspect',{position={x=-269.5,y=486.5},surface='gleba'}) end,
    'chunk (-9,15) was never charted on gleba; at (-269.5,486.5) ours stand on another planet: requester-chest on nauvis (surface: "nauvis")')
  -- nothing of ours there on another planet: as before
  eq(runtime.ground_state({surface=gleba,force=p.force,position={x=0,y=0}},{x=-200.5,y=486.5}),'chunk (-7,15) was never charted')
  charted.gleba=nil
  nauvis.find_entities_filtered=function() return {} end
end
print('d26_batch249b R5 never charted names ours on another planet: ok')

-- (the batch227 review, PU1's bug 4 now) transfer of a quality the character lacks names that quality and what it
-- holds of the item at the others (Gemini asked for iron-plate@uncommon holding 10 normal).
do
  p.force.is_chunk_visible=function() return true end
  local chest={valid=true,name='iron-chest',type='container',position={x=2.5,y=0.5},force=p.force,unit_number=77,prototype={},
    bounding_box={left_top={x=2.2,y=0.2},right_bottom={x=2.8,y=0.8}},get_item_count=function() return 0 end,get_max_inventory_index=function() return 1 end,
    get_inventory=function() return {valid=true,get_item_count=function() return 0 end,can_insert=function() return true end,insert=function() return 0 end,
      get_contents=function() return {} end} end}
  nauvis.find_entities_filtered=function(f) if f.position or f.area then return {chest} end return {} end
  local inv={get_item_count=function(q)
      if type(q)=='table' then return q.name=='iron-plate' and (q.quality==nil or q.quality=='normal') and 10 or 0 end
      return q=='iron-plate' and 10 or 0 end,
    get_contents=function() return {{name='iron-plate',quality='normal',count=10}} end,find_item_stack=function() return nil end,remove=function() return 0 end}
  p.get_main_inventory=function() return inv end
  p.get_item_count=inv.get_item_count
  fails(function() call('transfer',{direction='to_entity',item='iron-plate@uncommon',position={x=2.5,y=0.5}}) end,
    'no iron-plate@uncommon in inventory; the target has 0; you hold 10 iron-plate of other qualities')
  p.force.is_chunk_visible=function() return false end
  nauvis.find_entities_filtered=function() return {} end
end
print('d26_batch249b transfer names the quality asked: ok')
