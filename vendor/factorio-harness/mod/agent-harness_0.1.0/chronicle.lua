-- The chronicle (viewer Alex, 22:24: "a dramatic record of major events ... their own narrative history along with
-- the run"): an agent's entry about something notable, in its own words, and the events the harness saw, side by side
-- for the pog site's Chronicle and the stream.
-- - chronicle {text, title?}: one entry, stamped with the game tick, the agent, where it stands (planet or platform)
--   and the harness events of the last LINK_TICKS on its planet or platform (research: anywhere), or anywhere when
--   there are none there (at most LINKS, newest first): what the entry may be about. One an agent every GAP ticks (game time).
-- - The events: research finished (research.lua's list), a rocket launched (silo.lua's launches), a platform stopped at
--   or left a planet (freight.lua's events), a platform made (a new one in the force's list; the creator when made by
--   platform_create), a platform lost (its hub died: where it was or the leg it flew, what killed the hub, the asteroid
--   kinds that hit it most, the items in its hub), and an agent's death (what killed it). The lists are polled once a
--   second (cheap: their own seq or tick); the deaths come from on_entity_died.
-- - The operator read chronicle {since?, events_since?, limit?} gives both, oldest first, with their cursors.
-- Storage only, no game change. Kept: MAX_ENTRIES entries, MAX_EVENTS events (the stream writes them to the run).
return function(api)
  local M = {handlers={}, operator={}}
  local MAX_ENTRIES, MAX_EVENTS, TEXT_MAX, TITLE_MAX, GAP = 300, 300, 600, 80, 60 * 60
  local LINK_TICKS, LINKS, POLL = 15 * 3600, 3, 60
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.chronicle = s.chronicle or {seq=0, entries={}, event_seq=0, events={}, last={}, seen={}}
    return s.chronicle
  end
  local function one_line(v, max, name)
    if type(v) ~= 'string' then error(name .. ' must be text', 0) end
    v = v:gsub('[%c]', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if v == '' then error(name .. ' is required', 0) end
    if #v > max then v = v:sub(1, max) end
    return v
  end
  local function game_time(tick)
    local m = math.floor(tick / 3600)
    return string.format('%dh%02dm', math.floor(m / 60), m % 60)
  end
  -- Where an entity is, for people: a platform's name, else its surface (a planet).
  local function place(surface)
    local pl = try(function() return surface.platform end)
    if pl then return {surface=surface.name, platform=pl.name} end
    return {surface=surface and surface.name or nil, planet=surface and surface.name or nil}
  end

  -- Events ---------------------------------------------------------------------------------------------------------
  function M.event(kind, row)
    local c = store()
    c.event_seq = c.event_seq + 1
    row.id, row.kind, row.tick = c.event_seq, kind, row.tick or game.tick
    row.game_time = game_time(row.tick)
    c.events[#c.events+1] = row
    while #c.events > MAX_EVENTS do table.remove(c.events, 1) end
    return row
  end
  local function items_of(inv, out)
    for k, v in pairs(inv and try(function() return inv.get_contents() end) or {}) do
      local name = type(v) == 'table' and v.name or k
      if type(name) == 'table' then name = name.name end
      local n = type(v) == 'table' and v.count or v
      if type(name) == 'string' and type(n) == 'number' and n > 0 then out[name] = (out[name] or 0) + n end
    end
    return out
  end
  local function top(map, n)
    local list = {}
    for k, v in pairs(map or {}) do list[#list+1] = {name=k, count=v} end
    table.sort(list, function(a, b) return a.count > b.count or (a.count == b.count and a.name < b.name) end)
    local out, total = {}, 0
    for i, x in ipairs(list) do total = total + x.count; if i <= n then out[i] = x end end
    return out, total, #list
  end
  -- Where a platform is or the leg it flies (freight.lua's where), as a line and its parts.
  local function where_of(pl)
    local w = api.where and try(function() return api.where(pl) end)
    if w then return {text=w.text, at=w.at, from=w.leg and w.leg.from, to=w.leg and w.leg.to,
      flown=w.leg and math.floor((w.leg.flown or 0) * 100 + 0.5) or nil} end
    local at = try(function() return pl.space_location.name end)
    return {text=at and 'at ' .. at or 'in flight', at=at}
  end
  -- An entity of ours died (runtime's on_entity_died): a platform's hub (the platform is lost: read now, while the
  -- hub still stands for this handler) or an agent's character.
  function M.on_died(e, event)
    local cause = event.cause and event.cause.valid and event.cause or nil
    local by = cause and cause.name or (event.damage_type and try(function() return event.damage_type.name end)) or nil
    if e.type == 'space-platform-hub' then
      local pl = try(function() return e.surface.platform end)
      local hold = {}
      for _, id in ipairs({'hub_main', 'hub_trash'}) do
        local inv_id = defines.inventory[id]
        items_of(inv_id and try(function() return e.get_inventory(inv_id) end), hold)
      end
      local cargo, items, kinds = top(hold, 8)
      local hits = pl and try(function() return api.state().platform_alerts.by[pl.index].total.by end)
      local kinds_hit = top(hits, 3)
      local w = pl and where_of(pl) or {text='?'}
      local c = store()
      if pl then c.seen[pl.index] = nil end
      M.event('platform_lost', {platform=pl and pl.name or e.surface.name, force=e.force.name, surface=e.surface.name,
        where=w.text, at=w.at, from=w.from, to=w.to, flown=w.flown, by=by, hit_by=#kinds_hit > 0 and kinds_hit or nil,
        cargo=cargo, cargo_items=items, cargo_kinds=kinds, creator=pl and c.creators and c.creators[pl.index] or nil})
    elseif e.type == 'character' then
      local who = api.owner and try(function() return api.owner(e) end)
      if not who then return end
      local p = place(e.surface)
      M.event('death', {agent=who, force=e.force.name, surface=p.surface, planet=p.planet, platform=p.platform, by=by,
        position={x=math.floor(e.position.x), y=math.floor(e.position.y)}})
    end
  end
  -- platform_create (space.lua) names who made it.
  function M.created_by(pl, who)
    local c = store()
    c.creators = c.creators or {}
    if pl and pl.valid then c.creators[pl.index] = who end
  end
  -- Once a second: the lists research, silo and freight keep, and the force's platforms (new ones are made; one gone
  -- with no hub death is deleted).
  local function poll(c)
    local news = api.state().research_news
    c.research_seq = c.research_seq or (news and news.seq or 0)
    for _, r in ipairs(news and news.list or {}) do
      if r.seq > c.research_seq then
        c.research_seq = r.seq
        M.event('research', {force=r.force, name=r.name, tick=r.tick, queued_by=r.queued_by})
      end
    end
    local launches = api.state().silo_launches or {}
    if not c.launch_tick then
      c.launch_tick = 0
      for _, l in pairs(launches) do if (l.tick or 0) > c.launch_tick then c.launch_tick = l.tick end end
    end
    local newest = c.launch_tick
    local fresh = {}
    for _, l in pairs(launches) do if (l.tick or 0) > c.launch_tick then fresh[#fresh+1] = l end end
    table.sort(fresh, function(a, b) return a.tick < b.tick end)
    for _, l in ipairs(fresh) do
      M.event('rocket', {surface=l.surface, to=l.to, cargo=l.cargo, by=l.by, tick=l.tick})
      if l.tick > newest then newest = l.tick end
    end
    c.launch_tick = newest
    local pe = api.state().platform_events
    c.stop_seq = c.stop_seq or (pe and pe.seq or 0)
    for _, s in ipairs(pe and pe.list or {}) do
      if s.seq > c.stop_seq then
        c.stop_seq = s.seq
        M.event(s.kind == 'arrived' and 'platform_arrived' or 'platform_left', {platform=s.platform, force=s.force, at=s.at, to=s.to, tick=s.tick})
      end
    end
    -- Platforms: the first look takes the list as it is; then a new index is a platform made, one gone without its
    -- hub's death (on_died clears it) is deleted.
    local now = {}
    for _, f in pairs(game.forces) do
      for _, pl in pairs(try(function() return f.platforms end) or {}) do
        if pl.valid then now[pl.index] = {name=pl.name, force=f.name, pl=pl} end
      end
    end
    if not c.platforms_known then
      for index, x in pairs(now) do c.seen[index] = {name=x.name, force=x.force} end
      c.platforms_known = true
      return
    end
    for index, x in pairs(now) do
      if not c.seen[index] then
        local w = where_of(x.pl)
        local planet = try(function() return x.pl.space_location.name end)
        M.event('platform_created', {platform=x.name, force=x.force, at=planet, where=w.text,
          by=c.creators and c.creators[index] or nil})
        c.seen[index] = {name=x.name, force=x.force}
      else c.seen[index].name = x.name end
    end
    for index, x in pairs(c.seen) do
      if not now[index] then
        M.event('platform_deleted', {platform=x.name, force=x.force})
        c.seen[index] = nil
      end
    end
  end
  function M.tick(tick)
    if tick % POLL ~= 0 then return end
    poll(store())
  end

  -- Entries --------------------------------------------------------------------------------------------------------
  local function line(ev)
    local k = ev.kind
    if k == 'research' then return 'research finished: ' .. tostring(ev.name)
    elseif k == 'rocket' then return 'rocket launched from ' .. tostring(ev.surface) .. (ev.to and ' to ' .. ev.to or '')
    elseif k == 'death' then return tostring(ev.agent) .. ' died on ' .. tostring(ev.platform or ev.surface) .. (ev.by and ' (' .. ev.by .. ')' or '')
    elseif k == 'platform_arrived' then return 'platform ' .. tostring(ev.platform) .. ' stopped at ' .. tostring(ev.at)
    elseif k == 'platform_left' then return 'platform ' .. tostring(ev.platform) .. ' left ' .. tostring(ev.at) .. (ev.to and ' for ' .. ev.to or '')
    elseif k == 'platform_created' then return 'platform ' .. tostring(ev.platform) .. ' made' .. (ev.at and ' at ' .. ev.at or '')
    elseif k == 'platform_lost' then
      return 'platform ' .. tostring(ev.platform) .. ' lost ' .. tostring(ev.where) .. (ev.by and ' (' .. ev.by .. ')' or '') ..
        ((ev.cargo_items or 0) > 0 and string.format(', %d items in its hub', ev.cargo_items) or '')
    elseif k == 'platform_deleted' then return 'platform ' .. tostring(ev.platform) .. ' deleted' end
    return k
  end
  M.line = line
  -- The events an entry may be about: the newest of the last LINK_TICKS on its planet or platform, else anywhere.
  local function links(here)
    local c, near, any = store(), {}, {}
    for i = #c.events, 1, -1 do
      local ev = c.events[i]
      if game.tick - ev.tick > LINK_TICKS then break end
      -- (an event with no place, research, is the whole force's: beside an entry anywhere)
      local placeless = not (ev.surface or ev.at or ev.planet or ev.platform)
      local mine = placeless or (here.platform and ev.platform == here.platform)
        or (here.planet and (ev.surface == here.planet or ev.at == here.planet or ev.planet == here.planet))
      if mine and #near < LINKS then near[#near+1] = ev end
      if #any < LINKS then any[#any+1] = ev end
    end
    local list = #near > 0 and near or any
    local out = {}
    for i, ev in ipairs(list) do out[i] = {id=ev.id, kind=ev.kind, tick=ev.tick, line=line(ev)} end
    return out
  end
  function M.handlers.chronicle(p, a)
    a = type(a) == 'table' and a or {}
    local text = one_line(a.text, TEXT_MAX, 'text')
    local title = a.title ~= nil and one_line(a.title, TITLE_MAX, 'title') or nil
    local c = store()
    local last = c.last[p.index]
    if last and game.tick - last < GAP then
      error(string.format('one chronicle entry every %d s of game time; next in %d s', GAP / 60, math.ceil((GAP - (game.tick - last)) / 60)), 0)
    end
    c.last[p.index] = game.tick
    c.seq = c.seq + 1
    local here = try(function() return place(p.surface) end) or {}
    local pos = try(function() return p.position end)
    local entry = {seq=c.seq, tick=game.tick, game_time=game_time(game.tick), agent=p.name, title=title, text=text,
      surface=here.surface, planet=here.planet, platform=here.platform,
      position=pos and {x=math.floor(pos.x), y=math.floor(pos.y)} or nil, refs=links(here)}
    c.entries[#c.entries+1] = entry
    while #c.entries > MAX_ENTRIES do table.remove(c.entries, 1) end
    local refs = {}
    for i, r in ipairs(entry.refs) do refs[i] = r.line .. ' (' .. game_time(r.tick) .. ')' end
    return {seq=entry.seq, game_time=entry.game_time, where=here.platform or here.planet, linked=#refs > 0 and refs or nil,
      note='the pog site shows the chronicle by shift, beside the events the harness saw'}
  end

  -- The operator read (the stream): entries after since and events after events_since, oldest first, at most limit
  -- of each; cursors for both.
  function M.operator.chronicle(a)
    a = type(a) == 'table' and a or {}
    local since, esince = tonumber(a.since) or 0, tonumber(a.events_since) or 0
    local limit = tonumber(a.limit) or 50
    assert(limit >= 1 and limit <= 200, 'limit must be 1..200')
    local c = store()
    local entries, events = {}, {}
    for _, e in ipairs(c.entries) do if e.seq > since then entries[#entries+1] = e end end
    for _, ev in ipairs(c.events) do if ev.id > esince then events[#events+1] = ev end end
    while #entries > limit do table.remove(entries, 1) end
    while #events > limit do table.remove(events, 1) end
    for _, ev in ipairs(events) do ev.line = line(ev) end
    return {entries=entries, events=events, cursor=c.seq, events_cursor=c.event_seq, tick=game.tick}
  end

  M.schema = {
    chronicle = {text='1..' .. TEXT_MAX .. ' characters: an entry for the run\'s chronicle, in your own words',
      title='optional, 1..' .. TITLE_MAX .. ' characters',
      returns='seq, game_time, where (your planet or platform), linked (the harness events of the last 15 min there, or anywhere, the entry is filed beside); one entry every 60 s of game time'},
  }
  return M
end
