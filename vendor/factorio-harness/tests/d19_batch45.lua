-- d19 batch45. Run from the harness root: lua tests/d19_batch45.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) assert(a==b,(m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- batch40 C1 (Muse: second flares on a guarded spawner while shells flew): what is already coming at a flare's spot
do
  game={tick=7200}
  defines={inventory={artillery_turret_ammo=1}}
  local shells=10
  local piece={valid=true,unit_number=5,name='artillery-turret',position={x=-48.5,y=104.5},type='artillery-turret',
    get_inventory=function() return {get_item_count=function() return shells end,get_contents=function() return {{name='artillery-shell',count=shells}} end} end}
  local flare={valid=true}
  local st={artillery_checks={{index=1,by='muse',flare=flare,target={x=29.5,y=-56.5},surface=1,tick=7000,pieces={{e=piece,n=11}},m10=0},
    {index=1,by='muse',flare={valid=false},target={x=29.5,y=-56.5},surface=1,tick=3000,pieces={{e=piece,n=12}}}}}
  local surface={index=1,find_entities_filtered=function(f) if f.type=='artillery-projectile' then return {{},{}} end return {flare} end}
  local A=dofile('mod/agent-harness_0.1.0/artillery.lua'){state=function() return st end,position=function(v) return v end}
  local r=A.incoming(surface,{name='player'},{x=30,y=-56})
  eq(r.flares_waiting,1); eq(r.in_the_air,2)
  has(r.line,'1 flare of ours still waiting within 32 tiles; 2 artillery projectiles in the air within 64 tiles; team flares there in the last 60s: (29.5,-56.5) 3s ago by muse, still waiting')
  has(r.line,'pieces holding fewer shells since: artillery-turret (-48.5,104.5) 11 -> 10 shells')
  assert(not r.line:find('12 ->',1,true),'the flare over a minute old is left out')
  game,defines=nil,nil
end
print('d19_batch45 C1 artillery already coming: ok')
