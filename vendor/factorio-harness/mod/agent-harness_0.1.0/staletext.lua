-- (d23 batch123 CF1, viewer Aurora 09:44: "Luna's focus still shows the removed mash prerequisite. Could plan or
-- dependency changes flag stale focus/blocker text and prompt a refresh?") What a board change removed, and whether a
-- focus or team-plan line names it. A change is {what, was, words, ids, step, id}: the words of the text it removed (an
-- edited step's or title's words gone from the new text, a removed step's words, a dropped link's title words) and the
-- item numbers it unlinked. A text names it when it holds at least 2 of those words (all of them when fewer), or #N of an
-- unlinked item. Words: runs of letters, 4 or more, lower case, without the common ones below.
local M = {}
local STOP = {}
for w in ([[with that this then than from into only both when what each until after before there their them they have
  been will would should could also more most some such just over under unless while where which other about once
  your ours does done make made keep same very much many first last next were here back them able need needs]]):gmatch('%a+') do STOP[w] = true end
M.MIN_WORD = 4

function M.words(text)
  local set = {}
  for w in tostring(text or ''):lower():gmatch('%a+') do
    if #w >= M.MIN_WORD and not STOP[w] then set[w] = true end
  end
  return set
end
-- The words of `old` that `new` no longer has, sorted.
function M.removed(old, new)
  local now, out = M.words(new), {}
  for w in pairs(M.words(old)) do if not now[w] then out[#out+1] = w end end
  table.sort(out)
  return out
end
local function list(set)
  local out = {}
  for w in pairs(set) do out[#out+1] = w end
  table.sort(out)
  return out
end
M.list = list
-- What of change c the text names: {'#12', 'mash', ...} or nil.
function M.names(text, c)
  if not text or text == '' then return nil end
  local hits = {}
  for _, id in ipairs(c.ids or {}) do
    if tostring(text):find('#' .. id .. '%f[%D]') then hits[#hits+1] = '#' .. id end
  end
  local have, got = M.words(text), {}
  for _, w in ipairs(c.words or {}) do if have[w] then got[#got+1] = w end end
  local need = math.min(2, #(c.words or {}))
  if need > 0 and #got >= need then for _, w in ipairs(got) do hits[#hits+1] = w end end
  return #hits > 0 and hits or nil
end
local function clip(s, n)
  s = tostring(s or '')
  if #s <= n then return s end
  local cut = n - 3
  while cut > 0 and s:byte(cut + 1) and s:byte(cut + 1) >= 128 and s:byte(cut + 1) < 192 do cut = cut - 1 end
  return s:sub(1, cut) .. '...'
end
M.clip = clip
-- The mark kept on a focus or plan line: {change, was, names, tick, by}.
function M.mark(c, hits, tick)
  return {change=c.what, was=c.was and clip(c.was, 100) or nil, names=hits, tick=tick}
end
-- "marked stale 12m ago: step 8 of #1052 edited by astra (was: "..."); names mash, site"
function M.text(m, ago)
  return string.format('marked stale %s ago: %s%s; this text names %s', ago, m.change, m.was and ' (was: "' .. m.was .. '")' or '',
    table.concat(m.names or {}, ', '))
end
return M
