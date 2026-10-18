-- min_payload {platforms?, set?} (E8, Gemini 19:50: automatic silos launched rockets for 1-2 small items and spent
-- scarce low density structures; setting each platform's requests by hand took many calls): the custom minimum payload
-- of platform hub requests (the request GUI's "custom minimum payload", LogisticFilter minimum_delivery_count), read
-- for every request that imports from a planet, and set for named items on several platforms in one call. A set
-- changes only that number: min, max, quality and the import planet stay as they are; manual sections only.
return function(api)
  local M = {}
  local function try(fn) local ok, v = pcall(fn); if ok then return v end end
  local function name_of(v) return v and (type(v.name) == 'string' and v.name or try(function() return v.name.name end)) end
  local function from_of(f) return f.import_from and (type(f.import_from) == 'string' and f.import_from or try(function() return f.import_from.name end)) end
  -- The platforms named: nil or "all" every one of ours; a name or a list of names.
  local function platforms(p, which)
    local out, all = {}, {}
    for _, pl in pairs(p.force.platforms) do if pl.valid and pl.hub and pl.hub.valid then all[#all+1] = pl end end
    table.sort(all, function(x, y) return x.name < y.name end)
    if which == nil or which == 'all' then return all end
    local list = type(which) == 'string' and {which} or which
    assert(type(list) == 'table' and #list >= 1, 'platforms is "all", a platform name or a list of names')
    for _, n in ipairs(list) do
      local hit
      for _, pl in ipairs(all) do if pl.name == n then hit = pl end end
      assert(hit, 'no platform of ours named ' .. tostring(n))
      out[#out+1] = hit
    end
    return out
  end
  function M.handler(p, a)
    local lift = try(function() return prototypes.utility_constants.rocket_lift_weight end)
    local set = a.set
    if set ~= nil then
      assert(type(set) == 'table' and next(set) ~= nil and set[1] == nil, 'set is {item: N, ...} (0 or false clears the custom minimum payload)')
      for item, n in pairs(set) do
        assert(prototypes.item[item], 'unknown item ' .. tostring(item))
        assert(n == false or (type(n) == 'number' and n == math.floor(n) and n >= 0 and n <= 1000000), 'set ' .. item .. ': 1..1000000 items, or 0 or false to clear')
      end
    end
    local lines, changed, untouched = {}, 0, {}
    for item in pairs(set or {}) do untouched[item] = true end
    for _, pl in ipairs(platforms(p, a.platforms)) do
      local secs = try(function() return pl.hub.get_logistic_sections() end)
      for i = 1, secs and secs.sections_count or 0 do
        local sec = secs.get_section(i)
        for slot, f in pairs(try(function() return sec.filters end) or {}) do
          local item = f.value and name_of(f.value)
          local from = from_of(f)
          if item and set and set[item] ~= nil then
            assert(sec.is_manual, string.format('%s: %s is in a section the game manages (construction requests); the custom minimum payload is set on manual sections', pl.name, item))
            local n = set[item]
            local q = f.value.quality
            local nf = {value={type=f.value.type, name=item, quality=type(q) == 'table' and q.name or q, comparator=f.value.comparator}, min=f.min, max=f.max,
              import_from=from, minimum_delivery_count=(n ~= false and n > 0) and n or nil}
            sec.set_slot(slot, nf)
            f = try(function() return sec.get_slot(slot) end) or f
            changed = changed + 1; untouched[item] = nil
          end
          if item and from and (not set or set[item] ~= nil) then
            local w = try(function() return prototypes.item[item].weight end)
            local full = w and lift and w > 0 and math.floor(lift / w) or nil
            local held = try(function() return pl.hub.get_item_count(item) end) or 0
            local mp = f.minimum_delivery_count
            local grp = try(function() return sec.group end) or ''
            lines[#lines+1] = string.format('%s: %s from %s, asks %d (holds %d); custom minimum payload %s; a full rocket by weight %s%s',
              pl.name, item, from, f.min or 0, held, mp and tostring(mp) or 'none', full and tostring(full) or '?',
              grp:find('^platform_bom: ') and ' (in platform_bom\'s section: its keeper takes a change made here as its own)' or '')
          end
        end
      end
    end
    local missing = {}
    for item in pairs(untouched) do missing[#missing+1] = item end
    table.sort(missing)
    return {lines=#lines > 0 and lines or {'no request imports an item from a planet on these platforms'}, changed=set and changed or nil,
      not_requested=#missing > 0 and missing or nil,
      note=set and 'only the custom minimum payload changed: min, max, quality and import planet as they were' or nil}
  end
  M.schema = {min_payload = {platforms='optional "all" (default), a platform name, or a list of names',
    set='optional {item: N}: the custom minimum payload (the request GUI\'s) of that item\'s requests on those platforms, 1..1000000; 0 or false clears it. Only that number changes',
    returns='lines: each request that imports from a planet (those named in set, when set): platform, item, import planet, asks, holds, custom minimum payload (none), a full rocket of it by weight; changed (slots set); not_requested (set items no such platform requests)'}}
  return M
end
