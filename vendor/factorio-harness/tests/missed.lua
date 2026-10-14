-- Run from repository root: lua tests/missed.lua
-- Wakes a loop of sleeps throws away (missed.lua; Opus, shift12 12:26): the parts tests/sleep.lua's loop does not
-- reach. An eggs wake, a gap past the window, turns mode, and the line cap.
local function eq(a, b, m) assert(a == b, (m or 'mismatch') .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b)) end
game = {tick = 1000}
local st, mode = {}, 'realtime'
local M = dofile('mod/agent-harness_0.1.0/missed.lua'){state = function() return st end, clock_mode = function() return mode end}
-- An eggs wake: the sleep's last read shows it; the next sleep 12 ticks later.
eq(M.begin(7, 'sleep', {seconds = 300}), 'sleep')
game.tick = 1600
M.after(7, 'check', false, {woke = 'eggs', eggs = '3 pentapod-egg hatch within 5 min at (12,40)'}, nil)
game.tick = 1612
M.begin(7, 'sleep', {seconds = 300})
M.after(7, 'sleep', false, {}, nil)
game.tick = 2000
local kind, late = M.begin(7, 'status', {})
local reply = {}
M.after(7, kind, late, reply, nil)
eq(reply.team.missed_while_asleep[1], 'an eggs warning shown in a sleep reply that the next sleep followed 0.2 s later:')
eq(reply.team.missed_while_asleep[2], 'eggs: 3 pentapod-egg hatch within 5 min at (12,40)')
-- The next sleep 5 s or more after the last read: the reply reached the agent; nothing kept.
M.begin(7, 'sleep', {seconds = 300})
game.tick = 2600
M.after(7, 'check', false, {woke = 'told', team = {tells = {'x'}}}, {{tell = 3, tick = 2590, from = 'sol', text = 'hi', how = 'tell'}})
game.tick = 2900
M.begin(7, 'sleep', {seconds = 300})
reply = {}
M.after(7, 'sleep', true, reply, nil)
eq(reply.team, nil, 'nothing missed')
-- Turns mode: game time stands still while a model reads; nothing is kept.
mode = 'turns'
M.after(7, 'check', false, {woke = 'told'}, {{tell = 4, tick = 2900, from = 'sol', text = 'hi', how = 'tell'}})
M.begin(7, 'sleep', {seconds = 300})
mode = 'realtime'
game.tick = 3500
kind, late = M.begin(7, 'chat', {})
reply = {}
M.after(7, kind, late, reply, nil)
eq(reply.team, nil, 'turns mode keeps nothing')
-- At most 12 item lines; the rest counted.
M.begin(7, 'sleep', {seconds = 300})
local many = {}
for i = 1, 15 do many[i] = {tell = i, tick = 3500, from = 'grok', text = 'n' .. i, how = 'tell'} end
M.after(7, 'check', false, {woke = 'told'}, many)
game.tick = 3510
M.begin(7, 'sleep', {seconds = 300})
game.tick = 4000
kind, late = M.begin(7, 'status', {})
reply = {}
M.after(7, kind, late, reply, nil)
local lines = reply.team.missed_while_asleep
eq(lines[1], '15 tells shown in a sleep reply that the next sleep followed 0.2 s later:')
eq(lines[2], 'tell from grok, 8s ago: n1'); eq(lines[13], 'tell from grok, 8s ago: n12'); eq(lines[14], '+3 more'); eq(#lines, 14)
-- fh wait's final read: a status within 120 ticks of its last poll (status peek brief) is no ordinary request.
M.begin(7, 'status', {peek = true, brief = true})
game.tick = 4030
eq(M.kind(7, 'status', {}), 'final')
game.tick = 4200
eq(M.kind(7, 'status', {}), nil)
print('missed: ok')
