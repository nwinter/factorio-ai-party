-- Run from repository root: lua tests/d29_batch336_long.lua
-- (d29 batch336 FL3) platform_production {long: true}: made and used over the game's 1 h, 10 h, 50 h and 250 h windows,
-- for a platform or a planet, the items most made and used in all first; imports are not production.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
local function fails(fn,text) local ok,err=pcall(fn); assert(not ok and tostring(err):find(text,1,true),tostring(err)) end
defines={flow_precision_index={five_seconds=0,one_minute=1,ten_minutes=2,one_hour=3,ten_hours=4,fifty_hours=5,two_hundred_fifty_hours=6}}
-- per name: made per window index, used = made/2; all-time totals rank them
local W={['railgun-ammo']={[3]=600,[4]=6000,[5]=30000,[6]=31000},['iron-plate']={[3]=12000,[4]=120000,[5]=600000,[6]=2400000}}
local reads=0
local function stats(item)
  local tin=item and {['railgun-ammo']=31000,['iron-plate']=2400000,['copper-cable']=5} or {['thruster-fuel']=99}
  local tout={}
  for k,v in pairs(tin) do tout[k]=v/2 end
  return {input_counts=tin,output_counts=tout,
    get_flow_count=function(a)
      reads=reads+1
      local n=type(a.name)=='table' and a.name.name or a.name
      local v=(W[n] or {})[a.precision_index] or (n=='thruster-fuel' and 50 or 0)
      eq(a.count,true)
      return a.category=='input' and v or v/2
    end,
    get_input_count=function(n) return tin[n] or 0 end,get_output_count=function(n) return tout[n] or 0 end}
end
local nauvis={name='nauvis'}
local plsurf={name='platform-7'}
local pl={name='Resolute',surface=plsurf}; plsurf.platform=pl
prototypes={}
game={get_surface=function(n) return ({nauvis=nauvis,['platform-7']=plsurf})[n] end}
local p={force={get_item_production_statistics=function() return stats(true) end,get_fluid_production_statistics=function() return stats(false) end}}
local B=dofile('mod/agent-harness_0.1.0/platbom.lua'){platform=function(_,name) eq(name,'Resolute'); return pl end,cargo={}}

local r=B.production(p,{platform='Resolute',long=true})
eq(r.platform,'Resolute'); eq(r.surface,'platform-7')
eq(r.items[1].name,'iron-plate'); eq(r.items[2].name,'railgun-ammo'); eq(r.items[3].name,'thruster-fuel'); eq(r.items[3].kind,'fluid')
eq(r.items[2].made_1h,600); eq(r.items[2].used_10h,3000); eq(r.items[2].made_250h,31000)
eq(r.lines[2],'railgun-ammo: made 1h 600, 10h 6000, 50h 30k, 250h 31k; used 1h 300, 10h 3000, 50h 15k, 250h 15.5k')
has(r.note,'Imports are not production')
-- a planet, one item
r=B.production(p,{surface='nauvis',long=true,item='iron-plate'})
eq(#r.items,1); eq(r.surface,'nauvis'); eq(r.platform,nil); eq(r.items[1].made_50h,600000)
eq(r.lines[1],'iron-plate: made 1h 12k, 10h 120k, 50h 600k, 250h 2.4M; used 1h 6000, 10h 60k, 50h 300k, 250h 1.2M')
fails(function() B.production(p,{surface='platform-7',long=true}) end,'a platform goes as platform')
fails(function() B.production(p,{surface='nauvis'}) end,'surface goes with long')
fails(function() B.production(p,{platform='Resolute',surface='nauvis',long=true}) end,'platform or surface, not both')
-- at most LONG_ROWS
B.LONG_ROWS=1
r=B.production(p,{platform='Resolute',long=true})
eq(#r.items,1); has(r.lines[2],'+3 more names')
print('d29_batch336_long FL3: ok')
