-- argforms (d24 batch154, the batch149 review's bug 4 and improvements 4-5): argument forms read in one place.
-- item "name@quality" (inspect's signal form, #2104): split here once, for a call's item and for each record of a
-- record list that takes item and quality (argshapes.lua); an action that takes no quality refuses it, naming quality.
-- platform given where an action takes the platform under another argument (platforms, lane, surface): aliases.lua
-- runs the call that way (corrected); where nothing takes it, the refusal names the argument or the action that
-- does. tells: after is since; unread, seq and from are refused naming since.
local M = {}

-- "name@quality" -> name, quality; anything else -> itself, nil.
function M.split(v)
  if type(v) ~= 'string' then return v, nil end
  local at = v:find('@', 1, true)
  if not at then return v, nil end
  return v:sub(1, at - 1), v:sub(at + 1)
end

local function qualities()
  local list = {}
  for name, q in pairs((prototypes and prototypes.quality) or {}) do
    local ok, level = pcall(function() return q.level end)
    if name ~= 'quality-unknown' then list[#list+1] = {name=name, level=ok and tonumber(level) or 0} end
  end
  table.sort(list, function(a, b) if a.level ~= b.level then return a.level < b.level end return a.name < b.name end)
  local out = {}
  for i, q in ipairs(list) do out[i] = q.name end
  return table.concat(out, ', ')
end

-- A call's item (or a record's, where = 'builds[2]' ...): "name@quality" becomes item name and quality q where the
-- action takes quality; else refused naming quality. Item names hold no "@", so nothing else changes.
local NOT_ITEM = {checks=true}
function M.item_quality(action, t, takes_quality, where)
  if NOT_ITEM[action] or type(t) ~= 'table' then return end
  local name, q = M.split(t.item)
  if q == nil then return end
  local label = where and where .. '.item' or 'item'
  if name == '' or q == '' then
    error(string.format('%s %s: an item name, or name@quality (iron-plate@uncommon)', label, t.item), 0)
  end
  if prototypes and prototypes.quality and not prototypes.quality[q] then
    error(string.format('%s %s: no quality named %s (qualities: %s)', label, t.item, q, qualities()), 0)
  end
  if not takes_quality then
    error(string.format('%s %s: %s takes no quality (no quality argument, and no name@quality): item is the name alone, %s',
      label, t.item, action, name), 0)
  end
  if t.quality ~= nil and t.quality ~= q then
    error(string.format('%s %s says quality %s, and quality says %s', label, t.item, q, tostring(t.quality)), 0)
  end
  t.item, t.quality = name, q
end

-- transfer's refusal for an item name that is no item, in place of the engine's "Unknown item name: X" (the
-- review's bug 4); any other error as it was.
function M.unknown_item(args, err)
  local text = tostring(err)
  if not text:find('Unknown item name', 1, true) then return err end
  local name = text:match('Unknown item name: ([^%s;,]+)') or (type(args) == 'table' and tostring(args.item)) or '?'
  local fluid = prototypes and prototypes.fluid and prototypes.fluid[name] and ' (a fluid: items move by hand; fluids move in pipes, tanks, pumps and barrels)' or ''
  return string.format('item %s: no item named %s%s', name, name, fluid)
end

-- platform given to an action that does not take it. as: the argument that takes it ('surface': the platform's surface
-- name; stock's surface takes the platform's own name); text: what the action reads, for a refusal.
M.PLATFORM = {
  supply={as='surface', surface=true},
  fuel_budget={as='surface', surface=true},
  stock={as='surface'},
  min_payload={as='platforms'},
  pods={text='pods reads the cargo pods that landed on a planet with no landing pad to take them (surface: a planet, default yours); delivery_watch counts the pods a platform sends down (from: the platform)'},
  freight_audit={text='freight_audit reads one item on every planet and every platform at once (a line for each platform); it takes item alone'},
  delivery_watch={text='delivery_watch takes a platform as from (the platform that carries the item down: only its pods count) or in to as {platform} (a consumer aboard it)'},
  build={text='build places by hand where your character stands, within its reach; on a platform, place_ghosts, paste and blueprint_place take platform (the platform builds the ghosts from its hub)'},
}
-- tells (it takes since and limit): after is since; the others, refused naming since.
M.TELLS = {
  seq='tells takes since: since=N lists the tells after seq N (since=0: all of them, sent and received)',
  unread='tells takes since: without since it lists the last 30 tells you received, read or not (those it lists leave the team block\'s unread tells)',
  from='tells takes since: since=N lists the tells after seq N; each tell names its sender (from), and tells has no filter by sender',
}

-- The argument that takes platform for this action (and the value it takes), or nil. takes(action, key);
-- surface_of(name): the surface name of our platform of that name, or nil.
function M.platform_as(action, takes)
  local rule = M.PLATFORM[action]
  if rule and rule.as then return rule end
  if takes(action, 'lane') and not takes(action, 'platform') then return {as='lane', lane=true} end
  return nil
end
function M.platform_value(rule, name, surface_of)
  if type(name) ~= 'string' then return nil end
  if rule.lane then return 'platform:' .. name end
  if rule.surface or rule.as == 'surface' then
    local s = surface_of(name)
    if not s then return nil end
    return rule.surface and s or name
  end
  return name
end

-- The refusal for argument key of action, when this module knows the form meant; nil otherwise.
M.REPLY_FIELD = {ores = {drill_list = 'drill_list is a reply field: every ores call with patch carries it on the patch row (with forecast or without)'}}
function M.refusal(action, key, args, takes, surface_of)
  if key == 'platform' then
    local rule = M.platform_as(action, takes)
    if rule then
      local named = type(args.platform) == 'string' and surface_of(args.platform) == nil and rule.as ~= 'platforms' and not rule.lane
        and string.format(': no platform of ours is named %s', args.platform) or ''
      local how = rule.lane and 'lane="platform:NAME"' or rule.as == 'platforms' and 'platforms (a platform name, or a list of names)'
        or rule.surface and 'surface (the platform\'s surface name, platform-N, as platforms lists it)' or 'surface (a planet or platform name)'
      return string.format('%s takes no platform argument; it takes the platform as %s%s', action, how, named)
    end
    local text = M.PLATFORM[action] and M.PLATFORM[action].text
    if text then return string.format('%s takes no platform argument: %s', action, text) end
  end
  if action == 'tells' and M.TELLS[key] then return M.TELLS[key] end
  -- (d25 batch199 QL2, Sol #2295) a reply field sent as an argument
  if M.REPLY_FIELD[action] and M.REPLY_FIELD[action][key] then return M.REPLY_FIELD[action][key] end
  if action == 'tells' and key == 'after' then return 'tells takes since: since=N lists the tells after seq N (after is since, a number)' end
  return nil
end

return M
