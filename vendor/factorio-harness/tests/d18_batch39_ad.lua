-- d18 batch39, Groups A and D (the 19:50 poll; eng/d18-batch39-ad). Run from the harness root: lua tests/d18_batch39_ad.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,msg) assert(a==b,(msg or '')..' '..tostring(a)..' ~= '..tostring(b)) end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end

-- A1 (Luna, Grok: platform waits woke on board edits): wake_on_board: false holds board news for the reply.
-- A2 (Grok: woken by a board edit, missed that Cinder's launch had happened): whatever woke it, the waited condition now.
do
  game={tick=1000}
  local s={active={}}
  local seq=0
  local arrived=false
  local function integer(v,d,lo,hi,name) if v==nil then v=d end; assert(type(v)=='number' and v>=lo and v<=hi,name..' out of range'); return v end
  local W=dofile('mod/agent-harness_0.1.0/waits.lua'){state=function() return s end,integer=integer,replace=function() end,advance=function() end,
    clock_mode=function() return 'realtime' end,validate_condition=function() end,
    condition=function(p,c) return arrived,'Cinder '..(arrived and 'at gleba' or 'flying nauvis->gleba 40%') end,
    board_seq=function() return seq end,board_news=function(p,since) if seq>since then return '#1114 note by luna: Petrel drop landed' end end,
    platform_recent=function(name) eq(name,'Cinder'); return 'Cinder flying nauvis->gleba 40%; its latest launch up: #57 from gleba 12s ago (bioflux*400)' end}
  local p={index=1,name='grok',character={valid=true,health=300},force={}}
  -- a board edit wakes a plain sleep
  W.handlers.sleep(p,{seconds=600,condition={['until']='platform_arrived',platform='Cinder',location='gleba'}})
  seq=1; game.tick=1100
  local r=W.handlers.sleep_check(p,{})
  eq(r.woke,'board'); has(r.board,'#1114 note by luna')
  -- A2: the waited condition as it reads now, with the platform's place and its latest launch
  eq(#r.waited_now,1)
  has(r.waited_now[1],'not met now (Cinder flying nauvis->gleba 40%); Cinder flying nauvis->gleba 40%; its latest launch up: #57 from gleba 12s ago (bioflux*400)')
  -- wake_on_board: false: held, said with the wake
  game.tick=5000
  W.handlers.sleep(p,{seconds=600,condition={['until']='platform_arrived',platform='Cinder',location='gleba'},wake_on_board=false})
  seq=2; game.tick=5100
  eq(W.handlers.sleep_check(p,{peek=true}).woke,nil,'held, still asleep')
  seq=3; game.tick=5200
  arrived=true; game.tick=5300
  r=W.handlers.sleep_check(p,{})
  eq(r.woke,'condition'); eq(r.board_held_count,2); has(r.board_held[1],'#1114 note by luna')
  eq(r.waited_now,nil,'woken by its condition: saw says it')
  game.tick=9000; local ok,err=pcall(W.handlers.sleep,p,{seconds=60,wake_on_board='no'}); assert(not ok and tostring(err):find('wake_on_board must be true or false',1,true),err)
  game=nil
end
print('d18_batch39_ad A1 board wakes held, A2 the waited condition on any wake: ok')

print('d18 batch39 ad ok')
