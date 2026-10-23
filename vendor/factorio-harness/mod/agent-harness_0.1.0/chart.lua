-- chart (operator read for the site's chart; d22 batch97 BG3, Nick asked for a map like the Galaxy of Fame's). The
-- stream service draws each surface as 384-tile cells at 1 px a tile in the game's map colours from what this reads,
-- chunk by chunk, and keeps its own chunk store (tools/stream/chart.py). Read only; nothing in the game changes.
-- - The dirty set: a chunk is marked when something in it is built by hand (on_built_entity), mined by a player or a
--   robot, or dies (an enemy unit's death is not); control.lua forwards those events and no others, so robot builds and
--   tiles are not seen there. For those, `check` counts the entities in up to `check` read chunks (a rotating cursor;
--   count_entities_filtered with the read's own filter) and marks a chunk whose count changed since it was read.
-- - `chart {surfaces: true}`: every planet and platform surface: [{name, index, platform, dirty, read}].
-- - `chart {protos: true}`: the map colours and footprints, one string: "E name type w h friendly enemy map" a line
--   (colours as rrggbb, "-" for none; friendly_map_color is set on every entity prototype, map_color only on
--   resources, trees, rocks, cliffs and rails) and "T name map" a tile.
-- - `chart {surface, list: [cx0, cy0, cx1, cy1]}`: which chunks of that box our force has charted, a string of 0 and 1
--   a chunk row (at most LIST_MAX chunks; a bigger box is refused).
-- - `chart {surface, chunks: [cx, cy, ...]}`: those chunks' rows; `chart {surface, dirty: N, min_age?, check?}`: up to N
--   dirty chunks (oldest mark first) last read at least min_age ticks ago (default 36000, 10 game minutes) or never.
--   Either stops after MAX_CHUNKS (6) chunks or once MAX_ENTITIES (1200) entities are read (at least one chunk); `rest` the ones
--   left. Rows, one string: "C cx cy" then "T row|row|..." (32 tile rows of "index,run index,run ..." from the chunk's
--   top, an index into `tn`), "E index x2 y2 direction force" an entity whose position is in the chunk (index into `en`,
--   position in half tiles, force 1 ours, 2 enemy, 0 neutral), "R x2 y2 recipe" a crafter's recipe, "S x2 y2 name" a
--   train stop's name; "U cx cy" a chunk not charted. Characters, units, corpses, ghosts, robots, rolling stock,
--   projectiles and other short-lived types are left out.
-- Strings rather than tables of numbers: table_to_json takes about 28 us a number on the x86 private copy.
return function(api)
  local M = {operator={}}
  M.MAX_CHUNKS, M.MAX_ENTITIES, M.LIST_MAX, M.CHECK_MAX, M.MIN_AGE = 6, 1200, 4096, 128, 36000
  local SKIP = {'character', 'unit', 'corpse', 'character-corpse', 'particle-source', 'projectile', 'artillery-projectile',
    'item-entity', 'entity-ghost', 'tile-ghost', 'smoke-with-trigger', 'explosion', 'fire', 'sticker', 'highlight-box',
    'arrow', 'beam', 'deconstructible-tile-proxy', 'item-request-proxy', 'speech-bubble', 'stream', 'cargo-pod',
    'spider-unit', 'segment', 'segmented-unit', 'asteroid', 'combat-robot', 'construction-robot', 'logistic-robot',
    'capture-robot', 'rocket-silo-rocket', 'rocket-silo-rocket-shadow', 'car', 'spider-vehicle', 'spider-leg',
    'locomotive', 'cargo-wagon', 'fluid-wagon', 'artillery-wagon', 'infinity-cargo-wagon', 'fish', 'artillery-flare',
    'land-mine'}
  local SKIPPED = {}
  for _, t in ipairs(SKIP) do SKIPPED[t] = true end
  local CRAFTER = {['assembling-machine']=true, furnace=true}
  local fmt, concat, floor = string.format, table.concat, math.floor
  local function store()
    local s = api.state()
    s.chart = s.chart or {dirty={}, read={}, count={}, order={}, cursor={}, marks=0}
    return s.chart
  end
  -- A chunk's key: one number (string keys cost a number-to-text each).
  local function key(cx, cy) return (cx + 32768) * 65536 + (cy + 32768) end
  local function unkey(k) return floor(k / 65536) - 32768, k % 65536 - 32768 end
  M.key, M.unkey = key, unkey
  local function sub(t, si) local v = t[si]; if not v then v = {}; t[si] = v end; return v end
  local MARKED = {}
  for _, n in ipairs({'on_built_entity', 'on_player_mined_entity', 'on_robot_mined_entity', 'on_entity_died'}) do
    if defines.events[n] then MARKED[defines.events[n]] = true end
  end
  M.events = MARKED
  -- An event's entity marks its chunk dirty (the first mark since the last read stays: oldest first).
  function M.mark(event)
    local e = event.entity
    if not (e and e.valid) or SKIPPED[e.type] then return end
    local p, si = e.position, e.surface.index
    local k = key(floor(p.x / 32), floor(p.y / 32))
    local d = sub(store().dirty, si)
    if not d[k] then d[k] = event.tick or game.tick end
  end
  local function hex(c)
    if not c then return '-' end
    local r, g, b = c.r or c[1] or 0, c.g or c[2] or 0, c.b or c[3] or 0
    if r <= 1 and g <= 1 and b <= 1 then r, g, b = r * 255, g * 255, b * 255 end
    return fmt('%02x%02x%02x', floor(r + 0.5), floor(g + 0.5), floor(b + 0.5))
  end
  local function protos()
    local out = {}
    for name, p in pairs(prototypes.entity) do
      if not SKIPPED[p.type] then
        local box = p.collision_box or {left_top={x=0, y=0}, right_bottom={x=0, y=0}}
        local w = math.max(1, floor(box.right_bottom.x - box.left_top.x + 0.5))
        local h = math.max(1, floor(box.right_bottom.y - box.left_top.y + 0.5))
        out[#out+1] = fmt('E %s %s %d %d %s %s %s', name, p.type, w, h, hex(p.friendly_map_color), hex(p.enemy_map_color), hex(p.map_color))
      end
    end
    for name, t in pairs(prototypes.tile) do out[#out+1] = fmt('T %s %s', name, hex(t.map_color)) end
    table.sort(out)
    return concat(out, '\n')
  end
  local function surface_of(args)
    local s = game.surfaces[args.surface]
    assert(s, 'surface must name a surface (chart {surfaces: true} lists them)')
    return s
  end
  local function surfaces()
    local st, out = store(), {}
    for _, s in pairs(game.surfaces) do
      if s.planet or s.platform then
        local n, r = 0, 0
        for _ in pairs(st.dirty[s.index] or {}) do n = n + 1 end
        for _ in pairs(st.read[s.index] or {}) do r = r + 1 end
        out[#out+1] = {name=s.name, index=s.index, platform=s.platform and s.platform.valid and s.platform.name or nil, dirty=n, read=r}
      end
    end
    table.sort(out, function(a, b) return a.index < b.index end)
    return out
  end
  -- One chunk's lines into out; returns the entities read and the count the check compares.
  local function read_chunk(s, f, cx, cy, out, tn, ti, en, ei)
    if not f.is_chunk_charted(s, {cx, cy}) then out[#out+1] = fmt('U %d %d', cx, cy); return 0, nil end
    out[#out+1] = fmt('C %d %d', cx, cy)
    local x0, y0 = cx * 32, cy * 32
    local rows = {}
    for y = 0, 31 do
      local row, last, run = {}, nil, 0
      for x = 0, 31 do
        local name = s.get_tile(x0 + x, y0 + y).name
        local v = ti[name]
        if not v then tn[#tn+1] = name; v = #tn; ti[name] = v end
        if v == last then run = run + 1
        else
          if last then row[#row+1] = fmt('%d,%d', last, run) end
          last, run = v, 1
        end
      end
      row[#row+1] = fmt('%d,%d', last, run)
      rows[y + 1] = concat(row, ' ')
    end
    out[#out+1] = 'T ' .. concat(rows, '|')
    local ents = s.find_entities_filtered{area={{x0, y0}, {x0 + 32, y0 + 32}}, type=SKIP, invert=true}
    local n, extra = 0, {}
    for _, e in pairs(ents) do
      local p = e.position
      if p.x >= x0 and p.x < x0 + 32 and p.y >= y0 and p.y < y0 + 32 then
        n = n + 1
        local name, t = e.name, e.type
        local v = ei[name]
        if not v then en[#en+1] = name; v = #en; ei[name] = v end
        local fn = e.force.name
        local x2, y2 = floor(p.x * 2 + 0.5), floor(p.y * 2 + 0.5)
        out[#out+1] = fmt('E %d %d %d %d %d', v, x2, y2, e.direction or 0, fn == 'player' and 1 or fn == 'enemy' and 2 or 0)
        if CRAFTER[t] then
          local ok, r = pcall(e.get_recipe)
          if ok and r then extra[#extra+1] = fmt('R %d %d %s', x2, y2, r.name) end
        elseif t == 'train-stop' then
          extra[#extra+1] = fmt('S %d %d %s', x2, y2, (e.backer_name or ''):gsub('[\r\n]', ' '))
        end
      end
    end
    for _, l in ipairs(extra) do out[#out+1] = l end
    return n, #ents
  end
  local function read_chunks(s, list, args)
    local st, f = store(), game.forces.player
    local si = s.index
    local dirty, read, count, order = sub(st.dirty, si), sub(st.read, si), sub(st.count, si), sub(st.order, si)
    local out, tn, ti, en, ei = {}, {}, {}, {}, {}
    local chunks, entities, i = 0, 0, 1
    local max_chunks = math.min(M.MAX_CHUNKS, args.max_chunks or M.MAX_CHUNKS)
    while i <= #list and chunks < max_chunks and (chunks == 0 or entities < M.MAX_ENTITIES) do
      local cx, cy = list[i][1], list[i][2]
      local n, c = read_chunk(s, f, cx, cy, out, tn, ti, en, ei)
      local k = key(cx, cy)
      if not read[k] then order[#order+1] = k end
      read[k], count[k], dirty[k] = game.tick, c, nil
      chunks, entities, i = chunks + 1, entities + n, i + 1
    end
    return {tick=game.tick, surface=s.name, chunks=chunks, entities=entities, rest=#list - i + 1,
      tn=concat(tn, ' '), en=concat(en, ' '), rows=concat(out, '\n')}
  end
  -- Counts up to n read chunks from the cursor on; a changed count marks the chunk dirty.
  local function check(s, n)
    local st, si = store(), s.index
    local order, count, dirty = sub(st.order, si), sub(st.count, si), sub(st.dirty, si)
    local c, marked = st.cursor[si] or 1, 0
    n = math.min(n, #order, M.CHECK_MAX)
    for _ = 1, n do
      if c > #order then c = 1 end
      local k = order[c]
      local old = count[k]
      if old ~= nil and not dirty[k] then
        local cx, cy = unkey(k)
        local now = s.count_entities_filtered{area={{cx * 32, cy * 32}, {cx * 32 + 32, cy * 32 + 32}}, type=SKIP, invert=true}
        if now ~= old then dirty[k] = game.tick; marked = marked + 1 end
      end
      c = c + 1
    end
    st.cursor[si] = c
    return n, marked
  end
  function M.read(args)
    args = type(args) == 'table' and args or {}
    if args.surfaces then return {tick=game.tick, surfaces=surfaces()} end
    if args.protos then return {tick=game.tick, protos=protos()} end
    local s = surface_of(args)
    if args.list ~= nil then
      local b = args.list
      assert(type(b) == 'table' and #b == 4, 'list is [cx0, cy0, cx1, cy1] in chunks')
      local cx0, cy0, cx1, cy1 = floor(b[1]), floor(b[2]), floor(b[3]), floor(b[4])
      assert(cx1 >= cx0 and cy1 >= cy0 and (cx1 - cx0 + 1) * (cy1 - cy0 + 1) <= M.LIST_MAX, 'list covers at most ' .. M.LIST_MAX .. ' chunks')
      local f, rows, n = game.forces.player, {}, 0
      for cy = cy0, cy1 do
        local r = {}
        for cx = cx0, cx1 do
          local c = f.is_chunk_charted(s, {cx, cy})
          r[#r+1] = c and '1' or '0'
          if c then n = n + 1 end
        end
        rows[#rows+1] = concat(r)
      end
      return {tick=game.tick, surface=s.name, box={cx0, cy0, cx1, cy1}, charted=n, rows=rows}
    end
    if args.chunks ~= nil then
      local c = args.chunks
      assert(type(c) == 'table' and #c % 2 == 0 and #c >= 2, 'chunks is [cx, cy, cx, cy, ...]')
      local list = {}
      for i = 1, #c, 2 do list[#list+1] = {floor(c[i]), floor(c[i + 1])} end
      return read_chunks(s, list, args)
    end
    assert(args.dirty ~= nil, 'chart takes surfaces, protos, or a surface with list, chunks or dirty')
    local want = math.max(1, math.min(M.MAX_CHUNKS, floor(tonumber(args.dirty) or 1)))
    local checked, marked = 0, 0
    if args.check then checked, marked = check(s, math.max(0, floor(tonumber(args.check) or 0))) end
    local st, si = store(), s.index
    local dirty, read = sub(st.dirty, si), sub(st.read, si)
    local min_age = tonumber(args.min_age) or M.MIN_AGE
    local ready, waiting = {}, 0
    for k, t in pairs(dirty) do
      if not read[k] or game.tick - read[k] >= min_age then ready[#ready+1] = {k, t} else waiting = waiting + 1 end
    end
    table.sort(ready, function(a, b) return a[2] < b[2] or (a[2] == b[2] and a[1] < b[1]) end)
    local list = {}
    for i = 1, math.min(#ready, want) do local cx, cy = unkey(ready[i][1]); list[i] = {cx, cy} end
    local out = read_chunks(s, list, args)
    out.rest, out.waiting, out.checked, out.marked = #ready - out.chunks, waiting, checked, marked
    return out
  end
  M.operator.chart = M.read
  return M
end
