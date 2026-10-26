-- d24 batch165 QH1 (Sol #2223: Asterion's narrow hull 2210 failed in several drafts whose floor checks saw only the marks
-- of the moment; what worked was a fill first, then the wing taken up): platform_plan {phases} plays ordered cancel,
-- remove and fill on a model of the floor by the hub's rules, per phase what went, was built, waits (why) and is cut
-- off, and the rollback played back from the end. Run: lua tests/d24_batch165.lua
package.path='mod/agent-harness_0.1.0/?.lua;'..package.path
local function eq(a,b,m) if a~=b then error((m or 'mismatch')..': '..tostring(a)..' ~= '..tostring(b),2) end end
local function has(s,x) assert(tostring(s):find(x,1,true),tostring(s)..' lacks '..x) end
defines={inventory={hub_main=1}}
prototypes={entity={}}
local FOUNDATION={name='space-platform-foundation',prototype={mineable_properties={products={{name='space-platform-foundation'}}}}}
local EMPTY={name='empty-space',prototype={}}
local floor={}
local function k(x,y) return x..','..y end
-- the main floor x 0..9, y 0..9 (the hub at 2,2); a wing x 10..13, y 2..7; a one-tile notch at (9,4) beside the wing
for x=0,9 do for y=0,9 do floor[k(x,y)]=true end end
for x=10,13 do for y=2,7 do floor[k(x,y)]=true end end
floor[k(9,4)]=nil
local ents={}
local surface={name='platform-9',
  get_tile=function(x,y) return floor[k(math.floor(x),math.floor(y))] and FOUNDATION or EMPTY end,
  find_entities_filtered=function(f)
    if f.type then return {} end
    local out={}
    if f.area then for _,e in ipairs(ents) do
      if e.position.x>f.area[1][1] and e.position.x<f.area[2][1] and e.position.y>f.area[1][2] and e.position.y<f.area[2][2] then out[#out+1]=e end
    end end
    return out
  end,
  count_entities_filtered=function() return 0 end}
local hub={valid=true,name='space-platform-hub',position={x=2,y=2},get_item_count=function() return 500 end,
  get_inventory=function() return {get_insertable_count=function() return 1000 end} end}
local pl={name='Tern',surface=surface,force='us',hub=hub,valid=true}
local PP=require('platplan'){platform=function() return pl end,position=function(v) return v end}
local wing={left_top={x=10,y=2},right_bottom={x=14,y=8}}

-- the wing taken up as one phase: the tile beside the notch waits (its empty sides meet only through it)
local r=PP.read({},{platform='Tern',phases={{remove=wing,name='take up the wing'}}})
local p1=r.phases[1]
eq(p1.settled,false)
assert(p1.marks_waiting>=1,'a tile waits')
local pinch=false
for _,w in ipairs(p1.waiting) do if w:find('^%(10%.5,4%.5%): ') then pinch=true; has(w,'do not meet through the tiles round it') end end
assert(pinch,'(10.5,4.5) waits: '..p1.line)
has(p1.line,'phase 1 (take up the wing): remove 24 tiles (24 marked); played to stability:')
eq(r.settled,false)
-- nothing in the game changed
eq(floor[k(13,2)],true); eq(floor[k(9,4)],nil)

-- the notch filled first, then the wing: every tile goes
r=PP.read({},{platform='Tern',phases={{fill={{x=9.5,y=4.5}},name='fill the notch'},{remove=wing,name='take up the wing'}}})
eq(r.phases[1].built,1); eq(r.phases[1].settled,true)
eq(r.phases[2].went,24); eq(r.phases[2].marks_waiting,0); eq(r.phases[2].settled,true)
eq(r.settled,true); eq(r['end'].removed,24); eq(r['end'].added,1)
-- the rollback: the wing filled back, the notch taken up; the notch then has no empty side and stays: coordinates only
eq(r.rollback.fill_count,24); eq(r.rollback.remove_count,1)
eq(r.rollback.order_checked,true); eq(r.rollback.restores,false)
has(r.rollback.line,'coordinates only, no order that returns to the start was found')
eq(#r.rollback.played,2); eq(r.rollback.played[1].step,'fill back'); eq(r.rollback.played[1].built,24); eq(r.rollback.played[1].settled,true)
eq(r.rollback.played[2].step,'take up'); eq(r.rollback.played[2].marks_waiting,1)
has(r.rollback.played[2].waiting[1],'none of its four side neighbours')
-- the rollback's areas as "x0..x1,y0..y1", which phases takes back
eq(r.rollback.fill[1],'10..13,2..7'); eq(r.rollback.remove[1],'9..9,4..4')
local again=PP.read({},{platform='Tern',phases={{fill='9,4'},{remove=r.rollback.fill}}})
eq(again.phases[2].went,24)
-- (d26 batch249 R10) a hub holding only rare foundation: the same plan (2.0.77: {name} alone counts every quality, the
-- bare name normal only, which read 0 here)
hub.get_item_count=function(q) if type(q)=='table' and q.name=='space-platform-foundation' and (q.quality==nil or q.quality=='rare') then return 500 end return 0 end
local rare=PP.read({},{platform='Tern',phases={{fill='9,4'},{remove=r.rollback.fill}}})
eq(rare.phases[1].line,again.phases[1].line); eq(rare.phases[2].went,24)
hub.get_item_count=function() return 500 end

-- a tile that stands under an entity waits naming it; a removal that leaves floor joined only by a corner cuts it off
-- (10,9) east of the main floor's corner tile (9,9), and (10,10) under it, joined to the floor only through (10,9)
floor[k(10,9)]=true; floor[k(10,10)]=true
ents[1]={valid=true,name='iron-chest',type='container',position={x=13.5,y=7.5}}
r=PP.read({},{platform='Tern',phases={{remove={{x=13.5,y=7.5}}},{remove={{x=10.5,y=9.5}}}}})
eq(r.phases[1].marks_waiting,1); has(r.phases[1].waiting[1],'(13.5,7.5): iron-chest (13.5,7.5) stands on it')
eq(r.phases[2].went,1); eq(r.phases[2].cut_tiles,1)
has(r.phases[2].cut[1],'1 foundation tile in 10..10,10..10 cut off from the hub\'s floor (joined by sides)')
-- a cancel drops the marks a phase left
r=PP.read({},{platform='Tern',phases={{remove=wing},{cancel=wing},{fill={{x=9.5,y=4.5}}}}})
has(r.phases[2].line,string.format('cancel 24 tiles (%d marks, 0 ghosts cancelled)',r.phases[1].marks_waiting))
eq(r.phases[3].marks_waiting,0)
-- refusals: a phase with nothing, an unknown key
local ok,err=pcall(PP.read,{},{platform='Tern',phases={{}}})
assert(not ok and tostring(err):find('phases[1]: {cancel, remove, fill}',1,true),tostring(err))
ok,err=pcall(PP.read,{},{platform='Tern',phases={{fill={{x=1,y=1}},add={{x=1,y=1}}}}})
assert(not ok and tostring(err):find('phases[1].add: a phase takes cancel, remove, fill and name',1,true),tostring(err))
-- across ticks: a plan over NOW units goes on as a job (phases_check), and reads as the same plan in one go does
do
  local st={}
  game={tick=100}
  local FJ=require('floorphases'){state=function() return st end}
  local plan={{fill={{x=9.5,y=4.5}},name='fill the notch'},{remove=wing,name='take up the wing'},{fill=wing,name='put it back'},{remove=wing}}
  local whole=require('floorphases')({}).read(pl,plan)
  local r1=FJ.read(pl,plan)
  assert(r1.phases_check and r1.running,'a job: '..tostring(r1.line))
  has(r1.line,'phases_check: '..r1.phases_check)
  local mid=FJ.check(r1.phases_check)
  eq(mid.running,true)
  local ticks=0
  repeat game.tick=game.tick+1; FJ.tick(); ticks=ticks+1; r1=FJ.check(r1.phases_check) until not r1.running or ticks>500
  eq(r1.running,nil); assert(r1.ticks>=1)
  eq(#r1.phases,#whole.phases)
  for i,row in ipairs(whole.phases) do eq(r1.phases[i].went,row.went); eq(r1.phases[i].built,row.built); eq(r1.phases[i].marks_waiting,row.marks_waiting) end
  eq(r1['end'].removed,whole['end'].removed); eq(r1.rollback.restores,whole.rollback.restores)
  local ok2,err2=pcall(FJ.check,99)
  assert(not ok2 and tostring(err2):find('no phases plan #99',1,true),tostring(err2))
  game=nil
end
-- the play's run count is tilecheck's runs, on every ring of 8
local TC=require('tilecheck')()
local F=require('floorphases')({})
local RING={{0,-1},{1,-1},{1,0},{1,1},{0,1},{-1,1},{-1,0},{-1,-1}}
for mask=0,255 do
  local tiles={}
  for i,d in ipairs(RING) do tiles[d[1]..','..d[2]]=(math.floor(mask/2^(i-1))%2==1) end
  local s={get_tile=function(x,y) local e=tiles[x..','..y]; return (e==nil or e) and EMPTY or FOUNDATION end}
  eq(F.run_count(s,0,0,{}),#TC.runs(s,0,0,{}),'ring '..mask)
end
print('d24_batch165 QH1 floor phases: ok')
