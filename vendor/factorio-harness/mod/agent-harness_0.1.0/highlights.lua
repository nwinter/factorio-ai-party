-- Camera highlights: what an agent is doing, drawn in the game for the
-- director camera clients only (LuaRendering with players = the connected
-- camera players, never an agent's player): a ring in the agent's colour on
-- the spot or area it acts on, a thin dashed line from its character when the
-- spot is off to the side, and a short label ("Sol · rearming"). The stream
-- service sends the whole set with each update (operator dispatch
-- `highlights`, at most ~2/s); each call replaces the last set, and every
-- object also expires on its own (time_to_live). Nothing in the game changes,
-- and agents never see them: no agent action draws or reads them.
return function(api)
  local M = {operator={}}
  local MAX_ITEMS, DEFAULT_TTL, MIN_TTL, MAX_TTL, MAX_LABEL, MAX_BUBBLE = 12, 360, 30, 1800, 80, 120
  local LINE_FROM = 8  -- tiles: a spot this far from the agent's character gets a line from it
  local WHITE = {r=1, g=1, b=1}
  local function store()
    local s = api.state()
    s.highlights = s.highlights or {ids={}}
    return s.highlights
  end
  local function clear()
    local h = store()
    for _, id in ipairs(h.ids) do
      local o = rendering.get_object_by_id(id)
      if o and o.valid then o.destroy() end
    end
    h.ids = {}
  end
  -- The connected camera clients (directors): the only players who see these.
  local function cameras()
    local out = {}
    for _, p in pairs(game.connected_players) do
      if api.director(p.index) then out[#out+1] = p.index end
    end
    table.sort(out)
    return out
  end
  local function number(v, lo, hi) return type(v) == 'number' and v == v and v >= lo and v <= hi end
  local function colour(c)
    if type(c) ~= 'table' then return nil end
    if number(c.r, 0, 1) and number(c.g, 0, 1) and number(c.b, 0, 1) then return {r=c.r, g=c.g, b=c.b} end
  end
  local function check(it, i)
    assert(type(it) == 'table', 'items[' .. i .. '] must be an object')
    local p = it.position
    assert(type(p) == 'table' and number(p.x, -1e6, 1e6) and number(p.y, -1e6, 1e6), 'items[' .. i .. '].position {x,y} is required')
    assert(it.extent == nil or number(it.extent, 0, 200), 'items[' .. i .. '].extent must be 0..200 tiles')
    assert(it.label == nil or type(it.label) == 'string', 'items[' .. i .. '].label must be text')
    assert(it.agent == nil or type(it.agent) == 'string', 'items[' .. i .. '].agent must be an agent name')
    assert(it.surface == nil or type(it.surface) == 'string', 'items[' .. i .. '].surface must be a surface name')
    assert(it.kind == nil or type(it.kind) == 'string', 'items[' .. i .. '].kind must be text')
    assert(it.alpha == nil or number(it.alpha, 0, 1), 'items[' .. i .. '].alpha must be 0..1')
    assert(it.ttl == nil or number(it.ttl, MIN_TTL, MAX_TTL), 'items[' .. i .. '].ttl must be ' .. MIN_TTL .. '..' .. MAX_TTL .. ' ticks')
  end
  -- Looking (inspect, scan) reads apart from acting: a thin dotted line and
  -- ring; acting (building, configuring, moving items, fighting) a bold dashed one.
  local STYLE = {looking={ring=1.5, line=1.5, dash=0.25, gap=0.75}, acting={ring=3, line=2.5, dash=1, gap=0.4}}
  -- "{entity}" in a label: what stands at the spot ("inspecting {entity}" ->
  -- "inspecting gun turret"), or nothing.
  local function entity_at(surface, pos)
    local ok, list = pcall(function() return surface.find_entities_filtered{position=pos, radius=0.6, limit=4} end)
    for _, e in ipairs(ok and list or {}) do
      if e.valid and e.type ~= 'character' and e.type ~= 'resource' then
        return (e.type == 'entity-ghost' and (e.ghost_name .. ' ghost') or e.name):gsub('%-', ' ')
      end
    end
    for _, e in ipairs(ok and list or {}) do
      if e.valid and e.type == 'resource' then return (e.name:gsub('%-', ' ')) end
    end
    return ''
  end
  local function fill(label, surface, pos)
    if not label:find('{entity}', 1, true) then return label end
    local name = entity_at(surface, pos)
    return (label:gsub('{entity}', function() return name end):gsub('%s+', ' '):gsub('%s+$', ''))
  end
  M.schema = {highlights={items='array of up to 12 {position {x,y}, extent? (tiles across), surface? (default nauvis), agent? (name: its colour and a line from its character), color? {r,g,b} 0..1, label? (1..80 characters; {entity} becomes what stands at the spot), kind? (looking: thin dotted; else bold dashed), alpha? 0..1, ttl? ticks}',
    ttl='ticks each object lives (30..1800, default 360)', clear='true: remove the set drawn last',
    bubbles='array of up to 12 {agent, text (1..120 characters), ttl? ticks}: a speech bubble over the agent\'s character while its line is voiced',
    returns='drawn (objects), players (the camera players who see them); with no camera client connected nothing is drawn'}}
  -- {items, ttl} or {clear=true}: replaces the set drawn last.
  function M.operator.highlights(a)
    a = a or {}
    if type(a) == 'string' then a = helpers.json_to_table(a) end
    assert(type(a) == 'table', 'highlights takes {items=[...], ttl?} or {clear=true}')
    local items = a.items or {}
    assert(type(items) == 'table' and #items <= MAX_ITEMS, 'items must be an array of at most ' .. MAX_ITEMS)
    local ttl = a.ttl or DEFAULT_TTL
    assert(number(ttl, MIN_TTL, MAX_TTL), 'ttl must be ' .. MIN_TTL .. '..' .. MAX_TTL .. ' ticks')
    for i, it in ipairs(items) do check(it, i) end
    local bubbles = a.bubbles or {}
    assert(type(bubbles) == 'table' and #bubbles <= MAX_ITEMS, 'bubbles must be an array of at most ' .. MAX_ITEMS)
    for i, b in ipairs(bubbles) do
      assert(type(b) == 'table' and type(b.agent) == 'string' and type(b.text) == 'string', 'bubbles[' .. i .. '] needs agent and text')
      assert(b.ttl == nil or number(b.ttl, MIN_TTL, MAX_TTL), 'bubbles[' .. i .. '].ttl must be ' .. MIN_TTL .. '..' .. MAX_TTL .. ' ticks')
    end
    clear()
    if a.clear == true or (#items == 0 and #bubbles == 0) then return {ok=true, tick=game.tick, drawn=0, cleared=true} end
    local players = cameras()
    -- An empty players list would show the objects to everyone, agents included.
    if #players == 0 then return {ok=true, tick=game.tick, drawn=0, note='no camera client connected: nothing drawn'} end
    local h, skipped = store(), 0
    local function keep(o) if o then h.ids[#h.ids+1] = o.id end end
    for _, it in ipairs(items) do
      local surface = game.get_surface(it.surface or 'nauvis')
      if not surface then skipped = skipped + 1
      else
        local who = it.agent and api.agent(it.agent)
        local base = colour(it.color) or (who and who.color) or WHITE
        -- Fading: the stream lowers alpha as the action ages (colours are premultiplied).
        local alpha = it.alpha or 1
        local col = {r=base.r * alpha, g=base.g * alpha, b=base.b * alpha, a=alpha}
        local style = it.kind == 'looking' and STYLE.looking or STYLE.acting
        local life = it.ttl or ttl
        local pos = {x=it.position.x, y=it.position.y}
        local r = math.max(1.2, (it.extent or 0) / 2 + 0.8)
        local label = it.label and it.label ~= '' and fill(it.label, surface, pos):sub(1, MAX_LABEL) or nil
        keep(rendering.draw_circle{color=col, radius=r, width=style.ring, filled=false, target=pos, surface=surface, players=players, time_to_live=life})
        if label then
          keep(rendering.draw_text{text=label, target={x=pos.x, y=pos.y - r - 0.4}, surface=surface, players=players,
            color=col, scale=1.4, alignment='center', vertical_alignment='bottom', time_to_live=life, use_rich_text=false})
        end
        local c = who and who.character
        if c and c.valid and c.surface == surface then
          local dx, dy = pos.x - c.position.x, pos.y - c.position.y
          local d = (dx * dx + dy * dy)^0.5
          if d >= LINE_FROM then
            keep(rendering.draw_line{color={r=col.r * 0.8, g=col.g * 0.8, b=col.b * 0.8, a=alpha * 0.8}, width=style.line, from=c, to=pos,
              surface=surface, players=players, time_to_live=life, dash_length=style.dash, gap_length=style.gap})
            -- The same label at the character's end of the line, 4 tiles along
            -- it (in frame while the camera follows the agent; the target end
            -- may be off screen), with the distance.
            if label then
              keep(rendering.draw_text{text=string.format('%s · %d m', label, math.floor(d + 0.5)),
                target={entity=c, offset={dx / d * 4, dy / d * 4 - 0.3}}, surface=surface, players=players, color=col, scale=1.1,
                alignment='center', vertical_alignment='bottom', time_to_live=life, use_rich_text=false})
            end
          end
        end
      end
    end
    -- Speech bubbles: the voiced line over the agent's character (it follows the character).
    for _, b in ipairs(bubbles) do
      local who = api.agent(b.agent)
      local c = who and who.character
      if c and c.valid then
        local text = b.text:gsub('[%c]+', ' ')
        text = #text > MAX_BUBBLE and text:sub(1, MAX_BUBBLE - 3) .. '...' or text
        local life = b.ttl or ttl
        local half = math.min(9, #text * 0.11 + 0.4)
        keep(rendering.draw_rectangle{color={r=0, g=0, b=0, a=0.6}, filled=true, left_top={entity=c, offset={-half, -3.75}},
          right_bottom={entity=c, offset={half, -3.05}}, surface=c.surface, players=players, time_to_live=life})
        keep(rendering.draw_text{text=text, target={entity=c, offset={0, -3.7}}, surface=c.surface, players=players,
          color=who.color or WHITE, scale=1.1, alignment='center', time_to_live=life, use_rich_text=false})
      else skipped = skipped + 1 end
    end
    return {ok=true, tick=game.tick, drawn=#h.ids, players=players, skipped=skipped > 0 and skipped or nil}
  end
  return M
end
