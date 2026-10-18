-- Run from the harness root: lua tests/d17_territory.lua
-- Demolisher territories, cleared or not (d17 territory, Nick 17:08: Vulcanus territory 1 had no demolisher after Sol
-- killed it, and the reads and build notes did not tell that from one out of sight).
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,w) assert(s and s:find(w,1,true),tostring(s)..' lacks '..w) end
local function lacks(s,w) assert(not (s and s:find(w,1,true)),tostring(s)..' has '..w) end
game={tick=4888121}
local st={}
local function territory(cx0,cy0,cx1,cy1,units)
  local chunks={}
  for cx=cx0,cx1 do for cy=cy0,cy1 do chunks[#chunks+1]={x=cx,y=cy} end end
  -- the engine's chunk order is not sorted: the key is the smallest chunk whatever the order
  table.sort(chunks,function(a,b) return a.y>b.y end)
  return {get_chunks=function() return chunks end,get_segmented_units=function() return units end,box={cx0,cy0,cx1,cy1}}
end
local live={unit_number=91,health=30000,max_health=30000,speed=0,prototype={name='small-demolisher'},
  segments={{position={x=200,y=330},orientation=0.25,prototype={collision_box={left_top={x=-1.5,y=-1.5},right_bottom={x=1.5,y=1.5}}}}}}
local t1,t2,t3=territory(-10,-6,2,12,{}),territory(4,-6,8,0,{}),territory(4,8,8,12,{live})
local territories={t1,t2,t3}
local surface={name='vulcanus',get_territories=function() return territories end,
  get_territory_for_chunk=function(c) for _,t in ipairs(territories) do local b=t.box if c.x>=b[1] and c.x<=b[3] and c.y>=b[2] and c.y<=b[4] then return t end end end}
local force={is_chunk_charted=function() return true end,is_chunk_visible=function(_,c) return c.x>=4 and c.y>=8 end}
local sol={valid=true,type='character'}
local D=dofile('mod/agent-harness_0.1.0/demolishers.lua'){state=function() return st end,position=function(v) return v end,
  character_name=function(e) return e==sol and 'sol' or nil end}
local T=dofile('mod/agent-harness_0.1.0/territory.lua'){state=function(s,f,t) return D.state(s,f,t) end}

-- Sol kills territory 1's demolisher: its territory, when and by whom are kept; its last-seen memory goes.
st.demolisher_seen={[77]={x=-200,y=40,tick=4800000,name='small-demolisher'}}
local head={valid=true,type='segmented-unit',name='small-demolisher',surface=surface,position={x=-200.5,y=40.5},
  segmented_unit={unit_number=77,territory=t1}}
D.died({entity=head,cause=sol,tick=4888121,force={name='player'}})
eq(st.demolisher_seen[77],nil)
local d=st.demolisher_deaths['vulcanus|-10,-6']
eq(d.by,'sol'); eq(d.tick,4888121); eq(d.name,'small-demolisher')

game.tick=4888121+3*216000
local p={surface=surface,force=force,position={x=0,y=0}}
local r=D.read(p,{surface=nil})
local by={}
for _,row in ipairs(r.territories) do by[row.charted_chunks]=row end
eq(by[13*19].state,'killed')
has(by[13*19].line,'its small-demolisher was killed at tick 4888121 (game 22h37m, 3h ago) by sol; none seen since')
eq(by[5*7].state,'not seen'); has(by[5*7].line,'no demolisher seen in it')
eq(by[5*5].state,'has a demolisher'); has(by[5*5].line,'small-demolisher: head at (200,330)')

-- Build notes: a placement in the cleared territory says so, with no "attacks what is built" line; in one where none
-- was seen, that (a player cannot tell an empty territory from one whose demolisher is out of sight); by the live one,
-- the demolisher.
local n1=T.note(surface,force,{-225,30,-224,45})
has(n1,'(its small-demolisher was killed at tick 4888121 (game 22h37m, 3h ago) by sol; none seen since)'); lacks(n1,'attacks what is built')
local n2=T.note(surface,force,{140,-100,141,-99})
has(n2,'(no demolisher seen in it)'); has(n2,'attacks what is built')
local n3=T.note(surface,force,{150,300,151,301})
has(n3,'a demolisher attacks what is built in its territory')

-- A cause that is not a character: the entity and who built it; none: the killing force.
D.died({entity={valid=true,type='segmented-unit',name='small-demolisher',surface=surface,position={x=170,y=-100},segmented_unit={unit_number=78,territory=t2}},
  cause={valid=true,type='artillery-turret',name='artillery-turret',last_user={name='opus'}},tick=5000000})
eq(st.demolisher_deaths['vulcanus|4,-6'].by,'artillery-turret (built by opus)')
-- Survival-fair (operator 17:40): a territory whose demolisher lives but was never seen reads the same as an empty one.
t2.get_segmented_units=function() return {{unit_number=95,segments={{position={x=150,y=-100}}}}} end
eq(select(1,D.state(surface,force,t2)),'killed')  -- the artillery kill above
st.demolisher_deaths['vulcanus|4,-6']=nil
local s2,l2=D.state(surface,force,t2); eq(s2,'not seen'); eq(l2,'no demolisher seen in it')

-- The one-time seed (operator 17:40): Sol's kill in Vulcanus territory 1 from the team's record, applied once to the
-- territory under (-225,37); a death recorded there already is kept.
st={}
game.get_surface=function(n) return n=='vulcanus' and surface or nil end
local s1,l1=D.state(surface,force,t1)
eq(s1,'killed'); has(l1,'its demolisher was killed at tick 4888121 (game 22h37m'); has(l1,'by sol (the team\'s record: chat seq 2143); none seen since')
eq(st.demolisher_seeded['vulcanus-t1-sol'],true)
st.demolisher_deaths['vulcanus|-10,-6']=nil
eq(select(1,D.state(surface,force,t1)),'not seen','seeded once')
print('d17_territory: ok')

-- Part 2 (Nick 17:15, Vulcanus calcite): a drill waiting for space in a chest it drops into is output_full; one onto a
-- backed-up belt is not.
do
  defines={entity_status={waiting_for_space_in_destination=31,working=1},inventory={chest=1}}
  local PA=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){state=function() return {board={items={}}} end,agents=function() return {} end,who=function(p) return p.name end}
  local list={{name='calcite',count=1600},{name='stone',count=4}}
  local chest={valid=true,type='container',name='iron-chest',position={x=126.5,y=123.5},
    get_inventory=function() local inv={count_empty_stacks=function() return 0 end,get_contents=function() return list end}; return setmetatable(inv,{__len=function() return 32 end}) end}
  local drill={valid=true,name='electric-mining-drill',position={x=124.5,y=123.5},status=31,drop_target=chest,mining_target={name='calcite'}}
  eq(PA.drill_full(drill),'electric-mining-drill (124.5,123.5) mining calcite into iron-chest (126.5,123.5): 32/32 slots used (calcite 1600, stone 4)')
  drill.drop_target={valid=true,type='transport-belt',name='transport-belt',position={x=126.5,y=123.5}}
  eq(PA.drill_full(drill),nil)
  drill.drop_target=chest; drill.status=1
  eq(PA.drill_full(drill),nil)
  local g={kind='output_full',surface='vulcanus',n=2,names={['electric-mining-drill']=2},by={},center={x=130,y=118},at={{x=124.5,y=123.5},{x=135.5,y=110.5}},
    lost={'electric-mining-drill (124.5,123.5) mining calcite into iron-chest (126.5,123.5): 32/32 slots used (calcite 1600)'}}
  has(PA.text(g,'nauvis'),'2 electric-mining-drill stopped by a full chest near (130,118) on vulcanus: electric-mining-drill (124.5,123.5) mining calcite')
end
print('d17_territory part 2 output_full: ok')

-- Part 3 (Nick 17:22): our buildings out of radar sight per planet, with the nearest radar and its state; radars not
-- working; hourly in the team block.
do
  defines={entity_status={working=1,no_power=2,low_power=3}}
  local st={push_alerts={player={tick=100,groups={},sight={unread=0,cells={
    ['vulcanus|3,-4']={surface='vulcanus',drills=28,machines=0,turrets=2,n=30,sx=30*192,sy=30*-256},
    ['vulcanus|-4,0']={surface='vulcanus',drills=4,machines=0,turrets=0,n=4,sx=4*-225,sy=4*37},
    ['aquilo|0,0']={surface='aquilo',drills=0,machines=1,turrets=0,n=1,sx=10,sy=-5}},
    radars={vulcanus={{x=210,y=-214,status=2},{x=-29.5,y=98.5,status=1}},gleba={{x=-171,y=-98,status=2}}}}}}}
  game={tick=200}
  local PA=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){state=function() return st end,agents=function() return {} end,who=function(p) return p.name end}
  local lines=PA.sight_lines({name='player'})
  eq(#lines,3)
  eq(lines[1],'out of radar sight on aquilo: 0 drills, 1 machines, 0 turrets in 1 area (64 tiles): 1 machine near (10,-5), nearest radar none on aquilo')
  has(lines[2],'on gleba every drill, machine and turret of ours is in sight; radars not working: radar (-171,-98) no power')
  has(lines[3],'out of radar sight on vulcanus: 32 drills, 0 machines, 2 turrets in 2 areas (64 tiles): 28 drills, 2 turrets near (192,-256), nearest radar (210,-214) 46 tiles, no power; 4 drills near (-225,37), nearest radar (-29.5,98.5) 205 tiles, working; radars not working: radar (210,-214) no power')
  local h={}
  eq(#PA.sight_team({force={name='player'}},h),3); eq(#PA.sight_team({force={name='player'}},h),0)
  game.tick=200+216000; eq(#PA.sight_team({force={name='player'}},h),3)
end
print('d17_territory part 3 out of radar sight: ok')

-- Part 4 (Nick 17:33): what lies outside every construction area per planet, and requester/buffer chests outside
-- every logistic area; in status and the hourly team line.
do
  local st={push_alerts={player={tick=100,groups={},sight={cells={},radars={},
    cover={['vulcanus|-4,1']={surface='vulcanus',n=83,ghosts=19,sx=83*-228,sy=83*72,names={['gun-turret']=64,['ghost of gun-turret']=19}},
      ['vulcanus|3,-4']={surface='vulcanus',n=208,ghosts=208,sx=208*222,sy=208*-208,names={['ghost of transport-belt']=208}}},
    chests={nauvis={n=7,{name='requester-chest',x=-284.5,y=-313.5},{name='buffer-chest',x=280.5,y=-240.5}}}}}}}
  game={tick=200}
  defines={entity_status={working=1}}
  local PA=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){state=function() return st end,agents=function() return {} end,who=function(p) return p.name end}
  local lines=PA.coverage_lines({name='player'})
  eq(#lines,2)
  eq(lines[1],'7 requester or buffer chests outside every logistic area on nauvis (their requests never fill): requester-chest (-284.5,-313.5), buffer-chest (280.5,-240.5), +5 more')
  eq(lines[2],"outside every roboport's construction area on vulcanus (robots do not build, repair or rebuild there): 291 (227 of them ghosts) in 2 areas (64 tiles): 208 ghost of transport-belt near (222,-208); 64 gun-turret, 19 ghost of gun-turret near (-228,72)")
  local h={}
  local team=PA.sight_team({force={name='player'}},h)
  eq(#team,2); eq(#PA.sight_team({force={name='player'}},h),0)
end
print('d17_territory part 4 coverage: ok')

-- Part 4, lightning (operator 17:35, 23:12): our buildings outside every lightning attractor's protection on a
-- lightning planet (reach = 10 + range_elongation x (1 + 0.3 x quality level), measured on the copy), and our buildings
-- lightning killed (no cause, the neutral force, electric damage), in status and the hourly team line.
do
  local st={}
  game={tick=1000}
  local L=dofile('mod/agent-harness_0.1.0/lightning.lua'){state=function() return st end}
  eq(L.reach('lightning-rod',0),25); eq(L.reach('lightning-collector',0),35); eq(L.reach('fulgoran-ruin-attractor',0),30)
  eq(L.reach('lightning-rod',5),47.5); eq(L.reach('lightning-rod',1),29.5); eq(L.reach('lightning-collector',5),72.5)
  local function ent(name,type,x,y,level) return {valid=true,name=name,type=type,position={x=x,y=y},quality={level=level or 0}} end
  local attractors={ent('lightning-rod','lightning-attractor',0,0),ent('lightning-rod','lightning-attractor',200,0,5)}
  local ours={ent('assembling-machine-2','assembling-machine',10,0),   -- within 15 of the rod: every strike near it goes to the rod
    ent('medium-electric-pole','electric-pole',20,0),                  -- (30,0) is 30 from the rod: exposed at the edge
    ent('pipe','pipe',100,0),                                          -- its own center outside every reach
    ent('stone-wall','wall',100,5),                                    -- walls are never hit
    ent('logistic-robot','logistic-robot',100,0),                      -- not a building
    ent('accumulator','accumulator',235,0),                            -- 35 from the legendary rod (reach 47.5): safe
    {valid=false,type='pipe'}}
  local finds={}
  local fulgora={name='fulgora',planet={name='fulgora'},find_entities_filtered=function(f)
    finds[#finds+1]=f
    if f.type=='lightning-attractor' then return attractors end
    eq(f.force,'player'); return ours end}
  game.get_surface=function(n) return n=='fulgora' and fulgora or nil end
  eq(L.exposure_cursor({name='nauvis',planet={name='nauvis'}},{name='player'}),nil)
  local cur=L.exposure_cursor(fulgora,{name='player'})
  eq(L.exposure_step(cur,3),false); eq(cur.attractors,2)                -- the index, a step
  eq(L.exposure_step(cur,3),false); eq(#finds,2)                        -- the find, a step
  eq(L.exposure_step(cur,3),false); eq(L.exposure_step(cur,3),false)    -- 3 a step
  eq(L.exposure_step(cur,3),true)
  eq(cur.result.checked,4)
  local c00,c10=cur.result.cells[0],cur.result.cells[1048576]   -- 64-tile cells (0,0) and (1,0)
  eq(c00.n,1); eq(c00.center,0); eq(c00.names['medium-electric-pole'],1)
  eq(c10.n,1); eq(c10.center,1); eq(c10.names.pipe,1)
  eq(cur.result.cells[3*1048576],nil)
  -- A strike's death: no cause, the neutral force, electric damage, on a lightning planet; anything else is not.
  local pole=ent('small-electric-pole','electric-pole',466.5,205.5); pole.surface=fulgora; pole.force={name='player'}
  local electric={name='electric'}
  eq(L.struck({entity=pole,force={name='neutral'},damage_type=electric}),'lightning')
  eq(L.struck({entity=pole,force={name='enemy'},damage_type=electric}),nil)
  eq(L.struck({entity=pole,cause={valid=true},force={name='neutral'},damage_type=electric}),nil)
  eq(L.struck({entity=pole,force={name='neutral'},damage_type={name='physical'}}),nil)
  local nauvis_pole=ent('small-electric-pole','electric-pole',0,0); nauvis_pole.surface={name='nauvis',planet={name='nauvis'}}
  eq(L.struck({entity=nauvis_pole,force={name='neutral'},damage_type=electric}),nil)
  L.lost(pole)
  game.tick=1000+3600*5
  local lines=L.exposure_lines({fulgora=cur.result},{name='player'},5)
  eq(#lines,2)
  eq(lines[1],"outside every lightning attractor's protection on fulgora (a point within 10 tiles of each lies outside every attractor's reach, and a strike there hits what stands within 10 tiles; 2 attractors): 2 of 4 buildings of ours (1 with the center itself outside every reach) in 2 areas (64 tiles): 1 medium-electric-pole near (20,0); 1 pipe near (100,0)")
  eq(lines[2],'lost to lightning on fulgora: 1 in the last hour (1 small-electric-pole); the last small-electric-pole (466.5,205.5) 5m ago')
  -- Through pushalerts: the coverage lines (status alerts.outside_coverage and the hourly team line) carry them.
  st.push_alerts={player={tick=100,groups={},sight={cells={},radars={},strike={fulgora=cur.result}}}}
  defines={entity_status={working=1}}
  local PA=dofile('mod/agent-harness_0.1.0/pushalerts.lua'){state=function() return st end,agents=function() return {} end,who=function(p) return p.name end,
    strike_lines=function(strike,force,areas) return L.exposure_lines(strike,force,areas) end}
  local cl=PA.coverage_lines({name='player'})
  eq(#cl,2); eq(cl[1],lines[1])
  -- With no read yet, a lightning loss is still said.
  st.push_alerts=nil
  eq(#PA.coverage_lines({name='player'}),1)
end
print('d17_territory part 4 lightning: ok')
