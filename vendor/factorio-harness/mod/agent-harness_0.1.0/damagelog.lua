-- damagelog: what hit our entities, each hit's source (its name, position and facing), kept only for hits our force
-- saw: in a chunk it sees at the time (radar coverage or a character's sight), as a player watching there could (B8,
-- Sol, board #695: incident 973 blamed a flamethrower that faced away). Hits from one source on one entity within a
-- second are one row (count, damage). Bounded: the last ROWS rows an entity, ENTITIES entities (the oldest dropped).
-- damage_log {position, radius?} reads them, the destroyed ones too; inspect gives an entity's last rows.
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
    local last = rec.rows[#rec.rows]
    if last and last.cause == cname and last.cx == cx and last.cy == cy and last.type == dtype and event.tick - last.last <= JOIN then
      last.count = last.count + 1; last.damage = last.damage + (event.final_damage_amount or 0); last.last = event.tick
      return
    end
    rec.rows[#rec.rows+1] = {tick=event.tick, last=event.tick, count=1, damage=event.final_damage_amount or 0, type=dtype,
      cause=cname, cx=cx, cy=cy, facing=facing, force=cforce}
    if #rec.rows > ROWS then table.remove(rec.rows, 1) end
  end
  local function row_text(r)
    local src = r.cause and string.format('%s at (%g,%g)%s%s', r.cause, math.floor(r.cx * 10 + 0.5) / 10, math.floor(r.cy * 10 + 0.5) / 10,
      r.facing and ' facing ' .. r.facing or '', r.force and r.force ~= 'player' and ' (' .. r.force .. ')' or '') or 'no source the game names (a fire or projectile that outlived it)'
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
  function M.read(p, a)
    local centre = a.position and api.position(a.position) or p.position
    local radius = api.integer(a.radius, 8, 1, 64, 'radius')
    local surface = p.surface.name
    local list = {}
    for unit, rec in pairs(store().by) do
      if rec.surface == surface and (rec.x - centre.x) ^ 2 + (rec.y - centre.y) ^ 2 <= radius * radius and #rec.rows > 0 then
        list[#list+1] = {unit=unit, rec=rec, last=rec.rows[#rec.rows].last}
      end
    end
    table.sort(list, function(x, y) return x.last > y.last end)
    local rows = {}
    for i, it in ipairs(list) do
      if i > 16 then break end
      local alive
      for _, e in ipairs(try(function() return p.surface.find_entities_filtered{name=it.rec.name, position={it.rec.x, it.rec.y}, radius=0.3} end) or {}) do
        if e.unit_number == it.unit then alive = e end
      end
      local hits = {}
      for j = #it.rec.rows, 1, -1 do hits[#hits+1] = row_text(it.rec.rows[j]) end
      rows[#rows+1] = {name=it.rec.name, position={x=it.rec.x, y=it.rec.y}, alive=alive and alive.valid or false, hits=hits}
    end
    return {surface=surface, centre=centre, radius=radius, entities=rows, more=#list > 16 and #list - 16 or nil,
      note='hits on our entities in a chunk our force saw at the time (radar coverage or a character\'s sight); one row per source within a second; the last 8 rows an entity, 512 entities kept'}
  end
  M.schema = {damage_log = {position='optional {x,y} (default you)', radius='1..64 (default 8)', surface='optional planet or platform name (default yours)',
    returns='entities [{name, position, alive (or destroyed since), hits: newest first, each "Ns ago: N TYPE hits, D damage, from SOURCE at (x,y) facing DIR (its force when not ours)", or no source the game names}], more; only hits in a chunk our force saw at the time; the last 8 rows an entity, 512 entities. Read only'}}
  return M
end
