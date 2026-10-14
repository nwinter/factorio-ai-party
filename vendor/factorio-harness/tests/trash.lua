-- Run from repository root: lua tests/trash.lua
-- Personal logistics and auto-trash (trash.lua): the character's compiled
-- request limits, room under a max, the lines a take gets, the tally of a
-- timed take and the status line. Engine behaviour checked on a private
-- 2.0.77 server: 400 iron plates taken with a max of 100 moved 308 of the 408
-- held into the trash slots within 15 ticks; with trash unrequested on, 25
-- unrequested copper plates went there too.
local function eq(a, b, m) assert(a == b, (m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path = 'mod/agent-harness_0.1.0/?.lua;'..package.path
defines = {inventory={character_trash=8}}
local T = dofile('mod/agent-harness_0.1.0/trash.lua'){}
local main = {['iron-plate']=408, ['copper-plate']=25, coal=50}
local trash_room = {['iron-plate']=1000, ['copper-plate']=1000}
local trash_held = {}
local rp = {enabled=true, trash_not_requested=false,
  filters={{name='iron-plate', quality='normal', count=0, max_count=100}, {name='coal', quality='normal', count=10}}}
local trash = {
  get_insertable_count=function(f) return trash_room[f.name] or 0 end,
  is_empty=function() return next(trash_held) == nil end,
  get_contents=function() local out = {}; for n, c in pairs(trash_held) do out[#out+1] = {name=n, count=c, quality='normal'} end; table.sort(out, function(a, b) return a.name < b.name end); return out end}
local character = {valid=true, get_requester_point=function() return rp end, get_inventory=function(i) eq(i, 8); return trash end}
local p = {character=character, get_main_inventory=function() return {get_item_count=function(f) return main[f.name] or 0 end} end}

local lim = T.limits(p)
eq(lim.max['iron-plate@normal'], 100); eq(lim.requested['coal@normal'], true); eq(lim.max['coal@normal'], nil, 'coal has a min only')
eq(T.cap(lim, 'iron-plate'), 100); eq(T.cap(lim, 'coal'), nil); eq(T.cap(lim, 'copper-plate'), nil, 'unrequested, not trashed')
main['iron-plate'] = 60
eq(T.room(p, 'iron-plate'), 40); eq(T.room(p, 'coal'), nil)
main['iron-plate'] = 408
local lines = T.lines(p, {{name='iron-plate', count=400}, {name='coal', count=50}})
eq(#lines, 1); eq(lines[1], '400 iron-plate taken; your request max is 100: 308 go to trash')
-- Trash slots that hold less than the excess: the rest stays.
trash_room['iron-plate'] = 200
eq(T.lines(p, {{name='iron-plate', count=400}})[1], '400 iron-plate taken; your request max is 100: 200 go to trash; 108 more stay in your inventory (trash slots full)')
trash_room['iron-plate'] = 1000
-- Unrequested items go to trash when that is on.
rp.trash_not_requested = true
eq(T.cap(T.limits(p), 'copper-plate'), 0)
eq(T.lines(p, {{name='copper-plate', count=25}})[1], '25 copper-plate taken; it is not requested and your unrequested items go to trash: 25 go to trash')
rp.trash_not_requested = false
-- Personal logistics off: no limit, no lines.
rp.enabled = false
eq(T.limits(p), nil); eq(T.lines(p, {{name='iron-plate', count=400}}), nil); eq(T.room(p, 'iron-plate'), nil)
rp.enabled = true
-- A timed take: each take counts what it put over the cap (the game trashes it within ticks).
main['iron-plate'] = 114
local tally = T.count(p, nil, 'iron-plate', nil, 24)
eq(tally['iron-plate@normal'].n, 14, 'held 90, picked 24, max 100')
main['iron-plate'] = 130
tally = T.count(p, tally, 'iron-plate', nil, 30)
eq(tally['iron-plate@normal'].n, 44)
eq(T.count(p, nil, 'coal', nil, 50), nil, 'no max for coal')
eq(T.done(tally)[1], '44 iron-plate taken over your request max (100): the game moves them to your trash slots')
-- The status line.
eq(T.status(p), nil)
trash_held['iron-plate'] = 308
eq(T.status(p), 'iron-plate*308 in your trash slots: the game moves there what is over your request max (or unrequested, when unrequested items go to trash); logistic robots take them to storage')
print('trash: ok')
