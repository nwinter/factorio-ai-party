-- d24 batch193 QAI1 (viewer Aurora 20:58; Opus, shift71 02:03, 03:08 and 03:31 UTC): vehicle {position, go_to} on a far
-- spidertron was refused as out of sight with no word of the remote form that would have sent it. The refusal names it
-- for our spidertron, car or tank there (unit number and the call's own arguments), or why the remote form is refused
-- too; what is allowed is unchanged. Run from the harness root: lua tests/d24_batch193.lua
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
storage={agent_harness={active={}}}
defines={events={on_script_path_request_finished=10,on_entity_died=11,on_entity_damaged=12,on_console_chat=13,on_unit_group_finished_gathering=14},
  shooting={not_shooting=0,shooting_enemies=1},controllers={character=1,remote=27,spectator=2},direction={north=0},inventory={chest=1},
  build_mode={normal=1},build_check_type={manual=1},flow_precision_index={five_seconds=0,one_minute=1}}
local drawn={}
rendering={draw_text=function(t) local obj={id=#drawn+1,valid=true}; obj.destroy=function() obj.valid=false end; drawn[#drawn+1]=obj; return obj end,
  get_object_by_id=function(id) return drawn[id] end}
remote={interfaces={}}
helpers={json_to_table=function(t) return t end}
local force={name='player',chart=function() end,is_chunk_visible=function() return true end,is_chunk_charted=function() return true end,get_spawn_position=function() return {x=0,y=0} end}
local surface={name='nauvis',index=1}
local units=0
local function character(pos)
  local items={}
  units=units+1
  local c={valid=true,name='character',type='character',force=force,surface=surface,position=pos,unit_number=500+units,health=250,
    driving=false,build_distance=10,reach_distance=10,character_running_speed=0.15,walking_state={walking=false}}
  local inv={get_item_count=function(q) return items[type(q)=='table' and q.name or q] or 0 end,find_item_stack=function() return nil end,
    get_contents=function() return {} end}
  c.items=items
  c.insert=function(s) items[s.name]=(items[s.name] or 0)+s.count; return s.count end
  c.get_main_inventory=function() return inv end
  c.get_item_count=function(n) return items[n] or 0 end
  c.can_reach_entity=function() return true end
  c.destroy=function() c.valid=false end
  return c
end
surface.find_non_colliding_position=function(_,origin) return origin end
surface.create_entity=function(args) if args.name=='character' then return character(args.position) end return {valid=true,name=args.name,position=args.position} end
surface.can_place_entity=function() return true end
surface.find_entities_filtered=function() return {} end
surface.get_total_pollution=function() return 0 end; surface.get_chunks=function() return function() end end; surface.get_pollution=function() return 0 end
surface.request_path=function() return 1 end
local nick={index=1,name='nick',valid=true,connected=true,controller_type=1,physical_controller_type=1,cheat_mode=false,driving=false,force=force,surface=surface,position={x=5,y=5},chat_color={r=1,g=1,b=1}}
nick.character=character({x=5,y=5})
local director={index=2,name='pog-director',valid=true,connected=true,controller_type=2,physical_controller_type=2,force=force,surface=surface,position={x=50,y=50}}
local players={nick,director}
for _,pl in ipairs(players) do pl.print=function() end end
local tick=0
game={tick=0,players=players,forces={player=force,enemy={name='enemy',get_evolution_factor=function() return 0 end,get_evolution_factor_by_time=function() return 0 end,
  get_evolution_factor_by_pollution=function() return 0 end,get_evolution_factor_by_killing_spawners=function() return 0 end}},
  -- As the engine: a bot's index is no player index.
  get_player=function(i) assert(type(i)=='string' or i<=65536,'Given player value is too big'); if type(i)=='string' then for _,p in ipairs(players) do if p.name==i then return p end end return nil end return players[i] end,
  get_surface=function() return surface end,print=function() end,connected_players=players,
  get_pollution_statistics=function() return {input_counts={},output_counts={},get_flow_count=function() return 0 end} end}
local runtime=dofile('mod/agent-harness_0.1.0/runtime.lua')
local function advance(n) for _=1,n do tick=tick+1; game.tick=tick; runtime.tick{tick=tick} end end
local function jump(n) tick=tick+n; game.tick=tick end
-- As control.lua does: a failed request stops its player unless the runtime
-- marked it passive.
local function request(req)
  local ok,result=pcall(runtime.dispatch,req)
  if not ok then
    local who=req.player or (req.bot==nil and 1 or nil)
    if req.bot then who=runtime.bots.index_of(req.bot) end
    if type(who)=='number' then pcall(runtime.stop_player,who) end
    error(result,0)
  end
  return result
end
local function as(name) return function(action,args) return request{action=action,args=args or {},bot=name} end end
local astra,sol,grok=as('astra'),as('sol'),as('grok')
local function op(action,args) return request{action=action,args=args or {},operator=true} end
runtime.operator.bot_create('astra'); runtime.operator.bot_create('sol'); runtime.operator.bot_create('grok')
astra('profile',{display_name='Astra',glyph='A',color='#9977ff'})
sol('profile',{display_name='Sunny',glyph='S',color='#ffcb45'})

-- Fakes: vehicles found by position and radius, type and force; chunks our force sees.
local world={}
local dark={}
force.is_chunk_visible=function(_,c) return not dark[c.x..','..c.y] end
surface.find_entities_filtered=function(f)
  local out={}
  local types
  if f.type then types={}; for _,t in ipairs(type(f.type)=='table' and f.type or {f.type}) do types[t]=true end end
  for _,e in ipairs(world) do
    local d=f.position and math.sqrt((e.position.x-f.position.x)^2+(e.position.y-f.position.y)^2)
    if e.valid and (not types or types[e.type]) and (not f.force or e.force==f.force) and d and d<=(f.radius or 0.5) then out[#out+1]=e end
  end
  return out
end
game.get_entity_by_unit_number=function(n) for _,e in ipairs(world) do if e.valid and e.unit_number==n then return e end end end
local function vehicle(name,type_,x,y,unit)
  local v={valid=true,name=name,type=type_,position={x=x,y=y},force=force,speed=0,orientation=0.25,surface=surface,unit_number=unit}
  v.get_driver=function() return v.driver end
  v.get_passenger=function() return v.passenger end
  v.get_fuel_inventory=function() return {is_empty=function() return false end} end
  world[#world+1]=v
  return v
end
local function spidertron(x,y,unit)
  local s=vehicle('spidertron','spider-vehicle',x,y,unit)
  local route={}
  setmetatable(s,{__index=function(_,k)
    if k=='autopilot_destinations' then local out={} for i,d in ipairs(route) do out[i]=d end return out end
    if k=='autopilot_destination' then return route[1] end
  end,__newindex=function(t,k,v) if k=='autopilot_destination' then route=v and {v} or {} else rawset(t,k,v) end end})
  s.add_autopilot_destination=function(pos) route[#route+1]=pos end
  s.get_spider_legs=function() return {} end
  s.vehicle_automatic_targeting_parameters={auto_target_without_gunner=false,auto_target_with_gunner=false}
  s.route=function() return route end
  return s
end
local a_body=runtime.lookup(runtime.bots.index_of('astra')).character
local s_body=runtime.lookup(runtime.bots.index_of('sol')).character
local FAR='vehicle is outside local visible area: (-480,-500) is 63.3 tiles from the character at (-422.3,-526.0) (limit 32 tiles, in a visible chunk; move_to within 30 tiles first)'
local function refusal(fn) local ok,err=pcall(fn); assert(not ok,'refused'); return tostring(err) end

-- 1. Opus at 03:08:44: the spidertron 63 tiles off in a chunk our force sees. The refusal gives the remote call with its
-- unit number and the same go_to; nothing is sent by the refused call, and the call it names sends it.
a_body.position={x=-422.3,y=-526.0}
local spider=spidertron(-480,-500,23036938)
eq(refusal(function() astra('vehicle',{position={x=-480,y=-500},go_to={x=-600,y=-380}}) end),
  FAR..'; or by remote: vehicle {remote: true, vehicle: 23036938, go_to: {x: -600, y: -380}}')
eq(#spider.route(),0,'the refused call sent nothing')
local r=astra('vehicle',{remote=true,vehicle=23036938,go_to={x=-600,y=-380}})
eq(r.by,'remote view'); eq(spider.route()[1].x,-600)
-- a list with mode, clear, the targeting switches: the call's own arguments, in that order
eq(refusal(function() astra('vehicle',{position={x=-480,y=-500},go_to={{x=-600,y=-380},{-610,-390}},mode='append',auto_target_without_gunner=true}) end),
  FAR..'; or by remote: vehicle {remote: true, vehicle: 23036938, go_to: [{x: -600, y: -380}, [-610, -390]], mode: "append", auto_target_without_gunner: true}')
eq(refusal(function() astra('vehicle',{position={x=-480,y=-500},clear=true}) end),FAR..'; or by remote: vehicle {remote: true, vehicle: 23036938, clear: true}')
-- a read of it alone (refused before as "nothing is done"): the refusal, with the remote read
eq(refusal(function() astra('vehicle',{position={x=-480,y=-500}}) end),FAR..'; or by remote: vehicle {remote: true, vehicle: 23036938}')
eq(astra('vehicle',{remote=true,vehicle=23036938}).unit_number,23036938)
eq(refusal(function() astra('vehicle',{position={x=-480,y=-500},enter=true}) end),FAR..'; or by remote: vehicle {remote: true, vehicle: 23036938, go_to: {x, y}}')

-- 2. The remote form refused too: its chunk out of sight (the remote form's own rule) says why.
dark['-15,-16']=true
local msg=refusal(function() astra('vehicle',{position={x=-480,y=-500},go_to={x=-600,y=-380}}) end)
assert(msg:find('; by remote it is refused too: spidertron (-480,-500) is in no chunk our force sees now (radar coverage or a character\'s sight): remote view needs it in view',1,true),msg)
fails(function() astra('vehicle',{remote=true,vehicle=23036938,go_to={x=-600,y=-380}}) end,'is in no chunk our force sees now')
dark['-15,-16']=nil

-- 3. Not ours, or no vehicle there: the refusal as before.
spider.force={name='other'}
eq(refusal(function() astra('vehicle',{position={x=-480,y=-500},go_to={x=-600,y=-380}}) end),FAR)
spider.force=force; spider.valid=false
eq(refusal(function() astra('vehicle',{position={x=-480,y=-500},go_to={x=-600,y=-380}}) end),FAR)
spider.valid=true

-- 4. A car or tank far off: the remote drive (to go_to's target when it is one position), or the remote drive's refusal.
spider.valid=false
local tank=vehicle('tank','car',-480,-500,9001)
eq(refusal(function() astra('vehicle',{position={x=-480,y=-500},enter=true}) end),FAR..'; or by remote: vehicle {remote: true, vehicle: 9001, drive: {x, y}}')
eq(refusal(function() astra('vehicle',{position={x=-480,y=-500},go_to={x=-600,y=-380}}) end),FAR..'; or by remote: vehicle {remote: true, vehicle: 9001, drive: {x: -600, y: -380}}')
tank.driver=s_body
eq(refusal(function() astra('vehicle',{position={x=-480,y=-500},enter=true}) end),FAR..'; by remote it is refused too: tank (-480,-500): its driver seat holds sol\'s character')
tank.driver=nil
-- out of sight: the nearest coverage said once, in the refusal before it
dark['-15,-16']=true
msg=refusal(function() astra('vehicle',{position={x=-480,y=-500},enter=true}) end)
local _,n=msg:gsub('the nearest radar coverage',''); eq(n,1,msg)
assert(msg:find('(limit 32 tiles, in a visible chunk; move_to within 30 tiles first); the nearest radar coverage (or a character\'s sight) is chunk (-512,-512)-(-481,-481), 1 tile away; by remote it is refused too: tank (-480,-500) is in no chunk our force sees now (radar coverage or a character\'s sight): remote driving needs it in view',1,true),msg)
dark['-15,-16']=nil
tank.valid=false; spider.valid=true

-- 5. Nothing changes in sight: the spidertron within 32 tiles is sent as before, with no remote word.
a_body.position={x=-470,y=-505}
r=astra('vehicle',{position={x=-480,y=-500},go_to={x=-500,y=-520}})
eq(r.by,nil); eq(spider.route()[1].x,-500)
print('d24_batch193: ok')

