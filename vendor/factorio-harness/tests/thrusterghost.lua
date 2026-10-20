-- Run from repository root: lua tests/thrusterghost.lua
-- (d20 batch52 J1, Sol shift46 10:31) Thruster ghosts on Limestone-spare-unbuilt: the dry run failed with "LuaTile API
-- call when LuaTile was invalid." and the real call refused each thruster "placement blocked by tile ghost
-- space-platform-foundation". 2.0.77 on the private copy (pog-b41-headless, a thruster facing north): over foundation
-- tile ghosts the plain ghost check takes it (and a blueprint holding the foundation and the thruster places both); over
-- bare empty space the forced check takes it, and a forced blueprint lays the 20 foundation tile ghosts under it; built
-- foundation takes it; its second rule wants the 90 tiles behind it empty space, refused until their chunks are
-- generated (get_tile there gives an invalid tile; a plain request generates them within a few ticks).
-- Here the same rules against a fake platform: placewhy.rule_tiles, and the dry run in each case.
local function eq(a, b, m) assert(a == b, (m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s, part) assert(type(s) == 'string' and s:find(part, 1, true), tostring(s)..' lacks '..part) end
package.path = 'mod/agent-harness_0.1.0/?.lua;'..package.path
defines = {build_check_type={manual=0, manual_ghost=1}, inventory={hub_main=1}}
local function mask(...) local l = {} for _, k in ipairs({...}) do l[k] = true end return {layers=l} end
prototypes = {tile={
  ['empty-space']={name='empty-space', collision_mask=mask('empty_space', 'ground_tile', 'object', 'water_tile', 'item')},
  ['space-platform-foundation']={name='space-platform-foundation', collision_mask=mask('ground_tile')},
  ['out-of-map']={name='out-of-map', collision_mask=mask('ground_tile', 'object', 'out_of_map', 'water_tile')},
  ['stone-path']={name='stone-path', collision_mask=mask('ground_tile')},
}}
-- the thruster's rules as 2.0.77 gives them
local thruster = {name='thruster', type='thruster', tile_width=4, tile_height=5,
  collision_box={left_top={x=-1.7, y=-2.2}, right_bottom={x=1.7, y=2.2}}, collision_mask=mask('object', 'item', 'player'),
  items_to_place_this={{name='thruster', count=1}},
  tile_buildability_rules={
    {area={left_top={x=-1.796875, y=-2.296875}, right_bottom={x=1.796875, y=2.296875}}, required_tiles=mask('ground_tile'), colliding_tiles=mask('empty_space')},
    {area={left_top={x=-1.796875, y=2.69921875}, right_bottom={x=1.796875, y=90.296875}}, required_tiles=mask('empty_space'), colliding_tiles=mask()}}}
prototypes.entity = {thruster=thruster}
prototypes.item = {
  -- stone brick listed first: its tile is ground, but the game places it on no empty space (its condition): foundation
  ['stone-brick']={name='stone-brick', place_as_tile_result={result=prototypes.tile['stone-path'], condition=mask('water_tile', 'empty_space'), invert=false}},
  ['space-platform-foundation']={name='space-platform-foundation', place_as_tile_result={result=prototypes.tile['space-platform-foundation'],
    condition=mask('empty_space'), invert=true}},
}
local force = {name='player', recipes={['space-platform-foundation']={enabled=true}}}

-- A platform: built foundation x -20..20, y -10..10; generated chunks y < 160 (rows 0..4), allocated (valid, not
-- generated) to y < 192; past that get_tile gives an invalid tile, whose name raises as the engine's does.
local GEN, VALID = 160, 192
local function platform(built, ghosts)
  local s = {platform={}, requested={}}
  local tiles = {}
  for _, t in ipairs(built or {}) do tiles[t[1]..','..t[2]] = 'space-platform-foundation' end
  local tg = {}
  for _, g in ipairs(ghosts or {}) do
    tg[#tg+1] = {valid=true, type='tile-ghost', name='tile-ghost', ghost_name='space-platform-foundation', force=force, position={x=g[1]+0.5, y=g[2]+0.5}}
  end
  local function name_at(x, y)
    if tiles[x..','..y] then return tiles[x..','..y] end
    if x >= -20 and x <= 20 and y >= -10 and y <= 10 then return 'space-platform-foundation' end
    return 'empty-space'
  end
  s.get_tile = function(x, y)
    x, y = math.floor(x), math.floor(y)
    if y >= VALID then
      return setmetatable({valid=false}, {__index=function() error('LuaTile API call when LuaTile was invalid.') end})
    end
    if y >= GEN then return {valid=true, name='out-of-map', prototype=prototypes.tile['out-of-map']} end
    local n = name_at(x, y)
    return {valid=true, name=n, prototype=prototypes.tile[n]}
  end
  s.is_chunk_generated = function(c) return (c[2] or c.y) * 32 < GEN end
  s.request_to_generate_chunks = function(pos, r) s.requested[#s.requested+1] = {pos=pos, r=r} end
  s.find_entities_filtered = function(f)
    local out = {}
    if f.type == 'tile-ghost' then
      for _, g in ipairs(tg) do
        local ok = true
        if f.area then
          local lt, rb = f.area.left_top or f.area[1], f.area.right_bottom or f.area[2]
          local x0, y0, x1, y1 = lt.x or lt[1], lt.y or lt[2], rb.x or rb[1], rb.y or rb[2]
          ok = g.position.x >= x0 and g.position.x <= x1 and g.position.y >= y0 and g.position.y <= y1
        end
        if ok and f.position then ok = math.abs(g.position.x - f.position.x) < 0.6 and math.abs(g.position.y - f.position.y) < 0.6 end
        if ok then out[#out+1] = g end
      end
    end
    return out
  end
  s.count_entities_filtered = function(f) return #s.find_entities_filtered(f) end
  -- the engine's ghost check as the copy showed it: the body on foundation, a tile ghost, or (forced) empty space; the
  -- exhaust generated and empty, with no tile ghost
  local function ghost_at(x, y) for _, g in ipairs(tg) do if math.floor(g.position.x) == x and math.floor(g.position.y) == y then return true end end end
  s.engine = function(pos, forced)
    for x = pos.x - 2, pos.x + 1 do for y = math.floor(pos.y) - 2, math.floor(pos.y) + 2 do
      local n = y >= GEN and 'out-of-map' or name_at(x, y)
      if n ~= 'space-platform-foundation' and not ghost_at(x, y) and not (forced and n == 'empty-space') then return false end
    end end
    for x = pos.x - 2, pos.x + 1 do for y = math.floor(pos.y) + 3, math.floor(pos.y) + 90 do
      if y >= GEN or name_at(x, y) ~= 'empty-space' or ghost_at(x, y) then return false end
    end end
    return true
  end
  s.can_place_entity = function(a)
    if a.name == 'tile-ghost' then return true end
    return s.engine(a.position, a.forced)
  end
  return s
end

local placewhy = dofile('mod/agent-harness_0.1.0/placewhy.lua'){}
local N = 0

-- rule_tiles: empty space under it needs 20 foundation (not stone brick); tile ghosts count as laid; built foundation
-- needs nothing; foundation behind it breaks the exhaust rule; tiles past the generated chunks are not judged.
do
  local s = platform()
  local r = placewhy.rule_tiles(s, force, thruster, {x=40, y=20.5}, N)
  eq(r.ruled, true); eq(#r.need, 20); eq(r.need[1].item, 'space-platform-foundation'); eq(r.need[1].tile, 'empty-space'); eq(r.broken, nil); eq(r.ungenerated, nil)
  local ghosts = {}
  for x = 38, 41 do for y = 18, 22 do ghosts[#ghosts+1] = {x, y} end end
  s = platform(nil, ghosts)
  r = placewhy.rule_tiles(s, force, thruster, {x=40, y=20.5}, N)
  eq(#r.need, 0, 'tile ghosts count as laid'); eq(r.broken, nil)
  r = placewhy.rule_tiles(s, force, thruster, {x=0, y=0.5}, N)
  eq(#r.need, 0, 'built foundation'); has(r.broken, 'breaks its tile rule 2 facing north: tiles x -2..1, y 3..90 need empty_space'); has(r.broken, 'space-platform-foundation at (-2,3)')
  -- (Sol's) a body at y 108..112 on a small platform: the exhaust runs past the generated chunks
  r = placewhy.rule_tiles(s, force, thruster, {x=-8, y=110.5}, N)
  eq(#r.need, 20); eq(r.broken, nil, 'tiles past the generated chunks are not judged')
  eq(r.ungenerated.count, 4 * (200 - 160 + 1)); eq(r.ungenerated.y0, 160); eq(r.ungenerated.y1, 200); eq(#r.ungenerated.chunks, 2)
  local text = placewhy.ungenerated_text(s, r.ungenerated, true)
  has(text, '164 tiles its tile rules need (x -10..-7, y 160..200) lie in 2 chunks this surface has not generated yet, and the game refuses it until they are')
  has(text, 'generating 2 chunks was requested now (as a player\'s view would): call again in a few seconds')
  eq(#s.requested, 2); eq(s.requested[1].r, 0, 'a plain request, never forced generation')
  eq(placewhy.ungenerated_text(s, {count=1, chunks={{x=1, y=6}}, x0=40, x1=40, y0=200, y1=200}, false),
    'the tile (40,200) it needs lies in a chunk this surface has not generated yet, and the game refuses it until that chunk is')
end
print('thrusterghost rule_tiles: ok')

-- The dry run, kind ghosts, as Sol's calls: empty space (needs foundation, laid by place_ghosts first), tile ghosts
-- (placeable), built foundation (placeable), and Sol's spot (no error: blocked, the chunks asked for).
do
  local s
  local api = {placewhy=placewhy, charted=function() return true end, own_platform=function() return true end,
    ghost_placeable=function(p, proto, pos, dir) return p.surface.engine(pos, true) end,
    placement_error=function() return 'placement blocked' end}
  local dryrun = dofile('mod/agent-harness_0.1.0/dryrun.lua')(api)
  -- the entry's row, or {status='ok'} when the summary says it places (a clean dry run lists no rows)
  local function one(surface, pos)
    s = surface
    local p = {surface=s, force=force, position={x=0, y=0}}
    local out = dryrun.check(p, {kind='ghosts', entities={{index=1, name='thruster', position=pos, direction=N}}})
    if out.entities then return out.entities[1] end
    eq(out.summary, '1 placeable (of 1)')
    return {status='ok'}
  end
  local row = one(platform(), {x=40, y=20.5})
  eq(row.status, 'needs_tiles'); has(row.why, 'stands on 20 empty-space tiles: needs 20 space-platform-foundation first (place_ghosts lays those tile ghosts under it first)')
  local ghosts = {}
  for x = 38, 41 do for y = 18, 22 do ghosts[#ghosts+1] = {x, y} end end
  row = one(platform(nil, ghosts), {x=40, y=20.5})
  eq(row.status, 'ok', 'on foundation tile ghosts')
  local built = {}
  for x = 38, 41 do for y = 28, 32 do built[#built+1] = {x, y} end end
  row = one(platform(built), {x=40, y=30.5})
  eq(row.status, 'ok', 'on built foundation')
  -- Sol's: the body over tile ghosts at y 108..112, the exhaust to y 200 past the generated (160) and valid (192) rows
  local sol = {}
  for x = -10, -7 do for y = 108, 112 do sol[#sol+1] = {x, y} end end
  row = one(platform(nil, sol), {x=-8, y=110.5})
  eq(row.status, 'blocked')
  has(row.why, 'tiles its tile rules need (x -10..-7, y 160..200) lie in 2 chunks this surface has not generated yet, and the game refuses it until they are')
  has(row.why, 'call again in a few seconds')
  eq(#s.requested, 2)
  -- once generated (the request's few ticks later) the same dry run takes it
  GEN, VALID = 400, 400
  row = one(platform(nil, sol), {x=-8, y=110.5})
  eq(row.status, 'ok', 'generated: placeable over its tile ghosts')
  GEN, VALID = 160, 192
end
print('thrusterghost dry run: ok')
prototypes, defines = nil, nil
