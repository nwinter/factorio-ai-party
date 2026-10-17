-- Run from repository root: lua tests/bots.lua
-- Bots (script-driven characters), profiles, speech bubbles and director
-- cameras against a fake engine.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11},shooting={not_shooting=0,shooting_enemies=1},
  controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
local printed,drawn,created={},{},{}
rendering={draw_text=function(t) local obj={id=#drawn+1,valid=true}; obj.destroy=function() obj.valid=false end; t.obj=obj; drawn[#drawn+1]=t; return obj end,
  get_object_by_id=function(id) return drawn[id] and drawn[id].obj end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local charts={}
local force={name='player',chart=function(_,area) charts[#charts+1]=area end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1}
-- A character entity: the LuaControl surface the handlers use.
local function character(pos)
  local items={}
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=100+#created,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  local inv={get_item_count=function(q) return items[type(q)=='table' and q.name or q] or 0 end,
    find_item_stack=function(q)
      if (items[q.name] or 0)==0 then return nil end
      local stack={prototype={place_result={name=q.name,type='container',fast_replaceable_group=q.name:match('^assembling%-machine') and 'assembling-machine' or nil}}}
      -- 2.0's rail item is a rail planner: rails, no place_result.
      if q.name=='rail' then stack.prototype={rails={{name='straight-rail'},{name='half-diagonal-rail'},{name='curved-rail-a'},{name='curved-rail-b'}}} end
      stack.clear=function() items[q.name]=0 end
      return setmetatable(stack,{__index=function(_,k) if k=='count' then return items[q.name] end end,
        __newindex=function(_,k,v) if k=='count' then items[q.name]=v end end})
    end,
    get_contents=function() local out={} for k,v in pairs(items) do if v>0 then out[#out+1]={name=k,count=v} end end return out end}
  c.items=items
  c.insert=function(s) items[s.name]=(items[s.name] or 0)+s.count; return s.count end
  c.get_main_inventory=function() return inv end
  c.get_item_count=function(n) return items[n] or 0 end
  c.can_reach_entity=function() return true end
  c.die=function() c.valid=false; return true end
  c.destroy=function() c.valid=false end
  return c
end
-- An obstacle (the crash site) west of spawn pushes spots east of x=-3.
surface.find_non_colliding_position=function(_,origin) return {x=math.max(origin.x,-3),y=origin.y} end
surface.create_entity=function(args)
  local e
  if args.name=='character' then e=character(args.position) else e={valid=true,name=args.name,position=args.position,force=args.force,type='container'} end
  created[#created+1]={args=args,entity=e}
  return e
end
surface.can_place_entity=function() return true end
surface.find_entities_filtered=function() return {} end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character({x=5,y=5})
local director={index=2,name='pog-director',valid=true,connected=true,controller_type=1,physical_controller_type=1,force=force,surface=surface,position={x=50,y=50}}
director.character=character({x=50,y=50})
director.set_controller=function(t) director.controller_type=t.type; director.character=nil end
director.teleport=function(pos,surf) director.position={x=pos.x or pos[1],y=pos.y or pos[2]}; return true end
director.game_view_settings={show_minimap=true,show_entity_info=false,show_quickbar=true}
-- A camera client the operator has not pointed anywhere yet.
local cam1={index=3,name='pog-cam1',valid=true,connected=true,controller_type=1,physical_controller_type=1,force=force,surface=surface,position={x=0,y=0}}
cam1.character=character({x=0,y=0})
-- Console lines each player sees.
local seen={}
for _,pl in ipairs({nick,director,cam1}) do seen[pl.name]={}; pl.print=function(m) table.insert(seen[pl.name],m) end end
local players={nick,director,cam1}
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  get_player=function(i) if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function(m) printed[#printed+1]=m end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
local function bot(action,args) return runtime.dispatch{action=action,args=args,bot='astra'} end

-- Operator-only creation: unique valid names, starting items, next to spawn.
local made=runtime.operator.bot_create('astra')
eq(made.ok,true); eq(made.bot.name,'astra'); eq(made.bot.position.x,4); eq(made.bot.position.y,0)
-- A new character charts the area a player would see around it.
eq(#charts,1); eq(charts[1][1][1],4-48); eq(charts[1][2][2],48)
local c=made.bot and storage.agent_harness.bots.by_name.astra.character
eq(c.items['iron-plate'],8); eq(c.items['stone-furnace'],1); eq(c.items.pistol,1)
fails(function() runtime.operator.bot_create('astra') end,'already exists')
fails(function() runtime.operator.bot_create('Bad Name') end,'name must match')
fails(function() runtime.operator.bot_create('nick') end,'a player is named nick')
-- The freeplay scenario's own list wins when it exists.
remote.interfaces.freeplay={get_created_items=true,get_respawn_items=true}
remote.call=function(_,fn) if fn=='get_created_items' then return {['iron-plate']=3} end return {pistol=1} end
local made2=runtime.operator.bot_create('opus')
eq(storage.agent_harness.bots.by_name.opus.character.items['iron-plate'],3)
eq(storage.agent_harness.bots.by_name.opus.character.items['stone-furnace'],nil)
eq(made2.bot.index>made.bot.index,true)
-- Bots are not reachable through dispatch.
fails(function() runtime.dispatch{action='bot_create',args={},bot='astra'} end,'unsupported action')

-- Actions address a bot by name and drive its character.
local r=bot('walk',{direction='east',ticks=3})
eq(r.until_tick,3)
advance(1); eq(c.walking_state.walking,true); eq(c.walking_state.direction,4)
local st=bot('status',{})
eq(st.bot,true); eq(st.name,'astra'); eq(st.active.kind,'walk'); eq(st.alive,true); eq(st.position.x,4)
advance(3); eq(c.walking_state.walking,false); eq(bot('status',{}).last.outcome,'duration_elapsed')
fails(function() runtime.dispatch{action='status',args={},bot='nobody'} end,'no bot named nobody')
fails(function() runtime.dispatch{action='status',args={},bot='astra',player=1} end,'not both')
-- A player's actions are untouched by a bot's.
runtime.dispatch{action='walk',args={direction='north',ticks=2},player=1}
bot('walk',{direction='west',ticks=2}); advance(1)
eq(nick.walking_state.direction,0); eq(c.walking_state.direction,12)
advance(2)

-- Building uses direct placement (no cursor): consumes the item, checks reach, no player.
local b=bot('build',{item='stone-furnace',position={x=3,y=0}})
eq(b.consumed,1); eq(c.items['stone-furnace'],0)
local placed=created[#created].args
eq(placed.name,'stone-furnace'); eq(placed.player,nil); eq(placed.force,force)
fails(function() bot('build',{item='stone-furnace',position={x=3,y=1}}) end,'not in main inventory')
fails(function() c.items['stone-furnace']=1; bot('build',{item='stone-furnace',position={x=20,y=0},walk=false}) end,'out of build reach')
-- Remnants go before a build: shake3's bots were refused by the stump a mined
-- tree left ("placement blocked by tree-08-stump"). A character corpse stays.
local stump={valid=true,type='corpse',name='tree-08-stump',position={x=3.2,y=0.1}}
stump.destroy=function() stump.valid=false end
local body={valid=true,type='character-corpse',name='character-corpse',position={x=3,y=0}}
body.destroy=function() body.valid=false end
surface.find_entities_filtered=function(a) if a.type=='corpse' and a.area then return {stump,body} end return {} end
surface.can_place_entity=function() return not stump.valid end
eq(bot('build',{item='stone-furnace',position={x=3,y=0}}).consumed,1)
eq(stump.valid,false); eq(body.valid,true)
-- A biter corpse is cleared and not named; the error names the real blocker
-- (shake3: "placement blocked by small-biter-corpse (...), burner-mining-drill (...)").
local corpse={valid=true,type='corpse',name='small-biter-corpse',position={x=3.1,y=0.2}}
corpse.destroy=function() corpse.valid=false end
local drill={valid=true,type='mining-drill',name='burner-mining-drill',position={x=3,y=0}}
surface.find_entities_filtered=function(a)
  if not a.area then return {} end
  local out={}
  for _,e in ipairs{corpse,drill} do if e.valid and (a.type==nil or a.type==e.type) then out[#out+1]=e end end
  return out
end
surface.can_place_entity=function() return false end
c.items['stone-furnace']=1
local ok,err=pcall(bot,'build',{item='stone-furnace',position={x=3,y=0}})
assert(not ok and err:find('placement blocked by burner-mining-drill (3,0)',1,true) and not err:find('corpse'),err)
eq(corpse.valid,false); eq(c.items['stone-furnace'],1)
-- An item on the ground names its item and how to clear it (shake4: Grok's 9
-- refused builds at one spot, no remedy).
-- shake5: the build itself takes it into the inventory (Grok's pickup calls
-- left the plate); one that does not fit stays, and the error says so.
local dropped={valid=true,type='item-entity',name='item-on-ground',position={x=3.3,y=0.2},stack={valid_for_read=true,name='iron-plate',count=3}}
dropped.destroy=function() dropped.valid=false end
surface.find_entities_filtered=function(a) if a.area then return {dropped} end return {} end
surface.can_place_entity=function() return not dropped.valid end
local insert=c.insert
c.insert=function() return 0 end -- a full inventory
ok,err=pcall(bot,'build',{item='stone-furnace',position={x=3,y=0}})
assert(not ok and err:find('placement blocked by item-on-ground (iron-plate) (3.3,0.2); a build takes items on the ground into your inventory, and this one did not fit: free a slot',1,true),err)
eq(c.items['stone-furnace'],1); eq(dropped.valid,true)
c.insert=insert
local plates=c.items['iron-plate'] or 0
local placed=bot('build',{item='stone-furnace',position={x=3,y=0}})
eq(placed.consumed,1); eq(placed.picked_up['iron-plate'],3); eq(c.items['iron-plate'],plates+3); eq(dropped.valid,false)
surface.find_entities_filtered=function() return {} end
surface.can_place_entity=function() return true end
-- A machine over one of its fast-replace group passes the manual check, and
-- create_entity alone would leave both (shake5, request #68: assembling-
-- machine-2 over -1). On the same centre it is replaced as a player's build
-- does: the old machine and its contents into the inventory, its recipe set
-- on the new one. Not on the same centre, or no room for it: refused.
;(function()
  local box={left_top={x=-0.4,y=-0.4},right_bottom={x=0.4,y=0.4}}
  local function machine()
    local m={valid=true,type='assembling-machine',name='assembling-machine-1',position={x=3.5,y=0.5},force=force,
      prototype={fast_replaceable_group='assembling-machine',collision_box=box,mineable_properties={products={{type='item',name='assembling-machine-1',amount=1}}}}}
    m.get_recipe=function() return {name='iron-gear-wheel'},{name='normal'} end
    -- Mined into the holding inventory the build gives it (replace.lua).
    m.mine=function(args)
      local slot=args.inventory[1]
      slot.valid_for_read=true; slot.name='assembling-machine-1'; slot.count=1; slot.quality={name='normal'}
      m.valid=false; return true
    end
    return m
  end
  -- One slot is enough for the old machine; the character's fake inventory has no slots (its insert takes all).
  game.create_inventory=function(n)
    local inv={}
    for i=1,n do local s={valid_for_read=false}; s.clear=function() s.valid_for_read=false; s.count=0 end; inv[i]=s end
    inv.destroy=function() end
    return inv
  end
  prototypes=prototypes or {}; prototypes.item=prototypes.item or {}
  local old=machine()
  surface.find_entities_filtered=function(a) if a.area and a.force and old.valid then return {old} end return {} end
  local make=surface.create_entity
  local recipes={}
  surface.create_entity=function(args)
    local e=make(args)
    e.set_recipe=function(r,q) recipes[#recipes+1]={r,q} end
    return e
  end
  c.items['assembling-machine-2']=1
  local r=bot('build',{item='assembling-machine-2',position={x=3.5,y=0.5}})
  eq(r.consumed,1); eq(r.entity.name,'assembling-machine-2'); eq(old.valid,false)
  eq(r.replaced.name,'assembling-machine-1'); eq(r.replaced.recipe,'iron-gear-wheel'); eq(r.replaced.recipe_kept,true)
  eq(recipes[1][1],'iron-gear-wheel'); eq(recipes[1][2],'normal')
  eq(c.items['assembling-machine-1'],1); eq(c.items['assembling-machine-2'],0)
  eq(r.replaced.contents,'it was empty')
  -- No room in the inventory for the old machine (no free slot, and the build's own stack of 2 frees none): refused,
  -- nothing changes.
  old=machine(); c.items['assembling-machine-2']=2
  local made=#created
  local ok2,err2=pcall(bot,'build',{item='assembling-machine-2',position={x=3.5,y=0.5}})
  assert(not ok2 and err2:find('cannot replace assembling-machine-1 (3.5,0.5): your inventory has no room for 1 assembling-machine-1 (0 free slots, 1 needed); nothing moved',1,true),err2)
  eq(old.valid,true); eq(#created,made); eq(c.items['assembling-machine-2'],2)
  -- Overlapping but not on the same centre: refused, naming it.
  old=machine(); old.position={x=4.5,y=0.5}
  ok2,err2=pcall(bot,'build',{item='assembling-machine-2',position={x=3.5,y=0.5}})
  assert(not ok2 and err2:find('placement blocked by assembling-machine-1 (4.5,0.5) already on these tiles, not on the same centre',1,true),err2)
  eq(old.valid,true)
  -- A stone furnace (another group) is not refused by it.
  c.items['stone-furnace']=1
  eq(bot('build',{item='stone-furnace',position={x=3,y=0}}).consumed,1)
  c.items['assembling-machine-2']=0
  surface.create_entity=make
  surface.find_entities_filtered=function() return {} end
end)()
-- Rails: the rail item is a rail planner; build places the named rail
-- (default straight) directly, in the 16 directions rails use.
;(function()
  prototypes=prototypes or {}; prototypes.entity=prototypes.entity or {}
  for _,n in ipairs({'straight-rail','half-diagonal-rail','curved-rail-a','curved-rail-b'}) do prototypes.entity[n]={name=n,type=n} end
  c.items['rail']=4
  local made=#created
  eq(bot('build',{item='rail',position={x=6,y=6}}).consumed,1)
  eq(created[made+1].args.name,'straight-rail'); eq(created[made+1].args.direction,0)
  bot('build',{item='rail',entity='curved-rail-a',position={x=8,y=6},direction='northnortheast'})
  eq(created[made+2].args.name,'curved-rail-a'); eq(created[made+2].args.direction,1)
  eq(c.items['rail'],2)
  fails(function() bot('build',{item='rail',entity='rail-ramp',position={x=10,y=6}}) end,'rail places straight-rail, half-diagonal-rail, curved-rail-a, curved-rail-b; entity names which')
  c.items['stone-furnace']=1
  fails(function() bot('build',{item='stone-furnace',entity='iron-chest',position={x=12,y=6}}) end,'entity: stone-furnace places stone-furnace')
  c.items['rail']=0; c.items['stone-furnace']=0
end)()
-- The bot's own character the only thing on the footprint (shake3: Grok's most
-- common error): it walks off with real walking ticks, then builds.
local function inside(pos,area) return pos.x>area.left_top.x and pos.x<area.right_bottom.x and pos.y>area.left_top.y and pos.y<area.right_bottom.y end
surface.find_entities_filtered=function(a) if a.area and inside(c.position,a.area) then return {c} end return {} end
surface.count_entities_filtered=function() return 0 end
c.position={x=3.3,y=0}; c.items['stone-furnace']=2
local step=bot('build',{item='stone-furnace',position={x=3,y=0}})
eq(step.stepping_aside.to.x,3.85); eq(step.stepping_aside.to.y,0); eq(c.items['stone-furnace'],2)
advance(1); eq(c.walking_state.walking,true); eq(c.walking_state.direction,4)
eq(bot('status',{}).active.kind,'feed')
c.position={x=3.5,y=0}; advance(1); eq(c.walking_state.walking,true) -- still on it (0.4 + 0.2 of character)
c.position={x=3.7,y=0}; advance(1)
eq(c.walking_state.walking,false); eq(c.items['stone-furnace'],1)
local done=bot('status',{}).last; eq(done.outcome,'fed'); eq(done.result.consumed,1)
-- In a batch the entries before stay built, the rest go on after the step.
c.position={x=6.1,y=0}; c.items['stone-furnace']=2
local batch=bot('build',{item='stone-furnace',builds={{position={x=3,y=3}},{position={x=6,y=0}}}})
eq(batch.built,nil); eq(batch.built_so_far,1); eq(batch.still_to_build,1); assert(batch.not_yet:find('stepping aside first',1,true)); assert(math.abs(batch.stepping_aside.to.x-6.85)<1e-9); eq(c.items['stone-furnace'],1)
c.position={x=6.7,y=0}; advance(1)
done=bot('status',{}).last; eq(done.outcome,'fed'); eq(done.result.built,1); eq(done.result.built_before,1); eq(c.items['stone-furnace'],0)
-- A queued build waits through the step and succeeds.
c.position={x=3.3,y=-3}; c.items['stone-furnace']=1
bot('queue_submit',{steps={{action='build',args={item='stone-furnace',position={x=3,y=-3}}},{action='wait_ticks',args={ticks=50}}}})
advance(1); eq(bot('queue_status',{}).active.action,'build')
c.position={x=3.7,y=-3}; advance(2)
local hist=bot('queue_status',{}).history; eq(hist[#hist].action,'build'); eq(hist[#hist].ok,true); eq(c.items['stone-furnace'],0)
bot('queue_cancel',{})
-- chat and say do not pause or stop a running plan (sapilot: Opus's wish for
-- "a queue that does not pause on chat/say"; it already does not).
bot('queue_submit',{steps={{action='walk',args={direction='east',ticks=20}},{action='wait_ticks',args={ticks=5}}}})
advance(1); bot('say',{text='still walking'}); bot('chat',{})
advance(1); local qs=bot('queue_status',{}); eq(qs.paused,false); eq(qs.active.action,'walk')
bot('queue_cancel',{})
-- With nowhere to stand in reach it fails as before, naming the character.
c.items['stone-furnace']=1; c.position={x=3,y=0}; surface.can_place_entity=function(a) return a.name~='character' and false end
fails(function() bot('build',{item='stone-furnace',position={x=3,y=0}}) end,'the character standing on the footprint')
surface.find_entities_filtered=function() return {} end
surface.can_place_entity=function() return true end
c.position={x=4,y=0}

-- Profiles: set, read back, colour the character; bubbles over the speaker.
local pr=bot('profile',{display_name='Astra',color='#FF8000',glyph='🚀',motto='iron first'})
eq(pr.display_name,'Astra'); eq(pr.color,'#ff8000'); eq(pr.kind,'bot')
eq(c.color.r,1); eq(c.color.g,128/255)
eq(bot('profile',{}).glyph,'🚀')
fails(function() bot('profile',{color='orange'}) end,'#rrggbb')
fails(function() bot('profile',{glyph='abc'}) end,'glyph must be 1..2')
fails(function() bot('profile',{display_name=string.rep('x',25)}) end,'display_name must be 1..24')
eq(bot('profile',{glyph='👩‍🚀'}).glyph,'👩‍🚀') -- a ZWJ sequence counts as two
-- A glyph another agent holds is refused, naming the holder (shake3: Astra and
-- Muse both ✦, Sol and Sonnet both S); case and U+FE0F do not make it differ.
local function as_opus(args) return runtime.dispatch{action='profile',args=args,bot='opus'} end
fails(function() as_opus({display_name='Opus',glyph='👩‍🚀'}) end,'glyph 👩‍🚀 is taken by Astra (astra); pick another')
eq(as_opus({}).display_name,nil) -- refused before anything changed
eq(as_opus({glyph='S'}).glyph,'S')
fails(function() runtime.dispatch{action='profile',args={glyph='s'},player=1} end,'glyph S is taken by opus;')
eq(bot('profile',{glyph='👩‍🚀'}).glyph,'👩‍🚀') -- setting your own glyph again is fine
eq(as_opus({glyph='✦'}).glyph,'✦')
fails(function() bot('profile',{glyph='✦\239\184\143'}) end,'is taken by opus')
eq(as_opus({glyph='O'}).glyph,'O')
-- A colour too close to another agent's is refused the same way (shake4: four
-- oranges); a far one is fine, and your own colour again is fine.
fails(function() as_opus({color='#ff9010'}) end,"color #ff9010 is too close to Astra (astra)'s #ff8000")
fails(function() as_opus({color='#FF8000',glyph='Q'}) end,'pick another, e.g. #e6194b')
eq(as_opus({}).glyph,'O') -- refused before anything changed
eq(as_opus({color='#4363d8'}).color,'#4363d8')
eq(bot('profile',{color='#ff8000'}).color,'#ff8000')
-- voice: the stream's speaker id, stored lower case, listed in profiles.
eq(bot('profile',{voice='Orion'}).voice,'orion'); eq(bot('profile',{}).voice,'orion')
-- A voice another agent holds is refused, naming the holder (shake5: Sol and
-- Muse both oa-cedar); your own again is fine.
fails(function() as_opus({voice='ORION',glyph='Z'}) end,'voice orion is taken by Astra (astra); pick another')
eq(as_opus({}).glyph,'O') -- refused before anything changed
eq(as_opus({voice='oa-cedar'}).voice,'oa-cedar')
eq(bot('profile',{voice='orion'}).voice,'orion')
local listed; for _,row in ipairs(bot('profiles',{}).profiles) do if row.name=='astra' then listed=row end end
eq(listed.voice,'orion')
fails(function() bot('profile',{voice=string.rep('x',17)}) end,'voice must be 1..16')
-- pronouns: free text for the casters, listed in profiles; "" clears.
eq(bot('profile',{pronouns='she/her'}).pronouns,'she/her')
for _,row in ipairs(bot('profiles',{}).profiles) do if row.name=='astra' then listed=row end end
eq(listed.pronouns,'she/her')
fails(function() bot('profile',{pronouns=string.rep('x',33)}) end,'pronouns must be 0..32')
eq(bot('profile',{pronouns=''}).pronouns,nil)
-- avatar: a few named parts, validated and stored as sent; false clears.
eq(bot('profile',{}).avatar,nil)
local av=bot('profile',{avatar={base='robot',helmet='power',visor='mono',emblem='gear',accessory='antenna',backdrop='hazard',accent='#33CCFF'}}).avatar
eq(av.base,'robot'); eq(av.visor,'mono'); eq(av.accent,'#33ccff')
eq(bot('profile',{}).avatar.helmet,'power')
eq(bot('profile',{avatar={base='biter'}}).avatar.helmet,nil) -- a new avatar replaces the old one; unset parts follow from the name
fails(function() bot('profile',{avatar={base='dragon'}}) end,'avatar.base must be one of engineer|robot|biter|drone')
fails(function() bot('profile',{avatar={hat='hardhat'}}) end,'avatar: unknown field hat')
fails(function() bot('profile',{avatar={accent='blue'}}) end,'avatar.accent must be "#rrggbb"')
fails(function() bot('profile',{avatar='robot'}) end,'avatar must be an object')
fails(function() bot('profile',{display_name='Changed',avatar={visor='laser'}}) end,'avatar.visor must be one of')
eq(bot('profile',{}).display_name,'Astra') -- a refused avatar changes nothing
eq(bot('profile',{}).avatar.base,'biter')
eq(bot('profile',{avatar={accessory='headset'}}).avatar.accessory,'headset')
eq(bot('profile',{avatar=false}).avatar,nil)
bot('profile',{avatar={base='engineer',helmet='hardhat',emblem='flask'}})
bot('say',{text='taking iron, you take copper'})
-- Chat lines go to players, not camera clients (their view shows the bubble).
eq(#printed,0); eq(#seen['pog-director'],0); eq(#seen['pog-cam1'],0)
eq(seen.nick[#seen.nick]:find('astra[/color]: taking iron',1,true)~=nil,true)
eq(seen.nick[#seen.nick]:find('[color=1.00,0.50,0.00]',1,true)~=nil,true)
local bubble=drawn[#drawn]
eq(bubble.text,'taking iron, you take copper'); eq(bubble.target.entity,c); eq(bubble.time_to_live,480); eq(bubble.color.r,1)
-- Speaking again replaces the bubble; long text wraps at ~40 characters.
bot('say',{text=string.rep('word ',30)})
eq(bubble.obj.valid,false)
local lines=0
for i=#drawn,1,-1 do if drawn[i].obj.valid and drawn[i].time_to_live then lines=lines+1; assert(#drawn[i].text<=40) end end
eq(lines,4)
-- profiles: players and bots; camera clients (pog-cam*, pog-director) are
-- excluded even before their first camera call.
runtime.dispatch{action='profile',args={display_name='Nick'},player=1}
local list=runtime.dispatch{action='profiles',args={},player=1}.profiles
eq(#list,3)
local by={}; for _,row in ipairs(list) do by[row.name]=row end
eq(by.astra.kind,'bot'); eq(by.astra.display_name,'Astra'); eq(by.astra.alive,true); eq(by.astra.active,false)
eq(by.astra.avatar.emblem,'flask'); eq(by.opus.avatar,nil)
-- Where each agent is (Space Age): a planet, a platform, or a cargo pod in between.
surface.valid=true
for _,row in ipairs(runtime.dispatch{action='profiles',args={},player=1}.profiles) do by[row.name]=row end
eq(by.astra.surface,'nauvis'); eq(by.astra.where,'nauvis'); eq(by.astra.travel,nil); eq(by.nick.where,'nauvis')
storage.agent_harness.bots.by_name.opus.travel={state='ascending',platform='alpha'}
for _,row in ipairs(runtime.dispatch{action='profiles',args={},player=1}.profiles) do by[row.name]=row end
eq(by.opus.where,'cargo pod to platform alpha'); eq(by.opus.travel,'ascending'); eq(by.opus.platform,'alpha')
storage.agent_harness.bots.by_name.opus.travel=nil
surface.valid=nil
eq(by.astra.last_said.text:sub(1,4),'word'); eq(by.nick.kind,'player'); eq(by.nick.display_name,'Nick'); eq(by.opus.glyph,'O')

-- Director cameras: operator-only, spectator once, eased follow, release.
fails(function() runtime.operator.camera({player=2,follow='nobody'}) end,'no bot or player named nobody')
fails(function() runtime.operator.camera({player=2,follow='astra',zoom=5}) end,'zoom must be 0.3..4')
local old=director.character
local cam=runtime.operator.camera({player=2,follow='astra',zoom=0.5})
eq(cam.ok,true); eq(director.controller_type,2); eq(old.valid,false)
eq(director.show_on_map,false) -- its name does not float over the bot it follows
-- Camera clients with no camera yet become characterless spectators without a label
-- on the 5 s recheck (a character would show its name on stream); agents are untouched.
cam1.set_controller=function(t) cam1.controller_type=t.type; cam1.character=nil end
cam1.game_view_settings={show_minimap=true}
local cam1_body=cam1.character
eq(cam1.show_on_map,nil); advance(300-tick%300)
eq(cam1.show_on_map,false); eq(cam1.controller_type,2); eq(cam1_body.valid,false); eq(cam1.game_view_settings.show_minimap,false)
eq(nick.show_on_map,nil); eq(nick.controller_type,1)
eq(runtime.operator.camera({player=2,follow='astra',zoom=4}).camera.zoom,4); cam=runtime.operator.camera({player=2,follow='astra',zoom=0.5})
-- A clean view: GUI hidden, entity info kept.
eq(director.game_view_settings.show_minimap,false); eq(director.game_view_settings.show_quickbar,false)
eq(director.game_view_settings.show_crafting_queue,false); eq(director.game_view_settings.show_entity_info,true)
eq(director.position.x,4) -- first frame jumps to the target
c.position={x=11,y=0}; advance(1)
assert(director.position.x>4 and director.position.x<5,'eases toward the target')
advance(200); assert(math.abs(director.position.x-11)<0.05,'arrives')
c.position={x=500,y=0}; advance(1); eq(director.position.x,500) -- far targets jump
eq(runtime.operator.cameras().cameras[1].follow,'astra')
eq(runtime.dispatch{action='cameras',args={},player=1}.cameras[1].player,2)
list=runtime.dispatch{action='profiles',args={},player=1}.profiles
for _,row in ipairs(list) do assert(row.name~='pog-director','directors are not agents') end
eq(runtime.operator.camera({player=2,position={x=7,y=7},smooth=false}).camera.position.x,7)
eq(director.position.x,7)
-- A director (no character) can peek at the chat, as an overlay does.
eq(#runtime.dispatch{action='chat',args={peek=true,since=0},player=2}.messages>0,true)
fails(function() runtime.dispatch{action='chat',args={},player=2} end,'living survival character')
-- Back with a character (a reconnect): the next tick makes it a director again.
director.controller_type=1; director.character=character({x=7,y=7}); local back=director.character
director.game_view_settings.show_minimap=true
advance(1); eq(director.controller_type,2); eq(back.valid,false); eq(director.game_view_settings.show_minimap,false)
eq(runtime.operator.camera({player=2,release=true}).released,true)
eq(#runtime.operator.cameras().cameras,0)
-- Released, it is still a director, even with a character again.
eq(storage.agent_harness.directors[2],true)
director.controller_type=1; director.character=character({x=7,y=7})
for _,row in ipairs(runtime.dispatch{action='profiles',args={},player=1}.profiles) do assert(row.name~='pog-director') end
director.controller_type=2; director.character=nil
storage.agent_harness.controlled={[1]={}}
fails(function() runtime.operator.camera({player=1,follow='astra'}) end,'attached agent')
c.position={x=1,y=0}

-- Death: actions stop, the bot reports dead_until_tick, then respawns at spawn
-- after 600 ticks with what a respawning player gets; the corpse kept the rest.
bot('walk',{direction='east',ticks=600}); advance(1)
c.valid=false; advance(1)
local dead=bot('status',{})
eq(dead.alive,false); eq(dead.dead_until_tick,tick+600); eq(dead.active,false); eq(dead.last.outcome,'died')
fails(function() bot('walk',{direction='east',ticks=5}) end,'is dead')
-- Talk works while dead (shake3: Sonnet's chat failed 3 times with "bot sonnet is dead").
local said=bot('say',{text='down at the boilers, back in 10 s'}); assert(said.seq,'say while dead')
local heard=runtime.dispatch{action='chat',args={},player=1}
eq(heard.messages[#heard.messages].text,'down at the boilers, back in 10 s'); eq(heard.messages[#heard.messages].from,'astra')
runtime.dispatch{action='say',args={text='@astra ok'},player=1}
local read=bot('chat',{}); eq(read.messages[#read.messages].text,'@astra ok')
fails(function() bot('chat',{limit=0}) end,'limit must be 1..100')
for _,row in ipairs(runtime.dispatch{action='profiles',args={},player=1}.profiles) do
  if row.name=='astra' then eq(row.alive,false); eq(row.dead_until_tick,dead.dead_until_tick) end
  assert(row.name~='pog-director','a released director is still a spectator, not an agent')
end
-- Sleep works while dead too (shake4: 19 refused sleeps): it sleeps until the
-- respawn and wakes with respawned; the refusal of other actions points to it.
fails(function() bot('walk',{direction='east',ticks=5}) end,'fh sleep SECONDS waits and wakes with respawned')
-- observe answers when the bot respawns instead of failing (shake4: 26 failures).
local seen=bot('observe',{scope='nearest',name='iron-ore'}); eq(seen.dead,true); eq(seen.dead_until_tick,dead.dead_until_tick)
assert(seen.note:find('bot astra is dead until tick '..dead.dead_until_tick,1,true),seen.note)
eq(bot('observe',{}).dead,true)
local zz=bot('sleep',{seconds=30}); eq(zz.dead,true); eq(zz.respawns_at_tick,dead.dead_until_tick)
eq(bot('observe',{scope='sleep_check',peek=true}).woke,nil)
advance(599); eq(bot('status',{}).alive,false)
eq(bot('observe',{scope='sleep_check',peek=true}).woke,nil)
advance(1)
eq(bot('observe',{scope='sleep_check'}).woke,'respawned')
local again=bot('status',{}); eq(again.alive,true); eq(again.dead_until_tick,nil); eq(again.deaths,1)
local c2=storage.agent_harness.bots.by_name.astra.character
assert(c2~=c,'a new character'); eq(c2.items.pistol,1); eq(c2.items['iron-plate'],nil)
eq(c2.color.r,1) -- the profile colour is reapplied
-- Taking a corpse never calls mine_entity (the engine crashes for a playerless
-- character): its items move to the inventory and the empty corpse goes.
defines.inventory.character_corpse=9
local function slot(name,count)
  local st={valid_for_read=true,name=name,count=count}
  st.clear=function() st.valid_for_read=false; st.count=0 end
  return st
end
local loot={slot('iron-plate',4),slot('stone',20)}
loot.is_empty=function() for _,st in ipairs(loot) do if st.valid_for_read then return false end end return true end
local corpse={valid=true,type='character-corpse',get_inventory=function() return loot end}
corpse.destroy=function() corpse.valid=false end
c2.mine_entity=function() error('mine_entity must not be called on a corpse') end
local room=10
c2.get_main_inventory().insert=function(st) local n=math.min(room,st.count); room=room-n; c2.items[st.name]=(c2.items[st.name] or 0)+n; return n end
local astra_proxy=runtime.bots.proxy(storage.agent_harness.bots.by_name.astra)
eq(runtime.bots.mine(astra_proxy,corpse),false) -- only 10 fit
eq(c2.items['iron-plate'],4); eq(c2.items.stone,6); eq(loot[2].count,14); eq(corpse.valid,true)
room=100
eq(runtime.bots.mine(astra_proxy,corpse),true); eq(c2.items.stone,20); eq(corpse.valid,false)
-- Repair: the engine ignores repair_state for a playerless character, so a
-- bot heals by script and drains the pack; the pack goes back afterwards.
local furnace={valid=true,name='stone-furnace',type='furnace',force=force,position={x=2,y=0},health=100,max_health=200,minable=true,prototype={repair_speed_modifier=1}}
local pack={valid_for_read=false}
c2.cursor_stack={valid_for_read=false,swap_stack=function(st) pack.valid_for_read=true; pack.count=st.count; pack.durability=300; c2.items['repair-pack']=0
  setmetatable(c2.cursor_stack,{__index=pack}); c2.cursor_stack.valid_for_read=nil; return true end}
pack.prototype={type='repair-tool',speed=2}; pack.name='repair-pack'
pack.drain_durability=function(n) pack.durability=pack.durability-n end
pack.clear=function() pack.valid_for_read=false; pack.count=0 end
c2.items['repair-pack']=2
c2.get_main_inventory().find_item_stack=function(name) if (c2.items[name] or 0)>0 then return {count=c2.items[name],prototype=pack.prototype} end end
c2.get_main_inventory().insert=function(st) c2.items[st.name]=(c2.items[st.name] or 0)+st.count; return st.count end
surface.find_entities_filtered=function() return {furnace} end
c2.repair_state={repairing=false}
eq(bot('repair',{position={x=2,y=0},ticks=300}).until_tick,tick+300)
advance(10); eq(furnace.health,110); eq(pack.durability,290)
advance(100); eq(furnace.health,200); eq(bot('status',{}).last.outcome,'repair_completed')
eq(pack.valid_for_read,false); eq(c2.items['repair-pack'],2) -- back in the inventory
-- Astra 03:42 (2481 "entity does not need repair" errors in a shift from a repair patrol): an undamaged target is ok,
-- unchanged, nothing started, last nothing_to_do; in a queue the steps succeed and the plan goes on.
local r=bot('repair',{position={x=2,y=0}})
eq(r.unchanged,'not damaged'); eq(r.until_tick,nil); eq(r.health,200)
eq(bot('status',{}).last.outcome,'nothing_to_do'); eq(bot('status',{}).active,false)
bot('queue_submit',{steps={{action='repair',args={position={x=2,y=0}}},{action='repair',args={position={x=2,y=0}}},{action='wait_ticks',args={ticks=1}}}})
advance(3)
local qh=bot('queue_status',{}).history
eq(qh[#qh-2].action,'repair'); eq(qh[#qh-2].ok,true); eq(qh[#qh-2].result.unchanged,'not damaged'); eq(qh[#qh-1].ok,true); eq(qh[#qh].action,'wait_ticks')
-- Positions or an area: every damaged one, nearest first, counted as repaired against already full.
local f2={valid=true,name='stone-furnace',type='furnace',force=force,position={x=3,y=0},health=150,max_health=200,minable=true,prototype={repair_speed_modifier=1}}
local f3={valid=true,name='stone-furnace',type='furnace',force=force,position={x=4,y=0},health=200,max_health=200,minable=true,prototype={repair_speed_modifier=1}}
furnace.health=180
surface.find_entities_filtered=function(f)
  local all={furnace,f2,f3}
  if f.position then
    for _,e in ipairs(all) do if e.position.x==f.position.x and e.position.y==f.position.y then return {e} end end
    return {}
  end
  return all
end
local list=bot('repair',{positions={{x=2,y=0},{x=3,y=0},{x=4,y=0}},ticks=600})
eq(list.targets,3); eq(list.damaged,2); eq(list.already_full,1); eq(list.until_tick,tick+600)
eq(bot('status',{}).active.kind,'repair')
advance(200)
local rl=bot('status',{}).last
eq(rl.outcome,'repair_completed'); eq(rl.repaired,2); eq(rl.already_full,1); eq(rl.tally,'repaired 2, 1 already full')
eq(furnace.health,200); eq(f2.health,200); eq(pack.valid_for_read,false)
-- A list of positions given as position runs as positions (corrected says so).
local as_list=bot('repair',{position={{x=2,y=0},{x=4,y=0}}})
eq(as_list.targets,2); eq(as_list.unchanged,'not damaged'); assert(as_list.corrected,'corrected names the call as it ran')
local area={left_top={x=1,y=-1},right_bottom={x=5,y=1}}
local none=bot('repair',{area=area})
eq(none.unchanged,'not damaged'); eq(none.already_full,3); eq(none.damaged,0); eq(bot('status',{}).last.outcome,'nothing_to_do')
-- No repair pack: undamaged is still ok; a damaged target fails, single or in a list.
c2.items['repair-pack']=0
eq(bot('repair',{position={x=3,y=0}}).unchanged,'not damaged')
f2.health=120
fails(function() bot('repair',{position={x=3,y=0}}) end,'no repair tool in inventory')
fails(function() bot('repair',{area=area}) end,'no repair tool in inventory (1 of 3 targets damaged)')
fails(function() bot('repair',{area=area,positions={{x=3,y=0}}}) end,'give positions or area, not both')
c2.items['repair-pack']=2; f2.health=200
surface.find_entities_filtered=function() return {} end
-- Removal kills the character (its corpse keeps the items) and forgets the bot.
local removed=runtime.operator.bot_remove('opus')
eq(removed.bot.died,true)
fails(function() runtime.dispatch{action='status',args={},bot='opus'} end,'no bot named opus')
eq(#runtime.operator.bots().bots,1)

-- Turn clock: a bot's timed action is work in progress.
bot('clock',{mode='turns'})
eq(game.tick_paused,true)
bot('walk',{direction='east',ticks=5}); eq(game.tick_paused,false)
advance(7); eq(game.tick_paused,true)
-- Nine bots spread on rings around the spawn point, none on top of another,
-- and each keeps its surroundings charted once a second, staggered.
for _,name in ipairs({'sol','luna','sonnet','haiku','grok','gemini','muse','opus2'}) do runtime.operator.bot_create(name) end
local spots={}
for _,b in ipairs(runtime.operator.bots().bots) do spots[#spots+1]=b.position end
eq(#spots,9)
for i=1,#spots do for j=i+1,#spots do
  local d=((spots[i].x-spots[j].x)^2+(spots[i].y-spots[j].y)^2)^0.5
  assert(d>=2,'bots '..i..' and '..j..' spawn '..d..' tiles apart')
end end
local before=#charts; advance(60); eq(#charts-before,9)
local per_tick={}
before=#charts; for _=1,60 do local n=#charts; advance(1); per_tick[#per_tick+1]=#charts-n end
for _,n in ipairs(per_tick) do assert(n<=1,'charting is staggered across ticks') end
-- profile_ticks times the harness tick and logs the average once.
local logged={}
log=function(m) logged[#logged+1]=m end
table_size=function(t) local n=0 for _ in pairs(t) do n=n+1 end return n end
local timers=0
helpers.create_profiler=function() timers=timers+1; return {stop=function() end,add=function() end,divide=function(n) logged.divided=n end} end
eq(runtime.operator.profile_ticks(5).until_tick,tick+5)
advance(4); eq(#logged,0); advance(1); eq(#logged,1); eq(logged.divided,5); eq(logged[1][5],9)
advance(5); eq(#logged,1)
-- With a table it runs the dispatch/event profiler (profile.lua): a status
-- dispatch and the tick are logged per game second, then totals and done.
helpers.create_profiler=function() return {stop=function() end,add=function() end} end
eq(runtime.operator.profile_ticks({seconds=1}).until_tick,tick+60)
bot('status',{})
advance(61)
local profiled={}
for _,m in ipairs(logged) do if type(m)=='table' and type(m[2])=='string' then profiled[#profiled+1]=m[2]..(m[7] or '') end end
local function has(s) for _,l in ipairs(profiled) do if l:find(s,1,true) then return true end end return false end
assert(has('agent-harness profile second tick=dispatch status'),table.concat(profiled,'\n'))
assert(has('agent-harness profile total ticks=dispatch status')); assert(has('agent-harness profile done from_tick='))
assert(has('agent-harness profile second tick=part board.team')); assert(has('agent-harness profile total ticks=tick'))
local after=#logged; advance(60); eq(#logged,after)
-- A bot's screenshot is rendered by one director client, centred on the bot
-- (shake1/2: with no by_player every client rendered it into its own folder
-- and ./shot never delivered); none connected is an error, not a silent no-op.
local shots={}
game.take_screenshot=function(t) shots[#shots+1]=t end
local shot=bot('screenshot',{path='pog/astra/look-1.png'})
eq(#shots,1); eq(shots[1].by_player,director); eq(shots[1].player,nil); eq(shots[1].path,'pog/astra/look-1.png')
eq(shots[1].position.x,storage.agent_harness.bots.by_name.astra.character.position.x); eq(shot.client,'pog-director'); eq(shot.queued,true)
-- A player's screenshot stays on the player's own client.
eq(runtime.dispatch{action='screenshot',args={path='pog/nick/a.png'},player=1}.client,'nick'); eq(shots[2].by_player,nick)
game.connected_players={nick}
eq(bot('screenshot',{path='pog/astra/b.png'}).client,'nick')
game.connected_players={}
fails(function() bot('screenshot',{path='pog/astra/c.png'}) end,'no graphical client is connected')
game.connected_players=players
-- The hourly survey skips a bot aboard a platform (no body): live on sa, tick
-- 72000, it raised in the tick and quarantined the runtime.
local ab=storage.agent_harness.bots.by_name.astra
local ab_body=ab.character
force.platforms={{valid=true,name='alpha',index=1,surface={valid=true,name='platform-1'},hub=nil}}
ab.character=nil; ab.travel={state='aboard',platform='alpha',platform_index=1,since=tick}
advance(3600-tick%3600)
eq(storage.agent_harness.runtime_fault,nil); eq(ab.travel.state,'aboard')
ab.travel=nil; ab.character=ab_body; force.platforms=nil
-- Votes (votes.lua): the electorate is the bots whose own requests (or fh
-- sleep polls) are recent; the overlay's peeks at every bot's status do not count.
game.tick=game.tick+40000
runtime.dispatch{action='status',args={},bot='astra'}
runtime.dispatch{action='status',args={peek=true},bot='sol'}
local electorate=runtime.dispatch{action='votes',args={},operator=true}.active
eq(#electorate,1); eq(electorate[1],'astra')
-- A sleeping agent's sleep_check poll keeps it active: 40000 ticks on, astra
-- and sol's own requests are old, and only sol's poll is recent.
runtime.dispatch{action='sleep',args={seconds=900},bot='sol'}
game.tick=game.tick+40000
pcall(runtime.dispatch,{action='sleep_check',args={peek=true},bot='sol'})
electorate=runtime.dispatch{action='votes',args={},operator=true}.active
eq(#electorate,1); eq(electorate[1],'sol')
-- A bot's tile build fulfils a tile ghost of that tile, as a player's does: 2.0.77's set_tiles aborts on the ghost
-- entity, so construct never laid the landfill ghost under a pole on Gleba wetland (Sol, shift09). Elsewhere the
-- ghost is put back.
do
  local B=dofile('mod/agent-harness_0.1.0/bots.lua'){}
  local tiles,ghosts,made={},{},{}
  local function at(x,y) return math.floor(x)..','..math.floor(y) end
  ghosts[at(5,5)]={valid=true,type='tile-ghost',ghost_name='landfill',position={x=5.5,y=5.5},force=force}
  ghosts[at(5,5)].destroy=function() ghosts[at(5,5)].valid=false end
  local wet={name='wetland-blue-slime',prototype={collision_mask={layers={water_tile=true}}}}
  local s={get_tile=function(x,y) return tiles[at(x,y)] or wet end,
    find_entities_filtered=function(f) local g=ghosts[at(f.position[1],f.position[2])]; return g and g.valid and {g} or {} end,
    set_tiles=function(list) for _,t in ipairs(list) do
      local g=ghosts[at(t.position[1],t.position[2])]
      if g and g.valid then return end -- abort_on_collision: nothing is laid
      tiles[at(t.position[1],t.position[2])]={name=t.name,prototype={collision_mask={layers={ground_tile=true}}}}
    end end,
    set_hidden_tile=function() end,
    create_entity=function(a) made[#made+1]=a; return {valid=true} end}
  local removed=0
  local inv={get_item_count=function() return 5 end,remove=function(a) removed=removed+a.count end}
  local bot={surface=s,get_main_inventory=function() return inv end}
  local stack={prototype={place_as_tile_result={result={name='landfill',mineable_properties={minable=true}},condition={layers={ground_tile=true}}}}}
  local r=B.place_tiles(bot,{item='landfill'},stack,{x=5.5,y=5.5},1)
  eq(r.consumed,1); eq(tiles[at(5,5)].name,'landfill'); eq(ghosts[at(5,5)].valid,false); eq(#made,0); eq(removed,1)
  -- refused for another reason: the ghost comes back
  ghosts[at(7,5)]={valid=true,type='tile-ghost',ghost_name='landfill',position={x=7.5,y=5.5},force=force}
  ghosts[at(7,5)].destroy=function() ghosts[at(7,5)].valid=false end
  s.set_tiles=function() end
  fails(function() B.place_tiles(bot,{item='landfill'},stack,{x=7.5,y=5.5},1) end,'no tile was placed')
  eq(#made,1); eq(made[1].name,'tile-ghost'); eq(made[1].inner_name,'landfill'); eq(made[1].position.x,7.5)
  -- A tree on the tile (Sol, shift10: a slipstack on Gleba wetland): the refusal names it (dryrun.lua hand_tile).
  -- Sol, shift12 12:55: landfill at (68.5,45.5) on Gleba kept failing with "no tile was placed (blocked or already
  -- there)"; a water-cane stood there, which the game's tile building takes away (2.0.77: not
  -- protected_from_tile_building; robots laid landfill over an unmarked one and it was gone).
  local cane={valid=true,name='water-cane',position={x=11.8,y=5.9}}
  cane.destroy=function(o) eq(o.raise_destroy,true); cane.valid=false end
  local B2=dofile('mod/agent-harness_0.1.0/bots.lua'){hand_tile=function(_,_,item,x,y)
    eq(item,'landfill')
    if x==9 then return {why='blocked by slipstack tree at (9.4,5.6): mine it first',blockers={{}}} end
    if x==11 and cane.valid then return {removes={cane}} end
    if x==13 then return {why='landfill cannot go on lava (foundation can)'} end
    if tiles[at(x,y)] and tiles[at(x,y)].name=='landfill' then return {already=true} end
    return {removes={}}
  end,removes_text=function(list) eq(#list,1); return 'water-cane (11.8,5.9)' end}
  bot.force=force
  local laid=s.set_tiles
  s.set_tiles=function(list)
    for _,t in ipairs(list) do
      if t.position[1]==11 then assert(not cane.valid,'the cane goes before the tile') end
      tiles[at(t.position[1],t.position[2])]={name=t.name,prototype={collision_mask={layers={ground_tile=true}}}}
    end
  end
  fails(function() B2.place_tiles(bot,{item='landfill'},stack,{x=9.5,y=5.5},1) end,
    'no tile was placed: (9.5,5.5): blocked by slipstack tree at (9.4,5.6): mine it first')
  fails(function() B2.place_tiles(bot,{item='landfill'},stack,{x=13.5,y=5.5},1) end,'no tile was placed: (13.5,5.5): landfill cannot go on lava (foundation can)')
  local rc=B2.place_tiles(bot,{item='landfill'},stack,{x=11.5,y=5.5},1)
  eq(rc.consumed,1); eq(tiles[at(11,5)].name,'landfill'); eq(rc.removed,'water-cane (11.8,5.9)')
  eq(rc.removed_note,'water-cane and fish do not block a tile; a new tile takes them away'); eq(rc.not_placed,nil)
  fails(function() B2.place_tiles(bot,{item='landfill'},stack,{x=11.5,y=5.5},1) end,'no tile was placed: (11.5,5.5): landfill is there already')
  -- A 2x2 brush over (8..9, 4..5): (9,4) and (9,5) blocked by the slipstack, two laid; refusals grouped by reason.
  local rb=B2.place_tiles(bot,{item='landfill'},stack,{x=9,y=5},2)
  eq(rb.consumed,2); eq(rb.not_placed,'2 of 4 tiles: (9.5,4.5) (9.5,5.5): blocked by slipstack tree at (9.4,5.6): mine it first')
  -- Fewer items than tiles: the rest is said.
  local few={get_item_count=function() return 1 end,remove=function(a) removed=removed+a.count end}
  bot.get_main_inventory=function() return few end
  local rf=B2.place_tiles(bot,{item='landfill'},stack,{x=21,y=5},2)
  eq(rf.consumed,1); eq(rf.not_placed,'3 with no landfill left')
  bot.get_main_inventory=function() return inv end
  s.set_tiles=laid
  -- Concrete on Aquilo lands as its frozen variant (Sol, shift17 61h20: a 3x3 of concrete on rough ice failed "no tile
  -- was placed" though all 9 were laid, world n read frozen-concrete there): counted as placed, and as already there.
  do
    local ice={name='ice-rough',prototype={collision_mask={layers={ground_tile=true}}}}
    local aq={}
    local s4={get_tile=function(x,y) return aq[at(x,y)] or ice end,find_entities_filtered=function() return {} end,
      set_tiles=function(list) for _,tt in ipairs(list) do aq[at(tt.position[1],tt.position[2])]={name='frozen-'..tt.name,prototype={collision_mask={layers={ground_tile=true}}}} end end,
      set_hidden_tile=function() end,create_entity=function(a) made[#made+1]=a end}
    local used=0
    local inv4={get_item_count=function() return 30 end,remove=function(a) used=used+a.count end}
    local bot4={surface=s4,force=force,get_main_inventory=function() return inv4 end}
    local concrete={name='concrete',frozen_variant={name='frozen-concrete'},mineable_properties={minable=true}}
    local stack4={prototype={place_as_tile_result={result=concrete,condition={layers={water_tile=true}}}}}
    local made0=#made
    local r4=B.place_tiles(bot4,{item='concrete'},stack4,{x=5.5,y=-0.5},3)
    eq(r4.consumed,9); eq(used,9); eq(r4.not_placed,nil); eq(aq[at(5,-1)].name,'frozen-concrete'); eq(#made,made0)
    fails(function() B.place_tiles(bot4,{item='concrete'},stack4,{x=5.5,y=-0.5},1) end,'no tile was placed: (5.5,-0.5): concrete is there already')
  end
  -- Without the dry run module, the item's own rules: tile_condition (landfill never on lava).
  local lava={name='lava',prototype={collision_mask={layers={water_tile=true,lava_tile=true}}}}
  local s3={get_tile=function() return lava end,find_entities_filtered=function() return {} end,set_tiles=function() error('no set_tiles on lava') end}
  local stack3={prototype={place_as_tile_result={result={name='landfill'},condition={layers={ground_tile=true}},
    tile_condition={{name='water'},{name='wetland-light-dead-skin'}}}}}
  fails(function() B.place_tiles({surface=s3,force=force,get_main_inventory=function() return inv end},{item='landfill'},stack3,{x=0.5,y=0.5},1) end,
    'no tile was placed: (0.5,0.5): landfill cannot go on lava')
end
print('bots: ok')
