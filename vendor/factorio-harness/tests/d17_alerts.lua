-- d17 alerts: an alert line shown with the same words in the last 10 minutes is left out of the team block; changed
-- words show; the kinds that wake a sleep and a platform hub's damage always show.
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
game={tick=1000}
local st={}
local B=dofile('mod/agent-harness_0.1.0/board.lua'){state=function() return st end}
local h={}
local push='14 inserters feeding logistic-chest near (10,4) wait for space'
local out=B.alerts_seen(h,{'attack #4 at (1,2): 3 attackers seen',push},1)
eq(#out,2)
game.tick=1000+600
out=B.alerts_seen(h,{'attack #4 at (1,2): 3 attackers seen',push,'platform Wren hit 2 times: space-platform-hub 40'},1)
eq(#out,2,'the repeat left out'); eq(out[1],'attack #4 at (1,2): 3 attackers seen'); eq(out[2],'platform Wren hit 2 times: space-platform-hub 40')
-- changed words are a new line
out=B.alerts_seen(h,{'15 inserters feeding logistic-chest near (10,4) wait for space'},0)
eq(#out,1)
-- after 10 minutes it shows again
game.tick=1000+B.REPEAT_SHOWN
out=B.alerts_seen(h,{push},0)
eq(#out,1,'10 minutes on: shown again')
eq(B.alerts_seen(h,{push},0),nil,'nothing new: no alerts')
game=nil
print('d17_alerts: ok')
