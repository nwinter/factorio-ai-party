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
local directions = {north=0, northeast=2, east=4, southeast=6, south=8, southwest=10, west=12, northwest=14,
  -- 2.0's in-between directions, which rails use
  northnortheast=1, eastnortheast=3, eastsoutheast=5, southsoutheast=7, southsouthwest=9, westsouthwest=11, westnorthwest=13, northnorthwest=15}
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
M.claims=require('claims'){state=state,where_from=function(me) return M.where.from(me) end,owner_state=function(name) return M.board.owner_state(name) end}
M.belt=require('belt')()
-- Waits, queues and actions carried over a hot install (carry.lua: notes them while this loads).
M.carry=require('carry'){state=state,restart=function(index,call) return M.restart_call(index,call) end}
M.bots=require('bots'){state=state,stop=function(index,outcome) M.stop_player(index,outcome) end,crafting=M.crafting,
  -- What stands where a tile does not go (dryrun.lua tile_blockers): a hand-laid tile's refusal names it.
  tile_blockers=function(surface,force,tile,x,y) return M.dryrun and M.dryrun.tile_blockers(surface,force,tile,x,y) end,
  profile=function(index) return M.profiles.get(index) end,on_spawn=function(b) M.profiles.apply(M.bots.proxy(b)); M.nametags.refresh(b) end}
M.cameras=require('cameras'){state=state,bot=function(name) return M.bots.named(name) end,
  controlled=function(index) return state().controlled and state().controlled[index]~=nil end}
M.profiles=require('profiles'){state=state,is_bot=function(p) return M.bots.is(p) end,director=function(index) return M.cameras.director(index) end,
  bots=function() return M.bots.list() end,active=function(index) local a=M.active(index); return a and a.kind or false end,
  on_apply=function(p) if M.bots.is(p) then M.nametags.refresh(M.bots.record(p.index)) end end,bubble_y=function(index) return M.nametags.bubble_y(index) end}
M.nametags=require('nametags'){state=state,bots=function() return M.bots.list() end,profile=function(index) return M.profiles.get(index) end,
  carrier=function(b) return M.bots.carrier(b) end,
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
  reach_distance=true,resource_reach_distance=true,crafting_queue=true,begin_crafting=true,cancel_crafting=true,get_craftable_count=true,
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
  -- A bot's platform proxy has no __player: never hand the engine the proxy
  -- table ("Invalid PlayerIdentification" for every bot's ghosts in shake7).
  if rawget(p,'__platform') or rawget(p,'__remote') then return rawget(p,'__player') end
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
-- seated: a character in a vehicle is allowed (reads, chat, crafting, research,
-- remote-view actions and vehicle itself, set per request in M.seated_ok; a drive in progress).
local function player(index,seated)
  seated=seated or M.seated_ok
  if M.bots.is_index(index) then return M.bots.actor(index,seated) end
  local p = game.get_player(index or 1)
  assert(p and p.valid, 'player does not exist')
  local controlled=state().controlled and state().controlled[p.index]
  assert(p.connected, 'join a graphical Factorio client: disconnected players have no controllable character')
  assert(p.physical_controller_type == defines.controllers.character and p.character and p.character.valid, 'a living survival character is required')
  assert(not p.cheat_mode or (controlled and controlled.allow_cheat_mode), 'cheat mode requires explicit testing opt-in')
  assert(not p.driving or (seated and p.vehicle), 'the character is in a vehicle or riding a rocket/cargo pod: vehicle {exit: true} gets out of a vehicle (reads, chat, crafting, research and remote actions work seated); a ride ends by itself (poll status)')
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
  -- A walk around enemies ends at its goal, not its current leg's corner (avoid.lua).
  if action and action.foes and action.foes.goal then action.position=action.foes.goal; action.tolerance=action.foes.tolerance or action.tolerance end
  -- The goal lets a caller tell its own completion from one that replaced it.
  if action then s.last[index]={kind=action.kind, outcome=outcome, tick=game.tick, target=action.kind=='move_to' and action.position or nil} end
  -- A direct timed action that ended other than done counts for the review (selfview.lua; queue steps: scheduler fail).
  if action and not action.queued and M.selfview then pcall(M.selfview.ended,index,action.kind,outcome,action.error) end
  if action and action.blocked_item then s.last[index].blocked_item=action.blocked_item end
  if action and action.kind=='mine' and action.mined then s.last[index].mined=action.mined end
  if action and action.kind=='mine' and action.instead then s.last[index].instead=action.instead.line end
  if action and action.kind=='pickup' then
    s.last[index].picked=action.picked
    -- Hand hauling (hauling.lua): what the pickup took, at the character, as its own call.
    if action.picked and M.hauling then
      local stacks={}
      for name,n in pairs(action.picked) do stacks[#stacks+1]={name=name,count=n} end
      table.sort(stacks,function(x,y) return x.name<y.name end)
      local pl=M.lookup(index)
      if pl and pl.valid then pcall(M.hauling.moved,index,'to_player',pl.position,pl.surface.name,stacks,nil,action) end
    end
    -- An area pickup: what is still on the ground there, and stacks it walked away from.
    if action.area then
      local ok,left=pcall(M.ground.left,body(M.lookup(index)),action)
      s.last[index].left=ok and left or nil; s.last[index].skipped=action.skipped>0 and action.skipped or nil
    end
  end
  if action and action.kind=='mine' and action.error then s.last[index].error=action.error end
  -- Items picked up or collected over a radius that put the character over
  -- its request max: what the game moved to the trash slots, counted at
  -- each take (trash.lua).
  local tally=action and (action.trashed or (action.trash_tally and action.trash_tally.t))
  if tally then s.last[index].trash=M.trash.done(tally) end
  if action and action.kind=='build_path' then
    local last=s.last[index]
    last.placed=action.placed; last.skipped=action.skipped; last.next_index=action.next_index; last.total=#action.cells
    last.next_position=action.cells[action.next_index] and action.cells[action.next_index].position
    last.error=action.error
  end
  if action and action.kind=='move_to' then
    local last=s.last[index]
    -- A walk through via points: its final target, and each leg (the one that ended it already recorded by via_next).
    if action.via then
      if outcome~=nil and #action.via.legs<action.via.index then M.via_record(action,outcome) end
      last.target=action.via.final; last.legs=M.via_report(action)
    end
    -- Movement diagnostics, only when something went wrong on the way.
    last.replans=(action.replans or 0)>0 and action.replans or nil
    last.stalls=action.stalls; last.no_progress=action.no_progress; last.paths_failed=(action.paths_failed or 0)>0 and action.paths_failed or nil
    -- Why it gave up, the nearest point it can reach, and how it ended off a belt (pathing.lua).
    local pb=body(M.lookup(index))
    local here=pb and pb.valid and pb.character and pb.character.valid and pb.position
    local at=M.pathing.at
    if outcome=='unreachable' then
      last.why=action.why
      if action.reachable then
        last.nearest_reachable={x=math.floor(action.reachable.x*10+0.5)/10,y=math.floor(action.reachable.y*10+0.5)/10}
        last.reachable_gap=math.floor(distance(action.reachable,action.position)*10+0.5)/10
      end
      -- A spot it can reach within build reach of the goal, or none (pathing.lua).
      local sp=action.spot
      if sp and sp.none then
        last.build_spot_note=string.format('no spot the character can reach is within build reach (%g tiles) of %s',sp.reach,at(sp.goal))
      elseif sp then
        last.build_spot={x=math.floor(sp.pos.x*10+0.5)/10,y=math.floor(sp.pos.y*10+0.5)/10}
        local head=string.format('%s is reachable and within build reach of %s: %.1f tiles (build reach %g)',at(sp.pos),at(sp.goal),distance(sp.pos,sp.goal),sp.reach)
        local call=string.format('move_to {position=%s%s, squeeze=true}',at(sp.pos),sp.via and ', via=['..at(sp.via)..']' or '')
        local gap=string.format('a gap narrower than %.1f tiles%s',sp.width or 0.7,#(sp.by or {})>0 and ' ('..table.concat(sp.by,', ')..')' or '')
        if sp.room and not sp.searched then last.build_spot_note=head
        elseif sp.room then
          -- Found by the character's own steps after every path request failed (a target in water fails them all).
          last.build_spot_note=string.format('%s; the character\'s own steps found it, no path request did: %s walks there',head,call)
          last.build_spot_squeeze=true
        else
          last.build_spot_note=string.format('%s; it lies in %s, and no reachable spot with room to turn was found within build reach: %s walks into it',head,gap,call)
          last.build_spot_squeeze=true
        end
      end
    elseif outcome=='blocked' and (action.escape_stalled or action.trail_still) then
      last.why=action.why
    elseif outcome=='blocked' then
      last.why=string.format('stalled %d times%s; stopped at %s, %.1f tiles from the target',action.stalls or 0,
        action.no_progress and string.format(' (%d of them no progress for 90 ticks)',action.no_progress) or '',here and at(here) or '?',here and distance(here,action.position) or 0)
    elseif outcome=='timed_out' and here then
      last.why=string.format('time ran out at %s, %.1f tiles from the target',at(here),distance(here,action.position))
    end
    if action.blind then last.steered='without a path: '..action.blind end
    if action.avoided then last.path='off belts' end
    -- A gap the path did not lead into, a squeeze walked out of, a closed area mined out of (pathing.lua).
    local pk=action.pocket
    if pk then
      last.pocket=string.format('%s lies in a gap narrower than %.1f tiles (%s) that no path led into; stopped at %s, %.1f tiles from it (squeeze=true walks in)',
        at(action.position),(M.pathing.half(pb and pb.valid and pb.character or {})+M.pathing.PAD)*2,table.concat(pk.by,', '),at(pk.stop),distance(pk.stop,action.position))
    end
    if action.squeezed then
      last.squeezed=string.format('no path request led into the gaps: walked them from %s to %s',at(action.squeezed.from),at(action.squeezed.to))
    end
    if action.escapes and action.escape_first then
      last.escaped=string.format('no path led out of the gap at %s: walked out to %s first%s',at(action.escape_first),
        at(action.escaped_to or action.escape_first),action.escapes>1 and string.format(' (%d moves, each to more room)',action.escapes) or '')
    end
    if action.dig then
      local names={}
      for i,e in ipairs(action.dig.mine) do names[i]=e.name..' '..at(e.position) end
      last.mine_to_get_out=names
    end
    M.avoid.report(last,action)
    local ob=action.off_belt
    if ob then
      last.off_belt=ob.spot and string.format('arrived on a %s; stepped to %s, the nearest free tile without a belt %s',ob.belt,at(ob.spot),
        ob.within and 'within the arrival radius' or '(none within the arrival radius)') or ('arrived on a '..ob.belt..'; no free tile without a belt within 3 tiles')
    end
    -- move_to combat fires for the walk only: the combat channel ends next tick.
    local combat=s.combat and s.combat[index]
    if combat and combat.with_move then combat.until_tick=game.tick-1; combat.end_outcome='move_ended' end
  end
  if action and action.kind=='kite' then
    local last,p=s.last[index],body(M.lookup(index))
    last.kills=action.kills
    -- Why combat stopped, stated plainly (request #57), with what was left.
    last.why=action.why or (outcome=='timed_out' and 'time up' or outcome=='replaced' and 'replaced by another action' or nil)
    last.enemies_left=action.seen; last.retreated_from=action.retreating; last.reloads=action.reloads
    if p and p.valid and p.character and p.character.valid then
      last.ammo_used=kite.ammo_used(p,action); last.ammo_left=kite.ammo_count(p)
      p.shooting_state={state=defines.shooting.not_shooting,position=p.position}
    end
  end
  if action and action.kind=='drive' then
    local p=body(M.lookup(index))
    local last=s.last[index]
    if p and p.valid then M.vehicles.stop(p); local v=p.character and p.character.valid and p.character.vehicle; last.position=v and v.position or nil end
    last.target=action.target
    -- The path it followed, a back-up, why it stopped, enemies gone around (vehicles.lua, avoid.lua).
    local nav=action.nav
    if nav then
      last.path_length=nav.path_length
      if action.backed then last.backed_up=string.format('stuck at (%.1f,%.1f) (%s: %s): backed off and asked for a new path',action.backed.at.x,action.backed.at.y,action.backed.side or 'in front',action.backed.front) end
      M.avoid.report(last,nav)
    end
    last.why=last.why or action.why
    -- Units it pushed through or hit (vehicles.lua: units are no block).
    last.rammed=action.rammed_n
    last.reverse=action.reverse
    if outcome=='timed_out' and last.position then last.why=string.format('time ran out at (%.1f,%.1f), %.1f tiles from the target',last.position.x,last.position.y,distance(last.position,action.target)) end
  end
  if action and action.kind=='feed' then
    local last=s.last[index]
    last.result=action.result; last.error=action.error; last.handler=action.handler
  end
  if action and action.kind=='wait_until' then
    local last=s.last[index]
    last.condition=action.condition['until']; last.saw=action.saw; last.error=action.error
  end
  -- A direct wait ended by a tell or mention says from whom (the reply's team block has it in full).
  if action and action.told then s.last[index].why=action.told end
  if action and action.kind=='construct' then
    local last=s.last[index]
    last.built=action.built; last.mined=action.mined; last.remaining=construction.remaining(action)
    last.missing=next(action.missing) and action.missing or nil
    last.failed=#action.failed>0 and action.failed or nil
    -- Trees and rocks that stood in a ghost's way, where, and whether they went (request #167).
    if action.blockers and #action.blockers>0 then
      last.blockers={}
      for i,b in ipairs(action.blockers) do
        last.blockers[i]={name=b.name,position=b.position,ghost=b.ghost,at=b.at,cleared=not (b.entity and b.entity.valid)}
      end
    end
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
    if action.all then last.items=next(action.items) and action.items or nil end
    -- collect over a radius: the same total line as a transfer over several targets.
    if not action.op and #action.targets>1 then
      local moved={}
      if action.all then
        for key,n in pairs(action.items) do moved[#moved+1]={name=key,count=n} end
        table.sort(moved,function(x,y) return x.count>y.count end)
      else moved[1]={name=action.item,count=action.got,quality=action.quality} end
      local left=math.max(0,#action.targets-action.index+1)
      last.tally=M.tally{moved=moved,targets=#action.targets,touched=action.touched,unreached=action.unreached,errors=action.errors,
        noun='places'}..(left>0 and string.format('; %d places not visited (%s)',left,outcome) or '')
    end
    if action.op then
      last.op=action.op; last.got=nil; last.given=action.got; last.errors=action.errors; last.items=action.items; last.entities=action.rows
      last.left=math.max(0,#action.targets-action.index+1)>0 and #action.targets-action.index+1 or nil
    end
  end
  -- repair over positions or an area: repaired against already full, and what was not reached.
  if action and action.kind=='repair' and action.targets then
    local last,left=s.last[index],#action.targets-action.index+1
    last.repaired=action.repaired; last.already_full=action.already_full
    last.lost=action.lost>0 and action.lost or nil; last.unreached=action.unreached>0 and action.unreached or nil
    last.left=left>0 and left or nil
    last.tally=string.format('repaired %d, %d already full%s%s%s',action.repaired,action.already_full,
      action.unreached>0 and string.format(', %d not reached',action.unreached) or '',action.lost>0 and string.format(', %d gone',action.lost) or '',
      left>0 and string.format(', %d left (%s)',left,outcome) or '')
  end
  -- Item moves that ran over time: moved and the inventory line after (Muse 06:27).
  if action and (action.kind=='pickup' or action.kind=='gather' or action.kind=='feed') then pcall(M.moved_last,index,action,s.last[index]) end
  -- A walk that ends on a belt: the game carries the character on (shift03).
  if action and action.kind~='drive' then s.last[index].on_belt=M.belt.note(body(M.lookup(index))) end
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
  local guns
  if p and p.valid and p.character and p.character.valid then
    p.shooting_state={state=defines.shooting.not_shooting,position=p.position}
    -- Whole magazines (or shells) gone from the ammo slots since the start; a vehicle's from its gun's slot.
    if combat and combat.vehicle then used,guns=M.vehicles.combat_end(p,combat)
    elseif combat and combat.ammo_start then used=math.max(0,combat.ammo_start-kite.ammo_count(p)) end
  end
  if state().combat then state().combat[index]=nil end
  state().last_combat=state().last_combat or {}
  state().last_combat[index]={outcome=outcome,tick=game.tick,ammo_used=used,reloads=combat and combat.reloads,equipped=combat and combat.equipped,
    vehicle=combat and combat.vehicle,gun=combat and combat.gun,guns=guns}
end
-- The tick a read or passive action raised: the bootstrap's failure handler
-- calls stop_player right after, which must leave the action and queue alone.
local passive_failed=false
function M.stop_player(index,outcome)
  if passive_failed==game.tick and not outcome then passive_failed=false; return end
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
    stuck_s=action.watch and game.tick-action.watch.since>=STUCK_TICKS and math.floor((game.tick-action.watch.since)/60) or nil,
    -- the stream director's look-ahead: where the work is (set once when the action starts, never per tick)
    bounds=action.bounds,to=action.kind=='move_to' and action.position or nil,
    leg=action.kind=='move_to' and action.via and string.format('%d of %d',action.via.index,#action.via.points+1) or nil}
end
M.active=active
-- {left,top,right,bottom} around a list of cells or ghosts, once when an action is planned (at most 512 cells).
-- A field of M, not a top-level local (tests/locals.lua: runtime.lua keeps 3 of Lua's 200 free).
function M.cell_bounds(list,pos)
  local b
  for _,c in ipairs(list or {}) do
    local q=pos(c)
    if q then
      if not b then b={left=q.x,top=q.y,right=q.x,bottom=q.y}
      else b.left=math.min(b.left,q.x); b.top=math.min(b.top,q.y); b.right=math.max(b.right,q.x); b.bottom=math.max(b.bottom,q.y) end
    end
  end
  return b
end
-- Our own space platforms are shown whole in remote view: every chunk of
-- their surface counts as charted and visible.
local function own_platform(p)
  local pl=p.surface.platform
  return pl~=nil and pl.force==p.force
end
local function visible(p,pos)
  -- Acting on a platform by name (platform=): remote view shows all of it.
  if type(p)=='table' and rawget(p,'__platform') and own_platform(p) then return true end
  -- Another surface by name (surface=): remote view shows its visible chunks.
  if type(p)=='table' and rawget(p,'__remote') then return own_platform(p) or p.force.is_chunk_visible(p.surface,{x=math.floor(pos.x/32),y=math.floor(pos.y/32)}) end
  return distance(p.position,pos) <= 32 and (own_platform(p) or p.force.is_chunk_visible(p.surface, {x=math.floor(pos.x/32), y=math.floor(pos.y/32)}))
end
local function chunk_of(pos) return {x=math.floor(pos.x/32),y=math.floor(pos.y/32)} end
-- Reach and visibility failures say where the character actually stood, so a
-- plan step that ran from an unexpected spot is obvious from its error.
local function from_character(p,pos)
  return string.format('(%g,%g) is %.1f tiles from the character at (%.1f,%.1f)',pos.x,pos.y,distance(p.position,pos),p.position.x,p.position.y)
end
-- The nearest chunk our force sees now (radar coverage or a character's
-- sight) to pos, within 8 chunks: "(96,-64)-(127,-33), 40 tiles away".
function M.nearest_coverage(p,pos)
  local ok,text=pcall(function()
    local cx,cy=math.floor(pos.x/32),math.floor(pos.y/32)
    local best,bd
    for r=1,8 do
      if bd and (r-1)*32>bd then break end
      for dx=-r,r do
        for dy=-r,r do
          if math.max(math.abs(dx),math.abs(dy))==r and p.force.is_chunk_visible(p.surface,{x=cx+dx,y=cy+dy}) then
            local x0,y0=(cx+dx)*32,(cy+dy)*32
            local nx,ny=math.max(x0,math.min(pos.x,x0+32)),math.max(y0,math.min(pos.y,y0+32))
            local d=((nx-pos.x)^2+(ny-pos.y)^2)^0.5
            if not bd or d<bd then best,bd={x0,y0},d end
          end
        end
      end
    end
    if not best then return 'no chunk within 256 tiles of it is in radar coverage or a character\'s sight' end
    local d=math.max(1,math.floor(bd+0.5))
    return string.format('the nearest radar coverage (or a character\'s sight) is chunk (%d,%d)-(%d,%d), %d %s away',best[1],best[2],best[1]+31,best[2]+31,d,d==1 and 'tile' or 'tiles')
  end)
  return ok and text or nil
end
local function assert_visible(p,pos,what)
  if visible(p,pos) then return end
  -- Out of sight in a chunk our force sees: no coverage to name.
  local near=not (own_platform(p) or p.force.is_chunk_visible(p.surface,chunk_of(pos))) and M.nearest_coverage(p,pos) or nil
  if type(p)=='table' and rawget(p,'__remote') then
    error(string.format('%s at (%g,%g) on %s is not in a visible chunk (remote view needs radar coverage there)%s',what,pos.x,pos.y,p.surface.name,near and '; '..near or ''),2)
  end
  error(string.format('%s is outside local visible area: %s (limit 32 tiles, in a visible chunk; move_to within 30 tiles first)%s',what,from_character(p,pos),near and '; '..near or ''),2)
end
-- Reads by remote view (2.0): on the character's own surface the map shows
-- every entity in a chunk our force sees now (Astra, operator 04:57: inspect
-- only worked within 32 tiles). Returns 'remote view' when pos is out of the
-- character's sight but in such a chunk; nil in sight; errors otherwise,
-- naming the nearest radar coverage. Another surface by name (surface=) is
-- always remote view, with assert_visible's refusal.
function M.read_sight(p,pos,what)
  if type(p)=='table' and rawget(p,'__remote') then assert_visible(p,pos,what); return 'remote view' end
  if visible(p,pos) then return nil end
  if own_platform(p) or p.force.is_chunk_visible(p.surface,chunk_of(pos)) then return 'remote view' end
  local near=M.nearest_coverage(p,pos)
  error(string.format('%s at (%g,%g) (%s) is in no chunk our force sees now (radar coverage or a character\'s sight)%s',what,pos.x,pos.y,
    from_character(p,pos),near and '; '..near or ''),0)
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
-- Rails under a locomotive or wagon: the cursor picks the train, so a rail
-- is the target only when nothing else is there or it is named.
M.UNDER={['straight-rail']=true,['half-diagonal-rail']=true,['curved-rail-a']=true,['curved-rail-b']=true,['legacy-straight-rail']=true,
  ['legacy-curved-rail']=true,['elevated-straight-rail']=true,['elevated-half-diagonal-rail']=true,['elevated-curved-rail-a']=true,
  ['elevated-curved-rail-b']=true,['rail-ramp']=true,['rail-support']=true}
-- Flying robots, units and other passing or unselectable entities over a building yield to it unless named or
-- given by unit_number (Sol, shift08: a robot over a chest made inspect, transfer and collect there ambiguous).
M.PASSING={['logistic-robot']=true,['construction-robot']=true,['combat-robot']=true,['capture-robot']=true,unit=true,
  ['spider-unit']=true,projectile=true,['artillery-projectile']=true,fire=true,stream=true,sticker=true,beam=true,
  explosion=true,['smoke-with-trigger']=true,['highlight-box']=true,['speech-bubble']=true,['particle-source']=true}
function M.passing(e)
  if M.PASSING[e.type] then return true end
  local ok,selectable=pcall(function() return e.prototype.selectable_in_game end)
  return ok and selectable==false
end
local function entity(p,args,read_only)
  local pos = position(args.position)
  -- A read sees by remote view too (read_sight); an action needs the character's sight.
  local by
  if read_only then by=M.read_sight(p,pos,'target') else assert_visible(p,pos,'target') end
  local candidates = p.surface.find_entities_filtered{position=pos, radius=0.2, name=args.name}
  -- Ore under a building is never the intended target unless named explicitly
  -- (resource: the fallback, ore or an item on the ground).
  -- A ghost on a building (a paste replacing it) yields to the building
  -- unless named, as the cursor picks the building; inspect lists the ghost.
  local found, resource, ghost, drifter, rail
  local named = args.name or args.unit_number
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
      elseif e.type == 'entity-ghost' and not args.name then ghost = ghost or e
      elseif not named and M.passing(e) then drifter = drifter or e
      elseif not named and M.UNDER[e.type] then rail = rail or e
      else
        if found then
          error(string.format('ambiguous target: %s and %s at (%g,%g); specify name or unit_number', found.name, e.name, pos.x, pos.y), 0)
        end
        found = e
      end
    end
  end
  -- Any tile of a building's footprint picks it, as a player's cursor does
  -- (shake3: Gemini's inspect missed buildings off their centre). Ore at the
  -- point stays the target of an action (mine there means the ore, never the
  -- drill over it); a read takes the building.
  if not found and (read_only or not resource) then
    local cover
    for _, e in pairs(p.surface.find_entities_filtered{position=pos, name=args.name}) do
      if wanted(e) and e.type == 'entity-ghost' and not args.name then ghost = ghost or e
      elseif wanted(e) and not named and M.passing(e) then drifter = drifter or e
      elseif wanted(e) and not named and M.UNDER[e.type] then rail = rail or e
      elseif wanted(e) and e.type ~= 'resource' and e.type ~= 'item-entity' then
        if cover and cover ~= e then cover = nil; break end
        cover = e
      end
    end
    found = cover
  end
  found = found or ghost or rail or resource or drifter
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
  -- Reads (inspect) only need sight, as scan does; by is 'remote view' when it was out of the character's.
  if read_only then return found,by end
  if not p.can_reach_entity(found) then error(M.out_of_reach(p,found),0) end
  return found
end
-- The reach the engine applies (can_reach_entity, read on world n at 01:58 against measured distances; Grok 01:51:
-- "mine says reach 10 but fails at 3 to 8 tiles"): the distance from the character to the entity's collision box
-- (bounding_box), within reach_distance (10) for buildings and within resource_reach_distance (2.7) for ore and trees.
-- An assembler 10.19 tiles from its box was out though 9.78 from its selection box; a belt 10.25 from its centre was in
-- at 9.70 from its box; trees 4.3 to 11 tiles from their box and stone ore 3.24 were out, ore at 2.31 in. Rocks
-- (simple-entity) are taken as trees; a target the engine refuses inside the long reach gets the short one.
M.SHORT_REACH={resource=true,tree=true,['simple-entity']=true,fish=true}
function M.box_distance(pos,e)
  local ok,b=pcall(function() return e.bounding_box end)
  if not (ok and b and b.left_top) then return distance(pos,e.position) end
  local dx=math.max(b.left_top.x-pos.x,0,pos.x-b.right_bottom.x)
  local dy=math.max(b.left_top.y-pos.y,0,pos.y-b.right_bottom.y)
  return (dx*dx+dy*dy)^0.5
end
-- (reach, what it is for) for this target; d: its box distance when the engine has refused it.
function M.reach_for(p,e,d)
  local long=p.reach_distance or 10
  local ok,short=pcall(function() return p.resource_reach_distance end)
  short=ok and type(short)=='number' and short or 2.7
  if M.SHORT_REACH[e.type] or (d and d<=long) then return short,' (ore, trees and rocks)' end
  return long,''
end
-- Out of reach (Haiku, shift09: about once a cycle): how far to its edge, the reach for it, and a free spot that
-- reaches it by the same rule.
function M.out_of_reach(p,e)
  local at,from=e.position,p.position
  local d=M.box_distance(from,e)
  local reach,kind=M.reach_for(p,e,d)
  local text=string.format('entity is out of reach: %s at (%g,%g) is %.1f tiles away (to its edge), reach %g%s',e.name,at.x,at.y,d,reach,kind)
  local ok,spot=pcall(function()
    -- Points on the line from it toward you, nearest to you first, that are within reach of its box; each moved to
    -- free ground and kept only if still within reach.
    local cd=distance(from,at)
    local ux,uy=1,0
    if cd>0 then ux,uy=(from.x-at.x)/cd,(from.y-at.y)/cd end
    local tries=0
    for k=math.floor(cd*2)/2,0,-0.5 do
      local q={x=at.x+ux*k,y=at.y+uy*k}
      if M.box_distance(q,e)<=reach-0.4 then
        local free=p.surface.find_non_colliding_position('character',q,2,0.25)
        if free and M.box_distance(free,e)<=reach-0.2 then return free end
        tries=tries+1
        if tries>=8 then return nil end
      end
    end
  end)
  if ok and spot then text=text..string.format('; in reach from (%g,%g)',math.floor(spot.x*10+0.5)/10,math.floor(spot.y*10+0.5)/10) end
  return text
end
-- Remote view (2.0) opens any own entity in a visible chunk, without reach.
local function remote_entity(p,a)
  local pos=position(a.position)
  assert(own_platform(p) or p.force.is_chunk_visible(p.surface,chunk_of(pos)),
    string.format('target must be in a visible chunk (remote view): (%g,%g) on %s is not visible to our force now (radar coverage there)',pos.x,pos.y,p.surface.name))
  local found,best
  local function pick(list)
    for _,e in pairs(list) do
      if e.valid and e.type~='entity-ghost' and e.type~='character' and (a.name or not attached[e.type]) and (not a.unit_number or e.unit_number==a.unit_number) then
        local d=distance(e.position,pos)
        if not best or d<best then found,best=e,d end
      end
    end
  end
  pick(p.surface.find_entities_filtered{position=pos,radius=0.5,name=a.name,force=p.force})
  -- Any tile of a building's footprint picks it, as the cursor does in remote view (a silo is 9x9).
  if not found then pick(p.surface.find_entities_filtered{position=pos,name=a.name,force=p.force}) end
  assert(found,string.format('no entity of ours at (%g,%g) on %s',pos.x,pos.y,p.surface.name))
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
  -- An electric machine no pole reaches is unpowered, whatever its status
  -- reads (Gemini's roboports read low_power for 2 h 45 min).
  if e.type~='entity-ghost' and e.type~='tile-ghost' and M.unpowered then
    local ok,why=pcall(M.unpowered,e)
    if ok and why then out.status_name='unpowered'; out.power=why end
  end
  -- An underground end shows what the belt GUI arrows show: which end it is
  -- (flow direction by name) and where its partner is.
  if e.type=='underground-belt' then
    local other=e.neighbours
    out.underground=e.belt_to_ground_type; out.flow=compass_names[e.direction]
    if other then out.paired_with=other.position else out.unpaired=true end
  end
  -- Pumps and underground pipes likewise: where fluid enters and leaves.
  if e.type=='pump' or e.type=='offshore-pump' or e.type=='pipe-to-ground' then pipes.hint(e,out) end
  -- An unpaired end says why: lava or space under its reach, its partner a
  -- ghost or out of reach, or none (underpass.lua).
  if out.unpaired and M.underpass then
    local ok,why=pcall(M.underpass.why,e)
    out.unpaired_why=ok and why or nil
  end
  -- Inserter direction names the pickup side; show the tiles it moves between.
  local function tile(pos) return {x=math.floor(pos.x)+0.5,y=math.floor(pos.y)+0.5} end
  if e.type=='inserter' then
    out.pickup=tile(e.pickup_position); out.drop=tile(e.drop_position)
    -- Nothing to take from or put into on a point (the engine's targets):
    -- 'no pickup target', 'no drop target' (targets.lua).
    out.io_warning=M.targets and M.targets.missing(e) or nil
  end
  -- Item filters in use, one line (details.lua filters_line).
  if (e.type=='inserter' or e.type=='loader' or e.type=='loader-1x1') and M.details then
    local ok,line=pcall(M.details.filters_line,e)
    out.filters=ok and line or nil
  end
  -- A drill drops onto one tile beside its footprint: which, and into what
  -- (sapilot board #4: Astra placed output chests by trial).
  if e.type=='mining-drill' then
    local ok,drop,into=pcall(function() return e.drop_position,e.drop_target end)
    if ok and drop then out.drop=tile(drop); out.drop_into=into and into.valid and into.name or nil end
  end
  return out
end
local function contents(inv) return inv and inv.get_contents() or {} end
local inventories = {
  chest = {'container','logistic-container','linked-container','temporary-container','infinity-container'},
  fuel = {'furnace','assembling-machine','boiler','burner-generator','inserter','mining-drill','lab','car','locomotive','reactor','spider-vehicle'},
  burnt_result = {'furnace','assembling-machine','boiler','burner-generator','mining-drill','car','locomotive','reactor'},
  furnace_source = {'furnace'}, furnace_result = {'furnace'},
  assembling_machine_input = {'assembling-machine','rocket-silo'}, assembling_machine_output = {'assembling-machine','rocket-silo'},
  lab_input = {'lab'},
  -- Space Age logistics: a silo rocket's cargo, landing pad and platform hub
  -- storage, and what an asteroid collector gathered.
  rocket_silo_rocket = {'rocket-silo'}, cargo_landing_pad_main = {'cargo-landing-pad'}, hub_main = {'space-platform-hub'},
  asteroid_collector_output = {'asteroid-collector'},
  -- Gleba: an agricultural tower's seeds and harvest (farm.lua reads the rest).
  agricultural_tower_input = {'agricultural-tower'}, agricultural_tower_output = {'agricultural-tower'},
  -- Trash slots: where the game puts items an entity will not use (a silo's
  -- hand-loaded cargo once automatic requests are on). Take-only.
  rocket_silo_trash = {'rocket-silo'}, cargo_landing_pad_trash = {'cargo-landing-pad'}, hub_trash = {'space-platform-hub'},
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
local take_order={'character_corpse','rocket_silo_trash','cargo_landing_pad_trash','hub_trash','chest','cargo_landing_pad_main','hub_main','asteroid_collector_output','cargo_wagon','car_trunk','spider_trunk','furnace_result','assembling_machine_output','agricultural_tower_output','burnt_result','fuel',
  'furnace_source','assembling_machine_input','agricultural_tower_input','lab_input','turret_ammo','artillery_turret_ammo','artillery_wagon_ammo','car_ammo','spider_ammo',
  'roboport_robot','roboport_material','rocket_silo_rocket'}
local give_order={'chest','cargo_landing_pad_main','hub_main','cargo_wagon','car_trunk','spider_trunk','furnace_source','assembling_machine_input','agricultural_tower_input','lab_input','roboport_robot','roboport_material','fuel','rocket_silo_rocket'}
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
  assert(defines.inventory[name], 'inventory unavailable')
  local inv = e.get_inventory(defines.inventory[name])
  assert(inv and inv.valid, 'inventory unavailable')
  return inv
end
local handlers = {}
local request_path,navigate,check_args
function handlers.describe()
  local description = {protocol=1, version='0.1.0', max_action_ticks=MAX_TICKS, deduplication_window=256, deduplication_bytes=8*1024*1024,
    -- operator-only reads this runtime answers (dispatch with operator=true; callers check here before asking)
    operator_reads={'attack_groups_live','big_enemies_live','hauling'},
    target='position:{x,y} (or [x,y]): the entity\'s centre as scan lists it, or any tile of its footprint; optional name and unit_number; targets require local visibility and character reach (inspect and cargo weigh: sight, or by remote view anywhere on your surface in a chunk our force sees now, by: remote view); a miss names the nearest entities',map_view='the user may stay in map view: actions drive the character entity, reach and visibility come from its position',
    actions={
      attach={allow_cheat_mode='boolean; TESTING ONLY default false'},detach={},
      equipment={operation='insert|remove',item='owned equipment item for insert',position='{x,y} grid cell; optional for insert',quality='default normal'},revive_ghost={position='{x,y}',name='optional entity-ghost'},
      shoot={position='{x,y} or auto=true',ticks='1..600',radius='1..32 (in a vehicle 1..36, default its gun\'s range)',gun_slot='1..3 (in a vehicle: 1..its guns)',
        gun='in a vehicle: a gun name (tank-cannon, tank-machine-gun, tank-flamethrower, vehicle-machine-gun, spidertron-rocket-launcher-1..4)',
        ammo='in a vehicle: an ammo name (cannon-shell, explosive-cannon-shell, firearm-magazine, flamethrower-ammo, rocket, ...): the gun that takes it, its slot loaded from your inventory when empty or holding another kind',
        note='seated in a car, tank or spidertron as its gunner (the driver, unless driver_is_gunner is off and a passenger sits in) it fires the vehicle\'s selected gun from the vehicle\'s ammo slots; the turret turns toward the target as a player\'s cursor turns it; position= aims at the entity there (not our own), auto=true at the nearest enemy in radius; vehicle {drive} goes on while it fires; reply: vehicle, seat, gun, gun_slot, range, guns (each slot with its ammo), target, out_of_range',
        outcomes='fires real ammo from the ammo slots; empty slots are first filled from carried ammo (and a carried gun into an empty gun slot), said in equipped, and refilled the same way when they run dry mid-fight (last_combat reloads); fails when none is carried; status last_combat: duration_elapsed | out_of_ammo | interrupted, with ammo_used (whole magazines gone from the slots); in a vehicle also target_destroyed | left_vehicle, with gun and guns (what each slot holds after)'},equip={slot='gun|ammo|armor',item='owned item name',index='default 1'},
      describe={}, inventory={returns='the character inventory: inventory (main), guns, ammo, armor, free (slots), crafting (hand queue), warnings (nearly full, hoarding); the same as observe player and status inv'},
      map={position='optional charted centre (default player)',radius='32..1024 tiles of charted map (default 256)',limit='1..256 regions (default 48)',resources='default true',water='default true',enemies='default true',trees='default false; per-chunk counts',rocks='default false; per-chunk counts',min_count='minimum trees/rocks per chunk (default 1)'}, observe={position='optional charted centre (default player); fogged chunks omit units',radius='1..32 (default 16)', limit='1..512 (default 128)', tiles='boolean (default false)',entity_types='optional array of entity types',entity_names='optional array of names',exclude_resources='boolean',resources='summary (default; connected visible tiles, bounds may include gaps)|tiles|none',group='boolean: entity name->{count,nearest} instead of rows',equipment='boolean: per-equipment rows (default name->count)',returns='player, entities, resource_patches, ground_items {stacks, items [{name, count, stacks, box}], more_items}: items on the ground in the radius by item (rows for them only with entity_types/entity_names)'},
      status={since='alerts after this tick (default last 5 minutes; losses are also pushed once on any reply in team.alerts)',threats='boolean: rescan now and list every enemy base (default: cached for 10 s, summary lines)',machines='boolean: rescan now and list positions of non-working machines',
        reports='teammates (one line: each other agent\'s planet, platform or cargo pod, grouped; on your surface, distance in tiles and compass direction, nearest first; dead and offline marked, a bot being offline after 15 min with no request or sleep poll); crafting (hand queue: items, seconds left, head entry);spoiling (Space Age: spoilable items carried, "name*count fresh%" stalest first); on_belt (while the character stands on a belt, underground or splitter, which carries it; also on last when an action ends there); evolution (factor, time/pollution/kills parts, delta over >=5 min); pollution (total, per_min emitted/absorbed, top 3 emitters, cloud chunks/extent on the chart and directions where it leaves the chart); enemies (bases known from the chart within 512 tiles, nearest with when it was last seen, how many our cloud reaches and reached_list, each with distance and direction from our nearest building; a base counts as reached while one of its chunks had pollution in the last 15 minutes, as in the defense read; next to be reached); chart (charted/visible chunks, extent, radars); alerts (losses: destroyed counts by name; latest: one line per loss incident (a raid: losses within 32 tiles on one surface) with causes; incidents: the same as rows {id, surface, platform, box {x0,y0,x1,y1}, total, names, by, first_tick, last_tick, line}; attacked areas, attack groups gathering in visible chunks, enemy_news: nest_charted, pollution_reached_nest; ground_items: a cargo landing pad that is full while item stacks lie within 40 tiles of it (position, slots, stacks, items), and piles of 100+ item stacks in a 64-tile cell holding our buildings (box, stacks, items); refreshed every 30 s, new or grown by half also in team.alerts); inv (free slots); factory (science consumed and plates produced per min over 1m|10m, research eta/next, hand share: items fed/collected/crafted by the character vs factory consumption/production over 10m); machines (per name: working count and other statuses); warnings (inventory nearly full, hoarding, no_fuel, low_power, labs missing packs, research idle or ending)'}, stop={}, walk={direction='north|northeast|east|southeast|south|southwest|west|northwest', ticks='1..600'},
      build_path={points='2..64 tile-centred axis-aligned waypoints; at most 512 belt tiles',item='transport-belt by default',ticks='1..36000',start_index='resume at this tile index; default 1',end_direction='optional final belt direction',note='walks to a far start (or resume tile) with the pathfinder, then steers along the line placing belts'},
      kite={position='optional anchor to clear (walks there when no enemies)',min_distance='keep units at least this far (default 7)',max_distance='band edge (default 12)',range='shoot structures within (default 14)',radius='enemy scan 8..32 (default 32)',min_health='stop below this health fraction (default 0.4)',retreat='optional {x,y}: below min_health or out of ammunition, walk there (firing at units in reach while ammunition lasts) instead of stopping where you stand; ends retreated on arrival',ticks='1..36000 (default 3600)',outcomes='clear | low_health | out_of_ammo | retreated | timed_out; last reports why (in words), kills, ammo_used, ammo_left, enemies_left, retreated_from'},
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
      cargo={items='{name: count} or [{name, count, quality}]: a rocket cargo list (items, not fluids)',position='or a chest, rocket silo (its loaded cargo), landing pad, platform hub, wagon or vehicle in sight: what it holds',platform='optional platform name (a hub or chest there)',returns='lift (kg and cargo slots a rocket), items [{name, quality, count, each_kg, kg, stacks, per_rocket (alone in one rocket: by weight and by slots), share (of a rocket\'s lift)}] heaviest first, total_kg, stacks, fewest (rockets by total weight and stacks), rockets and split [{rocket, kg, slots, items}] (one split: heaviest first, each into the first rocket with room), too_heavy; a read, nothing moves'},
      ports={name='entity (or the item that places it), e.g. electromagnetic-plant',position='{x,y} where it would stand (snapped like a build)',direction='north|east|south|west (default north)',recipe='optional recipe: which ports open and the fluid each carries',mirror='optional boolean: the H/V flip of fluid machines',platform='optional platform name (platform coordinates)',returns='ports [{at (the entity tile with the connection), joins (the tile outside it where a pipe joins), direction, flow input|output, fluid, box, there (what stands on joins now)}], closed (ports this recipe closes); a read, nothing is built; inspect of a ghost with a recipe shows the same in fluid_connections (fluid_connections_closed)'},
      dry_run={action='place_ghosts|paste|blueprint_place|build',args='that call\'s arguments (details=true: every entry with its footprint); the same as the call with dry_run=true'},
      place_ghosts={dry_run='boolean: place nothing; check the plan instead (a read: the running action and queue go on): per entity ok or why not (what collides and where, water/lava/out of map/platform empty space), tiles it needs first (landfill, foundation; on a platform also the empty tiles new foundation would enclose), power (wire reach, groups of planned poles with no wire path to a built pole, machines no supply area covers), standing spots that reach every placement, items vs held; inserters [{index, name, position, direction, pickup, drop, missing}]: what stands on each planned inserter\'s pickup and drop point (built, planned in this call, a ghost; or none: the ground, empty space, or what is there that takes no items), missing \'no pickup target\' / \'no drop target\'; inserters_without_target (count)',entities='1..256 {name,position,direction?,type? input|output for undergrounds} at absolute positions in charted chunks; no items needed; a tile or tile item name (landfill, stone-brick, concrete, space-platform-foundation) makes a tile ghost',ammo='turret ghosts request ammo, which the construction robots that build them bring from the logistic network (2.0 item requests): an ammo item name, {name?, count?}, or false for none; an entities entry\'s own ammo comes first. Default item: of the ammo the turret takes, the one the logistic network there holds most of (none there: the first, firearm-magazine for a gun turret); default count: the turret\'s automated ammo count (10 for a gun turret), at most what its slots hold. Returns ammo_requests [{item, count (each), ghosts, network_holds (what the network at the first holds; none when no network covers it)}]',
        tiles='optional {name, area={left_top,right_bottom}}: fill up to 4096 tile ghosts (landfill over water, foundation beside a platform); returns tiles_placed, tiles_existing (same ghost already there), tiles_refused (not placeable there)',
        platform='optional platform name: place on that space platform (its hub builds ghosts from hub items); positions are platform coordinates, hub at 0,0',['repeat']='optional {count 1..64, dx, dy}: stamp the list count times, each shifted by dx,dy; per-copy rows',returns='placed, failed [{index,error}], bounds (construct defaults to them), obstacles_marked (trees/rocks under the ghosts, marked for deconstruction like a player placement; construct mines them); underground_warnings: an underground belt or pipe-to-ground ghost whose span crosses tiles an underground cannot pass under (lava, empty space), which stays unpaired; inserters_without_target [{name, position, missing, pickup, drop}] (first 16; inserters_without_target_count past them): inserter ghosts with nothing to take from or put into on a point once the call\'s ghosts stand'},
      construct={area='optional {left_top,right_bottom} <=256x256; default: ghosts from the last paste',ticks='1..216000 (default 36000)',note='builds every ghost in reach from inventory and hand-mines every entity marked for deconstruction (timed like mine; contents to inventory, stops with inventory_full), then walks to the free stand point (never on a footprint) covering the most remaining ghosts near the nearest one; blocked ghosts retry once after moving; trees/rocks under ghosts are marked and mined first; ghosts whose item is in the hand-crafting queue are awaited (status awaiting_craft), not missing; status reports built/mined/remaining/missing/failed and blockers (trees/rocks in the way of a ghost, marked and mined first, also when a build bumps into one: name, position, ghost, at, cleared); outcomes: constructed (everything done) | incomplete (ghosts left for missing items or failures; a plan step fails) | nothing_to_do (a success, completes at once) | inventory_full | timed_out'},
      move_to={position='{x,y}, within 512 tiles',ticks='1..36000, default 3600',tolerance='0.25..10, default 0.5 (alias within)',pathfind='default true: the engine pathfinder: a padded box on the tile grid (with a twin request avoiding belts, kept when at most 6 tiles or a quarter longer), then the character\'s own box from the nearest free tile centre, on the half-tile grid, and on the quarter-tile grid with a wider goal; when none finds a route the walk ends at once as unreachable (a target on ungenerated ground is steered to directly); a stall, back-and-forth, or no progress toward the next waypoint for 90 ticks (e.g. a belt carrying the character back) sidesteps, every 3rd stall replans wider, blocked after 15 stalls; false steers directly',note='never ends on a belt: arriving on one it steps to the nearest free tile without a belt within the arrival radius (else within 3 tiles). Where the path ends short of the target, the rest is walked straight only with room to turn (a 0.7-tile box): a gap narrower than that ends the walk before it (arrived_near; last.pocket says where). Squeezed into a gap no path leads out of, it walks out along the gaps to the nearest spot with room first (last.escaped); closed in, last.mine_to_get_out names the fewest of our entities, trees or rocks whose mining opens a way out',squeeze='optional true: walk the last stretch into a narrow gap anyway; where no path request leads (none leads into a gap narrower than 0.7 tiles), walk the character\'s own steps there (a search over quarter-tile steps, up to 64 tiles a side; last.squeezed)',via='optional 1..16 points {x,y} (or [x,y]) walked in order before position, in one call: each leg its own walk, pathfound and checked for enemies as a single move_to (a via point counts as reached within 1 tile, or tolerance when larger; only the last leg steps off a belt; ticks covers the whole walk); a leg that does not arrive ends the walk with its outcome; last.legs lists each leg {to, outcome, s (seconds), why, avoided_enemies} and then those not walked; status active.leg says which (2 of 4); a queue step resumed after a pause goes on from the first via point it had not reached',avoid_enemies='default: worms the map shows are kept out of range + 4 tiles; true: worms and spawners (their units\' sight: 30 tiles on Nauvis, 40 on Gleba) + 8; a number 0..32: that margin; false: no check. A path through one\'s reach is walked as legs around the nest (corners of octagons around each worm\'s or spawner\'s reach, each leg the engine\'s path); a nest holding the start or the target is not avoided (last.enemies_at_start_or_goal); last.avoided_enemies names what was gone around; with no way round, a path crossing only a margin is walked (last.passed_within_margin) and one crossing a range ends no_safe_route',combat='optional true or a radius 1..32 (default 20): fire at enemies in range while walking, as shoot auto does (needs ammunition), until the walk ends; status/last_combat report it (outcome move_ended, ammo_used)',status='last reports why (unreachable: closed in, with the area and what closes it in, or no path; blocked; timed_out), nearest_reachable and reachable_gap (its distance to the target); unreachable: build_spot, a spot the character reaches within 9.25 tiles of the target (build reach 10), with room to turn when one is found, and build_spot_note saying so, or that it lies in a gap or only the character\'s own steps found it (build_spot_squeeze: the note names the move_to squeeze=true call that walks there), or that no reachable spot is within build reach; off_belt, path (off belts), steered (without a path), replans, stalls, no_progress, paths_failed',outcomes='arrived | arrived_near (stuck within tolerance+1.5, e.g. goal inside an entity; or stopped before a narrow gap: pocket) | unreachable (no route for the character: why, nearest_reachable, build_spot, mine_to_get_out) | no_safe_route (every way passes within an enemy\'s reach: why) | blocked | timed_out'},
      pickup={ticks='1..600 (default 30); over an area 1..36000 (default 3600)',area='optional {left_top,right_bottom} up to 64x64: pick up every item stack on the ground in it',position='optional centre of the square for radius (default you)',radius='optional 1..32 (default 8): the square around position, instead of area',items='optional 1..16 item names: only stacks of these',note='takes items on the ground within your pickup distance (stand on or next to them; refused when none is in reach); outcomes picked_up | duration_elapsed | inventory_full | nothing_in_reach, last.picked {item: count}, last.moved (the count) and last.inv (the inventory line after); the reply: moved 0, timed (until when), inv. Over an area (area, position/radius or items): one stack every 6 ticks, walking to the nearest stack left in the area; refused when it holds none; returns item_stacks and items; outcomes picked_up (none left) | inventory_full | blocked (stacks it could not walk to: last.skipped; it stops after 8) | timed_out; last.picked, last.left (stacks still in the area)'},repair={position='{x,y}',ticks='1..600; with positions or area 1..36000 (default 3600)',item='repair-pack by default',
        positions='or 1..64 {x,y} (each may carry name or unit_number): every damaged one, nearest first, walking to each (a timed action; outcomes repair_completed | timed_out | repair_tool_exhausted; last: repaired, already_full, unreached, lost, left, tally)',
        area='or {left_top, right_bottom} up to 128x128: every entity of ours with health in it, as positions (at most 64 damaged)',
        returns='an undamaged target (or none damaged among positions/area): ok with unchanged "not damaged", nothing started, no repair tool needed, last outcome nothing_to_do (a queue step goes on); with positions/area: targets, damaged, already_full, failed and first_error (positions that name no entity), until_tick; a damaged target with no repair tool held fails (no repair tool in inventory)',platform='refused: the game repairs platform entities itself, one at a time, with repair packs from the hub; platforms {platform} and inspect of the hub list damaged and repair_packs'},
      mine={position='{x,y}', ticks='1..600', name='optional', radius='1..32 (default 8): a resource tile at position that is mined out (the resource named, or the one an earlier mine at that position took): the tile of the same resource within radius of it, one in reach first, is mined instead; the reply\'s instead (and last.instead) names it', outcomes='target_mined | duration_elapsed (ore: last reports mined) | inventory_full (blocked_item) | not_minable (a stump, remnant or corpse; last.error) | target_lost | out_of_reach'},
      stock={item='item name; omit for every item held, largest first (items, more)',radius='1..1024 around position (default 128)',position='optional centre (default character)',limit='1..32 places (default 8); without item 1..64 items (default 16)',quality='default normal',
        returns='with item: total held in our machine outputs (assemblers, furnaces), chests and landing pads; by_entity; places nearest first {name,position,count,distance; a spoilable item: first_spoils_in (its first stack there), spoiled_percent, within_5_min}; made_by (crafters set to a recipe making it); held (your inventory); summary line (with the first to spoil, or for pentapod-egg and other items that hatch into enemies the first to hatch); hatches_into. Without item each line adds the first to spoil or hatch'},
      craft={force='boolean: hand-craft even when nearby stock covers it',short='when fewer started than asked: the raw ingredients missing for the rest (e.g. "wood short 18 (held 2)"), with stock lines for them',stock='when our machines/chests within 64 tiles hold the product: a stock line per item; a craft of >=3 s of hand time that stock covers is refused (errors) unless force=true',returns='started; hand_s (character crafting seconds for these), queue_s (whole hand queue), assemblers (our machines already set to each recipe); blocks (when the hand queue is >=30s); no_assembler (per recipe no machine runs: the best unlocked assembler and its time for the same batch)',recipe='name',count='1..1000',recipes='optional batch: array of {recipe,count}; each attempted, started/errors keyed by recipe'},craftable={recipes='optional name or array; default every hand recipe startable now (count>0)'},
      rates={area='{left_top,right_bottom} <=192x192',positions='or 1..64 {x,y} machines',per='second|minute (default minute)',
        returns='rows per item: produced, consumed, net at full speed, by/into machines x count; power produced/consumed; errors (no_recipe, no_fuel, no_power, no_resources, ...)',
        note='Rate Calculator formulas: recipe, crafting speed, modules, beacons, productivity, quality, fuel, drill resources; our machines only'},
      bottleneck={area='{left_top,right_bottom} <=192x192',positions='or 1..64 {x,y} machines',
        returns='groups (machine+recipe x count, status counts, short = missing ingredients), limits (input/output inserters slower than the machine at full speed), needs (items consumed beyond area production /min, flagged over one belt), inserters (waiting for source/space), belt_capacity',
        note='inserter rates are estimates (arm rotation x stack size)'},
      grid={platform='optional platform name: act on that space platform (hub at 0,0)',area='{left_top,right_bottom} <=128x128 (instead of position + radius)',position='charted centre (default player)',radius='1..64 (default 16)',returns='one character per tile: rows [{y,row}] from origin, ruler, legend {char: names}. Upper case buildings by type, belts ^>v<, U/J underground in/out, S splitter, ? ghost, @ character, # other; lower case ore; ~ water'},
      power={area='{left_top,right_bottom} <=128x128 (instead of position + radius)',position='charted centre (default player)',radius='1..64 (default 16)',limit='unpowered rows 1..256 (default 32)',note='networks with a pole in the area: poles, production/consumption kW (5 s average) by prototype, unpowered machines (no_power|low_power|unconnected)'},
      scan={platform='optional platform name: act on that space platform (hub at 0,0)',area='{left_top,right_bottom} <=128x128 (instead of position + radius)',position='charted centre (default player)',radius='1..64 (default 16)',positions='or 1..64 {x,y}: just the entities on those tiles (e.g. a few belts\' lanes)',name='optional name or array',type='optional type or array (resources only listed when filtered)',fields='hp|fuel|inventory|output|spoil (spoilable items: count and stalest freshness %)|status|recipe|direction|amount|range (attack range)|ammo|target (turret shooting target)|lanes (belt contents L|R)|io (inserter pickup -> drop, with entities)|fluids (per fluidbox "fluid amount/capacity" then each connection "in|out|io x,y" = the tile it connects to, "=entity" when joined there; underground ends "io uS" with the partner; boxes split by |; ghosts too, from the prototype)|filters (inserters, loaders: "whitelist: items", "blacklist: items", "off (filters: items)", "set by circuit", none; our inserters and loaders with filters in use carry it unasked); other forces under fog show only static fields',limit='1..1024 rows (default 256)',ore='runs (per-row x ranges) or grid (letters, # blocked, ~ water)',returns='entities, total, truncated, ore; ground_items {stacks, items [{name, count, stacks, box}], more_items}: items on the ground in the area by item (rows for them only when name or type asks: item-on-ground, item-entity)'},
      nearest={position='optional charted centre (default player)',name='entity name or array',type='entity type or array (name or type required)',radius='1..128 (default 32); map-known (charted) entities only: after landing on a new planet about 48 tiles around you, so explore or build a radar',limit='1..64 (default 5)',returns='entities [{name?, position, distance}], total; note when nothing was found'},cancel_craft={recipe='cancel this recipe\'s own queued crafts (latest first)',index='1-based crafting queue index (instead of recipe)',count='number to cancel (default all of the recipe or entry); refunds through normal game rules'}, build={dry_run='boolean: build nothing; check every entry from where you stand (a read): placeable or why not, out of reach (distance vs build reach), items short (held + hand-craft queue), tiles needing landfill, poles\'s wire reach, and standing spots that reach every entry; inserters: each planned inserter\'s pickup and drop target, as place_ghosts dry_run gives them',item='name (a tile item such as landfill, stone-brick, concrete places tiles: size 1..4 square, default 1; landfill only on water)',entity='rail item (a rail planner): which rail it places: straight-rail (default), half-diagonal-rail, curved-rail-a, curved-rail-b; with directions including the in-between ones (northnortheast, eastnortheast, ...); place_ghosts takes the rail names too and construct builds them',size='tiles: brush size 1..4',position='{x,y}',direction='compass name (default north)',builds='optional batch of 1..64 {item,position,direction,quality,type}; top-level item/direction/quality are defaults; the first failure fails the action (earlier entries stay built)',skip_failed='boolean, with builds: a failing entry is listed in failed {index,position,error} and the rest still build',type='underground belts: input|output (default: output when an unpaired input flowing the same way is upstream in range); result shows underground, flow, paired_with|unpaired, and unpaired_why (lava or empty space under its reach, its partner a ghost or out of reach, or none in reach)',poles='a placed pole also wires to every other network in wire reach (networks_joined)',inserters='direction is the pickup side (east picks from the east, drops west); results show pickup and drop tiles',note='short of the item while the hand-craft queue makes it: waits for the craft and then builds (awaiting_craft; a timed action, outcome fed | failed | timed_out; use --wait). Your own character the only thing on the footprint: it walks off first and then builds (stepping_aside {from,to}; the same timed action and outcomes; last.result holds the build result)'},
      inspect={position='{x,y}',positions='optional 1..32 positions: one inspect each in one call, results in order (an entry that fails has position and error)',area='or {left_top, right_bottom} up to 128x128: our chests and machines (entities with an inventory; types to choose) with their centre inside that inspect can read (in sight, or by remote view in a chunk our force sees now), at most 64, one row each in reading order: entities [{name, position, holds (a chest: its items largest first, slots used of the total; a machine: in, out, fuel, ...), requests (requester, buffer: held/asked), recipe, status_name}], count, not_in_sight (how many more the area holds in chunks our force does not see)',types='with area: entity types (1..16; default every type with an inventory: chests, machines, labs, silos, boilers, drills, turrets, wagons, vehicles, landing pads, hubs, roboports, towers)',platform='optional platform name: inspect on that space platform (platform coordinates, hub at 0,0; the whole platform is in sight)',note='read-only, without reach: any entity in sight (32 tiles of the character), or by remote view any entity on your surface in a chunk our force sees now (radar coverage or a character\'s sight), as the map shows it (by: remote view; surface= another surface reads the same way); out of both, the refusal names the nearest radar coverage; in_reach says whether acting on it would reach; holds (a chest, logistic chest, wagon, car or spider trunk, landing pad, hub): one line, the largest stacks first as name*count, then slots used of the total and the red-X limit; requests (requester, buffer): item held/asked per request, summed over active sections; output_fill (assembler, furnace): each product in the output held of its stack size and %, and full when the machine stopped for it (status full_output), e.g. copper-cable 200/200 (100%), full; inserters and mining drills show their drop tile and what stands there (io); build replies and observe entity rows show a drill\'s drop and drop_into too; trash: what the game put in a silo\'s, landing pad\'s or hub\'s trash slots; rocket_weight (a silo): cargo held/lift kg; modules {inventory_index (the inventory a blueprint module request names), slots, contents}; filters, filter_mode, use_filters (inserters, loaders); an asteroid collector: filters (chunk names), filter_slots (the game\'s count; 0 until a filter is set), arm (chunks its arms hold), its output under inventories.asteroid_collector_output; held (an inserter\'s hand), pickup_target, drop_target, io_warning (\'no pickup target\', \'no drop target\': the engine\'s targets; also in io and observe rows; build and rotate replies read what stands on the points (on the engine\'s 1/256-tile grid), as the engine sets targets a tick later; a builds batch lists inserters_without_target after all its entries (first 16; inserters_without_target_count past them); an inserter ghost: what stands on its points); marked_for_deconstruction, marked_for_upgrade; ghosts_here (ghosts on the footprint, with their filters); on a platform: hub_slots, repair_packs and damaged (most damaged first, up to 10; damaged_count past that) on the hub, repair (how a damaged entity there gets repaired), and construction_blocked (hub full, ghosts whose items the hub lacks); spoiling: per inventory (and a belt\'s lanes, an inserter\'s hand, an item on the ground) each spoilable item, the time until its first stack spoils and how spoiled that stack is, and how many spoil within 5 min, earliest first; an item that hatches into enemies when it spoils (pentapod-egg, biter-egg) says hatches, and what into; hatch_warning sums those up (count, into what, the first, how many within 5 min); output_spoil (an assembler, furnace or biochamber whose products spoil): what the next products start at, the count-weighted spoilage of the spoilable ingredients in its input (bioflux from 15 yumako-mash at 80% and 12 jelly at 20%: about 53%), or fresh when the recipe resets freshness (pentapod-egg); an agricultural tower: tower {state, seeds, output, area, cells (growing, grown, free with soil for which seeds, blocked by what, no soil), plantable_now, planted_10min, plants (time until grown), harvest_made_10min}'}, rotate={direction='optional compass name (north, east, south, west; 2.0 numbers 0, 4, 8, 12 too): turn until it faces this way, one 90-degree turn at a time as the R key does',returns='rotated, before, after (compass names; 2.0 directions: north 0, east 4, south 8, west 12), turns (how many 90-degree turns it took), entity; one call without direction is one 90-degree turn clockwise, reverse=true counter-clockwise',position='{x,y}',reverse='boolean'},
      configure={surface='optional planet name: act there by remote view, where our force sees the chunk',auto_requests='rocket silo: boolean, the GUI\'s automatic requests (fill and launch for platforms\' requests in orbit; switched on with cargo loaded by hand, that cargo goes to the trash slots: cargo_to_trash, note)',send_to_orbit_automatically='rocket silo: boolean, the GUI\'s send to orbit automatically; a silo reply reads back settings {silo, auto_requests, send_to_orbit_automatically, requesting_for, rocket, parts}',position='{x,y}; out of reach works through remote view in any visible chunk (recipe changes then need an empty, idle machine)',platform='optional platform name: configure on that space platform through remote view (platform coordinates, hub at 0,0)',recipe='enabled recipe',quality='optional recipe quality (normal, uncommon, rare, epic, legendary; the machine needs the quality unlocked)',filters='or: item names (one name alone too) for a filtering inserter/loader, or asteroid chunk names (metallic-asteroid-chunk, ...) for an asteroid collector ([] clears and, on an inserter, turns filtering off; up to the entity\'s filter slot count; a collector\'s count reads 0 until a filter is set, so there each slot is tried and only the game\'s refusal fails it; the reply reads the filters back, not_set for a name that did not stick)',filter_mode='whitelist|blacklist (inserters; alias mode; alone it keeps the items; asteroid collectors have no filter mode in the game)',use_filters='inserters: true|false, the GUI\'s use filters (false keeps the items, unused)',force='boolean: allow destroying held fluids',returns='returned/spilled {item=count}: contents and interrupted-craft ingredients go to inventory like a player recipe change; filters: filters, filter_mode, use_filters read back, line (whitelist: items | blacklist: items | off (filters: items) | set by circuit), before (the line before)'},
      transfer={position='{x,y}',positions='optional array of 1..64 {x,y}: same transfer per entity; per-entity rows plus total',area='or {left_top, right_bottom} up to 128x128: our entities of types (default chests, machines, labs, silos, boilers, drills, turrets, wagons, vehicles, landing pads, roboports, agricultural towers) with their centre inside, as positions (at most 64; area_targets counts them)',types='with area: entity types to take (1..16)',inventory='chest|fuel|furnace_source|furnace_result|assembling_machine_input|assembling_machine_output|lab_input|rocket_silo_rocket (silo cargo)|rocket_silo_trash|cargo_landing_pad_main|hub_main|asteroid_collector_output|... (*_trash: take-only, what the game moved out); inferred when omitted (to_player takes from non-empty trash slots first; fuel items->burner fuel, else the first inventory accepting the item, e.g. silo ingredients then rocket cargo; to_player->output or inventory holding item)',item='name; omit with to_player to take everything',quality='default normal',count='1..10000 per entity (default: to_entity 1, or total; to_player all of the item; unlimited when item omitted)',total='optional cap across positions, filled in order; echoed',returns='moved (transferred: its alias for a shift), inv (the inventory line after: free slots, what you hold of the items moved); rows moved per target; tally with 2+ positions: one line, moved per item, targets touched of the total, short (full, holding none, failed with the first reason); a target out of reach fails at once, without walking: entity is out of reach: NAME at (x,y) is D tiles away, reach R; in reach from (x,y) (a free spot); inventory_full|entity_full {requested,got,blocked_item} when space ran out; to_entity gives from the main inventory, then (ammo) the gun ammo slots; holding none fails; short of items the hand-craft queue will deliver, it waits for them (awaiting_craft, outcome fed | failed | timed_out); into rocket_silo_rocket only what fits under the rocket\'s 1000 kg lift (rocket_weight held/lift kg; weight_limited {requested,fits,note} when fewer fit; fails when none fits)',direction='to_entity|to_player (from_player, give, put, insert, to_chest, to_container = to_entity; from_entity, take, from_chest, from_container = to_player; to_entity=true, from_entity=true, or to_entity={x,y} / from_entity={x,y} as the target, noted in corrected); any container: chests, logistic chests, car and spider trunks, cargo wagons, landing pads, hubs; inferred when omitted (echoed as direction): no item -> to_player; an item only the character holds or is hand-crafting -> to_entity; one only the targets hold -> to_player; both or neither -> error',keep='optional source reserve count',keep_max='true (to_player): refuse a take that would put you over your personal request max (the game moves what is over it to your trash slots); nothing is taken; up_to=true stops at that max instead (left_at_max); every take over it says so in trash',up_to='a number: the target total cap (tops the target up to it); true: move what there is, min(count, held or in the source, room), never failing on a short or empty source: moved, short {asked, moved, reason: none_held|source_short|target_full}; as a queue step it never pauses the plan for that'},
      feed={area='or {left_top, right_bottom} up to 128x128: our machines of types (default as in reach; with recipe assemblers and furnaces) with their centre inside, as positions (at most 64; those on another recipe are counted in other_recipe; area_targets counts them)',note='hand-feeds machines from inventory, nothing taken out: an assembler/furnace gets its recipe\'s item ingredients (an idle furnace its last recipe\'s; a furnace with no recipe yet the items or item named that it smelts), a lab its science packs, a burner (furnace, drill, boiler, burner inserter) fuel when its fuel slots are empty (or with fuel=true, fuel=NAME, or a fuel named in items); each item up to count per machine, keeping keep in inventory. In reach by default; positions or radius (a walking tour, timed: outcomes topped_up | nothing_to_do | out_of_items | timed_out; last reports given, visited, items, entities)',
        returns='moved (alias transferred), inv (the inventory line after), items, entities: per machine fed {position, name, gave, fuel (its fuel slots after: "coal 10" or "empty")}, with positions or area also each one that got nothing (got nothing); unchanged (count); held; nothing_moved: why nothing was given (what you carry and the machines hold, burners left alone because they hold fuel, furnaces with no recipe yet)',
        radius='1..256: walk a nearest-first route through every machine in radius that wants something you hold',ticks='with radius: 1..36000 (default 3600)',
        positions='optional 1..64 positions instead of everything in reach',items='optional 1..16 item names: give only these',item='optional one item name: give only it (with items, it is added to them)',
        count='1..1000 target per ingredient/science pack per machine (default 20)',fuel='fuel item for burners: given to every burner below fuel_count; true: the same with the fuel it holds when you carry it, else coal (chemical burners); omitted: only burners with empty fuel slots get fuel; false skips fuel',fuel_count='1..1000 fuel target per burner (default 10)',
        keep='reserve of each item kept in inventory (default 0)',types='optional entity type filter (default assembling-machine, furnace, lab, boiler, burner-generator, mining-drill, inserter)',quality='default normal',
        recipe='optional recipe name: every machine set to it (positions, in reach, or radius) gets each item ingredient for crafts crafts (topped up to ingredient amount x crafts); machines set to another recipe are listed apart',crafts='with recipe: 1..1000 (default 1)',
        up_to='true: a short or empty inventory never fails the call or, as a queue step, pauses the plan (a tour\'s out_of_items counts as done)',
        returns='moved (alias transferred), inv (the inventory line after), items {name=count}, entities (position, name, gave; with recipe: loaded, short {item=missing}), unchanged, held (what is left of each item given)'},
      rearm={radius='1..256: walk a nearest-first route through every turret in radius below count and top it up (a timed action; outcomes topped_up | nothing_to_do | out_of_items | timed_out; last reports given, visited, left)',ticks='with radius: 1..36000 (default 3600)',ammo='ammo item (default firearm-magazine)',count='1..1000 target per turret (default 10)',positions='optional 1..64 positions instead of every turret in reach',types='default {ammo-turret}; artillery-turret allowed',note='gives from the main inventory, then the gun ammo slots (crafted ammo lands there); fails when none is held and turrets want more; waits for ammo in the hand-craft queue (awaiting_craft; outcome fed | failed | timed_out)'},
      refuel={radius='1..256: walk a nearest-first route through every burner in radius below count and top it up (a timed action; outcomes topped_up | nothing_to_do | out_of_items | timed_out; last reports given, visited, left)',ticks='with radius: 1..36000 (default 3600)',fuel='fuel item (default coal)',count='1..1000 target per entity (default 10)',positions='optional 1..64 positions instead of every burner in reach',types='optional entity type filter',note='fails when no fuel is held and burners want more; waits for fuel in the hand-craft queue (awaiting_craft)'},
      collect={up_to='true: an empty source or a full inventory never fails the call or, as a queue step, pauses the plan (nothing_collected and inventory_full count as done); moved, short {asked, moved, reason}; it also stops at your personal request max for an item (left_at_max says what stayed in the source)',keep_max='true: refuse a take that would put you over your personal request max (the game moves what is over it to your trash slots); nothing is taken. Without it, a take over that max (or of an unrequested item while unrequested items go to trash) says so in the reply\'s trash lines: how many the game moves to your trash slots',types='entity types (default furnace, assembling-machine: machine outputs only)',chests='boolean: also empty plain chests (container, logistic-container) in reach or radius; off by default because chests are usually feed stock you placed (result notes chests_skipped / left_in_chests)',item='optional: only this item',positions='optional 1..64 positions instead of everything in reach (named chests are always taken from)',area='or {left_top, right_bottom} up to 128x128: our entities of types (default machines; chests=true adds chests) with their centre inside, as positions (at most 64; area_targets counts them)',
        radius='1..256: with item, walk to our machine outputs/chests holding it (as stock lists), nearest-neighbour route, taking it until count; without item, to every assembler and furnace output in it holding anything, taking all of it (output slots only, never inputs or fuel; chests need item; last reports items); a timed action',count='with radius: stop after this many (default all)',want='optional, with item: hold this many; takes only the difference (nothing when you already have it); not with count',ticks='with radius: 1..36000 (default 3600)',
        outcomes='with radius: collected | nothing_collected | inventory_full | timed_out; status reports got, visited, and tally with 2+ places: moved per item, places touched of the total, short (not reached, failed, not visited); in reach or with positions, 2+ targets: tally as transfer\'s'},
      research={technology='name (omit everything to report: current, progress, queue, pending, and entries: each queued technology with progress %, queued_by, packs, done_in at the lab throughput of the last minute (2 minutes, then the last 5, when the last minute had no research progress; throughput says which), waits_for a pack nobody made in 10 minutes; throughput; clock_stops_at)',remove='a queued technology name, or an array: takes it out of the queue as the research GUI does, with queued technologies that need it (also_removed); progress is kept for later',cancel='same as remove',move='a queued technology name: reorders it to position `to` (1 = researched now); refused ahead of a queued prerequisite or behind a queued technology that needs it',to='position for move (1..queue length)',front='boolean: technology or research_queue goes ahead of the current queue (overflow drops from the tail)',append='boolean: research_queue goes after the current queue',research_queue='array of ordered names; without front/append it replaces the queue ([] clears it)',returns='queue; skipped "name: reason" (unknown|already_researched|not_enabled|trigger_unlocked): dropped; pending: names beyond the engine queue cap (or waiting on prerequisites), kept and fed in as the queue frees up (adding more keeps them; a plain research_queue replaces them); added_prerequisites {tech: [names]}: unresearched prerequisites inserted ahead of each requested tech, like the game GUI'},research_next={technologies='prioritized list; starts first available only when research is idle'}, recipes={prefix='optional',limit='1..256'}, technologies={prefix='optional',limit='1..256',available='boolean: only unresearched ones whose prerequisites are done (what can be researched or triggered now)',returns='entries; trigger names what unlocks a trigger technology (craft 50 iron-plate, mine crude-oil, create a space platform, launch X to orbit, ...): labs never research those'},
      blueprint_import={blueprint='export string',slot='default clipboard'},blueprint_export={slot='default clipboard',name='or a team library entry (blueprint_save)',layout='true returns normalized relative layout and material costs instead of export string'},
      blueprint_list={name='optional team library entry: that entry in full (all entity counts, description, anchor, captured area)',returns='slots (your own); library: the team\'s entries {name, author, entities, tiles, footprint WxH tiles, counts (largest 4), saved, last_used (ago, by whom) or never, uses, surface, anchor, description}; library_limit'},
      blueprint_delete={slot='name',name='or a team library entry: its author any time, anyone after 24 game hours unused'},
      blueprint_save={name='1..40 letters, digits, _ . - : the team library entry (the same name replaces it; its author any time, anyone after 24 game hours unused)',area='{left_top:{x,y},right_bottom:{x,y}} up to 256x256 of charted map: our entities in it',positions='or 1..256 positions (each may carry name or unit_number): only those entities, and the wires between them',description='optional text up to 300 characters',anchor='optional {x,y} in the area: blueprint_place {name, position} then puts this point at position',tiles='boolean: include tiles (area)',returns='name, author, entities, tiles, footprint, counts, saved, anchor, replaced (the previous author); kept in the save for every agent and later shifts; the library holds 64 entries'},
      blueprint_rename={name='team library entry',new_name='1..40 letters, digits, _ . -',note='its author any time, anyone after 24 game hours unused'},
      blueprint_capture={area='{left_top:{x,y},right_bottom:{x,y}}',slot='default clipboard',tiles='boolean',station_names='boolean'},copy={area='{left_top:{x,y},right_bottom:{x,y}}'},cut={area='{left_top:{x,y},right_bottom:{x,y}}'},paste={dry_run='boolean: place nothing; check the plan instead (a read: the running action and queue go on): where each blueprint entity and tile lands, per entity ok or why not (what collides and where, water/lava/out of map/platform empty space), tiles it needs first (landfill, foundation; on a platform also the empty tiles new foundation would enclose), power (wire reach, groups of planned poles with no wire path to a built pole, machines no supply area covers), standing spots that reach every placement, items vs held; inserters [{index, name, position, direction, pickup, drop, missing}]: what stands on each planned inserter\'s pickup and drop point (built, planned in this call, a ghost; or none: the ground, empty space, or what is there that takes no items), missing \'no pickup target\' / \'no drop target\'; inserters_without_target (count); requests_kept: entities with requests it lands on, whose requests stay',platform='optional platform name: act on that space platform (hub at 0,0)',position='{x,y}: where the blueprint\'s center goes (the game centers it there); with anchor hub, where its hub goes (default the platform\'s hub)',anchor='hub | center | saved: on a platform a blueprint holding a space-platform-hub is placed by its hub (default there); a library entry saved with an anchor is placed by it (saved, default there: position is where that point lands; no flips); center places its center at position',['repeat']='optional {count 1..64, dx, dy}: paste count copies, each shifted by dx,dy; totals plus per-copy rows',slot='default clipboard',name='or a team library entry (blueprint_save; blueprint_list lists them): its last use is recorded',direction='north|east|south|west',flip_horizontal='boolean',flip_vertical='boolean',book_path='array of 1-based book indices',details='boolean: list every ghost',ammo='the new turret ghosts request ammo, as place_ghosts ammo (a name, {name?, count?}, or false); a ghost whose blueprint requests ammo keeps that request. Returns ammo_requests [{item, count, ghosts, network_holds}]',mode='normal (default: all or nothing, as a player\'s paste) | forced (shift-paste: ghosts where they fit; trees, rocks and the like in the way marked for deconstruction) | superforced (ctrl+shift-paste: our own entities in the way marked too)',returns='count, by_name, bounds; mode; origin_at, center_at (where the blueprint\'s 0,0 and center landed); anchor {by, hub, paste_position, hub_landed, aligned}; marked_for_deconstruction, marked_by_name (what a forced paste marked); wires {in_blueprint, connected, added, end_not_placed, failed, ends_not_placed} (the blueprint\'s wires between placed ends: missing ones connected); fewer ghosts than the blueprint holds: expected, not_placed [{name,position,direction,reason}] (first 20, not_placed_count; reason: uncharted, a broken tile rule, what blocks the footprint), existing_entities/existing_ghosts at the blueprint\'s spots, settings_differ [{name,position,ghost?,differs,fix}] (recipe, filters, modules unlike the blueprint; fix is the configure call), reason; inserters_without_target (as place_ghosts); requests_kept: each entity with requests the blueprint lands on (hub, requester and buffer chests, landing pads) and its requests after (a paste leaves them; the blueprint\'s own are not applied; changed while the blueprint carried none, they are put back)'},blueprint_place={dry_run='boolean: as paste dry_run',platform='optional platform name: act on that space platform (hub at 0,0)',position='{x,y}: where the blueprint\'s center goes (the game centers it there); with anchor hub, where its hub goes (default the platform\'s hub)',anchor='hub | center | saved: on a platform a blueprint holding a space-platform-hub is placed by its hub (default there); a library entry saved with an anchor is placed by it (saved, default there: position is where that point lands; no flips); center places its center at position',['repeat']='optional {count 1..64, dx, dy}: paste count copies, each shifted by dx,dy; totals plus per-copy rows',slot='default clipboard',name='or a team library entry (blueprint_save; blueprint_list lists them): its last use is recorded',direction='north|east|south|west',flip_horizontal='boolean',flip_vertical='boolean',book_path='array of 1-based book indices',details='boolean: list every ghost',ammo='the new turret ghosts request ammo, as place_ghosts ammo (a name, {name?, count?}, or false); a ghost whose blueprint requests ammo keeps that request. Returns ammo_requests [{item, count, ghosts, network_holds}]',mode='normal (default: all or nothing, as a player\'s paste) | forced (shift-paste: ghosts where they fit; trees, rocks and the like in the way marked for deconstruction) | superforced (ctrl+shift-paste: our own entities in the way marked too)',returns='count, by_name, bounds; mode; origin_at, center_at (where the blueprint\'s 0,0 and center landed); anchor {by, hub, paste_position, hub_landed, aligned}; marked_for_deconstruction, marked_by_name (what a forced paste marked); wires {in_blueprint, connected, added, end_not_placed, failed, ends_not_placed} (the blueprint\'s wires between placed ends: missing ones connected); fewer ghosts than the blueprint holds: expected, not_placed [{name,position,direction,reason}] (first 20, not_placed_count; reason: uncharted, a broken tile rule, what blocks the footprint), existing_entities/existing_ghosts at the blueprint\'s spots, settings_differ [{name,position,ghost?,differs,fix}] (recipe, filters, modules unlike the blueprint; fix is the configure call), reason; inserters_without_target (as place_ghosts); requests_kept: each entity with requests the blueprint lands on (hub, requester and buffer chests, landing pads) and its requests after (a paste leaves them; the blueprint\'s own are not applied; changed while the blueprint carried none, they are put back)'},deconstruct={platform='optional platform name: act on that space platform (hub at 0,0)',area='{left_top:{x,y},right_bottom:{x,y}} up to 256x256 of charted map',entity_names='optional array',entity_types='optional array',items_on_ground='optional boolean: mark every item stack on the ground in the area, as a planner over items on the ground (construction robots carry them to storage chests); other entities then only with entity_names/entity_types. Returns item_stacks (marked), item_stacks_already, items [{name,count,stacks}], robot_networks and storage_chests (logistic networks whose construction area covers marked stacks), outside_construction_area (stacks no roboport covers)',
        tiles='optional: true (every minable tile in the area) or 1..32 tile names, e.g. ["space-platform-foundation"], ["landfill"]: marks tiles as a planner in tile mode does (robots take them back to the hub or a roboport) and removes our tile ghosts of those tiles (tile_ghosts_removed: landfill planned over water, before robots build it); entities then only with entity_names/entity_types. Returns tiles_marked, tiles_already, tiles_refused with refused {under_entity, engine, not_minable, error}, tiles_blocked (marked tiles under entities not marked; a note names them), tile_ghosts_removed'},cancel_deconstruction={platform='optional platform name: act on that space platform (hub at 0,0)',area='{left_top:{x,y},right_bottom:{x,y}}',entity_names='optional array',entity_types='optional array',items_on_ground='optional boolean: unmark the item stacks on the ground in the area (item_stacks)',
        tiles='optional: true or 1..32 tile names: clears tile marks (tiles_cancelled); entities then only with entity_names/entity_types'},
      screenshot={path='relative .png path under script-output',width='320..1920',height='240..1080'}},
    limitations={'No teleport, resource creation, free crafting, direct mining, remote building, or map reveal',
      'Runtime source installation is trusted operator code, not a security sandbox',
      'Screenshots require a graphical client controlling the requested player; headless hosts do not render',
      'Vehicles and fluid transfers are unsupported',
      'Walk/mine completion is bounded by ticks; inspect status and observe to verify outcomes'}}
  for name,schema in pairs(scheduler and scheduler.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.orders and M.orders.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(clock and clock.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.chat and M.chat.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(space and space.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.profiles.schema) do description.actions[name]=schema end
  for name,schema in pairs(M.board and M.board.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.waits and M.waits.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.labs and M.labs.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.supply and M.supply.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.trace and M.trace.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.audience and M.audience.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.capsules and M.capsules.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.flush and M.flush.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.circuits and M.circuits.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.trains and M.trains.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.rails and M.rails.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.vehicles and M.vehicles.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.shore and M.shore.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.defense and M.defense.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.ores and M.ores.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.tells and M.tells.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.players and M.players.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.votes and M.votes.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.research and M.research.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.stores and M.stores.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.drops and M.drops.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.pushalerts and M.pushalerts.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.selfview and M.selfview.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.networks and M.networks.schema or {}) do description.actions[name]=schema end
  for name,schema in pairs(M.silo and M.silo.schema or {}) do description.actions[name]=schema end
  description.actions.status.brief='boolean: only active, last, combat, last_combat, alive, connected, surface, platform, position and tick (what fh --wait polls); without it, factory, machines, fuel/power/ammo/lab warnings, pollution and chart are shared by every agent on the same surface and refreshed every 10 s (factory_as_of, threats_as_of give the tick when older)'
  description.actions.status.alerts='boolean, with brief: add the alerts block (losses, attacked areas, groups, enemy news; read from what the game reported, no scan)'
  description.actions.cameras={returns='director cameras: player, follow, position, zoom'}
  -- inspect's circuit readback and another surface by remote view (circuits.lua).
  description.actions.inspect.surface='optional planet or surface name: inspect there by remote view (a visible chunk)'
  description.actions.inspect.note=description.actions.inspect.note..'; circuit (an entity with circuit settings or wires): enable/logistic conditions as text with _met, disabled, '..
    'settings and off (switches, modes, signals by the names circuit_set takes), a combinator\'s settings and output, wires per color (red, green, copper; '..
    'a combinator\'s red_input ... green_output, a power switch\'s copper_left/right) with each far end {entity, position, side}, networks {id, signals} (the signals on each now)'
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
-- counting every entity by name, so a wiped outpost is reported whole. A cell
-- quiet for 5 minutes, or a new shift (operator shift_start), starts a new
-- incident (shake5: one raid's total grew across two shifts and read as one
-- raid); the old ones stay in status alerts with since.
-- Since the shift 5 study, an incident is one raid: losses on the same surface within 32 tiles of its box join it
-- (while the box stays under 192 tiles), it has an id, and a reader is told it once and then its running total at most
-- once a game minute while it grows (shift 5: 839 loss lines for about 30 raids, each growth repeated).
-- One table: runtime.lua's main chunk is near Lua's 200-local limit (tests/locals.lua).
local LOSS={cell=64,max=64,join=32,span=192,again=3600,first=18000}
-- An incident's latest tick is `(i.last or i.first or 0)`: saves from before shake11 can hold one created without
-- `last` (it was set only after the 64-incident cap check, which then failed on it in the tick: shake10's quarantines).
-- friendly: the cause is one of the entity's own force (shake11-12: our flamethrower turrets burnt gun turrets, radars,
-- belts and their own oil lines in 8 and 11 areas), kept apart from enemy causes, with where the cause stood.
local function record_loss(tick,e,cause,friendly,cause_at)
  local s=state()
  s.losses=s.losses or {}
  local x,y=e.position.x,e.position.y
  local surface=e.surface and e.surface.name or nil
  local incident
  for _,i in ipairs(s.losses) do
    local b=i.box
    if i.surface==surface and not i.closed and tick-(i.last or i.first or 0)<=5*3600
      and x>=b[1]-LOSS.join and x<=b[3]+LOSS.join and y>=b[2]-LOSS.join and y<=b[4]+LOSS.join
      and math.max(b[3],x)-math.min(b[1],x)<=LOSS.span and math.max(b[4],y)-math.min(b[2],y)<=LOSS.span then incident=i; break end
  end
  if not incident then
    s.loss_ids=(s.loss_ids or 0)+1
    local ok,platform=pcall(function() return e.surface.platform and e.surface.platform.name end)
    incident={id=s.loss_ids,key=math.floor(x/LOSS.cell)..','..math.floor(y/LOSS.cell),surface=surface,platform=ok and platform or nil,
      box={x,y,x,y},first=tick,last=tick,names={},causes={},total=0}
    s.losses[#s.losses+1]=incident
    if #s.losses>LOSS.max then
      local oldest=1
      -- last is set at creation: the newest incident once had none, and this compare failed and left it so (shake11)
      for i,v in ipairs(s.losses) do if (v.last or v.first or 0)<(s.losses[oldest].last or s.losses[oldest].first or 0) then oldest=i end end
      table.remove(s.losses,oldest)
    end
  end
  s.loss_seq=(s.loss_seq or 0)+1
  local b=incident.box
  b[1],b[2],b[3],b[4]=math.min(b[1],e.position.x),math.min(b[2],e.position.y),math.max(b[3],e.position.x),math.max(b[4],e.position.y)
  incident.last=tick; incident.seq=s.loss_seq; incident.total=incident.total+1
  incident.names[e.name]=(incident.names[e.name] or 0)+1
  if cause and friendly then
    incident.friendly=incident.friendly or {}; incident.friendly[cause]=(incident.friendly[cause] or 0)+1
    -- Where the burning turret stands (up to 2 per name), so the reader can find it.
    if cause_at then
      incident.friendly_at=incident.friendly_at or {}
      local list=incident.friendly_at[cause] or {}; incident.friendly_at[cause]=list
      local at=string.format('(%g,%g)',cause_at.x,cause_at.y)
      local known=false
      for _,v in ipairs(list) do if v==at then known=true end end
      if not known and #list<2 then list[#list+1]=at end
    end
  elseif cause then incident.causes[cause]=(incident.causes[cause] or 0)+1 end
end
local function losses_since(since)
  local out={}
  -- An incident without a last tick (shake11: status failed for 4 agents on 'compare number with nil') counts as old.
  for _,i in ipairs(state().losses or {}) do if (i.last or i.first or 0)>since then out[#out+1]=i end end
  table.sort(out,function(a,b) return (a.last or a.first or 0)>(b.last or b.first or 0) end)
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
-- An incident kept from before ids gets one when next read.
function LOSS.id(i)
  if not i.id then local s=state(); s.loss_ids=(s.loss_ids or 0)+1; i.id=s.loss_ids end
  return i.id
end
-- What an incident lost and what destroyed it, as text: names ("4 stone-wall, 3 gun-turret"), causes ("5 small-biter,
-- friendly fire: 2 flamethrower-turret at (80,90)": our own entities after the enemy ones), or nil.
function LOSS.parts(i)
  local names=counted(i.names)
  while #names>6 do table.remove(names) end
  local causes=counted(i.causes)
  while #causes>2 do table.remove(causes) end
  local friendly={}
  for _,v in ipairs(counted(i.friendly or {})) do
    local name=v:match('^%d+ (.+)$')
    local at=name and i.friendly_at and i.friendly_at[name]
    friendly[#friendly+1]=v..(at and #at>0 and ' at '..table.concat(at,' ') or '')
  end
  while #friendly>2 do table.remove(friendly) end
  if #friendly>0 then causes[#causes+1]='friendly fire: '..table.concat(friendly,', ') end
  return table.concat(names,', '),#causes>0 and table.concat(causes,', ') or nil
end
-- "#7 in (x,y)-(x,y) 40 destroyed: ..."; `reader` (a surface name) names an incident on another surface; without a
-- reader (an operator read) any surface but nauvis is named. `before` (the total the reader was told) marks a running total.
local function describe_incident(i,reader,before)
  local names,causes=LOSS.parts(i)
  local last=(i.last or i.first or 0)
  local span=i.first==last and ago(game.tick-last)..' ago' or ago(game.tick-i.first)..'-'..ago(game.tick-last)..' ago'
  local b=i.box
  local where=string.format('(%d,%d)',math.floor(b[1]),math.floor(b[2]))
  if b[3]-b[1]>=1 or b[4]-b[2]>=1 then where=where..'-'..string.format('(%d,%d)',math.floor(b[3]),math.floor(b[4])) end
  local on=''
  if i.platform then on=' on platform '..i.platform
  elseif i.surface and i.surface~=(reader or 'nauvis') then on=' on '..i.surface end
  return string.format('#%d%s in %s%s %d destroyed%s: %s%s, %s',LOSS.id(i),on,where,before and ' continue:' or '',i.total,
    before and string.format(' (+%d since you were told)',i.total-before) or '',names,
    causes and ' by '..causes or '',span)
end
-- status alerts.incidents: one row per loss incident for programs (the stream's loss banners and cuts): where (surface,
-- platform, box), how many, what, by what, when; the text line beside it.
function LOSS.row(i,reader)
  local names,causes=LOSS.parts(i)
  local b=i.box
  return {id=LOSS.id(i),surface=i.surface,platform=i.platform,box={x0=math.floor(b[1]),y0=math.floor(b[2]),x1=math.ceil(b[3]),y1=math.ceil(b[4])},
    total=i.total,names=names,by=causes,first_tick=i.first,last_tick=i.last or i.first,line=describe_incident(i,reader)}
end
-- Losses in the reply's team alerts: each incident once, then its running total at most once a game minute while it
-- grows. A reader never told anything starts with the incidents of the last 5 minutes. s.losses_told[index] holds
-- {id -> {tick, total}} for incidents still kept.
local function unseen_losses(p)
  local s=state()
  s.losses_told=s.losses_told or {}
  local told=s.losses_told[p.index]
  local new_reader=told==nil
  told=told or {}
  -- What a reader saw before ids (s.losses_seen, a loss_seq) counts as told.
  local seen=s.losses_seen and s.losses_seen[p.index]
  if s.losses_seen then s.losses_seen[p.index]=nil end
  local kept,due={},{}
  for _,i in ipairs(s.losses or {}) do
    local id=LOSS.id(i)
    local t=told[id]
    if not t and seen and (i.seq or 0)<=seen then t={tick=game.tick,total=i.total} end
    if t then
      kept[id]=t
      if i.total>t.total and game.tick-t.tick>=LOSS.again then due[#due+1]={i=i,before=t.total} end
    elseif not (new_reader and not seen and game.tick-(i.last or i.first or 0)>LOSS.first) then due[#due+1]={i=i}
    else kept[id]={tick=game.tick,total=i.total} end
  end
  s.losses_told[p.index]=kept
  if #due==0 then return nil end
  table.sort(due,function(a,b) return (a.i.last or 0)>(b.i.last or 0) end)
  local lines={}
  local reader=p.surface and p.surface.name
  for n,d in ipairs(due) do
    if n>4 then lines[#lines+1]=string.format('+%d more areas with losses; status alerts lists them',#due-4); break end
    lines[#lines+1]='losses '..describe_incident(d.i,reader,d.before)
    kept[d.i.id]={tick=game.tick,total=d.i.total}
  end
  return lines
end
local function recent_alerts(a,p)
  local since=a.since or game.tick-18000
  local reader=p and p.surface and p.surface.name
  local counts,latest,rows={},{},{}
  for _,i in ipairs(losses_since(since)) do
    for name,n in pairs(i.names) do counts[name]=(counts[name] or 0)+n end
    if #latest<8 then local row=LOSS.row(i,reader); latest[#latest+1]=row.line; rows[#rows+1]=row end
  end
  local attacks=threat.alerts(since,reader)
  local kills={}
  for _,k in ipairs(state().kills or {}) do if k.tick>since then kills[k.name]=(kills[k.name] or 0)+1 end end
  local okp,platform_hits=pcall(M.platalerts.rows,since)
  platform_hits=okp and platform_hits or nil
  if #latest==0 and not attacks and not next(kills) and not platform_hits then return nil end
  local result=attacks or {}
  if #latest>0 then result.losses=counts; result.latest=latest; result.incidents=rows end
  result.kills=next(kills) and kills or nil
  result.platform_hits=platform_hits
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
  -- What a wait polls for (fh --wait, several times a second): the action
  -- running and the last results, none of the factory, threat or alert scans.
  -- The stream's overlay adds alerts (stored incidents, no scan).
  if a.brief==true then
    return {brief=true,active=active(p.index),last=state().last and state().last[p.index] or false,combat=state().combat and state().combat[p.index] or false,
      last_combat=state().last_combat and state().last_combat[p.index] or false,alive=alive or false,riding=p.driving or nil,connected=p.connected,
      drop_pending=M.drop_pending(p.index),last_drop=M.last_drop(p.index),
      surface=alive and p.surface.name or nil,platform=alive and p.surface.platform and p.surface.platform.name or nil,
      alerts=a.alerts==true and recent_alerts(a,p) or nil,order=M.orders.brief(p.index),
      supported_control=controllable,control_error=not controllable and tostring(control_error) or nil,tick=game.tick,position=p.position}
  end
  assert(a.alerts==nil,'alerts is an option of brief (a full status always has them)')
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
    -- One check per force and surface every 10 s, shared (one slot made agents on two surfaces rescan every call).
    state().fluid_check=nil
    state().fluid_checks=state().fluid_checks or {}
    local fkey=p.force.name..'/'..p.surface.index
    local fc=state().fluid_checks[fkey]
    if not fc or game.tick-fc.tick>=600 then
      local ok,list,limit=pcall(pipes.overlong,p,3)
      fc={tick=game.tick,surface=p.surface.index,list=ok and list or {},limit=limit}
      state().fluid_checks[fkey]=fc
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
      local on=area.surface and area.surface~=p.surface.name and ' on '..area.surface or ''
      table.insert(factory.warnings,shown,string.format('under attack%s near (%g,%g): %s hit %d times%s, %s ago',on,area.chunk_centre.x,area.chunk_centre.y,
        area.entities,area.hits,area.by and ' by '..area.by or '',ago(game.tick-area.last_tick)))
    end
  end
  -- Items on the ground: full landing pads that spill, piles near our buildings (ground.lua, a pass every 30 s).
  local alerts=recent_alerts(a,p)
  local ground=alive and M.ground.alerts(p)
  if ground then alerts=alerts or {}; alerts.ground_items=ground end
  if now and now.stuck_s then
    factory.warnings=factory.warnings or {}
    table.insert(factory.warnings,1,string.format('character: %s made no progress and moved under 2 tiles for %ds near (%.1f,%.1f); likely physically stuck (belt, obstacle, unreachable goal): cancel or redirect it',
      now.kind,now.stuck_s,p.position.x,p.position.y))
  end
  return {crafting=alive and crafting_line(p) or nil,inv=factory.inv,factory=factory.factory,machines=factory.machines,machine_positions=factory.machine_positions,warnings=factory.warnings,factory_as_of=factory.as_of,survey_error=factory.error,
    evolution=threats.evolution,pollution=threats.pollution,enemies=threats.enemies,chart=threats.chart,threats_as_of=threats.as_of,
    alerts=alerts,runtime_fault=state().runtime_fault or false,connected=p.connected,alive=p.character and p.character.valid or false,cheat_mode=p.cheat_mode,
    supported_control=controllable,control_error=not controllable and tostring(control_error) or nil,active=now,order=M.orders.brief(p.index),
    spoiling=alive and spoil_text(main_inventory(p)) or nil,on_belt=alive and M.belt.note(p) or nil,teammates=M.where.team(p),
    trash=alive and M.trash.status(p) or nil,
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
-- A name filter the engine does not know ("Unknown entity name: tree",
-- shake4): list the entity names holding every dash-separated part of it
-- ("rock-huge" finds huge-rock), and say when it is an entity type.
function M.find_named(surface,filter)
  local ok,found=pcall(surface.find_entities_filtered,filter)
  if ok then return found end
  local bad=tostring(found):match('[Uu]nknown entity name:? *([%w%-_]+)')
  if not bad then error(found,0) end
  local parts,matches,is_type={},{},false
  for part in bad:lower():gmatch('[^%-_]+') do parts[#parts+1]=part end
  for name,proto in pairs(prototypes.entity) do
    if proto.type==bad then is_type=true end
    local all=true
    for _,part in ipairs(parts) do if not name:find(part,1,true) then all=false end end
    if all then matches[#matches+1]=name end
  end
  table.sort(matches)
  local shown={}
  for i=1,math.min(#matches,12) do shown[i]=matches[i] end
  error(bad..' is not an entity name'..(#matches>0 and '; matching names: '..table.concat(shown,', ')..(#matches>12 and ' ('..#matches..' in all)' or '') or '')
    ..(is_type and '; '..bad..' is an entity type: filter with type instead' or ''),0)
end
-- Cheap targeting: the nearest matches around the player or any charted
-- position, limited to what the player's map shows.
function handlers.nearest(p,a)
  assert(a.name or a.type,'name or type is required')
  for _,key in ipairs({'name','type'}) do
    local v=a[key]
    assert(v==nil or type(v)=='string' or (type(v)=='table' and #v>=1 and #v<=32),key..' must be a string or 1..32 strings')
  end
  local radius=integer(a.radius,32,1,128,'radius')
  local limit=integer(a.limit,5,1,64,'limit')
  local origin,rows=center(p,a),{}
  for _,e in pairs(M.find_named(p.surface,{position=origin,radius=radius,name=a.name,type=a.type})) do
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
  -- Only charted ground is searched. Just after landing on a new planet that
  -- is the ~48 tiles a character sees (live on sa: Vulcanus coal was 90 out).
  if #rows==0 then out.note='nothing map-known within '..radius..' tiles; only charted chunks count, and on a new planet that is about 48 tiles around you: walk out to explore (map shows what is charted), or build a radar' end
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
    if e.type~='inserter' and e.type~='mining-drill' then return nil end
    local function at(pos)
      local target=e.surface.find_entities_filtered{position=pos,limit=1,type={'resource','character','corpse','character-corpse','item-entity','item-request-proxy','sticker','fire','smoke-with-trigger','projectile','entity-ghost','tile-ghost'},invert=true}[1]
      return string.format('%g,%g',pos.x,pos.y)..(target and ' '..target.name or '')
    end
    -- A drill only drops (onto the ground when nothing is there).
    if e.type=='mining-drill' then return '-> '..at(e.drop_position) end
    -- An inserter: a side with no target says so (the engine's pickup and drop targets).
    local ok,pick,drop=pcall(function() return e.pickup_target,e.drop_target end)
    return at(e.pickup_position)..((ok and not pick) and ' (no pickup target)' or '')..' -> '..at(e.drop_position)..((ok and not drop) and ' (no drop target)' or '')
  end,
  -- Fluidboxes with contents and where each pipe connection leads.
  fluids=function(e) return pipes.fluids(e) end,
  -- Item filters (inserters, loaders): whitelist|blacklist: items, off, set by circuit; none without.
  filters=function(e)
    local ok,line=pcall(M.details.filters_line,e)
    if ok and line then return line end
    local slots=(pcall(function() return e.filter_slot_count end)) and e.filter_slot_count or 0
    return slots>0 and 'none' or nil
  end,
  target=function(e)
    local ok,t=pcall(function() return e.shooting_target end)
    return ok and t and t.valid and t.name..'@'..math.floor(t.position.x+0.5)..','..math.floor(t.position.y+0.5) or nil
  end,
}
-- Fields that change over time; hidden for other forces' entities under fog.
local live_fields={hp=true,fuel=true,inventory=true,output=true,spoil=true,status=true,ammo=true,target=true,amount=true,lanes=true,fluids=true,filters=true}
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
  -- "hp|fuel" or "hp,fuel" as one string, as describe's example reads (61% of
  -- unknown-field errors copied it whole): each name a field.
  local fields={}
  for _,v in ipairs(type(a.fields)=='string' and {a.fields} or a.fields or {}) do
    for f in tostring(v):gmatch('[^|,%s]+') do fields[#fields+1]=f end
  end
  for _,f in ipairs(fields) do assert(scan_fields[f],'unknown field '..tostring(f)..'; use hp|fuel|inventory|output|spoil|status|recipe|direction|amount|range|ammo|target|lanes|io|fluids|filters') end
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
      for _,e in pairs(M.find_named(p.surface,{position=pos,radius=0.3,name=a.name,type=a.type})) do
        if not seen[e] then seen[e]=true; candidates[#candidates+1]=e end
      end
    end
  else candidates=M.find_named(p.surface,{area=area,name=a.name,type=a.type}) end
  -- Items on the ground: a summary by item unless the caller filtered for
  -- them (a spill of thousands of stacks would push every building out).
  local ground={}
  for _,e in pairs(candidates) do
    if e.valid and e~=p.character and known(p,e) then
      if e.type=='resource' and a.ore then ores[#ores+1]=e end
      if e.type=='item-entity' and not filtered then ground[#ground+1]=e
      elseif e.type~='resource' or filtered then rows[#rows+1]=e end
    end
  end
  out.ground_items=M.ground.summary(ground)
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
    -- An inserter or loader with item filters in use says so unasked (Sonnet 06:20: stale filters blocked a line).
    if row.filters==nil and e.force==p.force and (e.type=='inserter' or e.type=='loader' or e.type=='loader-1x1') then
      local ok,line=pcall(M.details.filters_line,e)
      row.filters=ok and line or nil
    end
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
for _,name in ipairs({'requests','platform_create','platform_schedule','launch','land','drop'}) do
  handlers[name]=function(p,a) return space[name](p,a) end
end
-- A launch an agent ordered is the silo read's last launch (silo.lua), with who ordered it.
handlers.launch=function(p,a)
  local out=space.launch(p,a)
  pcall(function()
    local silo=remote_entity(p,{position=a.position,name=a.name,unit_number=a.unit_number})
    if out.launched then M.silo.record(silo,{by=M.board.who(p),to=out.to,cargo=type(out.cargo)=='string' and out.cargo or nil}) end
    -- The silo's switches as they stand after the call (auto_requests set, or a launch).
    out.settings=M.silo.settings(silo)
  end)
  return out
end
local views={map=true,nearest=true,craftable=true,scan=true,power=true,grid=true,rates=true,bottleneck=true,stock=true,platforms=true,labs=true,science=true,supply=true,sleep_check=true}
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
  local candidates=M.find_named(p.surface,{position=origin, radius=radius,type=a.entity_types,name=a.entity_names})
  table.sort(candidates,function(x,y)
    local dx,dy=distance(origin,x.position),distance(origin,y.position)
    if dx ~= dy then return dx < dy end
    if x.position.x ~= y.position.x then return x.position.x < y.position.x end
    if x.position.y ~= y.position.y then return x.position.y < y.position.y end
    return x.name < y.name
  end)
  local resources,ground={},{}
  local unfiltered=not (a.entity_types or a.entity_names)
  for _, e in ipairs(candidates) do
    if distance(origin,e.position)<=radius and known(p,e) then
      if e.type=='resource' and mode~='tiles' then
        if mode=='summary' then resources[#resources+1]=e end
      elseif e.type=='item-entity' and unfiltered then ground[#ground+1]=e
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
  out.ground_items=M.ground.summary(ground)
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
-- Engine pathfinding for the character's walks (pathing.lua): a ladder of
-- requests (padded box, a belt-free variant, the character's own box on the
-- tile, half- and quarter-tile grids) whose results arrive through
-- on_script_path_request_finished; until then the character waits in place.
-- When no level finds a route the walk ends as unreachable with why and the
-- nearest reachable point. The shared path cache is skipped: it can hand back
-- routes planned for other units.
M.pathing=require('pathing'){paths=function() state().paths=state().paths or {}; return state().paths end,
  accept=function(p,nav,path,avoided) return M.avoid.accept(p,nav,path,avoided) end}
request_path=function(p,nav) return M.pathing.request(p,nav) end
-- Walks and drives around the enemy worms and spawners the map shows (avoid.lua): a
-- found path through one's reach becomes legs around it, each leg the engine's path.
M.avoid=require('avoid'){state=state,
  charted=function(force,surface,chunk) local pl=surface.platform if pl and pl.force==force then return true end return force.is_chunk_charted(surface,chunk) end,
  adopt=function(p,nav,path,avoided) if nav.vehicle then return M.vehicles.use(p,nav,path) end return M.pathing.use(p,nav,path,avoided) end,
  leg=function(p,nav)
    if not M.avoid.next_leg(p,nav) then return false end
    nav.path_level=0; nav.stalls=0; nav.stalled=0; nav.replans=0; nav.approach=nil
    if nav.vehicle then M.vehicles.request(p,nav) else request_path(p,nav) end
    return true
  end}
-- via: points walked in order before position in one call (Opus, operator
-- 06:26: worm detours took 5-6 chained move_tos a trip). Each leg is a walk of
-- its own, pathfound and checked for enemies as a single move_to; a via point
-- counts as reached within VIA_WITHIN tiles (or the walk's tolerance when
-- larger); a leg that does not arrive ends the walk with its outcome.
M.VIA_MAX,M.VIA_WITHIN=16,1
function M.via_points(p,list,target)
  assert(type(list)=='table' and #list>=1 and #list<=M.VIA_MAX,'via takes 1..'..M.VIA_MAX..' points {x,y}, walked in order before position')
  local points,from={},p.position
  for i,raw in ipairs(list) do
    local q=position(raw)
    assert(distance(from,q)<=512,string.format('via point %d (%g,%g) must be within 512 tiles of the point before it',i,q.x,q.y))
    points[i]=q; from=q
  end
  assert(distance(from,target)<=512,'position must be within 512 tiles of the last via point')
  return points
end
-- The fields a leg's walk sets (navigate, pathing.lua, avoid.lua): cleared for the next leg.
M.LEG_FIELDS={'found','path_state','foes','why','escape','escape_stalled','escape_still','probe_id','probe_kind','probe_radius','path_level',
  'waypoints','waypoint','reachable','dig_from','dig_area','avoid_id','sidestep','reach','paths_failed','path_id','leg','escapes',
  'escape_first','blind','avoided','asked_tick','asked_from','stalled','stalls','replans','region','progress_tick','progress_gap',
  'progress_mark','path_length','escaped_to','dig','approach','no_progress','off_belt','pocket','retry_tick','step_off','step_off_tick',
  'previous_position','spot','trail_still','squeezed','search','squeeze_tried'}
-- Leg i's goal: via point i, then the walk's position.
function M.via_leg(p,action,i)
  local v=action.via
  v.index=i; v.leg_tick=game.tick
  local final=i>#v.points
  action.position=final and v.final or v.points[i]
  action.tolerance=final and v.tolerance or math.max(M.VIA_WITHIN,v.tolerance)
  -- A move_to never ends on a belt; a via point is passed, so only the last leg steps off one.
  action.off_belts=final or nil
end
-- One leg's line in last.legs: where to, how it ended, how long, why not, what it went around.
function M.via_record(action,outcome)
  local v=action.via
  local goal=action.foes and action.foes.goal or action.position
  local r={to={x=math.floor(goal.x*10+0.5)/10,y=math.floor(goal.y*10+0.5)/10},outcome=outcome,s=math.floor((game.tick-(v.leg_tick or game.tick))/6+0.5)/10}
  if action.foes then
    local t={}
    M.avoid.report(t,action)
    r.avoided_enemies=t.avoided_enemies; r.passed_within_margin=t.passed_within_margin
  end
  if outcome~='arrived' and outcome~='arrived_near' then r.why=action.why end
  v.legs[#v.legs+1]=r
end
-- A leg ended: the next one starts (true), or the walk ends with this outcome.
function M.via_next(p,action,outcome,index)
  local v=action.via
  M.via_record(action,outcome)
  if not (outcome=='arrived' or outcome=='arrived_near') or v.index>#v.points then return false end
  -- A queue step restarted after a pause resumes from the next via point (scheduler.lua).
  local q=(state().queues or {})[index]
  if q and q.current and q.current.args==v.args then q.current.via_done=v.index end
  for _,k in ipairs(M.LEG_FIELDS) do action[k]=nil end
  M.via_leg(p,action,v.index+1)
  if not action.direct then M.avoid.start(p,action,v.mode); request_path(p,action) end
  return true
end
-- last.legs: each leg walked, then the ones not walked.
function M.via_report(action)
  local v=action.via
  local legs={}
  for i,r in ipairs(v.legs) do legs[i]=r end
  for i=#v.legs+1,#v.points+1 do
    local goal=i>#v.points and v.final or v.points[i]
    legs[i]={to={x=goal.x,y=goal.y},outcome='not walked'}
  end
  return legs
end
function handlers.move_to(p,a)
  local target=position(a.position)
  local via=a.via~=nil and M.via_points(p,a.via,target) or nil
  if not via then assert(distance(p.position,target)<=512,'movement target must be within 512 tiles') end
  local ticks=integer(a.ticks,3600,1,36000,'ticks')
  -- `within` reads naturally for "stop once in reach"; both mean the same.
  local tolerance=a.within or a.tolerance or 0.5
  assert(type(tolerance)=='number' and tolerance>=0.25 and tolerance<=10,'tolerance/within out of range 0.25..10')
  if state().active[p.index] then finish(p.index,'replaced') else stop(p) end
  assert(a.squeeze==nil or type(a.squeeze)=='boolean','squeeze must be true or false')
  local action={kind='move_to',position=target,tolerance=tolerance,off_belts=true,
    until_tick=game.tick+ticks,last_position=p.position,stalled=0,replans=0,direct=a.pathfind==false,pocket_check=true,squeeze=a.squeeze==true or nil}
  if via then
    action.via={points=via,final=target,tolerance=tolerance,legs={},mode=M.avoid.mode(a.avoid_enemies),args=a}
    M.via_leg(p,action,1)
  end
  -- combat: the combat channel fires at enemies in range for the walk (as
  -- shoot auto), so a walk into an attacked area shoots back (request #57).
  local combat
  if a.combat~=nil and a.combat~=false then
    local radius=a.combat==true and 20 or integer(a.combat,20,1,32,'combat radius')
    local equipped=kite.ammo_count(p)==0 and kite.auto_equip(p) or nil
    local ammo=kite.ammo_count(p)
    assert(ammo>0,'combat needs ammunition in the ammo slots and none is carried that fits a gun: craft firearm-magazine')
    state().combat=state().combat or {}
    combat_targets()[p.index]=nil
    state().combat[p.index]={until_tick=game.tick+ticks,auto=true,radius=radius,ammo_start=ammo,with_move=true}
    combat={auto=true,radius=radius,ammo=ammo,equipped=equipped}
  end
  state().active[p.index]=action
  local foes
  if not action.direct then foes=M.avoid.start(p,action,M.avoid.mode(a.avoid_enemies)); request_path(p,action) end
  return {until_tick=game.tick+ticks,position=target,pathfinding=not action.direct,combat=combat,avoid_enemies=foes and M.avoid.describe(foes.mode) or nil,
    via=via and #via or nil,legs=via and #via+1 or nil}
end
-- Hand-mining time for the character, including force and character bonuses.
local function hand_mining_ticks(p,e)
  local c=p.character
  local speed=c.prototype.mining_speed*(1+(c.character_mining_speed_modifier or 0)+(p.force.manual_mining_speed_modifier or 0))
  return math.max(1,math.ceil(e.prototype.mineable_properties.mining_time*60/speed))
end
-- A mined-out resource tile (Grok 03:20: a repeating mine step stalled its loop three times on one stone patch):
-- the resource this position held (name=, or remembered from an earlier mine there) is looked up within radius
-- (default 8) of it, a tile in reach first, else the nearest to the character. Positions remembered per agent.
-- A block: its helpers take no top-level local slots (tests/locals.lua).
do
local MINE_MEMORY=64
local function mine_key(pos) return string.format('%g,%g',pos.x,pos.y) end
local function remember_mined(p,pos,e)
  local s=state()
  s.mined_at=s.mined_at or {}
  local m=s.mined_at[p.index] or {order={},name={}}
  s.mined_at[p.index]=m
  local key=mine_key(pos)
  if m.name[key]==nil then
    m.order[#m.order+1]=key
    if #m.order>MINE_MEMORY then m.name[table.remove(m.order,1)]=nil end
  end
  m.name[key]=e.name
end
local function next_tile(p,a,pos)
  local m=(state().mined_at or {})[p.index]
  local name=a.name or (m and m.name[mine_key(pos)])
  local proto=name and prototypes.entity[name]
  if not (proto and proto.type=='resource') then return nil end
  local radius=integer(a.radius,8,1,32,'radius')
  local best,best_reach,best_d
  for _,e in pairs(p.surface.find_entities_filtered{position=pos,radius=radius,name=name,type='resource'}) do
    if e.valid and visible(p,e.position) then
      local reach=p.can_reach_entity(e)
      local d=distance(p.position,e.position)
      if not best or (reach and not best_reach) or (reach==best_reach and d<best_d) then best,best_reach,best_d=e,reach,d end
    end
  end
  return best,name,radius
end
function handlers.mine(p,a)
  local found,e=pcall(entity,p,a)
  local instead
  if not found then
    if not tostring(e):match('^entity not found at') then error(e,0) end
    local pos=position(a.position)
    local tile,name,radius=next_tile(p,a,pos)
    if not tile then
      if name then error(string.format('%s at (%g,%g) is mined out and no %s is left within %d tiles of it',name,pos.x,pos.y,name,radius),0) end
      error(e,0)
    end
    local gone=string.format('%s at (%g,%g) is mined out',name,pos.x,pos.y)
    if not p.can_reach_entity(tile) then
      error(string.format('%s; the nearest %s within %d tiles is out of reach: %s',gone,name,radius,M.out_of_reach(p,tile)),0)
    end
    instead={mined_out={x=pos.x,y=pos.y},name=name,position=tile.position,
      line=string.format('%s; mining %s at (%g,%g), %.1f tiles from it',gone,name,tile.position.x,tile.position.y,distance(pos,tile.position))}
    e=tile
  end
  friendly(p,e)
  assert(e.minable,'entity is not mineable')
  -- Space Age: some ores are not hand-mineable (tungsten-ore is hard-solid,
  -- big mining drills only). Ore is taken through mine_entity, which would
  -- not check, so check the character's resource categories here.
  local hand=e.type=='resource' and p.character and p.character.prototype.resource_categories
  local category=hand and e.prototype.resource_category
  assert(not category or hand[category],e.name..' is '..tostring(category)..': a character cannot mine it by hand (a drill that mines '..tostring(category)..' can)')
  local ticks=integer(a.ticks,60,1,MAX_TICKS,'ticks')
  if state().active[p.index] then finish(p.index,'replaced') else stop(p) end
  local action={kind='mine',entity=e,until_tick=game.tick+ticks,products={},started=game.tick}
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
    -- The step's position names this resource from now on, also once its tile is gone.
    remember_mined(p,position(a.position),e)
    if instead then remember_mined(p,e.position,e) end
  else
    -- Buildings, trees, rocks and corpses need the entity selected, and the
    -- connected client's cursor hover overwrites selection every tick (the
    -- selection box flashes). Take exactly the hand-mining time instead and
    -- then mine through the engine, which applies normal products and space checks.
    action.done_tick=game.tick+hand_mining_ticks(p,e)
    -- A shorter duration could only ever expire unfinished.
    action.until_tick=math.max(action.until_tick,action.done_tick)
  end
  action.instead=instead
  state().active[p.index]=action
  -- LuaEntity cannot be serialized to JSON; only tick is returned (and the tile taken for a mined-out one).
  return {until_tick=action.until_tick,instead=instead}
end
end
-- Items on the ground within the character's pickup distance. shake5: a bot's
-- pickup returned ok and the plate stayed (a bot's character does not pick up
-- by itself), so the tick takes them and last reports what it took.
function handlers.pickup(p,a)
  if a.area~=nil or a.radius~=nil or a.position~=nil or a.items~=nil then return M.ground.pickup(p,a) end
  local ticks=integer(a.ticks,30,1,MAX_TICKS,'ticks')
  local c=p.character
  local reach=c and c.valid and c.prototype and c.prototype.item_pickup_distance or 1
  local near=p.surface.find_entities_filtered{position=p.position,radius=reach,type='item-entity',limit=1}[1]
  assert(near,string.format('nothing to pick up within %g tiles of (%.1f,%.1f): stand on or next to the item (observe lists item-on-ground)',reach,p.position.x,p.position.y))
  if state().active[p.index] then finish(p.index,'replaced') else stop(p) end
  state().active[p.index]={kind='pickup',until_tick=game.tick+ticks,reach=reach}
  return {until_tick=game.tick+ticks}
end
-- Repair (Astra 03:42: a patrol of repair steps logged 2481 "entity does not need repair" errors in a shift, which
-- hid the real failures). An undamaged target is a success: unchanged, last nothing_to_do, no repair tool needed.
-- positions or area: every damaged entity among them in one timed action, nearest first, walking to each, counted
-- as repaired against already full. A damaged target with no repair tool held still fails.
-- A block: its helpers take no top-level local slots (tests/locals.lua).
do
local MAX_REPAIR=64
local function damaged(e)
  local ok,hurt=pcall(function() return e.health~=nil and e.max_health~=nil and e.health<e.max_health end)
  return ok and hurt
end
local function has_health(e)
  local ok,yes=pcall(function() return e.health~=nil and (e.max_health or 0)>0 end)
  return ok and yes
end
-- Puts a repair tool in the cursor (from the inventory); true when it was borrowed.
local function hold_tool(p,a,why)
  if p.cursor_stack.valid_for_read then
    assert(p.cursor_stack.prototype.type=='repair-tool','cursor must hold a repair tool')
    return false
  end
  local tool=p.get_main_inventory().find_item_stack(a.item or 'repair-pack')
  assert(tool and tool.prototype.type=='repair-tool','no repair tool in inventory'..(why or ''))
  assert(p.cursor_stack.swap_stack(tool),'cannot hold repair tool')
  return true
end
-- Nothing to repair: the reply, and the last a finished action leaves (a --wait and a queue step see nothing_to_do).
local function unchanged(p,out)
  out.unchanged='not damaged'
  local s=state(); s.last=s.last or {}
  s.last[p.index]={kind='repair',outcome='nothing_to_do',tick=game.tick,unchanged=out.unchanged,already_full=out.already_full}
  return out
end
-- A list action's next target: the current one counts as repaired (worked on and now full), already full (full
-- before it was reached), or lost (gone).
function M.repair_next(p,action)
  local e=action.entity
  if e and not e.valid then action.lost=action.lost+1
  elseif e and action.working then action.repaired=action.repaired+1
  elseif e then action.already_full=action.already_full+1 end
  action.index=action.index+1; action.entity=action.targets[action.index]; action.working=nil; action.nav=nil
  if not M.bots.is(p) then p.repair_state={repairing=false,position=p.position} end
end
function M.repair_done(e) return not (e and e.valid) or not damaged(e) end
local function repair_list(p,a)
  assert(a.position==nil and a.radius==nil,'give position, positions or area: one of them')
  assert(a.positions==nil or a.area==nil,'give positions or area, not both')
  local found,errors={},{}
  if a.area~=nil then
    assert(type(a.area)=='table' and a.area.left_top and a.area.right_bottom,'area requires left_top and right_bottom')
    local lt,rb=position(a.area.left_top),position(a.area.right_bottom)
    assert(lt.x<rb.x and lt.y<rb.y and rb.x-lt.x<=128 and rb.y-lt.y<=128,'area must be nonempty and at most 128x128')
    for _,e in pairs(p.surface.find_entities_filtered{area={left_top=lt,right_bottom=rb},force=p.force}) do
      if e.valid and e.type~='character' and has_health(e) then found[#found+1]=e end
    end
    assert(#found>0,string.format('no entity of ours with health in (%g,%g)-(%g,%g)',lt.x,lt.y,rb.x,rb.y))
  else
    assert(type(a.positions)=='table' and #a.positions>=1 and #a.positions<=MAX_REPAIR,'positions requires 1..'..MAX_REPAIR..' entries')
    for _,pos in ipairs(a.positions) do
      local ok,e=pcall(function()
        local t=entity(p,{position=pos,name=type(pos)=='table' and pos.name or nil,unit_number=type(pos)=='table' and pos.unit_number or nil},true)
        friendly(p,t)
        return t
      end)
      if ok then found[#found+1]=e else errors[#errors+1]=reason(e) end
    end
  end
  local todo,full={},0
  for _,e in ipairs(found) do if damaged(e) then todo[#todo+1]=e else full=full+1 end end
  local out={targets=#found,damaged=#todo,already_full=full,failed=#errors>0 and #errors or nil,first_error=errors[1]}
  if #todo==0 then
    assert(#found>0,errors[1] or 'no target')
    return unchanged(p,out)
  end
  assert(#todo<=MAX_REPAIR,string.format('%d damaged entities; at most %d (a smaller area)',#todo,MAX_REPAIR))
  table.sort(todo,function(x,y) return distance(p.position,x.position)<distance(p.position,y.position) end)
  local ticks=integer(a.ticks,3600,1,36000,'ticks')
  -- A missing tool fails before the running action is touched.
  if not p.cursor_stack.valid_for_read then
    local tool=p.get_main_inventory().find_item_stack(a.item or 'repair-pack')
    assert(tool and tool.prototype.type=='repair-tool',string.format('no repair tool in inventory (%d of %d targets damaged)',#todo,#found))
  end
  if state().active[p.index] then finish(p.index,'replaced') else stop(p) end
  local borrowed=hold_tool(p,a)
  state().active[p.index]={kind='repair',entity=todo[1],targets=todo,index=1,repaired=0,already_full=full,lost=0,unreached=0,
    borrowed_cursor=borrowed or M.bots.is(p),until_tick=game.tick+ticks}
  out.until_tick=game.tick+ticks
  return out
end
function handlers.repair(p,a)
  assert(a.platform==nil and not (p.surface and p.surface.platform),'repair cannot reach a space platform: '..(space and space.REPAIR_NOTE or ''))
  if a.positions~=nil or a.area~=nil then return repair_list(p,a) end
  -- Seen first (health shows on hover), then reached: an undamaged target out of reach is unchanged too.
  local e=entity(p,a,true); friendly(p,e)
  assert(has_health(e),e.name..' has no health to repair')
  if not damaged(e) then return unchanged(p,{name=e.name,position=e.position,health=e.health}) end
  if not p.can_reach_entity(e) then error(M.out_of_reach(p,e),0) end
  local ticks=integer(a.ticks,60,1,MAX_TICKS,'ticks')
  if state().active[p.index] then finish(p.index,'replaced') else stop(p) end
  local borrowed=hold_tool(p,a)
  -- A bot's cursor is invisible to it: always put the tool back afterwards.
  state().active[p.index]={kind='repair',entity=e,borrowed_cursor=borrowed or M.bots.is(p),until_tick=game.tick+ticks}
  return {until_tick=game.tick+ticks}
end
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
  -- Say why a machine-only recipe fails (shake3: Grok's engine-unit read
  -- "not hand-craftable now" with force and the ingredients held).
  local r,categories=p.force.recipes[recipe],p.character and p.character.prototype.crafting_categories
  if categories and not takes(categories,r) then
    error(string.format('%s (category %s) cannot be hand-crafted by a character; an assembling machine can make it (configure recipe=%s, then feed it)',recipe,r.category or 'crafting',recipe),0)
  end
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
-- clears them, where a direct build cannot. Items on the ground: pick them up.
-- A refused build (near) revives a ghost of the same entity on the same
-- centre, so that ghost is never what blocks it (Sol, shift09 01:38: five
-- pole ghosts on Gleba wetland read "placement blocked by ghost
-- medium-electric-pole" at their own positions; the tiles refused them).
local function placement_error(p,proto,pos,direction,near)
 local function blockers()
  local b=proto.collision_box or {left_top={x=-0.4,y=-0.4},right_bottom={x=0.4,y=0.4}}
  local l,t,r,btm=b.left_top.x,b.left_top.y,b.right_bottom.x,b.right_bottom.y
  if direction==4 or direction==12 then l,t,r,btm=-btm,l,-t,r end
  local area={left_top={x=pos.x+l,y=pos.y+t},right_bottom={x=pos.x+r,y=pos.y+btm}}
  local found,character,items={},false,false
  local trees,rocks,cliffs=0,0,0
  for _,e in pairs(p.surface.find_entities_filtered{area=area,limit=16}) do
    if e.valid and e.type=='character' and e==p.character then character=true
    elseif e.valid and e.type=='character' and #found<4 then
      -- Someone else stands there: say who, so the agent can ask them.
      local who=M.character_owner(e)
      found[#found+1]=string.format('%s standing at (%.1f,%.1f) (ask them to move, or build elsewhere)',who and who..'\'s character' or 'another character',e.position.x,e.position.y)
    elseif near and e.valid and e.type=='entity-ghost' and e.ghost_name==proto.name
      and math.abs(e.position.x-pos.x)<0.01 and math.abs(e.position.y-pos.y)<0.01 then
      -- the ghost this build revives
    elseif near and e.valid and e.type=='tile-ghost' then
      -- a tile ordered under it: the tile there now decides
    elseif e.valid and e.type~='resource' and #found<4 then
      local name=e.type=='entity-ghost' and 'ghost '..e.ghost_name or e.type=='tile-ghost' and 'tile ghost '..e.ghost_name or e.name
      -- An item on the ground (shake4: Grok's 9 tries at one spot): say which.
      if e.type=='item-entity' then items=true; name=name..(e.stack and e.stack.valid_for_read and ' ('..e.stack.name..')' or '') end
      if e.type=='tree' or e.type=='plant' then trees=trees+1 elseif e.type=='simple-entity' then rocks=rocks+1 elseif e.type=='cliff' then cliffs=cliffs+1 end
      found[#found+1]=string.format('%s (%g,%g)',name,e.position.x,e.position.y)
    end
  end
  if character then found[#found+1]='the character standing on the footprint (move off it first)' end
  if #found>0 then
    -- Trees and rocks need mining first (Sol, shift09: say so with the names
    -- and positions, also when a build that waited for a craft hits them).
    local what=trees>0 and rocks>0 and 'the trees and rocks' or trees>1 and 'the trees' or trees==1 and 'the tree'
      or rocks>1 and 'the rocks' or rocks==1 and 'the rock' or nil
    local them=trees+rocks>1 and 'them' or 'it'
    return ' by '..table.concat(found,', ')
      ..(what and string.format('; it needs %s mined first (mine %s, or place_ghosts marks %s and construct clears %s)',what,them,them,them) or '')
      ..(cliffs>0 and '; cliff explosives clear a cliff (a character cannot mine one)' or '')
      ..(items and '; a build takes items on the ground into your inventory, and this one did not fit: free a slot (or stand next to it and fh call pickup)' or '')
  end
  -- Tile buildability rules (asteroid collectors: rear rows on foundation, the
  -- front in empty space): the broken one; with rules, they judge the tiles.
  local rule,ruled=M.placewhy.tile_rules(p.surface,proto,pos,direction)
  if rule then return ': '..rule end
  -- Tiles it cannot stand on (its collision mask against each tile: water,
  -- wetland, lava, space), with the tile item that makes them buildable;
  -- else water, space and lava under it.
  local tiles,items={},{}
  local ok_fix,fixes=pcall(function() return not ruled and M.dryrun and M.dryrun.tile_fixes(p.surface,p.force,proto,pos,direction) end)
  for _,f in ipairs(ok_fix and fixes or {}) do
    if not tiles[f.tile] then tiles[f.tile]=true; tiles[#tiles+1]=f.tile end
    local item=f.item or f.locked
    if item and not items[item] then items[item]=true; items[#items+1]=item end
  end
  for _,tile in pairs(#tiles==0 and not ruled and p.surface.find_tiles_filtered{area=area,limit=16} or {}) do
    local mask=tile.prototype.collision_mask
    local layers=mask and mask.layers or {}
    if (layers.water_tile or layers.empty_space or layers.lava_tile) and not tiles[tile.name] then tiles[tile.name]=true; tiles[#tiles+1]=tile.name end
  end
  if #tiles>0 then
    return ' by tiles: '..table.concat(tiles,', ')..' (needs '..(#items>0 and table.concat(items,' or ') or 'landfill')
      ..', or a shore position: scan fields=fluids / grid ~ marks water)'
  end
  return ' (nothing found in the footprint: check the position is a valid centre for a '..(proto.name or 'entity')..' and the direction)'
 end
 local ok,extra=pcall(blockers)
 local text='placement blocked'..(ok and extra or '')
 -- A refused build (near): an offshore pump, or water under the footprint,
 -- lists the nearest valid placements (shore.lua).
 if near and M.shore then
  local water=ok and extra and extra:find(' by tiles: ',1,true)~=nil
  local fine,hint=pcall(M.shore.hint,p,proto,pos,direction,water)
  if fine and hint then text=text..hint end
 end
 return text
end
local function build_direct(p,stack,pos,direction,quality,kind,place)
  local proto,surface=place or stack.prototype.place_result,p.surface
  -- A rail planner's curve takes 3 rails and a half-diagonal 2, as the game
  -- charges them (items_to_place_this); everything else here takes one.
  local need=1
  for _,it in ipairs(proto.items_to_place_this or {}) do if it.name==stack.name then need=it.count or 1 end end
  if need>1 then
    local held=p.get_main_inventory().get_item_count{name=stack.name,quality=quality}
    assert(held>=need,string.format('%s takes %d %s; you hold %d',proto.name,need,stack.name,held))
  end
  construction.clear_remnants(surface,proto,pos,direction)
  -- Items on the ground in the footprint go into the inventory, as a player's
  -- build takes them (shake5: Grok's six builds over one iron plate). One
  -- that does not fit stays, and the placement error says so.
  local picked
  for _,it in pairs(surface.find_entities_filtered{area=construction.box(proto,pos,direction),type='item-entity'}) do
    if it.valid and it.type=='item-entity' and it.stack and it.stack.valid_for_read then
      local name,count=it.stack.name,it.stack.count
      local n=p.insert{name=name,count=count,quality=it.stack.quality and it.stack.quality.name or nil}
      if n>0 then
        picked=picked or {}; picked[name]=(picked[name] or 0)+n
        if n>=count then it.destroy() else it.stack.count=count-n end
      end
    end
  end
  local ghost=surface.find_entities_filtered{position=pos,radius=0.1,ghost_name=proto.name,force=p.force,limit=1}[1]
  local e,replaced,plan,hold
  if ghost then
    local _,revived=ghost.revive{raise_revive=true}
    e=revived
  else
    local args={name=proto.name,position=pos,direction=direction,force=p.force,build_check_type=defines.build_check_type.manual}
    if not surface.can_place_entity(args) then error(placement_error(p,proto,pos,direction,true),0) end
    -- The manual check allows a fast-replace, which create_entity without
    -- fast_replace does not do: both machines stayed on the tiles (shake5:
    -- assembling-machine-2 over -1, the old one kept running; request #68).
    -- A machine of the same group on the same centre is replaced as a
    -- player's build does: a chest's contents into the new chest as far as
    -- it holds them, the rest and the old one into the inventory, all or
    -- nothing (replace.lua); its recipe set on the new one. Any other
    -- overlap is refused.
    local group=proto.fast_replaceable_group
    if group then
      local cb=proto.collision_box or {left_top={x=-0.4,y=-0.4},right_bottom={x=0.4,y=0.4}}
      local l,t,r,btm=cb.left_top.x,cb.left_top.y,cb.right_bottom.x,cb.right_bottom.y
      if direction==4 or direction==12 then l,t,r,btm=-btm,l,-t,r end
      for _,o in pairs(surface.find_entities_filtered{area={left_top={x=pos.x+l,y=pos.y+t},right_bottom={x=pos.x+r,y=pos.y+btm}},force=p.force}) do
        if o.valid and o.type~='entity-ghost' and o.prototype and o.prototype.fast_replaceable_group==group then
          local ob=o.prototype.collision_box
          local same=math.abs(o.position.x-pos.x)<0.01 and math.abs(o.position.y-pos.y)<0.01 and ob
            and math.abs((ob.right_bottom.x-ob.left_top.x)-(cb.right_bottom.x-cb.left_top.x))<0.01
            and math.abs((ob.right_bottom.y-ob.left_top.y)-(cb.right_bottom.y-cb.left_top.y))<0.01
          if not same then
            error(string.format('placement blocked by %s (%g,%g) already on these tiles, not on the same centre: mine it first (mine at its position), then build',
              o.name,o.position.x,o.position.y),0)
          end
          assert(o.name~=proto.name,'target already contains this entity')
          local ok,recipe,rq=pcall(function() if o.get_recipe then return o.get_recipe() end end)
          local old={name=o.name,recipe=ok and recipe and recipe.name or nil,recipe_quality=ok and rq and rq.name or nil}
          plan=M.replace.plan(p,o,proto,quality,(need==1 and stack.count==1) and 1 or 0)
          if plan.error then error(plan.error,0) end
          hold=M.replace.take(o,plan)
          assert(hold,string.format('cannot replace %s (%g,%g): the game did not remove it; nothing moved',old.name,pos.x,pos.y))
          replaced=old
          break
        end
      end
    end
    args.quality=quality; args.player=real(p); args.raise_built=true
    if proto.type=='underground-belt' then args.type=kind or underground_type(surface,proto,pos,direction) end
    e=surface.create_entity(args)
  end
  if not e then
    -- The replaced entity's items go to the character after all.
    if hold then M.replace.give(p,nil,hold,{item={},kept={},keep=false,any=plan.any}) end
    error(placement_error(p,proto,pos,direction,true),0)
  end
  if need>1 then p.get_main_inventory().remove{name=stack.name,count=need,quality=quality}
  elseif stack.count>1 then stack.count=stack.count-1 else stack.clear() end
  if hold then replaced.contents=M.replace.give(p,e,hold,plan) end
  -- The replaced machine's recipe goes on the new one when it can make it.
  if replaced and replaced.recipe and e.set_recipe then
    local ok=pcall(e.set_recipe,replaced.recipe,replaced.recipe_quality)
    replaced.recipe_kept=ok or nil
  end
  return e,picked,replaced,need
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
-- An inserter has no engine targets in the tick it is built or turned (they
-- come a tick later; checked on 2.0.77): read what stands on its points instead.
local function built_summary(e)
  local out=summary(e); out.status_name=nil
  if e.type=='inserter' and M.targets then
    local ok,t=pcall(M.targets.plan,e.surface,e.prototype,e.position,e.direction)
    out.io_warning=ok and t and t.missing or nil
  end
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
  -- A turret out of reach: the refusal lists valid spots within reach toward it (shore.lua).
  local reached,far=pcall(build_reach,p,pos,'position')
  if not reached then
    local fine,hint=pcall(M.shore.reach_hint,p,a.item,pos)
    error(tostring(far)..(fine and hint or ''),0)
  end
  assert(type(a.item)=='string','item is required')
  local stack=p.get_main_inventory().find_item_stack{name=a.item,quality=a.quality or 'normal'}
  assert(stack,'item is not in main inventory')
  if stack.prototype.place_as_tile_result then return build_tile(p,a,stack,pos) end
  -- A rail planner (2.0: the rail item) places one of its rails, named by
  -- entity (default the first, straight-rail), directly at the position.
  local place,planner=stack.prototype.place_result,nil
  local ok_rails,rails=pcall(function() return stack.prototype.rails end)
  if ok_rails and type(rails)=='table' and #rails>0 then
    planner={}
    for _,r in ipairs(rails) do planner[#planner+1]=type(r)=='string' and r or r.name end
    local want=a.entity or planner[1]
    place=nil
    for _,n in ipairs(planner) do if n==want then place=prototypes.entity[n] end end
    assert(place,a.item..' places '..table.concat(planner,', ')..'; entity names which')
  else
    assert(a.entity==nil or (place and place.name==a.entity),'entity: '..a.item..' places '..tostring(place and place.name))
  end
  assert(place and place.type ~= 'rail-ramp','only ordinary entity placement is supported')
  -- Cursor building borrows the cursor; direct placement leaves it alone.
  -- While the game is tick-paused (turn mode between actions) the engine
  -- refuses every cursor build ("placement blocked" on clear ground), so
  -- place directly then, as in map view.
  local direct=in_map_view(p) or M.bots.is(p) or place.type=='underground-belt' or planner~=nil or game.tick_paused==true
  assert(direct or not p.cursor_stack.valid_for_read,'cursor must be empty; clear it in the client first')
  if place.type=='transport-belt' then
    pos={x=math.floor(pos.x)+0.5,y=math.floor(pos.y)+0.5}
    build_reach(p,pos,'snapped position')
  end
  local direction=directions[a.direction or 'north']; assert(direction,'invalid direction')
  local filter={position=pos,radius=2,name=place.name,limit=64}
  local existing={}
  for _,e in pairs(p.surface.find_entities_filtered(filter)) do
    -- Native cursor placement can rotate an existing belt without consuming an
    -- item. A build request must not silently change an occupied crossing.
    if e.valid and e.name==place.name and distance(e.position,pos)<0.1
      and (e.quality and e.quality.name or 'normal')==(a.quality or 'normal') then
      error('target already contains this entity; use rotate explicitly or an underground crossing')
    end
    existing[e.unit_number or (e.name..'@'..e.position.x..','..e.position.y)]=true
  end
  local proto=place
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
    local e,picked,replaced,need=build_direct(p,stack,pos,direction,a.quality or 'normal',a.type,place)
    local joined=e.type=='electric-pole' and bridge_pole(e) or 0
    return {consumed=need,entity=built_summary(e),networks_joined=joined>0 and joined or nil,picked_up=picked,replaced=replaced},{e}
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
    if not p.can_build_from_cursor{position=pos,direction=direction,build_mode=defines.build_mode.normal} then
      error(placement_error(p,proto,pos,direction,true),0)
    end
    p.build_from_cursor{position=pos,direction=direction,build_mode=defines.build_mode.normal}
  end)
  local restored=not p.cursor_stack.valid_for_read or
    (not stack.valid_for_read and p.cursor_stack.swap_stack(stack)) or p.clear_cursor()
  assert(restored,'build finished but could not restore cursor; items remain in cursor')
  assert(ok,err)
  local after=held()
  local placed,joined,ents={},nil,{}
  if before>after then
    for _,e in pairs(p.surface.find_entities_filtered(filter)) do
      if e.valid and not existing[e.unit_number or (e.name..'@'..e.position.x..','..e.position.y)] then
        placed[#placed+1]=built_summary(e); ents[#ents+1]=e
        if e.type=='electric-pole' then joined=(joined or 0)+bridge_pole(e) end
      end
    end
  end
  return {consumed=before-after,entity=#placed==1 and placed[1] or nil,entities=#placed>1 and placed or nil,
    networks_joined=joined and joined>0 and joined or nil},ents
end
-- After a hand build: what it just built closed the character in where it
-- stands (Gemini, shift09: a placement trapped the character in a closed
-- box), with the entities that each filled the last gap out (pathing.lua).
function M.closed_in_note(p,built)
  if #built==0 then return nil end
  local c=p.character
  if not (c and c.valid) or c.vehicle then return nil end
  local half=M.pathing.half(c)
  local ok,res=pcall(M.pathing.closed_by,p.surface,p.position,half,built,{ignore=c,force=p.force})
  if not (ok and res) then return nil end
  local list={}
  for _,e in ipairs(res.gaps) do if #list<6 then list[#list+1]=string.format('%s (%g,%g)',e.name,e.position.x,e.position.y) end end
  local here=p.position
  local what=#list==1 and 'the last gap out was where '..list[1]..' now stands'
    or #list>1 and 'without any one of '..table.concat(list,', ')..(#built>#list and string.format(' (of %d built now)',#built) or '')..' a gap out would stay'
    or 'what this build placed closes it'
  return string.format('the character is closed in now where it stands (%g,%g): %s; %s',math.floor(here.x*10+0.5)/10,math.floor(here.y*10+0.5)/10,
    what,M.pathing.area_text(res.region,half))
end
-- After a build or a ghost placement: logistic chests that no roboport's logistic area covers (networks.lua;
-- Sonnet, shift10: 8 chests with 31k copper sat outside roboport range for hours) and underground entrances fed
-- from the side by what was built (sidefeed.lua; Sol, shift10: long nutrient starvation). Lists or nil.
function M.build_notes(p,ents)
  local cover,side,seen={},{},{}
  local platform=own_platform(p)
  for _,e in ipairs(ents or {}) do
    if e.valid then
      local ghost=e.type=='entity-ghost'
      local t=ghost and e.ghost_type or e.type
      if t=='logistic-container' and not platform and M.networks and #cover<16 then
        local ok,line=pcall(M.networks.coverage,e.surface,e.force,e.position)
        if ok and line then cover[#cover+1]=string.format('%s (%g,%g): %s',ghost and e.ghost_name or e.name,e.position.x,e.position.y,line) end
      end
      if not ghost then
        local ok,lines=pcall(M.sidefeed.built,e)
        for _,l in ipairs(ok and lines or {}) do if not seen[l] and #side<8 then seen[l]=true; side[#side+1]=l end end
      end
    end
  end
  return #cover>0 and cover or nil,#side>0 and side or nil
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
    local r,ents=build_one(p,a)
    if not r.aside then
      r.closed_in=M.closed_in_note(p,ents or {})
      r.outside_logistic_coverage,r.underground_side_feed=M.build_notes(p,ents)
      return r
    end
    local rest={}
    for k,v in pairs(a) do rest[k]=v end
    return step_aside(r.aside,rest)
  end
  assert(type(a.builds)=='table' and #a.builds>=1 and #a.builds<=64,'builds requires 1..64 {item,position,direction} entries')
  assert(a.skip_failed==nil or type(a.skip_failed)=='boolean','skip_failed must be true or false')
  local placed,failed,inserters,built={},{},{},{}
  for _,f in ipairs(a.failed_before or {}) do failed[#failed+1]=f end
  for _,e in ipairs(a.built_ents or {}) do built[#built+1]=e end
  for i,b in ipairs(a.builds) do
    local ok,result,ents=pcall(function()
      assert(type(b)=='table','each build must be an object')
      local r,ents=build_one(p,{item=b.item or a.item,position=b.position,direction=b.direction or a.direction,quality=b.quality or a.quality,type=b.type,size=b.size or a.size,
        entity=b.entity or a.entity,stepped=a.stepped and i==1})
      assert(r.aside or r.consumed>0,'nothing was placed')
      return r,ents
    end)
    for _,e in ipairs(ok and ents or {}) do built[#built+1]=e end
    -- A partial batch is a failure, so plan on_fail policies see it; the
    -- entries before it stay built. skip_failed (shake3: Grok and Astra
    -- wanted the rest built) lists the entry and goes on.
    if not ok and a.skip_failed then
      failed[#failed+1]={index=i+(a.index_before or 0),position=type(b)=='table' and b.position or nil,error=reason(result)}
    elseif not ok then error(string.format('build %d/%d failed after %d built: %s',i,#a.builds,#placed,reason(result)))
    elseif result.aside then
      local rest={builds={}}
      for k,v in pairs(a) do if k~='builds' then rest[k]=v end end
      for j=i,#a.builds do rest.builds[#rest.builds+1]=a.builds[j] end
      rest.built_before=(a.built_before or 0)+#placed
      rest.index_before=(a.index_before or 0)+i-1
      rest.failed_before=#failed>0 and failed or nil
      rest.built_ents=#built>0 and built or nil
      local out=step_aside(result.aside,rest)
      out.built=#placed; out.placed=#placed>0 and placed or nil; out.failed=#failed>0 and failed or nil
      return out
    else
      local e=result.entity or (result.entities and result.entities[1])
      placed[#placed+1]=e and e.position or b.position
      -- (summary gives an inserter's pickup tile, and only an inserter's)
      if e and e.pickup~=nil then inserters[#inserters+1]=e.position end
    end
  end
  -- The batch's inserters with nothing on a pickup or drop point once all
  -- its entries stand (a chest built after its inserter counts; targets.lua):
  -- the first 16, and the count of all past them, as place_ghosts gives them.
  local loose,nloose
  for _,pos in ipairs(inserters) do
    local e=p.surface.find_entities_filtered{position=pos,type='inserter',limit=1}[1]
    local ok,t=pcall(function() return e and M.targets.plan(e.surface,e.prototype,e.position,e.direction) end)
    if ok and t and t.missing then
      loose=loose or {}; nloose=(nloose or 0)+1
      if #loose<16 then loose[#loose+1]={name=e.name,position=e.position,missing=t.missing,pickup=t.pickup,drop=t.drop} end
    end
  end
  local cover,side=M.build_notes(p,built)
  return {built=#placed,placed=placed,built_before=a.built_before,failed=#failed>0 and failed or nil,inserters_without_target=loose,
    inserters_without_target_count=nloose and nloose>#loose and nloose or nil,
    closed_in=M.closed_in_note(p,built),outside_logistic_coverage=cover,underground_side_feed=side}
end
-- Red, green and copper wires, as a player drags them (circuits.lua).
function handlers.wire(p,a) return M.circuits.wire(p,a) end
function handlers.build_path(p,a)
  assert(not p.permission_group or p.permission_group.allows_action(defines.input_action.start_walking),'permission denied: start_walking')
  local action=construction.plan(p,a)
  action.bounds=M.cell_bounds(action.cells,function(c) return c.position end)
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
  return {until_tick=action.until_tick,ammo=action.ammo_start,equipped=action.equipped}
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
  action.bounds={left=box.left_top.x,top=box.left_top.y,right=box.right_bottom.x,bottom=box.right_bottom.y}
  if state().active[p.index] then finish(p.index,'replaced') else stop(p) end
  state().active[p.index]=action
  -- Nothing to do is done: plans continue rather than pausing on an error.
  if #action.pending==0 then finish(p.index,'nothing_to_do'); return {total=0,built=0,outcome='nothing_to_do'} end
  return {until_tick=action.until_tick,total=#action.pending}
end
function handlers.inspect(p,a)
  local e,by=entity(p,a,true)
  local out=summary(e); out.inventories={}
  out.by=by
  -- A bot aboard a platform has no body to reach with (remote view only).
  local okr,inr=pcall(function() return p.can_reach_entity(e) end)
  out.in_reach=okr and inr==true
  out.health=e.health; out.max_health=e.max_health; out.direction=e.direction
  -- The engine's status number and its defines.entity_status name beside it (Muse, shift10: --format json gave 14, 26,
  -- 27 to look up); an entity no pole reaches says so in power ("unpowered: ...") while the engine reads low_power.
  out.status=e.status
  out.status_name=entity_status_names[out.status]
  out.energy=e.energy
  out.fluids=e.get_fluid_contents()
  out.electric_network_id=e.electric_network_id
  -- Inserters: the exact pickup/drop points, the tiles they are on, and what
  -- stands there (the same view as scan fields=io).
  if e.type=='inserter' or e.type=='mining-drill' then
    out.pickup_position=e.type=='inserter' and e.pickup_position or nil
    local okd,drop=pcall(function() return e.drop_position end)
    out.drop_position=okd and drop or nil
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
  -- A ghost with a recipe: the ports that recipe opens, each with its fluid
  -- (ports.lua), in place of every port the prototype has.
  if e.type=='entity-ghost' then
    local okp,rows,closed,recipe=pcall(function()
      local okr,r=pcall(function() return e.get_recipe() end)
      r=okr and r or nil
      local list,shut=M.ports.rows({prototype=e.ghost_prototype,position=e.position,direction=e.direction,mirroring=e.mirroring},r)
      return list,shut,r
    end)
    if okp and recipe and (#rows>0 or #closed>0) then
      out.fluid_connections=#rows>0 and rows or nil; out.fluids_summary=nil
      out.fluid_connections_closed=#closed>0 and closed or nil; out.fluid_recipe=recipe.name
    end
  end
  if e.type=='transport-belt' or e.type=='underground-belt' or e.type=='splitter' then
    out.belt_lines={}
    for i=1,e.get_max_transport_line_index() do out.belt_lines[i]=e.get_transport_line(i).get_contents() end
  end
  -- Spoilage (spoil.lua): per inventory each spoilable item, its first stack
  -- to spoil (time left, % spoiled) and how many within 5 min; a belt's lanes,
  -- an inserter's hand and an item on the ground too; items that hatch into
  -- enemies say so, and hatch_warning sums them up.
  local spoiling,all={},{}
  for name in pairs(inventories) do
    local ok,inv=pcall(inventory,e,name)
    if ok then
      out.inventories[name]=contents(inv)
      local acc=M.spoil.inventory(inv,{},name)
      for _,line in ipairs(M.spoil.lines(acc,8,name..': ')) do spoiling[#spoiling+1]=line end
      M.spoil.inventory(inv,all,name)
    end
  end
  do
    local acc={}
    if e.type=='transport-belt' or e.type=='underground-belt' or e.type=='splitter' or e.type=='loader' or e.type=='loader-1x1' or e.type=='linked-belt' then M.spoil.belt(e,acc,'belt')
    elseif e.type=='inserter' then M.spoil.add(acc,e.held_stack,'hand')
    elseif e.type=='item-entity' then M.spoil.add(acc,e.stack,'ground') end
    for _,r in ipairs(acc) do all[#all+1]=r; all[r.key]=all[r.key] or r end
    for _,line in ipairs(M.spoil.lines(acc,8,(acc[1] and acc[1].where or '')..': ')) do spoiling[#spoiling+1]=line end
  end
  if #spoiling>0 then out.spoiling=spoiling end
  out.hatch_warning=M.spoil.warning(all)
  -- What its next products start at: the inherited spoilage (spoil.lua).
  if e.type=='assembling-machine' or e.type=='furnace' then
    local okr,line=pcall(M.spoil.recipe_output,e)
    out.output_spoil=okr and line or nil
  end
  -- An agricultural tower: state, seeds, output, its cells and plants (farm.lua).
  if e.type=='agricultural-tower' then
    local okt,tower=pcall(M.farm.tower,e,{status_name=function(x) return entity_status_names[x.status] end,
      flow=function(item) return M.farm_flow(p,e.surface,item) end})
    out.tower=okt and tower or nil
  end
  if e.type=='rocket-silo' and space then
    local okw,weight=pcall(space.rocket_weight,e)
    out.rocket_weight=okw and weight or nil
  end
  -- Module slots and their inventory index (blueprint item requests name it).
  local okm,mods=pcall(function()
    local inv=e.get_module_inventory()
    return inv and {inventory_index=inv.index,slots=#inv,contents=contents(inv)}
  end)
  out.modules=okm and mods or nil
  -- Filters, held stack, pickup/drop targets, marks, ghosts on the footprint
  -- (details.lua); on a platform, the hub's slots and what holds up its building.
  if M.details then M.details.inspect(e,out) end
  -- An inserter ghost: what stands on its pickup and drop points, as a
  -- built one would have them (targets.lua).
  if e.type=='entity-ghost' and e.ghost_type=='inserter' then
    local okt,t=pcall(M.targets.ghost,e)
    if okt and t then out.pickup_target=t.pickup; out.drop_target=t.drop; out.io_warning=t.missing end
  end
  -- Circuit network: settings, each wire's far end, the signals now (circuits.lua).
  if M.circuits then local okc,c=pcall(M.circuits.read,e); if okc and c then out.circuit=c end end
  -- A roboport or logistic chest: its logistic network's id, areas and robots, or that it has none; a roboport's own cell (networks.lua).
  if M.networks and (e.type=='roboport' or e.type=='logistic-container') then
    local okn,ln=pcall(M.networks.of_entity,e); if okn and ln then out.logistic_network=ln end
  end
  local okp,pl=pcall(function() return e.surface.platform end)
  if okp and pl and space then
    if e.type=='space-platform-hub' then
      out.hub_slots=space.hub_slots(e)
      -- The platform's flight: speed, the leg and the km left on it, minutes at this speed, the next stop.
      local okf,flight=pcall(space.flight,pl)
      out.flight=okf and flight or nil
      local okr,repair=pcall(space.repair_view,pl)
      if okr then out.repair_packs,out.damaged,out.damaged_count=repair.repair_packs,repair.damaged,repair.damaged_count end
    end
    if e.health and e.max_health and e.health<e.max_health then out.repair=space.REPAIR_NOTE end
    if e.type=='space-platform-hub' or e.type=='entity-ghost' or e.type=='tile-ghost' or out.marked_for_deconstruction or out.ghosts_here then
      local okb,blocked=pcall(space.blockers,pl)
      out.construction_blocked=okb and blocked or nil
    end
  end
  -- Trash slots: one line naming what is there and how to take it.
  for name,list in pairs(out.inventories) do
    if name:find('_trash$') and #list>0 then
      local parts={}
      for i,s in ipairs(list) do parts[i]=s.count..' '..s.name..(s.quality and s.quality~='normal' and '@'..s.quality or '') end
      out.trash=table.concat(parts,', ')..' (in '..name..', put there by the game; take: transfer {position, direction=to_player, inventory='..name..'}, item= for one kind)'
    end
  end
  if e.type=='assembling-machine' or e.type=='furnace' then
    local recipe=e.get_recipe(); out.recipe=recipe and recipe.name or false
    out.crafting_progress=e.crafting_progress
    local okf,fill=pcall(M.output_fill,e)
    out.output_fill=okf and fill or nil
  end
  return out
end
-- How full an assembler's or furnace's output is (Muse: which of the machines fed by hand wait on their output): each
-- product held of its stack size, and full when the machine has stopped for it (status full_output), as the
-- machine GUI's output slot and status show: "copper-cable 180/200 (90%), full".
function M.output_fill(e)
  local inv=e.get_output_inventory and e.get_output_inventory()
  if not inv then return nil end
  local parts={}
  for i=1,#inv do
    local s=inv[i]
    if s.valid_for_read then
      local size=(s.prototype and s.prototype.stack_size) or (prototypes.item[s.name] and prototypes.item[s.name].stack_size) or 1
      parts[#parts+1]=string.format('%s %d/%d (%d%%)',s.name,s.count,size,math.floor(s.count*100/size+0.5))
    end
  end
  local status=defines.entity_status and defines.entity_status.full_output
  local full=status~=nil and e.status==status
  if #parts==0 then return full and 'empty, full' or 'empty' end
  return table.concat(parts,', ')..(full and ', full' or '')
end
-- inspect over positions (Muse surveys 6 assemblers every 5 minutes, one call each): one inspect per entry, in order;
-- an entry that fails is its position and error. Each entry may carry name or unit_number.
-- inspect over an area (Gemini, shift10: dozens of single inspects to check buffer chests' balances): our entities
-- with an inventory whose centre is in the area and that inspect can read (in sight, or by remote view in a chunk
-- our force sees now: read_sight), at most 64, one compact row each (name, position, holds, requests, recipe,
-- status_name), in reading order (top row first, then left to right).
do
  local inspect_one=handlers.inspect
  local MAX_SIDE,MAX_ROWS=128,64
  local AREA_TYPES={'container','logistic-container','linked-container','assembling-machine','furnace','lab','rocket-silo',
    'boiler','burner-generator','reactor','mining-drill','ammo-turret','artillery-turret','cargo-wagon','car','spider-vehicle',
    'cargo-landing-pad','roboport','agricultural-tower','space-platform-hub','asteroid-collector'}
  local STORES={'chest','cargo_wagon','car_trunk','spider_trunk','cargo_landing_pad_main','hub_main'}
  -- A machine's inventories as its GUI groups them, each with a short label.
  local PARTS={{'furnace_source','in'},{'assembling_machine_input','in'},{'lab_input','packs'},{'agricultural_tower_input','seeds'},
    {'furnace_result','out'},{'assembling_machine_output','out'},{'agricultural_tower_output','out'},{'asteroid_collector_output','out'},
    {'rocket_silo_rocket','cargo'},{'turret_ammo','ammo'},{'artillery_turret_ammo','ammo'},{'fuel','fuel'},{'burnt_result','burnt'},
    {'roboport_robot','robots'},{'roboport_material','repair packs'}}
  local CHESTS={container=true,['logistic-container']=true,['linked-container']=true}
  local function row(e)
    local r={name=e.name,position=e.position}
    -- A chest, wagon, trunk, landing pad or hub: holds as inspect writes it (details.lua), and a requester's asks.
    local held={inventories={}}
    for _,name in ipairs(STORES) do
      local ok,inv=pcall(inventory,e,name)
      if ok then held.inventories[name]=contents(inv) end
    end
    pcall(M.details.holds,e,held)
    r.holds=held.holds; r.requests=held.requests
    if not r.holds then
      local parts={}
      for _,part in ipairs(PARTS) do
        local ok,inv=pcall(inventory,e,part[1])
        if ok and not inv.is_empty() then
          local items={}
          for _,st in ipairs(inv.get_contents()) do
            local q=type(st.quality)=='table' and st.quality.name or st.quality
            items[#items+1]=st.name..(q and q~='normal' and '@'..q or '')..'*'..st.count
          end
          parts[#parts+1]=part[2]..': '..table.concat(items,' ')
        end
      end
      r.holds=#parts>0 and table.concat(parts,'; ') or 'empty'
    end
    if e.type=='assembling-machine' or e.type=='furnace' then
      local ok,recipe=pcall(e.get_recipe)
      r.recipe=ok and recipe and recipe.name or nil
    end
    if not CHESTS[e.type] then r.status_name=entity_status_names[e.status] end
    return r
  end
  local function area_rows(p,a)
    assert(a.positions==nil and a.position==nil,'give area, positions or position: one of them')
    assert(type(a.area)=='table' and a.area.left_top and a.area.right_bottom,'area requires left_top and right_bottom')
    local lt,rb=position(a.area.left_top),position(a.area.right_bottom)
    assert(lt.x<rb.x and lt.y<rb.y and rb.x-lt.x<=MAX_SIDE and rb.y-lt.y<=MAX_SIDE,'area must be nonempty and at most '..MAX_SIDE..'x'..MAX_SIDE)
    local types=a.types
    if types~=nil then assert(type(types)=='table' and #types>=1 and #types<=16,'types requires 1..16 entity types') else types=AREA_TYPES end
    local found,unseen={},0
    for _,e in pairs(p.surface.find_entities_filtered{area={left_top=lt,right_bottom=rb},force=p.force,type=types}) do
      local at=e.valid and e.position
      if at and at.x>=lt.x and at.x<=rb.x and at.y>=lt.y and at.y<=rb.y then
        if pcall(M.read_sight,p,at,'entity') then found[#found+1]=e else unseen=unseen+1 end
      end
    end
    local what=types==AREA_TYPES and 'chest or machine' or table.concat(types,', ',1,math.min(#types,6))..(#types>6 and ', ...' or '')
    assert(#found>0,string.format('no %s of ours with its centre in (%g,%g)-(%g,%g) in a chunk our force sees now%s',what,lt.x,lt.y,rb.x,rb.y,
      unseen>0 and string.format(' (%d in chunks it does not: radar coverage or a character\'s sight lights a chunk)',unseen) or ''))
    assert(#found<=MAX_ROWS,string.format('%d entities in the area; at most %d (a smaller area, or types)',#found,MAX_ROWS))
    table.sort(found,function(x,y)
      if x.position.y~=y.position.y then return x.position.y<y.position.y end
      return x.position.x<y.position.x
    end)
    local rows={}
    for i,e in ipairs(found) do rows[i]=row(e) end
    return {entities=rows,count=#rows,
      not_in_sight=unseen>0 and string.format('%d more in the area in chunks our force does not see now (radar coverage or a character\'s sight lights a chunk)',unseen) or nil}
  end
  function handlers.inspect(p,a)
    if a.area~=nil then return area_rows(p,a) end
    assert(a.types==nil,'types goes with area')
    if a.positions==nil then return inspect_one(p,a) end
    assert(type(a.positions)=='table' and #a.positions>=1 and #a.positions<=32,'positions requires 1..32 entries')
    assert(a.position==nil,'give position or positions, not both')
    local out={}
    for i,pos in ipairs(a.positions) do
      local args={}
      for k,v in pairs(a) do if k~='positions' then args[k]=v end end
      args.position=pos
      if type(pos)=='table' then args.name=pos.name or a.name; args.unit_number=pos.unit_number or a.unit_number end
      local ok,r=pcall(inspect_one,p,args)
      out[i]=ok and r or {position=pos,error=reason(r)}
    end
    return {entities=out,count=#out}
  end
end
-- Rotate as the R key does: one 90-degree turn clockwise per call (reverse=true counter-clockwise), or with direction,
-- turns until it faces that way. The reply names the facing before and after (Grok 01:51, "rotate turns a belt 180
-- degrees": its belts got two calls each, north to east to south, while the reply showed no facing).
function handlers.rotate(p,a)
  local e=entity(p,a); friendly(p,e)
  local names={}
  for n,d in pairs(directions) do names[d]=n end
  local function name(d) return d and (names[d] or tostring(d)) or nil end
  local target
  if a.direction~=nil then
    target=type(a.direction)=='number' and a.direction or directions[a.direction]
    assert(type(target)=='number' and target%1==0 and target>=0 and target<16,'direction must be a compass name (north, east, south, west) or 0..15')
    assert(a.reverse==nil,'give direction or reverse, not both')
  end
  local before=e.direction
  local turns=0
  if target==nil then
    if e.rotate{reverse=a.reverse==true,by_player=real(p)} then turns=1 end
  elseif before~=target then
    -- The shorter way round: clockwise up to 180 degrees, else counter-clockwise.
    local back=(target-before)%16>8
    for _=1,4 do
      if not e.rotate{reverse=back,by_player=real(p)} then break end
      turns=turns+1
      if e.direction==target then break end
    end
    assert(e.direction==target,string.format('%s at (%g,%g) faces %s after %d turn%s from %s; rotating does not bring it to %s',
      e.name,e.position.x,e.position.y,name(e.direction),turns,turns==1 and '' or 's',name(before),name(target)))
  end
  -- Rotating an underground flips its end (and its partner's): show the result.
  -- As after a build: a turned inserter's engine targets come a tick later.
  return {rotated=turns>0,before=name(before),after=name(e.direction),turns=turns,
    note=target~=nil and turns==0 and 'it faces '..name(target)..' already' or nil,entity=built_summary(e)}
end
-- Changing a recipe works as it does for a player: machine contents and the
-- ingredients of an interrupted craft go to the inventory, spilling at the
-- character's feet when it is full. Fluids are lost, so that needs force.
-- Item filters, as a player sets them in an inserter's (or loader's) GUI.
local function configure_filters(e,a)
  assert(a.recipe==nil,'give recipe or filters, not both')
  -- A collector's slot count reads 0 before its first filter (details.lua).
  if e.type=='asteroid-collector' then
    assert(type(a.filters)=='table','filters requires asteroid chunk names ([] clears)')
    return M.details.configure_collector(e,a)
  end
  local slots=e.filter_slot_count or 0
  assert(slots>0,e.name..' has no filter slots')
  -- One name is a list of one; filter_mode or use_filters alone keep the items (Sonnet 06:20: stale filters).
  local list=type(a.filters)=='string' and {a.filters} or a.filters
  assert(list==nil or (type(list)=='table' and #list<=slots),'filters requires 0..'..slots..' item names')
  for _,name in ipairs(list or {}) do assert(prototypes.item[name],'unknown item '..tostring(name)) end
  local inserter=e.type=='inserter'
  assert(a.use_filters==nil or (inserter and type(a.use_filters)=='boolean'),'use_filters is true or false, on an inserter')
  local before=M.details.filters_line(e) or 'none'
  if a.filter_mode~=nil then
    assert(a.filter_mode=='whitelist' or a.filter_mode=='blacklist','filter_mode is whitelist or blacklist')
    assert(inserter,'filter_mode applies to inserters')
    e.inserter_filter_mode=a.filter_mode
  end
  if list then
    for i=1,slots do e.set_filter(i,list[i]) end
    if inserter then e.use_filters=#list>0 end
  end
  if a.use_filters~=nil then e.use_filters=a.use_filters end
  local now=M.details.filters(e) or {filters={}}
  return {filters=now.filters,filter_mode=now.filter_mode,use_filters=now.use_filters,line=M.details.filters_line(e) or 'none',before=before}
end
M.configure_filters=configure_filters
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
    -- On another surface (surface=) the remote view's reason is the one that applies.
    if not ok then error(type(p)=='table' and rawget(p,'__remote') and far or e,0) end
    e=far
  end
  friendly(p,e)
  -- A rocket silo's GUI checkboxes, in reach or by remote view on any planet (Astra 01:41: a silo on Vulcanus with
  -- automatic requests off held up a ferry): automatic requests and send to orbit automatically, read back after.
  if e.type=='rocket-silo' then
    assert(a.recipe==nil and a.filters==nil,'a rocket silo takes auto_requests and send_to_orbit_automatically (its recipe is fixed)')
    assert(a.auto_requests~=nil or a.send_to_orbit_automatically~=nil,'a rocket silo takes auto_requests and send_to_orbit_automatically (true or false)')
    assert(a.send_to_orbit_automatically==nil or type(a.send_to_orbit_automatically)=='boolean','send_to_orbit_automatically must be true or false')
    local out={}
    if a.auto_requests~=nil then
      out=space.launch(p,{position=e.position,unit_number=e.unit_number,auto_requests=a.auto_requests})
      out.auto_requests=nil
    end
    if a.send_to_orbit_automatically~=nil then e.send_to_orbit_automatically=a.send_to_orbit_automatically end
    out.settings=M.silo.settings(e); out.remote=not near or nil
    return out
  end
  if a.filters~=nil or (a.recipe==nil and (a.filter_mode~=nil or a.use_filters~=nil)) then return configure_filters(e,a) end
  assert(e.type=='assembling-machine','only assembling machines support recipe configuration')
  local recipe=type(a.recipe)=='string' and p.force.recipes[a.recipe]
  assert(recipe and recipe.enabled,'recipe is unavailable')
  assert(e.prototype.crafting_categories[recipe.category],'recipe incompatible with machine')
  local current,current_quality=e.get_recipe()
  local same_quality=(a.quality or 'normal')==((current_quality and current_quality.name) or 'normal')
  if current and current.name==recipe.name and same_quality then return {recipe=recipe.name,quality=a.quality,unchanged=true} end
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
  return {recipe=current.name,quality=a.quality,remote=not near or nil,returned=next(returned) and returned or nil,spilled=next(spilled) and spilled or nil}
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
      -- Trash slots come first when they hold something; never as a fallback.
      elseif name:find('_trash$') then
        if a.item and inv.get_item_count{name=a.item,quality=a.quality or 'normal'}>0 or not a.item and not inv.is_empty() then return name,inv end
      elseif not a.item or inv.get_item_count{name=a.item,quality=a.quality or 'normal'}>0 then return name,inv
      else fallback=fallback or {name,inv} end
    end
  end
  assert(fallback,'entity has no transferable inventory')
  return fallback[1],fallback[2]
end
-- Moves matching stacks with transfer_stack so item metadata travels intact.
local function move_stacks(source,target,match,limit)
  -- remaining never goes below 0: the engine refuses an amount under 1
  -- ("Given amount value(-1) too small", request #69, a queue transfer with
  -- keep and up_to near the cap), so every call is skipped at 0.
  local remaining,moved,order=math.max(0,limit),{},{}
  for i=1,#source do
    if remaining<=0 then break end
    local stack=source[i]
    if stack.valid_for_read and match(stack) then
      local key,name,quality,start=stack.name..'@'..stack.quality.name,stack.name,stack.quality.name,stack.count
      -- Top up partial stacks of the same item first, as a player's
      -- shift-click does, then fill empty slots.
      for pass=1,2 do
        for j=1,#target do
          if remaining<=0 or not stack.valid_for_read then break end
          local slot=target[j]
          if (pass==1)==(slot.valid_for_read and slot.name==name and slot.quality.name==quality) then
            local before=stack.count
            slot.transfer_stack(stack,math.min(before,remaining))
            remaining=math.max(0,remaining-(before-(stack.valid_for_read and stack.count or 0)))
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
  local stacks,total={},0
  for i,key in ipairs(order) do stacks[i]=moved[key]; total=total+moved[key].count end
  return total,stacks
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
  if e then if not p.can_reach_entity(e) then error(M.out_of_reach(p,e),0) end
  else e=entity(p,{position=pos,name=pos.name or a.name,unit_number=pos.unit_number or a.unit_number}) end
  friendly(p,e)
  local inferred,target
  assert(not (a.direction=='to_entity' and type(a.inventory)=='string' and a.inventory:find('_trash$')),tostring(a.inventory)..' is take-only (direction=to_player)')
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
  -- Personal logistics (Astra, 01:53: two hauls lost to auto-trash): what a
  -- take puts over the character's request max goes to trash. up_to=true
  -- stops at the max; keep_max=true refuses such a take (trash.lua).
  local lim=a.direction=='to_player' and (a.partial or a.keep_max) and M.trash.limits(p) or nil
  local held_back,caps
  if a.item then
    match=function(s) return s.name==a.item and s.quality.name==quality end
    -- Taking an item defaults to all of it; giving defaults to one.
    wanted=integer(a.count,a.direction=='to_player' and 10000 or 1,1,10000,'count')
    if a.keep~=nil then wanted=math.min(wanted,math.max(0,available()-integer(a.keep,0,0,100000,'keep'))) end
    if a.up_to~=nil then wanted=math.min(wanted,math.max(0,integer(a.up_to,1,1,100000,'up_to')-count(target))) end
    local room=lim and M.trash.room(p,a.item,quality,lim)
    if room then
      local take=math.min(wanted,available())
      if a.keep_max then
        assert(take<=room,string.format('keep_max: nothing taken; %d %s would put you %d over your request max (%d): the game trashes what is over it',
          take,a.item,take-room,M.trash.cap(lim,a.item,quality)))
      elseif take>room then held_back={[a.item]={take-room,M.trash.cap(lim,a.item,quality)}}; wanted=room end
    end
  else
    match=function() return true end
    wanted=integer(a.count,1000000,1,1000000,'count')
    -- Taking everything: per item, what fits under the request max.
    if lim then
      local over={}
      for _,source in ipairs(sources) do
        for _,st in ipairs(source.get_contents()) do
          local room=M.trash.room(p,st.name,st.quality,lim)
          if room and st.count>room then over[#over+1]={name=st.name,quality=st.quality,count=st.count,room=room} end
        end
      end
      if #over>0 and a.keep_max then
        local o=over[1]
        error(string.format('keep_max: nothing taken; %d %s would put you %d over your request max (%d): the game trashes what is over it',
          o.count,o.name,o.count-o.room,M.trash.cap(lim,o.name,o.quality)),0)
      end
      if #over>0 then
        caps={}
        for _,o in ipairs(over) do
          caps[o.name..'@'..(o.quality or 'normal')]=o.room
          held_back=held_back or {}; held_back[o.name]={o.count-o.room,M.trash.cap(lim,o.name,o.quality)}
        end
      end
    end
  end
  if a.budget then wanted=math.min(wanted,a.budget.left) end
  -- A rocket lifts 1000 kg: the game takes more by script and then refuses
  -- the launch, so only what fits goes in (shift04 07:17, 1060 kg aboard).
  local rocket=a.item and a.direction=='to_entity' and (a.inventory or inferred)=='rocket_silo_rocket' and e.type=='rocket-silo' and space and {}
  if rocket then
    local room,load=space.rocket_room(e,a.item)
    assert(room>0 or wanted==0,'the rocket is full by weight ('..load.weight..' of its lift): no '..a.item..' ('..load.each..' each) fits; launch it, or take cargo out (transfer direction=to_player inventory=rocket_silo_rocket)')
    if room<wanted then
      rocket.limited={requested=wanted,fits=room,note=string.format('a rocket lifts %s: %d of %d %s (%s each) fit',load.weight:match('/(.*)$'),room,wanted,a.item,load.each)}
      wanted=room
    end
  end
  local moved,stacks,order=0,{},{}
  local function add(part)
    for _,st in ipairs(part) do
      local key=st.name..'@'..(st.quality or 'normal')
      if order[key] then order[key].count=order[key].count+st.count else order[key]=st; stacks[#stacks+1]=st end
    end
  end
  for _,source in ipairs(sources) do
    if moved>=wanted then break end
    if caps then
      -- Item by item, those over the request max only up to it.
      local kinds={}
      for _,st in ipairs(source.get_contents()) do kinds[#kinds+1]=st end
      for _,st in ipairs(kinds) do
        if moved>=wanted then break end
        local k=st.name..'@'..(st.quality or 'normal')
        local limit=math.min(wanted-moved,caps[k] or math.huge)
        if limit>0 then
          local n,part=move_stacks(source,target,function(s) return s.name==st.name and s.quality.name==(st.quality or 'normal') end,limit)
          moved=moved+n; add(part)
          if caps[k] then caps[k]=caps[k]-n end
        end
      end
    else
      local n,part=move_stacks(source,target,match,wanted-moved)
      moved=moved+n; add(part)
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
  -- A silo with automatic requests on loads its rocket for the platforms'
  -- requests and refuses cargo by hand, empty rocket or not (request #124).
  if full and a.direction=='to_entity' and (a.inventory or inferred)=='rocket_silo_rocket' and e.type=='rocket-silo' then
    local ok,auto=pcall(function() return e.use_transitional_requests end)
    if ok and auto then
      full.auto_requests=true
      full.note='this silo has automatic requests on: the game fills its rocket for the platforms\' requests and takes no cargo by hand; turn them off with launch {position, auto_requests=false}, then transfer (and launch with platform=...)'
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
    -- The same for the camera clients, in the agent's colour (visuals.lua).
    pcall(M.visuals.moved,p,e.position,e.surface,table.concat(parts,' '))
    -- Takes and puts by hand, for the agent's repeated hauls (selfview.lua).
    pcall(M.selfview.moved,p,a.direction,e,stacks)
    pcall(M.hauling.moved,p.index,a.direction,e.position,e.surface and e.surface.name,stacks,e.name)
  end
  local out={transferred=moved,items=not a.item and stacks or nil,inventory=inferred,none_held=short and a.item or nil,target_has=short and count(target) or nil,
    at_up_to=a.item and a.up_to~=nil and a.direction=='to_entity' and count(target)>=a.up_to or nil}
  if a.direction=='to_player' then
    -- What the game will move to the trash slots, and what up_to left behind at the max.
    out.trash=moved>0 and M.trash.lines(p,a.item and {{name=a.item,quality=quality,count=moved}} or stacks) or nil
    if out.trash and a.tally then
      for _,st in ipairs(a.item and {{name=a.item,quality=quality,count=moved}} or stacks) do a.tally.t=M.trash.count(p,a.tally.t,st.name,st.quality,st.count) end
    end
    if held_back then
      local parts={}
      for name,v in pairs(held_back) do parts[#parts+1]=string.format('%d %s (your request max %d)',v[1],name,v[2]) end
      table.sort(parts)
      out.left_at_max=table.concat(parts,', ')..' left in the source'
    end
  end
  if a.direction=='to_player' then out.inventory_full=full else out.entity_full=full end
  if rocket then out.rocket_weight=space.rocket_weight(e); out.weight_limited=rocket.limited end
  -- Nothing moved and nothing was full: say why (agent-minds study: about 125
  -- empty takes a shift read as a success; Muse 38 of 43 circuit takes).
  if moved==0 and not full and not short then
    pcall(function()
      local where=string.format('%s at (%g,%g)',e.name,e.position.x,e.position.y)
      local label=a.item and (a.item..(quality~='normal' and '@'..quality or '')) or 'items'
      if a.direction=='to_player' then
        local list={}
        for i,s in ipairs(sources[1].get_contents()) do if i<=3 then list[#list+1]=s.name..'*'..s.count end end
        out.nothing_moved=string.format('%s holds no %s in %s; %s',where,label,a.inventory or inferred or 'its inventories',
          #list>0 and 'it holds '..table.concat(list,' ') or 'it is empty')
      elseif out.at_up_to then
        out.nothing_moved=string.format('%s already holds %d %s (up_to %d)',where,count(target),label,a.up_to)
      elseif a.keep~=nil and wanted==0 then
        out.nothing_moved=string.format('you hold %d %s and keep %d',available(),label,a.keep)
      else
        out.nothing_moved=string.format('%s took no %s into %s',where,label,a.inventory or inferred or 'its inventory')
      end
    end)
  end
  -- An emptied corpse goes, as when a player takes everything from it.
  if a.direction=='to_player' and e.type=='character-corpse' and sources[1].is_empty() then e.destroy(); out.corpse_removed=true end
  return out
end
-- Targets are {position} or {entity}. Each is independent: an unreachable one
-- must not undo the others. Quiet batches list only entities that changed or failed.
local function transfer_batch(p,a,targets,quiet)
  local total,totals,items,rows,untouched=0,{},{},{},0
  local left_at_max
  local blocked,short,empty
  for _,t in ipairs(targets) do
    local pos=t.entity and t.entity.position or t.position
    local ok,result
    -- A spent batch total or a full character inventory ends the batch.
    if (a.budget and a.budget.left==0) or blocked then ok=false
    else ok,result=pcall(transfer_one,p,a,t.position,t.entity) end
    if result==nil then untouched=untouched+1
    elseif ok then
      total=total+result.transferred
      empty=empty or result.nothing_moved
      blocked=result.inventory_full and result.inventory_full.blocked_item
      if result.none_held then
        short=short or {}
        short[#short+1]=string.format('(%g,%g) has %d',pos.x,pos.y,result.target_has)
      end
      if result.transferred>0 or not quiet or result.entity_full then rows[#rows+1]={position=pos,moved=result.transferred,full=result.entity_full and true or nil} else untouched=untouched+1 end
      for _,s in ipairs(result.items or {}) do
        local key=s.name..'@'..(s.quality or 'normal')
        if totals[key] then totals[key].count=totals[key].count+s.count
        else totals[key]={name=s.name,count=s.count,quality=s.quality}; items[#items+1]=totals[key] end
      end
      left_at_max=left_at_max or result.left_at_max
    else rows[#rows+1]={position=pos,moved=0,error=reason(result)} end
  end
  -- Nothing moved and targets wanted more, but the character holds none.
  if a.fail_short and total==0 and short then
    error(string.format('no %s in inventory or ammo slots; %d target(s) want more: %s',a.item,#short,table.concat(short,', ',1,math.min(#short,6))),0)
  end
  -- Over all targets: what the game will move to the trash slots (trash.lua).
  local trash=a.direction=='to_player' and total>0 and M.trash.lines(p,a.item and {{name=a.item,quality=a.quality,count=total}} or items) or nil
  return {transferred=total,items=not a.item and items or nil,entities=rows,unchanged=(quiet or untouched>0) and untouched or nil,trash=trash,
    left_at_max=left_at_max,
    none_held=short and #short or nil,total=a.budget and a.budget.cap,inventory_full=blocked and {got=total,blocked_item=blocked} or nil,
    nothing_moved=total==0 and not blocked and empty and (#targets>1 and string.format('none of %d targets: first, %s',#targets,empty) or empty) or nil,
    tally=#targets>1 and M.tally{moved=a.item and {{name=a.item,count=total,quality=a.quality~='normal' and a.quality or nil}} or items,
      targets=#targets,rows=rows,none_held=short and #short or 0,full_item=blocked} or nil}
end
-- One line closing a transfer or collect over several targets (Muse): moved per item, targets touched of the total,
-- and what fell short (full, holding none, failed with the first reason, never reached).
function M.tally(t)
  local moved={}
  for _,s in ipairs(t.moved or {}) do
    if s.count>0 then moved[#moved+1]=s.count..' '..s.name..(s.quality and s.quality~='normal' and '@'..s.quality or '') end
  end
  local touched,full,failed,why=0,0,0,nil
  for _,r in ipairs(t.rows or {}) do
    if (r.moved or r.transferred or 0)>0 then touched=touched+1 end
    if r.full then full=full+1 end
    if r.error then failed=failed+1; why=why or r.error end
  end
  touched=touched+(t.touched or 0)
  local shorts={}
  if t.full_item then shorts[#shorts+1]='your inventory full of '..t.full_item end
  if full>0 then shorts[#shorts+1]=full..' full' end
  if (t.none_held or 0)>0 then shorts[#shorts+1]=t.none_held..' wanting more you hold none of' end
  if failed>0 then shorts[#shorts+1]=failed..' failed ('..tostring(why):gsub('%s+',' '):sub(1,120)..')' end
  if (t.unreached or 0)>0 then shorts[#shorts+1]=t.unreached..' not reached' end
  if (t.errors or 0)>0 then shorts[#shorts+1]=t.errors..' failed' end
  local line=string.format('moved %s; %d of %d %s touched',#moved>0 and table.concat(moved,', ') or 'nothing',touched,t.targets,t.noun or 'targets')
  return line..(#shorts>0 and '; short: '..table.concat(shorts,', ') or '')
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
    local targets=below_target(p,a,integer(a.radius,32,1,256,'radius'),function(e) return fuel_inventory(e)~=nil and pcall(inventory,e,'fuel') and M.farm.accepts_fuel(e,fuel) end,fuel_inventory,fuel,count)
    return start_tour(p,a,'refuel',fuel,count,targets)
  end
  assert(a.ticks==nil,'ticks applies with radius')
  local targets=reachable(p,a,function(e) return fuel_inventory(e)~=nil and pcall(inventory,e,'fuel') and M.farm.accepts_fuel(e,fuel) end)
  -- A burner at a given position that burns another fuel category says so (a biochamber burns nutrients).
  for _,t in ipairs(a.positions and targets or {}) do
    local ok,e=pcall(entity,p,{position=t.position})
    if ok and e and fuel_inventory(e) and not M.farm.accepts_fuel(e,fuel) then
      local cats={}
      for k in pairs(M.farm.fuel_categories(e) or {}) do cats[#cats+1]=k end
      table.sort(cats)
      error(string.format('%s at (%g,%g) burns %s fuel, not %s (%s)',e.name,e.position.x,e.position.y,table.concat(cats,'/'),fuel,
        tostring(prototypes.item[fuel].fuel_category)),0)
    end
  end
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
-- up_to=true (courier steps; Grok, Luna, Sonnet and Muse asked in shift08): move what there is, min(count, what the
-- source holds, room), and say how far short it fell instead of failing. n: targets the count applies to.
local function short_facts(out,a,n)
  local moved=out.transferred or 0
  out.moved=moved
  local asked=a.count~=nil and integer(a.count,1,1,10000,'count')*n or (a.direction=='to_entity' and n or nil)
  if a.budget then asked=math.min(asked or a.budget.cap,a.budget.cap) end
  local full=out.inventory_full or out.entity_full
  for _,row in ipairs(out.entities or {}) do full=full or row.full end
  if (asked and moved>=asked) or (not asked and moved>0 and not full) then return out end
  local reason
  if full then reason='target_full'
  elseif out.none_held and moved==0 then reason='none_held'
  elseif a.direction=='to_player' and moved==0 then reason='source_empty'
  else reason='source_short' end
  out.short={asked=asked or 'all',moved=moved,reason=reason}
  return out
end
M.short_facts=short_facts
-- Empties the outputs of furnaces and assemblers in reach. Plain chests are
-- usually feed chests the player stocked for machines, so they are only
-- emptied when named by position, listed in types, or with chests=true.
local collect_types={plain={'furnace','assembling-machine'},chests={'furnace','assembling-machine','container','logistic-container'}}
function handlers.collect(p,a)
  assert(a.chests==nil or type(a.chests)=='boolean','chests must be true or false')
  assert(a.types==nil or (type(a.types)=='table' and #a.types>=1 and #a.types<=16),'types requires 1..16 entity types')
  assert(a.up_to==nil or a.up_to==true,'up_to must be true (an empty source never fails the step)')
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
  assert(a.keep_max==nil or type(a.keep_max)=='boolean','keep_max must be true or false')
  -- up_to=true stops at the request max (partial); keep_max refuses a take over it (trash.lua).
  local args={direction='to_player',item=a.item,types=a.types or (a.chests and collect_types.chests or collect_types.plain),positions=a.positions,quality=a.quality,
    partial=a.up_to==true or nil,keep_max=a.keep_max}
  args.count=a.item and integer(a.count,10000,1,10000,'count') or nil
  local targets=reachable(p,args,function() return true end)
  local out=transfer_batch(p,args,targets,true)
  if a.up_to==true then short_facts(out,{direction='to_player',count=a.count},1) end
  -- Named targets inside another agent's claim are taken from, but say whose (and when no permission is needed).
  local claimed={}
  for _,t in ipairs(targets) do
    local ok,at=pcall(position,t.entity and t.entity.valid and t.entity.position or t.position)
    local c=ok and #claimed<4 and M.claims.find(p,at)
    if c then claimed[#claimed+1]=string.format('(%g,%g) in %s',at.x,at.y,M.claims.label(c,p)) end
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
local feeding={TYPES={'assembling-machine','furnace','lab','boiler','burner-generator','mining-drill','inserter','agricultural-tower'}}
-- The recipe an assembler or furnace is set to (a furnace's last one when idle), by name, or nil.
function feeding.recipe_of(e)
  if e.type~='assembling-machine' and e.type~='furnace' then return nil end
  local ok,r=pcall(e.get_recipe)
  if ok and r then return r.name end
  if e.type=='furnace' then
    local okp,prev=pcall(function() return e.previous_recipe end)
    local name=okp and prev and prev.name
    return type(name)=='table' and name.name or name
  end
end
-- What a burner's fuel slots hold: {name=count}, or nil when empty (or no burner).
function feeding.fuel_in(e)
  local inv=fuel_inventory(e)
  if not inv then return nil end
  local out
  for i=1,#inv do
    local s=inv[i]
    if s and s.valid_for_read then out=out or {}; out[s.name]=(out[s.name] or 0)+s.count end
  end
  return out
end
-- A burner's fuel slots as one line ("coal 10", "solid-fuel 3, wood 2", "empty"); nil for a machine with no burner.
function feeding.fuel_line(e)
  if not fuel_inventory(e) then return nil end
  local held_,names=feeding.fuel_in(e) or {},{}
  for name in pairs(held_) do names[#names+1]=name end
  table.sort(names)
  for i,name in ipairs(names) do names[i]=name..' '..held_[name] end
  return #names>0 and table.concat(names,', ') or 'empty'
end
-- The fuel item for a burner: fuel=NAME; a fuel it burns named in items; what its slots hold, when carried; else
-- coal for chemical burners, or what it burns (a biochamber: nutrients; farm.lua). Second value: named in items.
function feeding.fuel_for(p,e,a)
  if type(a.fuel)=='string' then return a.fuel end
  for _,name in ipairs(a.items or {}) do
    if (prototypes.item[name].fuel_value or 0)>0 and M.farm.accepts_fuel(e,name) then return name,true end
  end
  for name in pairs(feeding.fuel_in(e) or {}) do
    if held(p,name,a.quality)>0 then return name end
  end
  return M.farm.default_fuel(e,function(n) return held(p,n,a.quality) end)
end
-- A burner gets fuel when asked (fuel=NAME, fuel=true, or a fuel named in items) or when its fuel slots are empty
-- (Gemini 03:20: furnaces burning solid fuel refused an ore feed over "you carry 0 coal").
function feeding.fuel_want(p,e,a)
  if a.fuel==false or not fuel_inventory(e) or not pcall(inventory,e,'fuel') then return nil end
  local fuel,named=feeding.fuel_for(p,e,a)
  if not (fuel and M.farm.accepts_fuel(e,fuel)) then return nil end
  if a.fuel==nil and not named and feeding.fuel_in(e) then return nil,true end
  return {item=fuel,inventory='fuel',count=a.fuel_count}
end
-- Whether a furnace smelts item (a recipe of its crafting categories takes it), by furnace name; prototypes only.
feeding.smelts_cache={}
function feeding.smelts(e,item)
  local key=e.name..'\0'..item
  local smelts_cache=feeding.smelts_cache
  if smelts_cache[key]==nil then
    local ok,cats=pcall(function() return e.prototype.crafting_categories end)
    local found=false
    for _,r in pairs(ok and cats and prototypes.recipe or {}) do
      if cats[r.category] then
        for _,ing in ipairs(r.ingredients or {}) do if ing.type=='item' and ing.name==item then found=true; break end end
      end
      if found then break end
    end
    smelts_cache[key]=found
  end
  return smelts_cache[key]
end
function feeding.wants(p,e,a)
  local out={}
  -- recipe: that recipe's item ingredients for `crafts` crafts, only in machines set to it (the second value names
  -- the recipe a machine runs instead, or false for none).
  if a.recipe then
    local set=feeding.recipe_of(e)
    if set~=a.recipe then return out,set or false end
    for _,ing in ipairs(prototypes.recipe[a.recipe].ingredients or {}) do
      if ing.type=='item' then
        out[#out+1]={item=ing.name,inventory=e.type=='furnace' and 'furnace_source' or 'assembling_machine_input',count=math.min(ing.amount*(a.crafts or 1),100000)}
      end
    end
    return out
  end
  local fuel=feeding.fuel_want(p,e,a)
  if fuel then out[#out+1]=fuel end
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
    -- A furnace that never smelted has no recipe yet: it takes the named items it smelts, as a player puts them in.
    if not recipe and e.type=='furnace' then
      for _,name in ipairs(a.items or {}) do
        if feeding.smelts(e,name) then out[#out+1]={item=name,inventory='furnace_source',count=a.count} end
      end
    end
  elseif e.type=='lab' then
    local ok,names=pcall(function() return e.prototype.lab_inputs end)
    for _,name in ipairs(ok and names or {}) do out[#out+1]={item=name,inventory='lab_input',count=a.count} end
  elseif e.type=='agricultural-tower' then
    -- Seeds: the kinds it holds, else every kind the character carries.
    local seeds=M.farm.seeds()
    local okc,inv=pcall(inventory,e,'agricultural_tower_input')
    local kinds={}
    for _,st in ipairs(okc and inv.get_contents() or {}) do if seeds[st.name] then kinds[#kinds+1]=st.name end end
    if #kinds==0 then for name in pairs(seeds) do if held(p,name,a.quality)>0 then kinds[#kinds+1]=name end end end
    table.sort(kinds)
    for _,name in ipairs(kinds) do out[#out+1]={item=name,inventory='agricultural_tower_input',count=a.count} end
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
-- With recipe, also what each ingredient still lacks for the crafts asked (short) and a machine set to another recipe.
function feeding.one(p,e,a)
  local gave,total={},0
  local keep=integer(a.keep,0,0,100000,'keep')
  local wants,other=feeding.wants(p,e,a)
  local short
  for _,w in ipairs(wants) do
    if held(p,w.item,a.quality)>keep then
      local ok,out=pcall(transfer_one,p,{direction='to_entity',item=w.item,inventory=w.inventory,count=w.count,up_to=w.count,keep=keep,quality=a.quality},nil,e)
      if ok and out.transferred>0 then gave[w.item]=(gave[w.item] or 0)+out.transferred; total=total+out.transferred end
    end
    if a.recipe then
      local ok,inv=pcall(inventory,e,w.inventory)
      local have=ok and inv.get_item_count{name=w.item,quality=a.quality or 'normal'} or 0
      if have<w.count then short=short or {}; short[w.item]=w.count-have end
    end
  end
  return gave,total,short,other
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
-- Why a feed gave nothing, per wanted item: what the character carries and
-- what the machines hold (Haiku's 35 empty feeds read "nothing_to_do, given
-- 0" while it carried no coal).
function feeding.why(p,es,a)
  local keep=integer(a.keep,0,0,100000,'keep')
  local by,order={},{}
  -- Burners left alone because they hold fuel, and furnaces with no recipe yet.
  local fueled,fuels,unset={n=0},{},0
  for _,e in ipairs(es) do
    for _,w in ipairs(feeding.wants(p,e,a)) do
      local ok,inv=pcall(inventory,e,w.inventory)
      local c=ok and inv.get_item_count{name=w.item,quality=a.quality or 'normal'} or 0
      local b=by[w.item]
      if not b then b={n=0,lo=math.huge,hi=0,count=w.count}; by[w.item]=b; order[#order+1]=w.item end
      b.n=b.n+1; b.lo=math.min(b.lo,c); b.hi=math.max(b.hi,c)
    end
    local _,has=feeding.fuel_want(p,e,a)
    if has then
      fueled.n=fueled.n+1
      for name,c in pairs(feeding.fuel_in(e) or {}) do
        local f=fuels[name]
        if not f then f={lo=c,hi=c}; fuels[name]=f; fuels[#fuels+1]=name end
        f.lo=math.min(f.lo,c); f.hi=math.max(f.hi,c)
      end
    end
    if e.type=='furnace' and not feeding.recipe_of(e) then unset=unset+1 end
  end
  local notes={}
  -- Only fuel named: what goes into the furnaces' source slots is not asked about.
  local source=not a.items
  for _,name in ipairs(a.items or {}) do source=source or (prototypes.item[name].fuel_value or 0)<=0 end
  if unset>0 and source then
    -- What the character carries that those furnaces smelt (main inventory).
    local can={}
    local okc,contents=pcall(function() return p.get_main_inventory().get_contents() end)
    for _,st in ipairs(okc and contents or {}) do
      for _,e in ipairs(es) do
        if e.type=='furnace' and not feeding.recipe_of(e) and feeding.smelts(e,st.name) then can[#can+1]=st.name..' '..st.count; break end
      end
      if #can>=4 then break end
    end
    notes[#notes+1]=string.format('%d furnace%s with no recipe yet (nothing smelted there) take%s only items named in items or item%s',unset,unset==1 and '' or 's',unset==1 and 's' or '',
      #can>0 and ('; you carry '..table.concat(can,', ')..' that they smelt') or '')
  end
  if fueled.n>0 then
    table.sort(fuels)
    local holds={}
    for i,name in ipairs(fuels) do
      local f=fuels[name]
      holds[i]=name..' '..(f.lo==f.hi and f.lo or f.lo..'-'..f.hi)
    end
    notes[#notes+1]=string.format('%d burner%s hold%s fuel (%s): fuel is added to a burner with none, or with fuel=true or fuel=NAME',
      fueled.n,fueled.n==1 and '' or 's',fueled.n==1 and 's' or '',table.concat(holds,', '))
  end
  if #order==0 then
    local base=string.format('none of the %d machines wants an item (no recipe set, or not a machine feed fills)',#es)
    return #notes>0 and base..'; '..table.concat(notes,'; ') or base
  end
  local parts={}
  for i,item in ipairs(order) do
    if i>4 then parts[#parts+1]='+'..(#order-4)..' more'; break end
    local b,have=by[item],held(p,item,a.quality)
    local hold=b.lo==b.hi and tostring(b.lo) or (b.lo..'-'..b.hi)
    if have<=keep then
      parts[#parts+1]=string.format('you carry %d %s%s; %d machine%s hold %s',have,item,keep>0 and ' (keep '..keep..')' or '',b.n,b.n==1 and '' or 's',hold)
    else
      parts[#parts+1]=string.format('%d machine%s hold %s %s, at count %d already',b.n,b.n==1 and '' or 's',hold,item,b.count)
    end
  end
  for _,note in ipairs(notes) do parts[#parts+1]=note end
  return table.concat(parts,'; ')
end
-- Hand-feeds machines from inventory: recipe ingredients, science packs and
-- fuel, up to count each, keeping a reserve. In reach by default, at given
-- positions, or as a walking tour with radius. Nothing is taken out.
function handlers.feed(p,a)
  -- item: one name, as transfer takes it (Grok): the same as items=[item], beside any items given.
  if a.item~=nil then
    assert(type(a.item)=='string' and prototypes.item[a.item],'unknown item '..tostring(a.item))
    assert(a.items==nil or type(a.items)=='table','items requires 1..16 item names')
    local list={a.item}
    for _,name in ipairs(a.items or {}) do if name~=a.item then list[#list+1]=name end end
    a.items=list; a.item=nil
  end
  assert(a.items==nil or (type(a.items)=='table' and #a.items>=1 and #a.items<=16),'items requires 1..16 item names')
  for _,name in ipairs(a.items or {}) do assert(prototypes.item[name],'unknown item '..tostring(name)) end
  assert(a.fuel==nil or type(a.fuel)=='boolean' or (type(a.fuel)=='string' and prototypes.item[a.fuel] and (prototypes.item[a.fuel].fuel_value or 0)>0),'fuel must be a fuel item, true or false')
  a.count=integer(a.count,20,1,1000,'count'); a.fuel_count=integer(a.fuel_count,10,1,1000,'fuel_count')
  assert(a.types==nil or (type(a.types)=='table' and #a.types>=1 and #a.types<=16),'types requires 1..16 entity types')
  assert(a.up_to==nil or a.up_to==true,'up_to must be true (a short inventory never fails the step)')
  assert(a.crafts==nil or a.recipe~=nil,'crafts goes with recipe')
  if a.recipe~=nil then
    assert(type(a.recipe)=='string' and prototypes.recipe[a.recipe],'unknown recipe '..tostring(a.recipe))
    assert(a.items==nil,'give recipe or items (or item), not both')
    a.crafts=integer(a.crafts,1,1,1000,'crafts')
  end
  local types=a.types or (a.recipe and {'assembling-machine','furnace'}) or feeding.TYPES
  if a.radius~=nil then
    assert(a.positions==nil,'give radius or positions, not both')
    local targets,found={},{}
    for _,e in pairs(p.surface.find_entities_filtered{position=p.position,radius=integer(a.radius,32,1,256,'radius'),force=p.force,type=types}) do
      if e.valid then found[#found+1]=e; if feeding.hungry(p,e,a) then targets[#targets+1]=e end end
    end
    local action,out=stock.start_tour(p,'feed',targets,integer(a.ticks,3600,1,36000,'ticks'),{feed=a})
    if state().active[p.index] then finish(p.index,'replaced') else stop(p) end
    state().active[p.index]=action
    out.until_tick=action.until_tick
    if #targets==0 then
      local ok,why=pcall(feeding.why,p,found,a)
      out.nothing_moved=ok and ('nothing to feed: '..why) or nil
    end
    return out
  end
  assert(a.ticks==nil,'ticks applies with radius')
  local targets=reachable(p,{positions=a.positions,types=types},function() return true end)
  local rows,items,total,unchanged,seen,other_recipe={},{},0,0,{},0
  for _,t in ipairs(targets) do
    local ok,e=pcall(function() return t.entity or entity(p,{position=t.position,name=t.position.name,unit_number=t.position.unit_number}) end)
    if not ok then rows[#rows+1]={position=t.position,error=reason(e)}
    else
      seen[#seen+1]=e
      local okf,gave,n,short,other=pcall(feeding.one,p,e,a)
      if not okf then rows[#rows+1]={position=e.position,name=e.name,error=reason(gave)}
      elseif a.recipe then
        -- One row per machine: what it got and what it still lacks for the crafts, or the recipe it runs instead.
        -- Machines in reach on other recipes are only counted; named ones are listed.
        if other~=nil and a.positions and not a.from_area then rows[#rows+1]={position=e.position,name=e.name,recipe=other or 'none'}
        elseif other~=nil then other_recipe=other_recipe+1
        else rows[#rows+1]={position=e.position,name=e.name,loaded=next(gave) and gave or nil,short=short} end
        for item,c in pairs(gave) do items[item]=(items[item] or 0)+c end
        total=total+n
      elseif n>0 then
        rows[#rows+1]={position=e.position,name=e.name,gave=gave,fuel=feeding.fuel_line(e)}
        for item,c in pairs(gave) do items[item]=(items[item] or 0)+c end
        total=total+n
      else
        unchanged=unchanged+1
        -- Named machines (positions, area) each get a row, also when they got nothing (Haiku: one boiler call).
        if a.positions then rows[#rows+1]={position=e.position,name=e.name,got='nothing',fuel=feeding.fuel_line(e)} end
      end
    end
  end
  local left={}
  for item in pairs(items) do left[item]=held(p,item,a.quality) end
  local why
  if total==0 then
    local ok,w=pcall(feeding.why,p,seen,a)
    why=ok and w or 'no machine in reach wants an item you hold above keep (or they are at count already)'
  end
  return {transferred=total,items=next(items) and items or nil,entities=rows,unchanged=unchanged>0 and unchanged or nil,held=next(left) and left or nil,
    other_recipe=other_recipe>0 and other_recipe or nil,nothing_moved=why and ('nothing given: '..why) or nil}
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
  assert(a.up_to==nil or a.up_to==true or type(a.up_to)=='number','up_to must be a number (target cap) or true (move what there is)')
  assert(a.keep_max==nil or type(a.keep_max)=='boolean','keep_max must be true or false')
  if a.up_to==true then
    local args={}
    for k,v in pairs(a) do args[k]=v end
    args.up_to=nil; args.partial=true
    a=args
  end
  if a.direction~=nil then return transfer_directed(p,a) end
  local args={}
  for k,v in pairs(a) do args[k]=v end
  local ok,dir=pcall(infer_direction,p,a)
  -- up_to=true with the item on neither side: a short, not an error.
  if not ok and a.partial and tostring(dir):find('holds 0 .- and the targets? holds? 0') then
    local asked=a.count~=nil and integer(a.count,1,1,10000,'count')*#(a.positions or {a.position}) or 'all'
    return {transferred=0,moved=0,short={asked=asked,moved=0,reason='none_held'}}
  end
  assert(ok,dir)
  args.direction=dir
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
    if a.partial then return short_facts(out,a,1) end
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
  local out=transfer_batch(p,a,targets,false)
  if a.partial then return short_facts(out,a,#targets) end
  return out
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
  -- remove (or cancel) and move: edit the queue as the research GUI does
  -- (research.lua without/moved); the names waiting beyond the engine queue count.
  local drop=a.remove; if drop==nil then drop=a.cancel end
  if drop~=nil or a.move~=nil then
    assert(a.technology==nil and a.research_queue==nil and a.front==nil and a.append==nil,'remove and move go without technology, research_queue, front or append')
    assert(drop==nil or a.move==nil,'remove or move, one per call')
    local list={}
    for _,name in ipairs(current) do list[#list+1]=name end
    list=with_waiting(list)
    local edit
    if drop~=nil then list,edit=M.research.without(force,list,drop) else list=M.research.moved(force,list,a.move,a.to) end
    local out=set_research_queue(force,list)
    if edit then out.removed=edit.removed; out.also_removed=edit.also end
    return out
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
    -- Each entry in full: progress, who queued it, packs, time to finish (research.lua).
    local view=M.research.queue(force,waiting)
    out.entries=view.entries; out.throughput=view.throughput; out.clock_stops_at=view.clock_stops_at
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
-- Who queued what (research.lua): names that were neither queued nor waiting
-- before this agent's research call are this agent's.
do
  local queue_research=handlers.research
  local function known(force)
    local seen={}
    for _,name in ipairs(queue_names(force)) do seen[name]=true end
    local plan=state().research_plan and state().research_plan[force.name]
    for _,name in ipairs(plan and plan.names or {}) do seen[name]=true end
    return seen
  end
  handlers.research=function(p,a)
    local before=known(p.force)
    local out=queue_research(p,a)
    local fresh={}
    for name in pairs(known(p.force)) do if not before[name] then fresh[#fresh+1]=name end end
    table.sort(fresh)
    if #fresh>0 then M.research.record(p.force.name,fresh,M.board.who(p)) end
    return out
  end
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
    if ready then
      local started=p.force.add_research(t)
      if started then M.research.record(p.force.name,{name},M.board.who(p)) end
      return {started=started,current=name}
    end
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
  -- Seated: the vehicle's gun (vehicles.lua), aimed at an entity the gunner selects.
  if p.character and p.character.valid and p.character.vehicle then
    local action,out,target=M.vehicles.shoot(p,a,ticks)
    state().combat=state().combat or {}
    combat_targets()[p.index]=target and {fixed=target} or nil
    state().combat[p.index]=action
    return out
  end
  assert(a.gun==nil and a.ammo==nil,'gun and ammo pick a vehicle\'s gun (seated in a car, tank or spidertron); on foot gun_slot picks 1..3')
  local pos=a.position and position(a.position)
  assert(a.auto==true or pos,'specify position or auto=true')
  if pos then assert(visible(p,pos),'firing position must be locally visible') end
  if a.gun_slot then p.character.selected_gun_index=integer(a.gun_slot,nil,1,3,'gun_slot') end
  -- The engine fires from the ammo slots and spends what it fires; without
  -- ammo the trigger does nothing, so say so instead of "shooting". Empty
  -- slots are first filled from carried ammo (kite.auto_equip), and the reply says so.
  local equipped=kite.ammo_count(p)==0 and kite.auto_equip(p) or nil
  local ammo=kite.ammo_count(p)
  assert(ammo>0,'no ammunition in the ammo slots and none carried that fits a gun: craft firearm-magazine')
  state().combat=state().combat or {}
  combat_targets()[p.index]=nil
  state().combat[p.index]={until_tick=game.tick+ticks,position=pos,auto=a.auto==true,radius=integer(a.radius,24,1,32,'radius'),ammo_start=ammo}
  return {until_tick=game.tick+ticks,ammo=ammo,equipped=equipped}
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
-- Why a ghost was not placed, and settings a pasted-over entity lacks (placewhy.lua).
M.placewhy=require('placewhy'){filters=function(e) return M.details.filters(e) end}
-- What inserters take from and put into (targets.lua): built, ghost or planned.
M.targets=require('targets'){}
-- The requests of entities a paste lands on (keep.lua).
M.keep=require('keep'){}
-- Personal logistics: what a take puts over the character's request max goes to trash (trash.lua).
M.trash=require('trash'){}
-- Ammo requests on turret ghosts: place_ghosts, paste and the ghosts of our turrets that died (turretammo.lua).
M.turretammo=require('turretammo'){state=state}
M.replace=require('replace'){}
-- Underground entrances fed from the side by an inserter or a belt (sidefeed.lua; Sol, shift10).
M.sidefeed=require('sidefeed'){try=function(fn) local ok,v=pcall(fn); if ok then return v end end}
local blueprint_handlers=blueprint_module{position=position,visible=visible,distance=distance,entity=entity,friendly=friendly,integer=integer,real=real,own_platform=own_platform,targets=M.targets,keep=M.keep,turretammo=M.turretammo,
  build_notes=function(p,ents) return M.build_notes(p,ents) end,
  ground_mark=function(p,box,cancel,out) return M.ground.mark(p,box,cancel,out) end,
  placewhy=M.placewhy,blocked=function(p,proto,pos,direction) return placement_error(p,proto,pos,direction) end,
  who=function(p) return M.board.who(p) end}
for name,handler in pairs(blueprint_handlers) do if name~='plan' and name~='operator' then handlers[name]=handler end end
-- The team blueprint library's operator read (tools/bplibrary.py mirrors it to runs/RUN/blueprints/).
M.bplibrary_operator=blueprint_handlers.operator
-- Where a paste would land, placing nothing (paste dry_run).
M.paste_plan=blueprint_handlers.plan
-- Dry runs of place_ghosts, paste and build (dryrun.lua); fluid ports of an
-- entity not built yet, by recipe (ports.lua).
M.dryrun=require('dryrun'){placewhy=M.placewhy,charted=charted,own_platform=own_platform,character_owner=M.character_owner,targets=M.targets,keep=M.keep,pathing=M.pathing,
  sidefeed=M.sidefeed,coverage=function(s,force,pos,planned) return M.networks.coverage(s,force,pos,planned) end,
  placement_error=function(p,proto,pos,direction) return placement_error(p,proto,pos,direction) end,
  crafting_count=function(p,item) return crafting_count(p,item) end,
  rail_box=function(name,pos,dir) return M.rails and M.rails.box(name,pos,dir) end,
  rail_overlaps=function(shape,l,t,r,b) return M.rails.overlaps(shape,l,t,r,b) end}
M.ports=require('ports'){boxes=function(proto) return pipes.boxes(proto) end,defined=function(e) return pipes.defined(e) end}
-- Grenades and other capsules (capsules.lua, request #89).
M.capsules=require('capsules'){state=state,position=position,assert_visible=assert_visible,held=held}
handlers.use_item=M.capsules.handlers.use_item
-- The fluid GUI's flush (flush.lua, Sol's request): reach as configure.
M.flush=require('flush'){integer=integer,friendly=friendly,target=function(p,a)
  local near,e=pcall(entity,p,a)
  if near then return e end
  local ok,far=pcall(remote_entity,p,a)
  if not ok then error(e,0) end
  return far
end}
handlers.flush=M.flush.handlers.flush
-- Rocket cargo weighed before it is staged (cargo.lua, Sol: three kits rebuilt
-- into two after working weights out offline): a list, or what a chest, rocket
-- silo, landing pad, platform hub, wagon or vehicle holds.
M.cargo=require('cargo'){}
M.CARGO_INVENTORY={['rocket-silo']='rocket_silo_rocket',['cargo-landing-pad']='cargo_landing_pad_main',['space-platform-hub']='hub_main',
  ['cargo-wagon']='cargo_wagon',car='car_trunk',['spider-vehicle']='spider_trunk'}
handlers.cargo=function(p,a)
  local list,from,silo={},nil,nil
  assert((a.items==nil)~=(a.position==nil),'cargo takes items ({name: count} or [{name, count, quality}]) or a position, one of them')
  if a.items~=nil then
    assert(type(a.items)=='table' and next(a.items)~=nil,'items is {name: count} or [{name, count, quality}]')
    if #a.items>0 then
      for _,e in ipairs(a.items) do
        assert(type(e)=='table' and type(e.name)=='string','each item is {name, count, quality?}')
        assert(e.quality==nil or (type(e.quality)=='string' and prototypes.quality[e.quality]),'unknown quality '..tostring(e.quality))
        list[#list+1]={name=e.name,count=integer(e.count,nil,1,10000000,'count of '..e.name),quality=e.quality}
      end
    else
      for name,count in pairs(a.items) do
        assert(type(name)=='string','items is {name: count}')
        list[#list+1]={name=name,count=integer(count,nil,1,10000000,'count of '..name)}
      end
      table.sort(list,function(x,y) return x.name<y.name end)
    end
  else
    local e,by=entity(p,a,true)
    local name=M.CARGO_INVENTORY[e.type]
    if not name then for _,t in ipairs(inventories.chest) do if t==e.type then name='chest' end end end
    assert(name,e.name..' holds no cargo to weigh (a chest, rocket silo, landing pad, platform hub, wagon or vehicle does)')
    for _,s in ipairs(contents(inventory(e,name))) do list[#list+1]={name=s.name,count=s.count,quality=s.quality~='normal' and s.quality or nil} end
    if e.type=='rocket-silo' then silo=e end
    from={name=e.name,position=e.position,inventory=name,by=by}
    assert(#list>0,string.format('%s at (%g,%g) holds nothing in %s',e.name,e.position.x,e.position.y,name))
  end
  local lift,slots=M.cargo.limits(silo)
  local out=M.cargo.weigh(list,lift,slots)
  out.from=from
  return out
end
-- A rocket silo at a glance (silo.lua, Gemini's request): parts, crafting and
-- what it lacks, cargo against the lift, automatic requests, the last launch.
M.silo=require('silo'){state=state,cargo=M.cargo,position=position,status_name=function(e) return entity_status_names[e.status] end}
function handlers.silo(p,a) return M.silo.read(p,a) end
-- Circuit wires and settings (circuits.lua), train stops and schedules (trains.lua).
M.circuits=require('circuits'){entity=entity,remote_entity=remote_entity,friendly=friendly,own_platform=own_platform,position=position,
  configure_filters=function(e,a) return M.configure_filters(e,a) end}
handlers.circuit_set=M.circuits.handlers.circuit_set
-- The old name: queued plans and orders call handlers by name (direct calls run as circuit_set, aliases.lua).
handlers.circuit=handlers.circuit_set
M.trains=require('trains'){entity=entity,remote_entity=remote_entity,friendly=friendly,integer=integer}
handlers.train=M.trains.handlers.train
-- Vehicles (vehicles.lua): get in and out, drive a car, send a spidertron.
M.vehicles=require('vehicles'){entity=entity,friendly=friendly,integer=integer,position=position,distance=distance,assert_visible=assert_visible,
  start=function(p,action) if state().active[p.index] then finish(p.index,'replaced') end; state().active[p.index]=action end,
  -- A drive's path requests and its way around enemies (avoid.lua), as a walk's.
  paths=function() state().paths=state().paths or {}; return state().paths end,
  accept=function(p,nav,path) return M.avoid.accept(p,nav,path) end,
  avoid_mode=function(v) return M.avoid.mode(v) end,avoid_describe=function(mode) return M.avoid.describe(mode) end,
  avoid_start=function(p,nav,mode) return M.avoid.start(p,nav,mode) end,avoid_tick=function(p,nav) return M.avoid.tick(p,nav) end,
  leg=function(p,nav) return M.avoid.leg_done(p,nav,'arrived') end}
handlers.vehicle=M.vehicles.handlers.vehicle
-- Items on the ground (ground.lua): summaries for scan/observe, spill and pile
-- alerts, deconstruct items_on_ground, pickup over an area.
M.ground=require('ground'){state=state,real=real,distance=distance,position=position,integer=integer,assert_visible=assert_visible,trash=M.trash,
  start=function(p,action) if state().active[p.index] then finish(p.index,'replaced') else stop(p) end; state().active[p.index]=action end,
  request_path=function(p,nav) return request_path(p,nav) end,navigate=function(p,nav) return navigate(p,nav) end,
  stop_walking=function(p) p.walking_state={walking=false,direction=defines.direction.north} end}
-- Valid placements near a position (shore.lua): refused builds of offshore
-- pumps or onto water list them; the placements read returns them.
M.shore=require('shore'){position=position,integer=integer,assert_visible=assert_visible,directions=directions}
handlers.placements=M.shore.handlers.placements
-- The defense read (defense.lua): built-up areas, turret cover and ammo, nests near them.
M.details=require('details'){}
-- Gleba farming reads and burner fuel (farm.lua).
M.farm=require('farm'){}
-- Spoilage in the reads, recipe outputs' inherited spoilage, and the egg watch
-- (spoil.lua; Sol, shift10 04:59: stored pentapod eggs hatched in his camp).
M.spoil=require('spoil'){state=state,force=function() return game.forces.player end,
  characters=function()
    local out={}
    for _,b in ipairs(M.bots.list()) do if b.character and b.character.valid then out[#out+1]=b.character end end
    for _,pl in pairs(game.connected_players) do if not M.is_director(pl.index) and pl.character and pl.character.valid then out[#out+1]=pl.character end end
    return out
  end,
  character_name=function(e)
    for _,b in ipairs(M.bots.list()) do if b.character==e then return b.name end end
    for _,pl in pairs(game.connected_players) do if pl.character==e then return M.board.who(pl) end end
  end}
function M.farm_flow(p,surface,item)
  local ok,n=pcall(function()
    return p.force.get_item_production_statistics(surface).get_flow_count{name=item,category='input',precision_index=defines.flow_precision_index.ten_minutes,count=true}
  end)
  return ok and math.floor(n+0.5) or nil
end
-- Nest pollution from threat.lua's memory (one reading at the cloud's edge flickers), shared with status.
M.defense=require('defense'){state=state,polluted=function(s,pos) return threat.polluted(s,pos) end,reached=function(last) return threat.reached(last) end}
handlers.defense=M.defense.handlers.defense
handlers.flamers=M.defense.handlers.flamers
-- Every resource patch on the charted map (ores.lua, Opus: finding new iron in
-- one call): amount left, distances, nests within 50 tiles, our drills on it.
M.ores=require('ores'){state=state,integer=integer,position=position,
  charted=function(force,surface,chunk) local pl=surface.platform if pl and pl.force==force then return true end return force.is_chunk_charted(surface,chunk) end}
handlers.ores=M.ores.handlers.ores
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
-- A tile ghost goes where the engine's check takes it. Trees and rocks in
-- its way (Sol, shift10: a slipstack on Gleba wetland kept landfill from
-- three belt tiles; dryrun.lua tile_blockers) are marked for deconstruction
-- first, as the game's ghost placement marks them: marked, the engine takes
-- the tile ghost (2.0.77), and construct mines them before it lays the tile.
-- Anything else in the way refuses it, named. Returns the ghost and what it
-- marked.
local function place_tile_ghost(p,tile,pos)
  assert(charted(p,pos),'position is not charted')
  local x,y=math.floor(pos.x),math.floor(pos.y)
  local marked={}
  local blockers=M.dryrun.tile_blockers(p.surface,p.force,tile,x,y)
  if blockers then
    local others={}
    for _,b in ipairs(blockers) do if not b.obstacle then others[#others+1]=b end end
    if #others>0 then error('tile placement blocked by '..table.concat(M.dryrun.blocker_texts({others}),', '),0) end
    assert(#blockers>0,'tile placement blocked: the game refuses '..tile..' there now')
    for _,b in ipairs(blockers) do
      if b.entity.valid and b.entity.order_deconstruction(p.force,real(p)) then marked[#marked+1]=b.entity end
    end
  end
  local args={name='tile-ghost',inner_name=tile,position=pos,force=p.force}
  local ok=p.surface.can_place_entity{name='tile-ghost',inner_name=tile,position=pos,force=p.force,build_check_type=defines.build_check_type.manual_ghost}
  args.player=real(p); args.raise_built=true
  local ghost=ok and p.surface.create_entity(args)
  if not ghost then
    for _,e in ipairs(marked) do if e.valid then pcall(e.cancel_deconstruction,p.force,real(p)) end end
    error('tile placement blocked',0)
  end
  return ghost,marked
end
-- The reply's line for trees and rocks marked where tile ghosts go.
function M.tile_marks_line(list)
  if #list==0 then return nil end
  local parts,seen={},{}
  for _,e in ipairs(list) do
    if e.valid then
      local text=string.format('%s (%g,%g)',e.name,math.floor(e.position.x*10+0.5)/10,math.floor(e.position.y*10+0.5)/10)
      if not seen[text] then seen[text]=true; parts[#parts+1]=text end
    end
  end
  if #parts==0 then return nil end
  return 'marked for deconstruction where tile ghosts go: '..table.concat(parts,', ',1,math.min(8,#parts))..(#parts>8 and string.format(' and %d more',#parts-8) or '')
    ..'; construct mines them before it lays the tiles'
end
local function place_ghost(p,spec)
  assert(type(spec)=='table','entry must be {name,position,direction?,type?}')
  local tile=not prototypes.entity[spec.name or ''] and tile_named(spec.name)
  if tile then
    local ghost,tile_marked=place_tile_ghost(p,tile,position(spec.position))
    return ghost,0,nil,nil,tile_marked
  end
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
  -- Tiles it cannot stand on (water, Gleba wetland): the forced ghost check
  -- takes them once the force has landfill, because a player's forced
  -- placement lays the tile ghosts under the entity; so do we, before it.
  -- With no tile item for them the ghost would never be built: refused.
  -- Trees and rocks where those tiles go are marked first (place_tile_ghost);
  -- anything else there refuses the ghost, named.
  local fixes=M.dryrun.tile_fixes(p.surface,p.force,proto,pos,direction)
  for _,f in ipairs(fixes or {}) do
    local result=f.item and prototypes.item[f.item] and prototypes.item[f.item].place_as_tile_result
    f.result=result and result.result.name
    local blockers=f.result and M.dryrun.tile_blockers(p.surface,p.force,f.result,math.floor(f.x),math.floor(f.y))
    local others={}
    for _,b in ipairs(blockers or {}) do if not b.obstacle then others[#others+1]=b end end
    if not f.result or #others>0 or (blockers and #blockers==0) then
      error(string.format('placement blocked by tiles: %s at (%g,%g)%s',f.tile,f.x,f.y,
        f.locked and ' (needs '..f.locked..')' or #others>0 and ': its '..f.item..' is blocked by '..table.concat(M.dryrun.blocker_texts({others}),', ')
        or f.result and ' (the game refuses '..f.item..' there)' or ' (no tile item makes it buildable)'),0)
    end
  end
  local laid,tiles,tile_marked={},{},{}
  for _,f in ipairs(fixes or {}) do
    local ok,t,m=pcall(place_tile_ghost,p,f.result,{x=f.x,y=f.y})
    if not ok then
      for _,g in ipairs(tiles) do if g.valid then g.destroy() end end
      for _,e in ipairs(tile_marked) do if e.valid then pcall(e.cancel_deconstruction,p.force,real(p)) end end
      error(string.format('placement blocked by tiles: %s at (%g,%g): %s',f.tile,f.x,f.y,reason(t)),0)
    end
    tiles[#tiles+1]=t
    for _,e in ipairs(m or {}) do tile_marked[#tile_marked+1]=e end
    laid[f.item]=(laid[f.item] or 0)+1
  end
  local ghost=p.surface.create_entity{name='entity-ghost',inner_name=spec.name,position=pos,direction=direction,force=p.force,player=real(p),raise_built=true,type=spec.type}
  if not ghost then
    for _,t in ipairs(tiles) do if t.valid then t.destroy() end end
    for _,e in ipairs(tile_marked) do if e.valid then pcall(e.cancel_deconstruction,p.force,real(p)) end end
    error('placement blocked',0)
  end
  local _,marked=construction.mark_obstacles(p,ghost)
  return ghost,marked,fixes and laid or nil,fixes and fixes[1].tile or nil,tile_marked
end
local function place_ghost_list(p,list,ammo)
  local placed,failed,bounds,marked=0,{},nil,0
  local unders,inserters,chests={},{},{}
  local tiles_laid,laid_under,laid_on=nil,0,nil
  local tile_marked={}
  local ammo_rows={}
  for i,spec in ipairs(list) do
    local ok,err=pcall(function()
      if type(spec)=='table' then M.turretammo.check(spec.ammo) end
      local ghost,n,laid,on,tm=place_ghost(p,spec)
      -- A turret ghost requests ammo, so the robots that build it bring some (turretammo.lua).
      if ghost.type=='entity-ghost' then
        local what=spec.ammo
        if what==nil then what=ammo end
        local c=M.turretammo.request(ghost,what)
        if c then M.turretammo.add(ammo_rows,c) end
      end
      for _,e in ipairs(tm or {}) do tile_marked[#tile_marked+1]=e end
      marked=marked+#(tm or {})
      if laid then
        tiles_laid=tiles_laid or {}
        for item,count in pairs(laid) do tiles_laid[item]=(tiles_laid[item] or 0)+count end
        laid_under=laid_under+1; laid_on=laid_on or on
      end
      local g=ghost.position
      if ghost.type=='entity-ghost' and ghost.ghost_type=='inserter' then inserters[#inserters+1]=ghost end
      if ghost.type=='entity-ghost' and ghost.ghost_type=='logistic-container' then chests[#chests+1]=ghost end
      if ghost.type=='entity-ghost' and (ghost.ghost_type=='underground-belt' or ghost.ghost_type=='pipe-to-ground') then
        unders[#unders+1]={ghost=ghost,['end']=ghost.ghost_type=='underground-belt' and (spec.type or 'input') or nil}
      end
      marked=marked+n
      bounds=bounds or {left=g.x,top=g.y,right=g.x,bottom=g.y}
      bounds.left=math.min(bounds.left,g.x); bounds.top=math.min(bounds.top,g.y)
      bounds.right=math.max(bounds.right,g.x); bounds.bottom=math.max(bounds.bottom,g.y)
    end)
    if ok then placed=placed+1 else failed[#failed+1]={index=i,name=type(spec)=='table' and spec.name or nil,position=type(spec)=='table' and spec.position or nil,error=reason(err)} end
  end
  -- Underground spans over tiles they cannot pass under (lava, space): once
  -- per span, from a belt entrance or either pipe end (underpass.lua).
  local warnings,seen={},{}
  for _,u in ipairs(unders) do
    local g=u.ghost
    local ok,s=pcall(M.underpass.span,g,u['end'])
    if ok and s and #s.blocked>0 and (s.kind=='pipe-to-ground' or s['end']=='input') then
      -- Both ends of a pipe pair see the same tiles: one warning.
      local tiles={}
      for _,t in ipairs(s.blocked) do tiles[#tiles+1]=t.x..','..t.y end
      table.sort(tiles)
      local key=table.concat(tiles,' ')
      if not seen[key] then
        seen[key]=true
        local why=M.underpass.why(g,u['end'])
        warnings[#warnings+1]=string.format('%s %s ghost at (%g,%g) will stay unpaired: %s',s.name,s['end'] or '',g.position.x,g.position.y,why):gsub('  ',' ')
      end
    end
  end
  -- Inserter ghosts with nothing to take from or put into on their points,
  -- once all of this call's ghosts stand (targets.lua).
  local loose,nloose=M.targets.check(inserters,16)
  -- Tile ghosts laid under entity ghosts that stand on water or wetland: construct lays them first.
  local tile_note
  if tiles_laid then
    local parts={}
    for item,count in pairs(tiles_laid) do parts[#parts+1]=count..' '..item end
    table.sort(parts)
    local n=0
    for _,count in pairs(tiles_laid) do n=n+count end
    tile_note=string.format('%d ghost%s %s on %s: %s tile ghost%s laid under %s, which construct builds first (it takes the items from your inventory)',
      laid_under,laid_under==1 and '' or 's',laid_under==1 and 'stands' or 'stand',laid_on,table.concat(parts,', '),n==1 and '' or 's',laid_under==1 and 'it' or 'them')
  end
  -- Logistic chest ghosts no roboport's logistic area covers (a roboport placed in this call counts: it is a ghost now).
  local cover=M.build_notes(p,chests)
  return {placed=placed,failed=#failed>0 and failed or nil,bounds=bounds,obstacles_marked=marked>0 and marked or nil,
    underground_warnings=#warnings>0 and warnings or nil,inserters_without_target=loose,inserters_without_target_count=nloose,
    tiles_laid=tiles_laid,tiles_note=tile_note,outside_logistic_coverage=cover,tile_obstacles_marked=M.tile_marks_line(tile_marked),
    ammo_requests=#ammo_rows>0 and ammo_rows or nil}
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
  local tile_marked,why={},nil
  for x=x0,x1 do for y=y0,y1 do
    local pos={x=x+0.5,y=y+0.5}
    local ok=false
    local there=p.surface.find_entities_filtered{position=pos,radius=0.1,type='tile-ghost',force=p.force,limit=1}[1]
    if there and there.ghost_name==tile then existing=existing+1; ok=true
    else
      local res,m
      ok,res,m=pcall(place_tile_ghost,p,tile,pos)
      if ok then
        placed=placed+1
        for _,e in ipairs(m or {}) do tile_marked[#tile_marked+1]=e end
      elseif not why and type(res)=='string' and res:find('blocked by',1,true) then why=reason(res) end
    end
    if ok then
      bounds=bounds or {left=x+0.5,top=y+0.5,right=x+0.5,bottom=y+0.5}
      bounds.left=math.min(bounds.left,x+0.5); bounds.top=math.min(bounds.top,y+0.5)
      bounds.right=math.max(bounds.right,x+0.5); bounds.bottom=math.max(bounds.bottom,y+0.5)
    else refused=refused+1 end
  end end
  return {tile=tile,tiles_placed=placed,tiles_existing=existing>0 and existing or nil,tiles_refused=refused>0 and refused or nil,bounds=bounds,
    tiles_refused_why=refused>0 and why or nil,tile_obstacles_marked=M.tile_marks_line(tile_marked),
    obstacles_marked=#tile_marked>0 and #tile_marked or nil}
end
function handlers.place_ghosts(p,a)
  assert(a.entities~=nil or a.tiles~=nil,'place_ghosts requires entities and/or tiles')
  local out={}
  if a.entities~=nil then
    assert(type(a.entities)=='table' and #a.entities>=1 and #a.entities<=256,'entities requires 1..256 {name,position,direction?}')
    M.turretammo.check(a.ammo)
    out=place_ghost_list(p,a.entities,a.ammo)
  end
  if a.tiles~=nil then
    local t=place_tile_area(p,a.tiles)
    for k,v in pairs(t) do
      if k=='obstacles_marked' then out[k]=(out[k] or 0)+v
      elseif k=='tile_obstacles_marked' and out[k] then out[k]=out[k]..'; '..v
      elseif k~='bounds' then out[k]=v end
    end
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
-- Rails (rails.lua): rail_route plans the 2.0 rail planner's pieces around
-- what blocks them and places them as ghosts; the ones in build reach are
-- built from the inventory unless ghosts=true. train_stop puts a stop on the
-- side of a straight rail where it serves trains heading one way.
M.rails=require('rails'){position=position,directions=directions,chunk_of=chunk_of}
-- Ghosts of planned entities in build reach, built from the inventory as
-- construct builds them, without walking; the rest stay ghosts.
function M.rails.build(p,list)
  local built,why,order=0,{},{}
  local reach=p.build_distance or 0
  for _,spec in ipairs(list) do
    if distance(p.position,spec.position)<=reach then
      local g=p.surface.find_entities_filtered{position=spec.position,radius=0.1,ghost_name=spec.name,force=p.force,limit=1}[1]
      local proto=prototypes.entity[spec.name]
      local item=proto and proto.items_to_place_this and proto.items_to_place_this[1]
      if g and g.valid and item then
        local ok,err=pcall(build_one,p,{item=item.name,position=g.position,direction=spec.direction,entity=spec.name,stepped=true})
        if ok and not g.valid then built=built+1
        else
          local r=ok and 'the ghost remained' or reason(err)
          if not why[r] then order[#order+1]=r end
          why[r]=(why[r] or 0)+1
        end
      end
    end
  end
  local not_built={}
  for i=1,math.min(4,#order) do not_built[i]=why[order[i]]..'x '..order[i] end
  return built,#not_built>0 and not_built or nil
end
function handlers.rail_route(p,a)
  assert(a.ghosts==nil or type(a.ghosts)=='boolean','ghosts must be true or false')
  local plan=M.rails.plan(p,a)
  local out=plan.out
  if a.details then out.entities=plan.entities end
  local inv=p.get_main_inventory()
  for name,n in pairs(out.items) do
    local have=inv and inv.get_item_count(name) or 0
    if have<n then out.missing=out.missing or {}; out.missing[name]=n-have end
  end
  local placed=place_ghost_list(p,plan.entities)
  out.placed,out.failed,out.bounds,out.obstacles_marked=placed.placed,placed.failed,placed.bounds,placed.obstacles_marked
  if not a.ghosts and placed.placed>0 then out.built,out.not_built=M.rails.build(p,plan.entities) end
  return out
end
function handlers.train_stop(p,a)
  local name=a.name or a.station
  assert(type(name)=='string' and #name>=1 and #name<=100,'name (the station name) is 1..100 characters')
  assert(a.name==nil or a.station==nil or a.name==a.station,'name and station differ; give one of them')
  assert(a.ghosts==nil or type(a.ghosts)=='boolean','ghosts must be true or false')
  local limit=a.limit~=nil and integer(a.limit,nil,0,1000,'limit (0..1000)') or nil
  local cands=M.rails.stop_spot(p,a)
  -- The nearest spot, else the next ones serving the same way along the rail.
  local chosen,errs=nil,{}
  for _,c in ipairs(cands) do
    if c.heading==cands[1].heading and #errs<3 then
      local ok,ghost=pcall(place_ghost,p,{name='train-stop',position=c.spot,direction=M.rails.NAMES[c.heading]})
      if ok then chosen=c; c.ghost=ghost; break end
      errs[#errs+1]=string.format('(%g,%g): %s',c.spot.x,c.spot.y,reason(ghost))
    end
  end
  if not chosen then
    local ok,one_way=pcall(M.rails.line_signals,p,cands[1])
    error('no train stop fits beside the rail for trains heading '..M.rails.NAMES[cands[1].heading]..': '..(ok and one_way or table.concat(errs,'; ')),0)
  end
  chosen.ghost.backer_name=name
  if limit then chosen.ghost.trains_limit=limit end
  local h=chosen.heading
  local out={stop=name,position=chosen.spot,direction=M.rails.NAMES[h],serves='trains heading '..M.rails.NAMES[h],
    side=({[0]='east',[4]='south',[8]='west',[12]='north'})[h]..' of the rail',
    rail={position=chosen.rail.e.position,ghost=chosen.rail.ghost or nil},limit=limit}
  if not a.ghosts then
    local built,not_built=M.rails.build(p,{{name='train-stop',position=chosen.spot,direction=M.rails.NAMES[h]}})
    out.built=built>0 or nil; out.not_built=not_built
  end
  if not out.built then
    out.ghost=true
    out.bounds={left=chosen.spot.x,top=chosen.spot.y,right=chosen.spot.x,bottom=chosen.spot.y}
    if distance(p.position,chosen.spot)>(p.build_distance or 0) then out.reach=string.format('%.1f tiles from you, build reach %g',distance(p.position,chosen.spot),p.build_distance or 0) end
  end
  return out
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
  -- The forced ghost check also takes water and Gleba wetland once the force
  -- has landfill (Sol, shift09: 5 of 16 poles on wetland, which construct
  -- could not build): a spot the pole stands on as the tiles are comes first,
  -- else one with landfill under it (place_ghosts lays its ghost).
  local function dry(pos) return not M.dryrun.tile_fixes(p.surface,p.force,pole,pos,0) end
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
    for pass=1,2 do
      for _,d in ipairs({0,1,-1,2,-2}) do
        local try={x=pos.x+perp.x*d,y=pos.y+perp.y*d}
        local ok_dist=not last or distance(last,try)<=reach
        if ok_dist and free(try) and (pass==2 or dry(try)) then specs[#specs+1]={name=pole.name,position=try}; last=try; return end
      end
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
  -- Poles with no dry spot within 2 tiles stand on water or wetland: the
  -- tile items laid under them.
  local under,on,wet={},nil,0
  for _,spec in ipairs(specs) do
    local fixes=M.dryrun.tile_fixes(p.surface,p.force,pole,spec.position,0)
    if fixes then wet=wet+1 end
    for _,f in ipairs(fixes or {}) do
      if f.item then under[f.item]=(under[f.item] or 0)+1; on=on or f.tile end
    end
  end
  if next(under) then
    out.tiles_under=under
    local parts={}
    for name,n in pairs(under) do
      parts[#parts+1]=n..' '..name
      local have=p.get_main_inventory().get_item_count(name)
      if have<n then out.tiles_short=out.tiles_short or {}; out.tiles_short[name]=n-have end
    end
    table.sort(parts)
    out.tiles_note=string.format('%d pole%s with no dry spot within 2 tiles %s on %s: %s under %s, %s',wet,wet==1 and '' or 's',wet==1 and 'stands' or 'stand',on,
      table.concat(parts,', '),wet==1 and 'it' or 'them',
      a.dry_run and 'which the real call lays as tile ghosts for construct to build first' or 'laid as tile ghosts that construct builds first')
  end
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
        row.reason=out.reason; row.wires=out.wires
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
for _,name in ipairs({'paste','blueprint_place','place_ghosts','belt_route','pipe_route','rail_route','train_stop'}) do
  local handler=handlers[name]
  handlers[name]=function(p,a)
    local out=handler(p,a)
    -- construct works on the character's surface; platform ghosts are the hub's.
    if out.bounds and not (type(p)=='table' and rawget(p,'__platform')) then state().last_paste=state().last_paste or {}; state().last_paste[p.index]=out.bounds end
    return out
  end
end
-- Fluid ports of an entity not built yet (ports.lua; Gemini: a recipe moves
-- which fluid an electromagnetic plant's ports carry): each connection's tile,
-- the tile outside it where a pipe joins, facing, flow and the recipe's fluid
-- there, with what stands on that tile now.
function handlers.ports(p,a)
  assert(type(a.name)=='string','name is required: an entity (or the item that places it), e.g. electromagnetic-plant')
  local proto=prototypes.entity[a.name]
  if not proto and prototypes.item[a.name] then proto=prototypes.item[a.name].place_result end
  assert(proto,'unknown entity '..a.name)
  local direction=directions[a.direction or 'north']
  assert(direction and direction%4==0,'direction must be north, east, south or west')
  assert(a.mirror==nil or type(a.mirror)=='boolean','mirror must be true or false (the H/V flip of fluid machines)')
  local pos=M.dryrun.snap(proto,position(a.position),direction)
  local recipe=M.ports.recipe(proto,a.recipe)
  local rows,closed=M.ports.rows({prototype=proto,position=pos,direction=direction,mirroring=a.mirror==true},recipe)
  assert(#rows>0 or #closed>0,proto.name..' has no fluid connections')
  if charted(p,pos) then
    for _,r in ipairs(rows) do
      if not r.kind then
        for _,o in pairs(p.surface.find_entities_filtered{position=r.joins,radius=0.3,force=p.force,limit=4}) do
          if o.valid and o.type~='character' then r.there=o.type=='entity-ghost' and o.ghost_name..' (ghost)' or o.name; break end
        end
      end
    end
  end
  local unsure=false
  for _,r in ipairs(rows) do if type(r.fluid)=='string' and r.fluid:find('^one of ') then unsure=true end end
  local note
  if proto.crafting_categories and not recipe then note='the recipe decides which ports open and the fluid of each: pass recipe'
  elseif #closed>0 then note='closed ports take no pipe with this recipe' end
  return {name=proto.name,position=pos,direction=compass_names[direction],mirror=a.mirror or nil,recipe=recipe and recipe.name or nil,
    ports=rows,closed=#closed>0 and closed or nil,note=note,
    unsure=unsure and 'this machine has more boxes on a side than the recipe has fluids there; which fluid the extra port takes was not seen built' or nil}
end
-- trace (trace.lua, set up with supply below); here so platform= wraps it.
function handlers.trace(p,a) return M.trace.trace(p,a) end
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
for _,name in ipairs({'place_ghosts','deconstruct','cancel_deconstruction','paste','blueprint_place','grid','scan','inspect','configure','flush','circuit_set','circuit','wire','ports','cargo','trace'}) do
  local handler=handlers[name]
  handlers[name]=function(p,a)
    if a.platform==nil then return handler(p,a) end
    local args={}
    for k,v in pairs(a) do if k~='platform' then args[k]=v end end
    return handler(on_platform(p,a.platform),args)
  end
end
-- Another surface by remote view (inspect, circuit_set, wire surface=): one
-- of our platforms (by its name or its surface's), or a planet by name, where
-- the game's remote view shows visible chunks (radar coverage).
-- (A block: runtime.lua is near Lua's 200 top-level locals, tests/locals.lua.)
do
  local function on_surface(p,name)
    assert(type(name)=='string','surface is a planet, surface or platform name')
    for _,pl in pairs(p.force.platforms) do
      if pl.valid and (pl.name==name or (pl.surface and pl.surface.valid and pl.surface.name==name)) then return on_platform(p,pl.name) end
    end
    local s=game.get_surface(name)
    if not s then
      local known={}
      for _,each in pairs(game.surfaces) do if not each.platform then known[#known+1]=each.name end end
      table.sort(known)
      error('no surface named '..name..'; planets and surfaces: '..table.concat(known,', '),0)
    end
    if s==p.surface then return p end
    return setmetatable({__player=real(p),__remote=s.name},{
      __index=function(_,k) if k=='surface' then return s end return p[k] end,
      __newindex=function(_,k,v) p[k]=v end})
  end
  -- launch, configure and silo too (Astra 01:41: the silo on Vulcanus from Sunward above it); requests (Astra 02:20,
  -- board #377: a requester chest on Vulcanus feeding an assembler there).
  for _,name in ipairs({'inspect','circuit_set','circuit','wire','ores','launch','configure','silo','requests'}) do
    local handler=handlers[name]
    handlers[name]=function(p,a)
      if a.surface==nil then return handler(p,a) end
      -- launch's platform is where the rocket goes, not where the call acts.
      assert(name=='launch' or a.platform==nil,'give platform or surface, not both')
      -- requests on another surface acts on an entity there (a chest, a landing pad), never on your character.
      assert(name~='requests' or a.position~=nil,'requests with surface needs position (a requester or buffer chest, landing pad there)')
      local args={}
      for k,v in pairs(a) do if k~='surface' then args[k]=v end end
      return handler(on_surface(p,a.surface),args)
    end
  end
end
-- area {left_top, right_bottom} on feed, collect and transfer (Muse: "I hand-feed the same 5 ADV + 2 cable machines
-- every few minutes all shift"): our entities whose centre is inside it, of the call's types (feed and collect: their
-- defaults as in reach; transfer: machines, chests, wagons and the like), become its positions, nearest first, each by
-- its unit_number; then the call runs as with positions (a target out of reach is a row with the reach line).
do
  local MAX_SIDE,MAX_TARGETS=128,64
  local TRANSFER_TYPES={'container','logistic-container','linked-container','assembling-machine','furnace','lab','rocket-silo',
    'boiler','burner-generator','reactor','mining-drill','ammo-turret','artillery-turret','cargo-wagon','car','spider-vehicle',
    'cargo-landing-pad','roboport','agricultural-tower'}
  local function types_for(action,a)
    if a.types~=nil then
      assert(type(a.types)=='table' and #a.types>=1 and #a.types<=16,'types requires 1..16 entity types')
      return a.types
    end
    if action=='feed' then return a.recipe and {'assembling-machine','furnace'} or feeding.TYPES end
    if action=='collect' then return a.chests and collect_types.chests or collect_types.plain end
    return TRANSFER_TYPES
  end
  for _,action in ipairs({'feed','collect','transfer'}) do
    local handler=handlers[action]
    handlers[action]=function(p,a)
      if a.area==nil then return handler(p,a) end
      assert(a.positions==nil and a.position==nil and a.radius==nil,'give area, positions, position or radius: one of them')
      assert(type(a.area)=='table' and a.area.left_top and a.area.right_bottom,'area requires left_top and right_bottom')
      local lt,rb=position(a.area.left_top),position(a.area.right_bottom)
      assert(lt.x<rb.x and lt.y<rb.y and rb.x-lt.x<=MAX_SIDE and rb.y-lt.y<=MAX_SIDE,'area must be nonempty and at most '..MAX_SIDE..'x'..MAX_SIDE)
      local types=types_for(action,a)
      local found={}
      for _,e in pairs(p.surface.find_entities_filtered{area={left_top=lt,right_bottom=rb},force=p.force,type=types}) do
        local at=e.valid and e.position
        if at and at.x>=lt.x and at.x<=rb.x and at.y>=lt.y and at.y<=rb.y then found[#found+1]=e end
      end
      assert(#found>0,string.format('no %s of ours with its centre in (%g,%g)-(%g,%g)',table.concat(types,', ',1,math.min(#types,6))..(#types>6 and ', ...' or ''),lt.x,lt.y,rb.x,rb.y))
      assert(#found<=MAX_TARGETS,string.format('%d entities in the area; at most %d (a smaller area, or types)',#found,MAX_TARGETS))
      table.sort(found,function(x,y) return distance(p.position,x.position)<distance(p.position,y.position) end)
      local args={}
      for k,v in pairs(a) do if k~='area' then args[k]=v end end
      args.positions={}
      for i,e in ipairs(found) do args.positions[i]={x=e.position.x,y=e.position.y,unit_number=e.unit_number} end
      args.from_area=true
      local out=handler(p,args)
      if type(out)=='table' then out.area_targets=#found end
      return out
    end
  end
end
local permissions={walk='start_walking',move_to='start_walking',mine='begin_mining',pickup='change_picking_state',repair='start_repair',craft='craft',cancel_craft='cancel_craft',build='build',build_path='build',construct='build',place_ghosts='build',belt_route='build',pipe_route='build',pole_route='build',rail_route='build',train_stop='build',wire='wire_dragging',kite='change_shooting_state',revive_ghost='build',rotate='rotate_entity',configure='setup_assembling_machine',flush='flush_opened_entity_fluid',transfer='inventory_transfer',refuel='inventory_transfer',rearm='inventory_transfer',collect='inventory_transfer',feed='inventory_transfer',research='start_research',research_next='start_research',shoot='change_shooting_state',equip='inventory_transfer'}
for name,input in pairs(permissions) do
  local handler=handlers[name]
  handlers[name]=function(p,a)
    assert(not p.permission_group or p.permission_group.allows_action(defines.input_action[input]),'permission denied: '..input)
    return handler(p,a)
  end
end
-- A dry run (dryrun.lua): dry_run=true on place_ghosts, paste,
-- blueprint_place or build checks the plan the call would place and places
-- nothing. Dispatch turns such a request into this read, so the running
-- action and queue go on; a queue step with dry_run=true gets the same check.
function handlers.dry_run(p,a)
  local action,args=a.action,a.args
  assert(M.dryrun.ACTIONS[action],'dry_run takes action (place_ghosts, paste, blueprint_place, build or rail_route) and args (that call\'s arguments)')
  assert(type(args)=='table','args must be the call\'s arguments')
  assert(args.dry_run==nil or args.dry_run==true,'dry_run must be true or false')
  local inner={}
  for k,v in pairs(args) do if k~='dry_run' then inner[k]=v end end
  -- details (every entry with its footprint) is the paste's own argument; the others take it here.
  local details=inner.details==true
  if action~='paste' and action~='blueprint_place' then inner.details=nil end
  check_args(action,inner)
  M.turretammo.check(inner.ammo)
  local q=p
  if inner.platform~=nil and action~='build' then q=on_platform(p,inner.platform) end
  local kind=action=='build' and 'build' or (action=='place_ghosts' or action=='rail_route') and 'ghosts' or 'paste'
  local plan={kind=kind,mode=inner.mode,details=details,entities={},tiles={},standing=kind~='build'}
  local rail_plan
  -- Bounded work: a plan past these is refused before anything is checked.
  local function bounded()
    assert(#plan.entities<=M.dryrun.MAX_ENTITIES and #plan.tiles<=M.dryrun.MAX_TILES,string.format(
      'a dry run checks at most %d entities and %d tiles; this plan has %d entities and %d tiles so far (fewer repeat copies, or part of the layout)',
      M.dryrun.MAX_ENTITIES,M.dryrun.MAX_TILES,#plan.entities,#plan.tiles))
  end
  local copies,dx,dy=1,0,0
  local r=inner['repeat']
  if r~=nil then
    assert(kind~='build','repeat is for place_ghosts and paste')
    assert(type(r)=='table','repeat is {count,dx,dy}')
    copies=integer(r.count,1,1,64,'repeat count'); dx,dy=r.dx or 0,r.dy or 0
    assert(type(dx)=='number' and type(dy)=='number' and (dx~=0 or dy~=0),'repeat needs a nonzero dx or dy')
  end
  local paste
  for k=0,copies-1 do
    local copy=copies>1 and k+1 or nil
    if action=='rail_route' then
      -- The route as rail_route plans it (rails.lua), each piece checked;
      -- its signals go with the plan's rails (after_rails).
      rail_plan=M.rails.plan(q,inner)
      for i,e in ipairs(rail_plan.entities) do plan.entities[i]={index=i,name=e.name,position=e.position,direction=directions[e.direction]} end
    elseif kind=='ghosts' then
      assert(inner.entities~=nil or inner.tiles~=nil,'place_ghosts requires entities and/or tiles')
      if inner.entities~=nil then
        assert(type(inner.entities)=='table' and #inner.entities>=1 and #inner.entities<=256,'entities requires 1..256 {name,position,direction?}')
        for i,spec in ipairs(inner.entities) do
          assert(type(spec)=='table','entry must be {name,position,direction?,type?}')
          local pos=position(spec.position)
          pos={x=pos.x+k*dx,y=pos.y+k*dy}
          local tile=not prototypes.entity[spec.name or ''] and tile_named(spec.name)
          if tile then plan.tiles[#plan.tiles+1]={index=i,copy=copy,name=tile,position=pos}
          else
            local dir=spec.direction and directions[spec.direction]
            assert(spec.direction==nil or dir,'direction must be a compass name')
            plan.entities[#plan.entities+1]={index=i,copy=copy,name=spec.name,position=pos,direction=dir or 0,ug_type=spec.type}
          end
        end
      end
      if inner.tiles~=nil then
        local t=inner.tiles
        assert(type(t)=='table' and type(t.area)=='table','tiles requires {name, area={left_top,right_bottom}}')
        local tile=tile_named(t.name); assert(tile,'tiles name must be a tile or an item that places one')
        local lt,rb=position(t.area.left_top),position(t.area.right_bottom)
        local x0,y0,x1,y1=math.floor(lt.x),math.floor(lt.y),math.ceil(rb.x)-1,math.ceil(rb.y)-1
        assert(x1>=x0 and y1>=y0 and (x1-x0+1)*(y1-y0+1)<=4096,'tiles area must be 1..4096 tiles')
        for x=x0,x1 do for y=y0,y1 do plan.tiles[#plan.tiles+1]={copy=copy,name=tile,position={x=x+0.5+k*dx,y=y+0.5+k*dy}} end end
      end
    elseif kind=='build' then
      if inner.builds~=nil then assert(type(inner.builds)=='table' and #inner.builds>=1 and #inner.builds<=64,'builds requires 1..64 {item,position,direction} entries') end
      for i,b in ipairs(inner.builds or {inner}) do
        assert(type(b)=='table','each build must be an object')
        local item=b.item or inner.item
        assert(type(item)=='string','item is required')
        local ip=prototypes.item[item]; assert(ip,'unknown item '..item)
        local pos=position(b.position)
        if ip.place_as_tile_result then
          for _,t in ipairs(M.dryrun.brush(pos,integer(b.size or inner.size,1,1,4,'size'))) do
            plan.tiles[#plan.tiles+1]={index=i,name=ip.place_as_tile_result.result.name,item=item,position=t}
          end
        else
          local place=ip.place_result
          local okr,rails=pcall(function() return ip.rails end)
          if okr and type(rails)=='table' and #rails>0 then
            local want=b.entity or inner.entity
            place=nil
            for _,rl in ipairs(rails) do
              local n=type(rl)=='string' and rl or rl.name
              if not want or n==want then place=prototypes.entity[n]; break end
            end
          end
          assert(place,item..' places no entity here')
          local dir=directions[b.direction or inner.direction or 'north']; assert(dir,'invalid direction')
          plan.entities[#plan.entities+1]={index=i,name=place.name,position=pos,direction=dir,quality=b.quality or inner.quality,item=item,ug_type=b.type or inner.type}
        end
      end
    else
      local pa={}
      for kk,v in pairs(inner) do if kk~='repeat' then pa[kk]=v end end
      assert(copies==1 or inner.position~=nil,'repeat needs position')
      if inner.position~=nil then local p0=position(inner.position); pa.position={x=p0.x+k*dx,y=p0.y+k*dy} end
      local pl=M.paste_plan(q,pa)
      for _,e in ipairs(pl.entities) do e.copy=copy; plan.entities[#plan.entities+1]=e end
      for _,t in ipairs(pl.tiles) do t.copy=copy; plan.tiles[#plan.tiles+1]=t end
      paste=paste or {slot=pl.slot,label=pl.label,origin_at=pl.origin_at,center_at=pl.center_at,anchor=pl.anchor}
    end
    bounded()
  end
  local out,_,counts=M.dryrun.check(q,plan)
  out.action=action
  -- The ammo the turret ghosts would request (turretammo.lua; a blueprint's own requests are not counted here).
  if kind~='build' then
    local rows={}
    for _,e in ipairs(plan.entities) do
      local t=M.turretammo.takes(prototypes.entity[e.name])
      if t then
        local spec=kind=='ghosts' and type(inner.entities)=='table' and inner.entities[e.index] or nil
        local what=spec and spec.ammo
        if what==nil then what=inner.ammo end
        local c=M.turretammo.choose(t,q.surface,q.force,e.position,what)
        if c then M.turretammo.add(rows,c) end
      end
    end
    out.ammo_requests=#rows>0 and rows or nil
  end
  out.paste=paste
  out.rail_route=rail_plan and rail_plan.out or nil
  if kind=='paste' and (inner.mode or 'normal')=='normal' and (counts.refused_now or 0)>0 then
    out.paste_note=string.format('a normal paste is all or nothing: with %d entr%s the game refuses there now, it places no ghost at all; mode forced places the rest and marks trees and rocks in the way',
      counts.refused_now,counts.refused_now==1 and 'y' or 'ies')
  elseif kind=='build' and counts.fail_first then
    out.build_note=inner.skip_failed and string.format('skip_failed: entries that fail are skipped, the first #%d (%s)',counts.fail_first,counts.fail_why)
      or string.format('a build batch stops at the first entry that fails (the ones before it stay built): entry #%d (%s); with skip_failed the others build',
        counts.fail_first,counts.fail_why)
  end
  return out
end
for name in pairs(M.dryrun.ACTIONS) do
  local handler=handlers[name]
  handlers[name]=function(p,a)
    if type(a)=='table' and a.dry_run==true then return handlers.dry_run(p,{action=name,args=a}) end
    -- "dry_run":"true" must not build for real.
    assert(type(a)~='table' or a.dry_run==nil or a.dry_run==false,'dry_run must be true or false')
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
  fix_args=function(action,args) return M.aliases.fix(action,args,M.takes) end,
  busy=function(p,action)
    if action=='shoot' then return state().combat and state().combat[p.index]~=nil end
    if action=='drop' then return state().drop_jobs and state().drop_jobs[p.index]~=nil or false end
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
  on_step=function(index,action) M.selfview.request(index,action,true) end,
  step_begin=function(index,step) M.hauling.begin(index,step.order and 'order' or 'queue') end,
  step_done=function(index) M.hauling.done(index) end,
  on_fail=function(index,action,reason) M.selfview.failed(index,action,reason) end,
  completion=function(p,action)
    local last=action=='shoot' and state().last_combat or action=='drop' and state().last_drop or timed[action] and state().last
    return last and last[p.index]
  end,
  outcome=function(p,action)
    local last=action=='shoot' and state().last_combat or action=='drop' and state().last_drop or timed[action] and state().last
    return last and last[p.index] and last[p.index].outcome
  end
}
for name,handler in pairs(scheduler.handlers) do handlers[name]=handler end
-- A direct action a harness update stopped, started again from the call that started it (carry.lua).
function M.restart_call(index,call)
  local ok,err=pcall(function()
    local p=player(index,call.seated)
    handlers[call.action](p,call.args)
    local now=state().active[index]
    if now then now.call=call end
  end)
  return ok,(not ok) and reason(err) or nil
end
-- Standing orders (orders.lua): the agent's routines, run in its own queue
-- while its character is free.
M.orders=require('orders'){state=state,player=player,scheduler=scheduler,agents=function() return M.board.agents() end,
  condition=function(p,c) return conditions.check(p,c) end,validate_condition=function(c) return conditions.validate(c) end,
  busy=function(index)
    local action=state().active[index]
    if action then return action.kind end
    if state().combat and state().combat[index] then return 'shoot' end
  end,
  interrupt=function(index) M.stop_player(index,'interrupted') end,
  -- The agent's own last request (a clock a peek started is not one) or fh sleep poll.
  last_seen=function(index)
    local c=(state().clocks or {})[index]
    if not c then return nil end
    return math.max(not c.peeked and c.call_tick or 0,c.wait_tick or 0)
  end}
for name,handler in pairs(M.orders.handlers) do handlers[name]=handler end
-- Queue writes answer briefly: the revision, state, the next steps by id and
-- the last results; queue_status has the whole queue (agent-minds study: each
-- edit echoed 10-14 KB, and Sonnet sent its replies to /dev/null to cut them).
function M.queue_brief(q)
  local function step(s) return s and ((s.id or '?')..' '..tostring(s.action)..(s.label and ' ['..s.label..']' or '')) or nil end
  local pending={}
  for i,s in ipairs(q.pending or {}) do if i<=5 then pending[i]=step(s) end end
  local recent={}
  local h=q.history or {}
  for i=math.max(1,#h-1),#h do
    local r=h[i]
    local why=type(r.result)=='table' and (r.result.reason or r.result.outcome) or nil
    recent[#recent+1]=step(r)..(r.ok and ' ok' or ' failed')..(why and ': '..tostring(why) or '')
  end
  local f=q.last_failure
  return {revision=q.revision,paused=q.paused,active=q.active and step(q.active) or false,pending=pending,
    pending_count=#(q.pending or {}),recent=#recent>0 and recent or nil,
    last_failure=f and (step(f)..(type(f.result)=='table' and f.result.reason and ': '..tostring(f.result.reason) or '')) or nil,
    repeating=q.repeating or nil,cycle=q.cycle,next_cycle_tick=q.next_cycle_tick,guards=q.guards and #q.guards or nil,
    waiting=q.waiting,after_direct=q.after_direct,corrected=q.corrected,note='queue_status shows every step in full'}
end
for _,name in ipairs{'queue_submit','queue_repeat','queue_edit','queue_cancel','queue_resume'} do
  local handler=handlers[name]
  if handler then handlers[name]=function(p,a) return M.queue_brief(handler(p,a)) end end
end
clock=clock_module{state=state,lookup=function(index) return M.lookup(index) end}
for name,handler in pairs(clock.handlers) do handlers[name]=handler end
-- Direct wait_ticks and sleep/sleep_check (waits.lua).
M.waits=require('waits'){state=state,integer=integer,
  replace=function(p) if state().active[p.index] then finish(p.index,'replaced') else stop(p) end end,
  advance=function(p,ticks) return clock.handlers.advance(p,{ticks=ticks}) end,clock_mode=function() return clock.report().mode end,
  traveling=function(index) local b=M.bots.record(index); return b~=nil and b.travel~=nil end,
  dead_until=function(index) local b=M.bots.record(index); return b and not b.travel and not M.bots.alive(b) and b.dead_until_tick or nil end,
  board_seq=function() return M.board.seq() end,board_news=function(p,seq) return M.board.news(p,seq) end,
  egg_seq=function() return M.spoil.seq() end,egg_news=function(p,seq) return M.spoil.news(p,seq,M.board.who(p)) end,
  condition=function(p,c) return conditions.check(p,c) end,validate_condition=function(c) return conditions.validate(c) end}
for name,handler in pairs(M.waits.handlers) do handlers[name]=handler end
M.chat=M.chat_module{state=state,on_say=function(p,text) M.profiles.say(p,text) end,audience=function() return M.cameras.audience() end,
  on_message=function(m) M.board.on_message(m) end,on_read=function(index,messages) M.board.on_read(index,messages) end,
  on_viewer=function(m) M.board.on_viewer(m) end,
  -- say look= checks (chat.lua): a platform by name, a teammate by name
  platform=function(p,name) return space.platform(p,name) end,agents=function() return M.board.agents() end,
  mention_of=function(index,m) return M.board.mention_of(index,m) end,
  where_from=function(index) local p=M.lookup(index); return p and p.valid and M.where.from(M.board.who(p)) or nil end}
for name,handler in pairs(M.chat.handlers) do handlers[name]=handler end
-- Confessionals and the operator's viewer relay (audience.lua).
M.audience=require('audience'){state=state,post_viewer=function(name,text) return M.chat.viewer(name,text) end,
  notice=function(from,text) return M.chat.notice(from,text) end,agents=function() return M.board.agents() end,
  director=function(index) return M.is_director(index) end}
for name,handler in pairs(M.audience.handlers) do handlers[name]=handler end
for name,handler in pairs(M.profiles.handlers) do handlers[name]=handler end
-- Team board, reply hints, harness requests and saved plans (board.lua).
-- Bots are never directors (and game.get_player refuses their indices).
function M.is_director(index) return not M.bots.is_index(index) and M.cameras.director(index) end
M.board=require('board'){state=state,claims=M.claims,director=function(index) return M.is_director(index) end,bots=function() return M.bots.list() end,
  profile=function(index) return M.profiles.get(index) end,validate_plan=function(a) return scheduler.validate(a) end,
  submit=function(p,a) return handlers.queue_submit(p,a) end,
  research_lines=function(p,h) return M.research.lines(p,h) end,
  attack_line=function(v,again,reader) return threat.attack_line(v,again,reader) end,news_lines=function(from,since,reader) return threat.news_lines(from,since,reader) end,
  watch=function(p) return threat.watch(p) end,where_from=function(me) return M.where.from(me) end,
  platform_lines=function(p,h) return M.platalerts.lines(p,h) end,drop_lines=function(p,h) return M.drops.lines(p,h) end,push_lines=function(p,h) return M.pushalerts.lines(p,h) end,
  hatch_lines=function(p,h) return M.spoil.alert_lines(p,h,M.board.who(p)) end,
  science_line=function(p,h) return M.scienceline.lines(p,h) end}
for name,handler in pairs(M.board.handlers) do handlers[name]=handler end
-- Research news, who queued what, and the queue's times (research.lua).
M.research=require('research'){state=state,board_event=function(by,item,change,text) return M.board.system_event(by,item,change,text) end}
function handlers.research_done(p,a) return M.research.done(p,a) end
function handlers.research_options(p,a) return M.research.options(p.force,a) end
-- Where an item is stored, nearest first (stores.lua).
M.stores=require('stores'){agents=function() return M.board.agents() end,
  character=function(index) local ok,p=pcall(M.lookup,index); return ok and p and p.valid and p.character or nil end}
function handlers.where_is(p,a) return M.stores.where_is(p,a) end
-- Tells: lines to named teammates outside the chat (tells.lua).
M.tells=require('tells'){state=state,resolve=M.board.resolve,agents=M.board.agents,who=M.board.who,deliver=M.board.deliver,
  where_from=function(me) return M.where.from(me) end}
for name,handler in pairs(M.tells.handlers) do handlers[name]=handler end
-- Idle characters for the operator's nudge (idle.lua): idle_report, and the
-- standing clock idle_tick keeps.
M.idle=require('idle'){state=state,agents=function() return M.board.agents() end,
  mention_counts=function() return M.board.operator('mention_counts',{}) end,
  unread=function(index) return M.chat.unread(index,'peek') end,
  orders=function(index) return M.orders.report(index) end,
  has_body=function(index)
    local ok,p=pcall(M.lookup,index)
    return ok and p~=nil and p.valid and p.character~=nil and p.character.valid or false
  end,
  position=function(index)
    local ok,p=pcall(M.lookup,index)
    if ok and p and p.valid and p.character and p.character.valid then return p.character.position end
  end,
  is_read=function(action) return M.is_read(action) end,
  is_talk=function(action) return M.board.handlers[action]~=nil or M.players.handlers[action]~=nil or M.votes.handlers[action]~=nil end}
-- The agent's own play (selfview.lua): team.review every 2 game hours and the
-- review read (actions and time by kind, repeated hand hauls, failures, open
-- alerts in its claims, losses near its work); team.shift.retro at shift start.
-- Hand hauling per agent, for the stream and the site (hauling.lua; viewer Joonazan, 05:00).
M.hauling=require('hauling'){state=state,
  name=function(index) local ok,p=pcall(M.lookup,index); return ok and p and p.valid and M.board.who(p) or tostring(index) end,
  active=function(index) return state().active and state().active[index] end,
  order_step=function(index) local q=(state().queues or {})[index]; return q and q.current and q.current.order end}
M.selfview=require('selfview'){state=state,is_read=function(action) return M.is_read(action) end,
  talk=function(action) return M.idle.TALK[action]~=nil or M.board.handlers[action]~=nil or M.players.handlers[action]~=nil or M.votes.handlers[action]~=nil end,
  waiting=function(s,index) return M.idle.waiting(s,index) end,
  has_body=function(index)
    local ok,p=pcall(M.lookup,index)
    return ok and p~=nil and p.valid and p.character~=nil and p.character.valid or false
  end,
  where=function(index)
    local ok,at=pcall(function()
      local p=M.lookup(index)
      local c=p and p.valid and p.character
      if c and c.valid then return {x=math.floor(c.position.x+0.5),y=math.floor(c.position.y+0.5),s=c.surface and c.surface.name} end
    end)
    return ok and at or nil
  end,
  name=function(index) local ok,p=pcall(M.lookup,index); return ok and p and p.valid and M.board.who(p) or tostring(index) end,
  is_director=function(index) return M.is_director(index) end,
  claims=function(name)
    local out={}
    for _,i in pairs((state().board or {}).items or {}) do
      if i.kind=='claim' and i.owner==name and i.area and ({open=true,claimed=true,doing=true,blocked=true})[i.status] then out[#out+1]=i.area end
    end
    return out
  end,
  claim_alerts=function(p) return M.pushalerts.claim_lines(p) end,
  losses=function() return state().losses or {} end,
  loss_line=function(i,reader) return describe_incident(i,reader) end,
  research_between=function(force,from,to) return M.research.finished_between(force,from,to) end,
  board_items=function() return (state().board or {}).items or {} end}
function handlers.review(p,a) return M.selfview.read(p,a) end
-- Where teammates are (where.lua): status teammates, and the place of a
-- sender or claim owner on another planet in tells, chat and the board.
M.where=require('where'){state=state,bot=function(index) return M.bots.record(index) end,lookup=function(index) return M.lookup(index) end,
  agents=function() return M.board.agents() end,
  human=function(index) return not M.bots.is_index(index) and not (state().controlled and state().controlled[index]) end}
-- Why an underground belt or pipe-to-ground is unpaired (underpass.lua).
M.underpass=require('underpass'){}
-- Camera highlights (highlights.lua): drawn for the director camera clients
-- only, by the stream service as the operator; no agent action reaches them.
M.highlights=require('highlights'){state=state,director=function(index) return M.is_director(index) end,
  agent=function(name)
    local b=M.bots.named(name)
    local index=b and b.index
    local c=b and b.character
    if not b then
      local p=game.get_player(name)
      if not (p and p.valid) or M.is_director(p.index) then return nil end
      index,c=p.index,p.character
    end
    local pr=M.profiles.get(index)
    return {character=c,color=pr and pr.rgb or nil}
  end}
-- What agents are doing, drawn for the camera clients only (visuals.lua):
-- mining progress and particles, crafting queues, routes, item moves, work rings.
M.visuals=require('visuals'){state=state,lookup=function(index) return M.lookup(index) end,
  active=function(index) return state().active[index] end,
  color=function(index) local pr=M.profiles.get(index); return pr and pr.rgb or nil end,
  cameras=function()
    local out={}
    for _,p in pairs(game.connected_players) do if M.is_director(p.index) then out[#out+1]=p.index end end
    table.sort(out)
    return out
  end,
  agents=function()
    local out={}
    for _,b in ipairs(M.bots.list()) do out[#out+1]=b.index end
    for index in pairs(state().controlled or {}) do out[#out+1]=index end
    return out
  end}
-- Platform health alerts in team.alerts (platalerts.lua): hits, turret ammo,
-- repair packs, hub health, to the platform's creator, workers and riders.
M.platalerts=require('platalerts'){state=state,agents=function() return M.board.agents() end,bot=function(index) return M.bots.record(index) end,
  lookup=function(index) return M.lookup(index) end,who=function(p) return M.board.who(p) end}
-- Human players: their log and restore (players.lua). Bots, camera clients
-- and attached agents are not humans.
M.players=require('players'){state=state,
  is_human=function(index) return not M.bots.is_index(index) and not M.is_director(index) and not (state().controlled and state().controlled[index]) end,
  votes_on=function(target) return M.votes.on(target) end,
  notice=function(from,text) return M.chat.notice(from,text) end}
-- The agents' votes on viewers (mute, unmute) and human players (kick, ban,
-- trust): votes.lua. Active agents: bots and attached agents whose own last
-- request, or fh sleep poll (sleep_check), is within window ticks. Other peeks
-- do not count (a clock a peek started is marked peeked): the overlay peeks
-- at every bot's status every few seconds.
M.votes=require('votes'){state=state,notice=function(from,text) return M.chat.notice(from,text) end,
  active_agents=function(window)
    local out,clocks={},state().clocks or {}
    local function recent(c) return c and ((not c.peeked and game.tick-c.call_tick<=window) or (c.wait_tick and game.tick-c.wait_tick<=window)) end
    for _,b in ipairs(M.bots.list()) do if recent(clocks[b.index]) then out[#out+1]=b.name end end
    for index in pairs(state().controlled or {}) do
      local p=game.get_player(index)
      if p and recent(clocks[index]) then out[#out+1]=p.name end
    end
    return out
  end,
  viewer_name=M.audience.viewer_name,muted=M.audience.muted,mute=M.audience.mute,unmute=M.audience.unmute,muted_list=M.audience.muted_list,
  human=function(name) return M.players.find(name) end,group=function(p) return M.players.group(p) end}
for name,handler in pairs(M.votes.handlers) do handlers[name]=handler end
for name,handler in pairs(M.players.handlers) do handlers[name]=handler end
function handlers.cameras() return M.cameras.list() end
-- wait_until as a direct call: a timed action that holds the character idle
-- until the condition is met (outcome met) or the timeout passes (timed_out),
-- so `fh call wait_until --wait` works outside a queue (in turn mode the
-- clock runs for it like any timed action).
function handlers.wait_until(p,a)
  if a.pause_queue~=nil then
    local copy={}
    for k,v in pairs(a) do if k~='pause_queue' then copy[k]=v end end
    a=copy
  end
  conditions.validate(a)
  local timeout=integer(a.timeout,3600,1,54000,'timeout (1..54000 ticks)')
  local condition={}
  for k,v in pairs(a) do if k~='timeout' and k~='pause_queue' then condition[k]=v end end
  -- Met already: done at once, like construct with nothing to do.
  local ok,met,saw=pcall(conditions.check,p,condition)
  -- error, not assert: Factorio's Lua 5.2 assert puts the source line in front of the reason.
  if not ok then error(met,0) end
  if met then return {outcome='met',saw=saw,until_tick=game.tick} end
  if state().active[p.index] then finish(p.index,'replaced') else stop(p) end
  state().active[p.index]={kind='wait_until',condition=condition,saw=saw,until_tick=game.tick+timeout,next_check=game.tick+FEED_CHECK,start_tick=game.tick}
  return {until_tick=game.tick+timeout,condition=condition['until'],saw=saw}
end
-- Rendering observes the world without taking over character controls.
-- Actions that never drive the character; they leave a running queue alone.
local passive={order_set=true,order_remove=true,orders=true,orders_pause=true,orders_resume=true,circuit=true,train=true,sleep=true,profile=true,say=true,chat=true,confess=true,confessions=true,vote=true,votes=true,tell=true,tells=true,operator=true,clock=true,advance=true,requests=true,platform_create=true,platform_schedule=true,launch=true,drop=true,research=true,research_next=true,research_done=true,board_plan=true,craft=true,cancel_craft=true,place_ghosts=true,deconstruct=true,cancel_deconstruction=true,blueprint_import=true,blueprint_delete=true,flush=true}
-- circuit_set and wire (circuits.lua) leave the character and its queue alone, as circuit did.
passive.circuit_set=true; passive.wire=true
-- Planners and blueprint tools never drive the character, near or by remote
-- view: paste, blueprint_place and the route tools put ghosts down (as
-- place_ghosts), capture and copy read an area, cut marks it as the planner does.
for _,name in ipairs({'paste','blueprint_place','blueprint_capture','copy','cut','belt_route','pipe_route','pole_route','rail_route','train_stop','blueprint_save','blueprint_rename'}) do passive[name]=true end
local reads={ores=true,cargo=true,silo=true,dry_run=true,ports=true,placements=true,defense=true,flamers=true,labs=true,science=true,supply=true,sleep_check=true,describe=true,status=true,map=true,nearest=true,craftable=true,scan=true,power=true,grid=true,rates=true,bottleneck=true,stock=true,platforms=true,observe=true,inspect=true,recipes=true,technologies=true,blueprint_export=true,blueprint_list=true,screenshot=true,profiles=true,cameras=true,inventory=true,research_options=true,where_is=true,drops=true,game_alerts=true,review=true,networks=true}
reads.trace=true  -- trace.lua: a read (no stop, no queue pause)

-- Arguments are checked against describe, so a misspelt or unsupported key
-- fails loudly instead of silently falling back to a default. Describe keys
-- that document results rather than inputs are not arguments.
local DOC_ONLY={returns=true,note=true,reports=true,outcomes=true,status=true,usage=true,checked=true,max=true}
local TARGET={'name','unit_number'}
local EXTRA_ARGS={attach={'offline'},build={'quality','entity'},collect={'count','quality'},rearm={'quality'},refuel={'quality'},
  move_to={'within'},shoot={'auto'},transfer=TARGET,mine={'unit_number'},repair=TARGET,inspect=TARGET,rotate=TARGET,
  configure={'name','unit_number','quality'},revive_ghost={'unit_number'},observe={'scope'},requests=TARGET,launch=TARGET,
  board={'status'},board_post={'note'},board_update={'status','note'},plan_save={'note'}}
EXTRA_ARGS.circuit_set=TARGET
EXTRA_ARGS.trace=TARGET
-- observe forwards to the scoped views; a scoped call is checked as that view.
local VIEW_SCOPES={map=true,nearest=true,craftable=true,scan=true,power=true,grid=true,rates=true,bottleneck=true,stock=true,platforms=true,labs=true,science=true,supply=true,sleep_check=true}
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
      -- The valid name nearest the unknown one (Luna 06:20: filter on configure): a plural or singular, a name
      -- that starts with it, or at most 2 letters apart.
      local function apart(x,y)
        if math.abs(#x-#y)>2 then return 3 end
        local row={}
        for j=0,#y do row[j]=j end
        for i=1,#x do
          local prev,diag=row[0],row[0]
          row[0]=i
          for j=1,#y do
            prev=row[j]
            row[j]=math.min(row[j]+1,row[j-1]+1,diag+(x:sub(i,i)==y:sub(j,j) and 0 or 1))
            diag=prev
          end
        end
        return row[#y]
      end
      local k,closest,best=tostring(key),nil,3
      for _,v in ipairs(valid) do
        local d=(v==k..'s' or k==v..'s') and 0 or (#k>=3 and v:sub(1,#k)==k) and 1 or (#k>=4 and apart(k,v)) or 3
        if d<best then closest,best=v,d end
      end
      error('unknown argument '..k..' for '..action..'; valid: '..(#valid>0 and table.concat(valid,', ') or 'none')
        ..(closest and '; closest name: '..closest or ''),0)
    end
  end
end
M.check_args=check_args
-- An unknown argument of configure or circuit_set also names what the entity at the position takes (Luna 06:20:
-- configure {filter} on a long-handed inserter): "; long-handed-inserter at (3.5,2.5) takes: filters, ...".
function M.entity_args(request)
  local a=request.args
  if (request.action~='configure' and request.action~='circuit_set') or type(a)~='table' or type(a.position)~='table' then return '' end
  local p=player(request.player)
  local ok,e=pcall(entity,p,{position=a.position,name=a.name,unit_number=a.unit_number})
  if not ok then ok,e=pcall(remote_entity,p,{position=a.position,name=a.name,unit_number=a.unit_number}) end
  if not ok or not e then return '' end
  local what
  if request.action=='configure' then
    local takes={inserter='filters, filter_mode (alias mode), use_filters',loader='filters',['loader-1x1']='filters',
      ['asteroid-collector']='filters (asteroid chunk names)',['assembling-machine']='recipe, quality, force',
      ['rocket-silo']='auto_requests, send_to_orbit_automatically'}
    what=takes[e.type] or (e.type=='furnace' and 'nothing of its own: a furnace takes its recipe from what it smelts')
      or 'nothing of its own: configure sets recipes (assembling machines), item filters (inserters, loaders, asteroid collectors) and rocket silo switches'
  else what=M.circuits.takes(e) end
  return string.format('; %s at (%g,%g) takes: %s; and position, name, unit_number, platform, surface',e.name,e.position.x,e.position.y,what)
end
-- Whether an action takes an argument (describe's schema, as check_args reads it).
function M.takes(action,key)
  if not allowed_args then pcall(check_args,'describe',{}) end
  local set=allowed_args and allowed_args[action]
  return set~=nil and set[key]==true
end
-- An electric machine no pole reaches (no electric network): the nearest pole
-- and how far, else nil. Generators, poles and storage are not machines here.
function M.unpowered(e)
  if e.electric_network_id~=nil then return nil end
  local ok,src=pcall(function() return e.prototype.electric_energy_source_prototype end)
  if not (ok and src) then return nil end
  local own={['electric-pole']=true,['solar-panel']=true,accumulator=true,generator=true,['burner-generator']=true,
    ['electric-energy-interface']=true,['power-switch']=true,['fusion-generator']=true,['lightning-attractor']=true}
  if own[e.type] then return nil end
  local best,bd
  for _,pole in pairs(e.surface.find_entities_filtered{type='electric-pole',force=e.force,position=e.position,radius=64,limit=256}) do
    local d=distance(pole.position,e.position)
    if not bd or d<bd then best,bd=pole,d end
  end
  if not best then return 'unpowered: no pole reaches it, none within 64 tiles' end
  return string.format('unpowered: no pole reaches it; nearest pole %s at (%g,%g), %d tiles',best.name,best.position.x,best.position.y,math.floor(bd+0.5))
end
-- Common wrong argument names renamed to the real ones (aliases.lua).
M.aliases=require('aliases'){}
-- An empty item move an agent repeats (agent-minds study: Haiku's 35 identical
-- feeds that gave nothing): the third identical one in 7 minutes says so.
M.MOVES={transfer=true,feed=true,collect=true,rearm=true,refuel=true}
-- Item moves say moved and end with the inventory line after the move (Muse 06:27, dozens a shift: transfer and
-- collect printed moved or transferred, and a tour's reply was a tick alone, which read as a failure).
M.ITEM_MOVES={transfer=true,feed=true,collect=true,rearm=true,refuel=true,pickup=true}
-- "free 12/80; held: copper-plate 400, iron-plate 20": free main inventory slots, then what the character holds of
-- the items named (up to 6).
function M.inv_line(p,names)
  local inv=p and p.valid and p.get_main_inventory()
  if not inv then return nil end
  local parts,seen={},{}
  for _,raw in ipairs(names or {}) do
    local name=tostring(raw):match('^[^@]+')
    if name and not seen[name] and #parts<6 then
      seen[name]=true
      local ok,n=pcall(function() return p.get_item_count(name) end)
      parts[#parts+1]=name..' '..((ok and n) or inv.get_item_count(name))
    end
  end
  local line=string.format('free %d/%d',inv.count_empty_stacks(),#inv)
  return #parts>0 and line..'; held: '..table.concat(parts,', ') or line
end
-- moved (transferred stays as its alias for a shift), timed for a reply that only starts the move, inv after it.
function M.moved_line(request,result)
  if result.moved==nil then
    if type(result.transferred)=='number' then result.moved=result.transferred
    elseif result.until_tick then
      result.moved=0
      result.timed=string.format('moves until tick %d: last.moved and last.inv say what it moved (status, fh --wait)',result.until_tick)
    end
  end
  local a,names=type(request.args)=='table' and request.args or {},{}
  local function add(v) if type(v)=='string' then names[#names+1]=v end end
  add(a.item); add(a.fuel); add(a.ammo)
  if type(a.items)=='table' then for k,v in pairs(a.items) do add(type(k)=='string' and k or v) end end
  if type(result.items)=='table' then for k,v in pairs(result.items) do add(type(v)=='table' and v.name or k) end end
  for _,row in ipairs(type(result.entities)=='table' and result.entities or {}) do
    for k in pairs(type(row)=='table' and type(row.gave)=='table' and row.gave or {}) do add(k) end
  end
  result.inv=M.inv_line(body(M.lookup(request.player or 1)),names)
end
-- The same on last when a pickup, a tour (collect, feed, refuel, rearm over a radius) or a wait for crafts ends.
function M.moved_last(index,action,last)
  local n,names=0,{}
  if action.kind=='pickup' then
    for name,c in pairs(action.picked or {}) do n=n+c; names[#names+1]=name end
  elseif action.kind=='gather' then
    n=action.got or 0
    names[#names+1]=action.item
    for k in pairs(action.items or {}) do names[#names+1]=k end
  else
    local r=last.result
    n=type(r)=='table' and (r.moved or r.transferred) or 0
    names[#names+1]=action.item
  end
  last.moved=n
  last.inv=M.inv_line(body(M.lookup(index)),names)
end
function M.repeats(index,action,args)
  local s=state(); s.empty_moves=s.empty_moves or {}
  local parts={action}
  for _,k in ipairs{'position','positions','item','items','direction','radius','fuel','ammo'} do parts[#parts+1]=M.aliases.encode(args[k]) end
  local key=table.concat(parts,' ')
  local keep,n={},1
  for _,m in ipairs(s.empty_moves[index] or {}) do
    if game.tick-m.tick<=25200 then keep[#keep+1]=m; if m.key==key then n=n+1 end end
  end
  keep[#keep+1]={key=key,tick=game.tick}
  while #keep>20 do table.remove(keep,1) end
  s.empty_moves[index]=keep
  if n>=3 then return string.format('%s %d times in 7 min with nothing moved (same target and item)',action,n) end
end
-- Game-time feedback on every reply: how long since this player's previous
-- request, and how much of it the character was idle (idle.lua busy(), the
-- nudge's own definition: no action and no running plan; a wait or sleep is
-- idle, named apart) or stood waiting for hand-crafted items.
-- Hand crafting runs alongside and is listed.
-- A peeking request (fh --wait polls) reports without restarting the count,
-- so the reply after a wait covers the whole wait; it still counts as seen.
local function clock_line(p,peek)
  local clocks=state().clocks or {}; state().clocks=clocks
  local c=clocks[p.index]
  local since=c and game.tick-c.call_tick or 0
  local idle=c and c.idle or 0
  local waited=c and c.craft_wait or 0
  local in_waits=c and c.in_waits or 0
  local kinds={}
  for kind in pairs(c and c.wait_kinds or {}) do kinds[#kinds+1]=kind end
  table.sort(kinds)
  if peek and c then c.seen_tick=game.tick
  else clocks[p.index]={call_tick=game.tick,idle=0,craft_wait=0,in_waits=0,peeked=peek or nil} end
  local function t(ticks)
    local sec=math.floor(ticks/60)
    if sec>=3600 then return string.format('%dh%02dm',math.floor(sec/3600),math.floor(sec/60)%60) end
    if sec>=60 then return string.format('%dm%02ds',math.floor(sec/60),sec%60) end
    return sec..'s'
  end
  local craft=p.character and crafting_left(p) or 0
  local function share(n) return since>0 and math.floor(100*n/since+0.5) or 0 end
  local waiting=waited>0 and string.format(', waiting on hand crafting %s of it (%d%%)',t(waited),share(waited)) or ''
  local slept=in_waits>0 and string.format(', %s of that in %s',t(in_waits),table.concat(kinds,'/')) or ''
  return string.format('game %s; +%s since your last request, character idle %s of it (%d%%%s)%s; hand crafting %s queued',
    t(game.tick),t(since),t(idle),share(idle),slept,waiting,t(craft*60))
end
local function idle_tick()
  local s=state()
  for index,c in pairs(s.clocks or {}) do
    if not M.idle.busy(s,index) then
      c.idle=c.idle+1
      local kind=M.idle.waiting(s,index)
      if kind then c.in_waits=(c.in_waits or 0)+1; c.wait_kinds=c.wait_kinds or {}; c.wait_kinds[kind]=true end
    elseif s.active[index] and s.active[index].awaiting_craft then c.craft_wait=(c.craft_wait or 0)+1 end
  end
  -- When each character started standing (no action, no running queue, a body
  -- on the map), once a second, unlike the per-request idle count above
  -- (idle.lua idle_report: the operator's idle nudge).
  if game.tick%60==0 then M.idle.stand_tick(); pcall(M.selfview.tick) end
end
local dispatch_request
-- A failed request is counted for the agent's review (selfview.lua) and
-- raised again unchanged (control.lua reads it as before).
function M.dispatch(request)
  local ok,result=pcall(M.dispatch_inner,request)
  if type(request)=='table' and type(request.player)=='number' and request.operator~=true then pcall(M.hauling.done,request.player) end
  if not ok then pcall(M.selfview.dispatch_failed,request,result); error(result,0) end
  return result
end
function M.dispatch_inner(request)
  M.carry.carry()
  -- Operator tools (RCON, never fh) read and answer the board as `operator`
  -- without a player. A failure must stop nobody (the bootstrap stops player 1).
  if request.operator==true then
    local ok,result=pcall(function()
      assert(request.player==nil and request.bot==nil,'an operator request names no player or bot')
      local relay=M.audience.operator[request.action] or M.tells.operator[request.action] or M.players.operator[request.action] or M.votes.operator[request.action] or M.idle.operator[request.action] or M.hauling.operator[request.action]
        or M.highlights.operator[request.action] or threat.operator[request.action] or M.orders.operator[request.action] or M.bplibrary_operator[request.action]
      if relay then return relay(request.args or {}) end
      M.check_args(request.action,request.args)
      return M.board.operator(request.action,request.args)
    end)
    if not ok then passive_failed=game.tick; error(result,0) end
    return result
  end
  -- A bot is addressed by name and handled under its index from here on
  -- (the bootstrap's failure cleanup reads request.player too).
  if request.bot~=nil then
    assert(request.player==nil,'a request may name a player or a bot, not both')
    request.player=M.bots.index_of(request.bot)
  end
  -- Items this request moves by hand are a direct call's (hauling.lua).
  if type(request.player)=='number' then pcall(M.hauling.begin,request.player,'direct') end
  -- Wrong argument names the harness knows (craft item, move_to target, ...)
  -- run as the call meant; the reply says the call as it ran (corrected).
  local corrected
  do
    local ok,action,args,fix=pcall(M.aliases.fix,request.action,request.args,M.takes)
    if ok and fix then request.action,request.args,corrected=action,args,fix end
  end
  -- dry_run=true on place_ghosts, paste, blueprint_place or build is a read of
  -- the plan (dryrun.lua): it leaves the running action and queue alone.
  if type(request.args)=='table' and request.args.dry_run~=nil and request.args.dry_run~=false and M.dryrun.ACTIONS[request.action] then
    request.args={action=request.action,args=request.args}; request.action='dry_run'
  end
  -- A failed request of an action that does not drive the character, from the
  -- argument check on, stops nothing (shift04: a failed placements read and a
  -- board_update with an unknown argument each paused Sol's queue; control.lua's
  -- own list of reads lacks those).
  passive_failed=false
  local result
  -- A corrected call that still fails says how it ran.
  local function ran(r) return corrected and tostring(r)..' [ran as '..corrected.call..': '..table.concat(corrected.notes,'; ')..']' or r end
  if M.keeps(request.action,request.args) then
    local ok,r=pcall(dispatch_request,request)
    if not ok then M.seated_ok=nil; passive_failed=game.tick; error(ran(r),0) end
    result=r
  elseif corrected then
    local ok,r=pcall(dispatch_request,request)
    if not ok then M.seated_ok=nil; error(ran(r),0) end
    result=r
  else result=dispatch_request(request) end
  M.seated_ok=nil
  if corrected and type(result)=='table' then
    result.corrected=corrected.call..' ('..table.concat(corrected.notes,'; ')..')'
  end
  -- Item moves: moved, and the inventory line after the move (Muse 06:27).
  if type(result)=='table' and M.ITEM_MOVES[request.action] then pcall(M.moved_line,request,result) end
  -- The same empty move again (M.repeats).
  if type(result)=='table' and M.MOVES[request.action] and type(request.args)=='table'
    and (result.nothing_moved or (result.transferred==0 and not result.inventory_full and not result.entity_full)) then
    local ok,r=pcall(M.repeats,request.player,request.action,request.args)
    if ok and r then result.repeated=r end
  end
  if clock then clock.after_dispatch() end
  if request.action=='status' then M.bots.status(request.player,result) end
  if type(result)=='table' and request.action~='describe' and request.action~='profiles' and request.action~='cameras' then
    local p=M.lookup(request.player or 1)
    local peek=type(request.args)=='table' and request.args.peek==true
    -- The agent's previous request before this one (the shift block counts research since then).
    local before=p and p.valid and (state().clocks or {})[p.index]
    local last_call=before and not before.peeked and before.call_tick or nil
    if p and p.valid then result.clock=clock_line(p,peek) end
    if p and p.valid and not M.is_director(p.index) then
      -- Operator tells ride on every reply until a game action or message (tells.lua operator_lines).
      local consume=not peek and not M.is_read(request.action) and not M.idle.WAITS[request.action] and request.action~='sleep_check'
        and not ({chat=true,tells=true,board=true,board_events=true,queue_status=true,research_done=true,players=true,votes=true,requests=true})[request.action]
      result.operator=M.tells.operator_lines(p.index,consume)
      -- What the agent did, for the nudge's counts and the end of standing (idle.lua).
      if not peek or request.action=='sleep' then
        pcall(M.idle.request,p.index,request.action,request.args,result)
        pcall(M.selfview.request,p.index,request.action)
      end
      -- An fh --wait poll learns that a tell or mention arrived: it ends the wait (cli.ts).
      if peek and request.action=='status' then
        local t,woke,from=M.board.inbox_tick(p.index)
        if t then result.inbox={tick=t,woke=woke,from=from} end
      end
    end
    -- Standing orders: which runs and why, or what they wait for (orders.lua).
    if p and p.valid and result.orders==nil then result.orders=M.orders.line(p.index) end
    -- Who works on which platform, for its alerts (platalerts.lua).
    if p and p.valid and not peek and type(request.args)=='table' then
      pcall(M.platalerts.note,p,request.action,request.args,result)
      -- A brief ring on what a building, removing or configuring request acted on (visuals.lua).
      pcall(M.visuals.worked,p,request.action,request.args)
    end
    -- The owner's own request standing in a claim of theirs, or acting on a position in it, keeps it fresh (claims.lua).
    if p and p.valid and not peek then pcall(M.claims.worked,p,request.args) end
    -- An fh sleep poll keeps a sleeping agent active for votes (votes.lua).
    if p and p.valid and peek and (request.action=='sleep_check' or (request.action=='observe' and request.args.scope=='sleep_check')) then
      local c=(state().clocks or {})[p.index]; if c then c.wait_tick=game.tick end
    end
    -- What is new for this agent (mentions, board, attacks/losses, reminders);
    -- directors and peeking readers (overlays) leave the agent's cursors alone.
    if p and p.valid and not peek and request.action~='board_events' and not M.is_director(p.index) then
      result.team=M.board.team(p,M.ground.unseen(p,unseen_losses(p)))
      -- A chat read that left messages unread is repeated until they are read.
      local left=request.action~='chat' and M.chat and M.chat.left(p.index)
      if left then result.team=result.team or {}; result.team.chat_remaining=left end
      local updated=M.carry.take(p.index)
      if updated then result.team=result.team or {}; result.team.harness_updated=updated end
      -- A repeating plan's rounds with short steps, when they changed (scheduler.lua).
      local rounds=scheduler.round_news(p.index)
      if rounds then result.team=result.team or {}; result.team.queue=rounds end
      -- The first reply of a shift: plan goals, open projects, research since the agent's last shift, researched and none built.
      local ok,shift=pcall(M.research.shift_block,p,last_call,function() return M.board.plan_for(M.board.who(p)) end)
      if not ok then local s=state(); s.research_errors={count=((s.research_errors or {}).count or 0)+1,last=tostring(shift),tick=game.tick}
      elseif shift then
        -- The networks, one line each, next to researched_none_built (networks.lua).
        local okn,lines=pcall(M.networks.lines,p.force,p.surface and p.surface.name,8)
        if okn and #lines>0 then shift.networks=lines end
        -- The previous shift for the team (selfview.lua retro).
        local okr,retro=pcall(M.selfview.retro,p)
        if okr and retro then shift.retro=retro end
        result.team=result.team or {}; result.team.shift=shift
      end
      -- The agent's own review, every 2 game hours (selfview.lua).
      local okv,review=pcall(M.selfview.review_due,p)
      if okv and review then result.team=result.team or {}; result.team.review=review end
    end
    if clock and request.action=='status' then result.time_mode=clock.report() end
    -- The unread trailer repeats only when a newer message arrived (status always shows it).
    if M.chat and p and p.valid and request.action~='chat' then result.chat=M.chat.unread(p.index,peek and 'peek' or request.action=='status' and 'always' or nil) end
  end
  return result
end
-- Actions that never drive the character (reads, talk, the board, crafting,
-- research, sleep, queue calls, votes; an unknown name): a direct call leaves
-- the running action and queue alone, and so does its failure.
function M.is_read(action) return reads[action]==true end
function M.keeps(action,args)
  return type(action)~='string' or not handlers[action] or reads[action] or passive[action] or action:match('^queue_')~=nil
    or M.board.handlers[action]~=nil or M.players.handlers[action]~=nil or M.votes.handlers[action]~=nil or M.away(args)
end
-- A call on a platform by name or on another surface by name (args alone).
function M.away(args) return type(args)=='table' and (args.platform~=nil or args.surface~=nil) end
-- A call that acts on another surface or by remote view leaves the character's
-- action and queue alone, as a passive one does (Astra, shift08: her Nauvis
-- courier queue paused about 30 times by platform configure and paste):
-- platform= on any action, surface= naming a surface other than the
-- character's, configure on an entity out of the character's reach (remote
-- view). Character-bound work (walking, mining, crafting, inventory moves,
-- building in reach) still takes over.
function M.remote(p,action,args)
  if type(args)~='table' then return false end
  if args.platform~=nil then return true end
  if args.surface~=nil then
    local ok,here=pcall(function()
      local s=p.surface
      return args.surface==s.name or (s.platform~=nil and s.platform.name==args.surface)
    end)
    return not (ok and here)
  end
  if action=='configure' then return not pcall(entity,p,args) end
  return false
end
dispatch_request=function(request)
  local handler=handlers[request.action]; assert(handler,'unsupported action; call describe')
  M.seated_ok=(reads[request.action] or passive[request.action] or M.away(request.args) or request.action=='vehicle' or request.action=='shoot') and true or nil
  local args_ok,args_err=pcall(check_args,request.action,request.args)
  if not args_ok then
    local ok,hint=pcall(M.entity_args,request)
    error(tostring(args_err)..(ok and hint or ''),0)
  end
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
    if not ok then passive_failed=game.tick; error(result,0) end
    return result
  end
  -- Human players (players.lua): reads, votes and restore act for the agent,
  -- dead or alive, and never stop its character.
  local humans=M.players.handlers[request.action] or M.votes.handlers[request.action]
  if humans then
    local p=M.lookup(request.player or 1); assert(p and p.valid,'player does not exist')
    assert(not M.is_director(p.index),'directors do not vote or restore')
    local ok,result=pcall(humans,p,request.args or {})
    if not ok then passive_failed=game.tick; error(result,0) end
    return result
  end
  -- A peek at the chat is a read any player can make (directors and
  -- overlays have no character).
  local peek=request.action=='chat' and type(request.args)=='table' and request.args.peek==true
  -- sleep_check (an observe scope) also answers for a dead character.
  local sleeping=request.action=='observe' and type(request.args)=='table' and request.args.scope=='sleep_check'
  if peek or sleeping or request.action=='status' or request.action=='queue_status' or request.action=='queue_cancel' then
    local p=M.lookup(request.player or 1); assert(p and p.valid,'player does not exist')
    if request.action=='queue_cancel' then M.orders.on_drive(p.index) end
    return handler(body(p),request.args or {})
  end
  -- A dead bot's observe answers when it respawns, as sleep_check does
  -- (shake4: 26 observe calls failed with "is dead").
  if (request.action=='observe' or VIEW_SCOPES[request.action]) and M.bots.is_index(request.player) then
    local b=M.bots.record(request.player)
    if b and not b.travel and not M.bots.alive(b) then
      return {dead=true,dead_until_tick=b.dead_until_tick,respawns_in_s=b.dead_until_tick and math.max(0,math.ceil((b.dead_until_tick-game.tick)/60)) or nil,
        note=string.format('bot %s is dead until tick %s; fh sleep SECONDS wakes at the respawn (respawned)',b.name,tostring(b.dead_until_tick))}
    end
  end
  -- A dead bot still talks (and sleeps until it respawns): it reads and answers the team while it waits to
  -- respawn (or rides a cargo pod). Otherwise a bot aboard a platform (or in a
  -- cargo pod) has no body: remote view only.
  local p
  if (request.action=='chat' or request.action=='say' or request.action=='sleep') and M.bots.is_index(request.player) then
    p=M.lookup(request.player); assert(p and p.valid,'player does not exist')
  else
    if M.bots.is_index(request.player) then M.bots.check_action(request.player,request.action,request.args) end
    p=player(request.player)
  end
  -- Passive, or acting on another surface or by remote view (M.remote): the action and queue go on.
  local quiet=passive[request.action] or M.remote(p,request.action,request.args)
  if not reads[request.action] and not quiet and not request.action:match('^queue_') then
    local q=state().queues and state().queues[p.index]
    -- A direct wait would pause a running queue (agent-minds study, fix 7:
    -- Sonnet's "queue resume, wait_ticks 20000" interrupted 22 queued walks,
    -- 0 jobs done in 105 minutes); it refuses unless asked to pause it. A
    -- standing order is not the agent's own queue: the wait preempts it and
    -- it resumes after (orders.lua).
    if (request.action=='wait_ticks' or request.action=='wait_until') and q and not q.paused and not q.order
      and (q.current or #q.pending>0 or q.loop) and (request.args or {}).pause_queue~=true then
      local n=#q.pending+(q.current and 1 or 0)
      passive_failed=game.tick  -- the refusal stops nothing (the bootstrap's failure cleanup)
      error(string.format('%s would pause your queue (%d step%s%s): a direct wait stops the character, and its queue with it. '..
        'Use fh sleep SECONDS [--until COND] or fh wait --until COND --max SECONDS: your queue keeps running and the wait ends when it finishes or stalls. '..
        'To pause the queue for this wait, pass pause_queue=true',request.action,n,n==1 and '' or 's',q.loop and ', repeating' or ''),0)
    end
    if q and not q.paused then M.stop_player(p.index) end
  end
  -- The agent's own character work and queue calls: standing orders wait a while after it (orders.lua hold).
  if not reads[request.action] and not quiet and request.action~='queue_status' then M.orders.on_drive(p.index) end
  if quiet then
    local ok,result=pcall(handler,p,request.args or {})
    if not ok then passive_failed=game.tick; error(result,0) end
    return result
  end
  local before=state().active[p.index]
  local result=handler(p,request.args or {})
  -- The call that started a direct action that moves or builds, so a harness update can start it again (carry.lua).
  local now=state().active[p.index]
  if now and now~=before and not now.queued and not M.carry.CONTINUE[now.kind] then now.call={action=request.action,args=request.args or {},seated=M.seated_ok} end
  return result
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
  local reach=action.reach or math.max(0.5,(p.character_running_speed or 0.15)*1.5)
  while action.waypoint<=#action.waypoints and distance(p.position,action.waypoints[action.waypoint].position)<=reach do action.waypoint=action.waypoint+1 end
  return action.waypoint<=#action.waypoints and action.waypoints[action.waypoint].position or goal
end
kite=kite_module{position=position,distance=distance,integer=integer,visible=visible,directions=directions}
threat=threat_module{state=state,known=known,distance=distance,on_character_hit=function(event) M.board.on_character_hit(event) end}
survey=survey_module{state=state,status_name=function(e) return entity_status_names[e.status] end,
  research_rate=function(force_name) return M.research.rate(force_name) end}
-- supply: where one item sits and why it does not reach its users (supply.lua), an observe scope.
M.supply=require('supply'){integer=integer,position=position,status_name=function(e) return entity_status_names[e.status] end,spoil=M.spoil,
  agents=function() return M.board.agents() end,lookup=function(index) return M.lookup(index) end,state=state}
function handlers.supply(p,a) return M.supply.supply(p,a) end
-- trace: a machine's feeders and their sources, its output followed to where it ends, an item's routes (trace.lua).
M.trace=require('trace'){supply=M.supply,entity=entity,remote_entity=remote_entity,position=position,integer=integer,status_name=function(e) return entity_status_names[e.status] end}
-- labs: research line diagnostics (labs.lua), an observe scope; science reads its packs through supply's scan.
M.labs=require('labs'){integer=integer,center=center,status_name=function(e) return entity_status_names[e.status] end,
  agents=function() return M.board.agents() end,lookup=function(index) return M.lookup(index) end,supply=M.supply}
function handlers.labs(p,a) return M.labs.view(p,a) end
function handlers.science(p,a) return M.labs.science(p,a) end
rates=rates_module{position=position,status_name=function(e) return entity_status_names[e.status] end}
-- Electric and logistic networks and turrets, one line each (networks.lua):
-- the shift block, the networks read, and the network push alerts.
M.networks=require('networks'){state=state}
function handlers.networks(p,a) return M.networks.read(p,a) end
-- One science line per agent in the team block, at most every 5 min and when it changed (scienceline.lua, operator 03:22).
M.scienceline=require('scienceline'){state=state,supply=M.supply,networks=M.networks,status_name=function(e) return entity_status_names[e.status] end}
-- The game's alerts and key warnings, pushed to the agents they concern (pushalerts.lua).
-- Lightning attractors on Fulgora whose catches have nowhere to go, and full accumulators beside them (lightning.lua).
M.lightning=require('lightning'){}
M.pushalerts=require('pushalerts'){state=state,agents=function() return M.board.agents() end,who=M.board.who,
  place=function(index) return M.where.place(index) end,targets=M.targets,
  network_groups=function(force)
    local out=M.networks.alert_groups(force)
    local ok,more=pcall(M.lightning.alert_groups,force)
    if ok then for _,g in ipairs(more) do out[#out+1]=g end
    else local s=state(); s.lightning_errors={count=((s.lightning_errors or {}).count or 0)+1,last=tostring(more),tick=game.tick} end
    return out
  end,
  -- an agent player's alert panel (camera players have theirs switched off: cameras.lua)
  alert_reader=function(force)
    for _,pl in pairs(force.players) do if pl.valid and pl.connected and not M.is_director(pl.index) then return pl end end
  end}
function handlers.game_alerts(p,a) return M.pushalerts.read(p,a) end
-- Where drops landed (drops.lua): their pods followed down, told in the team block, the drops read.
M.drops=require('drops'){state=state,integer=integer,who=M.board.who,resolve=M.board.resolve}
function handlers.drops(p,a) return M.drops.read(p,a) end
space=space_module{position=position,integer=integer,remote_entity=remote_entity,real=real,bots=M.bots,drops=M.drops,cargo=M.cargo,
  -- A full drop's pods waiting for a hatch: a channel of their own, as shoot's is, so the
  -- character's action and queue go on (drop is passive); M.drop_jobs_tick sends them.
  start=function(p,job) state().drop_jobs=state().drop_jobs or {}; state().drop_jobs[p.index]=job end,
  pending=function(p) return state().drop_jobs and state().drop_jobs[p.index] end,
  bot=function(p) return M.bots.is(p) and M.bots.named(rawget(p,'__bot')) or nil end,
  -- Riding or landing takes the character away: controls stop and a plan pauses.
  stop=function(p) M.stop_player(p.index) end,
  -- A platform's defence: hub health, turrets and their ammo against the hub's, repair packs (platalerts.lua).
  defense=function(pl) return M.platalerts.defense(pl) end}
-- A full drop's pods that wait for a hatch (space.lua), every 10 ticks: sent
-- as hatches free up, then the result kept as last_drop (status shows it,
-- and drop_pending while pods wait; --wait follows them as it does shoot).
function M.drop_jobs_tick(tick)
  local jobs=state().drop_jobs
  if not (jobs and next(jobs)) or tick%10~=0 then return end
  for index,job in pairs(jobs) do
    local ok,outcome=pcall(space.drop_tick,M.lookup(index),job)
    if not ok then job.why=reason(outcome); outcome='failed' end
    if not outcome and tick>job.until_tick then outcome='timed_out' end
    if outcome then
      local result,why=space.drop_result(job,outcome)
      state().last_drop=state().last_drop or {}
      state().last_drop[index]={kind='drop',outcome=outcome,tick=tick,result=result,why=why}
      jobs[index]=nil
    end
  end
end
function M.drop_pending(index)
  local job=state().drop_jobs and state().drop_jobs[index]
  return job and {kind='drop',platform=job.platform.valid and job.platform.name or nil,pods_sent=#job.sent,pods_left=#job.pods,until_tick=job.until_tick} or nil
end
-- The last full drop's result for a minute after it ended (a wait reads it once).
function M.last_drop(index)
  local last=state().last_drop and state().last_drop[index]
  return last and game.tick-last.tick<=3600 and last or nil
end
stock=stock_module{distance=distance,integer=integer,position=position,claims=M.claims,spoil=M.spoil,
  -- One stop of a rearm/refuel tour: top the entity up; stop when none is left.
  visit=function(p,action,e)
    if action.op=='feed' then
      -- A feed stop gives every want; the tour ends early once nothing the
      -- remaining machines want is left above the reserve.
      local gave,n=feeding.one(p,e,action.feed)
      for item,c in pairs(gave) do action.items=action.items or {}; action.items[item]=(action.items[item] or 0)+c end
      -- Each stop: what the machine got and its fuel after (last.entities).
      action.rows=action.rows or {}
      action.rows[#action.rows+1]={position=e.position,name=e.name,gave=next(gave) and gave or nil,got=n==0 and 'nothing' or nil,fuel=feeding.fuel_line(e)}
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
  take=function(p,e,item,quality,count,inv,tally) return transfer_one(p,{direction='to_player',item=item,quality=quality,count=count,inventory=inv,tally=tally},nil,e) end,
  request_path=function(p,nav) return request_path(p,nav) end,navigate=function(p,nav) return navigate(p,nav) end,
  stop_walking=function(p) p.walking_state={walking=false,direction=defines.direction.north} end}
-- Shared walking controller (move_to, construct). Follows the engine path when
-- one exists, else steers directly. A stall of a few ticks first sidesteps
-- perpendicular to the heading, then re-paths with a wider goal radius, and
-- only gives up after repeated failures. Diagnostics stay on `nav`.
local STALL_TICKS,SIDESTEP_TICKS,MAX_STALLS,MAX_REPLANS,PROGRESS_TICKS=8,12,15,5,90
navigate=function(p,nav)
  local pos,goal=p.position,nav.position
  -- A move_to never ends on a belt (shift08: Grok's arrivals on the y=-27.5
  -- belt carried it off, then transfers failed out of reach): from a belt it
  -- steps to the nearest free tile without one (pathing.lua).
  if nav.step_off then
    if distance(pos,nav.step_off)<=0.3 or game.tick-nav.step_off_tick>120 then return 'arrived' end
    steer(p,nav.step_off,nav); return
  end
  if distance(pos,goal)<=math.max(nav.tolerance,(p.character_running_speed or 0)*0.55) then
    local belt=nav.off_belts and M.pathing.belt_at(p.surface,pos)
    if not belt then return 'arrived' end
    local spot,within=M.pathing.off_belt_spot(p,goal,nav.tolerance)
    nav.off_belt={belt=belt.name,spot=spot,within=within}
    if not spot then return 'arrived' end
    nav.step_off=spot; nav.step_off_tick=game.tick; steer(p,spot,nav); return
  end
  local last=nav.last_position or pos
  local moved=distance(pos,last)
  local oscillating=nav.previous_position and distance(pos,nav.previous_position)<0.005 and moved>0.005
  nav.previous_position=last; nav.last_position={x=pos.x,y=pos.y}
  -- A goal inside an entity is unreachable; stopping just beside it is what
  -- callers targeting a machine or chest want.
  local near=distance(pos,goal)<=nav.tolerance+1.5
  -- Enemy worms and spawners near the way: read while the path is asked for (avoid.lua).
  if nav.foes then M.avoid.tick(p,nav) end
  if nav.path_state=='pending' or nav.path_state=='probing' or nav.path_state=='scanning' then
    -- The first level's belt-free twin may answer late: decide without it after a while.
    if nav.found then M.pathing.grace(p,nav) end
    if nav.path_state=='pending' or nav.path_state=='probing' or nav.path_state=='scanning' then p.walking_state={walking=false,direction=defines.direction.north}; nav.stalled=0; nav.progress_tick=nil; return end
  end
  if nav.path_state=='unreachable' then return 'unreachable' end
  if nav.path_state=='unsafe' then return 'no_safe_route' end
  -- Closed in: the way out by mining, a tick after the flood (pathing.lua dig_step).
  if nav.path_state=='digging' then p.walking_state={walking=false,direction=defines.direction.north}; M.pathing.dig_step(p,nav); return end
  -- The character's own steps searched, a slice a tick (pathing.lua search_tick): a build spot, or a squeeze walk's trail.
  if nav.path_state=='searching' then p.walking_state={walking=false,direction=defines.direction.north}; M.pathing.search_tick(p,nav); return end
  -- Squeezed in: walking out along the flood's trail, then asking again (pathing.lua escape).
  if nav.path_state=='escape' then
    local wp=waypoint_goal(p,nav,nav.escape.to)
    if nav.waypoint>#nav.waypoints and distance(pos,nav.escape.to)<=0.2 then M.pathing.escaped(p,nav); return end
    nav.escape_still=moved<0.005 and (nav.escape_still or 0)+1 or 0
    if nav.escape_still>=30 then
      local at=M.pathing.at
      nav.why=string.format('squeezed in at %s: walking out toward %s stalled at %s',at(nav.escape.from),at(nav.escape.to),at(pos))
      nav.escape=nil; nav.reach=nil; nav.escape_stalled=true
      return 'blocked'
    end
    steer(p,wp,nav); return
  end
  -- squeeze=true where no path request led: the character's own steps, walked as a trail (pathing.lua squeeze_begin, walk_trail).
  if nav.path_state=='trail' then
    local wp=waypoint_goal(p,nav,goal)
    nav.trail_still=moved<0.005 and (nav.trail_still or 0)+1 or 0
    if nav.trail_still>=30 then
      local at=M.pathing.at
      nav.why=string.format('walking the gaps from %s toward %s stalled at %s',at(nav.squeezed.from),at(goal),at(pos))
      return 'blocked'
    end
    steer(p,wp,nav); return
  end
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
    if nav.stalls>(nav.max_stalls or MAX_STALLS) then
      if not nav.direct and M.pathing.escape(p,nav) then nav.stalls=0; return end
      return 'blocked'
    end
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
  local wp=waypoint_goal(p,nav,goal)
  -- The path ended short of the goal: a move_to walks the rest straight only
  -- with room to turn (Sol, shift09 03:12: that last stretch took him into the
  -- 0.6-tile gap between two assembling machines, which no path led out of).
  if nav.pocket_check and not nav.leg and wp==goal and nav.waypoints and not nav.approach then
    nav.approach=true
    local sq=not nav.squeeze and M.pathing.in_gap(p.surface,goal,M.pathing.half(p.character),nav.tolerance,p.character)
    if sq then
      nav.pocket={at={x=sq.x,y=sq.y},by=sq.by,stop={x=pos.x,y=pos.y}}
      p.walking_state={walking=false,direction=defines.direction.north}
      return 'arrived_near'
    end
  end
  steer(p,wp,nav)
end
-- Route planners take only tiles the piece stands on as they are (or on a tile ghost ordered there), and a
-- route with no way says what tiles the straight line crosses (dryrun.lua; Sol, shift09: poles on Gleba wetland).
do
  local tiles={stands_fn=function(...) return M.dryrun.stands_fn(...) end,line_tiles=function(...) return M.dryrun.line_tiles(...) end}
  route=route_module{position=position,directions=directions,chunk_of=chunk_of,tiles=tiles}
  pipes=pipes_module{position=position,directions=directions,chunk_of=chunk_of,tiles=tiles}
end
construction=construction_module{position=position,distance=distance,integer=integer,visible=visible,steer=steer,real=real,
  known=known,reason=reason,directions=directions,waypoint_goal=waypoint_goal,
  request_path=function(p,nav) return request_path(p,nav) end,navigate=function(p,nav) return navigate(p,nav) end,
  build=function(p,a) return handlers.build(p,a) end,hand_mining_ticks=hand_mining_ticks,crafting_count=crafting_count}
local function blocked_product(p,action)
  for _,name in ipairs(action.products or {}) do
    if not p.can_insert{name=name} then return name end
  end
end
-- The nearest visible enemy within the shot's radius, rescanned every 6
-- ticks (cached per agent): auto shoot on foot and in a vehicle.
function M.combat_scan(p,action,index,tick)
  local cached=combat_targets()[index]
  if not cached or tick>=(cached.next_scan or 0) then
    local enemies={}
    for _,force in pairs(game.forces) do
      if force~=p.force and force.name~='neutral' and not p.force.get_friend(force) and not p.force.get_cease_fire(force) then enemies[#enemies+1]=force end
    end
    local best=action.radius+1
    cached={next_scan=tick+6}
    if #enemies>0 then
      for _,e in pairs(p.surface.find_entities_filtered{position=p.position,radius=action.radius,force=enemies,limit=256,type={'unit','spider-unit','segmented-unit','unit-spawner','turret','ammo-turret','electric-turret','character'}}) do
        local d=distance(p.position,e.position)
        if e.valid and visible(p,e.position) and d<best then best=d; cached.entity=e end
      end
    end
    combat_targets()[index]=cached
  end
  local e=cached.entity
  if e and e.valid and distance(p.position,e.position)<=action.radius and visible(p,e.position) then return e end
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
  M.carry.carry()
  idle_tick()
  M.research.tick(event.tick)
  M.bots.tick(event.tick)
  M.drops.tick(event.tick)
  M.drop_jobs_tick(event.tick)
  M.nametags.tick(event.tick)
  pcall(M.networks.tick,event.tick)  -- the networks' samples never stop the harness tick
  pcall(M.pushalerts.tick,event.tick)  -- the alert read, one stage a tick (task-statuscost)
  pcall(survey.tick,event.tick)  -- status's factory survey, a slice a tick (task-statuscost)
  pcall(threat.tick,event.tick)  -- the chart sweep, a slice a tick (task-statuscost)
  pcall(M.scienceline.tick,event.tick)
  if state().turret_deaths then pcall(M.turretammo.tick,event.tick) end  -- ammo requests on the ghosts of turrets that died
  M.ores.tick()  -- queued chunks of an ore survey, a few a tick (never raises)
  if event.tick%600==0 then pcall(M.avoid.prune) end  -- enemy chunk records older than a minute (avoid.lua)
  -- The egg watch, a bounded stage a tick (spoil.lua); a fault is counted, never stops the tick.
  do
    local ok,err=pcall(M.spoil.tick,event.tick)
    if not ok then local s=state(); s.spoil_errors={count=((s.spoil_errors or {}).count or 0)+1,last=tostring(err),tick=event.tick} end
  end
  M.seated_ok=nil
  for index,action in pairs(state().active) do
    local ok,p=pcall(player,index,action.kind=='drive')
    if not ok then
      finish(index,'player_unavailable')
    elseif (action.kind=='wait_ticks' or action.kind=='wait_until') and not action.queued and action.start_tick
      and event.tick%30==0 and (M.board.inbox_tick(index) or -1)>=action.start_tick then
      -- A tell or mention ends a direct wait (agent-minds study, fix 5: agents
      -- moved to waits nobody could interrupt; Grok chose wait_until for that).
      local _,kind,from=M.board.inbox_tick(index)
      action.told=from and kind..' by '..from or kind
      finish(index,kind)
    elseif event.tick>action.until_tick then
      finish(index,(action.kind=='move_to' or action.kind=='build_path' or action.kind=='construct' or action.kind=='kite' or action.kind=='feed' or action.kind=='gather' or action.kind=='wait_until' or action.kind=='drive' or action.area~=nil or (action.kind=='repair' and action.targets~=nil)) and 'timed_out' or 'duration_elapsed')
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
      -- Legs around enemies (avoid.lua): the next one starts where one ends.
      if outcome and action.foes and M.avoid.leg_done(p,action,outcome) then outcome=nil end
      -- Legs through via points: the next one starts where one arrives.
      if outcome and action.via and M.via_next(p,action,outcome,index) then outcome=nil end
      if outcome then finish(index,outcome) end
    elseif action.kind=='build_path' then
      local outcome=construction.tick(p,action)
      if outcome then finish(index,outcome) end
    elseif action.kind=='kite' then
      local outcome=kite.tick(p,action,event.tick)
      if outcome then finish(index,outcome) end
    elseif action.kind=='drive' then
      local outcome=M.vehicles.tick(p,action)
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
    elseif action.kind=='pickup' and action.area then
      local outcome=M.ground.tick(p,action,event.tick)
      if outcome then finish(index,outcome) end
    elseif action.kind=='pickup' then
      -- One item stack every 6 ticks; done when none is left in reach. No
      -- picking_state: the engine's own pickup would go uncounted in picked.
      if event.tick>=(action.next_pick or 0) then
        action.next_pick=event.tick+6
        local item=p.surface.find_entities_filtered{position=p.position,radius=action.reach or 1,type='item-entity',limit=1}[1]
        if not (item and item.valid and item.stack and item.stack.valid_for_read) then finish(index,action.picked and 'picked_up' or 'nothing_in_reach')
        else
          local name,count=item.stack.name,item.stack.count
          local q=item.stack.quality and item.stack.quality.name or nil
          local n=p.insert{name=name,count=count,quality=q}
          if n==0 then finish(index,'inventory_full')
          else
            action.picked=action.picked or {}; action.picked[name]=(action.picked[name] or 0)+n
            action.trashed=M.trash.count(p,action.trashed,name,q,n)
            if n>=count then item.destroy() else item.stack.count=count-n end
          end
        end
      end
    elseif action.kind=='repair' and action.targets then
      -- positions or area: the next damaged target once this one is full or gone; walk to one out of reach.
      while action.entity and M.repair_done(action.entity) do M.repair_next(p,action) end
      local e=action.entity
      if not e then finish(index,'repair_completed')
      elseif not p.can_reach_entity(e) then
        if not action.nav then
          action.nav={position=e.position,tolerance=math.max(1,(p.reach_distance or 10)-3),max_stalls=6,replans=0,stalled=0,last_position=p.position}
          request_path(p,action.nav)
        end
        if navigate(p,action.nav) then
          action.unreached=action.unreached+1; action.entity=nil
          p.walking_state={walking=false,direction=defines.direction.north}
          M.repair_next(p,action)
        end
      elseif not p.cursor_stack.valid_for_read or p.cursor_stack.prototype.type~='repair-tool' then finish(index,'repair_tool_exhausted')
      else
        if action.nav then action.nav=nil; p.walking_state={walking=false,direction=defines.direction.north} end
        action.working=true
        if M.bots.is(p) then M.bots.repair(p,e)
        else
          if p.selected~=e then p.selected=e end
          if not p.repair_state.repairing then p.repair_state={repairing=true,position=e.position} end
        end
      end
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
      elseif not p.can_reach_entity(e) then
        -- Walked or pushed off mid-mine: the same words as a refused mine.
        local ok,why=pcall(M.out_of_reach,p,e); action.error=ok and why or nil
        finish(index,'out_of_reach')
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
    -- Vehicle fire runs seated (vehicles.lua); the rest needs the character on foot.
    local ok,p=pcall(player,index,action.vehicle~=nil)
    if not ok or event.tick>action.until_tick then stop_combat(index,ok and (action.end_outcome or 'duration_elapsed') or 'player_unavailable')
    elseif action.vehicle then
      local aim=combat_targets()[index]
      local fixed=aim and aim.fixed
      if fixed and not fixed.valid then stop_combat(index,'target_destroyed')
      else
        local outcome=M.vehicles.combat_tick(p,action,fixed or (action.auto and M.combat_scan(p,action,index,event.tick)) or nil)
        if outcome then stop_combat(index,outcome) end
      end
    elseif action.ammo_start and kite.ammo_count(p)==0 and not kite.reload(p,action) then stop_combat(index,'out_of_ammo')
    else
      local target=action.position
      if action.auto then
        local e=M.combat_scan(p,action,index,event.tick)
        if e then target=e.position end
      end
      p.shooting_state={state=target and defines.shooting.shooting_enemies or defines.shooting.not_shooting,position=target or p.position}
    end
  end
  if event.tick%60==0 then feed_research_plans() end
  if event.tick%3600==0 then
    for _,connected in pairs(game.connected_players) do
      local ok,p=pcall(player,connected.index)
      if ok then pcall(survey.sample,p) end
    end
  end
  if event.tick%3600==0 then
    for _,b in ipairs(M.bots.list()) do
      local ok,p=pcall(player,b.index)
      -- A bot aboard a platform has no body to sample (live on sa, tick 72000).
      if ok and p.character then pcall(survey.sample,p) end
    end
  end
  scheduler.tick()
  M.orders.tick()
  clock.tick()
  M.cameras.tick()
  -- Camera-only drawing must never quarantine the runtime: its faults are counted.
  local okv,errv=pcall(M.visuals.tick,event.tick)
  if not okv then local s=state(); s.visual_errors={count=((s.visual_errors or {}).count or 0)+1,last=tostring(errv),tick=game.tick} end
end
-- Operator-only remote functions (control.lua): never reachable through
-- dispatch, so agents cannot spawn bots or move cameras.
M.operator={
  bot_create=function(name) return {ok=true,tick=game.tick,bot=M.bots.create(name)} end,
  bot_remove=function(name) local out=M.bots.remove(name); return {ok=true,tick=game.tick,bot=out} end,
  bots=function() local out={}; for _,b in ipairs(M.bots.list()) do out[#out+1]={name=b.name,index=b.index,alive=M.bots.alive(b),position=b.position,dead_until_tick=b.dead_until_tick} end; return {ok=true,tick=game.tick,bots=out} end,
  camera=function(args) return M.cameras.set(args) end,
  -- A table ({seconds=N} or {stop=true}) runs the dispatch/event profiler (profile.lua).
  profile_ticks=function(n)
    if type(n)=='table' then return M.profile.start(n) end
    n=integer(n,600,1,36000,'ticks')
    local total=helpers.create_profiler(true)
    profiling={n=n,left=n,total=total}
    return {ok=true,tick=game.tick,until_tick=game.tick+n,note='the average lands in the server log (factorio-current.log)'}
  end,
  cameras=function() return M.cameras.list() end,
  -- A resumed world's later shift: its losses start fresh incidents.
  -- n: the shift's number in the world (tools/start-team.sh, from the resumed-from chain).
  shift_start=function(n)
    local closed=0
    for _,i in ipairs(state().losses or {}) do if not i.closed then i.closed='shift'; closed=closed+1 end end
    -- Each agent's first reply of the shift carries a shift block (research.lua).
    local shift=M.research.shift_start(n)
    return {ok=true,tick=game.tick,incidents_closed=closed,shift=shift.number}
  end}
local MAX_ALERTS=64
function M.on_event(event)
  -- The player log must never quarantine the runtime: its faults are counted.
  if M.players.events[event.name] then
    local ok,err=pcall(M.players.on_event,event)
    if not ok then local s=state(); s.player_log_errors={count=((s.player_log_errors or {}).count or 0)+1,last=tostring(err),tick=game.tick} end
    if event.name~=defines.events.on_entity_died then return end
  end
  -- Research news (research.lua): like the player log, its faults are counted.
  if event.name==defines.events.on_research_finished or event.name==defines.events.on_research_queued then
    local ok,err=pcall(event.name==defines.events.on_research_finished and M.research.on_finished or M.research.on_queued,event)
    if not ok then local s=state(); s.research_errors={count=((s.research_errors or {}).count or 0)+1,last=tostring(err),tick=game.tick} end
    return
  end
  -- Rocket launches for the silo read (silo.lua): like research news, faults are counted.
  if event.name==defines.events.on_rocket_launch_ordered then
    local ok,err=pcall(M.silo.on_launch_ordered,event)
    if not ok then local s=state(); s.silo_errors={count=((s.silo_errors or {}).count or 0)+1,last=tostring(err),tick=game.tick} end
    return
  end
  if event.name==defines.events.on_script_path_request_finished then
    local paths=state().paths or {}
    local index=paths[event.id]; paths[event.id]=nil
    local action=index and state().active[index]
    local nav=action and (action.nav or action)
    if not nav then return end
    -- A drive's path for the vehicle's box (vehicles.lua).
    if action.kind=='drive' then
      local ok,p=pcall(player,index,true)
      if ok then M.vehicles.on_path(p,action,event) elseif nav.path_id==event.id then nav.path_state='failed' end
      return
    end
    -- The walk's own request, its belt-free twin, or the probe after a give-up (pathing.lua).
    local ok,p=pcall(player,index)
    if ok then M.pathing.on_finished(p,nav,event) elseif nav.path_id==event.id then nav.path_state='failed' end
  elseif event.name==defines.events.on_console_chat then
    if M.chat then M.chat.on_console_chat(event) end
  elseif event.name==defines.events.on_unit_group_finished_gathering then
    threat.on_group(event)
  elseif event.name==defines.events.on_entity_damaged then
    -- A unit a driving bot's vehicle hits counts as rammed (vehicles.lua).
    local cause=event.cause
    if cause and cause.valid and cause.type=='car' then
      for _,action in pairs(state().active) do
        if action.kind=='drive' and action.vehicle==cause then M.vehicles.rammed(action,event.entity) end
      end
    end
    -- A platform's hits go to its alerts (platalerts.lua), counted on a fault.
    local ok,platform=pcall(M.platalerts.on_damaged,event)
    if not ok then local s=state(); s.platform_alert_errors={count=((s.platform_alert_errors or {}).count or 0)+1,last=tostring(platform),tick=game.tick} end
    if not (ok and platform) then threat.on_damaged(event) end
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
    -- A turret of ours that died: its ghost requests the ammo it held (turretammo.lua); a fault is counted.
    if e.type=='ammo-turret' or e.type=='artillery-turret' then
      local ok,err=pcall(M.turretammo.on_died,e)
      if ok then ok,err=pcall(M.pushalerts.turret_died,e) end  -- rebuilt, it is named if it stays empty (pushalerts.lua)
      if not ok then s.turret_ammo_errors={count=((s.turret_ammo_errors or {}).count or 0)+1,last=tostring(err),tick=game.tick} end
    end
    -- Friendly fire: a cause of the entity's own force, or, with the cause gone (a flame outliving its turret), the
    -- killing force (event.force) its own.
    local cause=event.cause and event.cause.valid and event.cause or nil
    local own=e.force.name
    local friendly=(cause and cause.force and cause.force.name==own) or (not cause and event.force and event.force.name==own) or false
    record_loss(event.tick,e,cause and cause.name or (friendly and 'unknown source') or nil,friendly,friendly and cause and cause.position or nil)
  end
end
-- Operator profiler (profile.lua): dispatches, events, the tick and these parts.
M.profile=require('profile')()
-- One small constructor per statement: one table of all the parts was "function or expression too complex"
-- for the game's Lua (01:06 deploy refused), though the test Lua took it; a function of its own, since the main
-- chunk has no local slots left.
;(function()
  local parts={}
  for _,part in ipairs{{M.board,'team','board.team'},{M.ground,'unseen','ground.unseen'},{M.research,'shift_block','research.shift_block'},{M.chat,'unread','chat.unread'},{M.chat,'left','chat.left'},{M.bots,'status','bots.status'},{M.bots,'tick','bots.tick'},{M.research,'tick','research.tick'},{M.nametags,'tick','nametags.tick'},{M.networks,'tick','networks.tick'}} do parts[#parts+1]=part end
  for _,part in ipairs{{M.cameras,'tick','cameras.tick'},{scheduler,'tick','scheduler.tick'},{M.orders,'tick','orders.tick'},{clock,'tick','clock.tick'},{clock,'after_dispatch','clock.after_dispatch'},{threat,'on_damaged','threat.on_damaged'},{threat,'on_group','threat.on_group'},{M.players,'on_event','players.on_event'},{M.vehicles,'tick','vehicles.tick'},{M.ground,'tick','ground.tick'}} do parts[#parts+1]=part end
  for _,part in ipairs{{survey,'sample','survey.sample'},{survey,'summary','survey.summary'},{threat,'summary','threat.summary'},{pipes,'overlong','pipes.overlong'},{M.ground,'alerts','ground.alerts'},{threat,'alerts','threat.alerts'},{M.where,'team','where.team'},{M.belt,'note','belt.note'},{M.orders,'brief','orders.brief'},{M.pushalerts,'lines','pushalerts.lines'}} do parts[#parts+1]=part end
  for _,part in ipairs{{M.pushalerts,'claim_lines','pushalerts.claim_lines'},{M.networks,'alert_groups','networks.alert_groups'},{M.networks,'lines','networks.lines'},{M.platalerts,'lines','platalerts.lines'},{M.drops,'lines','drops.lines'},{M.research,'lines','research.lines'},{threat,'watch','threat.watch'},{M.selfview,'review_due','selfview.review_due'},{M.selfview,'retro','selfview.retro'},{M.selfview,'request','selfview.request'}} do parts[#parts+1]=part end
  for _,part in ipairs{{M.idle,'request','idle.request'},{M.tells,'operator_lines','tells.operator_lines'},{M.orders,'line','orders.line'},{M.platalerts,'note','platalerts.note'},{M.visuals,'worked','visuals.worked'},{M.claims,'worked','claims.worked'},{M.carry,'carry','carry.carry'},{M.supply,'scan','supply.scan'},{M.supply,'chain','supply.chain'},{M.networks,'read','networks.read'}} do parts[#parts+1]=part end
  for _,part in ipairs{{M.pushalerts,'tick','pushalerts.tick'},{survey,'tick','survey.tick'},{threat,'tick','threat.tick'}} do parts[#parts+1]=part end
  for _,part in ipairs{{M.scienceline,'tick','scienceline.tick'},{M.scienceline,'lines','scienceline.lines'},{M.networks,'view_tick','networks.view_tick'}} do parts[#parts+1]=part end
  M.profile.wrap(M,parts)
end)()
return M
