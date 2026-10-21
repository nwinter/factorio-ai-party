-- Names in free text (board titles and steps), longest first (d20 batch67 AC1, Astra #1609: board_review read
-- "Kestrel II" and "Kestrel IVc" as the gone "Kestrel"). Each candidate is {name=...} plus whatever its caller keeps
-- with it; a candidate takes the spans of the text where its whole name stands between non-letters and non-digits
-- and no longer name took them first. Names of one length: the name as the game keeps it (its case) first, then
-- the same name in any case. Returns the matches in text order: {name, s, e, c=candidate}.
local M = {}
local function bounded(text, s, e)
  return not text:sub(s - 1, s - 1):match('[%w]') and not text:sub(e + 1, e + 1):match('[%w]')
end
-- The candidates sorted once for several texts (M.find takes either).
function M.prepare(candidates)
  local list = {prepared=true}
  for _, c in ipairs(candidates or {}) do
    if type(c.name) == 'string' and c.name ~= '' then list[#list+1] = {name=c.name, low=c.name:lower(), c=c} end
  end
  table.sort(list, function(x, y) if #x.name ~= #y.name then return #x.name > #y.name end return x.name < y.name end)
  return list
end
function M.find(text, candidates)
  if type(text) ~= 'string' or text == '' then return {} end
  local list = candidates and candidates.prepared and candidates or M.prepare(candidates)
  local low, taken, out = text:lower(), {}, {}
  local function free(s, e)
    for _, t in ipairs(taken) do if s <= t[2] and e >= t[1] then return false end end
    return true
  end
  local function scan(hay, x, needle)
    local from = 1
    while true do
      local s, e = hay:find(needle, from, true)
      if not s then return end
      if bounded(text, s, e) and free(s, e) then
        taken[#taken+1] = {s, e}
        out[#out+1] = {name=x.name, s=s, e=e, c=x.c}
      end
      from = s + 1
    end
  end
  local k = 1
  while k <= #list do
    local j = k
    while j < #list and #list[j + 1].name == #list[k].name do j = j + 1 end
    local here = {}
    for n = k, j do if low:find(list[n].low, 1, true) then here[#here+1] = list[n] end end
    for _, x in ipairs(here) do scan(text, x, x.name) end
    for _, x in ipairs(here) do scan(low, x, x.low) end
    k = j + 1
  end
  table.sort(out, function(x, y) return x.s < y.s end)
  return out
end
return M
