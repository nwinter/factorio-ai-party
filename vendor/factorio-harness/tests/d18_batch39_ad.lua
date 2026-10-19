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


-- A3 (Luna 20:25: railgun-damage-1, infinite, finished a level and the wait read "not researched" until its timeout):
-- a technology with levels is met when its level passes the level at the wait's start, or `level: N`.
do
  local tech={name='railgun-damage-1',researched=false,level=3,prototype={max_level=4294967295}}
  local p={force={technologies={['railgun-damage-1']=tech,automation={name='automation',researched=false,level=1,prototype={max_level=1}}}}}
  local C=dofile('mod/agent-harness_0.1.0/conditions.lua'){}
  local c={['until']='researched',technology='railgun-damage-1'}
  local record={}
  local met,saw=C.check(p,c,nil,record)
  eq(met,false); eq(saw,'railgun-damage-1 level 3 (its level when the wait began): not researched yet (levels to 2 researched, level 3 next, infinite)')
  tech.level=4
  met,saw=C.check(p,c,nil,record)
  eq(met,true); eq(saw,'railgun-damage-1 level 3 (its level when the wait began): researched (levels to 3 researched, level 4 next, infinite)')
  -- level: N
  local c5={['until']='researched',technology='railgun-damage-1',level=5}
  eq((C.check(p,c5,nil,{})),false); tech.level=6; eq((C.check(p,c5,nil,{})),true)
  -- a plain technology as before
  local ca={['until']='researched',technology='automation'}
  met,saw=C.check(p,ca,nil,{}); eq(met,false); eq(saw,'automation not researched')
  -- a finite leveled one, all levels done
  tech.prototype.max_level=7; tech.researched=true; tech.level=7
  met,saw=C.check(p,{['until']='researched',technology='railgun-damage-1',level=7},nil,{}); eq(met,true); has(saw,'levels to 7 researched, every level')
end
print('d18_batch39_ad A3 researched on a technology with levels: ok')

-- D2 (Opus: speed-module-2 917, the bulk not among the places listed): the most held first, module slots as places
-- (beacons and drills read too), each kind's count and places.
do
  prototypes={item={['speed-module-2']={get_spoil_ticks=function() return 0 end}}}
  defines={inventory={robot_cargo=1}}
  game={tick=100}
  local function ent(t,name,x,n,mods) return {valid=true,type=t,name=name,position={x=x,y=0},get_item_count=function() return n end,
    get_module_inventory=mods and function() return {get_item_count=function() return mods end} end or nil} end
  local list={ent('container','steel-chest',300,755),ent('beacon','beacon',5,4,4),ent('beacon','beacon',9,4,4),ent('assembling-machine','assembling-machine-2',2,2,2),
    ent('mining-drill','electric-mining-drill',40,6,6)}
  local surf={name='nauvis',find_entities_filtered=function(f) if f.type=='item-entity' then return {} end
    local want={} for _,t in ipairs(f.type or {}) do want[t]=true end
    local out={} for _,e in ipairs(list) do if want[e.type] then out[#out+1]=e end end return out end}
  local S=dofile('mod/agent-harness_0.1.0/stores.lua'){agents=function() return {} end}
  local p={surface=surf,position={x=0,y=0},force={logistic_networks={}}}
  local w=S.where_is(p,{item='speed-module-2'})
  eq(w.total,771); eq(w.places[1].entity,'steel-chest'); eq(w.places[1].count,755)
  eq(w.places[2].entity,'electric-mining-drill'); eq(w.places[2].in_module_slots,6)
  eq(w.by_kind.module_slots,16); eq(w.by_kind.beacon,0)
  eq(w.kinds_line,'771 speed-module-2: 755 chest (1 place), 16 in module slots (4 places)')
  w=S.where_is(p,{item='speed-module-2',sort='nearest',limit=2})
  eq(w.places[1].entity,'assembling-machine-2'); eq(w.pages,3); eq(w.more,3)
  game,defines,prototypes=nil,nil,nil
end
print('d18_batch39_ad D2 where_is: the most held first, module slots as places: ok')
print('d18 batch39 ad ok')
