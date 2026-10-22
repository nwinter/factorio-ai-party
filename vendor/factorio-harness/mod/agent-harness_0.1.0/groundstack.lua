-- One stack of items on the ground (item-entity, item-on-ground) as hovering it shows: the item, its quality, the
-- count and, for an item that spoils, how fresh it is (d22 batch78 AN1, Astra #1809: Gleba had thousands of dropped
-- items, and inspect and scan's inventory and spoil fields gave no stack name or count).
local M = {}
local spoils = {}  -- name@quality -> true when it spoils
local function read(e)
  local s = e.stack
  if not s.valid_for_read then return nil end
  local q = s.quality.name
  local key = s.name .. '@' .. q
  local v = spoils[key]
  if v == nil then
    local ok, ticks = pcall(function() return s.prototype.get_spoil_ticks(s.quality) end)
    v = ok and type(ticks) == 'number' and ticks > 0; spoils[key] = v
  end
  return {name=s.name, quality=q, count=s.count, fresh=v and math.floor((1 - s.spoil_percent) * 100) or nil}
end
-- {name, quality, count, fresh (percent, only for an item that spoils)} or nil
function M.stack(e)
  local ok, st = pcall(read, e)
  return ok and st or nil
end
-- "name@quality*count" (the quality only when not normal)
function M.text(st)
  return st and st.name .. (st.quality ~= 'normal' and '@' .. st.quality or '') .. '*' .. st.count or 'empty'
end
-- the spoil field's form: "name*count 62%" (fresh), nil when it does not spoil
function M.spoil_text(st)
  return st and st.fresh and string.format('%s %d%%', M.text(st), st.fresh) or nil
end
-- inspect's holds: "yumako*3, 62% fresh"
function M.holds(st)
  return st and M.text(st) .. (st.fresh and string.format(', %d%% fresh', st.fresh) or '') or 'empty'
end
return M
