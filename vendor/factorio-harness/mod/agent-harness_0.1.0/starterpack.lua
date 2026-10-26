-- Platforms waiting for a starter pack (d26 batch229 SP; Sol, operator request 973: a pack Sol loaded at Vulcanus for
-- the new platform Loom went to Aethera, made there 217 hours before and waiting for one since). Which of our waiting
-- platforms a starter pack goes to, and since when each has waited, for platform_create, a transfer or load_silo of a
-- pack into a rocket, a silo's settings and read, and the platforms read.
-- The game's rule (the copy of world n, 2.0.77; M.RULE): a rocket holding a starter pack launches on its own, whatever
-- the silo's two switches, the tick it is ready (the next tick when it is ready already) while a platform of ours waits
-- for a pack at that planet (waiting_for_starter_pack), to the one waiting with the lowest index; indices are never
-- reused (a deleted platform's stays free), so that is the one made first. A launch ordered in the tick the pack goes
-- in (load_silo launch: true) goes where it names: a platform (that one), orbit (the pack is lost). With none waiting
-- the pack stays aboard; automatic requests switched on move it to the trash slots; with one waiting they do not.
-- made: the tick each platform was made, kept from platform_create (its tick) and the chronicle's once-a-second look at
-- the force's platforms (a new one: within a second); platforms made before this runtime kept them read from the
-- chronicle's kept events where it still has their platform_created, else "made before" the tick keeping began.
-- Storage only, read only.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function store()
    local s = api.state()
    s.starterpack = s.starterpack or {made={}}
    local st = s.starterpack
    if not st.since then
      st.since = game.tick
      -- the chronicle's platform_created events still kept (the last 300 events) give the ones made before
      local ch = s.chronicle
      local by_name = {}
      for _, ev in ipairs(ch and ch.events or {}) do
        if ev.kind == 'platform_created' and ev.platform then by_name[ev.platform] = ev.tick end
      end
      if next(by_name) then
        for _, f in pairs(game.forces) do
          for _, pl in pairs(try(function() return f.platforms end) or {}) do
            if pl.valid and by_name[pl.name] and not st.made[pl.index] then st.made[pl.index] = by_name[pl.name] end
          end
        end
      end
    end
    return st
  end
  -- A platform made now (platform_create) or first seen (the chronicle's look); an earlier tick is kept.
  function M.made(pl, tick)
    local st = store()
    if pl and pl.valid and not st.made[pl.index] then st.made[pl.index] = tick or game.tick end
  end
  -- A platform gone: its tick dropped.
  function M.forget(index) local s = api.state().starterpack; if s then s.made[index] = nil end end
  local function hm(ticks)
    local m = math.floor(math.max(0, ticks) / 3600)
    if m >= 60 then return string.format('%dh%02dm', math.floor(m / 60), m % 60) end
    return string.format('%dm%02ds', m, math.floor(math.max(0, ticks) / 60) % 60)
  end
  M.hm = hm
  local function waiting_state() return (defines.space_platform_state or {}).waiting_for_starter_pack end
  local function planet_of(pl) return try(function() return pl.space_location.name end) end
  -- The game's order (RULE): the lowest platform index first, the one made first.
  M.RULE = 'a rocket there holding a starter pack launches on its own once ready, whatever the silo\'s switches, to the first made of ours waiting'
  -- Ours waiting for a starter pack at planet, in the order the game serves them.
  function M.waiting(force, planet)
    local out = {}
    local w = waiting_state()
    for _, pl in pairs(try(function() return force.platforms end) or {}) do
      if pl.valid and pl.state == w and planet_of(pl) == planet then out[#out+1] = pl end
    end
    table.sort(out, function(a, b) return a.index < b.index end)
    return out
  end
  -- How long a waiting platform has waited: {made, ticks, text}; made nil when not known (made before since).
  function M.age(pl)
    local st = store()
    local made = st.made[pl.index]
    if made then return {made=made, ticks=game.tick - made, text='waiting ' .. hm(game.tick - made)} end
    return {ticks=game.tick - st.since, text='waiting over ' .. hm(game.tick - st.since) .. ', made before tick ' .. st.since}
  end
  local function named(pl) return pl.name .. ' (' .. M.age(pl).text .. ')' end
  -- One line: the platforms waiting at planet in the game's order, and which one a pack goes to; nil when fewer than min
  -- (default 1) wait.
  function M.queue_line(force, planet, min)
    local list = M.waiting(force, planet)
    if #list == 0 or #list < (min or 1) then return nil end
    local names = {}
    for _, pl in ipairs(list) do names[#names+1] = named(pl) end
    return string.format('%d platform%s of ours wait%s for a starter pack at %s: %s; %s: %s',
      #list, #list == 1 and '' or 's', #list == 1 and 's' or '', planet, table.concat(names, ', '), M.RULE, list[1].name)
  end
  -- Where a starter pack aboard a rocket at planet goes, as a line (pack: its item*count).
  function M.goes_to_line(force, planet, pack)
    local list = M.waiting(force, planet)
    if #list == 0 then
      return string.format('%s; no platform of ours waits for a starter pack at %s: it stays aboard (automatic requests on: the trash slots)', pack or 'a starter pack', planet)
    end
    local rest = {}
    for i = 2, #list do rest[#rest+1] = named(list[i]) end
    return string.format('%s, which launches on its own once the rocket is ready, whatever the silo\'s switches, to %s (%s), the first made of ours waiting for one at %s%s; a launch in the tick it goes in (load_silo launch: true) goes to the platform it names',
      pack or 'a starter pack', list[1].name, M.age(list[1]).text, planet, #rest > 0 and '; also waiting: ' .. table.concat(rest, ', ') or '')
  end
  -- A waiting platform's line for the platforms read: where it waits, how long, and its place in the game's order.
  function M.row_line(pl)
    local planet = planet_of(pl) or '?'
    local list = M.waiting(pl.force, planet)
    local at = 1
    for i, x in ipairs(list) do if x == pl then at = i end end
    return string.format('waiting for its starter pack at %s, %s; %s: %s', planet, M.age(pl).text, M.RULE,
      at == 1 and 'this one' .. (#list > 1 and ' (of ' .. #list .. ')' or '')
        or string.format('%s (%s); %s is %d of %d', list[1].name, M.age(list[1]).text, pl.name, at, #list))
  end
  -- Starter pack items in a list of {name, count} (an item whose type is space-platform-starter-pack).
  function M.is_pack(name)
    local p = name and try(function() return prototypes.item[name] end)
    return p and p.type == 'space-platform-starter-pack' or false
  end
  function M.packs_in(inv)
    local out = {}
    for _, st in ipairs(inv and try(function() return inv.get_contents() end) or {}) do
      if M.is_pack(st.name) then out[#out+1] = st.name .. '*' .. st.count end
    end
    return #out > 0 and table.concat(out, ' ') or nil
  end
  return M
end
