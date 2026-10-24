-- d24 batch158 (the harness review's improvement 2): alerts that reached no one. On a copy of world n at 07:34, Nauvis's
-- groups went to "haiku (nearest)" while Haiku had been logged out for six hours, and ammo_low groups of hand-fed
-- turrets with no builder record and no agent within 64 tiles went to no one (to: null). Now the nearest agent that
-- plays (not offline, not resting) hears a group, nearer ones that do not named; a group no playing agent hears goes
-- to the team (every playing agent) with why.
-- Run from the harness root: lua tests/d24_batch158.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
game={tick=1000}; defines={entity_status={},alert_type={},inventory={}}
local A=require('pushalerts'){state=function() return {board={items={}}} end,agents=function() return {} end,who=function(p) return p.name end}
assert(A.owners,'before: no owners export (the nearest agent heard a group whether it played or not)')
local function place(x,y,extra)
  local p={key='nauvis',position={x=x,y=y}}
  for k,v in pairs(extra or {}) do p[k]=v end
  return p
end
local roster={haiku={index=7,place=place(10,0,{offline=true})},grok={index=4,place=place(20,0,{resting='resting until 15:59 (quota)'})},
  luna={index=3,place=place(50,0)},sol={index=2,place={key='vulcanus',position={x=0,y=0}}}}
local g={kind='no_power',surface='nauvis',center={x=0,y=0},by={}}
local o=A.owners(g,roster)
eq(o.luna,'nearest playing; haiku: offline, grok: resting nearer','the nearest that plays, nearer ones named')
eq(o.haiku,nil); eq(o['*team'],nil)
eq(A.to_text('luna',o.luna),'luna (nearest playing; haiku: offline, grok: resting nearer)')
-- the nearest plays: as before
roster.haiku.place.offline=nil
eq(A.owners(g,roster).haiku,'nearest')
-- no one on the surface plays: the nearest is named, and the team hears it
roster.haiku.place.offline=true; roster.luna.place.offline=true
o=A.owners(g,roster)
eq(o.haiku,'nearest, offline')
eq(o['*team'],'no agent it goes to plays now (haiku offline)')
roster.luna.place.offline=nil
-- ammo_low, hand-fed, no builder record, no agent within 64 tiles: the team, with why
local ammo={kind='ammo_low',surface='nauvis',center={x=500,y=500},by={}}
o=A.owners(ammo,roster)
eq(o['*team'],'no builder record for these turrets and no agent within 64 tiles of them')
-- built by an agent who is offline: the team too
ammo.by={haiku=1}
o=A.owners(ammo,roster)
eq(o.haiku,'built'); eq(o['*team'],'no agent it goes to plays now (haiku offline)')
-- built by one who plays: that agent alone
ammo.by={luna=1}
o=A.owners(ammo,roster)
eq(o.luna,'built'); eq(o['*team'],nil)
-- a platform's group with no agent on it: no one, as before
eq(next(A.owners({kind='power_high',surface='platform-6',center={x=0,y=0},by={}},roster)),nil)
eq(A.playing({place=place(0,0)}),true); eq(A.playing({place=place(0,0,{offline=true})}),false); eq(A.playing({}),false)
game,defines=nil,nil
print('d24_batch158 alerts to agents that play, else the team: ok')
