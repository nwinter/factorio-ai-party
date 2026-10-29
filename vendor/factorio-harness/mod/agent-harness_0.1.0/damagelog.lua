-- damagelog: what hit our entities, each hit's source (its name, position and facing), kept only for hits our force
-- saw: in a chunk it sees at the time (radar coverage or a character's sight), as a player watching there could (B8,
-- Sol, board #695: incident 973 blamed a flamethrower that faced away). Hits from one source on one entity within a
-- second are one row (count, damage). Bounded: the last ROWS rows an entity, ENTITIES entities (the oldest dropped).
-- damage_log {position, radius?} reads them, the destroyed ones too; inspect gives an entity's last rows.
-- (d20 batch53 M4, Astra #1200: fire on belts at (-116,509) named a flamethrower turret at (-119.5,423), 86 tiles away)
-- Every source here is the game's own event, never inferred: its cause (the entity behind the hit; for fire, the turret
-- whose stream lit the first fire, kept as a fire spreads) and its source (what dealt the hit: the fire, projectile or
-- stream). A row says both when they differ, and how far the cause stood from the hit against its range: a fire hit
-- past the turret's range spread there.
return function(api)
  local M = {}
  local ROWS, ENTITIES, JOIN = 8, 512, 60
  local COMPASS = {[0]='north', [2]='northeast', [4]='east', [6]='southeast', [8]='south', [10]='southwest', [12]='west', [14]='northwest'}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.damage_log = s.damage_log or {by={}, ring={}, next=1}
    return s.damage_log
  end
  -- Events confirm a removal; a failed lookup never does. No records are created by removals.
  M.removal_events = {}
  for name, status in pairs{on_entity_died='destroyed', on_player_mined_entity='removed',
      on_robot_mined_entity='removed', script_raised_destroy='removed'} do
    local id = defines and defines.events and defines.events[name]
    if id then M.removal_events[id] = status end
  end
  function M.on_removed(event)
    local status = M.removal_events[event.name]
    local e = event.entity
    local rec = status and e and e.valid and e.unit_number and store().by[e.unit_number]
    if rec then rec.removal = {state=status, tick=event.tick, surface=e.surface.name,
      position={x=e.position.x, y=e.position.y}} end
  end
  -- The event as it comes (cheap: our entities only, in a chunk our force sees).
  function M.on_damaged(event)
    local e = event.entity
    if not (e and e.valid and e.unit_number) then return end
    local force = e.force
    if not (force and force.name == 'player') then return end
    local pos = e.position
    if not force.is_chunk_visible(e.surface, {x=math.floor(pos.x / 32), y=math.floor(pos.y / 32)}) then return end
    local m = store()
    local k = e.unit_number
    local rec = m.by[k]
    if not rec then
      local old = m.ring[m.next]
      if old then m.by[old] = nil end
      m.ring[m.next] = k; m.next = m.next % ENTITIES + 1
      rec = {name=e.name, surface=e.surface.name, x=pos.x, y=pos.y, rows={}}
      m.by[k] = rec
    end
    rec.entity = e  -- Factorio's by-unit lookup omits stationary entities; a saved reference retains their identity.
    local c = event.cause
    local cname, cx, cy, facing, cforce
    if c and c.valid then
      cname, cx, cy = c.name, c.position.x, c.position.y
      cforce = c.force and c.force.name
      local d = try(function() return c.direction end)
      local o = (c.type == 'car' or c.type == 'spider-vehicle') and try(function() return c.orientation end) or nil
      facing = (o and string.format('orientation %.2f', o)) or (d and COMPASS[d]) or nil
    end
    local dtype = event.damage_type and event.damage_type.name or '?'
    local s = try(function() return event.source end)
    local sname, sx, sy, stype, range
    if s and s.valid and s ~= c then sname, sx, sy, stype = s.name, s.position.x, s.position.y, s.type end
    local last = rec.rows[#rec.rows]
    if last and last.position and last.position.x == pos.x and last.position.y == pos.y and last.surface == e.surface.name and last.cause == cname and last.cx == cx and last.cy == cy and last.type == dtype and last.source == sname and event.tick - last.last <= JOIN then
      last.count = last.count + 1; last.damage = last.damage + (event.final_damage_amount or 0); last.last = event.tick
      return
    end
    -- (d25 batch209 QV1) its range at its quality: the prototype's times the quality's range_multiplier
    if c and c.valid then range = try(function() local r = c.prototype.attack_parameters.range; local q = c.quality; return q and q.name ~= 'normal' and math.floor(r * q.range_multiplier * 10 + 0.5) / 10 or r end) end
    rec.rows[#rec.rows+1] = {unit_number=k, name=e.name, position={x=pos.x,y=pos.y}, surface=e.surface.name, tick=event.tick, last=event.tick, count=1, damage=event.final_damage_amount or 0, type=dtype,
      cause=cname, cx=cx, cy=cy, facing=facing, force=cforce, source=sname, sx=sx, sy=sy, stype=stype, range=range,
      dist=cx and math.floor(math.sqrt((cx - pos.x) ^ 2 + (cy - pos.y) ^ 2) + 0.5) or nil}
    if #rec.rows > ROWS then table.remove(rec.rows, 1) end
  end
  local function r1(v) return math.floor(v * 10 + 0.5) / 10 end
  local function row_text(r)
    local src = r.cause and string.format('%s at (%g,%g)%s%s', r.cause, r1(r.cx), r1(r.cy),
      r.facing and ' facing ' .. r.facing or '', r.force and r.force ~= 'player' and ' (' .. r.force .. ')' or '') or 'no source the game names (a fire or projectile that outlived it)'
    if r.cause and r.dist then
      local past = r.range and r.dist > r.range + 2
      src = src .. string.format(', %d tiles from the hit%s', r.dist, r.range and string.format(' (its range %g%s)', r.range, past and r.stype == 'fire' and ': the fire spread there from where its stream lit it'
        or past and ': past its range' or '') or '')
    end
    if r.source then
      src = string.format('%s at (%g,%g)%s', r.source, r1(r.sx), r1(r.sy), r.cause and ', the game\'s cause: ' .. src or ' (no cause the game names)')
    end
    return string.format('%ds ago: %d %s hit%s, %g damage, from %s', math.floor((game.tick - r.last) / 60), r.count, r.type, r.count == 1 and '' or 's',
      math.floor(r.damage * 10 + 0.5) / 10, src)
  end
  -- An entity's rows, newest first (inspect).
  function M.of(e)
    local rec = e and e.valid and e.unit_number and store().by[e.unit_number]
    if not rec then return nil end
    local out = {}
    for i = #rec.rows, 1, -1 do out[#out+1] = row_text(rec.rows[i]) end
    return out
  end
  local function visible(force, surface, pos)
    return force and surface and pos and try(function()
      return force.is_chunk_visible(surface, {x=math.floor(pos.x / 32), y=math.floor(pos.y / 32)})
    end) == true
  end
  local function current(unit, rec, force)
    if rec.removal then return rec.removal.state, false, nil, rec.removal end
    local e = rec.entity
    if not (e and e.valid and e.unit_number == unit) then
      e = try(function() return game.get_entity_by_unit_number(unit) end)
    end
    -- Pre-update records have no reference. A visible occupant with the original unit ID is also confirmation.
    if not (e and e.valid and e.unit_number == unit) then
      local s = try(function() return game.surfaces[rec.surface] end)
      local pos = {x=rec.x,y=rec.y}
      if visible(force,s,pos) then
        for _, candidate in ipairs(try(function() return s.find_entities_filtered{position=pos,limit=17} end) or {}) do
          if candidate.valid and candidate.unit_number == unit then e=candidate; break end
        end
      end
    end
    if e and e.valid and e.unit_number == unit then
      if visible(force, e.surface, e.position) then return 'alive', true, e end
      return 'unknown', nil, nil, nil, 'original unit is outside current sight'
    end
    return 'unknown', nil, nil, nil, 'original unit not found; no removal event recorded'
  end
  local function occupants(surface, force, pos, unit)
    if not visible(force, surface, pos) then return {status='unknown', reason='hit position is outside current sight'} end
    local found = try(function() return surface.find_entities_filtered{position=pos, limit=17} end)
    if not found then return {status='unknown', reason='occupant lookup failed'} end
    local rows = {}
    for i, e in ipairs(found) do
      if i > 16 then break end
      if e.valid then rows[#rows+1] = {unit_number=e.unit_number, name=e.name,
        position={x=e.position.x,y=e.position.y}, surface=e.surface.name, original=e.unit_number == unit} end
    end
    return {status=#found >= 17 and 'capped' or 'complete', entities=rows}
  end
  function M.read(p, a)
    local centre = a.position and api.position(a.position) or p.position
    local radius = api.integer(a.radius, 8, 1, 64, 'radius')
    local surface = p.surface.name
    local list = {}
    for unit, rec in pairs(store().by) do
      local matching = {}
      for j = #rec.rows, 1, -1 do
        local hit = rec.rows[j]
        -- Old saves kept only the first observed position. Keep it as an explicitly labelled search anchor,
        -- never manufacture a per-hit position for those rows.
        local pos = hit.position or {x=rec.x, y=rec.y}
        if (hit.surface or rec.surface) == surface and (pos.x-centre.x)^2 + (pos.y-centre.y)^2 <= radius^2 then
          matching[#matching+1] = hit
        end
      end
      if #matching > 0 then list[#list+1] = {unit=unit, rec=rec, matching=matching, last=matching[1].last} end
    end
    table.sort(list, function(x, y) return x.last > y.last or x.last == y.last and x.unit < y.unit end)
    local rows = {}
    for i, it in ipairs(list) do
      if i > 16 then break end
      local first = it.matching[1]
      local pos = first.position or {x=it.rec.x, y=it.rec.y}
      local status, alive, e, removal, reason = current(it.unit, it.rec, p.force)
      local hits, hit_rows = {}, {}
      for _, hit in ipairs(it.matching) do
        hits[#hits+1] = row_text(hit)
        hit_rows[#hit_rows+1] = {unit_number=hit.unit_number or it.unit, name=hit.name or it.rec.name,
          tick=hit.tick, last_tick=hit.last, position=hit.position, surface=hit.surface,
          position_status=hit.position and 'recorded' or 'unknown', count=hit.count, damage=hit.damage, type=hit.type}
      end
      rows[#rows+1] = {unit_number=it.unit, name=first.name or it.rec.name, position=pos,
        position_basis=first.position and 'latest matching hit' or 'legacy first observation; hit position not recorded',
        hit_tick=first.tick, last_hit_tick=first.last, state=status, alive=alive, state_reason=reason,
        current_position=e and {x=e.position.x,y=e.position.y} or nil, current_surface=e and e.surface.name or nil,
        removal=removal, current_occupants=occupants(p.surface,p.force,pos,it.unit), hits=hits, hit_rows=hit_rows}
    end
    return {surface=surface, centre=centre, radius=radius, entities=rows, more=#list > 16 and #list - 16 or nil,
      note='hits on our entities in a chunk our force saw at the time; only rows matching this area, newest first; one row per source and hit position within a second; last 8 rows per unit, 512 units kept. Alive is a visible lookup by original unit number; destroyed/removed requires a recorded event; otherwise unknown. Current occupants are separate units at the returned historical position, only when visible. Legacy rows lack per-hit positions and use the first observation as a search anchor. Sources are the game event, never inferred.'}
  end
  M.schema = {damage_log = {position='optional {x,y} (default you)', radius='1..64 (default 8)', surface='optional planet or platform name (default yours)',
    returns='entities [{unit_number, name, position, position_basis, hit_tick, last_hit_tick, state: alive|destroyed|removed|unknown, alive: true/false only when confirmed, state_reason?, current_position?, current_surface?, removal?: {state,tick,position,surface}, current_occupants: {status: complete|capped|unknown, entities?: [{unit_number?,name,position,surface,original}]}, hit_rows: [{unit_number,name,tick,last_tick,position?,position_status,surface?,count,damage,type}], hits: source/cause text newest first}]; only matching historical hit positions (legacy first observation labelled); more; last 8 rows per unit, 512 units. Current occupant lookup is bounded to 17, at the returned position in current sight. Read only'}}
  return M
end
