-- This file is also the hot-reload payload. Top-level execution must be pure:
-- Factorio executes it during on_load, when game and storage writes are forbidden.
local M = {}
local MAX_TICKS = 600
local blueprint_module = require('blueprints')
local scheduler_module = require('scheduler')
local construction_module = require('construction')
local kite_module = require('kite')
local threat_module = require('threat')
local survey_module = require('survey')
local conditions_module = require('conditions')
local route_module = require('route')
local route
local pipes_module = require('pipes')
local pipes
local rates_module = require('rates')
local rates
local stock_module = require('stock')
local stock
local space_module = require('space')
local clock_module = require('clock')
-- Kept on M rather than as locals: this chunk is near Lua's 200-local limit.
M.chat_module = require('chat')
local clock
local space
local kite
local threat
local survey
local construction
local scheduler
local directions = {north=0, northeast=2, east=4, southeast=6, south=8, southwest=10, west=12, northwest=14}
local function integer(value, default, low, high, name)
  if value == nil then value = default end
  assert(type(value) == 'number' and value == math.floor(value) and value >= low and value <= high, name .. ' out of range')
  return value
end
local function position(value)
  -- [x, y] as the engine accepts it (shake3: Gemini's inspect position=[-5,-6]).
  if type(value) == 'table' and value.x == nil and type(value[1]) == 'number' and type(value[2]) == 'number' and value[3] == nil then value = {x=value[1], y=value[2]} end
  assert(type(value) == 'table' and type(value.x) == 'number' and type(value.y) == 'number', 'position requires x and y')
  assert(math.abs(value.x) < 1000000 and math.abs(value.y) < 1000000, 'invalid position')
  return {x=value.x, y=value.y}
end
local function distance(a,b) return ((a.x-b.x)^2+(a.y-b.y)^2)^0.5 end
local function state() return storage.agent_harness end
-- Bots (script-driven characters), profiles/speech bubbles and director
-- cameras. Bot indices sit above every player index (bots.BASE).
M.crafting=require('crafting'){state=state}
M.claims=require('claims'){state=state}
M.bots=require('bots'){state=state,stop=function(index,outcome) M.stop_player(index,outcome) end,crafting=M.crafting,
  profile=function(index) return M.profiles.get(index) end,on_spawn=function(b) M.profiles.apply(M.bots.proxy(b)); M.nametags.refresh(b) end}
M.cameras=require('cameras'){state=state,bot=function(name) return M.bots.named(name) end,
  controlled=function(index) return state().controlled and state().controlled[index]~=nil end}
M.profiles=require('profiles'){state=state,is_bot=function(p) return M.bots.is(p) end,director=function(index) return M.cameras.director(index) end,
  bots=function() return M.bots.list() end,active=function(index) local a=M.active(index); return a and a.kind or false end,
  on_apply=function(p) if M.bots.is(p) then M.nametags.refresh(M.bots.record(p.index)) end end,bubble_y=function(index) return M.nametags.bubble_y(index) end}
M.nametags=require('nametags'){state=state,bots=function() return M.bots.list() end,profile=function(index) return M.profiles.get(index) end,
  parts=require('avatar_parts'),avatar=require('avatar')(require('avatar_parts'))}
-- A player or bot by index, dead or alive (cleanup and status).
function M.lookup(index)
  if M.bots.is_index(index) then return M.bots.lookup(index) end
  return game.get_player(index)
end
-- Who a character belongs to: a player's name, else a bot's (nil if neither).
function M.character_owner(e)
  local ok,pl=pcall(function() return e.player end)
  if ok and pl and pl.valid then return pl.name end
  for _,b in ipairs(M.bots.list()) do if b.character==e then return b.name end end
end
local function combat_targets()
  local s=state()
  -- Target selection affects simulation. Persist both entity and scan deadline
  -- so clients joining between scans reproduce the server's exact inputs.
  s.combat_targets=s.combat_targets or {}
  return s.combat_targets
end
-- Map view (the remote controller) moves the LuaPlayer's position, surface
-- and selection to the camera while the character stays where it is. The
-- character's own controls then go to the character entity (it shares
-- LuaControl); player-level things (force, cursor, permissions) stay put.
local ON_BODY={position=true,surface=true,walking_state=true,mining_state=true,shooting_state=true,picking_state=true,
  repair_state=true,selected=true,get_main_inventory=true,get_inventory=true,can_reach_entity=true,build_distance=true,
  reach_distance=true,crafting_queue=true,begin_crafting=true,cancel_crafting=true,get_craftable_count=true,
  mine_entity=true,character_running_speed=true,insert=true,can_insert=true,get_item_count=true,remove_item=true,
  crafting_queue_size=true,crafting_queue_progress=true}
local function body(p)
  if not (p and p.valid) or p.controller_type~=defines.controllers.remote then return p end
  local c=p.character
  if not (c and c.valid) then return p end
  return setmetatable({__player=p},{
    __index=function(_,k) if ON_BODY[k] then return c[k] end return p[k] end,
    __newindex=function(_,k,v) if ON_BODY[k] then c[k]=v else p[k]=v end end})
end
-- The LuaPlayer behind a body proxy, for engine calls that take a player
-- (nil for a bot: it has none).
local function real(p)
  if type(p)~='table' then return p end
  if rawget(p,'__bot') then return nil end
  return rawget(p,'__player') or p
end
local function in_map_view(p) local r=real(p); return r~=nil and r.controller_type==defines.controllers.remote end
-- Space Age spoilage: per spoilable item in an inventory, the count and the
-- stalest stack's freshness ("yumako*20 61%"), stalest first; nil when
-- nothing in it spoils (always, in the base game).
local function spoil_text(inv,limit)
  if not (inv and inv.valid) then return nil end
  local rows,by={},{}
  for i=1,#inv do
    local s=inv[i]
    if s.valid_for_read then
      local ok,spoiled=pcall(function() return s.prototype.get_spoil_ticks(s.quality)>0 and s.spoil_percent end)
      if ok and spoiled then
        local key=s.name..(s.quality.name~='normal' and '@'..s.quality.name or '')
        local r=by[key]
        if not r then r={key=key,count=0,fresh=1}; by[key]=r; rows[#rows+1]=r end
        r.count=r.count+s.count; r.fresh=math.min(r.fresh,1-spoiled)
      end
    end
  end
  if #rows==0 then return nil end
  table.sort(rows,function(x,y) if x.fresh~=y.fresh then return x.fresh<y.fresh end return x.key<y.key end)
  local parts={}
  for i=1,math.min(#rows,limit or 8) do parts[i]=string.format('%s*%d %d%%',rows[i].key,rows[i].count,math.floor(rows[i].fresh*100)) end
  return table.concat(parts,' ')..(#rows>(limit or 8) and string.format(' +%d more',#rows-(limit or 8)) or '')
end
local function main_inventory(p) local ok,inv=pcall(function() return p.get_main_inventory() end); return ok and inv or nil end
local function player(index)
  if M.bots.is_index(index) then return M.bots.actor(index) end
  local p = game.get_player(index or 1)
  assert(p and p.valid, 'player does not exist')
  local controlled=state().controlled and state().controlled[p.index]
  assert(p.connected, 'join a graphical Factorio client: disconnected players have no controllable character')
  assert(p.physical_controller_type == defines.controllers.character and p.character and p.character.valid, 'a living survival character is required')
  assert(not p.cheat_mode or (controlled and controlled.allow_cheat_mode), 'cheat mode requires explicit testing opt-in')
  assert(not p.driving, 'the character is in a vehicle or riding a rocket/cargo pod; vehicles are unsupported, and a ride ends by itself (poll status)')
  return body(p)
end
local function stop(p)
  if p and p.valid and p.character and p.character.valid then
    p.walking_state = {walking=false, direction=defines.direction.north}
    p.mining_state = {mining=false}
    p.picking_state = false
    p.repair_state = {repairing=false,position=p.position}
  end
end
local function finish(index, outcome)
  local s=state()
  s.last=s.last or {}
  local action=s.active[index]
  -- The goal lets a caller tell its own completion from one that replaced it.
  if action then s.last[index]={kind=action.kind, outcome=outcome, tick=game.tick, target=action.kind=='move_to' and action.position or nil} end
  if action and action.blocked_item then s.last[index].blocked_item=action.blocked_item end
  if action and action.kind=='mine' and action.mined then s.last[index].mined=action.mined end
  if action and action.kind=='mine' and action.error then s.last[index].error=action.error end
  if action and action.kind=='build_path' then
    local last=s.last[index]
    last.placed=action.placed; last.skipped=action.skipped; last.next_index=action.next_index; last.total=#action.cells
    last.next_position=action.cells[action.next_index] and action.cells[action.next_index].position
    last.error=action.error
  end
  if action and action.kind=='move_to' then
    local last=s.last[index]
    -- Movement diagnostics, only when something went wrong on the way.
    last.replans=(action.replans or 0)>0 and action.replans or nil
    last.stalls=action.stalls; last.no_progress=action.no_progress; last.paths_failed=(action.paths_failed or 0)>0 and action.paths_failed or nil
  end
  if action and action.kind=='kite' then
    local last,p=s.last[index],body(M.lookup(index))
    last.kills=action.kills
    if p and p.valid and p.character and p.character.valid then
      last.ammo_used=kite.ammo_used(p,action)
      p.shooting_state={state=defines.shooting.not_shooting,position=p.position}
    end
  end
  if action and action.kind=='feed' then
    local last=s.last[index]
    last.result=action.result; last.error=action.error
  end
  if action and action.kind=='wait_until' then
    local last=s.last[index]
    last.condition=action.condition['until']; last.saw=action.saw; last.error=action.error
  end
  if action and action.kind=='construct' then
    local last=s.last[index]
    last.built=action.built; last.mined=action.mined; last.remaining=construction.remaining(action)
    last.missing=next(action.missing) and action.missing or nil
    last.failed=#action.failed>0 and action.failed or nil
    -- Missing items our factory already holds: say where, not just what.
    local p=last.missing and body(M.lookup(index))
    if p and p.valid and p.character and p.character.valid then
      local n=0
      for item in pairs(last.missing) do
        n=n+1; if n>4 then break end
        local ok,line=pcall(function() return stock.line(stock.scan(p,item,{radius=128})) end)
        if ok and line then last.stock=last.stock or {}; last.stock[item]=line end
      end
    end
  end
  if action and action.kind=='gather' then
    local last=s.last[index]
    last.item=action.item; last.got=action.got; last.want=action.want<10000 and action.want or nil; last.visited=action.visited
    if action.op then
      last.op=action.op; last.got=nil; last.given=action.got; last.errors=action.errors; last.items=action.items
      last.left=math.max(0,#action.targets-action.index+1)>0 and #action.targets-action.index+1 or nil
    end
  end
  stop(body(M.lookup(index)))
  if action and action.borrowed_cursor then
    local p=M.lookup(index)
    if M.bots.is(p) and p.valid and p.character then M.bots.clear_cursor(p)
    elseif p and p.valid and p.connected and p.character and p.character.valid and p.cursor_stack then pcall(p.clear_cursor) end
  end
  s.active[index]=nil
end
local function stop_combat(index,outcome)
  combat_targets()[index]=nil
  local p=body(M.lookup(index))
  local combat=state().combat and state().combat[index]
  local used
  if p and p.valid and p.character and p.character.valid then
    p.shooting_state={state=defines.shooting.not_shooting,position=p.position}
    -- Whole magazines (or shells) gone from the ammo slots since the start.
    if combat and combat.ammo_start then used=math.max(0,combat.ammo_start-kite.ammo_count(p)) end
  end
  if state().combat then state().combat[index]=nil end
  state().last_combat=state().last_combat or {}
  state().last_combat[index]={outcome=outcome,tick=game.tick,ammo_used=used}
end
-- Set while a passive action raises: the bootstrap's failure handler calls
-- stop_player right after, which must leave the queue alone.
local passive_failed=false
function M.stop_player(index,outcome)
  if passive_failed and not outcome then passive_failed=false; return end
  if scheduler then scheduler.pause(index) end
  finish(index,outcome or 'interrupted')
  stop_combat(index,outcome or 'interrupted')
end
function M.stop_all()
  if scheduler then scheduler.pause_all() end
  for index in pairs(state().active) do finish(index,'interrupted') end
  for index in pairs(state().combat or {}) do stop_combat(index,'interrupted') end
end
-- Watchdog for actions that walk: no progress counter change (built, mined,
-- placed, next tile, kills) and under 2 tiles of displacement for STUCK_TICKS
-- means the character is physically stuck, whatever the controller believes.
local WATCH_TICKS,STUCK_TICKS=60,600
local watched={move_to=true,construct=true,build_path=true,gather=true}
local function watch(p,action)
  if not watched[action.kind] or game.tick%WATCH_TICKS~=0 then return end
  local key=table.concat({action.built or 0,action.mined or 0,action.placed or 0,action.next_index or 0,action.kills or 0,action.got or 0,action.index or 0},':')
  local w,pos=action.watch,p.position
  if not w or w.key~=key or action.mining or action.awaiting_craft or distance(pos,w.anchor)>=2 then
    action.watch={key=key,anchor={x=pos.x,y=pos.y},since=game.tick}
  end
end
local function active(index)
  local action=state().active[index]
  if not action then
    local combat=state().combat and state().combat[index]
    return combat and {kind='shoot',until_tick=combat.until_tick} or false
  end
  return {kind=action.kind,until_tick=action.until_tick,direction=action.direction,
    next_index=action.next_index,total=action.cells and #action.cells,placed=action.placed,skipped=action.skipped,
    next_position=action.cells and action.cells[action.next_index] and action.cells[action.next_index].position,
    target=action.entity and action.entity.valid and {name=action.entity.name,position=action.entity.position} or nil,
    kills=action.kills,shooting=action.kind=='kite' and action.target or nil,
    built=action.built,remaining=action.kind=='construct' and construction.remaining(action) or nil,
    missing=action.missing and next(action.missing) and action.missing or nil,
    awaiting_craft=action.awaiting_craft,got=action.got,
    condition=action.kind=='wait_until' and action.condition['until'] or nil,saw=action.kind=='wait_until' and action.saw or nil,
    stuck_s=action.watch and game.tick-action.watch.since>=STUCK_TICKS and math.floor((game.tick-action.watch.since)/60) or nil}
end
M.active=active
-- Our own space platforms are shown whole in remote view: every chunk of
-- their surface counts as charted and visible.
local function own_platform(p)
  local pl=p.surface.platform
  return pl~=nil and pl.force==p.force
end
local function visible(p,pos)
  return distance(p.position,pos) <= 32 and (own_platform(p) or p.force.is_chunk_visible(p.surface, {x=math.floor(pos.x/32), y=math.floor(pos.y/32)}))
end
local function chunk_of(pos) return {x=math.floor(pos.x/32),y=math.floor(pos.y/32)} end
-- Reach and visibility failures say where the character actually stood, so a
-- plan step that ran from an unexpected spot is obvious from its error.
local function from_character(p,pos)
  return string.format('(%g,%g) is %.1f tiles from the character at (%.1f,%.1f)',pos.x,pos.y,distance(p.position,pos),p.position.x,p.position.y)
end
local function assert_visible(p,pos,what)
  if visible(p,pos) then return end
  error(string.format('%s is outside local visible area: %s (limit 32 tiles, in a visible chunk; move_to within 30 tiles first)',what,from_character(p,pos)),2)
end
local function charted(p,pos) return own_platform(p) or p.force.is_chunk_charted(p.surface,chunk_of(pos)) end
-- Read views may be centred anywhere on the charted map, so scripts can look
-- without walking the character there.
local function center(p,a)
  if a.position==nil then return p.position end
  local pos=position(a.position)
  assert(charted(p,pos),'position must be in a charted chunk')
  return pos
end
-- What the player's map shows: everything in visible chunks; in charted but
-- fogged chunks only what stays drawn there (own and neutral entities, enemy
-- structures), never units that may have moved since.
local drawn_enemy={['unit-spawner']=true,turret=true}
local function known(p,e)
  local chunk=chunk_of(e.position)
  if own_platform(p) or p.force.is_chunk_visible(p.surface,chunk) then return true end
  if not p.force.is_chunk_charted(p.surface,chunk) then return false end
  return e.force==p.force or (e.force.name=='neutral' and e.type~='unit') or drawn_enemy[e.type]==true
end
local attached={['rocket-silo-rocket']=true,['rocket-silo-rocket-shadow']=true,['cargo-pod']=true}
local function entity(p,args,read_only)
  local pos = position(args.position)
  assert_visible(p,pos,'target')
  local candidates = p.surface.find_entities_filtered{position=pos, radius=0.2, name=args.name}
  -- Ore under a building is never the intended target unless named explicitly
  -- (resource: the fallback, ore or an item on the ground).
  local found, resource
  local function wanted(e)
    -- A silo's rocket and its cargo pod sit on the silo; they are never the
    -- intended target unless named.
    return e.valid and (not args.unit_number or e.unit_number == args.unit_number) and e.type ~= 'character'
      and (args.name or not attached[e.type])
  end
  for _, e in pairs(candidates) do
    if wanted(e) then
      -- An item lying on a chest's tile is not the target either (shake3:
      -- Grok's "ambiguous target" until the item was picked up).
      if (e.type == 'resource' or e.type == 'item-entity') and not args.name then resource = resource or e
      else
        if found then
          error(string.format('ambiguous target: %s and %s at (%g,%g); specify name or unit_number', found.name, e.name, pos.x, pos.y), 0)
        end
        found = e
      end
    end
  end
  -- Any tile of a building's footprint picks it, as a player's cursor does
  -- (shake3: Gemini's inspect missed buildings off their centre).
  if not found then
    local cover
    for _, e in pairs(p.surface.find_entities_filtered{position=pos, name=args.name}) do
      if wanted(e) and e.type ~= 'resource' and e.type ~= 'item-entity' then
        if cover and cover ~= e then cover = nil; break end
        cover = e
      end
    end
    found = cover
  end
  found = found or resource
  if not found then
    -- Say what is close instead (shake3: 23 of Gemini's inspect misses were a
    -- tile or so from a pole, inserter or belt, or empty).
    local near = {}
    for _, e in pairs(p.surface.find_entities_filtered{position=pos, radius=3, limit=32}) do
      if e.valid and e.type ~= 'resource' and not attached[e.type] and e ~= p.character then near[#near+1] = e end
    end
    table.sort(near, function(x, y) return distance(x.position, pos) < distance(y.position, pos) end)
    local parts = {}
    for i = 1, math.min(3, #near) do
      local e = near[i]
      local name = e.type == 'character' and ((M.character_owner(e) or 'another') .. "'s character") or e.type == 'entity-ghost' and 'ghost ' .. e.ghost_name or e.name
      parts[i] = string.format('%s (%g,%g) %.1f tiles', name, e.position.x, e.position.y, distance(e.position, pos))
    end
    error(string.format('entity not found at (%g,%g): %s; target an entity\'s position as scan lists it (observe scope=scan position={x=%g,y=%g} radius=3)',
      pos.x, pos.y, #parts > 0 and 'nearest ' .. table.concat(parts, ', ') or 'nothing within 3 tiles', pos.x, pos.y), 0)
  end
  -- Reads (inspect) only need sight, as scan does.
  if read_only then return found end
  assert(p.can_reach_entity(found), string.format('entity is out of reach (%.1f tiles from the character)',distance(p.position,found.position)))
  return found
end
-- Remote view (2.0) opens any own entity in a visible chunk, without reach.
local function remote_entity(p,a)
  local pos=position(a.position)
  assert(p.force.is_chunk_visible(p.surface,chunk_of(pos)),'target must be in a visible chunk (remote view)')
  local found,best
  for _,e in pairs(p.surface.find_entities_filtered{position=pos,radius=0.5,name=a.name,force=p.force}) do
    if e.valid and e.type~='entity-ghost' and e.type~='character' and (a.name or not attached[e.type]) and (not a.unit_number or e.unit_number==a.unit_number) then
      local d=distance(e.position,pos)
      if not best or d<best then found,best=e,d end
    end
  end
  assert(found,'no entity of ours at that position')
  return found
end
-- Per-entry failures drop "file:line: " prefixes; rethrows can stack them.
local function reason(err)
  local text,n=tostring(err),1
  while n>0 do text,n=text:gsub('^[^:]*:%d+: ','') end
  return text
end
local function friendly(p,e) assert(e.force == p.force or e.force.name == 'neutral', 'cannot manipulate another force') end
local entity_status_names={}
for name,value in pairs(defines.entity_status or {}) do entity_status_names[value]=name end
-- Defaults are omitted to save agent context: direction north, full health,
-- and the player's own force are implied when absent.
local compass_names={[0]='north',[4]='east',[8]='south',[12]='west'}
local function summary(e)
  local max_health=e.max_health
  local out={name=e.name, type=e.type~=e.name and e.type or nil, position=e.position, unit_number=e.unit_number,
    direction=e.direction~=0 and e.direction or nil, health=e.health and max_health and e.health<max_health and e.health or nil,
    force=e.force.name~='player' and e.force.name or nil, status_name=entity_status_names[e.status], amount=e.type == 'resource' and e.amount or nil,
    ghost_name=(e.type=='entity-ghost' or e.type=='tile-ghost') and e.ghost_name or nil,ghost_type=e.type=='entity-ghost' and e.ghost_type or nil}
  -- An underground end shows what the belt GUI arrows show: which end it is
  -- (flow direction by name) and where its partner is.
  if e.type=='underground-belt' then
    local other=e.neighbours
    out.underground=e.belt_to_ground_type; out.flow=compass_names[e.direction]
    if other then out.paired_with=other.position else out.unpaired=true end
  end
  -- Inserter direction names the pickup side; show the tiles it moves between.
  if e.type=='inserter' then
    local function tile(pos) return {x=math.floor(pos.x)+0.5,y=math.floor(pos.y)+0.5} end
    out.pickup=tile(e.pickup_position); out.drop=tile(e.drop_position)
  end
  -- Pumps and underground pipes likewise: where fluid enters and leaves.
  if e.type=='pump' or e.type=='offshore-pump' or e.type=='pipe-to-ground' then pipes.hint(e,out) end
  return out
end
local function contents(inv) return inv and inv.get_contents() or {} end
local inventories = {
  chest = {'container','logistic-container','linked-container'},
  fuel = {'furnace','assembling-machine','boiler','burner-generator','inserter','mining-drill','lab','car','locomotive','reactor'},
  burnt_result = {'furnace','assembling-machine','boiler','burner-generator','mining-drill','car','locomotive','reactor'},
  furnace_source = {'furnace'}, furnace_result = {'furnace'},
  assembling_machine_input = {'assembling-machine','rocket-silo'}, assembling_machine_output = {'assembling-machine','rocket-silo'},
  lab_input = {'lab'},
  -- Space Age logistics: a silo rocket's cargo, landing pad and platform hub
  -- storage, and what an asteroid collector gathered.
  rocket_silo_rocket = {'rocket-silo'}, cargo_landing_pad_main = {'cargo-landing-pad'}, hub_main = {'space-platform-hub'},
  asteroid_collector_output = {'asteroid-collector'},
  turret_ammo = {'ammo-turret'}, artillery_turret_ammo = {'artillery-turret'}, artillery_wagon_ammo = {'artillery-wagon'},
  car_ammo = {'car'}, car_trunk = {'car'}, spider_ammo = {'spider-vehicle'}, spider_trunk = {'spider-vehicle'},
  cargo_wagon = {'cargo-wagon'}, roboport_robot = {'roboport'}, roboport_material = {'roboport'},
  assembling_machine_modules = {'assembling-machine','rocket-silo'}, furnace_modules = {'furnace'}, lab_modules = {'lab'},
  mining_drill_modules = {'mining-drill'}, beacon_modules = {'beacon'},
  -- A dead character's items: take them (never mine_entity it, which crashes for bots).
  character_corpse = {'character-corpse'}
}
-- Inference order when a transfer omits its inventory (see infer_inventory).
-- Ammo and modules only go where the item's kind says, as a player's click does.
local take_order={'character_corpse','chest','cargo_landing_pad_main','hub_main','asteroid_collector_output','cargo_wagon','car_trunk','spider_trunk','furnace_result','assembling_machine_output','burnt_result','fuel',
  'furnace_source','assembling_machine_input','lab_input','turret_ammo','artillery_turret_ammo','artillery_wagon_ammo','car_ammo','spider_ammo',
  'roboport_robot','roboport_material','rocket_silo_rocket'}
local give_order={'chest','cargo_landing_pad_main','hub_main','cargo_wagon','car_trunk','spider_trunk','furnace_source','assembling_machine_input','lab_input','roboport_robot','roboport_material','fuel','rocket_silo_rocket'}
local ammo_inventory={['ammo-turret']='turret_ammo',['artillery-turret']='artillery_turret_ammo'}
local kind_order={
  ammo={'turret_ammo','artillery_turret_ammo','artillery_wagon_ammo','car_ammo','spider_ammo'},
  module={'assembling_machine_modules','furnace_modules','lab_modules','mining_drill_modules','beacon_modules'}}
local function inventory(e, name)
  local allowed = inventories[name]
  assert(allowed, 'unsupported inventory name')
  local matches = false
  for _, kind in ipairs(allowed) do if e.type == kind then matches=true end end
  assert(matches, 'inventory is not applicable to this entity type')
  local inv = e.get_inventory(defines.inventory[name])
  assert(inv and inv.valid, 'inventory unavailable')
  return inv
end
local handlers = {}
local request_path,navigate,check_args
function handlers.describe()
  local description = {protocol=1, version='0.1.0', max_action_ticks=MAX_TICKS, deduplication_window=256, deduplication_bytes=8*1024*1024,
    target='position:{x,y} (or [x,y]): the entity\'s centre as scan lists it, or any tile of its footprint; optional name and unit_number; targets require local visibility and character reach (inspect: sight only); a miss names the nearest entities',map_view='the user may stay in map view: actions drive the character entity, reach and visibility come from its position',
    actions={
      attach={allow_cheat_mode='boolean; TESTING ONLY default false'},detach={},
      equipment={operation='insert|remove',item='owned equipment item for insert',position='{x,y} grid cell; optional for insert',quality='default normal'},revive_ghost={position='{x,y}',name='optional entity-ghost'},
      shoot={position='{x,y} or auto=true',ticks='1..600',radius='1..32',gun_slot='1..3',
        outcomes='fires real ammo from the ammo slots (fails with none); status last_combat: duration_elapsed | out_of_ammo | interrupted, with ammo_used (whole magazines gone from the slots)'},equip={slot='gun|ammo|armor',item='owned item name',index='default 1'},
      describe={}, inventory={returns='the character inventory: inventory (main), guns, ammo, armor, free (slots), crafting (hand queue), warnings (nearly full, hoarding); the same as observe player and status inv'},
      map={position='optional charted centre (default player)',radius='32..1024 tiles of charted map (default 256)',limit='1..256 regions (default 48)',resources='default true',water='default true',enemies='default true',trees='default false; per-chunk counts',rocks='default false; per-chunk counts',min_count='minimum trees/rocks per chunk (default 1)'}, observe={position='optional charted centre (default player); fogged chunks omit units',radius='1..32 (default 16)', limit='1..512 (default 128)', tiles='boolean (default false)',entity_types='optional array of entity types',entity_names='optional array of names',exclude_resources='boolean',resources='summary (default; connected visible tiles, bounds may include gaps)|tiles|none',group='boolean: entity name->{count,nearest} instead of rows',equipment='boolean: per-equipment rows (default name->count)'},
      status={since='alerts after this tick (default last 5 minutes; losses are also pushed once on any reply in team.alerts)',threats='boolean: rescan now and list every enemy base (default: cached for 10 s, summary lines)',machines='boolean: rescan now and list positions of non-working machines',
        reports='crafting (hand queue: items, seconds left, head entry); spoiling (Space Age: spoilable items carried, "name*count fresh%" stalest first); evolution (factor, time/pollution/kills parts, delta over >=5 min); pollution (total, per_min emitted/absorbed, top 3 emitters, cloud chunks/extent on the chart and directions where it leaves the chart); enemies (bases known from the chart within 512 tiles, nearest with when it was last seen, how many our cloud reaches, next to be reached); chart (charted/visible chunks, extent, radars); alerts (losses: destroyed counts by name and incidents per 64-tile area with causes, attacked areas, attack groups gathering in visible chunks, enemy_news: nest_charted, pollution_reached_nest); inv (free slots); factory (science consumed and plates produced per min over 1m|10m, research eta/next, hand share: items fed/collected/crafted by the character vs factory consumption/production over 10m); machines (per name: working count and other statuses); warnings (inventory nearly full, hoarding, no_fuel, low_power, labs missing packs, research idle or ending)'}, stop={}, walk={direction='north|northeast|east|southeast|south|southwest|west|northwest', ticks='1..600'},
      build_path={points='2..64 tile-centred axis-aligned waypoints; at most 512 belt tiles',item='transport-belt by default',ticks='1..36000',start_index='resume at this tile index; default 1',end_direction='optional final belt direction',note='walks to a far start (or resume tile) with the pathfinder, then steers along the line placing belts'},
      kite={position='optional anchor to clear (walks there when no enemies)',min_distance='keep units at least this far (default 7)',max_distance='band edge (default 12)',range='shoot structures within (default 14)',radius='enemy scan 8..32 (default 32)',min_health='stop below this health fraction (default 0.4)',ticks='1..36000 (default 3600)',outcomes='clear | low_health | out_of_ammo | timed_out; status reports kills, ammo_used'},
      belt_route={from='{x,y} first belt tile, or an existing belt end to extend; the result route lists belt facings in order from it (W2 N1 = two belts facing west, then one facing north; uE4 = underground pair east, exit 4 tiles on)',to='{x,y} last belt tile if free; if it holds our belt or underground entrance, the route feeds into it',
        belt='transport belt entity (default transport-belt); undergrounds of the same tier hop obstacles',undergrounds='default true',lane='left|right: side-load onto this lane of the belt at to (it needs an input from behind)',
        to_direction='free to: last belt direction (default straight on)',dry_run='plan only, place nothing',details='list every entity',
        returns='route (runs like E12 N3, uE5 = underground pair east spanning 5), tiles, items, missing (vs inventory), arrival {mode straight|curve|side_load|end, lane}, placed/failed/bounds (construct defaults to them)',
        note='searches charted ground within 16 tiles around from and to; never passes a tile an existing belt outputs into; turns and undergrounds cost extra'},
      pole_route={from='{x,y}',to='{x,y}',waypoints='optional 1..16 {x,y} to pass through, in order (legs <=512 tiles, route <=1024)',item='pole item (default small-electric-pole)',spacing='tiles between poles (default: wire reach minus room for a 2-tile sideways shift: small 7, medium 8, big 29)',dry_run='boolean: plan only; returns positions',
        note='places pole ghosts along straight legs, shifting a blocked spot up to 2 tiles sideways within wire reach, reusing own poles/ghosts already on the line; returns poles, held, short (craft that many), failed (with reasons), bounds; then construct builds it (trees under ghosts are marked and cleared). Each placed pole joins every network in wire reach'},
      pipe_route={pumps='boolean: when the route (with the pipes it joins) would make a fluid segment past the engine extent limit (320 tiles), place pump ghosts on it (flow from -> to; pumps need power); without it the result warns and lists pump positions',waypoints='optional 1..16 free {x,y} tiles to pass through, in order (each leg <=200 tiles manhattan); without them a route over 150 tiles is split at free tiles along the straight line',from='{x,y} first pipe tile: free ground, or the free tile at a machine fluid connection (joins that machine only), or our pipe/pipe-to-ground/tank or single-connection machine (pumpjack, offshore pump; joined at a free tile by one of its connections)',
        to='{x,y} last pipe tile, same forms as from',pipe='pipe entity (default pipe); its -to-ground variant hops obstacles (reach from its fluid box)',undergrounds='default true',
        dry_run='plan only, place nothing',details='list every entity',
        returns='route (runs like E12 N3, uE10 = pipe-to-ground pair east spanning 10), tiles, items, missing (vs inventory), joins {from,to: name, position, fluid} for ends joined to an entity, placed/failed/bounds (construct defaults to them), segment_extent (tiles, with joined pipes) and, past the limit, extent_warning + pumps [{position,direction}]',
        note='plain pipe connects on every side, so it never goes where another pipe, machine connection or ghost would connect to it (only at a joined end); pipe-to-ground pairs pass beside or under those, belts and obstacles, never along another underground pipe axis or beneath lava/space; free ends stay plain pipe; refuses an end two entities connect to, a machine with several connections (give the tile), and joining two different known fluids; searches charted ground within 16 tiles around from and to'},
      place_ghosts={entities='1..256 {name,position,direction?,type? input|output for undergrounds} at absolute positions in charted chunks; no items needed; a tile or tile item name (landfill, stone-brick, concrete, space-platform-foundation) makes a tile ghost',
        tiles='optional {name, area={left_top,right_bottom}}: fill up to 4096 tile ghosts (landfill over water, foundation beside a platform); returns tiles_placed, tiles_existing (same ghost already there), tiles_refused (not placeable there)',
        platform='optional platform name: place on that space platform (its hub builds ghosts from hub items); positions are platform coordinates, hub at 0,0',['repeat']='optional {count 1..64, dx, dy}: stamp the list count times, each shifted by dx,dy; per-copy rows',returns='placed, failed [{index,error}], bounds (construct defaults to them), obstacles_marked (trees/rocks under the ghosts, marked for deconstruction like a player placement; construct mines them)'},
      construct={area='optional {left_top,right_bottom} <=256x256; default: ghosts from the last paste',ticks='1..216000 (default 36000)',note='builds every ghost in reach from inventory and hand-mines every entity marked for deconstruction (timed like mine; contents to inventory, stops with inventory_full), then walks to the free stand point (never on a footprint) covering the most remaining ghosts near the nearest one; blocked ghosts retry once after moving; trees/rocks under ghosts are marked and mined first; ghosts whose item is in the hand-crafting queue are awaited (status awaiting_craft), not missing; status reports built/mined/remaining/missing/failed; outcomes: constructed (everything done) | incomplete (ghosts left for missing items or failures; a plan step fails) | nothing_to_do (a success, completes at once) | inventory_full | timed_out'},
      move_to={position='{x,y}, within 512 tiles',ticks='1..36000, default 3600',tolerance='0.25..10, default 0.5 (alias within)',pathfind='default true: engine pathfinder (a failed request retries from the nearest free tile centre with a slimmer box, then a wider goal); a stall, back-and-forth, or no progress toward the next waypoint for 90 ticks (e.g. a belt carrying the character back) sidesteps, every 3rd stall replans wider, blocked after 15 stalls; false steers directly',status='last reports replans, stalls, no_progress, paths_failed',outcomes='arrived | arrived_near (stuck within tolerance+1.5, e.g. goal inside an entity) | blocked | timed_out'},
      pickup={ticks='1..600'},repair={position='{x,y}',ticks='1..600',item='repair-pack by default'},
      mine={position='{x,y}', ticks='1..600', name='optional', outcomes='target_mined | duration_elapsed (ore: last reports mined) | inventory_full (blocked_item) | not_minable (a stump, remnant or corpse; last.error) | target_lost | out_of_reach'},
      stock={item='item name; omit for every item held, largest first (items, more)',radius='1..1024 around position (default 128)',position='optional centre (default character)',limit='1..32 places (default 8); without item 1..64 items (default 16)',quality='default normal',
        returns='with item: total held in our machine outputs (assemblers, furnaces), chests and landing pads; by_entity; places nearest first {name,position,count,distance}; made_by (crafters set to a recipe making it); held (your inventory); summary line'},
      craft={force='boolean: hand-craft even when nearby stock covers it',short='when fewer started than asked: the raw ingredients missing for the rest (e.g. "wood short 18 (held 2)"), with stock lines for them',stock='when our machines/chests within 64 tiles hold the product: a stock line per item; a craft of >=3 s of hand time that stock covers is refused (errors) unless force=true',returns='started; hand_s (character crafting seconds for these), queue_s (whole hand queue), assemblers (our machines already set to each recipe); blocks (when the hand queue is >=30s); no_assembler (per recipe no machine runs: the best unlocked assembler and its time for the same batch)',recipe='name',count='1..1000',recipes='optional batch: array of {recipe,count}; each attempted, started/errors keyed by recipe'},craftable={recipes='optional name or array; default every hand recipe startable now (count>0)'},
      rates={area='{left_top,right_bottom} <=192x192',positions='or 1..64 {x,y} machines',per='second|minute (default minute)',
        returns='rows per item: produced, consumed, net at full speed, by/into machines x count; power produced/consumed; errors (no_recipe, no_fuel, no_power, no_resources, ...)',
        note='Rate Calculator formulas: recipe, crafting speed, modules, beacons, productivity, quality, fuel, drill resources; our machines only'},
      bottleneck={area='{left_top,right_bottom} <=192x192',positions='or 1..64 {x,y} machines',
        returns='groups (machine+recipe x count, status counts, short = missing ingredients), limits (input/output inserters slower than the machine at full speed), needs (items consumed beyond area production /min, flagged over one belt), inserters (waiting for source/space), belt_capacity',
        note='inserter rates are estimates (arm rotation x stack size)'},
      grid={platform='optional platform name: act on that space platform (hub at 0,0)',area='{left_top,right_bottom} <=128x128 (instead of position + radius)',position='charted centre (default player)',radius='1..64 (default 16)',returns='one character per tile: rows [{y,row}] from origin, ruler, legend {char: names}. Upper case buildings by type, belts ^>v<, U/J underground in/out, S splitter, ? ghost, @ character, # other; lower case ore; ~ water'},
      power={area='{left_top,right_bottom} <=128x128 (instead of position + radius)',position='charted centre (default player)',radius='1..64 (default 16)',limit='unpowered rows 1..256 (default 32)',note='networks with a pole in the area: poles, production/consumption kW (5 s average) by prototype, unpowered machines (no_power|low_power|unconnected)'},
      scan={platform='optional platform name: act on that space platform (hub at 0,0)',area='{left_top,right_bottom} <=128x128 (instead of position + radius)',position='charted centre (default player)',radius='1..64 (default 16)',positions='or 1..64 {x,y}: just the entities on those tiles (e.g. a few belts\' lanes)',name='optional name or array',type='optional type or array (resources only listed when filtered)',fields='hp|fuel|inventory|output|spoil (spoilable items: count and stalest freshness %)|status|recipe|direction|amount|range (attack range)|ammo|target (turret shooting target)|lanes (belt contents L|R)|io (inserter pickup -> drop, with entities)|fluids (per fluidbox "fluid amount/capacity" then each connection "in|out|io x,y" = the tile it connects to, "=entity" when joined there; underground ends "io uS" with the partner; boxes split by |; ghosts too, from the prototype); other forces under fog show only static fields',limit='1..1024 rows (default 256)',ore='runs (per-row x ranges) or grid (letters, # blocked, ~ water)'},
      nearest={position='optional charted centre (default player)',name='entity name or array',type='entity type or array (name or type required)',radius='1..64 (default 32); map-known entities only',limit='1..64 (default 5)'},cancel_craft={recipe='cancel this recipe\'s own queued crafts (latest first)',index='1-based crafting queue index (instead of recipe)',count='number to cancel (default all of the recipe or entry); refunds through normal game rules'}, build={item='name (a tile item such as landfill, stone-brick, concrete places tiles: size 1..4 square, default 1; landfill only on water)',size='tiles: brush size 1..4',position='{x,y}',direction='compass name (default north)',builds='optional batch of 1..64 {item,position,direction,quality,type}; top-level item/direction/quality are defaults; the first failure fails the action (earlier entries stay built)',type='underground belts: input|output (default: output when an unpaired input flowing the same way is upstream in range); result shows underground, flow, paired_with|unpaired',poles='a placed pole also wires to every other network in wire reach (networks_joined)',inserters='direction is the pickup side (east picks from the east, drops west); results show pickup and drop tiles',note='short of the item while the hand-craft queue makes it: waits for the craft and then builds (awaiting_craft; a timed action, outcome fed | failed | timed_out; use --wait). Your own character the only thing on the footprint: it walks off first and then builds (stepping_aside {from,to}; the same timed action and outcomes; last.result holds the build result)'},
      wire={from='pole {x,y} (optional name/unit_number) in reach',to='pole {x,y} in reach',disconnect='boolean: remove the copper wire instead'},
      inspect={position='{x,y}',note='read-only: any entity in sight (32 tiles, visible chunk) without reach; in_reach says whether acting on it would reach'}, rotate={position='{x,y}',reverse='boolean'},
      configure={position='{x,y}; out of reach works through remote view in any visible chunk (recipe changes then need an empty, idle machine)',recipe='enabled recipe',filters='or: item names for a filtering inserter/loader ([] clears; slot count from the entity)',filter_mode='whitelist|blacklist (inserters)',force='boolean: allow destroying held fluids',returns='returned/spilled {item=count}: contents and interrupted-craft ingredients go to inventory like a player recipe change'},
      transfer={position='{x,y}',positions='optional array of 1..64 {x,y}: same transfer per entity; per-entity rows plus total',inventory='chest|fuel|furnace_source|furnace_result|assembling_machine_input|assembling_machine_output|lab_input|rocket_silo_rocket (silo cargo)|cargo_landing_pad_main|hub_main|asteroid_collector_output|...; inferred when omitted (fuel items->burner fuel, else the first inventory accepting the item, e.g. silo ingredients then rocket cargo; to_player->output or inventory holding item)',item='name; omit with to_player to take everything',quality='default normal',count='1..10000 per entity (default: to_entity 1, or total; to_player all of the item; unlimited when item omitted)',total='optional cap across positions, filled in order; echoed',returns='transferred; inventory_full|entity_full {requested,got,blocked_item} when space ran out; to_entity gives from the main inventory, then (ammo) the gun ammo slots; holding none fails; short of items the hand-craft queue will deliver, it waits for them (awaiting_craft, outcome fed | failed | timed_out)',direction='to_entity|to_player; inferred when omitted (echoed as direction): no item -> to_player; an item only the character holds or is hand-crafting -> to_entity; one only the targets hold -> to_player; both or neither -> error',keep='optional source reserve count',up_to='optional target total cap'},
      feed={note='hand-feeds machines from inventory, nothing taken out: an assembler/furnace gets its recipe\'s item ingredients (an idle furnace its last recipe\'s), a lab its science packs, a burner (furnace, drill, boiler, burner inserter) fuel; each item up to count per machine, keeping keep in inventory. In reach by default; positions or radius (a walking tour, timed: outcomes topped_up | nothing_to_do | out_of_items | timed_out; last reports given, visited, items)',
        radius='1..256: walk a nearest-first route through every machine in radius that wants something you hold',ticks='with radius: 1..36000 (default 3600)',
        positions='optional 1..64 positions instead of everything in reach',items='optional 1..16 item names: give only these',
        count='1..1000 target per ingredient/science pack per machine (default 20)',fuel='fuel item for burners (default coal); false skips fuel',fuel_count='1..1000 fuel target per burner (default 10)',
        keep='reserve of each item kept in inventory (default 0)',types='optional entity type filter (default assembling-machine, furnace, lab, boiler, burner-generator, mining-drill, inserter)',quality='default normal',
        returns='transferred, items {name=count}, entities (position, name, gave), unchanged, held (what is left of each item given)'},
      rearm={radius='1..256: walk a nearest-first route through every turret in radius below count and top it up (a timed action; outcomes topped_up | nothing_to_do | out_of_items | timed_out; last reports given, visited, left)',ticks='with radius: 1..36000 (default 3600)',ammo='ammo item (default firearm-magazine)',count='1..1000 target per turret (default 10)',positions='optional 1..64 positions instead of every turret in reach',types='default {ammo-turret}; artillery-turret allowed',note='gives from the main inventory, then the gun ammo slots (crafted ammo lands there); fails when none is held and turrets want more; waits for ammo in the hand-craft queue (awaiting_craft; outcome fed | failed | timed_out)'},
      refuel={radius='1..256: walk a nearest-first route through every burner in radius below count and top it up (a timed action; outcomes topped_up | nothing_to_do | out_of_items | timed_out; last reports given, visited, left)',ticks='with radius: 1..36000 (default 3600)',fuel='fuel item (default coal)',count='1..1000 target per entity (default 10)',positions='optional 1..64 positions instead of every burner in reach',types='optional entity type filter',note='fails when no fuel is held and burners want more; waits for fuel in the hand-craft queue (awaiting_craft)'},
      collect={types='entity types (default furnace, assembling-machine: machine outputs only)',chests='boolean: also empty plain chests (container, logistic-container) in reach or radius; off by default because chests are usually feed stock you placed (result notes chests_skipped / left_in_chests)',item='optional: only this item',positions='optional 1..64 positions instead of everything in reach (named chests are always taken from)',
        radius='with item: 1..256, walk to our machine outputs/chests holding it (as stock lists), nearest-neighbour route, taking it until count; a timed action',count='with radius: stop after this many (default all)',want='optional, with item: hold this many; takes only the difference (nothing when you already have it); not with count',ticks='with radius: 1..36000 (default 3600)',
        outcomes='with radius: collected | nothing_collected | inventory_full | timed_out; status reports got, visited'},
      research={technology='name (omit everything to report: current, progress, queue, pending)',front='boolean: technology or research_queue goes ahead of the current queue (overflow drops from the tail)',append='boolean: research_queue goes after the current queue',research_queue='array of ordered names; without front/append it replaces the queue ([] clears it)',returns='queue; skipped "name: reason" (unknown|already_researched|not_enabled|trigger_unlocked): dropped; pending: names beyond the engine queue cap (or waiting on prerequisites), kept and fed in as the queue frees up (adding more keeps them; a plain research_queue replaces them); added_prerequisites {tech: [names]}: unresearched prerequisites inserted ahead of each requested tech, like the game GUI'},research_next={technologies='prioritized list; starts first available only when research is idle'}, recipes={prefix='optional',limit='1..256'}, technologies={prefix='optional',limit='1..256',available='boolean: only unresearched ones whose prerequisites are done (what can be researched or triggered now)',returns='entries; trigger names what unlocks a trigger technology (craft 50 iron-plate, mine crude-oil, create a space platform, launch X to orbit, ...): labs never research those'},
      blueprint_import={blueprint='export string',slot='default clipboard'},blueprint_export={slot='default clipboard',layout='true returns normalized relative layout and material costs instead of export string'},blueprint_list={},blueprint_delete={slot='name'},
      blueprint_capture={area='{left_top:{x,y},right_bottom:{x,y}}',slot='default clipboard',tiles='boolean',station_names='boolean'},copy={area='{left_top:{x,y},right_bottom:{x,y}}'},cut={area='{left_top:{x,y},right_bottom:{x,y}}'},paste={platform='optional platform name: act on that space platform (hub at 0,0)',position='{x,y}',['repeat']='optional {count 1..64, dx, dy}: paste count copies, each shifted by dx,dy; totals plus per-copy rows',slot='default clipboard',direction='north|east|south|west',flip_horizontal='boolean',flip_vertical='boolean',book_path='array of 1-based book indices',details='boolean: list every ghost'},blueprint_place={platform='optional platform name: act on that space platform (hub at 0,0)',position='{x,y}',['repeat']='optional {count 1..64, dx, dy}: paste count copies, each shifted by dx,dy; totals plus per-copy rows',slot='default clipboard',direction='north|east|south|west',flip_horizontal='boolean',flip_vertical='boolean',book_path='array of 1-based book indices',details='boolean: list every ghost'},deconstruct={platform='optional platform name: act on that space platform (hub at 0,0)',area='{left_top:{x,y},right_bottom:{x,y}} up to 256x256 of charted map',entity_names='optional array',entity_types='optional array'},cancel_deconstruction={platform='optional platform name: act on that space platform (hub at 0,0)',area='{left_top:{x,y},right_bottom:{x,y}}'},
      screenshot={path='relative .png path under script-output',width='320..1920',height='240..1080'}},
    limitations={'No teleport, resource creation, free crafting, direct mining, remote building, or map reveal',
      'Runtime source installation is trusted operator code, not a security sandbox',
      'Screenshots require a graphical client controlling the requested player; headless hosts do not render',
      'Vehicles, rail placement, circuit wiring, and fluid transfers are unsupported',
      'Walk/mine completion is bounded by ticks; inspect status and observe to verify outcomes'}}
  for name,schema in pairs(scheduler and scheduler.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(clock and clock.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.chat and M.chat.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(space and space.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.profiles.schema) do description.actions[name]=schema end
  for name,schema in pairs(M.board and M.board.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.waits and M.waits.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.labs and M.labs.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.audience and M.audience.schema or {}) do description.actions[name]=schema end
  description.actions.cameras={returns='director cameras: player, follow, position, zoom'}
  description.runtime_fault=state().runtime_fault or false
  return description
end
function handlers.attach(p,a)
  state().controlled=state().controlled or {}
  assert(a.offline~=true,'offline control is unsupported; join a graphical Factorio client')
  state().controlled[p.index]={allow_cheat_mode=a.allow_cheat_mode==true}
  return {player=p.index,connected=p.connected,allow_cheat_mode=a.allow_cheat_mode==true}
end
function handlers.detach(p)
  M.stop_player(p.index)
  if state().controlled then state().controlled[p.index]=nil end
  return {detached=true}
end
-- Losses (buildings destroyed) are kept as incidents: one per 64-tile cell,
-- counting every entity by name, so a wiped outpost is reported whole.
local LOSS_CELL,MAX_INCIDENTS=64,64
local function record_loss(tick,e,cause)
  local s=state()
  s.losses=s.losses or {}
  local cx,cy=math.floor(e.position.x/LOSS_CELL),math.floor(e.position.y/LOSS_CELL)
  local key=cx..','..cy
  local incident
  for _,i in ipairs(s.losses) do if i.key==key then incident=i; break end end
  if not incident then
    incident={key=key,box={e.position.x,e.position.y,e.position.x,e.position.y},first=tick,names={},causes={},total=0}
    s.losses[#s.losses+1]=incident
    if #s.losses>MAX_INCIDENTS then
      local oldest=1
      for i,v in ipairs(s.losses) do if v.last<s.losses[oldest].last then oldest=i end end
      table.remove(s.losses,oldest)
    end
  end
  s.loss_seq=(s.loss_seq or 0)+1
  local b=incident.box
  b[1],b[2],b[3],b[4]=math.min(b[1],e.position.x),math.min(b[2],e.position.y),math.max(b[3],e.position.x),math.max(b[4],e.position.y)
  incident.last=tick; incident.seq=s.loss_seq; incident.total=incident.total+1
  incident.names[e.name]=(incident.names[e.name] or 0)+1
  if cause then incident.causes[cause]=(incident.causes[cause] or 0)+1 end
end
local function losses_since(since)
  local out={}
  for _,i in ipairs(state().losses or {}) do if i.last>since then out[#out+1]=i end end
  table.sort(out,function(a,b) return a.last>b.last end)
  return out
end
local function ago(ticks)
  local sec=math.floor(ticks/60)
  if sec>=3600 then return string.format('%dh%02dm',math.floor(sec/3600),math.floor(sec/60)%60) end
  if sec>=60 then return string.format('%dm%02ds',math.floor(sec/60),sec%60) end
  return sec..'s'
end
local function counted(t)
  local names={}
  for name,n in pairs(t) do names[#names+1]={name,n} end
  table.sort(names,function(a,b) return a[2]>b[2] or a[2]==b[2] and a[1]<b[1] end)
  for i,v in ipairs(names) do names[i]=v[2]..' '..v[1] end
  return names
end
local function describe_incident(i)
  local names=counted(i.names)
  while #names>6 do table.remove(names) end
  local causes=counted(i.causes)
  while #causes>2 do table.remove(causes) end
  local span=i.first==i.last and ago(game.tick-i.last)..' ago' or ago(game.tick-i.first)..'-'..ago(game.tick-i.last)..' ago'
  local b=i.box
  local where=string.format('(%d,%d)',math.floor(b[1]),math.floor(b[2]))
  if b[3]-b[1]>=1 or b[4]-b[2]>=1 then where=where..'-'..string.format('(%d,%d)',math.floor(b[3]),math.floor(b[4])) end
  return string.format('in %s %d destroyed: %s%s, %s',where,i.total,table.concat(names,', '),
    #causes>0 and ' by '..table.concat(causes,', ') or '',span)
end
-- Losses this player has not been told about, once, in the reply's team
-- alerts. Incidents that grew since are repeated whole so the totals stay readable.
local function unseen_losses(p)
  local s=state()
  s.losses_seen=s.losses_seen or {}
  local seen=s.losses_seen[p.index] or 0
  s.losses_seen[p.index]=s.loss_seq or 0
  local incidents={}
  for _,i in ipairs(s.losses or {}) do if (i.seq or 0)>seen then incidents[#incidents+1]=i end end
  if #incidents==0 then return nil end
  table.sort(incidents,function(a,b) return a.seq>b.seq end)
  local lines={}
  for n,i in ipairs(incidents) do
    if n>4 then lines[#lines+1]=string.format('+%d more areas with losses; status alerts lists them',#incidents-4); break end
    lines[#lines+1]=describe_incident(i):gsub('^in ','losses in ',1)
  end
  return lines
end
local function recent_alerts(a)
  local since=a.since or game.tick-18000
  local counts,latest={},{}
  for _,i in ipairs(losses_since(since)) do
    for name,n in pairs(i.names) do counts[name]=(counts[name] or 0)+n end
    if #latest<8 then latest[#latest+1]=describe_incident(i) end
  end
  local attacks=threat.alerts(since)
  local kills={}
  for _,k in ipairs(state().kills or {}) do if k.tick>since then kills[k.name]=(kills[k.name] or 0)+1 end end
  if #latest==0 and not attacks and not next(kills) then return nil end
  local result=attacks or {}
  if #latest>0 then result.losses=counts; result.latest=latest end
  result.kills=next(kills) and kills or nil
  return result
end
-- Hand-crafting queue as the crafting panel shows it, with the time left at
-- the character's crafting speed.
local function hand_speed(p)
  return 1+(p.character and p.character.character_crafting_speed_modifier or 0)+(p.force.manual_crafting_speed_modifier or 0)
end
-- Seconds of hand crafting left in the queue, and its item count.
local function crafting_left(p)
  local queue=p.crafting_queue
  if not queue or #queue==0 then return 0,0 end
  local items,seconds=0,0
  for _,entry in ipairs(queue) do
    local recipe=p.force.recipes[entry.recipe]
    if not entry.prerequisite then items=items+entry.count end
    seconds=seconds+(recipe and recipe.energy or 0.5)*entry.count
  end
  local head_recipe=p.force.recipes[queue[1].recipe]
  seconds=seconds-(head_recipe and head_recipe.energy or 0.5)*(p.crafting_queue_progress or 0)
  return math.max(0,seconds)/hand_speed(p),items
end
-- Items of this name the hand-crafting queue will still deliver (final
-- entries only; prerequisite crafts are consumed by the entry they feed).
local function crafting_count(p,item)
  local n=0
  for _,entry in ipairs(p.crafting_queue or {}) do
    local recipe=not entry.prerequisite and p.force.recipes[entry.recipe]
    for _,product in ipairs(recipe and recipe.products or {}) do
      if product.name==item then n=n+(product.amount or product.amount_max or 1)*entry.count end
    end
  end
  return n
end
local function crafting_line(p)
  local queue=p.crafting_queue
  if not queue or #queue==0 then return nil end
  local seconds,items=crafting_left(p)
  return string.format('%d items, ~%ds left, head=%s x%d',items,math.ceil(seconds),queue[1].recipe,queue[1].count)
end
-- A paused plan still holding steps is easy to forget between sessions.
local function queue_warning(index)
  local q=state().queues and state().queues[index]
  if not (q and q.paused and #q.pending>0) then return nil end
  local first,last=q.pending[1],q.history[#q.history]
  local cause=''
  if last and last.ok==false and last.id then
    local why=type(last.result)=='table' and (last.result.reason or last.result.outcome) or nil
    cause=string.format('; paused when %s %s failed%s',last.id,last.action,why and ': '..reason(why) or '')
  end
  return string.format('queue: paused with %d pending step%s (first: %s %s%s)%s; queue resume runs them, queue cancel drops them',
    #q.pending,#q.pending==1 and '' or 's',first.id or '?',first.action,first.label and ' ['..first.label..']' or '',cause)
end
function handlers.status(p,a)
  a=a or {}
  local controllable,control_error=pcall(player,p.index)
  local alive=p.character and p.character.valid
  local threats=alive and threat.summary(p,a.threats==true) or {}
  -- Status is the recovery channel; a survey fault is reported, not raised.
  local surveyed,factory=true,{}
  if alive then surveyed,factory=pcall(survey.summary,p,a.machines==true) end
  if not surveyed then factory={error=reason(factory)} end
  local now=active(p.index)
  local paused=queue_warning(p.index)
  if paused then
    factory.warnings=factory.warnings or {}
    table.insert(factory.warnings,1,paused)
  end
  -- Fluid segments past the engine's extent limit carry no flow at all.
  if alive then
    local fc=state().fluid_check
    if not fc or fc.surface~=p.surface.index or game.tick-fc.tick>=600 then
      local ok,list,limit=pcall(pipes.overlong,p,3)
      fc={tick=game.tick,surface=p.surface.index,list=ok and list or {},limit=limit}
      state().fluid_check=fc
    end
    for _,seg in ipairs(fc.list) do
      factory.warnings=factory.warnings or {}
      local b=seg.box
      factory.warnings[#factory.warnings+1]=string.format('fluid: %s segment spans %d tiles (limit %d) over (%d,%d)-(%d,%d), e.g. at (%g,%g): the game stops all flow into it; split it with a pump',
        seg.fluid and 'a '..seg.fluid or 'an empty',seg.extent,fc.limit,b[1],b[2],b[3],b[4],seg.at.x,seg.at.y)
    end
  end
  -- Fighting right now (hits in the last 10 s) goes first, with where.
  local fresh=alive and threat.alerts(game.tick-600)
  local shown=0
  for _,area in ipairs(fresh and fresh.attacked or {}) do
    -- Zero-damage hits (the crash site's fire) are not a fight.
    if shown<3 and area.damage>0 then
      shown=shown+1
      factory.warnings=factory.warnings or {}
      table.insert(factory.warnings,shown,string.format('under attack near (%g,%g): %s hit %d times%s, %s ago',area.chunk_centre.x,area.chunk_centre.y,
        area.entities,area.hits,area.by and ' by '..area.by or '',ago(game.tick-area.last_tick)))
    end
  end
  if now and now.stuck_s then
    factory.warnings=factory.warnings or {}
    table.insert(factory.warnings,1,string.format('character: %s made no progress and moved under 2 tiles for %ds near (%.1f,%.1f); likely physically stuck (belt, obstacle, unreachable goal): cancel or redirect it',
      now.kind,now.stuck_s,p.position.x,p.position.y))
  end
  return {crafting=alive and crafting_line(p) or nil,inv=factory.inv,factory=factory.factory,machines=factory.machines,machine_positions=factory.machine_positions,warnings=factory.warnings,factory_as_of=factory.as_of,survey_error=factory.error,
    evolution=threats.evolution,pollution=threats.pollution,enemies=threats.enemies,chart=threats.chart,threats_as_of=threats.as_of,
    alerts=recent_alerts(a),runtime_fault=state().runtime_fault or false,connected=p.connected,alive=p.character and p.character.valid or false,cheat_mode=p.cheat_mode,
    supported_control=controllable,control_error=not controllable and tostring(control_error) or nil,active=now,
    spoiling=alive and spoil_text(main_inventory(p)) or nil,
    surface=alive and p.surface.name or nil,platform=alive and p.surface.platform and p.surface.platform.name or nil,riding=p.driving or nil, last=state().last and state().last[p.index] or false, combat=state().combat and state().combat[p.index] or false, last_combat=state().last_combat and state().last_combat[p.index] or false, tick=game.tick, position=p.position}
end
-- The character's inventory on its own (shake2: `call inventory` failed 15
-- times): observe's player inventories plus status's free-slot line.
function handlers.inventory(p)
  local free,warnings=survey.inventory(p)
  return {inventory=contents(p.get_main_inventory()),guns=contents(p.get_inventory(defines.inventory.character_guns)),
    ammo=contents(p.get_inventory(defines.inventory.character_ammo)),armor=contents(p.get_inventory(defines.inventory.character_armor)),
    free=free,crafting=crafting_line(p),warnings=warnings and #warnings>0 and warnings or nil}
end
-- Connected visible resource tiles are summarized separately from structures so a
-- large ore patch cannot consume the entity budget and hide machines or enemies.
local function resource_patches(entities)
  local remaining, patches = {}, {}
  local function key(name,x,y) return name..':'..x..':'..y end
  for _,e in ipairs(entities) do remaining[key(e.name,math.floor(e.position.x),math.floor(e.position.y))]=e end
  for _,seed in ipairs(entities) do
    local sx,sy=math.floor(seed.position.x),math.floor(seed.position.y)
    if remaining[key(seed.name,sx,sy)] then
      local patch={name=seed.name,tiles=0,amount=0,left=sx,top=sy,right=sx+1,bottom=sy+1}
      local queue,head={{sx,sy,seed.amount or 0}},1
      remaining[key(seed.name,sx,sy)]=nil
      while head<=#queue do
        local cell=queue[head]; head=head+1
        local x,y=cell[1],cell[2]
        patch.tiles=patch.tiles+1
        patch.amount=patch.amount+cell[3]
        patch.left=math.min(patch.left,x); patch.top=math.min(patch.top,y)
        patch.right=math.max(patch.right,x+1); patch.bottom=math.max(patch.bottom,y+1)
        for _,d in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
          local nx,ny=x+d[1],y+d[2]
          local k=key(seed.name,nx,ny); local e=remaining[k]
          if e then remaining[k]=nil; queue[#queue+1]={nx,ny,e.amount or 0} end
        end
      end
      patches[#patches+1]=patch
    end
  end
  return patches
end
-- Live map queries require current visibility. Merely explored chunks may be
-- fog-covered: reading their current entities would expose unseen expansions.
-- Historical map knowledge must come from previously observed snapshots.
function handlers.map(p,a)
  local radius=integer(a.radius,256,32,1024,'radius')
  local want={resources=a.resources~=false,water=a.water~=false,enemies=a.enemies~=false}
  local surface,force=p.surface,p.force
  local origin=center(p,a)
  local cx0,cy0=math.floor(origin.x/32),math.floor(origin.y/32)
  local r=math.ceil(radius/32)
  local cells={}
  local function add(kind,name,cx,cy,count,amount,box)
    local k=name..':'..cx..':'..cy
    local c=cells[k] or {kind=kind,name=name,cx=cx,cy=cy,count=0,amount=0,left=box.left,top=box.top,right=box.right,bottom=box.bottom}
    cells[k]=c
    c.count=c.count+count; c.amount=c.amount+(amount or 0)
    c.left=math.min(c.left,box.left); c.top=math.min(c.top,box.top); c.right=math.max(c.right,box.right); c.bottom=math.max(c.bottom,box.bottom)
  end
  local water_names={}
  for name,tile in pairs(prototypes.tile) do
    if tile.collision_mask and tile.collision_mask.layers and tile.collision_mask.layers.water_tile and not tile.collision_mask.layers.ground_tile then water_names[#water_names+1]=name end
  end
  for cx=cx0-r,cx0+r do
    for cy=cy0-r,cy0+r do
      -- The player's map keeps charted ore, water and enemy bases drawn under
      -- fog of war, so charted (not currently visible) is the fair boundary.
      if force.is_chunk_charted(surface,{x=cx,y=cy}) then
        local area={{cx*32,cy*32},{cx*32+32,cy*32+32}}
        if want.resources then
          for _,e in pairs(surface.find_entities_filtered{area=area,type='resource'}) do
            local x,y=math.floor(e.position.x),math.floor(e.position.y)
            if math.floor(x/32)==cx and math.floor(y/32)==cy then
              add('resource',e.name,cx,cy,1,e.amount,{left=x,top=y,right=x+1,bottom=y+1})
            end
          end
        end
        if want.water and #water_names>0 then
          local n=surface.count_tiles_filtered{area=area,name=water_names}
          if n>0 then add('water','water',cx,cy,n,0,{left=cx*32,top=cy*32,right=cx*32+32,bottom=cy*32+32}) end
        end
        for _,kind in ipairs({'tree','rock'}) do
          if a[kind..'s'] then
            local filter=kind=='tree' and {area=area,type=(script and script.active_mods['space-age']) and {'tree','plant'} or 'tree'} or {area=area,type='simple-entity'}
            for _,e in pairs(surface.find_entities_filtered(filter)) do
              local x,y=math.floor(e.position.x),math.floor(e.position.y)
              if math.floor(x/32)==cx and math.floor(y/32)==cy and (kind=='tree' or e.name:find('rock')) then
                add(kind,kind..'s',cx,cy,1,0,{left=x,top=y,right=x+1,bottom=y+1})
              end
            end
          end
        end
        if want.enemies then
          for _,e in pairs(surface.find_entities_filtered{area=area,type={'unit-spawner','turret'},force='enemy'}) do
            local x,y=math.floor(e.position.x),math.floor(e.position.y)
            -- Area searches include overlapping collision boxes. Attribute an
            -- entity only to its center's chunk, never an adjacent hidden one.
            if math.floor(x/32)==cx and math.floor(y/32)==cy then
              add('enemy','enemy-base',cx,cy,1,0,{left=x,top=y,right=x+1,bottom=y+1})
            end
          end
        end
      end
    end
  end
  local regions={}
  local seen={}
  -- Trees and rocks are scattered everywhere: report per-chunk density
  -- (at least min_count) instead of merging them into one huge region.
  local min_count=integer(a.min_count,1,1,1024,'min_count')
  for k,c in pairs(cells) do
    if (c.kind=='tree' or c.kind=='rock') and not seen[k] then
      seen[k]=true
      if c.count>=min_count then
        local mid={x=c.cx*32+16,y=c.cy*32+16}
        regions[#regions+1]={kind=c.kind,name=c.name,count=c.count,left=c.left,top=c.top,right=c.right,bottom=c.bottom,center=mid,distance=math.floor(distance(origin,mid))}
      end
    end
  end
  for k,c in pairs(cells) do
    if not seen[k] then
      seen[k]=true
      local region={kind=c.kind,name=c.name,count=0,amount=0,left=c.left,top=c.top,right=c.right,bottom=c.bottom}
      local queue,head={c},1
      while head<=#queue do
        local cell=queue[head]; head=head+1
        region.count=region.count+cell.count; region.amount=region.amount+cell.amount
        region.left=math.min(region.left,cell.left); region.top=math.min(region.top,cell.top)
        region.right=math.max(region.right,cell.right); region.bottom=math.max(region.bottom,cell.bottom)
        for dx=-1,1 do for dy=-1,1 do
          local nk=c.name..':'..(cell.cx+dx)..':'..(cell.cy+dy)
          if cells[nk] and not seen[nk] then seen[nk]=true; queue[#queue+1]=cells[nk] end
        end end
      end
      region.center={x=math.floor((region.left+region.right)/2),y=math.floor((region.top+region.bottom)/2)}
      region.distance=math.floor(distance(origin,region.center))
      if region.kind~='resource' then region.amount=nil end
      regions[#regions+1]=region
    end
  end
  table.sort(regions,function(x,y) return x.distance<y.distance end)
  local limit=integer(a.limit,48,1,256,'limit')
  local out={regions={},truncated=#regions>limit,radius=radius,
    scope='charted chunks (as drawn on the player map); bounds may include gaps; count is tiles (water, ore) or structures (enemy)'}
  for i=1,math.min(limit,#regions) do out.regions[i]=regions[i] end
  return out
end
-- Cheap targeting: the nearest matches around the player or any charted
-- position, limited to what the player's map shows.
function handlers.nearest(p,a)
  assert(a.name or a.type,'name or type is required')
  for _,key in ipairs({'name','type'}) do
    local v=a[key]
    assert(v==nil or type(v)=='string' or (type(v)=='table' and #v>=1 and #v<=32),key..' must be a string or 1..32 strings')
  end
  local radius=integer(a.radius,32,1,64,'radius')
  local limit=integer(a.limit,5,1,64,'limit')
  local origin,rows=center(p,a),{}
  for _,e in pairs(p.surface.find_entities_filtered{position=origin,radius=radius,name=a.name,type=a.type}) do
    if e.valid and e~=p.character and known(p,e) then rows[#rows+1]={entity=e,distance=distance(origin,e.position)} end
  end
  table.sort(rows,function(x,y)
    if x.distance~=y.distance then return x.distance<y.distance end
    local u,v=x.entity.position,y.entity.position
    if u.x~=v.x then return u.x<v.x end
    return u.y<v.y
  end)
  -- A single requested name is implied; otherwise each row names its entity.
  local named=not (type(a.name)=='string' or (type(a.name)=='table' and #a.name==1))
  local out={entities={},total=#rows}
  for i=1,math.min(limit,#rows) do
    local e=rows[i].entity
    out.entities[i]={name=named and e.name or nil,position=e.position,distance=math.floor(rows[i].distance*10+0.5)/10}
  end
  return out
end
local function stacks_text(list)
  local parts={}
  for _,s in ipairs(list) do parts[#parts+1]=s.name..(s.quality and s.quality~='normal' and '@'..s.quality or '')..'*'..s.count end
  return #parts>0 and table.concat(parts,' ') or 'empty'
end
local function fuel_inventory(e) local ok,inv=pcall(e.get_fuel_inventory); return ok and inv or nil end
-- Opt-in per-entity columns; each is a short string or number.
local scan_fields={
  hp=function(e) return e.health and e.max_health and e.max_health>0 and math.floor(e.health+0.5)..'/'..math.floor(e.max_health+0.5) or nil end,
  fuel=function(e) local inv=fuel_inventory(e); return inv and stacks_text(inv.get_contents()) or nil end,
  inventory=function(e)
    local all,any={},false
    for _,name in ipairs(take_order) do
      local ok,inv=false,nil
      if name~='fuel' then ok,inv=pcall(inventory,e,name) end
      if ok then any=true; for _,s in ipairs(inv.get_contents()) do all[#all+1]=s end end
    end
    return any and stacks_text(all) or nil
  end,
  output=function(e) local ok,inv=pcall(e.get_output_inventory); return ok and inv and stacks_text(inv.get_contents()) or nil end,
  spoil=function(e)
    local parts={}
    for _,name in ipairs(take_order) do
      local ok,inv=false,nil
      if name~='fuel' then ok,inv=pcall(inventory,e,name) else ok,inv=true,fuel_inventory(e) end
      local text=ok and spoil_text(inv,4)
      if text then parts[#parts+1]=text end
    end
    return #parts>0 and table.concat(parts,' | ') or nil
  end,
  status=function(e) return entity_status_names[e.status] end,
  recipe=function(e) local ok,r=pcall(e.get_recipe); return ok and r and r.name or nil end,
  direction=function(e) return e.supports_direction and e.direction or nil end,
  amount=function(e) return e.type=='resource' and e.amount or nil end,
  -- Attack range from the prototype (turrets, worms, units); spawners have none.
  range=function(e)
    local proto=e.prototype
    local ok,r=pcall(function() return proto.turret_range or (proto.attack_parameters and proto.attack_parameters.range) end)
    return ok and r or nil
  end,
  ammo=function(e)
    local name=ammo_inventory[e.type] or (e.type=='car' and 'car_ammo') or (e.type=='spider-vehicle' and 'spider_ammo')
    local ok,inv=false,nil
    if name then ok,inv=pcall(inventory,e,name) end
    return ok and stacks_text(inv.get_contents()) or nil
  end,
  -- Belt lanes (left|right, in flow direction); splitters and undergrounds
  -- have more transport lines, listed in engine order.
  lanes=function(e)
    local ok,n=pcall(e.get_max_transport_line_index)
    if not ok or not n or n<1 then return nil end
    local parts={}
    for i=1,n do parts[#parts+1]=(n==2 and (i==1 and 'L' or 'R') or tostring(i))..': '..stacks_text(e.get_transport_line(i).get_contents()) end
    return table.concat(parts,' | ')
  end,
  -- Inserter pickup and drop positions with the entity found at each.
  io=function(e)
    if e.type~='inserter' then return nil end
    local function at(pos)
      local target=e.surface.find_entities_filtered{position=pos,limit=1,type={'resource','character','corpse','character-corpse','item-entity','item-request-proxy','sticker','fire','smoke-with-trigger','projectile','entity-ghost','tile-ghost'},invert=true}[1]
      return string.format('%g,%g',pos.x,pos.y)..(target and ' '..target.name or '')
    end
    return at(e.pickup_position)..' -> '..at(e.drop_position)
  end,
  -- Fluidboxes with contents and where each pipe connection leads.
  fluids=function(e) return pipes.fluids(e) end,
  target=function(e)
    local ok,t=pcall(function() return e.shooting_target end)
    return ok and t and t.valid and t.name..'@'..math.floor(t.position.x+0.5)..','..math.floor(t.position.y+0.5) or nil
  end,
}
-- Fields that change over time; hidden for other forces' entities under fog.
local live_fields={hp=true,fuel=true,inventory=true,output=true,spoil=true,status=true,ammo=true,target=true,amount=true,lanes=true,fluids=true}
-- Ore letters are stable per name within one reply: the first unused letter
-- of the name, upper-cased.
local function ore_letters(names)
  local legend,used={},{['#']=true,['~']=true,['.']=true}
  table.sort(names)
  for _,name in ipairs(names) do
    for ch in (name:upper()..'ABCDEFGHIJKLMNOPQRSTUVWXYZ'):gmatch('%u') do
      if not used[ch] then used[ch]=true; legend[name]=ch; break end
    end
  end
  return legend
end
-- One compact row per entity plus optional ore layout, over a radius around
-- any charted position or an explicit area (<=128x128).
-- An explicit area up to 128x128, or a square around a charted centre.
local function view_area(p,a)
  if a.area then
    assert(type(a.area)=='table','area requires left_top and right_bottom')
    local lt,rb=position(a.area.left_top),position(a.area.right_bottom)
    assert(rb.x>lt.x and rb.y>lt.y and rb.x-lt.x<=128 and rb.y-lt.y<=128,'area must be nonempty and at most 128x128')
    return {left_top=lt,right_bottom=rb}
  end
  local c,r=center(p,a),integer(a.radius,16,1,64,'radius')
  return {left_top={x=c.x-r,y=c.y-r},right_bottom={x=c.x+r,y=c.y+r}}
end
function handlers.scan(p,a)
  local area=a.positions==nil and view_area(p,a) or nil
  for _,key in ipairs({'name','type','fields'}) do
    local v=a[key]
    assert(v==nil or type(v)=='string' or (type(v)=='table' and #v<=32),key..' must be a string or up to 32 strings')
  end
  local fields=type(a.fields)=='string' and {a.fields} or a.fields or {}
  for _,f in ipairs(fields) do assert(scan_fields[f],'unknown field '..tostring(f)..'; use hp|fuel|inventory|output|spoil|status|recipe|direction|amount|range|ammo|target|lanes|io|fluids') end
  local limit=integer(a.limit,256,1,1024,'limit')
  local filtered=a.name~=nil or a.type~=nil
  local out={entities={},truncated=false}
  local rows,ores,blocked={}, {}, {}
  local candidates
  if a.positions~=nil then
    assert(a.area==nil and a.position==nil and a.radius==nil and a.ore==nil,'positions replaces area, position, radius and ore')
    assert(type(a.positions)=='table' and #a.positions>=1 and #a.positions<=64,'positions requires 1..64 {x,y}')
    candidates={}
    local seen={}
    for _,raw in ipairs(a.positions) do
      local pos=position(raw)
      for _,e in pairs(p.surface.find_entities_filtered{position=pos,radius=0.3,name=a.name,type=a.type}) do
        if not seen[e] then seen[e]=true; candidates[#candidates+1]=e end
      end
    end
  else candidates=p.surface.find_entities_filtered{area=area,name=a.name,type=a.type} end
  for _,e in pairs(candidates) do
    if e.valid and e~=p.character and known(p,e) then
      if e.type=='resource' and a.ore then ores[#ores+1]=e end
      if e.type~='resource' or filtered then rows[#rows+1]=e end
    end
  end
  table.sort(rows,function(x,y)
    local u,v=x.position,y.position
    if u.y~=v.y then return u.y<v.y end
    if u.x~=v.x then return u.x<v.x end
    return x.name<y.name
  end)
  for _,e in ipairs(rows) do
    if #out.entities>=limit then out.truncated=true; break end
    local row={name=e.name,position=e.position}
    if e.type=='entity-ghost' or e.type=='tile-ghost' then row.ghost_name=e.ghost_name; row.ghost_type=e.ghost_type end
    local live=e.force==p.force or p.force.is_chunk_visible(p.surface,chunk_of(e.position))
    for _,f in ipairs(fields) do if live or not live_fields[f] then row[f]=scan_fields[f](e) end end
    out.entities[#out.entities+1]=row
  end
  out.total=#rows
  if a.ore then
    assert(a.ore=='runs' or a.ore=='grid','ore must be runs or grid')
    -- Ore needs its own unfiltered query when rows were filtered by name/type.
    if filtered then
      ores={}
      for _,e in pairs(p.surface.find_entities_filtered{area=area,type='resource'}) do
        if known(p,e) then ores[#ores+1]=e end
      end
    end
    local totals,names,cells={},{},{}
    for _,e in ipairs(ores) do
      local t=totals[e.name]
      if not t then t={name=e.name,tiles=0,amount=0}; totals[e.name]=t; names[#names+1]=e.name end
      t.tiles=t.tiles+1; t.amount=t.amount+e.amount
      cells[math.floor(e.position.y)..':'..math.floor(e.position.x)]=e.name
    end
    local legend=ore_letters(names)
    out.ore={legend={},totals={}}
    for _,name in ipairs(names) do out.ore.legend[legend[name]]=name; out.ore.totals[#out.ore.totals+1]=totals[name] end
    local left,top=math.floor(area.left_top.x),math.floor(area.left_top.y)
    local right,bottom=math.ceil(area.right_bottom.x)-1,math.ceil(area.right_bottom.y)-1
    out.ore.rows={}
    if a.ore=='grid' then
      -- Drill layout needs obstacles too: '#' marks tiles under other entities
      -- (trees, rocks, buildings), '~' marks water.
      for _,e in pairs(p.surface.find_entities_filtered{area=area}) do
        local layers=e.valid and e.type~='resource' and e.prototype.collision_mask and e.prototype.collision_mask.layers or {}
        if (layers.object or layers.player or layers.cliff) and e~=p.character and known(p,e) then
          local box=e.bounding_box
          for y=math.floor(box.left_top.y),math.ceil(box.right_bottom.y)-1 do
            for x=math.floor(box.left_top.x),math.ceil(box.right_bottom.x)-1 do blocked[y..':'..x]='#' end
          end
        end
      end
      for _,tile in pairs(p.surface.find_tiles_filtered{area=area,collision_mask='water_tile'}) do
        blocked[math.floor(tile.position.y)..':'..math.floor(tile.position.x)]='~'
      end
      out.ore.origin={x=left,y=top}
      for y=top,bottom do
        local line={}
        for x=left,right do
          local k=y..':'..x
          line[#line+1]=blocked[k] or (cells[k] and legend[cells[k]]) or '.'
        end
        out.ore.rows[#out.ore.rows+1]={y=y,row=table.concat(line)}
      end
    else
      -- Runs: per row, maximal x ranges of one ore, e.g. "C:-64..-50 I:-40..-30".
      for y=top,bottom do
        local runs,x={},left
        while x<=right do
          local name=cells[y..':'..x]
          if name then
            local start=x
            while x+1<=right and cells[y..':'..(x+1)]==name do x=x+1 end
            runs[#runs+1]=legend[name]..':'..start..'..'..x
          end
          x=x+1
        end
        if #runs>0 then out.ore.rows[#out.ore.rows+1]={y=y,runs=table.concat(runs,' ')} end
      end
    end
  end
  return out
end
-- Electric networks with a pole in the area. Rates are 5 s averages in kW;
-- the engine reports J per tick, input being consumption.
function handlers.power(p,a)
  local area=view_area(p,a)
  local UNPOWERED={[defines.entity_status.no_power]='no_power',[defines.entity_status.low_power]='low_power'}
  local networks,order={},{}
  local function rates(stats,category,counts)
    local total,top=0,{}
    for name in pairs(counts) do
      local kw=stats.get_flow_count{name=name,category=category,precision_index=defines.flow_precision_index.five_seconds}*60/1000
      if kw>=0.5 then total=total+kw; top[#top+1]={name=name,kw=math.floor(kw+0.5)} end
    end
    table.sort(top,function(x,y) return x.kw>y.kw end)
    return math.floor(total+0.5),top
  end
  for _,e in pairs(p.surface.find_entities_filtered{area=area,type='electric-pole',force=p.force}) do
    local id=e.valid and known(p,e) and e.electric_network_id
    if id then
      local n=networks[id]
      if not n then
        local stats=e.electric_network_statistics
        n={id=id,poles=0,unpowered=0}
        n.consumption_kw,n.consumers=rates(stats,'input',stats.input_counts)
        n.production_kw,n.producers=rates(stats,'output',stats.output_counts)
        networks[id]=n; order[#order+1]=n
      end
      n.poles=n.poles+1
    end
  end
  -- Machines without power: unconnected ones have no network id at all.
  local unpowered,limit={},integer(a.limit,32,1,256,'limit')
  local total=0
  for _,e in pairs(p.surface.find_entities_filtered{area=area,force=p.force}) do
    if e.valid and e.type~='electric-pole' and known(p,e) and e.prototype.electric_energy_source_prototype then
      local id=e.electric_network_id
      local why=not id and 'unconnected' or UNPOWERED[e.status]
      if why then
        total=total+1
        if networks[id] then networks[id].unpowered=networks[id].unpowered+1 end
        if #unpowered<limit then unpowered[#unpowered+1]={name=e.name,position=e.position,status=why,network=id} end
      end
    end
  end
  table.sort(order,function(x,y) return x.poles>y.poles end)
  return {networks=order,unpowered=unpowered,unpowered_total=total>#unpowered and total or nil}
end
-- A top-down character map of an area, one character per tile: buildings as
-- upper-case letters by type, belts as arrows, ore under free tiles in lower
-- case, water '~'. Every letter in use is listed in the legend.
-- Upper case never collides with ore, which is always lower case.
local GRID_TYPES={['mining-drill']='D',furnace='F',['assembling-machine']='A',lab='L',container='C',['logistic-container']='C',
  ['electric-pole']='P',inserter='I',boiler='B',generator='E',splitter='S',['ammo-turret']='G',['electric-turret']='G',
  turret='W',['unit-spawner']='N',wall='X',gate='X',pipe='=',['pipe-to-ground']='=',['offshore-pump']='O',radar='*',
  ['storage-tank']='K',pump='=',['rocket-silo']='Z',roboport='Q',beacon='Y',['solar-panel']='H',accumulator='M',
  tree='T',['simple-entity']='R',cliff='%',['entity-ghost']='?',character='@',car='&'}
local GRID_SKIP={resource=true,corpse=true,['character-corpse']=true,['item-entity']=true,['item-request-proxy']=true,
  ['highlight-box']=true,projectile=true,sticker=true,fire=true,['smoke-with-trigger']=true,['tile-ghost']=true,
  ['deconstructible-tile-proxy']=true,particle=true,['speech-bubble']=true,explosion=true}
local ARROWS={[0]='^',[4]='>',[8]='v',[12]='<'}
local function grid_char(e)
  if e.type=='transport-belt' then return ARROWS[e.direction] or '+' end
  if e.type=='underground-belt' then return e.belt_to_ground_type=='input' and 'U' or 'J' end
  return GRID_TYPES[e.type] or '#'
end
function handlers.grid(p,a)
  local area=view_area(p,a)
  local x0,y0=math.floor(area.left_top.x),math.floor(area.left_top.y)
  local x1,y1=math.ceil(area.right_bottom.x),math.ceil(area.right_bottom.y)
  local cells,legend={},{}
  local function put(x,y,ch,name)
    if x>=x0 and x<x1 and y>=y0 and y<y1 then
      cells[y..':'..x]=ch
      local names=legend[ch] or {}; legend[ch]=names
      if name and not names[name] and #names<6 then names[name]=true; names[#names+1]=name end
    end
  end
  local ore_names,ores={},{}
  for _,e in pairs(p.surface.find_entities_filtered{area=area,type='resource'}) do
    if known(p,e) then
      if not ores[e.name] then ores[e.name]={}; ore_names[#ore_names+1]=e.name end
      table.insert(ores[e.name],e.position)
    end
  end
  local letters=ore_letters(ore_names)
  for name,list in pairs(ores) do
    for _,pos in ipairs(list) do put(math.floor(pos.x),math.floor(pos.y),letters[name]:lower(),name) end
  end
  for _,tile in pairs(p.surface.find_tiles_filtered{area=area,collision_mask='water_tile'}) do
    put(math.floor(tile.position.x),math.floor(tile.position.y),'~','water')
  end
  -- On a platform, space without foundation is where nothing can stand.
  if own_platform(p) then
    for _,tile in pairs(p.surface.find_tiles_filtered{area=area,name='empty-space'}) do
      put(math.floor(tile.position.x),math.floor(tile.position.y),'_','empty space')
    end
  end
  for _,e in pairs(p.surface.find_entities_filtered{area=area}) do
    if e.valid and not GRID_SKIP[e.type] and (e==p.character or known(p,e)) then
      local ch=e==p.character and '@' or grid_char(e)
      local name=e.type=='entity-ghost' and 'ghost: '..e.ghost_name or e.name
      if e.type=='underground-belt' then name=name..' '..e.belt_to_ground_type end
      local box=e.bounding_box
      for y=math.floor(box.left_top.y+0.01),math.ceil(box.right_bottom.y-0.01)-1 do
        for x=math.floor(box.left_top.x+0.01),math.ceil(box.right_bottom.x-0.01)-1 do put(x,y,ch,name) end
      end
    end
  end
  local rows,ruler={},{}
  for x=x0,x1-1 do ruler[#ruler+1]=x%10==0 and '|' or ' ' end
  for y=y0,y1-1 do
    local line={}
    for x=x0,x1-1 do line[#line+1]=cells[y..':'..x] or '.' end
    rows[#rows+1]={y=y,row=table.concat(line)}
  end
  local out_legend={}
  for ch,names in pairs(legend) do out_legend[ch]=table.concat(names,', ') end
  return {origin={x=x0,y=y0},ruler=table.concat(ruler),ruler_note="'|' marks x%10==0",rows=rows,legend=out_legend}
end
function handlers.rates(p,a) return rates.rates(p,a) end
function handlers.bottleneck(p,a) return rates.bottleneck(p,a) end
function handlers.stock(p,a) return stock.view(p,a) end
function handlers.platforms(p,a) return space.platforms(p,a) end
for _,name in ipairs({'requests','platform_create','platform_schedule','launch','land'}) do
  handlers[name]=function(p,a) return space[name](p,a) end
end
local views={map=true,nearest=true,craftable=true,scan=true,power=true,grid=true,rates=true,bottleneck=true,stock=true,platforms=true,labs=true,sleep_check=true}
function handlers.observe(p,a)
  -- Newer read-only views travel as observe scopes: an already loaded
  -- bootstrap treats unknown action names as cached mutations.
  if a.scope then
    assert(views[a.scope],'unknown observe scope')
    return handlers[a.scope](p,a)
  end
  local mode=a.exclude_resources and 'none' or a.resources or 'summary'
  assert(mode=='summary' or mode=='tiles' or mode=='none','resources must be summary, tiles, or none')
  local radius=integer(a.radius,16,1,32,'radius')
  local limit=integer(a.limit,128,1,512,'limit')
  for _,key in ipairs({'entity_types','entity_names'}) do
    if a[key] then
      assert(type(a[key])=='table' and #a[key]>0 and #a[key]<=32,key..' requires 1..32 names')
      for _,name in ipairs(a[key]) do assert(type(name)=='string',key..' requires strings') end
    end
  end
  local out={player={index=p.index, position=p.position, surface=p.surface.name, health=p.character.health, max_health=p.character.max_health, selected_gun_slot=p.character.selected_gun_index,
    inventory=contents(p.get_main_inventory()), guns=contents(p.get_inventory(defines.inventory.character_guns)), ammo=contents(p.get_inventory(defines.inventory.character_ammo)), armor=contents(p.get_inventory(defines.inventory.character_armor)), crafting_queue=p.crafting_queue or {}}, entities={}, tiles={}, truncated=false,
    active=active(p.index)}
  if a.group then out.entities=nil; out.groups={} end
  local origin=center(p,a)
  local candidates=p.surface.find_entities_filtered{position=origin, radius=radius,type=a.entity_types,name=a.entity_names}
  table.sort(candidates,function(x,y)
    local dx,dy=distance(origin,x.position),distance(origin,y.position)
    if dx ~= dy then return dx < dy end
    if x.position.x ~= y.position.x then return x.position.x < y.position.x end
    if x.position.y ~= y.position.y then return x.position.y < y.position.y end
    return x.name < y.name
  end)
  local resources={}
  for _, e in ipairs(candidates) do
    if distance(origin,e.position)<=radius and known(p,e) then
      if e.type=='resource' and mode~='tiles' then
        if mode=='summary' then resources[#resources+1]=e end
      elseif a.group then
        local g=out.groups[e.name]
        if g then g.count=g.count+1 else out.groups[e.name]={count=1,nearest=e.position} end
      elseif #out.entities >= limit then out.truncated=true
      else out.entities[#out.entities+1]=summary(e) end
    end
  end
  if mode=='summary' then
    out.resource_patches=resource_patches(resources)
  end
  if a.tiles then
    for _,tile in ipairs(p.surface.find_tiles_filtered{position=origin,radius=radius}) do
      if p.force.is_chunk_charted(p.surface,chunk_of(tile.position)) then
        if #out.tiles >= integer(a.tiles_limit,4096,1,4096,'tiles_limit') then out.tiles_truncated=true; break end
        out.tiles[#out.tiles+1]={name=tile.name,position=tile.position}
      end
    end
  end
  -- Equipment rows are opt-in; the default is a compact name->count summary.
  local grid=p.character.grid
  out.player.equipment={}
  if grid then
    for _,e in pairs(grid.equipment) do
      if a.equipment then
        out.player.equipment[#out.player.equipment+1]={name=e.name,position=e.position,quality=e.quality.name,energy=e.energy,shield=e.shield}
      else out.player.equipment[e.name]=(out.player.equipment[e.name] or 0)+1 end
    end
    if not a.equipment then out.player.robots=p.character.logistic_network and {available_construction=p.character.logistic_network.available_construction_robots,total_construction=p.character.logistic_network.all_construction_robots} or nil end
  end
  local r=p.force.current_research
  out.research=r and {name=r.name, progress=p.force.research_progress} or false
  out.research_queue={}
  for _,technology in ipairs(p.force.research_queue or {}) do out.research_queue[#out.research_queue+1]=technology.name end
  out.combat=state().combat and state().combat[p.index] or false
  local q=state().queues and state().queues[p.index]
  out.queue=q and {revision=q.revision,paused=q.paused,pending=#q.pending,
    active=q.current and {id=q.current.id,action=q.current.action,started_tick=q.current.started_tick} or false} or false
  return out
end
function handlers.stop(p) if scheduler then scheduler.pause(p.index) end; finish(p.index,'stopped'); stop_combat(p.index,'stopped'); return {stopped=true} end
function handlers.walk(p,a)
  local direction=directions[a.direction]
  assert(direction,'invalid compass direction')
  local ticks=integer(a.ticks,60,1,MAX_TICKS,'ticks')
  if state().active[p.index] then finish(p.index,'replaced') else stop(p) end
  state().active[p.index]={kind='walk',direction=direction,until_tick=game.tick+ticks}
  return {until_tick=game.tick+ticks}
end
-- Engine pathfinding for the character's own footprint (slightly padded so
-- 8-direction walking does not snag corners). Results arrive through
-- on_script_path_request_finished; until then the character waits in place.
-- Each replan widens the goal radius so a goal boxed in by entities still
-- yields a path to somewhere beside it. The shared path cache is skipped: it
-- can hand back routes planned for other units.
-- Paths are planned for a padded box so they keep clear of corners the
-- character snags on at speed. A padded box that already overlaps something
-- at the start makes the engine fail the request, and so does a start in a gap
-- narrower than a tile (between two drills): the pathfinder works from tile
-- nodes. Failures retry from the nearest free tile centre with a slimmer box,
-- then also with a wider goal.
local PADDED_BOX,SLIM_BOX={{-0.35,-0.35},{0.35,0.35}},{{-0.15,-0.15},{0.15,0.15}}
request_path=function(p,nav)
  local c=p.character
  local level=nav.path_level or 0
  local start=level>0 and p.surface.find_non_colliding_position(c.name,p.position,3,0.5,true) or p.position
  local id=p.surface.request_path{bounding_box=level==0 and PADDED_BOX or SLIM_BOX,collision_mask=c.prototype.collision_mask,
    start=start,goal=nav.position,force=p.force,radius=nav.tolerance+1+(nav.replans or 0)+(level>=2 and 3 or 0),entity_to_ignore=c,
    can_open_gates=true,pathfind_flags={prefer_straight_paths=true,no_break=true,cache=false}}
  state().paths=state().paths or {}
  state().paths[id]=p.index
  nav.path_id=id; nav.path_state='pending'; nav.waypoints=nil; nav.waypoint=nil; nav.sidestep=nil
end
function handlers.move_to(p,a)
  local target=position(a.position)
  assert(distance(p.position,target)<=512,'movement target must be within 512 tiles')
  local ticks=integer(a.ticks,3600,1,36000,'ticks')
  -- `within` reads naturally for "stop once in reach"; both mean the same.
  local tolerance=a.within or a.tolerance or 0.5
  assert(type(tolerance)=='number' and tolerance>=0.25 and tolerance<=10,'tolerance/within out of range 0.25..10')
  if state().active[p.index] then finish(p.index,'replaced') else stop(p) end
  local action={kind='move_to',position=target,tolerance=tolerance,
    until_tick=game.tick+ticks,last_position=p.position,stalled=0,replans=0,direct=a.pathfind==false}
  state().active[p.index]=action
  if not action.direct then request_path(p,action) end
  return {until_tick=game.tick+ticks,position=target,pathfinding=not action.direct}
end
-- Hand-mining time for the character, including force and character bonuses.
local function hand_mining_ticks(p,e)
  local c=p.character
  local speed=c.prototype.mining_speed*(1+(c.character_mining_speed_modifier or 0)+(p.force.manual_mining_speed_modifier or 0))
  return math.max(1,math.ceil(e.prototype.mineable_properties.mining_time*60/speed))
end
function handlers.mine(p,a)
  local e=entity(p,a); friendly(p,e)
  assert(e.minable,'entity is not mineable')
  -- Space Age: some ores are not hand-mineable (tungsten-ore is hard-solid,
  -- big mining drills only). Ore is taken through mine_entity, which would
  -- not check, so check the character's resource categories here.
  local hand=e.type=='resource' and p.character and p.character.prototype.resource_categories
  local category=hand and e.prototype.resource_category
  assert(not category or hand[category],e.name..' is '..tostring(category)..': a character cannot mine it by hand (a drill that mines '..tostring(category)..' can)')
  local ticks=integer(a.ticks,60,1,MAX_TICKS,'ticks')
  if state().active[p.index] then finish(p.index,'replaced') else stop(p) end
  local action={kind='mine',entity=e,until_tick=game.tick+ticks,products={}}
  for _,product in ipairs(e.prototype.mineable_properties.products or {}) do
    if product.type=='item' then action.products[#action.products+1]=product.name end
  end
  if e.type=='resource' then
    for _,product in ipairs(e.prototype.mineable_properties.products or {}) do
      assert(product.type=='item','fluid resources cannot be mined by hand')
    end
    -- Setting mining_state does not survive a connected client's own input,
    -- so ore never progressed. Mine one unit per hand-mining cycle through
    -- the engine instead (same yield and speed as holding the mine button).
    action.cycle=hand_mining_ticks(p,e)
    action.next_mine=game.tick+action.cycle
    action.mined=0
  else
    -- Buildings, trees, rocks and corpses need the entity selected, and the
    -- connected client's cursor hover overwrites selection every tick (the
    -- selection box flashes). Take exactly the hand-mining time instead and
    -- then mine through the engine, which applies normal products and space checks.
    action.done_tick=game.tick+hand_mining_ticks(p,e)
    -- A shorter duration could only ever expire unfinished.
    action.until_tick=math.max(action.until_tick,action.done_tick)
  end
  state().active[p.index]=action
  -- LuaEntity cannot be serialized to JSON; only tick is returned.
  return {until_tick=action.until_tick}
end
function handlers.pickup(p,a)
  local ticks=integer(a.ticks,30,1,MAX_TICKS,'ticks')
  if state().active[p.index] then finish(p.index,'replaced') else stop(p) end
  state().active[p.index]={kind='pickup',until_tick=game.tick+ticks}
  return {until_tick=game.tick+ticks}
end
function handlers.repair(p,a)
  local e=entity(p,a); friendly(p,e)
  assert(e.health and e.health<e.max_health,'entity does not need repair')
  local ticks=integer(a.ticks,60,1,MAX_TICKS,'ticks')
  if state().active[p.index] then finish(p.index,'replaced') else stop(p) end
  local borrowed=false
  if not p.cursor_stack.valid_for_read then
    local tool=p.get_main_inventory().find_item_stack(a.item or 'repair-pack')
    assert(tool and tool.prototype.type=='repair-tool','no repair tool in inventory')
    assert(p.cursor_stack.swap_stack(tool),'cannot hold repair tool')
    borrowed=true
  end
  assert(p.cursor_stack.prototype.type=='repair-tool','cursor must hold a repair tool')
  -- A bot's cursor is invisible to it: always put the tool back afterwards.
  state().active[p.index]={kind='repair',entity=e,borrowed_cursor=borrowed or M.bots.is(p),until_tick=game.tick+ticks}
  return {until_tick=game.tick+ticks}
end
-- Hand-crafting what our machines already made wastes the character's time:
-- stock of the product within STOCK_RADIUS is stated, and a craft of at least
-- STOCK_REFUSE_S of hand time that the stock covers is refused unless forced.
local STOCK_RADIUS,STOCK_REFUSE_S=64,3
local function craft_stock(p,name,count,force,notes)
  local recipe=p.force.recipes[name]
  local product
  for _,pr in ipairs(recipe.products or {}) do if pr.type=='item' then product=pr; break end end
  if not product then return end
  local s=stock.scan(p,product.name,{radius=STOCK_RADIUS})
  if s.total==0 then return end
  local line=stock.line(s)
  local wanted=count*(product.amount or product.amount_max or 1)
  if not force and s.total>=wanted and (recipe.energy or 0.5)*count/hand_speed(p)>=STOCK_REFUSE_S then
    error('not crafted: '..line..'; or pass force=true to hand-craft anyway',0)
  end
  notes[product.name]=line
end
-- Why a hand craft started fewer than asked: the raw items it runs out of,
-- following hand-craftable intermediates (gears, cables) down like the
-- engine does, with where our factory holds each.
-- Whether a crafter with these categories takes the recipe: its own category
-- or one of its additional ones (Space Age: pressing, electronics, ...).
local function takes(categories,recipe)
  if categories[recipe.category or 'crafting'] then return true end
  for _,extra in ipairs(recipe.additional_categories or {}) do if categories[extra] then return true end end
  return false
end
local function hand_recipe(p,item)
  local recipe=p.force.recipes[item]
  local categories=p.character and p.character.prototype.crafting_categories or {}
  if recipe and recipe.enabled and takes(categories,recipe) then return recipe end
end
local function craft_shortfall(p,name,count,notes)
  local have,short={},{}
  local inv=p.get_main_inventory()
  local function walk(recipe,n,depth)
    for _,ing in ipairs(recipe.ingredients or {}) do
      if ing.type=='item' then
        local need=ing.amount*n
        local held=have[ing.name] or inv.get_item_count{name=ing.name,quality='normal'}
        local use=math.min(held,need); have[ing.name]=held-use
        local missing=need-use
        local sub=missing>0 and depth<4 and hand_recipe(p,ing.name)
        local made=0
        for _,pr in ipairs(sub and sub.products or {}) do if pr.name==ing.name then made=pr.amount or pr.amount_max or 1 end end
        if made>0 then walk(sub,math.ceil(missing/made),depth+1)
        elseif missing>0 then
          local row=short[ing.name] or {need=0,held=inv.get_item_count{name=ing.name,quality='normal'}}
          short[ing.name]=row; row.need=row.need+missing
        end
      end
    end
  end
  walk(p.force.recipes[name],count,0)
  local out={}
  for item,row in pairs(short) do
    out[#out+1]=string.format('%s short %d (held %d)',item,row.need,row.held)
    local ok,line=pcall(function() return stock.line(stock.scan(p,item,{radius=128})) end)
    if ok and line and notes then notes[item]=line end
  end
  table.sort(out)
  return #out>0 and table.concat(out,', ') or nil
end
local function begin_craft(p,recipe,count,force,notes,shorts)
  assert(type(recipe)=='string' and p.force.recipes[recipe] and p.force.recipes[recipe].enabled,'recipe is unavailable')
  count=integer(count,1,1,1000,'count')
  craft_stock(p,recipe,count,force,notes)
  local started=p.begin_crafting{recipe=recipe,count=count}
  if started<count and shorts then shorts[recipe]=craft_shortfall(p,recipe,count-started,notes) or 'not hand-craftable now' end
  for _,product in ipairs(p.force.recipes[recipe].products or {}) do
    if product.type=='item' then survey.log_hand('crafted',product.name,started*(product.amount or product.amount_max or 1)) end
  end
  return started
end
-- What a hand craft costs: seconds of character crafting for what was just
-- queued, the whole queue's backlog, and how many of our assemblers already
-- run each recipe (surface-wide).
local function craft_cost(p,started)
  local hand,assemblers=0,{}
  local counts={}
  for _,e in pairs(p.surface.find_entities_filtered{type='assembling-machine',force=p.force}) do
    local ok,r=pcall(e.get_recipe); if ok and r then counts[r.name]=(counts[r.name] or 0)+1 end
  end
  for name,n in pairs(started) do
    local recipe=p.force.recipes[name]
    hand=hand+(recipe and recipe.energy or 0.5)*n
    assemblers[name]=counts[name] or 0
  end
  return math.ceil(hand/hand_speed(p)),math.ceil((crafting_left(p))),assemblers
end
-- The best assembler this force can build that takes the recipe's category.
local ASSEMBLERS={'assembling-machine-3','assembling-machine-2','assembling-machine-1'}
local function best_assembler(p,recipe)
  for _,name in ipairs(ASSEMBLERS) do
    local proto=prototypes.entity[name]
    local unlocked=p.force.recipes[name] and p.force.recipes[name].enabled
    if proto and unlocked and takes(proto.crafting_categories or {},recipe) then
      local ok,speed=pcall(function() return proto.get_crafting_speed() end)
      return name,ok and speed or proto.crafting_speed or 1
    end
  end
end
-- Facts that make a large hand craft's cost visible: the backlog the
-- character's queued work may wait on, and what a machine would take instead.
local HAND_BACKLOG_S=30
local function craft_facts(p,out,started)
  if out.queue_s>=HAND_BACKLOG_S then
    out.blocks=string.format('~%ds of hand crafting queued (this: ~%ds); a construct needing these items waits for them',out.queue_s,out.hand_s)
  end
  for name,n in pairs(started) do
    local recipe=p.force.recipes[name]
    local machine,speed=nil,nil
    if recipe and n>0 and (out.assemblers[name] or 0)==0 then machine,speed=best_assembler(p,recipe) end
    if machine then
      local items=0
      for _,product in ipairs(recipe.products or {}) do
        if product.name==name or #recipe.products==1 then items=items+n*(product.amount or product.amount_max or 1) end
      end
      out.no_assembler=out.no_assembler or {}
      out.no_assembler[name]=string.format('none of our assemblers is set to %s; one %s makes these %d in ~%ds without the character',
        name,machine,items>0 and items or n,math.ceil((recipe.energy or 0.5)*n/speed))
    end
  end
  return out
end
function handlers.craft(p,a)
  local notes,shorts={},{}
  if not a.recipes then
    local started=begin_craft(p,a.recipe,a.count,a.force,notes,shorts)
    local hand_s,queue_s,assemblers=craft_cost(p,{[a.recipe]=started})
    return craft_facts(p,{started=started,short=shorts[a.recipe],stock=next(notes) and notes or nil,hand_s=hand_s,queue_s=queue_s,assemblers=assemblers},{[a.recipe]=started})
  end
  assert(type(a.recipes)=='table' and #a.recipes>=1 and #a.recipes<=32,'recipes requires 1..32 {recipe,count} entries')
  -- Every entry is attempted: a shortfall in one should not hide what the
  -- others queued. Repeated recipes accumulate.
  local started,errors={},{}
  for _,entry in ipairs(a.recipes) do
    local name=type(entry)=='table' and entry.recipe
    local ok,result=pcall(begin_craft,p,name,type(entry)=='table' and entry.count,a.force or type(entry)=='table' and entry.force,notes,shorts)
    local key=tostring(name)
    if ok then started[key]=(started[key] or 0)+result
    else errors[key]=reason(result) end
  end
  local hand_s,queue_s,assemblers=craft_cost(p,started)
  return craft_facts(p,{started=started,errors=next(errors) and errors or nil,short=next(shorts) and shorts or nil,stock=next(notes) and notes or nil,hand_s=hand_s,queue_s=queue_s,assemblers=assemblers},started)
end
-- Hand-craftable counts from current inventory, including intermediates.
function handlers.craftable(p,a)
  local names=type(a.recipes)=='string' and {a.recipes} or a.recipes
  local out={}
  local categories=p.character.prototype.crafting_categories or {}
  local function by_hand(recipe) return takes(categories,recipe) end
  if names then
    assert(type(names)=='table' and #names>=1 and #names<=64,'recipes requires 1..64 names')
    for _,name in ipairs(names) do
      local recipe=type(name)=='string' and p.force.recipes[name]
      assert(recipe,'unknown recipe: '..tostring(name))
      out[name]=recipe.enabled and by_hand(recipe) and p.get_craftable_count(name) or 0
    end
  else
    -- Unfiltered: only the recipes that can be started right now.
    for name,recipe in pairs(p.force.recipes) do
      if recipe.enabled and not recipe.hidden and by_hand(recipe) then
        local n=p.get_craftable_count(name)
        if n>0 then out[name]=n end
      end
    end
  end
  return {craftable=out}
end
function handlers.cancel_craft(p,a)
  if a.recipe~=nil then
    assert(a.index==nil,'give recipe or index, not both')
    -- The recipe's own entries, not intermediates queued for other crafts;
    -- latest first, as a player trims the tail of the queue.
    local queue=p.crafting_queue or {}
    local available=0
    for _,entry in ipairs(queue) do if entry.recipe==a.recipe and not entry.prerequisite then available=available+entry.count end end
    assert(available>0,'no queued crafts of '..tostring(a.recipe))
    local wanted=integer(a.count,available,1,available,'count')
    local left=wanted
    for i=#queue,1,-1 do
      local entry=queue[i]
      if left>0 and entry.recipe==a.recipe and not entry.prerequisite then
        local n=math.min(left,entry.count)
        p.cancel_crafting{index=entry.index or i,count=n}
        left=left-n
      end
    end
    return {cancelled=wanted,recipe=a.recipe,crafting_queue=p.crafting_queue or {}}
  end
  local index=integer(a.index,1,1,10000,'index')
  local entry=(p.crafting_queue or {})[index]
  assert(entry,'crafting queue entry does not exist')
  local count=integer(a.count,entry.count,1,entry.count,'count')
  p.cancel_crafting{index=index,count=count}
  return {cancelled=count,recipe=entry.recipe,crafting_queue=p.crafting_queue or {}}
end
-- A player's pole auto-connects only to a few neighbours, and a pole revived
-- from a ghost keeps only the ghost's wires (none for a lone ghost). Join the
-- nearest pole of every separate wire group the wire reaches. Groups come from
-- walking copper wires, not electric_network_id: poles built in the same tick
-- (construct builds several per tick) share a stale network id until the next
-- update, which left rows of ghost-built poles unwired.
local COPPER_GROUP_LIMIT=4096
local function copper_group(e,seen)
  local copper=defines.wire_connector_id.pole_copper
  local queue,head,n={e},1,0
  seen[e.unit_number]=true
  while head<=#queue and n<COPPER_GROUP_LIMIT do
    local pole=queue[head]; head=head+1; n=n+1
    local connector=pole.get_wire_connector(copper,false)
    for _,c in ipairs(connector and connector.connections or {}) do
      local other=c.target and c.target.owner
      if other and other.valid and other.type=='electric-pole' and not seen[other.unit_number] then
        seen[other.unit_number]=true; queue[#queue+1]=other
      end
    end
  end
end
local function bridge_pole(e)
  local copper=defines.wire_connector_id.pole_copper
  local mine=e.get_wire_connector(copper,true)
  local reach=e.prototype.get_max_wire_distance(e.quality)
  local others=e.surface.find_entities_filtered{type='electric-pole',position=e.position,radius=reach,force=e.force}
  table.sort(others,function(x,y) return distance(e.position,x.position)<distance(e.position,y.position) end)
  local joined,seen=0,{}
  copper_group(e,seen)
  for _,other in ipairs(others) do
    if other.valid and not seen[other.unit_number] then
      local theirs=other.get_wire_connector(copper,true)
      if mine.can_wire_reach(theirs) and mine.connect_to(theirs,false) then
        joined=joined+1
        copper_group(other,seen)
      end
    end
  end
  return joined
end
-- Map view (cursor building there only places ghosts) and undergrounds: place
-- the way a hand build does: reach and manual build checks from the character, one item from
-- its inventory, and a ghost already on the spot revived with its settings.
local STEP={[0]={0,-1},[4]={1,0},[8]={0,1},[12]={-1,0}}
-- The end a player's hand-build makes: the nearest same-kind underground
-- upstream flowing the same way decides. An unpaired entrance makes this its
-- exit; an exit or a paired entrance leaves this an entrance. Undergrounds
-- flowing another way never pair with it and are skipped.
local function underground_type(surface,proto,pos,direction)
  local step=STEP[direction]
  local x,y=math.floor(pos.x)+0.5,math.floor(pos.y)+0.5
  for k=1,proto.max_underground_distance or 0 do
    for _,e in pairs(surface.find_entities_filtered{position={x=x-step[1]*k,y=y-step[2]*k},radius=0.3,type='underground-belt'}) do
      if e.name==proto.name and e.direction==direction then
        return (e.direction==direction and e.belt_to_ground_type=='input' and not e.neighbours) and 'output' or 'input'
      end
    end
  end
  return 'input'
end
-- What sits in a refused footprint: entities and ghosts (name and position),
-- the character itself, else the tiles it may not go on (water, space).
-- Trees and rocks are called out: place_ghosts marks them and construct
-- clears them, where a direct build cannot.
local function placement_error(p,proto,pos,direction)
 local function blockers()
  local b=proto.collision_box or {left_top={x=-0.4,y=-0.4},right_bottom={x=0.4,y=0.4}}
  local l,t,r,btm=b.left_top.x,b.left_top.y,b.right_bottom.x,b.right_bottom.y
  if direction==4 or direction==12 then l,t,r,btm=-btm,l,-t,r end
  local area={left_top={x=pos.x+l,y=pos.y+t},right_bottom={x=pos.x+r,y=pos.y+btm}}
  local found,character,clearable={},false,false
  for _,e in pairs(p.surface.find_entities_filtered{area=area,limit=16}) do
    if e.valid and e.type=='character' and e==p.character then character=true
    elseif e.valid and e.type=='character' and #found<4 then
      -- Someone else stands there: say who, so the agent can ask them.
      local who=M.character_owner(e)
      found[#found+1]=string.format('%s standing at (%.1f,%.1f) (ask them to move, or build elsewhere)',who and who..'\'s character' or 'another character',e.position.x,e.position.y)
    elseif e.valid and e.type~='resource' and #found<4 then
      local name=e.type=='entity-ghost' and 'ghost '..e.ghost_name or e.type=='tile-ghost' and 'tile ghost '..e.ghost_name or e.name
      if e.type=='tree' or e.type=='plant' or e.type=='simple-entity' or e.type=='cliff' then clearable=true end
      found[#found+1]=string.format('%s (%g,%g)',name,e.position.x,e.position.y)
    end
  end
  if character then found[#found+1]='the character standing on the footprint (move off it first)' end
  if #found>0 then
    return ' by '..table.concat(found,', ')..(clearable and '; mine it, or place_ghosts (marks it) + construct (clears it)' or '')
  end
  local tiles={}
  for _,tile in pairs(p.surface.find_tiles_filtered{area=area,limit=16}) do
    local mask=tile.prototype.collision_mask
    local layers=mask and mask.layers or {}
    if (layers.water_tile or layers.empty_space or layers.lava_tile) and not tiles[tile.name] then tiles[tile.name]=true; tiles[#tiles+1]=tile.name end
  end
  if #tiles>0 then return ' by tiles: '..table.concat(tiles,', ')..' (needs landfill, or a shore position: scan fields=fluids / grid ~ marks water)' end
  return ' (nothing found in the footprint: check the position is a valid centre for a '..(proto.name or 'entity')..' and the direction)'
 end
 local ok,extra=pcall(blockers)
 return 'placement blocked'..(ok and extra or '')
end
local function build_direct(p,stack,pos,direction,quality,kind)
  local proto,surface=stack.prototype.place_result,p.surface
  construction.clear_remnants(surface,proto,pos,direction)
  local ghost=surface.find_entities_filtered{position=pos,radius=0.1,ghost_name=proto.name,force=p.force,limit=1}[1]
  local e
  if ghost then
    local _,revived=ghost.revive{raise_revive=true}
    e=revived
  else
    local args={name=proto.name,position=pos,direction=direction,force=p.force,build_check_type=defines.build_check_type.manual}
    assert(surface.can_place_entity(args),placement_error(p,proto,pos,direction))
    args.quality=quality; args.player=real(p); args.raise_built=true
    if proto.type=='underground-belt' then args.type=kind or underground_type(surface,proto,pos,direction) end
    e=surface.create_entity(args)
  end
  assert(e,placement_error(p,proto,pos,direction))
  if stack.count>1 then stack.count=stack.count-1 else stack.clear() end
  return e
end
local function build_reach(p,pos,what)
  assert_visible(p,pos,what)
  if distance(p.position,pos)>p.build_distance then
    error(string.format('%s is out of build reach: %s, build reach %g',what,from_character(p,pos),p.build_distance),2)
  end
end
-- Tiles go down like a player's: the item in the cursor, placed over a
-- size x size square (the game's terrain brush) that the tile's placement
-- rules allow (landfill only on water), revived over matching tile ghosts.
-- A building's status the tick it is placed is stale (a powered radar reads
-- no_power until the network updates), so build results leave it out.
local function built_summary(e)
  local out=summary(e); out.status_name=nil
  return out
end
local function build_tile(p,a,stack,pos)
  assert(not in_map_view(p),'tiles are placed by the character; leave map view')
  assert(a.direction==nil or a.direction=='north','tiles take no direction')
  local size=integer(a.size,1,1,4,'size')
  if M.bots.is(p) then return M.bots.place_tiles(p,a,stack,pos,size) end
  assert(not p.cursor_stack.valid_for_read,'cursor must be empty; clear it in the client first')
  local tile=stack.prototype.place_as_tile_result.result.name
  local inv=p.get_main_inventory()
  local function held() return inv.get_item_count{name=a.item,quality=a.quality or 'normal'} end
  local before=held()
  assert(p.cursor_stack.swap_stack(stack),'could not borrow inventory stack')
  local ok,err=pcall(function()
    assert(p.can_build_from_cursor{position=pos,terrain_building_size=size},'tile placement blocked (landfill needs water; the tile may already be there)')
    p.build_from_cursor{position=pos,terrain_building_size=size}
  end)
  local restored=not p.cursor_stack.valid_for_read or
    (not stack.valid_for_read and p.cursor_stack.swap_stack(stack)) or p.clear_cursor()
  assert(restored,'build finished but could not restore cursor; items remain in cursor')
  assert(ok,err)
  local consumed=before-held()
  assert(consumed>0,'no tile was placed (blocked or already there)')
  return {consumed=consumed,tile=tile,position={x=math.floor(pos.x)+0.5,y=math.floor(pos.y)+0.5}}
end
local function build_one(p,a)
  local pos=position(a.position)
  build_reach(p,pos,'position')
  assert(type(a.item)=='string','item is required')
  local stack=p.get_main_inventory().find_item_stack{name=a.item,quality=a.quality or 'normal'}
  assert(stack,'item is not in main inventory')
  if stack.prototype.place_as_tile_result then return build_tile(p,a,stack,pos) end
  assert(stack.prototype.place_result and stack.prototype.place_result.type ~= 'rail-ramp','only ordinary entity placement is supported')
  -- Cursor building borrows the cursor; direct placement leaves it alone.
  -- While the game is tick-paused (turn mode between actions) the engine
  -- refuses every cursor build ("placement blocked" on clear ground), so
  -- place directly then, as in map view.
  local direct=in_map_view(p) or M.bots.is(p) or stack.prototype.place_result.type=='underground-belt' or game.tick_paused==true
  assert(direct or not p.cursor_stack.valid_for_read,'cursor must be empty; clear it in the client first')
  if stack.prototype.place_result.type=='transport-belt' then
    pos={x=math.floor(pos.x)+0.5,y=math.floor(pos.y)+0.5}
    build_reach(p,pos,'snapped position')
  end
  local direction=directions[a.direction or 'north']; assert(direction,'invalid direction')
  local filter={position=pos,radius=2,name=stack.prototype.place_result.name,limit=64}
  local existing={}
  for _,e in pairs(p.surface.find_entities_filtered(filter)) do
    -- Native cursor placement can rotate an existing belt without consuming an
    -- item. A build request must not silently change an occupied crossing.
    if e.valid and e.name==stack.prototype.place_result.name and distance(e.position,pos)<0.1
      and (e.quality and e.quality.name or 'normal')==(a.quality or 'normal') then
      error('target already contains this entity; use rotate explicitly or an underground crossing')
    end
    existing[e.unit_number or (e.name..'@'..e.position.x..','..e.position.y)]=true
  end
  local proto=stack.prototype.place_result
  assert(a.type==nil or proto.type=='underground-belt' and (a.type=='input' or a.type=='output'),'type is input|output for underground belts only')
  -- Only the agent's own character in the way: handlers.build walks it off
  -- the footprint first, once per entry.
  if not a.stepped then
    local aside=construction.aside(p,proto,pos,direction)
    if aside then return {aside=aside} end
  end
  -- Undergrounds are always placed directly with an explicit end: cursor
  -- building does not reliably make the exit of a pair from script.
  if direct then
    local e=build_direct(p,stack,pos,direction,a.quality or 'normal',a.type)
    local joined=e.type=='electric-pole' and bridge_pole(e) or 0
    return {consumed=1,entity=built_summary(e),networks_joined=joined>0 and joined or nil}
  end
  local function held()
    local n=p.get_main_inventory().get_item_count{name=a.item,quality=a.quality or 'normal'}
    local c=p.cursor_stack
    if c.valid_for_read and c.name==a.item and c.quality.name==(a.quality or 'normal') then n=n+c.count end
    return n
  end
  local before=held()
  assert(p.cursor_stack.swap_stack(stack),'could not borrow inventory stack')
  local ok,err=pcall(function()
    assert(p.can_build_from_cursor{position=pos,direction=direction,build_mode=defines.build_mode.normal},placement_error(p,proto,pos,direction))
    p.build_from_cursor{position=pos,direction=direction,build_mode=defines.build_mode.normal}
  end)
  local restored=not p.cursor_stack.valid_for_read or
    (not stack.valid_for_read and p.cursor_stack.swap_stack(stack)) or p.clear_cursor()
  assert(restored,'build finished but could not restore cursor; items remain in cursor')
  assert(ok,err)
  local after=held()
  local placed,joined={},nil
  if before>after then
    for _,e in pairs(p.surface.find_entities_filtered(filter)) do
      if e.valid and not existing[e.unit_number or (e.name..'@'..e.position.x..','..e.position.y)] then
        placed[#placed+1]=built_summary(e)
        if e.type=='electric-pole' then joined=(joined or 0)+bridge_pole(e) end
      end
    end
  end
  return {consumed=before-after,entity=#placed==1 and placed[1] or nil,entities=#placed>1 and placed or nil,
    networks_joined=joined and joined>0 and joined or nil}
end
-- Batches share item/direction/quality defaults and stop at the first failure,
-- (tiles report the tile instead of an entity)
-- returning only the placed positions; earlier placements stay built.
function handlers.build(p,a)
  -- Short of an item the hand-craft queue is making: wait for it
  -- (awaiting_craft, outcome fed | failed | timed_out), as transfer does.
  if not a.awaited then
    local need,order={},{}
    for _,b in ipairs(a.builds or {a}) do
      local item=type(b)=='table' and b.item or a.item
      if type(item)=='string' then
        if not need[item] then order[#order+1]=item end
        need[item]=(need[item] or 0)+1
      end
    end
    for _,item in ipairs(order) do
      local waiting=crafting_count(p,item)>0 and M.await_feed(p,'build',a,item,need[item])
      if waiting then return waiting end
    end
  end
  -- The character stands on the footprint and nothing else does: walk it off
  -- (real walking, a timed action) and build then, as a player steps aside.
  -- The rest of the call reruns from that entry (outcome fed | failed | timed_out).
  local function step_aside(aside,rest)
    rest.awaited=true; rest.stepped=true
    -- A later batch entry from a rerun replaces the running step-aside itself.
    local current=state().active[p.index]
    if current and not current.running then finish(p.index,'replaced') elseif not current then stop(p) end
    local until_tick=game.tick+180
    state().active[p.index]={kind='feed',handler='build',args=rest,aside=aside,until_tick=until_tick,next_check=game.tick}
    return {stepping_aside={from=p.position,to=aside.to},until_tick=until_tick}
  end
  if not a.builds then
    local r=build_one(p,a)
    if not r.aside then return r end
    local rest={}
    for k,v in pairs(a) do rest[k]=v end
    return step_aside(r.aside,rest)
  end
  assert(type(a.builds)=='table' and #a.builds>=1 and #a.builds<=64,'builds requires 1..64 {item,position,direction} entries')
  local placed={}
  for i,b in ipairs(a.builds) do
    local ok,result=pcall(function()
      assert(type(b)=='table','each build must be an object')
      local r=build_one(p,{item=b.item or a.item,position=b.position,direction=b.direction or a.direction,quality=b.quality or a.quality,type=b.type,size=b.size or a.size,
        stepped=a.stepped and i==1})
      assert(r.aside or r.consumed>0,'nothing was placed')
      return r
    end)
    -- A partial batch is a failure, so plan on_fail policies see it; the
    -- entries before it stay built.
    if not ok then error(string.format('build %d/%d failed after %d built: %s',i,#a.builds,#placed,reason(result))) end
    if result.aside then
      local rest={builds={}}
      for k,v in pairs(a) do if k~='builds' then rest[k]=v end end
      for j=i,#a.builds do rest.builds[#rest.builds+1]=a.builds[j] end
      rest.built_before=(a.built_before or 0)+#placed
      local out=step_aside(result.aside,rest)
      out.built=#placed; out.placed=#placed>0 and placed or nil
      return out
    end
    local e=result.entity or (result.entities and result.entities[1])
    placed[i]=e and e.position or b.position
  end
  return {built=#placed,placed=placed,built_before=a.built_before}
end
-- Copper wire between two poles, both in the character's reach like a player
-- dragging a wire; the wire itself must span the distance.
function handlers.wire(p,a)
  local function pole(t,key)
    assert(type(t)=='table',key..' requires a pole position {x,y}')
    local e=entity(p,{position=t.position or t,name=t.name,unit_number=t.unit_number})
    friendly(p,e); assert(e.type=='electric-pole',key..' is not an electric pole')
    return e.get_wire_connector(defines.wire_connector_id.pole_copper,true),e
  end
  local from,fe=pole(a.from,'from')
  local to,te=pole(a.to,'to')
  assert(fe~=te,'from and to are the same pole')
  if a.disconnect then
    return {disconnected=from.disconnect_from(to),split=fe.electric_network_id~=te.electric_network_id}
  end
  if from.is_connected_to(to) then return {connected=true,already=true} end
  assert(from.can_wire_reach(to),'wire does not reach between these poles')
  assert(from.connect_to(to,false),'engine refused the connection (pole wire limit?)')
  return {connected=true,network=fe.electric_network_id}
end
function handlers.build_path(p,a)
  assert(not p.permission_group or p.permission_group.allows_action(defines.input_action.start_walking),'permission denied: start_walking')
  local action=construction.plan(p,a)
  if state().active[p.index] then finish(p.index,'replaced') else stop(p) end
  state().active[p.index]=action
  return {until_tick=action.until_tick,total=#action.cells,next_index=action.next_index}
end
function handlers.kite(p,a)
  local action=kite.plan(p,a)
  if state().active[p.index] then finish(p.index,'replaced') else stop(p) end
  -- Kiting owns both walking and shooting; a separate shoot would fight it.
  if state().combat and state().combat[p.index] then stop_combat(p.index,'replaced') end
  state().active[p.index]=action
  return {until_tick=action.until_tick,ammo=action.ammo_start}
end
function handlers.construct(p,a)
  assert(not p.permission_group or p.permission_group.allows_action(defines.input_action.start_walking),'permission denied: start_walking')
  local box
  if a.area then
    local lt,rb=position(a.area.left_top),position(a.area.right_bottom)
    assert(rb.x>lt.x and rb.y>lt.y and rb.x-lt.x<=256 and rb.y-lt.y<=256,'area must be nonempty and at most 256x256')
    box={left_top=lt,right_bottom=rb}
  else
    local b=state().last_paste and state().last_paste[p.index]
    assert(b,'no area given and no earlier paste to construct')
    -- Bounds hold ghost centres; pad so whole footprints are searched.
    box={left_top={x=b.left-0.5,y=b.top-0.5},right_bottom={x=b.right+0.5,y=b.bottom+0.5}}
  end
  local action=construction.plan_ghosts(p,a,box)
  if state().active[p.index] then finish(p.index,'replaced') else stop(p) end
  state().active[p.index]=action
  -- Nothing to do is done: plans continue rather than pausing on an error.
  if #action.pending==0 then finish(p.index,'nothing_to_do'); return {total=0,built=0,outcome='nothing_to_do'} end
  return {until_tick=action.until_tick,total=#action.pending}
end
function handlers.inspect(p,a)
  local e=entity(p,a,true)
  local out=summary(e); out.inventories={}
  out.in_reach=p.can_reach_entity(e)
  out.health=e.health; out.max_health=e.max_health; out.direction=e.direction
  out.status=e.status
  out.status_name=entity_status_names[out.status]
  out.energy=e.energy
  out.fluids=e.get_fluid_contents()
  out.electric_network_id=e.electric_network_id
  -- Inserters: the exact pickup/drop points, the tiles they are on, and what
  -- stands there (the same view as scan fields=io).
  if e.type=='inserter' then
    out.pickup_position=e.pickup_position; out.drop_position=e.drop_position
    local ok,io=pcall(scan_fields.io,e)
    if ok then out.io=io end
  end
  -- Fluid connections: where each one is, the neighbouring tile it joins,
  -- its flow, and what is connected there (in scan fields=fluids form too).
  local okc,conns=pcall(pipes.connections,e)
  if okc and conns and #conns>0 then
    out.fluid_connections={}
    for i,c in ipairs(conns) do
      local target=c.target
      out.fluid_connections[i]={box=c.box,flow=c.flow,kind=c.kind,fluid=c.fluid,
        at={x=c.x+0.5,y=c.y+0.5},joins={x=c.tx+0.5,y=c.ty+0.5},direction=compass_names[c.dir],
        connected_to=target and target.valid and target.name or nil,underground_reach=c.reach}
    end
    local okf,text=pcall(pipes.fluids,e)
    if okf and text then out.fluids_summary=text end
  end
  if e.type=='transport-belt' or e.type=='underground-belt' or e.type=='splitter' then
    out.belt_lines={}
    for i=1,e.get_max_transport_line_index() do out.belt_lines[i]=e.get_transport_line(i).get_contents() end
  end
  for name in pairs(inventories) do
    local ok,inv=pcall(inventory,e,name)
    if ok then out.inventories[name]=contents(inv) end
  end
  if e.type=='assembling-machine' or e.type=='furnace' then
    local recipe=e.get_recipe(); out.recipe=recipe and recipe.name or false
    out.crafting_progress=e.crafting_progress
  end
  return out
end
function handlers.rotate(p,a)
  local e=entity(p,a); friendly(p,e)
  local rotated=e.rotate{reverse=a.reverse == true,by_player=real(p)}
  -- Rotating an underground flips its end (and its partner's): show the result.
  return {rotated=rotated,entity=summary(e)}
end
-- Changing a recipe works as it does for a player: machine contents and the
-- ingredients of an interrupted craft go to the inventory, spilling at the
-- character's feet when it is full. Fluids are lost, so that needs force.
-- Item filters, as a player sets them in an inserter's (or loader's) GUI.
local function configure_filters(e,a)
  assert(a.recipe==nil,'give recipe or filters, not both')
  local slots=e.filter_slot_count or 0
  assert(slots>0,e.name..' has no filter slots')
  assert(type(a.filters)=='table' and #a.filters<=slots,'filters requires 0..'..slots..' item names')
  for _,name in ipairs(a.filters) do assert(prototypes.item[name],'unknown item '..tostring(name)) end
  if a.filter_mode~=nil then
    assert(a.filter_mode=='whitelist' or a.filter_mode=='blacklist','filter_mode is whitelist or blacklist')
    e.inserter_filter_mode=a.filter_mode
  end
  for i=1,slots do e.set_filter(i,a.filters[i]) end
  if e.type=='inserter' then e.use_filters=#a.filters>0 end
  local mode=e.type=='inserter' and e.inserter_filter_mode or nil
  return {filters=a.filters,filter_mode=mode}
end
-- Out of reach, 2.0's remote view still opens the machine: recipes and
-- filters change the same way, but contents cannot come back to the
-- character, so a remote recipe change needs an empty, idle machine.
local function holds_items(e)
  for _,name in ipairs({'assembling_machine_input','assembling_machine_output'}) do
    local ok,inv=pcall(inventory,e,name)
    if ok and not inv.is_empty() then return true end
  end
  return (e.crafting_progress or 0)>0
end
function handlers.configure(p,a)
  local near,e=pcall(entity,p,a)
  if not near then
    local ok,far=pcall(remote_entity,p,a)
    if not ok then error(e,0) end
    e=far
  end
  friendly(p,e)
  if a.filters~=nil then return configure_filters(e,a) end
  assert(e.type=='assembling-machine','only assembling machines support recipe configuration')
  local recipe=type(a.recipe)=='string' and p.force.recipes[a.recipe]
  assert(recipe and recipe.enabled,'recipe is unavailable')
  assert(e.prototype.crafting_categories[recipe.category],'recipe incompatible with machine')
  local current=e.get_recipe()
  if current and current.name==recipe.name then return {recipe=recipe.name,unchanged=true} end
  if not a.force then
    for i=1,#e.fluidbox do assert(not e.fluidbox[i],'machine holds fluid that a recipe change destroys; pass force=true') end
  end
  assert(near or not holds_items(e),string.format('remote recipe change: the machine at (%g,%g) holds items or is mid-craft, which only come back to a character in reach; walk there (%s) or empty it first',
    e.position.x,e.position.y,from_character(p,e.position)))
  local returned,spilled={},{}
  -- A machine slot is inserted as the stack itself so item data (spoilage) travels.
  local function give(stack,slot)
    local count=stack.count
    -- Slots carry a LuaQualityPrototype (userdata); set_recipe returns names.
    local quality=stack.quality
    if type(quality)~='string' then quality=quality and quality.name or 'normal' end
    local key=stack.name..(quality~='normal' and '@'..quality or '')
    local inserted=p.insert(slot and stack or {name=stack.name,count=count,quality=quality})
    returned[key]=(returned[key] or 0)+count
    if inserted<count then
      spilled[key]=(spilled[key] or 0)+count-inserted
      local rest={name=stack.name,count=count-inserted,quality=quality}
      if slot then stack.count=count-inserted; rest=stack end
      p.surface.spill_item_stack{position=p.position,stack=rest,enable_looted=true,allow_belts=false}
    end
    if slot then stack.clear() end
  end
  for _,name in ipairs({'assembling_machine_input','assembling_machine_output'}) do
    local ok,inv=pcall(inventory,e,name)
    for i=1,ok and #inv or 0 do
      if inv[i].valid_for_read then give(inv[i],true) end
    end
  end
  for _,item in ipairs(e.set_recipe(recipe.name,a.quality) or {}) do give(item) end
  current=e.get_recipe()
  assert(current and current.name==recipe.name,'recipe incompatible with machine')
  return {recipe=current.name,remote=not near or nil,returned=next(returned) and returned or nil,spilled=next(spilled) and spilled or nil}
end
-- Omitted inventories are inferred the way a player's click is: fuel into the
-- burner, smeltables into the furnace, and results back out of it.
local function infer_inventory(e,a)
  local item=a.item and prototypes.item[a.item]
  local fuel=item and (item.fuel_value or 0)>0
  if a.direction=='to_entity' and item and kind_order[item.type] then
    for _,name in ipairs(kind_order[item.type]) do
      local ok,inv=pcall(inventory,e,name)
      if ok then return name,inv end
    end
  end
  local fallback
  for _,name in ipairs(a.direction=='to_player' and take_order or give_order) do
    local ok,inv=pcall(inventory,e,name)
    if ok then
      if a.direction=='to_entity' then
        -- An inventory that refuses the item (a silo's ingredient slots for
        -- rocket cargo, say) yields to a later one that takes it.
        local accepts=not (item and inv.can_insert) or inv.can_insert{name=a.item,quality=a.quality or 'normal'}
        if accepts and (name=='fuel' or not fuel or not e.get_fuel_inventory()) then return name,inv end
        fallback=fallback or {name,inv}
      elseif not a.item or inv.get_item_count{name=a.item,quality=a.quality or 'normal'}>0 then return name,inv
      else fallback=fallback or {name,inv} end
    end
  end
  assert(fallback,'entity has no transferable inventory')
  return fallback[1],fallback[2]
end
-- Moves matching stacks with transfer_stack so item metadata travels intact.
local function move_stacks(source,target,match,limit)
  local remaining,moved,order=limit,{},{}
  for i=1,#source do
    if remaining==0 then break end
    local stack=source[i]
    if stack.valid_for_read and match(stack) then
      local key,name,quality,start=stack.name..'@'..stack.quality.name,stack.name,stack.quality.name,stack.count
      -- Top up partial stacks of the same item first, as a player's
      -- shift-click does, then fill empty slots.
      for pass=1,2 do
        for j=1,#target do
          if remaining==0 or not stack.valid_for_read then break end
          local slot=target[j]
          if (pass==1)==(slot.valid_for_read and slot.name==name and slot.quality.name==quality) then
            local before=stack.count
            slot.transfer_stack(stack,math.min(before,remaining))
            remaining=remaining-(before-(stack.valid_for_read and stack.count or 0))
          end
        end
      end
      local n=start-(stack.valid_for_read and stack.count or 0)
      if n>0 then
        if not moved[key] then moved[key]={name=name,count=0,quality=quality~='normal' and quality or nil}; order[#order+1]=key end
        moved[key].count=moved[key].count+n
      end
    end
  end
  local stacks={}
  for i,key in ipairs(order) do stacks[i]=moved[key] end
  return limit-remaining,stacks
end
-- Where the character gives items from: the main inventory, then for ammo
-- the gun ammo slots, where crafted and picked-up ammo lands first.
local function give_sources(p,item)
  local out={p.get_main_inventory()}
  local proto=item and prototypes and prototypes.item[item]
  if proto and proto.type=='ammo' and defines.inventory.character_ammo and p.get_inventory then
    local ammo=p.get_inventory(defines.inventory.character_ammo)
    if ammo then out[#out+1]=ammo end
  end
  return out
end
local function held(p,item,quality)
  local n=0
  for _,inv in ipairs(give_sources(p,item)) do n=n+inv.get_item_count{name=item,quality=quality or 'normal'} end
  return n
end
local function transfer_one(p,a,pos,e)
  if e then assert(p.can_reach_entity(e),'entity is out of reach')
  else e=entity(p,{position=pos,name=pos.name or a.name,unit_number=pos.unit_number or a.unit_number}) end
  friendly(p,e)
  local inferred,target
  if a.inventory then target=inventory(e,a.inventory) else inferred,target=infer_inventory(e,a) end
  local sources=a.direction=='to_player' and {target} or give_sources(p,a.item)
  if a.direction=='to_player' then target=p.get_main_inventory() end
  local quality=a.quality or 'normal'
  local wanted,match
  local function count(inv) return inv.get_item_count{name=a.item,quality=quality} end
  local function available()
    local n=0
    for _,inv in ipairs(sources) do n=n+count(inv) end
    return n
  end
  if a.item then
    match=function(s) return s.name==a.item and s.quality.name==quality end
    -- Taking an item defaults to all of it; giving defaults to one.
    wanted=integer(a.count,a.direction=='to_player' and 10000 or 1,1,10000,'count')
    if a.keep~=nil then wanted=math.min(wanted,math.max(0,available()-integer(a.keep,0,0,100000,'keep'))) end
    if a.up_to~=nil then wanted=math.min(wanted,math.max(0,integer(a.up_to,1,1,100000,'up_to')-count(target))) end
  else
    match=function() return true end
    wanted=integer(a.count,1000000,1,1000000,'count')
  end
  if a.budget then wanted=math.min(wanted,a.budget.left) end
  local moved,stacks,order=0,{},{}
  for _,source in ipairs(sources) do
    if moved>=wanted then break end
    local n,part=move_stacks(source,target,match,wanted-moved)
    moved=moved+n
    for _,st in ipairs(part) do
      local key=st.name..'@'..(st.quality or 'normal')
      if order[key] then order[key].count=order[key].count+st.count else order[key]=st; stacks[#stacks+1]=st end
    end
  end
  if a.budget then a.budget.left=a.budget.left-moved end
  -- Matching items left behind while more was asked for: the target is full.
  local full
  if moved<wanted then
    for _,source in ipairs(sources) do
      for i=1,#source do
        local stack=source[i]
        if not full and stack.valid_for_read and match(stack) then
          local left=0
          for _,inv in ipairs(sources) do left=left+inv.get_item_count{name=stack.name,quality=stack.quality.name} end
          full={requested=math.min(wanted,moved+left),got=moved,blocked_item=stack.name}
        end
      end
    end
  end
  -- A burner's fuel slot holds one fuel type: giving coal to a boiler burning
  -- wood is refused by the game; say what is in the way.
  if full and a.direction=='to_entity' and (a.inventory or inferred)=='fuel' then
    for i=1,#target do
      local slot=target[i]
      if slot.valid_for_read and slot.name~=a.item then
        full.holding=slot.name
        full.note=string.format('the fuel slot holds %s; one fuel type at a time: let it burn out or take it out first (transfer to_player item=%s)',slot.name,slot.name)
        break
      end
    end
  end
  -- Asked for an item the character does not hold at all: say so.
  local short=a.item and a.direction=='to_entity' and moved<wanted and not full and moved==0 and available()==0 and wanted or nil
  -- Hand share: feeding anything, and collecting from machines (not storage).
  local kind=a.direction=='to_entity' and 'fed' or (e.type~='container' and e.type~='logistic-container' and 'collected')
  for _,s in ipairs(kind and stacks or {}) do survey.log_hand(kind,s.name,s.count) end
  if moved>0 then
    -- The usual inventory feedback a player sees when moving items by hand.
    local sign,parts=a.direction=='to_player' and '+' or '-',{}
    for _,s in ipairs(stacks) do parts[#parts+1]=sign..s.count..' [item='..s.name..']' end
    p.create_local_flying_text{text=table.concat(parts,' '),position=e.position}
  end
  local out={transferred=moved,items=not a.item and stacks or nil,inventory=inferred,none_held=short and a.item or nil,target_has=short and count(target) or nil}
  if a.direction=='to_player' then out.inventory_full=full else out.entity_full=full end
  -- An emptied corpse goes, as when a player takes everything from it.
  if a.direction=='to_player' and e.type=='character-corpse' and sources[1].is_empty() then e.destroy(); out.corpse_removed=true end
  return out
end
-- Targets are {position} or {entity}. Each is independent: an unreachable one
-- must not undo the others. Quiet batches list only entities that changed or failed.
local function transfer_batch(p,a,targets,quiet)
  local total,totals,items,rows,untouched=0,{},{},{},0
  local blocked,short
  for _,t in ipairs(targets) do
    local pos=t.entity and t.entity.position or t.position
    local ok,result
    -- A spent batch total or a full character inventory ends the batch.
    if (a.budget and a.budget.left==0) or blocked then ok=false
    else ok,result=pcall(transfer_one,p,a,t.position,t.entity) end
    if result==nil then untouched=untouched+1
    elseif ok then
      total=total+result.transferred
      blocked=result.inventory_full and result.inventory_full.blocked_item
      if result.none_held then
        short=short or {}
        short[#short+1]=string.format('(%g,%g) has %d',pos.x,pos.y,result.target_has)
      end
      if result.transferred>0 or not quiet or result.entity_full then rows[#rows+1]={position=pos,transferred=result.transferred,full=result.entity_full and true or nil} else untouched=untouched+1 end
      for _,s in ipairs(result.items or {}) do
        local key=s.name..'@'..(s.quality or 'normal')
        if totals[key] then totals[key].count=totals[key].count+s.count
        else totals[key]={name=s.name,count=s.count,quality=s.quality}; items[#items+1]=totals[key] end
      end
    else rows[#rows+1]={position=pos,transferred=0,error=reason(result)} end
  end
  -- Nothing moved and targets wanted more, but the character holds none.
  if a.fail_short and total==0 and short then
    error(string.format('no %s in inventory or ammo slots; %d target(s) want more: %s',a.item,#short,table.concat(short,', ',1,math.min(#short,6))),0)
  end
  return {transferred=total,items=not a.item and items or nil,entities=rows,unchanged=(quiet or untouched>0) and untouched or nil,
    none_held=short and #short or nil,total=a.budget and a.budget.cap,inventory_full=blocked and {got=total,blocked_item=blocked} or nil}
end
-- Items a feed still needs across its targets (up_to tops up; else count each).
local function shortfall(p,a,targets)
  local need=0
  for _,t in ipairs(targets) do
    local ok,n=pcall(function()
      local e=t.entity or entity(p,{position=t.position,name=t.position.name or a.name,unit_number=t.position.unit_number or a.unit_number})
      local _,inv
      if a.inventory then inv=inventory(e,a.inventory) else _,inv=infer_inventory(e,a) end
      local have=inv.get_item_count{name=a.item,quality=a.quality or 'normal'}
      return a.up_to and math.max(0,a.up_to-have) or (a.count or 1)
    end)
    if ok then need=need+n end
  end
  return need
end
-- A feed short of items the hand-crafting queue will deliver waits for them
-- (like construct does) instead of moving nothing: a timed 'feed' action that
-- reruns the handler once the crafts land.
local FEED_CHECK=10
local function await_feed(p,handler,a,item,need)
  if a.awaited or need<=0 then return nil end
  local have,coming=held(p,item,a.quality),crafting_count(p,item)
  if have>=need or coming==0 then return nil end
  if state().active[p.index] then finish(p.index,'replaced') end
  local args={}
  for k,v in pairs(a) do args[k]=v end
  args.awaited=true
  local until_tick=game.tick+math.ceil(crafting_left(p)*60)+600
  state().active[p.index]={kind='feed',handler=handler,args=args,item=item,need=need,awaiting_craft=true,until_tick=until_tick,next_check=game.tick+FEED_CHECK}
  return {awaiting_craft={item=item,held=have,need=need,crafting=coming},until_tick=until_tick}
end
M.await_feed=await_feed
-- Own entities in reach (or at explicit positions) matching a predicate,
-- nearest first so a short supply goes to the closest machines.
local function reachable(p,a,wanted)
  local out={}
  if a.positions then
    assert(type(a.positions)=='table' and #a.positions>=1 and #a.positions<=64,'positions requires 1..64 entries')
    for i,pos in ipairs(a.positions) do out[i]={position=pos} end
    return out
  end
  local found={}
  for _,e in pairs(p.surface.find_entities_filtered{position=p.position,radius=(p.reach_distance or 10)+3,force=p.force,type=a.types}) do
    if e.valid and wanted(e) and p.can_reach_entity(e) then found[#found+1]=e end
  end
  table.sort(found,function(x,y) return distance(p.position,x.position)<distance(p.position,y.position) end)
  for i,e in ipairs(found) do out[i]={entity=e} end
  return out
end
-- With a radius, rearm/refuel walk a nearest-first route through every
-- matching entity in it that is below the target, topping each up.
local function below_target(p,a,radius,wanted,inv_of,item,count)
  local out={}
  for _,e in pairs(p.surface.find_entities_filtered{position=p.position,radius=radius,force=p.force,type=a.types}) do
    if e.valid and wanted(e) then
      local inv=inv_of(e)
      if inv and inv.get_item_count{name=item,quality=a.quality or 'normal'}<count then out[#out+1]=e end
    end
  end
  return out
end
local function start_tour(p,a,op,item,count,targets)
  assert(held(p,item,a.quality)+crafting_count(p,item)>0,string.format('no %s in inventory%s; %d entities in radius want more',item,op=='rearm' and ' or ammo slots' or '',#targets))
  local action,out=stock.start_tour(p,op,targets,integer(a.ticks,3600,1,36000,'ticks'),{item=item,quality=a.quality,count=count})
  if state().active[p.index] then finish(p.index,'replaced') else stop(p) end
  state().active[p.index]=action
  out.until_tick=action.until_tick; out.held=held(p,item,a.quality)
  return out
end
-- Tops every burner in reach up to `count` of one fuel item.
function handlers.refuel(p,a)
  local fuel=a.fuel or 'coal'
  assert(type(fuel)=='string' and prototypes.item[fuel] and (prototypes.item[fuel].fuel_value or 0)>0,'fuel must be a fuel item')
  local count=integer(a.count,10,1,1000,'count')
  if a.radius~=nil then
    assert(a.positions==nil,'give radius or positions, not both')
    local targets=below_target(p,a,integer(a.radius,32,1,256,'radius'),function(e) return fuel_inventory(e)~=nil and pcall(inventory,e,'fuel') end,fuel_inventory,fuel,count)
    return start_tour(p,a,'refuel',fuel,count,targets)
  end
  assert(a.ticks==nil,'ticks applies with radius')
  local targets=reachable(p,a,function(e) return fuel_inventory(e)~=nil and pcall(inventory,e,'fuel') end)
  local args={direction='to_entity',item=fuel,inventory='fuel',count=count,up_to=count,quality=a.quality,fail_short=true}
  local waiting=await_feed(p,'refuel',a,fuel,shortfall(p,args,targets))
  if waiting then return waiting end
  return transfer_batch(p,args,targets,true)
end
-- Tops every turret in reach (or at positions) up to `count` of one ammo item.
function handlers.rearm(p,a)
  local ammo=a.ammo or 'firearm-magazine'
  assert(type(ammo)=='string' and prototypes.item[ammo] and prototypes.item[ammo].type=='ammo','ammo must be an ammo item')
  local count=integer(a.count,10,1,1000,'count')
  if a.radius~=nil then
    assert(a.positions==nil,'give radius or positions, not both')
    local types=a.types or {'ammo-turret'}
    local targets=below_target(p,{types=types,quality=a.quality},integer(a.radius,32,1,256,'radius'),function(e) return ammo_inventory[e.type]~=nil end,
      function(e) return e.get_inventory(defines.inventory[ammo_inventory[e.type]]) end,ammo,count)
    return start_tour(p,a,'rearm',ammo,count,targets)
  end
  assert(a.ticks==nil,'ticks applies with radius')
  local args={direction='to_entity',item=ammo,count=count,up_to=count,quality=a.quality,positions=a.positions,types=a.types or {'ammo-turret'},fail_short=true}
  assert(type(args.types)=='table' and #args.types>=1,'types requires entity types')
  local targets=reachable(p,args,function(e) return ammo_inventory[e.type]~=nil end)
  local waiting=await_feed(p,'rearm',a,ammo,shortfall(p,args,targets))
  if waiting then return waiting end
  return transfer_batch(p,args,targets,true)
end
-- Empties the outputs of furnaces and assemblers in reach. Plain chests are
-- usually feed chests the player stocked for machines, so they are only
-- emptied when named by position, listed in types, or with chests=true.
local collect_types={plain={'furnace','assembling-machine'},chests={'furnace','assembling-machine','container','logistic-container'}}
function handlers.collect(p,a)
  assert(a.chests==nil or type(a.chests)=='boolean','chests must be true or false')
  assert(a.types==nil or (type(a.types)=='table' and #a.types>=1 and #a.types<=16),'types requires 1..16 entity types')
  -- want: a target holding (shake2 and shake3 plans wrote collect want=N);
  -- takes only the difference, and nothing when the character has enough.
  -- Worked out when the step runs, so a queued step sees what earlier steps got.
  if a.want~=nil then
    assert(type(a.item)=='string','want needs item: collect item=NAME want=N stops once you hold N')
    assert(a.count==nil,'give count (how many to take) or want (how many to hold), not both')
    local want,have=integer(a.want,1,1,100000,'want'),held(p,a.item,a.quality)
    if have>=want then return {transferred=0,held=have,want=want,note='already holding '..have..' '..a.item} end
    local copy={}
    for k,v in pairs(a) do copy[k]=v end
    copy.want=nil; copy.count=math.min(want-have,10000)
    a=copy
  end
  if a.radius~=nil then
    local action,out=stock.start(p,a,integer(a.ticks,3600,1,36000,'ticks'))
    if state().active[p.index] then finish(p.index,'replaced') else stop(p) end
    state().active[p.index]=action
    out.until_tick=action.until_tick
    return out
  end
  assert(a.ticks==nil,'ticks applies to collect with radius')
  local args={direction='to_player',item=a.item,types=a.types or (a.chests and collect_types.chests or collect_types.plain),positions=a.positions,quality=a.quality}
  args.count=a.item and integer(a.count,10000,1,10000,'count') or nil
  local targets=reachable(p,args,function() return true end)
  local out=transfer_batch(p,args,targets,true)
  -- Named targets inside another agent's claim are taken from, but say whose.
  local claimed={}
  for _,t in ipairs(targets) do
    local ok,at=pcall(position,t.entity and t.entity.valid and t.entity.position or t.position)
    local c=ok and #claimed<4 and M.claims.other(p,at)
    if c then claimed[#claimed+1]=string.format('(%g,%g) in %s',at.x,at.y,M.claims.label(c)) end
  end
  if #claimed>0 then out.claimed=claimed end
  if not a.positions and not a.types and not a.chests then
    local skipped=0
    for _,e in pairs(p.surface.find_entities_filtered{position=p.position,radius=(p.reach_distance or 10)+3,force=p.force,type={'container','logistic-container'}}) do
      if e.valid and p.can_reach_entity(e) then
        local ok,inv=pcall(e.get_inventory,defines.inventory.chest)
        if ok and inv and (not a.item and not inv.is_empty() or a.item and inv.get_item_count{name=a.item,quality=a.quality or 'normal'}>0) then skipped=skipped+1 end
      end
    end
    if skipped>0 then out.chests_skipped=skipped; out.note='chests in reach were left alone; pass chests=true or their positions to take from them' end
  end
  return out
end
-- What a machine takes by hand: its recipe's item ingredients (a furnace's
-- last recipe when idle), a lab's science packs, and a burner's fuel. Each
-- want names the inventory the item goes to and the target count.
local feeding={TYPES={'assembling-machine','furnace','lab','boiler','burner-generator','mining-drill','inserter'}}
function feeding.wants(p,e,a)
  local out={}
  local fuel=a.fuel~=false and (a.fuel or 'coal')
  if fuel and fuel_inventory(e) and pcall(inventory,e,'fuel') then out[#out+1]={item=fuel,inventory='fuel',count=a.fuel_count} end
  local recipe
  if e.type=='assembling-machine' or e.type=='furnace' then
    local ok,r=pcall(e.get_recipe); recipe=ok and r or nil
    if not recipe and e.type=='furnace' then
      local okp,prev=pcall(function() return e.previous_recipe end)
      local name=okp and prev and prev.name
      name=type(name)=='table' and name.name or name
      recipe=name and prototypes.recipe and prototypes.recipe[name] or nil
    end
    for _,ing in ipairs(recipe and recipe.ingredients or {}) do
      if ing.type=='item' then out[#out+1]={item=ing.name,inventory=e.type=='furnace' and 'furnace_source' or 'assembling_machine_input',count=a.count} end
    end
  elseif e.type=='lab' then
    local ok,names=pcall(function() return e.prototype.lab_inputs end)
    for _,name in ipairs(ok and names or {}) do out[#out+1]={item=name,inventory='lab_input',count=a.count} end
  end
  if a.items then
    local keep,only={},{}
    for _,name in ipairs(a.items) do only[name]=true end
    for _,w in ipairs(out) do if only[w.item] then keep[#keep+1]=w end end
    out=keep
  end
  return out
end
-- Feeds one machine every want the character can spare; returns what it got.
function feeding.one(p,e,a)
  local gave,total={},0
  local keep=integer(a.keep,0,0,100000,'keep')
  for _,w in ipairs(feeding.wants(p,e,a)) do
    if held(p,w.item,a.quality)>keep then
      local ok,out=pcall(transfer_one,p,{direction='to_entity',item=w.item,inventory=w.inventory,count=w.count,up_to=w.count,keep=keep,quality=a.quality},nil,e)
      if ok and out.transferred>0 then gave[w.item]=(gave[w.item] or 0)+out.transferred; total=total+out.transferred end
    end
  end
  return gave,total
end
-- A machine that wants something the character holds beyond the reserve and
-- is below the target count for it.
function feeding.hungry(p,e,a)
  local keep=integer(a.keep,0,0,100000,'keep')
  for _,w in ipairs(feeding.wants(p,e,a)) do
    if held(p,w.item,a.quality)>keep then
      local ok,inv=pcall(inventory,e,w.inventory)
      if ok and inv.get_item_count{name=w.item,quality=a.quality or 'normal'}<w.count then return true end
    end
  end
  return false
end
-- Hand-feeds machines from inventory: recipe ingredients, science packs and
-- fuel, up to count each, keeping a reserve. In reach by default, at given
-- positions, or as a walking tour with radius. Nothing is taken out.
function handlers.feed(p,a)
  assert(a.items==nil or (type(a.items)=='table' and #a.items>=1 and #a.items<=16),'items requires 1..16 item names')
  for _,name in ipairs(a.items or {}) do assert(prototypes.item[name],'unknown item '..tostring(name)) end
  assert(a.fuel==nil or a.fuel==false or (type(a.fuel)=='string' and prototypes.item[a.fuel] and (prototypes.item[a.fuel].fuel_value or 0)>0),'fuel must be a fuel item or false')
  a.count=integer(a.count,20,1,1000,'count'); a.fuel_count=integer(a.fuel_count,10,1,1000,'fuel_count')
  assert(a.types==nil or (type(a.types)=='table' and #a.types>=1 and #a.types<=16),'types requires 1..16 entity types')
  local types=a.types or feeding.TYPES
  if a.radius~=nil then
    assert(a.positions==nil,'give radius or positions, not both')
    local targets={}
    for _,e in pairs(p.surface.find_entities_filtered{position=p.position,radius=integer(a.radius,32,1,256,'radius'),force=p.force,type=types}) do
      if e.valid and feeding.hungry(p,e,a) then targets[#targets+1]=e end
    end
    local action,out=stock.start_tour(p,'feed',targets,integer(a.ticks,3600,1,36000,'ticks'),{feed=a})
    if state().active[p.index] then finish(p.index,'replaced') else stop(p) end
    state().active[p.index]=action
    out.until_tick=action.until_tick
    return out
  end
  assert(a.ticks==nil,'ticks applies with radius')
  local targets=reachable(p,{positions=a.positions,types=types},function() return true end)
  local rows,items,total,unchanged={},{},0,0
  for _,t in ipairs(targets) do
    local ok,e=pcall(function() return t.entity or entity(p,{position=t.position,name=t.position.name,unit_number=t.position.unit_number}) end)
    if not ok then rows[#rows+1]={position=t.position,error=reason(e)}
    else
      local okf,gave,n=pcall(feeding.one,p,e,a)
      if not okf then rows[#rows+1]={position=e.position,name=e.name,error=reason(gave)}
      elseif n>0 then
        rows[#rows+1]={position=e.position,name=e.name,gave=gave}
        for item,c in pairs(gave) do items[item]=(items[item] or 0)+c end
        total=total+n
      else unchanged=unchanged+1 end
    end
  end
  local left={}
  for item in pairs(items) do left[item]=held(p,item,a.quality) end
  return {transferred=total,items=next(items) and items or nil,entities=rows,unchanged=unchanged>0 and unchanged or nil,held=next(left) and left or nil,
    note=total==0 and 'nothing given: no machine in reach wants an item you hold above keep (or they are at count already)' or nil}
end
-- Items of this name in an entity's transferable inventories (fuel included).
local function entity_holds(e,item,quality)
  local n=0
  for _,name in ipairs(take_order) do
    local ok,inv=pcall(inventory,e,name)
    if ok then n=n+inv.get_item_count{name=item,quality=quality or 'normal'} end
  end
  return n
end
-- An omitted direction follows where the item is, as a player's click would:
-- no item takes everything; an item only the character holds (or will get
-- from the hand-craft queue) is given; one only the targets hold is taken.
local function infer_direction(p,a)
  if a.item==nil then return 'to_player' end
  local mine=held(p,a.item,a.quality)+crafting_count(p,a.item)
  local theirs=0
  for _,pos in ipairs(a.positions or {a.position}) do
    local ok,n=pcall(function()
      local e=entity(p,{position=pos,name=pos.name or a.name,unit_number=pos.unit_number or a.unit_number})
      friendly(p,e)
      return entity_holds(e,a.item,a.quality)
    end)
    if ok then theirs=theirs+n end
  end
  if mine>0 and theirs==0 then return 'to_entity' end
  if theirs>0 and mine==0 then return 'to_player' end
  error(string.format('direction is required (to_entity|to_player): the character holds %d %s and the target%s %d',
    mine,a.item,a.positions and 's hold' or ' holds',theirs),0)
end
local transfer_directed
function handlers.transfer(p,a)
  assert(a.direction==nil or a.direction=='to_entity' or a.direction=='to_player','direction must be to_entity or to_player')
  assert(a.item==nil or type(a.item)=='string','item must be a string')
  if a.direction~=nil then return transfer_directed(p,a) end
  local args={}
  for k,v in pairs(a) do args[k]=v end
  args.direction=infer_direction(p,a)
  local out=transfer_directed(p,args)
  out.direction=args.direction
  return out
end
transfer_directed=function(p,a)
  assert(a.item or a.direction=='to_player','item is required for to_entity')
  assert(a.item or (a.keep==nil and a.up_to==nil),'keep and up_to require item')
  if a.direction=='to_entity' and a.total==nil then
    local targets={}
    for i,pos in ipairs(a.positions or {a.position}) do targets[i]={position=pos} end
    local waiting=await_feed(p,'transfer',a,a.item,shortfall(p,a,targets))
    if waiting then return waiting end
  end
  if not a.positions then
    local out=transfer_one(p,a,a.position)
    if a.item and a.count~=nil then out.requested=integer(a.count,1,1,10000,'count') end
    assert(not out.none_held,out.none_held and string.format('no %s in inventory%s; the target has %d',a.item,
      prototypes.item[a.item] and prototypes.item[a.item].type=='ammo' and ' or ammo slots' or '',out.target_has))
    return out
  end
  assert(type(a.positions)=='table' and #a.positions>=1 and #a.positions<=64,'positions requires 1..64 entries')
  -- One unit_number cannot identify several entities; put it on the entries.
  assert(a.unit_number==nil,'with positions, give unit_number per entry: {x,y,unit_number}')
  -- total caps the whole batch, filled in order; count stays per entity.
  if a.total~=nil then
    assert(a.item,'total requires item')
    local cap=integer(a.total,1,1,100000,'total')
    local args={}
    for k,v in pairs(a) do args[k]=v end
    args.budget={cap=cap,left=cap}
    args.count=a.count or math.min(cap,10000)
    a=args
  end
  local targets={}
  for i,pos in ipairs(a.positions) do targets[i]={position=pos} end
  return transfer_batch(p,a,targets,false)
end
local function queue_names(force)
  local names={}
  for i,technology in ipairs(force.research_queue or {}) do names[i]=technology.name end
  return names
end
-- What unlocks a trigger technology, in words: labs never research these.
local function trigger_text(t)
  local r=t.prototype.research_trigger
  if not r then return nil end
  local function name(v) return type(v)=='table' and (v.name or tostring(v)) or tostring(v) end
  if r.type=='craft-item' then return string.format('craft %d %s',r.count or 1,name(r.item)) end
  if r.type=='craft-fluid' then return string.format('produce %g %s',r.amount or 0,name(r.fluid)) end
  if r.type=='mine-entity' then return 'mine '..name(r.entity) end
  if r.type=='build-entity' then return 'build '..name(r.entity) end
  if r.type=='send-item-to-orbit' then return 'launch '..name(r.item)..' to orbit' end
  if r.type=='capture-spawner' then return 'capture '..(r.entity and name(r.entity) or 'a biter spawner') end
  if r.type=='create-space-platform' then return 'create a space platform' end
  return r.type
end
-- Why a technology cannot be queued behind `queued` right now; nil if it can.
local function research_block(force,name,queued)
  local t=type(name)=='string' and force.technologies[name]
  if not t then return 'unknown' end
  if t.researched then return 'already_researched' end
  if not t.enabled then return 'not_enabled' end
  if t.prototype.research_trigger then return 'trigger_unlocked ('..trigger_text(t)..')' end
  if queued[name] then return 'duplicate' end
  local missing={}
  for pre_name,pre in pairs(t.prerequisites) do
    if not (pre.researched or queued[pre_name]) then missing[#missing+1]=pre_name end
  end
  if #missing>0 then
    table.sort(missing)
    return 'prerequisites_not_queued (needs '..table.concat(missing,', ')..')'
  end
end
-- Like the game GUI: every requested technology is preceded by its unresearched
-- prerequisites (recursively, dependency order, each once) unless the list
-- already has them earlier. added maps a requested name to what was inserted.
local function with_prerequisites(force,list)
  local out,seen,added={},{},{}
  local function visit(name,root)
    local t=type(name)=='string' and force.technologies[name]
    if not t or t.researched or seen[name] then return end
    seen[name]=true
    local pres={}
    for pre_name,pre in pairs(t.prerequisites) do
      if not pre.researched and not seen[pre_name] then pres[#pres+1]=pre_name end
    end
    table.sort(pres)
    for _,pre_name in ipairs(pres) do
      if not seen[pre_name] then
        visit(pre_name,root)
        added[root]=added[root] or {}
        table.insert(added[root],pre_name)
      end
    end
    out[#out+1]=name
  end
  for _,name in ipairs(list) do
    local t=type(name)=='string' and force.technologies[name]
    if t and not t.researched and not seen[name] then visit(name,name)
    elseif not seen[name] then seen[name]=true; out[#out+1]=name end
  end
  -- Report inserted prerequisites in queue order.
  local position={}
  for i,name in ipairs(out) do position[name]=i end
  for _,names in pairs(added) do table.sort(names,function(x,y) return position[x]<position[y] end) end
  return out,next(added) and added or nil
end
-- Sets the engine queue, reads it back and gives every entry that did not land
-- a reason. Entries that can land later (queue full, prerequisites still
-- pending) become the force's plan, which tick feeds in as slots free up.
local function set_research_queue(force,list)
  local added
  list,added=with_prerequisites(force,list)
  local wanted,queued,reasons={},{},{}
  for _,name in ipairs(list) do
    local why=research_block(force,name,queued)
    if why then reasons[tostring(name)]=why else wanted[#wanted+1]=name; queued[name]=true end
  end
  force.research_queue=wanted
  local queue,landed=queue_names(force),{}
  for _,name in ipairs(queue) do landed[name]=true end
  local skipped,pending={},{}
  for _,name in ipairs(list) do
    name=tostring(name)
    if not landed[name] and reasons[name]~='duplicate' then
      local why=reasons[name] or 'queue_full'
      -- Entries that can land later are kept and fed in, not dropped.
      if why=='queue_full' or why:find('^prerequisites_not_queued') then pending[#pending+1]=name
      else skipped[#skipped+1]=name..': '..why end
    end
  end
  local plans=state().research_plan or {}
  state().research_plan=plans
  plans[force.name]=#pending>0 and {names=pending,queued=#queue} or nil
  return {queue=queue,skipped=#skipped>0 and skipped or nil,pending=#pending>0 and pending or nil,
    pending_note=#pending>0 and 'the engine queue is full (or prerequisites are pending): these are fed in as it frees up' or nil,added_prerequisites=added}
end
local function array_of_names(list)
  assert(type(list)=='table' and #list<=64 and (#list>0 or next(list)==nil),'research_queue requires an array of 0..64 names')
  return list
end
-- research_queue replaces the queue; with front it goes ahead of the current
-- queue, with append behind it. A lone technology is added (or put in front).
function handlers.research(p,a)
  local force=p.force
  local current=queue_names(force)
  -- Adding keeps names still waiting for room behind the engine queue.
  local plan=state().research_plan and state().research_plan[force.name]
  local waiting=plan and plan.names or {}
  local function with_waiting(list)
    local seen={}
    for _,name in ipairs(list) do seen[name]=true end
    for _,name in ipairs(waiting) do if not seen[name] then seen[name]=true; list[#list+1]=name end end
    return list
  end
  if a.research_queue then
    local list=array_of_names(a.research_queue)
    assert(not (a.front and a.append),'use front or append, not both')
    if a.front or a.append then
      local merged,seen={},{}
      local first,second=list,current
      if a.append then first,second=current,list end
      for _,part in ipairs{first,second} do
        for _,name in ipairs(part) do if not seen[name] then seen[name]=true; merged[#merged+1]=name end end
      end
      list=with_waiting(merged)
    end
    return set_research_queue(force,list)
  end
  -- No arguments: report, as observe does, instead of refusing.
  if a.technology==nil then
    assert(a.front==nil and a.append==nil,'technology or research_queue is required with front/append')
    local active=force.current_research
    local out={queue=current,pending=#waiting>0 and waiting or nil}
    if active then out.current=active.name; out.progress=force.research_progress
    else out.current=false; out.note='no research in progress: pass technology=name or research_queue=[...] (technologies available=true lists what can be researched)' end
    return out
  end
  local technology=force.technologies[a.technology]
  assert(technology,'unknown technology '..tostring(a.technology))
  -- Appending may rely on prerequisites already queued; the front may not.
  local queued={}
  if not a.front then for _,name in ipairs(current) do queued[name]=true end end
  queued[technology.name]=nil
  local why=research_block(force,technology.name,queued)
  local needs=why and why:find('^prerequisites_not_queued')
  assert(not why or needs,'technology cannot be researched: '..tostring(why))
  -- Missing prerequisites go in ahead of it, as the game GUI does.
  if needs and not a.front then
    local list={}
    for _,name in ipairs(current) do if name~=technology.name then list[#list+1]=name end end
    list[#list+1]=technology.name
    return set_research_queue(force,with_waiting(list))
  end
  if not a.front or #current==0 and not needs then
    local queued=force.add_research(technology)
    if queued or #current==0 then return {queued=queued,queue=queue_names(force)} end
    -- Refused with an item ahead of it: the engine queue is full; wait for room.
    local list={}
    for _,name in ipairs(current) do list[#list+1]=name end
    for _,name in ipairs(waiting) do if name~=technology.name then list[#list+1]=name end end
    list[#list+1]=technology.name
    return set_research_queue(force,list)
  end
  -- The first queue entry is the active research; displaced progress is kept.
  local list={technology.name}
  for _,name in ipairs(current) do if name~=technology.name then list[#list+1]=name end end
  local out=set_research_queue(force,with_waiting(list))
  -- With the queue disabled by map settings, add_research replaces the current one.
  if not needs and out.queue[1]~=technology.name then out.queued=force.add_research(technology); out.queue=queue_names(force) end
  return out
end
-- Feeds a force's pending plan into the engine queue once it has shrunk.
local function feed_research_plans()
  for name,plan in pairs(state().research_plan or {}) do
    local force=game.forces[name]
    if not (force and force.valid) then state().research_plan[name]=nil
    else
      local current=queue_names(force)
      if #current<plan.queued then
        local list=current
        for _,n in ipairs(plan.names) do list[#list+1]=n end
        set_research_queue(force,list)
      end
    end
  end
end
function handlers.research_next(p,a)
  assert(type(a.technologies)=='table' and #a.technologies>0 and #a.technologies<=64,'technologies requires 1..64 names')
  for _,name in ipairs(a.technologies) do assert(type(name)=='string' and p.force.technologies[name],'unknown technology') end
  if p.force.current_research then return {current=p.force.current_research.name,started=false} end
  for _,name in ipairs(a.technologies) do
    local t=p.force.technologies[name]
    local ready=t.enabled and not t.researched and not t.prototype.research_trigger
    for _,pre in pairs(t.prerequisites) do if not pre.researched then ready=false end end
    if ready then return {started=p.force.add_research(t),current=name} end
  end
  return {started=false,current=false}
end
local function catalog(p,a,kind)
  local limit=integer(a.limit,64,1,256,'limit')
  local prefix=a.prefix or ''; assert(type(prefix)=='string','prefix must be a string')
  local names={}
  -- available: unresearched technologies whose prerequisites are all done.
  local function available(entry)
    if entry.researched then return false end
    for _,pre in pairs(entry.prerequisites) do if not pre.researched then return false end end
    return true
  end
  for name,entry in pairs(p.force[kind]) do
    if entry.enabled and name:sub(1,#prefix)==prefix and not (a.available and kind=='technologies' and not available(entry)) then names[#names+1]=name end
  end
  table.sort(names)
  local out={entries={},truncated=#names>limit}
  for i=1,math.min(#names,limit) do
    local entry=p.force[kind][names[i]]
    if kind=='recipes' then out.entries[i]={name=entry.name,ingredients=entry.ingredients,products=entry.products,energy=entry.energy}
    else
      local prerequisites={}
      for name,pre in pairs(entry.prerequisites) do prerequisites[#prerequisites+1]={name=name,researched=pre.researched} end
      table.sort(prerequisites,function(x,y) return x.name<y.name end)
      out.entries[i]={name=entry.name,researched=entry.researched,level=entry.level,
        prerequisites=prerequisites,ingredients=entry.research_unit_ingredients,
        count=not entry.prototype.research_trigger and entry.research_unit_count or nil,energy=not entry.prototype.research_trigger and entry.research_unit_energy or nil,
        trigger=trigger_text(entry)}
    end
  end
  return out
end
function handlers.recipes(p,a) return catalog(p,a,'recipes') end
function handlers.technologies(p,a) return catalog(p,a,'technologies') end
-- The client that renders a screenshot: a player's own. A bot has none, and
-- without by_player every connected client rendered it into its own
-- script-output (shake1/2: ./shot never delivered), so one is chosen: the
-- first connected director, else the first connected player.
local function screenshot_client(p)
  local own=real(p)
  if own then return own end
  local pick
  for _,pl in pairs(game.connected_players) do
    if pl.valid then
      local rank=M.is_director(pl.index) and 0 or 1
      if not pick or rank<pick.rank or (rank==pick.rank and pl.index<pick.player.index) then pick={player=pl,rank=rank} end
    end
  end
  return pick and pick.player
end
function handlers.screenshot(p,a)
  assert(type(a.path)=='string' and #a.path<=160 and a.path:match('^[%w_/-]+%.png$') and not a.path:find('..',1,true) and a.path:sub(1,1)~='/','path must be a relative PNG path')
  local client=screenshot_client(p)
  assert(client,'no graphical client is connected to render a screenshot')
  game.take_screenshot{player=real(p),by_player=client,surface=p.surface,position=p.position,path=a.path,resolution={x=integer(a.width,1280,320,1920,'width'),y=integer(a.height,720,240,1080,'height')},zoom=1,show_entity_info=true}
  return {queued=true,path=a.path,client=client.name,requires_graphical_client=true}
end
function handlers.revive_ghost(p,a)
  local e=entity(p,a); friendly(p,e)
  assert(e.type=='entity-ghost','target must be an entity ghost')
  local needed=e.ghost_prototype
  local quality=e.quality.name
  local item
  for i=1,#p.get_main_inventory() do
    local stack=p.get_main_inventory()[i]
    if stack.valid_for_read and stack.quality.name==quality and stack.prototype.place_result==needed then item=stack.name; break end
  end
  assert(item,'no matching building item and quality in inventory')
  local direction
  for name,value in pairs(directions) do if value==e.direction then direction=name end end
  assert(direction,'unsupported ghost direction')
  local result=handlers.build(p,{item=item,quality=quality,position=e.position,direction=direction})
  result.revived=not e.valid
  return result
end
function handlers.equipment(p,a)
  local grid=p.character.grid; assert(grid,'equipped armor has no equipment grid')
  local inv=p.get_main_inventory()
  if a.operation=='insert' then
    assert(type(a.item)=='string','item required')
    local stack=inv.find_item_stack{name=a.item,quality=a.quality or 'normal'}
    assert(stack and stack.prototype.place_as_equipment_result,'equipment item missing')
    local pos=a.position and position(a.position)
    if pos then integer(pos.x,nil,0,grid.width-1,'x'); integer(pos.y,nil,0,grid.height-1,'y') end
    local equipment=grid.put{name=stack.prototype.place_as_equipment_result.name,quality=stack.quality,position=pos,by_player=real(p)}
    assert(equipment,'equipment does not fit')
    stack.count=stack.count-1
    return {inserted=equipment.name,position=equipment.position}
  end
  assert(a.operation=='remove','operation must be insert or remove')
  local pos=position(a.position)
  local equipment=grid.get(pos); assert(equipment,'equipment not found')
  local item={name=equipment.prototype.take_result.name,quality=equipment.quality.name,count=1}
  assert(inv.can_insert(item),'main inventory has no space for removed equipment')
  local removed=grid.take{equipment=equipment,by_player=real(p)}
  assert(removed,'equipment removal failed')
  local inserted=inv.insert(removed)
  if inserted<removed.count then
    p.surface.spill_item_stack{position=p.position,stack={name=removed.name,quality=removed.quality,count=removed.count-inserted},enable_looted=true,force=p.force}
  end
  return {removed=removed.name}
end
function handlers.shoot(p,a)
  local ticks=integer(a.ticks,60,1,MAX_TICKS,'ticks')
  local pos=a.position and position(a.position)
  assert(a.auto==true or pos,'specify position or auto=true')
  if pos then assert(visible(p,pos),'firing position must be locally visible') end
  if a.gun_slot then p.character.selected_gun_index=integer(a.gun_slot,nil,1,3,'gun_slot') end
  -- The engine fires from the ammo slots and spends what it fires; without
  -- ammo the trigger does nothing, so say so instead of "shooting".
  local ammo=kite.ammo_count(p)
  assert(ammo>0,'no ammunition in the ammo slots: equip some (equip slot=ammo item=firearm-magazine) or craft firearm-magazine')
  state().combat=state().combat or {}
  combat_targets()[p.index]=nil
  state().combat[p.index]={until_tick=game.tick+ticks,position=pos,auto=a.auto==true,radius=integer(a.radius,24,1,32,'radius'),ammo_start=ammo}
  return {until_tick=game.tick+ticks,ammo=ammo}
end
function handlers.equip(p,a)
  local names={gun='character_guns',ammo='character_ammo',armor='character_armor'}
  assert(names[a.slot],'slot must be gun, ammo, or armor')
  local inv=p.get_inventory(defines.inventory[names[a.slot]])
  local index=integer(a.index,1,1,#inv,'index')
  assert(type(a.item)=='string','item required')
  local source=p.get_main_inventory().find_item_stack(a.item)
  assert(source,'item is not in inventory')
  assert(inv[index].swap_stack(source),'item incompatible with slot or displaced item cannot fit')
  return {equipped=a.item,slot=a.slot,index=index}
end
local blueprint_handlers=blueprint_module{position=position,visible=visible,distance=distance,entity=entity,friendly=friendly,integer=integer,real=real,own_platform=own_platform}
for name,handler in pairs(blueprint_handlers) do handlers[name]=handler end
-- Ghosts at absolute positions, as a player places them from the cursor or
-- the map: anywhere charted, no items needed. `construct` then builds them.
-- One ghost as a player's ghost placement (shift-build): manual ghost checks
-- on charted ground, no item needed. `type` picks an underground end.
-- A tile by its tile name or by the item that places it (stone-brick ->
-- stone-path), or nil.
local function tile_named(name)
  if type(name)~='string' then return nil end
  local item=prototypes.item[name]
  local result=item and item.place_as_tile_result
  if result then return result.result.name end
  if prototypes.tile[name] and not prototypes.entity[name] then return name end
end
local function place_tile_ghost(p,tile,pos)
  assert(charted(p,pos),'position is not charted')
  local args={name='tile-ghost',inner_name=tile,position=pos,force=p.force}
  assert(p.surface.can_place_entity{name='tile-ghost',inner_name=tile,position=pos,force=p.force,build_check_type=defines.build_check_type.manual_ghost},'tile placement blocked')
  args.player=real(p); args.raise_built=true
  local ghost=p.surface.create_entity(args)
  assert(ghost,'tile placement blocked')
  return ghost
end
local function place_ghost(p,spec)
  assert(type(spec)=='table','entry must be {name,position,direction?,type?}')
  local tile=not prototypes.entity[spec.name or ''] and tile_named(spec.name)
  if tile then return place_tile_ghost(p,tile,position(spec.position)),0 end
  local proto=type(spec.name)=='string' and prototypes.entity[spec.name]
  assert(proto and proto.items_to_place_this and #proto.items_to_place_this>0,'not a placeable entity: '..tostring(spec.name))
  local pos=position(spec.position)
  assert(charted(p,pos),'position is not charted')
  local direction=spec.direction and directions[spec.direction]
  assert(spec.direction==nil or direction,'direction must be a compass name')
  assert(spec.type==nil or proto.type=='underground-belt' and (spec.type=='input' or spec.type=='output'),'type is input|output for underground belts only')
  -- The engine's check refuses trees, rocks and stumps (shake3: "placement
  -- blocked by tree-08"); a player's ghost goes over them and marks the trees
  -- and rocks, and the build clears the stumps (build_direct).
  if not p.surface.can_place_entity{name=spec.name,position=pos,direction=direction,force=p.force,build_check_type=defines.build_check_type.manual_ghost,forced=true}
    and not construction.only_obstacles(p.surface,proto,pos,direction) then
    error(placement_error(p,proto,pos,direction),0)
  end
  local ghost=p.surface.create_entity{name='entity-ghost',inner_name=spec.name,position=pos,direction=direction,force=p.force,player=real(p),raise_built=true,type=spec.type}
  assert(ghost,'placement blocked')
  local _,marked=construction.mark_obstacles(p,ghost)
  return ghost,marked
end
local function place_ghost_list(p,list)
  local placed,failed,bounds,marked=0,{},nil,0
  for i,spec in ipairs(list) do
    local ok,err=pcall(function()
      local ghost,n=place_ghost(p,spec)
      local g=ghost.position
      marked=marked+n
      bounds=bounds or {left=g.x,top=g.y,right=g.x,bottom=g.y}
      bounds.left=math.min(bounds.left,g.x); bounds.top=math.min(bounds.top,g.y)
      bounds.right=math.max(bounds.right,g.x); bounds.bottom=math.max(bounds.bottom,g.y)
    end)
    if ok then placed=placed+1 else failed[#failed+1]={index=i,error=reason(err)} end
  end
  return {placed=placed,failed=#failed>0 and failed or nil,bounds=bounds,obstacles_marked=marked>0 and marked or nil}
end
-- A filled rectangle of tile ghosts (landfill, foundation, paths); tiles the
-- game refuses there (landfill on land, a tile already present) are counted.
local function place_tile_area(p,t)
  assert(type(t)=='table' and type(t.area)=='table','tiles requires {name, area={left_top,right_bottom}}')
  local tile=tile_named(t.name); assert(tile,'tiles name must be a tile or an item that places one')
  local lt,rb=position(t.area.left_top),position(t.area.right_bottom)
  local x0,y0,x1,y1=math.floor(lt.x),math.floor(lt.y),math.ceil(rb.x)-1,math.ceil(rb.y)-1
  assert(x1>=x0 and y1>=y0 and (x1-x0+1)*(y1-y0+1)<=4096,'tiles area must be 1..4096 tiles')
  local placed,refused,existing,bounds=0,0,0,nil
  for x=x0,x1 do for y=y0,y1 do
    local pos={x=x+0.5,y=y+0.5}
    local ok=false
    local there=p.surface.find_entities_filtered{position=pos,radius=0.1,type='tile-ghost',force=p.force,limit=1}[1]
    if there and there.ghost_name==tile then existing=existing+1; ok=true
    else
      ok=pcall(place_tile_ghost,p,tile,pos)
      if ok then placed=placed+1 end
    end
    if ok then
      bounds=bounds or {left=x+0.5,top=y+0.5,right=x+0.5,bottom=y+0.5}
      bounds.left=math.min(bounds.left,x+0.5); bounds.top=math.min(bounds.top,y+0.5)
      bounds.right=math.max(bounds.right,x+0.5); bounds.bottom=math.max(bounds.bottom,y+0.5)
    else refused=refused+1 end
  end end
  return {tile=tile,tiles_placed=placed,tiles_existing=existing>0 and existing or nil,tiles_refused=refused>0 and refused or nil,bounds=bounds}
end
function handlers.place_ghosts(p,a)
  assert(a.entities~=nil or a.tiles~=nil,'place_ghosts requires entities and/or tiles')
  local out={}
  if a.entities~=nil then
    assert(type(a.entities)=='table' and #a.entities>=1 and #a.entities<=256,'entities requires 1..256 {name,position,direction?}')
    out=place_ghost_list(p,a.entities)
  end
  if a.tiles~=nil then
    local t=place_tile_area(p,a.tiles)
    for k,v in pairs(t) do if k~='bounds' then out[k]=v end end
    local b,c=out.bounds,t.bounds
    if c then
      out.bounds=b and {left=math.min(b.left,c.left),top=math.min(b.top,c.top),right=math.max(b.right,c.right),bottom=math.max(b.bottom,c.bottom)} or c
    end
  end
  return out
end
-- A belt or pipe line planned around obstacles and placed as ghosts;
-- construct builds it. dry_run only plans.
local function place_route(p,a,plan,out)
  if a.details then out.entities=plan.entities end
  local inv=p.get_main_inventory()
  for name,n in pairs(plan.items) do
    local have=inv and inv.get_item_count(name) or 0
    if have<n then out.missing=out.missing or {}; out.missing[name]=n-have end
  end
  if a.dry_run then out.dry_run=true; return out end
  local placed=place_ghost_list(p,plan.entities)
  out.placed,out.failed,out.bounds=placed.placed,placed.failed,placed.bounds
  return out
end
function handlers.belt_route(p,a)
  local plan=route.plan(p,a)
  return place_route(p,a,plan,{route=plan.route,tiles=plan.tiles,items=plan.items,arrival=plan.arrival,extends=plan.extends})
end
-- Long pipelines go in legs: through the given waypoints, or (beyond one
-- search's span) through free tiles picked along the straight line. Each leg
-- starts from the pipe ghost the previous one ended with.
local PIPE_LEG=150
local function free_pipe_tile(p,name,pos)
  local x0,y0=math.floor(pos.x),math.floor(pos.y)
  for r=0,6 do
    for dx=-r,r do for dy=-r,r do
      if math.max(math.abs(dx),math.abs(dy))==r then
        local c={x=x0+dx+0.5,y=y0+dy+0.5}
        if charted(p,c) and p.surface.can_place_entity{name=name,position=c,direction=0,force=p.force,build_check_type=defines.build_check_type.manual_ghost}
          and #p.surface.find_entities_filtered{position=c,radius=0.3,type='entity-ghost'}==0 then return c end
      end
    end end
  end
end
local function pipe_leg(p,a,from,to)
  local args={}
  for k,v in pairs(a) do if k~='waypoints' and k~='pumps' then args[k]=v end end
  args.from,args.to=from,to
  local plan=pipes.plan(p,args)
  return place_route(p,args,plan,{route=plan.route,tiles=plan.tiles,items=plan.items,joins=plan.joins}),plan
end
-- The existing segment a route end joins (pipes and tanks only; machines,
-- pumps and ghosts start segments of their own).
local function joined_box(p,join)
  if not join then return nil end
  local e=p.surface.find_entities_filtered{position=join.position,name=join.name,force=p.force,limit=1}[1]
  return pipes.segment_box(e,1)
end
-- Pumps where the finished route would pass the segment extent limit; with
-- place, they replace the route's own pipe ghosts on those tiles.
local function route_pumps(p,out,entities,joins_from,joins_to,place)
  local limit=pipes.extent_limit()
  local ext=pipes.pump_plan(entities,joined_box(p,joins_from),joined_box(p,joins_to),limit)
  out.segment_extent=ext.extent
  if ext.extent<=limit then return end
  out.extent_warning=string.format('this pipeline makes one fluid segment spanning %d tiles (limit %d, including the pipes it joins): the game stops all flow into it; %s',
    ext.extent,limit,ext.unsplittable or (place and 'pumps placed as below (they need power)' or 'add the pumps below (pumps=true places them; they need power), flowing from -> to'))
  local rows={}
  for i,pump in ipairs(ext.pumps or {}) do rows[i]={position=pump.position,direction=pump.direction} end
  out.pumps=#rows>0 and rows or nil
  if not place or out.dry_run or #rows==0 then return end
  local placed,failed=0,{}
  for _,pump in ipairs(ext.pumps) do
    local ok,err=pcall(function()
      for _,k in ipairs(pump.tiles) do
        for _,g in pairs(p.surface.find_entities_filtered{position=entities[k].position,radius=0.1,type='entity-ghost',force=p.force}) do
          if g.valid and g.ghost_name==entities[k].name then g.destroy() end
        end
      end
      place_ghost(p,{name='pump',position=pump.position,direction=pump.direction})
    end)
    if ok then placed=placed+1 else failed[#failed+1]=string.format('(%g,%g): %s',pump.position.x,pump.position.y,reason(err)) end
  end
  out.pumps_placed=placed; out.pump_failures=#failed>0 and failed or nil
  if placed>0 then
    out.items.pump=(out.items.pump or 0)+placed
    local pipe=entities[1] and entities[ext.pumps[1].tiles[1]].name
    if pipe and out.items[pipe] then out.items[pipe]=out.items[pipe]-2*placed end
  end
end
-- A line of power poles from A to B (through optional waypoints) as ghosts,
-- spaced within the pole's wire reach, each pole shifted sideways by up to
-- two tiles when its spot is blocked (water, a building, a tree that
-- construct would have to clear). Existing own poles of the same kind on the
-- line are reused. construct then builds it, like belt_route and pipe_route.
function handlers.pole_route(p,a)
  local item=a.item or 'small-electric-pole'
  local proto=prototypes.item[item]
  assert(proto and proto.place_result and proto.place_result.type=='electric-pole','item must place an electric pole (small-electric-pole, medium-electric-pole, big-electric-pole)')
  local pole=proto.place_result
  local ok,reach=pcall(function() return pole.get_max_wire_distance and pole.get_max_wire_distance() or pole.max_wire_distance end)
  reach=ok and tonumber(reach) or 7.5
  -- Spacing leaves room for a two-tile sideways shift inside the wire reach.
  local spacing=integer(a.spacing,math.max(1,math.floor(math.sqrt(reach*reach-4))),1,64,'spacing')
  assert(spacing<=reach,string.format('spacing %d is beyond the wire reach %g of %s',spacing,reach,item))
  local box=pole.collision_box or {left_top={x=-0.4,y=-0.4},right_bottom={x=0.4,y=0.4}}
  -- Footprint width in tiles: 1x1 poles sit on tile centres, 2x2 on corners.
  local even=math.ceil(box.right_bottom.x-box.left_top.x-0.01)%2==0
  local function snap(pos)
    if even then return {x=math.floor(pos.x+0.5),y=math.floor(pos.y+0.5)} end
    return {x=math.floor(pos.x)+0.5,y=math.floor(pos.y)+0.5}
  end
  local points={position(a.from)}
  for _,w in ipairs(a.waypoints or {}) do points[#points+1]=position(w) end
  points[#points+1]=position(a.to)
  assert(#points<=18,'waypoints requires at most 16 entries')
  local function free(pos)
    return p.surface.can_place_entity{name=pole.name,position=pos,force=p.force,build_check_type=defines.build_check_type.manual_ghost,forced=true}
  end
  local function existing(pos)
    for _,e in pairs(p.surface.find_entities_filtered{position=pos,radius=1.1,name=pole.name,force=p.force,limit=1}) do
      if e.valid then return e end
    end
    for _,e in pairs(p.surface.find_entities_filtered{position=pos,radius=1.1,ghost_name=pole.name,force=p.force,limit=1}) do
      if e.valid then return e end
    end
  end
  local specs,reused,failed,last={},0,{},nil
  local function place(want,perp)
    local pos=snap(want)
    local there=existing(pos)
    if there then reused=reused+1; last=there.position; return end
    for _,d in ipairs({0,1,-1,2,-2}) do
      local try={x=pos.x+perp.x*d,y=pos.y+perp.y*d}
      local ok_dist=not last or distance(last,try)<=reach
      if ok_dist and free(try) then specs[#specs+1]={name=pole.name,position=try}; last=try; return end
    end
    failed[#failed+1]={position=pos,error=placement_error(p,pole,pos,0)}
    last=pos
  end
  local total=0
  for i=1,#points-1 do
    local from,to=points[i],points[i+1]
    local dx,dy=to.x-from.x,to.y-from.y
    local length=(dx*dx+dy*dy)^0.5
    assert(length<=512,'a leg is longer than 512 tiles')
    total=total+length
    assert(total<=1024,'the route is longer than 1024 tiles')
    local ux,uy=length>0 and dx/length or 0,length>0 and dy/length or 0
    local perp=math.abs(ux)>=math.abs(uy) and {x=0,y=1} or {x=1,y=0}
    local steps=math.max(1,math.ceil(length/spacing))
    for k=(i==1 and 0 or 1),steps-1 do place({x=from.x+ux*(length*k/steps),y=from.y+uy*(length*k/steps)},perp) end
    if i==#points-1 then place(to,perp) end
  end
  local out={item=item,spacing=spacing,wire_reach=reach,poles=#specs,reused=reused>0 and reused or nil,failed=#failed>0 and failed or nil}
  local held=p.get_main_inventory().get_item_count(item)
  out.held=held; out.short=#specs>held and #specs-held or nil
  if a.dry_run then out.positions={}; for i,s in ipairs(specs) do out.positions[i]=s.position end; return out end
  if #specs>0 then
    local placed=handlers.place_ghosts(p,{entities=specs})
    out.placed=placed.placed; out.bounds=placed.bounds; out.obstacles_marked=placed.obstacles_marked
    if placed.failed then for _,f in ipairs(placed.failed) do failed[#failed+1]={position=specs[f.index].position,error=f.error} end; out.failed=failed end
  end
  out.note=#specs>0 and 'ghosts placed; run construct (default area: these bounds) to build them'..(out.short and string.format('; craft %d more %s first',out.short,item) or '') or 'nothing to place'
  return out
end
function handlers.pipe_route(p,a)
  local from,to=position(a.from),position(a.to)
  local points={from}
  if a.waypoints~=nil then
    assert(type(a.waypoints)=='table' and #a.waypoints>=1 and #a.waypoints<=16,'waypoints requires 1..16 {x,y} free tiles')
    for _,w in ipairs(a.waypoints) do points[#points+1]=position(w) end
  else
    local span=math.abs(to.x-from.x)+math.abs(to.y-from.y)
    local legs=math.ceil(span/PIPE_LEG)
    for k=1,legs-1 do
      local want={x=from.x+(to.x-from.x)*k/legs,y=from.y+(to.y-from.y)*k/legs}
      local w=free_pipe_tile(p,a.pipe or 'pipe',want)
      assert(w,string.format('no free tile for an automatic waypoint near (%g,%g); give waypoints',want.x,want.y))
      points[#points+1]=w
    end
  end
  points[#points+1]=to
  assert(a.pumps==nil or type(a.pumps)=='boolean','pumps must be boolean')
  local out={route={},tiles=0,items={},placed=0}
  if #points>2 then
    out.legs=#points-1; out.waypoints={}
    for i=2,#points-1 do out.waypoints[#out.waypoints+1]=points[i] end
  end
  local entities,first_join,last_join={},nil,nil
  for i=1,#points-1 do
    local ok,leg,plan=pcall(pipe_leg,p,a,points[i],points[i+1])
    if not ok then
      if #points==2 then error(leg,0) end
      error(string.format('pipe_route leg %d/%d (%g,%g)->(%g,%g) failed: %s%s',i,#points-1,points[i].x,points[i].y,points[i+1].x,points[i+1].y,reason(leg),
        out.bounds and string.format('; legs before it placed %d ghosts in (%g,%g)-(%g,%g)',out.placed,out.bounds.left,out.bounds.top,out.bounds.right,out.bounds.bottom) or ''),0)
    end
    for _,e in ipairs(plan.entities) do entities[#entities+1]=e end
    if i==1 then first_join=plan.joins and plan.joins.from end
    if i==#points-1 then last_join=plan.joins and plan.joins.to end
    out.route[i]=leg.route; out.tiles=out.tiles+(leg.tiles or 0); out.placed=out.placed+(leg.placed or 0)
    for name,n in pairs(leg.items or {}) do out.items[name]=(out.items[name] or 0)+n end
    for _,f in ipairs(leg.failed or {}) do out.failed=out.failed or {}; f.leg=#points>2 and i or nil; out.failed[#out.failed+1]=f end
    if leg.entities then out.entities=out.entities or {}; for _,e in ipairs(leg.entities) do out.entities[#out.entities+1]=e end end
    local b=leg.bounds
    if b then
      local t=out.bounds
      out.bounds=t and {left=math.min(t.left,b.left),top=math.min(t.top,b.top),right=math.max(t.right,b.right),bottom=math.max(t.bottom,b.bottom)} or b
    end
    out.dry_run=leg.dry_run
  end
  if first_join or last_join then out.joins={from=first_join,to=last_join} end
  route_pumps(p,out,entities,first_join,last_join,a.pumps==true)
  local inv=p.get_main_inventory()
  for name,n in pairs(out.items) do
    local have=inv and inv.get_item_count(name) or 0
    if have<n then out.missing=out.missing or {}; out.missing[name]=n-have end
  end
  out.route=table.concat(out.route,' | ')
  if out.dry_run and #points>2 then out.note='dry_run plans each leg alone from its waypoint tile' end
  if out.dry_run then out.placed=nil end
  return out
end
-- repeat={count,dx,dy} stamps the same placement count times, each shifted by
-- (dx,dy) from the previous one: a row of furnaces or turrets in one call.
-- Copies are independent; one that fails does not stop the rest.
local function shifted(pos,dx,dy) local p0=position(pos); return {x=p0.x+dx,y=p0.y+dy} end
local repeat_shift={
  paste=function(a,dx,dy) return {position=shifted(a.position,dx,dy)} end,
  blueprint_place=function(a,dx,dy) return {position=shifted(a.position,dx,dy)} end,
  place_ghosts=function(a,dx,dy)
    local list={}
    for i,spec in ipairs(type(a.entities)=='table' and a.entities or {}) do
      list[i]={name=spec.name,direction=spec.direction,position=shifted(spec.position,dx,dy)}
    end
    return {entities=list}
  end}
for name,shift in pairs(repeat_shift) do
  local handler=handlers[name]
  handlers[name]=function(p,a)
    local r=a['repeat']
    if r==nil then return handler(p,a) end
    assert(type(r)=='table','repeat is {count,dx,dy}')
    local count=integer(r.count,1,1,64,'repeat count')
    local dx,dy=r.dx or 0,r.dy or 0
    assert(type(dx)=='number' and type(dy)=='number' and (dx~=0 or dy~=0),'repeat needs a nonzero dx or dy')
    local total={copies={}}
    for i=0,count-1 do
      local args={}
      for k,v in pairs(a) do if k~='repeat' then args[k]=v end end
      for k,v in pairs(shift(a,i*dx,i*dy)) do args[k]=v end
      local ok,out=pcall(handler,p,args)
      local row={index=i+1,position=args.position or (args.entities[1] and args.entities[1].position)}
      if not ok then row.error=reason(out)
      else
        for k,v in pairs(out) do
          if type(v)=='number' and k~='expected' and k~='existing_ghosts' and k~='existing_entities' then total[k]=(total[k] or 0)+v; row[k]=v end
        end
        row.reason=out.reason
        for item,n in pairs(out.by_name or {}) do total.by_name=total.by_name or {}; total.by_name[item]=(total.by_name[item] or 0)+n end
        for _,failure in ipairs(out.failed or {}) do
          total.failed=total.failed or {}; failure.copy=i+1; total.failed[#total.failed+1]=failure
        end
        local b=out.bounds
        if b then
          local t=total.bounds
          if t then t.left=math.min(t.left,b.left); t.top=math.min(t.top,b.top); t.right=math.max(t.right,b.right); t.bottom=math.max(t.bottom,b.bottom)
          else total.bounds={left=b.left,top=b.top,right=b.right,bottom=b.bottom} end
        end
      end
      total.copies[#total.copies+1]=row
    end
    return total
  end
end
-- Remember where the last paste put ghosts so `construct` can default to it.
for _,name in ipairs({'paste','blueprint_place','place_ghosts','belt_route','pipe_route'}) do
  local handler=handlers[name]
  handlers[name]=function(p,a)
    local out=handler(p,a)
    -- construct works on the character's surface; platform ghosts are the hub's.
    if out.bounds and not (type(p)=='table' and rawget(p,'__platform')) then state().last_paste=state().last_paste or {}; state().last_paste[p.index]=out.bounds end
    return out
  end
end
-- Remote building on our space platforms: the same ghost and view actions,
-- run against the platform's surface (hub at its centre). The hub builds
-- the ghosts from its own inventory, as in the game.
local function on_platform(p,name)
  local pl=space.platform(p,name)
  assert(pl.surface,'platform '..pl.name..' has no surface yet (waiting for its starter pack)')
  local hub=pl.hub and pl.hub.valid and pl.hub.position or {x=0,y=0}
  return setmetatable({__player=real(p),__platform=pl.name},{
    __index=function(_,k) if k=='surface' then return pl.surface elseif k=='position' then return hub end return p[k] end,
    __newindex=function(_,k,v) p[k]=v end})
end
for _,name in ipairs({'place_ghosts','deconstruct','cancel_deconstruction','paste','blueprint_place','grid','scan'}) do
  local handler=handlers[name]
  handlers[name]=function(p,a)
    if a.platform==nil then return handler(p,a) end
    local args={}
    for k,v in pairs(a) do if k~='platform' then args[k]=v end end
    return handler(on_platform(p,a.platform),args)
  end
end
local permissions={walk='start_walking',move_to='start_walking',mine='begin_mining',pickup='change_picking_state',repair='start_repair',craft='craft',cancel_craft='cancel_craft',build='build',build_path='build',construct='build',place_ghosts='build',belt_route='build',pipe_route='build',pole_route='build',wire='wire_dragging',kite='change_shooting_state',revive_ghost='build',rotate='rotate_entity',configure='setup_assembling_machine',transfer='inventory_transfer',refuel='inventory_transfer',rearm='inventory_transfer',collect='inventory_transfer',feed='inventory_transfer',research='start_research',research_next='start_research',shoot='change_shooting_state',equip='inventory_transfer'}
for name,input in pairs(permissions) do
  local handler=handlers[name]
  handlers[name]=function(p,a)
    assert(not p.permission_group or p.permission_group.allows_action(defines.input_action[input]),'permission denied: '..input)
    return handler(p,a)
  end
end
local equipment_handler=handlers.equipment
handlers.equipment=function(p,a)
  local input=a.operation=='remove' and 'take_equipment' or 'place_equipment'
  assert(not p.permission_group or p.permission_group.allows_action(defines.input_action[input]),'permission denied: '..input)
  return equipment_handler(p,a)
end
local timed={walk=true,move_to=true,build_path=true,construct=true,kite=true,mine=true,pickup=true,repair=true,rearm=true,refuel=true,transfer=true,collect=true,feed=true,wait_until=true,wait_ticks=true,build=true}
-- The active action kind a step's handler starts, where it differs from its name.
local timed_kind={rearm={feed=true,gather=true},refuel={feed=true,gather=true},transfer={feed=true},build={feed=true},collect={gather=true},feed={gather=true}}
local conditions=conditions_module{known=known,position=position}
scheduler=scheduler_module{
  state=state,player=player,handlers=handlers,
  condition=function(p,c) return conditions.check(p,c) end,check_args=function(action,args) return check_args(action,args) end,validate_condition=function(c) return conditions.validate(c) end,
  busy=function(p,action)
    if action=='shoot' then return state().combat and state().combat[p.index]~=nil end
    local now=timed[action] and state().active[p.index]
    return now and (timed_kind[action] and timed_kind[action][now.kind] or now.kind==action) or false
  end,
  -- Halting controls must not pause the queue: guard reactions and goto
  -- continue right after it. Pausing is always explicit (scheduler.pause).
  stop=function(p) finish(p.index,'interrupted'); stop_combat(p.index,'interrupted') end,
  stop_index=function(index) finish(index,'interrupted'); stop_combat(index,'interrupted') end,
  -- Timed actions a plan step started are its own; any other is a direct call's.
  claim=function(p) local action=state().active[p.index]; if action then action.queued=true end end,
  direct_action=function(p) local action=state().active[p.index]; return action and not action.queued and action.kind or nil end,
  reason=reason,
  completion=function(p,action)
    local last=action=='shoot' and state().last_combat or timed[action] and state().last
    return last and last[p.index]
  end,
  outcome=function(p,action)
    local last=action=='shoot' and state().last_combat or timed[action] and state().last
    return last and last[p.index] and last[p.index].outcome
  end
}
for name,handler in pairs(scheduler.handlers) do handlers[name]=handler end
clock=clock_module{state=state,lookup=function(index) return M.lookup(index) end}
for name,handler in pairs(clock.handlers) do handlers[name]=handler end
-- Direct wait_ticks and sleep/sleep_check (waits.lua).
M.waits=require('waits'){state=state,integer=integer,
  replace=function(p) if state().active[p.index] then finish(p.index,'replaced') else stop(p) end end,
  advance=function(p,ticks) return clock.handlers.advance(p,{ticks=ticks}) end,clock_mode=function() return clock.report().mode end}
for name,handler in pairs(M.waits.handlers) do handlers[name]=handler end
M.chat=M.chat_module{state=state,on_say=function(p,text) M.profiles.say(p,text) end,audience=function() return M.cameras.audience() end,
  on_message=function(m) M.board.on_message(m) end,on_read=function(index,messages) M.board.on_read(index,messages) end,
  mention_of=function(index,m) return M.board.mention_of(index,m) end}
for name,handler in pairs(M.chat.handlers) do handlers[name]=handler end
-- Confessionals and the operator's viewer relay (audience.lua).
M.audience=require('audience'){state=state,post_viewer=function(name,text) return M.chat.viewer(name,text) end}
for name,handler in pairs(M.audience.handlers) do handlers[name]=handler end
for name,handler in pairs(M.profiles.handlers) do handlers[name]=handler end
-- Team board, reply hints, harness requests and saved plans (board.lua).
-- Bots are never directors (and game.get_player refuses their indices).
function M.is_director(index) return not M.bots.is_index(index) and M.cameras.director(index) end
M.board=require('board'){state=state,director=function(index) return M.is_director(index) end,bots=function() return M.bots.list() end,
  profile=function(index) return M.profiles.get(index) end,validate_plan=function(a) return scheduler.validate(a) end,
  submit=function(p,a) return handlers.queue_submit(p,a) end}
for name,handler in pairs(M.board.handlers) do handlers[name]=handler end
function handlers.cameras() return M.cameras.list() end
-- wait_until as a direct call: a timed action that holds the character idle
-- until the condition is met (outcome met) or the timeout passes (timed_out),
-- so `fh call wait_until --wait` works outside a queue (in turn mode the
-- clock runs for it like any timed action).
function handlers.wait_until(p,a)
  conditions.validate(a)
  local timeout=integer(a.timeout,3600,1,54000,'timeout (1..54000 ticks)')
  local condition={}
  for k,v in pairs(a) do if k~='timeout' then condition[k]=v end end
  -- Met already: done at once, like construct with nothing to do.
  local ok,met,saw=pcall(conditions.check,p,condition)
  assert(ok,met)
  if met then return {outcome='met',saw=saw,until_tick=game.tick} end
  if state().active[p.index] then finish(p.index,'replaced') else stop(p) end
  state().active[p.index]={kind='wait_until',condition=condition,saw=saw,until_tick=game.tick+timeout,next_check=game.tick+FEED_CHECK}
  return {until_tick=game.tick+timeout,condition=condition['until'],saw=saw}
end
-- Rendering observes the world without taking over character controls.
-- Actions that never drive the character; they leave a running queue alone.
local passive={sleep=true,profile=true,say=true,chat=true,confess=true,confessions=true,clock=true,advance=true,requests=true,platform_create=true,platform_schedule=true,launch=true,research=true,research_next=true,craft=true,cancel_craft=true,place_ghosts=true,deconstruct=true,cancel_deconstruction=true,blueprint_import=true,blueprint_delete=true}
local reads={labs=true,sleep_check=true,describe=true,status=true,map=true,nearest=true,craftable=true,scan=true,power=true,grid=true,rates=true,bottleneck=true,stock=true,platforms=true,observe=true,inspect=true,recipes=true,technologies=true,blueprint_export=true,blueprint_list=true,screenshot=true,profiles=true,cameras=true,inventory=true}

-- Arguments are checked against describe, so a misspelt or unsupported key
-- fails loudly instead of silently falling back to a default. Describe keys
-- that document results rather than inputs are not arguments.
local DOC_ONLY={returns=true,note=true,reports=true,outcomes=true,status=true,usage=true,checked=true,max=true}
local TARGET={'name','unit_number'}
local EXTRA_ARGS={attach={'offline'},build={'quality'},collect={'count','quality'},rearm={'quality'},refuel={'quality'},
  move_to={'within'},shoot={'auto'},transfer=TARGET,mine={'unit_number'},repair=TARGET,inspect=TARGET,rotate=TARGET,
  configure={'name','unit_number','quality'},revive_ghost={'unit_number'},observe={'scope'},requests=TARGET,launch=TARGET,
  board={'status'},board_update={'status','note'},plan_save={'note'}}
-- observe forwards to the scoped views; a scoped call is checked as that view.
local VIEW_SCOPES={map=true,nearest=true,craftable=true,scan=true,power=true,grid=true,rates=true,bottleneck=true,stock=true,platforms=true,labs=true,sleep_check=true}
local allowed_args
function check_args(action,args)
  if not allowed_args then
    allowed_args={}
    for name,schema in pairs(handlers.describe().actions) do
      local set={}
      for key in pairs(schema) do if not DOC_ONLY[key] then set[key]=true end end
      for _,key in ipairs(EXTRA_ARGS[name] or {}) do set[key]=true end
      allowed_args[name]=set
    end

  end
  local set=allowed_args[action]
  if not set or type(args)~='table' then return end
  -- A scoped observe is the view it names (the host sends craftable, scan,
  -- ... this way): only that view's own arguments, so none is silently ignored.
  if action=='observe' and args.scope~=nil and allowed_args[args.scope] and VIEW_SCOPES[args.scope] then
    action=args.scope
    set=allowed_args[action]
  end
  for key in pairs(args) do
    -- peek (boolean) on any request: read without consuming this agent's
    -- team hints (overlays polling as an agent).
    if not set[key] and not (key=='scope' and action~='observe' and VIEW_SCOPES[action]) and not (key=='peek' and type(args.peek)=='boolean') then
      local valid={}
      for k in pairs(set) do valid[#valid+1]=k end
      table.sort(valid)
      error('unknown argument '..tostring(key)..' for '..action..'; valid: '..(#valid>0 and table.concat(valid,', ') or 'none'),0)
    end
  end
end
M.check_args=check_args
-- Game-time feedback on every reply: how long since this player's previous
-- request, and how much of it the character had nothing to do (no active
-- action and no running plan) or stood waiting for hand-crafted items.
-- Hand crafting runs alongside and is listed.
-- A peeking request (fh --wait polls) reports without restarting the count,
-- so the reply after a wait covers the whole wait; it still counts as seen.
local function clock_line(p,peek)
  local clocks=state().clocks or {}; state().clocks=clocks
  local c=clocks[p.index]
  local since=c and game.tick-c.call_tick or 0
  local idle=c and c.idle or 0
  local waited=c and c.craft_wait or 0
  if peek and c then c.seen_tick=game.tick
  else clocks[p.index]={call_tick=game.tick,idle=0,craft_wait=0} end
  local function t(ticks)
    local sec=math.floor(ticks/60)
    if sec>=3600 then return string.format('%dh%02dm',math.floor(sec/3600),math.floor(sec/60)%60) end
    if sec>=60 then return string.format('%dm%02ds',math.floor(sec/60),sec%60) end
    return sec..'s'
  end
  local craft=p.character and crafting_left(p) or 0
  local function share(n) return since>0 and math.floor(100*n/since+0.5) or 0 end
  local waiting=waited>0 and string.format(', waiting on hand crafting %s of it (%d%%)',t(waited),share(waited)) or ''
  return string.format('game %s; +%s since your last request, character idle %s of it (%d%%)%s; hand crafting %s queued',
    t(game.tick),t(since),t(idle),share(idle),waiting,t(craft*60))
end
local function idle_tick()
  for index,c in pairs(state().clocks or {}) do
    local q=state().queues and state().queues[index]
    local planned=q and not q.paused and (q.current or #q.pending>0 or q.loop)
    local now=state().active[index]
    if not now and not planned then c.idle=c.idle+1
    elseif now and now.awaiting_craft then c.craft_wait=(c.craft_wait or 0)+1 end
  end
end
local dispatch_request
function M.dispatch(request)
  -- Operator tools (RCON, never fh) read and answer the board as `operator`
  -- without a player. A failure must stop nobody (the bootstrap stops player 1).
  if request.operator==true then
    local ok,result=pcall(function()
      assert(request.player==nil and request.bot==nil,'an operator request names no player or bot')
      local relay=M.audience.operator[request.action]
      if relay then return relay(request.args or {}) end
      M.check_args(request.action,request.args)
      return M.board.operator(request.action,request.args)
    end)
    if not ok then passive_failed=true; error(result,0) end
    return result
  end
  -- A bot is addressed by name and handled under its index from here on
  -- (the bootstrap's failure cleanup reads request.player too).
  if request.bot~=nil then
    assert(request.player==nil,'a request may name a player or a bot, not both')
    request.player=M.bots.index_of(request.bot)
  end
  local result=dispatch_request(request)
  if clock then clock.after_dispatch() end
  if request.action=='status' then M.bots.status(request.player,result) end
  if type(result)=='table' and request.action~='describe' and request.action~='profiles' and request.action~='cameras' then
    local p=M.lookup(request.player or 1)
    local peek=type(request.args)=='table' and request.args.peek==true
    if p and p.valid then result.clock=clock_line(p,peek) end
    -- What is new for this agent (mentions, board, attacks/losses, reminders);
    -- directors and peeking readers (overlays) leave the agent's cursors alone.
    if p and p.valid and not peek and request.action~='board_events' and not M.is_director(p.index) then
      result.team=M.board.team(p,unseen_losses(p))
      -- A chat read that left messages unread is repeated until they are read.
      local left=request.action~='chat' and M.chat and M.chat.left(p.index)
      if left then result.team=result.team or {}; result.team.chat_remaining=left end
    end
    if clock and request.action=='status' then result.time_mode=clock.report() end
    -- The unread trailer repeats only when a newer message arrived (status always shows it).
    if M.chat and p and p.valid and request.action~='chat' then result.chat=M.chat.unread(p.index,peek and 'peek' or request.action=='status' and 'always' or nil) end
  end
  return result
end
dispatch_request=function(request)
  local handler=handlers[request.action]; assert(handler,'unsupported action; call describe')
  check_args(request.action,request.args)
  if request.action=='describe' or request.action=='profiles' or request.action=='cameras' then return handler() end
  if M.bots.is_index(request.player) and (request.action=='attach' or request.action=='detach') then
    return {bot=M.bots.record(request.player).name,attached=request.action=='attach',note='bots need no attach'}
  end
  if request.action=='attach' then
    local p=game.get_player(request.player or 1)
    assert(p and p.valid and p.connected,'join a graphical Factorio client: disconnected players have no controllable character')
    assert(p.character and p.character.valid and p.physical_controller_type==defines.controllers.character,'a living survival character is required')
    local a=request.args or {}
    assert(not p.cheat_mode or a.allow_cheat_mode==true,'cheat mode requires explicit testing opt-in')
    return handler(p,a)
  end
  -- Board actions never stop the character on failure. Board reads work for
  -- any player (directors, overlays); posts work while a bot is dead.
  local board=M.board.handlers[request.action]
  if board then
    local p
    if M.board.needs_character[request.action] then p=player(request.player)
    else
      p=M.lookup(request.player or 1); assert(p and p.valid,'player does not exist')
      if not M.board.open_reads[request.action] then assert(not M.is_director(p.index),'directors do not post on the board') end
    end
    local ok,result=pcall(board,p,request.args or {})
    if not ok then passive_failed=true; error(result,0) end
    return result
  end
  -- A peek at the chat is a read any player can make (directors and
  -- overlays have no character).
  local peek=request.action=='chat' and type(request.args)=='table' and request.args.peek==true
  -- sleep_check (an observe scope) also answers for a dead character.
  local sleeping=request.action=='observe' and type(request.args)=='table' and request.args.scope=='sleep_check'
  if peek or sleeping or request.action=='status' or request.action=='queue_status' or request.action=='queue_cancel' then
    local p=M.lookup(request.player or 1); assert(p and p.valid,'player does not exist')
    return handler(body(p),request.args or {})
  end
  -- A dead bot still talks: it reads and answers the team while it waits to respawn.
  local p
  if (request.action=='chat' or request.action=='say') and M.bots.is_index(request.player) then
    p=M.lookup(request.player); assert(p and p.valid,'player does not exist')
  else p=player(request.player) end
  if not reads[request.action] and not passive[request.action] and not request.action:match('^queue_') then
    local q=state().queues and state().queues[p.index]
    if q and not q.paused then M.stop_player(p.index) end
  end
  if passive[request.action] then
    local ok,result=pcall(handler,p,request.args or {})
    if not ok then passive_failed=true; error(result,0) end
    return result
  end
  return handler(p,request.args or {})
end
-- Choose the 8-way direction closest to the heading, but keep the previous
-- one while it stays within 30 degrees. Re-choosing every tick flips between
-- neighbours and makes the client camera jitter.
local compass={'north','northeast','east','southeast','south','southwest','west','northwest'}
local function steer(p,target,memo)
  local dx,dy=target.x-p.position.x,target.y-p.position.y
  local angle=(math.atan2 or math.atan)(dx,-dy)
  local function error_for(i) local d=math.abs(angle-(i-1)*math.pi/4)%(2*math.pi); return math.min(d,2*math.pi-d) end
  local best=math.floor(angle/(math.pi/4)+0.5)%8+1
  local choice=best
  if memo and memo.steer and error_for(memo.steer)<math.pi/6 then choice=memo.steer end
  if memo then memo.steer=choice end
  p.walking_state={walking=true,direction=directions[compass[choice]]}
end
-- The next point to steer at: the first engine path waypoint not yet reached,
-- else the goal itself. At high running speed one tick can cover most of a tile.
local function waypoint_goal(p,action,goal)
  if not action.waypoints then return goal end
  local reach=math.max(0.5,(p.character_running_speed or 0.15)*1.5)
  while action.waypoint<=#action.waypoints and distance(p.position,action.waypoints[action.waypoint].position)<=reach do action.waypoint=action.waypoint+1 end
  return action.waypoint<=#action.waypoints and action.waypoints[action.waypoint].position or goal
end
kite=kite_module{position=position,distance=distance,integer=integer,visible=visible,directions=directions}
threat=threat_module{state=state,known=known,distance=distance,on_character_hit=function(event) M.board.on_character_hit(event) end}
survey=survey_module{state=state,status_name=function(e) return entity_status_names[e.status] end}
-- labs: research line diagnostics (labs.lua), an observe scope.
M.labs=require('labs'){integer=integer,center=center,status_name=function(e) return entity_status_names[e.status] end}
function handlers.labs(p,a) return M.labs.view(p,a) end
rates=rates_module{position=position,status_name=function(e) return entity_status_names[e.status] end}
space=space_module{position=position,integer=integer,remote_entity=remote_entity,real=real,
  -- Riding or landing takes the character away: controls stop and a plan pauses.
  stop=function(p) M.stop_player(p.index) end}
stock=stock_module{distance=distance,integer=integer,position=position,claims=M.claims,
  -- One stop of a rearm/refuel tour: top the entity up; stop when none is left.
  visit=function(p,action,e)
    if action.op=='feed' then
      -- A feed stop gives every want; the tour ends early once nothing the
      -- remaining machines want is left above the reserve.
      local gave,n=feeding.one(p,e,action.feed)
      for item,c in pairs(gave) do action.items=action.items or {}; action.items[item]=(action.items[item] or 0)+c end
      local more=false
      for i=action.index+1,#action.targets do
        local t=action.targets[i]
        if t.entity and t.entity.valid and feeding.hungry(p,t.entity,action.feed) then more=true; break end
      end
      return {transferred=n,stop=(not more and action.targets[action.index+1]) and 'out_of_items' or nil}
    end
    local args={direction='to_entity',item=action.item,quality=action.quality,count=action.count,up_to=action.count,
      inventory=action.op=='refuel' and 'fuel' or nil}
    local out=transfer_one(p,args,nil,e)
    local left=held(p,action.item,action.quality)
    return {transferred=out.transferred,stop=left==0 and action.targets[action.index+1] and crafting_count(p,action.item)==0 and 'out_of_items' or nil}
  end,
  take=function(p,e,item,quality,count) return transfer_one(p,{direction='to_player',item=item,quality=quality,count=count},nil,e) end,
  request_path=function(p,nav) return request_path(p,nav) end,navigate=function(p,nav) return navigate(p,nav) end,
  stop_walking=function(p) p.walking_state={walking=false,direction=defines.direction.north} end}
-- Shared walking controller (move_to, construct). Follows the engine path when
-- one exists, else steers directly. A stall of a few ticks first sidesteps
-- perpendicular to the heading, then re-paths with a wider goal radius, and
-- only gives up after repeated failures. Diagnostics stay on `nav`.
local STALL_TICKS,SIDESTEP_TICKS,MAX_STALLS,MAX_REPLANS,PROGRESS_TICKS=8,12,15,5,90
navigate=function(p,nav)
  local pos,goal=p.position,nav.position
  if distance(pos,goal)<=math.max(nav.tolerance,(p.character_running_speed or 0)*0.55) then return 'arrived' end
  local last=nav.last_position or pos
  local moved=distance(pos,last)
  local oscillating=nav.previous_position and distance(pos,nav.previous_position)<0.005 and moved>0.005
  nav.previous_position=last; nav.last_position={x=pos.x,y=pos.y}
  -- A goal inside an entity is unreachable; stopping just beside it is what
  -- callers targeting a machine or chest want.
  local near=distance(pos,goal)<=nav.tolerance+1.5
  if nav.path_state=='pending' then p.walking_state={walking=false,direction=defines.direction.north}; nav.stalled=0; nav.progress_tick=nil; return end
  if nav.path_state=='busy' then
    nav.retry_tick=nav.retry_tick or game.tick+20
    if game.tick>=nav.retry_tick then nav.retry_tick=nil; request_path(p,nav); return end
  end
  -- Flipping between two spots is a stall in disguise.
  if oscillating and near then return 'arrived_near' end
  nav.stalled=(moved<0.01 or oscillating) and (nav.stalled or 0)+1 or 0
  -- Motion is not progress: a belt carrying the character back, units shoving
  -- it, or any other jitter moves it every tick without getting closer. Count
  -- a stall when neither the waypoint nor the distance to it has improved by
  -- half a tile for PROGRESS_TICKS.
  local mark=nav.waypoint or 0
  local gap=distance(pos,waypoint_goal(p,nav,goal))
  if not nav.progress_tick or mark~=nav.progress_mark or gap<nav.progress_gap-0.5 then
    nav.progress_tick,nav.progress_mark,nav.progress_gap=game.tick,mark,gap
  elseif game.tick-nav.progress_tick>=PROGRESS_TICKS then
    nav.progress_tick=game.tick; nav.progress_gap=gap
    nav.no_progress=(nav.no_progress or 0)+1
    nav.sidestep=nil; nav.stalled=STALL_TICKS
  end
  if nav.sidestep then
    if game.tick<nav.sidestep.until_tick and nav.stalled<STALL_TICKS then
      p.walking_state={walking=true,direction=directions[compass[nav.sidestep.choice]]}; return
    end
    nav.sidestep=nil
  end
  if nav.stalled>=STALL_TICKS then
    if near then return 'arrived_near' end
    nav.stalls=(nav.stalls or 0)+1; nav.stalled=0
    if nav.stalls>(nav.max_stalls or MAX_STALLS) then return 'blocked' end
    if nav.stalls%(nav.replan_every or 3)==0 and (nav.replans or 0)<MAX_REPLANS and not nav.direct then
      nav.replans=(nav.replans or 0)+1; nav.path_level=0; request_path(p,nav); return
    end
    -- Slide around the obstacle: 90 degrees off the heading, alternating sides.
    local heading=nav.steer or 1
    local turn=nav.stalls%2==1 and 2 or -2
    nav.sidestep={choice=(heading-1+turn)%8+1,until_tick=game.tick+SIDESTEP_TICKS}
    p.walking_state={walking=true,direction=directions[compass[nav.sidestep.choice]]}
    return
  end
  steer(p,waypoint_goal(p,nav,goal),nav)
end
route=route_module{position=position,directions=directions,chunk_of=chunk_of}
pipes=pipes_module{position=position,directions=directions,chunk_of=chunk_of}
construction=construction_module{position=position,distance=distance,integer=integer,visible=visible,steer=steer,real=real,
  known=known,reason=reason,directions=directions,waypoint_goal=waypoint_goal,
  request_path=function(p,nav) return request_path(p,nav) end,navigate=function(p,nav) return navigate(p,nav) end,
  build=function(p,a) return handlers.build(p,a) end,hand_mining_ticks=hand_mining_ticks,crafting_count=crafting_count}
local function blocked_product(p,action)
  for _,name in ipairs(action.products or {}) do
    if not p.can_insert{name=name} then return name end
  end
end
-- Operator measurement (profile_ticks): the harness tick's own cost, timed
-- with LuaProfiler and written to the log. Module state on purpose: it never
-- touches game state, and profiler readings differ between machines anyway.
local profiling
function M.tick(event)
  if not profiling then return M.tick_body(event) end
  local timer=helpers.create_profiler()
  M.tick_body(event)
  timer.stop(); profiling.total.add(timer); profiling.left=profiling.left-1
  if profiling.left==0 then
    profiling.total.divide(profiling.n)
    log({'','agent-harness tick average over ',profiling.n,' ticks (',#M.bots.list(),' bots, ',table_size(state().active),' active actions): ',profiling.total})
    profiling=nil
  end
end
function M.tick_body(event)
  idle_tick()
  M.bots.tick(event.tick)
  M.nametags.tick(event.tick)
  for index,action in pairs(state().active) do
    local ok,p=pcall(player,index)
    if not ok then
      finish(index,'player_unavailable')
    elseif event.tick>action.until_tick then
      finish(index,(action.kind=='move_to' or action.kind=='build_path' or action.kind=='construct' or action.kind=='kite' or action.kind=='feed' or action.kind=='gather' or action.kind=='wait_until') and 'timed_out' or 'duration_elapsed')
    elseif action.kind=='wait_until' then
      if event.tick>=action.next_check then
        action.next_check=event.tick+FEED_CHECK
        local ok,met,saw=pcall(conditions.check,p,action.condition)
        action.saw=ok and saw or nil
        if not ok then action.error=reason(met); finish(index,'failed')
        elseif met then finish(index,'met') end
      end
    elseif action.kind=='walk' then
      p.walking_state={walking=true,direction=action.direction}
    elseif action.kind=='move_to' then
      local outcome=navigate(p,action)
      if outcome then finish(index,outcome) end
    elseif action.kind=='build_path' then
      local outcome=construction.tick(p,action)
      if outcome then finish(index,outcome) end
    elseif action.kind=='kite' then
      local outcome=kite.tick(p,action,event.tick)
      if outcome then finish(index,outcome) end
    elseif action.kind=='construct' then
      local outcome=construction.tick_ghosts(p,action)
      if outcome then finish(index,outcome) end
    elseif action.kind=='gather' then
      local outcome=stock.tick(p,action)
      if outcome then finish(index,outcome) end
    elseif action.kind=='feed' then
      -- A build stepping aside walks until the character is off the footprint.
      if action.aside and construction.in_box(p.position,action.aside.box) then steer(p,action.aside.to,action)
      elseif event.tick>=action.next_check then
        if action.aside then stop(p); action.aside=nil end
        action.next_check=event.tick+FEED_CHECK
        if not action.item or held(p,action.item,action.args.quality)>=action.need or crafting_count(p,action.item)==0 then
          action.awaiting_craft=nil
          action.running=true
          local ok,result=pcall(handlers[action.handler],p,action.args)
          action.running=nil
          if ok then action.result=result else action.error=reason(result) end
          -- A later batch entry stepping aside installed a new action: keep it.
          if state().active[index]==action then finish(index,ok and 'fed' or 'failed') end
        end
      end
    elseif action.kind=='pickup' then
      p.picking_state=true
    elseif action.kind=='repair' then
      local e=action.entity
      if not e or not e.valid then finish(index,'target_lost')
      elseif not p.can_reach_entity(e) then finish(index,'out_of_reach')
      elseif e.health>=e.max_health then finish(index,'repair_completed')
      elseif not p.cursor_stack.valid_for_read or p.cursor_stack.prototype.type~='repair-tool' then finish(index,'repair_tool_exhausted')
      else
        -- Reassigning selection/state every tick fights the client's cursor
        -- hover and makes the selection box flash; only correct drift.
        if M.bots.is(p) then M.bots.repair(p,e)
        else
          if p.selected~=e then p.selected=e end
          if not p.repair_state.repairing then p.repair_state={repairing=true,position=e.position} end
        end
      end
    elseif action.kind=='mine' then
      local e=action.entity
      -- Timed mining only finishes through mine_entity; a vanished target was
      -- taken by something else (a bot, a biter, another player).
      if not e or not e.valid then finish(index,action.done_tick and 'target_lost' or 'target_mined')
      elseif not p.can_reach_entity(e) then finish(index,'out_of_reach')
      elseif action.done_tick then
        if event.tick>=action.done_tick then
          if M.bots.mine(p,e) then finish(index,'target_mined')
          else
            -- The engine refuses for two reasons: no room for the products,
            -- or an entity that cannot be mined by hand (a stump or remnant).
            action.blocked_item=blocked_product(p,action)
            if action.blocked_item or e.valid and e.type=='character-corpse' then finish(index,'inventory_full')
            else action.error='the engine refused to mine '..e.name..' (not hand-minable: a stump, remnant or corpse; it does not block building, or deconstruct it)'; finish(index,'not_minable') end
          end
        end
      elseif blocked_product(p,action) then
        -- The engine silently idles a character whose output has no room.
        action.blocked_item=blocked_product(p,action); finish(index,'inventory_full')
      elseif action.next_mine and event.tick>=action.next_mine then
        -- mine_entity on a resource takes one unit and returns false while
        -- the tile has ore left, so judge success by the amount.
        local before=e.amount
        p.mine_entity(e,false)
        if not e.valid then action.mined=action.mined+1; finish(index,'target_mined')
        elseif e.amount<before then action.mined=action.mined+1; action.next_mine=event.tick+action.cycle
        else action.blocked_item=blocked_product(p,action); finish(index,'inventory_full') end
      end
    end
    if ok and state().active[index]==action then watch(p,action) end
  end
  for index,action in pairs(state().combat or {}) do
    local ok,p=pcall(player,index)
    if not ok or event.tick>action.until_tick then stop_combat(index,ok and 'duration_elapsed' or 'player_unavailable')
    elseif action.ammo_start and kite.ammo_count(p)==0 then stop_combat(index,'out_of_ammo')
    else
      local target=action.position
      if action.auto then
        local cached=combat_targets()[index]
        if not cached or event.tick>=cached.next_scan then
          local enemies={}
          for _,force in pairs(game.forces) do
            if force~=p.force and force.name~='neutral' and not p.force.get_friend(force) and not p.force.get_cease_fire(force) then enemies[#enemies+1]=force end
          end
          local best=action.radius+1
          cached={next_scan=event.tick+6}
          if #enemies>0 then
            for _,e in pairs(p.surface.find_entities_filtered{position=p.position,radius=action.radius,force=enemies,limit=256,type={'unit','unit-spawner','turret','ammo-turret','electric-turret','character'}}) do
              local d=distance(p.position,e.position)
              if e.valid and visible(p,e.position) and d<best then best=d; cached.entity=e end
            end
          end
          combat_targets()[index]=cached
        end
        local e=cached.entity
        if e and e.valid and distance(p.position,e.position)<=action.radius and visible(p,e.position) then target=e.position end
      end
      p.shooting_state={state=target and defines.shooting.shooting_enemies or defines.shooting.not_shooting,position=target or p.position}
    end
  end
  if event.tick%60==0 then feed_research_plans() end
  if event.tick%3600==0 then
    for _,connected in pairs(game.connected_players) do
      local ok,p=pcall(player,connected.index)
      if ok then survey.sample(p) end
    end
  end
  if event.tick%3600==0 then
    for _,b in ipairs(M.bots.list()) do
      local ok,p=pcall(player,b.index)
      if ok then survey.sample(p) end
    end
  end
  scheduler.tick()
  clock.tick()
  M.cameras.tick()
end
-- Operator-only remote functions (control.lua): never reachable through
-- dispatch, so agents cannot spawn bots or move cameras.
M.operator={
  bot_create=function(name) return {ok=true,tick=game.tick,bot=M.bots.create(name)} end,
  bot_remove=function(name) local out=M.bots.remove(name); return {ok=true,tick=game.tick,bot=out} end,
  bots=function() local out={}; for _,b in ipairs(M.bots.list()) do out[#out+1]={name=b.name,index=b.index,alive=M.bots.alive(b),position=b.position,dead_until_tick=b.dead_until_tick} end; return {ok=true,tick=game.tick,bots=out} end,
  camera=function(args) return M.cameras.set(args) end,
  profile_ticks=function(n)
    n=integer(n,600,1,36000,'ticks')
    local total=helpers.create_profiler(true)
    profiling={n=n,left=n,total=total}
    return {ok=true,tick=game.tick,until_tick=game.tick+n,note='the average lands in the server log (factorio-current.log)'}
  end,
  cameras=function() return M.cameras.list() end}
local MAX_ALERTS=64
function M.on_event(event)
  if event.name==defines.events.on_script_path_request_finished then
    local paths=state().paths or {}
    local index=paths[event.id]; paths[event.id]=nil
    local action=index and state().active[index]
    local nav=action and (action.nav or action)
    if not nav or nav.path_id~=event.id then return end
    nav.paths_failed=(nav.paths_failed or 0)+(event.path and 0 or 1)
    if event.path then nav.waypoints=event.path; nav.waypoint=1; nav.path_state='found'
    elseif event.try_again_later then nav.path_state='busy'
    elseif (nav.path_level or 0)<2 then
      -- Escalate (true box, then wider goal) before steering blind.
      nav.path_level=(nav.path_level or 0)+1
      local ok,p=pcall(player,index)
      if ok then request_path(p,nav) else nav.path_state='failed' end
    else nav.path_state='failed' end
  elseif event.name==defines.events.on_console_chat then
    if M.chat then M.chat.on_console_chat(event) end
  elseif event.name==defines.events.on_unit_group_finished_gathering then
    threat.on_group(event)
  elseif event.name==defines.events.on_entity_damaged then
    threat.on_damaged(event)
  elseif event.name==defines.events.on_entity_died then
    local cause=event.cause
    if cause and cause.valid and cause.type=='character' then
      for index,action in pairs(state().active) do
        local p=action.kind=='kite' and M.lookup(index)
        if p and p.character==cause then action.kills=action.kills+1 end
      end
    end
    local e=event.entity
    local s=state()
    if e and e.valid and e.force and e.force.name=='enemy' and (e.type=='unit-spawner' or e.type=='turret') and event.force and event.force.name~='enemy' then
      s.kills=s.kills or {}
      table.insert(s.kills,{tick=event.tick,name=e.name,position=e.position})
      while #s.kills>MAX_ALERTS do table.remove(s.kills,1) end
      return
    end
    if not (e and e.valid and e.force and e.force.name~='enemy' and e.force.name~='neutral') then return end
    s.alerts=nil -- superseded by incidents
    record_loss(event.tick,e,event.cause and event.cause.valid and event.cause.name or nil)
  end
end
return M
