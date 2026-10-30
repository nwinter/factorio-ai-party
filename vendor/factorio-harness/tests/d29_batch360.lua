-- BC, Astra #2772: guard-593 used tick 83453890's AQ->EDGE budget on the new deep leg at 83454180.
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(s:find(x,1,true),s..' lacks '..x) end
local function fixture()
  local pl={name='Resolute',valid=true,space_connection={name='aquilo-solar-system-edge'}}
  local p={force={platforms={pl}}}
  local f={reads=0,value=-77696,leg={from='aquilo',to='solar-system-edge',back=false,flown=0.99,length=100000}}
  local C=require('conditions'){
    leg=function() return f.leg end,
    return_budget=function(_,name,args)
      f.reads=f.reads+1; eq(name,pl.name); f.args=args
      if f.err then error(f.err,0) end
      if f.missing then return nil end
      return {binds={name='rocket',out_km_max=f.value}}
    end}
  local c={['until']='budget_below',platform='Resolute',km=5000,turnaround={km=0,back_to='solar-system-edge',
    speed_floor=25,margin=0.2,reserve={['firearm-magazine']=3600,rocket=2540,['railgun-ammo']=2700},
    items={'firearm-magazine','rocket','railgun-ammo'}}}
  local guard={['until']='all',conditions={
    {['until']='platform_progress',platform='Resolute',from='solar-system-edge',to='shattered-planet',at_least=1e-8},c}}
  return C,p,pl,f,c,guard
end

-- The exact timeline, including an arrival seen by the predicate and one between guard checks.
for _,observe_stop in ipairs{true,false} do
  local C,p,pl,f,c,guard=fixture()
  game={tick=83453890}
  local met,saw=C.check(p,guard)
  eq(met,false); eq(f.reads,1); has(saw,'-77696'); has(saw,'cached leg aquilo->solar-system-edge'); has(saw,'tick 83453890')
  game.tick=83454177; pl.space_location={name='solar-system-edge'}
  if observe_stop then
    met,saw=C.check(p,c); eq(met,false); eq(f.reads,1); has(saw,'cached budget cleared')
  end
  pl.space_location=nil; pl.space_connection={name='solar-system-edge-shattered-planet'}
  f.leg={from='solar-system-edge',to='shattered-planet',back=false,flown=1/4000000,length=4000000}
  f.value=22439; game.tick=83454180
  met,saw=C.check(p,guard)
  eq(met,false,'deep guard must not fire from the previous leg'); eq(f.reads,2)
  has(saw,'22439'); has(saw,'cached leg solar-system-edge->shattered-planet'); has(saw,'tick 83454180')
  assert(not saw:find('83453890',1,true))
  -- Reuse within the leg, even as progress changes, then read at the normal 600-tick boundary.
  f.value=100; f.leg.flown=0.01; game.tick=83454779
  met=C.check(p,guard); eq(met,false); eq(f.reads,2)
  game.tick=83454780
  met=C.check(p,guard); eq(met,true); eq(f.reads,3)
end
print('d29_batch360: AQ budget, EDGE arrival, deep-only guard, same-leg reuse and expiry: ok')

do
  local C,p,pl,f,c=fixture(); game={tick=1000}
  eq(C.check(p,c),true); eq(f.reads,1)
  -- Reversing mid-flight keeps the connection but changes the direction.
  game.tick=1001; f.leg={from='solar-system-edge',to='aquilo',back=true}; f.value=20000
  local met,saw=C.check(p,c); eq(met,false); eq(f.reads,2); has(saw,'direction back')
  -- Identity includes connection, endpoints, and direction independently.
  game.tick=1002; pl.space_connection={name='replacement-connection'}
  C.check(p,c); eq(f.reads,3)
  game.tick=1003; f.leg.back=false
  C.check(p,c); eq(f.reads,4)
  game.tick=1004; f.leg.to='shattered-planet'
  C.check(p,c); eq(f.reads,5)
  -- A stop also drops the cache if departure resumes the exact same connection and direction.
  game.tick=1005; pl.space_location={name='solar-system-edge'}
  eq(C.check(p,c),false); eq(f.reads,5)
  game.tick=1006; pl.space_location=nil
  C.check(p,c); eq(f.reads,6)
  -- No leg is an unavailable read, never a reason to reuse the last one.
  f.leg=nil; met,saw=C.check(p,c); eq(met,false); has(saw,'no flight leg'); eq(f.reads,6)
  f.leg={from='solar-system-edge',to='aquilo',back=true}; C.check(p,c); eq(f.reads,7)
end
print('d29_batch360: mid-flight direction/connection/endpoints and stop invalidate: ok')

do
  local C,p,pl,f,c,guard=fixture(); game={tick=2000}
  C.check(p,guard); eq(f.reads,1)
  game.tick=2001; f.leg={from='solar-system-edge',to='shattered-planet',back=false,flown=1/4000000,length=4000000}
  pl.space_connection={name='solar-system-edge-shattered-planet'}; f.err='deep budget unavailable'
  local met,saw=C.check(p,guard); eq(met,false); eq(f.reads,2)
  has(saw,'no fresh return budget for this leg (not met)'); has(saw,'deep budget unavailable'); has(saw,'tick 2001')
  game.tick=2002; f.err=nil; f.value=100
  eq(C.check(p,guard),false); eq(f.reads,2,'failure throttled on this leg only')
  game.tick=2601; eq(C.check(p,guard),true); eq(f.reads,3)
  -- A cached failure cannot delay the next leg's first read either.
  f.err='old leg unavailable'; game.tick=3201; eq(C.check(p,c),false); eq(f.reads,4)
  game.tick=3202; f.leg.back=true; f.err=nil
  eq(C.check(p,c),true); eq(f.reads,5)
  game.tick=3802; f.missing=true
  met,saw=C.check(p,c); eq(met,false); has(saw,'read returned no budget')
end
print('d29_batch360: new-leg failure/missing budget is not met, failures expire and invalidate: ok')

do
  local C,p,pl,f,c=fixture(); game={tick=3000}
  C.check(p,c); eq(f.reads,1)
  local function changed(n) game.tick=game.tick+1; C.check(p,c); eq(f.reads,n) end
  c.turnaround.reserve.rocket=2600; changed(2)
  c.turnaround.items[2]='repair-pack'; changed(3)
  c.turnaround.return_allowance={legs={'solar-system-edge->aquilo'},items={rocket=100},label='test'}; changed(4)
  c.turnaround.return_allowance.items.rocket=200; changed(5)
  c.turnaround.return_allowance.legs[1]='aquilo->solar-system-edge'; changed(6)
  c.turnaround.margin=0.3; changed(7)
  c.turnaround.reserve.rocket=nil; changed(8)
  -- Equal arguments in a new table reuse the read; changing only the predicate's threshold also reuses it.
  c.turnaround.items={'firearm-magazine','repair-pack','railgun-ammo'}; changed(8)
  c.km=0; changed(8)
  pl.name='Resolute II'; c.platform=pl.name; changed(9)
end
print('d29_batch360: argument values including nested reserve/items/allowance key the cache: ok')
