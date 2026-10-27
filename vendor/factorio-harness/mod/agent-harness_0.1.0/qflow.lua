-- (d24 batch152 PX1, Astra #2182: Asterion's 20 rare laser turrets drew 5.8 MW and power listed no laser at all) In
-- 2.0.77 a LuaFlowStatistics read by name (get_flow_count{name=...}, get_input_count(name), get_output_count(name))
-- counts normal quality only; name={name=, quality=} counts that quality (a quality= field beside name is ignored); and
-- input_counts and output_counts give each name's total over every quality. Item, electric and build statistics are
-- kept by quality; fluid and pollution statistics take a name only (a pair fails there), so their reads stay plain.
-- Measured on a copy of world n (tick 56717928): a read is 0.4-5 us, a pair the same with its argument table kept.
local M = {}
local QS
-- The qualities a read covers: every one not hidden, by level (normal first).
function M.qualities()
  if QS then return QS end
  local list = {}
  local ok = pcall(function()
    for name, q in pairs(prototypes.quality) do
      if name ~= 'quality-unknown' and not q.hidden then list[#list+1] = {name=name, level=q.level or 0} end
    end
  end)
  if not ok or #list == 0 then return {'normal'} end
  table.sort(list, function(x, y) return x.level < y.level or (x.level == y.level and x.name < y.name) end)
  QS = {}
  for i, q in ipairs(list) do QS[i] = q.name end
  return QS
end
function M.reset() QS = nil end
local ARG = {name=nil, category=nil, precision_index=nil, count=nil}
local PAIR = {name=nil, quality=nil}
local function flow_of(stats, name, q, category, pi, count)
  PAIR.name, PAIR.quality = name, q
  ARG.name, ARG.category, ARG.precision_index, ARG.count = q == 'normal' and name or PAIR, category, pi, count
  local ok, v = pcall(stats.get_flow_count, ARG)
  return ok and tonumber(v) or 0
end
local function count_of(stats, name, q, category)
  PAIR.name, PAIR.quality = name, q
  local f = category == 'input' and stats.get_input_count or stats.get_output_count
  local ok, v = pcall(f, q == 'normal' and name or PAIR)
  return ok and tonumber(v) or 0
end
-- Only normal has ever counted for name: all (its input_counts or output_counts value, every quality's total since the
-- game began) is no more than normal's own total.
local function normal_only(stats, name, category, all)
  return all ~= nil and count_of(stats, name, 'normal', category) >= all
end
-- name's flow over every quality: the total, and by, a list {quality, n} of each quality with any, by level (nil when
-- only normal has any). all: the name's input_counts/output_counts value when the caller has it (then a name only
-- ever counted at normal is read once).
function M.flow_by(stats, name, category, pi, count, all)
  local normal = flow_of(stats, name, 'normal', category, pi, count)
  if normal_only(stats, name, category, all) then return normal, nil end
  local total, by = normal, nil
  for _, q in ipairs(M.qualities()) do
    if q ~= 'normal' then
      local n = flow_of(stats, name, q, category, pi, count)
      if n ~= 0 then
        by = by or (normal ~= 0 and {{quality='normal', n=normal}} or {})
        by[#by+1] = {quality=q, n=n}
        total = total + n
      end
    end
  end
  return total, by
end
function M.flow(stats, name, category, pi, count, all) return (M.flow_by(stats, name, category, pi, count, all)) end
-- name's count since the game began (get_input_count, get_output_count) over every quality, and by as flow_by gives.
function M.count_by(stats, name, category)
  local normal = count_of(stats, name, 'normal', category)
  local total, by = normal, nil
  for _, q in ipairs(M.qualities()) do
    if q ~= 'normal' then
      local n = count_of(stats, name, q, category)
      if n ~= 0 then
        by = by or (normal ~= 0 and {{quality='normal', n=normal}} or {})
        by[#by+1] = {quality=q, n=n}
        total = total + n
      end
    end
  end
  return total, by
end
function M.count(stats, name, category) return (M.count_by(stats, name, category)) end
-- by as text: 'normal 12, rare 3' (each n through fmt, default rounded); nil for nil
function M.label(by, fmt)
  if not by then return nil end
  local parts = {}
  for _, r in ipairs(by) do parts[#parts+1] = r.quality .. ' ' .. (fmt and fmt(r.n) or tostring(math.floor(r.n + 0.5))) end
  return table.concat(parts, ', ')
end
-- (d26 batch249 R10, the batch227 review 3c) a holder's count of an item (an entity or an inventory) at every quality,
-- in the forms measured on a copy (2.0.77; a chest of 600 uncommon iron-plate read 0 by its bare name): an entity's
-- get_item_count{name} with no quality, an inventory's get_item_count_filtered{name}. total, and by as count_by gives
-- (nil when all of it is normal). line(l, name): a transport line's, summed over {name, quality} pairs.
local ANY, ONE = {name=nil}, {name=nil, quality=nil}
function M.held(holder, name)
  ANY.name = name
  -- (no closure: where_is reads ~2000 holders a call; the method's own read was outside pcall before too)
  local ok, n = pcall(holder.object_name == 'LuaInventory' and holder.get_item_count_filtered or holder.get_item_count, ANY)
  if not ok or type(n) ~= 'number' or n == 0 then return 0, nil end
  local okn, normal = pcall(holder.get_item_count, name)
  if okn and normal == n then return n, nil end
  local by = {}
  for _, q in ipairs(M.qualities()) do
    ONE.name, ONE.quality = name, q
    local okq, k = pcall(holder.get_item_count, ONE)
    if okq and type(k) == 'number' and k > 0 then by[#by+1] = {quality=q, n=k} end
  end
  return n, by
end
function M.line(l, name)
  local n = 0
  for _, q in ipairs(M.qualities()) do
    ONE.name, ONE.quality = name, q
    local ok, k = pcall(l.get_item_count, q == 'normal' and name or ONE)
    if ok and type(k) == 'number' then n = n + k end
  end
  return n
end
-- several holders' by summed into acc ({quality: n}, normal for a nil by); by_of(acc): acc as by (nil when all normal)
function M.add(acc, n, by)
  if by then for _, r in ipairs(by) do acc[r.quality] = (acc[r.quality] or 0) + r.n end
  elseif n > 0 then acc.normal = (acc.normal or 0) + n end
  return acc
end
function M.by_of(acc)
  local by = {}
  for _, q in ipairs(M.qualities()) do if (acc[q] or 0) > 0 then by[#by+1] = {quality=q, n=acc[q]} end end
  if #by == 0 or (#by == 1 and by[1].quality == 'normal') then return nil end
  return by
end
-- n with its qualities when any is above normal: '200 (normal 150, rare 50)', else '200'
function M.text(n, by) return by and string.format('%d (%s)', n, M.label(by)) or tostring(n) end
-- the qualities in by, as a list of names (nil for nil)
function M.names(by)
  if not by then return nil end
  local out = {}
  for _, r in ipairs(by) do out[#out+1] = r.quality end
  return out
end
return M
